param([switch]$NoGit)

$ErrorActionPreference = "Stop"

$BearRoot = "C:\trading\bearpath_lab_v0_1"
$WebRoot  = $PSScriptRoot
$PredRoot = Join-Path $BearRoot "data\predictions"
$MicroRoot = Join-Path $BearRoot "data\micro_predictions"
$IndexPath = Join-Path $WebRoot "index.html"
$RiskExportScript = Join-Path $BearRoot "scripts\bearpath_risk_check_export.py"
$RiskDataSource = Join-Path $BearRoot "data\public\risk_scores.json"
$RiskDataWeb = Join-Path $WebRoot "risk_scores.json"

function HtmlEncode([object]$x) {
    if ($null -eq $x) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$x)
}
function Pct($x) {
    if ($null -eq $x) { return "n/a" }
    try { return ('{0:+0.00;-0.00;0.00}%' -f [double]$x) } catch { return "$x" }
}
function Money($x) {
    if ($null -eq $x) { return "n/a" }
    try { return ('$' + ('{0:N2}' -f [double]$x)) } catch { return "$x" }
}

if (-not (Test-Path $PredRoot)) { throw "BearPath predictions folder not found: $PredRoot" }
$pred = Get-ChildItem $PredRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName "prediction_manifest.json") } | Sort-Object Name | Select-Object -Last 1
if (-not $pred) { throw "No frozen BearPath prediction found." }

$manifestPath = Join-Path $pred.FullName "prediction_manifest.json"
$gradePath = Join-Path $pred.FullName "grade.json"
$man = Get-Content $manifestPath -Raw | ConvertFrom-Json
$grade = if (Test-Path $gradePath) { Get-Content $gradePath -Raw | ConvertFrom-Json } else { $null }

# Build the public Tomorrow Risk Check dataset from the exact frozen session.
# This is a fail-closed health gate: any reconciliation failure stops publication.
if (-not (Test-Path $RiskExportScript)) { throw "Risk Check exporter missing: $RiskExportScript" }
$Python = Join-Path $BearRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $Python)) { throw "BearPath Python missing: $Python" }
Push-Location $BearRoot
try {
    & $Python $RiskExportScript --target-date ([string]$man.target_date)
    if ($LASTEXITCODE -ne 0) { throw "Risk Check exporter failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
if (-not (Test-Path $RiskDataSource)) { throw "Risk Check export missing after successful exporter run: $RiskDataSource" }
Copy-Item $RiskDataSource $RiskDataWeb -Force

# Optional separate Chaos Micro research lane. It never changes the production $5+ manifest.
$microMan = $null
$microPred = $null
$microTargetDate = $null
$microFrozenET = $null
if (Test-Path $MicroRoot) {
    $microPred = Get-ChildItem $MicroRoot -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "prediction_manifest.json") } |
        Sort-Object Name | Select-Object -Last 1
    if ($microPred) {
        $microMan = Get-Content (Join-Path $microPred.FullName "prediction_manifest.json") -Raw | ConvertFrom-Json
        $microTargetDate = [datetime]::ParseExact([string]$microMan.target_date, "yyyy-MM-dd", $null).Date
        try {
            $eastern = [TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")
            $microFrozenET = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Parse([string]$microMan.created_utc), $eastern).ToString("yyyy-MM-dd HH:mm:ss 'ET'")
        } catch {
            $microFrozenET = [string]$microMan.created_utc
        }
    }
}

$gradeMap = @{}
if ($grade -and $grade.picks) {
    foreach ($p in @($grade.picks)) { $gradeMap[[string]$p.symbol] = $p }
}

$snapshots = $null
$liveError = $null
$targetDate = [datetime]::ParseExact([string]$man.target_date, "yyyy-MM-dd", $null).Date
$todayLocal = (Get-Date).Date
$isTargetDay = ($todayLocal -eq $targetDate)

if ($isTargetDay -and ((-not $grade) -or $microMan)) {
    $key = $env:APCA_API_KEY_ID
    $secret = if ($env:APCA_API_SECRET_KEY) { $env:APCA_API_SECRET_KEY } else { $env:APCA_API_SECRET }
    if ($key -and $secret) {
        try {
            $symbolList = @($man.top) | ForEach-Object { [string]$_.symbol }
            if ($microMan -and $microTargetDate -eq $targetDate) {
                $symbolList += @($microMan.top) | ForEach-Object { [string]$_.symbol }
            }
            $symbols = ($symbolList | Sort-Object -Unique) -join ","
            $uri = "https://data.alpaca.markets/v2/stocks/snapshots?symbols=$([uri]::EscapeDataString($symbols))&feed=delayed_sip"
            $headers = @{ "APCA-API-KEY-ID"=$key; "APCA-API-SECRET-KEY"=$secret }
            $snapshots = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 30
        } catch {
            $liveError = $_.Exception.Message
        }
    } else {
        $liveError = "Alpaca API environment variables unavailable to dashboard sync."
    }
}

$cards = ""
$downNow = 0
$moves = New-Object System.Collections.Generic.List[double]

foreach ($x in @($man.top)) {
    $sym = [string]$x.symbol
    $ref = [double]$x.close
    $price = $null
    $move = $null
    $status = "PENDING"
    $rankText = ""
    $class = "flat"
    $tags = ""

    if ($x.r1_flag) { $tags += '<span class="tag">R1</span>' }
    if ($x.r2_flag) { $tags += '<span class="tag">R2</span>' }

    if ($grade -and $gradeMap.ContainsKey($sym)) {
        $g = $gradeMap[$sym]
        $move = [double]$g.target_return_pct
        $price = $ref * (1.0 + $move/100.0)
        $mr = [int]$g.market_loser_rank
        $rankText = " &middot; market loser #$mr"
        if ($mr -le 50) { $tags += '<span class="tag top50">TOP 50</span>' }
        elseif ($mr -le 100) { $tags += '<span class="tag top100">TOP 100</span>' }
    } elseif ($snapshots -and ($snapshots.PSObject.Properties.Name -contains $sym)) {
        $snap = $snapshots.$sym
        $tradeIsToday = $false
        if ($snap.latestTrade -and $snap.latestTrade.t) {
            try {
                $tradeTime = [DateTimeOffset]::Parse([string]$snap.latestTrade.t).LocalDateTime
                $tradeIsToday = ($tradeTime.Date -eq $targetDate)
            } catch {
                $tradeIsToday = $false
            }
        }
        if ($tradeIsToday -and $null -ne $snap.latestTrade.p) {
            $price = [double]$snap.latestTrade.p
        }
        if ($null -ne $price -and $ref -ne 0) { $move = (($price / $ref) - 1.0) * 100.0 }
    }

    if ($null -ne $move) {
        $moves.Add([double]$move)
        if ($move -lt 0) { $status="HIT"; $class="hit"; $downNow++ }
        elseif ($move -gt 0) { $status="MISS"; $class="miss" }
        else { $status="FLAT"; $class="flat" }
    }

    $latestLabel = if ($grade) { "Final" } else { "Latest" }
    $cards += @"
<div class="pick $class">
  <div class="pickTop">
    <div><span class="rank">#$($x.rank)</span> <span class="ticker">&#36;$([string](HtmlEncode $sym))</span>$tags</div>
    <div class="verdict $class">$status</div>
  </div>
  <div class="priceRow">
    <div><span>Frozen</span><b>$(Money $ref)</b></div>
    <div><span>$latestLabel</span><b>$(Money $price)</b></div>
    <div><span>Move</span><b class="$($class)Text">$(Pct $move)</b></div>
  </div>
  <div class="why">BP score $([math]::Round([double]$x.bearpath_score,1))$rankText &middot; $([string](HtmlEncode $x.why))</div>
</div>
"@
}

$microHtml = ""
if ($microMan) {
    $microCards = ""
    foreach ($m in @($microMan.top)) {
        $msym = [string]$m.symbol
        $mref = [double]$m.close
        $mprice = $null
        $mmove = $null
        $mstatus = "PENDING"
        $mclass = "flat"

        if ($snapshots -and $microTargetDate -eq $targetDate -and ($snapshots.PSObject.Properties.Name -contains $msym)) {
            $msnap = $snapshots.$msym
            $mbarIsToday = $false
            if ($msnap.dailyBar -and $msnap.dailyBar.t) {
                try {
                    $mbarTime = [DateTimeOffset]::Parse([string]$msnap.dailyBar.t).LocalDateTime
                    $mbarIsToday = ($mbarTime.Date -eq $microTargetDate)
                } catch { $mbarIsToday = $false }
            }
            if ($mbarIsToday -and $null -ne $msnap.dailyBar.c) { $mprice = [double]$msnap.dailyBar.c }
            if ($null -ne $mprice -and $mref -ne 0) { $mmove = (($mprice / $mref) - 1.0) * 100.0 }
        }
        if ($null -ne $mmove) {
            if ($mmove -lt 0) { $mstatus="HIT"; $mclass="hit" }
            elseif ($mmove -gt 0) { $mstatus="MISS"; $mclass="miss" }
            else { $mstatus="FLAT" }
        }

        $microCards += @"
<div class="pick $mclass">
  <div class="pickTop">
    <div><span class="rank">#$($m.rank)</span> <span class="ticker">&#36;$([string](HtmlEncode $msym))</span></div>
    <div class="verdict $mclass">$mstatus</div>
  </div>
  <div class="priceRow">
    <div><span>Frozen</span><b>$(Money $mref)</b></div>
    <div><span>$(if ($grade) { "Final" } else { "Latest" })</span><b>$(Money $mprice)</b></div>
    <div><span>Move</span><b class="$($mclass)Text">$(Pct $mmove)</b></div>
  </div>
  <div class="why">Micro score $([math]::Round([double]$m.micro_score,1)) &middot; $([string](HtmlEncode $m.why))</div>
</div>
"@
    }
    $microHash = if ($microMan.manifest_hash) { ([string]$microMan.manifest_hash).Substring(0,16) + "..." } else { "n/a" }
    $microHtml = @"
<div class="title">Chaos Micro &middot; experimental &#36;1.00-&#36;4.99 lane</div>
<div class="microMeta">
  <b>FROZEN / FORWARD TEST</b> &middot; target $($microMan.target_date) &middot; signal close $($microMan.as_of) &middot; $($microMan.eligible_universe_n) eligible &middot; 10 picks<br>
  Frozen timestamp: $microFrozenET &middot; Manifest $microHash<br>
  Separate research lane; not included in the Chaos Alpha public record.
</div>
<div class="grid">$microCards</div>
"@
}

$medianMove = "n/a"
if ($moves.Count -gt 0) {
    $sorted = @($moves | Sort-Object)
    $n = $sorted.Count
    if ($n % 2 -eq 1) { $med = $sorted[[int][math]::Floor($n/2)] }
    else { $med = ($sorted[$n/2-1] + $sorted[$n/2]) / 2.0 }
    $medianMove = Pct $med
}

if ($grade) {
    $mode = "OFFICIAL EOD"
    $leftLabel = "Picks down"; $leftVal = "$($grade.picks_down_n)/15"
    $midLabel = "Top-100 losers"; $midVal = "$($grade.top100_hits)/15"
    $universe = [int]$grade.universe_graded_n
} else {
    if ($isTargetDay) {
        $mode = "LIVE / PRE-EOD"
        $leftLabel = "Down now"; $leftVal = "$downNow/15"
        $midLabel = "Median move"; $midVal = $medianMove
    } else {
        $mode = "FROZEN / PRE-MARKET"
        $leftLabel = "Top-100 hits"; $leftVal = "Pending"
        $midLabel = "Top-50 hits"; $midVal = "Pending"
    }
    $universe = [int]$man.eligible_universe_n
}

$trackHtml = '<div class="notice">Forward track record begins after the first official EOD grade.</div>'
$trackPath = Join-Path $BearRoot "data\public\track_record.json"
if (Test-Path $trackPath) {
    $tr = Get-Content $trackPath -Raw | ConvertFrom-Json
    $trackHtml = @"
<div class="track">
<div><span>Days graded</span><b>$($tr.days)</b></div>
<div><span>Top-100 hits</span><b>$($tr.top100_hits)</b></div>
<div><span>Top-100 lift</span><b>$($tr.top100_lift_vs_random)x</b></div>
<div><span>Picks down</span><b>$($tr.picks_down_pct)%</b></div>
</div>
"@
}

$err = if ($liveError -and -not $grade) { '<div class="notice">Live feed note: ' + (HtmlEncode $liveError) + '</div>' } else { "" }
$now = Get-Date

$html = @"
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta http-equiv="refresh" content="60">
<title>BearPath Live n/a Downside 15</title>
<style>
:root{color-scheme:dark;--bg:#070b10;--card:#101720;--line:#223144;--text:#eef5fc;--muted:#8ca0b5;--good:#37d67a;--bad:#ff5e6c;--gold:#ffd166}
*{box-sizing:border-box}body{margin:0;background:linear-gradient(180deg,#07101a,#070b10 35%);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif}
.wrap{max-width:1050px;margin:auto;padding:18px 12px 40px}.hero,.pick,.track{background:var(--card);border:1px solid var(--line);border-radius:16px}.hero{padding:17px}
.brand{display:flex;justify-content:space-between;gap:12px}.logo{font-size:28px;font-weight:900}.logo em{color:var(--bad);font-style:normal}.sub,.why{color:var(--muted)}
.sub{font-size:12px;margin-top:4px}.mode{font-size:11px;font-weight:900;color:var(--gold);background:#202a36;padding:7px 10px;border-radius:999px}.riskCta{display:inline-block;margin-top:12px;padding:10px 13px;border-radius:10px;background:#7f2530;color:white;text-decoration:none;font-size:12px;font-weight:900}.launchCounters{display:inline-block;margin-left:10px;color:var(--muted);font-size:10px}.launchCounters b{color:var(--text)}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-top:14px}.stat{background:#0b1118;border:1px solid var(--line);border-radius:12px;padding:10px}.stat span,.priceRow span,.track span{display:block;color:var(--muted);font-size:9px;text-transform:uppercase}.stat b{font-size:22px}
.title{margin:16px 3px 8px;color:var(--muted);font-size:11px;text-transform:uppercase;font-weight:800;letter-spacing:.7px}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:9px}
.pick{padding:12px;border-left:5px solid #546273}.pick.hit{border-left-color:var(--good)}.pick.miss{border-left-color:var(--bad)}.pickTop{display:flex;justify-content:space-between;gap:8px}.rank{font-size:11px;color:var(--muted)}.ticker{font-size:20px;font-weight:900}
.tag{font-size:8px;padding:3px 5px;border-radius:6px;background:#263546;margin-left:4px}.tag.top50{background:#17603e}.tag.top100{background:#274c7d}.verdict{font-size:10px;font-weight:900;padding:5px 7px;border-radius:7px}.verdict.hit{color:var(--good);background:#123c2b}.verdict.miss{color:var(--bad);background:#461d26}
.priceRow{display:grid;grid-template-columns:repeat(3,1fr);gap:7px;margin-top:10px}.priceRow div{background:#0a1017;border-radius:8px;padding:7px}.priceRow b{display:block;font-size:12px}.hitText{color:var(--good)}.missText{color:var(--bad)}.why{font-size:10px;margin-top:9px;line-height:1.35}
.track{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;padding:10px}.track div{padding:7px}.track b{font-size:18px}.notice{margin-top:10px;background:#2a2111;color:#ffd98b;border:1px solid #54411c;padding:9px;border-radius:9px;font-size:11px}.microMeta{margin-bottom:9px;background:#101720;border:1px solid #3a3150;border-radius:12px;padding:10px;color:#b9a9cf;font-size:11px;line-height:1.55}.microMeta b{color:#d7b8ff}
.footer{font-size:10px;color:var(--muted);text-align:center;line-height:1.5;margin-top:18px}
@media(max-width:750px){.grid{grid-template-columns:1fr 1fr}.stats,.track{grid-template-columns:1fr 1fr}}@media(max-width:470px){.grid{grid-template-columns:1fr}}
</style></head><body><div class="wrap">
<div class="hero"><div class="brand"><div><div class="logo">BEAR<em>PATH</em> LIVE</div><div class="sub">Downside 15 &middot; target $($man.target_date) &middot; signal close $($man.as_of)</div></div><div class="mode">$mode</div></div>
<div class="stats"><div class="stat"><span>$leftLabel</span><b>$leftVal</b></div><div class="stat"><span>$midLabel</span><b>$midVal</b></div><div class="stat"><span>Universe graded</span><b>$("{0:N0}" -f $universe)</b></div><div class="stat"><span>$(if ($grade) { "Top-50 losers" } else { "Frozen picks" })</span><b>$(if ($grade) { "$($grade.top50_hits)/15" } else { "15" })</b></div></div><a id="riskCheckCta" class="riskCta" href="./risk-check.html">CHECK YOUR STOCK →</a><span class="launchCounters">Dashboard views <b id="dashboardViews">—</b> &middot; Risk Check clicks <b id="riskClicks">—</b></span>$err</div>
<div class="title">Daily Downside 15</div><div class="grid">$cards</div>
$microHtml
<div class="title">Forward track record</div>$trackHtml
<div class="footer">GREEN = stock down / BearPath hit. RED = stock up / BearPath miss.<br>Live/Micro display uses Alpaca delayed-SIP snapshots; official BearPath EOD results use the frozen full-universe grader.<br>Manifest $($man.manifest_hash.Substring(0,16))... &middot; Published $($now.ToString("yyyy-MM-dd HH:mm:ss")) ET<br>Historical research only n/a not investment advice.</div>
</div>
<script>
(function(){
  const base="https://countapi.mileshilliard.com/api/v1";
  const viewKey="bearpath_dashboard_views_20261123";
  const clickKey="bearpath_riskcheck_clicks_20261123";
  const viewEl=document.getElementById("dashboardViews");
  const clickEl=document.getElementById("riskClicks");
  function show(el,v){ if(el && v!==undefined && v!==null) el.textContent=String(v); }
  fetch(base+"/hit/"+viewKey).then(r=>r.json()).then(j=>show(viewEl,j.value)).catch(()=>show(viewEl,"n/a"));
  fetch(base+"/get/"+clickKey).then(r=>r.ok?r.json():null).then(j=>show(clickEl,j?j.value:0)).catch(()=>show(clickEl,"n/a"));
  const cta=document.getElementById("riskCheckCta");
  if(cta){
    cta.addEventListener("click",function(){
      try{ navigator.sendBeacon(base+"/hit/"+clickKey); }
      catch(e){ fetch(base+"/hit/"+clickKey,{keepalive:true}).catch(()=>{}); }
    });
  }
})();
</script></body></html>
"@

$html | Set-Content $IndexPath -Encoding UTF8
if ($NoGit) { exit 0 }

Set-Location $WebRoot
git add -- index.html risk_scores.json risk-check.html
git diff --cached --quiet
if ($LASTEXITCODE -eq 0) { exit 0 }
git commit -m "Update BearPath Live $($now.ToString('yyyy-MM-dd HH:mm'))" | Out-Host
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
git push origin main | Out-Host
exit $LASTEXITCODE