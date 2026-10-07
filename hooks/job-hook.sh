#!/usr/bin/env bash
# Job hook of the WSL runners (ACTIONS_RUNNER_HOOK_JOB_STARTED/COMPLETED, set in each runner's .env by
# wsl-start.sh). Appends one JSON line per event to ~/actions-runner/_logs/<runner>.jsonl and, when the job
# starts, empties the runner's TMPDIR. It must NEVER fail: a start hook that exits non-zero fails the job.
event="${1:-}"
{
  mkdir -p "$HOME/actions-runner/_logs"
  # /usr/bin/python3 explicitly: at the end of a job the PATH still has the job's setup-python Python,
  # which may not even load outside its environment (libpython*.so missing from LD_LIBRARY_PATH).
  /usr/bin/python3 - "$event" >>"$HOME/actions-runner/_logs/${RUNNER_NAME:-unknown}.jsonl" <<'PY'
import json, os, sys, datetime
e = os.environ.get
print(json.dumps({"event": sys.argv[1], "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "runner": e("RUNNER_NAME"), "repo": e("GITHUB_REPOSITORY"), "workflow": e("GITHUB_WORKFLOW"),
    "job": e("GITHUB_JOB"), "run_id": e("GITHUB_RUN_ID"), "attempt": e("GITHUB_RUN_ATTEMPT"),
    "ref": e("GITHUB_REF_NAME"), "trigger": e("GITHUB_EVENT_NAME")}, ensure_ascii=False))
PY
  case "${TMPDIR:-}" in
    "$HOME"/actions-runner/*/_tmp) [ "$event" = started ] && find "$TMPDIR" -mindepth 1 -delete 2>/dev/null ;;
  esac
} || echo "local-ci-forge job-hook ($event): failed to record"
exit 0
