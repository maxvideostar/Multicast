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
