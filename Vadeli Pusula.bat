@echo off
rem Vadeli Pusula'yi baslatir: yerel sunucuyu kucuk bir pencerede acar ve paneli tarayicida gosterir.
cd /d "%~dp0"
start "Vadeli Pusula sunucusu" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sunucu.ps1"
timeout /t 2 /nobreak >nul
start "" http://localhost:8765/
