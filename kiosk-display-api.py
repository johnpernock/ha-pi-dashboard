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
  GET  /health          → {"status": "ok", "uptime": N}

Home Assistant integration:
  See ha-display-config.yaml in the same repo for ready-to-use HA config.

Display type auto-detection priority:
  1. DSI backlight  — /sys/class/backlight/* (official Pi touchscreen, some HDMI)
  2. DDC/CI         — ddcutil (HDMI monitors that support the DDC protocol)
  3. None           — API still runs but brightness calls are no-ops with a warning
"""

import http.server
import json
import os
import subprocess
import sys
import glob
import time
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

PORT          = int(config.get("display", "port",        fallback="2701"))
COMPOSITOR    = config.get("display", "compositor",      fallback="x11")
DISPLAY_OUT   = config.get("display", "output",          fallback="HDMI-A-1")
WAYLAND_SOCK  = config.get("display", "wayland_socket",  fallback="/run/user/1000/wayland-0")
X_DISPLAY     = config.get("display", "x_display",       fallback=":0")
KIOSK_USER    = config.get("display", "kiosk_user",      fallback="pi")
KIOSK_UID     = int(config.get("display", "kiosk_uid",   fallback="1000"))

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
#  Display backend detection
# =============================================================================
class DisplayBackend:
    """Abstract display control — auto-selects the right backend at startup."""

    def __init__(self):
        self.type = "none"
        self.backlight_path = None
        self.ddc_display_id = None
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
        try:
            if self.type == "backlight":
                actual   = int(Path(f"{self.backlight_path}/brightness").read_text().strip())
                max_val  = int(Path(f"{self.backlight_path}/max_brightness").read_text().strip())
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
                ["sudo", "-u", KIOSK_USER, "--preserve-env=WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DISPLAY"] + cmd,
                env=env, check=True, timeout=10
            )
            return True
        except Exception as e:
            log.error(f"_run_as_kiosk({cmd}) error: {e}")
            return False

    def screen_off(self) -> bool:
        """Turn the display off without shutting down the Pi."""
        log.info("Screen OFF requested")
        try:
            # Backlight off via sysfs (immediate, works on all backends)
            if self.backlight_path:
                Path(f"{self.backlight_path}/bl_power").write_text("1")
                return True

            if COMPOSITOR.lower() in ("wayland", "wayland + labwc"):
                return self._run_as_kiosk(
                    ["wlr-randr", "--output", DISPLAY_OUT, "--off"]
                )
            else:
                # X11: use xrandr, fall back to tvservice (older Pi OS)
                ok = self._run_as_kiosk(["xrandr", "--display", X_DISPLAY, "--output", "HDMI-1", "--off"])
                if not ok:
                    ok = self._run_as_kiosk(["tvservice", "-o"])
                return ok
        except Exception as e:
            log.error(f"screen_off error: {e}")
            return False

    def screen_on(self) -> bool:
        """Turn the display back on."""
        log.info("Screen ON requested")
        try:
            if self.backlight_path:
                Path(f"{self.backlight_path}/bl_power").write_text("0")
                return True

            if COMPOSITOR.lower() in ("wayland", "wayland + labwc"):
                return self._run_as_kiosk(
                    ["wlr-randr", "--output", DISPLAY_OUT, "--on"]
                )
            else:
                ok = self._run_as_kiosk(["xrandr", "--display", X_DISPLAY, "--output", "HDMI-1", "--auto"])
                if not ok:
                    ok = self._run_as_kiosk(["tvservice", "-p"])
                return ok
        except Exception as e:
            log.error(f"screen_on error: {e}")
            return False

    def status(self) -> dict:
        return {
            "backend":    self.type,
            "brightness": self.get_brightness(),
            "output":     DISPLAY_OUT,
            "compositor": COMPOSITOR,
        }


# =============================================================================
#  HTTP request handler
# =============================================================================
DISPLAY = DisplayBackend()

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

        elif path == "/status":
            self._send_json(200, DISPLAY.status())

        else:
            self._send_error(f"Unknown endpoint: {path}", 404)

    def do_POST(self):
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
            # Accept value from query string or JSON body
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
                self._send_json(200, {"screen": "off", "ok": True})
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

    server = http.server.HTTPServer(("0.0.0.0", PORT), KioskDisplayHandler)
    log.info(f"Listening on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
        server.shutdown()
