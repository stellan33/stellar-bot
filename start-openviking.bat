@echo off
echo ================================================
echo  OpenViking Server
echo ================================================

:: Set config file path
set OPENVIKING_CONFIG_FILE=%USERPROFILE%\.openviking\ov.conf

:: Add conda env Scripts to PATH so openviking-server can find vikingbot.exe
set PATH=C:\Users\andre\Anaconda3\envs\openviking\Scripts;%PATH%

:: Force UTF-8 so Python can handle emoji in vikingbot output (CP1252 can't)
chcp 65001 >nul
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8

:: Clean up stale RocksDB locks (prevent startup failures after unclean shutdown)
echo Cleaning stale locks...
del /f /q "C:\Dev\openviking_workspace\*.lock" 2>nul
del /f /q "C:\Dev\openviking_workspace\viking\.lock" 2>nul
del /f /q "C:\Dev\openviking_workspace\vectordb\context\store\LOCK" 2>nul
del /f /q "C:\Dev\openviking_workspace\.openviking.pid" 2>nul

echo Starting OpenViking Server with bot...
C:\Users\andre\Anaconda3\envs\openviking\Scripts\openviking-server.exe --bot --with-bot --bot-url http://localhost:18791
