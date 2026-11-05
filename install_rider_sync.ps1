$ErrorActionPreference = "Stop"

$Repo = "azender1/bot-dashboard"
$Local = "C:\trading\bot-dashboard"
$TaskName = "RiderCouncilWebSync"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required."
}

gh auth status
if ($LASTEXITCODE -ne 0) { throw "Run: gh auth login" }

gh auth setup-git
if ($LASTEXITCODE -ne 0) { throw "Could not configure Git credentials." }

if (Test-Path $Local) {
    Set-Location $Local
    git pull origin main
    if ($LASTEXITCODE -ne 0) { throw "Could not update local bot-dashboard repo." }
} else {
    Set-Location "C:\trading"
    gh repo clone $Repo $Local
    if ($LASTEXITCODE -ne 0) { throw "Could not clone $Repo" }
    Set-Location $Local
}

$Sync = Join-Path $Local "sync_rider_status.ps1"
if (-not (Test-Path $Sync)) {
    throw "sync_rider_status.ps1 missing after clone/pull."
}

# Publish immediately.
powershell -NoProfile -ExecutionPolicy Bypass -File $Sync
if ($LASTEXITCODE -ne 0) { throw "Initial Rider dashboard sync failed." }

$TaskCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Sync`""
schtasks.exe /Create /TN $TaskName /TR $TaskCmd /SC MINUTE /MO 5 /F | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Could not create scheduled sync task." }

Write-Host ""
Write-Host "RIDER WEBSITE SYNC READY"
Write-Host "Website:"
Write-Host "https://azender1.github.io/bot-dashboard/"
Write-Host ""
Write-Host "Refresh cadence: about every 5 minutes"
