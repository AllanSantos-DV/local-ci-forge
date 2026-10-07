# local-ci-forge

**Run your GitHub Actions on your own Windows + WSL machine — same workflows, same releases, no hosted-minute cap.**

[Português](README.pt-BR.md) · [Site](https://allansantos-dv.github.io/local-ci-forge/) · [Changelog](CHANGELOG.md) · [Backlog](BACKLOG.md)

local-ci-forge turns a Windows 11 workstation into a fleet of GitHub **self-hosted runners** — native Windows
plus Linux in WSL — and routes each repository's jobs to it with one repository variable. It packages the
fixes you only find after running real CI on a machine you also use every day: per-runner Python, a Dev Drive,
safe parallelism, job metrics, a dashboard and alerts.

## Why

GitHub-hosted runners bill private repositories by the minute against a monthly quota, and Windows and macOS
minutes cost more than Linux ones. Teams that ship often run out of minutes before the month ends — and then
CI, CD and releases stop.

"GitHub Actions usage is free for self-hosted runners and for public repositories that use standard
GitHub-hosted runners" ([GitHub Docs: Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)).
The runner itself is easy to install; running *many* of them on one workstation reliably is not. local-ci-forge
is that second part.

> A per-minute platform fee for self-hosted runners was announced by GitHub in December 2025 and postponed
> indefinitely two days later. Check the current pricing before relying on it.

## How it works

```
 git push / PR / tag
        │
        ▼
 GitHub Actions ── runs-on: ${{ vars.CI_RUNNER == 'local' && fromJSON('["self-hosted","Linux"]') || 'ubuntu-latest' }}
        │
        ├─ CI_RUNNER=local ──► this machine: Windows runners (<runnerRoot>\<repo>-wN) + WSL runners (~/actions-runner/<repo>-lN)
        └─ unset / hosted ───► GitHub-hosted (bypass, e.g. when the machine is off)
```

- **Same workflows, same releases.** Only `runs-on` changes; artifacts, releases and Pages deploys work as before.
- **One switch per repo.** `gh variable set CI_RUNNER -b hosted` sends that repo back to GitHub-hosted.
- **Configured in one file.** `forge.json` lists your repos and how many Windows/Linux runners each gets.

## What you get

| Piece | What it does |
|---|---|
| `install.ps1` | End-to-end setup from `forge.json`: toolchain, WSL, Dev Drive, elevated logon task, runners, alerts |
| `windows\sync-runners.ps1` | Runner **count control**: registers the missing runners, removes extras (idle only) |
| `windows\start-runners.ps1` | Logon task: mounts the Dev Drive, gives every Windows runner its own Python, wires hooks, starts runners |
| `windows\setup-devdrive.ps1` | Moves the runners to a **Dev Drive** (ReFS + Defender performance mode) behind a junction |
| `windows\restart-runners.ps1` | Restart without a UAC prompt (asks the elevated task) |
| `tools\route_workflows.py` | Rewrites a repo's workflows for `CI_RUNNER` routing and turns off cache restores on local runners |
| `tools\report.py` / `tools\metrics.py` | Runners per repo, job duration/queue/failures (local vs hosted), **estimated billable minutes saved** |
| `tools\dashboard.py` | Self-contained HTML dashboard of projects and runners |
| `tools\alert.py` + `windows\install-alerts.ps1` | Windows notifications: runner offline, job stuck in queue, failure on the default branch |
| `hooks\` | Per-job log line (`_logs/<runner>.jsonl`) and a clean TEMP before every job |

## Requirements

- Windows 11 (Dev Drive needs build 22621.2338+; it is optional), admin rights for the one-time setup
- WSL 2 with Ubuntu, passwordless `sudo` for your user (jobs run `sudo apt-get`)
- PowerShell 7 (`pwsh`), Git for Windows (Git Bash), [GitHub CLI](https://cli.github.com/) logged in with **admin** on the repos
- Python 3.10+ on Windows (for the tools); Docker Desktop with WSL integration if your jobs use service containers
- **Private repositories only** — see [Security](#security)

## Install

```powershell
git clone https://github.com/AllanSantos-DV/local-ci-forge
cd local-ci-forge
Copy-Item config\forge.example.json forge.json
notepad forge.json        # owner, repos and runner counts
.\install.ps1             # asks for UAC twice (Dev Drive, logon task)
```

`forge.json`:

```json
{
  "owner": "your-github-user",
  "runnerRoot": "C:\\actions-runner",
  "wslDistro": "Ubuntu",
  "devDrive": { "enabled": true, "vhdxPath": "C:\\DevDrives\\actions-runner.vhdx", "sizeGB": 150, "defenderExclusion": false },
  "repos": [
    { "name": "my-app", "windows": 1, "linux": 2, "python": ["3.12"] }
  ]
}
```

`python` lists the versions your Windows jobs request with `actions/setup-python`; each Windows runner gets
its own copy. Change counts later and run `windows\sync-runners.ps1`.

## Integrate a repository

1. Route its workflows and open a PR:
   ```powershell
   python tools\route_workflows.py C:\path\to\my-app
   ```
   Every `runs-on: ubuntu-latest|windows-latest` becomes the `CI_RUNNER` expression, and `cache:` of
   `setup-node/java/python` is skipped on local runners (they are persistent; the restore only re-downloads
   what is already on disk). It flags what needs a human: matrix `runs-on`, `container:`, macOS/pinned images.
2. **Read every workflow before routing it.** Exclude anything that must not run on the machine you use —
   tests that drive the real desktop, or touch production services:
   `--exclude desktop-tests.yml`.
3. Turn it on: `gh variable set CI_RUNNER -b local -R <owner>/my-app`. Until then, nothing changes.

Matrix jobs: add a `local` field and use `runs-on: ${{ vars.CI_RUNNER == 'local' && matrix.local || matrix.os }}`:

```yaml
strategy:
  matrix:
    include:
      - os: windows-latest
        local: [self-hosted, Windows]
      - os: ubuntu-latest
        local: [self-hosted, Linux]
```

## Daily use

```powershell
python tools\report.py --days 1          # text report
python tools\dashboard.py --open         # HTML dashboard (projects, runners, jobs, saved minutes)
python tools\metrics.py --json           # raw metrics for your own tooling
.\windows\sync-runners.ps1               # apply new runner counts from forge.json
.\windows\restart-runners.ps1            # after changing scripts or forge.json (no UAC)
```

## Sizing

- **One runner runs one job.** Give a repo as many runners as the jobs of one run that must overlap. If a job
  waits for another job's artifact (e.g. a bundle waiting for a release jar), one runner per OS deadlocks.
- **Personal accounts only have repository-level runners**, so every repo gets its own instances. An idle
  runner costs ~95 MB of RAM; a Java test job ~2.7 GB.
- **WSL memory is a ceiling, not a reservation.** `.wslconfig` `memory=` caps the VM (shared with Docker
  Desktop); it grows on demand and gives memory back when idle. Too many runners plus heavy jobs under a low
  cap makes WSL stop answering. Repos with short jobs need one Linux runner.
- **Parallel jobs share your CPU.** Timing-sensitive tests (barriers, process races) can time out under load,
  which never happens on hosted runners.

## Security

- **Use it with private repositories only.** On a public repo, a pull request from a fork would run
  untrusted code on your machine. Public repos do not consume Actions minutes anyway.
- Windows runners run **elevated** (`actions/setup-python` needs admin to install Python). A job can do
  anything you can.
- `devDrive.defenderExclusion` (off by default) stops Defender from scanning everything jobs download and run.
- Runners use your Windows user profile and WSL home (`~/.m2`, `~/.npm`, ...). Review workflows that touch
  credentials or the desktop before routing them.

## Troubleshooting

| Symptom | Cause | Fix (already in local-ci-forge unless noted) |
|---|---|---|
| `setup-python` on Windows: "Error happened during Python installation" | needs admin; installer registers one copy per version machine-wide | elevated logon task + per-runner Python from python-build-standalone |
| `ModuleNotFoundError: tkinter` | NuGet Python is a reduced build | per-runner Python comes from python-build-standalone (has tkinter) |
| `shell: bash` steps run in WSL on Windows | `System32\bash.exe` comes first on PATH | start-runners puts Git Bash first |
| `Could not get lock /var/lib/apt/lists/lock` | parallel `sudo apt-get` | `flock` wrapper in `/usr/local/sbin/apt-get` |
| Maven: "Source option 5 is no longer supported" | apt's Maven defaults to compiler-plugin 3.1 | official Maven in `/opt` (also: pin `maven-compiler-plugin` in your pom) |
| Corrupted jar in `~/.m2` | parallel `mvn` on a shared local repo | `MAVEN_ARGS` file lock in every runner's `.env` |
| WSL stops answering, many `wsl.exe` processes | VM out of memory / one holder per task trigger | size runners to the VM; single holder via `flock` |
| Runner config has `_work\r` | PowerShell writes CRLF to a native stdin | scripts are passed to WSL as base64 |
| Node action aborts on Windows: `UV_HANDLE_CLOSING` assertion | node20 action forced onto Node 24 | upgrade the action (e.g. `astral-sh/setup-uv` ≥ v10.2.0) — in your workflow |
| `Get-FileHash` not recognized in `powershell.exe` spawned by a test | PS 7 module path inherited by PS 5.1 | drop `PSModulePath` from the child env — in your code |
| Freshly written `.exe` takes 20–60 s to start in tests | Defender Block at First Sight | Dev Drive (and optionally the Defender exclusion) |
| Runners online but jobs queued forever, `BrokerServer` errors in `_diag` | GitHub Actions incident | check [githubstatus.com](https://www.githubstatus.com/) |

Logs: `<runnerRoot>\start-runners.log`, `<runnerRoot>\<runner>\_diag\`, `~/actions-runner/<runner>/runner.log`,
`<runnerRoot>\_logs\` (hooks, alerts, dashboard).

## Limitations

Windows 11 + WSL only (no macOS/Linux hosts yet), no ARM runners, no fallback to GitHub-hosted when the
machine is off (switch `CI_RUNNER` by hand), runners are persistent (not ephemeral). See [BACKLOG.md](BACKLOG.md).

## License

[MIT](LICENSE)
