param(
    [string]$Reason = "live"
)

$ErrorActionPreference = "Stop"
$WebRoot = $PSScriptRoot
$ExpectedLeaf = "bot-dashboard-publish"
$ActualLeaf = Split-Path $WebRoot -Leaf
if ($ActualLeaf -ne $ExpectedLeaf) {
    throw "SAFETY STOP: automation publisher must run from a checkout named '$ExpectedLeaf'. Current: $WebRoot"
}

$LockDir = Join-Path $env:TEMP "BearPathOps"
New-Item -ItemType Directory -Force -Path $LockDir | Out-Null
$LockPath = Join-Path $LockDir "dashboard-publish.lock"
$lock = $null
try {
    try {
        $lock = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        Write-Host "Publish already running; skipping."
        exit 0
    }

    Set-Location $WebRoot
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Write-Host "Publish attempt $attempt/$maxAttempts"

        git fetch origin
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }

        git reset --hard origin/main
        if ($LASTEXITCODE -ne 0) { throw "git reset --hard origin/main failed" }

        git clean -fd
        if ($LASTEXITCODE -ne 0) { throw "git clean -fd failed" }

        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $WebRoot "sync_bearpath_status.ps1") -NoGit
        if ($LASTEXITCODE -ne 0) { throw "dashboard render failed with exit code $LASTEXITCODE" }

        git add -- index.html risk_scores.json risk-check.html
        if ($LASTEXITCODE -ne 0) { throw "git add failed" }

        git diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "No dashboard changes to publish."
            exit 0
        }

        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        git commit -m "BearPath $Reason $stamp"
        if ($LASTEXITCODE -ne 0) { throw "git commit failed" }

        git push origin main
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Dashboard published successfully."
            exit 0
        }

        Write-Warning "Push rejected/failed on attempt $attempt. Resetting and regenerating."
        if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 10 }
    }

    throw "Dashboard publish failed after $maxAttempts attempts."
}
finally {
    if ($lock) { $lock.Dispose() }
}
