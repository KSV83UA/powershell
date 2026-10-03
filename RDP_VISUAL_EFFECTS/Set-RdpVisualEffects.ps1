#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Отключает визуальные эффекты окон для всех пользователей (плавность RDP-сессий).

.DESCRIPTION
    В RDP-сессии окна «дёргаются» при перетаскивании и изменении размера, потому что
    содержимое окна перерисовывается на каждом шаге. Скрипт выключает:
      - показ содержимого окна при перетаскивании (DragFullWindows) — у каждого пользователя;
      - анимацию сворачивания/разворачивания окон (MinAnimate) — у каждого пользователя;
      - анимации окон через политику DWM (DisallowAnimations) — для всего компьютера.

    Пользовательские параметры записываются во все существующие профили и в профиль
    Default (для новых пользователей). Изменения действуют после повторного входа.

    Запускать НА СЕРВЕРЕ в PowerShell от администратора.
    Повторный запуск безопасен.

.PARAMETER Restore
    Возвращает значения Windows по умолчанию (эффекты включены) и удаляет политику DWM.
    Прежние значения не запоминаются: откат всегда ведёт к настройкам по умолчанию.

.PARAMETER SkipDefaultProfile
    Не изменять профиль Default (новые пользователи получат настройки Windows по умолчанию).

.EXAMPLE
    .\Set-RdpVisualEffects.ps1 -WhatIf
    Показывает, какие профили будут изменены, ничего не меняя.

.EXAMPLE
    .\Set-RdpVisualEffects.ps1
    Отключает эффекты для всех пользователей.

.EXAMPLE
    .\Set-RdpVisualEffects.ps1 -Restore
    Возвращает настройки по умолчанию.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Restore,
    [switch]$SkipDefaultProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$userValue = if ($Restore) { '1' } else { '0' }
$userSettings = @(
    @{ Key = 'Control Panel\Desktop'; Name = 'DragFullWindows'; Value = $userValue }
    @{ Key = 'Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate'; Value = $userValue }
)

$policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DWM'
$policyName = 'DisallowAnimations'
$profileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$tempHive = 'RdpVisualEffects_Temp'

function Invoke-Reg {
    param([string[]]$Arguments)

    # reg.exe пишет ошибки в stderr; при 'Stop' PowerShell 5.1 бросил бы исключение раньше проверки кода возврата
    $ErrorActionPreference = 'Continue'
    $output = & reg.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "reg.exe $($Arguments -join ' '): $(($output | ForEach-Object { "$_".Trim() }) -join ' ')"
    }
}

function Set-UserHiveSettings {
    param([string]$HiveRoot)

    # Только reg.exe: провайдер реестра PowerShell держит открытые дескрипторы и не даёт выгрузить куст
    foreach ($setting in $userSettings) {
        Invoke-Reg @('add', "$HiveRoot\$($setting.Key)", '/v', $setting.Name, '/t', 'REG_SZ', '/d', $setting.Value, '/f')
    }
}

function Set-OfflineHiveSettings {
    param([string]$HiveFile)

    if (-not (Test-Path -LiteralPath $HiveFile)) {
        throw "файл не найден: $HiveFile"
    }

    Invoke-Reg @('load', "HKU\$tempHive", $HiveFile)
    try {
        Set-UserHiveSettings -HiveRoot "HKU\$tempHive"
    }
    finally {
        Invoke-Reg @('unload', "HKU\$tempHive")
    }
}

# --- main ---

if ($Restore) {
    Write-Host 'Режим: возврат настроек Windows по умолчанию (эффекты включены).'
}
else {
    Write-Host 'Режим: отключение визуальных эффектов окон.'
}

# Куст мог остаться загруженным, если прошлый запуск был прерван
if (Test-Path "Registry::HKEY_USERS\$tempHive") {
    Invoke-Reg @('unload', "HKU\$tempHive")
}

# --- Политика для всего компьютера ---------------------------------------

if ($Restore) {
    $policyValue = Get-ItemProperty -Path $policyPath -Name $policyName -ErrorAction SilentlyContinue
    if ($null -ne $policyValue) {
        if ($PSCmdlet.ShouldProcess("$policyPath\$policyName", 'Удалить политику')) {
            Remove-ItemProperty -Path $policyPath -Name $policyName
            Write-Host "Политика DWM '$policyName' удалена."
        }
    }
    else {
        Write-Host "Политика DWM '$policyName' не задана."
    }
}
elseif ($PSCmdlet.ShouldProcess("$policyPath\$policyName", 'Установить значение 1')) {
    if (-not (Test-Path $policyPath)) {
        New-Item -Path $policyPath -Force | Out-Null
    }

    Set-ItemProperty -Path $policyPath -Name $policyName -Value 1 -Type DWord
    Write-Host "Политика DWM '$policyName' = 1: анимации окон отключены для всего компьютера."
}

# --- Профили пользователей ------------------------------------------------

# Только учётные записи пользователей (локальные, доменные, Azure AD); записи вида '<SID>.bak' не трогаем
$profiles = @(Get-ChildItem -Path $profileListPath |
    Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)(-\d+)+$' } |
    ForEach-Object {
        [pscustomobject]@{
            Sid  = $_.PSChildName
            Path = [string]$_.GetValue('ProfileImagePath')
        }
    })

$changed = 0
$failed = 0

foreach ($userProfile in $profiles) {
    $label = "$($userProfile.Path) [$($userProfile.Sid)]"

    try {
        if (Test-Path "Registry::HKEY_USERS\$($userProfile.Sid)") {
            # Пользователь сейчас в системе — его куст уже загружен
            if ($PSCmdlet.ShouldProcess($label, 'Изменить загруженный куст реестра')) {
                Set-UserHiveSettings -HiveRoot "HKU\$($userProfile.Sid)"
                Write-Host "Профиль обновлён (пользователь в системе): $label"
                $changed++
            }
        }
        elseif ($PSCmdlet.ShouldProcess($label, 'Изменить NTUSER.DAT')) {
            Set-OfflineHiveSettings -HiveFile (Join-Path $userProfile.Path 'NTUSER.DAT')
            Write-Host "Профиль обновлён: $label"
            $changed++
        }
    }
    catch {
        Write-Warning "Профиль пропущен: $label — $($_.Exception.Message)"
        $failed++
    }
}

# --- Профиль Default (шаблон для новых пользователей) ---------------------

if (-not $SkipDefaultProfile) {
    $defaultProfilePath = [string](Get-ItemProperty -Path $profileListPath -Name 'Default').Default

    try {
        if ($PSCmdlet.ShouldProcess($defaultProfilePath, 'Изменить NTUSER.DAT профиля Default')) {
            Set-OfflineHiveSettings -HiveFile (Join-Path $defaultProfilePath 'NTUSER.DAT')
            Write-Host "Профиль Default обновлён: $defaultProfilePath"
            $changed++
        }
    }
    catch {
        Write-Warning "Профиль Default пропущен: $defaultProfilePath — $($_.Exception.Message)"
        $failed++
    }
}

Write-Host ''
Write-Host "Готово. Профилей изменено: $changed, пропущено с ошибкой: $failed."
Write-Host 'Изменения вступят в силу после повторного входа пользователей.'

if ($failed -gt 0) {
    exit 1
}
