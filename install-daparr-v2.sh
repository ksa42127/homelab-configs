#!/usr/bin/env bash
# =============================================================================
# Daparr Installer v1.1 — Lidarr → DAP Sync Manager
# Node 3 (pve-nas, 192.168.1.105) — local-zfs storage
# Creates CT 233 at 192.168.1.233:8325
# =============================================================================
set -euo pipefail
YL='\033[1;33m'; GR='\033[0;32m'; RD='\033[0;31m'; CY='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CY}[daparr]${NC} $*"; }
success() { echo -e "${GR}[  ok  ]${NC} $*"; }
die()     { echo -e "${RD}[ fail ]${NC} $*"; exit 1; }

CTID=233; CT_IP="192.168.1.233"; CT_GW="192.168.1.1"; CT_DNS="192.168.1.200"
CT_HOST="daparr"; CT_DISK=4; CT_RAM=512; CT_CORES=1
STORAGE="local-zfs"; BRIDGE="vmbr0"; TEMPLATE_STORAGE="local"
LIDARR_URL="http://192.168.1.186:8686"
LIDARR_KEY="dd4cba55c4ee423580b207f67e669c91"
SYNCED_MUSIC_PATH="/mnt/backup5tb/media/music/synced"
DAPARR_PORT=8325

echo ""; echo -e "${YL}╔═══════════════════════════════════════════╗${NC}"
echo -e "${YL}║         Daparr Installer v1.1             ║${NC}"
echo -e "${YL}║      Lidarr → DAP Sync Manager            ║${NC}"
echo -e "${YL}╚═══════════════════════════════════════════╝${NC}"; echo ""

[[ $(id -u) -eq 0 ]] || die "Must run as root"
command -v pct &>/dev/null || die "Not a Proxmox host"
pct status "$CTID" &>/dev/null && die "CT $CTID exists. Remove: pct destroy $CTID --purge"
mountpoint -q /mnt/backup5tb || die "/mnt/backup5tb not mounted"
mkdir -p "$SYNCED_MUSIC_PATH"
success "Synced path ready: $SYNCED_MUSIC_PATH"

TEMPLATE_PATH=$(find /var/lib/vz/template/cache -name "debian-12-standard_*.tar.zst" 2>/dev/null | sort -V | tail -1 || true)
if [[ -z "$TEMPLATE_PATH" ]]; then
  info "Downloading Debian 12 template..."
  pveam update
  TMPL=$(pveam available --section system | grep "debian-12-standard" | sort -V | tail -1 | awk '{print $2}')
  pveam download "$TEMPLATE_STORAGE" "$TMPL"
  TEMPLATE_PATH=$(find /var/lib/vz/template/cache -name "debian-12-standard_*.tar.zst" | sort -V | tail -1)
fi
success "Template: $TEMPLATE_PATH"

info "Creating CT $CTID on $STORAGE..."
pct create "$CTID" "$TEMPLATE_PATH" \
  --hostname "$CT_HOST" --cores "$CT_CORES" --memory "$CT_RAM" --swap 256 \
  --rootfs "${STORAGE}:${CT_DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${CT_IP}/24,gw=${CT_GW}" \
  --nameserver "$CT_DNS" --unprivileged 1 --features nesting=1 --start 1 --onboot 1
sleep 4; success "CT $CTID created"

info "Adding bind mount..."
pct set "$CTID" --mp0 "${SYNCED_MUSIC_PATH},mp=/mnt/synced,backup=0"
pct restart "$CTID"; sleep 4
success "Bind mount: $SYNCED_MUSIC_PATH → /mnt/synced"

info "Installing packages..."
pct exec "$CTID" -- bash -c "
  echo 'nameserver 1.1.1.1' > /etc/resolv.conf
  apt-get update -qq
  apt-get install -y --no-install-recommends python3 python3-pip python3-venv curl ca-certificates 2>/dev/null
  echo 'nameserver 192.168.1.200' > /etc/resolv.conf; echo 'nameserver 1.1.1.1' >> /etc/resolv.conf"
success "Packages installed"

pct exec "$CTID" -- mkdir -p /opt/daparr/backend /opt/daparr/frontend
pct exec "$CTID" -- bash -c 'touch /opt/daparr/backend/__init__.py'

# Backend
info "Writing backend..."
pct exec "$CTID" -- tee /opt/daparr/backend/main.py > /dev/null << 'PYEOF'
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import StreamingResponse
import httpx, os, json, pathlib

LIDARR_URL  = os.getenv("LIDARR_URL",  "http://192.168.1.186:8686")
LIDARR_KEY  = os.getenv("LIDARR_KEY",  "dd4cba55c4ee423580b207f67e669c91")
SYNCED_PATH = pathlib.Path(os.getenv("SYNCED_PATH", "/mnt/synced"))
STATE_FILE  = pathlib.Path("/opt/daparr/state.json")
HEADERS     = {"X-Api-Key": LIDARR_KEY}

app = FastAPI(title="Daparr")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

def load_state():
    return json.loads(STATE_FILE.read_text()) if STATE_FILE.exists() else {"synced_albums": {}}
def save_state(s): STATE_FILE.write_text(json.dumps(s, indent=2))

async def lidarr_get(path):
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get(f"{LIDARR_URL}/api/v1{path}", headers=HEADERS)
        r.raise_for_status(); return r.json()

@app.get("/api/artists")
async def get_artists():
    return sorted(await lidarr_get("/artist"), key=lambda a: a.get("sortName","").lower())

@app.get("/api/artists/{artist_id}/albums")
async def get_albums(artist_id: int):
    return sorted(await lidarr_get(f"/album?artistId={artist_id}"), key=lambda a: a.get("releaseDate") or "9999")

@app.get("/api/proxy/image")
async def proxy_image(url: str):
    try:
        async with httpx.AsyncClient(timeout=10, follow_redirects=True) as c:
            h = {} if url.startswith("http") else HEADERS
            target = url if url.startswith("http") else f"{LIDARR_URL}{url}"
            r = await c.get(target, headers=h)
            return StreamingResponse(iter([r.content]), media_type=r.headers.get("content-type","image/jpeg"))
    except: raise HTTPException(404, "Image not found")

@app.get("/api/proxy/album-cover/{album_id}")
async def proxy_album_cover(album_id: int):
    try:
        async with httpx.AsyncClient(timeout=10, follow_redirects=True) as c:
            r = await c.get(f"{LIDARR_URL}/api/v1/MediaCover/Albums/{album_id}/cover-250.jpg", headers=HEADERS)
            return StreamingResponse(iter([r.content]), media_type="image/jpeg")
    except: raise HTTPException(404, "Cover not found")

@app.get("/api/sync/state")
async def get_sync_state(): return load_state()

@app.post("/api/sync/add")
async def add_to_sync(p: dict):
    state = load_state()
    aid, aname, atitle, apath = str(p["albumId"]), p.get("artistName","?"), p.get("albumTitle","?"), p.get("albumPath","")
    sa = "".join(c for c in aname  if c not in r'\/:*?"<>|').strip()
    st = "".join(c for c in atitle if c not in r'\/:*?"<>|').strip()
    d  = SYNCED_PATH / sa; d.mkdir(parents=True, exist_ok=True)
    lnk = d / st
    if apath and pathlib.Path(apath).exists() and not lnk.exists(): lnk.symlink_to(apath)
    state["synced_albums"][aid] = {"artistName":aname,"albumTitle":atitle,"path":str(lnk)}
    save_state(state); return {"ok":True,"albumId":aid,"path":str(lnk)}

@app.post("/api/sync/remove")
async def remove_from_sync(p: dict):
    state = load_state(); aid = str(p["albumId"])
    if aid in state["synced_albums"]:
        e = state["synced_albums"].pop(aid); lnk = pathlib.Path(e.get("path",""))
        if lnk.is_symlink(): lnk.unlink()
        try: lnk.parent.rmdir()
        except OSError: pass
        save_state(state)
    return {"ok":True}

@app.get("/api/health")
async def health():
    try:
        await lidarr_get("/system/status")
        return {"lidarr":"ok","synced_path":str(SYNCED_PATH),"path_exists":SYNCED_PATH.exists()}
    except Exception as ex: return {"lidarr":"error","detail":str(ex)}

app.mount("/", StaticFiles(directory="/opt/daparr/frontend", html=True), name="frontend")
PYEOF
success "Backend written"

# Frontend HTML
info "Writing frontend HTML..."
pct exec "$CTID" -- tee /opt/daparr/frontend/index.html > /dev/null << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Daparr</title>
  <script src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
  <script src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=DM+Mono:wght@300;400;500&family=Playfair+Display:wght@400;700&display=swap" rel="stylesheet">
  <style>
    *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
    :root{--bg:#0f0f0d;--surface:#181815;--surface2:#1e1e1b;--border:#252520;--border-warm:#3a3628;
      --gold:#c9a84c;--gold-dim:#7a6830;--gold-glow:rgba(201,168,76,.07);
      --text:#e8e4d8;--text-dim:#6a6660;--text-faint:#333330;--green:#6a8c5a;--red:#8c4a4a;
      --font-display:"Playfair Display",serif;--font-mono:"DM Mono",monospace}
    body{background:var(--bg);color:var(--text);font-family:var(--font-mono);overflow:hidden;height:100vh}
    #root{height:100vh}
  </style>
</head>
<body><div id="root"></div><script src="/app.js"></script></body>
</html>
HTMLEOF

# Frontend JS — write via python to avoid heredoc quoting issues
info "Writing frontend JS..."
pct exec "$CTID" -- python3 -c "
import pathlib
js = r'''
const { useState, useEffect, useRef, useCallback } = React;

async function api(path, opts = {}) {
  const r = await fetch(path, opts);
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}

const imgProxy   = url => \"/api/proxy/image?url=\" + encodeURIComponent(url);
const coverProxy = id  => \"/api/proxy/album-cover/\" + id;

function getPoster(images) {
  images = images || [];
  const p = images.find(i => i.coverType === \"poster\") || images.find(i => i.coverType === \"fanart\");
  return p ? (p.remoteUrl || p.url) : null;
}
function getFanart(images) {
  images = images || [];
  const f = images.find(i => i.coverType === \"fanart\");
  return f ? (f.remoteUrl || f.url) : null;
}

const initials    = n => n.replace(/^(The|A|An) /,\"\").split(/\s+/).slice(0,2).map(w=>w[0]||\"\" ).join(\"\").toUpperCase();
const statusColor = s => s===\"full\"?\"#c9a84c\":s===\"partial\"?\"#7a9060\":\"#333330\";
const statusLabel = s => s===\"full\"?\"SYNCED\":s===\"partial\"?\"PARTIAL\":\"\";

function ArtistAvatar({ artist, size, selected }) {
  size = size || 40;
  const [src, setSrc] = useState(null);
  const [ok, setOk]   = useState(false);
  useEffect(() => {
    const u = getPoster(artist.images);
    if (u) { setSrc(imgProxy(u)); setOk(true); } else setOk(false);
  }, [artist.id]);
  const border = \"1px solid \" + (selected ? \"var(--gold-dim)\" : \"var(--border-warm)\");
  const base   = { width:size, height:size, borderRadius:4, flexShrink:0, display:\"block\", border };
  if (ok && src)
    return React.createElement(\"img\", { src, alt:artist.artistName, onError:()=>setOk(false),
      style: Object.assign({}, base, { objectFit:\"cover\", objectPosition:\"center top\" }) });
  return React.createElement(\"div\", {
    style: Object.assign({}, base, { background:\"var(--surface2)\", display:\"flex\",
      alignItems:\"center\", justifyContent:\"center\",
      fontSize:size*0.3, fontWeight:500,
      color:selected?\"var(--gold)\":\"var(--gold-dim)\", fontFamily:\"var(--font-display)\" })
  }, initials(artist.artistName));
}

function ArtistHero({ artist }) {
  const [src, setSrc] = useState(null);
  const [ok, setOk]   = useState(false);
  useEffect(() => {
    const u = getFanart(artist.images);
    if (u) { setSrc(imgProxy(u)); setOk(true); } else setOk(false);
  }, [artist.id]);
  if (!ok || !src) return null;
  const e = React.createElement;
  return e(\"div\", { style:{ position:\"absolute\", inset:0, zIndex:0, overflow:\"hidden\" } },
    e(\"img\", { src, onError:()=>setOk(false), alt:\"\",
      style:{ width:\"100%\", height:\"100%\", objectFit:\"cover\", objectPosition:\"center 20%\",
        opacity:0.15, filter:\"saturate(0.5) blur(2px)\" } }),
    e(\"div\", { style:{ position:\"absolute\", inset:0,
      background:\"linear-gradient(to bottom,var(--bg) 0%,transparent 40%,var(--bg) 100%)\" } })
  );
}

function AlbumCard({ album, synced, onToggle }) {
  const [coverOk, setCoverOk] = useState(true);
  const [hovered, setHovered] = useState(false);
  const year = album.releaseDate ? new Date(album.releaseDate).getFullYear() : \"\\u2014\";
  const meta = [String(year),
    album.statistics && album.statistics.trackCount ? album.statistics.trackCount+\" TRK\" : null,
    album.albumType && album.albumType !== \"Album\" ? album.albumType.toUpperCase() : null
  ].filter(Boolean).join(\" \\u00b7 \");
  const e = React.createElement;
  return e(\"div\", {
    onClick: onToggle,
    onMouseEnter: ()=>setHovered(true),
    onMouseLeave: ()=>setHovered(false),
    style:{
      cursor:\"pointer\", borderRadius:6, overflow:\"hidden\",
      border: synced ? \"2px solid var(--gold-dim)\" : \"1px solid var(--border)\",
      background:\"var(--surface)\",
      transform: hovered ? \"scale(1.03)\" : \"scale(1)\",
      transition:\"transform 0.15s, border 0.15s, box-shadow 0.15s\",
      boxShadow: hovered ? \"0 8px 24px rgba(0,0,0,.5)\" : \"0 2px 8px rgba(0,0,0,.3)\"
    }
  },
    e(\"div\", { style:{ position:\"relative\", paddingBottom:\"100%\", background:\"var(--surface2)\" } },
      coverOk
        ? e(\"img\", { src:coverProxy(album.id), alt:album.title, onError:()=>setCoverOk(false),
            style:{ position:\"absolute\", inset:0, width:\"100%\", height:\"100%\", objectFit:\"cover\", display:\"block\" } })
        : e(\"div\", { style:{ position:\"absolute\", inset:0, display:\"flex\",
            alignItems:\"center\", justifyContent:\"center\", fontSize:42, color:\"var(--text-faint)\" } }, \"\\u266a\"),
      synced && e(\"div\", { style:{ position:\"absolute\", inset:0, background:\"rgba(201,168,76,.12)\",
          display:\"flex\", alignItems:\"flex-start\", justifyContent:\"flex-end\", padding:6 } },
        e(\"div\", { style:{ background:\"var(--gold)\", color:\"#0f0f0d\", borderRadius:3,
            fontSize:8, letterSpacing:\"1.5px\", padding:\"2px 6px\", fontWeight:600 } }, \"\\u2713 QUEUED\")
      )
    ),
    e(\"div\", { style:{ padding:\"8px 10px 10px\" } },
      e(\"div\", { style:{ fontSize:11, color:\"var(--text)\", fontWeight:500,
          whiteSpace:\"nowrap\", overflow:\"hidden\", textOverflow:\"ellipsis\" } }, album.title),
      e(\"div\", { style:{ fontSize:9, color:\"var(--text-dim)\", marginTop:3, letterSpacing:\".5px\" } }, meta)
    )
  );
}

const CSS = \`
  .app{display:flex;flex-direction:column;height:100vh;overflow:hidden}
  .hdr{display:flex;align-items:center;padding:0 20px;height:52px;border-bottom:1px solid var(--border);background:var(--surface);gap:24px;flex-shrink:0}
  .logo{font-family:var(--font-display);font-size:20px;font-weight:700;color:var(--gold);letter-spacing:-.5px}
  .logo span{font-family:var(--font-mono);font-size:9px;color:var(--text-faint);letter-spacing:2px;margin-left:8px}
  .nav{display:flex;gap:2px}
  .nb{background:none;border:none;color:var(--text-dim);font-family:var(--font-mono);font-size:10px;letter-spacing:1.5px;text-transform:uppercase;padding:5px 12px;cursor:pointer;border-radius:3px;transition:color .15s,background .15s}
  .nb:hover{color:var(--text);background:var(--surface2)} .nb.on{color:var(--gold);background:var(--gold-glow)}
  .hr{margin-left:auto;display:flex;align-items:center;gap:12px}
  .qpill{background:var(--gold-glow);border:1px solid var(--gold-dim);border-radius:3px;padding:4px 10px;font-size:10px;letter-spacing:1px;color:var(--gold);display:flex;align-items:center;gap:6px}
  .dpill{display:flex;align-items:center;gap:7px;background:var(--surface2);border:1px solid var(--border);border-radius:3px;padding:4px 10px;font-size:10px;color:var(--text-dim)}
  .dot{width:5px;height:5px;border-radius:50%;background:var(--green);box-shadow:0 0 5px var(--green)}
  .body{display:flex;flex:1;overflow:hidden}
  .sb{width:280px;flex-shrink:0;border-right:1px solid var(--border);display:flex;flex-direction:column;background:var(--surface)}
  .sbt{padding:10px 12px;border-bottom:1px solid var(--border);display:flex;flex-direction:column;gap:8px}
  .si{background:var(--bg);border:1px solid var(--border);border-radius:3px;color:var(--text);font-family:var(--font-mono);font-size:11px;padding:6px 10px;width:100%;outline:none;transition:border-color .15s}
  .si::placeholder{color:var(--text-faint)} .si:focus{border-color:var(--gold-dim)}
  .fr{display:flex;gap:3px}
  .fb{flex:1;background:none;border:1px solid var(--border);border-radius:3px;color:var(--text-dim);font-family:var(--font-mono);font-size:9px;letter-spacing:1px;text-transform:uppercase;padding:4px 0;cursor:pointer;transition:all .15s}
  .fb:hover{border-color:var(--border-warm);color:var(--text)} .fb.on{border-color:var(--gold-dim);color:var(--gold);background:var(--gold-glow)}
  .al{flex:1;overflow-y:auto;scrollbar-width:thin;scrollbar-color:var(--border) transparent}
  .ar{display:flex;align-items:center;gap:10px;padding:9px 12px;cursor:pointer;border-bottom:1px solid var(--border);transition:background .12s;position:relative}
  .ar:hover{background:var(--surface2)} .ar.on{background:var(--gold-glow)}
  .ar.on::before{content:\"\";position:absolute;left:0;top:0;bottom:0;width:2px;background:var(--gold)}
  .ai{flex:1;min-width:0}
  .an{font-size:12px;font-weight:500;color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .am{font-size:9px;color:var(--text-dim);margin-top:2px;letter-spacing:.5px}
  .badge{font-size:8px;letter-spacing:1.2px;padding:2px 5px;border-radius:2px;flex-shrink:0;font-weight:500}
  .det{flex:1;display:flex;flex-direction:column;overflow:hidden;background:var(--bg)}
  .empty{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;color:var(--text-faint);gap:10px}
  .empty p{font-size:10px;letter-spacing:1.5px;text-transform:uppercase}
  .dh{padding:20px 28px 18px;border-bottom:1px solid var(--border);background:var(--surface);flex-shrink:0;position:relative;min-height:120px;overflow:hidden}
  .dhc{position:relative;z-index:1}
  .dar{display:flex;align-items:flex-start;gap:16px}
  .dn{font-family:var(--font-display);font-size:24px;font-weight:700;color:var(--text);letter-spacing:-.5px;line-height:1.1}
  .ds{display:flex;gap:18px;margin-top:8px;flex-wrap:wrap}
  .dstat{font-size:10px;color:var(--text-dim);letter-spacing:.5px}
  .da{display:flex;gap:7px;margin-top:12px}
  .btn{font-family:var(--font-mono);font-size:10px;letter-spacing:1px;text-transform:uppercase;padding:6px 14px;border-radius:3px;cursor:pointer;border:1px solid;transition:all .15s}
  .bp{background:var(--gold);border-color:var(--gold);color:#0f0f0d;font-weight:500} .bp:hover{background:#d4b460}
  .bg{background:none;border-color:var(--border);color:var(--text-dim)} .bg:hover{border-color:var(--border-warm);color:var(--text)}
  .slbl{padding:7px 28px 5px;font-size:8px;letter-spacing:2px;text-transform:uppercase;color:var(--text-faint);border-bottom:1px solid var(--border);background:var(--surface);flex-shrink:0}
  .grid{flex:1;overflow-y:auto;padding:20px 28px;display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:16px;align-content:start;scrollbar-width:thin;scrollbar-color:var(--border) transparent}
  .sbar{border-top:1px solid var(--border);padding:8px 28px;display:flex;align-items:center;gap:20px;background:var(--surface);flex-shrink:0;font-size:9px;color:var(--text-dim);letter-spacing:.8px}
  .ldg{display:flex;align-items:center;justify-content:center;padding:40px;color:var(--text-faint);font-size:10px;letter-spacing:2px;gap:10px}
  @keyframes spin{from{transform:rotate(0)}to{transform:rotate(360deg)}} .spin{animation:spin 1s linear infinite;display:inline-block}
  .toast{position:fixed;bottom:20px;right:20px;background:var(--surface2);border:1px solid var(--border-warm);border-left:3px solid var(--gold);padding:9px 14px;font-size:10px;letter-spacing:.5px;border-radius:3px;color:var(--text);z-index:100;animation:fadeUp .18s ease}
  @keyframes fadeUp{from{transform:translateY(6px);opacity:0}to{transform:translateY(0);opacity:1}}
\`;

function App() {
  const [artists,LA]       = useState([]);
  const [albums,LB]        = useState({});
  const [syncState,SS]     = useState({});
  const [selected,SEL]     = useState(null);
  const [loadingList,LL]   = useState(true);
  const [loadingAlbums,LA2]= useState(false);
  const [search,SR]        = useState(\"\");
  const [filter,FT]        = useState(\"all\");
  const [view,VW]          = useState(\"library\");
  const [health,HL]        = useState(null);
  const [toast,TS]         = useState(null);
  const toastRef           = useRef(null);

  const showToast = msg => {
    TS(msg); clearTimeout(toastRef.current);
    toastRef.current = setTimeout(()=>TS(null), 2600);
  };

  useEffect(() => {
    Promise.all([api(\"/api/artists\"),api(\"/api/sync/state\"),api(\"/api/health\")])
      .then(([a,s,h]) => {
        LA(a);
        const st = {}; Object.keys(s.synced_albums||{}).forEach(k=>st[k]=true); SS(st);
        HL(h); LL(false);
      }).catch(()=>LL(false));
  }, []);

  useEffect(() => {
    if (!selected || albums[selected.id]) return;
    LA2(true);
    api(\"/api/artists/\"+selected.id+\"/albums\")
      .then(d=>{LB(p=>({...p,[selected.id]:d}));LA2(false);})
      .catch(()=>LA2(false));
  }, [selected && selected.id]);

  const toggleAlbum = useCallback(async (album, artist) => {
    const id = String(album.id);
    if (syncState[id]) {
      await api(\"/api/sync/remove\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},
        body:JSON.stringify({albumId:album.id})});
      SS(p=>{const n={...p};delete n[id];return n;});
      showToast(\"Removed from sync queue\");
    } else {
      await api(\"/api/sync/add\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},
        body:JSON.stringify({albumId:album.id,albumTitle:album.title,albumPath:album.path||\"\",artistName:artist.artistName})});
      SS(p=>({...p,[id]:true}));
      showToast(\"Added to sync queue\");
    }
  }, [syncState]);

  const queueAll = useCallback(async () => {
    if (!selected) return;
    for (const album of (albums[selected.id]||[])) {
      if (!syncState[String(album.id)]) {
        await api(\"/api/sync/add\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},
          body:JSON.stringify({albumId:album.id,albumTitle:album.title,albumPath:album.path||\"\",artistName:selected.artistName})});
        SS(p=>({...p,[String(album.id)]:true}));
      }
    }
    showToast((albums[selected.id]||[]).length+\" albums queued\");
  }, [selected,albums,syncState]);

  const removeAll = useCallback(async () => {
    if (!selected) return;
    for (const album of (albums[selected.id]||[])) {
      const id=String(album.id);
      if (syncState[id]) {
        await api(\"/api/sync/remove\",{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},
          body:JSON.stringify({albumId:album.id})});
        SS(p=>{const n={...p};delete n[id];return n;});
      }
    }
    showToast(\"Artist removed from sync\");
  }, [selected,albums,syncState]);

  const getStatus = a => {
    const al=albums[a.id]; if(!al) return \"none\";
    const n=al.filter(x=>syncState[String(x.id)]).length;
    return n===0?\"none\":n===al.length?\"full\":\"partial\";
  };

  const totalQueued = Object.keys(syncState).length;
  const selAlbums   = selected?(albums[selected.id]||[]):[];
  const selSynced   = selAlbums.filter(a=>syncState[String(a.id)]).length;
  const selStatus   = selected?getStatus(selected):\"none\";
  const filtered    = artists.filter(a => {
    if (!a.artistName.toLowerCase().includes(search.toLowerCase())) return false;
    if (filter===\"all\") return true;
    const st=getStatus(a);
    return filter===\"unsynced\"?st===\"none\":filter===st;
  });

  const e = React.createElement;
  return e(React.Fragment,null,
    e(\"style\",null,CSS),
    e(\"div\",{className:\"app\"},
      e(\"header\",{className:\"hdr\"},
        e(\"div\",{className:\"logo\"},\"Daparr\",e(\"span\",null,\"LIDARR \\u2192 DAP\")),
        e(\"nav\",{className:\"nav\"},[\"library\",\"queue\",\"devices\"].map(v=>
          e(\"button\",{key:v,className:\"nb\"+(view===v?\" on\":\"\"),onClick:()=>VW(v)},v)
        )),
        e(\"div\",{className:\"hr\"},
          totalQueued>0 && e(\"div\",{className:\"qpill\"},
            e(\"span\",{style:{fontSize:13,fontWeight:500}},totalQueued),\" ALBUMS QUEUED\"),
          e(\"div\",{className:\"dpill\"},e(\"div\",{className:\"dot\"}),\"iBasso DX180\")
        )
      ),
      e(\"div\",{className:\"body\"},
        e(\"aside\",{className:\"sb\"},
          e(\"div\",{className:\"sbt\"},
            e(\"input\",{className:\"si\",placeholder:\"Search artists\\u2026\",value:search,onChange:ev=>SR(ev.target.value)}),
            e(\"div\",{className:\"fr\"},[\"all\",\"synced\",\"partial\",\"unsynced\"].map(f=>
              e(\"button\",{key:f,className:\"fb\"+(filter===f?\" on\":\"\"),onClick:()=>FT(f)},f)
            ))
          ),
          e(\"div\",{className:\"al\"},
            loadingList
              ? e(\"div\",{className:\"ldg\"},e(\"span\",{className:\"spin\"},\"\\u25cc\"),\" LOADING\")
              : filtered.map(a=>{
                  const st=getStatus(a),sel=selected&&selected.id===a.id;
                  return e(\"div\",{key:a.id,className:\"ar\"+(sel?\" on\":\"\"),onClick:()=>SEL(a)},
                    e(ArtistAvatar,{artist:a,size:34,selected:sel}),
                    e(\"div\",{className:\"ai\"},
                      e(\"div\",{className:\"an\"},a.artistName),
                      e(\"div\",{className:\"am\"},
                        (a.statistics&&a.statistics.albumCount||\"?\")+\" ALBUMS\"+
                        (albums[a.id]?\" \\u00b7 \"+albums[a.id].filter(x=>syncState[String(x.id)]).length+\" QUEUED\":\"\")
                      )
                    ),
                    st!==\"none\"&&e(\"span\",{className:\"badge\",
                      style:{color:statusColor(st),border:\"1px solid \"+statusColor(st),background:statusColor(st)+\"18\"}
                    },statusLabel(st))
                  );
                })
          )
        ),
        e(\"main\",{className:\"det\"},
          !selected
            ? e(\"div\",{className:\"empty\"},
                e(\"span\",{style:{fontSize:36,color:\"var(--text-faint)\"}},\"\\u25c8\"),
                e(\"p\",null,loadingList?\"Connecting to Lidarr\\u2026\":\"Select an artist\")
              )
            : e(React.Fragment,null,
                e(\"div\",{className:\"dh\"},
                  e(ArtistHero,{artist:selected}),
                  e(\"div\",{className:\"dhc\"},
                    e(\"div\",{className:\"dar\"},
                      e(ArtistAvatar,{artist:selected,size:60,selected:true}),
                      e(\"div\",null,
                        e(\"div\",{className:\"dn\"},selected.artistName),
                        e(\"div\",{className:\"ds\"},
                          e(\"div\",{className:\"dstat\"},e(\"strong\",null,selAlbums.length),\" albums\"),
                          e(\"div\",{className:\"dstat\"},e(\"strong\",null,selSynced),\" queued\"),
                          selAlbums.length>0&&e(\"div\",{className:\"dstat\"},\"Status: \",
                            e(\"strong\",{style:{color:statusColor(selStatus)}},selStatus.toUpperCase())
                          )
                        ),
                        e(\"div\",{className:\"da\"},
                          e(\"button\",{className:\"btn bp\",onClick:queueAll,disabled:loadingAlbums},\"Queue All\"),
                          e(\"button\",{className:\"btn bg\",onClick:removeAll,disabled:loadingAlbums},\"Remove All\")
                        )
                      )
                    )
                  )
                ),
                e(\"div\",{className:\"slbl\"},\"Albums \\u2014 click cover to toggle sync\"),
                loadingAlbums
                  ? e(\"div\",{className:\"ldg\"},e(\"span\",{className:\"spin\"},\"\\u25cc\"),\" LOADING ALBUMS\")
                  : e(\"div\",{className:\"grid\"},
                      selAlbums.map(album=>e(AlbumCard,{key:album.id,album,
                        synced:!!syncState[String(album.id)],
                        onToggle:()=>toggleAlbum(album,selected)}))
                    ),
                e(\"div\",{className:\"sbar\"},
                  e(\"span\",null,e(\"strong\",null,selSynced),\" / \"+selAlbums.length+\" selected\"),
                  e(\"span\",null,\"Lidarr \",e(\"strong\",{style:{color:health&&health.lidarr===\"ok\"?\"var(--green)\":\"var(--red)\"}},
                    health&&health.lidarr===\"ok\"?\"CONNECTED\":\"ERROR\")),
                  e(\"span\",{style:{color:\"var(--text-faint)\"}},\"192.168.1.186:8686\")
                )
              )
        )
      )
    ),
    toast&&e(\"div\",{className:\"toast\"},toast)
  );
}

ReactDOM.createRoot(document.getElementById(\"root\")).render(React.createElement(App));
'''
pathlib.Path('/opt/daparr/frontend/app.js').write_text(js)
print('ok')
"
success "Frontend JS written"

info "Installing Python dependencies..."
pct exec "$CTID" -- bash -c "python3 -m venv /opt/daparr/venv && /opt/daparr/venv/bin/pip install --quiet fastapi 'uvicorn[standard]' httpx"
success "Python venv ready"

info "Creating systemd service..."
pct exec "$CTID" -- tee /etc/systemd/system/daparr.service > /dev/null << 'SVCEOF'
[Unit]
Description=Daparr - Lidarr to DAP Sync Manager
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/daparr
Environment=LIDARR_URL=http://192.168.1.186:8686
Environment=LIDARR_KEY=dd4cba55c4ee423580b207f67e669c91
Environment=SYNCED_PATH=/mnt/synced
ExecStart=/opt/daparr/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8325
Restart=unless-stopped
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

pct exec "$CTID" -- bash -c "systemctl daemon-reload && systemctl enable daparr && systemctl start daparr"
success "Service started"

info "Waiting for service to come up..."
sleep 6
HTTP=$(pct exec "$CTID" -- bash -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:8325/ 2>/dev/null || echo 000")

echo ""; echo -e "${YL}═══════════════════════════════════════════${NC}"
if [[ "$HTTP" == "200" ]]; then
  echo -e "${GR}  ✓ Daparr is running!${NC}"
else
  echo -e "${YL}  ⚠ HTTP $HTTP — check logs:${NC}"
  echo -e "  pct exec $CTID -- journalctl -u daparr -n 30 --no-pager"
fi
echo ""
echo -e "  ${CY}Web UI:${NC}    http://${CT_IP}:${DAPARR_PORT}"
echo -e "  ${CY}CT:${NC}        $CTID on $STORAGE"
echo -e "  ${CY}Logs:${NC}      pct exec $CTID -- journalctl -u daparr -f"
echo -e "  ${CY}Sync dir:${NC}  $SYNCED_MUSIC_PATH"
echo ""
echo -e "  ${YL}Next: open Syncthing (192.168.1.232:8384)${NC}"
echo -e "  Add folder: /mnt/backup5tb/media/music/synced"
echo -e "  Share with iBasso DX180 → /Music/Synced on SD card"
echo ""
echo -e "${YL}═══════════════════════════════════════════${NC}"
