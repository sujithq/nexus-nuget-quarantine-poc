[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot "Common.ps1")
$config = Get-PocConfiguration
Assert-NativeSuccess `
    -Command "dotnet" `
    -Arguments @(
        "run",
        "--project",
        (Join-Path $config.RepoRoot "tests\NexusQuarantine.Core.Tests\NexusQuarantine.Core.Tests.csproj"),
        "--nologo"
    )
