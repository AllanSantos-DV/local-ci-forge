#!/usr/bin/env bash
# Starts the Linux runners in WSL (~/actions-runner/*) and keeps one wsl.exe alive so the distro stays up.
# A runner that is already running is skipped.
HOOKS="$(cd "$(dirname "$0")/../hooks" && pwd)"

for dir in "$HOME"/actions-runner/*/; do
  dir="${dir%/}"
  [ -f "$dir/.runner" ] || continue
  # Read by the runner from the .env in its directory: job hooks (per-job log line + clean TMPDIR) and
  # MAVEN_ARGS with Maven's cross-process file lock (runners share ~/.m2).
  { grep -vE '^(ACTIONS_RUNNER_HOOK_|MAVEN_ARGS=)' "$dir/.env" 2>/dev/null
    echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$HOOKS/job-started.sh"
    echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$HOOKS/job-completed.sh"
    echo "MAVEN_ARGS=-Daether.syncContext.named.factory=file-lock -Daether.syncContext.named.nameMapper=file-gav"
  } >"$dir/.env.new" && mv "$dir/.env.new" "$dir/.env"
  if pgrep -f "$dir/bin/Runner.Listener" >/dev/null; then echo "$(basename "$dir"): already running"; continue; fi
  # TMPDIR per runner: parallel jobs sharing /tmp step on each other (e.g. pytest-of-$USER cleanup).
  mkdir -p "$dir/_tmp"
  (cd "$dir" && TMPDIR="$dir/_tmp" nohup ./run.sh >>"$dir/runner.log" 2>&1 &)
  echo "$(basename "$dir"): started"
done

# Keep wsl.exe alive while any runner of this user exists. Only ONE process does it: every task trigger
# (logon, sync, restart) runs this script, and without the lock each copy stayed alive forever.
exec 9>"$HOME/actions-runner/.wsl-start.lock"
flock -n 9 || exit 0
while pgrep -u "$USER" -f 'actions-runner/.*/bin/Runner.Listener' >/dev/null; do sleep 60; done
