# Starts every self-hosted runner on this machine. Called (elevated) by the logon task
# 'local-ci-forge-runners'. A runner that is already running is skipped, so it is safe to call again.
. "$PSScriptRoot\common.ps1"
$config = Get-ForgeConfig
$root = $config.runnerRoot
$distro = $config.wslDistro

# The runner root may be a junction to a Dev Drive VHDX (setup-devdrive.ps1). It must be mounted
# before anything touches the root; without it there is no Windows runner at all, so fail loudly.
if ($config.devDrive -and $config.devDrive.enabled -and (Test-Path $config.devDrive.vhdxPath)) {
    if (-not (Get-DiskImage -ImagePath $config.devDrive.vhdxPath).Attached) { Mount-DiskImage -ImagePath $config.devDrive.vhdxPath | Out-Null }
    if (-not (Test-Path "$root\")) { throw "Dev Drive $($config.devDrive.vhdxPath) is mounted but $root does not resolve" }
}
New-Item -ItemType Directory -Force -Path $root | Out-Null
Start-Transcript -Path (Join-Path $root 'start-runners.log') -Force | Out-Null

# Restart request (restart-runners.ps1, no admin needed): this task already runs elevated, so it is the
# one that stops the runners — elevated processes a normal user cannot kill.
$restartRequest = Join-Path $script:ForgeRoot 'restart.request'
if (Test-Path $restartRequest) {
    Remove-Item $restartRequest
    Get-ForgeRunnerProcesses $root | Stop-Process -Force
    wsl.exe -d $distro -e pkill -f 'actions-runner/.*/bin/Runner.Listener'
    Start-Sleep -Seconds 5
    'Restart requested: runners stopped.'
}

# windows-latest resolves `shell: bash` to Git Bash. In a normal session the first bash on PATH is
# C:\Windows\System32\bash.exe (the WSL launcher), which would break those steps.
$gitBin = if ($config.gitBashBin) { $config.gitBashBin } else { 'C:\Program Files\Git\bin' }
if (-not (Test-Path "$gitBin\bash.exe")) { throw "Git Bash not found in $gitBin (set gitBashBin in forge.json)" }
$env:Path = "$gitBin;" + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')

# Python PER RUNNER from python-build-standalone (https://github.com/astral-sh/python-build-standalone,
# the builds uv uses): full CPython (tkinter included) in a relocatable tar.gz, no installer, no registry.
# The python.org installer that actions/setup-python runs registers each version machine-wide (only one
# per version fits, and parallel jobs shared one site-packages); the NuGet package lacks tkinter. It goes
# into the runner's own tool cache (<runner>\_work\_tool\Python\<version>\x64 + x64.complete), where
# setup-python looks before downloading, so it never runs the installer.
# A failure here does not stop the runner (Write-Warning is not terminating): it is logged and the job
# that needs the version fails on its own.
$wanted = @{}
foreach ($r in $config.repos) { if ($r.python) { $wanted[$r.name] = @($r.python) } }
$dist = Join-Path $root '_dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$tar = "$env:SystemRoot\System32\tar.exe"
$script:pbsRelease = $null

function Get-PythonStandalone([string]$mm) {
    if (-not $script:pbsRelease) {
        $script:pbsRelease = Invoke-RestMethod 'https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest'
    }
    $pattern = '^cpython-' + [regex]::Escape($mm) + '\.\d+\+\d+-x86_64-pc-windows-msvc-install_only\.tar\.gz$'
    $asset = $script:pbsRelease.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { throw "no Windows x64 build of Python $mm in release $($script:pbsRelease.tag_name)" }
    $pkg = Join-Path $dist $asset.name
    if (-not (Test-Path $pkg)) {
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile "$pkg.part"
        $sha = (Get-FileHash "$pkg.part" -Algorithm SHA256).Hash.ToLower()
        if ("sha256:$sha" -ne $asset.digest) { Remove-Item "$pkg.part"; throw "SHA-256 of $($asset.name) does not match" }
        Move-Item "$pkg.part" $pkg
    }
    @{
        Version = $asset.name -replace '^cpython-([\d.]+)\+.*$', '$1'
        Package = $pkg
        Source  = "python-build-standalone $($script:pbsRelease.tag_name)"
    }
}

function Install-RunnerPython([string]$runnerDir, [string[]]$versions) {
    $pyRoot = "$runnerDir\_work\_tool\Python"
    $keep = @()
    foreach ($mm in $versions) {
        try {
            $py = Get-PythonStandalone $mm
            $verDir = "$pyRoot\$($py.Version)"
            $keep += $py.Version
            if ((Test-Path "$verDir\x64.complete") -and (Get-Content "$verDir\local-ci-forge.source" -ErrorAction SilentlyContinue) -eq $py.Source) { continue }
            Remove-Item $verDir, "$verDir.extract" -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path "$verDir.extract" | Out-Null
            & $tar -xzf $py.Package -C "$verDir.extract"
            if ($LASTEXITCODE) { throw "tar failed to extract $($py.Package)" }
            New-Item -ItemType Directory -Force -Path $verDir | Out-Null
            Move-Item "$verDir.extract\python" "$verDir\x64"
            Remove-Item "$verDir.extract" -Recurse -Force
            & "$verDir\x64\python.exe" -c 'import ssl, sqlite3, venv, pip, tkinter' 2>&1 | Out-Null
            if ($LASTEXITCODE) { throw 'the extracted Python could not import ssl/sqlite3/venv/pip/tkinter' }
            Set-Content -LiteralPath "$verDir\local-ci-forge.source" -Value $py.Source
            New-Item -ItemType File -Path "$verDir\x64.complete" | Out-Null
            "$(Split-Path $runnerDir -Leaf): Python $($py.Version) ($($py.Source)) ready"
        } catch { Write-Warning "$(Split-Path $runnerDir -Leaf): Python ${mm} failed: $_" }
    }
    # Any other version in the cache leaves: setup-python picks the highest compatible one it finds.
    if ($keep) {
        Get-ChildItem $pyRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $keep -and $_.Name -notlike '*.extract' } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force; "$(Split-Path $runnerDir -Leaf): Python $($_.Name) removed from the cache" }
    }
}

# Variables the runner reads from the .env in its directory:
#  - job hooks (per-job log line + clean TEMP before each job);
#  - MAVEN_ARGS (read by Maven since 3.9.0): runners share ~/.m2 and Maven 3.9 only synchronizes inside
#    one process by default; the resolver's file lock works across processes.
$runnerEnv = [ordered]@{
    ACTIONS_RUNNER_HOOK_JOB_STARTED   = Join-Path $script:ForgeRoot 'hooks\job-started.ps1'
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED = Join-Path $script:ForgeRoot 'hooks\job-completed.ps1'
    LOCAL_CI_FORGE_LOGS               = Join-Path $root '_logs'
    MAVEN_ARGS                        = '-Daether.syncContext.named.factory=file-lock -Daether.syncContext.named.nameMapper=file-gav'
}

$running = Get-ForgeRunnerProcesses $root | Where-Object ProcessName -eq 'Runner.Listener' | ForEach-Object { $_.Path }
$realRoot = (Get-Item $root).LinkTarget
foreach ($dir in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
    if (-not (Test-Path "$($dir.FullName)\.runner")) { continue }
    $envFile = Join-Path $dir.FullName '.env'
    $kept = @(Get-Content $envFile -ErrorAction SilentlyContinue | Where-Object { ($_ -split '=', 2)[0] -notin $runnerEnv.Keys })
    Set-Content -LiteralPath $envFile -Value ($kept + ($runnerEnv.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })) -Encoding ascii
    $paths = @($dir.FullName) + @($(if ($realRoot) { Join-Path $realRoot $dir.Name }))
    if ($running | Where-Object { $p = $_; $paths | Where-Object { $p -like "$_\*" } }) { "$($dir.Name): already running"; continue }
    # Python only on a STOPPED runner: swapping the interpreter of a busy runner would break its job.
    if ($dir.Name -match '^(.+)-w\d+$' -and $wanted[$Matches[1]]) { Install-RunnerPython $dir.FullName $wanted[$Matches[1]] }
    # TEMP per runner: on hosted runners every job gets a VM; here parallel runners (and you) would share
    # %TEMP% — tools like pytest clean "old" directories of another live session, and files created by an
    # elevated job become "Access denied" for your normal user.
    $env:TEMP = $env:TMP = Join-Path $dir.FullName '_tmp'
    New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
    Start-Process cmd.exe -ArgumentList '/c', 'run.cmd' -WorkingDirectory $dir.FullName -WindowStyle Hidden
    "$($dir.Name): started"
}

# Linux: a live wsl.exe keeps the distro up while the runners run (wsl-start.sh keeps only one alive).
$wslScript = (& wsl.exe -d $distro -e wslpath -a (Join-Path $script:ForgeRoot 'wsl\wsl-start.sh')).Trim()
Start-Process wsl.exe -ArgumentList '-d', $distro, '-e', 'bash', $wslScript -WindowStyle Hidden
"WSL ($distro): launched"
