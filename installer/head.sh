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
