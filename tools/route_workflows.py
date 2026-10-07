"""Routes a repository's workflows to the local self-hosted runners through the repo variable CI_RUNNER.

Rewrites .github/workflows/*.yml:
  - `runs-on: ubuntu-latest` / `windows-latest` -> an expression that picks the local runner when
    vars.CI_RUNNER == 'local' and the GitHub-hosted one otherwise;
  - `cache: <npm|yarn|pnpm|maven|gradle|sbt|pip|pipenv|poetry>` of setup-* actions -> no cache on the local
    runner (it is persistent and already has ~/.m2, ~/.npm, ...; the restore would download it every job).

Warns, without changing, about what needs a human look: runs-on from a matrix, `container:`, pinned images
(ubuntu-24.04, macos-*). Read every workflow before routing: some must not run on a machine you use (e.g.
tests that drive the real desktop, or that reach production services) — pass them in --exclude.

Usage: python tools/route_workflows.py <repo-dir> [--exclude workflow.yml ...]
"""
import argparse
import re
import sys
from pathlib import Path

LINUX = "${{ vars.CI_RUNNER == 'local' && fromJSON('[\"self-hosted\",\"Linux\"]') || 'ubuntu-latest' }}"
WINDOWS = "${{ vars.CI_RUNNER == 'local' && fromJSON('[\"self-hosted\",\"Windows\"]') || 'windows-latest' }}"
RUNS_ON = re.compile(r"(?m)^(\s*runs-on:\s*)['\"]?(ubuntu-latest|windows-latest)['\"]?(?=\s*(#.*)?$)")
CACHE = re.compile(r"\bcache:\s*['\"]?(npm|yarn|pnpm|maven|gradle|sbt|pip|pipenv|poetry)['\"]?(?=\s*(,|\}|#|$))", re.M)
REVIEW = [
    (re.compile(r"(?m)^\s*runs-on:\s*\$\{\{\s*matrix"), "runs-on from a matrix (route by hand, e.g. a matrix.local field)"),
    (re.compile(r"(?m)^\s*container:"), "job with container: (needs Docker on the runner)"),
    (re.compile(r"(?m)^\s*runs-on:\s*['\"]?(ubuntu-2\d\.04|windows-20\d\d|macos-[\w.-]+)"), "pinned image/macOS (not routed)"),
]


def route_text(text):
    """Returns (new_text, runs_on_count, cache_count, review_notes)."""
    text, n_runs = RUNS_ON.subn(lambda m: m.group(1) + (LINUX if m.group(2) == "ubuntu-latest" else WINDOWS), text)
    text, n_cache = CACHE.subn(lambda m: f"cache: \"${{{{ vars.CI_RUNNER != 'local' && '{m.group(1)}' || '' }}}}\"", text)
    return text, n_runs, n_cache, [msg for rx, msg in REVIEW if rx.search(text)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    parser.add_argument("--exclude", nargs="*", default=[], help="workflow file names that always stay on GitHub-hosted")
    args = parser.parse_args()
    files = sorted(Path(args.repo, ".github", "workflows").glob("*.y*ml"))
    if not files:
        sys.exit(f"no workflows in {args.repo}/.github/workflows")
    for path in files:
        if path.name in args.exclude:
            print(f"{path.name}: excluded (stays on GitHub-hosted)")
            continue
        raw = path.read_bytes()
        newline = "\r\n" if b"\r\n" in raw else "\n"
        text, n_runs, n_cache, notes = route_text(raw.decode("utf-8"))
        if n_runs or n_cache:
            path.write_bytes(text.replace("\r\n", "\n").replace("\n", newline).encode("utf-8"))
        print(f"{path.name}: {n_runs} runs-on, {n_cache} cache" + (f"  ! {'; '.join(notes)}" if notes else ""))


if __name__ == "__main__":
    main()
