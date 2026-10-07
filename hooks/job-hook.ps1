# Job hook of the Windows runners (ACTIONS_RUNNER_HOOK_JOB_STARTED/COMPLETED, set in each runner's .env by
# start-runners.ps1). Appends one JSON line per event to $env:LOCAL_CI_FORGE_LOGS\<runner>.jsonl and, when
# the job starts, empties the runner's TEMP (a runner takes one job at a time, so its TEMP is this job's).
# It must NEVER fail: a start hook that exits non-zero fails the job
# (https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/run-scripts).
param([Parameter(Mandatory)][ValidateSet('started', 'completed')][string]$Event)
try {
    $logDir = $env:LOCAL_CI_FORGE_LOGS
    if (-not $logDir) { throw 'LOCAL_CI_FORGE_LOGS is not set in the runner .env (run restart-runners.ps1)' }
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $line = [ordered]@{
        event    = $Event
        ts       = (Get-Date).ToUniversalTime().ToString('o')
        runner   = $env:RUNNER_NAME
        repo     = $env:GITHUB_REPOSITORY
        workflow = $env:GITHUB_WORKFLOW
        job      = $env:GITHUB_JOB
        run_id   = $env:GITHUB_RUN_ID
        attempt  = $env:GITHUB_RUN_ATTEMPT
        ref      = $env:GITHUB_REF_NAME
        trigger  = $env:GITHUB_EVENT_NAME
    } | ConvertTo-Json -Compress
    Add-Content -LiteralPath (Join-Path $logDir "$env:RUNNER_NAME.jsonl") -Value $line -Encoding utf8
    # Only a per-runner TEMP set by start-runners.ps1 (<runner>\_tmp) is emptied, never the user's TEMP.
    if ($Event -eq 'started' -and $env:TEMP -like '*\_tmp' -and (Test-Path (Join-Path (Split-Path $env:TEMP -Parent) '.runner'))) {
        Get-ChildItem -LiteralPath $env:TEMP -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "local-ci-forge job-hook ($Event): $_"
}
exit 0
