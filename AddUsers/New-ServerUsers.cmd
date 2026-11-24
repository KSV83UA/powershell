@echo off
rem Добавление пользователей двойным щелчком: скрипт спросит - по одному или списком.
rem Запускает New-ServerUsers.ps1 из этой же папки. Политика выполнения обходится только
rem для этого запуска (-ExecutionPolicy Bypass), настройки компьютера не меняются.
rem Параметры передаются скрипту: New-ServerUsers.cmd -Interactive, New-ServerUsers.cmd ivanov и т.д.
rem Запускайте от имени администратора: правой кнопкой - «Запуск от имени администратора».
rem Файл без BOM и с CRLF: так его правильно читает cmd.exe.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-ServerUsers.ps1" %*
set "rc=%ERRORLEVEL%"

echo.
pause
exit /b %rc%
