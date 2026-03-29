Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# =============================================================================
# Paths
# =============================================================================
$BOT_DIR  = "C:\Dev\stellar-bot"
$OV_EXE   = "C:\Users\andre\Anaconda3\envs\openviking\Scripts\openviking-server.exe"
$PYTHON   = "C:\Users\andre\Anaconda3\envs\openviking\python.exe"

# =============================================================================
# Status detection
# =============================================================================
function Test-Port($port) {
    return $null -ne (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

function Test-BotRunning {
    foreach ($p in (Get-WmiObject Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -like "*bot.py*") { return $true }
    }
    return $false
}

# =============================================================================
# Start / Stop
# =============================================================================
function Start-OV  { Start-Process "cmd.exe" -ArgumentList "/k `"$BOT_DIR\start-openviking.bat`"" }
function Start-Bot { Start-Process "cmd.exe" -ArgumentList "/k `"$BOT_DIR\start-bot.bat`"" }
function Start-Dev { Start-Process "cmd.exe" -ArgumentList "/k `"$BOT_DIR\start-dev-server.bat`"" }

function Stop-OV {
    Get-Process "openviking-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
function Stop-Bot {
    foreach ($p in (Get-WmiObject Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -like "*bot.py*") { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}
function Stop-Dev {
    $conn = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
    if ($conn) { Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue }
}

# =============================================================================
# UI Helpers
# =============================================================================
$DARK_BG    = [System.Drawing.Color]::FromArgb(28, 28, 28)
$DARK_ROW   = [System.Drawing.Color]::FromArgb(38, 38, 38)
$DARK_BTN   = [System.Drawing.Color]::FromArgb(55, 55, 55)
$DARK_BTN_R = [System.Drawing.Color]::FromArgb(100, 35, 35)
$GREEN      = [System.Drawing.Color]::FromArgb(80, 200, 100)
$RED        = [System.Drawing.Color]::FromArgb(210, 70, 70)
$GRAY       = [System.Drawing.Color]::FromArgb(130, 130, 130)
$WHITE      = [System.Drawing.Color]::FromArgb(230, 230, 230)
$FONT_UI    = New-Object System.Drawing.Font("Segoe UI", 9.5)
$FONT_BOLD  = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$FONT_MONO  = New-Object System.Drawing.Font("Consolas", 8.5)

function New-Label($text, $x, $y, $w, $h, $font=$FONT_UI, $color=$WHITE) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = $font
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}

function New-Btn($text, $x, $y, $w, $h, $bg=$DARK_BTN) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $b.FlatAppearance.BorderSize = 1
    $b.BackColor = $bg
    $b.ForeColor = $WHITE
    $b.Font = $FONT_UI
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

# =============================================================================
# Form
# =============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Stellar Dev Services"
$form.Size = New-Object System.Drawing.Size(470, 420)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.BackColor = $DARK_BG

# Title
$lblTitle = New-Label "Stellar Dev Services" 15 14 280 28 $FONT_BOLD
$form.Controls.Add($lblTitle)

# Divider panel under title
$div1 = New-Object System.Windows.Forms.Panel
$div1.Location = New-Object System.Drawing.Point(0, 48)
$div1.Size = New-Object System.Drawing.Size(470, 1)
$div1.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$form.Controls.Add($div1)

# =============================================================================
# Service rows  [name] [status] [Start] [Stop] [Restart]
# =============================================================================
$services = @(
    @{ Name="OpenViking";  Port=1933; Check={ Test-Port 1933 }; StartFn={ Start-OV }; StopFn={ Stop-OV } },
    @{ Name="Slack Bot";   Port=$null; Check={ Test-BotRunning }; StartFn={ Start-Bot }; StopFn={ Stop-Bot } },
    @{ Name="Dev Server";  Port=3000; Check={ Test-Port 3000 }; StartFn={ Start-Dev }; StopFn={ Stop-Dev } }
)

$rows = @()
$yBase = 60
$rowH = 46

foreach ($i in 0..2) {
    $svc = $services[$i]
    $y = $yBase + $i * $rowH

    # Row background panel
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(8, ($y - 5))
    $panel.Size = New-Object System.Drawing.Size(436, 36)
    $panel.BackColor = $DARK_ROW
    $form.Controls.Add($panel)

    $lblName   = New-Label $svc.Name      12 ($y) 110 24
    $lblStatus = New-Label "● checking"  122 ($y) 110 24 $FONT_UI $GRAY
    $btnStart  = New-Btn "Start"         238 ($y - 3) 58 28
    $btnStop   = New-Btn "Stop"          302 ($y - 3) 58 28 $DARK_BTN_R
    $btnRst    = New-Btn "Restart"       366 ($y - 3) 72 28

    $form.Controls.AddRange(@($lblName, $lblStatus, $btnStart, $btnStop, $btnRst))

    $rows += @{ Svc=$svc; LblStatus=$lblStatus; BtnStart=$btnStart; BtnStop=$btnStop; BtnRst=$btnRst }
}

# =============================================================================
# Wire button events
# =============================================================================
function Log($msg) {
    $logBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $msg`r`n")
    $logBox.SelectionStart = $logBox.Text.Length
    $logBox.ScrollToCaret()
}

function Update-Status {
    foreach ($row in $rows) {
        $up = & $row.Svc.Check
        if ($up) {
            $row.LblStatus.Text = "● running"
            $row.LblStatus.ForeColor = $GREEN
            $row.BtnStart.Enabled = $false
            $row.BtnStop.Enabled  = $true
            $row.BtnRst.Enabled   = $true
        } else {
            $row.LblStatus.Text = "○ stopped"
            $row.LblStatus.ForeColor = $RED
            $row.BtnStart.Enabled = $true
            $row.BtnStop.Enabled  = $false
            $row.BtnRst.Enabled   = $false
        }
    }
}

foreach ($row in $rows) {
    $r = $row  # capture for closure
    $r.BtnStart.Add_Click({
        & $r.Svc.StartFn
        Log "Starting $($r.Svc.Name)..."
        Update-Status
    })
    $r.BtnStop.Add_Click({
        & $r.Svc.StopFn
        Log "Stopped $($r.Svc.Name)."
        Update-Status
    })
    $r.BtnRst.Add_Click({
        & $r.Svc.StopFn
        Start-Sleep -Milliseconds 800
        & $r.Svc.StartFn
        Log "Restarting $($r.Svc.Name)..."
        Update-Status
    })
}

# =============================================================================
# Divider + bottom buttons
# =============================================================================
$div2 = New-Object System.Windows.Forms.Panel
$div2.Location = New-Object System.Drawing.Point(0, 202)
$div2.Size = New-Object System.Drawing.Size(470, 1)
$div2.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$form.Controls.Add($div2)

$btnStartAll = New-Btn "▶  Start All"   10 212 130 32
$btnStopAll  = New-Btn "■  Stop All"   148 212 130 32 $DARK_BTN_R
$btnRefresh  = New-Btn "↺  Refresh"    318 212 130 32

$form.Controls.AddRange(@($btnStartAll, $btnStopAll, $btnRefresh))

$btnStartAll.Add_Click({
    Log "Starting all services..."
    Start-OV
    Log "Waiting for OpenViking on port 1933..."
    $attempts = 0
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 500
        $attempts++
    } while (-not (Test-Port 1933) -and $attempts -lt 30)
    if (Test-Port 1933) {
        Log "OpenViking ready."
        Start-Bot;  Log "Slack Bot started."
        Start-Dev;  Log "Dev Server started."
    } else {
        Log "WARNING: OpenViking did not come up in time."
    }
    Update-Status
})

$btnStopAll.Add_Click({
    Stop-Bot; Stop-Dev; Stop-OV
    Log "All services stopped."
    Update-Status
})

$btnRefresh.Add_Click({
    Update-Status
    Log "Refreshed."
})

# =============================================================================
# Log box
# =============================================================================
$div3 = New-Object System.Windows.Forms.Panel
$div3.Location = New-Object System.Drawing.Point(0, 253)
$div3.Size = New-Object System.Drawing.Size(470, 1)
$div3.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$form.Controls.Add($div3)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(10, 260)
$logBox.Size = New-Object System.Drawing.Size(434, 118)
$logBox.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 120)
$logBox.ReadOnly = $true
$logBox.Font = $FONT_MONO
$logBox.BorderStyle = "None"
$logBox.ScrollBars = "Vertical"
$form.Controls.Add($logBox)

# =============================================================================
# Auto-refresh timer (every 8 seconds)
# =============================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 8000
$timer.Add_Tick({ Update-Status })
$timer.Start()

# =============================================================================
# Launch
# =============================================================================
Update-Status
Log "Launcher ready."

[void]$form.ShowDialog()
$timer.Stop()
