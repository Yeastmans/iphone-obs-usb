@echo off
color 0B
title iproxy - USB Tunnel
echo iproxy USB Tunnel
echo ========================
echo Forwarding localhost:8080 to iPhone port 8080
echo Close this window to stop the tunnel.
echo.
"C:\Users\kiran\iphone streaming app\iphone-obs-usb-main\windows\libimobiledevice.1.2.1-r1122-win-x64\iproxy.exe" 8080 8080
pause
