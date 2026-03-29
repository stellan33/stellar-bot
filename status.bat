@echo off
echo ================================================
echo  Stellar Dev Services - Status
echo ================================================
echo.

:: --- OpenViking (port 1933) ---
echo [OpenViking Server]
for /f "tokens=*" %%A in ('netstat -an ^| findstr ":1933 " ^| findstr "LISTENING"') do set OV_UP=1
if defined OV_UP (
    echo   STATUS : RUNNING  ^(port 1933^)
) else (
    echo   STATUS : NOT RUNNING
)
set OV_UP=

:: ov status output
echo   ---
C:\Users\andre\Anaconda3\envs\openviking\Scripts\ov.exe status 2>&1
echo   ---
echo.

:: --- Slack Bot ---
echo [Slack Bot]
for /f "tokens=*" %%A in ('tasklist ^| findstr /i "python.exe"') do set BOT_UP=1
if defined BOT_UP (
    echo   STATUS : RUNNING  ^(python.exe found^)
) else (
    echo   STATUS : NOT RUNNING
)
set BOT_UP=
echo.

:: --- Dev Server (port 3000) ---
echo [Stellar Studio Dev Server]
for /f "tokens=*" %%A in ('netstat -an ^| findstr ":3000 " ^| findstr "LISTENING"') do set DEV_UP=1
if defined DEV_UP (
    echo   STATUS : RUNNING  ^(http://localhost:3000^)
) else (
    echo   STATUS : NOT RUNNING
)
set DEV_UP=
echo.

:: --- Index ---
echo [OpenViking Index]
if exist "C:\Dev\openviking_workspace\viking\default\resources" (
    dir /b "C:\Dev\openviking_workspace\viking\default\resources" 2>nul
) else (
    echo   No resources indexed yet. Run update-index.bat
)
echo.

:: --- Active ov.exe processes (shows if indexing is in progress) ---
echo [Active ov.exe processes]
tasklist 2>nul | findstr /i "ov.exe"
if errorlevel 1 echo   None running.
echo.

echo ================================================
pause
