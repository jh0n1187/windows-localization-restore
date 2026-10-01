@echo off
REM Executa Pending-Step.ps1 elevado e grava log em ..\Logs\Pending-Step-last.log
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& { & .\Pending-Step.ps1 } *>&1 | Tee-Object -FilePath ..\Logs\Pending-Step-last.log; Copy-Item ..\Logs\Pending-Step-last.log (\"..\Logs\Pending-Step-\" + (Get-Date -Format yyyyMMdd-HHmmss) + \".log\")"
echo.
echo ===== FIM - pode fechar esta janela =====
pause
