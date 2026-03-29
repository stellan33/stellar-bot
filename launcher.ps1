Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Show tray icon immediately so the user knows the app is loading
$notifyIcon         = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon    = [System.Drawing.SystemIcons]::Information
$notifyIcon.Text    = "Stellar Dev Services - Loading..."
$notifyIcon.Visible = $true
$notifyIcon.ShowBalloonTip(3000, "Stellar Dev Services", "Loading...", [System.Windows.Forms.ToolTipIcon]::Info)

# =============================================================================
# Paths
# =============================================================================
$BOT_DIR = "C:\Dev\stellar-bot"
$OV_EXE  = "C:\Users\andre\Anaconda3\envs\openviking\Scripts\openviking-server.exe"
$PYTHON  = "C:\Users\andre\Anaconda3\envs\openviking\python.exe"
$APP_DIR = "C:\Dev\Stellar_studio\app"

# =============================================================================
# Shared state
#   Q        - thread-safe output queue; entries = "KEY|0|text" or "KEY|1|text"
#   procs    - live Process objects keyed by service key
#   prev     - last known running state for transition detection
#   lblInfo  - info-strip Label per service (set during UI build, read in drain timer)
#   svcData  - live parsed data per service
# =============================================================================
$script:Q       = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:procs   = @{ OV = $null; BOT = $null; DEV = $null }
$script:prev    = @{ OV = $false; BOT = $false; DEV = $false }
$script:infoLabels = @{}
$script:svcData = @{
    OV  = @{ LastRX = "--:--:--"; LastTX = "--:--:--" }
    BOT = @{ Chan = ""; Snippet = "waiting for first message..."; LastTX = "--:--:--"; Busy = $false }
    DEV = @{ Local = "--"; Network = "--"; Build = "starting..." }
}

# =============================================================================
# Status detection
# =============================================================================
function Test-Port($port) {
    return $null -ne (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}
function Test-BotRunning {
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -like "*bot.py*") { return $true }
    }
    return $false
}

# =============================================================================
# Info-strip text builders (called from drain timer and Update-Status)
# =============================================================================
function Get-OvInfoText {
    $d = $script:svcData["OV"]
    return "last req: $($d.LastRX)   last resp: $($d.LastTX)   port: 1933"
}
function Get-BotInfoText {
    $d = $script:svcData["BOT"]
    $busy = if ($d.Busy) { "  [processing...]" } else { "" }
    $chan = if ($d.Chan) { "$($d.Chan): " } else { "" }
    return "$chan$($d.Snippet)$busy"
}
function Get-DevInfoText {
    $d = $script:svcData["DEV"]
    return "local: $($d.Local)   network: $($d.Network)   $($d.Build)"
}

function Refresh-InfoLabel($key) {
    $lbl = $script:infoLabels[$key]
    if (-not $lbl) { return }
    switch ($key) {
        "OV"  { $lbl.Text = Get-OvInfoText }
        "BOT" { $lbl.Text = Get-BotInfoText }
        "DEV" { $lbl.Text = Get-DevInfoText }
    }
}

# =============================================================================
# Managed process launcher
#   Starts a process with no window, redirects stdout/stderr into $script:Q
# =============================================================================
function New-ManagedProcess {
    param(
        [string]$exe,
        [string]$arguments,
        [string]$workDir,
        [hashtable]$extraEnv,
        [string]$svcKey
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $exe
    $psi.Arguments              = $arguments
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    if ($workDir) { $psi.WorkingDirectory = $workDir }

    if ($extraEnv) {
        foreach ($kv in $extraEnv.GetEnumerator()) {
            $psi.EnvironmentVariables.Remove($kv.Key)
            $psi.EnvironmentVariables.Add($kv.Key, $kv.Value)
        }
    }

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo          = $psi
    $p.EnableRaisingEvents = $true

    $q  = $script:Q
    $sk = $svcKey

    Register-ObjectEvent -InputObject $p -EventName OutputDataReceived `
        -MessageData @{ Q = $q; S = $sk } -Action {
        if ($EventArgs.Data) {
            $Event.MessageData.Q.Enqueue("$($Event.MessageData.S)|0|$($EventArgs.Data)")
        }
    } | Out-Null

    Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived `
        -MessageData @{ Q = $q; S = $sk } -Action {
        if ($EventArgs.Data) {
            $Event.MessageData.Q.Enqueue("$($Event.MessageData.S)|1|$($EventArgs.Data)")
        }
    } | Out-Null

    Register-ObjectEvent -InputObject $p -EventName Exited `
        -MessageData @{ Q = $q; S = $sk } -Action {
        $Event.MessageData.Q.Enqueue("$($Event.MessageData.S)|1|[process exited]")
    } | Out-Null

    $p.Start() | Out-Null
    $p.BeginOutputReadLine()
    $p.BeginErrorReadLine()
    return $p
}

# =============================================================================
# Start / Stop
# =============================================================================
function Start-OV {
    @(
        "C:\Dev\openviking_workspace\*.lock",
        "C:\Dev\openviking_workspace\viking\.lock",
        "C:\Dev\openviking_workspace\vectordb\context\store\LOCK",
        "C:\Dev\openviking_workspace\.openviking.pid"
    ) | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }

    $ovScripts = "C:\Users\andre\Anaconda3\envs\openviking\Scripts"
    $newPath   = "$ovScripts;" + [System.Environment]::GetEnvironmentVariable("PATH")

    # Reset info state
    $script:svcData["OV"].LastRX = "--:--:--"
    $script:svcData["OV"].LastTX = "--:--:--"
    Refresh-InfoLabel "OV"

    $script:procs["OV"] = New-ManagedProcess `
        -exe       $OV_EXE `
        -arguments "--bot --with-bot --bot-url http://localhost:18791" `
        -workDir   $null `
        -extraEnv  @{
            "PATH"                   = $newPath
            "OPENVIKING_CONFIG_FILE" = "$env:USERPROFILE\.openviking\ov.conf"
            "PYTHONUTF8"             = "1"
            "PYTHONIOENCODING"       = "utf-8"
        } `
        -svcKey "OV"
}

function Start-Bot {
    $script:svcData["BOT"].Snippet = "waiting for first message..."
    $script:svcData["BOT"].Chan    = ""
    $script:svcData["BOT"].LastTX  = "--:--:--"
    $script:svcData["BOT"].Busy    = $false
    Refresh-InfoLabel "BOT"

    $script:procs["BOT"] = New-ManagedProcess `
        -exe       $PYTHON `
        -arguments "bot.py" `
        -workDir   $BOT_DIR `
        -extraEnv  @{ "PYTHONUTF8" = "1"; "PYTHONIOENCODING" = "utf-8" } `
        -svcKey "BOT"
}

function Start-Dev {
    $script:svcData["DEV"].Local   = "--"
    $script:svcData["DEV"].Network = "--"
    $script:svcData["DEV"].Build   = "starting..."
    Refresh-InfoLabel "DEV"

    $script:procs["DEV"] = New-ManagedProcess `
        -exe       "cmd.exe" `
        -arguments "/c npm run dev" `
        -workDir   $APP_DIR `
        -extraEnv  $null `
        -svcKey "DEV"
}

function Stop-Managed($key) {
    $p = $script:procs[$key]
    if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
    $script:procs[$key] = $null
}

function Stop-OV {
    Stop-Managed "OV"
    Get-Process "openviking-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
function Stop-Bot {
    Stop-Managed "BOT"
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -like "*bot.py*") { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}
function Stop-Dev {
    Stop-Managed "DEV"
    $conn = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
    if ($conn) { Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue }
}

# =============================================================================
# Colors / Fonts
# =============================================================================
$DARK_BG    = [System.Drawing.Color]::FromArgb(28, 28, 28)
$DARK_ROW   = [System.Drawing.Color]::FromArgb(38, 38, 38)
$DARK_BTN   = [System.Drawing.Color]::FromArgb(55, 55, 55)
$DARK_BTN_R = [System.Drawing.Color]::FromArgb(100, 35, 35)
$GREEN      = [System.Drawing.Color]::FromArgb(80, 200, 100)
$RED        = [System.Drawing.Color]::FromArgb(210, 70, 70)
$GRAY       = [System.Drawing.Color]::FromArgb(130, 130, 130)
$WHITE      = [System.Drawing.Color]::FromArgb(230, 230, 230)
$CYAN       = [System.Drawing.Color]::FromArgb(100, 220, 220)
$YELLOW     = [System.Drawing.Color]::FromArgb(220, 200, 80)
$MAGENTA    = [System.Drawing.Color]::FromArgb(200, 130, 210)
$INFO_COLOR = [System.Drawing.Color]::FromArgb(190, 200, 215)

$FONT_UI   = New-Object System.Drawing.Font("Segoe UI", 9.5)
$FONT_BOLD = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$FONT_MONO = New-Object System.Drawing.Font("Consolas", 8.5)
$FONT_INFO = New-Object System.Drawing.Font("Consolas", 9)

$SVC_COLOR = @{ OV = $CYAN; BOT = $YELLOW; DEV = $MAGENTA }

# =============================================================================
# UI Helpers
# =============================================================================
function New-Label($text, $x, $y, $w, $h, $font = $FONT_UI, $color = $WHITE) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $text
    $l.Location  = New-Object System.Drawing.Point($x, $y)
    $l.Size      = New-Object System.Drawing.Size($w, $h)
    $l.AutoSize  = $false
    $l.Font      = $font
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}

function New-Btn($text, $x, $y, $w, $h, $bg = $DARK_BTN) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text     = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size     = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $b.FlatAppearance.BorderSize  = 1
    $b.BackColor = $bg
    $b.ForeColor = $WHITE
    $b.Font      = $FONT_UI
    $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
    return $b
}

# =============================================================================
# Form
# =============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Stellar Dev Services"
$form.Size            = New-Object System.Drawing.Size(510, 620)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false
$form.BackColor       = $DARK_BG

$lblTitle = New-Label "Stellar Dev Services" 15 14 280 28 $FONT_BOLD
$form.Controls.Add($lblTitle)

$div1 = New-Object System.Windows.Forms.Panel
$div1.Location  = New-Object System.Drawing.Point(0, 48)
$div1.Size      = New-Object System.Drawing.Size(510, 1)
$div1.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$form.Controls.Add($div1)

# =============================================================================
# Service rows
#   Each row has two lines:
#     Line 1 (y):    service name  |  status dot  |  Start / Stop / Restart
#     Line 2 (y+32): live info strip (URLs, timestamps, last message, etc.)
# =============================================================================
$services = @(
    @{ Key="OV";  Name="OpenViking"; Check={ Test-Port 1933 };  StartFn={ Start-OV };  StopFn={ Stop-OV } },
    @{ Key="BOT"; Name="Slack Bot";  Check={ Test-BotRunning }; StartFn={ Start-Bot }; StopFn={ Stop-Bot } },
    @{ Key="DEV"; Name="Dev Server"; Check={ Test-Port 3000 };  StartFn={ Start-Dev }; StopFn={ Stop-Dev } }
)

$rows  = @()
$yBase = 60
$rowH  = 76   # expanded to fit info strip

foreach ($i in 0..2) {
    $svc = $services[$i]
    $y   = $yBase + $i * $rowH

    # Panel is the parent — all controls are children of it, not the form.
    # This ensures z-order is never an issue (children always render above parent).
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location  = New-Object System.Drawing.Point(8, ($y - 4))
    $panel.Size      = New-Object System.Drawing.Size(476, 64)
    $panel.BackColor = $DARK_ROW

    # Coordinates below are panel-relative (panel origin = form 8, $y-4)
    # Line 1: name, status, buttons
    $lblName   = New-Label $svc.Name     4   4  110 22
    $lblStatus = New-Label "● checking" 114  4  140 22 $FONT_UI $GRAY
    $btnStart  = New-Btn "Start"        258  2   58 28
    $btnStop   = New-Btn "Stop"         322  2   58 28 $DARK_BTN_R
    $btnRst    = New-Btn "Restart"      386  2   76 28

    # Line 2: info strip
    $initText = switch ($svc.Key) {
        "OV"  { Get-OvInfoText }
        "BOT" { Get-BotInfoText }
        "DEV" { Get-DevInfoText }
    }
    $lblInfo = New-Label $initText 4 36 464 22 $FONT_INFO $INFO_COLOR

    $panel.Controls.AddRange(@($lblName, $lblStatus, $btnStart, $btnStop, $btnRst, $lblInfo))
    $form.Controls.Add($panel)

    $script:infoLabels[$svc.Key] = $lblInfo
    $rows += @{ Key=$svc.Key; Svc=$svc; LblStatus=$lblStatus; BtnStart=$btnStart; BtnStop=$btnStop; BtnRst=$btnRst }
}

# =============================================================================
# Divider + bottom buttons
# =============================================================================
$div2 = New-Object System.Windows.Forms.Panel
$div2.Location  = New-Object System.Drawing.Point(0, 292)
$div2.Size      = New-Object System.Drawing.Size(510, 1)
$div2.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$form.Controls.Add($div2)

$btnStartAll = New-Btn "> Start All"  10  302 130 32
$btnStopAll  = New-Btn "| Stop All"  148  302 130 32 $DARK_BTN_R
$btnRefresh  = New-Btn "~ Refresh"   358  302 130 32
$form.Controls.AddRange(@($btnStartAll, $btnStopAll, $btnRefresh))

$div3 = New-Object System.Windows.Forms.Panel
$div3.Location  = New-Object System.Drawing.Point(0, 345)
$div3.Size      = New-Object System.Drawing.Size(510, 1)
$div3.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$form.Controls.Add($div3)

# =============================================================================
# Log box
# =============================================================================
$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location    = New-Object System.Drawing.Point(10, 352)
$logBox.Size        = New-Object System.Drawing.Size(474, 230)
$logBox.BackColor   = [System.Drawing.Color]::FromArgb(18, 18, 18)
$logBox.ForeColor   = $GREEN
$logBox.ReadOnly    = $true
$logBox.Font        = $FONT_MONO
$logBox.BorderStyle = "None"
$logBox.ScrollBars  = "Vertical"
$form.Controls.Add($logBox)

# =============================================================================
# Logging helpers
# =============================================================================
function Log($msg, $color = $GREEN) {
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor  = $color
    $logBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $msg`n")
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.ScrollToCaret()
}

# =============================================================================
# NotifyIcon — update text now that UI is ready (created at top of script)
# =============================================================================
$notifyIcon.Text = "Stellar Dev Services"

function Show-Notification($title, $body) {
    $notifyIcon.ShowBalloonTip(4000, $title, $body, [System.Windows.Forms.ToolTipIcon]::Info)
}

# =============================================================================
# Status update — polls running state, fires notifications on transitions
# =============================================================================
function Update-Status {
    foreach ($row in $rows) {
        $key = $row.Key
        $up  = & $row.Svc.Check

        if ($up -and -not $script:prev[$key]) {
            Log "$($row.Svc.Name) is ready." $GREEN
            Show-Notification "Stellar Dev" "$($row.Svc.Name) is ready"
        } elseif (-not $up -and $script:prev[$key]) {
            Log "$($row.Svc.Name) stopped." $RED
        }
        $script:prev[$key] = $up

        if ($up) {
            $row.LblStatus.Text      = "● running"
            $row.LblStatus.ForeColor = $GREEN
            $row.BtnStart.Enabled    = $false
            $row.BtnStop.Enabled     = $true
            $row.BtnRst.Enabled      = $true
        } else {
            $row.LblStatus.Text      = "○ stopped"
            $row.LblStatus.ForeColor = $RED
            $row.BtnStart.Enabled    = $true
            $row.BtnStop.Enabled     = $false
            $row.BtnRst.Enabled      = $false
        }
    }
}

# =============================================================================
# Wire service-row buttons
# =============================================================================
foreach ($row in $rows) {
    $r = $row
    $r.BtnStart.Add_Click({
        Log "Starting $($r.Svc.Name)..." $GRAY
        & $r.Svc.StartFn
        Update-Status
    })
    $r.BtnStop.Add_Click({
        & $r.Svc.StopFn
        Log "Stopped $($r.Svc.Name)." $RED
        Update-Status
    })
    $r.BtnRst.Add_Click({
        Log "Restarting $($r.Svc.Name)..." $GRAY
        & $r.Svc.StopFn
        Start-Sleep -Milliseconds 800
        & $r.Svc.StartFn
        Update-Status
    })
}

# =============================================================================
# Wire bottom buttons
# =============================================================================
$btnStartAll.Add_Click({
    Log "Starting all services..." $GRAY
    Start-OV
    Log "Waiting for OpenViking on port 1933..." $GRAY
    $attempts = 0
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 500
        $attempts++
    } while (-not (Test-Port 1933) -and $attempts -lt 30)

    if (Test-Port 1933) {
        Start-Bot
        Start-Dev
    } else {
        Log "WARNING: OpenViking did not come up in time." $RED
    }
    Update-Status
})

$btnStopAll.Add_Click({
    Stop-Bot; Stop-Dev; Stop-OV
    Log "All services stopped." $RED
    Update-Status
})

$btnRefresh.Add_Click({
    Update-Status
    Log "Refreshed." $GRAY
})

# =============================================================================
# Drain timer (250ms)
#   Flushes $script:Q into the log box AND parses key patterns to update
#   the per-service info strips on each row.
#
#   OV  patterns: uvicorn HTTP request logs  ("POST /bot/v1/chat")
#   BOT patterns: [BOT RX] / [BOT TX] / [BOT BUSY] printed by bot.py
#   DEV patterns: Next.js startup output    ("Local:" / "Network:" / "Ready")
# =============================================================================
$drainTimer          = New-Object System.Windows.Forms.Timer
$drainTimer.Interval = 250
$drainTimer.Add_Tick({
    $item  = $null
    $count = 0
    while ($script:Q.TryDequeue([ref]$item) -and $count -lt 100) {
        $parts = $item.Split('|', 3)
        if ($parts.Count -lt 3) { $count++; continue }

        $svc   = $parts[0]
        $isErr = $parts[1] -eq '1'
        $text  = $parts[2] -replace '\x1b\[[0-9;]*[mGKHFABCDJsu]', ''  # strip ANSI

        if ([string]::IsNullOrWhiteSpace($text)) { $count++; continue }

        # ── Log box ──────────────────────────────────────────────────────────
        $color = if ($isErr) { $RED } else { $SVC_COLOR[$svc] }
        if (-not $color) { $color = $WHITE }
        $logBox.SelectionStart  = $logBox.TextLength
        $logBox.SelectionLength = 0
        $logBox.SelectionColor  = $color
        $logBox.AppendText("[$svc] $text`n")
        $count++

        # ── Info strip parsing ────────────────────────────────────────────────
        $infoChanged = $false

        switch ($svc) {

            "OV" {
                # Uvicorn/FastAPI HTTP request log: POST /bot/v1/chat ... 200 OK
                if ($text -match 'POST /bot/v1/chat') {
                    $script:svcData["OV"].LastRX = (Get-Date -Format 'HH:mm:ss')
                    $infoChanged = $true
                }
                if ($text -match '"POST /bot/v1/chat[^"]*" 2\d\d') {
                    $script:svcData["OV"].LastTX = (Get-Date -Format 'HH:mm:ss')
                    $infoChanged = $true
                }
            }

            "BOT" {
                # bot.py prints: [BOT RX] #channel | prompt snippet
                if ($text -match '^\[BOT RX\]\s+(\S+)\s*\|\s*(.+)') {
                    $script:svcData["BOT"].Chan    = $Matches[1]
                    $script:svcData["BOT"].Snippet = $Matches[2].Substring(0, [Math]::Min(55, $Matches[2].Length))
                    $script:svcData["BOT"].Busy    = $true
                    $infoChanged = $true
                }
                # bot.py prints: [BOT TX] #channel | N chars | elapsed
                if ($text -match '^\[BOT TX\]\s+\S+\s*\|\s*(.+)') {
                    $script:svcData["BOT"].LastTX = (Get-Date -Format 'HH:mm:ss')
                    $script:svcData["BOT"].Busy   = $false
                    $script:svcData["BOT"].Snippet = "sent $($Matches[1]) @ $($script:svcData['BOT'].LastTX)"
                    $infoChanged = $true
                }
                # bot.py connected line
                if ($text -match 'Waiting for messages') {
                    $script:svcData["BOT"].Snippet = "connected, waiting..."
                    $infoChanged = $true
                }
            }

            "DEV" {
                # Next.js startup: "  - Local:   http://localhost:3000"
                if ($text -match 'Local:\s+(https?://\S+)') {
                    $script:svcData["DEV"].Local = $Matches[1]
                    $infoChanged = $true
                }
                # Next.js startup: "  - Network: http://192.168.x.x:3000"
                if ($text -match 'Network:\s+(https?://\S+)') {
                    $script:svcData["DEV"].Network = $Matches[1]
                    $infoChanged = $true
                }
                # Ready
                if ($text -match 'Ready in') {
                    $script:svcData["DEV"].Build = "ready"
                    $infoChanged = $true
                }
                # Compiling
                if ($text -match 'Compil') {
                    $script:svcData["DEV"].Build = "compiling..."
                    $infoChanged = $true
                }
                # Compile complete
                if ($text -match 'compiled.*successfully|compiled client') {
                    $script:svcData["DEV"].Build = "compiled"
                    $infoChanged = $true
                }
            }
        }

        if ($infoChanged) { Refresh-InfoLabel $svc }
    }

    if ($count -gt 0) {
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.ScrollToCaret()
    }
})
$drainTimer.Start()

# =============================================================================
# Auto-refresh timer (8s)
# =============================================================================
$statusTimer          = New-Object System.Windows.Forms.Timer
$statusTimer.Interval = 8000
$statusTimer.Add_Tick({ Update-Status })
$statusTimer.Start()

# =============================================================================
# Cleanup on close
# =============================================================================
$form.Add_FormClosing({
    $statusTimer.Stop()
    $drainTimer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
})

# =============================================================================
# Launch
# =============================================================================
Update-Status
Log "Launcher ready.  [OV]=cyan  [BOT]=yellow  [DEV]=magenta  errors=red"
$notifyIcon.Text = "Stellar Dev Services - Ready"

[void]$form.ShowDialog()
