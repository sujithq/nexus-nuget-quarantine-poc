[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "Common.ps1")
$config = Get-PocConfiguration
$headers = New-NexusHeaders -Username $config.Username -Password $config.Password
$packagesRoot = Join-Path $config.RepoRoot "artifacts\packages"

if (-not (Test-Path -LiteralPath $packagesRoot)) {
    throw "No packages found. Run scripts/Build-Packages.ps1 first."
}

$uploads = @(
    @{
        Format = "pypi"
        Repository = "pypi-quarantine"
        Field = "pypi.asset"
        Pattern = "*.whl"
    },
    @{
        Format = "npm"
        Repository = "npm-quarantine"
        Field = "npm.asset"
        Pattern = "*.tgz"
    },
    @{
        Format = "nuget"
        Repository = "nuget-quarantine"
        Field = "nuget.asset"
        Pattern = "*.nupkg"
    }
)

foreach ($upload in $uploads) {
    $files = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $packagesRoot $upload.Format) `
            -File `
            -Filter $upload.Pattern
    )
    if ($files.Count -ne 2) {
        throw "Expected two $($upload.Format) packages, found $($files.Count)."
    }

    foreach ($file in $files) {
        $form = @{ $upload.Field = Get-Item -LiteralPath $file.FullName }
        Invoke-WebRequest `
            -Uri "$($config.BaseUrl)/service/rest/v1/components?repository=$($upload.Repository)" `
            -Headers $headers `
            -Method Post `
            -Form $form | Out-Null
        Write-Host "Published $($file.Name) to $($upload.Repository)."
    }
}

$deadline = [DateTime]::UtcNow.AddSeconds(60)
do {
    $counts = @{}
    foreach ($upload in $uploads) {
        $page = Invoke-RestMethod `
            -Uri "$($config.BaseUrl)/service/rest/v1/search?repository=$($upload.Repository)&format=$($upload.Format)" `
            -Headers $headers `
            -Method Get
        $counts[$upload.Format] = @($page.items | Write-Output).Count
    }

    if (@($counts.Values | Where-Object { $_ -eq 2 }).Count -eq 3) {
        break
    }

    if ([DateTime]::UtcNow -ge $deadline) {
        throw "Nexus did not index two quarantine components per format: $($counts | ConvertTo-Json -Compress)."
    }

    Start-Sleep -Seconds 2
} while ($true)

Write-Host "Quarantine component counts: pypi=2, npm=2, nuget=2."
