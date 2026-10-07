# Shared helpers for the local-ci-forge PowerShell scripts. Dot-source it: . "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Stop'

$script:ForgeRoot = Split-Path $PSScriptRoot -Parent

function Get-ForgeConfig {
    $path = Join-Path $script:ForgeRoot 'forge.json'
    if (-not (Test-Path $path)) {
        throw "forge.json not found at $path. Copy config\forge.example.json to forge.json and edit it."
    }
    $config = Get-Content $path -Raw | ConvertFrom-Json
    foreach ($key in 'owner', 'runnerRoot', 'wslDistro', 'repos') {
        if (-not $config.$key) { throw "forge.json: '$key' is required" }
    }
    if ($config.owner -eq 'your-github-user') { throw "forge.json: set 'owner' to your GitHub user or organization" }
    return $config
}

function Test-ForgeAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# With the runner root on a Dev Drive behind a junction, Windows reports process paths through the real
# target, not the junction. Every match against runner processes has to accept both.
function Get-ForgeRunnerProcesses([string]$RunnerRoot) {
    $realRoot = (Get-Item $RunnerRoot -ErrorAction SilentlyContinue).LinkTarget
    Get-Process Runner.Listener, Runner.Worker -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -like "$RunnerRoot\*" -or ($realRoot -and $_.Path -like "$realRoot\*")
    }
}

function Invoke-ForgeWsl([string]$Distro, [string]$Script) {
    # Passed as base64 in the argument, never through stdin: PowerShell writes CRLF to a native process'
    # stdin and the CR sticks to the last argument of every line.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Script -replace "`r", '')))
    wsl.exe -d $Distro -e bash -c "echo $b64 | base64 -d | bash"
    if ($LASTEXITCODE) { throw "WSL script failed (exit $LASTEXITCODE)" }
}
