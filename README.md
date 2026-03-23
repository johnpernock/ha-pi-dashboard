# 🖥️ Pi Wall Panel Kiosk

A zero-touch setup script for turning a Raspberry Pi into a wall-mounted display kiosk. Built for **Raspberry Pi OS Trixie (Debian 13)** with Wayland + labwc.

---

## Features

- **Full kiosk mode** — Chromium launches fullscreen with no address bar, no UI chrome, no escape
- **Forced dark mode** — applied at the OS level (GTK), compositor level (labwc env), and browser level (`--force-dark-mode` + `WebContentsForceDark`)
- **No desktop flash** — `swaybg` paints a solid black background before Chromium loads, so the desktop is never visible
- **Crash recovery** — a watchdog loop in the autostart automatically relaunches Chromium if it exits for any reason
- **Network-aware boot** — waits up to 30 seconds for the kiosk URL to be reachable before launching (no blank screen on cold boot)
- **Scheduled shutdown** — cron shuts the Pi down at a configurable time each night
- **RTC wake alarm** — sets a hardware wake alarm so the Pi powers back on at a configurable time each morning
- **Hardware watchdog** — the Pi reboots itself automatically if the kernel hangs for more than 15 seconds
- **Touch controls locked down** — pinch-to-zoom, overscroll, and pull-to-refresh all disabled
- **All infobars suppressed** — no crash restore prompts, no save-password bubbles, no translate offers, no notifications
- **Idempotent URL updates** — re-run with `--update-url` to change the displayed URL without reinstalling anything
- **Wi-Fi power-save disabled** — prevents random network drops on the display
- **Log rotation** — activity logged to `/var/log/kiosk.log` with weekly rotation

---

## Requirements

- Raspberry Pi (any model with HDMI or DSI output)
- Raspberry Pi OS **Trixie** (Debian 13) — desktop variant (not Lite)
- Internet connection during setup
- RTC module (e.g. DS3231) if using the hardware wake alarm feature

> ⚠️ This script is written for **Trixie + Wayland + labwc** specifically. It will not work correctly on Bookworm or earlier without modification.

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/pi-kiosk.git
cd pi-kiosk

# Make executable
chmod +x kiosk-setup.sh

# Run as root, passing your kiosk URL
sudo bash kiosk-setup.sh https://your-dashboard.com

# Reboot to launch the kiosk
sudo reboot
```

---

## Configuration

All user-configurable settings are grouped at the top of `kiosk-setup.sh` under the **CONFIG** banner — no need to dig through the script logic.

| Variable | Default | Description |
|---|---|---|
| `KIOSK_URL` | `https://example.com` | URL to display (also set via argument) |
| `SHUTDOWN_HOUR` | `0` | Hour to shut down (24h) |
| `SHUTDOWN_MINUTE` | `0` | Minute to shut down |
| `WAKE_HOUR` | `6` | Hour to wake via RTC alarm (24h) |
| `WAKE_MINUTE` | `0` | Minute to wake |
| `DISPLAY_TRANSFORM` | `normal` | Display rotation: `normal`, `90`, `180`, `270` |
| `DISPLAY_OUTPUT` | `HDMI-A-1` | Wayland output name (see note below) |
| `AUTO_RELOAD_SECONDS` | `0` | Reload page every N seconds (`0` = disabled) |

### Finding your display output name

After first boot, run:
```bash
wlr-randr
```
Common values: `HDMI-A-1`, `HDMI-A-2`, `DSI-1` (official Pi touchscreen).

---

## Updating the URL

The script is safe to re-run at any time. To update just the URL without reinstalling:

```bash
sudo bash kiosk-setup.sh --update-url https://new-dashboard.com
```

Then reboot (or `sudo pkill chromium`) to apply.

This is useful when IP addresses or hostnames change after a network reconfiguration.

---

## RTC Wake Alarm

The nightly shutdown script (`/usr/local/bin/kiosk-shutdown.sh`) writes a wake epoch to `/sys/class/rtc/rtc0/wakealarm` before powering down, so the Pi wakes itself up at the configured time without any external smart plug or timer.

### Verify your RTC is working

```bash
# Read the hardware clock
sudo hwclock -r

# Sync system time to the RTC (do this after setting the correct system time)
sudo hwclock --systohc

# Manually test the full shutdown + wake cycle
sudo /usr/local/bin/kiosk-shutdown.sh
```

> If your Pi does not have an RTC module, the wake alarm will not work. In that case, use a smart plug on a timer as an alternative.

---

## File Layout

```
pi-kiosk/
├── kiosk-setup.sh                   # Main setup script
└── README.md                        # This file

After install, the following files are created on the Pi:
~/.config/labwc/
├── autostart                        # Session autostart (Chromium launcher + watchdog)
├── environment                      # Wayland env vars (dark mode, ozone backend)
└── rc.xml                           # Compositor config (cursor hiding, keybindings)
~/.config/gtk-3.0/settings.ini       # GTK dark theme
~/.config/gtk-4.0/settings.ini       # GTK4 dark theme
~/.config/systemd/user/
└── kiosk-inhibit.service            # Idle/blank inhibitor service
/usr/local/bin/kiosk-shutdown.sh     # Nightly shutdown + RTC wake script
/etc/kiosk-installed                 # Install marker (enables --update-url mode)
/var/log/kiosk.log                   # Runtime log
```

---

## Troubleshooting

**Chromium shows a white flash before loading**
This shouldn't happen with `swaybg` installed, but if it does, confirm `swaybg` is running:
```bash
pgrep swaybg
```

**Screen goes blank / display turns off**
Check that the inhibitor service is running:
```bash
systemctl --user status kiosk-inhibit.service
```

**Pi doesn't wake up at the right time**
Verify the RTC alarm was set correctly:
```bash
cat /sys/class/rtc/rtc0/wakealarm   # should show a Unix epoch timestamp
sudo hwclock -r                      # confirm hardware clock is correct
```

**Chromium keeps crashing**
Check the log for exit codes:
```bash
tail -f /var/log/kiosk.log
```

**URL is unreachable on boot**
The network wait loop will retry for 30 seconds. If your network takes longer to come up, increase `MAX_WAIT` in `~/.config/labwc/autostart`.

**Display rotation not working**
Find your output name with `wlr-randr`, update `DISPLAY_OUTPUT` in the script, and re-run.

---

## License

MIT — do whatever you want with it.
