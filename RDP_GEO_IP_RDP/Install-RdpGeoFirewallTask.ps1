#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Регистрирует задачу планировщика для периодического обновления RDP geo-firewall.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CollectionCount {
    param($Items)

    if ($null -eq $Items) {
        return 0
    }

    return @($Items).Count
}

if (-not (Test-Path $ConfigPath)) {
    throw "Файл конфигурации не найден: $ConfigPath"
}

$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
$config = Import-PowerShellDataFile -Path $ConfigPath
$taskName = [string]$config.ScheduledTaskName
$intervalHours = [int]$config.UpdateIntervalHours
$scriptPath = Join-Path $PSScriptRoot 'Update-RdpGeoFirewall.ps1'

if (-not (Test-Path $scriptPath)) {
    throw "Скрипт обновления не найден: $scriptPath"
}

$existing = @(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
if ((Get-CollectionCount $existing) -gt 0) {
    Write-Host "Удаление существующей задачи: $taskName"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$ConfigPath`""

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Hours $intervalHours) `
    -RepetitionDuration (New-TimeSpan -Days 9999)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Обновление правил Windows Firewall: RDP доступ только из geo-зоны Украины' | Out-Null

Write-Host "Задача '$taskName' создана. Интервал: каждые $intervalHours ч."
Write-Host "Первый запуск через ~1 минуту."
Write-Host ""
Write-Host "Ручной запуск:"
Write-Host "  Start-ScheduledTask -TaskName '$taskName'"
Write-Host ""
Write-Host "Удаление задачи:"
Write-Host "  Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
