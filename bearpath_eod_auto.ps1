$ErrorActionPreference = "Stop"
$BearRoot = "C:\trading\bearpath_lab_v0_1"
$Py = Join-Path $BearRoot ".venv\Scripts\python.exe"
Set-Location $BearRoot
& $Py -m bearpath.cli grade-daily
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\trading\bot-dashboard\sync_bearpath_status.ps1"
