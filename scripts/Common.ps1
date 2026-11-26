Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-PocEnvironment {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $envPath = Join-Path $repoRoot ".env"
    if (-not (Test-Path -LiteralPath $envPath)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $envPath) {
        if ($line -match "^\s*(#|$)") {
            continue
        }

        $separator = $line.IndexOf("=")
        if ($separator -lt 1) {
            throw "Invalid .env line '$line'. Expected NAME=VALUE."
        }

        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ([string]::IsNullOrWhiteSpace(
                [Environment]::GetEnvironmentVariable($name, "Process"))) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Get-PocConfiguration {
    Import-PocEnvironment

    $baseUrl = [Environment]::GetEnvironmentVariable("NEXUS_BASE_URL", "Process")
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        $baseUrl = "http://localhost:8081"
    }

    $parsedUri = $null
    if (-not [Uri]::TryCreate($baseUrl, [UriKind]::Absolute, [ref] $parsedUri) -or
        $parsedUri.Scheme -notin @("http", "https")) {
        throw "NEXUS_BASE_URL '$baseUrl' is not an absolute HTTP(S) URL."
    }

    $password = [Environment]::GetEnvironmentVariable("NEXUS_ADMIN_PASSWORD", "Process")
    if ([string]::IsNullOrWhiteSpace($password)) {
        $password = "local-demo-only-password"
    }

    return [pscustomobject]@{
        RepoRoot = Split-Path -Parent $PSScriptRoot
        BaseUrl = "$($parsedUri.Scheme)://$($parsedUri.Authority)".TrimEnd("/")
        Username = if ([string]::IsNullOrWhiteSpace(
                [Environment]::GetEnvironmentVariable("NEXUS_ADMIN_USER", "Process"))) {
            "admin"
        }
        else {
            [Environment]::GetEnvironmentVariable("NEXUS_ADMIN_USER", "Process")
        }
        Password = $password
    }
}

function New-NexusHeaders {
    param(
        [string] $Username,
        [string] $Password
    )

    $token = [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
    return @{ Authorization = "Basic $token" }
}

function ConvertFrom-QuarantinePeriod {
    param([Parameter(Mandatory)][string] $Period)

    if ($Period -notmatch "^\s*(?<Amount>\d+)(?<Unit>[smhdSMHD])\s*$") {
        throw "Invalid quarantine period '$Period'. Use an integer followed by s, m, h, or d."
    }

    [long] $amount = [long] $Matches.Amount
    [long] $multiplier = switch ($Matches.Unit.ToLowerInvariant()) {
        "s" { 1 }
        "m" { 60 }
        "h" { 3600 }
        "d" { 86400 }
    }

    $seconds = $amount * $multiplier
    if ($seconds -gt [int]::MaxValue) {
        throw "Quarantine period '$Period' is too large for the demo runner."
    }

    return [int] $seconds
}

function Get-AuthenticatedRepositoryUrl {
    param(
        [Parameter(Mandatory)][pscustomobject] $Configuration,
        [Parameter(Mandatory)][string] $Path
    )

    $builder = [UriBuilder]::new(
        "$($Configuration.BaseUrl)/$($Path.TrimStart('/'))")
    $builder.UserName = $Configuration.Username
    $builder.Password = $Configuration.Password
    return $builder.Uri.AbsoluteUri
}

function Assert-NativeSuccess {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $WorkingDirectory = $PWD.Path
    )

    Push-Location $WorkingDirectory
    try {
        & $Command @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        throw "'$Command' failed with exit code $exitCode."
    }
}
