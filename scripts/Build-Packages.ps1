[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "Common.ps1")
$config = Get-PocConfiguration
$packagesRoot = Join-Path $config.RepoRoot "artifacts\packages"
if (Test-Path -LiteralPath $packagesRoot) {
    Remove-Item -LiteralPath $packagesRoot -Recurse -Force
}

$pypiOutput = Join-Path $packagesRoot "pypi"
$npmOutput = Join-Path $packagesRoot "npm"
$nugetOutput = Join-Path $packagesRoot "nuget"
New-Item -ItemType Directory -Path $pypiOutput, $npmOutput, $nugetOutput -Force | Out-Null

Assert-NativeSuccess `
    -Command "python" `
    -Arguments @(
        (Join-Path $PSScriptRoot "build_python_wheels.py"),
        "--repository-root", $config.RepoRoot,
        "--output", $pypiOutput
    )

foreach ($package in @("alpha", "beta")) {
    Assert-NativeSuccess `
        -Command "npm" `
        -Arguments @(
            "pack",
            (Join-Path $config.RepoRoot "samples\npm\$package"),
            "--pack-destination", $npmOutput,
            "--ignore-scripts",
            "--silent"
        )
}

$offlineNugetConfig = Join-Path $config.RepoRoot "samples\nuget\NuGet.Config"
foreach ($project in @(
        (Join-Path $config.RepoRoot "samples\nuget\Alpha\Alpha.csproj"),
        (Join-Path $config.RepoRoot "samples\nuget\Beta\Beta.csproj"))) {
    Assert-NativeSuccess `
        -Command "dotnet" `
        -Arguments @(
            "restore", $project,
            "--configfile", $offlineNugetConfig,
            "--force",
            "--nologo"
        )
    Assert-NativeSuccess `
        -Command "dotnet" `
        -Arguments @(
            "pack", $project,
            "--configuration", "Release",
            "--output", $nugetOutput,
            "--no-restore",
            "--nologo"
        )
}

foreach ($format in @("pypi", "npm", "nuget")) {
    $files = @(Get-ChildItem -LiteralPath (Join-Path $packagesRoot $format) -File)
    if ($files.Count -ne 2) {
        throw "Expected two $format packages, found $($files.Count)."
    }

    Write-Host "$format packages:"
    $files | Sort-Object Name | ForEach-Object { Write-Host "  $($_.Name)" }
}
