# Registers the task 'local-ci-forge-alerts': runs tools\alert.py every 10 minutes while you are logged on
# (Windows notification + <runnerRoot>\_logs\alerts.jsonl). No admin. Idempotent.
. "$PSScriptRoot\common.ps1"
$null = Get-ForgeConfig

$python = (Get-Command python.exe -ErrorAction Stop).Source
$pythonw = Join-Path (Split-Path $python) 'pythonw.exe'   # no console window
if (-not (Test-Path $pythonw)) { throw "pythonw.exe not found next to $python" }
$alert = Join-Path $script:ForgeRoot 'tools\alert.py'

$action = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$alert`"" -WorkingDirectory (Split-Path $alert)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'local-ci-forge-alerts' -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Force -Description 'local-ci-forge: runner alerts (offline, queue, failure on default branch)' | Out-Null
"Task 'local-ci-forge-alerts' registered: $pythonw $alert every 10 min."
