# TimeTrace green-build packager (fixed: data/ must be included + verified)
param([string]$Version = 'v1.0.0')
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

# sanity check before zipping
foreach ($need in @('timetrace_app.exe','flutter_windows.dll','data\app.so','data\icudtl.dat','data\flutter_assets\AssetManifest.bin')) {
  if (-not (Test-Path "$out\$need")) { Write-Error "staging missing: $need" }
}
Write-Output "staging OK ($((Get-ChildItem $out -Recurse | Measure-Object Length -Sum).Sum/1MB) MB)"

$zip = "$dist\$name.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path $out -DestinationPath $zip
$zsize = [math]::Round((Get-Item $zip).Length/1MB,1)
Write-Output "zip: $zip ($zsize MB)"
