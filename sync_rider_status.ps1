$ErrorActionPreference = "Stop"

$RiderRoot = "C:\trading\rider_council_v1_friday"
$WebRoot   = $PSScriptRoot
$StatePath = Join-Path $RiderRoot "runtime\state.json"
$IndexPath = Join-Path $WebRoot "index.html"

function H([object]$x) {
    if ($null -eq $x) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$x)
}
function Pct($x) {
    if ($null -eq $x) { return "n/a" }
    try { return ('{0:+0.00;-0.00;0.00}%' -f [double]$x) } catch { return "$x" }
}
function Num1($x) {
    if ($null -eq $x) { return "n/a" }
    try { return ('{0:0.0}' -f [double]$x) } catch { return "$x" }
}
function ModeClass($mode) {
    switch ($mode) {
        "ACTIVE"    { return "good" }
        "RESEARCH"  { return "warn" }
        "WIND_DOWN" { return "warn" }
        "HALTED"    { return "bad" }
        default     { return "muted" }
    }
}

$now = Get-Date
$mode = "NO STATE"
$date = ""
$scans = 0
$entries = 0
$exits = 0
$halt = "none"
$lastScan = ""
$losers = @()
$winners = @()
$positions = @()
$trades = @()
$errors = @()

if (Test-Path $StatePath) {
    $s = Get-Content $StatePath -Raw | ConvertFrom-Json
    $mode = [string]$s.mode
    $date = [string]$s.date_et
    $scans = $s.scan_count
    $entries = $s.paper_entries
    $exits = $s.paper_exits
    $halt = if ($s.halt_reason) { [string]$s.halt_reason } else { "none" }
    $lastScan = [string]$s.last_scan_utc
    $losers = @($s.top_losers) | Select-Object -First 8
    $winners = @($s.top_winners) | Select-Object -First 8
    if ($s.managed_positions) { $positions = @($s.managed_positions.PSObject.Properties) }
    $trades = @($s.trades) | Select-Object -Last 8
    $errors = @($s.errors) | Select-Object -Last 5
}

$loserRows = ""
foreach ($x in $losers) {
    $q = if ($x.qualified) { '<span class="yes">YES</span>' } else { '<span class="no">NO</span>' }
    $loserRows += "<tr><td><b>$(H $x.symbol)</b></td><td>$(H (Pct $x.day))</td><td>$(H (Num1 $x.score))</td><td>$(H (Pct $x.rel))</td><td>$(H (Pct $x.vwap_dist))</td><td>$q</td></tr>"
}
if (-not $loserRows) { $loserRows = '<tr><td colspan="6" class="mutedText">No loser candidates yet</td></tr>' }

$winnerRows = ""
foreach ($x in $winners) {
    $q = if ($x.qualified) { '<span class="yes">YES</span>' } else { '<span class="no">NO</span>' }
    $winnerRows += "<tr><td><b>$(H $x.symbol)</b></td><td>$(H (Pct $x.day))</td><td>$(H (Num1 $x.score))</td><td>$(H (Pct $x.rel))</td><td>$(H (Pct $x.vwap_dist))</td><td>$q</td></tr>"
}
if (-not $winnerRows) { $winnerRows = '<tr><td colspan="6" class="mutedText">No winner candidates yet</td></tr>' }

$positionCards = ""
if ($positions.Count -eq 0) {
    $positionCards = '<div class="empty">No Rider-managed positions</div>'
} else {
    foreach ($p in $positions) {
        $v = $p.Value
        $sideClass = if ($v.side -eq "LONG") { "long" } else { "short" }
        $positionCards += "<div class='position $sideClass'><div><b>$(H $p.Name)</b> <span class='pill'>$(H $v.side)</span></div><div class='small'>Status: $(H $v.status)</div><div class='small'>Entry ref: $(H $v.entry_reference) &nbsp; Stop: $(H $v.stop_price)</div><div class='small'>Score: $(H $v.score)</div></div>"
    }
}

$tradeItems = ""
if ($trades.Count -eq 0) { $tradeItems = '<li>none</li>' }
else { foreach ($t in $trades) { $tradeItems += "<li>$(H $t)</li>" } }

$errorItems = ""
if ($errors.Count -eq 0) { $errorItems = '<li>none</li>' }
else { foreach ($e in $errors) { $errorItems += "<li>$(H $e)</li>" } }

$modeClass = ModeClass $mode
$haltClass = if ($halt -eq "none") { "good" } else { "bad" }

$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta http-equiv="refresh" content="60">
<title>Rider Council Live</title>
<style>
:root{color-scheme:dark;--bg:#0b0f14;--card:#121923;--line:#233041;--text:#eef4fb;--muted:#8ea0b5;--good:#47d16c;--bad:#ff5b68;--warn:#ffca4a;--blue:#62a8ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif}
.wrap{max-width:920px;margin:auto;padding:16px 12px 40px}.header{display:flex;justify-content:space-between;gap:12px;align-items:flex-start;margin-bottom:14px}
h1{font-size:25px;margin:0}.sub{color:var(--muted);font-size:12px;margin-top:5px}.badge{padding:7px 10px;border-radius:999px;font-weight:800;font-size:12px;background:#1b2633}
.badge.good{color:var(--good)}.badge.bad{color:var(--bad)}.badge.warn{color:var(--warn)}.badge.muted{color:var(--muted)}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:12px}.stat,.card{background:var(--card);border:1px solid var(--line);border-radius:14px}
.stat{padding:12px}.stat .k{font-size:11px;color:var(--muted);text-transform:uppercase}.stat .v{font-size:22px;font-weight:800;margin-top:4px}
.card{padding:14px;margin-bottom:12px}h2{font-size:17px;margin:0 0 10px}
table{width:100%;border-collapse:collapse;font-size:13px}th{color:var(--muted);font-size:10px;text-transform:uppercase;text-align:right;padding:7px 5px;border-bottom:1px solid var(--line)}
th:first-child,td:first-child{text-align:left}td{text-align:right;padding:9px 5px;border-bottom:1px solid #1b2532}.yes{color:var(--good);font-weight:800}.no{color:var(--muted)}
.positions{display:grid;grid-template-columns:repeat(2,1fr);gap:8px}.position{padding:11px;border-radius:10px;background:#0d141d;border-left:4px solid var(--blue)}
.position.long{border-left-color:var(--good)}.position.short{border-left-color:var(--bad)}
.pill{font-size:10px;padding:3px 6px;border-radius:999px;background:#202b38}.small{font-size:12px;color:var(--muted);margin-top:5px}.empty,.mutedText{color:var(--muted)}
ul{padding-left:20px;margin:5px 0}li{margin:5px 0;font-size:12px;word-break:break-word}.footer{color:var(--muted);font-size:11px;text-align:center;margin-top:15px}
.halt.good{color:var(--good)}.halt.bad{color:var(--bad)}
@media(max-width:600px){.grid{grid-template-columns:repeat(2,1fr)}.positions{grid-template-columns:1fr}table{font-size:11px}.card{padding:10px}.wrap{padding:12px 8px 30px}h1{font-size:21px}}
</style>
</head>
<body>
<div class="wrap">
<div class="header"><div><h1>Rider Council Live</h1><div class="sub">Trading date $(H $date) · web publish $($now.ToString("yyyy-MM-dd HH:mm:ss")) ET</div></div><div class="badge $modeClass">$(H $mode)</div></div>
<div class="grid">
<div class="stat"><div class="k">Scans</div><div class="v">$(H $scans)</div></div>
<div class="stat"><div class="k">Entries</div><div class="v">$(H $entries)</div></div>
<div class="stat"><div class="k">Exits</div><div class="v">$(H $exits)</div></div>
<div class="stat"><div class="k">Halt</div><div class="v halt $haltClass" style="font-size:15px">$(H $halt)</div></div>
</div>
<div class="card"><h2>Bear · Loser Rider</h2><table><thead><tr><th>Symbol</th><th>Day</th><th>Score</th><th>Rel</th><th>VWAP</th><th>Go?</th></tr></thead><tbody>$loserRows</tbody></table></div>
<div class="card"><h2>Bull · Winner Rider</h2><table><thead><tr><th>Symbol</th><th>Day</th><th>Score</th><th>Rel</th><th>VWAP</th><th>Go?</th></tr></thead><tbody>$winnerRows</tbody></table></div>
<div class="card"><h2>Managed positions</h2><div class="positions">$positionCards</div></div>
<div class="card"><h2>Recent actions</h2><ul>$tradeItems</ul></div>
<div class="card"><h2>Errors</h2><ul>$errorItems</ul></div>
<div class="footer">Last engine scan UTC: $(H $lastScan)<br>Sanitized paper-trading monitor. No credentials published. Auto-refreshes every 60 seconds.</div>
</div>
</body>
</html>
"@

$html | Set-Content $IndexPath -Encoding UTF8

Set-Location $WebRoot
git add index.html
$changes = git status --porcelain
if (-not $changes) { exit 0 }

git commit -m "Update Rider Council live status $($now.ToString('yyyy-MM-dd HH:mm'))" | Out-Host
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
git push origin main | Out-Host
exit $LASTEXITCODE
