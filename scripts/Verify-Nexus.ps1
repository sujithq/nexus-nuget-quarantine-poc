[CmdletBinding()]
param(
    [int] $ExpectedApprovedComponents = 2,
    [int] $ExpectedQuarantineComponents = 2
)

. (Join-Path $PSScriptRoot "Common.ps1")
$config = Get-PocConfiguration
$headers = New-NexusHeaders -Username $config.Username -Password $config.Password

$expected = @(
    [pscustomobject]@{ Name = "pypi-quarantine"; Format = "pypi" },
    [pscustomobject]@{ Name = "pypi-approved"; Format = "pypi" },
    [pscustomobject]@{ Name = "npm-quarantine"; Format = "npm" },
    [pscustomobject]@{ Name = "npm-approved"; Format = "npm" },
    [pscustomobject]@{ Name = "nuget-quarantine"; Format = "nuget" },
    [pscustomobject]@{ Name = "nuget-approved"; Format = "nuget" }
)
$expectedByName = @{}
foreach ($repository in $expected) {
    $expectedByName[$repository.Name] = $repository.Format
}

$repositories = @(
    Invoke-RestMethod `
        -Uri "$($config.BaseUrl)/service/rest/v1/repositories" `
        -Headers $headers `
        -Method Get | Write-Output
)
if ($repositories.Count -ne 6) {
    throw "Expected exactly six Nexus repositories, found $($repositories.Count)."
}

foreach ($repository in $repositories) {
    if (-not $expectedByName.ContainsKey($repository.name) -or
        $repository.type -ne "hosted" -or
        $repository.format -ne $expectedByName[$repository.name]) {
        throw "Repository '$($repository.name)' is not an expected hosted-only repository."
    }
}

$deadline = [DateTime]::UtcNow.AddSeconds(60)
do {
    $mismatches = @()
    $counts = @{}
    foreach ($repository in $expected) {
        $url = "{0}/service/rest/v1/search?repository={1}&format={2}" -f `
            $config.BaseUrl,
            [Uri]::EscapeDataString($repository.Name),
            [Uri]::EscapeDataString($repository.Format)
        $page = Invoke-RestMethod `
            -Uri $url `
            -Headers $headers `
            -Method Get
        $count = @($page.items | Write-Output).Count
        $expectedCount = if ($repository.Name.EndsWith("-approved")) {
            $ExpectedApprovedComponents
        }
        else {
            $ExpectedQuarantineComponents
        }
        $counts[$repository.Name] = $count

        if ($count -gt $expectedCount) {
            throw "Repository '$($repository.Name)' has $count components; expected $expectedCount."
        }

        if ($count -lt $expectedCount) {
            $mismatches += "$($repository.Name)=$count/$expectedCount"
        }
    }

    if ($mismatches.Count -eq 0) {
        break
    }

    if ([DateTime]::UtcNow -ge $deadline) {
        throw "Timed out waiting for Nexus search indexing: $($mismatches -join ', ')."
    }

    Write-Host "Waiting for Nexus search indexing: $($mismatches -join ', ')"
    Start-Sleep -Seconds 2
} while ($true)

foreach ($repository in $expected) {
    Write-Host "$($repository.Name): $($counts[$repository.Name]) component(s), hosted $($repository.Format)"
}

Write-Host "Verified: exactly six hosted repositories and no proxy/group repositories."
