[CmdletBinding()]
param(
    [switch] $Reset,
    [string] $QuarantinePeriod
)

. (Join-Path $PSScriptRoot "Common.ps1")
$config = Get-PocConfiguration
if ([string]::IsNullOrWhiteSpace($QuarantinePeriod)) {
    $QuarantinePeriod = [Environment]::GetEnvironmentVariable(
        "DEMO_QUARANTINE_PERIOD",
        "Process")
    if ([string]::IsNullOrWhiteSpace($QuarantinePeriod)) {
        $QuarantinePeriod = "45s"
    }
}

$quarantineSeconds = ConvertFrom-QuarantinePeriod -Period $QuarantinePeriod
if ($quarantineSeconds -lt 1 -or $quarantineSeconds -gt 300) {
    throw "The demo quarantine period must be between 1s and 5m; received '$QuarantinePeriod'."
}

if ($Reset) {
    & (Join-Path $PSScriptRoot "Reset-Demo.ps1")
}

Write-Host "Starting Nexus..."
Assert-NativeSuccess `
    -Command "docker" `
    -Arguments @("compose", "up", "-d", "nexus") `
    -WorkingDirectory $config.RepoRoot

& (Join-Path $PSScriptRoot "Initialize-Nexus.ps1")
& (Join-Path $PSScriptRoot "Build-Packages.ps1")
& (Join-Path $PSScriptRoot "Publish-Packages.ps1")
& (Join-Path $PSScriptRoot "Verify-Nexus.ps1") `
    -ExpectedQuarantineComponents 2 `
    -ExpectedApprovedComponents 0

$beforeRunId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
& (Join-Path $PSScriptRoot "Test-Consumers.ps1") `
    -Phase BeforePromotion `
    -RunId $beforeRunId

Write-Host "All approved-only exact-version lookups failed as expected."
Write-Host "Waiting $QuarantinePeriod so all six components become eligible..."
Start-Sleep -Seconds $quarantineSeconds

[Environment]::SetEnvironmentVariable("NEXUS_BASE_URL", $config.BaseUrl, "Process")
[Environment]::SetEnvironmentVariable("NEXUS_ADMIN_USER", $config.Username, "Process")
[Environment]::SetEnvironmentVariable("NEXUS_ADMIN_PASSWORD", $config.Password, "Process")
[Environment]::SetEnvironmentVariable("QUARANTINE_PERIOD", $QuarantinePeriod, "Process")

Assert-NativeSuccess `
    -Command "dotnet" `
    -Arguments @(
        "build",
        (Join-Path $config.RepoRoot "src\NexusQuarantine.Promoter\NexusQuarantine.Promoter.csproj"),
        "--nologo"
    ) `
    -WorkingDirectory $config.RepoRoot

Assert-NativeSuccess `
    -Command "dotnet" `
    -Arguments @(
        "run",
        "--project",
        (Join-Path $config.RepoRoot "src\NexusQuarantine.Promoter\NexusQuarantine.Promoter.csproj"),
        "--no-build",
        "--no-restore",
        "--",
        "--period", $QuarantinePeriod
    ) `
    -WorkingDirectory $config.RepoRoot

& (Join-Path $PSScriptRoot "Verify-Nexus.ps1") `
    -ExpectedQuarantineComponents 2 `
    -ExpectedApprovedComponents 2

$afterRunId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
& (Join-Path $PSScriptRoot "Test-Consumers.ps1") `
    -Phase AfterPromotion `
    -RunId $afterRunId

Write-Host @"
Quarantine lifecycle complete.
  before evidence: $($config.RepoRoot)\artifacts\consumer-runs\$beforeRunId-BeforePromotion\evidence
  after evidence:  $($config.RepoRoot)\artifacts\consumer-runs\$afterRunId-AfterPromotion\evidence
"@
