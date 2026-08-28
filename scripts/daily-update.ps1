<#
  daily-update.ps1 - Storage-Node-Dashboard
  Zieht taeglich die Token-Kurse (CoinGecko), haengt einen Snapshot an data/history.json,
  spiegelt ihn in index.html (#history-data) und committet/pusht auf main.

  Manuell testen:  powershell -ExecutionPolicy Bypass -File scripts\daily-update.ps1
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root     = Split-Path -Parent $PSScriptRoot
$histPath = Join-Path $root 'data\history.json'
$htmlPath = Join-Path $root 'index.html'
$logPath  = Join-Path $PSScriptRoot 'last-run.log'
Set-Location $root

function Log([string]$msg) {
  $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Write-Host $line
  Add-Content -Path $logPath -Value $line -Encoding UTF8
}

$today = (Get-Date).ToString('yyyy-MM-dd')
Log "=== Lauf gestartet fuer $today ==="

$hist = Get-Content $histPath -Raw -Encoding UTF8 | ConvertFrom-Json
$last = $hist.snapshots[$hist.snapshots.Count - 1]
$m = @{}
foreach ($p in $last.metrics.PSObject.Properties) { $m[$p.Name] = $p.Value }
$note = 'Automatischer Lauf.'

try {
  $cg = Invoke-RestMethod -Uri 'https://api.coingecko.com/api/v3/simple/price?ids=storj,siacoin,filecoin,arweave&vs_currencies=usd' -TimeoutSec 45
  if ($cg.storj.usd)    { $m['storj_usd']    = [math]::Round([double]$cg.storj.usd, 6) }
  if ($cg.siacoin.usd)  { $m['siacoin_usd']  = [math]::Round([double]$cg.siacoin.usd, 6) }
  if ($cg.filecoin.usd) { $m['filecoin_usd'] = [math]::Round([double]$cg.filecoin.usd, 6) }
  if ($cg.arweave.usd)  { $m['arweave_usd']  = [math]::Round([double]$cg.arweave.usd, 6) }
  Log ("CoinGecko OK: storj={0} sia={1} fil={2} ar={3}" -f $cg.storj.usd, $cg.siacoin.usd, $cg.filecoin.usd, $cg.arweave.usd)
} catch {
  $note = 'Automatischer Lauf. CoinGecko nicht erreichbar - Kurse vom Vortag uebernommen.'
  Log ("CoinGecko FEHLER: " + $_.Exception.Message)
}

$keys = @('storj_usd','siacoin_usd','filecoin_usd','arweave_usd')
$metrics = [ordered]@{}
foreach ($k in $keys) { $metrics[$k] = $m[$k] }
$snap = [pscustomobject]@{ date = $today; note = $note; metrics = [pscustomobject]$metrics }

$list = [System.Collections.ArrayList]@($hist.snapshots)
$idx = -1
for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].date -eq $today) { $idx = $i } }
if ($idx -ge 0) { $list[$idx] = $snap; Log "Snapshot $today ersetzt." } else { [void]$list.Add($snap); Log "Snapshot $today angehaengt." }
$hist.snapshots = $list

$jsonOut = $hist | ConvertTo-Json -Depth 10
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($histPath, $jsonOut, $utf8)

$htmlText = Get-Content $htmlPath -Raw -Encoding UTF8
$rxData = [regex]'(?s)(<script type="application/json" id="history-data">\s*).*?(\s*</script>)'
$htmlText = $rxData.Replace($htmlText, { param($mm) $mm.Groups[1].Value + $jsonOut + $mm.Groups[2].Value }, 1)
[System.IO.File]::WriteAllText($htmlPath, $htmlText, $utf8)
Log "index.html + history.json aktualisiert."

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
  git add -A *> $null
  $status = git status --porcelain
  if ([string]::IsNullOrWhiteSpace($status)) { Log "Keine Aenderungen zu committen." }
  else {
    git commit -m "Daily update $today" *> $null
    git push origin main *> $null
    if ($LASTEXITCODE -eq 0) { Log "Commit + Push OK." } else { Log "Git-Push Exit-Code $LASTEXITCODE." }
  }
} catch { Log ("Git FEHLER: " + $_.Exception.Message) } finally { $ErrorActionPreference = $prevEAP }

Log "=== Lauf beendet ==="
