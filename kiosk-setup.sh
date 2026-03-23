#!/bin/bash
# =============================================================================
#  kiosk-setup.sh — Wall Panel Kiosk for Raspberry Pi
# =============================================================================
#  Supports:
#    Hardware : Raspberry Pi 4, Raspberry Pi 5
#    OS       : Raspberry Pi OS Bookworm (Debian 12) — X11 + LXDE
#               Raspberry Pi OS Trixie  (Debian 13) — Wayland + labwc
#
#  USAGE:
#    Full install:
#      sudo bash kiosk-setup.sh https://your-dashboard.com
#
#    Update URL only (no reinstall):
#      sudo bash kiosk-setup.sh --update-url https://new-url.com
#
#    Enable RTC shutdown/wake after adding RTC hardware:
#      sudo bash kiosk-setup.sh --enable-rtc
#
#  Features:
#    - Auto-detects OS, compositor, and Pi model at runtime
#    - Probes for RTC hardware — disables shutdown/wake gracefully if absent
#    - Full kiosk mode with dark mode forced at OS + browser level
#    - No desktop flash (black bg before Chromium loads)
#    - Chromium crash watchdog — auto-restarts on unexpected exit
#    - Network-aware boot — waits for URL before launching
#    - Optional on-screen keyboard (wvkbd / onboard)
#    - Hardware watchdog — Pi reboots if kernel hangs > 15s
#    - Idempotent: --update-url and --enable-rtc are safe to run anytime
# =============================================================================

set -e

# =============================================================================
#  CONFIG — edit these before running
# =============================================================================

# URL to display (also accepted as first positional argument)
KIOSK_URL="${1:-https://example.com}"

# Shutdown time (24h) — only active if RTC hardware is detected
SHUTDOWN_HOUR=0
SHUTDOWN_MINUTE=0

# RTC wake time (24h) — only active if RTC hardware is detected
WAKE_HOUR=6
WAKE_MINUTE=0

# On-screen keyboard
# true  = install and enable OSK (wvkbd on Trixie, onboard on Bookworm)
# false = no OSK (default for dashboards that need no text input)
ENABLE_OSK=false

# Display rotation: normal | 90 | 180 | 270  (Trixie/Wayland only)
DISPLAY_TRANSFORM="normal"

# Wayland output name — run `wlr-randr` after boot to find yours
# Common values: HDMI-A-1, HDMI-A-2, DSI-1 (Pi official touchscreen)
DISPLAY_OUTPUT="HDMI-A-1"

# Auto-reload page every N seconds (0 = disabled)
AUTO_RELOAD_SECONDS=0

# =============================================================================
#  Internal — do not edit below this line
# =============================================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'
log()    { echo -e "${GREEN}[✔]${NC} $1"; }
info()   { echo -e "${CYAN}[i]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
err()    { echo -e "${RED}[✘]${NC} $1"; exit 1; }
banner() { echo -e "${CYAN}${BOLD}$1${NC}"; }
hr()     { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

KIOSK_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
KIOSK_HOME="/home/$KIOSK_USER"
INSTALL_MARKER="/etc/kiosk-installed"
SHUTDOWN_MINUTE_PAD=$(printf '%02d' "$SHUTDOWN_MINUTE")
WAKE_MINUTE_PAD=$(printf '%02d' "$WAKE_MINUTE")

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Must be run as root. Try: sudo bash $0 [--update-url|--enable-rtc] <args>"
command -v raspi-config &>/dev/null || err "This doesn't look like a Raspberry Pi. Aborting."

# ── OS detection ──────────────────────────────────────────────────────────────
OS_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"')

case "$OS_CODENAME" in
    trixie)
        IS_TRIXIE=true;    IS_BOOKWORM=false
        COMPOSITOR="Wayland + labwc"
        CHROMIUM_PKG="chromium"
        OSK_PKG="wvkbd"
        ;;
    bookworm)
        IS_TRIXIE=false;   IS_BOOKWORM=true
        COMPOSITOR="X11 + LXDE"
        CHROMIUM_PKG="chromium-browser"
        OSK_PKG="onboard"
        ;;
    *)
        err "Unsupported OS: '$OS_CODENAME'. Supported: bookworm, trixie."
        ;;
esac

# ── Pi model detection ────────────────────────────────────────────────────────
PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")
if   echo "$PI_MODEL" | grep -q "Raspberry Pi 5"; then PI_GEN=5
elif echo "$PI_MODEL" | grep -q "Raspberry Pi 4"; then PI_GEN=4
else
    PI_GEN=0
    warn "Could not identify Pi model — assuming Pi 4 behaviour."
fi

# ── Autostart path by compositor ─────────────────────────────────────────────
if $IS_TRIXIE; then
    AUTOSTART_DIR="$KIOSK_HOME/.config/labwc"
else
    AUTOSTART_DIR="$KIOSK_HOME/.config/lxsession/LXDE-pi"
fi
AUTOSTART_FILE="$AUTOSTART_DIR/autostart"

# =============================================================================
#  RTC DETECTION — probes hardware directly, never assumes
# =============================================================================
detect_rtc() {
    local RTC_WAKEALARM="/sys/class/rtc/rtc0/wakealarm"

    # 1. Does the sysfs node exist at all?
    if [[ ! -e "$RTC_WAKEALARM" ]]; then
        RTC_PRESENT=false
        RTC_STATUS="No RTC device found at $RTC_WAKEALARM"
        return
    fi

    # 2. Can we read the hardware clock successfully?
    if ! hwclock -r &>/dev/null; then
        RTC_PRESENT=false
        RTC_STATUS="RTC node exists but hwclock could not read it (module missing or clock not set)"
        return
    fi

    # 3. Is the wakealarm writable? (Some dummy RTCs exist but can't set alarms)
    if ! echo 0 > "$RTC_WAKEALARM" 2>/dev/null; then
        RTC_PRESENT=false
        RTC_STATUS="RTC found but wakealarm is not writable (check i2c/permissions)"
        return
    fi

    RTC_PRESENT=true
    RTC_CLOCK=$(hwclock -r 2>/dev/null || echo "unknown")
    if [[ $PI_GEN -eq 5 ]]; then
        RTC_STATUS="Built-in Pi 5 RTC detected (${RTC_CLOCK})"
    else
        RTC_STATUS="External RTC module detected (${RTC_CLOCK})"
    fi
}

detect_rtc

# =============================================================================
#  --enable-rtc  — activate shutdown/wake on an already-installed kiosk
# =============================================================================
if [[ "$1" == "--enable-rtc" ]]; then
    hr
    banner "  Enable RTC Shutdown/Wake"
    hr
    echo ""
    [[ ! -f "$INSTALL_MARKER" ]] && err "Kiosk not yet installed. Run a full install first."

    detect_rtc
    if ! $RTC_PRESENT; then
        echo ""
        warn "RTC hardware still not detected:"
        echo "    $RTC_STATUS"
        echo ""
        echo "  Check that your RTC module is:"
        echo "    1. Physically connected (SDA→GPIO2, SCL→GPIO3, VCC→3.3V, GND→GND)"
        echo "    2. Enabled in /boot/firmware/config.txt:"
        echo "       dtoverlay=i2c-rtc,ds3231    ← or your module type"
        echo "    3. The Pi has been rebooted since adding the overlay"
        echo ""
        echo "  Once hardware is confirmed, re-run:"
        echo "    sudo bash $0 --enable-rtc"
        echo ""
        exit 1
    fi

    log "RTC detected: $RTC_STATUS"
    echo ""

    # Write the shutdown script
    _write_shutdown_script

    # Install cron job
    CRON_JOB="$SHUTDOWN_MINUTE $SHUTDOWN_HOUR * * * /usr/local/bin/kiosk-shutdown.sh >> /var/log/kiosk.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v "kiosk-shutdown"; echo "$CRON_JOB" ) | crontab -
    log "Cron job installed: shutdown daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"

    # Update the install marker
    sed -i "s/^RTC_ENABLED=.*/RTC_ENABLED=true/" "$INSTALL_MARKER"

    echo ""
    log "Scheduled shutdown + RTC wake are now active."
    info "  Shutdown : daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"
    info "  Wake     : daily at ${WAKE_HOUR}:${WAKE_MINUTE_PAD}"
    echo ""
    warn "Sync your hardware clock now if you haven't already:"
    echo "    sudo hwclock --systohc"
    echo ""
    exit 0
fi

# =============================================================================
#  --update-url  — change the kiosk URL, no reinstall
# =============================================================================
if [[ "$1" == "--update-url" ]]; then
    UPDATE_URL="${2:-}"
    [[ -z "$UPDATE_URL" ]] && err "No URL provided. Usage: sudo bash $0 --update-url https://new-url.com"
    [[ ! -f "$INSTALL_MARKER" ]] && err "Kiosk not yet installed. Run a full install first."
    [[ ! -f "$AUTOSTART_FILE" ]] && err "Autostart file not found at $AUTOSTART_FILE"

    hr
    banner "  Kiosk URL Update"
    hr
    echo ""
    info "New URL → $UPDATE_URL"

    sed -i "s|^  KIOSK_URL_VALUE=.*|  KIOSK_URL_VALUE=$UPDATE_URL|" "$AUTOSTART_FILE"
    sed -i "s|^URL=.*|URL=$UPDATE_URL|" "$INSTALL_MARKER"

    log "URL updated in $AUTOSTART_FILE"
    echo ""
    warn "Reboot to apply:  sudo reboot"
    echo "  — or kill Chromium and the watchdog will relaunch it:"
    echo "      sudo pkill chromium"
    echo ""
    exit 0
fi

# =============================================================================
#  Full install
# =============================================================================
[[ "$1" != "https://"* && "$1" != "http://"* && -n "$1" ]] && \
    err "Unknown argument: '$1'. Did you mean --update-url or --enable-rtc?"
[[ -z "$1" ]] && warn "No URL supplied — defaulting to https://example.com"

hr
banner "  Raspberry Pi Wall Panel Kiosk — Full Install"
hr
echo ""
info "Pi model    : $PI_MODEL"
info "OS          : $OS_CODENAME (Debian $OS_VERSION)"
info "Compositor  : $COMPOSITOR"
info "Kiosk user  : $KIOSK_USER"
info "Kiosk URL   : $KIOSK_URL"
info "OSK         : $([ "$ENABLE_OSK" = true ] && echo "Enabled ($OSK_PKG)" || echo "Disabled")"
echo ""

# ── RTC status report ─────────────────────────────────────────────────────────
if $RTC_PRESENT; then
    info "RTC         : $RTC_STATUS"
    info "Shutdown    : Daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"
    info "Wake        : Daily at ${WAKE_HOUR}:${WAKE_MINUTE_PAD}"
else
    warn "RTC         : NOT DETECTED — $RTC_STATUS"
    warn "Shutdown/wake scheduling will be DISABLED."
    warn "Re-enable later with:  sudo bash $0 --enable-rtc"
fi
echo ""

# ── 1. Packages ───────────────────────────────────────────────────────────────
log "Updating package list..."
apt-get update -qq

BASE_PKGS=(util-linux curl jq)
OSK_PKGS=()
$ENABLE_OSK && OSK_PKGS=("$OSK_PKG")

if $IS_TRIXIE; then
    log "Installing packages (Trixie/Wayland)..."
    apt-get install -y -qq \
        "$CHROMIUM_PKG" cage wlr-randr swaybg xdg-utils \
        "${BASE_PKGS[@]}" "${OSK_PKGS[@]}"
else
    log "Installing packages (Bookworm/X11)..."
    apt-get install -y -qq \
        "$CHROMIUM_PKG" unclutter xdotool x11-xserver-utils \
        "${BASE_PKGS[@]}" "${OSK_PKGS[@]}"
fi

# ── 2. GPU overlay ────────────────────────────────────────────────────────────
RASPI_CONFIG_FILE=/boot/firmware/config.txt
if [[ -f "$RASPI_CONFIG_FILE" ]]; then
    if $IS_TRIXIE; then
        if grep -q "dtoverlay=vc4-fkms-v3d" "$RASPI_CONFIG_FILE"; then
            sed -i 's/dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-kms-v3d/' "$RASPI_CONFIG_FILE"
            log "GPU overlay: fkms → kms (Wayland requires full KMS)"
        else
            log "GPU overlay: vc4-kms-v3d already set"
        fi
    else
        if [[ $PI_GEN -ne 5 ]] && \
           grep -q "dtoverlay=vc4-kms-v3d" "$RASPI_CONFIG_FILE" && \
           ! grep -q "dtoverlay=vc4-fkms-v3d" "$RASPI_CONFIG_FILE"; then
            sed -i 's/dtoverlay=vc4-kms-v3d/dtoverlay=vc4-fkms-v3d/' "$RASPI_CONFIG_FILE"
            log "GPU overlay: kms → fkms (better X11 stability on Pi 4)"
        else
            log "GPU overlay: already appropriate"
        fi
    fi
else
    warn "/boot/firmware/config.txt not found — skipping GPU overlay."
fi

# ── 3. Hardware watchdog ──────────────────────────────────────────────────────
WATCHDOG_CONF=/etc/systemd/system.conf
if ! grep -q "^RuntimeWatchdogSec" "$WATCHDOG_CONF" 2>/dev/null; then
    { echo ""; echo "# Kiosk hardware watchdog"
      echo "RuntimeWatchdogSec=15"; echo "ShutdownWatchdogSec=2min"; } >> "$WATCHDOG_CONF"
    log "Hardware watchdog enabled (15s timeout)"
else
    log "Hardware watchdog already configured"
fi

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
        log "Autologin: $KIOSK_USER → labwc"
    else
        sed -i "/^\[Seat:\*\]/,/^\[/ s/^#\?autologin-session=.*/autologin-session=LXDE-pi/" "$LIGHTDM_CONF"
        log "Autologin: $KIOSK_USER → LXDE-pi"
    fi
else
    warn "lightdm.conf not found — enable autologin via raspi-config."
fi

# ── 5. GTK dark theme ─────────────────────────────────────────────────────────
for GTK_DIR in "$KIOSK_HOME/.config/gtk-3.0" "$KIOSK_HOME/.config/gtk-4.0"; do
    mkdir -p "$GTK_DIR"
    cat > "$GTK_DIR/settings.ini" << 'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
EOF
done
log "GTK dark theme set (gtk-3.0 + gtk-4.0)"

# ── 6. Compositor-specific config ────────────────────────────────────────────
mkdir -p "$AUTOSTART_DIR"

if $IS_TRIXIE; then

    # labwc environment
    cat > "$AUTOSTART_DIR/environment" << 'EOF'
GTK_THEME=Adwaita:dark
DBUS_SESSION_COLOR_SCHEME=prefer-dark
CHROME_EXTRA_FLAGS="--ozone-platform=wayland"
QT_STYLE_OVERRIDE=adwaita-dark
EOF
    log "labwc environment written"

    # labwc rc.xml
    cat > "$AUTOSTART_DIR/rc.xml" << 'RCEOF'
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
    log "labwc rc.xml written"

    # systemd idle inhibitor
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

    # ── OSK: wvkbd (Wayland) ─────────────────────────────────────────────────
    # wvkbd is a Wayland-native on-screen keyboard.
    # It surfaces automatically when Chromium requests a virtual keyboard via
    # the input-method Wayland protocol (triggered on tap of any text input).
    # The keyboard appears at the bottom of the screen and dismisses on blur.
    if $ENABLE_OSK; then
        OSK_LAUNCH="wvkbd-mobintl --hidden --fn 'Noto Sans 16' --landscape-layers full &"
        log "OSK: wvkbd configured (appears on text field tap)"
    else
        OSK_LAUNCH="# OSK disabled. Set ENABLE_OSK=true in kiosk-setup.sh and re-run to enable."
    fi

    # ── labwc autostart ───────────────────────────────────────────────────────
    cat > "$AUTOSTART_FILE" << AUTOSTART
#!/bin/bash
# ── Kiosk autostart (Trixie / Wayland + labwc) ───────────────────────────────
# Update URL: sudo bash kiosk-setup.sh --update-url https://new-url.com

  KIOSK_URL_VALUE=$KIOSK_URL

# Black background — first thing drawn, so the desktop is never visible
swaybg -m solid_color -c 000000 &

# On-screen keyboard (wvkbd) — appears automatically on text field focus
$OSK_LAUNCH

# Display rotation
$(if [[ "$DISPLAY_TRANSFORM" != "normal" ]]; then
    echo "wlr-randr --output $DISPLAY_OUTPUT --transform $DISPLAY_TRANSFORM"
else
    echo "# wlr-randr --output $DISPLAY_OUTPUT --transform 90   # uncomment to rotate"
fi)

# Wait up to 30s for the URL to be reachable before launching
MAX_WAIT=30; WAITED=0
while ! curl -s --max-time 2 "\$KIOSK_URL_VALUE" > /dev/null 2>&1; do
    sleep 2; WAITED=\$((WAITED + 2))
    [ \$WAITED -ge \$MAX_WAIT ] \
        && echo "[\$(date)] Network wait timeout — launching anyway" >> /var/log/kiosk.log \
        && break
done

$(if [[ $AUTO_RELOAD_SECONDS -gt 0 ]]; then
echo "# Auto-reload every ${AUTO_RELOAD_SECONDS}s via F5 keystroke"
echo "(while true; do sleep $AUTO_RELOAD_SECONDS; wtype -k F5 2>/dev/null; done) &"
fi)

# Chromium crash watchdog — relaunches automatically on any exit
while true; do
    echo "[\$(date)] Launching Chromium → \$KIOSK_URL_VALUE" >> /var/log/kiosk.log
    chromium \\
      --ozone-platform=wayland \\
      --enable-features=UseOzonePlatform,WebContentsForceDark \\
      --force-dark-mode \\
      $(if $ENABLE_OSK; then echo "--enable-virtual-keyboard \\\\"; fi)
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
    # ── Bookworm / X11 ────────────────────────────────────────────────────────

    # Xorg blanking
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/10-kiosk-blanking.conf << 'EOF'
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection
EOF
    log "Xorg blanking disabled"

    # Black LXDE desktop (prevents flash before Chromium paints)
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
    log "LXDE desktop background set to black"

    # ── OSK: onboard (X11) ───────────────────────────────────────────────────
    # onboard is a full-featured X11 OSK that auto-shows on text field focus
    # when accessibility support is enabled. It works well with Chromium in
    # kiosk mode on Bookworm — no extra input method configuration needed.
    if $ENABLE_OSK; then
        OSK_LINE="@onboard --startup-delay=4 --theme=Blackboard &"
        log "OSK: onboard configured (auto-shows on text field tap)"
    else
        OSK_LINE="# OSK disabled. Set ENABLE_OSK=true in kiosk-setup.sh and re-run to enable."
    fi

    # LXDE autostart
    cat > "$AUTOSTART_FILE" << AUTOSTART
# ── Kiosk autostart (Bookworm / X11 + LXDE) ─────────────────────────────────
# Update URL: sudo bash kiosk-setup.sh --update-url https://new-url.com

  KIOSK_URL_VALUE=$KIOSK_URL

# Black root window — drawn before anything else to prevent desktop flash
@xsetroot -solid black

# Disable screen saver and DPMS power management
@xset s off
@xset -dpms
@xset s noblank

# Hide mouse cursor when idle (0.5s timeout)
@unclutter -idle 0.5 -root

# On-screen keyboard
$OSK_LINE

# Network wait + Chromium crash watchdog
@bash -c '
  KIOSK_URL=\$(grep "KIOSK_URL_VALUE=" "${AUTOSTART_FILE}" | head -1 | sed "s/.*KIOSK_URL_VALUE=//")
  MAX_WAIT=30; WAITED=0
  while ! curl -s --max-time 2 "\$KIOSK_URL" > /dev/null 2>&1; do
    sleep 2; WAITED=\$((WAITED + 2))
    [ \$WAITED -ge \$MAX_WAIT ] \
      && echo "[\$(date)] Network timeout — launching anyway" >> /var/log/kiosk.log \
      && break
  done
  while true; do
    echo "[\$(date)] Launching Chromium → \$KIOSK_URL" >> /var/log/kiosk.log
    chromium-browser \
      --enable-features=WebContentsForceDark \
      --force-dark-mode \
$(if $ENABLE_OSK; then echo '      --enable-virtual-keyboard \'; fi)
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
    log "LXDE autostart written"
fi

# ── 7. Wi-Fi power-save off ───────────────────────────────────────────────────
cat > /etc/NetworkManager/conf.d/99-kiosk-wifi-powersave.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF
log "Wi-Fi power management disabled"

# ── 8. Ownership ──────────────────────────────────────────────────────────────
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"
log "Ownership set for $KIOSK_HOME/.config"

# ── 9. Shutdown script (written as a function so --enable-rtc can reuse it) ──
_write_shutdown_script() {
    cat > /usr/local/bin/kiosk-shutdown.sh << SCRIPT
#!/bin/bash
# =============================================================================
#  kiosk-shutdown.sh — Nightly shutdown with RTC wake alarm
#  Generated by kiosk-setup.sh
# =============================================================================

WAKE_HOUR=${WAKE_HOUR}
WAKE_MINUTE=${WAKE_MINUTE}
RTC_DEVICE=/sys/class/rtc/rtc0/wakealarm

echo "[\$(date)] Shutdown initiated — RTC wake set for \${WAKE_HOUR}:\$(printf '%02d' \$WAKE_MINUTE)..." \
    | tee -a /var/log/kiosk.log

WAKE_TIME_STR="\${WAKE_HOUR}:\$(printf '%02d' \$WAKE_MINUTE):00"
NOW=\$(date +%s)
TODAY_WAKE=\$(date -d "today \${WAKE_TIME_STR}" +%s)
TOMORROW_WAKE=\$(date -d "tomorrow \${WAKE_TIME_STR}" +%s)

# Always wake tomorrow if we're already past today's wake time
WAKE_EPOCH=\$( [ "\$NOW" -ge "\$TODAY_WAKE" ] && echo "\$TOMORROW_WAKE" || echo "\$TODAY_WAKE" )

echo "[\$(date)] RTC alarm → \$(date -d "@\$WAKE_EPOCH" '+%A %Y-%m-%d %H:%M:%S')" \
    | tee -a /var/log/kiosk.log

if [[ -w "\$RTC_DEVICE" ]]; then
    echo 0 > "\$RTC_DEVICE"
    echo "\$WAKE_EPOCH" > "\$RTC_DEVICE"
    echo "[\$(date)] Alarm written via sysfs" | tee -a /var/log/kiosk.log
elif command -v rtcwake &>/dev/null; then
    rtcwake -m no -t "\$WAKE_EPOCH"
    echo "[\$(date)] Alarm set via rtcwake" | tee -a /var/log/kiosk.log
else
    echo "[\$(date)] ERROR: Cannot set RTC alarm — wakealarm not writable and rtcwake not found." \
        | tee -a /var/log/kiosk.log
    exit 1
fi

sync
echo "[\$(date)] Shutting down. Good night!" | tee -a /var/log/kiosk.log
/sbin/shutdown -h now
SCRIPT
    chmod +x /usr/local/bin/kiosk-shutdown.sh
    log "Shutdown script written → /usr/local/bin/kiosk-shutdown.sh"
}

# ── 10. Conditionally install shutdown + cron ─────────────────────────────────
if $RTC_PRESENT; then
    _write_shutdown_script

    CRON_JOB="$SHUTDOWN_MINUTE $SHUTDOWN_HOUR * * * /usr/local/bin/kiosk-shutdown.sh >> /var/log/kiosk.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v "kiosk-shutdown"; echo "$CRON_JOB" ) | crontab -
    log "Cron: shutdown daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"
    RTC_ENABLED=true
else
    # Remove any leftover cron job from a previous install
    ( crontab -l 2>/dev/null | grep -v "kiosk-shutdown" ) | crontab - 2>/dev/null || true
    RTC_ENABLED=false
    warn "No RTC detected — shutdown/wake scheduling skipped."
fi

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
RTC_ENABLED=$RTC_ENABLED
OSK_ENABLED=$ENABLE_OSK
EOF
log "Install marker → $INSTALL_MARKER"

# =============================================================================
#  Summary
# =============================================================================
echo ""
hr
banner "  Setup Complete!"
hr
echo ""
echo -e "  ${CYAN}Pi model     :${NC} $PI_MODEL"
echo -e "  ${CYAN}OS           :${NC} $OS_CODENAME (Debian $OS_VERSION)"
echo -e "  ${CYAN}Compositor   :${NC} $COMPOSITOR"
echo -e "  ${CYAN}Kiosk URL    :${NC} $KIOSK_URL"
echo -e "  ${CYAN}Dark mode    :${NC} Forced (GTK + Chromium)"
echo -e "  ${CYAN}OSK          :${NC} $([ "$ENABLE_OSK" = true ] && echo "Enabled ($OSK_PKG)" || echo "Disabled")"
echo -e "  ${CYAN}Logs         :${NC} /var/log/kiosk.log"
echo ""

if $RTC_ENABLED; then
    echo -e "  ${CYAN}Shutdown     :${NC} Daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD} (cron)"
    echo -e "  ${CYAN}Wake         :${NC} Daily at ${WAKE_HOUR}:${WAKE_MINUTE_PAD} (RTC)"
    echo ""
    warn "Sync hardware clock now if you haven't:"
    echo "    sudo hwclock --systohc"
else
    echo -e "  ${YELLOW}Shutdown     : DISABLED — RTC not detected${NC}"
    echo -e "  ${YELLOW}Wake         : DISABLED — RTC not detected${NC}"
    echo ""
    warn "No RTC hardware was found. Shutdown/wake scheduling is disabled."
    echo ""
    echo "  To add an RTC later (e.g. DS3231 on Pi 4):"
    echo "    1. Wire the module: SDA→GPIO2, SCL→GPIO3, VCC→3.3V, GND→GND"
    echo "    2. Add to /boot/firmware/config.txt:"
    echo "         dtoverlay=i2c-rtc,ds3231"
    echo "    3. Reboot, then run:"
    echo "         sudo hwclock --systohc"
    echo "         sudo bash $0 --enable-rtc"
    echo ""
    echo "  Pi 5 note: the built-in RTC requires a battery (CR2032 on the board)"
    echo "  and an initial clock sync before wakealarm becomes writable:"
    echo "    sudo hwclock --systohc && sudo bash $0 --enable-rtc"
fi

echo ""

if $ENABLE_OSK; then
    info "On-screen keyboard notes:"
    if $IS_TRIXIE; then
        echo "    wvkbd appears automatically when a text field is tapped."
        echo "    It uses the Wayland input-method protocol — no extra config needed."
        echo "    If it doesn't appear, confirm wvkbd is running:  pgrep wvkbd"
    else
        echo "    onboard appears automatically when a text field is tapped."
        echo "    Theme: Blackboard (matches dark mode). Startup delay: 4s."
        echo "    If it doesn't appear, check:  pgrep onboard"
    fi
    echo ""
else
    info "OSK is disabled. To enable:"
    echo "    Set ENABLE_OSK=true in kiosk-setup.sh, then re-run the full install."
    echo ""
fi

info "To update the URL without reinstalling:"
echo "    sudo bash $0 --update-url https://new-url.com"
echo ""
warn "Reboot to start the kiosk:"
echo "    sudo reboot"
echo ""
