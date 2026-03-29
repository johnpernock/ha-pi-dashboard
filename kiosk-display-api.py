#!/usr/bin/env python3
"""
kiosk-display-api.py — Lightweight HTTP API for kiosk display control.
Installed and managed by kiosk-setup.sh when ENABLE_DISPLAY_API=true.

Endpoints:
  GET  /status          → JSON: display type, brightness (0-100), screen state
  GET  /brightness      → JSON: {"brightness": 75}
  POST /brightness      → JSON body {"value": 75}  or query ?value=75
  POST /screen/off      → turn backlight/display off (Pi stays fully on)
  POST /screen/on       → turn backlight/display back on
  GET  /screen/state    → {"screen": "on"|"off"}
  GET  /health          → {"status": "ok", "uptime": N}

Touch-to-wake (ENABLE_TOUCH_TO_WAKE=true in kiosk.conf):
  When the screen is turned off, the touchscreen input device is grabbed at
  the kernel level via evdev. Chromium receives zero touch events while the
  screen is dark, preventing accidental dashboard triggers. The first tap
  releases the grab, wakes the backlight, and restores brightness. All
  subsequent events reach Chromium normally.

Display type auto-detection priority:
  1. DSI backlight  — /sys/class/backlight/* (official Pi touchscreen, some HDMI)
  2. DDC/CI         — ddcutil (HDMI monitors that support the DDC protocol)
  3. None           — API still runs but brightness calls are no-ops with a warning
"""

import http.server
import json
import os
import select
import subprocess
import sys
import glob
import time
import threading
import logging
import configparser
import urllib.parse
from pathlib import Path

# =============================================================================
#  Configuration — read from /etc/kiosk-display.conf (written by kiosk-setup.sh)
# =============================================================================
CONFIG_FILE = "/etc/kiosk-display.conf"
LOG_FILE    = "/var/log/kiosk-display.log"

config = configparser.ConfigParser()
config.read(CONFIG_FILE)

PORT          = int(config.get("display", "port",            fallback="2701"))
BIND_ADDRESS  = config.get("display", "bind_address",        fallback="0.0.0.0")
COMPOSITOR    = config.get("display", "compositor",          fallback="x11")
DISPLAY_OUT   = config.get("display", "output",              fallback="HDMI-A-1")
WAYLAND_SOCK  = config.get("display", "wayland_socket",      fallback="/run/user/1000/wayland-0")
X_DISPLAY     = config.get("display", "x_display",           fallback=":0")
KIOSK_USER    = config.get("display", "kiosk_user",          fallback="pi")
KIOSK_UID     = int(config.get("display", "kiosk_uid",       fallback="1000"))

# Touch-to-wake configuration
ENABLE_TOUCH_TO_WAKE    = config.getboolean("display", "touch_to_wake",   fallback=False)
_wake_bri_raw           = config.get("display", "wake_brightness",        fallback="last").strip()
SCREEN_ON_MODE          = config.get("display", "screen_on_mode",         fallback="").strip()
# If set, wlr-randr uses --custom-mode MODE instead of --on (needed for
# displays that require a specific mode to be re-applied after --off)
SOFTWARE_BRIGHTNESS     = config.getboolean("display", "software_brightness", fallback=False)
# Use wlr-randr gamma for brightness on displays without DDC/CI or backlight
TOUCH_WAKE_BRIGHTNESS   = _wake_bri_raw if _wake_bri_raw == "last" else int(_wake_bri_raw)
TOUCH_WAKE_SWALLOW_MS   = int(config.get("display", "wake_swallow_ms",    fallback="300"))

START_TIME = time.time()

# =============================================================================
#  Logging
# =============================================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("kiosk-display")

# =============================================================================
#  Touch-to-wake monitor
#
#  Uses evdev to hold an exclusive kernel-level grab on the touchscreen while
#  the display is off. This is OS-level input blocking — Chromium receives
#  literally zero events. No race conditions, no JavaScript required.
#
#  Flow:
#    screen_off() → grab touchscreen → drain 600ms (absorbs button lift) → DDC off
#    user taps    → our thread reads the event (Chromium sees nothing)
#                 → drain remaining events for SWALLOW_MS
#                 → ungrab → restore brightness → screen on
#    screen_on()  → ungrab (if grabbed) → DDC on
# =============================================================================
class TouchWakeMonitor:
    """Kernel-level touch grab for wake-on-touch with accidental-tap prevention."""

    def __init__(self, wake_brightness, swallow_ms):
        self._wake_brightness = wake_brightness  # int or 'last'
        self._swallow_ms      = swallow_ms / 1000.0
        self._device          = None
        self._grabbed         = False
        self._lock            = threading.Lock()
        self._wake_event      = threading.Event()  # signals monitor thread to wake
        self._stop            = False
        self._display         = None               # set after DisplayBackend created

        self._find_device()

        if self._device:
            self._thread = threading.Thread(
                target=self._monitor_loop,
                name="touch-wake-monitor",
                daemon=True,
            )
            self._thread.start()
            log.info(
                f"Touch-to-wake monitor started — device: {self._device.name} "
                f"({self._device.path}), brightness: {wake_brightness}, "
                f"swallow: {swallow_ms}ms"
            )

    def _find_device(self):
        """Locate the touchscreen input device by name at startup."""
        try:
            from evdev import InputDevice, list_devices
        except ImportError:
            log.error(
                "evdev not installed — touch-to-wake disabled. "
                "Run: pip install evdev --break-system-packages"
            )
            return

        keywords = ["touch", "waveshare", "ili", "ft5", "goodix", "elan",
                    "hid", "xinput", "sitronix"]
        for path in list_devices():
            try:
                dev = InputDevice(path)
                if any(k in dev.name.lower() for k in keywords):
                    self._device = dev
                    return
            except Exception:
                pass

        log.warning(
            "Touch-to-wake: no touchscreen input device found. "
            "Check 'evtest' to identify the correct device and set "
            "touch_device in /etc/kiosk-display.conf if needed."
        )

    @property
    def is_grabbed(self) -> bool:
        return self._grabbed

    def grab(self):
        """
        Called by screen_off() BEFORE turning the display off.
        Grabs the device exclusively — Chromium stops receiving all input.
        """
        if not self._device:
            return
        with self._lock:
            if self._grabbed:
                return
            try:
                self._device.grab()
                self._grabbed = True
                log.info("Touch-to-wake: input grab active — Chromium input blocked")
            except Exception as e:
                log.warning(f"Touch-to-wake: grab failed ({e}) — touch events may leak")

    def ungrab(self):
        """
        Called when screen wakes. Releases the grab so Chromium gets input again.
        Always safe to call even if not currently grabbed.
        """
        if not self._device:
            return
        with self._lock:
            if not self._grabbed:
                return
            try:
                self._device.ungrab()
                self._grabbed = False
                log.info("Touch-to-wake: input grab released — Chromium input restored")
            except Exception as e:
                log.warning(f"Touch-to-wake: ungrab failed ({e})")

    def _drain_events(self):
        """
        Consume all events queued in our fd for SWALLOW_MS.
        These are events that arrived while grabbed — they can never reach
        Chromium since we already own the fd. Draining prevents them from
        being processed if the fd somehow gets re-inherited.
        """
        deadline = time.monotonic() + self._swallow_ms
        while time.monotonic() < deadline:
            remaining = max(0.001, deadline - time.monotonic())
            try:
                r, _, _ = select.select([self._device.fd], [], [], remaining)
                if r:
                    self._device.read()
            except Exception:
                break

    def _do_wake(self):
        """
        Perform the full wake sequence — screen on, brightness restore,
        drain swallow window, then ungrab.
        """
        if not self._display:
            return

        # Restore brightness first (this is what the user wants to see)
        bri = (
            self._display._pre_off_brightness
            if self._wake_brightness == "last"
            else self._wake_brightness
        )
        # Clamp to valid range
        bri = max(1, min(100, bri if bri else 80))

        log.info(f"Touch-to-wake: waking screen, brightness → {bri}%")
        self._display.screen_on_internal()   # turn display on (DDC/backlight)
        self._display.set_brightness(bri)    # restore brightness

        # Drain any queued events during swallow window before releasing grab
        self._drain_events()
        self.ungrab()

    def _monitor_loop(self):
        """
        Background daemon thread.
        Blocks on device.read_loop() — wakes only when the grab is active
        and a touch event arrives.
        """
        from evdev import ecodes

        while not self._stop:
            # Wait until grabbed
            if not self._grabbed:
                time.sleep(0.05)
                continue

            try:
                # Drain events for 600ms after grab activates.
                # This absorbs the finger-lift from whatever button/tap
                # triggered the screen-off, preventing an immediate re-wake.
                drain_until = time.monotonic() + 0.6
                while time.monotonic() < drain_until:
                    remaining = max(0.001, drain_until - time.monotonic())
                    try:
                        r, _, _ = select.select([self._device.fd], [], [], remaining)
                        if r:
                            self._device.read()
                    except Exception:
                        break

                for event in self._device.read_loop():
                    if not self._grabbed:
                        break
                    # Any absolute (touch coordinates) or key event = touch
                    if event.type in (ecodes.EV_ABS, ecodes.EV_KEY):
                        log.info("Touch-to-wake: touch detected while screen off")
                        self._do_wake()
                        break
            except Exception as e:
                if self._grabbed:
                    log.error(f"Touch-to-wake monitor error: {e}")
                time.sleep(0.5)

    def stop(self):
        self._stop = True
        self.ungrab()


# =============================================================================
#  Display backend detection
# =============================================================================
class DisplayBackend:
    """Abstract display control — auto-selects the right backend at startup."""

    def __init__(self):
        self.type               = "none"
        self.backlight_path     = None
        self.ddc_display_id     = None
        self._screen_off        = False       # track screen state
        self._pre_off_brightness = 80         # brightness before last screen-off
        self._sw_brightness      = 80         # last software brightness value
        self._detect()

    def _detect(self):
        # ── Try DSI / sysfs backlight first ──────────────────────────────────
        candidates = sorted(glob.glob("/sys/class/backlight/*/brightness"))
        if candidates:
            self.backlight_path = str(Path(candidates[0]).parent)
            self.type = "backlight"
            log.info(f"Display backend: sysfs backlight at {self.backlight_path}")
            return

        # ── Try DDC/CI via ddcutil ────────────────────────────────────────────
        try:
            result = subprocess.run(
                ["ddcutil", "detect", "--brief"],
                capture_output=True, text=True, timeout=8
            )
            if result.returncode == 0 and "Display" in result.stdout:
                self.type = "ddc"
                log.info("Display backend: DDC/CI via ddcutil")
                return
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

        # ── No brightness control available ───────────────────────────────────
        log.warning(
            "No display backend found. Brightness calls will be no-ops. "
            "Install ddcutil for HDMI DDC/CI support, or check sysfs backlight."
        )

    # ── Brightness ────────────────────────────────────────────────────────────
    def get_brightness(self) -> int:
        """Return current brightness as 0-100."""
        if SOFTWARE_BRIGHTNESS and not self.backlight_path and not self.ddc_ok:
            return getattr(self, "_sw_brightness", 80)
        try:
            if self.type == "backlight":
                actual  = int(Path(f"{self.backlight_path}/brightness").read_text().strip())
                max_val = int(Path(f"{self.backlight_path}/max_brightness").read_text().strip())
                return round((actual / max_val) * 100)

            if self.type == "ddc":
                result = subprocess.run(
                    ["ddcutil", "getvcp", "10", "--brief"],
                    capture_output=True, text=True, timeout=8
                )
                # Output format: "VCP 10 C 75 100"  (current max)
                parts = result.stdout.strip().split()
                if len(parts) >= 4:
                    return int(parts[3])
        except Exception as e:
            log.error(f"get_brightness error: {e}")
        return -1

    def set_brightness(self, value: int) -> bool:
        """Set brightness 0-100. Returns True on success."""
        value = max(0, min(100, value))
        try:
            if self.type == "backlight":
                max_val = int(Path(f"{self.backlight_path}/max_brightness").read_text().strip())
                raw = round((value / 100) * max_val)
                Path(f"{self.backlight_path}/brightness").write_text(str(raw))
                log.info(f"Backlight brightness set to {value}% (raw {raw}/{max_val})")
                return True

            if self.type == "ddc":
                subprocess.run(
                    ["ddcutil", "setvcp", "10", str(value)],
                    check=True, timeout=8
                )
                log.info(f"DDC brightness set to {value}%")
                return True

            log.warning(f"set_brightness({value}) called but no backend available")
        except Exception as e:
            log.error(f"set_brightness error: {e}")
        return False

    # ── Screen on/off ─────────────────────────────────────────────────────────
    def _run_as_kiosk(self, cmd: list) -> bool:
        """Run a command as the kiosk user with the correct display env."""
        env = os.environ.copy()
        if COMPOSITOR.lower() in ("wayland", "wayland + labwc"):
            env["WAYLAND_DISPLAY"] = "wayland-0"
            env["XDG_RUNTIME_DIR"]  = f"/run/user/{KIOSK_UID}"
        else:
            env["DISPLAY"] = X_DISPLAY
        try:
            subprocess.run(
                ["sudo", "-u", KIOSK_USER,
                 "--preserve-env=WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DISPLAY"] + cmd,
                env=env, check=True, timeout=10
            )
            return True
        except Exception as e:
            log.error(f"_run_as_kiosk({cmd}) error: {e}")
            return False

    def screen_off(self) -> bool:
        """
        Turn the display off without shutting down the Pi.
        Grabs the touchscreen BEFORE cutting the backlight so there is
        zero window where a tap could reach Chromium on a dark screen.
        """
        log.info("Screen OFF requested")

        # Save brightness for potential restore-to-last
        current = self.get_brightness()
        if current > 0:
            self._pre_off_brightness = current

        # Grab input BEFORE turning off display (eliminates race window)
        if TOUCH_WAKE:
            TOUCH_WAKE.grab()

        ok = self._screen_off_hw()
        if ok:
            self._screen_off = True
        else:
            # Failed to turn off — release grab so user isn't locked out
            if TOUCH_WAKE:
                TOUCH_WAKE.ungrab()
        return ok

    def _screen_off_hw(self) -> bool:
        """Hardware screen-off (backlight / compositor)."""
        try:
            if self.backlight_path:
                Path(f"{self.backlight_path}/bl_power").write_text("1")
                return True

            if COMPOSITOR.lower() in ("wayland", "wayland + labwc"):
                return self._run_as_kiosk(
                    ["wlr-randr", "--output", DISPLAY_OUT, "--off"]
                )
            else:
                ok = self._run_as_kiosk(
                    ["xrandr", "--display", X_DISPLAY, "--output", "HDMI-1", "--off"]
                )
                if not ok:
                    ok = self._run_as_kiosk(["tvservice", "-o"])
                return ok
        except Exception as e:
            log.error(f"screen_off_hw error: {e}")
            return False

    def screen_on(self) -> bool:
        """
        Turn the display back on.
        Called by external clients (HA automations, etc.).
        Releases the grab if held — the touch-wake monitor handles its own
        ungrab when it initiates the wake, but external calls must also release.
        """
        log.info("Screen ON requested (external)")

        # Release grab if held (HA automation waking the screen)
        if TOUCH_WAKE and TOUCH_WAKE.is_grabbed:
            TOUCH_WAKE.ungrab()

        ok = self.screen_on_internal()
        if ok:
            self._screen_off = False
        return ok

    def screen_on_internal(self) -> bool:
        """
        Hardware screen-on. Called by both screen_on() and the touch-wake
        monitor's _do_wake(). Does NOT touch the grab — caller manages that.
        """
        try:
            if self.backlight_path:
                Path(f"{self.backlight_path}/bl_power").write_text("0")
                self._screen_off = False
                return True

            if COMPOSITOR.lower() in ("wayland", "wayland + labwc"):
                if SCREEN_ON_MODE:
                    # Step 1: re-enable output with its native preferred mode
                    self._run_as_kiosk(
                        ["wlr-randr", "--output", DISPLAY_OUT, "--on"]
                    )
                    import time as _time; _time.sleep(0.5)
                    # Step 2: switch to the desired custom mode
                    ok = self._run_as_kiosk(
                        ["wlr-randr", "--output", DISPLAY_OUT,
                         "--custom-mode", SCREEN_ON_MODE]
                    )
                else:
                    ok = self._run_as_kiosk(
                        ["wlr-randr", "--output", DISPLAY_OUT, "--on"]
                    )
            else:
                ok = self._run_as_kiosk(
                    ["xrandr", "--display", X_DISPLAY, "--output", "HDMI-1", "--auto"]
                )
                if not ok:
                    ok = self._run_as_kiosk(["tvservice", "-p"])

            if ok:
                self._screen_off = False
            return ok
        except Exception as e:
            log.error(f"screen_on_internal error: {e}")
            return False

    def status(self) -> dict:
        return {
            "backend":    self.type,
            "brightness": self.get_brightness(),
            "screen":     "off" if self._screen_off else "on",
            "output":     DISPLAY_OUT,
            "compositor": COMPOSITOR,
            "touch_wake": ENABLE_TOUCH_TO_WAKE,
        }


# =============================================================================
#  Initialise singletons
# =============================================================================
DISPLAY = DisplayBackend()

TOUCH_WAKE: TouchWakeMonitor | None = None
if ENABLE_TOUCH_TO_WAKE:
    TOUCH_WAKE = TouchWakeMonitor(
        wake_brightness=TOUCH_WAKE_BRIGHTNESS,
        swallow_ms=TOUCH_WAKE_SWALLOW_MS,
    )
    TOUCH_WAKE._display = DISPLAY   # back-reference for _do_wake()


# =============================================================================
#  HTTP request handler
# =============================================================================
# =============================================================================
#  Simple rate limiter — prevents rapid-fire POST spam to ddcutil
#  Max RATE_LIMIT_MAX calls per RATE_LIMIT_WINDOW_S seconds per client IP.
# =============================================================================
import collections
_rate_buckets: dict = collections.defaultdict(list)
_rate_lock = threading.Lock()
RATE_LIMIT_MAX      = 20          # max calls per window
RATE_LIMIT_WINDOW_S = 10.0        # rolling window in seconds

def _rate_check(ip: str) -> bool:
    """Return True if the request is allowed, False if rate-limited."""
    now = time.monotonic()
    with _rate_lock:
        bucket = _rate_buckets[ip]
        # Evict entries outside the window
        _rate_buckets[ip] = [t for t in bucket if now - t < RATE_LIMIT_WINDOW_S]
        if len(_rate_buckets[ip]) >= RATE_LIMIT_MAX:
            return False
        _rate_buckets[ip].append(now)
        return True


class KioskDisplayHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        log.info(f"{self.address_string()} - {fmt % args}")

    def _send_json(self, code: int, data: dict):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type",   "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, msg: str, code: int = 400):
        self._send_json(code, {"error": msg})

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path   = parsed.path.rstrip("/")

        if path == "/health":
            self._send_json(200, {
                "status": "ok",
                "uptime": round(time.time() - START_TIME),
            })

        elif path == "/brightness":
            b = DISPLAY.get_brightness()
            if b < 0:
                self._send_error("Could not read brightness", 503)
            else:
                self._send_json(200, {"brightness": b})

        elif path == "/screen/state":
            self._send_json(200, {
                "screen":     "off" if DISPLAY._screen_off else "on",
                "touch_grab": TOUCH_WAKE.is_grabbed if TOUCH_WAKE else False,
            })

        elif path == "/status":
            self._send_json(200, DISPLAY.status())

        else:
            self._send_error(f"Unknown endpoint: {path}", 404)

    def do_POST(self):
        # Rate limit — prevent rapid ddcutil spam
        client_ip = self.client_address[0]
        if not _rate_check(client_ip):
            log.warning(f"Rate limit exceeded for {client_ip}")
            self._send_error("Rate limit exceeded — slow down", 429)
            return

        parsed = urllib.parse.urlparse(self.path)
        path   = parsed.path.rstrip("/")
        params = urllib.parse.parse_qs(parsed.query)

        # Read JSON body if present
        body = {}
        content_len = int(self.headers.get("Content-Length", 0))
        if content_len:
            try:
                body = json.loads(self.rfile.read(content_len))
            except json.JSONDecodeError:
                pass

        if path == "/brightness":
            raw = params.get("value", [body.get("value", None)])[0]
            if raw is None:
                self._send_error("Missing 'value' parameter (0-100)")
                return
            try:
                value = int(raw)
            except (ValueError, TypeError):
                self._send_error("'value' must be an integer 0-100")
                return
            if DISPLAY.set_brightness(value):
                self._send_json(200, {"brightness": value, "ok": True})
            else:
                self._send_error("Failed to set brightness", 503)

        elif path == "/screen/off":
            if DISPLAY.screen_off():
                self._send_json(200, {
                    "screen":     "off",
                    "ok":         True,
                    "touch_grab": TOUCH_WAKE.is_grabbed if TOUCH_WAKE else False,
                })
            else:
                self._send_error("Failed to turn screen off", 503)

        elif path == "/screen/on":
            if DISPLAY.screen_on():
                self._send_json(200, {"screen": "on", "ok": True})
            else:
                self._send_error("Failed to turn screen on", 503)

        else:
            self._send_error(f"Unknown endpoint: {path}", 404)


# =============================================================================
#  Entry point
# =============================================================================
if __name__ == "__main__":
    log.info(f"Kiosk display API starting on port {PORT}")
    log.info(f"Display backend: {DISPLAY.type}")
    log.info(f"Compositor: {COMPOSITOR} | Output: {DISPLAY_OUT}")
    log.info(f"Touch-to-wake: {'enabled' if ENABLE_TOUCH_TO_WAKE else 'disabled'}")

    server = http.server.HTTPServer((BIND_ADDRESS, PORT), KioskDisplayHandler)
    log.info(f"Listening on http://{BIND_ADDRESS}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
        if TOUCH_WAKE:
            TOUCH_WAKE.stop()
        server.shutdown()
