# Installs on Windows what windows-latest ships and workflows commonly use without a setup-* step, when
# it is missing: Maven (official Apache build, SHA-512 checked) under %LOCALAPPDATA%\local-ci-forge\tools,
# added to the user PATH. No admin. Then checks the rest of the toolchain and fails loudly if something
# is missing. Idempotent.
. "$PSScriptRoot\common.ps1"
$config = Get-ForgeConfig
$mavenVersion = if ($config.mavenVersion) { $config.mavenVersion } else { '3.9.16' }

$tools = Join-Path $env:LOCALAPPDATA 'local-ci-forge\tools'
$mavenHome = Join-Path $tools "apache-maven-$mavenVersion"
if (-not (Get-Command mvn -ErrorAction SilentlyContinue) -and -not (Test-Path "$mavenHome\bin\mvn.cmd")) {
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    $base = "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/$mavenVersion/apache-maven-$mavenVersion-bin.zip"
    $zip = Join-Path ([IO.Path]::GetTempPath()) "apache-maven-$mavenVersion-bin.zip"
    Invoke-WebRequest -Uri $base -OutFile $zip -UseBasicParsing
    $expected = (Invoke-WebRequest -Uri "$base.sha512" -UseBasicParsing).Content.Trim().Split(' ')[0]
    if ((Get-FileHash $zip -Algorithm SHA512).Hash -ne $expected.ToUpper()) { throw "Maven SHA-512 does not match" }
    Expand-Archive $zip -DestinationPath $tools -Force
    Remove-Item $zip
}
if (Test-Path "$mavenHome\bin") {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains "$mavenHome\bin") {
        [Environment]::SetEnvironmentVariable('Path', "$userPath;$mavenHome\bin", 'User')
    }
    $env:Path = "$env:Path;$mavenHome\bin"
}

$missing = @()
foreach ($t in 'git', 'pwsh', 'gh', 'mvn', 'wsl') {
    $ok = [bool](Get-Command $t -ErrorAction SilentlyContinue)
    '{0,-6} {1}' -f $t, $(if ($ok) { 'ok' } else { 'MISSING' })
    if (-not $ok) { $missing += $t }
}
$gitBash = if ($config.gitBashBin) { $config.gitBashBin } else { 'C:\Program Files\Git\bin' }
$okBash = Test-Path "$gitBash\bash.exe"
'{0,-6} {1}' -f 'bash', $(if ($okBash) { "ok ($gitBash)" } else { "MISSING in $gitBash" })
if (-not $okBash) { $missing += 'git-bash' }
if ($missing) { throw "Missing tools: $($missing -join ', '). Install them and run again." }
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE) { throw 'gh is not logged in: run `gh auth login` first' }
