# 🖥️ Pi Wall Panel Kiosk

A zero-touch setup script for turning a Raspberry Pi into a wall-mounted display kiosk. Automatically detects your hardware and OS and configures everything accordingly.

## Compatibility

| | Pi 4 | Pi 5 |
|---|---|---|
| **Bookworm** (Debian 12) — X11 + LXDE | ✅ | ✅ |
| **Trixie** (Debian 13) — Wayland + labwc | ✅ | ✅ |

The script detects your OS and Pi model at runtime and branches automatically — no manual configuration needed for compatibility.

---

## Features

- **Auto-detection** — detects OS (Bookworm/Trixie), compositor (X11/Wayland), and Pi model (4/5) at runtime
- **Full kiosk mode** — Chromium launches fullscreen with no address bar, no UI chrome, no escape
- **Dark mode** — forced at OS level (GTK 3 + 4), compositor level, and Chromium level (`--force-dark-mode` + `WebContentsForceDark`)
- **No desktop flash** — black background painted before Chromium loads (Trixie: `swaybg`; Bookworm: `xsetroot` + LXDE desktop color)
- **Crash recovery** — watchdog loop automatically relaunches Chromium on unexpected exit
- **Network-aware boot** — waits up to 30s for the URL to be reachable before launching (no blank screen on cold boot)
- **Scheduled shutdown** — cron shuts the Pi down at a configurable time nightly
- **RTC wake alarm** — Pi 5 uses the built-in RTC; Pi 4 uses an external RTC module (e.g. DS3231)
- **Hardware watchdog** — Pi reboots itself if the kernel hangs for more than 15 seconds
- **Touch controls locked** — pinch-to-zoom, overscroll, and pull-to-refresh disabled
- **All infobars suppressed** — no crash restore prompts, no save-password bubbles, no translate bar, no notifications
- **Idempotent URL updates** — `--update-url` flag changes the displayed URL without reinstalling anything
- **Wi-Fi power-save disabled** — prevents random network drops
- **Log rotation** — activity logged to `/var/log/kiosk.log` with weekly rotation

---

## Requirements

- Raspberry Pi 4 or Raspberry Pi 5
- Raspberry Pi OS **Bookworm** or **Trixie** — desktop variant (not Lite)
- Internet connection during setup
- **Pi 4 only:** External RTC module (e.g. DS3231) if you need the hardware wake alarm

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

## Configuration

All settings are grouped at the top of `kiosk-setup.sh` under the **CONFIG** banner.

| Variable | Default | Description |
|---|---|---|
| `KIOSK_URL` | `https://example.com` | URL to display (also set via argument) |
| `SHUTDOWN_HOUR` | `0` | Hour to shut down (24h) |
| `SHUTDOWN_MINUTE` | `0` | Minute to shut down |
| `WAKE_HOUR` | `6` | Hour to wake via RTC (24h) |
| `WAKE_MINUTE` | `0` | Minute to wake |
| `DISPLAY_TRANSFORM` | `normal` | Rotation: `normal`, `90`, `180`, `270` *(Trixie only)* |
| `DISPLAY_OUTPUT` | `HDMI-A-1` | Wayland output name *(Trixie only)* |
| `AUTO_RELOAD_SECONDS` | `0` | Reload page every N seconds (`0` = disabled) |

### Finding your Wayland display output name (Trixie only)

```bash
wlr-randr
```

Common values: `HDMI-A-1`, `HDMI-A-2`, `DSI-1` (official Pi touchscreen).

---

## Updating the URL

Safe to run at any time — only touches the autostart file, no reinstall:

```bash
sudo bash kiosk-setup.sh --update-url https://new-dashboard.com
sudo reboot
```

This is the recommended workflow when IP addresses or hostnames change after a network reconfiguration.

---

## RTC Wake Alarm

The nightly shutdown script writes a wake epoch to the RTC before powering down, so the Pi starts itself at the configured time without any external timer or smart plug.

### Pi 5 — built-in RTC

```bash
sudo hwclock -r              # verify the hardware clock
sudo hwclock --systohc       # sync system time → RTC (do after NTP sync)
```

### Pi 4 — external RTC module required

Tested with DS3231. Enable in `/boot/firmware/config.txt`:
```
dtoverlay=i2c-rtc,ds3231
```
Then:
```bash
sudo hwclock -r
sudo hwclock --systohc
```

### Test the shutdown/wake cycle

```bash
sudo /usr/local/bin/kiosk-shutdown.sh
```

The Pi will shut down and wake at the next scheduled wake time.

---

## OS / Compositor Differences

| | Bookworm (X11 + LXDE) | Trixie (Wayland + labwc) |
|---|---|---|
| Chromium package | `chromium-browser` | `chromium` |
| Autostart location | `~/.config/lxsession/LXDE-pi/autostart` | `~/.config/labwc/autostart` |
| Cursor hiding | `unclutter` | labwc `rc.xml` timeout |
| Screen blanking | `xset s off` / Xorg config | systemd inhibitor service |
| Black background | `xsetroot` + LXDE desktop color | `swaybg -c 000000` |
| Display rotation | Not supported (Bookworm uses X11 RandR) | `wlr-randr` |
| GPU overlay | `vc4-fkms-v3d` (Pi 4) / `vc4-kms-v3d` (Pi 5) | `vc4-kms-v3d` |

---

## File Layout

```
ha-pi-dashboard/
├── kiosk-setup.sh       # Main setup script
└── README.md

After install (created on the Pi):

Trixie:
~/.config/labwc/
├── autostart            # Session launcher + crash watchdog
├── environment          # Wayland env vars (dark mode, ozone)
└── rc.xml               # Compositor config (cursor, keybindings)

Bookworm:
~/.config/lxsession/LXDE-pi/
└── autostart            # LXDE session launcher + crash watchdog
~/.config/pcmanfm/LXDE-pi/
└── desktop-items-0.conf # Black desktop background

Both:
~/.config/gtk-3.0/settings.ini        # GTK dark theme
~/.config/gtk-4.0/settings.ini        # GTK4 dark theme
~/.config/systemd/user/
└── kiosk-inhibit.service             # Idle/blank inhibitor (Trixie)
/usr/local/bin/kiosk-shutdown.sh      # Nightly shutdown + RTC wake
/etc/kiosk-installed                  # Install marker (enables --update-url)
/var/log/kiosk.log                    # Runtime log
```

---

## Troubleshooting

**Desktop flash before Chromium loads**
- Trixie: confirm `swaybg` is running: `pgrep swaybg`
- Bookworm: check `~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf` has `desktop_bg=#000000`

**Screen goes blank / turns off**
- Trixie: `systemctl --user status kiosk-inhibit.service`
- Bookworm: confirm `xset -dpms` and `xset s off` are in the autostart

**Pi doesn't wake at the right time**
```bash
cat /sys/class/rtc/rtc0/wakealarm    # should show a Unix timestamp
sudo hwclock -r                       # confirm hardware clock is correct
```

**Chromium keeps crashing**
```bash
tail -f /var/log/kiosk.log
```

**URL unreachable on boot**
The network wait retries for 30 seconds. Increase `MAX_WAIT` in the autostart file if your network takes longer.

**Wrong display rotation (Trixie)**
Find your output name: `wlr-randr`
Update `DISPLAY_OUTPUT` and `DISPLAY_TRANSFORM` in the script, then re-run.

---

## License

MIT — do whatever you want with it.
