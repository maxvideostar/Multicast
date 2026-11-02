#!/usr/bin/env bash
# =====================================================================
#  nTs-Encoder — encoder multicast broadcast pentru mini PC Intel (QSV/VAAPI)
#  Instalare all-in-one: Ubuntu 22.04 / 24.04, Debian 12
#
#    sudo bash install-ntsenc.sh              # instalează / actualizează
#    sudo bash install-ntsenc.sh uninstall    # dezinstalează (păstrează config)
#
#  Opțiuni (variabile de mediu):
#    PORT=8090          portul panoului web
#    MCAST_IF=enp1s0    interfața pe care ies multicasturile (implicit: cea cu default route)
# =====================================================================
set -euo pipefail
APP=/opt/ntsenc; CONF=/etc/ntsenc; DATA=/var/lib/ntsenc; SVC=ntsenc
PORT="${PORT:-8090}"
G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
say(){ echo -e "${G}==>${N} $*"; }; warn(){ echo -e "${Y}[!]${N} $*"; }
[ "$(id -u)" = 0 ] || { echo -e "${R}Rulează cu sudo.${N}"; exit 1; }

if [ "${1:-}" = "uninstall" ]; then
  systemctl disable --now $SVC 2>/dev/null || true
  rm -f /etc/systemd/system/$SVC.service; systemctl daemon-reload
  rm -rf "$APP" "$DATA"
  say "Dezinstalat. Configurația a rămas în $CONF (șterge manual dacă vrei)."; exit 0
fi

. /etc/os-release
say "Sistem: $PRETTY_NAME"
export DEBIAN_FRONTEND=noninteractive

# ---------- 1. pachete: ffmpeg, drivere Intel VAAPI/QSV, utilitare captură
if [ "${SKIP_APT:-0}" != 1 ]; then
  say "Activez depozitele pentru driverul Intel non-free…"
  if [ "$ID" = ubuntu ]; then
    apt-get update -qq; apt-get install -y -qq software-properties-common >/dev/null
    add-apt-repository -y multiverse >/dev/null 2>&1 || true
  elif [ "$ID" = debian ]; then
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
      sed -i -E '/^Components:/{/non-free( |$)/!s/$/ non-free/}' /etc/apt/sources.list.d/debian.sources
      sed -i -E '/^Components:/{/non-free-firmware/!s/$/ non-free-firmware/}' /etc/apt/sources.list.d/debian.sources
    else
      sed -i -E '/^deb .*main/{/non-free( |$)/!s/main/main contrib non-free non-free-firmware/}' /etc/apt/sources.list
    fi
  fi
  apt-get update -qq
  say "Instalez ffmpeg, drivere VAAPI/QSV, v4l-utils, alsa-utils…"
  apt-get install -y -qq ffmpeg python3 curl vainfo v4l-utils alsa-utils intel-gpu-tools pciutils iproute2 >/dev/null
  apt-get install -y -qq intel-media-va-driver-non-free >/dev/null 2>&1 \
    || apt-get install -y -qq intel-media-va-driver >/dev/null 2>&1 || warn "intel-media-va-driver indisponibil"
  apt-get install -y -qq i965-va-driver >/dev/null 2>&1 || true          # GPU Intel vechi (Gen 5–8)
  for p in libvpl2 libmfx-gen1.2 libmfx-gen1 libmfx1; do apt-get install -y -qq $p >/dev/null 2>&1 || true; done  # runtime QSV
fi

# ---------- 2. aplicația
say "Instalez aplicația în $APP"
mkdir -p "$APP" "$CONF" "$DATA/hls"
cat > "$APP/ntsenc.py" <<'NTSENC_FILE_EOF'
#!/usr/bin/env python3
# nTs-Encoder — encoder multicast broadcast pentru mini PC cu Intel iGPU (VAAPI/QSV)
# Intrări: HDMI/SDI (V4L2 + ALSA), UDP/RTP/SRT/RTMP/HTTP/HLS
# Ieșiri : UDP multicast MPEG-TS CBR, SRT, RTMP, HLS, HTTP-TS
import os, sys, json, time, threading, subprocess, signal, socket, secrets, hashlib, re, glob, queue, shlex, collections
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from http import cookies
from urllib.parse import urlparse, parse_qs

VERSION = "1.0.0"
CONF_DIR = os.environ.get("NTSENC_CONF", "/etc/ntsenc")
DATA_DIR = os.environ.get("NTSENC_DATA", "/var/lib/ntsenc")
CONF_FILE = os.path.join(CONF_DIR, "config.json")
HLS_DIR = os.path.join(DATA_DIR, "hls")
FFMPEG = os.environ.get("NTSENC_FFMPEG", "ffmpeg")
HTTPTS_BASE_PORT = 21000

LOCK = threading.RLock()
SESSIONS = {}

# ---------------------------------------------------------------- config
def h(pw, salt): return hashlib.sha256((salt + pw).encode()).hexdigest()

def default_config():
    salt = secrets.token_hex(8)
    return {"user": "admin", "salt": salt, "pass": h("admin", salt), "port": 8090,
            "vaapi_device": "/dev/dri/renderD128", "stream_token": "", "channels": []}

def default_channel():
    return {
        "id": secrets.token_hex(4), "name": "Canal nou", "enabled": False, "lport": 0,
        "input": {"type": "url", "url": "udp://239.0.0.1:1234", "program": "",
                  "v4l2_dev": "/dev/video0", "v4l2_format": "auto", "v4l2_size": "1920x1080",
                  "v4l2_fps": "", "alsa_dev": "", "hwdec": True, "all_audio": False},
        "video": {"codec": "h264_vaapi", "width": 1920, "height": 1080, "fps": "25", "deint": "auto",
                  "bitrate": 6000, "gop": 50, "bframes": 2, "profile": "high", "low_power": "auto"},
        "audio": {"codec": "mp2", "bitrate": 192, "channels": 2, "samplerate": 48000},
        "ts": {"service_id": 1, "service_name": "", "provider": "nTs-Encoder", "pmt_pid": 4096,
               "video_pid": 256, "audio_pid": 257, "audio_pids": "", "pid_mode": "manual",
               "muxrate": 0, "pcr_period": 20},
        "out": {"udp": "udp://239.1.1.1:1234", "ttl": 16, "localaddr": "",
                "srt": "", "rtmp": "", "hls": False, "hls_time": 2, "hls_list": 6, "httpts": True},
    }

def deep_merge(base, upd):
    for k, v in upd.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict): deep_merge(base[k], v)
        else: base[k] = v
    return base

def load_config():
    os.makedirs(CONF_DIR, exist_ok=True); os.makedirs(HLS_DIR, exist_ok=True)
    if not os.path.exists(CONF_FILE):
        cfg = default_config(); save_config(cfg); return cfg
    with open(CONF_FILE) as f: cfg = json.load(f)
    d = default_config(); d.update({k: v for k, v in cfg.items() if k != "channels"})
    d["channels"] = [deep_merge(default_channel(), c) for c in cfg.get("channels", [])]
    used = set()
    for c in d["channels"]:
        if not c.get("lport") or c["lport"] in used:
            c["lport"] = next(p for p in range(HTTPTS_BASE_PORT, HTTPTS_BASE_PORT + 5000) if p not in used)
        used.add(c["lport"])
    return d

def save_config(cfg):
    tmp = CONF_FILE + ".tmp"
    with open(tmp, "w") as f: json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.replace(tmp, CONF_FILE)

CFG = load_config()

# ---------------------------------------------------------------- ffmpeg features
def ff_has(word):
    try:
        out = subprocess.run([FFMPEG, "-hide_banner", "-h", "full"], capture_output=True, text=True, timeout=15).stdout
        return word in out
    except Exception: return False
FF_FPSMODE = ff_has("-fps_mode")
try:
    FF_PROTO = subprocess.run([FFMPEG, "-hide_banner", "-protocols"], capture_output=True, text=True, timeout=15).stdout
except Exception: FF_PROTO = ""
try:
    FF_VER = subprocess.run([FFMPEG, "-version"], capture_output=True, text=True, timeout=15).stdout.splitlines()[0]
except Exception: FF_VER = "ffmpeg ?"

# ---------------------------------------------------------------- PIDs
RESOLVED = {}   # ch_id -> PID-urile efective folosite la ultima pornire

def input_url(i):
    url = i["url"].strip()
    sch = urlparse(url).scheme.lower()
    if sch in ("udp", "rtp"):
        sep = "&" if "?" in url else "?"
        if "fifo_size" not in url: url += f"{sep}fifo_size=1000000&overrun_nonfatal=1"; sep = "&"
        if "timeout" not in url: url += f"{sep}timeout=10000000"
        try:
            hostpart = (urlparse(url).hostname or "")
            if hostpart and 224 <= int(hostpart.split(".")[0]) <= 239 and "reuse" not in url: url += "&reuse=1"
        except ValueError: pass
    return url

def probe_source(url):
    """Analizează sursa: programe, PMT, PID-uri, codecuri, limbi."""
    try:
        r = subprocess.run(["ffprobe", "-hide_banner", "-v", "error", "-analyzeduration", "4000000", "-probesize", "8000000",
                            "-show_programs", "-show_streams", "-of", "json", url],
                           capture_output=True, text=True, timeout=25)
        j = json.loads(r.stdout or "{}")
    except subprocess.TimeoutExpired:
        return {"error": "Timp depășit — sursa nu trimite date"}
    except Exception as e:
        return {"error": str(e)}
    def st(x):
        try: pid = int(str(x.get("id", "0")), 16) if str(x.get("id", "")).startswith("0x") else int(x.get("id") or 0)
        except ValueError: pid = 0
        t = x.get("tags") or {}
        info = x.get("codec_name") or "?"
        if x.get("codec_type") == "video" and x.get("width"):
            info += f" {x['width']}x{x['height']}" + (" i" if x.get("field_order") in ("tt", "bb", "tb", "bt") else "")
        if x.get("codec_type") == "audio":
            info += f" {x.get('sample_rate','')}Hz {x.get('channels','')}ch"
        return {"index": x.get("index"), "pid": pid, "type": x.get("codec_type", "?"), "codec": info,
                "lang": t.get("language", "")}
    progs = []
    for pg in j.get("programs") or []:
        t = pg.get("tags") or {}
        progs.append({"program_id": pg.get("program_id"), "pmt_pid": pg.get("pmt_pid"), "pcr_pid": pg.get("pcr_pid"),
                      "name": t.get("service_name", ""), "provider": t.get("service_provider", ""),
                      "streams": sorted([st(x) for x in pg.get("streams") or []], key=lambda z: z["index"] or 0)})
    if not progs and j.get("streams"):
        progs.append({"program_id": 0, "pmt_pid": 0, "pcr_pid": 0, "name": "", "provider": "",
                      "streams": [st(x) for x in j["streams"]]})
    if not progs: return {"error": (r.stderr or "Nicio informație de la sursă").strip()[-300:]}
    return {"programs": progs}

def parse_pids(txt):
    out = []
    for x in re.split(r"[,\s;]+", str(txt or "").strip()):
        if not x: continue
        try: out.append(int(x, 16) if x.lower().startswith("0x") else int(x))
        except ValueError: pass
    return out

def resolve_pids(ch, src=None):
    """PID-urile efective: manual sau copiate din sursă (src = rezultat probe_source)."""
    ts, i = ch["ts"], ch["input"]
    n_audio = 0 if ch["audio"]["codec"] == "none" else (1 if (not i.get("all_audio") or i["type"] == "v4l2") else 8)
    r = {"sid": int(ts["service_id"]), "pmt": int(ts["pmt_pid"]), "vpid": int(ts["video_pid"]),
         "apids": [], "mode": "manual", "name": ts.get("service_name") or ch["name"],
         "provider": ts.get("provider") or "nTs-Encoder"}
    man = parse_pids(ts.get("audio_pids"))
    for k in range(n_audio):
        r["apids"].append(man[k] if k < len(man) else (man[-1] + k - len(man) + 1 if man else int(ts["audio_pid"]) + k))
    # ce afișăm: pistele cunoscute (lista manuală / sursa); restul sunt rezerve pentru „toate pistele”
    r["show"] = (man[:n_audio] if man else r["apids"][:1]) + (["…"] if n_audio > max(1, len(man)) else [])
    if ts.get("pid_mode") == "source" and i["type"] == "url" and src and src.get("programs"):
        want = str(i.get("program") or "").strip()
        progs = src["programs"]
        pg = next((p for p in progs if str(p["program_id"]) == want), None) if want else \
             next((p for p in progs if any(s["type"] == "video" for s in p["streams"])), progs[0])
        if pg:
            vids = [s for s in pg["streams"] if s["type"] == "video"]
            auds = [s for s in pg["streams"] if s["type"] == "audio"]
            if vids and vids[0]["pid"] >= 16: r["vpid"] = vids[0]["pid"]
            if auds and n_audio:
                r["apids"] = [s["pid"] for s in auds[:n_audio] if s["pid"] >= 16] or r["apids"]
                r["show"] = list(r["apids"])
            if pg.get("program_id"): r["sid"] = int(pg["program_id"])
            if pg.get("pmt_pid"): r["pmt"] = int(pg["pmt_pid"])
            if not ts.get("service_name") and pg.get("name"): r["name"] = pg["name"]
            r["mode"] = "sursă"
    return r

def check_pids(r):
    allp = [r["pmt"], r["vpid"]] + [x for x in r["show"] if isinstance(x, int)]
    bad = [p for p in allp if not (16 <= p <= 8190)]
    if bad: return f"PID invalid: {bad} (permis 16–8190)"
    if len(set(allp)) != len(allp): return f"PID-uri duplicate: {allp}"
    return ""

# ---------------------------------------------------------------- command builder
def teeesc(s): return str(s).replace("\\", "\\\\").replace("|", "\\|").replace("[", "\\[").replace("]", "\\]")
def optesc(s): return str(s).replace("\\", "\\\\").replace(":", "\\:")

def build_cmd(ch, idx, src=None, store=True):
    i, v, a, ts, o = ch["input"], ch["video"], ch["audio"], ch["ts"], ch["out"]
    dev = CFG.get("vaapi_device") or "/dev/dri/renderD128"
    vc = v["codec"]
    is_vaapi, is_qsv = vc.endswith("_vaapi"), vc.endswith("_qsv")
    hw_enc = is_vaapi or is_qsv
    hwdec = bool(i.get("hwdec")) and vc != "copy"
    cmd = [FFMPEG, "-hide_banner", "-nostdin", "-loglevel", "warning", "-progress", "pipe:1",
           "-stats_period", "2", "-y"]
    if hw_enc or hwdec:
        cmd += ["-init_hw_device", f"vaapi=va:{dev}"]
        if is_qsv: cmd += ["-init_hw_device", "qsv=qs@va"]
        cmd += ["-filter_hw_device", "va"]
    # --- inputs
    hw_frames = False
    if hwdec:
        cmd += ["-hwaccel", "vaapi", "-hwaccel_device", "va"]
        if hw_enc: cmd += ["-hwaccel_output_format", "vaapi"]; hw_frames = True
    if i["type"] == "v4l2":
        cmd += ["-f", "v4l2", "-thread_queue_size", "2048"]
        if i.get("v4l2_format") and i["v4l2_format"] != "auto": cmd += ["-input_format", i["v4l2_format"]]
        if i.get("v4l2_size"): cmd += ["-video_size", i["v4l2_size"]]
        if str(i.get("v4l2_fps") or "").strip(): cmd += ["-framerate", str(i["v4l2_fps"])]
        cmd += ["-i", i["v4l2_dev"]]
        vmap, amaps = ["0:v:0"], []
        if i.get("alsa_dev"):
            cmd += ["-f", "alsa", "-thread_queue_size", "2048", "-ac", str(a.get("channels") or 2),
                    "-ar", "48000", "-i", i["alsa_dev"]]
            amaps = ["1:a:0"]
    else:
        url = input_url(i)
        sch = urlparse(url).scheme.lower()
        cmd += ["-fflags", "+genpts+discardcorrupt", "-analyzeduration", "3000000", "-probesize", "5000000"]
        if sch in ("http", "https"):
            cmd += ["-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5", "-rw_timeout", "10000000"]
        elif sch in ("rtmp", "rtmps"):
            cmd += ["-rw_timeout", "10000000"]
        cmd += ["-i", url]
        p = str(i.get("program") or "").strip()
        pre = f"0:p:{p}:" if p else "0:"
        vmap = [pre + "v:0"]
        amaps = [pre + "a?"] if i.get("all_audio") else [pre + "a:0?"]
    if a["codec"] == "none": amaps = []
    # --- video filters
    vf = []
    w, hgt = int(v.get("width") or 0), int(v.get("height") or 0)
    fps = str(v.get("fps") or "").strip()
    deint = v.get("deint", "auto")
    if vc == "copy":
        pass
    elif hw_enc:
        if not hw_frames: vf += ["format=nv12", "hwupload=extra_hw_frames=64"]
        if deint != "off": vf += ["deinterlace_vaapi=rate=frame:auto=%d" % (1 if deint == "auto" else 0)]
        sc = "scale_vaapi=format=nv12"
        if w and hgt: sc = f"scale_vaapi=w={w}:h={hgt}:format=nv12"
        vf += [sc]
        if fps: vf += [f"fps={fps}"]
        if is_qsv: vf += ["hwmap=derive_device=qsv", "format=qsv"]
    else:
        if deint != "off": vf += ["bwdif=mode=send_frame:deint=%s" % ("interlaced" if deint == "auto" else "all")]
        if w and hgt: vf += [f"scale={w}:{hgt}:flags=bicubic"]
        if fps: vf += [f"fps={fps}"]
        vf += ["format=yuv420p"]
    cmd += ["-map", vmap[0]]
    for m in amaps: cmd += ["-map", m]
    if vf: cmd += ["-vf", ",".join(vf)]
    # --- video encoder
    br = int(v.get("bitrate") or 4000); gop = int(v.get("gop") or 50); bf = int(v.get("bframes") or 0)
    if vc == "copy":
        cmd += ["-c:v", "copy"]
    else:
        cmd += ["-c:v", vc, "-b:v", f"{br}k", "-maxrate", f"{br}k", "-bufsize", f"{br}k", "-g", str(gop), "-bf", str(bf)]
        prof = v.get("profile") or ""
        if is_vaapi:
            cmd += ["-rc_mode", "CBR", "-aud", "1"]
            if prof and vc.startswith("h264"): cmd += ["-profile:v", prof]
            if v.get("low_power") == "on": cmd += ["-low_power", "1"]
        elif is_qsv:
            if prof and vc.startswith("h264"): cmd += ["-profile:v", prof]
            if v.get("low_power") == "on": cmd += ["-low_power", "1"]
            elif v.get("low_power") == "off": cmd += ["-low_power", "0"]
        elif vc == "libx264":
            cmd += ["-preset", "veryfast", "-minrate", f"{br}k", "-sc_threshold", "0",
                    "-x264-params", "nal-hrd=cbr:force-cfr=1"]
            if prof: cmd += ["-profile:v", prof]
        elif vc == "mpeg2video":
            cmd += ["-minrate", f"{br}k", "-sc_threshold", "0"]
        if fps and vc != "copy":
            cmd += (["-fps_mode", "cfr"] if FF_FPSMODE else ["-vsync", "cfr"])
    # --- audio
    if amaps:
        if a["codec"] == "copy":
            cmd += ["-c:a", "copy"]
        else:
            cmd += ["-c:a", a["codec"], "-b:a", f"{int(a.get('bitrate') or 128)}k",
                    "-ac", str(a.get("channels") or 2), "-ar", str(a.get("samplerate") or 48000),
                    "-af", "aresample=async=1:first_pts=0"]
    # --- PIDs / metadata
    pr = resolve_pids(ch, src)
    if store: RESOLVED[ch["id"]] = pr
    cmd += ["-streamid", f"0:{pr['vpid']}"]
    if amaps:
        for k, ap in enumerate(pr["apids"]): cmd += ["-streamid", f"{1+k}:{ap}"]
    cmd += ["-metadata", f"service_name={pr['name']}", "-metadata", f"service_provider={pr['provider']}",
            "-max_muxing_queue_size", "2048"]
    # --- outputs: encoderul scrie DOAR UDP (multicast + loopback intern).
    # SRT/RTMP/HLS/HTTP-TS sunt alimentate din loopback de procese separate,
    # astfel încât căderea unei ieșiri de rețea nu poate bloca multicastul.
    tsopt = [f"mpegts_service_id={pr['sid']}", f"mpegts_pmt_start_pid={pr['pmt']}",
             "mpegts_flags=+resend_headers+system_b", f"pcr_period={int(ts.get('pcr_period') or 20)}"]
    mr = int(ts.get("muxrate") or 0)
    if mr: tsopt.append(f"muxrate={mr*1000}")
    slaves = []
    q = f"pkt_size=1316&ttl={int(o.get('ttl') or 16)}"
    if o.get("localaddr"): q += f"&localaddr={o['localaddr']}"
    for u in [x.strip() for x in str(o.get("udp") or "").splitlines() if x.strip()]:
        uu = u + ("&" if "?" in u else "?") + q
        slaves.append("[f=mpegts:" + ":".join(tsopt) + "]" + teeesc(uu))
    slaves.append("[f=mpegts:onfail=ignore:" + ":".join(tsopt) + "]udp://127.0.0.1:%d?pkt_size=1316" % lport(ch))
    cmd += ["-f", "tee", "|".join(slaves)]
    return cmd

def sidecar_cmd(kind, target, ch):
    ts, a = ch["ts"], ch["audio"]
    pr = RESOLVED.get(ch["id"]) or resolve_pids(ch)
    base = [FFMPEG, "-hide_banner", "-loglevel", "error", "-fflags", "+genpts+discardcorrupt",
            "-analyzeduration", "2000000", "-f", "mpegts", "-i", "pipe:0"]
    meta = ["-metadata", f"service_name={pr['name']}", "-metadata", f"service_provider={pr['provider']}"]
    tsflags = ["-mpegts_service_id", str(pr["sid"]), "-mpegts_pmt_start_pid", str(pr["pmt"]),
               "-mpegts_flags", "+resend_headers"]
    tsflags += ["-streamid", f"0:{pr['vpid']}"]
    for k, ap in enumerate(pr["apids"]): tsflags += ["-streamid", f"{1+k}:{ap}"]
    if kind == "srt":
        return base + ["-map", "0", "-c", "copy"] + meta + tsflags + ["-f", "mpegts", target]
    if kind == "rtmp":
        ac = ["-c:a", "copy"] if a["codec"] == "aac" else ["-c:a", "aac", "-b:a", "128k", "-ar", "48000"]
        return base + ["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"] + ac + \
            ["-f", "flv", "-flvflags", "no_duration_filesize", target]
    if kind == "hls":
        o = ch["out"]; d = os.path.join(HLS_DIR, ch["id"])
        ac = ["-c:a", "copy"] if a["codec"] in ("aac", "none") else ["-c:a", "aac", "-b:a", "128k", "-ar", "48000"]
        return base + ["-map", "0:v:0", "-map", "0:a?", "-c:v", "copy"] + ac + meta + [x for k, x in enumerate(tsflags) if k >= 6] + ["-f", "hls", "-hls_time", str(int(o.get("hls_time") or 2)),
                       "-hls_list_size", str(int(o.get("hls_list") or 6)),
                       "-hls_flags", "delete_segments+omit_endlist+independent_segments",
                       "-hls_segment_filename", os.path.join(d, "s_%06d.ts"), os.path.join(d, "index.m3u8")]

# ---------------------------------------------------------------- HTTP-TS relay
class Sidecar:
    """Proces FFmpeg separat (SRT/RTMP/HLS) alimentat din loopback; se reconectează singur."""
    NAMES = {"srt": "SRT", "rtmp": "RTMP", "hls": "HLS"}
    def __init__(self, kind, target, ch):
        self.kind, self.target, self.ch = kind, target, ch
        self.q = queue.Queue(maxsize=3000); self.proc = None; self.closed = False
        self.st = {"kind": self.NAMES[kind], "target": target, "state": "inactiv", "restarts": 0, "err": "", "since": 0}
        self.next_start = 0; self.fail = 0; self.lock = threading.Lock()
    def alive(self): return self.proc is not None and self.proc.poll() is None
    def feed(self, data):
        if self.closed: return
        if not self.alive():
            if time.time() < self.next_start: return
            with self.lock:
                if not self.alive(): self.spawn()
        try: self.q.put_nowait(data)
        except queue.Full: pass
    def spawn(self):
        if self.kind == "hls":
            d = os.path.join(HLS_DIR, self.ch["id"]); os.makedirs(d, exist_ok=True)
            for fn in glob.glob(os.path.join(d, "*")):
                try: os.remove(fn)
                except Exception: pass
        while not self.q.empty():
            try: self.q.get_nowait()
            except queue.Empty: break
        try:
            p = subprocess.Popen(sidecar_cmd(self.kind, self.target, self.ch), stdin=subprocess.PIPE,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
        except Exception as e:
            self.st.update(state="eroare", err=str(e)); self.next_start = time.time() + 10; return
        self.proc = p; self.st.update(state="activ", since=time.time())
        threading.Thread(target=self.writer, args=(p,), daemon=True).start()
        threading.Thread(target=self.reader, args=(p,), daemon=True).start()
    def writer(self, p):
        while p.poll() is None and not self.closed:
            try: data = self.q.get(timeout=1)
            except queue.Empty: continue
            chunks = [data]
            try:
                while len(chunks) < 64: chunks.append(self.q.get_nowait())
            except queue.Empty: pass
            try: p.stdin.write(b"".join(chunks)); p.stdin.flush()
            except Exception: break
        try: p.stdin.close()
        except Exception: pass
    def reader(self, p):
        for line in p.stderr:
            line = line.decode(errors="replace").strip()
            if line: self.st["err"] = line[:300]
        rc = p.wait()
        if self.closed or self.st["state"] == "inactiv": return
        ran = time.time() - self.st["since"]
        self.fail = 0 if ran > 60 else self.fail + 1
        self.st["restarts"] += 1; self.st["state"] = "eroare"
        self.next_start = time.time() + min(30, 2 ** self.fail)
    def kill(self):
        p = self.proc
        if p and p.poll() is None:
            try: os.killpg(p.pid, signal.SIGTERM)
            except Exception: pass
            try: p.wait(timeout=3)
            except Exception:
                try: os.killpg(p.pid, signal.SIGKILL)
                except Exception: pass
    def idle(self):
        if self.alive() or self.st["state"] != "inactiv":
            self.st["state"] = "inactiv"; self.kill(); self.next_start = 0; self.fail = 0
    def close(self): self.closed = True; self.st["state"] = "inactiv"; self.kill()

def relay_sig(ch, port):
    o = ch["out"]
    return json.dumps([port, o.get("srt"), o.get("rtmp"), o.get("hls"), o.get("hls_time"), o.get("hls_list"),
                       ch["ts"], ch["audio"]["codec"], ch["name"]], sort_keys=True)

STREAM_TYPES = {0x01: "MPEG-1 Video", 0x02: "MPEG-2 Video", 0x03: "MPEG-1 Audio", 0x04: "MPEG-2 Audio",
                0x0F: "AAC", 0x11: "AAC LATM", 0x15: "Metadata", 0x1B: "H.264", 0x24: "HEVC", 0x33: "VVC",
                0x81: "AC-3", 0x87: "E-AC-3", 0x86: "SCTE-35"}

class TsAnalyzer:
    """Analiză live a TS-ului de ieșire: PID-uri, tip, limbă, bitrate, serviciu (fără CC)."""
    def __init__(self):
        self.bytes = collections.Counter(); self.rates = {}; self.t0 = time.time(); self.lock = threading.Lock()
        self.pmt_pids = {}      # pmt_pid -> program
        self.es = {}            # pid -> {"type", "lang", "prog"}
        self.pcr = {}           # program -> pcr pid
        self.svc = {}           # program -> (name, provider)
        self.psi_t = {}         # pid -> ultima parsare
    def feed(self, data):
        n = len(data) - len(data) % 188
        cnt = self.bytes
        for off in range(0, n, 188):
            if data[off] != 0x47: continue
            pid = ((data[off + 1] & 0x1F) << 8) | data[off + 2]
            cnt[pid] += 188
            if (pid == 0 or pid == 0x11 or pid in self.pmt_pids) and data[off + 1] & 0x40:
                now = time.time()
                if now - self.psi_t.get(pid, 0) > 2:
                    self.psi_t[pid] = now
                    try: self.psi(pid, data[off:off + 188])
                    except Exception: pass
        now = time.time()
        if now - self.t0 >= 2:
            with self.lock:
                dt = now - self.t0
                self.rates = {k: v * 8 / dt for k, v in cnt.items()}
                self.bytes = collections.Counter(); self.t0 = now
    def psi(self, pid, pkt):
        afc = (pkt[3] >> 4) & 3
        i = 4 + (1 + pkt[4] if afc & 2 else 0)
        if not afc & 1: return
        i += 1 + pkt[i]                      # pointer_field
        tid = pkt[i]; slen = ((pkt[i + 1] & 0x0F) << 8) | pkt[i + 2]
        sec = pkt[i:i + 3 + slen]
        if len(sec) < 3 + slen: return       # secțiune pe mai multe pachete — ignorăm
        body, end = sec[8:], len(sec) - 4    # fără CRC
        if pid == 0 and tid == 0x00:
            pm = {}
            for k in range(8, end, 4):
                prog = (sec[k] << 8) | sec[k + 1]; pp = ((sec[k + 2] & 0x1F) << 8) | sec[k + 3]
                if prog: pm[pp] = prog
            self.pmt_pids = pm
        elif tid == 0x02:
            prog = (sec[3] << 8) | sec[4]
            self.pcr[prog] = ((sec[8] & 0x1F) << 8) | sec[9]
            k = 12 + (((sec[10] & 0x0F) << 8) | sec[11])
            es = {p: v for p, v in self.es.items() if v["prog"] != prog}
            while k + 5 <= end:
                st = sec[k]; epid = ((sec[k + 1] & 0x1F) << 8) | sec[k + 2]
                il = ((sec[k + 3] & 0x0F) << 8) | sec[k + 4]
                desc = sec[k + 5:k + 5 + il]; lang = ""; name = STREAM_TYPES.get(st, f"Tip 0x{st:02X}")
                d = 0
                while d + 2 <= len(desc):
                    tag, dl = desc[d], desc[d + 1]; dv = desc[d + 2:d + 2 + dl]
                    if tag == 0x0A and dl >= 3: lang = dv[:3].decode("latin-1", "replace")
                    elif st == 0x06 and tag == 0x6A: name = "AC-3"
                    elif st == 0x06 and tag == 0x7A: name = "E-AC-3"
                    elif st == 0x06 and tag == 0x56: name = "Teletext"
                    elif st == 0x06 and tag == 0x59:
                        name = "Subtitrări DVB"; lang = lang or dv[:3].decode("latin-1", "replace")
                    d += 2 + dl
                es[epid] = {"type": name, "lang": lang, "prog": prog}
                k += 5 + il
            self.es = es
        elif pid == 0x11 and tid == 0x42:
            k = 11
            while k + 5 <= end:
                sid = (sec[k] << 8) | sec[k + 1]; dl = ((sec[k + 3] & 0x0F) << 8) | sec[k + 4]
                desc = sec[k + 5:k + 5 + dl]; d = 0
                while d + 2 <= len(desc):
                    if desc[d] == 0x48:
                        pl = desc[d + 3]; prov = desc[d + 4:d + 4 + pl]; nl = desc[d + 4 + pl]
                        name = desc[d + 5 + pl:d + 5 + pl + nl]
                        dec = lambda b: (b[1:] if b[:1] and b[0] < 0x20 else b).decode("utf-8", "replace")
                        self.svc[sid] = (dec(name), dec(prov))
                    d += 2 + desc[d + 1]
                k += 5 + dl
    def report(self):
        with self.lock: rates = dict(self.rates)
        rows = []
        for pid in sorted(rates):
            if pid == 0: t = "PAT"
            elif pid == 0x11: t = "SDT"
            elif pid == 0x1FFF: t = "Null"
            elif pid in self.pmt_pids: t = "PMT"
            elif pid in self.es: t = self.es[pid]["type"]
            else: t = "?"
            kind = "video" if "Video" in t or t in ("H.264", "HEVC", "VVC") else \
                   "audio" if "Audio" in t or t in ("AAC", "AAC LATM", "AC-3", "E-AC-3") else "psi" if t in ("PAT", "SDT", "PMT", "Null") else "data"
            pcr = any(v == pid for v in self.pcr.values())
            rows.append({"pid": pid, "type": t, "kind": kind, "lang": self.es.get(pid, {}).get("lang", ""),
                         "rate": round(rates[pid]), "pcr": pcr})
        progs = [{"sid": sid, "name": n, "provider": pv} for sid, (n, pv) in self.svc.items()]
        return {"rows": rows, "programs": progs, "total": round(sum(rates.values()))}

class TsRelay:
    def __init__(self, port, ch):
        self.port, self.clients, self.lock, self.stop_ev = port, {}, threading.Lock(), threading.Event()
        self.sig = relay_sig(ch, port); self.httpts = bool(ch["out"].get("httpts"))
        self.bytes = 0; self.last = 0; self.sidecars = []; self.rate = 0; self._rb = 0; self._rt = time.time()
        self.ana = TsAnalyzer()
        o = ch["out"]
        for kind in ("srt", "rtmp"):
            for u in [x.strip() for x in str(o.get(kind) or "").splitlines() if x.strip()]:
                self.sidecars.append(Sidecar(kind, u, ch))
        if o.get("hls"): self.sidecars.append(Sidecar("hls", "", ch))
        self.t = threading.Thread(target=self.run, daemon=True); self.t.start()
    def run(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
        for _ in range(50):
            try: s.bind(("127.0.0.1", self.port)); break
            except OSError: time.sleep(0.2)
        s.settimeout(1)
        while not self.stop_ev.is_set():
            try: data = s.recv(65536)
            except socket.timeout:
                if time.time() - self.last > 10:
                    for sc in self.sidecars: sc.idle()
                continue
            except Exception: break
            self.bytes += len(data); self.last = time.time()
            if self.last - self._rt >= 2:
                self.rate = (self.bytes - self._rb) * 8 / (self.last - self._rt) / 1000
                self._rb, self._rt = self.bytes, self.last
            self.ana.feed(data)
            for sc in self.sidecars: sc.feed(data)
            if self.clients:
                with self.lock:
                    for cid, (q, info) in list(self.clients.items()):
                        try: q.put_nowait(data)
                        except queue.Full: info["drop"] = True
        s.close()
        for sc in self.sidecars: sc.close()
    def add(self, info):
        q = queue.Queue(maxsize=4000); cid = secrets.token_hex(6)
        with self.lock: self.clients[cid] = (q, info)
        return cid, q
    def remove(self, cid):
        with self.lock: self.clients.pop(cid, None)
    def close(self): self.stop_ev.set()

RELAYS = {}

def lport(ch):
    return int(ch.get("lport") or 0) or HTTPTS_BASE_PORT

# ---------------------------------------------------------------- worker
class Worker:
    def __init__(self, cid):
        self.cid = cid; self.proc = None; self.want = False; self.th = None
        self.log = collections.deque(maxlen=400)
        self.st = {"state": "oprit", "fps": 0, "bitrate": "", "speed": "", "frame": 0, "drop": 0, "dup": 0,
                   "started": 0, "restarts": 0, "last_err": "", "pid": 0, "last_progress": 0}
    def logln(self, s):
        self.log.append(time.strftime("%H:%M:%S ") + s.rstrip())
    def start(self):
        if self.want: return
        self.want = True; self.st["restarts"] = 0
        self.th = threading.Thread(target=self.loop, daemon=True); self.th.start()
    def stop(self):
        self.want = False; self.kill(); self.st["state"] = "oprit"
    def kill(self):
        p = self.proc
        if p and p.poll() is None:
            try: os.killpg(p.pid, signal.SIGTERM)
            except Exception: pass
            for _ in range(30):
                if p.poll() is not None: break
                time.sleep(0.1)
            if p.poll() is None:
                try: os.killpg(p.pid, signal.SIGKILL)
                except Exception: pass
    def loop(self):
        backoff = 1
        while self.want:
            ch, idx = find_channel(self.cid)
            if not ch: break
            src = None
            if ch["ts"].get("pid_mode") == "source" and ch["input"]["type"] == "url":
                self.st["state"] = "analizează"
                src = probe_source(input_url(ch["input"]))
                if src.get("error"): self.logln("PROBE: " + src["error"] + " — folosesc PID-urile manuale")
                self.st["src"] = src if not src.get("error") else None
            cmd = build_cmd(ch, idx, src)
            err = check_pids(RESOLVED[ch["id"]])
            if err:
                self.logln("EROARE: " + err); self.st.update(state="eroare", last_err=err)
                for _ in range(100):
                    if not self.want: break
                    time.sleep(0.1)
                continue
            self.logln("PID: SID %(sid)d · PMT %(pmt)d · video %(vpid)d · audio %(apids)s (%(mode)s)" % RESOLVED[ch["id"]])
            self.logln("START: " + shlex.join(cmd))
            self.st.update(state="pornește", started=time.time(), last_progress=time.time(), fps=0, speed="", frame=0, ot=0)
            try:
                self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                             text=True, bufsize=1, start_new_session=True)
            except Exception as e:
                self.logln(f"EROARE pornire: {e}"); self.st.update(state="eroare", last_err=str(e))
                time.sleep(5); continue
            self.st["pid"] = self.proc.pid
            threading.Thread(target=self.read_err, args=(self.proc,), daemon=True).start()
            threading.Thread(target=self.watchdog, args=(self.proc,), daemon=True).start()
            kv = {}
            for line in self.proc.stdout:
                if "=" not in line: continue
                k, _, val = line.strip().partition("=")
                kv[k] = val
                if k == "progress":
                    try: fr = int(kv.get("frame", 0) or 0)
                    except ValueError: fr = 0
                    try: ot = int(kv.get("out_time_us") or kv.get("out_time_ms") or 0)
                    except ValueError: ot = 0
                    if (fr and fr != self.st["frame"]) or (ot > 0 and ot != self.st.get("ot", 0)):
                        self.st["last_progress"] = time.time()
                        self.st["state"] = "rulează"
                    self.st.update(frame=fr, ot=ot, fps=kv.get("fps", "") if fr else "copy",
                                   speed=kv.get("speed", ""), drop=kv.get("drop_frames", 0), dup=kv.get("dup_frames", 0))
            rc = self.proc.wait()
            ran = time.time() - self.st["started"]
            if not self.want: break
            self.st["restarts"] += 1
            self.st["state"] = "eroare"
            self.logln(f"ffmpeg a ieșit (cod {rc}) după {int(ran)}s — repornesc")
            backoff = 1 if ran > 60 else min(backoff * 2, 30)
            for _ in range(backoff * 10):
                if not self.want: break
                time.sleep(0.1)
        self.st["state"] = "oprit"; self.st["pid"] = 0
    def read_err(self, p):
        for line in p.stderr:
            line = line.strip()
            if not line: continue
            self.logln(line); self.st["last_err"] = line[:300]
    def watchdog(self, p):
        while p.poll() is None:
            time.sleep(2)
            if time.time() - self.st["last_progress"] > 30:
                self.logln("WATCHDOG: niciun cadru de 30s — repornesc")
                try: os.killpg(p.pid, signal.SIGKILL)
                except Exception: pass
                break

WORKERS = {}

def find_channel(cid):
    with LOCK:
        for n, c in enumerate(CFG["channels"]):
            if c["id"] == cid: return c, n
    return None, -1

def sync_relays():
    with LOCK:
        wanted = {c["id"]: (lport(c), c) for c in CFG["channels"]}
        for cid in list(RELAYS):
            if cid not in wanted or RELAYS[cid].sig != relay_sig(wanted[cid][1], wanted[cid][0]):
                r = RELAYS.pop(cid); r.close(); r.t.join(timeout=3)
        for cid, (port, c) in wanted.items():
            if cid not in RELAYS: RELAYS[cid] = TsRelay(port, c)
            else: RELAYS[cid].httpts = bool(c["out"].get("httpts"))

def worker(cid):
    with LOCK:
        if cid not in WORKERS: WORKERS[cid] = Worker(cid)
        return WORKERS[cid]

def restart_channel(cid):
    w = worker(cid); was = w.want
    w.stop()
    if w.th: w.th.join(timeout=8)
    if was or find_channel(cid)[0]["enabled"]: w.start()

# ---------------------------------------------------------------- system stats
_prev = {"cpu": None, "net": None, "t": 0}
def sysstats():
    out = {}
    try:
        with open("/proc/stat") as f: p = list(map(int, f.readline().split()[1:]))
        idle, tot = p[3] + p[4], sum(p)
        if _prev["cpu"]:
            di, dt = idle - _prev["cpu"][0], tot - _prev["cpu"][1]
            out["cpu"] = round(100 * (1 - di / dt), 1) if dt else 0
        _prev["cpu"] = (idle, tot)
    except Exception: pass
    try:
        mi = {}
        for l in open("/proc/meminfo"):
            k, v = l.split(":"); mi[k] = int(v.split()[0])
        out["mem"] = round(100 * (1 - mi["MemAvailable"] / mi["MemTotal"]), 1)
        out["mem_total"] = round(mi["MemTotal"] / 1048576, 1)
    except Exception: pass
    temps = []
    for z in glob.glob("/sys/class/thermal/thermal_zone*/temp") + glob.glob("/sys/class/hwmon/hwmon*/temp1_input"):
        try: temps.append(int(open(z).read()) / 1000)
        except Exception: pass
    if temps: out["temp"] = round(max(temps), 1)
    for fa, fm in (("/sys/class/drm/card0/gt_act_freq_mhz", "/sys/class/drm/card0/gt_max_freq_mhz"),
                   ("/sys/class/drm/card1/gt_act_freq_mhz", "/sys/class/drm/card1/gt_max_freq_mhz")):
        try:
            out["gpu_mhz"] = int(open(fa).read()); out["gpu_max"] = int(open(fm).read()); break
        except Exception: pass
    try:
        net = {}
        for l in open("/proc/net/dev").readlines()[2:]:
            n, d = l.split(":", 1); d = d.split(); n = n.strip()
            if n == "lo": continue
            net[n] = (int(d[0]), int(d[8]))
        now = time.time()
        if _prev["net"]:
            dt = now - _prev["t"]
            out["net"] = {n: {"rx": round((v[0] - _prev["net"][n][0]) * 8 / dt / 1e6, 2),
                              "tx": round((v[1] - _prev["net"][n][1]) * 8 / dt / 1e6, 2)}
                          for n, v in net.items() if n in _prev["net"]}
        _prev["net"], _prev["t"] = net, now
    except Exception: pass
    try: out["load"] = open("/proc/loadavg").read().split()[:3]
    except Exception: pass
    try: out["uptime"] = int(float(open("/proc/uptime").read().split()[0]))
    except Exception: pass
    return out

def run(cmd, t=10):
    try: return subprocess.run(cmd, capture_output=True, text=True, timeout=t).stdout
    except Exception as e: return f"({e})"

def devices():
    vids = []
    for d in sorted(glob.glob("/dev/video*"), key=lambda x: int(re.sub(r"\D", "", x) or 0)):
        fm = run(["v4l2-ctl", "-d", d, "--list-formats-ext"])
        if "Video Capture" not in fm and "Size:" not in fm: continue
        name = run(["v4l2-ctl", "-d", d, "--info"])
        m = re.search(r"Card type\s*:\s*(.*)", name)
        vids.append({"dev": d, "name": m.group(1).strip() if m else d, "formats": fm.strip()})
    auds = []
    for l in run(["arecord", "-l"]).splitlines():
        m = re.match(r"card (\d+): (\S+) \[(.*?)\], device (\d+): .*?\[(.*?)\]", l)
        if m: auds.append({"dev": f"plughw:{m.group(1)},{m.group(4)}", "name": f"{m.group(3)} — {m.group(5)}"})
    gpus = []
    for d in sorted(glob.glob("/dev/dri/renderD*")):
        vi = run(["vainfo", "--display", "drm", "--device", d])
        drv = re.search(r"Driver version:\s*(.*)", vi)
        enc = sorted(set(re.findall(r"VAProfile(\w+)\s*:\s*VAEntrypointEncSlice(LP)?", vi)))
        gpus.append({"dev": d, "driver": drv.group(1).strip() if drv else "?",
                     "enc": [p + (" (LP)" if lp else "") for p, lp in enc], "raw": vi.strip()[-4000:]})
    return {"video": vids, "audio": auds, "gpu": gpus, "ffmpeg": FF_VER,
            "srt": " srt" in FF_PROTO or "\nsrt" in FF_PROTO}

# ---------------------------------------------------------------- HTTP
def public_cfg():
    with LOCK:
        c = json.loads(json.dumps(CFG))
    for k in ("salt", "pass"): c.pop(k, None)
    return c

class H(BaseHTTPRequestHandler):
    server_version = "nTs-Encoder/" + VERSION
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, code, body, ctype="application/json", extra=None):
        if isinstance(body, (dict, list)): body = json.dumps(body, ensure_ascii=False)
        if isinstance(body, str): body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def authed(self):
        c = cookies.SimpleCookie(self.headers.get("Cookie", ""))
        sid = c.get("ntsenc_sid")
        return bool(sid and SESSIONS.get(sid.value, 0) > time.time())
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n: return {}
        try: return json.loads(self.rfile.read(n))
        except Exception: return {}
    def token_ok(self, qs):
        t = CFG.get("stream_token") or ""
        return (not t) or qs.get("token", [""])[0] == t or self.authed()

    def do_GET(self):
        u = urlparse(self.path); p = u.path; qs = parse_qs(u.query)
        if p in ("/", "/index.html"):
            return self.send(200, PAGE if self.authed() else LOGIN, "text/html; charset=utf-8")
        if p == "/static/hls.min.js":
            fn = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hls.min.js")
            if not os.path.isfile(fn): return self.send(404, "", "text/plain")
            with open(fn, "rb") as f: return self.send(200, f.read(), "application/javascript", {"Cache-Control": "max-age=86400"})
        m = re.match(r"^/ts/([0-9a-f]+)(\.ts)?$", p)
        if m: return self.http_ts(m.group(1), qs)
        m = re.match(r"^/hls/([0-9a-f]+)/([\w.]+)$", p)
        if m:
            if not self.token_ok(qs): return self.send(403, "forbidden", "text/plain")
            fn = os.path.join(HLS_DIR, m.group(1), m.group(2))
            if not os.path.isfile(fn): return self.send(404, "not found", "text/plain")
            ct = "application/vnd.apple.mpegurl" if fn.endswith(".m3u8") else "video/mp2t"
            with open(fn, "rb") as f: data = f.read()
            if fn.endswith(".m3u8") and CFG.get("stream_token") and qs.get("token"):
                data = re.sub(rb"(s_\d+\.ts)", rb"\1?token=" + qs["token"][0].encode(), data)
            return self.send(200, data, ct, {"Access-Control-Allow-Origin": "*"})
        if not p.startswith("/api/"): return self.send(404, "not found", "text/plain")
        if not self.authed(): return self.send(401, {"error": "auth"})
        if p == "/api/state":
            chs = []
            with LOCK:
                for c in CFG["channels"]:
                    w = WORKERS.get(c["id"])
                    st = dict(w.st) if w else {"state": "oprit"}
                    st["running_for"] = int(time.time() - st["started"]) if st.get("started") and st["state"] != "oprit" else 0
                    r = RELAYS.get(c["id"])
                    st["clients"] = [{"ip": inf["ip"], "since": int(time.time() - inf["t"])} for _, inf in r.clients.values()] if r else []
                    st["outs"] = [dict(sc.st) for sc in r.sidecars] if r else []
                    st["pids"] = RESOLVED.get(c["id"]) or resolve_pids(c)
                    st.pop("src", None)
                    live = r and time.time() - r.last < 5
                    st["bitrate"] = (f"{r.rate/1000:.2f} Mb/s" if r.rate >= 1000 else f"{r.rate:.0f} kb/s") if live else "—"
                    chs.append({"id": c["id"], "name": c["name"], "enabled": c["enabled"], "st": st,
                                "summary": summary(c)})
            return self.send(200, {"channels": chs, "sys": sysstats(), "version": VERSION})
        if p == "/api/config": return self.send(200, public_cfg())
        if p == "/api/devices": return self.send(200, devices())
        if p == "/api/new": return self.send(200, default_channel())
        m = re.match(r"^/api/channel/([0-9a-f]+)/pids$", p)
        if m:
            r = RELAYS.get(m.group(1))
            if not r or time.time() - r.last > 5: return self.send(200, {"rows": [], "programs": [], "total": 0})
            return self.send(200, r.ana.report())
        m = re.match(r"^/api/channel/([0-9a-f]+)/(log|cmd)$", p)
        if m:
            ch, idx = find_channel(m.group(1))
            if not ch: return self.send(404, {"error": "nu există"})
            if m.group(2) == "log":
                w = WORKERS.get(ch["id"]); return self.send(200, {"log": list(w.log) if w else []})
            w = WORKERS.get(ch["id"])
            return self.send(200, {"cmd": shlex.join(build_cmd(ch, idx, w.st.get("src") if w else None, store=False))})
        return self.send(404, {"error": "?"})

    def do_POST(self):
        p = urlparse(self.path).path; b = self.body()
        if p == "/login":
            if b.get("user") == CFG["user"] and h(b.get("pass", ""), CFG["salt"]) == CFG["pass"]:
                sid = secrets.token_hex(24); SESSIONS[sid] = time.time() + 86400 * 7
                return self.send(200, {"ok": True}, extra={"Set-Cookie": f"ntsenc_sid={sid}; Path=/; HttpOnly; SameSite=Lax; Max-Age=604800"})
            time.sleep(1); return self.send(403, {"error": "Utilizator sau parolă greșită"})
        if p == "/logout":
            return self.send(200, {"ok": True}, extra={"Set-Cookie": "ntsenc_sid=; Path=/; Max-Age=0"})
        if not self.authed(): return self.send(401, {"error": "auth"})
        if p == "/api/probe":
            i = deep_merge(default_channel()["input"], b.get("input") or {})
            if i["type"] != "url": return self.send(200, {"error": "Analiza PID merge doar pentru surse de rețea"})
            w = WORKERS.get(b.get("id") or "")
            ch, _ = find_channel(b.get("id") or "")
            running = w and w.want and ch and ch["input"].get("url", "").strip() == i["url"].strip()
            res = probe_source(input_url(i))
            if res.get("error") and running:
                if w.st.get("src"):
                    res = dict(w.st["src"]); res["note"] = "Canalul rulează — afișez analiza făcută la pornire."
                elif "already in use" in res["error"]:
                    res["error"] = "Sursa unicast e deja citită de canalul pornit, deci nu poate fi analizată în paralel. Oprește canalul, sau pune modul „Originale din sursă” (analiza se face la pornire). Sursele multicast pot fi analizate oricând."
            return self.send(200, res)
        if p == "/api/preview_cmd":
            ch = deep_merge(default_channel(), b)
            _, idx = find_channel(ch["id"])
            if idx < 0: idx = len(CFG["channels"])
            pr = resolve_pids(ch)
            return self.send(200, {"cmd": shlex.join(build_cmd(ch, idx, store=False)), "pid_error": check_pids(pr)})
        if p == "/api/channel":
            ch = deep_merge(default_channel(), b)
            perr = check_pids(resolve_pids(ch))
            if perr and ch["ts"].get("pid_mode") != "source": return self.send(400, {"error": perr})
            with LOCK:
                ex, _ = find_channel(ch["id"])
                used = {c.get("lport") for c in CFG["channels"] if c["id"] != ch["id"]}
                if not ch.get("lport") or ch["lport"] in used:
                    ch["lport"] = next(pn for pn in range(HTTPTS_BASE_PORT, HTTPTS_BASE_PORT + 5000) if pn not in used)
                if ex: CFG["channels"][CFG["channels"].index(ex)] = ch
                else: CFG["channels"].append(ch)
                save_config(CFG)
            sync_relays()
            w = worker(ch["id"])
            if ch["enabled"]: threading.Thread(target=restart_channel, args=(ch["id"],), daemon=True).start()
            else: w.stop()
            return self.send(200, {"ok": True, "id": ch["id"]})
        m = re.match(r"^/api/channel/([0-9a-f]+)/(start|stop|restart|delete)$", p)
        if m:
            cid, act = m.groups(); ch, _ = find_channel(cid)
            if not ch: return self.send(404, {"error": "nu există"})
            if act == "delete":
                worker(cid).stop()
                with LOCK: CFG["channels"] = [c for c in CFG["channels"] if c["id"] != cid]; save_config(CFG)
                sync_relays(); return self.send(200, {"ok": True})
            with LOCK: ch["enabled"] = act != "stop"; save_config(CFG)
            if act == "stop": worker(cid).stop()
            elif act == "start": worker(cid).start()
            else: threading.Thread(target=restart_channel, args=(cid,), daemon=True).start()
            return self.send(200, {"ok": True})
        if p == "/api/settings":
            with LOCK:
                if b.get("newpass"):
                    if h(b.get("oldpass", ""), CFG["salt"]) != CFG["pass"]: return self.send(403, {"error": "Parola veche e greșită"})
                    CFG["salt"] = secrets.token_hex(8); CFG["pass"] = h(b["newpass"], CFG["salt"])
                for k in ("user", "vaapi_device", "stream_token"):
                    if k in b and b[k] is not None: CFG[k] = str(b[k]).strip() or CFG.get(k, "")
                if "stream_token" in b: CFG["stream_token"] = str(b["stream_token"]).strip()
                if b.get("port"): CFG["port"] = int(b["port"])
                save_config(CFG)
            return self.send(200, {"ok": True})
        return self.send(404, {"error": "?"})

    def http_ts(self, cid, qs):
        if not self.token_ok(qs): return self.send(403, "forbidden", "text/plain")
        r = RELAYS.get(cid)
        if not r or not r.httpts: return self.send(404, "canal fără HTTP-TS", "text/plain")
        ip = self.headers.get("X-Real-IP") or self.client_address[0]
        info = {"ip": ip, "t": time.time(), "drop": False}
        cid2, q = r.add(info)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "video/mp2t"); self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close"); self.end_headers()
            self.close_connection = True
            while not info["drop"]:
                try: data = q.get(timeout=10)
                except queue.Empty: break
                chunks = [data]
                try:
                    while len(chunks) < 64: chunks.append(q.get_nowait())
                except queue.Empty: pass
                self.wfile.write(b"".join(chunks))
        except Exception: pass
        finally: r.remove(cid2)

def summary(c):
    v, a, i, o = c["video"], c["audio"], c["input"], c["out"]
    src = i["url"] if i["type"] == "url" else f"{i['v4l2_dev']}" + (f" + {i['alsa_dev']}" if i.get("alsa_dev") else "")
    outs = [x.strip() for x in str(o.get("udp") or "").splitlines() if x.strip()]
    outs += ["SRT"] * len([x for x in str(o.get("srt") or "").splitlines() if x.strip()])
    outs += ["RTMP"] * len([x for x in str(o.get("rtmp") or "").splitlines() if x.strip()])
    if o.get("hls"): outs.append("HLS")
    if o.get("httpts"): outs.append("HTTP-TS")
    res = f"{v['width']}x{v['height']}" if v.get("width") and v.get("height") else "orig"
    vid = "copy" if v["codec"] == "copy" else f"{v['codec']} {res} {v.get('fps') or ''} {v['bitrate']}k"
    return {"src": src, "video": vid,
            "audio": "—" if a["codec"] == "none" else ("copy" if a["codec"] == "copy" else f"{a['codec']} {a['bitrate']}k"),
            "outs": outs, "muxrate": c["ts"].get("muxrate", 0), "sid": c["ts"]["service_id"],
            "hls": bool(o.get("hls")), "httpts": bool(o.get("httpts"))}

LOGIN = r"""__LOGIN__"""
PAGE = r"""__PAGE__"""

def main():
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        global LOGIN, PAGE
        if LOGIN == "__" + "LOGIN__": LOGIN = open(os.path.join(here, "login.html"), encoding="utf-8").read()
        if PAGE == "__" + "PAGE__": PAGE = open(os.path.join(here, "panel.html"), encoding="utf-8").read()
    except Exception as e:
        print("lipsesc fișierele html:", e)
    sync_relays()
    for c in CFG["channels"]:
        if c["enabled"]: worker(c["id"]).start()
    def bye(*_):
        for w in list(WORKERS.values()): w.want = False; w.kill()
        os._exit(0)
    signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGINT, bye)
    srv = ThreadingHTTPServer(("0.0.0.0", int(CFG.get("port") or 8090)), H)
    srv.daemon_threads = True
    print(f"nTs-Encoder {VERSION} pe portul {CFG.get('port')} — {FF_VER}", flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
NTSENC_FILE_EOF
cat > "$APP/panel.html" <<'NTSENC_FILE_EOF'
<!doctype html><html lang="ro"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>nTs-Encoder</title>
<script src="/static/hls.min.js" onerror="var s=document.createElement('script');s.src='https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.13/hls.min.js';document.head.appendChild(s)"></script>
<style>
:root{--bg:#0b0e13;--panel:#121720;--panel2:#171e29;--line:#232b38;--tx:#e6ebf2;--mut:#7d8898;--ok:#22c55e;--warn:#f59e0b;--bad:#ff3b30;--blue:#3b82f6;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.45 system-ui,Segoe UI,Roboto,sans-serif}
button{font:inherit;cursor:pointer;border:1px solid var(--line);background:var(--panel2);color:var(--tx);padding:7px 12px;border-radius:8px}
button:hover{border-color:#3a4558}button.pri{background:var(--tx);color:var(--bg);border-color:var(--tx);font-weight:700}
button.red{color:#ff8a83}button.grn{color:#6ee7a0}button.sm{padding:4px 9px;font-size:12.5px}
header{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;align-items:center;gap:14px;padding:12px 18px;background:rgba(11,14,19,.92);backdrop-filter:blur(6px);border-bottom:1px solid var(--line)}
.brand{display:flex;align-items:center;gap:9px;font-weight:800;letter-spacing:.01em;font-size:16px}
.brand .dot{width:11px;height:11px;border-radius:50%;background:var(--bad);box-shadow:0 0 10px var(--bad)}
.meters{display:flex;flex-wrap:wrap;gap:6px;flex:1}
.m{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:4px 10px;font-size:12px;color:var(--mut)}
.m b{color:var(--tx);font-family:var(--mono);font-weight:600;margin-left:4px}
.actions{display:flex;gap:6px;flex-wrap:wrap}
main{padding:18px;max-width:1500px;margin:0 auto}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:14px}
@media(max-width:420px){.grid{grid-template-columns:1fr}main{padding:12px}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden;display:flex;flex-direction:column}
.card .top{display:flex;align-items:center;gap:10px;padding:12px 14px;border-bottom:1px solid var(--line)}
.led{width:10px;height:10px;border-radius:50%;background:#3a4558;flex:none}
.led.run{background:var(--ok);box-shadow:0 0 9px var(--ok)}.led.start{background:var(--warn);box-shadow:0 0 9px var(--warn);animation:bl 1s infinite}
.led.err{background:var(--bad);box-shadow:0 0 9px var(--bad);animation:bl .6s infinite}@keyframes bl{50%{opacity:.35}}
.card h3{margin:0;font-size:15px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tag{font-size:11px;padding:2px 7px;border-radius:20px;border:1px solid var(--line);color:var(--mut);font-family:var(--mono)}
.stats{display:grid;grid-template-columns:repeat(4,1fr);border-bottom:1px solid var(--line)}
.stats div{padding:9px 12px;border-right:1px solid var(--line)}.stats div:last-child{border:0}
.stats span{display:block;font-size:10.5px;color:var(--mut);text-transform:uppercase;letter-spacing:.07em}
.stats b{font-family:var(--mono);font-size:15px;font-weight:600}
.info{padding:10px 14px;font-size:12.5px;color:var(--mut);display:grid;gap:3px}
.info code{color:var(--tx);font-family:var(--mono);font-size:12px;word-break:break-all}
.errbox{margin:0 14px 10px;padding:7px 9px;border-radius:7px;background:#2a1414;color:#ffb4ae;font-family:var(--mono);font-size:11.5px;word-break:break-all;max-height:60px;overflow:hidden}
.card .bot{display:flex;gap:6px;flex-wrap:wrap;padding:10px 14px;margin-top:auto;border-top:1px solid var(--line);background:var(--panel2)}
.empty{text-align:center;padding:60px 20px;color:var(--mut);border:1px dashed var(--line);border-radius:12px}
dialog{background:var(--panel);color:var(--tx);border:1px solid var(--line);border-radius:14px;padding:0;width:min(900px,96vw);max-height:92vh}
dialog::backdrop{background:rgba(0,0,0,.65)}
.dh{display:flex;align-items:center;gap:10px;padding:14px 18px;border-bottom:1px solid var(--line)}.dh h2{margin:0;font-size:16px;flex:1}
.db{padding:16px 18px;overflow:auto;max-height:calc(92vh - 130px)}.df{display:flex;justify-content:flex-end;gap:8px;padding:12px 18px;border-top:1px solid var(--line)}
.tabs{display:flex;gap:4px;padding:0 18px;border-bottom:1px solid var(--line);overflow-x:auto}
.tabs button{border:0;border-bottom:2px solid transparent;border-radius:0;background:none;color:var(--mut);padding:10px 12px;white-space:nowrap}
.tabs button.on{color:var(--tx);border-color:var(--tx)}
.pane{display:none}.pane.on{display:block}
.fg{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px 14px}
.fg .w2{grid-column:span 2}.fg .w3{grid-column:1/-1}@media(max-width:520px){.fg .w2{grid-column:1/-1}}
label.f{display:flex;flex-direction:column;gap:5px;font-size:11.5px;color:var(--mut);text-transform:uppercase;letter-spacing:.05em}
label.f input,label.f select,label.f textarea{text-transform:none;letter-spacing:0;font:13.5px var(--mono);padding:8px 10px;border-radius:7px;border:1px solid var(--line);background:#0d1119;color:var(--tx);width:100%}
label.f textarea{min-height:64px;resize:vertical}
label.ck{flex-direction:row;align-items:center;gap:8px;text-transform:none;font-size:13.5px;color:var(--tx);padding-top:20px}
.hint{font-size:12px;color:var(--mut);margin:12px 0 0;line-height:1.5}.hint code{font-family:var(--mono);color:#b9c3d1}
pre.log{margin:0;font:12px/1.5 var(--mono);white-space:pre-wrap;word-break:break-all;background:#080a0e;padding:12px;border-radius:8px;min-height:300px}
video{width:100%;background:#000;border-radius:8px;aspect-ratio:16/9}
.dev{border:1px solid var(--line);border-radius:9px;padding:10px 12px;margin-bottom:8px}
.dev summary{cursor:pointer}.dev pre{font:11.5px var(--mono);white-space:pre-wrap;color:var(--mut);max-height:240px;overflow:auto}
h4{margin:16px 0 8px;font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--mut)}
.pids{margin:0 14px 12px;border-top:1px solid var(--line)}
.pids h5{margin:10px 0 6px;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--mut);font-weight:600}
.pids table{width:100%;border-collapse:collapse;font:12.5px var(--mono)}
.pids th{text-align:left;font:600 11px system-ui,sans-serif;color:var(--mut);padding:5px 4px;border-bottom:1px solid var(--line)}
.pids td{padding:5px 4px;border-bottom:1px solid var(--line);vertical-align:top}
.pids td.r,.pids th.r{text-align:right}.pids .dec{color:var(--mut);margin-left:6px}
.pids .k-video{color:#60a5fa}.pids .k-audio{color:#c084fc}.pids .k-psi{color:var(--mut)}.pids .k-data{color:#fbbf24}
.pids .pcr{font-size:10px;border:1px solid var(--line);border-radius:4px;padding:0 4px;margin-left:5px;color:var(--mut)}
button.on{border-color:var(--tx)}
.toast{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);background:var(--tx);color:var(--bg);padding:9px 16px;border-radius:9px;font-weight:600;opacity:0;transition:.25s;pointer-events:none;z-index:99}
.toast.on{opacity:1}
</style></head><body>
<header>
  <div class="brand"><span class="dot"></span>nTs-Encoder</div>
  <div class="meters" id="meters"></div>
  <div class="actions">
    <button class="pri" onclick="editCh()">+ Canal</button>
    <button onclick="openDevices()">Dispozitive</button>
    <button onclick="openSettings()">Setări</button>
    <button onclick="fetch('/logout',{method:'POST'}).then(()=>location.reload())">Ieșire</button>
  </div>
</header>
<main><div class="grid" id="grid"></div></main>

<dialog id="dEdit"><div class="dh"><h2 id="eTitle">Canal</h2><button class="sm" onclick="showCmd()">Comanda FFmpeg</button></div>
<div class="tabs" id="tabs"></div>
<div class="db" id="eBody">
<div class="pane" data-tab="General"><div class="fg">
  <label class="f w2">Nume canal<input data-k="name"></label>
  <label class="f ck"><input type="checkbox" data-k="enabled"> Pornit (auto-start)</label>
</div></div>

<div class="pane" data-tab="Intrare"><div class="fg">
  <label class="f">Tip intrare<select data-k="input.type" onchange="inType()"><option value="url">Rețea (UDP/SRT/RTMP/HTTP/HLS)</option><option value="v4l2">Placă captură HDMI/SDI</option></select></label>
  <label class="f ck"><input type="checkbox" data-k="input.hwdec"> Decodare hardware (VAAPI)</label>
  <div class="w3 i-url fg" style="display:grid">
    <label class="f w3">URL sursă<input data-k="input.url" placeholder="udp://239.0.0.1:1234  ·  srt://ip:9000?mode=caller  ·  http://.../stream.ts"></label>
    <label class="f">Program (SID, opțional)<input data-k="input.program" placeholder="ex. 101"></label>
    <label class="f ck"><input type="checkbox" data-k="input.all_audio"> Toate pistele audio</label>
  </div>
  <div class="w3 i-v4l2 fg" style="display:grid">
    <label class="f">Dispozitiv video<select data-k="input.v4l2_dev" class="vdevs"></select></label>
    <label class="f">Format<select data-k="input.v4l2_format"><option>auto</option><option>mjpeg</option><option>yuyv422</option><option>nv12</option><option>uyvy422</option><option>p010</option></select></label>
    <label class="f">Rezoluție captură<input data-k="input.v4l2_size" placeholder="1920x1080"></label>
    <label class="f">FPS captură<input data-k="input.v4l2_fps" placeholder="gol = implicit"></label>
    <label class="f w2">Audio (ALSA)<select data-k="input.alsa_dev" class="adevs"></select></label>
  </div>
</div>
<p class="hint">Plăcile HDMI/SDI USB (Magewell, Elgato, AVerMedia, plăci UVC ieftine) și Magewell PCIe apar ca <code>/dev/videoX</code>. Pentru 1080p60 pe USB 2.0 alege <code>mjpeg</code>. Lista exactă de formate o găsești la „Dispozitive”.</p></div>

<div class="pane" data-tab="Video"><div class="fg">
  <label class="f">Codec<select data-k="video.codec"><option value="h264_vaapi">H.264 · VAAPI (GPU)</option><option value="hevc_vaapi">HEVC · VAAPI (GPU)</option><option value="h264_qsv">H.264 · QSV (GPU)</option><option value="hevc_qsv">HEVC · QSV (GPU)</option><option value="mpeg2video">MPEG-2 (CPU)</option><option value="libx264">H.264 x264 (CPU)</option><option value="copy">Copy (fără re-encodare)</option></select></label>
  <label class="f">Bitrate video (kbps)<input type="number" data-k="video.bitrate" data-t="n"></label>
  <label class="f">Lățime (0=original)<input type="number" data-k="video.width" data-t="n"></label>
  <label class="f">Înălțime (0=original)<input type="number" data-k="video.height" data-t="n"></label>
  <label class="f">FPS ieșire<select data-k="video.fps"><option value="">original</option><option>25</option><option>50</option><option>30000/1001</option><option>60000/1001</option><option>30</option><option>60</option></select></label>
  <label class="f">Deinterlace<select data-k="video.deint"><option value="auto">auto (doar interlaced)</option><option value="on">forțat</option><option value="off">oprit</option></select></label>
  <label class="f">GOP (cadre)<input type="number" data-k="video.gop" data-t="n"></label>
  <label class="f">B-frames<input type="number" data-k="video.bframes" data-t="n"></label>
  <label class="f">Profil H.264<select data-k="video.profile"><option value="high">high</option><option value="main">main</option><option value="constrained_baseline">baseline</option><option value="">implicit</option></select></label>
  <label class="f">Low-power (VDENC)<select data-k="video.low_power"><option value="auto">auto</option><option value="on">da</option><option value="off">nu</option></select></label>
</div>
<p class="hint">Intel N100/N200/N305 și Gen 11+ encodează adesea doar prin <b>low-power</b> — dacă primești „No usable encoding entrypoint”, pune <code>da</code>. GOP 50 la 25 fps = keyframe la 2 s (recomandat pentru HLS/IPTV).</p></div>

<div class="pane" data-tab="Audio"><div class="fg">
  <label class="f">Codec<select data-k="audio.codec"><option value="mp2">MPEG-1 Layer II (broadcast)</option><option value="aac">AAC</option><option value="ac3">AC-3</option><option value="copy">Copy</option><option value="none">Fără audio</option></select></label>
  <label class="f">Bitrate (kbps)<input type="number" data-k="audio.bitrate" data-t="n"></label>
  <label class="f">Canale<select data-k="audio.channels" data-t="n"><option value="2">stereo</option><option value="1">mono</option><option value="6">5.1</option></select></label>
  <label class="f">Sample rate<select data-k="audio.samplerate" data-t="n"><option>48000</option><option>44100</option></select></label>
</div><p class="hint">Pentru ieșirea RTMP audio-ul e convertit automat în AAC (dacă nu e deja AAC), deci poți păstra MP2 pe multicast.</p></div>

<div class="pane" data-tab="MPEG-TS"><div class="fg">
  <label class="f w2">Mod PID<select data-k="ts.pid_mode" onchange="pidMode()"><option value="manual">Manual (PID-urile de mai jos)</option><option value="source">Originale din sursă (SID, PMT, video, audio)</option></select></label>
  <label class="f" style="justify-content:flex-end"><button type="button" onclick="probeSrc()">Analizează sursa</button></label>
  <div class="w3" id="probeBox"></div>
  <label class="f">Service ID (program)<input type="number" data-k="ts.service_id" data-t="n"></label>
  <label class="f">Service name<input data-k="ts.service_name" placeholder="= numele canalului"></label>
  <label class="f">Provider<input data-k="ts.provider"></label>
  <label class="f">PMT PID<input type="number" data-k="ts.pmt_pid" data-t="n"></label>
  <label class="f">Video PID<input type="number" data-k="ts.video_pid" data-t="n"></label>
  <label class="f">Audio PID (prima)<input type="number" data-k="ts.audio_pid" data-t="n"></label>
  <label class="f w2">PID-uri audio pe piste (opțional)<input data-k="ts.audio_pids" placeholder="ex. 257, 258, 259  ·  gol = consecutive de la prima"></label>
  <label class="f">Muxrate CBR (kbps, 0=VBR)<input type="number" data-k="ts.muxrate" data-t="n"></label>
  <label class="f">PCR period (ms)<input type="number" data-k="ts.pcr_period" data-t="n"></label>
  <label class="f" style="justify-content:flex-end"><button type="button" onclick="autoMux()">Calculează muxrate</button></label>
</div><p class="hint">Muxrate CBR umple cu pachete NULL până la o rată fixă — cum cer modulatoarele DVB-C/T și headend-urile IPTV. Regula: video + audio + ~10% overhead.<br>
<b>Originale din sursă</b>: la fiecare pornire sursa e analizată și ieșirea primește exact SID-ul, PMT-ul și PID-urile video/audio ale programului ales (sau ale primului program cu video). Dacă analiza eșuează, se folosesc valorile manuale. PID-urile permise sunt 16–8190, fără duplicate. FFmpeg pune PCR pe PID-ul video.</p></div>

<div class="pane" data-tab="Ieșiri"><div class="fg">
  <label class="f w2">UDP multicast (una pe linie)<textarea data-k="out.udp" placeholder="udp://239.1.1.1:1234"></textarea></label>
  <label class="f">TTL<input type="number" data-k="out.ttl" data-t="n"></label>
  <label class="f">IP interfață (localaddr)<input data-k="out.localaddr" placeholder="ex. 192.168.10.5"></label>
  <label class="f w2">SRT (una pe linie)<textarea data-k="out.srt" placeholder="srt://server:9000?mode=caller&latency=400000&streamid=..."></textarea></label>
  <label class="f w2">RTMP (una pe linie)<textarea data-k="out.rtmp" placeholder="rtmp://netstreaming.eu/live/cheie"></textarea></label>
  <label class="f ck"><input type="checkbox" data-k="out.httpts"> HTTP-TS (/ts/ID.ts)</label>
  <label class="f ck"><input type="checkbox" data-k="out.hls"> HLS (/hls/ID/index.m3u8)</label>
  <label class="f">Segment HLS (s)<input type="number" data-k="out.hls_time" data-t="n"></label>
  <label class="f">Segmente în playlist<input type="number" data-k="out.hls_list" data-t="n"></label>
</div><p class="hint">Encoderul scrie doar UDP. SRT, RTMP și HLS rulează ca procese separate (remux fără re-encodare) cu reconectare automată — dacă serverul de destinație cade, multicastul merge mai departe. RTMP nu acceptă HEVC: folosește H.264 dacă trimiți pe RTMP.</p></div>
</div>
<div class="df"><button class="red" id="bDel" onclick="delCh()">Șterge</button><span style="flex:1"></span><button onclick="dEdit.close()">Anulează</button><button class="pri" onclick="saveCh()">Salvează & aplică</button></div></dialog>

<dialog id="dLog"><div class="dh"><h2 id="lTitle">Jurnal</h2><button class="sm" onclick="dLog.close()">Închide</button></div><div class="db"><pre class="log" id="logBox"></pre></div></dialog>
<dialog id="dPrev"><div class="dh"><h2 id="pTitle">Previzualizare</h2><button class="sm" onclick="closePrev()">Închide</button></div><div class="db"><video id="vid" controls muted autoplay playsinline></video><p class="hint" id="pLinks"></p></div></dialog>
<dialog id="dDev"><div class="dh"><h2>Dispozitive</h2><button class="sm" onclick="dDev.close()">Închide</button></div><div class="db" id="devBody">Se încarcă…</div></dialog>
<dialog id="dSet"><div class="dh"><h2>Setări</h2><button class="sm" onclick="dSet.close()">Închide</button></div><div class="db"><div class="fg">
  <label class="f">Utilizator<input id="sUser"></label>
  <label class="f">Port panou<input id="sPort" type="number"></label>
  <label class="f">Dispozitiv VAAPI<input id="sDev"></label>
  <label class="f w2">Token streamuri (gol = public)<input id="sTok" placeholder="?token=... pentru /ts și /hls"></label>
  <label class="f">Parolă veche<input id="sOld" type="password"></label>
  <label class="f">Parolă nouă<input id="sNew" type="password"></label>
</div><p class="hint">Portul se aplică după <code>systemctl restart ntsenc</code>.</p></div>
<div class="df"><button class="pri" onclick="saveSet()">Salvează</button></div></dialog>
<div class="toast" id="toast"></div>

<script>
const $=s=>document.querySelector(s),$$=s=>[...document.querySelectorAll(s)];
let CH=null,STATE={channels:[]},CFG={},DEV=null,hls=null;
const toast=t=>{const e=$('#toast');e.textContent=t;e.classList.add('on');setTimeout(()=>e.classList.remove('on'),2200)};
async function api(u,b){const r=await fetch(u,b===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)});if(r.status==401)location.reload();const j=await r.json();if(!r.ok)throw new Error(j.error||r.status);return j}
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const dur=s=>{if(!s)return'—';const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return d?`${d}z ${h}h`:h?`${h}h ${m}m`:`${m}m ${s%60}s`};
const tok=()=>CFG.stream_token?`?token=${encodeURIComponent(CFG.stream_token)}`:'';

async function refresh(){
  try{STATE=await api('/api/state')}catch(e){return}
  const s=STATE.sys||{};let m=`<div class="m">CPU<b>${s.cpu??'—'}%</b></div><div class="m">RAM<b>${s.mem??'—'}%</b></div>`;
  if(s.temp)m+=`<div class="m">Temp<b>${s.temp}°C</b></div>`;
  if(s.gpu_mhz!=null)m+=`<div class="m">GPU<b>${s.gpu_mhz}/${s.gpu_max} MHz</b></div>`;
  if(s.load)m+=`<div class="m">Load<b>${s.load.join(' ')}</b></div>`;
  for(const[n,v]of Object.entries(s.net||{}))if(v.tx>0.05||v.rx>0.05)m+=`<div class="m">${esc(n)}<b>↑${v.tx} ↓${v.rx} Mb</b></div>`;
  $('#meters').innerHTML=m;
  const g=$('#grid');
  if(!STATE.channels.length){g.innerHTML='<div class="empty" style="grid-column:1/-1">Niciun canal. Apasă <b>+ Canal</b> ca să adaugi primul encoder.</div>';return}
  g.innerHTML=STATE.channels.map(c=>{const st=c.st,sm=c.summary;
    const led={'rulează':'run','pornește':'start','eroare':'err'}[st.state]||'';
    const br=st.bitrate;
    return `<div class="card"><div class="top"><span class="led ${led}"></span><h3>${esc(c.name)}</h3><span class="tag">SID ${st.pids?st.pids.sid:sm.sid}</span><span class="tag">${esc(st.state)}</span></div>
    <div class="stats"><div><span>FPS</span><b>${st.fps||'—'}</b></div><div><span>Bitrate</span><b>${br||'—'}</b></div><div><span>Viteză</span><b>${st.speed||'—'}</b></div><div><span>Uptime</span><b>${dur(st.running_for)}</b></div></div>
    <div class="info"><div>Sursă: <code>${esc(sm.src)}</code></div><div>Video: <code>${esc(sm.video)}</code> · Audio: <code>${esc(sm.audio)}</code>${sm.muxrate?` · CBR <code>${sm.muxrate}k</code>`:''}</div>
    <div>Ieșiri: <code>${esc(sm.outs.filter(x=>x.startsWith('udp')).join('  ·  ')||'—')}</code>${sm.httpts?' · <code>HTTP-TS</code>':''}</div>
    ${(st.outs||[]).map(o=>`<div><span class="led ${o.state=='activ'?'run':o.state=='eroare'?'err':''}" style="display:inline-block;width:7px;height:7px;margin-right:6px"></span>${o.kind}: <code>${esc(o.target||'/hls/'+c.id+'/index.m3u8')}</code>${o.restarts?` · reconectări ${o.restarts}`:''}${o.state=='eroare'&&o.err?`<div class="errbox" style="margin:4px 0 0">${esc(o.err)}</div>`:''}</div>`).join('')}
    ${st.pids?`<div>PID: <code>SID ${st.pids.sid} · PMT ${st.pids.pmt} · V ${st.pids.vpid}${(st.pids.show||[]).length?' · A '+st.pids.show.join(','):''}</code>${st.pids.mode=='sursă'?' <span class="tag">din sursă</span>':''}</div>`:''}
    <div>Reporniri: <code>${st.restarts||0}</code> · Drop/Dup: <code>${st.drop||0}/${st.dup||0}</code>${st.clients&&st.clients.length?` · Clienți HTTP: <code>${st.clients.map(x=>x.ip).join(', ')}</code>`:''}</div></div>
    ${st.state=='eroare'&&st.last_err?`<div class="errbox">${esc(st.last_err)}</div>`:''}
    ${OPEN.has(c.id)?`<div class="pids" id="pids-${c.id}">${pidTable(PIDS[c.id])}</div>`:''}
    <div class="bot">${c.enabled?`<button class="sm red" onclick="act('${c.id}','stop')">■ Stop</button><button class="sm" onclick="act('${c.id}','restart')">↻ Restart</button>`:`<button class="sm grn" onclick="act('${c.id}','start')">▶ Start</button>`}
    <button class="sm" onclick="editCh('${c.id}')">Editează</button><button class="sm" onclick="showLog('${c.id}','${esc(c.name)}')">Jurnal</button><button class="sm ${OPEN.has(c.id)?'on':''}" onclick="togglePids('${c.id}')">PID-uri</button>
    ${sm.hls||sm.httpts?`<button class="sm" onclick="preview('${c.id}','${esc(c.name)}',${sm.hls},${sm.httpts})">Previzualizare</button>`:''}</div></div>`}).join('');
}
const OPEN=new Set(),PIDS={};
const fmtR=b=>b>=1e6?(b/1e6).toFixed(2)+' Mb/s':Math.round(b/1e3)+' kb/s';
function pidTable(d){if(!d)return'<h5>PID-uri ieșire</h5><p class="hint" style="margin:0 0 6px">Se încarcă…</p>';
  if(!d.rows.length)return'<h5>PID-uri ieșire</h5><p class="hint" style="margin:0 0 6px">Canalul nu trimite date.</p>';
  const pg=d.programs.map(p=>`${esc(p.name)}${p.provider?' · '+esc(p.provider):''} <span style="opacity:.6">(SID ${p.sid})</span>`).join(' / ');
  return `<h5>PID-uri ieșire${pg?' · '+pg:''}</h5><table><tr><th>PID</th><th>Tip</th><th>Limbă</th><th class="r">Bitrate</th></tr>`+
   d.rows.map(r=>`<tr><td>0x${r.pid.toString(16).toUpperCase().padStart(4,'0')}<span class="dec">${r.pid}</span></td><td class="k-${r.kind}">${esc(r.type)}${r.pcr?'<span class="pcr">PCR</span>':''}</td><td>${esc(r.lang)}</td><td class="r">${fmtR(r.rate)}</td></tr>`).join('')+
   `<tr><td colspan="3" style="color:var(--mut)">Total</td><td class="r"><b>${fmtR(d.total)}</b></td></tr></table>`}
function togglePids(id){OPEN.has(id)?OPEN.delete(id):OPEN.add(id);refresh().then(loadPids)}
async function loadPids(){for(const id of OPEN){try{PIDS[id]=await api(`/api/channel/${id}/pids`);const e=$('#pids-'+id);if(e)e.innerHTML=pidTable(PIDS[id])}catch(e){}}}
async function act(id,a){await api(`/api/channel/${id}/${a}`,{});toast({start:'Pornit',stop:'Oprit',restart:'Repornire…'}[a]);setTimeout(refresh,600)}

const getK=(o,k)=>k.split('.').reduce((a,b)=>a?.[b],o);
const setK=(o,k,v)=>{const p=k.split('.'),l=p.pop();p.reduce((a,b)=>a[b]??={},o)[l]=v};
async function loadDev(){if(!DEV)DEV=await api('/api/devices');
  $$('.vdevs').forEach(s=>s.innerHTML=DEV.video.map(v=>`<option value="${v.dev}">${esc(v.dev)} — ${esc(v.name)}</option>`).join('')||'<option value="/dev/video0">/dev/video0</option>');
  $$('.adevs').forEach(s=>s.innerHTML='<option value="">— fără audio —</option>'+DEV.audio.map(a=>`<option value="${a.dev}">${esc(a.dev)} — ${esc(a.name)}</option>`).join(''))}
function inType(){const t=$('[data-k="input.type"]').value;$('.i-url').style.display=t=='url'?'grid':'none';$('.i-v4l2').style.display=t=='v4l2'?'grid':'none'}
function tab(n){$$('.tabs button').forEach(b=>b.classList.toggle('on',b.textContent==n));$$('.pane').forEach(p=>p.classList.toggle('on',p.dataset.tab==n))}
$('#tabs').innerHTML=$$('.pane').map(p=>`<button onclick="tab('${p.dataset.tab}')">${p.dataset.tab}</button>`).join('');
async function editCh(id){
  CFG=await api('/api/config');await loadDev();
  CH=id?structuredClone(CFG.channels.find(c=>c.id==id)):await api('/api/new');
  if(!id){CH.name='Canal '+(CFG.channels.length+1);CH.ts.service_id=CFG.channels.length+1;CH.enabled=true}
  $('#eTitle').textContent=id?'Editează: '+CH.name:'Canal nou';$('#bDel').style.display=id?'':'none';
  for(const el of $$('[data-k]')){const v=getK(CH,el.dataset.k);
    if(el.type=='checkbox')el.checked=!!v;else{if(el.tagName=='SELECT'&&v!=null&&![...el.options].some(o=>o.value==String(v)))el.add(new Option(v,v));el.value=v??''}}
  $('#probeBox').innerHTML='';inType();pidMode();tab('General');dEdit.showModal()}
function collect(){for(const el of $$('[data-k]')){let v=el.type=='checkbox'?el.checked:el.value;if(el.dataset.t=='n')v=Number(v)||0;setK(CH,el.dataset.k,v)}return CH}
function pidMode(){const src=$('[data-k="ts.pid_mode"]').value=='source';
  ['ts.service_id','ts.pmt_pid','ts.video_pid','ts.audio_pid','ts.audio_pids'].forEach(k=>{const e=$(`[data-k="${k}"]`);e.disabled=src;e.style.opacity=src?.45:1})}
async function probeSrc(){collect();const b=$('#probeBox');
  if(CH.input.type!='url'){b.innerHTML='<p class="hint">Analiza PID merge doar pentru surse de rețea.</p>';return}
  b.innerHTML='<p class="hint">Analizez <code>'+esc(CH.input.url)+'</code>…</p>';
  const j=await api('/api/probe',{input:CH.input,id:CH.id}).catch(e=>({error:e.message}));
  if(j.error){b.innerHTML='<div class="errbox" style="margin:0">'+esc(j.error)+'</div>';return}
  window.PROBE=j;
  b.innerHTML=(j.note?`<p class="hint" style="margin:0 0 8px">${esc(j.note)}</p>`:'')+j.programs.map((p,n)=>`<div class="dev"><div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap"><b>Program ${p.program_id}</b>${p.name?` — ${esc(p.name)}`:''}${p.provider?` <span class="tag">${esc(p.provider)}</span>`:''}
    <span class="tag">PMT ${p.pmt_pid}</span><span class="tag">PCR ${p.pcr_pid}</span><span style="flex:1"></span><button type="button" class="sm" onclick="usePids(${n})">Folosește aceste PID-uri</button></div>
    <table style="width:100%;margin-top:8px;font:12px var(--mono);border-collapse:collapse">${p.streams.map(s=>`<tr style="border-top:1px solid var(--line)"><td style="padding:4px 0;width:70px">${s.pid} <span style="color:var(--mut)">0x${s.pid.toString(16)}</span></td><td style="width:60px;color:var(--mut)">${s.type}</td><td>${esc(s.codec)}</td><td style="width:50px">${esc(s.lang)}</td></tr>`).join('')}</table></div>`).join('')}
function usePids(n){const p=PROBE.programs[n],v=p.streams.find(s=>s.type=='video'),a=p.streams.filter(s=>s.type=='audio');
  const set=(k,val)=>{const e=$(`[data-k="${k}"]`);if(e&&val!=null)e.value=val};
  set('ts.pid_mode','manual');pidMode();
  if(p.program_id)set('ts.service_id',p.program_id);if(p.pmt_pid)set('ts.pmt_pid',p.pmt_pid);
  if(v)set('ts.video_pid',v.pid);if(a.length){set('ts.audio_pid',a[0].pid);set('ts.audio_pids',a.map(s=>s.pid).join(', '))}
  if(p.name&&!$('[data-k="ts.service_name"]').value)set('ts.service_name',p.name);
  if(PROBE.programs.length>1&&p.program_id)set('input.program',p.program_id);
  toast('PID-uri copiate în câmpuri')}
function autoMux(){collect();const a=CH.audio.codec=='none'?0:CH.audio.bitrate*(CH.input.all_audio?2:1);$('[data-k="ts.muxrate"]').value=Math.ceil(((CH.video.bitrate+a)*1.1+150)/100)*100}
async function saveCh(){try{await api('/api/channel',collect());dEdit.close();toast('Salvat — se aplică');DEV=null;setTimeout(refresh,500)}catch(e){alert(e.message)}}
async function delCh(){if(!confirm('Ștergi canalul '+CH.name+'?'))return;await api(`/api/channel/${CH.id}/delete`,{});dEdit.close();refresh()}
async function showCmd(){const j=await api('/api/preview_cmd',collect());clearInterval(logT);
  $('#lTitle').textContent='Comanda FFmpeg (previzualizare, nesalvat)';
  $('#logBox').textContent=(j.pid_error?'!! '+j.pid_error+'\n\n':'')+(CH.ts.pid_mode=='source'?'# PID-urile din sursă se aplică la pornire (aici apar cele manuale)\n\n':'')+j.cmd;dLog.showModal()}
let logT=null;async function showLog(id,n){$('#lTitle').textContent='Jurnal: '+n;const f=async()=>{const j=await api(`/api/channel/${id}/log`);const b=$('#logBox');const end=b.scrollHeight-b.scrollTop-b.clientHeight<40;b.textContent=j.log.join('\n')||'(gol)';if(end)b.scrollTop=1e9};
  await f();dLog.showModal();clearInterval(logT);logT=setInterval(()=>dLog.open?f():clearInterval(logT),2000)}
async function preview(id,n,isH,isT){CFG=await api('/api/config');$('#pTitle').textContent=n;const v=$('#vid');const base=location.origin;
  const hu=`${base}/hls/${id}/index.m3u8${tok()}`,tu=`${base}/ts/${id}.ts${tok()}`;
  $('#pLinks').innerHTML=(isH?`HLS: <code>${esc(hu)}</code><br>`:'')+(isT?`HTTP-TS: <code>${esc(tu)}</code> (VLC)`:'')+(isH?'':'<br>Previzualizarea în browser cere HLS activ (audio-ul HLS e convertit automat în AAC).');
  if(isH){if(window.Hls&&Hls.isSupported()){hls=new Hls({liveSyncDurationCount:2});hls.loadSource(hu);hls.attachMedia(v)}else v.src=hu}
  dPrev.showModal()}
function closePrev(){if(hls){hls.destroy();hls=null}$('#vid').removeAttribute('src');dPrev.close()}
dPrev.addEventListener('close',()=>{if(hls){hls.destroy();hls=null}});
async function openDevices(){dDev.showModal();DEV=null;$('#devBody').textContent='Se încarcă…';await loadDev();
  let h=`<h4>FFmpeg</h4><div class="dev"><code>${esc(DEV.ffmpeg)}</code> · SRT: <b>${DEV.srt?'da':'NU (lipsește libsrt)'}</b></div><h4>GPU (VAAPI)</h4>`;
  h+=DEV.gpu.map(g=>`<details class="dev"><summary><b>${esc(g.dev)}</b> — ${esc(g.driver)}<br><small>Encodare: ${esc(g.enc.join(', ')||'niciun profil găsit')}</small></summary><pre>${esc(g.raw)}</pre></details>`).join('')||'<div class="dev">Niciun /dev/dri/renderD* — verifică driverul Intel.</div>';
  h+='<h4>Captură video</h4>'+(DEV.video.map(v=>`<details class="dev"><summary><b>${esc(v.dev)}</b> — ${esc(v.name)}</summary><pre>${esc(v.formats)}</pre></details>`).join('')||'<div class="dev">Nicio placă de captură detectată.</div>');
  h+='<h4>Captură audio (ALSA)</h4>'+(DEV.audio.map(a=>`<div class="dev"><code>${esc(a.dev)}</code> — ${esc(a.name)}</div>`).join('')||'<div class="dev">Niciun dispozitiv.</div>');
  $('#devBody').innerHTML=h}
async function openSettings(){CFG=await api('/api/config');sUser.value=CFG.user;sPort.value=CFG.port;sDev.value=CFG.vaapi_device;sTok.value=CFG.stream_token||'';sOld.value=sNew.value='';dSet.showModal()}
async function saveSet(){try{await api('/api/settings',{user:sUser.value,port:+sPort.value,vaapi_device:sDev.value,stream_token:sTok.value,oldpass:sOld.value,newpass:sNew.value});dSet.close();toast('Setări salvate')}catch(e){alert(e.message)}}
api('/api/config').then(c=>CFG=c);refresh();setInterval(()=>refresh().then(loadPids),2000);
</script></body></html>
NTSENC_FILE_EOF
cat > "$APP/login.html" <<'NTSENC_FILE_EOF'
<!doctype html><html lang="ro"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>nTs-Encoder · Autentificare</title>
<style>
:root{--bg:#0b0e13;--panel:#131821;--line:#232b38;--tx:#e6ebf2;--mut:#7d8898;--acc:#ff3b30}
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle at 30% 20%,#141b27,#0b0e13 60%);color:var(--tx);font:15px/1.4 system-ui,Segoe UI,Roboto,sans-serif}
form{width:min(340px,92vw);background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:28px}
.logo{display:flex;align-items:center;gap:10px;font-weight:700;font-size:20px;margin-bottom:22px}
.dot{width:12px;height:12px;border-radius:50%;background:var(--acc);box-shadow:0 0 12px var(--acc)}
.logo small{display:block;font-weight:400;color:var(--mut);font-size:12px;letter-spacing:.08em;text-transform:uppercase}
label{display:block;font-size:12px;color:var(--mut);margin:12px 0 5px;text-transform:uppercase;letter-spacing:.06em}
input{width:100%;padding:10px 12px;border-radius:8px;border:1px solid var(--line);background:#0d1119;color:var(--tx);font-size:15px}
input:focus{outline:none;border-color:#3b82f6}
button{margin-top:20px;width:100%;padding:11px;border:0;border-radius:8px;background:#e6ebf2;color:#0b0e13;font-weight:700;font-size:15px;cursor:pointer}
#e{color:#ff6b62;font-size:13px;margin-top:12px;min-height:18px}
</style></head><body>
<form id="f"><div class="logo"><span class="dot"></span><div>nTs-Encoder<small>Multicast broadcast encoder</small></div></div>
<label>Utilizator</label><input name="user" value="admin" autocomplete="username">
<label>Parolă</label><input name="pass" type="password" autocomplete="current-password" autofocus>
<button>Intră</button><div id="e"></div></form>
<script>
f.onsubmit=async ev=>{ev.preventDefault();e.textContent='';
const r=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({user:f.user.value,pass:f.pass.value})});
if(r.ok)location.reload();else e.textContent=(await r.json()).error||'Eroare'};
</script></body></html>
NTSENC_FILE_EOF
curl -fsSL --max-time 20 -o "$APP/hls.min.js" https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.13/hls.min.js \
  || warn "hls.js nu s-a putut descărca (previzualizarea va folosi CDN-ul)"
chmod 755 "$APP/ntsenc.py"

# ---------- 3. rețea: buffere UDP mari + rută multicast
say "Optimizez bufferele UDP pentru multicast"
cat > /etc/sysctl.d/90-ntsenc.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=4194304
net.core.wmem_default=4194304
net.ipv4.igmp_max_memberships=256
EOF
sysctl -q --system >/dev/null 2>&1 || true

DEF_IF=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)
OLD_IF=$(grep -s '^MCAST_IF=' "$CONF/env" | cut -d= -f2 || true)
MCAST_IF="${MCAST_IF:-${OLD_IF:-${DEF_IF:-}}}"      # 1) dat de tine  2) cel salvat  3) default route
echo "MCAST_IF=$MCAST_IF" > "$CONF/env"

# ---------- 4. port inițial (doar la prima instalare)
if [ ! -f "$CONF/config.json" ]; then
  python3 - "$CONF/config.json" "$PORT" <<'EOF'
import json, secrets, hashlib, sys
salt = secrets.token_hex(8)
cfg = {"user": "admin", "salt": salt, "pass": hashlib.sha256((salt + "admin").encode()).hexdigest(),
       "port": int(sys.argv[2]), "vaapi_device": "/dev/dri/renderD128", "stream_token": "", "channels": []}
json.dump(cfg, open(sys.argv[1], "w"), indent=2)
EOF
  chmod 600 "$CONF/config.json"
fi
# alege automat primul renderD (pe unele mini PC-uri iGPU-ul e renderD129)
RD=$(ls /dev/dri/renderD* 2>/dev/null | head -1 || true)
if [ -n "$RD" ]; then
  python3 - "$CONF/config.json" "$RD" <<'EOF'
import json, sys, os
p, rd = sys.argv[1], sys.argv[2]; c = json.load(open(p))
if not os.path.exists(c.get("vaapi_device", "")): c["vaapi_device"] = rd; json.dump(c, open(p, "w"), indent=2)
EOF
fi

# ---------- 5. serviciu systemd
say "Creez serviciul systemd"
cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=nTs-Encoder (multicast broadcast encoder)
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$CONF/env
Environment=PYTHONUNBUFFERED=1
ExecStartPre=-/bin/sh -c '[ -n "\$MCAST_IF" ] && ip route replace 224.0.0.0/4 dev "\$MCAST_IF" || true'
ExecStart=/usr/bin/python3 $APP/ntsenc.py
Restart=always
RestartSec=3
Nice=-5
LimitNOFILE=65536
KillMode=control-group
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable $SVC >/dev/null 2>&1
systemctl restart $SVC

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  P=$(python3 -c "import json;print(json.load(open('$CONF/config.json'))['port'])"); ufw allow "$P"/tcp >/dev/null; say "UFW: port $P deschis"
fi

# ---------- 6. raport
sleep 2
P=$(python3 -c "import json;print(json.load(open('$CONF/config.json'))['port'])")
IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
echo; echo -e "${G}=================== nTs-Encoder instalat ===================${N}"
echo    "  Panou:        http://${IP:-IP}:$P      (admin / admin — schimbă din Setări)"
echo    "  Serviciu:     systemctl status $SVC   ·   journalctl -u $SVC -f"
echo    "  Multicast pe: ${MCAST_IF:-(nicio interfață — setează MCAST_IF=...)}"
echo    "  FFmpeg:       $(ffmpeg -hide_banner -version 2>/dev/null | head -1 | cut -d' ' -f1-3)"
if [ -n "$RD" ] && command -v vainfo >/dev/null; then
  VI=$(vainfo --display drm --device "$RD" 2>/dev/null || true)
  echo  "  GPU:          $RD — $(echo "$VI" | grep -m1 'Driver version' | sed 's/.*Driver version: //')"
  ENC=$(echo "$VI" | grep -E 'VAEntrypointEncSlice' | grep -oE 'VAProfile(H264High|HEVCMain|MPEG2Main|AV1Profile0)\s*:\s*VAEntrypointEncSlice(LP)?' | sed -E 's/VAProfile//; s/[[:space:]]*:[[:space:]]*VAEntrypointEncSlice/ /' | paste -sd, - || true)
  echo  "  Encodare HW:  ${ENC:-NU a fost găsită — verifică driverul}"
  echo "$VI" | grep -q 'EncSliceLP' && ! echo "$VI" | grep -qE 'EncSlice$' && echo -e "  ${Y}Notă:${N} GPU-ul are doar encoder low-power → în canal pune Low-power = da"
else
  warn "Nu am găsit /dev/dri/renderD* — iGPU-ul Intel nu e activ (BIOS / driver i915)."
fi
V=$(ls /dev/video* 2>/dev/null | tr '\n' ' ' || true); echo "  Captură:      ${V:-nicio placă detectată}"
systemctl is-active --quiet $SVC && echo -e "  Stare:        ${G}rulează${N}" || { echo -e "  Stare:        ${R}eroare${N}"; journalctl -u $SVC -n 20 --no-pager; }
echo -e "${G}=============================================================${N}"
