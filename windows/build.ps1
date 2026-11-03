<#
.SYNOPSIS
  Builds EdgeGlow for Windows as a self-contained single-file executable and zips it.

.EXAMPLE
  ./build.ps1                      # dist/EdgeGlow.exe + dist/EdgeGlow-Windows-x64.zip
  ./build.ps1 -Version 1.2.0 -NoZip
#>
param(
    [string]$Version = "1.0.0",
    [string]$Configuration = "Release",
    [switch]$NoZip
)

$ErrorActionPreference = "Stop"

$root       = $PSScriptRoot
$project    = Join-Path $root "EdgeGlow.Windows\EdgeGlow.Windows.csproj"
$publishDir = Join-Path $root "publish"
$distDir    = Join-Path $root "dist"

foreach ($dir in @($publishDir, $distDir)) {
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
}
New-Item -ItemType Directory -Path $distDir | Out-Null

Write-Host "==> Publishing EdgeGlow $Version (win-x64, self-contained, single file)"
dotnet publish $project `
    -c $Configuration `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:Version=$Version `
    -o $publishDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

$exe = Join-Path $publishDir "EdgeGlow.exe"
if (-not (Test-Path $exe)) { throw "Expected $exe was not produced" }
Copy-Item $exe $distDir

if (-not $NoZip) {
    Write-Host "==> Packaging EdgeGlow-Windows-x64.zip"
    $items = @((Join-Path $distDir "EdgeGlow.exe"))
    $license = Join-Path $root "..\LICENSE"
    if (Test-Path $license) { $items += (Resolve-Path $license).Path }
    $zip = Join-Path $distDir "EdgeGlow-Windows-x64.zip"
    Compress-Archive -Path $items -DestinationPath $zip -Force
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    Write-Host "    $zip"
    Write-Host "    SHA256 $hash"
}

Write-Host "==> Done"
