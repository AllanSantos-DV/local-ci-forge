"""Shared helpers for the local-ci-forge Python tools: config, GitHub API via `gh`, WSL, local runners."""
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

FORGE_ROOT = Path(__file__).resolve().parent.parent
# CREATE_NO_WINDOW: no console flashing when a tool runs from a hidden scheduled task (pythonw).
NO_WINDOW = 0x08000000 if sys.platform == "win32" else 0


def load_config():
    path = FORGE_ROOT / "forge.json"
    if not path.exists():
        sys.exit(f"forge.json not found at {path}. Copy config/forge.example.json to forge.json and edit it.")
    config = json.loads(path.read_text(encoding="utf-8"))
    for key in ("owner", "runnerRoot", "wslDistro", "repos"):
        if not config.get(key):
            sys.exit(f"forge.json: '{key}' is required")
    return config


def gh(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True, creationflags=NO_WINDOW))


def gh_optional(path):
    """Like gh(), but returns None on HTTP errors (e.g. a repo variable that does not exist)."""
    out = subprocess.run(["gh", "api", path], capture_output=True, text=True, creationflags=NO_WINDOW)
    return json.loads(out.stdout) if out.returncode == 0 else None


def wsl(config, cmd, check=True):
    # errors="replace": without a console (pythonw) wsl.exe may print system messages in another encoding;
    # reading must not die because of that.
    out = subprocess.run(["wsl.exe", "-d", config["wslDistro"], "-e", "bash", "-c", cmd], capture_output=True,
                         encoding="utf-8", errors="replace", creationflags=NO_WINDOW)
    if check and out.returncode:
        raise RuntimeError(f"wsl.exe failed ({out.returncode}): {(out.stderr or out.stdout).strip()[:300]}")
    return out.stdout


def ts(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def local_runner_configs(config):
    """Every .runner file on this machine (Windows and WSL): agentName and gitHubUrl of each local runner."""
    configs = []
    for f in Path(config["runnerRoot"]).glob("*/.runner"):
        configs.append(json.loads(f.read_text(encoding="utf-8-sig")))
    out = wsl(config, "for f in ~/actions-runner/*/.runner; do [ -f \"$f\" ] || continue; "
                      "tr -d '\\n\\r' < \"$f\" | sed 's/^\\xef\\xbb\\xbf//'; echo; done", check=False)
    for line in out.splitlines():
        if line.strip():
            configs.append(json.loads(line))
    return configs


def forge_repos(config):
    """owner/repo for every repo in forge.json."""
    return [f"{config['owner']}/{r['name']}" for r in config["repos"]]


def log_dirs(config):
    return Path(config["runnerRoot"]) / "_logs"


def hook_events(config):
    """Job events recorded by the hooks on Windows and in WSL, oldest first."""
    lines = []
    for f in log_dirs(config).glob("*.jsonl"):
        if f.name.startswith("alert"):
            continue
        lines += f.read_text(encoding="utf-8-sig").splitlines()
    lines += wsl(config, "cat ~/actions-runner/_logs/*.jsonl 2>/dev/null", check=False).splitlines()
    events = []
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("event") in ("started", "completed"):
            events.append(e)
    return sorted(events, key=lambda e: e["ts"])
