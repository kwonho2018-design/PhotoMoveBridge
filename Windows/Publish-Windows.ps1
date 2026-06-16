param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$CertificateThumbprint = "",
    [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $scriptRoot "PhotoMoveBridge.Windows\PhotoMoveBridge.Windows.csproj"
$publishDir = Join-Path $scriptRoot "artifacts\publish\$Runtime"

dotnet restore $project -r $Runtime
dotnet publish $project -c $Configuration -r $Runtime --self-contained true -o $publishDir

$exe = Join-Path $publishDir "PhotoMoveBridge.Windows.exe"
if ($CertificateThumbprint -and (Test-Path $exe)) {
    $signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if (-not $signtool) {
        throw "signtool.exe was not found. Install Windows SDK or run without -CertificateThumbprint."
    }

    & $signtool.Source sign /fd SHA256 /td SHA256 /tr $TimestampUrl /sha1 $CertificateThumbprint $exe
}

Write-Host "Published: $publishDir"
