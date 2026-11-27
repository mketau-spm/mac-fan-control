# Changelog

## 1.0.0 — 2026-11-27

First public release.

- Menu bar popover: core temperature, fan speed, on/off switch, draggable curve, profile.
- Presets Quiet, Balanced, Cool, Cold and Very Cold, plus your own profiles.
- Thermal inertia: the curve follows a smoothed temperature (Fast 10 s, Smooth 45 s,
  Very Smooth 90 s). Cooling is followed three times faster than heating.
- Fan level changes by at most +2 %/s and −3 %/s.
- Fail-safe: 100 % at an average of 95 °C or any core at 105 °C, until 90 °C / 100 °C.
- Fans go back to macOS when the app quits or crashes, the switch is off, or the SMC refuses a write.
- 15 languages.
