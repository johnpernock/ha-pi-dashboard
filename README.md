# 🖥️ Pi Wall Panel Kiosk

A zero-touch setup script for turning a Raspberry Pi into a wall-mounted display kiosk. Automatically detects your hardware, OS, and RTC availability and configures everything accordingly.

## Compatibility

| | Pi 4 | Pi 5 |
|---|---|---|
| **Bookworm** (Debian 12) — X11 + LXDE | ✅ | ✅ |
| **Trixie** (Debian 13) — Wayland + labwc | ✅ | ✅ |

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

# Update URL only — no reinstall, safe to run anytime
sudo bash kiosk-setup.sh --update-url https://new-url.com

# Enable RTC shutdown/wake after adding RTC hardware
sudo bash kiosk-setup.sh --enable-rtc
```

---

## Features

- **Auto-detection** — detects OS (Bookworm/Trixie), compositor (X11/Wayland), and Pi model (4/5) at runtime
- **RTC detection** — probes hardware directly; gracefully disables shutdown/wake if no RTC is present with clear instructions to re-enable later
- **Full kiosk mode** — Chromium launches fullscreen with no address bar, no UI chrome, no escape
- **Dark mode** — forced at OS (GTK 3+4), compositor, and Chromium level (`--force-dark-mode` + `WebContentsForceDark`)
- **No desktop flash** — black background before Chromium loads (Trixie: `swaybg`; Bookworm: `xsetroot` + LXDE desktop color)
- **Crash recovery** — watchdog loop automatically relaunches Chromium on unexpected exit
- **Network-aware boot** — waits up to 30s for the URL to be reachable before launching
- **On-screen keyboard** — optional; `wvkbd` (Trixie/Wayland) or `onboard` (Bookworm/X11), toggled via `ENABLE_OSK`
- **Scheduled shutdown + RTC wake** — configurable times; only active when RTC hardware is confirmed present
- **Hardware watchdog** — Pi reboots itself if the kernel hangs for more than 15 seconds
- **Touch controls locked** — pinch-to-zoom, overscroll, and pull-to-refresh all disabled
- **All infobars suppressed** — no crash prompts, save-password bubbles, translate bar, or notifications
- **Wi-Fi power-save disabled** — prevents random network drops
- **Log rotation** — activity logged to `/var/log/kiosk.log` with weekly rotation

---

## Configuration

All settings are at the top of `kiosk-setup.sh` under the **CONFIG** banner.

| Variable | Default | Description |
|---|---|---|
| `KIOSK_URL` | `https://example.com` | URL to display (also set via argument) |
| `SHUTDOWN_HOUR` | `0` | Hour to shut down (24h) — requires RTC |
| `SHUTDOWN_MINUTE` | `0` | Minute to shut down — requires RTC |
| `WAKE_HOUR` | `6` | Hour to wake (24h) — requires RTC |
| `WAKE_MINUTE` | `0` | Minute to wake — requires RTC |
| `ENABLE_OSK` | `false` | Enable on-screen keyboard (`true`/`false`) |
| `DISPLAY_TRANSFORM` | `normal` | Rotation: `normal`, `90`, `180`, `270` *(Trixie only)* |
| `DISPLAY_OUTPUT` | `HDMI-A-1` | Wayland output name *(Trixie only)* |
| `AUTO_RELOAD_SECONDS` | `0` | Reload page every N seconds (`0` = disabled) |

---

## RTC Wake Alarm

The script **probes the RTC hardware directly** at install time rather than assuming it exists. If no RTC is detected, shutdown/wake scheduling is skipped and a clear warning is shown.

### What counts as "detected"

All three of these must pass:
1. `/sys/class/rtc/rtc0/wakealarm` exists
2. `hwclock -r` succeeds (clock is readable)
3. The wakealarm sysfs node is writable

### Pi 5 — built-in RTC

The Pi 5 has a built-in RTC, but it requires a CR2032 battery on the board and an initial time sync before the wakealarm becomes writable.

```bash
sudo hwclock --systohc        # sync system time → RTC
sudo bash kiosk-setup.sh --enable-rtc
```

### Pi 4 — external RTC module (e.g. DS3231)

1. Wire the module: `SDA→GPIO2`, `SCL→GPIO3`, `VCC→3.3V`, `GND→GND`
2. Add to `/boot/firmware/config.txt`:
   ```
   dtoverlay=i2c-rtc,ds3231
   ```
3. Reboot, then:
   ```bash
   sudo hwclock --systohc
   sudo bash kiosk-setup.sh --enable-rtc
   ```

### Re-enabling after adding hardware

If the RTC wasn't present during the original install, run this after setting up the hardware:

```bash
sudo bash kiosk-setup.sh --enable-rtc
```

This writes the shutdown script and cron job without touching any other kiosk configuration.

---

## On-Screen Keyboard

Set `ENABLE_OSK=true` in `kiosk-setup.sh` before running, then re-run the install. The keyboard appears automatically when a text input field is tapped in Chromium.

| OS | Package | Notes |
|---|---|---|
| Trixie (Wayland) | `wvkbd` | Native Wayland OSK; uses input-method protocol; appears/dismisses automatically |
| Bookworm (X11) | `onboard` | X11 OSK; Blackboard theme to match dark mode; 4s startup delay |

Both integrate with Chromium's `--enable-virtual-keyboard` flag so the browser signals the OSK when a text field gains focus.

> **Note:** In kiosk mode, the OSK will not appear for Chromium's own URL bar (which is hidden anyway). It only appears for text inputs within the webpage being displayed.

---

## Updating the URL

```bash
sudo bash kiosk-setup.sh --update-url https://new-dashboard.com
sudo reboot   # or: sudo pkill chromium
```

The watchdog loop will relaunch Chromium with the new URL automatically after `pkill`.

---

## OS / Compositor Differences

| | Bookworm (X11) | Trixie (Wayland) |
|---|---|---|
| Chromium package | `chromium-browser` | `chromium` |
| Autostart location | `~/.config/lxsession/LXDE-pi/autostart` | `~/.config/labwc/autostart` |
| Cursor hiding | `unclutter` | labwc `rc.xml` timeout |
| Screen blanking | `xset s off` + Xorg config | systemd inhibitor service |
| Black background | `xsetroot` + LXDE desktop color | `swaybg -c 000000` |
| Display rotation | X11 RandR (not scripted) | `wlr-randr` |
| GPU overlay | `vc4-fkms-v3d` (Pi 4) / `vc4-kms-v3d` (Pi 5) | `vc4-kms-v3d` |
| OSK | `onboard` | `wvkbd` |

---

## Troubleshooting

**RTC not detected after setup**
```bash
sudo bash kiosk-setup.sh --enable-rtc    # shows detailed diagnostics
sudo hwclock -r                           # check if clock is readable
cat /sys/class/rtc/rtc0/wakealarm        # check sysfs node
```

**Screen goes blank**
- Trixie: `systemctl --user status kiosk-inhibit.service`
- Bookworm: confirm `xset -dpms` is in the autostart

**Desktop flash before Chromium**
- Trixie: `pgrep swaybg`
- Bookworm: check `~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf`

**Chromium keeps crashing**
```bash
tail -f /var/log/kiosk.log
```

**OSK not appearing**
- Trixie: `pgrep wvkbd` — confirm it's running
- Bookworm: `pgrep onboard` — confirm it's running
- Ensure `--enable-virtual-keyboard` is in the Chromium flags (set automatically when `ENABLE_OSK=true`)

**URL unreachable on boot**
Increase `MAX_WAIT` in `~/.config/labwc/autostart` (Trixie) or the autostart bash block (Bookworm).

---

## File Layout

```
ha-pi-dashboard/
├── kiosk-setup.sh
└── README.md

After install (on the Pi):

Trixie:
~/.config/labwc/autostart              Launcher + crash watchdog
~/.config/labwc/environment            Dark mode env vars
~/.config/labwc/rc.xml                 Cursor hiding, keybindings
~/.config/systemd/user/kiosk-inhibit.service

Bookworm:
~/.config/lxsession/LXDE-pi/autostart
~/.config/pcmanfm/LXDE-pi/desktop-items-0.conf

Both:
~/.config/gtk-3.0/settings.ini
~/.config/gtk-4.0/settings.ini
/usr/local/bin/kiosk-shutdown.sh       (only if RTC detected)
/etc/kiosk-installed                   Install marker
/var/log/kiosk.log
```

---

## License

MIT
