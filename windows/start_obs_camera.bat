@echo off
title iPhone OBS Camera

echo ================================================
echo   iPhone OBS USB Camera - Starting...
echo ================================================
echo.
echo Make sure your iPhone is plugged in via USB.
echo.

:: Start iproxy in its own window
start "iproxy" "C:\Users\kiran\Documents\Bookietok\libimobiledevice.1.2.1-r1122-win-x64\iproxy.exe" 8080 8080

:: Brief pause to let iproxy initialise
timeout /t 2 /nobreak >nul

:: Start the Python receiver in its own window
start "OBS Receiver" cmd /k "python C:\Users\kiran\Documents\GitHub\iphone-obs-usb\windows\receiver.py"

echo Both components started.
echo.
echo NEXT STEPS:
echo  1. Open the OBS Camera app on your iPhone
echo  2. Tap "Start Streaming"
echo  3. In OBS: Add Source ^> Media Source ^> uncheck Local File
echo     URL: http://localhost:9090/stream
echo.
pause
