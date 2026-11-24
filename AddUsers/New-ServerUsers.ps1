#Requires -Version 5.1

<#
.SYNOPSIS
    Создаёт локальных пользователей RDP-сервера: одного по параметрам, по одному в диалоге
    или пакетно по списку CSV.

.DESCRIPTION
    Способы запуска:

      Один пользователь - параметрами. Достаточно логина или имени (с фамилией или без):
        .\New-ServerUsers.ps1 ivanov
        .\New-ServerUsers.ps1 -FirstName Іван -LastName Петренко        (логин i.petrenko)

      Диалог - по одному: скрипт спрашивает имя, фамилию, телефон, отдел и логин:
        .\New-ServerUsers.ps1 -Interactive

      Список - пакетно из CSV:
        .\New-ServerUsers.ps1 -UserList D:\users.csv

      Без параметров скрипт спрашивает, что делать: диалог или список
      New-ServerUsers.users.csv рядом со скриптом.

    Для каждого пользователя скрипт:
      - если логин не задан, составляет его из имени и фамилии латиницей по шаблону
        -LoginTemplate (украинская транслитерация КМУ 2010, русские буквы тоже обрабатываются);
      - берёт заданный пароль или генерирует случайный;
      - создаёт локальную учётную запись с ФИО и описанием (отдел, должность);
      - добавляет её в группы «Пользователи» и «Пользователи удалённого рабочего стола»,
        а также в группы из -ExtraGroups и столбца Groups.

    Уже существующие учётные записи скрипт не трогает и пароль им не меняет, поэтому его можно
    запускать повторно, например после добавления в список нового сотрудника.

    Логины и пароли созданных пользователей записываются в файл
    New-ServerUsers.passwords_<дата_время>.csv. Доступ к нему получают только администраторы.
    После раздачи паролей файл нужно удалить.

    Данные проверяются до создания учётных записей. В пакетном режиме при ошибках скрипт
    перечисляет их все и никого не создаёт.

    Запускать на самом сервере от имени администратора.

.PARAMETER Login
    Логин одного пользователя, до 20 символов. Можно указать первым параметром без имени.
    Не задан - составляется из -FirstName и -LastName.

.PARAMETER FirstName
    Имя. Вместе с -LastName - логин по шаблону -LoginTemplate; одно имя - логин из имени.

.PARAMETER LastName
    Фамилия.

.PARAMETER FullName
    ФИО в учётной записи. Не задано - «Имя Фамилия» из -FirstName и -LastName.

.PARAMETER Phone
    Телефон. Попадает только в файл с паролями, в учётную запись - нет.

.PARAMETER Department
    Отдел. Вместе с -Position составляет описание учётной записи.

.PARAMETER Position
    Должность.

.PARAMETER Description
    Описание учётной записи (до 48 символов) вместо «отдел, должность».

.PARAMETER Password
    Готовый пароль. Не задан - генерируется.

.PARAMETER Interactive
    Диалог: пользователи вводятся по одному, пока имя не оставят пустым.

.PARAMETER UserList
    CSV-файл со списком пользователей (разделитель - точка с запятой или запятая, кодировка
    UTF-8 или ANSI). Столбцы, все по желанию, но нужен Login или имя:
      Login                - логин; пусто - составляется из FirstName и LastName;
      FirstName, LastName  - имя и фамилия;
      FullName             - ФИО; пусто - «Имя Фамилия», а без них учётная запись без ФИО;
      Password             - готовый пароль; пусто - пароль будет сгенерирован;
      Description          - описание; пусто - составляется из Department и Position;
      Department, Position, Phone;
      Groups               - дополнительные группы через |, например: 1C_Users|Принтеры.
    Подходит и файл с паролями, который скрипт создал на другом сервере: так пользователи
    переносятся с теми же паролями.

.PARAMETER PasswordFile
    Куда записать логины и пароли. По умолчанию - новый файл рядом со списком пользователей
    (в диалоге и для одного пользователя - рядом со скриптом). Если файл уже есть,
    записи дописываются в его конец.

.PARAMETER PasswordLength
    Длина генерируемого пароля, от 8 до 64 символов. По умолчанию 12.

.PARAMETER PasswordNeverExpires
    Срок действия пароля не ограничен. Включено по умолчанию; с -PasswordNeverExpires:$false
    срок задаёт политика сервера (по умолчанию 42 дня).

.PARAMETER AccountExpires
    Когда учётная запись перестаёт действовать, например для временного сотрудника:
    -AccountExpires 2026-12-31 (с начала этого дня).

.PARAMETER ExtraGroups
    Дополнительные группы для всех создаваемых пользователей - по имени или по SID.

.PARAMETER LoginTemplate
    Шаблон логина из имени и фамилии: {f} - первая буква имени, {first} - имя, {last} - фамилия.
    По умолчанию {f}.{last}: Іван Петренко -> i.petrenko.

.EXAMPLE
    .\New-ServerUsers.ps1 -FirstName Іван -LastName Петренко -Phone '000 000 00 01' -Department Бухгалтерия
    Создаёт i.petrenko и показывает его пароль.

.EXAMPLE
    .\New-ServerUsers.ps1 -UserList D:\users.csv -WhatIf
    Проверяет список и показывает, кто будет создан, ничего не меняя.

.EXAMPLE
    .\New-ServerUsers.ps1 temp1 -AccountExpires 2026-12-31 -ExtraGroups 1C_Users
    Временная учётная запись с дополнительной группой.
#>
[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    # --- один пользователь ---
    [Parameter(Position = 0)]
    [Alias('Name')]
    [string]$Login,
    [string]$FirstName,
    [string]$LastName,
    [string]$FullName,
    [string]$Phone,
    [string]$Department,
    [string]$Position,
    [string]$Description,
    [string]$Password,

    # --- диалог или список ---
    [switch]$Interactive,
    [string]$UserList,   # пусто - New-ServerUsers.users.csv рядом со скриптом (см. ниже)

    # --- для всех режимов ---
    [string]$PasswordFile,

    [ValidateRange(8, 64)]
    [int]$PasswordLength = 12,

    [switch]$PasswordNeverExpires = $true,
    [datetime]$AccountExpires,
    [string[]]$ExtraGroups,
    [string]$LoginTemplate = '{f}.{last}'
)

# Не в значении по умолчанию в param(): в PowerShell 5.1 при запуске через powershell.exe -File
# (ярлык, планировщик) $PSScriptRoot там пуст у скрипта с [CmdletBinding()]
$defaultUserList = Join-Path $PSScriptRoot 'New-ServerUsers.users.csv'

$ErrorActionPreference = 'Stop'

function Get-ErrorText($ErrorRecord) { $ErrorRecord.Exception.GetBaseException().Message }

# --- Проверка параметров ---
$singleParams = @(foreach ($name in 'Login', 'FirstName', 'LastName', 'FullName', 'Phone', 'Department', 'Position', 'Description', 'Password') {
        if ($PSBoundParameters.ContainsKey($name)) { $name }
    })
if ($singleParams.Count -gt 0 -and ($Interactive -or $UserList)) {
    throw "Параметры одного пользователя (-$($singleParams -join ', -')) нельзя указывать вместе с -Interactive или -UserList."
}
if ($Interactive -and $UserList) { throw 'Укажите что-то одно: -Interactive или -UserList.' }
$accountExpiresSet = $PSBoundParameters.ContainsKey('AccountExpires')
if ($accountExpiresSet -and $AccountExpires -le (Get-Date)) {
    throw "Дата -AccountExpires ($AccountExpires) уже прошла: учётная запись была бы недействительной сразу."
}

if (-not (Get-Command New-LocalUser -ErrorAction SilentlyContinue)) {
    throw 'Не найдены командлеты локальных учётных записей (New-LocalUser). Нужна 64-разрядная консоль Windows PowerShell 5.1.'
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) {
    throw 'Запустите PowerShell от имени администратора: создавать учётные записи может только администратор.'
}

# --- Логин из имени и фамилии ---
# Украинская официальная транслитерация (КМУ 2010); русские буквы тоже обрабатываются.
function Convert-ToLatin([string]$Text) {
    # в начале слова
    $start = @{ 'є' = 'ye'; 'ї' = 'yi'; 'й' = 'y'; 'ю' = 'yu'; 'я' = 'ya'; 'ё' = 'yo' }
    # в остальных позициях
    $map = @{
        'а' = 'a'; 'б' = 'b'; 'в' = 'v'; 'г' = 'h'; 'ґ' = 'g'; 'д' = 'd'; 'е' = 'e'; 'є' = 'ie'; 'ж' = 'zh'
        'з' = 'z'; 'и' = 'y'; 'і' = 'i'; 'ї' = 'i'; 'й' = 'i'; 'к' = 'k'; 'л' = 'l'; 'м' = 'm'; 'н' = 'n'
        'о' = 'o'; 'п' = 'p'; 'р' = 'r'; 'с' = 's'; 'т' = 't'; 'у' = 'u'; 'ф' = 'f'; 'х' = 'kh'; 'ц' = 'ts'
        'ч' = 'ch'; 'ш' = 'sh'; 'щ' = 'shch'; 'ь' = ''; 'ю' = 'iu'; 'я' = 'ia'
        # русские
        'ы' = 'y'; 'э' = 'e'; 'ё' = 'io'; 'ъ' = ''
    }
    # апострофы (типографские задаём кодами: PowerShell считает их кавычками)
    $apos = @("'", '`', [string][char]0x2019, [string][char]0x02BC, [string][char]0x2018)
    foreach ($a in $apos) { $map[$a] = '' }
    $letterOrApos = '[\p{L}' + [regex]::Escape(-join $apos) + ']'

    $s = $Text.ToLower()
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = [string]$s[$i]
        $prev = if ($i -gt 0) { [string]$s[$i - 1] } else { '' }
        $atStart = ($i -eq 0) -or ($prev -notmatch $letterOrApos)

        # «зг» -> «zgh», чтобы не путать с «zh»
        if ($c -eq 'г' -and $prev -eq 'з') { [void]$sb.Append('gh'); continue }

        if ($atStart -and $start.ContainsKey($c)) { [void]$sb.Append($start[$c]) }
        elseif ($map.ContainsKey($c)) { [void]$sb.Append($map[$c]) }
        else { [void]$sb.Append($c) }
    }
    $sb.ToString()
}

function Get-CleanPart([string]$Text) { (Convert-ToLatin $Text) -replace '[^a-z0-9]', '' }

function Get-LoginFromName([string]$First, [string]$Last) {
    $f = Get-CleanPart $First
    $l = Get-CleanPart $Last
    if ($f -and $l) { return $LoginTemplate.Replace('{first}', $f).Replace('{last}', $l).Replace('{f}', $f.Substring(0, 1)) }
    if ($f) { return $f }
    return $l
}

function Get-LoginProblem([string]$Name) {
    if ($Name.Length -gt 20) { return 'Login длиннее 20 символов - Windows такой не примет' }
    if ($Name -match '["/\\\[\]:;|=,+*?<>@]' -or $Name.EndsWith('.')) { return 'в Login недопустимые для Windows символы' }
    return $null
}

# --- Группы ---
# Группы добавляются через net.exe: он обращается к группе напрямую по имени и работает
# и там, где Add-LocalGroupMember / Get-LocalGroup не видят групп из-за сбоя перечисления в SAM.
function Invoke-NetExe([string[]]$Arguments) {
    # иначе в PowerShell 5.1 сообщение net.exe в stderr превратится в исключение
    $ErrorActionPreference = 'Continue'
    $text = (& net.exe @Arguments 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' '
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
}

# Имя группы на этом сервере по имени или SID; $null - такой группы нет
$groupCache = @{}
function Resolve-LocalGroup([string]$Group) {
    $key = $Group.Trim()
    if ($groupCache.ContainsKey($key)) { return $groupCache[$key] }
    $name = $key
    if ($key -match '^S-1-') {
        try { $name = (New-Object Security.Principal.SecurityIdentifier $key).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1] }
        catch { $name = $null }
    }
    if ($name -and (Invoke-NetExe 'localgroup', $name).ExitCode -ne 0) { $name = $null }
    $groupCache[$key] = $name
    return $name
}

# По SID: в русской и украинской Windows группы называются по-другому.
# «Пользователи» и «Пользователи удалённого рабочего стола» (без второй не войти по RDP).
$defaultGroups = @(foreach ($sid in 'S-1-5-32-545', 'S-1-5-32-555') {
        $group = Resolve-LocalGroup $sid
        if (-not $group) { throw "Не найдена встроенная группа $sid на этом сервере." }
        $group
    })
foreach ($group in @($ExtraGroups | ForEach-Object { "$_".Trim() } | Where-Object { $_ })) {
    if (-not (Resolve-LocalGroup $group)) { throw "Группа «$group» из -ExtraGroups не найдена на этом сервере." }
}

# --- Данные пользователя ---
# Проверяет данные одного пользователя и приводит их к виду для создания.
# Problems пустой - всё в порядке.
function Resolve-UserSpec {
    param(
        [string]$Login, [string]$FirstName, [string]$LastName, [string]$FullName, [string]$Description,
        [string]$Department, [string]$Position, [string]$Phone, [string]$Password, [string[]]$Groups
    )

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $first = "$FirstName".Trim()
    $last = "$LastName".Trim()

    $name = "$Login".Trim()
    $auto = $false
    if (-not $name -and ($first -or $last)) {
        $name = Get-LoginFromName $first $last
        $auto = $true
        if (-not $name) { $problems.Add('из имени и фамилии не получился логин латиницей - задайте Login') }
    }
    if (-not $name) {
        if (-not $auto) { $problems.Add('не задан Login (или имя, чтобы составить его)') }
    }
    else {
        $problem = Get-LoginProblem $name
        if ($problem) { $problems.Add($problem) }
    }

    $full = "$FullName".Trim()
    if (-not $full) { $full = (@($first, $last) | Where-Object { $_ }) -join ' ' }

    $desc = "$Description".Trim()
    if (-not $desc) { $desc = (@($Department, $Position) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ', ' }
    if ($desc.Length -gt 48) {
        $problems.Add('описание (Description или Department и Position) длиннее 48 символов - столько вмещает учётная запись')
    }

    # пароль не обрезаем: пробел по краям может быть его частью
    $pass = "$Password"
    if (-not $pass.Trim()) { $pass = '' }

    $groupNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($group in $defaultGroups) { $groupNames.Add($group) }
    foreach ($group in @($Groups | ForEach-Object { "$_".Trim() } | Where-Object { $_ })) {
        $resolved = Resolve-LocalGroup $group
        if (-not $resolved) { $problems.Add("группа «$group» не найдена на этом сервере") }
        elseif ($groupNames -notcontains $resolved) { $groupNames.Add($resolved) }
    }

    [pscustomobject]@{
        Login       = $name
        AutoLogin   = $auto
        FullName    = $full
        Description = $desc
        Phone       = "$Phone".Trim()
        Password    = $pass
        Groups      = $groupNames.ToArray()
        Problems    = $problems.ToArray()
    }
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

$script:passwordEncoding = New-Object Text.UTF8Encoding $true
$script:passwordFileReady = $false
$script:passwordFileCreated = $false
$script:createdCount = 0

function Initialize-PasswordFile([string]$Header) {
    if ($script:passwordFileReady) { return }
    try {
        if (Test-Path -LiteralPath $PasswordFile -PathType Leaf) {
            # файл уже есть (указан -PasswordFile) - дописываем в конец в его же кодировке
            $bytes = [IO.File]::ReadAllBytes($PasswordFile)
            $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            if ($bytes.Length -eq 0) { [IO.File]::AppendAllText($PasswordFile, $Header + "`r`n", $script:passwordEncoding) }
            else {
                if (-not $hasBom) { $script:passwordEncoding = [Text.Encoding]::Default }
                if ($bytes[-1] -ne 10) { [IO.File]::AppendAllText($PasswordFile, "`r`n", $script:passwordEncoding) }
            }
        }
        else {
            New-ProtectedFile $PasswordFile
            [IO.File]::AppendAllText($PasswordFile, $Header + "`r`n", $script:passwordEncoding)
            $script:passwordFileCreated = $true
        }
    }
    catch { throw "Не удалось подготовить файл для паролей ${PasswordFile}, учётная запись не создана: $(Get-ErrorText $_)" }
    $script:passwordFileReady = $true
}

# --- Создание учётной записи ---
function New-UserAccount($User) {
    if (Get-LocalUser -Name $User.Login -ErrorAction SilentlyContinue) {
        $status = 'уже существует - не изменён'
        if ($User.AutoLogin) { $status += ' (логин составлен из имени; если это другой человек - задайте Login явно)' }
        return [pscustomobject]@{ Status = $status; Password = $null }
    }
    if (-not $PSCmdlet.ShouldProcess($User.Login, "создать учётную запись$(if ($User.FullName) { " ($($User.FullName))" })")) {
        return [pscustomobject]@{ Status = 'будет создан'; Password = $null }
    }

    $password = if ($User.Password) { $User.Password } else { New-Password $PasswordLength $User.Login }
    $record = [pscustomobject]@{ Login = $User.Login; FullName = $User.FullName; Phone = $User.Phone; Password = $password }
    $csv = @($record | ConvertTo-Csv -Delimiter ';' -NoTypeInformation)

    # Файл готовим до создания учётной записи: если записать пароль некуда,
    # лучше остановиться сразу, чем получить пользователя с неизвестным паролем.
    Initialize-PasswordFile $csv[0]

    $account = @{
        Name     = $User.Login
        Password = ConvertTo-SecureString $password -AsPlainText -Force
        Confirm  = $false
    }
    if ($User.FullName) { $account.FullName = $User.FullName }
    if ($User.Description) { $account.Description = $User.Description }
    if ($PasswordNeverExpires) { $account.PasswordNeverExpires = $true }
    if ($accountExpiresSet) { $account.AccountExpires = $AccountExpires }
    try { New-LocalUser @account | Out-Null }
    catch { return [pscustomobject]@{ Status = "ошибка: $(Get-ErrorText $_)"; Password = $null } }
    $script:createdCount++

    $notes = New-Object 'System.Collections.Generic.List[string]'
    # пароль записываем сразу, чтобы сбой на следующих пользователях его не потерял
    try { [IO.File]::AppendAllText($PasswordFile, $csv[1] + "`r`n", $script:passwordEncoding) }
    catch { $notes.Add("пароль НЕ записан в файл ($(Get-ErrorText $_)) - сохраните его: $password") }

    $failedGroups = @(foreach ($group in $User.Groups) {
            $net = Invoke-NetExe 'localgroup', $group, $User.Login, '/add'
            if ($net.ExitCode -ne 0) { "«$group» ($($net.Text))" }
        })
    if ($failedGroups) { $notes.Add("не добавлен в группу - добавьте вручную: $($failedGroups -join '; ')") }

    $status = if ($notes.Count) { "создан, но $($notes -join '; ')" } else { 'создан' }
    [pscustomobject]@{ Status = $status; Password = $password }
}

# Результат одного пользователя на экран (диалог и один пользователь): пароль нужен сразу
function Show-UserResult($User, $Result) {
    if ($Result.Password) {
        Write-Host "Создан: $($User.Login)$(if ($User.FullName) { " ($($User.FullName))" })" -ForegroundColor Green
        Write-Host "Пароль: $($Result.Password)" -ForegroundColor Green
        if ($Result.Status -ne 'создан') { Write-Host "  $($Result.Status)" -ForegroundColor Yellow }
    }
    else {
        $color = if ($Result.Status -like 'ошибка*') { 'Red' } else { 'Yellow' }
        Write-Host "$($User.Login): $($Result.Status)" -ForegroundColor $color
    }
}

# --- Режим работы ---
if ($singleParams.Count -gt 0) { $mode = 'Single' }
elseif ($Interactive) { $mode = 'Interactive' }
elseif ($UserList) { $mode = 'Batch' }
elseif ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    # без параметров при запуске вручную - спрашиваем
    Write-Host 'Что делаем?'
    Write-Host '  1 - добавить пользователей по одному, с вопросами'
    Write-Host "  2 - добавить всех из списка $defaultUserList$(if (-not (Test-Path -LiteralPath $defaultUserList)) { ' (файла пока нет)' })"
    $answer = "$(Read-Host 'Выбор [1]')".Trim()
    if (-not $answer -or $answer -eq '1') { $mode = 'Interactive' }
    elseif ($answer -eq '2') { $mode = 'Batch' }
    else { throw "Неизвестный выбор: $answer" }
}
else { $mode = 'Batch' }   # без консоли (планировщик) - список рядом со скриптом
if ($mode -eq 'Batch' -and -not $UserList) { $UserList = $defaultUserList }

# --- Список пользователей (пакетный режим) ---
if ($mode -eq 'Batch') {
    if (-not (Test-Path -LiteralPath $UserList -PathType Leaf)) {
        $hint = if ($UserList -eq $defaultUserList) { ' Скопируйте New-ServerUsers.users.example.csv в New-ServerUsers.users.csv и заполните.' } else { '' }
        throw "Файл со списком пользователей не найден: $UserList.$hint"
    }
    $UserList = (Resolve-Path -LiteralPath $UserList).ProviderPath
    # Файл могли сохранить и Блокнотом (UTF-8), и Excel (ANSI) - читаем оба варианта
    $text = [IO.File]::ReadAllText($UserList)
    if ($text.Contains([string][char]0xFFFD)) { $text = [IO.File]::ReadAllText($UserList, [Text.Encoding]::Default) }
    # Excel оставляет в конце строки из одних разделителей - их отбрасываем вместе с пустыми
    $lines = @($text -split "`r?`n" | Where-Object { $_ -match '[^\s;,]' })
    if ($lines.Count -lt 2) { throw "В файле $UserList нет ни одной записи." }
    $delimiter = if ($lines[0].Contains(';')) { ';' } else { ',' }
    $rows = @($lines | ConvertFrom-Csv -Delimiter $delimiter)

    $columns = @($rows[0].PSObject.Properties.Name)
    if (-not ($columns | Where-Object { $_ -in 'Login', 'FirstName', 'LastName' })) {
        throw "В файле $UserList нет столбца Login (или FirstName, LastName). Первая строка - названия столбцов, например: Login;FirstName;LastName;Department;Position;Phone"
    }
    $knownColumns = 'Login', 'FirstName', 'LastName', 'FullName', 'Password', 'Description', 'Department', 'Position', 'Phone', 'Groups'
    $unknownColumns = @($columns | Where-Object { $_ -notin $knownColumns })
    if ($unknownColumns) { Write-Warning "Эти столбцы скрипт не знает и пропускает: $($unknownColumns -join ', ')" }

    # Проверка списка: собираем все ошибки сразу
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    $number = 0
    $users = @(foreach ($row in $rows) {
            $number++
            $spec = Resolve-UserSpec -Login $row.Login -FirstName $row.FirstName -LastName $row.LastName -FullName $row.FullName `
                -Description $row.Description -Department $row.Department -Position $row.Position -Phone $row.Phone `
                -Password $row.Password -Groups (@("$($row.Groups)" -split '\|') + @($ExtraGroups))
            $where = "запись $number ($(if ($spec.Login) { $spec.Login } else { $spec.FullName }))"
            foreach ($problem in $spec.Problems) { $problems.Add("${where}: $problem") }
            if ($spec.Login) {
                if ($seen.ContainsKey($spec.Login)) {
                    $problems.Add("${where}: такой Login уже есть в списке$(if ($spec.AutoLogin) { ' (составлен из имени и фамилии - задайте Login явно)' })")
                }
                else { $seen[$spec.Login] = $true }
            }
            $spec
        })
    if ($problems.Count -gt 0) {
        $list = $problems -join "`n  - "
        throw "Список пользователей не прошёл проверку (файл $UserList), никто не создан:`n  - $list"
    }
}

# --- Файл с паролями ---
if (-not $PasswordFile) {
    $folder = if ($mode -eq 'Batch') { Split-Path $UserList } else { $PSScriptRoot }
    $PasswordFile = Join-Path $folder "New-ServerUsers.passwords_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').csv"
}
$PasswordFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PasswordFile)

# --- Создание ---
$results = New-Object 'System.Collections.Generic.List[object]'

switch ($mode) {
    'Single' {
        $user = Resolve-UserSpec -Login $Login -FirstName $FirstName -LastName $LastName -FullName $FullName `
            -Description $Description -Department $Department -Position $Position -Phone $Phone `
            -Password $Password -Groups $ExtraGroups
        if ($user.Problems) { throw "Пользователь не создан:`n  - $($user.Problems -join "`n  - ")" }
        $result = New-UserAccount $user
        Show-UserResult $user $result
        $results.Add([pscustomobject]@{ Login = $user.Login; FullName = $user.FullName; Status = $result.Status })
    }

    'Interactive' {
        Write-Host 'Добавление пользователей по одному. Чтобы закончить, оставьте имя пустым и нажмите Enter.'
        while ($true) {
            Write-Host ''
            $first = "$(Read-Host 'Имя')".Trim()
            if (-not $first) { break }
            $last = "$(Read-Host 'Фамилия (Enter - без фамилии)')".Trim()
            $phoneValue = "$(Read-Host 'Телефон (Enter - пропустить)')".Trim()
            $descriptionValue = "$(Read-Host 'Отдел, должность (Enter - пропустить)')".Trim()

            # свободный логин: занят - добавляем 2, 3, ...
            $suggested = Get-LoginFromName $first $last
            if ($suggested) {
                $base = $suggested
                $n = 2
                while (Get-LocalUser -Name $suggested -ErrorAction SilentlyContinue) { $suggested = "$base$n"; $n++ }
            }
            $typed = "$(Read-Host $(if ($suggested) { "Логин [$suggested]" } else { 'Логин' }))".Trim()
            $loginValue = if ($typed) { $typed } else { $suggested }

            $user = Resolve-UserSpec -Login $loginValue -FirstName $first -LastName $last -Phone $phoneValue `
                -Description $descriptionValue -Groups $ExtraGroups
            if ($user.Problems) {
                foreach ($problem in $user.Problems) { Write-Host "  $problem" -ForegroundColor Red }
                Write-Host '  Пользователь не создан - введите данные заново.' -ForegroundColor Yellow
                continue
            }
            $result = New-UserAccount $user
            Show-UserResult $user $result
            $results.Add([pscustomobject]@{ Login = $user.Login; FullName = $user.FullName; Status = $result.Status })
        }
    }

    'Batch' {
        foreach ($user in $users) {
            $result = New-UserAccount $user
            $results.Add([pscustomobject]@{ Login = $user.Login; FullName = $user.FullName; Status = $result.Status })
        }
    }
}

# --- Итог ---
# ни одной учётной записи не создано - новый файл с одним заголовком не нужен
if ($script:passwordFileCreated -and $script:createdCount -eq 0) { [IO.File]::Delete($PasswordFile) }

if ($mode -eq 'Batch' -or $results.Count -gt 1) {
    Write-Host ''
    $results | Format-Table Login, FullName, Status -AutoSize -Wrap
}
if ($script:createdCount -gt 0) {
    Write-Host "Создано учётных записей: $($script:createdCount). Логины и пароли: $PasswordFile"
    if ($script:passwordFileCreated) {
        Write-Warning 'Файл с паролями доступен только администраторам. После раздачи паролей удалите его.'
    }
    else { Write-Warning 'Пароли дописаны в существующий файл. После раздачи паролей удалите его.' }
}
if ($results | Where-Object { $_.Status -like 'ошибка*' -or $_.Status -like 'создан, но*' }) {
    Write-Warning 'Не всё прошло успешно - смотрите столбец Status. Несозданных можно создать повторным запуском, когда причина устранена.'
}
