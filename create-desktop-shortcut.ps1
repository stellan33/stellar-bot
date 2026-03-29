# Run this once to create a desktop shortcut for the launcher
$shell = New-Object -ComObject WScript.Shell
$desktop = [System.Environment]::GetFolderPath("Desktop")
$shortcut = $shell.CreateShortcut("$desktop\Stellar Services.lnk")
$shortcut.TargetPath = "C:\Dev\stellar-bot\launch.bat"
$shortcut.WorkingDirectory = "C:\Dev\stellar-bot"
$shortcut.WindowStyle = 7  # minimized (hides the cmd flash)
$shortcut.Description = "Stellar Dev Services Launcher"
$shortcut.Save()
Write-Host "Shortcut created on Desktop: 'Stellar Services'"
