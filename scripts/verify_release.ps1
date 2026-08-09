# Verify: run from a clean extracted dir, confirm VC DLLs load from app dir
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$zip = Get-ChildItem (Join-Path $root 'dist') -Filter 'TimeTrace-*.zip' |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1 -ExpandProperty FullName
$dir = "$env:TEMP\tt-verify"
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
Expand-Archive $zip $dir
$exe = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($zip) + '\timetrace_app.exe')
if (-not (Test-Path $exe)) { Write-Error "exe missing"; exit 1 }
Write-Output "extracted OK"

$p = Start-Process $exe -PassThru
Start-Sleep -Seconds 12
if ($p.HasExited) { Write-Error "exited code=$($p.ExitCode)"; exit 1 }
Write-Output "running PID=$($p.Id)"

$mods = Get-Process -Id $p.Id -Module -ErrorAction SilentlyContinue
foreach ($name in @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','timetrace_bridge.dll')) {
  $m = $mods | Where-Object { $_.ModuleName -eq $name } | Select-Object -First 1
  if ($m) {
    $fromApp = $m.FileName.StartsWith($dir)
    Write-Output ("{0,-24} -> {1}  {2}" -f $name, $(if ($fromApp) { 'APP-DIR OK' } else { 'SYSTEM !!!' }), $m.FileName)
  } else {
    Write-Output "$name -> not loaded"
  }
}
Stop-Process -Id $p.Id -Force
Write-Output "verify done"
