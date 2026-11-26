[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "Common.ps1")
$config = Get-PocConfiguration

& docker compose down --volumes --remove-orphans
if ($LASTEXITCODE -ne 0) {
    throw "docker compose down failed with exit code $LASTEXITCODE."
}

$artifacts = Join-Path $config.RepoRoot "artifacts"
if (Test-Path -LiteralPath $artifacts) {
    Remove-Item -LiteralPath $artifacts -Recurse -Force
}

Write-Host "Removed the dedicated Nexus volume and generated demo artifacts."
