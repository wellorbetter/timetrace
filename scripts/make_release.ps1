# TimeTrace green-build packager (fixed: data/ must be included + verified)
param([string]$Version = 'v1.0.1')
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner = "$root\app\build\windows\x64\runner"
$dist = "$root\dist"
$name = "TimeTrace-$Version-windows-x64"
$out = "$dist\$name"

if (-not (Test-Path "$runner\data\app.so")) { Write-Error "data/app.so missing - run assemble first"; exit 1 }
if (-not (Test-Path "$runner\data\flutter_assets\AssetManifest.bin")) { Write-Error "flutter_assets incomplete"; exit 1 }

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-ChildItem $runner -File | Where-Object { $_.Extension -in '.exe', '.dll' } |
  Copy-Item -Destination $out
Copy-Item "$runner\data" "$out\data" -Recurse
Copy-Item "$runner\data\flutter_assets" "$out\data\flutter_assets" -Recurse

# Bundle the MSVC runtime so a clean Windows machine does not need a separate
# Visual C++ Redistributable installation. Prefer the active toolchain, then
# locate the installed VS Build Tools through vswhere.
$crtRoot = $env:VCToolsRedistDir
if (-not $crtRoot) {
  $vswhere = @(
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
    "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($vswhere) {
    $installationPath = & $vswhere -latest -products * -property installationPath
    if ($installationPath) { $crtRoot = Join-Path $installationPath 'VC\Redist\MSVC' }
  }
}
if (-not $crtRoot -or -not (Test-Path $crtRoot)) {
  Write-Error 'MSVC runtime directory not found; install VS Build Tools or set VCToolsRedistDir'
}
$crtFiles = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')
$crtDir = Get-ChildItem $crtRoot -Directory -Recurse |
  Where-Object { $_.FullName -match '\\x64\\Microsoft\.VC[^\\]+\.CRT$' } |
  Sort-Object FullName -Descending | Select-Object -First 1
if (-not $crtDir) { Write-Error "x64 MSVC CRT directory not found under $crtRoot" }
foreach ($crtFile in $crtFiles) {
  $source = Join-Path $crtDir.FullName $crtFile
  if (-not (Test-Path $source)) { Write-Error "MSVC runtime missing: $source" }
  Copy-Item $source $out
}

# sanity check before zipping
foreach ($need in @('timetrace_app.exe','flutter_windows.dll','vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','data\app.so','data\icudtl.dat','data\flutter_assets\AssetManifest.bin')) {
  if (-not (Test-Path "$out\$need")) { Write-Error "staging missing: $need" }
}
Write-Output "staging OK ($((Get-ChildItem $out -Recurse | Measure-Object Length -Sum).Sum/1MB) MB)"

$zip = "$dist\$name.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $out -DestinationPath $zip
$zsize = [math]::Round((Get-Item $zip).Length/1MB,1)
Write-Output "zip: $zip ($zsize MB)"
