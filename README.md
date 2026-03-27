# 🖥️ Pi Wall Panel Kiosk

A zero-touch setup script for turning a Raspberry Pi into a wall-mounted display kiosk. Automatically detects your hardware, OS version, compositor, and RTC availability — then configures everything accordingly.

---

## Compatibility Matrix

### Hardware Tiers

| Tier | Models | RAM | Notes |
|---|---|---|---|
| **1 — Recommended** | Pi 4, Pi 4B, Pi 400, CM4, Pi 5 | 2–8GB | Full support, all features |
| **2 — Capable** | Pi 3, Pi 3A+, Pi 3B+, Zero 2W | 512MB–1GB | Works well; memory flags auto-applied below 1GB |
| **3 — Limited** | Pi 2 | 1GB | Works; slow page loads; avoid heavy JS pages |
| **4 — Not Advised** | Pi Zero, Pi Zero W, Pi 1 (A/B/B+) | 256–512MB | ARMv6; Chromium runs but very slow; no hardware watchdog; prompted to confirm |

> **Compute Modules:** CM3 is treated as Pi 3, CM4 as Pi 4.  
> **Unknown models** are treated as Tier 2 with a warning.

### Operating System Support

| OS | Debian | Compositor | Support Level |
|---|---|---|---|
| **Trixie** | 13 | Wayland + labwc | ✅ Recommended |
| **Bookworm** | 12 | X11 + LXDE | ✅ Fully supported |
| **Bullseye** | 11 | X11 + LXDE | ✅ Supported (dark mode portal unavailable) |
| **Buster** | 10 | X11 | ⚠️ Best-effort (EOL — upgrade advised) |
| **Older** | <10 | X11 | ⚠️ Best-effort (strongly upgrade advised) |

> **Trixie on ARMv6 (Pi Zero / Pi 1):** automatically falls back to X11 path — Wayland is not supported on ARMv6 CPUs.  
> **Buster / legacy:** the script will warn you and ask for confirmation before proceeding.

---

## Quick Start

```bash
git clone https://github.com/johnpernock/ha-pi-smarthome.git
cd ha-pi-smarthome
chmod +x kiosk-setup.sh
sudo bash kiosk-setup.sh https://your-dashboard.com
sudo reboot
```

---

## Usage

```bash
# Full install
sudo bash kiosk-setup.sh https://your-dashboard.com

# Wipe ALL user data and non-essential packages, reinstall from scratch
sudo bash kiosk-setup.sh --factory-reset https://your-dashboard.com

# Wipe existing kiosk config and reinstall fresh (lighter than factory reset)
sudo bash kiosk-setup.sh --reset https://your-dashboard.com

# Reset only — no immediate reinstall (prompts to confirm first)
sudo bash kiosk-setup.sh --reset

# Update the displayed URL — no reinstall, safe to run anytime
sudo bash kiosk-setup.sh --update-url https://new-url.com

# Update the HA long-lived access token — no reinstall
sudo bash kiosk-setup.sh --set-token YOUR_NEW_TOKEN

# Set or update the browser_mod Browser ID — no reinstall
sudo bash kiosk-setup.sh --set-browser-id kiosk-living-room

# Enable RTC scheduled shutdown/wake after adding RTC hardware
sudo bash kiosk-setup.sh --enable-rtc
```

---

## Features

| Feature | Details |
|---|---|
| **Auto-detection** | Detects OS, compositor, Pi model/tier/RAM, and CPU arch at runtime |
| **Full kiosk mode** | Chromium in `--kiosk` mode — no address bar, no UI chrome, no escape |
| **Dark mode** | Forced at OS (GTK 3+4), compositor env, and Chromium level |
| **No desktop flash** | Black background painted before Chromium loads |
| **Crash recovery** | Watchdog loop relaunches Chromium on any unexpected exit |
| **Network-aware boot** | Waits up to 30s for the URL before launching — no blank screen on cold boot |
| **RTC scheduling** | Hardware-probed; skipped gracefully if absent; `--enable-rtc` to activate later |
| **On-screen keyboard** | Optional; `wvkbd` (Wayland) or `onboard` (X11); auto-appears on text field tap |
| **Hardware watchdog** | Pi reboots if kernel hangs >15s (where hardware supports it) |
| **Memory optimisation** | Reduced Chromium memory flags auto-applied on devices with <1GB RAM |
| **Touch controls locked** | Pinch-to-zoom, overscroll, pull-to-refresh all disabled |
| **Infobars suppressed** | No crash prompts, save-password bubbles, translate bar, or notifications |
| **Wi-Fi power-save off** | Prevents random network drops |
| **Log rotation** | `/var/log/kiosk.log` rotated weekly, 4 weeks retained |
| **Idempotent updates** | `--update-url` and `--enable-rtc` are safe to run at any time |
| **browser_mod** | HACS integration compatibility — switches Chromium to a persistent profile so browser_mod can register the kiosk as a HA device (enables popups, navigation, doorbell alerts, software overlay). See `ha-browser-mod-config.yaml` |
| **Waveshare 10.1DP-CAPLCD** | Auto-configures 1280×800 HDMI resolution in `config.txt` and confirms DDC/CI brightness path for this specific display |
| **Display API** | Optional HTTP API (port 2701) for HA to control brightness and screen on/off; auto-detects DSI backlight or HDMI DDC/CI; exposes `/brightness`, `/screen/on`, `/screen/off`, `/status` |
| **Factory reset** | `--factory-reset` strips the device to a bare minimum — wipes all user data (preserving `.ssh`), purges all packages installed by the script plus desktop bloat, and offers immediate fresh reinstall; SSH and networking are never touched |
| **Package cleanup** | Removes desktop bloat (Wolfram, LibreOffice, Scratch, Thonny, games) and runs `autoremove`/`autoclean` after install; `--reset` can also uninstall exactly the packages the script added |
| **Clean reset** | `--reset` wipes all kiosk config (autologin, autostart, cron, watchdog, HA wrapper, LightDM) with a confirmation prompt — optionally followed by a fresh install in one command |
| **Existing install guard** | Full install detects a previous install and prompts: reset, update URL, overwrite, or quit — no accidental overwrites |

---

## Configuration

Settings live in a `kiosk.conf` file alongside the script — **never edit `kiosk-setup.sh` directly**. This means `git pull` will never overwrite your settings.

```bash
cp kiosk.conf.example kiosk.conf
nano kiosk.conf
```

`kiosk.conf` is git-ignored. The script sources it after its own defaults, so anything you set there wins. Only set the variables you need — everything else falls back to the defaults in `kiosk-setup.sh`.

If no `kiosk.conf` exists the script runs entirely from its built-in defaults, so it is always safe to run without one.

| Variable | Default | Description |
|---|---|---|
| `KIOSK_URL` | `https://example.com` | URL to display (or pass as first argument) |
| `SHUTDOWN_HOUR` | `0` | Hour to shut down, 24h format (requires RTC) |
| `SHUTDOWN_MINUTE` | `0` | Minute to shut down (requires RTC) |
| `WAKE_HOUR` | `6` | Hour to wake via RTC alarm, 24h (requires RTC) |
| `WAKE_MINUTE` | `0` | Minute to wake (requires RTC) |
| `ENABLE_OSK` | `false` | Enable on-screen keyboard: `true` or `false` |
| `DISPLAY_TRANSFORM` | `normal` | Screen rotation: `normal` / `90` / `180` / `270` *(Trixie only)* |
| `DISPLAY_OUTPUT` | `HDMI-A-1` | Wayland output name *(Trixie only — run `wlr-randr` to find yours)* |
| `AUTO_RELOAD_SECONDS` | `0` | Auto-reload page every N seconds (`0` = off) |
| `REMOVE_BLOAT` | `true` | Remove desktop bloat packages during install (LibreOffice, Wolfram, Scratch, etc.) |
| `HA_AUTO_LOGIN` | `false` | Enable HA auto-login: `true` or `false` |
| `HA_URL` | `http://homeassistant.local:8123` | Full URL of your HA instance |
| `HA_TOKEN` | `""` | Long-lived access token from HA Profile (leave blank for Trusted Networks only) |
| `HA_DASHBOARD_PATH` | `/lovelace/0` | Dashboard path to open after login |
| `ENABLE_DISPLAY_API` | `false` | Install the display brightness/power HTTP API |
| `DISPLAY_API_PORT` | `2701` | Port the display API listens on |
| `ENABLE_BROWSER_MOD` | `false` | Enable browser_mod compatibility (persistent Chromium profile, removes `--incognito`) |
| `BROWSER_MOD_ID` | `""` | browser_mod Browser ID pre-seeded into localStorage. Use a descriptive name like `kiosk-living-room`. Auto-generates from Pi serial if blank. |
| `WAVESHARE_10DP` | `false` | Auto-configure resolution and DDC/CI for the Waveshare 10.1DP-CAPLCD display |

---

## Resetting an Existing Install

If a kiosk is already configured and you want to start completely fresh, use `--reset`. It removes every file and setting the script created, then optionally runs a clean install immediately.

### Factory Reset vs Regular Reset

| | `--reset` | `--factory-reset` |
|---|---|---|
| Removes kiosk config files | ✅ | ✅ |
| Removes display API | ✅ | ✅ |
| Prompts to remove kiosk packages | ✅ | ✅ (automatic) |
| Wipes home directory (keeps `.ssh`) | ❌ | ✅ |
| Purges ALL desktop/bloat packages | ❌ | ✅ |
| Clears systemd failed units | ❌ | ✅ |
| Requires typing `FACTORY RESET` to confirm | ❌ | ✅ |
| Safe on wall-mounted Pi (SSH/network preserved) | ✅ | ✅ |

Use `--reset` when you want to change the kiosk configuration. Use `--factory-reset` when you want to return the device to a clean slate — for example, when repurposing a Pi that was previously used for something else, or when troubleshooting a deeply broken install.

> **Wall-mounted Pi safety guarantee:** Neither `--reset` nor `--factory-reset` will ever touch SSH host keys, `authorized_keys`, network configuration (NetworkManager/wpa_supplicant/dhcpcd), boot config, or sudo access. The device remains fully reachable via SSH after either command completes.

### Reset + reinstall in one command

```bash
sudo bash kiosk-setup.sh --reset https://your-new-dashboard.com
```

Wipes everything, then falls straight through to a full install with the new URL. No second command needed.

### Reset only (then reinstall separately)

```bash
sudo bash kiosk-setup.sh --reset
# ... make any config changes to kiosk-setup.sh ...
sudo bash kiosk-setup.sh https://your-dashboard.com
```

Prompts for confirmation before wiping, then exits cleanly so you can edit the config before reinstalling.

### What gets removed

| Item | Location |
|---|---|
| labwc autostart, environment, rc.xml | `~/.config/labwc/` |
| LXDE autostart | `~/.config/lxsession/LXDE-pi/` |
| LXDE desktop background config | `~/.config/pcmanfm/LXDE-pi/` |
| GTK dark theme settings | `~/.config/gtk-3.0/` and `gtk-4.0/` |
| Systemd idle inhibitor service | `~/.config/systemd/user/kiosk-inhibit.service` |
| HA token wrapper page | `~/kiosk-ha-login.html` |
| Xorg blanking config | `/etc/X11/xorg.conf.d/10-kiosk-blanking.conf` |
| Wi-Fi power-save config | `/etc/NetworkManager/conf.d/99-kiosk-wifi-powersave.conf` |
| Nightly shutdown script | `/usr/local/bin/kiosk-shutdown.sh` |
| Cron job | root crontab |
| Hardware watchdog entries | `/etc/systemd/system.conf` |
| LightDM autologin | `/etc/lightdm/lightdm.conf` (commented out) |
| Install marker | `/etc/kiosk-installed` |

> `/var/log/kiosk.log` is intentionally preserved so you have a record of what the previous install did.

### Existing install guard

Running a full install on an already-configured device (without `--reset`) triggers an interactive prompt:

```
[!] An existing kiosk install was detected (/etc/kiosk-installed).
[i]   Installed : 2025-03-01 14:22:00
[i]   URL       : http://192.168.1.100:8123

  Options:
    [r] Reset and reinstall fresh
    [u] Update URL only
    [c] Continue anyway and overwrite
    [q] Quit
```

This prevents accidental overwrites of working installations.

---

## RTC Scheduled Shutdown & Wake

The script **probes the RTC hardware directly** at install time. Scheduling is only activated if all three checks pass:

1. `/sys/class/rtc/rtc0/wakealarm` exists
2. `hwclock -r` succeeds (clock is readable and the module is loaded)
3. The wakealarm sysfs node is writable

If any check fails, the shutdown script and cron job are skipped entirely, and you get a specific message explaining what failed.

### Pi 5 — Built-in RTC

The Pi 5 has a built-in RTC but requires:
- A **CR2032 battery** seated in the J5 header on the board
- An initial time sync: `sudo hwclock --systohc`

Once done, run `--enable-rtc` to activate scheduling without reinstalling.

```bash
sudo hwclock --systohc
sudo bash kiosk-setup.sh --enable-rtc
```

### Pi 4 / Pi 3 / Zero 2W — External RTC Module

Tested with the DS3231 module (recommended). Other I²C RTC modules work too — change the overlay name accordingly.

**Wiring (DS3231):**

| Module Pin | Pi GPIO Header |
|---|---|
| VCC | Pin 1 (3.3V) |
| GND | Pin 6 (GND) |
| SDA | Pin 3 (GPIO 2) |
| SCL | Pin 5 (GPIO 3) |

**Enable the overlay:**

Add to `/boot/firmware/config.txt` (or `/boot/config.txt` on older OS):
```
dtoverlay=i2c-rtc,ds3231
```

**Initialise:**
```bash
sudo reboot
sudo hwclock --systohc    # sync system time → RTC
sudo hwclock -r           # verify it reads back correctly
sudo bash kiosk-setup.sh --enable-rtc
```

### Re-enable after adding hardware

If the RTC wasn't present during the original install, just run:
```bash
sudo bash kiosk-setup.sh --enable-rtc
```

This runs the full three-stage probe, writes the shutdown script, and installs the cron job — without touching any other kiosk configuration. If the hardware still isn't detected, it exits with a specific diagnostic rather than silently failing.

### Test the shutdown/wake cycle manually

```bash
sudo /usr/local/bin/kiosk-shutdown.sh
```

The Pi will shut down and restart at the next scheduled wake time.

---

## On-Screen Keyboard

Set `ENABLE_OSK=true` in `kiosk-setup.sh` before running the install.

The OSK integrates with Chromium's `--enable-virtual-keyboard` flag so it appears and dismisses automatically when text inputs inside the webpage gain and lose focus. No button or manual trigger is needed.

| OS | Package | Behaviour |
|---|---|---|
| Trixie (Wayland) | `wvkbd` | Native Wayland input-method protocol; appears/dismisses automatically |
| Bookworm / Bullseye (X11) | `onboard` | Blackboard dark theme; 4s startup delay; auto-shows on text focus |
| Buster / legacy | `onboard` | May work; not guaranteed |

> **Kiosk mode note:** The OSK only responds to text fields **inside your webpage**. It will not appear for Chromium's own UI (address bar, settings) — which is hidden anyway in kiosk mode.

> **Pi Zero / Pi 1 note:** The OSK will consume significant CPU on low-end hardware. If performance is unacceptable, leave `ENABLE_OSK=false`.

---

## Hardware Watchdog

The hardware watchdog causes the Pi to reboot automatically if the kernel hangs for more than 15 seconds.

| Model | Watchdog | Module |
|---|---|---|
| Pi 5 | ✅ Built-in | None needed |
| Pi 4 / CM4 / Pi 400 | ✅ `bcm2835_wdt` | Loaded automatically |
| Pi 3 / CM3 / Zero 2W | ✅ `bcm2835_wdt` | Loaded automatically |
| Pi 2 | ✅ `bcm2835_wdt` | Loaded automatically |
| Pi Zero / Pi Zero W / Pi 1 | ❌ Not available | Software-only operation |

---

## Low-RAM Memory Flags

On devices with less than 1GB of RAM, the following Chromium flags are automatically added to reduce memory pressure:

```
--js-flags=--max-old-space-size=128
--renderer-process-limit=1
--single-process
--disable-gpu-shader-disk-cache
--disk-cache-size=1
```

> `--single-process` puts the browser and renderer in one process, which saves ~100–200MB but means a renderer crash takes down the whole browser (recovered by the watchdog loop). This is an acceptable tradeoff on constrained hardware.

---

## OS / Compositor Differences

| | Trixie | Bookworm / Bullseye | Buster / legacy |
|---|---|---|---|
| Compositor | Wayland + labwc | X11 + LXDE | X11 |
| Chromium package | `chromium` | `chromium-browser` | `chromium-browser` |
| Autostart location | `~/.config/labwc/autostart` | `~/.config/lxsession/LXDE-pi/autostart` | `~/.config/lxsession/LXDE-pi/autostart` |
| Cursor hiding | labwc `rc.xml` timeout | `unclutter` daemon | `unclutter` daemon |
| Screen blanking | systemd inhibitor service | `xset s off` + Xorg config | `xset s off` + Xorg config |
| Black background | `swaybg -c 000000` | `xsetroot` + LXDE desktop color | `xsetroot` |
| Dark mode (system) | GTK + labwc env + portal | GTK only | GTK only (Adwaita-dark may be missing) |
| Display rotation | `wlr-randr` (configurable) | X11 RandR (not scripted) | Not scripted |
| GPU overlay (Pi 4) | `vc4-kms-v3d` | `vc4-fkms-v3d` | `vc4-fkms-v3d` |
| GPU overlay (Pi 3 / older) | `vc4-kms-v3d` | `vc4-fkms-v3d` | `vc4-fkms-v3d` |
| GPU overlay (Pi 5) | `vc4-kms-v3d` (native) | `vc4-kms-v3d` (native) | N/A |
| OSK | `wvkbd` | `onboard` | `onboard` (may not work) |

---

## Updating the URL

```bash
sudo bash kiosk-setup.sh --update-url https://new-dashboard.com
```

The script updates a single sentinel line in the autostart file and exits. The Chromium crash watchdog loop reads this line each time it relaunches, so the new URL takes effect automatically after:

```bash
sudo pkill chromium     # watchdog relaunches with new URL
# — or —
sudo reboot
```

This is the recommended workflow when IP addresses or hostnames change after a network reconfiguration — no reinstall needed.

---

## File Layout

```
ha-pi-smarthome/
├── kiosk-setup.sh
└── README.md

After install — files created on the Pi:

Trixie (Wayland):
  ~/.config/labwc/autostart                  Launcher + crash watchdog
  ~/.config/labwc/environment                Dark mode env vars, ozone backend
  ~/.config/labwc/rc.xml                     Cursor timeout, bg colour, keybindings
  ~/.config/systemd/user/kiosk-inhibit.service

Bookworm / Bullseye / Buster (X11):
  ~/.config/lxsession/LXDE-pi/autostart      Launcher + crash watchdog
  ~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf   Black desktop bg

Both:
  ~/.config/gtk-3.0/settings.ini             GTK dark theme
  ~/.config/gtk-4.0/settings.ini             GTK4 dark theme
  ~/kiosk-ha-login.html                      HA token wrapper + browser_mod ID pre-seeder
                                             (HA_AUTO_LOGIN=true + HA_TOKEN set)
  ~/kiosk-bmod-preloader.html               Standalone browser_mod ID pre-seeder
                                             (ENABLE_BROWSER_MOD=true, HA_AUTO_LOGIN=false)
  ~/.config/chromium-kiosk/                  Persistent Chromium profile (ENABLE_BROWSER_MOD=true)
  /etc/kiosk-browser-mod-id                  Stored Browser ID — cat to retrieve anytime
  /etc/X11/xorg.conf.d/10-kiosk-blanking.conf    (X11 only)
  /usr/local/bin/kiosk-shutdown.sh           (only if RTC detected)
  /usr/local/bin/kiosk-display-api.py        Display brightness/power API (ENABLE_DISPLAY_API=true)
  /etc/kiosk-display.conf                    Display API runtime config
  /etc/systemd/system/kiosk-display-api.service
  /etc/kiosk-installed                       Install state marker (URL, OS, Pi, RTC/OSK/HA/
                                             browser_mod/display API state, package list)
  /var/log/kiosk.log                         Kiosk runtime log
  /var/log/kiosk-display.log                 Display API log (ENABLE_DISPLAY_API=true)
  /etc/logrotate.d/kiosk                     Log rotation (both logs)
  /etc/NetworkManager/conf.d/99-kiosk-wifi-powersave.conf

Repo files (used during install, kept for updates):
  kiosk-setup.sh                             Main setup script (do not edit — use kiosk.conf)
  kiosk.conf                                 Your local settings (git-ignored, survives pulls)
  kiosk.conf.example                         Template — copy to kiosk.conf to get started
  kiosk-display-api.py                       Display API source (copied to /usr/local/bin/)
  ha-display-config.yaml                     HA config for hardware brightness control
  ha-browser-mod-config.yaml                 HA config for browser_mod popups/navigation
```

---

## Display Brightness & Power Control

The script installs a lightweight HTTP API that gives Home Assistant full hardware control over the Waveshare (and any DDC/CI-capable) display — set brightness to any level from 0–100, or turn the backlight completely off while the Pi stays running. This is real hardware control: actual backlight current changes, not a software overlay.

**Yes — HA can control brightness and backlight** via the display API + `ha-display-config.yaml`. For the Waveshare 10.1DP-CAPLCD specifically, DDC/CI over HDMI is confirmed as the correct method (`ddcutil setvcp 10 <value>`), and the script wires this up automatically when `ENABLE_DISPLAY_API=true` and `WAVESHARE_10DP=true`.

### Enabling

Set `ENABLE_DISPLAY_API=true` in `kiosk-setup.sh` before running (or re-running) the install. Also copy `kiosk-display-api.py` from the repo to the same directory as `kiosk-setup.sh` on the Pi.

```bash
sudo bash kiosk-setup.sh https://your-dashboard.com
```

The API starts automatically on boot via a systemd service and listens on port `2701` (configurable via `DISPLAY_API_PORT`).

### Display type auto-detection

| Priority | Backend | When used |
|---|---|---|
| 1 | **sysfs backlight** | Official Pi touchscreen (DSI), some HDMI displays with kernel backlight driver |
| 2 | **DDC/CI via `ddcutil`** | HDMI monitors that support the DDC/CI protocol (most modern monitors) |
| 3 | **None** | API still runs but brightness calls are no-ops; screen on/off still works via compositor |

Run `ddcutil detect` after install to confirm DDC/CI is available on your display. If it shows "Display 1", brightness control will work. If not, check whether your monitor has DDC/CI enabled in its OSD menu.

### API endpoints

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/health` | `{"status": "ok", "uptime": N}` |
| `GET` | `/status` | Backend type, current brightness, compositor, output name |
| `GET` | `/brightness` | `{"brightness": 75}` (0–100) |
| `POST` | `/brightness` | Body: `{"value": 75}` or query: `?value=75` |
| `POST` | `/screen/off` | Turn display off (Pi stays fully running) |
| `POST` | `/screen/on` | Turn display back on |

### Testing the API

```bash
# From another machine on the same network:
curl http://KIOSK_IP:2701/health
curl http://KIOSK_IP:2701/status
curl http://KIOSK_IP:2701/brightness
curl -X POST http://KIOSK_IP:2701/brightness -H "Content-Type: application/json" -d '{"value": 50}'
curl -X POST http://KIOSK_IP:2701/screen/off
curl -X POST http://KIOSK_IP:2701/screen/on
```

### Home Assistant integration

Use `ha-display-config.yaml` from the repo — it contains ready-to-paste snippets for:
- `rest_command` entries (set brightness, screen on/off)
- `sensor` (current brightness, display status, API health)
- `number` entity (brightness slider 0–100 in the HA dashboard)
- `switch` entity (screen on/off toggle)
- `light` entity (combines brightness + on/off into a single HA light, compatible with Google Home / Alexa)
- Example `automation` entries (dim at night, turn off when away, restore at sunrise)
- Lovelace card YAML

Replace `KIOSK_IP` and `KIOSK_PORT` in the file with your Pi's IP and API port. The script prints these values at the end of install when `ENABLE_DISPLAY_API=true`.

### Troubleshooting the display API

```bash
# Check service status
sudo systemctl status kiosk-display-api.service

# Watch live logs
sudo journalctl -fu kiosk-display-api.service

# Test DDC/CI availability
ddcutil detect
ddcutil getvcp 10   # read current brightness

# Check sysfs backlight
ls /sys/class/backlight/
cat /sys/class/backlight/*/brightness
cat /sys/class/backlight/*/max_brightness
```

---

## Home Assistant Auto-Login

The recommended and simplest setup is **Trusted Networks only** — no token, no files to copy to HA, nothing extra to maintain. The token wrapper page is an optional belt-and-suspenders fallback if you want it.

### Method 1 — Trusted Networks (recommended, no token needed)

Tells HA to automatically authenticate any device on your local subnet. Set `HA_AUTO_LOGIN=true` and leave `HA_TOKEN=""` in `kiosk.conf`. The script prints the exact YAML block to add to HA during install.

**Add to `configuration.yaml` on your HA instance:**

```yaml
homeassistant:
  auth_providers:
    - type: trusted_networks
      trusted_networks:
        - 192.168.1.0/24      # your subnet — script auto-detects and prints this
        - 127.0.0.1
      trusted_users:
        192.168.1.0/24:
          - user_id: YOUR_HA_USER_ID
      allow_bypass_login: true
    - type: homeassistant    # keep this so other devices still log in normally
```

**Finding `YOUR_HA_USER_ID`:**
HA → Settings → People → click your user → copy the long hex ID from the browser URL bar.

**After editing:**
HA → Developer Tools → Check Configuration → Restart HA.

With `allow_bypass_login: true` HA skips both the login screen and the user selection screen entirely for local network devices.

---

### Method 2 — Token Wrapper Page (optional, belt-and-suspenders)

If you want a fallback that doesn't rely on Trusted Networks, set `HA_TOKEN` to a long-lived access token. The script generates `~/kiosk-ha-login.html` which injects the token into HA's localStorage and then redirects to your dashboard.

**Important:** The wrapper page must be served from the HA origin, not from `file://`. Copy it to your HA server after install:

```bash
# Get the file contents from the Pi
cat ~/kiosk-ha-login.html
# Paste into /config/www/kiosk-ha-login.html via HA File Editor or Terminal add-on
```

The wrapper is then accessible at `http://HA_IP:8123/local/kiosk-ha-login.html` and the kiosk URL is set to that address automatically.

**Create a long-lived access token:**
HA → Profile → Long-Lived Access Tokens → Create Token → copy it

**Set in `kiosk.conf`:**
```bash
HA_AUTO_LOGIN=true
HA_URL="http://192.168.1.149:8123"
HA_TOKEN="your-token-here"            # must be on ONE line — no line breaks
HA_DASHBOARD_PATH="/dashboard-wall/home"
```

> **Security note:** The token is stored in a local file on the Pi, readable by the kiosk user. Acceptable for a wall panel on a trusted LAN.

---

### Using Both Together

With both Trusted Networks and a token set, `allow_bypass_login: true` handles auth at the HA server level, and the wrapper page handles it at the browser level. Either one alone is sufficient for most setups.

---

### Updating the Token

```bash
sudo bash kiosk-setup.sh --set-token YOUR_NEW_TOKEN
sudo pkill chromium
```

Re-copy `~/kiosk-ha-login.html` to `/config/www/` on your HA server after updating.

---

### Using Trusted Networks Only (no token, simplest setup)

Leave `HA_TOKEN=""` in `kiosk.conf`. The script skips the wrapper page entirely and points Chromium directly at your dashboard URL. Nothing to copy to the HA server. This is the recommended default.

---

## Package Management

### Bloat removal

The script probes for known desktop-only packages and removes any it finds during a full install. None of these are required for kiosk operation:

| Category | Packages removed |
|---|---|
| Wolfram / Mathematica | `wolfram-engine`, `wolfram-script` |
| LibreOffice | Full suite (`libreoffice*`) |
| Scratch | `scratch`, `scratch3`, `scratch3-upstream-resources` |
| Sonic Pi | `sonic-pi`, `sonic-pi-server` |
| Thonny IDE | `thonny`, `python3-thonny` |
| Minecraft | `minecraft-pi`, `python3-minecraftpi` |
| Java IDEs | `greenfoot`, `bluej` |
| Desktop games | `timidity`, `gnome-games`, `freeciv-*` |
| Unused apps | `geany`, `claws-mail`, `galculator`, `nodered` |

Only packages that are **actually installed** on the device are removed — nothing happens if a package isn't present. Set `REMOVE_BLOAT=false` in the config block to skip this entirely.

After the targeted removal the script always runs:
```bash
apt-get autoremove --purge   # remove orphaned dependencies
apt-get autoclean            # clear the local package cache
```

### Package tracking and reset

The install marker (`/etc/kiosk-installed`) records exactly which packages the script installed via the `INSTALLED_PKGS` field. The package list varies depending on your OS, compositor, and whether the OSK was enabled — it is built at install time and stored automatically, so you never need to set it manually.

When you run `--reset`, the script reads `INSTALLED_PKGS` back from the marker and offers to remove only those packages — nothing else is touched:

```
[?] Remove kiosk packages installed by this script? [Y/n]
```

Answering Y removes the tracked packages, runs `autoremove`, and cleans the cache. Answering N leaves packages in place and only wipes the config files.

---

## Troubleshooting

### RTC not detected

```bash
# Run the built-in diagnostic
sudo bash kiosk-setup.sh --enable-rtc

# Check each stage manually
ls -la /sys/class/rtc/rtc0/wakealarm    # does the node exist?
sudo hwclock -r                          # is the clock readable?
echo 0 | sudo tee /sys/class/rtc/rtc0/wakealarm  # is it writable?
```

For Pi 4 with DS3231: confirm `dtoverlay=i2c-rtc,ds3231` is in config.txt and the Pi has been rebooted since adding it.

For Pi 5: confirm the CR2032 battery is in the J5 header and `sudo hwclock --systohc` has been run.

### Screen goes blank / turns off

- **Trixie:** `systemctl --user status kiosk-inhibit.service`
- **Bookworm / Bullseye:** confirm `xset -dpms` and `xset s off` appear in the autostart

### Desktop flash before Chromium loads

- **Trixie:** `pgrep swaybg` — confirm it's running
- **Bookworm / Bullseye:** check `~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf` contains `desktop_bg=#000000`

### Chromium keeps crashing or restarting

```bash
tail -f /var/log/kiosk.log    # watch exit codes
```

High exit codes (137 = OOM kill) on low-RAM devices — consider simpler pages or a higher-tier Pi.

### OSK not appearing

- Confirm `ENABLE_OSK=true` was set before running the install
- **Trixie:** `pgrep wvkbd` — if not running, check the autostart
- **X11:** `pgrep onboard` — if not running, check the autostart
- Confirm `--enable-virtual-keyboard` appears in the Chromium flags in the autostart file

### URL unreachable on boot (blank screen)

The network wait retries for 30 seconds. If your network takes longer:

```bash
# Edit MAX_WAIT in the autostart file
nano ~/.config/labwc/autostart          # Trixie
nano ~/.config/lxsession/LXDE-pi/autostart   # Bookworm/Bullseye
```

Increase `MAX_WAIT=30` to a higher value (e.g. `60`).

### Display rotation (Trixie only)

```bash
wlr-randr    # find your output name
```

Set `DISPLAY_OUTPUT` and `DISPLAY_TRANSFORM` in `kiosk-setup.sh` and re-run the install.

### Wrong Chromium package installed

The script auto-detects the package name. If Chromium fails to launch, check which binary exists:

```bash
which chromium
which chromium-browser
```

The script auto-detects the correct package (`chromium` on Trixie, `chromium-browser` on Bookworm/Bullseye). If neither binary exists, install Chromium manually:
```bash
sudo apt-get install chromium           # Trixie
sudo apt-get install chromium-browser   # Bookworm / Bullseye
```

### Pi Zero / Pi 1 — Chromium won't start

These devices have very limited RAM. Try:

```bash
# Reduce GPU memory split to give more to Chromium
echo "gpu_mem=16" | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

If Chromium still fails, consider a lighter browser (`surf`, `midori`) or upgrade to a Pi Zero 2W or Pi 3.

### Black screen with cursor — Chromium never launches

This means the autostart ran but died before the Chromium watchdog loop started. Two confirmed causes:

**Cause 1 — Log file permission denied:**
The kiosk user cannot write to `/var/log/`. If the log is pointing there, the `>>` redirect crashes the entire script.
```bash
# Check where the log is pointing
grep "KIOSK_LOG" ~/.config/labwc/autostart
# Should be ~/kiosk.log NOT /var/log/kiosk.log
```
If it shows `/var/log/kiosk.log`, pull the latest script and reinstall — the log path was fixed in v1.7.0.

**Cause 2 — Autostart not running as bash:**
labwc runs the autostart with `sh` if the file is not executable. Any bash-only syntax (arrays, `+=`) causes a silent error.
```bash
ls -la ~/.config/labwc/autostart   # must show -rwxr-xr-x (executable)
sh -n ~/.config/labwc/autostart    # must show no syntax errors
```
Fix: `chmod +x ~/.config/labwc/autostart`

### Chromium launches but exits after 2–5 seconds

Exit code 0 means Chromium intentionally quit — not a crash. This happens when `--kiosk` was not passed (Chromium opened in a normal window and then closed). Usually caused by the autostart's Chromium command being broken by blank lines or bad quoting.
```bash
# Check the chromium line in the autostart
grep "chromium" ~/.config/labwc/autostart
# Should be ONE long line with all flags including --kiosk
```
If you see multiple lines, arrays, or eval — pull the latest script (fixed in v1.7.0) and reinstall.

### Settings overwritten by git pull

Never edit `kiosk-setup.sh` directly. Put your settings in `kiosk.conf` instead:
```bash
cp kiosk.conf.example kiosk.conf
nano kiosk.conf
```
`kiosk.conf` is git-ignored and survives every `git pull`. See the [Configuration](#configuration) section.

### Home Assistant login screen still appearing

**Check 1 — Trusted Networks not configured:**
Confirm you added the YAML block printed during install to `configuration.yaml` and restarted HA. The YAML is printed at the end of every install when `HA_AUTO_LOGIN=true`.

**Check 2 — Wrong subnet in the YAML:**
The script auto-detects the subnet from the Pi's default route. If your network changed since install, update the subnet in `configuration.yaml` manually and restart HA.

**Check 3 — allow_bypass_login missing:**
The user selection screen appears (pick which user) when `allow_bypass_login: true` is missing from the Trusted Networks YAML. Add it and restart HA.

**Check 4 — Token wrapper not loading (if using HA_TOKEN):**
If using a token, confirm the wrapper page is on the HA server:
```bash
# From the Pi — does the URL respond?
curl -I http://192.168.1.149:8123/local/kiosk-ha-login.html
# Should return HTTP 200, not 404
```
If 404, copy `~/kiosk-ha-login.html` to `/config/www/kiosk-ha-login.html` on the HA server via File Editor.

**Check 5 — Token expired or revoked:**
```bash
sudo bash kiosk-setup.sh --set-token YOUR_NEW_TOKEN
sudo pkill chromium
```
Re-copy `~/kiosk-ha-login.html` to `/config/www/` on the HA server after updating.

**Check 6 — HA IP changed:**
Update `kiosk.conf` with the new IP and reset:
```bash
nano ~/ha-pi-smarthome/kiosk.conf   # update HA_URL
sudo bash ~/ha-pi-smarthome/kiosk-setup.sh --reset http://NEW_IP:8123/dashboard-wall/home
sudo reboot
```

**Token injection not working — localStorage origin mismatch:**
The wrapper page must be served from the **same origin as HA** (`http://HA_IP:8123/local/...`), not from `file://`. localStorage is strictly origin-scoped — a token written at `file://` is invisible to HA at `http://`.

Check where your kiosk is pointed:
```bash
grep "KIOSK_URL_VALUE" ~/.config/labwc/autostart
# Must show: http://HA_IP:8123/local/kiosk-ha-login.html
# Must NOT show: file:///home/...
```

If it shows `file://`, the wrapper page needs to be on your HA server:
1. Copy `~/kiosk-ha-login.html` to `/config/www/kiosk-ha-login.html` on your HA machine
2. Update the autostart: `sed -i 's|KIOSK_URL_VALUE=.*|KIOSK_URL_VALUE=http://HA_IP:8123/local/kiosk-ha-login.html|' ~/.config/labwc/autostart`
3. `sudo pkill chromium` — watchdog relaunches with new URL


### browser_mod not registering the kiosk

**How browser_mod ID works in this setup:**
The script appends `?BrowserID=your-id` to the kiosk URL. browser_mod reads this parameter when the HA frontend loads and registers with that ID. No localStorage manipulation, no files to copy — just a URL parameter.

**Check 1 — BrowserID in the URL:**
```bash
grep "KIOSK_URL_VALUE" ~/.config/labwc/autostart   # Trixie
grep "KIOSK_URL_VALUE" ~/.config/lxsession/LXDE-pi/autostart  # Bookworm
```
The URL must include `?BrowserID=your-id`. If it doesn't, confirm `ENABLE_BROWSER_MOD=true` and `BROWSER_MOD_ID="your-id"` are set in `kiosk.conf` and re-run `--reset`.

**Check 2 — incognito mode active:**
browser_mod requires a persistent Chromium profile to maintain registration across restarts. Confirm `--user-data-dir` is in the Chromium flags, not `--incognito`:
```bash
grep "incognito\|user-data-dir" ~/.config/labwc/autostart
```
If `--incognito` appears, `ENABLE_BROWSER_MOD=true` wasn't set during install. Re-run `--reset`.

**Check 3 — Profile directory exists:**
```bash
ls ~/.config/chromium-kiosk/Default/
```
If this directory is missing or empty, the persistent profile never got created. Re-run `--reset` with `ENABLE_BROWSER_MOD=true`.

**Check 4 — browser_mod installed in HA:**
Confirm browser_mod is installed via HACS and the integration is added in Settings → Devices & Services. Check the Browser Mod panel in the HA sidebar — the kiosk should appear within 10 seconds of Chromium loading.

**Check 5 — Kiosk appears with wrong/random ID:**
browser_mod may be holding an old registration on the HA side. Fix it without touching the Pi:
- HA → Browser Mod panel (sidebar) → find the kiosk → click its ID → rename it to the correct value

**Check 6 — Register toggle:**
In the Browser Mod panel, confirm the Register toggle is on for the kiosk. Without it, the kiosk connects but doesn't create HA entities.

**Check 7 — browser_mod interaction icon not visible:**
The interaction icon (small circle, bottom-right of HA) signals that browser_mod needs a user gesture before it can play audio/video. In kiosk mode with `--kiosk` the browser chrome is hidden but the HA page content still shows. If you can't see or click the icon, rename the browser ID from the HA Browser Mod panel instead — that doesn't require any interaction on the kiosk display.

### Display API not responding

```bash
# Check the service is running
sudo systemctl status kiosk-display-api.service

# Check logs for backend detection result
sudo journalctl -u kiosk-display-api.service | head -20

# Test endpoints directly from the Pi
curl http://localhost:2701/health
curl http://localhost:2701/status
curl -X POST http://localhost:2701/brightness -H "Content-Type: application/json" -d '{"value":50}'
```

If the service shows `backend: none`, DDC/CI was not detected. Follow the Waveshare DDC/CI steps below, then restart the service:
```bash
sudo systemctl restart kiosk-display-api.service
```

### Waveshare display wrong resolution or no display

Confirm the resolution lines are in `/boot/firmware/config.txt`:
```bash
grep -A4 "Waveshare" /boot/firmware/config.txt
```
If missing, set `WAVESHARE_10DP=true` and re-run the install, then reboot.

### Waveshare DDC/CI brightness not working

```bash
sudo ddcutil detect          # must show "Display 1"
sudo modprobe i2c-dev        # load I2C module if not auto-loaded
sudo ddcutil setvcp 10 50    # test directly
```
If `detect` still fails, enable DDC/CI in the display OSD: Menu button → Advanced or Settings → DDC/CI → Enable.

### Bloat removal left something behind

If a package was missed (e.g. a new Pi OS image added a new bloat package), remove it manually:
```bash
sudo apt-get remove --purge <package-name>
sudo apt-get autoremove --purge
```
To add it to the script's removal list permanently, add its name to the `BLOAT_PKGS` array in `kiosk-setup.sh`.

---

## browser_mod Integration

[browser_mod](https://github.com/thomasloven/hass-browser_mod) is a HACS integration that registers each Chromium kiosk instance as a device in HA, enabling:

- **Popups** — show any HA card as a fullscreen or dialog overlay (`browser_mod.popup`)
- **Navigation** — send the kiosk to a different dashboard from an automation (`browser_mod.navigate`)
- **Doorbell alerts** — pop up a live camera feed when the doorbell rings
- **Critical notifications** — non-dismissable alert overlays for smoke/CO alarms
- **Software screen blackout** — CSS black overlay via the browser_mod `light` entity

### Setup

**Step 1 — Build the kiosk with browser_mod enabled:**
```bash
# In kiosk-setup.sh, set:
ENABLE_BROWSER_MOD=true
BROWSER_MOD_ID="kiosk-living-room"   # pick a name — becomes the HA entity ID
```

This removes `--incognito` and switches Chromium to a persistent profile at `~/.config/chromium-kiosk`. Without this, browser_mod cannot retain its device ID across restarts.

The `BROWSER_MOD_ID` is pre-seeded into `localStorage` before the HA frontend loads, so browser_mod registers with exactly this ID every time — no random UUID, no manual copy-paste. If you leave `BROWSER_MOD_ID` empty, the script auto-generates a stable ID from the Pi's serial number so it survives reinstalls on the same hardware.

The ID is stored on disk for easy retrieval:
```bash
cat /etc/kiosk-browser-mod-id
# or
grep BROWSER_MOD_ID /etc/kiosk-installed
```

To change it without reinstalling:
```bash
sudo bash kiosk-setup.sh --set-browser-id kiosk-bedroom
sudo pkill chromium   # watchdog relaunches with new ID
```

**HA entity IDs are predictable** once the ID is set. For `BROWSER_MOD_ID="kiosk-living-room"`:
```
light.browser_mod_kiosk_living_room
media_player.browser_mod_kiosk_living_room
binary_sensor.browser_mod_kiosk_living_room
```
Use these directly in your automations — no hunting for random device IDs in the browser_mod panel.

**Step 2 — Install browser_mod in HA:**
```
HA → HACS → Integrations → Search "Browser Mod" → Download
HA → Settings → Devices & Services → Add Integration → Browser Mod
Restart HA
```

**Step 3 — Register the kiosk:**
After the kiosk reboots and Chromium loads your dashboard, the kiosk auto-registers. Go to:
```
HA → Browser Mod panel (sidebar)
```
The kiosk appears in the registered browsers list. Note the Browser ID (e.g. `a1b2c3d4-e5f6a7b8`) — you need it to target this kiosk in automations.

**Step 4 — Configure the kiosk browser settings:**
In the Browser Mod panel, click the settings icon next to the kiosk and enable:
- **Hide sidebar** — keeps the UI clean in kiosk mode
- **Always on top** — prevents HA dialogs from appearing behind the kiosk window

**Step 5 — Add the HA configuration:**
Use `ha-browser-mod-config.yaml` from the repo. Replace `KIOSK_BROWSER_ID` with your actual Browser ID throughout.

### browser_mod light entity vs display API

This is the most important thing to understand about the combined setup:

| | browser_mod `light` entity | Display API (`ddcutil`) |
|---|---|---|
| What it does | CSS black overlay drawn in the browser | Controls physical backlight via DDC/CI |
| Hardware power saved | ❌ No — panel still at full brightness | ✅ Yes — backlight current drops significantly |
| Response time | Instant | ~1-2 seconds (DDC/CI latency) |
| Works without display API | ✅ Yes | ✅ Yes (independent) |
| Best for | Visual screensaver, partial dimming overlay | Actual power saving, true screen off |

**Best practice — use both together:** browser_mod overlay for instant visual response, display API for actual power reduction. The example automations in `ha-browser-mod-config.yaml` demonstrate this pattern.

### Ready-to-use automations in ha-browser-mod-config.yaml

| Automation | Trigger |
|---|---|
| Doorbell camera popup | Doorbell binary_sensor → on |
| Motion alert popup | Motion sensor → on, nobody home |
| Navigate on rain | Weather precipitation > 0 |
| Return to main dashboard | Every 15 minutes |
| Software blackout when away | Presence group → not_home for 5 min |
| Restore screen when home | Presence group → home |
| Adaptive night dimming | 10 PM — hardware dim + overlay |
| Full brightness morning | 7 AM |
| Critical alert popup | Smoke detector → on (non-dismissable) |

---

## Waveshare 10.1DP-CAPLCD Display

The Waveshare 10.1DP-CAPLCD is confirmed compatible with this kiosk setup. Set `WAVESHARE_10DP=true` in `kiosk-setup.sh` before running the install.

### What the script configures automatically

**Display resolution** — adds to `/boot/firmware/config.txt`:
```
hdmi_group=2
hdmi_mode=87
hdmi_cvt 1280 800 60 6 0 0 0
hdmi_drive=1
```
This sets the correct 1280×800 resolution. Without it, the Pi may output the wrong resolution and the display will look wrong.

**DDC/CI brightness** — installs `ddcutil` and confirms it is the correct brightness control method for this display. There is no sysfs backlight path for this display — DDC/CI over HDMI is the only software brightness control available.

### Verify DDC/CI works after reboot

```bash
sudo ddcutil detect          # should show "Display 1"
sudo ddcutil getvcp 10       # read current brightness value
sudo ddcutil setvcp 10 50    # set to 50%
```

If `ddcutil detect` shows nothing, check:
1. The HDMI cable is connected (not just USB-C power)
2. DDC/CI is enabled in the display OSD menu (Menu button → Advanced → DDC/CI → On)
3. Run `sudo modprobe i2c-dev` and retry

### Touch screen setup

The touch USB cable must be connected to a Pi USB port. It registers as a USB HID device — no driver needed on any supported OS. If touch isn't working:
```bash
lsusb | grep -i "waltop\|eeti\|ili"   # confirm USB HID device appears
xinput list                             # Bookworm/X11 — confirm touch device listed
```

---

## Suggestions & Ideas

Based on the full setup, here are features worth considering next:

### Popup automations — companion repo
The [ha-custom-automation](https://github.com/johnpernock/ha-custom-automation) repo contains ready-to-use browser_mod popup cards for this kiosk setup (in `kiosk/popups/`):
- **NWS weather alerts** — severity-tiered (Extreme/Severe/Moderate/Minor), color-coded, wakes displays
- **Doorbell camera** — 30-second live feed on both displays when the bell rings
- **SEPTA train delays** — fires when your next train exceeds a delay threshold; matches the septa-paoli-card in the dashboard

All cards are fully self-contained single JS files — no dependencies, drop in and register.

### browser_mod (HACS integration)
Install [browser_mod](https://github.com/thomasloven/hass-browser_mod) in Home Assistant. It registers each Chromium kiosk instance as a "browser device" in HA, giving you:
- Wake/sleep the display from HA automations
- Navigate to a different dashboard from an HA automation (e.g. show a camera feed when a doorbell rings)
- Show popup alerts on the kiosk screen
- Play audio through the Pi's audio output
No additional scripting needed — it works entirely through the HA frontend.

### Screen on/off on schedule (without full shutdown)
If you don't have an RTC module, you can still save power by turning off the display backlight at night while keeping the Pi running. The display API's `/screen/off` and `/screen/on` endpoints handle this. Pair them with the example automations in `ha-display-config.yaml`.

### Read-only filesystem (SD card protection)
Wall-mounted Pis that run 24/7 are at risk of SD card corruption on power loss. Consider overlayfs or `raspi-config → Performance → Overlay File System` to make the root filesystem read-only. The kiosk will still work normally; only logs and the install marker need write access (mount `/var/log` as a tmpfs or use a separate USB drive).

### Health reporting to HA via MQTT
A small systemd service that publishes kiosk health metrics (Chromium running, last URL loaded, uptime, CPU temp, memory usage) to an MQTT broker lets you monitor all kiosks from a single HA dashboard. Pairs well with `mosquitto` on the same Pi that runs HA.

### Auto-update from git
A weekly cron job that does `git pull && sudo bash kiosk-setup.sh --update-url "$(grep ^URL= /etc/kiosk-installed | cut -d= -f2)"` keeps the kiosk script current without manual SSH sessions.

### SSH hardening
Since these Pis are always-on and network-connected, consider:
```bash
# Disable password auth (key-only login)
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```
Do this only after confirming your SSH key works for login.

### Multiple kiosk displays

Each Pi gets its own clone of the repo and its own `kiosk.conf`. The only value that differs between displays is `BROWSER_MOD_ID`.

**Example — two wall panels:**

Pi 1 `kiosk.conf`:
```bash
KIOSK_URL="http://192.168.1.149:8123/dashboard-wall/home"
HA_AUTO_LOGIN=true
HA_URL="http://192.168.1.149:8123"
HA_TOKEN=""
HA_DASHBOARD_PATH="/dashboard-wall/home"
ENABLE_BROWSER_MOD=true
BROWSER_MOD_ID="kiosk-front-door"
ENABLE_DISPLAY_API=true
WAVESHARE_10DP=true
REMOVE_BLOAT=true
```

Pi 2 `kiosk.conf`:
```bash
KIOSK_URL="http://192.168.1.149:8123/dashboard-wall/home"
HA_AUTO_LOGIN=true
HA_URL="http://192.168.1.149:8123"
HA_TOKEN=""
HA_DASHBOARD_PATH="/dashboard-wall/home"
ENABLE_BROWSER_MOD=true
BROWSER_MOD_ID="kiosk-garage"
ENABLE_DISPLAY_API=true
WAVESHARE_10DP=true
REMOVE_BLOAT=true
```

The `?BrowserID=` parameter is appended to each Pi's URL automatically so both register with correct, distinct IDs in browser_mod. No wrapper page or file copying required when using Trusted Networks.

**Updating all displays at once:**
```bash
for IP in 192.168.1.x 192.168.1.y; do
  ssh johnpernock@$IP "cd ~/ha-pi-smarthome && git pull && sudo bash kiosk-setup.sh --update-url http://192.168.1.149:8123/dashboard-wall/home"
done
```

---

## Voice Assistant (Optional)

A companion repo handles voice satellite setup — completely separate from the kiosk install. Can run on the same Pi or a dedicated device.

**→ [ha-voice-sattelite](https://github.com/johnpernock/ha-voice-sattelite)**

Supports ReSpeaker 2-Mic HAT V2.0, ReSpeaker Lite (USB), generic USB mic, or any ALSA device. Connects to HA via ESPHome protocol, auto-discovered.

---

## Related Repositories

| Repo | Purpose |
|---|---|
| [ha-pi-smarthome](https://github.com/johnpernock/ha-pi-smarthome) | This repo — kiosk OS setup, display API, browser_mod wiring |
| [ha-custom-cards](https://github.com/johnpernock/ha-custom-cards) | Custom Lovelace dashboard cards displayed on the kiosk |
| [ha-voice-sattelite](https://github.com/johnpernock/ha-voice-sattelite) | Voice satellite installer — LVA + ReSpeaker, ESPHome protocol |

---

## License

[MIT](LICENSE) — do whatever you want with it.
