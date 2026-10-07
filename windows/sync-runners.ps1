<#
.SYNOPSIS
  Makes the self-hosted runners on this machine match forge.json: registers the missing ones and
  removes the extras (highest index first, only when idle).

.DESCRIPTION
  Personal GitHub accounts only have repository-level runners, so every repo gets its own instances:
  Windows in <runnerRoot>\<repo>-w<N>, Linux in WSL at ~/actions-runner/<repo>-l<N>.
  The runner binary comes from the official actions/runner release and is checked against the
  SHA-256 published in it. Needs `gh` logged in with admin rights on the repos. Removing a running
  Windows runner needs an elevated shell (the runners run elevated).

.EXAMPLE
  .\sync-runners.ps1                 # all repos in forge.json
  .\sync-runners.ps1 -Repo my-app    # one repo
#>
param([string]$Repo)
. "$PSScriptRoot\common.ps1"
$config = Get-ForgeConfig
$root = $config.runnerRoot
$distro = $config.wslDistro

$release = gh api repos/actions/runner/releases/latest | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'gh api failed while reading the actions/runner release (is gh logged in?)' }
$version = $release.tag_name.TrimStart('v')

function Get-Sha([string]$platform) {
    if ($release.body -notmatch "<!-- BEGIN SHA $platform -->([0-9a-f]{64})<!-- END SHA $platform -->") {
        throw "SHA-256 for $platform not found in the notes of runner release v$version"
    }
    $Matches[1]
}

function New-Token([string]$fullRepo, [string]$kind) {
    $t = gh api -X POST "repos/$fullRepo/actions/runners/$kind-token" --jq .token
    if ($LASTEXITCODE -or -not $t) { throw "could not create a $kind token for $fullRepo (admin rights on the repo are required)" }
    $t
}

function Get-RemoteRunners([string]$fullRepo) {
    (gh api "repos/$fullRepo/actions/runners?per_page=100" | ConvertFrom-Json).runners
}

function Add-WindowsRunner([string]$fullRepo, [string]$name, [int]$i) {
    $dist = Join-Path $root '_dist'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $zip = Join-Path $dist "actions-runner-win-x64-$version.zip"
    if (-not (Test-Path $zip)) {
        Invoke-WebRequest -UseBasicParsing -OutFile "$zip.part" `
            -Uri "https://github.com/actions/runner/releases/download/v$version/actions-runner-win-x64-$version.zip"
        if ((Get-FileHash "$zip.part" -Algorithm SHA256).Hash -ne (Get-Sha 'win-x64').ToUpper()) {
            Remove-Item "$zip.part"; throw "SHA-256 of the Windows runner v$version does not match"
        }
        Move-Item "$zip.part" $zip
    }
    $dir = Join-Path $root "$name-w$i"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Expand-Archive $zip -DestinationPath $dir -Force
    & "$dir\config.cmd" --unattended --url "https://github.com/$fullRepo" --token (New-Token $fullRepo 'registration') `
        --name "$env:COMPUTERNAME-$name-w$i" --work _work
    if ($LASTEXITCODE) { throw "config.cmd failed for $name-w$i" }
    "added Windows runner $name-w$i"
}

function Add-LinuxRunner([string]$fullRepo, [string]$name, [int]$i) {
    $sha = Get-Sha 'linux-x64'
    $url = "https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-x64-$version.tar.gz"
    $token = New-Token $fullRepo 'registration'
    Invoke-ForgeWsl $distro @"
set -euo pipefail
dir="`$HOME/actions-runner/$name-l$i"
tgz="`$HOME/actions-runner/_dist/actions-runner-linux-x64-$version.tar.gz"
mkdir -p "`$(dirname "`$tgz")" "`$dir"
if [ ! -f "`$tgz" ]; then
  curl -fsSL -o "`$tgz.part" "$url"
  echo "$sha  `$tgz.part" | sha256sum -c --quiet
  mv "`$tgz.part" "`$tgz"
fi
tar -xzf "`$tgz" -C "`$dir"
cd "`$dir"
./config.sh --unattended --url "https://github.com/$fullRepo" --token "$token" --name "`$(hostname)-$name-l$i" --work _work
"@
    "added Linux runner $name-l$i"
}

function Remove-Runner([string]$fullRepo, $remote, [string]$localName, [bool]$linux) {
    if ($remote -and $remote.busy) { Write-Warning "$($remote.name) is running a job; not removed (run again later)"; return }
    if ($linux) {
        Invoke-ForgeWsl $distro "pkill -f 'actions-runner/$localName/bin/Runner.Listener' || true; rm -rf ~/actions-runner/$localName"
    } else {
        $dir = Join-Path $root $localName
        Get-ForgeRunnerProcesses $root | Where-Object { $_.Path -like "*\$localName\*" } | Stop-Process -Force
        Start-Sleep -Seconds 2
        Remove-Item $dir -Recurse -Force
    }
    if ($remote) { gh api -X DELETE "repos/$fullRepo/actions/runners/$($remote.id)" | Out-Null }
    "removed runner $localName"
}

$repos = @($config.repos | Where-Object { -not $Repo -or $_.name -eq $Repo })
if (-not $repos) { throw "repo '$Repo' is not in forge.json" }
$linuxDirs = (wsl.exe -d $distro -e bash -c 'ls ~/actions-runner 2>/dev/null' 2>$null) -split "`n" | ForEach-Object { $_.Trim() }

foreach ($r in $repos) {
    $fullRepo = "$($config.owner)/$($r.name)"
    $remote = Get-RemoteRunners $fullRepo
    foreach ($os in 'windows', 'linux') {
        $want = [int]$r.$os
        $suffix = if ($os -eq 'windows') { 'w' } else { 'l' }
        $present = if ($os -eq 'windows') {
            @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^$([regex]::Escape($r.name))-w(\d+)$" -and (Test-Path "$($_.FullName)\.runner") } | ForEach-Object { [int]$Matches[1] })
        } else {
            @($linuxDirs | Where-Object { $_ -match "^$([regex]::Escape($r.name))-l(\d+)$" } | ForEach-Object { [int]$Matches[1] })
        }
        foreach ($i in 1..([Math]::Max($want, 1))) {
            if ($i -le $want -and $i -notin $present) {
                if ($os -eq 'windows') { Add-WindowsRunner $fullRepo $r.name $i } else { Add-LinuxRunner $fullRepo $r.name $i }
            }
        }
        foreach ($i in ($present | Where-Object { $_ -gt $want } | Sort-Object -Descending)) {
            $localName = "$($r.name)-$suffix$i"
            $match = $remote | Where-Object { $_.name -like "*-$localName" } | Select-Object -First 1
            Remove-Runner $fullRepo $match $localName ($os -eq 'linux')
        }
    }
}

if (Get-ScheduledTask -TaskName 'local-ci-forge-runners' -ErrorAction SilentlyContinue) {
    Start-ScheduledTask -TaskName 'local-ci-forge-runners'
    "Runners started by the 'local-ci-forge-runners' task."
} else {
    Write-Warning "Scheduled task 'local-ci-forge-runners' not installed yet: run install.ps1 (or windows\install-task.ps1 as admin)."
}
