# Changelog

## v0.1.0 — 2026-10-07

First public release, extracted from a setup that runs the CI and releases of 9 private repositories.

- `install.ps1`: end-to-end setup from `forge.json` (toolchain, WSL, Dev Drive, elevated logon task, runners, alerts).
- `sync-runners.ps1`: runner count control per repo (adds missing, removes idle extras), runner binary checked by SHA-256.
- Per-runner Python on Windows from python-build-standalone (parallel jobs, tkinter included, no installer).
- Dev Drive migration behind a junction; optional Defender exclusion.
- Job hooks: per-job JSON log and clean TEMP per job; Maven cross-process file lock via `MAVEN_ARGS`.
- WSL: official Maven, apt lock wrapper, single `wsl.exe` holder.
- Tools: `route_workflows.py`, `report.py`, `metrics.py` (billable minutes saved), `dashboard.py`, `alert.py`.
- Restart without UAC through the elevated task.
