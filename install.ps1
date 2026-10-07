<#
.SYNOPSIS
  Sets up local-ci-forge on this machine from forge.json: toolchain, WSL, Dev Drive, the elevated logon
  task, the runners of every repo and the alerts. Asks for UAC where admin is needed. Idempotent.

.EXAMPLE
  Copy-Item config\forge.example.json forge.json   # then edit it
  .\install.ps1
#>
param([switch]$SkipDevDrive, [switch]$SkipAlerts)
. "$PSScriptRoot\windows\common.ps1"
$config = Get-ForgeConfig
$win = Join-Path $PSScriptRoot 'windows'

function Invoke-Elevated([string]$script, [string[]]$extra = @()) {
    if (Test-ForgeAdmin) { & $script @extra; return }
    $p = Start-Process pwsh -Verb RunAs -Wait -PassThru -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"") + $extra)
    if ($p.ExitCode) { throw "$(Split-Path $script -Leaf) failed (exit $($p.ExitCode))" }
}

'== 1/6 Windows toolchain'
& "$win\provision-windows.ps1"

'== 2/6 WSL toolchain'
$provision = (& wsl.exe -d $config.wslDistro -e wslpath -a (Join-Path $PSScriptRoot 'wsl\provision-wsl.sh')).Trim()
wsl.exe -d $config.wslDistro -e bash $provision $config.mavenVersion
if ($LASTEXITCODE) { throw 'wsl/provision-wsl.sh failed' }

if ($config.devDrive -and $config.devDrive.enabled -and -not $SkipDevDrive) {
    '== 3/6 Dev Drive (UAC)'
    Invoke-Elevated "$win\setup-devdrive.ps1"
} else { '== 3/6 Dev Drive: skipped' }

'== 4/6 Elevated logon task (UAC)'
Invoke-Elevated "$win\install-task.ps1"

'== 5/6 Runners'
& "$win\sync-runners.ps1"

if (-not $SkipAlerts) {
    '== 6/6 Alerts'
    & "$win\install-alerts.ps1"
} else { '== 6/6 Alerts: skipped' }

@"

Done. Next, in each repo:
  1. python tools\route_workflows.py <path-to-repo>   (review the diff, open a PR)
  2. gh variable set CI_RUNNER -b local -R $($config.owner)/<repo>
Status: python tools\report.py   |   Dashboard: python tools\dashboard.py
"@
