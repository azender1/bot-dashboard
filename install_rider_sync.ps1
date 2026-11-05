$ErrorActionPreference = "Stop"

$Local = "C:\trading\bot-dashboard"
$TaskName = "RiderCouncilWebSync"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is required."
}

if (-not (Test-Path $Local)) {
    throw "Local bot-dashboard repo not found at $Local"
}

Set-Location $Local

git pull origin main
if ($LASTEXITCODE -ne 0) { throw "Could not update local bot-dashboard repo." }

$Sync = Join-Path $Local "sync_rider_status.ps1"
if (-not (Test-Path $Sync)) {
    throw "sync_rider_status.ps1 missing after git pull."
}

Write-Host "Publishing current Rider status..."
powershell -NoProfile -ExecutionPolicy Bypass -File $Sync
if ($LASTEXITCODE -ne 0) { throw "Initial Rider dashboard sync failed." }

$TaskCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Sync`""
schtasks.exe /Create /TN $TaskName /TR $TaskCmd /SC MINUTE /MO 5 /F | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Could not create $TaskName. If access is denied, rerun this script from an elevated PowerShell."
}

Write-Host ""
Write-Host "RIDER WEBSITE SYNC READY"
Write-Host "Website:"
Write-Host "https://azender1.github.io/bot-dashboard/"
Write-Host ""
Write-Host "Refresh cadence: about every 5 minutes"
