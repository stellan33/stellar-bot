@echo off
echo ================================================
echo  Stellar Dev Services - Startup
echo ================================================

:: -----------------------------------------------
:: STEP 1 - Verify environment
:: -----------------------------------------------
echo.
echo [1/3] Checking environment...
if not exist "C:\Users\andre\Anaconda3\envs\openviking\python.exe" (
    echo   ERROR: openviking conda env not found.
    echo   Run: conda create -n openviking python=3.11
    pause & exit /b 1
)
echo   OK.

:: -----------------------------------------------
:: STEP 2 - Start OpenViking, wait until ready
:: -----------------------------------------------
echo.
echo [2/3] Starting OpenViking Server...
start "OpenViking Server" cmd /k "C:\Dev\stellar-bot\start-openviking.bat"
echo   Polling port 1933
set /a ATTEMPTS=0
:WAIT_OV
set /a ATTEMPTS+=1
if %ATTEMPTS% GTR 30 (
    echo.
    echo   ERROR: OpenViking not responding after 60s.
    echo   Check the "OpenViking Server" window for errors.
    pause & exit /b 1
)
netstat -an 2>nul | find "1933" | find "LISTENING" >nul 2>&1
if errorlevel 1 (
    set /p D=. <nul
    timeout /t 2 /nobreak >nul
    goto WAIT_OV
)
echo.
echo   OpenViking ready on port 1933.

:: -----------------------------------------------
:: STEP 3 - Start bot and dev server
:: -----------------------------------------------
echo.
echo [3/3] Starting services...
start "Slack Bot" cmd /k "C:\Dev\stellar-bot\start-bot.bat"
start "Stellar Studio Dev" cmd /k "C:\Dev\stellar-bot\start-dev-server.bat"

echo.
echo ================================================
echo  All services started!
echo   OpenViking : http://localhost:1933
echo   Slack Bot  : see "Slack Bot" window
echo   Dev Server : http://localhost:3000
echo.
echo   NOTE: If this is the first run or you have
echo   made code changes, run update-index-smart.bat
echo ================================================
pause
