<#
    winoc2api :: control panel for the local opencode2api adapter gateway
    ---------------------------------------------------------------
    ONE engine behind the skill's single entry point.

    From the skill folder root:

        LAUNCHER.bat              interactive panel + menu
        LAUNCHER.bat start        start, wait until ready
        LAUNCHER.bat stop         force stop
        LAUNCHER.bat restart      stop, then start
        LAUNCHER.bat status       print the status panel, exit
        LAUNCHER.bat models       live model list
        LAUNCHER.bat probe        live model list + probe every model
        LAUNCHER.bat logs         tail the runtime logs

    Standalone (repo cloned on its own, no LAUNCHER.bat):

        powershell -NoProfile -ExecutionPolicy Bypass -File scripts\adapter.ps1 [command]

    Colours come from Write-Host -ForegroundColor (the console API), never
    from raw ANSI escapes, so they render the same in conhost and in
    Windows Terminal.
#>
param(
    [Parameter(Position = 0)]
    [string]$Command = ''
)

# ------------------------------------------------------------------ paths
$Scripts = $PSScriptRoot
$Repo    = Split-Path -Parent $Scripts
$Leaf    = Split-Path -Leaf   $Repo
$ExePath = Join-Path $Repo 'bin\opencode2api.exe'
$CfgPath = Join-Path $Repo 'bin\config\config-oc2api.json'
$LogDir  = Join-Path $Repo 'logs'
$OutLog  = Join-Path $LogDir 'winoc2api.out.log'
$ErrLog  = Join-Path $LogDir 'winoc2api.err.log'
$Lister  = Join-Path $Scripts 'list-models.ps1'

$RelExe = $Leaf + '\bin\opencode2api.exe'
$RelCfg = $Leaf + '\bin\config\config-oc2api.json'
$RelLog = $Leaf + '\logs\winoc2api.out.log'
$RelErr = $Leaf + '\logs\winoc2api.err.log'

$Inner  = 70      # box content width
$LabelW = 13      # status label column

# -------------------------------------------------------- box characters
$TL  = [string][char]0x2554   # ╔
$TR  = [string][char]0x2557   # ╗
$ML  = [string][char]0x2560   # ╠
$MR  = [string][char]0x2563   # ╣
$BL  = [string][char]0x255A   # ╚
$BR  = [string][char]0x255D   # ╝
$VB  = [string][char]0x2551   # ║
$HB  = [string][char]0x2550   # ═
$TH  = [string][char]0x2500   # ─
$Dot = [string][char]0x00B7   # ·

# ----------------------------------------------------------------- colours
$Border = [ConsoleColor]::DarkCyan
$TitleC = [ConsoleColor]::Cyan
$LabelC = [ConsoleColor]::DarkGray
$ValueC = [ConsoleColor]::Gray
$GoodC  = [ConsoleColor]::Green
$WarnC  = [ConsoleColor]::Yellow
$BadC   = [ConsoleColor]::Red
$KeyC   = [ConsoleColor]::Yellow
$HeadC  = [ConsoleColor]::Cyan

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { $Host.UI.RawUI.WindowTitle = 'winoc2api  |  opencode2api adapter  |  127.0.0.1:20132' } catch { }

# ---------------------------------------------------------------- helpers
function Test-TcpPort {
    param([string]$HostName, [int]$Port)
    $c = $null
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect($HostName, $Port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne(500, $false)
        if ($ok -and $c.Connected) { $c.EndConnect($ar); return $true }
        return $false
    } catch { return $false }
    finally { if ($c) { try { $c.Close() } catch { } } }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ($Bytes.ToString() + ' B')
}

function Write-Note {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host ('  ' + $Text) -ForegroundColor $Color
}

function Write-BoxBar {
    param([string]$Left, [string]$Right)
    $bar = $HB * ($Inner + 2)
    Write-Host ('  ' + $Left + $bar + $Right) -ForegroundColor $Border
}

function Write-BoxTitle {
    param([string]$Text)
    if ($Text.Length -gt $Inner) { $Text = $Text.Substring(0, $Inner) }
    $l = [int][Math]::Floor(($Inner - $Text.Length) / 2)
    $r = $Inner - $Text.Length - $l
    $padL = ' ' * $l
    $padR = ' ' * $r
    Write-Host -NoNewline ('  ' + $VB + ' ') -ForegroundColor $Border
    Write-Host -NoNewline ($padL + $Text + $padR) -ForegroundColor $TitleC
    Write-Host (' ' + $VB) -ForegroundColor $Border
}

function Write-BoxRow {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$ValueColor = [ConsoleColor]::Gray
    )
    $maxV = $Inner - $LabelW
    if ($Value.Length -gt $maxV) { $Value = $Value.Substring(0, $maxV) }
    $pad = $Inner - $LabelW - $Value.Length
    $head = '  ' + $VB + ' '
    $lab  = $Label.PadRight($LabelW)
    Write-Host -NoNewline $head -ForegroundColor $Border
    Write-Host -NoNewline $lab  -ForegroundColor $LabelC
    Write-Host -NoNewline $Value -ForegroundColor $ValueColor
    if ($pad -gt 0) { Write-Host -NoNewline (' ' * $pad) -ForegroundColor $ValueColor }
    Write-Host (' ' + $VB) -ForegroundColor $Border
}

function Write-BoxRule {
    $head = '  ' + $VB + ' '
    $gap  = ' ' * 4
    $rule = $TH * ($Inner - 4)
    Write-Host -NoNewline $head -ForegroundColor $Border
    Write-Host -NoNewline $gap  -ForegroundColor $Border
    Write-Host -NoNewline $rule -ForegroundColor $Border
    Write-Host (' ' + $VB) -ForegroundColor $Border
}

# ------------------------------------------------------------------ state
function Get-AdapterState {
    $s = @{}
    $s.Running    = $false
    $s.Pid        = $null
    $s.Health     = $null
    $s.ExePresent = Test-Path -LiteralPath $ExePath
    $s.CfgExists  = Test-Path -LiteralPath $CfgPath
    $s.Listen     = '127.0.0.1:20132'
    $s.Upstream   = 'https://opencode.ai/zen'
    $s.KeyCount   = 0
    $s.Keys       = @()
    $s.OutSize    = 0

    $p = Get-Process -Name 'opencode2api' -ErrorAction SilentlyContinue
    if ($p) { $s.Running = $true; $s.Pid = (@($p)[0]).Id }

    if ($s.CfgExists) {
        try {
            $cfg = Get-Content -LiteralPath $CfgPath -Raw | ConvertFrom-Json
            if ($cfg.listen)                          { $s.Listen   = [string]$cfg.listen }
            if ($cfg.upstream -and $cfg.upstream.zen) { $s.Upstream = [string]$cfg.upstream.zen }
            if ($cfg.server_keys) {
                $s.Keys     = @( @($cfg.server_keys) | ForEach-Object { [string]$_ } )
                $s.KeyCount = $s.Keys.Count
            }
        } catch { }
    }

    if ($s.Listen -match '^https?://') { $s.Base = $s.Listen } else { $s.Base = 'http://' + $s.Listen }

    try {
        $r = Invoke-WebRequest -Uri ($s.Base + '/healthz') -UseBasicParsing -TimeoutSec 4
        $s.Health = $r.Content | ConvertFrom-Json
    } catch { $s.Health = $null }

    $s.NineRouter = Test-TcpPort -HostName '127.0.0.1' -Port 20128

    if (Test-Path -LiteralPath $OutLog) {
        try { $s.OutSize = (Get-Item -LiteralPath $OutLog).Length } catch { $s.OutSize = 0 }
    }
    return $s
}

function Test-Ready {
    # fast health probe used while polling after a start
    param([string]$Base)
    try {
        $r = Invoke-WebRequest -Uri ($Base + '/healthz') -UseBasicParsing -TimeoutSec 3
        $h = $r.Content | ConvertFrom-Json
        if ($h.ready) { return $true }
    } catch { }
    return $false
}

# -------------------------------------------------------------- rendering
function Write-StatusPanel {
    $s = Get-AdapterState

    $listenShort = ($s.Listen -replace '^https?://', '')
    $ver     = '?'
    $exposed = $null
    $total   = $null
    $refresh = $null
    $stale   = $null
    $proxyH  = $null
    $proxyT  = $null

    if ($s.Health) {
        try {
            if ($s.Health.version) { $ver = [string]$s.Health.version }
            if ($s.Health.models) {
                $exposed = $s.Health.models.exposed
                $total   = $s.Health.models.total
                $refresh = $s.Health.models.last_refresh
                $stale   = $s.Health.models.stale
            }
            if ($s.Health.proxies) { $proxyH = $s.Health.proxies.healthy; $proxyT = $s.Health.proxies.total }
        } catch { }
    }

    Write-BoxBar $TL $TR
    $mid = 'opencode2api'
    if ($ver -ne '?') { $mid = 'opencode2api ' + $ver }
    $title = 'WINOC2API   ' + $Dot + '   ' + $mid + '   ' + $Dot + '   ' + $listenShort
    Write-BoxTitle $title
    Write-BoxBar $ML $MR

    # --- status -------------------------------------------------------
    if ($s.Running -and $s.Health -and $s.Health.ready) {
        $v = 'RUNNING ' + $Dot + ' pid ' + $s.Pid
        Write-BoxRow 'Status' $v $GoodC
    } elseif ($s.Running) {
        $v = 'RUNNING ' + $Dot + ' pid ' + $s.Pid + '   (starting / not ready)'
        Write-BoxRow 'Status' $v $WarnC
    } elseif ($s.Health) {
        Write-BoxRow 'Status' 'STOPPED   port still answering - foreign process?' $WarnC
    } else {
        Write-BoxRow 'Status' 'STOPPED' $BadC
    }

    if ($s.Health -and $s.Health.ready) {
        Write-BoxRow 'Health' ('ok ' + $Dot + ' ready') $GoodC
    } elseif ($s.Health) {
        Write-BoxRow 'Health' 'responding, ready=false' $WarnC
    } elseif ($s.Running) {
        Write-BoxRow 'Health' 'unreachable - alive but silent' $BadC
    } else {
        Write-BoxRow 'Health' 'not running' $LabelC
    }

    Write-BoxRow 'Endpoint' $s.Base $ValueC

    # --- models -------------------------------------------------------
    if ($null -ne $exposed) {
        $mv  = $exposed.ToString() + ' exposed / ' + $total.ToString() + ' upstream'
        $mc  = $GoodC
        if ([int]$exposed -eq 0) { $mc = $BadC }
        Write-BoxRow 'Models' $mv $mc
    } else {
        Write-BoxRow 'Models' '-' $LabelC
    }

    if ($refresh) {
        try { $t = ([datetime]::Parse([string]$refresh)).ToUniversalTime().ToString('HH:mm:ss') + 'Z' }
        catch { $t = [string]$refresh }
        if ($stale) { Write-BoxRow 'Refresh' ($t + '   STALE') $WarnC }
        else        { Write-BoxRow 'Refresh' ($t + '   fresh')  $GoodC }
    } else {
        Write-BoxRow 'Refresh' '-' $LabelC
    }

    $upHost = ($s.Upstream -replace '^https?://', '')
    if ($null -ne $proxyH) {
        $uv = $upHost + ' ' + $Dot + ' proxy ' + $proxyH.ToString() + '/' + $proxyT.ToString() + ' healthy'
        Write-BoxRow 'Upstream' $uv $ValueC
    } else {
        Write-BoxRow 'Upstream' $upHost $LabelC
    }

    if ($s.KeyCount -gt 0) {
        # key(s) read live from config at runtime - never hardcoded in this file
        $keyList = @($s.Keys)
        if ($keyList.Count -gt 0 -and $keyList[0]) {
            Write-BoxRow 'Auth' ($keyList[0] + '   ' + $Dot + ' key required') $WarnC
            for ($i = 1; $i -lt $keyList.Count; $i++) {
                if ($keyList[$i]) { Write-BoxRow '' $keyList[$i] $WarnC }
            }
        } else {
            Write-BoxRow 'Auth' ('<key set - config unreadable>   ' + $Dot + ' key required') $WarnC
        }
    } else {
        Write-BoxRow 'Auth' 'no key required (anonymous)' $GoodC
    }

    if ($s.NineRouter) {
        $nv = 'CONNECTED  127.0.0.1:20128 ' + $Dot + ' prefix opec'
        Write-BoxRow '9router' $nv $GoodC
    } else {
        Write-BoxRow '9router' 'offline    127.0.0.1:20128' $LabelC
    }

    Write-BoxRule

    # --- files --------------------------------------------------------
    if ($s.ExePresent) {
        Write-BoxRow 'Gateway' $RelExe $ValueC
    } else {
        Write-BoxRow 'Gateway' ($RelExe + '   [MISSING - gitignored]') $BadC
    }

    if ($s.CfgExists) {
        Write-BoxRow 'Config' $RelCfg $ValueC
    } else {
        Write-BoxRow 'Config' ($RelCfg + '   [copy the example first]') $BadC
    }

    if ($s.OutSize -gt 0) {
        $lv = $RelLog + '  (' + (Format-Size $s.OutSize) + ')'
        Write-BoxRow 'Log' $lv $ValueC
    } else {
        Write-BoxRow 'Log' ($RelLog + '  (empty)') $LabelC
    }

    Write-BoxBar $BL $BR
}

function Write-ActionMenu {
    $items = @(
        @{ K = '1'; T = 'Start adapter' },
        @{ K = '2'; T = 'Stop adapter' },
        @{ K = '3'; T = 'Restart' },
        @{ K = '4'; T = 'List models' },
        @{ K = '5'; T = 'Probe models' },
        @{ K = '6'; T = 'Tail logs' },
        @{ K = '7'; T = 'Open config' },
        @{ K = '8'; T = 'Open docs' },
        @{ K = '0'; T = 'Exit' }
    )

    Write-BoxBar $TL $TR

    $head = 'ACTIONS'
    $hp   = ' ' * ($Inner - $head.Length)
    $pfx  = '  ' + $VB + ' '
    Write-Host -NoNewline $pfx -ForegroundColor $Border
    Write-Host -NoNewline $head -ForegroundColor $HeadC
    Write-Host -NoNewline $hp   -ForegroundColor $Border
    Write-Host (' ' + $VB) -ForegroundColor $Border

    Write-BoxBar $ML $MR

    for ($i = 0; $i -lt $items.Count; $i += 3) {
        Write-Host -NoNewline $pfx -ForegroundColor $Border
        Write-Host -NoNewline (' ' * 4) -ForegroundColor $Border
        for ($j = $i; $j -lt ($i + 3); $j++) {
            $it = $items[$j]
            $key = '[' + $it.K + '] '
            Write-Host -NoNewline $key -ForegroundColor $KeyC
            Write-Host -NoNewline $it.T.PadRight(18) -ForegroundColor $ValueC
        }
        Write-Host (' ' + $VB) -ForegroundColor $Border
    }

    Write-BoxBar $BL $BR
}

# ---------------------------------------------------------------- actions
function Invoke-Start {
    $s = Get-AdapterState

    if ($s.Running) {
        $m = '[OK] already running (pid ' + $s.Pid + ') - nothing to do.'
        Write-Note $m $GoodC
        return
    }
    if (-not $s.ExePresent) {
        Write-Note ('[FAIL] gateway binary missing: ' + $RelExe) $BadC
        Write-Note '       it is gitignored - drop opencode2api.exe into bin\' $LabelC
        return
    }
    if (-not $s.CfgExists) {
        Write-Note ('[FAIL] config missing: ' + $RelCfg) $BadC
        Write-Note '       copy bin\config\config.example.json -> bin\config\config-oc2api.json' $LabelC
        return
    }

    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

    $argList = @('-config', ('"' + $CfgPath + '"'))
    $wd      = Join-Path $Repo 'bin'
    $sp = @{
        FilePath              = $ExePath
        ArgumentList          = $argList
        WorkingDirectory      = $wd
        WindowStyle           = 'Hidden'
        RedirectStandardOutput = $OutLog
        RedirectStandardError  = $ErrLog
    }
    Start-Process @sp

    $base = $s.Base
    Write-Host -NoNewline '  [*] starting gateway' -ForegroundColor $ValueC
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 600
        if (Test-Ready $base) {
            Write-Host '  OK' -ForegroundColor $GoodC
            return
        }
        if (($i % 5) -eq 4) { Write-Host -NoNewline '.' -ForegroundColor $LabelC }
    }
    Write-Host '  TIMEOUT' -ForegroundColor $BadC

    Write-Note '    last log lines:' $WarnC
    foreach ($f in @($ErrLog, $OutLog)) {
        if (Test-Path -LiteralPath $f) {
            try {
                $lines = Get-Content -LiteralPath $f -Tail 8 -ErrorAction Stop
                foreach ($ln in $lines) { Write-Host ('      ' + $ln) -ForegroundColor $LabelC }
            } catch {
                Write-Note ('      (cannot read ' + $f + ' while the gateway holds it)') $LabelC
            }
        }
    }
}

function Invoke-Stop {
    $p = Get-Process -Name 'opencode2api' -ErrorAction SilentlyContinue
    if (-not $p) {
        Write-Note '[OK] not running - nothing to do.' $LabelC
        return
    }
    $ids = (@($p) | ForEach-Object { $_.Id }) -join ', '
    $p | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        if (-not (Get-Process -Name 'opencode2api' -ErrorAction SilentlyContinue)) { break }
    }
    if (Get-Process -Name 'opencode2api' -ErrorAction SilentlyContinue) {
        Write-Note ('[FAIL] pid ' + $ids + ' still alive') $BadC
    } else {
        Write-Note ('[OK] stopped pid ' + $ids) $GoodC
    }
}

function Invoke-Restart {
    Invoke-Stop
    Start-Sleep -Seconds 1
    Write-Host ''
    Invoke-Start
}

function Invoke-Lister {
    param([switch]$Probe)
    Clear-Host
    Write-Host -NoNewline '  winoc2api  ::  ' -ForegroundColor $TitleC
    if ($Probe) { Write-Host 'probe every model (live truth)' -ForegroundColor $ValueC }
    else        { Write-Host 'live model list (never hardcoded)' -ForegroundColor $ValueC }
    $rule = '  ' + ($TH * $Inner)
    Write-Host $rule -ForegroundColor $Border
    Write-Host ''

    if (-not (Test-Path -LiteralPath $Lister)) {
        Write-Note ('[FAIL] list-models.ps1 not found: ' + $Lister) $BadC
        return
    }
    if ($Probe) { & $Lister -Probe -Timeout 150 -Retries 2 }
    else        { & $Lister }

    Write-Host ''
    Write-Host $rule -ForegroundColor $Border
}

function Show-LogTail {
    param([string]$Path, [string]$Name, [int]$Tail, [ConsoleColor]$Base)
    Write-Note $Name $HeadC
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Note '      (file not found yet)' $LabelC
        return
    }
    try { $lines = Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop }
    catch {
        Write-Note '      (file is held open by the running gateway - stop it to read)' $WarnC
        return
    }
    if (-not $lines) { Write-Note '      (empty)' $LabelC; return }
    foreach ($ln in $lines) {
        $c = $Base
        if ($ln -match 'error|ERROR|fail|FAIL') { $c = $BadC }
        elseif ($ln -match 'warn|WARN')         { $c = $WarnC }
        elseif ($ln -match 'ready|models|refresh') { $c = $GoodC }
        Write-Host ('      ' + $ln) -ForegroundColor $c
    }
}

function Invoke-Logs {
    Clear-Host
    Write-Host -NoNewline '  winoc2api  ::  ' -ForegroundColor $TitleC
    Write-Host 'runtime log tail' -ForegroundColor $ValueC
    $rule = '  ' + ($TH * $Inner)
    Write-Host $rule -ForegroundColor $Border

    if (-not (Test-Path -LiteralPath $OutLog) -and -not (Test-Path -LiteralPath $ErrLog)) {
        Write-Host ''
        Write-Note 'no logs yet - start the gateway first (option 1).' $LabelC
        return
    }

    Write-Host ''
    Show-LogTail -Path $ErrLog -Name ('stderr  ' + $RelErr) -Tail 20 -Base $LabelC
    Write-Host ''
    Show-LogTail -Path $OutLog -Name ('stdout  ' + $RelLog) -Tail 45 -Base $ValueC
    Write-Host ''
    Write-Host $rule -ForegroundColor $Border
}

function Open-Folder {
    param([string]$Path, [string]$What)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Note ('[FAIL] ' + $What + ' not found: ' + $Path) $BadC
        return
    }
    try {
        $arg = '"' + $Path + '"'
        Start-Process explorer.exe -ArgumentList $arg | Out-Null
        Write-Note ('[OK] opened ' + $What) $GoodC
    } catch {
        Write-Note ('[FAIL] could not open ' + $What) $BadC
    }
}

function Show-Usage {
    Write-Host ''
    Write-Host '  winoc2api  ::  opencode2api adapter control panel' -ForegroundColor $TitleC
    Write-Host ''
    Write-Host '  usage:' -ForegroundColor $HeadC
    Write-Host '      LAUNCHER.bat                 interactive panel + menu' -ForegroundColor $ValueC
    Write-Host '      LAUNCHER.bat start           start, wait until ready' -ForegroundColor $ValueC
    Write-Host '      LAUNCHER.bat stop            force stop' -ForegroundColor $ValueC
    Write-Host '      LAUNCHER.bat restart         stop, then start' -ForegroundColor $ValueC
    Write-Host '      LAUNCHER.bat status          print the status panel, exit' -ForegroundColor $ValueC
    Write-Host '      LAUNCHER.bat models          live model list' -ForegroundColor $ValueC
    Write-Host '      LAUNCHER.bat probe           live model list + probe every model' -ForegroundColor $ValueC
    Write-Host '      LAUNCHER.bat logs            tail the runtime logs' -ForegroundColor $ValueC
    Write-Host '      LAUNCHER.bat open-config     open bin\config in Explorer' -ForegroundColor $ValueC
    Write-Host '      LAUNCHER.bat open-docs       open docs in Explorer' -ForegroundColor $ValueC
    Write-Host ''
    Write-Host '  unknown command:' -ForegroundColor $BadC
    Write-Host ('      ' + $Command) -ForegroundColor $ValueC
    Write-Host ''
}

# ------------------------------------------------------------------- main
$cmd = ''
if ($Command) { $cmd = $Command.Trim().ToLower() }

switch ($cmd) {
    'start'       { Invoke-Start; exit 0 }
    'stop'        { Invoke-Stop;  exit 0 }
    'restart'     { Invoke-Restart; exit 0 }
    'status'      { Write-StatusPanel; exit 0 }
    'models'      { Invoke-Lister; exit 0 }
    'probe'       { Invoke-Lister -Probe; exit 0 }
    'logs'        { Invoke-Logs; exit 0 }
    'open-config' { Open-Folder -Path (Join-Path $Repo 'bin\config') -What 'config folder'; exit 0 }
    'open-docs'   { Open-Folder -Path (Join-Path $Repo 'docs')       -What 'docs folder';   exit 0 }
    ''            { }
    default       { Show-Usage; exit 2 }
}

# interactive loop
while ($true) {
    Clear-Host
    Write-StatusPanel
    Write-ActionMenu

    Write-Host ''
    $tip = '  tip: LAUNCHER.bat start | stop | restart | status | models | probe | logs'
    Write-Host $tip -ForegroundColor $LabelC
    Write-Host -NoNewline '  Select [0-8] > ' -ForegroundColor $TitleC

    $choice = Read-Host
    if ($null -eq $choice) { break }
    $choice = $choice.Trim()

    if ($choice -eq '0') { exit 0 }
    if ($choice -eq '')  { continue }

    Write-Host ''
    switch ($choice) {
        '1' { Invoke-Start }
        '2' { Invoke-Stop }
        '3' { Invoke-Restart }
        '4' { Invoke-Lister }
        '5' { Invoke-Lister -Probe }
        '6' { Invoke-Logs }
        '7' { Open-Folder -Path (Join-Path $Repo 'bin\config') -What 'config folder' }
        '8' { Open-Folder -Path (Join-Path $Repo 'docs')       -What 'docs folder' }
        default {
            $m = "unknown option '" + $choice + "'  (choose 0-8)"
            Write-Note $m $BadC
        }
    }

    # options 4/5/6 already cleared the screen for their own view
    if ($choice -eq '4' -or $choice -eq '5' -or $choice -eq '6') {
        Write-Host ''
        Write-Host '  Press ENTER to return to the panel ...' -ForegroundColor $LabelC
        $null = Read-Host
        continue
    }

    Write-Host ''
    Write-Host '  Press ENTER to refresh the panel ...' -ForegroundColor $LabelC
    $null = Read-Host
}
