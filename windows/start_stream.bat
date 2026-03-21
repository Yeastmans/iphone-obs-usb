@echo off
title iPhone OBS Stream Launcher
color 0A

echo ================================================
echo   iPhone OBS USB Camera - Stream Launcher
echo ================================================
echo.

:: ── Check Python ──────────────────────────────────
python --version >nul 2>&1
if errorlevel 1 (
    color 0C
    echo [ERROR] Python not found. Please install Python 3.8+ and add it to PATH.
    echo         https://www.python.org/downloads/
    pause
    exit /b 1
)

:: ── Check iproxy ──────────────────────────────────
where iproxy >nul 2>&1
if errorlevel 1 (
    color 0C
    echo [ERROR] iproxy not found in PATH.
    echo.
    echo  To install iproxy on Windows:
    echo    1. Install iTunes from the Microsoft Store (includes Apple drivers)
    echo    2. Download libimobiledevice for Windows:
    echo       https://github.com/libimobiledevice-win32/imobiledevice-net/releases
    echo    3. Copy iproxy.exe to a folder in your PATH  (e.g. C:\Windows\System32)
    echo.
    pause
    exit /b 1
)

:: ── Make sure iPhone is connected ─────────────────
echo [*] Checking for connected iPhone...
ideviceinfo >nul 2>&1
if errorlevel 1 (
    color 0E
    echo [WARNING] No iPhone detected. Make sure it is:
    echo    - Plugged in via USB
    echo    - Unlocked and trusted on this PC
    echo.
    echo  Continuing anyway — iproxy will wait for the device.
    echo.
    timeout /t 3 >nul
    color 0A
)

:: ── Step 1: Launch iproxy in its own window ───────
echo [1/2] Starting iproxy tunnel (port 8080)...
start "iproxy - USB Tunnel" cmd /k "color 0B && echo iproxy USB Tunnel && echo ======================== && echo Forwarding localhost:8080 to iPhone port 8080 && echo Close this window to stop the tunnel. && echo. && iproxy 8080 8080"

:: Give iproxy a moment to initialise
timeout /t 2 >nul

:: ── Step 2: Launch receiver.py in its own window ──
echo [2/2] Starting Python receiver (MJPEG on port 9090)...
start "receiver.py - MJPEG Server" cmd /k "color 09 && cd /d %~dp0 && python receiver.py"

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
