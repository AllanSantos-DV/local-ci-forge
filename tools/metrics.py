"""Collects local-ci-forge metrics: runners, jobs (local vs GitHub-hosted), saved minutes, hook events, disk.

Usage: python tools/metrics.py [--days N] [--json]
Used by report.py and dashboard.py.
"""
import argparse
import json
import math
import shutil
import statistics
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from forge_common import forge_repos, gh, gh_optional, hook_events, load_config, local_runner_configs, ts, wsl

# ESTIMATE of hosted billable minutes: each job rounded up to the whole minute, weighted by OS the way the
# included-minutes quota was historically counted (Windows 2x, macOS 10x). Private repos only; public
# repos and self-hosted runners are free (https://docs.github.com/en/billing/concepts/product-billing/github-actions).
MULTIPLIER = {"windows": 2, "macos": 10, "linux": 1}


def job_os(job):
    # Hosted jobs carry labels like windows-latest; local ones carry self-hosted + Windows/Linux.
    labels = " ".join(job.get("labels") or []).lower()
    if "windows" in labels:
        return "windows"
    if "macos" in labels:
        return "macos"
    return "linux"


def collect(config, days=1):
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    local_names = {c.get("agentName") for c in local_runner_configs(config)}
    result = {"generated_at": datetime.now(timezone.utc).isoformat(), "days": days, "since": since,
              "owner": config["owner"], "repos": []}
    for repo in forge_repos(config):
        info = gh(f"repos/{repo}")
        var = gh_optional(f"repos/{repo}/actions/variables/CI_RUNNER")
        runners = gh(f"repos/{repo}/actions/runners?per_page=100")["runners"]
        entry = {
            "repo": repo, "private": info.get("private", False), "default_branch": info.get("default_branch"),
            "ci_runner": (var or {}).get("value", ""),
            "runners": {
                "total": len(runners),
                "online": sum(r["status"] == "online" for r in runners),
                "busy": [r["name"] for r in runners if r["busy"]],
                "offline": [r["name"] for r in runners if r["status"] != "online"],
            },
        }
        groups = defaultdict(list)
        totals = {"jobs": 0, "local": 0, "hosted": 0, "failures": 0, "local_minutes": 0.0, "hosted_minutes": 0.0,
                  "saved_billable_minutes": 0, "hosted_billable_minutes": 0}
        runs = gh(f"repos/{repo}/actions/runs?per_page=100&created=%3E%3D{since}")["workflow_runs"]
        for run in runs:
            if run["status"] != "completed":
                continue
            jobs = gh(f"repos/{repo}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs?per_page=100")["jobs"]
            for job in jobs:
                if not job["started_at"] or not job["completed_at"] or job["conclusion"] in (None, "skipped"):
                    continue
                where = "local" if job.get("runner_name") in local_names else "hosted"
                minutes = (ts(job["completed_at"]) - ts(job["started_at"])).total_seconds() / 60
                queue = (ts(job["started_at"]) - ts(job["created_at"])).total_seconds() / 60
                failed = job["conclusion"] != "success"
                billable = math.ceil(minutes) * MULTIPLIER[job_os(job)] if entry["private"] else 0
                groups[(job["name"], where)].append((minutes, queue, failed))
                totals["jobs"] += 1
                totals[where] += 1
                totals["failures"] += failed
                totals[f"{where}_minutes"] += minutes
                totals["saved_billable_minutes" if where == "local" else "hosted_billable_minutes"] += billable
        entry["totals"] = {k: round(v, 1) if isinstance(v, float) else v for k, v in totals.items()}
        entry["jobs"] = []
        for (name, where), items in sorted(groups.items(), key=lambda kv: -sum(i[0] for i in kv[1])):
            durations, queues, fails = zip(*items)
            entry["jobs"].append({"name": name, "where": where, "n": len(items),
                                  "median_min": round(statistics.median(durations), 2), "max_min": round(max(durations), 2),
                                  "queue_median_min": round(statistics.median(queues), 2), "queue_max_min": round(max(queues), 2),
                                  "failures": sum(fails)})
        result["repos"].append(entry)

    busy = {name for r in result["repos"] for name in r["runners"]["busy"]}
    open_jobs, finished = {}, []
    for e in hook_events(config):
        key = (e.get("runner"), e.get("run_id"), e.get("job"), e.get("attempt"))
        if e["event"] == "started":
            # A runner runs one job at a time: an unmatched "started" on the same runner is over.
            for stale in [k for k in open_jobs if k[0] == key[0]]:
                del open_jobs[stale]
            open_jobs[key] = e
        elif key in open_jobs:
            start = open_jobs.pop(key)
            finished.append({**start, "minutes": round((ts(e["ts"]) - ts(start["ts"])).total_seconds() / 60, 2)})
    result["hooks"] = {
        "running": [e for e in open_jobs.values() if e["runner"] in busy],
        "unpaired": [e for e in open_jobs.values() if e["runner"] not in busy],
        "recent": finished[-25:][::-1],
    }
    usage = shutil.disk_usage(config["runnerRoot"]) if Path(config["runnerRoot"]).exists() else None
    result["disk"] = {
        "runner_root_free_gb": round(usage.free / 2**30, 1) if usage else None,
        "runner_root_total_gb": round(usage.total / 2**30, 1) if usage else None,
        "wsl": wsl(config, "df -h --output=avail,size ~ | tail -1", check=False).strip(),
    }
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=1)
    parser.add_argument("--json", action="store_true", help="print JSON (default: a short summary)")
    args = parser.parse_args()
    data = collect(load_config(), args.days)
    if args.json:
        print(json.dumps(data, indent=1, ensure_ascii=False))
        return
    saved = sum(r["totals"]["saved_billable_minutes"] for r in data["repos"])
    hosted = sum(r["totals"]["hosted_billable_minutes"] for r in data["repos"])
    print(f"Since {data['since']}: {saved} billable minutes run locally (saved), {hosted} billable minutes on GitHub-hosted.")


if __name__ == "__main__":
    main()
