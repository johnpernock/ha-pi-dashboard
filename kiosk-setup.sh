#!/bin/bash
# =============================================================================
#  kiosk-setup.sh — Wall Panel Kiosk for Raspberry Pi OS Trixie (Debian 13)
# =============================================================================
#  FULL INSTALL:
#    sudo bash kiosk-setup.sh https://your-dashboard.com
#
#  UPDATE URL ONLY (no reinstall, safe to run anytime):
#    sudo bash kiosk-setup.sh --update-url https://your-new-dashboard.com
#
#  Features:
#    - Wayland + labwc compositor (Trixie default)
#    - Chromium kiosk mode with dark mode forced (OS + browser level)
#    - All infobars / notifications / crash bubbles suppressed
#    - Pinch-to-zoom and touch scroll overrides disabled
#    - Cursor hidden, screen blanking disabled
#    - Configurable shutdown time and RTC wake time
#    - Hardware watchdog enabled (auto-reboot on kernel hang)
#    - Chromium crash watchdog (auto-restarts browser if it dies)
#    - Network wait before launching Chromium (avoids blank-on-boot)
#    - Idempotent — safe to re-run to change URL or adjust settings
#    - All activity logged to /var/log/kiosk.log with weekly rotation
# =============================================================================

set -e

# =============================================================================
#  ██████╗  ██████╗ ███╗   ██╗███████╗██╗ ██████╗
#  ██╔════╝██╔═══██╗████╗  ██║██╔════╝██║██╔════╝
#  ██║     ██║   ██║██╔██╗ ██║█████╗  ██║██║  ███╗
#  ██║     ██║   ██║██║╚██╗██║██╔══╝  ██║██║   ██║
#  ╚██████╗╚██████╔╝██║ ╚████║██║     ██║╚██████╔╝
#   ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝
#  Edit these variables before running the script.
# =============================================================================

# ── URL to display in the kiosk ───────────────────────────────────────────────
KIOSK_URL="${2:-https://example.com}"

# ── Daily shutdown time (24-hour format) ─────────────────────────────────────
SHUTDOWN_HOUR=0       # 0  = midnight
SHUTDOWN_MINUTE=0     # 0  = on the hour

# ── Daily RTC wake/startup time (24-hour format) ─────────────────────────────
WAKE_HOUR=6           # 6  = 6 AM
WAKE_MINUTE=0         # 0  = on the hour

# ── Display rotation (uncomment one if needed) ────────────────────────────────
# DISPLAY_TRANSFORM="normal"   # default landscape
# DISPLAY_TRANSFORM="90"       # portrait — rotated right
# DISPLAY_TRANSFORM="180"      # upside-down landscape
# DISPLAY_TRANSFORM="270"      # portrait — rotated left
DISPLAY_TRANSFORM="normal"

# ── Display output name (run `wlr-randr` after boot to find yours) ────────────
# Common values: HDMI-A-1, HDMI-A-2, DSI-1 (official Pi touchscreen)
DISPLAY_OUTPUT="HDMI-A-1"

# ── Chromium reload interval in seconds (0 = never auto-reload) ──────────────
#    Useful for dashboards that don't self-refresh
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
LABWC_DIR="$KIOSK_HOME/.config/labwc"
INSTALL_MARKER="/etc/kiosk-installed"

# ── Validate args ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Must be run as root.  Try: sudo bash $0 [--update-url] <URL>"

UPDATE_ONLY=false
if [[ "$1" == "--update-url" ]]; then
    UPDATE_ONLY=true
    KIOSK_URL="${2:-}"
    [[ -z "$KIOSK_URL" ]] && err "No URL provided.  Usage: sudo bash $0 --update-url https://new-url.com"
    [[ ! -f "$INSTALL_MARKER" ]] && err "Kiosk not yet installed. Run without --update-url first."
else
    KIOSK_URL="${1:-https://example.com}"
    [[ -z "$1" ]] && warn "No URL supplied — defaulting to https://example.com"
fi

# =============================================================================
#  URL-only update path — fast, no reinstall
# =============================================================================
if [[ "$UPDATE_ONLY" == true ]]; then
    hr
    echo -e "${CYAN}  Kiosk URL Update${NC}"
    hr
    info "Updating URL to: $KIOSK_URL"

    AUTOSTART="$LABWC_DIR/autostart"
    [[ ! -f "$AUTOSTART" ]] && err "Autostart file not found at $AUTOSTART"

    # Replace the URL on the last non-empty, non-comment line (the URL line)
    # Uses a sentinel comment we embed during install
    sed -i "s|^  KIOSK_URL_VALUE=.*|  KIOSK_URL_VALUE=$KIOSK_URL|" "$AUTOSTART"

    # Also update the stored URL in the marker file
    sed -i "s|^URL=.*|URL=$KIOSK_URL|" "$INSTALL_MARKER"

    log "URL updated in $AUTOSTART"
    echo ""
    warn "Restart Chromium to apply (or just reboot):"
    echo "    sudo pkill chromium && sudo -u $KIOSK_USER WAYLAND_DISPLAY=wayland-1 chromium ... &"
    echo "  — or simply:"
    echo "    sudo reboot"
    echo ""
    exit 0
fi

# =============================================================================
#  Full install path
# =============================================================================
hr
echo -e "${CYAN}  Raspberry Pi Wall Panel Kiosk Setup (Trixie)${NC}"
hr
info "Kiosk user  : $KIOSK_USER"
info "Kiosk URL   : $KIOSK_URL"
info "Compositor  : Wayland + labwc"
info "Dark mode   : Forced (OS + browser)"
info "Shutdown    : Daily at ${SHUTDOWN_HOUR}:$(printf '%02d' $SHUTDOWN_MINUTE)"
info "Wake        : Daily at ${WAKE_HOUR}:$(printf '%02d' $WAKE_MINUTE) (RTC)"
echo ""

command -v raspi-config &>/dev/null || err "This doesn't look like a Raspberry Pi. Aborting."

# ── 1. Install dependencies ───────────────────────────────────────────────────
log "Updating package list..."
apt-get update -qq

log "Installing packages..."
apt-get install -y -qq \
    chromium \
    cage \
    wlr-randr \
    swaybg \
    util-linux \
    xdg-utils \
    curl \
    jq

# ── 2. GPU overlay — keep vc4-kms-v3d for Wayland ────────────────────────────
RASPI_CONFIG_FILE=/boot/firmware/config.txt
if [[ -f "$RASPI_CONFIG_FILE" ]]; then
    if grep -q "dtoverlay=vc4-fkms-v3d" "$RASPI_CONFIG_FILE"; then
        sed -i 's/dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-kms-v3d/' "$RASPI_CONFIG_FILE"
        log "GPU overlay: vc4-fkms-v3d → vc4-kms-v3d (Wayland requires full KMS)"
    else
        log "GPU overlay vc4-kms-v3d already active"
    fi
else
    warn "/boot/firmware/config.txt not found — skipping GPU overlay check."
fi

# ── 3. Hardware watchdog ──────────────────────────────────────────────────────
#   Enables the Pi's built-in watchdog timer. If the kernel hangs for more
#   than 15 seconds the hardware will force a reboot automatically.
WATCHDOG_CONF=/etc/systemd/system.conf
if ! grep -q "^RuntimeWatchdogSec" "$WATCHDOG_CONF" 2>/dev/null; then
    echo "" >> "$WATCHDOG_CONF"
    echo "# Kiosk hardware watchdog" >> "$WATCHDOG_CONF"
    echo "RuntimeWatchdogSec=15" >> "$WATCHDOG_CONF"
    echo "ShutdownWatchdogSec=2min" >> "$WATCHDOG_CONF"
    log "Hardware watchdog enabled (15s timeout)"
else
    log "Hardware watchdog already configured"
fi

# Also enable the bcm2835 watchdog module
if ! grep -q "bcm2835_wdt" /etc/modules 2>/dev/null; then
    echo "bcm2835_wdt" >> /etc/modules
    modprobe bcm2835_wdt 2>/dev/null || true
    log "bcm2835_wdt watchdog module enabled"
fi

# ── 4. Autologin via LightDM ──────────────────────────────────────────────────
LIGHTDM_CONF=/etc/lightdm/lightdm.conf
if [[ -f "$LIGHTDM_CONF" ]]; then
    sed -i "/^\[Seat:\*\]/,/^\[/ s/^#\?autologin-user=.*/autologin-user=$KIOSK_USER/" "$LIGHTDM_CONF"
    sed -i "/^\[Seat:\*\]/,/^\[/ s/^#\?autologin-user-timeout=.*/autologin-user-timeout=0/" "$LIGHTDM_CONF"
    sed -i "/^\[Seat:\*\]/,/^\[/ s/^#\?autologin-session=.*/autologin-session=labwc/" "$LIGHTDM_CONF"
    log "Autologin: $KIOSK_USER → labwc Wayland session"
else
    warn "lightdm.conf not found. Enable autologin manually via raspi-config."
fi

# ── 5. GTK dark theme (OS-level dark mode) ───────────────────────────────────
#   Sets the GTK colour scheme and theme for the kiosk user so that any
#   GTK widgets (including Chromium's file pickers etc.) appear dark.
GTK_SETTINGS_DIR="$KIOSK_HOME/.config/gtk-3.0"
mkdir -p "$GTK_SETTINGS_DIR"
cat > "$GTK_SETTINGS_DIR/settings.ini" << 'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
EOF

GTK4_SETTINGS_DIR="$KIOSK_HOME/.config/gtk-4.0"
mkdir -p "$GTK4_SETTINGS_DIR"
cat > "$GTK4_SETTINGS_DIR/settings.ini" << 'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
EOF

# XDG color-scheme preference (read by portals & some Wayland-native apps)
DCONF_PROFILE_DIR="$KIOSK_HOME/.config/dconf"
mkdir -p "$DCONF_PROFILE_DIR"
# We set this via the environment file so it applies without a dbus session
log "GTK dark theme configured (gtk-3.0 + gtk-4.0 + Adwaita-dark)"

# ── 6. labwc environment — dark mode + display env vars ──────────────────────
#   labwc sources ~/.config/labwc/environment before launching the session.
mkdir -p "$LABWC_DIR"
cat > "$LABWC_DIR/environment" << EOF
# ── Kiosk environment ─────────────────────────────────────────────────────────

# Force dark mode for GTK apps and Chromium via the portal color-scheme hint
GTK_THEME=Adwaita:dark
DBUS_SESSION_COLOR_SCHEME=prefer-dark

# Chromium Wayland backend
CHROME_EXTRA_FLAGS="--ozone-platform=wayland"

# Prevent Qt apps from overriding dark theme
QT_STYLE_OVERRIDE=adwaita-dark
EOF
log "labwc environment file written (dark mode env vars set)"

# ── 7. labwc autostart — Chromium kiosk launcher with crash watchdog ─────────
#   This script is sourced by labwc on session start.
#   The inner while-loop is the crash watchdog: Chromium is automatically
#   relaunched if it exits unexpectedly (crash, OOM kill, etc.).
#   A 5-second network wait prevents a blank screen on cold boot.
cat > "$LABWC_DIR/autostart" << AUTOSTART
#!/bin/bash
# ── Kiosk autostart (labwc / Wayland) ────────────────────────────────────────
# Generated by kiosk-setup.sh — edit KIOSK_URL_VALUE to change the URL,
# or run:  sudo bash kiosk-setup.sh --update-url https://new-url.com

# URL — update this line or use the --update-url flag
  KIOSK_URL_VALUE=$KIOSK_URL

# ── Black background — painted FIRST so no desktop flash is ever visible ──────
# swaybg holds a solid black Wayland surface behind Chromium at all times.
# It stays running — Chromium in kiosk mode covers it completely once loaded.
swaybg -m solid_color -c 000000 &

# ── Display rotation ──────────────────────────────────────────────────────────
$(if [[ "$DISPLAY_TRANSFORM" != "normal" ]]; then
    echo "wlr-randr --output $DISPLAY_OUTPUT --transform $DISPLAY_TRANSFORM"
else
    echo "# wlr-randr --output $DISPLAY_OUTPUT --transform 90   # uncomment to rotate"
fi)

# ── Wait for network before launching (avoids blank screen on cold boot) ──────
MAX_WAIT=30
WAITED=0
while ! curl -s --max-time 2 "\$KIOSK_URL_VALUE" > /dev/null 2>&1; do
    sleep 2
    WAITED=\$((WAITED + 2))
    if [ \$WAITED -ge \$MAX_WAIT ]; then
        echo "[\$(date)] Network timeout — launching anyway" >> /var/log/kiosk.log
        break
    fi
done

# ── Auto-reload helper (optional) ─────────────────────────────────────────────
$(if [[ $AUTO_RELOAD_SECONDS -gt 0 ]]; then
cat << 'RELOAD'
# Periodically sends a reload keystroke to Chromium via wtype
(
  while true; do
    sleep AUTO_RELOAD_SECONDS
    WAYLAND_DISPLAY=\$WAYLAND_DISPLAY wtype -k F5 2>/dev/null || true
  done
) &
RELOAD
sed -i "s/AUTO_RELOAD_SECONDS/$AUTO_RELOAD_SECONDS/" "$LABWC_DIR/autostart"
else
    echo "# Auto-reload disabled. Set AUTO_RELOAD_SECONDS > 0 in kiosk-setup.sh to enable."
fi)

# ── Chromium crash watchdog loop ──────────────────────────────────────────────
# Chromium is relaunched automatically if it exits for any reason.
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
      --disable-features=OverscrollHistoryNavigation \\
      --autoplay-policy=no-user-gesture-required \\
      "\$KIOSK_URL_VALUE"
    EXIT_CODE=\$?
    echo "[\$(date)] Chromium exited (code \$EXIT_CODE) — restarting in 5s..." >> /var/log/kiosk.log
    sleep 5
done &
AUTOSTART

chmod +x "$LABWC_DIR/autostart"
log "labwc autostart written with crash watchdog + network wait"

# ── 8. labwc rc.xml — disable keybinds, hide cursor ─────────────────────────
RC_XML="$LABWC_DIR/rc.xml"
cat > "$RC_XML" << 'RCEOF'
<?xml version="1.0" encoding="UTF-8"?>
<labwc_config>
  <core>
    <!-- Hide cursor after 1 second of inactivity -->
    <cursorHideTimeout>1000</cursorHideTimeout>
  </core>
  <theme>
    <!-- Solid black background — belt-and-suspenders behind swaybg -->
    <name></name>
    <backgroundColor>#000000</backgroundColor>
  </theme>
  <keyboard>
    <!-- All keybindings cleared — kiosk cannot be escaped via keyboard -->
  </keyboard>
  <windowRules>
    <!-- Force all windows to be fullscreen and undecorated -->
    <windowRule identifier="*">
      <action name="Maximize"/>
    </windowRule>
  </windowRules>
</labwc_config>
RCEOF
log "labwc rc.xml written (cursor hidden, keybindings cleared)"

# ── 9. Systemd user service — idle screen blanking inhibitor ─────────────────
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
    || warn "kiosk-inhibit.service will activate on next login (normal during install)"

log "Idle/blank inhibitor service installed"

# ── 10. Disable Bluetooth and Wi-Fi power-save (reduces display stutter) ──────
if command -v rfkill &>/dev/null; then
    rfkill block bluetooth 2>/dev/null || true
fi
# Disable Wi-Fi power management (prevents random network drops)
WIFI_PM_CONF=/etc/NetworkManager/conf.d/99-kiosk-wifi-powersave.conf
cat > "$WIFI_PM_CONF" << 'EOF'
[connection]
wifi.powersave = 2
EOF
log "Wi-Fi power management disabled (prevents network drops)"

# ── 11. SD card wear reduction — reduce unnecessary writes ───────────────────
#   Moves tmp and log dirs to RAM (tmpfs) to reduce SD card writes.
#   Uncomment if you want this — be aware logs won't survive a reboot.
# if ! grep -q "tmpfs /tmp" /etc/fstab; then
#     echo "tmpfs /tmp  tmpfs defaults,noatime,nosuid,size=64m 0 0" >> /etc/fstab
#     echo "tmpfs /var/tmp tmpfs defaults,noatime,nosuid,size=16m 0 0" >> /etc/fstab
#     log "tmpfs mounts added for /tmp and /var/tmp (SD card wear reduction)"
# fi

# ── 12. Set correct ownership ─────────────────────────────────────────────────
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"
log "Ownership set for $KIOSK_HOME/.config"

# ── 13. Shutdown + RTC wake script ───────────────────────────────────────────
SHUTDOWN_MINUTE_PAD=$(printf '%02d' $SHUTDOWN_MINUTE)
WAKE_MINUTE_PAD=$(printf '%02d' $WAKE_MINUTE)

cat > /usr/local/bin/kiosk-shutdown.sh << SCRIPT
#!/bin/bash
# =============================================================================
#  kiosk-shutdown.sh — Scheduled shutdown with RTC wake alarm
#  Called at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD} daily by cron.
#  Sets the RTC alarm to wake the Pi at ${WAKE_HOUR}:${WAKE_MINUTE_PAD}.
# =============================================================================

WAKE_HOUR=${WAKE_HOUR}
WAKE_MINUTE=${WAKE_MINUTE}
RTC_DEVICE=/sys/class/rtc/rtc0/wakealarm

echo "[\$(date)] Preparing shutdown — RTC wake set for \${WAKE_HOUR}:\$(printf '%02d' \$WAKE_MINUTE)..." \
    | tee -a /var/log/kiosk.log

# ── Calculate wake epoch ──────────────────────────────────────────────────────
WAKE_TIME_STR="\${WAKE_HOUR}:\$(printf '%02d' \$WAKE_MINUTE):00"
NOW=\$(date +%s)
TODAY_WAKE=\$(date -d "today \${WAKE_TIME_STR}" +%s)
TOMORROW_WAKE=\$(date -d "tomorrow \${WAKE_TIME_STR}" +%s)

# Always wake tomorrow if we're past today's wake time
if [ "\$NOW" -ge "\$TODAY_WAKE" ]; then
    WAKE_EPOCH=\$TOMORROW_WAKE
else
    WAKE_EPOCH=\$TODAY_WAKE
fi

WAKE_DATE=\$(date -d "@\$WAKE_EPOCH" '+%A %Y-%m-%d %H:%M:%S')
echo "[\$(date)] RTC alarm → \$WAKE_DATE" | tee -a /var/log/kiosk.log

# ── Set RTC alarm ─────────────────────────────────────────────────────────────
if [[ -w "\$RTC_DEVICE" ]]; then
    echo 0 > "\$RTC_DEVICE"              # clear any existing alarm
    echo "\$WAKE_EPOCH" > "\$RTC_DEVICE"
    echo "[\$(date)] Alarm written via sysfs (\$RTC_DEVICE)" | tee -a /var/log/kiosk.log
elif command -v rtcwake &>/dev/null; then
    rtcwake -m no -t "\$WAKE_EPOCH"
    echo "[\$(date)] Alarm set via rtcwake" | tee -a /var/log/kiosk.log
else
    echo "[\$(date)] ERROR: Cannot set RTC alarm — no sysfs or rtcwake found." | tee -a /var/log/kiosk.log
    exit 1
fi

# ── Sync filesystem and shut down ────────────────────────────────────────────
sync
echo "[\$(date)] Shutting down. Good night!" | tee -a /var/log/kiosk.log
/sbin/shutdown -h now
SCRIPT

chmod +x /usr/local/bin/kiosk-shutdown.sh
log "Shutdown script → /usr/local/bin/kiosk-shutdown.sh"

# ── 14. Cron job for nightly shutdown ────────────────────────────────────────
CRON_EXPR="$SHUTDOWN_MINUTE $SHUTDOWN_HOUR * * *"
CRON_JOB="$CRON_EXPR /usr/local/bin/kiosk-shutdown.sh >> /var/log/kiosk.log 2>&1"
( crontab -l 2>/dev/null | grep -v "kiosk-shutdown"; echo "$CRON_JOB" ) | crontab -
log "Cron job: shutdown daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"

# ── 15. Log rotation ──────────────────────────────────────────────────────────
cat > /etc/logrotate.d/kiosk << 'EOF'
/var/log/kiosk.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
log "Log rotation: /var/log/kiosk.log (weekly, 4 weeks)"

# ── 16. Write install marker (enables --update-url mode) ─────────────────────
cat > "$INSTALL_MARKER" << EOF
# Kiosk install marker — do not delete
INSTALLED=$(date '+%Y-%m-%d %H:%M:%S')
USER=$KIOSK_USER
URL=$KIOSK_URL
SHUTDOWN=${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}
WAKE=${WAKE_HOUR}:${WAKE_MINUTE_PAD}
EOF
log "Install marker written to $INSTALL_MARKER"

# =============================================================================
#  Done
# =============================================================================
echo ""
hr
echo -e "${GREEN}  Setup Complete!${NC}"
hr
echo ""
echo -e "  ${CYAN}Kiosk URL    :${NC} $KIOSK_URL"
echo -e "  ${CYAN}Kiosk user   :${NC} $KIOSK_USER"
echo -e "  ${CYAN}Compositor   :${NC} Wayland + labwc"
echo -e "  ${CYAN}Dark mode    :${NC} Forced (OS + Chromium)"
echo -e "  ${CYAN}Shutdown     :${NC} Daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD} (cron)"
echo -e "  ${CYAN}Wake         :${NC} Daily at ${WAKE_HOUR}:${WAKE_MINUTE_PAD} (RTC alarm)"
echo -e "  ${CYAN}Watchdog     :${NC} Hardware (15s) + Chromium crash (auto-restart)"
echo -e "  ${CYAN}Logs         :${NC} /var/log/kiosk.log"
echo ""
warn "Before relying on RTC wake, verify your hardware clock is synced:"
echo "    sudo hwclock -r             # read hardware clock"
echo "    sudo hwclock --systohc      # sync system time → RTC"
echo ""
info "To update the URL without reinstalling:"
echo "    sudo bash $0 --update-url https://new-url.com"
echo ""
info "To rotate the display, set DISPLAY_TRANSFORM in this script"
echo "    then re-run, or uncomment the wlr-randr line in:"
echo "    $LABWC_DIR/autostart"
echo ""
warn "Reboot to start the kiosk:"
echo "    sudo reboot"
echo ""
