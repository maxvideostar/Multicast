# nTs-Encoder — encoder multicast broadcast pentru mini PC (Intel QSV/VAAPI)

Encoder live în stilul celor din televiziuni, gândit pentru un mini PC cu iGPU Intel (N100/N200/N305, Core gen 8+). Rulează pe Ubuntu 22.04/24.04 sau Debian 12 și are panou web.

## Instalare

```bash
curl -fsSL https://raw.githubusercontent.com/maxvideostar/multicast/main/install-ntsenc.sh -o install-ntsenc.sh
sudo bash install-ntsenc.sh
# opțional: sudo PORT=8090 MCAST_IF=enp1s0 bash install-ntsenc.sh
```

Panoul: `http://IP:8090` — user/parolă implicite `admin / admin` (schimbă din **Setări**).

Dezinstalare (păstrează configurația din `/etc/ntsenc`):

```bash
sudo bash install-ntsenc.sh uninstall
```

## Ce face

| | |
|---|---|
| **Intrări** | Plăci HDMI/SDI (V4L2 + audio ALSA) · UDP/RTP multicast · SRT · RTMP · HTTP-TS · HLS · selecție program (SID) · toate pistele audio |
| **Video** | H.264 / HEVC pe GPU (VAAPI sau QSV), decodare HW, deinterlace + scalare pe GPU · MPEG-2 / x264 pe CPU · copy |
| **Audio** | MP2 (broadcast) · AAC · AC-3 · copy |
| **MPEG-TS** | Muxrate CBR cu pachete NULL · Service ID · service name / provider · PID PMT / video / audio · PCR period |
| **Ieșiri** | UDP multicast (mai multe, TTL, interfață) · SRT · RTMP · HLS · HTTP-TS · token opțional pe `/ts` și `/hls` |
| **Monitorizare** | FPS, bitrate real de ieșire, viteză, uptime, reporniri, drop/dup, jurnal live, comanda FFmpeg, previzualizare HLS, CPU/RAM/temp/GPU/rețea |

## Arhitectură

```
sursă ──► ffmpeg (decodare/encodare GPU) ──► UDP multicast (CBR)
                                         └──► loopback 127.0.0.1 ──► nTs relay ─┬─► HTTP-TS clienți
                                                                                ├─► ffmpeg ► SRT
                                                                                ├─► ffmpeg ► RTMP (audio → AAC)
                                                                                └─► ffmpeg ► HLS  (audio → AAC)
```

Encoderul scrie **doar UDP**. SRT, RTMP și HLS rulează ca procese separate, fără re-encodare, cu reconectare automată. Dacă un server de destinație cade, multicastul nu e afectat — muxer-ul `tee` din FFmpeg bloca tot encoderul în acest caz.

Watchdog: dacă un canal nu mai produce cadre timp de 30 s, e repornit automat.

## Note GPU

- Intel N100/N200/N305 și Gen 11+ au adesea doar encoder **low-power** (VDENC). Dacă apare „No usable encoding entrypoint”, setează **Low-power = da** în tab-ul Video. Instalatorul îți spune la final ce profile de encodare are GPU-ul.
- Dacă iGPU-ul apare ca `renderD129`, schimbă dispozitivul VAAPI din **Setări**.
- RTMP nu acceptă HEVC — folosește H.264 dacă trimiți pe RTMP.

## Multicast

Instalatorul adaugă ruta `224.0.0.0/4` pe interfața din `MCAST_IF` (implicit cea cu default route) la fiecare pornire a serviciului și mărește bufferele UDP. Pe fiecare ieșire poți forța interfața cu câmpul **IP interfață (localaddr)**.

## Fișiere

| Cale | Rol |
|---|---|
| `/opt/ntsenc/` | aplicația |
| `/etc/ntsenc/config.json` | canale + setări |
| `/etc/ntsenc/env` | `MCAST_IF` |
| `/var/lib/ntsenc/hls/` | segmente HLS |

```bash
systemctl status ntsenc
journalctl -u ntsenc -f
```

## Dezvoltare

Sursele sunt în `src/` (backend Python fără dependențe externe + panou HTML). Instalatorul all-in-one se regenerează cu:

```bash
./build.sh
```

Rulare locală fără instalare:

```bash
NTSENC_CONF=./t/conf NTSENC_DATA=./t/data python3 src/ntsenc.py
```
