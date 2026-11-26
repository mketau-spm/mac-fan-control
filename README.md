# FanCurve

A tiny menu bar app that lets you set your own fan curve on Apple Silicon MacBook Pros.
It reads the average temperature of all CPU cores and sets the fan speed from the curve you draw.

<p align="center"><img src="docs/screenshot.png" width="300" alt="FanCurve popover: temperature, fan speed, curve and profile"></p>

- **One popover, nothing else.** Temperature, fan speed, an on/off switch, the curve and the profile.
- **Drag the curve.** Double-click empty space to add a point, double-click a point to remove it.
- **Profiles.** Quiet, Balanced, Cool, Cold and Very Cold, plus your own: save, rename, delete.
- **Safe by default.** See [Safety](#safety).
- **15 languages**, chosen from your system language: English, Chinese (Simplified), Hindi, Spanish,
  French, Arabic, Bengali, Portuguese, Russian, Urdu, Indonesian, German, Japanese, Turkish, Korean.

> Works on MacBook Pro with M-series chips (tested on M5 Pro, macOS 27). Macs without fans,
> such as MacBook Air, have nothing to control.

## Install

FanCurve is built from source. You need Xcode or the Xcode Command Line Tools.

```sh
git clone https://github.com/mketau-spm/mac-fan-control.git
cd mac-fan-control
scripts/build.sh --install
open /Applications/FanCurve.app
```

`scripts/build.sh` compiles the app and the helper, runs all tests, signs the bundle
(with your Apple Development certificate if you have one, otherwise ad-hoc) and, with `--install`,
copies it to `/Applications`.

On first launch click the fan icon in the menu bar, then **Allow fan control**.
macOS asks for your password once to install the helper that talks to the fans.

## How it works

| Part | Installed to | Role |
|---|---|---|
| `App/` (SwiftUI) | `/Applications/FanCurve.app` | Menu bar popover, profiles in `~/Library/Application Support/FanCurve/profiles.json` |
| `Helper/fancurved.m` | `/Library/PrivilegedHelperTools/com.fancurve.helper` | `launchd` daemon running as root: reads temperatures (IOHID) and sets fans (SMC keys `F<n>md` / `F<n>Md`, `F<n>Tg`) |
| Unix socket | `/var/run/fancurve.sock` | App ↔ helper, one JSON object per line. Mode `0600`, owner = the user who installed it, peer uid checked |

The helper only drives the fans **while the app is connected**. With no app connected it sleeps
and leaves the fans to macOS.

## Safety

- Fan speed always stays between Apple's minimum and maximum for each fan.
- Average core temperature ≥ 90 °C or any core ≥ 95 °C → fans go to 100 % at once.
- The curve can never go down: hotter never means slower.
- Speed changes are smoothed: up to +20 %/s, down to −3 %/s.
- New targets are written at most every 3 s and only when they change by ≥ 3 %.
  The safety rule, the first write, a new curve and reaching min/max skip this.
- Fans go back to macOS when the app quits or crashes, the switch is off, sensors are missing,
  the SMC refuses a write, or the helper gets a signal or restarts.

## Tests

```sh
scripts/build.sh
```

- `Tests/helper_test.py` — end-to-end tests of the helper in `--fake` mode (no root, simulated fans).
- `Tests/CurveTests.swift` — curve math, presets, profile storage, the display filter.

Run the UI against simulated fans:

```sh
build/fancurved --fake --socket /tmp/fc.sock &
open -n build/FanCurve.app --env FANCURVE_SOCKET=/tmp/fc.sock
```

Try another language: `open -n build/FanCurve.app --args -AppleLanguages "(ja)"`.

## Uninstall

```sh
sudo sh Helper/uninstall-helper.sh
rm -rf /Applications/FanCurve.app
```

## Disclaimer

FanCurve writes to the System Management Controller through undocumented keys. It never sets a fan
outside Apple's own limits and always hands the fans back to macOS when it stops, but you use it at
your own risk.

## License

[MIT](LICENSE)
