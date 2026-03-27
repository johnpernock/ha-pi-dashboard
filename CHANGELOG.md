# Changelog

All notable changes to this project are documented here.

---

## [1.11.0] — 2026-03-27

### Documentation

- **README: HA Auto-Login section rewritten** — now leads with the recommended Trusted Networks-only setup (simplest, no files to copy). Token wrapper page documented as an optional fallback. Updated to reflect that `kiosk.conf` is the right place for all config, not editing the script directly.
- **README: browser_mod troubleshooting rewritten** — documents all failure modes discovered during real-world install: wrong localStorage key, wrong origin (`file://` vs `http://`), incognito blocking persistence, profile directory missing, wrong/random ID on HA side, Register toggle, interaction icon in kiosk mode. Correct fix documented for each.
- **README: Multiple kiosk displays section rewritten** — full example `kiosk.conf` for two Pi wall panels with different `BROWSER_MOD_ID` values. Documents that `?BrowserID=` is appended automatically and no wrapper page copying is needed with Trusted Networks.
- **README: HA login screen troubleshooting updated** — added `allow_bypass_login: true` check for user-selection screen, curl test for wrapper page 404, updated token rotation steps to include re-copy to HA server.
- **README: `file://` references removed** — all outdated references to loading the wrapper page from `file://` replaced with the correct `http://HA_IP/local/` approach.

---

## [1.10.0] — 2026-03-27

### Changed

- **No wrapper page required when using Trusted Networks** — if `HA_TOKEN` is empty and Trusted Networks handles auth, the script now skips the `kiosk-ha-login.html` wrapper entirely and appends `?BrowserID=` directly to the dashboard URL. Nothing to copy to the HA server, no manual steps.
- **Standalone preloader eliminated** — the `kiosk-bmod-preloader.html` `file://` workaround is gone. `?BrowserID=` is appended directly to whatever URL the kiosk loads, whether that's the dashboard directly or the wrapper page.
- **Install is now fully self-contained** — for a Trusted Networks setup with browser_mod, the complete post-install step is just `sudo reboot`. No file copying required.

---

## [1.9.0] — 2026-03-27

### Changed

- **Dynamic Browser ID — one wrapper file serves all kiosks** — `kiosk-ha-login.html` now reads the `BrowserID` URL parameter from its own URL first, falling back to the value baked in at install time. This means the single file in `/config/www/` on the HA server works for every kiosk display without conflict. Each Pi's autostart now points to:
  `http://HA_IP:8123/local/kiosk-ha-login.html?BrowserID=kiosk-front-door`
  `http://HA_IP:8123/local/kiosk-ha-login.html?BrowserID=kiosk-garage`
- **`HA_WRAPPER_URL` includes `?BrowserID=` when browser_mod is enabled** — the URL written to the autostart and install marker now includes the BrowserID parameter automatically. No manual URL editing needed.

---

## [1.8.0] — 2026-03-27

### Fixed

- **browser_mod ID not registering (critical)** — the `localStorage.setItem("browser_mod-browser-id", ...)` approach was broken in two ways: wrong key name (browser_mod 2.x does not read that key), and wrong origin (localStorage written at `file://` or `/local/` is invisible to the HA frontend at `http://`). Replaced with the official browser_mod 2.x method: appending `?BrowserID=name` to the redirect URL. browser_mod reads this parameter on load and registers with the correct ID without any localStorage manipulation.
- **`--set-browser-id` using broken preloader** — the standalone preloader written by `_write_bmod_preloader` had the same localStorage/origin bugs and also pointed at `file://` which broke auto-login. Replaced with direct wrapper page update — the `BROWSER_MOD_ID` JS variable in the HA wrapper page is updated in-place and the file is re-copied to the HA www folder automatically.
- **Stale wrapper page on HA server** — after `--set-browser-id` or token updates, the wrapper page on the HA server (`/config/www/kiosk-ha-login.html`) was not being updated. Script now attempts to re-copy it automatically and prints clear manual instructions if HA is on a different machine.
- **Token truncation in kiosk.conf** — added explicit warning in `kiosk.conf.example` that `HA_TOKEN` must be on a single line with no line breaks.
- **Install instructions** — end-of-install output now notes that the wrapper page must be re-copied to HA after running `--set-browser-id` or updating the token.

---

## [1.7.0] — 2026-03-25

### Added

- **`kiosk.conf` local config override** — personal settings now live in a git-ignored `kiosk.conf` file alongside the script; `git pull` never overwrites them. Copy `kiosk.conf.example` to get started. Script prints a confirmation line when `kiosk.conf` is loaded.
- **`kiosk.conf.example`** — template file with every configurable variable commented out and documented
- **Guard against combined flags** — `--factory-reset` and `--reset` now immediately error if `$2` starts with `--` (e.g. `--factory-reset --set-token TOKEN URL`), printing clear instructions to run flags one at a time

### Fixed

- **Black screen on boot (critical)** — `kiosk.log` was written to `/var/log/kiosk.log` which the kiosk user cannot write to. The `>>` redirect caused the entire network-wait loop to crash with a permission error before Chromium ever launched, leaving a black screen with only a cursor. Log moved to `~/kiosk.log` (home directory, always writable). Log file is now created and chowned during install.
- **Chromium exiting immediately (critical)** — conditional `$(if ...; fi)` lines inside the heredoc that evaluated to empty string left blank lines in the middle of a backslash-continuation command, terminating it early. `--kiosk` and all subsequent flags ran as separate shell commands instead of Chromium flags, causing Chromium to launch without kiosk mode and exit cleanly after a few seconds. Fixed by pre-building the entire Chromium command as a `_CHROME_FLAGS` string in the script (where bash is guaranteed) before the heredoc is written. The heredoc then contains one clean `chromium $_CHROME_FLAGS "$KIOSK_URL_VALUE"` line — no backslash continuations, no conditionals, no arrays.
- **Bash array syntax breaking autostart** — replaced `CHROMIUM_FLAGS=(...)` array (bash-only) and `eval` approaches with the pre-built string approach above. The written autostart now passes `sh -n` syntax check with zero errors.
- **HA login screen appearing despite token** — the token wrapper page was loaded from `file://` which is a different browser origin than `http://192.168.1.x:8123`. localStorage is strictly origin-scoped, so a token written at the `file://` origin is completely invisible to HA at the `http://` origin. Fixed by changing `HA_WRAPPER_URL` from `file://$HA_WRAPPER_PATH` to `$HA_URL/local/kiosk-ha-login.html`. The script now also attempts to auto-copy the wrapper page to the HA `www` folder (`/config/www/`) during install.
- **Double-backslash in Trixie autostart** — conditional `echo` statements inside the heredoc produced `\` (two backslashes) instead of `\` (one), broken by the pre-built string fix above.
- **`_reset_kiosk()` definition order** — function was called before it was defined when `--factory-reset` ran; moved definition above the first call site.

---

## [1.6.0] — 2026-03-25

### Added
- **`BROWSER_MOD_ID` config variable** — pre-seed a stable Browser ID into
  Chromium's `localStorage` before the HA frontend loads, so browser_mod
  registers with a known, predictable identity on every boot
- **`--set-browser-id` flag** — update the browser_mod Browser ID without
  reinstalling; updates the wrapper/preloader HTML and `/etc/kiosk-browser-mod-id`
- **`/etc/kiosk-browser-mod-id`** — dedicated file storing the active Browser ID,
  readable at any time with `cat /etc/kiosk-browser-mod-id`
- **Auto-generated Browser ID** — if `BROWSER_MOD_ID` is left blank, a stable ID
  is derived from the Pi's serial number so it survives reinstalls on the same hardware
- **Standalone browser_mod preloader** (`~/kiosk-bmod-preloader.html`) — seeds the
  Browser ID and redirects to the kiosk URL when `ENABLE_BROWSER_MOD=true` but
  `HA_AUTO_LOGIN=false` (no HA wrapper page in use)
- **Browser ID injected into HA wrapper page** — when `HA_AUTO_LOGIN=true`, the
  existing `kiosk-ha-login.html` also sets `browser_mod-browser-id` in localStorage

### Changed
- `_reset_kiosk` now removes `kiosk-bmod-preloader.html`, `/etc/kiosk-browser-mod-id`,
  and `~/.config/chromium-kiosk` (persistent Chromium profile)

### Fixed
- `ha-display-config.yaml`: replaced deprecated `number: platform: template` with
  `input_number:` + automation pattern (compatible with all current HA versions)
- `ha-display-config.yaml`: updated `light:` entity to modern `template:` syntax
  (HA 2023.4+)
- README: removed duplicate `DISPLAY_API_PORT` row from config table
- README: removed duplicate `~/kiosk-ha-login.html` entry from file layout

---

## [1.5.0] — 2026-03-25

### Added
- **`ENABLE_BROWSER_MOD` config variable** — switches Chromium from `--incognito`
  to a persistent profile at `~/.config/chromium-kiosk`, required for browser_mod
  to retain its device ID across restarts
- **`WAVESHARE_10DP` config variable** — auto-configures 1280×800 HDMI resolution
  in `config.txt` and installs `ddcutil` for DDC/CI brightness control
- **`kiosk-display-api.py`** — lightweight Python HTTP API (port 2701) for HA to
  control display brightness and screen on/off via DDC/CI (`ddcutil`) or sysfs backlight.
  Endpoints: `GET /health`, `GET /status`, `GET /brightness`,
  `POST /brightness`, `POST /screen/off`, `POST /screen/on`
- **`ENABLE_DISPLAY_API` + `DISPLAY_API_PORT` config variables**
- **`ha-display-config.yaml`** — ready-to-paste HA config: `rest_command`,
  `sensor`, `input_number` slider, `switch`, `light` entity, example automations
  (dim at night, screen off when away, etc.), Lovelace card YAML
- **`ha-browser-mod-config.yaml`** — ready-to-paste HA config: doorbell camera
  popup, motion alerts, navigation, software blackout, critical alerts, reusable
  scripts, Lovelace control card YAML
- **`--factory-reset` flag** — strips device to bare minimum: wipes home directory
  (preserving `.ssh`), purges all bloat and kiosk packages, clears systemd failed
  units, apt cache; SSH and network config are never touched; requires typing
  `FACTORY RESET` to confirm
- **Step 15** (display API install): installs `ddcutil`, copies `kiosk-display-api.py`,
  writes `/etc/kiosk-display.conf`, installs and enables systemd service
- **Step 16** (Waveshare config): appends HDMI resolution lines to `config.txt`
- **Step 17** (browser_mod profile): creates persistent Chromium profile directory

### Changed
- `--reset` now also removes the display API service, config, and script
- `_factory_reset` calls `_reset_kiosk` with `--skip-confirm --skip-packages`
  flags to avoid double-prompting

---

## [1.4.0] — 2026-03-24

### Added
- **`REMOVE_BLOAT` config variable** — removes known desktop-only packages
  (Wolfram, LibreOffice, Scratch, Sonic Pi, Thonny, Minecraft Pi, games, etc.)
  during install; saves 1–3GB on full desktop images
- **`apt-get autoremove` + `autoclean`** after every full install
- **Package tracking** — `INSTALLED_PKGS` saved to `/etc/kiosk-installed`;
  `--reset` offers to remove only the packages the script installed
- **`--reset` flag** — wipes all kiosk config with confirmation prompt; optionally
  accepts a URL for immediate reinstall (`--reset https://url`)
- **Existing install guard** — full install detects `/etc/kiosk-installed` and
  prompts: reset+reinstall, update URL, continue, or quit
- **`--set-token` flag** — updates the HA long-lived access token in the wrapper
  page without reinstalling
- **Factory-reset expanded package list** — adds vlc, gimp, cups, blueman,
  avahi-daemon, triggerhappy, rpi-imager, audacity, and more

### Changed
- `_reset_kiosk` parameterised with `--skip-confirm` and `--skip-packages` flags
  for internal use by `--factory-reset`

---

## [1.3.0] — 2026-03-23

### Added
- **`HA_AUTO_LOGIN` config block** — `HA_URL`, `HA_TOKEN`, `HA_DASHBOARD_PATH`
- **Method 1 — Trusted Networks**: auto-detects Pi subnet, prints ready-to-paste
  YAML for `configuration.yaml` at end of install
- **Method 2 — Token wrapper page** (`~/kiosk-ha-login.html`): local HTML file
  that injects a long-lived access token into Chromium's `localStorage` and
  redirects to HA; used as the kiosk start URL when a token is provided
- **`--set-token` flag** — rotate the HA token in the wrapper page, no reinstall

---

## [1.2.0] — 2026-03-23

### Added
- **RTC hardware detection** — three-stage probe: sysfs node exists →
  `hwclock -r` succeeds → wakealarm is writable; shutdown/wake skipped
  entirely if any stage fails
- **`--enable-rtc` flag** — activates shutdown/wake scheduling after adding
  RTC hardware without reinstalling; includes Pi-specific diagnostics
- **`ENABLE_OSK` config variable** — installs `wvkbd` (Trixie/Wayland) or
  `onboard` (Bookworm/X11); adds `--enable-virtual-keyboard` to Chromium
- **Pi 5 built-in RTC** detection and guidance (CR2032 battery + `hwclock --systohc`)
- **External RTC module** setup guidance for Pi 4/3/Zero 2W (DS3231 wiring table)

### Changed
- Shutdown/wake cron job and script only installed when RTC hardware is confirmed

---

## [1.1.0] — 2026-03-23

### Added
- **Full Pi model matrix**: Pi 1/2/3/4/5, Zero/Zero W/Zero 2W, CM3/CM4, Pi 400
- **Hardware tier system** (1–4) with compatibility warnings and y/N prompts
  for Tier 3 (Pi 2) and Tier 4 (Pi Zero/Pi 1) hardware
- **ARMv6 safety net** — auto-falls back from Wayland to X11 on Pi Zero/Pi 1
- **Chromium memory flags** auto-applied on devices with < 1GB RAM:
  `--js-flags=--max-old-space-size=128`, `--single-process`, etc.
- **Bullseye (Debian 11)** support: X11 path, probes Chromium package name
- **Buster (Debian 10)** best-effort support with EOL warning and y/N prompt
- **Legacy OS** best-effort support with strong upgrade warning
- **Pi 4 vs Pi 5 GPU overlay** logic: `vc4-fkms-v3d` for Pi 4/X11,
  `vc4-kms-v3d` for Pi 5 and Wayland
- **Pi-model-specific watchdog**: `bcm2835_wdt` module loaded on Pi 4/3/2;
  skipped on Pi Zero/Pi 1 (not available); Pi 5 uses built-in
- `/boot/config.txt` fallback for older OS layouts

### Changed
- `chromium-browser` (Bookworm/Bullseye) vs `chromium` (Trixie) auto-detected
- OSK package: `onboard` on X11, `wvkbd` on Wayland

---

## [1.0.0] — 2026-03-23

### Initial release — Trixie + Bookworm, Pi 4 + Pi 5

#### Core kiosk features
- **Auto-detection** of OS (Trixie/Bookworm) and Pi model (4/5) at runtime
- **Trixie/Wayland** path: labwc compositor, `chromium` package, ozone flags,
  `swaybg` black background, labwc `rc.xml`, systemd idle inhibitor
- **Bookworm/X11** path: LXDE, `chromium-browser`, `unclutter`, `xsetroot`/
  pcmanfm black background, Xorg blanking config
- **Chromium kiosk mode**: `--kiosk`, `--noerrdialogs`, `--disable-infobars`,
  `--disable-notifications`, `--disable-popup-blocking`, `--no-first-run`,
  `--disable-extensions`, `--disable-translate`, `--incognito`, `--disable-pinch`,
  `--overscroll-history-navigation=0`, `--hide-scrollbars`, `--force-dark-mode`,
  `--enable-features=WebContentsForceDark`
- **GTK dark theme**: `Adwaita-dark` applied to gtk-3.0 and gtk-4.0
- **labwc environment** for Wayland dark mode portal
- **Chromium crash watchdog** loop — auto-relaunches on unexpected exit
- **Network-aware boot** — waits up to 30s for URL before launching
- **LightDM autologin** — kiosk user auto-logins to labwc or LXDE session
- **GPU overlay**: `vc4-kms-v3d` (Wayland), `vc4-fkms-v3d` (X11/Pi4)
- **Hardware watchdog**: `RuntimeWatchdogSec=15` in `systemd/system.conf`
- **Wi-Fi power-save disabled** via NetworkManager config
- **Log rotation**: `/var/log/kiosk.log` weekly, 4 weeks
- **`--update-url` flag** for changing the kiosk URL without reinstalling
- **Install marker** at `/etc/kiosk-installed`
- **Configurable shutdown** (`SHUTDOWN_HOUR`, `SHUTDOWN_MINUTE`) + RTC wake
  (`WAKE_HOUR`, `WAKE_MINUTE`) via cron + sysfs wakealarm
- **Display rotation** via `DISPLAY_TRANSFORM` + `wlr-randr` (Trixie)
- **Auto-reload** via `AUTO_RELOAD_SECONDS`
