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
git clone https://github.com/johnpernock/ha-pi-dashboard.git
cd ha-pi-dashboard
chmod +x kiosk-setup.sh
sudo bash kiosk-setup.sh https://your-dashboard.com
sudo reboot
```

---

## Usage

```bash
# Full install
sudo bash kiosk-setup.sh https://your-dashboard.com

# Update the displayed URL — no reinstall, safe to run anytime
sudo bash kiosk-setup.sh --update-url https://new-url.com

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

---

## Configuration

All settings are at the top of `kiosk-setup.sh` under the **CONFIG** section. Edit before running.

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
ha-pi-dashboard/
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
  /etc/X11/xorg.conf.d/10-kiosk-blanking.conf    (X11 only)
  /usr/local/bin/kiosk-shutdown.sh           (only if RTC detected)
  /etc/kiosk-installed                       Install state marker
  /var/log/kiosk.log                         Runtime log
  /etc/logrotate.d/kiosk                     Log rotation config
  /etc/NetworkManager/conf.d/99-kiosk-wifi-powersave.conf
```

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

Update `CHROMIUM_PKG` at the top of `kiosk-setup.sh` if needed and re-run.

### Pi Zero / Pi 1 — Chromium won't start

These devices have very limited RAM. Try:

```bash
# Reduce GPU memory split to give more to Chromium
echo "gpu_mem=16" | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

If Chromium still fails, consider a lighter browser (`surf`, `midori`) or upgrade to a Pi Zero 2W or Pi 3.

---

## License

MIT — do whatever you want with it.
