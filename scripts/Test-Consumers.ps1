[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("BeforePromotion", "AfterPromotion")]
    [string] $Phase,

    [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9._-]*$")]
    [string] $RunId = (Get-Date -Format "yyyyMMdd-HHmmss-fff")
)

. (Join-Path $PSScriptRoot "Common.ps1")
$config = Get-PocConfiguration
$runRoot = Join-Path $config.RepoRoot "artifacts\consumer-runs\$RunId-$Phase"
$evidenceRoot = Join-Path $runRoot "evidence"
if (Test-Path -LiteralPath $runRoot) {
    throw "Consumer run '$runRoot' already exists. Choose a new -RunId to preserve cache isolation."
}
New-Item -ItemType Directory -Path $runRoot, $evidenceRoot -Force | Out-Null

function Invoke-CapturedCommand {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $LogPath,
        [Parameter(Mandatory)][string] $WorkingDirectory
    )

    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments 2>&1 |
            Tee-Object -FilePath $LogPath |
            Out-Host
        return [int] $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

function Assert-EvidenceContains {
    param(
        [Parameter(Mandatory)][string] $LogPath,
        [Parameter(Mandatory)][string] $LiteralText,
        [Parameter(Mandatory)][string] $Description
    )

    $content = Get-Content -LiteralPath $LogPath -Raw
    if (-not $content.Contains($LiteralText, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The $Description proof did not report package absence: '$LiteralText'."
    }
}

Write-Host "Running exact-version consumer phase '$Phase' in '$runRoot'."

$pypiDirectory = Join-Path $runRoot "pypi"
$pypiTarget = Join-Path $pypiDirectory "target"
$pypiSource = Join-Path $config.RepoRoot "consumers\pypi\requirements.txt"
New-Item -ItemType Directory -Path $pypiDirectory -Force | Out-Null
Copy-Item -LiteralPath $pypiSource -Destination $pypiDirectory
$pypiUrl = Get-AuthenticatedRepositoryUrl `
    -Configuration $config `
    -Path "/repository/pypi-approved/simple/"
$pipExitCode = Invoke-CapturedCommand `
    -FilePath "python" `
    -Arguments @(
        "-m", "pip",
        "--isolated",
        "install",
        "--disable-pip-version-check",
        "--no-cache-dir",
        "--ignore-installed",
        "--no-deps",
        "--index-url", $pypiUrl,
        "--target", $pypiTarget,
        "--requirement", "requirements.txt"
    ) `
    -LogPath (Join-Path $evidenceRoot "pypi.log") `
    -WorkingDirectory $pypiDirectory

$npmDirectory = Join-Path $runRoot "npm"
$npmCache = Join-Path $npmDirectory "cache"
New-Item -ItemType Directory -Path $npmDirectory -Force | Out-Null
Copy-Item `
    -LiteralPath (Join-Path $config.RepoRoot "consumers\npm\package.json") `
    -Destination $npmDirectory
$npmUrl = "$($config.BaseUrl)/repository/npm-approved/"
$npmUri = [Uri]::new($npmUrl)
$npmToken = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes("$($config.Username):$($config.Password)"))
$npmCredentialPath = "//$($npmUri.Authority)$($npmUri.AbsolutePath.TrimEnd('/'))/"
$npmConfig = Join-Path $npmDirectory ".npmrc"
@(
    "registry=$npmUrl",
    "${npmCredentialPath}:_auth=$npmToken",
    "audit=false",
    "fund=false",
    "update-notifier=false"
) | Set-Content -LiteralPath $npmConfig -Encoding utf8

$previousNpmUserConfig = [Environment]::GetEnvironmentVariable(
    "NPM_CONFIG_USERCONFIG",
    "Process")
$previousNpmCache = [Environment]::GetEnvironmentVariable("NPM_CONFIG_CACHE", "Process")
[Environment]::SetEnvironmentVariable("NPM_CONFIG_USERCONFIG", $npmConfig, "Process")
[Environment]::SetEnvironmentVariable("NPM_CONFIG_CACHE", $npmCache, "Process")
try {
    $npmExitCode = Invoke-CapturedCommand `
        -FilePath "npm" `
        -Arguments @(
            "install",
            "--userconfig", $npmConfig,
            "--registry", $npmUrl,
            "--cache", $npmCache,
            "--package-lock=false",
            "--ignore-scripts",
            "--no-audit",
            "--no-fund"
        ) `
        -LogPath (Join-Path $evidenceRoot "npm.log") `
        -WorkingDirectory $npmDirectory
}
finally {
    if ($null -eq $previousNpmUserConfig) {
        Remove-Item Env:NPM_CONFIG_USERCONFIG -ErrorAction SilentlyContinue
    }
    else {
        [Environment]::SetEnvironmentVariable(
            "NPM_CONFIG_USERCONFIG",
            $previousNpmUserConfig,
            "Process")
    }
    if ($null -eq $previousNpmCache) {
        Remove-Item Env:NPM_CONFIG_CACHE -ErrorAction SilentlyContinue
    }
    else {
        [Environment]::SetEnvironmentVariable(
            "NPM_CONFIG_CACHE",
            $previousNpmCache,
            "Process")
    }
}

$nugetDirectory = Join-Path $runRoot "nuget"
$nugetPackages = Join-Path $nugetDirectory "global-packages"
$nugetHttpCache = Join-Path $nugetDirectory "http-cache"
$nugetHome = Join-Path $nugetDirectory "dotnet-home"
New-Item -ItemType Directory -Path $nugetDirectory -Force | Out-Null
Copy-Item `
    -LiteralPath (Join-Path $config.RepoRoot "consumers\nuget\ApprovedOnly\ApprovedOnly.csproj") `
    -Destination $nugetDirectory
$escapedUsername = [Security.SecurityElement]::Escape($config.Username)
$escapedPassword = [Security.SecurityElement]::Escape($config.Password)
$nugetSource = "$($config.BaseUrl)/repository/nuget-approved/index.json"
$nugetConfig = Join-Path $nugetDirectory "NuGet.Config"
@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="approved-only" value="$nugetSource" protocolVersion="3" allowInsecureConnections="true" />
  </packageSources>
  <packageSourceCredentials>
    <approved-only>
      <add key="Username" value="$escapedUsername" />
      <add key="ClearTextPassword" value="$escapedPassword" />
    </approved-only>
  </packageSourceCredentials>
</configuration>
"@ | Set-Content -LiteralPath $nugetConfig -Encoding utf8

$previousNugetPackages = [Environment]::GetEnvironmentVariable("NUGET_PACKAGES", "Process")
$previousNugetHttpCache = [Environment]::GetEnvironmentVariable(
    "NUGET_HTTP_CACHE_PATH",
    "Process")
$previousDotnetHome = [Environment]::GetEnvironmentVariable("DOTNET_CLI_HOME", "Process")
[Environment]::SetEnvironmentVariable("NUGET_PACKAGES", $nugetPackages, "Process")
[Environment]::SetEnvironmentVariable("NUGET_HTTP_CACHE_PATH", $nugetHttpCache, "Process")
[Environment]::SetEnvironmentVariable("DOTNET_CLI_HOME", $nugetHome, "Process")
try {
    $nugetExitCode = Invoke-CapturedCommand `
        -FilePath "dotnet" `
        -Arguments @(
            "restore",
            "ApprovedOnly.csproj",
            "--configfile", $nugetConfig,
            "--packages", $nugetPackages,
            "--force",
            "--no-cache",
            "--nologo"
        ) `
        -LogPath (Join-Path $evidenceRoot "nuget.log") `
        -WorkingDirectory $nugetDirectory
}
finally {
    if ($null -eq $previousNugetPackages) {
        Remove-Item Env:NUGET_PACKAGES -ErrorAction SilentlyContinue
    }
    else {
        [Environment]::SetEnvironmentVariable(
            "NUGET_PACKAGES",
            $previousNugetPackages,
            "Process")
    }
    if ($null -eq $previousNugetHttpCache) {
        Remove-Item Env:NUGET_HTTP_CACHE_PATH -ErrorAction SilentlyContinue
    }
    else {
        [Environment]::SetEnvironmentVariable(
            "NUGET_HTTP_CACHE_PATH",
            $previousNugetHttpCache,
            "Process")
    }
    if ($null -eq $previousDotnetHome) {
        Remove-Item Env:DOTNET_CLI_HOME -ErrorAction SilentlyContinue
    }
    else {
        [Environment]::SetEnvironmentVariable(
            "DOTNET_CLI_HOME",
            $previousDotnetHome,
            "Process")
    }
}

$exitCodes = [ordered]@{
    pypi = $pipExitCode
    npm = $npmExitCode
    nuget = $nugetExitCode
}
$expectedSuccess = $Phase -eq "AfterPromotion"
$failedExpectations = @()
foreach ($ecosystem in $exitCodes.Keys) {
    if (($expectedSuccess -and $exitCodes[$ecosystem] -ne 0) -or
        (-not $expectedSuccess -and $exitCodes[$ecosystem] -eq 0)) {
        $failedExpectations += $ecosystem
    }
}

if ($failedExpectations.Count -ne 0) {
    throw "Consumer phase '$Phase' failed for: $($failedExpectations -join ', ')."
}

if (-not $expectedSuccess) {
    Assert-EvidenceContains `
        -LogPath (Join-Path $evidenceRoot "pypi.log") `
        -LiteralText "No matching distribution found for quarantine-pypi-alpha==1.0.0" `
        -Description "pip"
    Assert-EvidenceContains `
        -LogPath (Join-Path $evidenceRoot "npm.log") `
        -LiteralText "404 Not Found" `
        -Description "npm HTTP"
    Assert-EvidenceContains `
        -LogPath (Join-Path $evidenceRoot "npm.log") `
        -LiteralText "nexus-quarantine-poc-alpha" `
        -Description "npm package"
    Assert-EvidenceContains `
        -LogPath (Join-Path $evidenceRoot "nuget.log") `
        -LiteralText "Unable to find package NexusQuarantinePoc.Alpha" `
        -Description "NuGet Alpha"
    Assert-EvidenceContains `
        -LogPath (Join-Path $evidenceRoot "nuget.log") `
        -LiteralText "Unable to find package NexusQuarantinePoc.Beta" `
        -Description "NuGet Beta"
}

if ($expectedSuccess) {
    $pypiInstalled = @(
        Get-ChildItem -LiteralPath $pypiTarget -Directory -Filter "*.dist-info" |
            Where-Object { $_.Name -like "quarantine_pypi_*" }
    ).Count
    $npmInstalled = @(
        Get-ChildItem -LiteralPath (Join-Path $npmDirectory "node_modules") -Directory |
            Where-Object { $_.Name -like "nexus-quarantine-poc-*" }
    ).Count
    $nugetInstalled = @(
        Get-ChildItem -LiteralPath $nugetPackages -Directory |
            Where-Object { $_.Name -like "nexusquarantinepoc.*" }
    ).Count

    if ($pypiInstalled -ne 2 -or $npmInstalled -ne 2 -or $nugetInstalled -ne 2) {
        throw @"
Expected two installed packages per ecosystem after promotion; found:
  pypi=$pypiInstalled npm=$npmInstalled nuget=$nugetInstalled
"@
    }
}

$summary = [ordered]@{
    phase = $Phase
    expectation = if ($expectedSuccess) { "success" } else { "failure" }
    observedExitCodes = $exitCodes
    approvedOnlySources = [ordered]@{
        pypi = "$($config.BaseUrl)/repository/pypi-approved/simple/"
        npm = $npmUrl
        nuget = $nugetSource
    }
    isolatedCaches = [ordered]@{
        pypi = "pip --isolated --no-cache-dir --ignore-installed --target $pypiTarget"
        npm = $npmCache
        nugetPackages = $nugetPackages
        nugetHttpCache = $nugetHttpCache
    }
}
$summary |
    ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $evidenceRoot "summary.json") -Encoding utf8

Write-Host @"
Consumer proof:
  pypi exit=$pipExitCode
  npm exit=$npmExitCode
  nuget exit=$nugetExitCode
  evidence=$evidenceRoot
"@
