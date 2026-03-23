#!/bin/bash
# =============================================================================
#  kiosk-setup.sh — Wall Panel Kiosk for Raspberry Pi
# =============================================================================
#  Supports:
#    Hardware : Raspberry Pi 4, Raspberry Pi 5
#    OS       : Raspberry Pi OS Bookworm (Debian 12) — X11 + LXDE
#               Raspberry Pi OS Trixie  (Debian 13) — Wayland + labwc
#
#  FULL INSTALL:
#    sudo bash kiosk-setup.sh https://your-dashboard.com
#
#  UPDATE URL ONLY (safe to run anytime, no reinstall):
#    sudo bash kiosk-setup.sh --update-url https://your-new-url.com
#
#  Features:
#    - Auto-detects OS (Bookworm/Trixie) and Pi model (4/5)
#    - Full kiosk mode — no address bar, no UI chrome, no escape
#    - Dark mode forced at OS + browser level
#    - No desktop flash — black background painted before Chromium loads
#    - Chromium crash watchdog — auto-restarts on unexpected exit
#    - Network-aware boot — waits for URL to be reachable before launching
#    - Configurable shutdown time + RTC hardware wake alarm
#    - Hardware watchdog — Pi reboots if kernel hangs > 15s
#    - Touch zoom, overscroll, infobars all disabled
#    - Idempotent URL update mode (--update-url)
#    - All activity logged to /var/log/kiosk.log
# =============================================================================

set -e

# =============================================================================
#  CONFIG — edit these before running
# =============================================================================

# URL to display (also accepted as first argument)
KIOSK_URL="${1:-https://example.com}"

# Shutdown time (24h)
SHUTDOWN_HOUR=0
SHUTDOWN_MINUTE=0

# RTC wake time (24h)
WAKE_HOUR=6
WAKE_MINUTE=0

# Display rotation: normal | 90 | 180 | 270
DISPLAY_TRANSFORM="normal"

# Wayland output name — run `wlr-randr` after boot to find yours
# Common: HDMI-A-1, HDMI-A-2, DSI-1 (Pi touchscreen)
# Only used on Trixie/Wayland
DISPLAY_OUTPUT="HDMI-A-1"

# Auto-reload interval in seconds (0 = disabled)
AUTO_RELOAD_SECONDS=0

# =============================================================================
#  Internal — do not edit below this line
# =============================================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
hr()   { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

KIOSK_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
KIOSK_HOME="/home/$KIOSK_USER"
INSTALL_MARKER="/etc/kiosk-installed"

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Must be run as root.  Try: sudo bash $0 [--update-url] <URL>"
command -v raspi-config &>/dev/null || err "This doesn't look like a Raspberry Pi. Aborting."

# ── OS detection ──────────────────────────────────────────────────────────────
OS_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')

case "$OS_CODENAME" in
    trixie)
        IS_TRIXIE=true
        IS_BOOKWORM=false
        COMPOSITOR="Wayland + labwc"
        CHROMIUM_PKG="chromium"
        ;;
    bookworm)
        IS_TRIXIE=false
        IS_BOOKWORM=true
        COMPOSITOR="X11 + LXDE"
        CHROMIUM_PKG="chromium-browser"
        ;;
    *)
        err "Unsupported OS: $OS_CODENAME. This script supports Bookworm and Trixie only."
        ;;
esac

# ── Pi model detection ────────────────────────────────────────────────────────
PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")
if echo "$PI_MODEL" | grep -q "Raspberry Pi 5"; then
    PI_GEN=5
    HAS_BUILTIN_RTC=true
elif echo "$PI_MODEL" | grep -q "Raspberry Pi 4"; then
    PI_GEN=4
    HAS_BUILTIN_RTC=false
else
    PI_GEN="Unknown"
    HAS_BUILTIN_RTC=false
    warn "Could not detect Pi model — assuming Pi 4 behaviour."
fi

# ── Autostart path differs by compositor ─────────────────────────────────────
if $IS_TRIXIE; then
    AUTOSTART_DIR="$KIOSK_HOME/.config/labwc"
    AUTOSTART_FILE="$AUTOSTART_DIR/autostart"
else
    AUTOSTART_DIR="$KIOSK_HOME/.config/lxsession/LXDE-pi"
    AUTOSTART_FILE="$AUTOSTART_DIR/autostart"
fi

# =============================================================================
#  URL-only update path — fast, no reinstall
# =============================================================================
if [[ "$1" == "--update-url" ]]; then
    UPDATE_URL="${2:-}"
    [[ -z "$UPDATE_URL" ]] && err "No URL provided.  Usage: sudo bash $0 --update-url https://new-url.com"
    [[ ! -f "$INSTALL_MARKER" ]] && err "Kiosk not yet installed. Run without --update-url first."

    hr
    echo -e "${CYAN}  Kiosk URL Update${NC}"
    hr
    info "Updating URL → $UPDATE_URL"

    [[ ! -f "$AUTOSTART_FILE" ]] && err "Autostart file not found at $AUTOSTART_FILE"

    # The sentinel line is written the same way for both compositors
    sed -i "s|^  KIOSK_URL_VALUE=.*|  KIOSK_URL_VALUE=$UPDATE_URL|" "$AUTOSTART_FILE"
    sed -i "s|^URL=.*|URL=$UPDATE_URL|" "$INSTALL_MARKER"

    log "URL updated in $AUTOSTART_FILE"
    echo ""
    warn "Reboot to apply:  sudo reboot"
    echo "  — or kill Chromium and it will relaunch automatically:"
    echo "    sudo pkill chromium"
    echo ""
    exit 0
fi

# =============================================================================
#  Full install
# =============================================================================
[[ -z "$1" ]] && warn "No URL supplied — defaulting to https://example.com"

hr
echo -e "${CYAN}  Raspberry Pi Wall Panel Kiosk Setup${NC}"
hr
info "Pi model    : $PI_MODEL"
info "OS          : $OS_CODENAME (Debian $(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"'))"
info "Compositor  : $COMPOSITOR"
info "Kiosk user  : $KIOSK_USER"
info "Kiosk URL   : $KIOSK_URL"
info "Shutdown    : ${SHUTDOWN_HOUR}:$(printf '%02d' $SHUTDOWN_MINUTE) daily"
info "Wake        : ${WAKE_HOUR}:$(printf '%02d' $WAKE_MINUTE) daily (RTC)"
$HAS_BUILTIN_RTC && info "RTC         : Built-in (Pi 5)" \
                 || info "RTC         : External module required (Pi 4)"
echo ""

# ── 1. Packages ───────────────────────────────────────────────────────────────
log "Updating package list..."
apt-get update -qq

if $IS_TRIXIE; then
    log "Installing packages (Trixie/Wayland)..."
    apt-get install -y -qq \
        "$CHROMIUM_PKG" \
        cage \
        wlr-randr \
        swaybg \
        util-linux \
        xdg-utils \
        curl \
        jq
else
    log "Installing packages (Bookworm/X11)..."
    apt-get install -y -qq \
        "$CHROMIUM_PKG" \
        unclutter \
        xdotool \
        x11-xserver-utils \
        util-linux \
        curl \
        jq
fi

# ── 2. GPU overlay ────────────────────────────────────────────────────────────
RASPI_CONFIG_FILE=/boot/firmware/config.txt
if [[ -f "$RASPI_CONFIG_FILE" ]]; then
    if $IS_TRIXIE; then
        # Trixie/Wayland needs full KMS — ensure fkms is NOT set
        if grep -q "dtoverlay=vc4-fkms-v3d" "$RASPI_CONFIG_FILE"; then
            sed -i 's/dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-kms-v3d/' "$RASPI_CONFIG_FILE"
            log "GPU overlay: fkms → kms (Wayland requires full KMS)"
        else
            log "GPU overlay: vc4-kms-v3d already set"
        fi
    else
        # Bookworm/X11 — fkms is more stable for X11 on Pi 4; Pi 5 always uses kms
        if [[ $PI_GEN -eq 5 ]]; then
            log "GPU overlay: Pi 5 uses kms natively — no change needed"
        else
            if grep -q "dtoverlay=vc4-kms-v3d" "$RASPI_CONFIG_FILE" && \
               ! grep -q "dtoverlay=vc4-fkms-v3d" "$RASPI_CONFIG_FILE"; then
                sed -i 's/dtoverlay=vc4-kms-v3d/dtoverlay=vc4-fkms-v3d/' "$RASPI_CONFIG_FILE"
                log "GPU overlay: kms → fkms (better X11 stability on Pi 4)"
            else
                log "GPU overlay: already appropriate for X11"
            fi
        fi
    fi
else
    warn "/boot/firmware/config.txt not found — skipping GPU overlay."
fi

# ── 3. Hardware watchdog ──────────────────────────────────────────────────────
WATCHDOG_CONF=/etc/systemd/system.conf
if ! grep -q "^RuntimeWatchdogSec" "$WATCHDOG_CONF" 2>/dev/null; then
    {
        echo ""
        echo "# Kiosk hardware watchdog"
        echo "RuntimeWatchdogSec=15"
        echo "ShutdownWatchdogSec=2min"
    } >> "$WATCHDOG_CONF"
    log "Hardware watchdog enabled (15s timeout)"
else
    log "Hardware watchdog already configured"
fi

# Pi 4 watchdog module (Pi 5 has it built in)
if [[ $PI_GEN -eq 4 ]]; then
    if ! grep -q "bcm2835_wdt" /etc/modules 2>/dev/null; then
        echo "bcm2835_wdt" >> /etc/modules
        modprobe bcm2835_wdt 2>/dev/null || true
        log "bcm2835_wdt watchdog module enabled (Pi 4)"
    fi
fi

# ── 4. Autologin ──────────────────────────────────────────────────────────────
LIGHTDM_CONF=/etc/lightdm/lightdm.conf
if [[ -f "$LIGHTDM_CONF" ]]; then
    sed -i "/^\[Seat:\*\]/,/^\[/ s/^#\?autologin-user=.*/autologin-user=$KIOSK_USER/" "$LIGHTDM_CONF"
    sed -i "/^\[Seat:\*\]/,/^\[/ s/^#\?autologin-user-timeout=.*/autologin-user-timeout=0/" "$LIGHTDM_CONF"
    if $IS_TRIXIE; then
        sed -i "/^\[Seat:\*\]/,/^\[/ s/^#\?autologin-session=.*/autologin-session=labwc/" "$LIGHTDM_CONF"
        log "Autologin: $KIOSK_USER → labwc session"
    else
        sed -i "/^\[Seat:\*\]/,/^\[/ s/^#\?autologin-session=.*/autologin-session=LXDE-pi/" "$LIGHTDM_CONF"
        log "Autologin: $KIOSK_USER → LXDE-pi session"
    fi
else
    warn "lightdm.conf not found — enable autologin via raspi-config."
fi

# ── 5. Dark mode — GTK (works on both compositors) ───────────────────────────
GTK3_DIR="$KIOSK_HOME/.config/gtk-3.0"
GTK4_DIR="$KIOSK_HOME/.config/gtk-4.0"
mkdir -p "$GTK3_DIR" "$GTK4_DIR"

for GTK_DIR in "$GTK3_DIR" "$GTK4_DIR"; do
    cat > "$GTK_DIR/settings.ini" << 'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
EOF
done
log "GTK dark theme set (gtk-3.0 + gtk-4.0)"

# ── 6. Compositor-specific setup ─────────────────────────────────────────────
mkdir -p "$AUTOSTART_DIR"

if $IS_TRIXIE; then
    # ── Trixie: labwc environment ─────────────────────────────────────────────
    cat > "$AUTOSTART_DIR/environment" << 'EOF'
GTK_THEME=Adwaita:dark
DBUS_SESSION_COLOR_SCHEME=prefer-dark
CHROME_EXTRA_FLAGS="--ozone-platform=wayland"
QT_STYLE_OVERRIDE=adwaita-dark
EOF
    log "labwc environment file written (dark mode env vars)"

    # ── Trixie: labwc rc.xml ──────────────────────────────────────────────────
    RC_XML="$AUTOSTART_DIR/rc.xml"
    cat > "$RC_XML" << 'RCEOF'
<?xml version="1.0" encoding="UTF-8"?>
<labwc_config>
  <core>
    <cursorHideTimeout>1000</cursorHideTimeout>
  </core>
  <theme>
    <backgroundColor>#000000</backgroundColor>
  </theme>
  <keyboard>
    <!-- All keybindings cleared — kiosk cannot be escaped via keyboard -->
  </keyboard>
  <windowRules>
    <windowRule identifier="*">
      <action name="Maximize"/>
    </windowRule>
  </windowRules>
</labwc_config>
RCEOF
    log "labwc rc.xml written (black bg, cursor hidden, keybindings cleared)"

    # ── Trixie: systemd inhibitor (prevents Wayland idle blanking) ────────────
    SYSTEMD_USER_DIR="$KIOSK_HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "$SYSTEMD_USER_DIR/kiosk-inhibit.service" << 'EOF'
[Unit]
Description=Kiosk display sleep/blank inhibitor
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/systemd-inhibit \
    --what=idle:sleep:handle-lid-switch \
    --who=kiosk \
    --why="Kiosk display must stay on" \
    --mode=block \
    /bin/sleep infinity
Restart=always

[Install]
WantedBy=default.target
EOF
    sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$KIOSK_USER")" \
        systemctl --user enable kiosk-inhibit.service 2>/dev/null \
        || warn "kiosk-inhibit.service will activate on next login."
    log "Idle/blank inhibitor service installed"

    # ── Trixie: labwc autostart ───────────────────────────────────────────────
    cat > "$AUTOSTART_FILE" << AUTOSTART
#!/bin/bash
# ── Kiosk autostart (Trixie / Wayland + labwc) ───────────────────────────────
# To change the URL run: sudo bash kiosk-setup.sh --update-url https://new-url.com

  KIOSK_URL_VALUE=$KIOSK_URL

# Black background — painted first so the desktop is never visible
swaybg -m solid_color -c 000000 &

# Display rotation (edit DISPLAY_TRANSFORM in kiosk-setup.sh and re-run)
$(if [[ "$DISPLAY_TRANSFORM" != "normal" ]]; then
    echo "wlr-randr --output $DISPLAY_OUTPUT --transform $DISPLAY_TRANSFORM"
else
    echo "# wlr-randr --output $DISPLAY_OUTPUT --transform 90   # uncomment to rotate"
fi)

# Wait for network before launching
MAX_WAIT=30; WAITED=0
while ! curl -s --max-time 2 "\$KIOSK_URL_VALUE" > /dev/null 2>&1; do
    sleep 2; WAITED=\$((WAITED + 2))
    [ \$WAITED -ge \$MAX_WAIT ] && echo "[\$(date)] Network timeout — launching anyway" >> /var/log/kiosk.log && break
done

$(if [[ $AUTO_RELOAD_SECONDS -gt 0 ]]; then
echo "# Auto-reload every ${AUTO_RELOAD_SECONDS}s"
echo "(while true; do sleep $AUTO_RELOAD_SECONDS; WAYLAND_DISPLAY=\$WAYLAND_DISPLAY wtype -k F5 2>/dev/null; done) &"
fi)

# Chromium crash watchdog — relaunches automatically on unexpected exit
while true; do
    echo "[\$(date)] Launching Chromium → \$KIOSK_URL_VALUE" >> /var/log/kiosk.log
    chromium \\
      --ozone-platform=wayland \\
      --enable-features=UseOzonePlatform,WebContentsForceDark \\
      --force-dark-mode \\
      --kiosk \\
      --noerrdialogs \\
      --disable-infobars \\
      --disable-notifications \\
      --disable-popup-blocking \\
      --no-first-run \\
      --disable-default-apps \\
      --disable-extensions \\
      --disable-translate \\
      --disable-features=TranslateUI,PasswordManagerOnboardingAndroid \\
      --incognito \\
      --disable-session-crashed-bubble \\
      --disable-restore-session-state \\
      --disable-save-password-bubble \\
      --disable-sync \\
      --disable-background-networking \\
      --check-for-update-interval=31536000 \\
      --disable-pinch \\
      --touch-events=enabled \\
      --disable-features=TouchpadOverscrollHistoryNavigation \\
      --overscroll-history-navigation=0 \\
      --hide-scrollbars \\
      --autoplay-policy=no-user-gesture-required \\
      "\$KIOSK_URL_VALUE"
    echo "[\$(date)] Chromium exited (\$?) — restarting in 5s..." >> /var/log/kiosk.log
    sleep 5
done &
AUTOSTART
    chmod +x "$AUTOSTART_FILE"
    log "labwc autostart written"

else
    # ── Bookworm: Xorg blanking config ───────────────────────────────────────
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/10-kiosk-blanking.conf << 'EOF'
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
EOF
    log "Xorg blanking disabled via xorg.conf.d"

    # ── Bookworm: black LXDE desktop background (prevents desktop flash) ──────
    PCMANFM_DIR="$KIOSK_HOME/.config/pcmanfm/LXDE-pi"
    mkdir -p "$PCMANFM_DIR"
    cat > "$PCMANFM_DIR/desktop-items-0.conf" << 'EOF'
[*]
wallpaper_mode=color
desktop_bg=#000000
desktop_fg=#000000
desktop_shadow=#000000
show_documents=0
show_trash=0
show_mounts=0
EOF
    log "LXDE desktop background set to black (no desktop flash)"

    # ── Bookworm: LXDE autostart ──────────────────────────────────────────────
    cat > "$AUTOSTART_FILE" << AUTOSTART
# ── Kiosk autostart (Bookworm / X11 + LXDE) ─────────────────────────────────
# To change the URL run: sudo bash kiosk-setup.sh --update-url https://new-url.com

# Sentinel line — do not rename this variable
  KIOSK_URL_VALUE=$KIOSK_URL

# Paint black root window immediately (belt-and-suspenders against flash)
@xsetroot -solid black

# Disable screen saver and DPMS
@xset s off
@xset -dpms
@xset s noblank

# Hide the mouse cursor when idle
@unclutter -idle 0.5 -root

# Wait for network then launch Chromium via wrapper script
@bash -c '
  KIOSK_URL=\$(grep "KIOSK_URL_VALUE=" $AUTOSTART_FILE | head -1 | cut -d= -f2)
  MAX_WAIT=30; WAITED=0
  while ! curl -s --max-time 2 "\$KIOSK_URL" > /dev/null 2>&1; do
    sleep 2; WAITED=\$((WAITED + 2))
    [ \$WAITED -ge \$MAX_WAIT ] && echo "[\$(date)] Network timeout" >> /var/log/kiosk.log && break
  done
  while true; do
    echo "[\$(date)] Launching Chromium → \$KIOSK_URL" >> /var/log/kiosk.log
    chromium-browser \
      --enable-features=WebContentsForceDark \
      --force-dark-mode \
      --kiosk \
      --noerrdialogs \
      --disable-infobars \
      --disable-notifications \
      --disable-popup-blocking \
      --no-first-run \
      --disable-default-apps \
      --disable-extensions \
      --disable-translate \
      --disable-features=TranslateUI,PasswordManagerOnboardingAndroid \
      --incognito \
      --disable-session-crashed-bubble \
      --disable-restore-session-state \
      --disable-save-password-bubble \
      --disable-sync \
      --disable-background-networking \
      --check-for-update-interval=31536000 \
      --disable-pinch \
      --touch-events=enabled \
      --overscroll-history-navigation=0 \
      --hide-scrollbars \
      --autoplay-policy=no-user-gesture-required \
      "\$KIOSK_URL"
    echo "[\$(date)] Chromium exited (\$?) — restarting in 5s..." >> /var/log/kiosk.log
    sleep 5
  done
'
AUTOSTART

    # Fix the self-referential path in the Bookworm autostart wrapper
    sed -i "s|$AUTOSTART_FILE|$AUTOSTART_FILE|g" "$AUTOSTART_FILE"

    log "LXDE autostart written"
fi

# ── 7. Wi-Fi power-save off ───────────────────────────────────────────────────
WIFI_PM_CONF=/etc/NetworkManager/conf.d/99-kiosk-wifi-powersave.conf
cat > "$WIFI_PM_CONF" << 'EOF'
[connection]
wifi.powersave = 2
EOF
log "Wi-Fi power management disabled"

# ── 8. Ownership ──────────────────────────────────────────────────────────────
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"
log "Ownership set for $KIOSK_HOME/.config"

# ── 9. Shutdown + RTC wake script ────────────────────────────────────────────
SHUTDOWN_MINUTE_PAD=$(printf '%02d' $SHUTDOWN_MINUTE)
WAKE_MINUTE_PAD=$(printf '%02d' $WAKE_MINUTE)

# Pi 5 RTC device path differs from external modules
if [[ $PI_GEN -eq 5 ]]; then
    RTC_DEVICE_PATH="/sys/class/rtc/rtc0/wakealarm"
    RTC_NOTE="Pi 5 built-in RTC"
else
    RTC_DEVICE_PATH="/sys/class/rtc/rtc0/wakealarm"
    RTC_NOTE="External RTC module (e.g. DS3231)"
fi

cat > /usr/local/bin/kiosk-shutdown.sh << SCRIPT
#!/bin/bash
# =============================================================================
#  kiosk-shutdown.sh
#  Shuts down the Pi and sets an RTC wake alarm.
#  RTC: $RTC_NOTE
# =============================================================================

WAKE_HOUR=${WAKE_HOUR}
WAKE_MINUTE=${WAKE_MINUTE}
RTC_DEVICE=${RTC_DEVICE_PATH}

echo "[\$(date)] Shutdown initiated — setting RTC wake for \${WAKE_HOUR}:\$(printf '%02d' \$WAKE_MINUTE)..." \
    | tee -a /var/log/kiosk.log

WAKE_TIME_STR="\${WAKE_HOUR}:\$(printf '%02d' \$WAKE_MINUTE):00"
NOW=\$(date +%s)
TODAY_WAKE=\$(date -d "today \${WAKE_TIME_STR}" +%s)
TOMORROW_WAKE=\$(date -d "tomorrow \${WAKE_TIME_STR}" +%s)

if [ "\$NOW" -ge "\$TODAY_WAKE" ]; then
    WAKE_EPOCH=\$TOMORROW_WAKE
else
    WAKE_EPOCH=\$TODAY_WAKE
fi

WAKE_DATE=\$(date -d "@\$WAKE_EPOCH" '+%A %Y-%m-%d %H:%M:%S')
echo "[\$(date)] RTC alarm → \$WAKE_DATE" | tee -a /var/log/kiosk.log

if [[ -w "\$RTC_DEVICE" ]]; then
    echo 0 > "\$RTC_DEVICE"
    echo "\$WAKE_EPOCH" > "\$RTC_DEVICE"
    echo "[\$(date)] Alarm written via sysfs" | tee -a /var/log/kiosk.log
elif command -v rtcwake &>/dev/null; then
    rtcwake -m no -t "\$WAKE_EPOCH"
    echo "[\$(date)] Alarm set via rtcwake" | tee -a /var/log/kiosk.log
else
    echo "[\$(date)] ERROR: Cannot set RTC alarm — no sysfs or rtcwake found." | tee -a /var/log/kiosk.log
    exit 1
fi

sync
echo "[\$(date)] Shutting down. Good night!" | tee -a /var/log/kiosk.log
/sbin/shutdown -h now
SCRIPT

chmod +x /usr/local/bin/kiosk-shutdown.sh
log "Shutdown script → /usr/local/bin/kiosk-shutdown.sh"

# ── 10. Cron job ──────────────────────────────────────────────────────────────
CRON_JOB="$SHUTDOWN_MINUTE $SHUTDOWN_HOUR * * * /usr/local/bin/kiosk-shutdown.sh >> /var/log/kiosk.log 2>&1"
( crontab -l 2>/dev/null | grep -v "kiosk-shutdown"; echo "$CRON_JOB" ) | crontab -
log "Cron: shutdown daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"

# ── 11. Log rotation ──────────────────────────────────────────────────────────
cat > /etc/logrotate.d/kiosk << 'EOF'
/var/log/kiosk.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
log "Log rotation configured"

# ── 12. Install marker ────────────────────────────────────────────────────────
cat > "$INSTALL_MARKER" << EOF
INSTALLED=$(date '+%Y-%m-%d %H:%M:%S')
OS=$OS_CODENAME
PI=$PI_MODEL
USER=$KIOSK_USER
URL=$KIOSK_URL
COMPOSITOR=$COMPOSITOR
AUTOSTART=$AUTOSTART_FILE
SHUTDOWN=${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}
WAKE=${WAKE_HOUR}:${WAKE_MINUTE_PAD}
EOF
log "Install marker → $INSTALL_MARKER"

# =============================================================================
#  Done
# =============================================================================
echo ""
hr
echo -e "${GREEN}  Setup Complete!${NC}"
hr
echo ""
echo -e "  ${CYAN}Pi model     :${NC} $PI_MODEL"
echo -e "  ${CYAN}OS           :${NC} $OS_CODENAME"
echo -e "  ${CYAN}Compositor   :${NC} $COMPOSITOR"
echo -e "  ${CYAN}Kiosk URL    :${NC} $KIOSK_URL"
echo -e "  ${CYAN}Dark mode    :${NC} Forced (GTK + Chromium)"
echo -e "  ${CYAN}Shutdown     :${NC} Daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"
echo -e "  ${CYAN}Wake         :${NC} Daily at ${WAKE_HOUR}:${WAKE_MINUTE_PAD} (RTC)"
echo -e "  ${CYAN}Logs         :${NC} /var/log/kiosk.log"
echo ""

if ! $HAS_BUILTIN_RTC; then
    warn "Pi 4 detected — RTC wake requires an external module (e.g. DS3231):"
    echo "    sudo hwclock -r           # verify hardware clock"
    echo "    sudo hwclock --systohc    # sync system time → RTC"
    echo ""
else
    info "Pi 5 built-in RTC detected. Verify it:"
    echo "    sudo hwclock -r"
    echo "    sudo hwclock --systohc"
    echo ""
fi

if $IS_TRIXIE; then
    info "To rotate display, set DISPLAY_TRANSFORM in the script and re-run."
    echo "    Current output name can be found with:  wlr-randr"
    echo ""
fi

info "To update the URL without reinstalling:"
echo "    sudo bash $0 --update-url https://new-url.com"
echo ""
warn "Reboot to start the kiosk:"
echo "    sudo reboot"
echo ""
