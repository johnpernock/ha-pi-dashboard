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

## Display API

`kiosk-display-api.py` runs as a systemd service on port 2701. Endpoints:

- `GET /status` — brightness level + screen state
- `GET /health` — service health check
- `POST /brightness` — set brightness (0–100)
- `POST /screen/on` / `POST /screen/off` — screen power
- `GET /screen/state` — current on/off state

Rate limited to 20 POST calls per 10 seconds per IP. No external HTTP framework — uses Python stdlib `http.server`.

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
| `/var/log/kiosk.log` | Chromium watchdog loop (rotated weekly) |
| `/var/log/kiosk-display.log` | Display API requests and events (rotated weekly) |
| `/etc/kiosk-installed` | Presence indicates a completed install |
| `/etc/kiosk-display.conf` | INI config consumed by the Python API |
| `/etc/kiosk-browser-mod-id` | browser_mod device ID |
| `~/.config/chromium-kiosk` | Persistent Chromium profile (only when browser_mod is enabled) |
