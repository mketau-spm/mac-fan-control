#!/usr/bin/env python3
"""End-to-end tests for fancurved in --fake mode (no root needed).

Usage: python3 -I Tests/helper_test.py path/to/fancurved
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

HELPER = os.path.abspath(sys.argv[1])
failures = 0


def check(name, cond, detail=""):
    global failures
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures += 1


class Conn:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(3)
        self.s.connect(path)
        self.f = self.s.makefile("r")

    def req(self, obj):
        self.s.sendall((json.dumps(obj) + "\n").encode())
        return json.loads(self.f.readline())

    def close(self):
        self.f.close()  # makefile() keeps the fd open until it is closed too
        self.s.close()


def start(env_extra=None):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "s.sock")
    env = dict(os.environ, **(env_extra or {}))
    p = subprocess.Popen([HELPER, "--fake", "--socket", path], env=env, stderr=subprocess.PIPE)
    for _ in range(50):
        if os.path.exists(path):
            break
        time.sleep(0.05)
    return p, path


CURVE = [[40, 0], [60, 50], [80, 100]]

# --- basic protocol, curve math, permissions
FAST = {"FANCURVE_FAKE_RAMP": "20,3"}  # quick slew so curve tests don't wait a minute
p, path = start({"FANCURVE_FAKE_TEMP": "50", **FAST})
check("socket is owner-only (0600)", oct(os.stat(path).st_mode & 0o777) == "0o600", oct(os.stat(path).st_mode))
c = Conn(path)
check("hello returns version", c.req({"cmd": "hello"}).get("version") == 5)
s = c.req({"cmd": "state"})
check("state before control is auto", s["mode"] == "auto", s["mode"])
check("state has 2 fans", len(s["fans"]) == 2)
s = c.req({"cmd": "control", "enabled": True, "points": CURVE})
check("control → curve mode", s["mode"] == "curve", s)
check("50 °C on curve → 25 %", s["pct"] == 25.0, s["pct"])
check("client is controlling", s["controlling"] is True)
fan0 = s["fans"][0]
time.sleep(1.2)
s = c.req({"cmd": "state"})
check("fan target = min + 25% of range", abs(s["fans"][0]["target"] - (1350 + 0.25 * (5349 - 1350))) <= 1, s["fans"][0])
check("fan in manual", s["fans"][0]["manual"] is True)

# --- validation
for bad, why in [([[40, 0]], "one point"), ([[40, 0], [40.5, 10]], "points too close"),
                 ([[40, 0], [60, 150]], "pct > 100"), ([[10, 0], [60, 10]], "temp < 20"),
                 ("x", "not a list"), ([[40, "a"], [50, 1]], "string value")]:
    r = c.req({"cmd": "control", "enabled": True, "points": bad})
    check(f"rejects {why}", r.get("ok") is False, r)
r = c.req({"cmd": "control", "enabled": True, "points": [[40, 60], [60, 20]]})
check("ramp up is limited per second", r["ok"] and 25 < r["pct"] <= 45.0, r.get("pct"))
time.sleep(2.3)
r = c.req({"cmd": "state"})
check("non-monotonic curve is flattened, not slower when hotter", r["pct"] == 60.0, r.get("pct"))
c.req({"cmd": "control", "enabled": True, "points": [[40, 0], [60, 0]]})
time.sleep(1.2)
r = c.req({"cmd": "state"})
check("ramp down is limited per second", 50 <= r["pct"] < 60, r.get("pct"))
c.req({"cmd": "control", "enabled": True, "points": CURVE})

# --- disable → auto
s = c.req({"cmd": "control", "enabled": False, "points": CURVE})
check("disabled → auto", s["mode"] == "auto" and s["fans"][0]["manual"] is False, s["mode"])

# --- a second client cannot keep fans manual after the controller leaves
c.req({"cmd": "control", "enabled": True, "points": CURVE})
c2 = Conn(path)
check("second client sees curve but is not controlling", (lambda s: s["mode"] == "curve" and not s["controlling"])(c2.req({"cmd": "state"})))
c.close()
time.sleep(0.3)
s = c2.req({"cmd": "state"})
check("controller disconnect → auto immediately", s["mode"] == "auto" and s["fans"][0]["manual"] is False, s)
c2.close()

# --- garbage input does not kill the helper
c = Conn(path)
c.s.sendall(b"not json\n")
check("bad json → error reply", json.loads(c.f.readline()).get("ok") is False)
for bad in [{"cmd": "control", "enabled": [1], "points": CURVE}, {"cmd": "control", "enabled": "yes", "points": CURVE},
            {"cmd": ["control"]}, [1, 2], {"cmd": "control", "enabled": True, "points": CURVE, "response": "x"}]:
    r = c.req(bad)
    check(f"badly typed request gets a reply: {json.dumps(bad)[:40]}", isinstance(r, dict) and "ok" in r, r)
check("helper still alive", p.poll() is None)
c.close()

# --- SIGTERM exits cleanly and removes the socket
p.terminate()
p.wait(3)
check("SIGTERM exits 0", p.returncode == 0, p.returncode)
check("socket removed on exit", not os.path.exists(path))

# --- failsafe
p, path = start()
c = Conn(path)
c.req({"cmd": "fake-temp", "value": 91})
s = c.req({"cmd": "control", "enabled": True, "points": [[40, 0], [100, 10]]})
check("avg 91 °C is not a fail-safe any more", s["mode"] == "curve", s["mode"])
c.req({"cmd": "fake-temp", "value": 96})
time.sleep(1.2)
s = c.req({"cmd": "state"})
check("avg ≥ 95 °C → failsafe 100 % regardless of curve", s["mode"] == "failsafe" and s["pct"] == 100.0, s)
c.req({"cmd": "fake-temp", "value": 92})
time.sleep(1.2)
check("fail-safe holds until avg < 90 °C (no flapping)", c.req({"cmd": "state"})["mode"] == "failsafe")
c.req({"cmd": "fake-temp", "value": 89})
time.sleep(1.2)
s = c.req({"cmd": "state"})
check("fail-safe ends below 90 °C and fans slow down gradually", s["mode"] == "curve" and s["pct"] >= 93, (s["mode"], s["pct"]))
c.close(); p.terminate(); p.wait(3)

# --- SMC refusal → error mode, fans back to auto, re-enable retries
p, path = start({"FANCURVE_FAKE_TEMP": "50", "FANCURVE_FAKE_REFUSE": "1"})
c = Conn(path)
s = c.req({"cmd": "control", "enabled": True, "points": CURVE})
check("SMC refusal → error mode with message", s["mode"] == "error" and "refused" in (s["error"] or ""), s)
check("after refusal fans are not manual", all(not f["manual"] for f in s["fans"]))
c.close(); p.terminate(); p.wait(3)

# --- write throttle: ≤ 1 write per 3 s, only for ≥ 3 % changes; fail-safe, new curve and min/max skip it
MIN0, MAX0 = 1350, 5349
rpm = lambda pct: MIN0 + pct / 100 * (MAX0 - MIN0)
p, path = start(FAST)
c = Conn(path)
T = lambda s: s["fans"][0]["target"]
st = lambda: c.req({"cmd": "state"})
c.req({"cmd": "fake-temp", "value": 50})
s = c.req({"cmd": "control", "enabled": True, "points": CURVE})
check("throttle: first write is immediate", abs(T(s) - rpm(25)) <= 1, T(s))
c.req({"cmd": "fake-temp", "value": 70})  # curve wants 75 %
time.sleep(1.2)
s = st()
check("throttle: big change within 3 s is held", abs(T(s) - rpm(25)) <= 1 and s["pct"] > 25, (T(s), s["pct"]))
time.sleep(2.3)
s = st()
check("throttle: after 3 s the new target is written", T(s) > rpm(25) + 500, T(s))
time.sleep(4.5)
s = st()
settled = T(s)
check("throttle: settles on the curve", s["applied"] == 75.0 and abs(settled - rpm(75)) <= 1, (s["applied"], settled))
c.req({"cmd": "fake-temp", "value": 70.4})  # 76 % → +40 rpm, under 1 %
time.sleep(4.5)
check("throttle: < 3 % change is never written", T(st()) == settled)
c.req({"cmd": "fake-temp", "value": 96})
time.sleep(1.2)
s = st()
check("throttle: fail-safe skips it → max at once", s["mode"] == "failsafe" and T(s) == MAX0, (s["mode"], T(s)))
c.req({"cmd": "fake-temp", "value": 60})
s = c.req({"cmd": "control", "enabled": True, "points": [[40, 0], [60, 4]]})
check("throttle: new curve is written at once", s["applied"] == s["pct"], (s["applied"], s["pct"]))
c.close(); p.terminate(); p.wait(3)

p, path = start(FAST)  # fresh helper: start at 4 %, then fall to the minimum
c = Conn(path)
c.req({"cmd": "fake-temp", "value": 60})
s = c.req({"cmd": "control", "enabled": True, "points": [[40, 0], [60, 4]]})
check("throttle: starts at 4 %", s["applied"] == 4.0, s["applied"])
c.req({"cmd": "fake-temp", "value": 40})  # want 0 %: 4 → 1 (held, < 3 s) → 0 = min (written at once)
time.sleep(2.2)
s = st()
check("throttle: reaching the minimum is written without waiting", T(s) == MIN0, T(s))
c.close(); p.terminate(); p.wait(3)

# --- thermal inertia: the curve follows a smoothed temperature
SM = [[40, 0], [60, 50], [80, 100]]
p, path = start(FAST)
c = Conn(path)
c.req({"cmd": "fake-temp", "value": 40})
c.req({"cmd": "control", "enabled": True, "points": SM, "response": 0})  # response 0 → follows the raw value at once
s = c.req({"cmd": "control", "enabled": True, "points": SM, "response": 20})
check("inertia: starts from the raw temperature", s["cpu"]["effective"] == 40.0 and s["pct"] == 0.0, s["cpu"])
check("inertia: response is reported", s["response"] == 20, s.get("response"))
c.req({"cmd": "fake-temp", "value": 80})
time.sleep(2.2)
s = c.req({"cmd": "state"})
check("inertia: short spike barely moves the fans", s["cpu"]["avg"] == 80.0 and s["cpu"]["effective"] < 50 and s["pct"] < 25,
      (s["cpu"], s["pct"]))
s = c.req({"cmd": "control", "enabled": True, "points": SM, "response": 2})  # same session: no reset
check("inertia: a new response keeps the smoothed value", s["cpu"]["effective"] < 50, s["cpu"])
time.sleep(8.2)
s = c.req({"cmd": "state"})
check("inertia: long load reaches the curve", s["cpu"]["effective"] > 78 and s["pct"] > 90, (s["cpu"], s["pct"]))
c.req({"cmd": "control", "enabled": True, "points": SM, "response": 12})  # falling: 4 s
c.req({"cmd": "fake-temp", "value": 40})
time.sleep(1.2)
s = c.req({"cmd": "state"})
check("inertia: cooling is smoothed too", 60 < s["cpu"]["effective"] < 78, s["cpu"])
c.close(); p.terminate(); p.wait(3)

# --- soft response near the fail-safe, slow default slew
p, path = start()
c = Conn(path)
c.req({"cmd": "fake-temp", "value": 40})
c.req({"cmd": "control", "enabled": True, "points": SM, "response": 0})
c.req({"cmd": "control", "enabled": True, "points": SM, "response": 300})
c.req({"cmd": "fake-temp", "value": 93})
time.sleep(3.2)
s = c.req({"cmd": "state"})
# 300 s normally → +0.5 °C in 3 s; at 93 °C the time constant is 60 s → about +2.6 °C
check("inertia: near the fail-safe the response gets faster, without a jump",
      41.8 < s["cpu"]["effective"] < 46, s["cpu"])
c.req({"cmd": "fake-temp", "value": 70})
before = c.req({"cmd": "control", "enabled": True, "points": SM, "response": 0})["pct"]  # curve wants 75 % now
time.sleep(3.2)
s = c.req({"cmd": "state"})
check("slew: fans rise by about 2 % per second", 4 <= s["pct"] - before <= 8.5, (before, s["pct"]))
c.req({"cmd": "fake-temp", "value": 96})
time.sleep(1.2)
s = c.req({"cmd": "state"})
check("slew: the fail-safe still goes to 100 % at once", s["mode"] == "failsafe" and s["pct"] == 100.0, (s["mode"], s["pct"]))
c.close(); p.terminate(); p.wait(3)

print(f"\n{failures} failure(s)")
sys.exit(1 if failures else 0)
