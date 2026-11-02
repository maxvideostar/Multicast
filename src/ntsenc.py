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
