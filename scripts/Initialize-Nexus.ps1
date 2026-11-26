[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "Common.ps1")
$config = Get-PocConfiguration
$configuredHeaders = New-NexusHeaders -Username $config.Username -Password $config.Password

Write-Host "Waiting for Nexus at $($config.BaseUrl)..."
$deadline = [DateTime]::UtcNow.AddMinutes(4)
do {
    try {
        $response = Invoke-WebRequest `
            -Uri "$($config.BaseUrl)/service/rest/v1/status" `
            -Method Get `
            -SkipHttpErrorCheck
        if ($response.StatusCode -lt 500) {
            break
        }
    }
    catch {
        # Nexus is still starting; the remaining retries provide the useful failure.
    }

    if ([DateTime]::UtcNow -ge $deadline) {
        throw "Nexus did not become reachable at $($config.BaseUrl) within four minutes."
    }

    Start-Sleep -Seconds 5
} while ($true)

function Test-NexusAdmin {
    try {
        Invoke-RestMethod `
            -Uri "$($config.BaseUrl)/service/rest/v1/security/users?userId=admin" `
            -Headers $configuredHeaders `
            -Method Get | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

if (-not (Test-NexusAdmin)) {
    $initialPassword = (& docker compose exec -T nexus cat /nexus-data/admin.password 2>$null |
        Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($initialPassword)) {
        throw @"
The configured Nexus password is not valid and no initial admin password is available.
If this is a previous local run, set NEXUS_ADMIN_PASSWORD to its password or reset:
  docker compose down --volumes
"@
    }

    $initialHeaders = New-NexusHeaders -Username $config.Username -Password $initialPassword
    Invoke-RestMethod `
        -Uri "$($config.BaseUrl)/service/rest/v1/security/users/admin/change-password" `
        -Headers $initialHeaders `
        -Method Put `
        -ContentType "text/plain" `
        -Body $config.Password | Out-Null

    if (-not (Test-NexusAdmin)) {
        throw "Nexus accepted the password change but the configured admin credentials still failed."
    }
}

$expectedRepositories = @(
    [pscustomobject]@{ Name = "pypi-quarantine"; Format = "pypi" },
    [pscustomobject]@{ Name = "pypi-approved"; Format = "pypi" },
    [pscustomobject]@{ Name = "npm-quarantine"; Format = "npm" },
    [pscustomobject]@{ Name = "npm-approved"; Format = "npm" },
    [pscustomobject]@{ Name = "nuget-quarantine"; Format = "nuget" },
    [pscustomobject]@{ Name = "nuget-approved"; Format = "nuget" }
)
$expectedByName = @{}
foreach ($expected in $expectedRepositories) {
    $expectedByName[$expected.Name] = $expected
}

$repositories = @(
    Invoke-RestMethod `
        -Uri "$($config.BaseUrl)/service/rest/v1/repositories" `
        -Headers $configuredHeaders `
        -Method Get | Write-Output
)

$repositoriesToDelete = @(
    $repositories |
        Where-Object {
            -not $expectedByName.ContainsKey($_.name) -or
            $_.type -ne "hosted" -or
            $_.format -ne $expectedByName[$_.name].Format
        } |
        Sort-Object @{
            Expression = {
                switch ($_.type) {
                    "group" { 0 }
                    "proxy" { 1 }
                    default { 2 }
                }
            }
        }
)

foreach ($repository in $repositoriesToDelete) {
    Write-Host "Removing non-POC repository '$($repository.name)' ($($repository.format)/$($repository.type))."
    Invoke-RestMethod `
        -Uri "$($config.BaseUrl)/service/rest/v1/repositories/$([Uri]::EscapeDataString($repository.name))" `
        -Headers $configuredHeaders `
        -Method Delete | Out-Null
}

$repositories = @(
    Invoke-RestMethod `
        -Uri "$($config.BaseUrl)/service/rest/v1/repositories" `
        -Headers $configuredHeaders `
        -Method Get | Write-Output
)
$presentNames = @($repositories | ForEach-Object { $_.name })

foreach ($expected in $expectedRepositories) {
    if ($presentNames -contains $expected.Name) {
        continue
    }

    $request = @{
        name = $expected.Name
        online = $true
        storage = @{
            blobStoreName = "default"
            strictContentTypeValidation = $true
            writePolicy = "ALLOW"
        }
        cleanup = @{
            policyNames = @()
        }
        component = @{
            proprietaryComponents = $true
        }
    }
    if ($expected.Format -eq "nuget") {
        $request.nuget = @{ queryCacheItemMaxAge = 60 }
    }

    Write-Host "Creating hosted repository '$($expected.Name)'."
    Invoke-RestMethod `
        -Uri "$($config.BaseUrl)/service/rest/v1/repositories/$($expected.Format)/hosted" `
        -Headers $configuredHeaders `
        -Method Post `
        -ContentType "application/json" `
        -Body ($request | ConvertTo-Json -Depth 6 -Compress) | Out-Null
}

$repositories = @(
    Invoke-RestMethod `
        -Uri "$($config.BaseUrl)/service/rest/v1/repositories" `
        -Headers $configuredHeaders `
        -Method Get | Write-Output
)

if ($repositories.Count -ne 6) {
    throw "Expected exactly six repositories, found $($repositories.Count)."
}

foreach ($repository in $repositories) {
    if ($repository.type -ne "hosted" -or -not $expectedByName.ContainsKey($repository.name) -or
        $repository.format -ne $expectedByName[$repository.name].Format) {
        throw "Unexpected Nexus repository '$($repository.name)' ($($repository.format)/$($repository.type))."
    }
}

Write-Host "Nexus hosted-only topology:"
$repositories |
    Sort-Object name |
    Select-Object name, format, type |
    Format-Table -AutoSize
