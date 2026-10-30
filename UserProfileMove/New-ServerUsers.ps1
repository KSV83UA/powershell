#Requires -Version 5.1

<#
.SYNOPSIS
    Создаёт на сервере локальные учётные записи по списку и генерирует для них пароли.

.DESCRIPTION
    Читает список из New-ServerUsers.users.csv (рядом со скриптом) и для каждой записи:
      - создаёт локальную учётную запись с полным именем и описанием (отдел, должность);
      - берёт пароль из столбца Password, а если его нет - генерирует случайный;
      - добавляет пользователя в группы «Пользователи» и «Пользователи удалённого рабочего стола».

    Столбец Password нужен при переносе пользователей на новый сервер: в качестве списка
    подходит файл с паролями, который скрипт создал на старом сервере.

    Уже существующие учётные записи скрипт не трогает и пароль им не меняет, поэтому его можно
    запускать повторно, например после добавления в список нового сотрудника.

    Логины и пароли созданных пользователей записываются в файл
    New-ServerUsers.passwords_<дата_время>.csv. Доступ к нему получают только администраторы.
    После раздачи паролей файл нужно удалить.

    Список проверяется перед началом работы; при ошибках скрипт перечисляет их все
    и никого не создаёт.

    Запускать на самом сервере от имени администратора.

.PARAMETER UserList
    CSV-файл со списком пользователей (разделитель - точка с запятой). Столбцы Login и FullName
    обязательны; остальные - по желанию:
      Password                - готовый пароль; пусто - пароль будет сгенерирован;
      Description             - описание учётной записи; пусто - составляется из Department и Position;
      Department, Position, Phone.

.PARAMETER PasswordFile
    Куда записать логины и пароли. По умолчанию - рядом со списком пользователей.

.PARAMETER PasswordLength
    Длина пароля, от 8 до 64 символов. По умолчанию 12.

.PARAMETER PasswordNeverExpires
    Сделать пароли бессрочными. Без этого ключа срок действия пароля задаёт политика сервера
    (по умолчанию 42 дня).

.EXAMPLE
    .\New-ServerUsers.ps1 -WhatIf
    Проверяет список и показывает, кто будет создан, ничего не меняя.

.EXAMPLE
    .\New-ServerUsers.ps1 -PasswordNeverExpires
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$UserList = (Join-Path $PSScriptRoot 'New-ServerUsers.users.csv'),

    [string]$PasswordFile,

    [ValidateRange(8, 64)]
    [int]$PasswordLength = 12,

    [switch]$PasswordNeverExpires
)

$ErrorActionPreference = 'Stop'

function Get-ErrorText($ErrorRecord) { $ErrorRecord.Exception.GetBaseException().Message }

# --- Список пользователей ---
if (-not (Test-Path -LiteralPath $UserList -PathType Leaf)) { throw "Файл со списком пользователей не найден: $UserList" }
$UserList = (Resolve-Path -LiteralPath $UserList).ProviderPath
# Файл могли сохранить и Блокнотом (UTF-8), и Excel (ANSI) - читаем оба варианта
$text = [IO.File]::ReadAllText($UserList)
if ($text.Contains([string][char]0xFFFD)) { $text = [IO.File]::ReadAllText($UserList, [Text.Encoding]::Default) }
# Excel оставляет в конце строки из одних разделителей - их отбрасываем вместе с пустыми
$lines = @($text -split "`r?`n" | Where-Object { $_ -match '[^\s;,]' })
if ($lines.Count -lt 2) { throw "В файле $UserList нет ни одной записи." }
$delimiter = if ($lines[0].Contains(';')) { ';' } else { ',' }
$rows = @($lines | ConvertFrom-Csv -Delimiter $delimiter)
foreach ($column in 'Login', 'FullName') {
    if (@($rows[0].PSObject.Properties.Name) -notcontains $column) {
        throw "В файле $UserList нет столбца $column. Первая строка должна быть: Login;FullName;Department;Position;Phone"
    }
}

# --- Проверка списка: собираем все ошибки сразу ---
$problems = New-Object 'System.Collections.Generic.List[string]'
$seen = @{}
$number = 0
$users = @(foreach ($row in $rows) {
        $number++
        $login = "$($row.Login)".Trim()
        $fullName = "$($row.FullName)".Trim()
        $description = "$($row.Description)".Trim()
        if (-not $description) {
            $description = (@($row.Department, $row.Position) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ', '
        }
        # пароль не обрезаем: пробел по краям может быть его частью
        $password = "$($row.Password)"
        if (-not $password.Trim()) { $password = '' }
        $where = "запись $number ($(if ($login) { $login } else { $fullName }))"

        if (-not $login) { $problems.Add("${where}: не задан Login") }
        elseif ($login.Length -gt 20) { $problems.Add("${where}: Login длиннее 20 символов - Windows такой не примет") }
        elseif ($login -match '["/\\\[\]:;|=,+*?<>@]' -or $login.EndsWith('.')) {
            $problems.Add("${where}: в Login недопустимые для Windows символы")
        }
        elseif ($seen.ContainsKey($login)) { $problems.Add("${where}: такой Login уже есть в списке") }
        else { $seen[$login] = $true }
        if (-not $fullName) { $problems.Add("${where}: не задано FullName") }
        if ($description.Length -gt 48) {
            $problems.Add("${where}: описание (Description или Department и Position) длиннее 48 символов - столько вмещает учётная запись")
        }

        [pscustomobject]@{ Login = $login; FullName = $fullName; Description = $description; Phone = "$($row.Phone)".Trim(); Password = $password }
    })
if ($problems.Count -gt 0) {
    $list = $problems -join "`n  - "
    throw "Список пользователей не прошёл проверку (файл $UserList):`n  - $list"
}

if (-not (Get-Command New-LocalUser -ErrorAction SilentlyContinue)) {
    throw 'Не найдены командлеты локальных учётных записей (New-LocalUser). Нужна 64-разрядная консоль Windows PowerShell 5.1.'
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) {
    throw 'Запустите PowerShell от имени администратора: создавать учётные записи может только администратор.'
}

# --- Пароли ---
# Без похожих символов (0 и O, 1, l и I): пароль придётся диктовать и набирать вручную.
# Только буквы и цифры: знаки препинания стоят на разных клавишах в разных раскладках.
$alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ' + 'abcdefghijkmnpqrstuvwxyz' + '23456789'
$rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
function New-Password([int]$Length, [string]$Login) {
    # байты с «хвоста» диапазона отбрасываем, иначе часть символов выпадала бы чаще других
    $limit = 256 - (256 % $alphabet.Length)
    $byte = New-Object byte[] 1
    while ($true) {
        $chars = New-Object char[] $Length
        $i = 0
        while ($i -lt $Length) {
            $rng.GetBytes($byte)
            if ($byte[0] -lt $limit) {
                $chars[$i] = $alphabet[$byte[0] % $alphabet.Length]
                $i++
            }
        }
        $password = -join $chars
        # Требования сложности Windows: буквы обоих регистров и цифра, логин внутри пароля запрещён
        if ($password -cmatch '[A-Z]' -and $password -cmatch '[a-z]' -and $password -match '\d' -and
            $password.IndexOf($Login, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            return $password
        }
    }
}

# Файл с паролями создаётся пустым и сразу закрывается от всех, кроме администраторов:
# на терминальном сервере обычная папка читается любым пользователем.
function New-ProtectedFile([string]$Path) {
    [IO.File]::WriteAllText($Path, '')
    $security = New-Object Security.AccessControl.FileSecurity
    $security.SetAccessRuleProtection($true, $false)
    # Администраторы, SYSTEM и тот, кто запустил скрипт
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        $account = New-Object Security.Principal.SecurityIdentifier $sid
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule ($account, 'FullControl', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

# Группы задаются по SID: в русской и украинской Windows они называются по-другому.
# «Пользователи» и «Пользователи удалённого рабочего стола» (без второй не войти по RDP).
$groupSids = 'S-1-5-32-545', 'S-1-5-32-555'

if (-not $PasswordFile) {
    $PasswordFile = Join-Path (Split-Path $UserList) "New-ServerUsers.passwords_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').csv"
}
$PasswordFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PasswordFile)
$utf8 = New-Object Text.UTF8Encoding $true
$created = 0
$fileReady = $false

$results = foreach ($user in $users) {
    $status = 'будет создан'
    if (Get-LocalUser -Name $user.Login -ErrorAction SilentlyContinue) {
        $status = 'уже существует - не изменён'
    }
    elseif ($PSCmdlet.ShouldProcess($user.Login, "создать учётную запись ($($user.FullName))")) {
        $password = $user.Password
        if (-not $password) { $password = New-Password $PasswordLength $user.Login }
        $record = [pscustomobject]@{ Login = $user.Login; FullName = $user.FullName; Phone = $user.Phone; Password = $password }
        $csv = @($record | ConvertTo-Csv -Delimiter ';' -NoTypeInformation)

        # Файл готовим до создания первой учётной записи: если записать пароли некуда,
        # лучше остановиться сразу, чем получить пользователей с неизвестными паролями.
        if (-not $fileReady) {
            try {
                New-ProtectedFile $PasswordFile
                [IO.File]::AppendAllText($PasswordFile, $csv[0] + "`r`n", $utf8)
            }
            catch { throw "Не удалось подготовить файл для паролей $PasswordFile, никто не создан: $(Get-ErrorText $_)" }
            $fileReady = $true
        }

        try {
            $account = @{
                Name     = $user.Login
                FullName = $user.FullName
                Password = ConvertTo-SecureString $password -AsPlainText -Force
            }
            if ($user.Description) { $account.Description = $user.Description }
            if ($PasswordNeverExpires) { $account.PasswordNeverExpires = $true }
            New-LocalUser @account | Out-Null

            # пароль записываем сразу, чтобы сбой на следующих пользователях его не потерял
            [IO.File]::AppendAllText($PasswordFile, $csv[1] + "`r`n", $utf8)
            $created++
            $status = if ($user.Password) { 'создан, пароль из списка' } else { 'создан' }

            $failedGroups = @()
            foreach ($sid in $groupSids) {
                try { Add-LocalGroupMember -SID $sid -Member $user.Login }
                catch {
                    $group = try { (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount]).Value } catch { $sid }
                    $failedGroups += "«$group» ($(Get-ErrorText $_))"
                }
            }
            if ($failedGroups) { $status = "создан, но не добавлен в группу - добавьте вручную: $($failedGroups -join '; ')" }
        }
        catch { $status = "ошибка: $(Get-ErrorText $_)" }
    }

    [pscustomobject]@{ Login = $user.Login; FullName = $user.FullName; Status = $status }
}

# ни одной учётной записи не создано - файл с одним заголовком не нужен
if ($fileReady -and $created -eq 0) { [IO.File]::Delete($PasswordFile) }

$results | Format-Table Login, FullName, Status -AutoSize -Wrap
if ($created -gt 0) {
    Write-Host "Создано учётных записей: $created. Логины и пароли: $PasswordFile"
    Write-Warning 'Файл с паролями доступен только администраторам. После раздачи паролей удалите его.'
}
if ($results | Where-Object { $_.Status -like 'ошибка*' -or $_.Status -like '*не добавлен*' }) {
    Write-Warning 'Не всё прошло успешно - смотрите столбец Status. Несозданных можно создать повторным запуском, когда причина устранена.'
}
