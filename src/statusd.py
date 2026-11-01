#!/usr/bin/env python3
"""sd-uploader status light daemon.

Shows the uploader's state on LEDs. The state is a single word in
/run/sd-uploader/state, written by the uploader (or `sd-uploader led <state>`).

  state      meaning                      gpio (3 LEDs)        act (onboard LED)
  idle       waiting for a card           all off              normal SD activity
  uploading  working, keep the card in    blue blinking        slow blink
  done       finished, safe to remove     green on             solid on
  error      failed, nothing deleted      red fast blinking    fast blink

LED_BACKEND in /etc/sd-uploader/sd-uploader.conf picks gpio, act or none.
"""
import os
import signal
import time

STATE_FILE = os.environ.get("SD_UPLOADER_RUN", "/run/sd-uploader") + "/state"
CONF_FILE = os.environ.get("SD_UPLOADER_CONF", "/etc/sd-uploader/sd-uploader.conf")
STATES = ("idle", "uploading", "done", "error")


def read_conf():
    conf = {"LED_BACKEND": "gpio", "LED_PIN_RED": "17", "LED_PIN_BLUE": "23", "LED_PIN_GREEN": "22"}
    try:
        with open(CONF_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    conf[key.strip()] = value.strip().strip('"')
    except FileNotFoundError:
        pass
    return conf


def read_state():
    try:
        with open(STATE_FILE) as f:
            state = f.read().strip()
    except FileNotFoundError:
        return "idle"
    # An unknown word means something wrote garbage: show it as an error.
    return state if state in STATES else "error"


class ActBackend:
    """The Pi's onboard green ACT LED, driven by the kernel's LED triggers."""

    def __init__(self):
        # Named ACT on current kernels, led0 on older ones.
        for name in ("ACT", "led0"):
            path = os.path.join("/sys/class/leds", name)
            if os.path.isdir(path):
                self.led = path
                break
        else:
            raise SystemExit("LED_BACKEND=act: no onboard ACT LED found in /sys/class/leds")

    def _write(self, name, value):
        with open(os.path.join(self.led, name), "w") as f:
            f.write(str(value))

    def _blink(self, on_ms, off_ms):
        self._write("trigger", "timer")
        self._write("delay_on", on_ms)
        self._write("delay_off", off_ms)

    def show(self, state):
        if state == "uploading":
            self._blink(500, 500)
        elif state == "done":
            self._write("trigger", "none")
            self._write("brightness", 1)
        elif state == "error":
            self._blink(100, 100)
        else:
            # Idle: give the LED back to its normal job (SD card activity).
            self._write("trigger", "mmc0")

    def close(self):
        self.show("idle")


class GpioBackend:
    """Red, blue and green LEDs on GPIO pins, each with a series resistor."""

    def __init__(self, conf):
        from gpiozero import LED

        self.red = LED(int(conf["LED_PIN_RED"]))
        self.blue = LED(int(conf["LED_PIN_BLUE"]))
        self.green = LED(int(conf["LED_PIN_GREEN"]))

    def show(self, state):
        for led in (self.red, self.blue, self.green):
            led.off()
        if state == "uploading":
            self.blue.blink(on_time=0.5, off_time=0.5)
        elif state == "done":
            self.green.on()
        elif state == "error":
            self.red.blink(on_time=0.1, off_time=0.1)

    def close(self):
        for led in (self.red, self.blue, self.green):
            led.off()
            led.close()


class NoBackend:
    """No light: the state is still kept for `sd-uploader status`."""

    def show(self, state):
        pass

    def close(self):
        pass


def make_backend(conf):
    backend = conf["LED_BACKEND"]
    if backend == "gpio":
        return GpioBackend(conf)
    if backend == "act":
        return ActBackend()
    if backend == "none":
        return NoBackend()
    raise SystemExit(f"unknown LED_BACKEND={backend} in {CONF_FILE} (use gpio, act or none)")


def main():
    light = make_backend(read_conf())

    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    shown = None
    while running:
        state = read_state()
        if state != shown:
            light.show(state)
            shown = state
        time.sleep(0.2)
    light.close()


if __name__ == "__main__":
    main()
