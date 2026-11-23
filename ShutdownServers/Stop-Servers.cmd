@echo off
rem Выключение серверной стойки двойным щелчком: план, подтверждение YES, выключение.
rem Запускает Stop-Servers.ps1 из этой же папки. Политика выполнения обходится только
rem для этого запуска (-ExecutionPolicy Bypass), настройки компьютера не меняются.
rem Параметры передаются скрипту: Stop-Servers.cmd -Check, Stop-Servers.cmd -Stage 1 и т.д.
rem Запускайте от той учётной записи, под которой сохранены учётные данные и SSH-ключи.
rem Файл без BOM и с CRLF: так его правильно читает cmd.exe.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Stop-Servers.ps1" %*
set "rc=%ERRORLEVEL%"

rem С -Force (ПО ИБП, планировщик) смотреть на окно некому: не ждём нажатия клавиши
echo %* | findstr /i /c:"-Force" >nul && exit /b %rc%

echo.
pause
exit /b %rc%
