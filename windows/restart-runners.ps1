# Restarts every runner on this machine (needed after changing start-runners.ps1, wsl-start.sh or forge.json).
# No admin: leaves a request file and triggers the elevated task 'local-ci-forge-runners', which stops
# the runners and starts them again. Kills jobs in progress too: run it with the runners idle.
. "$PSScriptRoot\common.ps1"
$config = Get-ForgeConfig
New-Item -ItemType File -Force -Path (Join-Path $script:ForgeRoot 'restart.request') | Out-Null
Start-ScheduledTask -TaskName 'local-ci-forge-runners'
"Restart requested from task 'local-ci-forge-runners' (log: $(Join-Path $config.runnerRoot 'start-runners.log'))."
