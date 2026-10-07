"""Builds a self-contained HTML dashboard (projects + runners + metrics) from the collected metrics.

Usage: python tools/dashboard.py [--days N] [--out file.html] [--open]
Default output: <runnerRoot>/_logs/dashboard.html
"""
import argparse
import html
import json
import webbrowser
from pathlib import Path

from forge_common import load_config, log_dirs
from metrics import collect

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>local-ci-forge · dashboard</title>
<style>
:root{--bg:#0f1115;--card:#171a21;--line:#262b36;--text:#e6e8ee;--muted:#9aa3b2;--ok:#3fb950;--warn:#d29922;--bad:#f85149;--acc:#58a6ff}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 system-ui,Segoe UI,sans-serif;background:var(--bg);color:var(--text)}
header{padding:20px 28px;border-bottom:1px solid var(--line)}h1{margin:0;font-size:20px}h2{font-size:15px;margin:0 0 12px}
.sub{color:var(--muted)}main{padding:20px 28px;display:grid;gap:20px}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.kpi{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px}
.kpi b{display:block;font-size:24px}.kpi span{color:var(--muted);font-size:12px}
section{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;overflow:auto}
table{border-collapse:collapse;width:100%}th,td{padding:6px 10px;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}
th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase}td.num{text-align:right;font-variant-numeric:tabular-nums}
.pill{padding:1px 8px;border-radius:999px;font-size:12px;border:1px solid var(--line)}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.local{color:var(--acc)}
</style></head><body>
<header><h1>local-ci-forge</h1><div class="sub">__SUB__</div></header>
<main>
<div class="kpis">__KPIS__</div>
<section><h2>Projects</h2><table><thead><tr><th>repo</th><th>CI_RUNNER</th><th>runners</th><th>jobs</th><th>local</th>
<th>failures</th><th>saved billable min</th><th>hosted billable min</th></tr></thead><tbody>__PROJECTS__</tbody></table></section>
<section><h2>Runners</h2><table><thead><tr><th>repo</th><th>online</th><th>busy</th><th>offline</th></tr></thead><tbody>__RUNNERS__</tbody></table></section>
<section><h2>Jobs</h2><table><thead><tr><th>repo</th><th>job</th><th>where</th><th>n</th><th>median min</th><th>max min</th>
<th>queue median</th><th>queue max</th><th>failures</th></tr></thead><tbody>__JOBS__</tbody></table></section>
<section><h2>Recent jobs on this machine</h2><table><thead><tr><th>started (UTC)</th><th>min</th><th>runner</th><th>repo</th>
<th>workflow / job</th></tr></thead><tbody>__RECENT__</tbody></table></section>
</main>
<script type="application/json" id="metrics">__DATA__</script>
</body></html>
"""


def e(value):
    return html.escape(str(value))


def render(data):
    repos = data["repos"]
    saved = sum(r["totals"]["saved_billable_minutes"] for r in repos)
    hosted = sum(r["totals"]["hosted_billable_minutes"] for r in repos)
    online = sum(r["runners"]["online"] for r in repos)
    total = sum(r["runners"]["total"] for r in repos)
    jobs = sum(r["totals"]["jobs"] for r in repos)
    local = sum(r["totals"]["local"] for r in repos)
    fails = sum(r["totals"]["failures"] for r in repos)
    kpis = [("billable minutes saved", saved), ("billable minutes on GitHub", hosted),
            ("runners online", f"{online}/{total}"), ("jobs (local)", f"{jobs} ({local})"), ("failed jobs", fails),
            ("runner disk free", f"{data['disk']['runner_root_free_gb']} GB")]
    projects, runners, job_rows = [], [], []
    for r in repos:
        t, run = r["totals"], r["runners"]
        cls = "ok" if run["online"] == run["total"] and run["total"] else ("bad" if run["total"] else "warn")
        mode = f"<span class='pill {'local' if r['ci_runner'] == 'local' else ''}'>{e(r['ci_runner'] or 'unset')}</span>"
        projects.append(f"<tr><td>{e(r['repo'])}</td><td>{mode}</td><td class='{cls}'>{run['online']}/{run['total']}</td>"
                        f"<td class=num>{t['jobs']}</td><td class=num>{t['local']}</td><td class='num {'bad' if t['failures'] else ''}'>{t['failures']}</td>"
                        f"<td class=num>{t['saved_billable_minutes']}</td><td class=num>{t['hosted_billable_minutes']}</td></tr>")
        runners.append(f"<tr><td>{e(r['repo'])}</td><td class='{cls}'>{run['online']}/{run['total']}</td>"
                       f"<td>{e(', '.join(run['busy']) or '-')}</td><td class='{'bad' if run['offline'] else ''}'>{e(', '.join(run['offline']) or '-')}</td></tr>")
        for j in r["jobs"]:
            job_rows.append(f"<tr><td>{e(r['repo'].split('/')[1])}</td><td>{e(j['name'])}</td><td class='{'local' if j['where'] == 'local' else ''}'>{j['where']}</td>"
                            f"<td class=num>{j['n']}</td><td class=num>{j['median_min']:.1f}</td><td class=num>{j['max_min']:.1f}</td>"
                            f"<td class='num {'warn' if j['queue_median_min'] > 5 else ''}'>{j['queue_median_min']:.1f}</td><td class=num>{j['queue_max_min']:.1f}</td>"
                            f"<td class='num {'bad' if j['failures'] else ''}'>{j['failures']}</td></tr>")
    recent = [f"<tr><td>{e(x['ts'][:16])}</td><td class=num>{x['minutes']:.1f}</td><td>{e(x['runner'])}</td><td>{e(x['repo'])}</td>"
              f"<td>{e(x['workflow'])} / {e(x['job'])}</td></tr>" for x in data["hooks"]["recent"]]
    page = PAGE
    for key, value in {
        "__SUB__": e(f"{data['owner']} · since {data['since']} · generated {data['generated_at'][:16]} UTC"),
        "__KPIS__": "".join(f"<div class=kpi><b>{e(v)}</b><span>{e(k)}</span></div>" for k, v in kpis),
        "__PROJECTS__": "".join(projects) or "<tr><td colspan=8>no repos in forge.json</td></tr>",
        "__RUNNERS__": "".join(runners),
        "__JOBS__": "".join(job_rows) or "<tr><td colspan=9>no jobs in the window</td></tr>",
        "__RECENT__": "".join(recent) or "<tr><td colspan=5>no hook events yet</td></tr>",
        "__DATA__": json.dumps(data, ensure_ascii=False).replace("</", "<\\/"),
    }.items():
        page = page.replace(key, value)
    return page


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    config = load_config()
    out = args.out or log_dirs(config) / "dashboard.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render(collect(config, args.days)), encoding="utf-8")
    print(f"dashboard written: {out}")
    if args.open:
        webbrowser.open(out.resolve().as_uri())


if __name__ == "__main__":
    main()
