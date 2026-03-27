#!/bin/bash
# =============================================================================
#  kiosk-setup.sh — Wall Panel Kiosk for Raspberry Pi
# =============================================================================
#  Supported hardware:
#    Tier 1 (Recommended) : Pi 4, Pi 4B, Pi 400, CM4, Pi 5
#    Tier 2 (Capable)     : Pi 3, Pi 3A+, Pi 3B+, Pi Zero 2W
#    Tier 3 (Limited)     : Pi 2
#    Tier 4 (Not advised) : Pi Zero, Pi Zero W, Pi 1 (A, B, B+)
#
#  Supported OS:
#    Trixie   (Debian 13) — Wayland + labwc        [recommended]
#    Bookworm (Debian 12) — X11 + LXDE             [supported]
#    Bullseye (Debian 11) — X11 + LXDE             [supported, some limits]
#    Buster   (Debian 10) — X11                    [best-effort, not advised]
#    Older                — X11 best-effort        [warn + prompt to continue]
#
#  USAGE:
#    Full install:
#      sudo bash kiosk-setup.sh https://your-dashboard.com
#
#    Wipe existing kiosk config and reinstall fresh:
#      sudo bash kiosk-setup.sh --reset https://your-dashboard.com
#
#    Wipe ALL user data and non-essential packages, reinstall from scratch:
#      sudo bash kiosk-setup.sh --factory-reset https://your-dashboard.com
#
#    Update displayed URL (no reinstall):
#      sudo bash kiosk-setup.sh --update-url https://new-url.com
#
#    Update HA long-lived access token (no reinstall):
#      sudo bash kiosk-setup.sh --set-token YOUR_TOKEN
#
#    Enable RTC shutdown/wake after adding hardware:
#      sudo bash kiosk-setup.sh --enable-rtc
#
#    Update the browser_mod Browser ID (no reinstall):
#      sudo bash kiosk-setup.sh --set-browser-id kiosk-living-room
#
#  NOTE: Flags must be run one at a time. They cannot be combined on one line.
#    Correct:   sudo bash kiosk-setup.sh --factory-reset https://your-url.com
#               sudo bash kiosk-setup.sh --set-token YOUR_TOKEN
#    Incorrect: sudo bash kiosk-setup.sh --factory-reset --set-token TOKEN https://url
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
# true  = install + enable OSK (wvkbd on Trixie, onboard on Bookworm/Bullseye)
# false = disabled (default — most dashboards need no text entry)
ENABLE_OSK=false

# Display rotation: normal | 90 | 180 | 270  (Trixie/Wayland only)
DISPLAY_TRANSFORM="normal"

# Wayland output name — run `wlr-randr` after boot to find yours
# Common: HDMI-A-1, HDMI-A-2, DSI-1 (official Pi touchscreen)
DISPLAY_OUTPUT="HDMI-A-1"

# Auto-reload page every N seconds (0 = disabled)
AUTO_RELOAD_SECONDS=0

# Remove desktop bloat packages that serve no purpose on a kiosk
# (Wolfram/Mathematica, LibreOffice, Scratch, Sonic Pi, Thonny, games, etc.)
# true  = remove them during install (saves 1-3GB+ on a full desktop image)
# false = leave them untouched
REMOVE_BLOAT=true

# Install the display brightness/power HTTP API (port 2701 by default)
# Enables Home Assistant to control display brightness and screen on/off.
# Requires: ddcutil (for HDMI DDC/CI monitors) or a sysfs backlight device.
# See ha-display-config.yaml for the matching HA configuration.
ENABLE_DISPLAY_API=false
DISPLAY_API_PORT=2701

# Enable browser_mod (HACS) compatibility.
# browser_mod registers Chromium as a HA device, enabling popups, navigation,
# doorbell alerts, and a software screen-blackout overlay from HA automations.
# IMPORTANT: enabling this removes --incognito and switches to a persistent
# Chromium profile, which is required for browser_mod to retain its device ID
# across restarts. The profile is stored at ~/.config/chromium-kiosk.
ENABLE_BROWSER_MOD=false

# browser_mod Browser ID (pre-seeded into localStorage before Chromium loads).
# Use a short descriptive name: "kiosk-living-room", "kiosk-kitchen", etc.
# It becomes the HA entity ID, e.g. light.browser_mod_kiosk_living_room
# Leave empty to auto-generate a stable UUID from the Pi serial number.
# Update anytime with: sudo bash kiosk-setup.sh --set-browser-id NEW_ID
BROWSER_MOD_ID=""

# Waveshare 10.1DP-CAPLCD display support.
# Set to true if you are using the Waveshare 10.1inch DP CAPLCD display.
# Adds the required HDMI resolution config (1280x800) to /boot/firmware/config.txt
# and confirms that DDC/CI brightness control via ddcutil is the correct method.
WAVESHARE_10DP=false

# =============================================================================
#  HOME ASSISTANT AUTO-LOGIN (optional)
# =============================================================================
# Set HA_AUTO_LOGIN=true to skip the HA login screen automatically.
# Two methods work together as belt-and-suspenders:
#
#  Method 1 - Trusted Networks (recommended, configured on the HA side):
#    Add the YAML block printed at the end of this install to your HA
#    configuration.yaml. HA will then auto-authenticate any request from
#    your local subnet with no credentials stored on the Pi at all.
#
#  Method 2 - Token wrapper page (configured here, Pi side):
#    Set HA_TOKEN to a long-lived access token created in HA.
#    The script generates a local HTML page that injects the token into
#    Chromium's localStorage before redirecting to your dashboard.
#    Create a token: HA -> Profile -> Long-Lived Access Tokens -> Create Token.
#
# Using both methods means auto-login works even if one fails.
# If HA_AUTO_LOGIN=false this entire section is ignored.

HA_AUTO_LOGIN=false

# Full URL of your Home Assistant instance.
# Examples: http://192.168.1.100:8123  or  http://homeassistant.local:8123
HA_URL="http://homeassistant.local:8123"

# Long-lived access token from HA Profile page.
# Leave empty to use Trusted Networks only (no wrapper page generated).
HA_TOKEN=""

# Dashboard path to land on after login.
# Examples: /lovelace/0  /lovelace/kiosk  /dashboard-kiosk
HA_DASHBOARD_PATH="/lovelace/0"

# =============================================================================
#  LOCAL OVERRIDES — kiosk.conf (optional, git-ignored)
# =============================================================================
# Keep your personal settings in kiosk.conf alongside this script.
# It is sourced here, after all defaults, so your values win.
# git pull will never overwrite it.
#
# Quick start:
#   cp kiosk.conf.example kiosk.conf
#   nano kiosk.conf
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/kiosk.conf" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/kiosk.conf"
    echo "[kiosk-setup] Loaded local config: $SCRIPT_DIR/kiosk.conf"
fi

# =============================================================================
#  Internal — do not edit below this line
# =============================================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
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
[[ $EUID -ne 0 ]] && err "Must be run as root. Try: sudo bash $0 [--factory-reset|--reset|--update-url|--set-token|--set-browser-id|--enable-rtc] <args>"
command -v raspi-config &>/dev/null || err "This doesn't look like a Raspberry Pi. Aborting."

# =============================================================================
#  OS DETECTION
# =============================================================================
OS_CODENAME=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null \
    | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo "unknown")
OS_VERSION=$(grep VERSION_ID /etc/os-release 2>/dev/null \
    | cut -d= -f2 | tr -d '"' || echo "?")
OS_PRETTY=$(grep PRETTY_NAME /etc/os-release 2>/dev/null \
    | cut -d= -f2 | tr -d '"' || echo "Unknown OS")

# OS tier flags
IS_TRIXIE=false; IS_BOOKWORM=false; IS_BULLSEYE=false
IS_BUSTER=false; IS_LEGACY=false; OS_UNSUPPORTED=false

case "$OS_CODENAME" in
    trixie)
        IS_TRIXIE=true
        COMPOSITOR="Wayland + labwc"
        CHROMIUM_PKG="chromium"
        OSK_PKG="wvkbd"
        OS_SUPPORT_LEVEL="recommended"
        ;;
    bookworm)
        IS_BOOKWORM=true
        COMPOSITOR="X11 + LXDE"
        CHROMIUM_PKG="chromium-browser"
        OSK_PKG="onboard"
        OS_SUPPORT_LEVEL="supported"
        ;;
    bullseye)
        IS_BULLSEYE=true
        COMPOSITOR="X11 + LXDE"
        # On Bullseye the package is chromium-browser, but on some builds it
        # may be just 'chromium'. We probe and fall back gracefully.
        if apt-cache show chromium-browser &>/dev/null 2>&1; then
            CHROMIUM_PKG="chromium-browser"
        else
            CHROMIUM_PKG="chromium"
        fi
        OSK_PKG="onboard"
        OS_SUPPORT_LEVEL="supported (some limitations — see notes)"
        ;;
    buster)
        IS_BUSTER=true
        COMPOSITOR="X11 (basic)"
        CHROMIUM_PKG="chromium-browser"
        OSK_PKG="onboard"
        OS_SUPPORT_LEVEL="best-effort (Buster is EOL — upgrade advised)"
        OS_UNSUPPORTED=true
        ;;
    stretch|jessie|wheezy|*)
        IS_LEGACY=true
        COMPOSITOR="X11 (basic)"
        CHROMIUM_PKG="chromium-browser"
        OSK_PKG="onboard"
        OS_SUPPORT_LEVEL="unsupported (too old — upgrade strongly advised)"
        OS_UNSUPPORTED=true
        ;;
esac

# Trixie is only usable on ARMv8 — guard checked after Pi detection below.
# Bullseye lacks Wayland/labwc — force X11 path even if someone tries Trixie
# flags manually.
if $IS_BULLSEYE || $IS_BUSTER || $IS_LEGACY; then
    IS_TRIXIE=false  # never use Wayland path on these releases
fi

# =============================================================================
#  PI MODEL DETECTION
# =============================================================================
PI_MODEL_RAW=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")
PI_RAM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
PI_RAM_MB=$((PI_RAM_KB / 1024))
CPU_ARCH=$(uname -m)  # armv6l | armv7l | aarch64

# Normalise model string → PI_GEN and PI_TIER
# Tier 1 = Pi 4+/5 (recommended)
# Tier 2 = Pi 3 / Zero 2W (capable)
# Tier 3 = Pi 2 (limited)
# Tier 4 = Pi Zero / Pi 1 (not advised)
PI_GEN=0
PI_TIER=0
PI_VARIANT=""
HAS_BUILTIN_RTC=false
HAS_HW_WATCHDOG=true   # most Pi models have some watchdog; overridden below
WATCHDOG_MODULE=""

case "$PI_MODEL_RAW" in
    *"Raspberry Pi 5"*)
        PI_GEN=5; PI_TIER=1; PI_VARIANT="Pi 5"
        HAS_BUILTIN_RTC=true
        WATCHDOG_MODULE=""  # Pi 5 watchdog is built-in, no module needed
        ;;
    *"Raspberry Pi 4"* | *"Raspberry Pi 400"* | *"Compute Module 4"*)
        PI_GEN=4; PI_TIER=1
        [[ "$PI_MODEL_RAW" == *"400"* ]] && PI_VARIANT="Pi 400" \
            || PI_VARIANT="Pi 4"
        [[ "$PI_MODEL_RAW" == *"Compute Module"* ]] && PI_VARIANT="CM4"
        WATCHDOG_MODULE="bcm2835_wdt"
        ;;
    *"Raspberry Pi 3"* | *"Compute Module 3"*)
        PI_GEN=3; PI_TIER=2; PI_VARIANT="Pi 3"
        [[ "$PI_MODEL_RAW" == *"3 Model A"* ]] && PI_VARIANT="Pi 3A+"
        [[ "$PI_MODEL_RAW" == *"3 Model B+"* ]] && PI_VARIANT="Pi 3B+"
        [[ "$PI_MODEL_RAW" == *"Compute Module"* ]] && PI_VARIANT="CM3"
        WATCHDOG_MODULE="bcm2835_wdt"
        ;;
    *"Raspberry Pi Zero 2"*)
        PI_GEN=0; PI_TIER=2; PI_VARIANT="Pi Zero 2W"
        WATCHDOG_MODULE="bcm2835_wdt"
        ;;
    *"Raspberry Pi 2"*)
        PI_GEN=2; PI_TIER=3; PI_VARIANT="Pi 2"
        WATCHDOG_MODULE="bcm2835_wdt"
        ;;
    *"Raspberry Pi Zero W"* | *"Raspberry Pi Zero"*)
        PI_GEN=0; PI_TIER=4
        [[ "$PI_MODEL_RAW" == *"Zero W"* ]] && PI_VARIANT="Pi Zero W" \
            || PI_VARIANT="Pi Zero"
        HAS_HW_WATCHDOG=false
        ;;
    *"Raspberry Pi Model"* | *"Raspberry Pi 1"* | *"Raspberry Pi Compute Module"*)
        PI_GEN=1; PI_TIER=4; PI_VARIANT="Pi 1"
        HAS_HW_WATCHDOG=false
        ;;
    *)
        PI_GEN=0; PI_TIER=2; PI_VARIANT="Unknown Pi"
        warn "Unrecognised Pi model: '$PI_MODEL_RAW'"
        warn "Treating as Tier 2 (Pi 3 / Zero 2W). Review output carefully."
        WATCHDOG_MODULE="bcm2835_wdt"
        ;;
esac

# ARMv6 CPUs (Pi Zero, Pi 1) cannot run Trixie/Wayland at all
if [[ "$CPU_ARCH" == "armv6l" ]] && $IS_TRIXIE; then
    warn "ARMv6 CPU detected — Trixie/Wayland is not supported on this hardware."
    warn "Falling back to X11 path (treating as Bookworm-like)."
    IS_TRIXIE=false; IS_BOOKWORM=true
    COMPOSITOR="X11 (ARMv6 fallback)"
    CHROMIUM_PKG="chromium-browser"
fi

# Trixie is only meaningful on Tier 1-2 hardware; warn on Tier 3+
if $IS_TRIXIE && [[ $PI_TIER -ge 3 ]]; then
    warn "Trixie/Wayland on $PI_VARIANT — Wayland compositor may be unstable."
    warn "If kiosk is unstable, consider Bookworm/X11 instead."
fi

# Chromium memory flags for low-RAM devices (< 1GB)
CHROMIUM_MEMORY_FLAGS=""
if [[ $PI_RAM_MB -lt 1024 ]]; then
    CHROMIUM_MEMORY_FLAGS="--js-flags=--max-old-space-size=128 \
      --renderer-process-limit=1 \
      --single-process \
      --disable-gpu-shader-disk-cache \
      --disk-cache-size=1"
fi

# Autostart path by compositor
if $IS_TRIXIE; then
    AUTOSTART_DIR="$KIOSK_HOME/.config/labwc"
else
    AUTOSTART_DIR="$KIOSK_HOME/.config/lxsession/LXDE-pi"
fi
AUTOSTART_FILE="$AUTOSTART_DIR/autostart"

# =============================================================================
#  RTC DETECTION
# =============================================================================
detect_rtc() {
    local RTC_WAKEALARM="/sys/class/rtc/rtc0/wakealarm"
    RTC_PRESENT=false

    if [[ ! -e "$RTC_WAKEALARM" ]]; then
        RTC_STATUS="No RTC device found at $RTC_WAKEALARM"
        return
    fi
    if ! hwclock -r &>/dev/null; then
        RTC_STATUS="RTC node exists but hwclock failed (module not loaded or clock unset)"
        return
    fi
    if ! echo 0 > "$RTC_WAKEALARM" 2>/dev/null; then
        RTC_STATUS="RTC found but wakealarm is not writable (check i2c/permissions)"
        return
    fi

    RTC_PRESENT=true
    local RTC_CLOCK
    RTC_CLOCK=$(hwclock -r 2>/dev/null || echo "unknown")
    if $HAS_BUILTIN_RTC; then
        RTC_STATUS="Built-in Pi 5 RTC ($RTC_CLOCK)"
    else
        RTC_STATUS="External RTC module ($RTC_CLOCK)"
    fi
}

detect_rtc

# =============================================================================
#  COMPATIBILITY WARNINGS — shown before any changes are made
# =============================================================================
_show_compatibility_warnings() {
    local WARN_COUNT=0

    # Tier 4 hardware warning
    if [[ $PI_TIER -ge 4 ]]; then
        echo ""
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn " LOW-END HARDWARE WARNING: $PI_VARIANT"
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  ${PI_VARIANT} has very limited CPU and RAM (${PI_RAM_MB}MB)."
        echo "  Chromium will run but expect:"
        echo "    - Slow initial page load (30-90 seconds cold)"
        echo "    - High memory pressure — complex pages may crash"
        echo "    - Possible compositor glitches"
        echo "    - No hardware watchdog support"
        echo ""
        echo "  Recommended alternatives:"
        echo "    - Use a Pi Zero 2W, Pi 3B+, Pi 4, or Pi 5 instead"
        echo "    - Or use a lightweight browser like surf or midori"
        echo ""
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    # Tier 3 hardware warning
    if [[ $PI_TIER -eq 3 ]]; then
        echo ""
        warn "Pi 2 detected (${PI_RAM_MB}MB RAM) — performance will be limited."
        echo "  Memory flags will be applied to Chromium automatically."
        echo "  Avoid pages with heavy JavaScript or large media."
        echo ""
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    # Low RAM warning (Zero 2W, Pi 3 with 512MB)
    if [[ $PI_TIER -le 2 && $PI_RAM_MB -lt 1024 ]]; then
        warn "${PI_VARIANT} has only ${PI_RAM_MB}MB RAM — memory-saving Chromium flags applied."
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    # Unsupported OS warning
    if $OS_UNSUPPORTED; then
        echo ""
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        warn " UNSUPPORTED OS: $OS_PRETTY"
        warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        if $IS_BUSTER; then
            echo "  Buster (Debian 10) reached end-of-life in June 2024."
            echo "  Security updates are no longer provided."
            echo "  The script will attempt a best-effort X11 install."
            echo "  Some features (dark mode, OSK) may not work correctly."
        else
            echo "  $OS_PRETTY is too old for full support."
            echo "  The script will attempt a best-effort X11 install."
            echo "  Many features may not work. Upgrade your OS."
        fi
        echo ""
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    # Bullseye limitations
    if $IS_BULLSEYE; then
        info "Bullseye note: Wayland/labwc not available — X11 path will be used."
        info "Bullseye note: Dark mode support is limited (GTK theme only, no portal)."
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    # Prompt to continue if any serious warnings
    if [[ $WARN_COUNT -gt 0 ]] && ( $OS_UNSUPPORTED || [[ $PI_TIER -ge 4 ]] ); then
        echo ""
        read -r -p "$(echo -e "${YELLOW}[!]${NC} Warnings above may affect stability. Continue anyway? [y/N] ")" REPLY
        [[ "${REPLY,,}" =~ ^y ]] || { echo "Aborting."; exit 0; }
        echo ""
    fi
}

# =============================================================================
#  --enable-rtc
# =============================================================================
if [[ "$1" == "--enable-rtc" ]]; then
    hr; banner "  Enable RTC Shutdown/Wake"; hr; echo ""
    [[ ! -f "$INSTALL_MARKER" ]] && err "Kiosk not yet installed. Run a full install first."

    detect_rtc
    if ! $RTC_PRESENT; then
        echo ""
        warn "RTC hardware still not detected:"
        echo "    $RTC_STATUS"
        echo ""
        if $HAS_BUILTIN_RTC; then
            echo "  Pi 5 built-in RTC checklist:"
            echo "    1. Ensure a CR2032 battery is seated in the board header (J5)"
            echo "    2. Run:  sudo hwclock --systohc"
            echo "    3. Reboot, then re-run this command"
        else
            echo "  External RTC checklist (e.g. DS3231):"
            echo "    1. Check wiring: SDA→GPIO2, SCL→GPIO3, VCC→3.3V, GND→GND"
            echo "    2. Ensure /boot/firmware/config.txt contains:"
            echo "         dtoverlay=i2c-rtc,ds3231"
            echo "    3. Reboot, then run:  sudo hwclock --systohc"
            echo "    4. Re-run:  sudo bash $0 --enable-rtc"
        fi
        echo ""
        exit 1
    fi

    log "RTC detected: $RTC_STATUS"
    _write_shutdown_script
    CRON_JOB="$SHUTDOWN_MINUTE $SHUTDOWN_HOUR * * * /usr/local/bin/kiosk-shutdown.sh >> $KIOSK_HOME/kiosk.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v "kiosk-shutdown"; echo "$CRON_JOB" ) | crontab -
    log "Cron job installed: shutdown daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"
    sed -i "s/^RTC_ENABLED=.*/RTC_ENABLED=true/" "$INSTALL_MARKER"

    echo ""
    log "Scheduled shutdown + RTC wake are now active."
    info "  Shutdown : daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"
    info "  Wake     : daily at ${WAKE_HOUR}:${WAKE_MINUTE_PAD}"
    echo ""
    warn "Sync your hardware clock if you haven't already:"
    echo "    sudo hwclock --systohc"
    echo ""
    exit 0
fi

# =============================================================================
#  --update-url
# =============================================================================
if [[ "$1" == "--update-url" ]]; then
    UPDATE_URL="${2:-}"
    [[ -z "$UPDATE_URL" ]]          && err "Usage: sudo bash $0 --update-url https://new-url.com"
    [[ ! -f "$INSTALL_MARKER" ]]    && err "Kiosk not yet installed. Run a full install first."
    [[ ! -f "$AUTOSTART_FILE" ]]    && err "Autostart file not found at $AUTOSTART_FILE"

    hr; banner "  Kiosk URL Update"; hr; echo ""
    info "New URL → $UPDATE_URL"
    sed -i "s|^  KIOSK_URL_VALUE=.*|  KIOSK_URL_VALUE=$UPDATE_URL|" "$AUTOSTART_FILE"
    sed -i "s|^URL=.*|URL=$UPDATE_URL|" "$INSTALL_MARKER"
    log "URL updated in $AUTOSTART_FILE"
    echo ""
    warn "Reboot to apply:  sudo reboot"
    echo "  — or kill Chromium (watchdog relaunches it automatically):"
    echo "      sudo pkill chromium"
    echo ""
    exit 0
fi

# =============================================================================
#  --set-token — update the HA long-lived access token without reinstalling
# =============================================================================
if [[ "$1" == "--set-token" ]]; then
    NEW_TOKEN="${2:-}"
    [[ -z "$NEW_TOKEN" ]]        && err "Usage: sudo bash $0 --set-token YOUR_LONG_LIVED_TOKEN"
    [[ ! -f "$INSTALL_MARKER" ]] && err "Kiosk not yet installed. Run a full install first."

    # Check HA auto-login was enabled during install
    if ! grep -q "^HA_AUTO_LOGIN=true" "$INSTALL_MARKER" 2>/dev/null; then
        err "HA auto-login was not enabled during install. Re-run the full install with HA_AUTO_LOGIN=true."
    fi

    WRAPPER="$KIOSK_HOME/kiosk-ha-login.html"
    [[ ! -f "$WRAPPER" ]] && err "Wrapper page not found at $WRAPPER. Re-run the full install with HA_AUTO_LOGIN=true and a token set."

    hr; banner "  HA Token Update"; hr; echo ""
    info "Updating long-lived access token in: $WRAPPER"

    # Replace the TOKEN assignment line inside the wrapper page JS
    sed -i "s|var TOKEN     = \".*\";|var TOKEN     = \"$NEW_TOKEN\";|" "$WRAPPER"

    if grep -q "$NEW_TOKEN" "$WRAPPER"; then
        log "Token updated successfully"
    else
        err "Token replacement failed — check $WRAPPER manually."
    fi

    echo ""
    echo ""
    warn "If HA is on a different machine, recopy the updated wrapper page:"
    echo "    cat $WRAPPER   # copy the output into HA File Editor"
    echo "    at: /config/www/kiosk-ha-login.html"
    echo ""
    warn "Restart Chromium to apply (watchdog relaunches automatically):"
    echo "    sudo pkill chromium"
    echo "  — or reboot:"
    echo "    sudo reboot"
    echo ""
    exit 0
fi

# =============================================================================
#  --set-browser-id -- update the browser_mod Browser ID without reinstalling
# =============================================================================
_write_bmod_preloader() {
    local BM_ID="$1"
    local WRAPPER="$KIOSK_HOME/kiosk-ha-login.html"
    # If no HA wrapper exists, update the autostart URL to point to a
    # standalone pre-loader that seeds the ID then redirects to the dashboard.
    local PRELOADER="$KIOSK_HOME/kiosk-bmod-preloader.html"
    # Preloader not needed — ?BrowserID= param handles ID via URL directly.
    # Just update the BROWSER_MOD_ID in the HA wrapper page and restart.
    # This function is kept for backward compatibility but no longer writes
    # a file:// preloader since that approach was broken (wrong localStorage
    # key, wrong origin). The --set-browser-id handler now updates the
    # wrapper page directly.
    log "Preloader not used — ?BrowserID= handles ID via URL parameter"
}

if [[ "$1" == "--set-browser-id" ]]; then
    NEW_BM_ID="${2:-}"
    [[ -z "$NEW_BM_ID" ]]        && err "Usage: sudo bash $0 --set-browser-id YOUR_BROWSER_ID"
    [[ ! -f "$INSTALL_MARKER" ]] && err "Kiosk not yet installed. Run a full install first."

    if ! grep -q "^BROWSER_MOD=true" "$INSTALL_MARKER" 2>/dev/null; then
        err "browser_mod was not enabled during install. Re-run with ENABLE_BROWSER_MOD=true."
    fi

    WRAPPER="$KIOSK_HOME/kiosk-ha-login.html"
    PRELOADER="$KIOSK_HOME/kiosk-bmod-preloader.html"
    BM_ID_FILE="/etc/kiosk-browser-mod-id"

    hr; banner "  browser_mod Browser ID Update"; hr; echo ""
    info "New Browser ID : $NEW_BM_ID"

    # Update BROWSER_MOD_ID in wrapper page JS (uses ?BrowserID= URL param)
    if [[ -f "$WRAPPER" ]]; then
        sed -i "s|var BROWSER_MOD_ID = \".*\";|var BROWSER_MOD_ID = \"$NEW_BM_ID\";|" "$WRAPPER"
        log "Updated BROWSER_MOD_ID in wrapper: $WRAPPER"

        # Re-copy updated wrapper to HA www folder
        for HA_CFG_DIR in /config /root/config /home/homeassistant/.homeassistant /usr/share/hassio/homeassistant; do
            if [[ -d "$HA_CFG_DIR/www" ]]; then
                cp "$WRAPPER" "$HA_CFG_DIR/www/kiosk-ha-login.html" 2>/dev/null && {
                    log "Updated wrapper copied to HA: $HA_CFG_DIR/www/kiosk-ha-login.html"
                    break
                }
            fi
        done

        echo ""
        warn "If HA is on a different machine, re-copy the wrapper page:"
        echo "    cp $WRAPPER <HA_CONFIG>/www/kiosk-ha-login.html"
        echo "    Accessible at: $HA_URL/local/kiosk-ha-login.html"
    else
        warn "No wrapper page found. Re-run a full install with ENABLE_BROWSER_MOD=true."
    fi

    # Persist to dedicated file and install marker
    echo "$NEW_BM_ID" > "$BM_ID_FILE"
    chmod 644 "$BM_ID_FILE"
    if grep -q "^BROWSER_MOD_ID=" "$INSTALL_MARKER"; then
        sed -i "s|^BROWSER_MOD_ID=.*|BROWSER_MOD_ID=$NEW_BM_ID|" "$INSTALL_MARKER"
    else
        echo "BROWSER_MOD_ID=$NEW_BM_ID" >> "$INSTALL_MARKER"
    fi
    log "Browser ID stored in $BM_ID_FILE"

    echo ""
    warn "Restart Chromium to apply (watchdog relaunches automatically):"
    echo "    sudo pkill chromium"
    echo ""
    info "HA entity IDs for this kiosk:"
    echo "    light.browser_mod_$(echo "$NEW_BM_ID" | tr '-' '_')"
    echo "    media_player.browser_mod_$(echo "$NEW_BM_ID" | tr '-' '_')"
    echo ""
    info "To retrieve the stored ID later:"
    echo "    cat /etc/kiosk-browser-mod-id"
    echo "    grep BROWSER_MOD_ID /etc/kiosk-installed"
    echo ""
    exit 0
fi

# =============================================================================
#  --factory-reset — strip device to bare minimum, wipe all user data, reinstall
# =============================================================================
# SAFE CONSTRAINTS (since Pi may be wall-mounted with no physical SD access):
#   ✓ SSH daemon, authorised keys, and sshd_config are NEVER touched
#   ✓ Network config (NetworkManager, wpa_supplicant, dhcpcd) is NEVER touched
#   ✓ /boot/firmware/config.txt is NEVER touched
#   ✓ sudo access is NEVER touched
#   Everything else is fair game.
# =============================================================================
#  --reset — wipe all kiosk config and start fresh
# =============================================================================
_reset_kiosk() {
    local TARGET_USER="$1"
    local SKIP_CONFIRM="${2:-}"
    local SKIP_PACKAGES="${3:-}"
    local TARGET_HOME="/home/$TARGET_USER"
    local TARGET_USER="$1"
    local TARGET_HOME="/home/$TARGET_USER"

    if [[ "$SKIP_CONFIRM" != "--skip-confirm" ]]; then
        hr; banner "  Kiosk Reset — Removing All Configuration"; hr; echo ""
        warn "This will remove ALL kiosk configuration for user: $TARGET_USER"
        warn "Log file ($KIOSK_HOME/kiosk.log) will be preserved."
        echo ""
        read -r -p "$(echo -e "${RED}[!]${NC} Are you sure you want to wipe the kiosk config? [y/N] ")" REPLY
        [[ "${REPLY,,}" =~ ^y ]] || { echo "Reset cancelled."; exit 0; }
        echo ""
    fi

    # ── Autostart files ──────────────────────────────────────────────────
    local LABWC_DIR="$TARGET_HOME/.config/labwc"
    local LXDE_DIR="$TARGET_HOME/.config/lxsession/LXDE-pi"
    local PCMANFM_DIR="$TARGET_HOME/.config/pcmanfm/LXDE-pi"

    for f in         "$LABWC_DIR/autostart"         "$LABWC_DIR/environment"         "$LABWC_DIR/rc.xml"         "$LXDE_DIR/autostart"         "$PCMANFM_DIR/desktop-items-0.conf"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            log "Removed: $f"
        fi
    done

    # ── GTK theme settings ───────────────────────────────────────────────
    for f in         "$TARGET_HOME/.config/gtk-3.0/settings.ini"         "$TARGET_HOME/.config/gtk-4.0/settings.ini"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            log "Removed: $f"
        fi
    done

    # ── Systemd user service ───────────────────────────────────────────
    local INHIBIT_SVC="$TARGET_HOME/.config/systemd/user/kiosk-inhibit.service"
    if [[ -f "$INHIBIT_SVC" ]]; then
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")"             systemctl --user disable kiosk-inhibit.service 2>/dev/null || true
        rm -f "$INHIBIT_SVC"
        log "Removed and disabled: kiosk-inhibit.service"
    fi

    # ── HA wrapper + browser_mod preloader pages ─────────────────────────────
    for f in         "$TARGET_HOME/kiosk-ha-login.html"         "$TARGET_HOME/kiosk-bmod-preloader.html"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            log "Removed: $f"
        fi
    done

    # ── browser_mod ID file + Chromium persistent profile ───────────────────
    [[ -f /etc/kiosk-browser-mod-id ]] && rm -f /etc/kiosk-browser-mod-id         && log "Removed: /etc/kiosk-browser-mod-id"
    if [[ -d "$TARGET_HOME/.config/chromium-kiosk" ]]; then
        rm -rf "$TARGET_HOME/.config/chromium-kiosk"
        log "Removed: ~/.config/chromium-kiosk (browser_mod persistent profile)"
    fi

    # ── Display API ────────────────────────────────────────────────────────────────
    for f in         /usr/local/bin/kiosk-display-api.py         /etc/kiosk-display.conf         /etc/systemd/system/kiosk-display-api.service         /etc/logrotate.d/kiosk-display; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            log "Removed: $f"
        fi
    done
    systemctl disable kiosk-display-api.service 2>/dev/null || true
    systemctl stop    kiosk-display-api.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    # ── Xorg blanking config ──────────────────────────────────────────────
    if [[ -f /etc/X11/xorg.conf.d/10-kiosk-blanking.conf ]]; then
        rm -f /etc/X11/xorg.conf.d/10-kiosk-blanking.conf
        log "Removed: /etc/X11/xorg.conf.d/10-kiosk-blanking.conf"
    fi

    # ── Wi-Fi power-save config ────────────────────────────────────────────
    if [[ -f /etc/NetworkManager/conf.d/99-kiosk-wifi-powersave.conf ]]; then
        rm -f /etc/NetworkManager/conf.d/99-kiosk-wifi-powersave.conf
        log "Removed: 99-kiosk-wifi-powersave.conf"
    fi

    # ── Shutdown script ───────────────────────────────────────────────────────
    if [[ -f /usr/local/bin/kiosk-shutdown.sh ]]; then
        rm -f /usr/local/bin/kiosk-shutdown.sh
        log "Removed: /usr/local/bin/kiosk-shutdown.sh"
    fi

    # ── Cron job ───────────────────────────────────────────────────────────────
    ( crontab -l 2>/dev/null | grep -v "kiosk-shutdown" ) | crontab - 2>/dev/null || true
    log "Cron job removed"

    # ── Log rotation config ─────────────────────────────────────────────────
    if [[ -f /etc/logrotate.d/kiosk ]]; then
        rm -f /etc/logrotate.d/kiosk
        log "Removed: /etc/logrotate.d/kiosk"
    fi

    # ── Hardware watchdog entries ───────────────────────────────────────────
    if grep -q "Kiosk hardware watchdog" /etc/systemd/system.conf 2>/dev/null; then
        sed -i '/# Kiosk hardware watchdog/,/ShutdownWatchdogSec=2min/d' /etc/systemd/system.conf
        log "Removed: hardware watchdog entries from system.conf"
    fi

    # ── LightDM autologin ────────────────────────────────────────────────────
    local LIGHTDM_CONF=/etc/lightdm/lightdm.conf
    if [[ -f "$LIGHTDM_CONF" ]]; then
        sed -i "/^\[Seat:\*\]/,/^\[/ s/^autologin-user=.*/#autologin-user=/" "$LIGHTDM_CONF"
        sed -i "/^\[Seat:\*\]/,/^\[/ s/^autologin-user-timeout=.*/#autologin-user-timeout=/" "$LIGHTDM_CONF"
        sed -i "/^\[Seat:\*\]/,/^\[/ s/^autologin-session=.*/#autologin-session=/" "$LIGHTDM_CONF"
        log "LightDM autologin disabled"
    fi

    # ── Kiosk-installed packages ───────────────────────────────────────────────
    if [[ "$SKIP_PACKAGES" != "--skip-packages" ]]; then
        local PREV_PKGS=""
        if [[ -f /etc/kiosk-installed ]]; then
            PREV_PKGS=$(grep "^INSTALLED_PKGS=" /etc/kiosk-installed | cut -d= -f2-)
        fi

        if [[ -n "$PREV_PKGS" ]]; then
            echo ""
            read -r -p "$(echo -e "${YELLOW}[?]${NC} Remove kiosk packages installed by this script? [Y/n] ")" PKG_REPLY
            if [[ ! "${PKG_REPLY,,}" =~ ^n ]]; then
                log "Removing kiosk packages: $PREV_PKGS"
                REMOVE_LIST=()
                for pkg in $PREV_PKGS; do
                    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && REMOVE_LIST+=("$pkg")
                done
                if [[ ${#REMOVE_LIST[@]} -gt 0 ]]; then
                    apt-get remove -y -qq --purge "${REMOVE_LIST[@]}" 2>/dev/null || true
                    apt-get autoremove -y -qq --purge 2>/dev/null || true
                    apt-get autoclean -qq 2>/dev/null || true
                    log "Packages removed and orphans cleaned up"
                else
                    log "No tracked packages found to remove (already uninstalled)"
                fi
            else
                info "Package removal skipped"
            fi
        else
            info "No package list in install marker — skipping package removal"
            info "(Packages can be removed manually or via apt)"
        fi
    fi

    # ── Install marker ────────────────────────────────────────────────────────
    if [[ -f /etc/kiosk-installed ]]; then
        rm -f /etc/kiosk-installed
        log "Removed: /etc/kiosk-installed"
    fi

    echo ""
    log "Reset complete. All kiosk configuration has been removed."
    info "$KIOSK_HOME/kiosk.log has been preserved."
    echo ""
}

_factory_reset() {
    local TARGET_USER="$1"
    local TARGET_HOME="/home/$TARGET_USER"

    hr
    echo -e "${RED}${BOLD}"
    echo "  ███████████████████████████████████████████████"
    echo "   FACTORY RESET — THIS CANNOT BE UNDONE"
    echo "  ███████████████████████████████████████████████"
    echo -e "${NC}"
    echo "  This will permanently:"
    echo "    • Wipe ALL contents of $TARGET_HOME (except .ssh)"
    echo "    • Remove all kiosk configuration files"
    echo "    • Remove the display API if installed"
    echo "    • Purge kiosk-installed packages and orphaned dependencies"
    echo "    • Purge ALL known desktop/bloat packages aggressively"
    echo "    • Reset LightDM, cron, watchdog, logrotate entries"
    echo ""
    echo "  This will NOT touch:"
    echo "    • SSH daemon, host keys, or authorised_keys"
    echo "    • Network configuration (Wi-Fi, Ethernet)"
    echo "    • Boot config (/boot/firmware/config.txt)"
    echo "    • sudo / PAM configuration"
    echo "    • $KIOSK_HOME/kiosk.log (preserved for diagnostics)"
    echo ""
    warn "The Pi will still be accessible via SSH after this completes."
    echo ""
    echo -e "${RED}  To confirm, type exactly:  FACTORY RESET${NC}"
    read -r -p "  Confirmation: " CONFIRM
    if [[ "$CONFIRM" != "FACTORY RESET" ]]; then
        echo "Confirmation did not match. Aborting."
        exit 0
    fi
    echo ""

    # ── Step 1: Run the standard kiosk reset (removes all config files) ─────────
    log "Step 1/5: Removing kiosk configuration..."
    _reset_kiosk "$TARGET_USER" --skip-confirm --skip-packages

    # ── Step 2: Remove display API files ─────────────────────────────────────
    log "Step 2/5: Removing display API..."
    for f in         /usr/local/bin/kiosk-display-api.py         /etc/kiosk-display.conf         /etc/systemd/system/kiosk-display-api.service         /etc/logrotate.d/kiosk-display; do
        [[ -f "$f" ]] && rm -f "$f" && log "  Removed: $f"
    done
    systemctl disable kiosk-display-api.service 2>/dev/null || true
    systemctl stop    kiosk-display-api.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    # ── Step 3: Wipe user home directory (preserve .ssh) ───────────────────────
    log "Step 3/5: Wiping home directory (preserving .ssh)..."
    if [[ -d "$TARGET_HOME" ]]; then
        # Move .ssh to a temp location
        SSH_TMP=$(mktemp -d)
        [[ -d "$TARGET_HOME/.ssh" ]] && cp -a "$TARGET_HOME/.ssh" "$SSH_TMP/"

        # Wipe everything
        find "$TARGET_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

        # Restore .ssh
        [[ -d "$SSH_TMP/.ssh" ]] && cp -a "$SSH_TMP/.ssh" "$TARGET_HOME/" &&             chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.ssh"
        rm -rf "$SSH_TMP"
        log "  Home directory wiped, .ssh preserved"
    fi

    # ── Step 4: Aggressive package purge ──────────────────────────────────────
    log "Step 4/5: Purging packages..."
    # Everything in BLOAT_PKGS plus additional desktop packages
    FACTORY_EXTRA_PKGS=(
        # Additional IDEs and dev tools not needed on kiosk
        idle3 python3-idle python3-pygame python3-pil
        # Media tools
        vlc vlc-bin vlc-plugin-base vlc-plugin-video-output
        gimp gimp-data audacity
        # Pi-specific extras
        rpi-imager
        # Additional office/productivity
        xpdf evince
        # Unused desktop shell extras
        lxtask lxrandr lxappearance
        # Print system (no printer on a wall panel)
        cups cups-browsed cups-client
        # Bluetooth tools (UI)
        blueman
        # Additional unused services
        avahi-daemon triggerhappy
    )

    ALL_REMOVE=("${BLOAT_PKGS[@]}" "${FACTORY_EXTRA_PKGS[@]}")
    FOUND_PKGS=()
    for pkg in "${ALL_REMOVE[@]}"; do
        dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && FOUND_PKGS+=("$pkg")
    done

    if [[ ${#FOUND_PKGS[@]} -gt 0 ]]; then
        log "  Purging ${#FOUND_PKGS[@]} packages..."
        apt-get remove -y -qq --purge "${FOUND_PKGS[@]}" 2>/dev/null || true
    fi

    # Also remove any previously-installed kiosk packages
    PREV_PKGS=$(grep "^INSTALLED_PKGS=" /etc/kiosk-installed 2>/dev/null | cut -d= -f2- || echo "")
    if [[ -n "$PREV_PKGS" ]]; then
        REMOVE_LIST=()
        for pkg in $PREV_PKGS; do
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" && REMOVE_LIST+=("$pkg")
        done
        [[ ${#REMOVE_LIST[@]} -gt 0 ]] &&             apt-get remove -y -qq --purge "${REMOVE_LIST[@]}" 2>/dev/null || true
    fi

    apt-get autoremove -y -qq --purge 2>/dev/null || true
    apt-get autoclean -qq 2>/dev/null || true
    log "  Package purge complete"

    # ── Step 5: Clean up system state ──────────────────────────────────────────
    log "Step 5/5: Cleaning system state..."
    # Clear systemd failed units
    systemctl reset-failed 2>/dev/null || true
    # Clear thumbnail/cache dirs
    rm -rf /root/.cache /root/.thumbnails 2>/dev/null || true
    # Clear apt lists to free space
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    log "  System state cleaned"

    echo ""
    log "Factory reset complete."
    info "SSH access is intact. Network config is unchanged."
    info "$KIOSK_HOME/kiosk.log preserved."
    echo ""
}

if [[ "$1" == "--factory-reset" ]]; then
    FACTORY_URL="${2:-}"

    # Guard: catch accidental "kiosk-setup.sh --factory-reset --some-flag url" usage
    # where $2 is another flag rather than a URL
    if [[ "$FACTORY_URL" == --* ]]; then
        err "Unexpected argument after --factory-reset: '$FACTORY_URL'\n  --factory-reset only accepts a URL as its second argument.\n  Flags like --set-token cannot be combined on one line.\n\n  Run each step separately:\n    sudo bash $0 --factory-reset https://your-url.com\n    sudo bash $0 --set-token YOUR_TOKEN"
    fi

    _factory_reset "$KIOSK_USER"

    if [[ -n "$FACTORY_URL" ]]; then
        info "URL provided — running fresh kiosk install: $FACTORY_URL"
        KIOSK_URL="$FACTORY_URL"
        echo ""
        # Fall through to full install
    else
        warn "Factory reset done. Run a fresh install when ready:"
        echo "    sudo bash $0 https://your-dashboard.com"
        echo ""
        exit 0
    fi
fi


if [[ "$1" == "--reset" ]]; then
    # Allow URL to be passed alongside --reset for immediate reinstall
    RESET_URL="${2:-}"

    # Guard: catch accidental flag-as-URL usage
    if [[ "$RESET_URL" == --* ]]; then
        err "Unexpected argument after --reset: '$RESET_URL'\n  --reset only accepts a URL as its second argument.\n  Flags cannot be combined on one line.\n\n  Run each step separately:\n    sudo bash $0 --reset https://your-url.com\n    sudo bash $0 --set-token YOUR_TOKEN"
    fi

    _reset_kiosk "$KIOSK_USER"

    if [[ -n "$RESET_URL" ]]; then
        info "URL provided — proceeding with fresh install: $RESET_URL"
        KIOSK_URL="$RESET_URL"
        echo ""
        # Fall through to full install below
    else
        warn "Run a fresh install when ready:"
        echo "    sudo bash $0 https://your-dashboard.com"
        echo ""
        exit 0
    fi
fi

# =============================================================================
#  Full install
# =============================================================================
[[ "$1" != "--reset" && "$1" != "https://"* && "$1" != "http://"* && -n "$1" ]] && \
    err "Unknown argument: '$1'.\n  Flags must be run one at a time — they cannot be combined on one line.\n  e.g.  sudo bash $0 --factory-reset https://your-url.com\n        sudo bash $0 --set-token YOUR_TOKEN"
[[ -z "$1" || "$1" == "--reset" ]] && [[ -z "$RESET_URL" ]] && warn "No URL supplied — defaulting to https://example.com"

# ── Existing install guard ─────────────────────────────────────────────────────
if [[ -f "$INSTALL_MARKER" && "$1" != "--reset" ]]; then
    echo ""
    warn "An existing kiosk install was detected (/etc/kiosk-installed)."
    PREV_URL=$(grep "^URL=" "$INSTALL_MARKER" | cut -d= -f2)
    PREV_DATE=$(grep "^INSTALLED=" "$INSTALL_MARKER" | cut -d= -f2)
    info "  Installed : $PREV_DATE"
    info "  URL       : $PREV_URL"
    echo ""
    echo "  Options:"
    echo "    [r] Reset and reinstall fresh  (sudo bash $0 --reset https://new-url.com)"
    echo "    [u] Update URL only            (sudo bash $0 --update-url https://new-url.com)"
    echo "    [c] Continue anyway and overwrite"
    echo "    [q] Quit"
    echo ""
    read -r -p "$(echo -e "${YELLOW}[?]${NC} Choose [r/u/c/q]: ")" CHOICE
    case "${CHOICE,,}" in
        r)
            echo ""
            _reset_kiosk "$KIOSK_USER"
            info "Continuing with fresh install..."
            echo ""
            ;;
        u)
            echo ""
            info "Run:  sudo bash $0 --update-url https://new-url.com"
            exit 0
            ;;
        c)
            warn "Continuing — existing config will be overwritten."
            echo ""
            ;;
        *)
            echo "Quitting."
            exit 0
            ;;
    esac
fi

hr
banner "  Raspberry Pi Wall Panel Kiosk — Full Install"
hr
echo ""
info "Pi model    : $PI_MODEL_RAW"
info "Pi variant  : $PI_VARIANT (Tier $PI_TIER, ${PI_RAM_MB}MB RAM, $CPU_ARCH)"
info "OS          : $OS_PRETTY"
info "Compositor  : $COMPOSITOR"
info "Support     : $OS_SUPPORT_LEVEL"
info "Kiosk user  : $KIOSK_USER"
info "Kiosk URL   : $KIOSK_URL"
info "OSK         : $([ "$ENABLE_OSK" = true ] && echo "Enabled ($OSK_PKG)" || echo "Disabled")"
if $RTC_PRESENT; then
    info "RTC         : $RTC_STATUS"
    info "Shutdown    : Daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"
    info "Wake        : Daily at ${WAKE_HOUR}:${WAKE_MINUTE_PAD}"
else
    warn "RTC         : NOT DETECTED — $RTC_STATUS"
    warn "Shutdown/wake scheduling will be DISABLED (run --enable-rtc to activate later)"
fi
echo ""

_show_compatibility_warnings

# ── 1. Packages ───────────────────────────────────────────────────────────────
log "Updating package list..."
apt-get update -qq

BASE_PKGS=(util-linux curl)
OSK_PKGS=()
$ENABLE_OSK && OSK_PKGS=("$OSK_PKG")

if $IS_TRIXIE; then
    log "Installing packages (Trixie / Wayland)..."
    INSTALLED_PKGS=("$CHROMIUM_PKG" cage wlr-randr swaybg xdg-utils jq "${BASE_PKGS[@]}" "${OSK_PKGS[@]}")
    apt-get install -y -qq "${INSTALLED_PKGS[@]}"
else
    # X11 path covers Bookworm, Bullseye, Buster, legacy
    log "Installing packages (${OS_CODENAME} / X11)..."
    INSTALLED_PKGS=("$CHROMIUM_PKG" unclutter x11-xserver-utils "${BASE_PKGS[@]}" "${OSK_PKGS[@]}")
    # xdotool only available on Bullseye+
    $IS_BUSTER || $IS_LEGACY || INSTALLED_PKGS+=(xdotool)
    # jq may not be in Buster repos
    apt-cache show jq &>/dev/null && INSTALLED_PKGS+=(jq) || true
    apt-get install -y -qq "${INSTALLED_PKGS[@]}"
fi

# ── 2. GPU overlay ────────────────────────────────────────────────────────────
RASPI_CONFIG_FILE=/boot/firmware/config.txt
# Fallback for older Pi OS that uses /boot/config.txt
[[ ! -f "$RASPI_CONFIG_FILE" ]] && RASPI_CONFIG_FILE=/boot/config.txt

if [[ -f "$RASPI_CONFIG_FILE" ]]; then
    if $IS_TRIXIE; then
        if grep -q "dtoverlay=vc4-fkms-v3d" "$RASPI_CONFIG_FILE"; then
            sed -i 's/dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-kms-v3d/' "$RASPI_CONFIG_FILE"
            log "GPU overlay: fkms → kms (Wayland requires full KMS)"
        else
            log "GPU overlay: vc4-kms-v3d already set"
        fi
    else
        # X11: Pi 4/5/CM4 — kms is fine; Pi 1/2/3/Zero — fkms or legacy driver
        if [[ $PI_GEN -le 3 || $PI_TIER -ge 3 ]]; then
            # Older Pi — ensure fkms or vc4-fkms-v3d for X11 stability
            if grep -q "dtoverlay=vc4-kms-v3d" "$RASPI_CONFIG_FILE" && \
               ! grep -q "dtoverlay=vc4-fkms-v3d" "$RASPI_CONFIG_FILE"; then
                sed -i 's/dtoverlay=vc4-kms-v3d/dtoverlay=vc4-fkms-v3d/' "$RASPI_CONFIG_FILE"
                log "GPU overlay: kms → fkms (X11 stability on $PI_VARIANT)"
            else
                log "GPU overlay: already appropriate for $PI_VARIANT"
            fi
        elif [[ $PI_GEN -eq 5 ]]; then
            log "GPU overlay: Pi 5 uses kms natively — no change needed"
        else
            log "GPU overlay: Pi 4 — kms acceptable for X11"
        fi
    fi
else
    warn "config.txt not found at /boot/firmware/config.txt or /boot/config.txt"
    warn "Skipping GPU overlay configuration — check manually."
fi

# ── 3. Hardware watchdog ──────────────────────────────────────────────────────
if $HAS_HW_WATCHDOG; then
    WATCHDOG_CONF=/etc/systemd/system.conf
    if ! grep -q "^RuntimeWatchdogSec" "$WATCHDOG_CONF" 2>/dev/null; then
        { echo ""; echo "# Kiosk hardware watchdog"
          echo "RuntimeWatchdogSec=15"; echo "ShutdownWatchdogSec=2min"; } >> "$WATCHDOG_CONF"
        log "Hardware watchdog enabled (15s timeout)"
    else
        log "Hardware watchdog already configured"
    fi

    if [[ -n "$WATCHDOG_MODULE" ]]; then
        if ! grep -q "$WATCHDOG_MODULE" /etc/modules 2>/dev/null; then
            echo "$WATCHDOG_MODULE" >> /etc/modules
            modprobe "$WATCHDOG_MODULE" 2>/dev/null || true
            log "Watchdog module loaded: $WATCHDOG_MODULE"
        fi
    fi
else
    warn "No hardware watchdog available on $PI_VARIANT — software-only operation."
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
    warn "lightdm.conf not found — enable autologin via:  sudo raspi-config"
fi

# ── 5. GTK dark theme ─────────────────────────────────────────────────────────
# Adwaita-dark is available on Bookworm, Trixie, and Bullseye.
# On Buster/legacy it may not be present — we apply and log a warning if needed.
for GTK_DIR in "$KIOSK_HOME/.config/gtk-3.0" "$KIOSK_HOME/.config/gtk-4.0"; do
    mkdir -p "$GTK_DIR"
    cat > "$GTK_DIR/settings.ini" << 'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
EOF
done
if $IS_BUSTER || $IS_LEGACY; then
    warn "GTK dark theme set but Adwaita-dark may not be available on $OS_CODENAME."
    warn "Install it with:  sudo apt-get install gnome-themes-extra"
else
    log "GTK dark theme set (gtk-3.0 + gtk-4.0)"
fi

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

    # OSK for Wayland
    $ENABLE_OSK && OSK_LINE="wvkbd-mobintl --hidden --fn 'Noto Sans 16' &" \
                || OSK_LINE="# OSK disabled — set ENABLE_OSK=true in kiosk-setup.sh to enable"

    # Build the Chromium command once, before the heredoc.
    # This is the only reliable way to handle conditional flags — resolve them
    # here in the script where bash is guaranteed, then write one clean line.
    _CHROME_FLAGS="--ozone-platform=wayland"
    _CHROME_FLAGS+=" --enable-features=UseOzonePlatform,WebContentsForceDark"
    _CHROME_FLAGS+=" --force-dark-mode"
    $ENABLE_OSK         && _CHROME_FLAGS+=" --enable-virtual-keyboard"
    $ENABLE_BROWSER_MOD && _CHROME_FLAGS+=" --user-data-dir=$KIOSK_HOME/.config/chromium-kiosk" \
                        || _CHROME_FLAGS+=" --incognito"
    [[ -n "$CHROMIUM_MEMORY_FLAGS" ]] && _CHROME_FLAGS+=" $CHROMIUM_MEMORY_FLAGS"
    _CHROME_FLAGS+=" --kiosk"
    _CHROME_FLAGS+=" --noerrdialogs"
    _CHROME_FLAGS+=" --disable-infobars"
    _CHROME_FLAGS+=" --disable-notifications"
    _CHROME_FLAGS+=" --disable-popup-blocking"
    _CHROME_FLAGS+=" --no-first-run"
    _CHROME_FLAGS+=" --disable-default-apps"
    _CHROME_FLAGS+=" --disable-extensions"
    _CHROME_FLAGS+=" --disable-translate"
    _CHROME_FLAGS+=" --disable-features=TranslateUI,PasswordManagerOnboardingAndroid"
    _CHROME_FLAGS+=" --disable-session-crashed-bubble"
    ! $ENABLE_BROWSER_MOD && _CHROME_FLAGS+=" --disable-restore-session-state"
    _CHROME_FLAGS+=" --disable-save-password-bubble"
    _CHROME_FLAGS+=" --disable-sync"
    _CHROME_FLAGS+=" --disable-background-networking"
    _CHROME_FLAGS+=" --check-for-update-interval=31536000"
    _CHROME_FLAGS+=" --disable-pinch"
    _CHROME_FLAGS+=" --touch-events=enabled"
    _CHROME_FLAGS+=" --disable-features=TouchpadOverscrollHistoryNavigation"
    _CHROME_FLAGS+=" --overscroll-history-navigation=0"
    _CHROME_FLAGS+=" --hide-scrollbars"
    _CHROME_FLAGS+=" --autoplay-policy=no-user-gesture-required"
    CHROMIUM_CMD="chromium $_CHROME_FLAGS"

    # labwc autostart
    cat > "$AUTOSTART_FILE" << AUTOSTART
#!/bin/bash
# ── Kiosk autostart (${OS_CODENAME} / Wayland + labwc) ───────────────────────
# Update URL:  sudo bash kiosk-setup.sh --update-url https://new-url.com

  KIOSK_LOG=$KIOSK_HOME/kiosk.log
  KIOSK_URL_VALUE=$KIOSK_URL

# Black background — first thing rendered, prevents any desktop flash
swaybg -m solid_color -c 000000 &

# On-screen keyboard
$OSK_LINE

# Display rotation
$(if [[ "$DISPLAY_TRANSFORM" != "normal" ]]; then
    echo "wlr-randr --output $DISPLAY_OUTPUT --transform $DISPLAY_TRANSFORM"
else
    echo "# wlr-randr --output $DISPLAY_OUTPUT --transform 90   # uncomment to rotate"
fi)

# Wait up to 30s for URL to be reachable before launching
MAX_WAIT=30; WAITED=0
while ! curl -s --max-time 2 "\$KIOSK_URL_VALUE" > /dev/null 2>&1; do
    sleep 2; WAITED=\$((WAITED + 2))
    [ \$WAITED -ge \$MAX_WAIT ] \
        && echo "[\$(date)] Network wait timeout — launching anyway" >> \$KIOSK_LOG \
        && break
done

$(if [[ $AUTO_RELOAD_SECONDS -gt 0 ]]; then
echo "# Auto-reload every ${AUTO_RELOAD_SECONDS}s"
echo "(while true; do sleep $AUTO_RELOAD_SECONDS; wtype -k F5 2>/dev/null; done) &"
fi)

# Chromium crash watchdog — relaunches on any unexpected exit
while true; do
    echo "[\$(date)] Launching Chromium \$KIOSK_URL_VALUE" >> \$KIOSK_LOG
    $CHROMIUM_CMD "\$KIOSK_URL_VALUE"
    echo "[\$(date)] Chromium exited (\$?) — restarting in 5s..." >> \$KIOSK_LOG
    sleep 5
done &
AUTOSTART
    chmod +x "$AUTOSTART_FILE"
    log "labwc autostart written"

else
    # ── X11 path — Bookworm, Bullseye, Buster, legacy ────────────────────────

    # Xorg blanking config
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

    # OSK for X11
    $ENABLE_OSK && OSK_LINE="@onboard --startup-delay=4 --theme=Blackboard &" \
                || OSK_LINE="# OSK disabled — set ENABLE_OSK=true in kiosk-setup.sh to enable"

    # LXDE autostart
    # Build X11 Chromium flag string before heredoc (same pattern as Wayland)
    _X11_FLAGS="--enable-features=WebContentsForceDark --force-dark-mode"
    $ENABLE_OSK         && _X11_FLAGS+=" --enable-virtual-keyboard"
    $ENABLE_BROWSER_MOD && _X11_FLAGS+=" --user-data-dir=$KIOSK_HOME/.config/chromium-kiosk" \
                        || _X11_FLAGS+=" --incognito"
    [[ -n "$CHROMIUM_MEMORY_FLAGS" ]] && _X11_FLAGS+=" $CHROMIUM_MEMORY_FLAGS"
    _X11_FLAGS+=" --kiosk --noerrdialogs --disable-infobars --disable-notifications"
    _X11_FLAGS+=" --disable-popup-blocking --no-first-run --disable-default-apps"
    _X11_FLAGS+=" --disable-extensions --disable-translate"
    _X11_FLAGS+=" --disable-features=TranslateUI,PasswordManagerOnboardingAndroid"
    _X11_FLAGS+=" --disable-session-crashed-bubble"
    ! $ENABLE_BROWSER_MOD && _X11_FLAGS+=" --disable-restore-session-state"
    _X11_FLAGS+=" --disable-save-password-bubble --disable-sync --disable-background-networking"
    _X11_FLAGS+=" --check-for-update-interval=31536000 --disable-pinch --touch-events=enabled"
    _X11_FLAGS+=" --overscroll-history-navigation=0 --hide-scrollbars --autoplay-policy=no-user-gesture-required"
    X11_CHROMIUM_FLAGS="$_X11_FLAGS"

    cat > "$AUTOSTART_FILE" << AUTOSTART
# ── Kiosk autostart (${OS_CODENAME} / X11 + LXDE) ────────────────────────────
# Update URL:  sudo bash kiosk-setup.sh --update-url https://new-url.com

  KIOSK_URL_VALUE=$KIOSK_URL

# Black root window — before anything else renders
@xsetroot -solid black

# Disable screen saver and DPMS power management
@xset s off
@xset -dpms
@xset s noblank

# Hide mouse cursor after 0.5s idle
@unclutter -idle 0.5 -root

# On-screen keyboard
$OSK_LINE

# Network wait + Chromium crash watchdog
@bash -c '
  KIOSK_URL=\$(grep "KIOSK_URL_VALUE=" "${AUTOSTART_FILE}" | head -1 | sed "s/.*KIOSK_URL_VALUE=//")
  # Build flag string (pre-resolved at install time — no conditionals here)
  X11_CHROMIUM_FLAGS="$X11_CHROMIUM_FLAGS"
  MAX_WAIT=30; WAITED=0
  while ! curl -s --max-time 2 "\$KIOSK_URL" > /dev/null 2>&1; do
    sleep 2; WAITED=\$((WAITED + 2))
    [ \$WAITED -ge \$MAX_WAIT ] \
      && echo "[\$(date)] Network timeout" >> $KIOSK_HOME/kiosk.log \
      && break
  done
  while true; do
    echo "[\$(date)] Launching Chromium \$KIOSK_URL" >> $KIOSK_HOME/kiosk.log
    ${CHROMIUM_PKG} $X11_CHROMIUM_FLAGS "\$KIOSK_URL"
    echo "[\$(date)] Chromium exited (\$?) — restarting in 5s..." >> $KIOSK_HOME/kiosk.log
    sleep 5
  done
'
AUTOSTART
    log "LXDE autostart written"
fi

# ── 7. Wi-Fi power-save off ───────────────────────────────────────────────────
NM_CONF_DIR=/etc/NetworkManager/conf.d
if [[ -d "$NM_CONF_DIR" ]]; then
    cat > "$NM_CONF_DIR/99-kiosk-wifi-powersave.conf" << 'EOF'
[connection]
wifi.powersave = 2
EOF
    log "Wi-Fi power management disabled"
else
    warn "NetworkManager not found — Wi-Fi power-save not configured."
fi

# ── 8. Ownership ──────────────────────────────────────────────────────────────
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"
log "Ownership set for $KIOSK_HOME/.config"

# ── 9. Shutdown script (function — reused by --enable-rtc) ───────────────────
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
    | tee -a $KIOSK_HOME/kiosk.log

WAKE_TIME_STR="\${WAKE_HOUR}:\$(printf '%02d' \$WAKE_MINUTE):00"
NOW=\$(date +%s)
TODAY_WAKE=\$(date -d "today \${WAKE_TIME_STR}" +%s)
TOMORROW_WAKE=\$(date -d "tomorrow \${WAKE_TIME_STR}" +%s)
WAKE_EPOCH=\$( [ "\$NOW" -ge "\$TODAY_WAKE" ] && echo "\$TOMORROW_WAKE" || echo "\$TODAY_WAKE" )

echo "[\$(date)] RTC alarm → \$(date -d "@\$WAKE_EPOCH" '+%A %Y-%m-%d %H:%M:%S')" \
    | tee -a $KIOSK_HOME/kiosk.log

if [[ -w "\$RTC_DEVICE" ]]; then
    echo 0 > "\$RTC_DEVICE"
    echo "\$WAKE_EPOCH" > "\$RTC_DEVICE"
    echo "[\$(date)] Alarm written via sysfs" | tee -a $KIOSK_HOME/kiosk.log
elif command -v rtcwake &>/dev/null; then
    rtcwake -m no -t "\$WAKE_EPOCH"
    echo "[\$(date)] Alarm set via rtcwake" | tee -a $KIOSK_HOME/kiosk.log
else
    echo "[\$(date)] ERROR: wakealarm not writable and rtcwake not found." \
        | tee -a $KIOSK_HOME/kiosk.log
    exit 1
fi

sync
echo "[\$(date)] Shutting down. Good night!" | tee -a $KIOSK_HOME/kiosk.log
/sbin/shutdown -h now
SCRIPT
    chmod +x /usr/local/bin/kiosk-shutdown.sh
    log "Shutdown script → /usr/local/bin/kiosk-shutdown.sh"
}

# ── 10. Conditionally install shutdown + cron ─────────────────────────────────
if $RTC_PRESENT; then
    _write_shutdown_script
    CRON_JOB="$SHUTDOWN_MINUTE $SHUTDOWN_HOUR * * * /usr/local/bin/kiosk-shutdown.sh >> $KIOSK_HOME/kiosk.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v "kiosk-shutdown"; echo "$CRON_JOB" ) | crontab -
    log "Cron: shutdown daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}"
    RTC_ENABLED=true
else
    ( crontab -l 2>/dev/null | grep -v "kiosk-shutdown" ) | crontab - 2>/dev/null || true
    RTC_ENABLED=false
fi

# ── 11. Log rotation ──────────────────────────────────────────────────────────
cat > /etc/logrotate.d/kiosk << 'EOF'
$KIOSK_HOME/kiosk.log {
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
PI_MODEL=$PI_MODEL_RAW
PI_VARIANT=$PI_VARIANT
PI_TIER=$PI_TIER
PI_RAM_MB=$PI_RAM_MB
USER=$KIOSK_USER
URL=$KIOSK_URL
COMPOSITOR=$COMPOSITOR
AUTOSTART=$AUTOSTART_FILE
SHUTDOWN=${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD}
WAKE=${WAKE_HOUR}:${WAKE_MINUTE_PAD}
RTC_ENABLED=$RTC_ENABLED
OSK_ENABLED=$ENABLE_OSK
HA_AUTO_LOGIN=$HA_AUTO_LOGIN
DISPLAY_API=$ENABLE_DISPLAY_API
DISPLAY_API_PORT=$DISPLAY_API_PORT
BROWSER_MOD=$ENABLE_BROWSER_MOD
BROWSER_MOD_ID=$BROWSER_MOD_ID
WAVESHARE_10DP=$WAVESHARE_10DP
INSTALLED_PKGS=${INSTALLED_PKGS[*]}
EOF
log "Install marker → $INSTALL_MARKER"
    touch "$KIOSK_HOME/kiosk.log"
    chown "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/kiosk.log"
    log "Kiosk log file created at $KIOSK_HOME/kiosk.log"

# ── 13. Home Assistant auto-login ─────────────────────────────────────────────
HA_WRAPPER_PATH="$KIOSK_HOME/kiosk-ha-login.html"
# The wrapper page MUST be served from the HA origin so localStorage writes
# land in the correct origin scope. file:// and http:// are different origins —
# a token written in file:// localStorage is invisible to HA at http://.
# We copy the file to HA's www folder and load it via /local/.
# BrowserID is appended as a URL parameter so ONE file serves ALL kiosks —
# each Pi points to kiosk-ha-login.html?BrowserID=its-own-id.
if [[ -n "$BROWSER_MOD_ID" && "$ENABLE_BROWSER_MOD" == "true" ]]; then
    HA_WRAPPER_URL="$HA_URL/local/kiosk-ha-login.html?BrowserID=${BROWSER_MOD_ID}"
else
    HA_WRAPPER_URL="$HA_URL/local/kiosk-ha-login.html"
fi

_setup_ha_autologin() {
    # ── Method 1: print Trusted Networks YAML for user to add to HA ────────
    # Detect local subnet from the Pi's default route interface
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    SUBNET=$(echo "$LOCAL_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Step required: Add this to Home Assistant${NC}"
    echo -e "${CYAN}  configuration.yaml then restart HA${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  homeassistant:"
    echo "    auth_providers:"
    echo "      - type: trusted_networks"
    echo "        trusted_networks:"
    echo "          - $SUBNET          # your local subnet (auto-detected)"
    echo "          - 127.0.0.1"
    echo "        trusted_users:"
    echo "          $SUBNET:"
    echo "            - user_id: YOUR_HA_USER_ID   # see note below"
    echo "        allow_bypass_login: true"
    echo "      - type: homeassistant  # keep this so other devices still work"
    echo ""
    echo -e "${YELLOW}  How to find YOUR_HA_USER_ID:${NC}"
    echo "    HA → Settings → People → click your user → copy the ID from the URL"
    echo "    (looks like: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4)"
    echo ""
    echo -e "${YELLOW}  After editing configuration.yaml:${NC}"
    echo "    HA → Developer Tools → Check Configuration → Restart HA"
    echo ""

    # ── Method 2: generate token wrapper page (if HA_TOKEN provided) ───────
    if [[ -n "$HA_TOKEN" ]]; then
        log "Generating HA token wrapper page → $HA_WRAPPER_PATH"
        cat > "$HA_WRAPPER_PATH" << HTMLEOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Connecting to Home Assistant...</title>
  <style>
    body {
      margin: 0;
      background: #000;
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100vh;
      font-family: sans-serif;
    }
    .msg {
      color: #4fc3f7;
      font-size: 1.2rem;
      opacity: 0;
      animation: fadein 0.6s ease 0.3s forwards;
    }
    @keyframes fadein { to { opacity: 1; } }
  </style>
</head>
<body>
  <p class="msg">Connecting to Home Assistant…</p>
  <script>
    // Inject the long-lived access token into HA's localStorage auth store.
    // HA's frontend reads hassTokens on load and skips the login screen
    // when a valid token is present.
    (function() {
      var HA_URL    = "${HA_URL}";
      var HA_PATH   = "${HA_DASHBOARD_PATH}";
      var TOKEN     = "${HA_TOKEN}";
      var CLIENT_ID = "https://home-assistant.io/";

      // HA stores auth as a JSON object keyed by client ID + HA URL
      var authKey = "hassTokens";
      var authData = {};

      try {
        authData = JSON.parse(localStorage.getItem(authKey) || "{}");
      } catch(e) {}

      // Overwrite with our long-lived token.
      // The expires field is set far in the future; HA will refresh as needed.
      authData[HA_URL] = {
        access_token  : TOKEN,
        token_type    : "Bearer",
        expires_in    : 1800,
        hassUrl       : HA_URL,
        clientId      : CLIENT_ID,
        expires       : Date.now() + (1800 * 1000),
        refresh_token : TOKEN   // HA treats long-lived tokens as self-refreshing
      };

      try {
        localStorage.setItem(authKey, JSON.stringify(authData));
      } catch(e) {
        // localStorage unavailable on file:// — fall through to direct redirect
      }

      // Set the browser_mod Browser ID via URL parameter — the official
      // browser_mod 2.x method (?BrowserID=name appended to any HA URL).
      //
      // Dynamic: read BrowserID from THIS page's own URL first so one
      // wrapper file serves all kiosks. Each Pi points to:
      //   /local/kiosk-ha-login.html?BrowserID=kiosk-front-door
      //   /local/kiosk-ha-login.html?BrowserID=kiosk-garage
      // Fallback to the hardcoded value baked in at install time.
      var FALLBACK_BROWSER_MOD_ID = "${BROWSER_MOD_ID}";
      var urlParams = new URLSearchParams(window.location.search);
      var BROWSER_MOD_ID = urlParams.get('BrowserID') || FALLBACK_BROWSER_MOD_ID;

      var destination = HA_URL + HA_PATH;
      if (BROWSER_MOD_ID) {
        destination += (destination.indexOf('?') === -1 ? '?' : '&')
                     + 'BrowserID=' + encodeURIComponent(BROWSER_MOD_ID);
      }

      // Navigate to HA dashboard.
      window.location.replace(destination);
    })();
  </script>
</body>
</html>
HTMLEOF
        chown "$KIOSK_USER:$KIOSK_USER" "$HA_WRAPPER_PATH"
        log "Token wrapper page created: $HA_WRAPPER_PATH"

        # IMPORTANT: The wrapper page MUST be served from the HA origin.
        # localStorage is origin-scoped — a token written at file:// is
        # completely invisible to HA at http://. Copy to HA www folder so
        # it loads from http://HA_URL/local/kiosk-ha-login.html.
        HA_COPIED=false
        for HA_CFG_DIR in /config /root/config /home/homeassistant/.homeassistant /usr/share/hassio/homeassistant; do
            if [[ -d "$HA_CFG_DIR" ]]; then
                mkdir -p "$HA_CFG_DIR/www" 2>/dev/null
                if cp "$HA_WRAPPER_PATH" "$HA_CFG_DIR/www/kiosk-ha-login.html" 2>/dev/null; then
                    log "Wrapper copied to HA: $HA_CFG_DIR/www/kiosk-ha-login.html"
                    HA_COPIED=true
                    break
                fi
            fi
        done
        if ! $HA_COPIED; then
            warn "Could not auto-copy wrapper to HA www folder."
            echo "  Copy it manually before rebooting:"
            echo "    cp $HA_WRAPPER_PATH <HA_CONFIG>/www/kiosk-ha-login.html"
            echo "  Then verify it is accessible at:"
            echo "    $HA_WRAPPER_URL"
        fi

        # Point the kiosk autostart at the HA-hosted wrapper page.
        sed -i "s|^  KIOSK_URL_VALUE=.*|  KIOSK_URL_VALUE=$HA_WRAPPER_URL|" "$AUTOSTART_FILE"
        sed -i "s|^URL=.*|URL=$HA_WRAPPER_URL|" "$INSTALL_MARKER"
        log "Autostart updated: $HA_WRAPPER_URL"

        echo -e "${CYAN}[i]${NC} Kiosk will load:"
        echo "    $HA_WRAPPER_URL"
        echo "    (injects auth token then redirects to ${HA_URL}${HA_DASHBOARD_PATH})"
        echo ""
    else
        info "No HA_TOKEN set — wrapper page skipped."
        info "Trusted Networks alone will handle auto-login."
        info "Make sure you add the YAML above to configuration.yaml."
    fi
}

if $HA_AUTO_LOGIN; then
    _setup_ha_autologin
else
    info "HA auto-login disabled (HA_AUTO_LOGIN=false). Set to true to enable."
fi

# If browser_mod is enabled but HA wrapper was NOT generated (no HA_AUTO_LOGIN),
# create a standalone preloader that seeds the Browser ID then redirects.
if $ENABLE_BROWSER_MOD && ! $HA_AUTO_LOGIN; then
    PRELOADER_PATH="$KIOSK_HOME/kiosk-bmod-preloader.html"
    log "Creating standalone browser_mod ID preloader..."
    cat > "$PRELOADER_PATH" << HTMLEOF
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Loading...</title>
<style>body{margin:0;background:#000;display:flex;align-items:center;
justify-content:center;height:100vh;font-family:sans-serif;}
.msg{color:#4fc3f7;font-size:1.1rem;opacity:0;animation:f .5s ease .2s forwards;}
@keyframes f{to{opacity:1;}}</style></head>
<body><p class="msg">Starting kiosk...</p>
<script>
(function(){
  var BROWSER_MOD_ID = "${BROWSER_MOD_ID}";
  var TARGET         = "${KIOSK_URL}";
  // Set browser_mod ID via official URL parameter (?BrowserID=name)
  var destination = TARGET;
  if (BROWSER_MOD_ID) {
    destination += (destination.indexOf('?') === -1 ? '?' : '&')
                 + 'BrowserID=' + encodeURIComponent(BROWSER_MOD_ID);
  }
  window.location.replace(destination);
})();
</script></body></html>
HTMLEOF
    chown "$KIOSK_USER:$KIOSK_USER" "$PRELOADER_PATH"
    sed -i "s|^  KIOSK_URL_VALUE=.*|  KIOSK_URL_VALUE=file://$PRELOADER_PATH|" "$AUTOSTART_FILE"
    sed -i "s|^URL=.*|URL=file://$PRELOADER_PATH|" "$INSTALL_MARKER"
    log "Autostart updated to use browser_mod preloader"
fi

# ── 14. Bloat removal + apt cleanup ───────────────────────────────────────────────
# Packages that are present on a full Pi desktop image but have no purpose
# on a wall-panel kiosk. Safe to remove — none are kiosk dependencies.
BLOAT_PKGS=(
    # Wolfram / Mathematica — 800MB+ on some images
    wolfram-engine wolfram-script
    # LibreOffice suite
    libreoffice libreoffice-base libreoffice-calc libreoffice-common
    libreoffice-core libreoffice-draw libreoffice-impress libreoffice-math
    libreoffice-writer libreoffice-base-core libreoffice-gtk3 soffice
    # Scratch / Scratch 3
    scratch scratch3 scratch3-upstream-resources
    # Sonic Pi
    sonic-pi sonic-pi-server
    # Thonny IDE
    thonny
    # Minecraft
    minecraft-pi python3-minecraftpi
    # Greenfoot / BlueJ IDEs
    greenfoot bluej
    # Desktop games
    timidity freeciv-client-gtk freeciv-data gnome-games
    # NodeRED (not needed unless specifically wanted)
    nodered
    # Unused desktop apps
    geany geany-common
    claws-mail claws-mail-i18n
    galculator
    # Pi-specific extras that add no value to a kiosk
    python3-thonny
)

if $REMOVE_BLOAT; then
    log "Checking for bloat packages to remove..."
    FOUND_BLOAT=()
    for pkg in "${BLOAT_PKGS[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            FOUND_BLOAT+=("$pkg")
        fi
    done

    if [[ ${#FOUND_BLOAT[@]} -gt 0 ]]; then
        log "Removing ${#FOUND_BLOAT[@]} bloat package(s): ${FOUND_BLOAT[*]}"
        apt-get remove -y -qq --purge "${FOUND_BLOAT[@]}" 2>/dev/null || true
        log "Bloat packages removed"
    else
        log "No bloat packages found (already clean)"
    fi
else
    info "Bloat removal skipped (REMOVE_BLOAT=false)"
fi

log "Running apt autoremove + autoclean..."
apt-get autoremove -y -qq --purge 2>/dev/null || true
apt-get autoclean -qq 2>/dev/null || true
log "Package cleanup complete"

# ── 15. Display brightness/power API ─────────────────────────────────────────────
_install_display_api() {
    log "Installing display API..."

    # Install ddcutil if not present (needed for HDMI DDC/CI brightness control)
    if ! command -v ddcutil &>/dev/null; then
        log "Installing ddcutil (HDMI DDC/CI brightness control)..."
        apt-get install -y -qq ddcutil 2>/dev/null ||             warn "ddcutil not available in repos — HDMI DDC/CI will be unavailable."
    fi

    # Install the API script
    cp "$(dirname "$0")/kiosk-display-api.py" /usr/local/bin/kiosk-display-api.py         2>/dev/null || {
        # Fallback: try the same dir as kiosk-setup.sh
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$SCRIPT_DIR/kiosk-display-api.py" ]]; then
            cp "$SCRIPT_DIR/kiosk-display-api.py" /usr/local/bin/kiosk-display-api.py
        else
            warn "kiosk-display-api.py not found alongside kiosk-setup.sh."
            warn "Download it from the repo and place it in the same directory, then re-run."
            return 1
        fi
    }
    chmod +x /usr/local/bin/kiosk-display-api.py
    log "Display API script installed → /usr/local/bin/kiosk-display-api.py"

    # Write display config file (read by the API at runtime)
    cat > /etc/kiosk-display.conf << DISPLAYCONF
[display]
port         = $DISPLAY_API_PORT
compositor   = $COMPOSITOR
output       = $DISPLAY_OUTPUT
wayland_socket = /run/user/$(id -u "$KIOSK_USER")/wayland-0
x_display    = :0
kiosk_user   = $KIOSK_USER
kiosk_uid    = $(id -u "$KIOSK_USER")
DISPLAYCONF
    log "Display config written → /etc/kiosk-display.conf"

    # Write systemd service
    cat > /etc/systemd/system/kiosk-display-api.service << SVCEOF
[Unit]
Description=Kiosk Display Control API
After=network.target multi-user.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/kiosk-display-api.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
# Run as root so it can write to sysfs backlight nodes
User=root

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable kiosk-display-api.service
    systemctl restart kiosk-display-api.service 2>/dev/null || true
    log "Display API service enabled and started (port $DISPLAY_API_PORT)"

    # Log rotation for display API
    cat > /etc/logrotate.d/kiosk-display << 'EOF'
/var/log/kiosk-display.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

    echo ""
    info "Display API installed. Replace KIOSK_IP and KIOSK_PORT in ha-display-config.yaml:"
    info "  KIOSK_IP   : $(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
    info "  KIOSK_PORT : $DISPLAY_API_PORT"
    info "  API health : http://$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1):$DISPLAY_API_PORT/health"
    echo ""
}

if $ENABLE_DISPLAY_API; then
    _install_display_api
else
    info "Display API disabled (ENABLE_DISPLAY_API=false). Set to true to enable."
fi

# ── 16. Waveshare 10.1DP-CAPLCD display configuration ───────────────────────────
if $WAVESHARE_10DP; then
    log "Configuring Waveshare 10.1DP-CAPLCD display (1280x800)..."
    BOOT_CFG=""
    [[ -f /boot/firmware/config.txt ]] && BOOT_CFG=/boot/firmware/config.txt
    [[ -z "$BOOT_CFG" && -f /boot/config.txt ]] && BOOT_CFG=/boot/config.txt

    if [[ -n "$BOOT_CFG" ]]; then
        if ! grep -q "hdmi_cvt 1280 800" "$BOOT_CFG"; then
            cat >> "$BOOT_CFG" << 'DISPLAYCFG'

# Waveshare 10.1DP-CAPLCD -- 1280x800 HDMI display
hdmi_group=2
hdmi_mode=87
hdmi_cvt 1280 800 60 6 0 0 0
hdmi_drive=1
DISPLAYCFG
            log "Waveshare resolution config added to $BOOT_CFG (takes effect after reboot)"
        else
            log "Waveshare resolution config already present in $BOOT_CFG"
        fi
    else
        warn "config.txt not found -- add the following manually:"
        echo "    hdmi_group=2"
        echo "    hdmi_mode=87"
        echo "    hdmi_cvt 1280 800 60 6 0 0 0"
        echo "    hdmi_drive=1"
    fi

    # ddcutil is required for DDC/CI brightness control on this display
    if ! command -v ddcutil &>/dev/null; then
        log "Installing ddcutil for Waveshare DDC/CI brightness control..."
        apt-get install -y -qq ddcutil 2>/dev/null             || warn "ddcutil install failed -- brightness control via HA will be unavailable."
    else
        log "ddcutil already installed"
    fi

    echo ""
    info "Waveshare 10.1DP-CAPLCD uses DDC/CI for brightness (no sysfs backlight)."
    info "After reboot, verify with:  sudo ddcutil detect"
    info "Test brightness:            sudo ddcutil setvcp 10 50"
    echo ""
else
    info "Waveshare 10.1DP-CAPLCD config skipped (WAVESHARE_10DP=false)"
fi

# ── 17. browser_mod persistent profile ──────────────────────────────────────────
if $ENABLE_BROWSER_MOD; then
    mkdir -p "$KIOSK_HOME/.config/chromium-kiosk"
    chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config/chromium-kiosk"
    log "Persistent Chromium profile directory created: ~/.config/chromium-kiosk"

    # Resolve the Browser ID: use BROWSER_MOD_ID if set, else derive a stable
    # UUID from the Pi serial number so it survives reinstalls on the same Pi.
    if [[ -z "$BROWSER_MOD_ID" ]]; then
        PI_SERIAL=$(grep Serial /proc/cpuinfo 2>/dev/null | awk "{print \$3}" | tail -1)
        if [[ -n "$PI_SERIAL" ]]; then
            # Derive a deterministic UUID-like ID from the serial
            BROWSER_MOD_ID="kiosk-$(echo "$PI_SERIAL" | tail -c 9 | tr '[:upper:]' '[:lower:]')"
        else
            # Fallback: random UUID
            BROWSER_MOD_ID="kiosk-$(cat /proc/sys/kernel/random/uuid | cut -d- -f1-2)"
        fi
        log "Auto-generated Browser ID from Pi serial: $BROWSER_MOD_ID"
    else
        log "Using configured Browser ID: $BROWSER_MOD_ID"
    fi

    # Store the resolved ID in a dedicated file for easy retrieval
    echo "$BROWSER_MOD_ID" > /etc/kiosk-browser-mod-id
    chmod 644 /etc/kiosk-browser-mod-id
    log "Browser ID stored in /etc/kiosk-browser-mod-id"

    # IMPORTANT: The wrapper page and autostart URL were written before this
    # step resolved BROWSER_MOD_ID. Now that we have the final ID, update both.
    #
    # 1. Patch the BROWSER_MOD_ID variable in the wrapper page JS
    if [[ -f "$HA_WRAPPER_PATH" ]]; then
        sed -i "s|var BROWSER_MOD_ID = \".*\";|var BROWSER_MOD_ID = \"$BROWSER_MOD_ID\";|" "$HA_WRAPPER_PATH"
        log "Wrapper page patched with resolved Browser ID: $BROWSER_MOD_ID"
        # Re-copy the updated wrapper to HA www folder if it exists
        for HA_CFG_DIR in /config /root/config /home/homeassistant/.homeassistant /usr/share/hassio/homeassistant; do
            if [[ -f "$HA_CFG_DIR/www/kiosk-ha-login.html" ]]; then
                cp "$HA_WRAPPER_PATH" "$HA_CFG_DIR/www/kiosk-ha-login.html" 2>/dev/null &&                     log "Updated wrapper page copied to $HA_CFG_DIR/www/kiosk-ha-login.html"
                break
            fi
        done
    fi

    # 2. The wrapper page JS already appends ?BrowserID= to the dashboard
    #    redirect URL. No need to modify the autostart URL — the wrapper
    #    page URL stays clean (just /local/kiosk-ha-login.html).
    log "Browser ID will be set via wrapper page redirect: $BROWSER_MOD_ID"
    echo ""
    warn "browser_mod requires manual setup steps after reboot:"
    echo ""
    echo "  1. Install browser_mod via HACS:"
    echo "       HA -> HACS -> Integrations -> Search 'Browser Mod' -> Download"
    echo "       HA -> Settings -> Devices & Services -> Add Integration -> Browser Mod"
    echo "       Restart HA when prompted."
    echo ""
    echo "  2. After kiosk reboots and Chromium loads your dashboard:"
    echo "       HA -> Browser Mod panel (sidebar)"
    echo "       The kiosk will appear in the registered browsers list automatically."
    echo "       Note the Browser ID -- you need it to target this kiosk in automations."
    echo ""
    echo "  3. In the Browser Mod panel for this kiosk, enable:"
    echo "       - 'Hide sidebar' (keeps the kiosk clean)"
    echo "       - 'Lock screen' (optional -- prevents navigating away)"
    echo ""
    echo "  4. See ha-browser-mod-config.yaml in the repo for automation examples:"
    echo "       - Doorbell camera popup"
    echo "       - Navigate to a different dashboard from HA"
    echo "       - Show alert notifications"
    echo "       - Software screen blackout (overlay)"
    echo "       - Combined hardware brightness + software overlay"
    echo ""
fi

# =============================================================================
#  Summary
# =============================================================================
echo ""
hr
banner "  Setup Complete!"
hr
echo ""
echo -e "  ${CYAN}Pi             :${NC} $PI_VARIANT (Tier $PI_TIER, ${PI_RAM_MB}MB RAM)"
echo -e "  ${CYAN}OS             :${NC} $OS_PRETTY"
echo -e "  ${CYAN}Compositor     :${NC} $COMPOSITOR"
echo -e "  ${CYAN}Kiosk URL      :${NC} $KIOSK_URL"
echo -e "  ${CYAN}Dark mode      :${NC} Forced (GTK + Chromium)"
echo -e "  ${CYAN}OSK            :${NC} $([ "$ENABLE_OSK" = true ] && echo "Enabled ($OSK_PKG)" || echo "Disabled")"
echo -e "  ${CYAN}HA Auto-login  :${NC} $(${HA_AUTO_LOGIN} && echo "Enabled (${HA_URL})" || echo "Disabled")"
echo -e "  ${CYAN}Display API    :${NC} $(${ENABLE_DISPLAY_API} && echo "Enabled (port ${DISPLAY_API_PORT})" || echo "Disabled")"
echo -e "  ${CYAN}browser_mod    :${NC} $(${ENABLE_BROWSER_MOD} && echo "Enabled (persistent profile)" || echo "Disabled")"
if $ENABLE_BROWSER_MOD; then
    echo -e "  ${CYAN}  Browser ID   :${NC} $BROWSER_MOD_ID"
    echo -e "  ${CYAN}  ID file      :${NC} /etc/kiosk-browser-mod-id  (cat to retrieve)"
fi
if $HA_AUTO_LOGIN && [[ -n "$HA_TOKEN" ]]; then
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${YELLOW}  ACTION REQUIRED — Copy wrapper page to HA server${NC}"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  The HA login wrapper page must be on your HA server to work."
    echo "  Every time you run --reset or change the token/browser ID,"
    echo "  you must recopy this file."
    echo ""
    echo "  File on this Pi:  $HA_WRAPPER_PATH"
    echo "  Copy to HA:       /config/www/kiosk-ha-login.html"
    echo "  (Re-copy this file whenever you run --set-browser-id or update the token)"
    echo ""
    echo "  Options:"
    echo "    A) HA Terminal add-on:"
    echo "       paste the output of:  cat $HA_WRAPPER_PATH"
    echo "       into:  /config/www/kiosk-ha-login.html"
    echo ""
    echo "    B) If HA is on same machine / accessible path:"
    echo "       cp $HA_WRAPPER_PATH /config/www/kiosk-ha-login.html"
    echo ""
    echo "    C) scp (replace USER and HA_IP):"
    echo "       scp $HA_WRAPPER_PATH USER@HA_IP:/config/www/kiosk-ha-login.html"
    echo ""
    echo "  Verify it works at:"
    echo "    $HA_WRAPPER_URL"
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi
echo -e "  ${CYAN}Waveshare 10DP :${NC} $(${WAVESHARE_10DP} && echo "Configured (1280x800 DDC/CI)" || echo "Not configured")"
echo -e "  ${CYAN}Watchdog       :${NC} $($HAS_HW_WATCHDOG && echo "Hardware (15s)" || echo "None — software-only")"
echo -e "  ${CYAN}Logs           :${NC} $KIOSK_HOME/kiosk.log"
echo ""

if $RTC_ENABLED; then
    echo -e "  ${CYAN}Shutdown       :${NC} Daily at ${SHUTDOWN_HOUR}:${SHUTDOWN_MINUTE_PAD} (cron)"
    echo -e "  ${CYAN}Wake           :${NC} Daily at ${WAKE_HOUR}:${WAKE_MINUTE_PAD} (RTC)"
    echo ""
    warn "Sync hardware clock now if you haven't:"
    echo "    sudo hwclock --systohc"
else
    echo -e "  ${YELLOW}Shutdown       : DISABLED — RTC not detected${NC}"
    echo -e "  ${YELLOW}Wake           : DISABLED — RTC not detected${NC}"
    echo ""
    warn "To enable shutdown/wake after adding RTC hardware:"
    if $HAS_BUILTIN_RTC; then
        echo "  Pi 5: insert CR2032 battery, then:"
        echo "    sudo hwclock --systohc && sudo bash $0 --enable-rtc"
    else
        echo "  Pi 4 / Pi 3 / Zero 2W: wire a DS3231 module, add to /boot/firmware/config.txt:"
        echo "    dtoverlay=i2c-rtc,ds3231"
        echo "  Then reboot and run:"
        echo "    sudo hwclock --systohc && sudo bash $0 --enable-rtc"
    fi
fi

echo ""
[[ $PI_TIER -ge 4 ]] && warn "Reminder: $PI_VARIANT is low-end hardware. Expect slow Chromium startup."
echo ""
info "To update the URL:  sudo bash $0 --update-url https://new-url.com"
info "To enable RTC:      sudo bash $0 --enable-rtc"
warn "Reboot to start:    sudo reboot"
echo ""
