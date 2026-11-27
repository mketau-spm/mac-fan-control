# Security

FanCurve installs a helper that runs as root (`/Library/PrivilegedHelperTools/com.fancurve.helper`).
It listens on `/var/run/fancurve.sock` (mode `0600`, owned by the user who installed it, peer uid checked)
and accepts only these commands: `hello`, `state`, `control` (a curve of 2–12 points) and `release`.
It never sets a fan outside Apple's minimum and maximum and never runs other programs.

## Reporting a problem

Please do not open a public issue for a security problem. Use
[private vulnerability reporting](https://github.com/mketau-spm/mac-fan-control/security/advisories/new)
on GitHub. Say which version you use and how to reproduce the problem.
