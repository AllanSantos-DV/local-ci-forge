"""Text report of the local runners: runners per repo, jobs (local vs hosted), what is running now, disk.

Usage: python tools/report.py [--days N]
"""
import argparse

from forge_common import load_config
from metrics import collect


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=1, help="job analysis window (default: 1 day)")
    args = parser.parse_args()
    data = collect(load_config(), args.days)

    print("## Runners\n")
    print("| repo | CI_RUNNER | online | busy | offline |")
    print("|---|---|---|---|---|")
    for r in data["repos"]:
        run = r["runners"]
        print(f"| {r['repo']} | {r['ci_runner'] or '-'} | {run['online']}/{run['total']} | "
              f"{', '.join(run['busy']) or '-'} | {', '.join(run['offline']) or '-'} |")

    print(f"\n## Jobs since {data['since']} (minutes)\n")
    print("| repo | job | where | n | median | max | queue median | queue max | failures |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in data["repos"]:
        for j in r["jobs"]:
            print(f"| {r['repo'].split('/')[1]} | {j['name'][:45]} | {j['where']} | {j['n']} | {j['median_min']:.1f} | "
                  f"{j['max_min']:.1f} | {j['queue_median_min']:.1f} | {j['queue_max_min']:.1f} | {j['failures']} |")
    saved = sum(r["totals"]["saved_billable_minutes"] for r in data["repos"])
    hosted = sum(r["totals"]["hosted_billable_minutes"] for r in data["repos"])
    print(f"\nBillable minutes run locally (not charged): **{saved}** · still on GitHub-hosted: **{hosted}**")

    print("\n## Now (job hooks)\n")
    for e in data["hooks"]["running"]:
        print(f"- running: {e['runner']} · {e['repo']} · {e['workflow']} / {e['job']} (since {e['ts'][:16]})")
    if not data["hooks"]["running"]:
        print("- no job running")
    for e in data["hooks"]["unpaired"]:
        print(f"- no end recorded (runner idle): {e['ts'][:16]} · {e['runner']} · {e['workflow']} / {e['job']}")
    print("\nLatest finished:\n")
    for e in data["hooks"]["recent"][:10]:
        print(f"- {e['ts'][:16]} · {e['minutes']:.1f} min · {e['runner']} · {e['repo']} · {e['workflow']} / {e['job']}")

    d = data["disk"]
    print("\n## Disk\n")
    print(f"- runner root: {d['runner_root_free_gb']} GB free of {d['runner_root_total_gb']} GB")
    print(f"- WSL: {d['wsl']} (free, total)")


if __name__ == "__main__":
    main()
