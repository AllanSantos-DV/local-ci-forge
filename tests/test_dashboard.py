import json
import re

import dashboard

DATA = {
    "generated_at": "2026-10-07T12:00:00+00:00", "days": 7, "since": "2026-09-30", "owner": "o",
    "repos": [{
        "repo": "o/app", "private": True, "default_branch": "main", "ci_runner": "local",
        "runners": {"total": 2, "online": 1, "busy": ["host-app-l1"], "offline": ["host-app-w1"]},
        "totals": {"jobs": 3, "local": 2, "hosted": 1, "failures": 1, "local_minutes": 4.0, "hosted_minutes": 2.0,
                   "saved_billable_minutes": 6, "hosted_billable_minutes": 2},
        "jobs": [{"name": "<script>alert(1)</script>", "where": "local", "n": 2, "median_min": 2.0, "max_min": 3.0,
                  "queue_median_min": 6.0, "queue_max_min": 7.0, "failures": 1}],
    }],
    "hooks": {"running": [], "unpaired": [], "recent": [{"ts": "2026-10-07T11:00:00", "minutes": 1.5, "runner": "host-app-l1",
                                                        "repo": "o/app", "workflow": "CI", "job": "test"}]},
    "disk": {"runner_root_free_gb": 100.0, "runner_root_total_gb": 150.0, "wsl": "900G 1007G"},
}


def test_render_escapes_and_embeds_data():
    page = dashboard.render(DATA)
    assert "<script>alert(1)</script>" not in page.split('id="metrics">')[0]  # escaped in the tables
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in page
    embedded = re.search(r'<script type="application/json" id="metrics">(.*)</script>', page, re.S).group(1)
    assert json.loads(embedded.replace("<\\/", "</"))["repos"][0]["repo"] == "o/app"
    assert "</script>alert" not in embedded  # cannot close the JSON block early
    assert ">6<" in page and ">1/2<" in page  # saved minutes KPI and runners online
