"""Runner alerts (run every 10 min by the 'local-ci-forge-alerts' task).

Notifies (Windows toast + <runnerRoot>/_logs/alerts.jsonl) when:
  - a runner is offline in two consecutive checks (at boot it takes a moment to reconnect);
  - a job waits in the queue longer than alerts.queueMinutes (default 10);
  - a run fails on the repo's default branch.
Each situation is notified once; state lives in <runnerRoot>/_logs/alert-state.json.

Usage: python tools/alert.py [--dry-run]   (--dry-run prints instead of notifying and keeps no state)
"""
import argparse
import json
import os
import subprocess
from datetime import datetime, timedelta, timezone

from forge_common import NO_WINDOW, forge_repos, gh, load_config, log_dirs, ts

TOAST = r"""
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t = $xml.GetElementsByTagName('text')
$t.Item(0).AppendChild($xml.CreateTextNode($env:FORGE_TITLE)) | Out-Null
$t.Item(1).AppendChild($xml.CreateTextNode($env:FORGE_BODY)) | Out-Null
$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
"""


def notify(log_dir, title, body, dry_run):
    if dry_run:
        print(f"[alert] {title}: {body}")
        return
    log_dir.mkdir(parents=True, exist_ok=True)
    with open(log_dir / "alerts.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "title": title, "body": body}, ensure_ascii=False) + "\n")
    # Through Windows PowerShell 5.1: pwsh 7 does not load the WinRT toast APIs.
    subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", TOAST],
                   env={**os.environ, "FORGE_TITLE": title, "FORGE_BODY": body}, creationflags=NO_WINDOW, check=False)


def run_checks(config, state, now, dry_run, send=notify):
    """One round of checks. Returns the new state."""
    log_dir = log_dirs(config)
    queue_min = (config.get("alerts") or {}).get("queueMinutes", 10)
    offline_prev = set(state.get("offline_seen", []))
    alerted = dict(state.get("alerted", {}))  # key -> when it was notified
    last_check = state.get("last_check") or (now - timedelta(hours=1)).isoformat()
    offline_now = set()
    for repo in forge_repos(config):
        name = repo.split("/")[1]
        for r in gh(f"repos/{repo}/actions/runners?per_page=100")["runners"]:
            if r["status"] != "online":
                offline_now.add(r["name"])
                if r["name"] in offline_prev and f"offline:{r['name']}" not in alerted:
                    send(log_dir, "Runner offline", f"{r['name']} ({name}) has been offline for more than one check.", dry_run)
                    alerted[f"offline:{r['name']}"] = now.isoformat()
        default = gh(f"repos/{repo}")["default_branch"]
        for status in ("queued", "in_progress"):
            for run in gh(f"repos/{repo}/actions/runs?status={status}&per_page=50")["workflow_runs"]:
                for job in gh(f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100")["jobs"]:
                    waited = (now - ts(job["created_at"])).total_seconds() / 60
                    key = f"queue:{job['id']}"
                    if job["status"] == "queued" and waited > queue_min and key not in alerted:
                        send(log_dir, "Job stuck in queue", f"{name} · {run['name']} / {job['name']}: waiting {waited:.0f} min "
                             f"for a runner ({', '.join(job.get('labels') or [])}).", dry_run)
                        alerted[key] = now.isoformat()
        for run in gh(f"repos/{repo}/actions/runs?branch={default}&status=failure&per_page=20")["workflow_runs"]:
            key = f"fail:{run['id']}:{run['run_attempt']}"
            if run["updated_at"] > last_check and key not in alerted:
                send(log_dir, "Failure on default branch", f"{name} · {run['name']} failed on {default} ({run['head_sha'][:7]}).", dry_run)
                alerted[key] = now.isoformat()
    # A runner that came back may alert again on its next outage; job/run alerts expire after 7 days.
    week_ago = (now - timedelta(days=7)).isoformat()
    alerted = {k: t for k, t in alerted.items()
               if t > week_ago and not (k.startswith("offline:") and k.split(":", 1)[1] not in offline_now)}
    return {"last_check": now.isoformat(), "offline_seen": sorted(offline_now), "alerted": alerted}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    config = load_config()
    state_file = log_dirs(config) / "alert-state.json"
    state = json.loads(state_file.read_text(encoding="utf-8")) if state_file.exists() else {}
    new_state = run_checks(config, state, datetime.now(timezone.utc), args.dry_run)
    if not args.dry_run:
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(json.dumps(new_state, indent=1), encoding="utf-8")
    print(f"{new_state['last_check'][:16]} ok: offline={new_state['offline_seen'] or '-'}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # From the scheduled task it runs under pythonw (no console): without this the failure is silent.
        import traceback
        from forge_common import FORGE_ROOT
        with open(FORGE_ROOT / "alert-error.log", "a", encoding="utf-8") as f:
            f.write(f"--- {datetime.now(timezone.utc).isoformat()}\n{traceback.format_exc()}")
        raise
