$ErrorActionPreference = "Stop"
$BearRoot = "C:\trading\bearpath_lab_v0_1"
$Py = Join-Path $BearRoot ".venv\Scripts\python.exe"
Set-Location $BearRoot
& $Py -m bearpath.cli daily-rank --top 15 --freeze
if ($LASTEXITCODE -ne 0) { Write-Host "daily-rank returned $LASTEXITCODE. Continuing to dashboard sync." }
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\trading\bot-dashboard\sync_bearpath_status.ps1"
