# Puts the Windows runners on a Dev Drive (https://learn.microsoft.com/windows/dev-drive/): a ReFS volume
# meant for repositories, package caches and build output, with Microsoft Defender in performance mode.
# Creates a dynamic VHDX (only uses what it needs), formats it as a Dev Drive, copies the runner root
# into it and turns the runner root into a junction — no path in the scripts or runner configs changes.
# start-runners.ps1 mounts the VHDX at every logon. Asks for UAC on its own. Idempotent.
#   -RemoveBackup  deletes the <runnerRoot>.pre-devdrive copy left by the migration (after you validated)
param([switch]$RemoveBackup)
. "$PSScriptRoot\common.ps1"
$config = Get-ForgeConfig

if (-not (Test-ForgeAdmin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($RemoveBackup) { $argList += '-RemoveBackup' }
    $p = Start-Process pwsh -Verb RunAs -Wait -PassThru -ArgumentList $argList
    exit $p.ExitCode
}

$dd = $config.devDrive
if (-not $dd -or -not $dd.enabled) { throw 'devDrive.enabled is false in forge.json' }
$vhdx = $dd.vhdxPath
$root = $config.runnerRoot
$sizeGB = if ($dd.sizeGB) { [int]$dd.sizeGB } else { 150 }

$log = Join-Path ([IO.Path]::GetTempPath()) 'local-ci-forge-devdrive.log'
Start-Transcript -Path $log -Force | Out-Null
try {
    if (-not (Test-Path $vhdx)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $vhdx) | Out-Null
        New-VHD -Path $vhdx -SizeBytes ([int64]$sizeGB * 1GB) -Dynamic | Out-Null
        Mount-DiskImage -ImagePath $vhdx | Out-Null
        $diskNumber = (Get-DiskImage -ImagePath $vhdx).Number
        Initialize-Disk -Number $diskNumber -PartitionStyle GPT
        New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter |
            Format-Volume -DevDrive -FileSystem ReFS -NewFileSystemLabel 'actions-runner' -Confirm:$false -Force | Out-Null
        "Dev Drive created at $vhdx ($sizeGB GB, dynamic)."
    } elseif (-not (Get-DiskImage -ImagePath $vhdx).Attached) {
        Mount-DiskImage -ImagePath $vhdx | Out-Null
    }

    $letter = (Get-Partition -DiskNumber (Get-DiskImage -ImagePath $vhdx).Number | Where-Object DriveLetter).DriveLetter
    if (-not $letter) { throw "the Dev Drive at $vhdx is mounted without a drive letter" }
    $target = "${letter}:\actions-runner"

    $item = Get-Item $root -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'Junction') {
        "$root is already a junction to $($item.LinkTarget)."
    } else {
        if (Get-ForgeRunnerProcesses $root) { throw 'runners are running: stop them first (they must be idle to be moved)' }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        if ($item) {
            robocopy $root $target /E /COPYALL /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NP /NJH | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed (code $LASTEXITCODE)" }
            Rename-Item $root "$root.pre-devdrive"
            "Copied; the original stayed at $root.pre-devdrive (remove it with -RemoveBackup after validating)."
        }
        New-Item -ItemType Junction -Path $root -Target $target | Out-Null
        "$root -> $target"
    }

    if ($dd.defenderExclusion) {
        # Opt-in: Defender stops scanning what jobs download and run under the runner root.
        foreach ($path in @($root, (Get-Item $root).LinkTarget)) {
            if ((Get-MpPreference).ExclusionPath -notcontains $path) { Add-MpPreference -ExclusionPath $path; "Defender exclusion added: $path" }
        }
    }
    if ($RemoveBackup -and (Test-Path "$root.pre-devdrive")) {
        Remove-Item "$root.pre-devdrive" -Recurse -Force
        "Backup $root.pre-devdrive removed."
    }
    fsutil devdrv query "${letter}:"
} finally {
    Stop-Transcript | Out-Null
}
