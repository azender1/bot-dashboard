$ErrorActionPreference = "Stop"
$Local = "C:\trading\bot-dashboard"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Git is required." }
if (-not (Test-Path $Local)) { throw "Local bot-dashboard repo not found at $Local" }
Set-Location $Local
git pull origin main
if ($LASTEXITCODE -ne 0) { throw "Could not update local bot-dashboard repo." }

$Sync = Join-Path $Local "sync_bearpath_status.ps1"
$Morning = Join-Path $Local "bearpath_morning_auto.ps1"
$Eod = Join-Path $Local "bearpath_eod_auto.ps1"

Write-Host "Publishing BearPath Live now..."
powershell -NoProfile -ExecutionPolicy Bypass -File $Sync
if ($LASTEXITCODE -ne 0) { throw "Initial BearPath dashboard sync failed." }

foreach ($taskName in @("RiderCouncilWebSync","BearPathWebSync","BearPathMorningFreeze","BearPathEODGrade")) {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}

$SyncCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $Sync + '"'
$MorningCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $Morning + '"'
$EodCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $Eod + '"'

schtasks.exe /Create /TN "BearPathWebSync" /TR $SyncCmd /SC MINUTE /MO 10 /F | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Could not create BearPathWebSync. Rerun PowerShell as Administrator." }
schtasks.exe /Create /TN "BearPathMorningFreeze" /TR $MorningCmd /SC WEEKLY /D MON,TUE,WED,THU,FRI /ST 07:05 /F | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Could not create BearPathMorningFreeze." }
schtasks.exe /Create /TN "BearPathEODGrade" /TR $EodCmd /SC WEEKLY /D MON,TUE,WED,THU,FRI /ST 16:30 /F | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Could not create BearPathEODGrade." }

Write-Host ""
Write-Host "BEARPATH LIVE READY"
Write-Host "Website: https://azender1.github.io/bot-dashboard/"
Write-Host "Morning freeze: weekdays 7:05 AM"
Write-Host "Live sync: every 10 minutes"
Write-Host "Official EOD grade: weekdays 4:30 PM"
Write-Host "GREEN = stock down / hit; RED = stock up / miss."
