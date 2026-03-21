@echo off
title iPhone OBS Stream Launcher
color 0A

echo ================================================
echo   iPhone OBS USB Camera - Stream Launcher
echo ================================================
echo.

:: ── Check helper scripts exist ────────────────────
if not exist "%~dp0_run_iproxy.bat" (
    color 0C
    echo [ERROR] _run_iproxy.bat not found next to start_stream.bat.
    pause
    exit /b 1
)
if not exist "%~dp0_run_receiver.bat" (
    color 0C
    echo [ERROR] _run_receiver.bat not found next to start_stream.bat.
    pause
    exit /b 1
)

:: ── Step 1: Launch iproxy in its own window ───────
echo [1/2] Starting iproxy tunnel (port 8080)...
start "iproxy - USB Tunnel" "%~dp0_run_iproxy.bat"

:: Give iproxy a moment to initialise
timeout /t 2 >nul

:: ── Step 2: Launch receiver.py in its own window ──
echo [2/2] Starting Python receiver (MJPEG on port 9090)...
start "receiver.py - MJPEG Server" "%~dp0_run_receiver.bat"

:: ── Done ──────────────────────────────────────────
echo.
echo ================================================
echo   Both components are running in separate windows.
echo ================================================
echo.
echo   Next steps:
echo    1. Open the CameraStream app on your iPhone
echo    2. Tap "Start Streaming"
echo    3. In OBS: Add Source ^> Media Source
echo              uncheck "Local File"
echo              URL: http://localhost:9090/stream
echo.
echo   Close the iproxy and receiver windows to stop.
echo.
pause
