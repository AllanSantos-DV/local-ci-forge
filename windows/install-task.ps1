#Requires -RunAsAdministrator
# Creates (or recreates) the logon task 'local-ci-forge-runners', which starts every runner on this
# machine ELEVATED (RunLevel Highest, no UAC prompt on each logon). Admin is only needed to create it.
# Why elevated: actions/setup-python on Windows needs admin to install Python
# (https://github.com/actions/setup-python/blob/main/docs/advanced-usage.md), and so does `choco install`.
. "$PSScriptRoot\common.ps1"
$config = Get-ForgeConfig

$user = (Get-CimInstance Win32_ComputerSystem).UserName   # the logged-on user, not the elevating account
$starter = Join-Path $PSScriptRoot 'start-runners.ps1'
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$starter`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'local-ci-forge-runners' -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Force -Description 'local-ci-forge: starts the self-hosted GitHub Actions runners at logon (elevated)' | Out-Null
"Task 'local-ci-forge-runners' registered for $user (elevated)."

# Replace any Windows runner running unelevated with the elevated ones.
Get-ForgeRunnerProcesses $config.runnerRoot | Stop-Process -Force
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName 'local-ci-forge-runners'
'Runners (re)started elevated.'
