#!/usr/bin/env python3
"""Experimental charging and WiFi panel for the Razer Phone 2 framebuffer."""

import glob
import mmap
import os
import select
import struct
import subprocess
import time


FB = "/dev/fb0"
INPUT = "/dev/input/event0"
KMS_HELPER = "/usr/local/sbin/razer-kms-present"
SHARED_FRAME = "/run/razer-control-panel.frame"
MANUAL_CHARGE_MARKER = "/var/lib/razer-control-panel/charge-to-full"
IDLE_SECONDS = int(os.environ.get("RAZER_PANEL_IDLE_SECONDS", "60"))
EVENT = struct.Struct("llHHi")
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
BTN_TOUCH = 330
ABS_X, ABS_Y = 0, 1
ABS_MT_POSITION_X, ABS_MT_POSITION_Y = 53, 54
ABS_MT_TRACKING_ID = 57

COLORS = {
    "bg": (13, 18, 22),
    "panel": (27, 35, 41),
    "panel2": (37, 48, 55),
    "text": (239, 244, 246),
    "muted": (151, 166, 174),
    "green": (72, 201, 132),
    "cyan": (65, 174, 214),
    "amber": (245, 174, 66),
    "red": (231, 92, 92),
}

# Compact 5x7 font. Lowercase is intentionally rendered as uppercase so the
# UI remains readable without shipping a font package in the base image.
FONT = {
    " ": ["00000"] * 7,
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
    "6": ["01110", "10000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01111", "10000", "10000", "10111", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
    "J": ["00111", "00010", "00010", "00010", "10010", "10010", "01100"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "11011", "10001"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    ".": ["00000", "00000", "00000", "00000", "00000", "00110", "00110"],
    ":": ["00000", "00110", "00110", "00000", "00110", "00110", "00000"],
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    "_": ["00000", "00000", "00000", "00000", "00000", "00000", "11111"],
    "/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
    "@": ["01110", "10001", "10111", "10101", "10111", "10000", "01111"],
    "%": ["11001", "11010", "00100", "01000", "10110", "00110", "00000"],
    "*": ["00000", "10101", "01110", "11111", "01110", "10101", "00000"],
    "?": ["01110", "10001", "00010", "00100", "00100", "00000", "00100"],
    "!": ["00100", "00100", "00100", "00100", "00100", "00000", "00100"],
    "#": ["01010", "11111", "01010", "01010", "11111", "01010", "00000"],
    "+": ["00000", "00100", "00100", "11111", "00100", "00100", "00000"],
    "=": ["00000", "11111", "00000", "11111", "00000", "00000", "00000"],
}


def read_text(path, default=""):
    try:
        with open(path, "r", encoding="ascii", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return default


def read_int(path):
    try:
        return int(read_text(path, "0"))
    except ValueError:
        return 0


def read_float(path):
    try:
        return float(read_text(path, "0"))
    except ValueError:
        return 0.0


def read_iio_channel(label_name):
    for label_path in glob.glob("/sys/bus/iio/devices/iio:device*/in_*_label"):
        if read_text(label_path) != label_name:
            continue
        base = label_path[:-6]
        raw_path = base + "_raw"
        scale_path = base + "_scale"
        if not os.path.exists(raw_path) or not os.path.exists(scale_path):
            continue
        return read_float(raw_path) * read_float(scale_path), True
    return 0.0, False


def run(args, timeout=15):
    try:
        return subprocess.run(args, text=True, capture_output=True,
                              timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(args, 1, "", str(exc))


class Framebuffer:
    def __init__(self):
        size = read_text("/sys/class/graphics/fb0/virtual_size", "1440,2560")
        self.width, self.height = (int(value) for value in size.split(","))
        self.stride = self.width * 4
        self.length = self.stride * self.height
        self.buf = bytearray(self.length)
        self.sequence = 0
        self.shared_fd = os.open(SHARED_FRAME, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
        os.ftruncate(self.shared_fd, 8 + self.length)
        self.shared = mmap.mmap(self.shared_fd, 8 + self.length, mmap.MAP_SHARED,
                                mmap.PROT_READ | mmap.PROT_WRITE)
        self.presenter = subprocess.Popen([KMS_HELPER, SHARED_FRAME])
        time.sleep(0.5)
        if self.presenter.poll() is not None:
            raise RuntimeError("KMS presenter failed to start")

    @staticmethod
    def pixel(color):
        red, green, blue = color
        return bytes((blue, green, red, 0))

    def rect(self, x, y, width, height, color):
        x = max(0, min(self.width, int(x)))
        y = max(0, min(self.height, int(y)))
        width = max(0, min(self.width - x, int(width)))
        height = max(0, min(self.height - y, int(height)))
        if not width or not height:
            return
        row = self.pixel(color) * width
        for line in range(y, y + height):
            start = line * self.stride + x * 4
            self.buf[start:start + width * 4] = row

    def clear(self, color):
        row = self.pixel(color) * self.width
        padding = b"\0" * max(0, self.stride - self.width * 4)
        frame_row = row + padding
        self.buf[:] = frame_row * self.height

    def text_width(self, text, scale):
        return max(0, len(text) * 6 * scale - scale)

    def text(self, x, y, text, scale=8, color=None, center=False, max_chars=0):
        color = color or COLORS["text"]
        text = str(text).upper()
        if max_chars and len(text) > max_chars:
            text = text[:max(1, max_chars - 1)] + "?"
        if center:
            x -= self.text_width(text, scale) // 2
        pixel = self.pixel(color)
        for char in text:
            glyph = FONT.get(char, FONT["?"])
            for row, bits in enumerate(glyph):
                for col, bit in enumerate(bits):
                    if bit == "1":
                        px = x + col * scale
                        py = y + row * scale
                        if px < 0 or py < 0 or px + scale > self.width or py + scale > self.height:
                            continue
                        block = pixel * scale
                        for line in range(py, min(py + scale, self.height)):
                            start = line * self.stride + px * 4
                            self.buf[start:start + scale * 4] = block
            x += 6 * scale

    def present(self):
        self.sequence += 1
        struct.pack_into("<Q", self.shared, 0, self.sequence)
        self.shared[8:] = self.buf
        self.sequence += 1
        struct.pack_into("<Q", self.shared, 0, self.sequence)

    def close(self):
        if self.presenter.poll() is None:
            self.presenter.terminate()
            try:
                self.presenter.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.presenter.kill()
        self.shared.close()
        os.close(self.shared_fd)
        try:
            os.unlink(SHARED_FRAME)
        except OSError:
            pass


class ControlPanel:
    def __init__(self):
        self.fb = Framebuffer()
        self.buttons = []
        self.page = "dashboard"
        self.message = ""
        self.networks = []
        self.selected_ssid = ""
        self.selected_security = ""
        self.password = ""
        self.key_mode = "ABC"
        self.last_touch = time.monotonic()
        self.last_refresh = 0.0
        self.screen_on = False
        self.touch_x = 0
        self.touch_y = 0
        self.touch_down = False
        self.suppress_click = False
        self.manual_charge = os.path.exists(MANUAL_CHARGE_MARKER)
        self.input_fd = os.open(INPUT, os.O_RDONLY | os.O_NONBLOCK)
        if self.manual_charge:
            self.apply_manual_charge()

    def write_sysfs(self, path, value):
        try:
            with open(path, "w", encoding="ascii") as handle:
                handle.write(str(value))
        except OSError:
            pass

    def set_screen(self, on):
        if on:
            for path in glob.glob("/sys/class/backlight/*/bl_power"):
                self.write_sysfs(path, 0)
            for path in glob.glob("/sys/class/backlight/*/brightness"):
                maximum = read_int(os.path.join(os.path.dirname(path), "max_brightness"))
                self.write_sysfs(path, max(1, min(1200, maximum)))
            self.screen_on = True
            self.last_touch = time.monotonic()
            self.draw()
        else:
            for path in glob.glob("/sys/class/backlight/*/brightness"):
                self.write_sysfs(path, 0)
            for path in glob.glob("/sys/class/backlight/*/bl_power"):
                self.write_sysfs(path, 4)
            self.screen_on = False

    def add_button(self, x, y, width, height, label, action, color="panel2", scale=7):
        self.fb.rect(x, y, width, height, COLORS[color])
        max_chars = max(1, (width - 30) // (6 * scale))
        label = str(label)
        if len(label) > max_chars:
            label = label[:max(1, max_chars - 1)] + "?"
        self.fb.text(x + width // 2, y + (height - 7 * scale) // 2, label,
                     scale, center=True)
        self.buttons.append((x, y, x + width, y + height, action))

    def charger_path(self):
        for path in glob.glob("/sys/class/power_supply/*"):
            if read_text(os.path.join(path, "type")) != "USB":
                continue
            if os.path.exists(os.path.join(path, "voltage_now")):
                return path
        return ""

    def battery_path(self):
        for path in glob.glob("/sys/class/power_supply/*"):
            if read_text(os.path.join(path, "type")) == "Battery":
                return path
        return ""

    def metrics(self):
        charger = self.charger_path()
        battery = self.battery_path()
        voltage, voltage_metered = read_iio_channel("usbin_v")
        current, current_metered = read_iio_channel("usbin_i")
        if charger and not voltage_metered:
            voltage = read_int(os.path.join(charger, "voltage_now"))
        if charger and not current_metered:
            current = read_int(os.path.join(charger, "current_now"))
        limit = read_int(os.path.join(charger, "current_max")) if charger else 0
        online = read_int(os.path.join(charger, "online")) if charger else 0
        capacity = read_text(os.path.join(battery, "capacity"), "--") if battery else "--"
        battery_current = read_int(os.path.join(battery, "current_now")) if battery else 0
        status = read_text(os.path.join(charger, "status"), "OFFLINE") if charger else "OFFLINE"
        mode = read_text("/sys/class/typec/port0/power_operation_mode", "NO TYPEC")
        if not online:
            contract = "DISCONNECTED"
        elif voltage >= 6500000:
            contract = "PD 9V"
        elif "delivery" in mode.lower():
            contract = "USB PD"
        elif voltage > 0:
            contract = "USB 5V"
        else:
            contract = "USB ONLINE"

        if battery_current > 50000:
            battery_flow = "CHARGING"
        elif battery_current < -50000:
            battery_flow = "DISCHARGING"
        else:
            battery_flow = "IDLE"

        if not online:
            source = "BATTERY ONLY"
        elif battery_current < -50000:
            source = "USB + BATTERY"
        elif battery_current > 50000:
            source = "USB + CHARGING"
        else:
            source = "USB ONLY"

        return {
            "voltage": voltage / 1_000_000,
            "current": current / 1_000_000,
            "limit": limit / 1_000_000,
            "power": voltage * current / 1_000_000_000_000,
            "capacity": capacity,
            "battery_current": battery_current / 1_000_000,
            "battery_flow": battery_flow,
            "metered": voltage_metered and current_metered,
            "source": source,
            "status": status,
            "contract": contract,
        }

    def apply_manual_charge(self):
        run(["systemctl", "stop", "razer-charge-limits.service"])
        charger = self.charger_path()
        if charger:
            behaviour = os.path.join(charger, "charge_behaviour")
            if os.path.exists(behaviour):
                self.write_sysfs(behaviour, "auto\n")
            else:
                self.write_sysfs(os.path.join(charger, "status"), "Charging\n")

    def set_manual_charge(self, enabled, completed=False):
        self.manual_charge = enabled
        if enabled:
            os.makedirs(os.path.dirname(MANUAL_CHARGE_MARKER), exist_ok=True)
            with open(MANUAL_CHARGE_MARKER, "w", encoding="ascii") as handle:
                handle.write("charge-to-full\n")
            self.apply_manual_charge()
            self.message = "CHARGING TO 100%"
        else:
            try:
                os.unlink(MANUAL_CHARGE_MARKER)
            except OSError:
                pass
            run(["systemctl", "start", "razer-charge-limits.service"])
            self.message = "100% COMPLETE" if completed else "40-80 LIMIT ACTIVE"

    def update_manual_charge(self):
        if not self.manual_charge:
            return
        battery = self.battery_path()
        capacity = read_int(os.path.join(battery, "capacity")) if battery else 0
        if capacity >= 100:
            self.set_manual_charge(False, completed=True)

    def wifi_info(self):
        result = run(["nmcli", "-t", "-f", "GENERAL.CONNECTION,IP4.ADDRESS",
                      "device", "show", "wlan0"], timeout=4)
        connection, address = "DISCONNECTED", ""
        for line in result.stdout.splitlines():
            if line.startswith("GENERAL.CONNECTION:"):
                connection = line.split(":", 1)[1] or "DISCONNECTED"
            elif line.startswith("IP4.ADDRESS"):
                address = line.split(":", 1)[1].split("/", 1)[0]
        return connection, address

    def draw_header(self, title):
        self.fb.rect(0, 0, self.fb.width, 210, COLORS["panel"])
        self.fb.text(70, 72, title, 11, COLORS["text"], max_chars=18)

    def draw_dashboard(self):
        data = self.metrics()
        ssid, address = self.wifi_info()
        self.draw_header("POWER PANEL")
        power_color = COLORS["green"] if data["power"] > 0.05 else COLORS["amber"]
        power_text = f'{data["power"]:.2f} W' if data["metered"] else "METER N/A"
        self.fb.text(self.fb.width // 2, 330, power_text, 20,
                     power_color, center=True)
        self.fb.text(self.fb.width // 2, 570,
                     f'USB IN {data["voltage"]:.3f} V  {data["current"]:.3f} A',
                     10, COLORS["text"], center=True)
        self.fb.text(self.fb.width // 2, 675,
                     f'{data["contract"]}  {data["status"]}',
                     6, COLORS["muted"], center=True, max_chars=32)
        self.fb.rect(70, 760, self.fb.width - 140, 800, COLORS["panel"])
        rows = [
            ("POWER SOURCE", data["source"]),
            ("BATTERY", f'{data["capacity"]} %'),
            ("BAT FLOW", data["battery_flow"]),
            ("BAT CURRENT", f'{data["battery_current"]:+.3f} A'),
            ("USB LIMIT", f'{data["limit"]:.3f} A'),
            ("POLICY", "TO 100%" if self.manual_charge else "40-80"),
            ("WIFI", ssid),
            ("IP", address or "--"),
        ]
        y = 800
        for label, value in rows:
            self.fb.text(110, y, label, 6, COLORS["muted"])
            self.fb.text(610, y, value, 5, COLORS["text"], max_chars=24)
            y += 90
        charge_label = "USE 40-80 LIMIT" if self.manual_charge else "CHARGE TO 100%"
        charge_color = "amber" if self.manual_charge else "green"
        self.add_button(70, 1620, 1300, 180, charge_label, "charge_toggle", charge_color, 8)
        self.add_button(70, 1850, 620, 200, "WIFI", "wifi", "cyan", 9)
        self.add_button(750, 1850, 620, 200, "REFRESH", "refresh", "panel2", 7)
        self.add_button(70, 2100, 1300, 200, "SCREEN OFF", "screen_off", "panel2", 8)
        if self.message:
            self.fb.text(self.fb.width // 2, 2380, self.message, 5,
                         COLORS["amber"], center=True, max_chars=34)

    @staticmethod
    def split_nmcli(line):
        fields, field, escaped = [], [], False
        for char in line:
            if escaped:
                field.append(char)
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == ":":
                fields.append("".join(field))
                field = []
            else:
                field.append(char)
        fields.append("".join(field))
        return fields

    def scan_wifi(self):
        self.message = "SCANNING"
        self.draw()
        result = run(["nmcli", "-t", "--escape", "yes", "-f",
                      "SSID,SIGNAL,SECURITY", "device", "wifi", "list",
                      "--rescan", "yes", "ifname", "wlan0"], timeout=20)
        found = {}
        for line in result.stdout.splitlines():
            fields = self.split_nmcli(line)
            if len(fields) < 3 or not fields[0]:
                continue
            try:
                signal = int(fields[1])
            except ValueError:
                signal = 0
            old = found.get(fields[0])
            if old is None or signal > old[0]:
                found[fields[0]] = (signal, fields[2])
        self.networks = sorted(((ssid, *values) for ssid, values in found.items()),
                               key=lambda item: item[1], reverse=True)[:8]
        self.message = "" if self.networks else (result.stderr.strip() or "NO NETWORKS")

    def draw_wifi(self):
        self.draw_header("WIFI NETWORKS")
        self.add_button(990, 45, 380, 120, "BACK", "dashboard", "panel2", 7)
        y = 260
        for index, (ssid, signal, security) in enumerate(self.networks):
            color = "cyan" if index == 0 else "panel"
            self.add_button(70, y, 1300, 205, ssid, ("network", index), color, 7)
            self.fb.text(110, y + 135, f"{signal}%  {security or 'OPEN'}", 5,
                         COLORS["muted"], max_chars=30)
            y += 230
        if self.message:
            self.fb.text(self.fb.width // 2, 2150, self.message, 6,
                         COLORS["amber"], center=True, max_chars=30)
        self.add_button(70, 2320, 1300, 170, "SCAN", "scan", "panel2", 8)

    def keyboard_rows(self):
        if self.key_mode == "SYM":
            return [list("!@#$%^&*()"), list("-_=+[]{}"), list(".,:;?/\\")]
        letters = [list("QWERTYUIOP"), list("ASDFGHJKL"), list("ZXCVBNM")]
        if self.key_mode == "abc":
            letters = [[char.lower() for char in row] for row in letters]
        return [list("1234567890")] + letters

    def draw_keyboard(self):
        self.draw_header("WIFI PASSWORD")
        self.add_button(1070, 45, 300, 120, "CANCEL", "wifi", "panel2", 5)
        self.fb.text(self.fb.width // 2, 280, self.selected_ssid, 8,
                     COLORS["cyan"], center=True, max_chars=24)
        masked = "*" * len(self.password)
        self.fb.rect(70, 410, 1300, 190, COLORS["panel"])
        self.fb.text(110, 470, masked or "PASSWORD", 7,
                     COLORS["text"] if masked else COLORS["muted"], max_chars=28)
        self.add_button(1120, 430, 220, 150, "DEL", "delete", "red", 6)
        rows = self.keyboard_rows()
        y = 690
        for row in rows:
            gap = 12
            width = min(120, (1300 - gap * (len(row) - 1)) // len(row))
            total = width * len(row) + gap * (len(row) - 1)
            x = (self.fb.width - total) // 2
            for key in row:
                self.add_button(x, y, width, 170, key, ("key", key), "panel2", 6)
                x += width + gap
            y += 195
        self.add_button(70, 1700, 370, 190, self.key_mode, "key_mode", "panel2", 7)
        self.add_button(465, 1700, 500, 190, "SPACE", ("key", " "), "panel2", 7)
        self.add_button(990, 1700, 380, 190, "CLEAR", "clear", "panel2", 6)
        if self.message:
            self.fb.text(self.fb.width // 2, 2040, self.message, 6,
                         COLORS["amber"], center=True, max_chars=30)
        self.add_button(70, 2240, 1300, 230, "CONNECT", "connect", "green", 9)

    def draw(self):
        if not self.screen_on:
            return
        self.buttons = []
        self.fb.clear(COLORS["bg"])
        if self.page == "dashboard":
            self.draw_dashboard()
        elif self.page == "wifi":
            self.draw_wifi()
        else:
            self.draw_keyboard()
        self.fb.present()
        self.last_refresh = time.monotonic()

    def connect_wifi(self):
        self.message = "CONNECTING"
        self.draw()
        args = ["nmcli", "device", "wifi", "connect", self.selected_ssid,
                "ifname", "wlan0", "name", self.selected_ssid]
        if self.selected_security:
            args[5:5] = ["password", self.password]
        result = run(args, timeout=35)
        if result.returncode == 0:
            run(["nmcli", "connection", "modify", self.selected_ssid,
                 "connection.autoconnect", "yes", "connection.autoconnect-priority", "100"])
            self.message = "WIFI CONNECTED"
            self.page = "dashboard"
        else:
            self.message = (result.stderr.strip() or "CONNECTION FAILED")[-30:]
        self.draw()

    def action(self, action):
        self.last_touch = time.monotonic()
        if action == "wifi":
            self.page = "wifi"
            self.scan_wifi()
        elif action == "dashboard":
            self.page = "dashboard"
            self.message = ""
        elif action in ("refresh", "scan"):
            if self.page == "wifi":
                self.scan_wifi()
            self.message = ""
        elif action == "screen_off":
            self.set_screen(False)
            return
        elif action == "charge_toggle":
            self.set_manual_charge(not self.manual_charge)
        elif action == "delete":
            self.password = self.password[:-1]
        elif action == "clear":
            self.password = ""
        elif action == "key_mode":
            self.key_mode = {"ABC": "abc", "abc": "SYM", "SYM": "ABC"}[self.key_mode]
        elif action == "connect":
            self.connect_wifi()
            return
        elif isinstance(action, tuple) and action[0] == "network":
            self.selected_ssid, _, self.selected_security = self.networks[action[1]]
            self.password = ""
            self.message = ""
            if self.selected_security:
                self.page = "keyboard"
            else:
                self.connect_wifi()
                return
        elif isinstance(action, tuple) and action[0] == "key":
            if len(self.password) < 63:
                self.password += action[1]
        self.draw()

    def click(self, x, y):
        for left, top, right, bottom, action in reversed(self.buttons):
            if left <= x < right and top <= y < bottom:
                print(f"touch x={x} y={y} action={action}", flush=True)
                self.action(action)
                break
        else:
            print(f"touch x={x} y={y} action=none", flush=True)

    def finish_touch(self):
        if not self.touch_down:
            return
        self.touch_down = False
        if self.suppress_click:
            self.suppress_click = False
        else:
            self.click(self.touch_x, self.touch_y)

    def process_input(self):
        try:
            data = os.read(self.input_fd, EVENT.size * 64)
        except BlockingIOError:
            return
        for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
            _, _, event_type, code, value = EVENT.unpack_from(data, offset)
            if event_type == EV_ABS:
                if code in (ABS_X, ABS_MT_POSITION_X):
                    self.touch_x = max(0, min(self.fb.width - 1, value))
                elif code in (ABS_Y, ABS_MT_POSITION_Y):
                    self.touch_y = max(0, min(self.fb.height - 1, value))
                elif code == ABS_MT_TRACKING_ID:
                    if value >= 0:
                        self.touch_down = True
                        if not self.screen_on:
                            self.set_screen(True)
                            self.suppress_click = True
                    else:
                        self.finish_touch()
            elif event_type == EV_KEY and code == BTN_TOUCH:
                if value:
                    self.touch_down = True
                    if not self.screen_on:
                        self.set_screen(True)
                        self.suppress_click = True
                else:
                    self.finish_touch()

    def loop(self):
        self.set_screen(True)
        while True:
            timeout = 1.0 if self.screen_on else None
            readable, _, _ = select.select([self.input_fd], [], [], timeout)
            if readable:
                self.process_input()
            now = time.monotonic()
            self.update_manual_charge()
            if self.screen_on and now - self.last_touch >= IDLE_SECONDS:
                self.set_screen(False)
            elif self.screen_on and self.page == "dashboard" and now - self.last_refresh >= 2:
                self.draw()

    def close(self):
        os.close(self.input_fd)
        self.fb.close()


def main():
    panel = ControlPanel()
    try:
        panel.loop()
    finally:
        panel.close()


if __name__ == "__main__":
    main()
