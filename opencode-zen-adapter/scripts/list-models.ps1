#Requires -Version 5.1
<#
  winoc2api - dynamic model lister

  Queries the LIVE gateway for available models. Nothing is hardcoded:
    - listen address + api key  -> read from config-oc2api.json
    - model list                -> GET /v1/models at runtime
    - per-model status          -> optional real probe (switch -Probe)

  Usage:
    ./list-models.ps1                     # list models from live gateway
    ./list-models.ps1 -Probe              # also send a real completion to each
    ./list-models.ps1 -Probe -Timeout 150 # lightning model needs ~100s
    ./list-models.ps1 -Probe -Retries 3   # transient 5xx/timeouts retried
    ./list-models.ps1 -Json               # machine-readable output
    ./list-models.ps1 -Prefix opec        # add 9router prefix column

  Probe semantics:
    4xx  -> deterministic, never retried  ("dead")
    5xx  -> transient, retried            (a 502 is not proof of death)
    200 with empty text -> 'empty'        (reasoning tokens ate the budget)
    max_tokens is fixed at 512: the provider rejects < 16, and reasoning
    models burn ~190 tokens before emitting any visible content.
#>
[CmdletBinding()]
param(
    [switch]$Probe,
    [switch]$Json,
    [int]$Timeout = 45,
    [int]$Retries = 2,
    [string]$Prefix = '',
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- resolve config (single source of truth for listen + key) ---
# Normal layout:  scripts\list-models.ps1  ->  ..\bin\config\config-oc2api.json
# Fallbacks keep a flat layout (config next to this script) working too.
if (-not $ConfigPath) {
    foreach ($cand in @(
        (Join-Path $here '..\bin\config\config-oc2api.json'),
        (Join-Path $here '..\config-oc2api.json'),
        (Join-Path $here 'config-oc2api.json'),
        (Join-Path $here 'config.json')
    )) {
        if (Test-Path $cand) { $ConfigPath = (Resolve-Path -LiteralPath $cand).Path; break }
    }
}
if (-not $ConfigPath -or -not (Test-Path $ConfigPath)) {
    Write-Output "ERROR: no gateway config file found."
    Write-Output "  looked in : $here\..\bin\config\   (and next to this script)"
    Write-Output "  expected  : bin\config\config-oc2api.json"
    Write-Output "  first run : copy bin\config\config.example.json -> bin\config\config-oc2api.json"
    exit 2
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$listen = if ($cfg.listen) { $cfg.listen } else { '127.0.0.1:20132' }
$base   = if ($listen -match '^https?:') { $listen } else { "http://$listen" }
$key    = if ($cfg.server_keys -and $cfg.server_keys.Count -gt 0) { $cfg.server_keys[0] } else { $null }

function Invoke-Gw {
    param([string]$Uri, [string]$Method = 'GET', [string]$Body = '', [int]$To = 20)
    $h = @{ 'Accept' = 'application/json' }
    if ($key) { $h['x-api-key'] = $key }
    if ($Method -ne 'GET' -and $Body) {
        $h['Content-Type'] = 'application/json'
        return Invoke-WebRequest -Uri $Uri -Method $Method -Headers $h -Body $Body `
                                 -UseBasicParsing -TimeoutSec $To
    }
    Invoke-WebRequest -Uri $Uri -Method $Method -Headers $h -UseBasicParsing -TimeoutSec $To
}

# --- 1. gateway up? ---
try { $hz = (Invoke-Gw "$base/healthz" -To 5).Content | ConvertFrom-Json }
catch {
    $msg = "GATEWAY DOWN at $base"
    if ($Json) { @{ gateway = $false; base = $base; config = $ConfigPath; error = "$_" } | ConvertTo-Json -Depth 5 }
    else       { Write-Output $msg; Write-Output "Run: LAUNCHER.bat start   (skill folder root)" }
    exit 1
}

# --- 2. live model list ---
try { $models = ((Invoke-Gw "$base/v1/models" -To 15).Content | ConvertFrom-Json).data.id }
catch {
    if ($Json) { @{ gateway = $true; base = $base; config = $ConfigPath; error = "$_" } | ConvertTo-Json -Depth 5 }
    else       { Write-Output "ERROR: /v1/models failed: $_" }
    exit 1
}
$models = @($models | Sort-Object)

# --- 3. optional real probe ---
$rows = foreach ($m in $models) {
    $row = [ordered]@{
        model  = $m
        route  = if ($Prefix) { "$Prefix/$m" } else { $m }
        status = 'untested'
        ms     = $null
        note   = ''
    }
    if ($Probe) {
        # Retry policy: 4xx = deterministic client/upstream rejection, never retried.
        # 5xx / timeout / transport error = transient, retried so a single blip is not
        # misreported as "dead" (observed: nemotron-3-ultra 502 then OK on retry).
        $attempt = 0
        $maxTry = 1 + [Math]::Max(0, $Retries)
        while ($true) {
            $attempt++
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                # max_tokens MUST be >= 16 (provider rejects lower) and large enough to
                # survive reasoning-token burn: muse-spark burns ~190 reasoning tokens
                # before emitting visible content, so a small budget yields empty output.
                $b = @{ model = $m; messages = @(@{ role = 'user'; content = 'Say the word OK.' }); max_tokens = 512 } | ConvertTo-Json -Depth 6
                $respBody = (Invoke-Gw "$base/v1/chat/completions" -Method POST -Body $b -To $Timeout).Content
                $sw.Stop()
                $row.ms = [int]$sw.ElapsedMilliseconds
                $text = ''
                try { $text = "$((($respBody | ConvertFrom-Json).choices[0].message.content))" } catch {}
                if ($text.Trim().Length -gt 0) {
                    $row.status = 'ok'
                    $row.note   = ($text -replace '\s+', ' ').Trim()
                    if ($row.note.Length -gt 40) { $row.note = $row.note.Substring(0, 40) + '...' }
                    if ($attempt -gt 1) { $row.note = "$($row.note) (attempt $attempt)" }
                }
                else {
                    # HTTP 200 but no visible text = reasoning ate the budget
                    $row.status = 'empty'
                    $row.note   = '200 but empty content (reasoning overflow?)'
                }
                break
            }
            catch {
                $sw.Stop()
                $elapsed = [int]$sw.ElapsedMilliseconds
                $resp = $_.Exception.Response
                $isTimeout = -not $resp -and ("$_" -match 'timed out|Timeout')

                if ($resp) {
                    $code = [int]$resp.StatusCode
                    $body = ''
                    try {
                        $stream = $resp.GetResponseStream()
                        if ($stream -and $stream.CanSeek) { $stream.Position = 0 }
                        $sr = New-Object System.IO.StreamReader($stream)
                        $body = $sr.ReadToEnd()
                        $sr.Close()
                    }
                    catch {}

                    $note = $null
                    if ($body) {
                        try {
                            $j = $body | ConvertFrom-Json
                            if ($j -and $j.error -and $j.error.message) { $note = $j.error.message }
                            elseif ($j -and $j.message)                 { $note = $j.message }
                            else                                        { $note = $body }
                        }
                        catch { $note = $body }
                    }
                    if (-not $note) { $note = '(empty error body)' }

                    $transient = ($code -ge 500)
                    if ($transient -and $attempt -lt $maxTry) {
                        Start-Sleep -Seconds 1
                        continue
                    }

                    $row.status = "$code"
                    $row.note   = "$note"
                    if ($row.note.Length -gt 90) { $row.note = $row.note.Substring(0, 90) + '...' }
                    if ($attempt -gt 1) { $row.note = "$($row.note) [after $attempt attempts]" }
                    $row.ms = $elapsed
                    break
                }
                elseif ($isTimeout) {
                    if ($attempt -lt $maxTry) { Start-Sleep -Seconds 1; continue }
                    $row.status = 'timeout'
                    $row.note   = "no response in ${Timeout}s [after $attempt attempts]"
                    $row.ms     = $elapsed
                    break
                }
                else {
                    $msg = "$_"
                    if ($attempt -lt $maxTry) { Start-Sleep -Seconds 1; continue }
                    $row.status = 'error'
                    $row.note   = $msg.Substring(0, [Math]::Min(90, $msg.Length))
                    $row.ms     = $elapsed
                    break
                }
            }
        }
    }
    [pscustomobject]$row
}

# --- 4. output ---
$okCount    = @($rows | Where-Object { $_.status -eq 'ok' }).Count
$emptyCount = @($rows | Where-Object { $_.status -eq 'empty' }).Count
$untested   = @($rows | Where-Object { $_.status -eq 'untested' }).Count
# only count real failures; 'untested' (no -Probe) is not a failure
$failCount  = @($rows | Where-Object { $_.status -ne 'ok' -and $_.status -ne 'empty' -and $_.status -ne 'untested' }).Count
$badStatus  = $rows | Where-Object { $_.status -ne 'ok' -and $_.status -ne 'empty' -and $_.status -ne 'untested' } |
              Group-Object status | Sort-Object Count -Descending

if ($Json) {
    [ordered]@{
        gateway    = $true
        base       = $base
        config     = $ConfigPath
        refreshed  = $hz.models.last_refresh
        stale      = $hz.models.stale
        upstream   = $hz.models.total
        exposed    = $hz.models.exposed
        probed     = [bool]$Probe
        ok         = $okCount
        empty      = $emptyCount
        failed     = $failCount
        models     = $rows
    } | ConvertTo-Json -Depth 6
}
else {
    Write-Output ""
    Write-Output "Gateway : $base   (up=$($hz.status), upstream=$($hz.models.total), exposed=$($hz.models.exposed))"
    Write-Output "Config  : $ConfigPath"
    Write-Output "Refresh : $($hz.models.last_refresh)  stale=$($hz.models.stale)"
    Write-Output ""
    if ($Probe) {
        Write-Output ("{0,-38} {1,-10} {2,-8} {3}" -f 'MODEL', 'STATUS', 'MS', 'NOTE')
        Write-Output ("-" * 100)
        foreach ($r in $rows) { Write-Output ("{0,-38} {1,-10} {2,-8} {3}" -f $r.model, $r.status, $r.ms, $r.note) }
        Write-Output ""
        Write-Output "RESULT: $okCount OK / $emptyCount empty / $failCount failed   (of $($rows.Count) exposed)"
        if ($badStatus) {
            foreach ($g in $badStatus) { Write-Output ("  {0,-10} x{1,-3} {2}" -f $g.Name, $g.Count, (($g.Group.model) -join ', ')) }
        }
    }
    else {
        foreach ($r in $rows) { Write-Output ("  " + $r.route) }
        Write-Output ""
        Write-Output "RESULT: $($rows.Count) models exposed. Add -Probe to test each one."
    }
    Write-Output ""
}
