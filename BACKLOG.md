# Backlog

Known gaps and ideas, roughly by value. Not implemented in v0.1.0.

- **Automatic fallback to GitHub-hosted** when the machine is offline (a cheap gate job that checks runner
  status and flips `runs-on`); today `CI_RUNNER` is switched by hand.
- **Uninstall script** (unregister runners, remove tasks, optionally the Dev Drive).
- **Ephemeral runners** (`--ephemeral` + re-register per job) for stronger isolation between jobs.
- **Organization-level runners**: one pool shared by every repo in an org, instead of per-repo instances.
- **Linux/macOS hosts** (systemd units instead of the Windows logon task).
- **Metrics history**: append `metrics.py --json` snapshots and chart trends in the dashboard.
- **Alert channels** beyond Windows toasts (e-mail, chat webhooks).
- **Concurrency guard** for heavy jobs (e.g. at most N Java test jobs at once across repos) to protect
  timing-sensitive tests and WSL memory.
- **Dashboard served live** (small local HTTP server with refresh) instead of a generated file.
- **Workflow audit** in `route_workflows.py`: detect desktop-acting tests and production endpoints automatically.
