# =====================================================================
# Install-RdpGuard.ps1
# Устанавливает Rdp-Guard: копирует скрипт в C:\Scripts и создаёт
# задание планировщика "RDP-Guard" (каждые 15 минут с 17:00 до 07:00,
# от SYSTEM, с наивысшими правами).
#
# Запускать НА СЕРВЕРЕ в PowerShell от администратора,
# положив рядом файл Rdp-Guard.ps1.
# Повторный запуск безопасен — задание пересоздаётся.
# =====================================================================

$ErrorActionPreference = 'Stop'

$targetDir  = 'C:\Scripts'
$scriptName = 'Rdp-Guard.ps1'
$taskName   = 'RDP-Guard'

# --- Копирование скрипта -------------------------------------------------

if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

$source = Join-Path $PSScriptRoot $scriptName
$target = Join-Path $targetDir  $scriptName

if ((Test-Path $source) -and
    ([IO.Path]::GetFullPath($source) -ieq [IO.Path]::GetFullPath($target))) {
    Write-Host "Скрипт уже на месте: $target (копирование не требуется)"
}
elseif (Test-Path $source) {
    Copy-Item $source $target -Force
    Write-Host "Скрипт скопирован: $target"
}
elseif (-not (Test-Path $target)) {
    throw "Не найден $scriptName ни рядом с установщиком, ни в $targetDir"
}
else {
    Write-Host "Используется уже существующий $target"
}

# --- Создание задания планировщика ---------------------------------------

$action = New-ScheduledTaskAction `
    -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$target`""

# Ежедневно в 17:00, далее повтор каждые 15 минут в течение 14 часов (до 07:00)
$trigger = New-ScheduledTaskTrigger -Daily -At '17:00'
$repetition = (New-ScheduledTaskTrigger -Once -At '17:00' `
    -RepetitionInterval (New-TimeSpan -Minutes 15) `
    -RepetitionDuration (New-TimeSpan -Hours 14)).Repetition
$trigger.Repetition = $repetition

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Write-Host ""
Write-Host "Задание '$taskName' создано: каждые 15 минут с 17:00 до 07:00, от SYSTEM."
Write-Host ""
Write-Host "Проверка прямо сейчас:"
Write-Host "  Start-ScheduledTask -TaskName '$taskName'"
Write-Host "  Get-Content $targetDir\Rdp-Guard.log -Tail 10"
