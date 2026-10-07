from datetime import datetime, timedelta, timezone

import alert

NOW = datetime(2026, 10, 7, 12, 0, tzinfo=timezone.utc)
ISO = "%Y-%m-%dT%H:%M:%SZ"
CONFIG = {"owner": "o", "runnerRoot": "/tmp/forge-test", "wslDistro": "Ubuntu", "repos": [{"name": "r"}]}


def fake_world(offline):
    def gh(path):
        if path.startswith("repos/o/r/actions/runners"):
            return {"runners": [{"name": "w1", "status": "offline" if offline() else "online"}]}
        if path == "repos/o/r":
            return {"default_branch": "main"}
        if "status=queued" in path:
            return {"workflow_runs": [{"id": 1, "name": "CI"}]}
        if "status=in_progress" in path:
            return {"workflow_runs": []}
        if path.startswith("repos/o/r/actions/runs/1/jobs"):
            return {"jobs": [{"id": 9, "name": "test", "status": "queued",
                              "created_at": (NOW - timedelta(minutes=15)).strftime(ISO), "labels": ["self-hosted"]}]}
        if "status=failure" in path:
            return {"workflow_runs": [{"id": 5, "run_attempt": 1, "name": "CI", "updated_at": NOW.strftime(ISO), "head_sha": "abcdef12"}]}
        raise AssertionError(path)
    return gh


def test_alert_lifecycle(monkeypatch):
    world = {"offline": True}
    monkeypatch.setattr(alert, "gh", fake_world(lambda: world["offline"]))
    sent = []
    send = lambda _dir, title, _body, _dry: sent.append(title)  # noqa: E731

    state = alert.run_checks(CONFIG, {}, NOW, True, send)
    assert sent == ["Job stuck in queue", "Failure on default branch"]  # offline only after 2 checks

    sent.clear()
    state = alert.run_checks(CONFIG, state, NOW + timedelta(minutes=10), True, send)
    assert sent == ["Runner offline"]  # queue/failure are not repeated

    sent.clear()
    world["offline"] = False
    state = alert.run_checks(CONFIG, state, NOW + timedelta(minutes=20), True, send)
    assert sent == []

    world["offline"] = True
    state = alert.run_checks(CONFIG, state, NOW + timedelta(minutes=30), True, send)
    state = alert.run_checks(CONFIG, state, NOW + timedelta(minutes=40), True, send)
    assert sent == ["Runner offline"]  # down again -> alerts again


def test_alerts_expire_after_a_week(monkeypatch):
    monkeypatch.setattr(alert, "gh", fake_world(lambda: False))
    old = {"alerted": {"queue:1": (NOW - timedelta(days=8)).isoformat(), "queue:2": NOW.isoformat()}}
    state = alert.run_checks(CONFIG, old, NOW, True, lambda *a: None)
    assert "queue:1" not in state["alerted"] and "queue:2" in state["alerted"]
