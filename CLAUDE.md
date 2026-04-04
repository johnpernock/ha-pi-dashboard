# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ha-pi-smarthome** is a zero-touch provisioning system that turns a Raspberry Pi into a wall-mounted Home Assistant kiosk display. There is no traditional build system — the project is a Bash provisioning script plus a Python HTTP API service.

## Running the Setup Script

```bash
# Full install
sudo bash kiosk-setup.sh https://your-ha-dashboard.com

# Update dashboard URL without reinstalling
sudo bash kiosk-setup.sh --update-url https://new-url.com

# Set a Home Assistant long-lived token
sudo bash kiosk-setup.sh --set-token YOUR_TOKEN

# Set browser_mod device ID
sudo bash kiosk-setup.sh --set-browser-id kiosk-living-room

# Enable RTC scheduling (after adding hardware)
sudo bash kiosk-setup.sh --enable-rtc

# Reset config only (keeps installed packages)
sudo bash kiosk-setup.sh --reset https://your-url.com

# Full factory reset (wipes Chromium profile, removes generated configs, reinstalls)
sudo bash kiosk-setup.sh --factory-reset https://your-url.com
```

> Flags must be passed **one at a time** — combining multiple flags in a single invocation is not supported.

## Deployed hardware

| Pi | Hostname | IP | Display | OS | Notes |
|----|----------|----|---------|-----|-------|
| Pi 4 | `VoicePiKitchen` | `192.168.1.153` | HyperPixel 4 Rectangle, portrait 480×800 | Debian 13 Trixie | Upgraded in-place from Bookworm. No LightDM — labwc launched via `.bash_profile` (see below). Display API on port 2701. |
| Pi | `KioskPiDiningRoom` | `192.168.1.156` | — | — | Dining room kiosk display |
| Pi | `KioskPiFamilyRoom` | `192.168.1.157` | — | — | Family room kiosk display |
| Pi | `KioskPiPortable` | `192.168.1.158` | — | — | Portable kiosk — reserved, not yet deployed |

### HyperPixel 4 Rectangle — kiosk.conf
```bash
DISPLAY_OUTPUT="DPI-1"
DISPLAY_TRANSFORM="normal"
ENABLE_DISPLAY_API=true
ENABLE_SCREEN_CONTROL=true
ENABLE_TOUCH_TO_WAKE=true
ENABLE_PULL_TO_REFRESH=false
```

### No-LightDM workaround (Trixie, upgraded from Bookworm)
The script warns if `lightdm.conf` is not found and skips autologin config. After running the setup, create `/home/pi/.bash_profile` to start labwc on tty1:
```bash
if [[ -z "$WAYLAND_DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec dbus-run-session labwc
fi
```
Also manually install `labwc`, `swaybg`, and `wlr-randr` if they were missing from the Trixie repo at upgrade time:
```bash
sudo apt-get install -y labwc wlr-randr swaybg
```

## Display API

`kiosk-display-api.py` runs as a systemd service on port 2701. Endpoints:

- `GET /status` — brightness level + screen state
- `GET /health` — service health check
- `POST /brightness` — set brightness (0–100)
- `POST /screen/on` / `POST /screen/off` — screen power
- `GET /screen/state` — current on/off state

Rate limited to 20 POST calls per 10 seconds per IP. No external HTTP framework — uses Python stdlib `http.server`.

**Authentication:** POST endpoints support optional bearer-token auth (`DISPLAY_API_TOKEN` in `kiosk.conf`). GET endpoints are always unauthenticated. HA `ha-display-config.yaml` POST REST commands include `Authorization: !secret kiosk_api_bearer_token`. Add to HA `secrets.yaml`:
```yaml
kiosk_api_bearer_token: "Bearer your-token-here"   # or just "Bearer" if no token set
```

**Logging:** Logs to stdout only (systemd journal). Setup writes `Storage=volatile` to journald — journal stays in RAM, never touches the SD card.

## Architecture

### Component Relationships

```
Home Assistant  ──HTTP──▶  kiosk-display-api.py (port 2701)
                                    │
                              DisplayBackend
                         (sysfs backlight OR ddcutil DDC/CI)
                                    │
                           TouchWakeMonitor
                         (evdev kernel grab for touch-to-wake)
```

The **setup script** (`kiosk-setup.sh`) generates all runtime configs and systemd units:
- `kiosk.service` — Chromium watchdog loop (restarts browser on crash)
- `kiosk-display-api.service` — the Python API

### Configuration Hierarchy (lowest → highest precedence)

1. Script defaults (lines 54–148 of `kiosk-setup.sh`)
2. `/home/pi/kiosk.conf` — user overrides, sourced before main logic, git-ignored
3. Command-line arguments
4. Generated runtime configs written to `/etc/kiosk-*`

Use `kiosk.conf.example` as a template; copy to `kiosk.conf` for local overrides that survive `git pull`.

### OS/Hardware Branching

The script detects the environment and branches behavior accordingly:

- **Trixie** → Wayland + labwc compositor + wvkbd on-screen keyboard
- **Bookworm / Bullseye / Buster** → X11 + LXDE + onboard keyboard
- **ARMv6 (Pi Zero / Pi 1)** → forces X11 path even on Trixie
- **<1GB RAM** → applies Chromium memory-reduction flags
- **Pi 5** → uses built-in RTC; others use DS3231 via I2C overlay

### Key Patterns

- **Idempotency:** All `--flag` modes are safe to re-run; the script checks existing state before overwriting.
- **Privilege separation:** Setup runs as root; Chromium runs as `$KIOSK_USER` (default: `pi`); Display API runs as root for sysfs backlight write access.
- **Display backend auto-detection:** sysfs backlight → DDC/CI via ddcutil → none (graceful degradation).
- **Touch-to-wake:** Uses kernel `evdev` grab (not JavaScript). A 600ms post-grab drain absorbs the finger-lift after pressing the screen-off button.

## HA Integration Files

- `ha-display-config.yaml` — paste into HA `configuration.yaml` to add `rest_command`, `sensor`, `input_number`, `switch`, and automations for the Display API
- `ha-browser-mod-config.yaml` — HA automations using the browser_mod HACS integration for HA-controlled popups and navigation

## Logs & Runtime Files

| Path | Purpose |
|---|---|
| `~/kiosk.log` | Chromium watchdog loop (rotated weekly) |
| `/etc/kiosk-installed` | Presence indicates a completed install |
| `/etc/kiosk-display.conf` | INI config consumed by the Python API |
| `/etc/kiosk-browser-mod-id` | browser_mod device ID |
| `~/.config/chromium-kiosk` | Persistent Chromium profile (only when browser_mod is enabled) |

> `kiosk-display-api.py` logs to stdout → systemd journal (volatile/RAM only, never written to disk). Use `journalctl -u kiosk-display-api.service -f` to follow live.
