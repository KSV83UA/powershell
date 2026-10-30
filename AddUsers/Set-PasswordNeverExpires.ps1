#Requires -Version 5.1

<#
.SYNOPSIS
    Ставит «Срок действия пароля не ограничен» уже созданным локальным пользователям.

.DESCRIPTION
    Обрабатывает все локальные учётные записи сервера, кроме встроенных (Администратор, Гость,
    DefaultAccount, WDAGUtilityAccount). Пароли и остальные настройки не меняются,
    поэтому скрипт можно запускать повторно.

    Запускать на самом сервере от имени администратора.

.EXAMPLE
    .\Set-PasswordNeverExpires.ps1 -WhatIf
    Показывает, кто будет изменён, ничего не меняя.

.EXAMPLE
    .\Set-PasswordNeverExpires.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'

function Get-ErrorText($ErrorRecord) { $ErrorRecord.Exception.GetBaseException().Message }

if (-not (Get-Command Set-LocalUser -ErrorAction SilentlyContinue)) {
    throw 'Не найдены командлеты локальных учётных записей (Set-LocalUser). Нужна 64-разрядная консоль Windows PowerShell 5.1.'
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) {
    throw 'Запустите PowerShell от имени администратора: менять учётные записи может только администратор.'
}

# Встроенные записи определяются по SID: их имена зависят от языка Windows, и их можно переименовать.
# 500 - Администратор, 501 - Гость, 503 - DefaultAccount, 504 - WDAGUtilityAccount.
$users = @(Get-LocalUser | Where-Object { $_.SID.Value -notmatch '-(500|501|503|504)$' })
if ($users.Count -eq 0) {
    Write-Host 'Локальных учётных записей, кроме встроенных, нет.'
    return
}

$results = foreach ($user in $users) {
    $status = 'будет изменён'
    if ($PSCmdlet.ShouldProcess($user.Name, 'поставить «Срок действия пароля не ограничен»')) {
        try {
            Set-LocalUser -Name $user.Name -PasswordNeverExpires $true
            $status = 'готово'
        }
        catch { $status = "ошибка: $(Get-ErrorText $_)" }
    }

    [pscustomobject]@{ Login = $user.Name; FullName = $user.FullName; Status = $status }
}

$results | Format-Table Login, FullName, Status -AutoSize -Wrap
if ($results | Where-Object { $_.Status -like 'ошибка*' }) {
    Write-Warning 'Не всё прошло успешно - смотрите столбец Status. Когда причина устранена, запустите скрипт ещё раз.'
}
