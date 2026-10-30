<#
.SYNOPSIS
    Копирует список баз 1С (ibases.v8i) из каждого профиля в папку этого пользователя.

.DESCRIPTION
    Для каждого профиля из ProfilesRoot берёт файл AppData\Roaming\1C\1CEStart\ibases.v8i
    и кладёт его в <папка назначения>\<Пользователь>\ibases.v8i.

    Настройки - откуда, куда и какие профили пропустить - берутся из того же файла, что и у
    Backup-UserProfiles.ps1 (Backup-UserProfiles.config.psd1 рядом со скриптом), поэтому файл
    попадает в те же папки пользователей, где лежат архивы. Параметры командной строки имеют
    приоритет над файлом.

    Если в папке пользователя уже есть копия с прошлого запуска, она заменяется свежей.
    Профили, в которых файла нет, пропускаются.

    Запускать от имени администратора, иначе чужие профили не прочитать.

.PARAMETER ConfigPath
    Путь к файлу конфигурации. По умолчанию - Backup-UserProfiles.config.psd1 рядом со скриптом.

.PARAMETER ProfilesRoot
    Папка с профилями, полный путь. Локальная (C:\Users) или сетевая (\\RDS01\C$\Users).

.PARAMETER Destination
    Куда складывать, полный путь. По умолчанию - BackupRoot из файла конфигурации.

.PARAMETER User
    Имена папок профилей, которые нужно обработать (можно с * и ?). По умолчанию - все.

.PARAMETER ExcludeUser
    Профили, которые обрабатывать не нужно (можно с * и ?).

.PARAMETER RelativePath
    Какой файл копировать: путь относительно корня профиля.

.EXAMPLE
    .\Copy-1CBaseList.ps1
    Все настройки - из Backup-UserProfiles.config.psd1.

.EXAMPLE
    .\Copy-1CBaseList.ps1 -WhatIf
    Показывает, у кого файл есть и куда он будет скопирован, ничего не копируя.

.EXAMPLE
    .\Copy-1CBaseList.ps1 -Destination D:\1C-Bases -User accounter*
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Backup-UserProfiles.config.psd1'),

    [string]$ProfilesRoot,

    [string]$Destination,

    [string[]]$User,

    [string[]]$ExcludeUser,

    [string]$RelativePath = 'AppData\Roaming\1C\1CEStart\ibases.v8i'
)

$ErrorActionPreference = 'Stop'

function Test-Like([string]$Name, [string[]]$Patterns) {
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    return $false
}
function Get-ErrorText($ErrorRecord) { $ErrorRecord.Exception.GetBaseException().Message }

# --- Настройки: параметр командной строки > файл конфигурации > значение по умолчанию ---
$config = @{}
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
    # Читаем сами, а не через Import-PowerShellDataFile: тот в PowerShell 5.1 принимает UTF-8 без BOM
    # за ANSI и молча портит кириллицу в именах профилей. Здесь годятся UTF-8 (с BOM и без) и ANSI.
    $text = [IO.File]::ReadAllText($ConfigPath)
    if ($text.Contains([string][char]0xFFFD)) { $text = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::Default) }
    try {
        $block = [scriptblock]::Create($text)
        # в файле допустимы только данные, без команд и переменных
        $block.CheckRestrictedLanguage([string[]]@(), [string[]]@(), $false)
        $config = & $block
    }
    catch { throw "Файл конфигурации $ConfigPath не читается: $(Get-ErrorText $_)" }
    if ($config -isnot [hashtable]) { throw "Файл конфигурации $ConfigPath должен содержать одну таблицу @{ ... }." }
}
elseif ($PSBoundParameters.ContainsKey('ConfigPath')) { throw "Файл конфигурации не найден: $ConfigPath" }
else { $ConfigPath = $null }

# Папка назначения в файле конфигурации называется BackupRoot: она общая со скриптом бэкапа
$settings = @{
    ProfilesRoot = $config['ProfilesRoot']
    Destination  = $config['BackupRoot']
    User         = @('*')
    ExcludeUser  = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser*', 'TEMP', 'TEMP.*', '.NET v*', 'MSSQL*')
}
foreach ($key in 'User', 'ExcludeUser') { if ($config.ContainsKey($key)) { $settings[$key] = $config[$key] } }
foreach ($key in 'ProfilesRoot', 'Destination', 'User', 'ExcludeUser') {
    if ($PSBoundParameters.ContainsKey($key)) { $settings[$key] = $PSBoundParameters[$key] }
}

# --- Проверка настроек: собираем все ошибки сразу ---
$problems = New-Object 'System.Collections.Generic.List[string]'
$pathOk = @{}
foreach ($key in 'ProfilesRoot', 'Destination') {
    $value = $settings[$key]
    $pathOk[$key] = $false
    # в файле конфигурации папка назначения записана как BackupRoot - так её и называем в сообщении
    $label = if ($key -eq 'Destination' -and $ConfigPath -and -not $PSBoundParameters.ContainsKey('Destination')) { 'BackupRoot' } else { $key }
    if ($null -eq $value -or ($value -is [string] -and -not $value.Trim())) { $problems.Add("${label}: не задан") }
    elseif ($value -isnot [string]) { $problems.Add("${label}: должен быть одной строкой с путём") }
    elseif ($value -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') {
        $problems.Add("${label}: '$value' - нужен полный путь: с буквой диска или вида \\сервер\папка")
    }
    else { $pathOk[$key] = $true }
}
# try: на пути с недопустимыми символами Test-Path и GetPathRoot не возвращают $false, а падают
if ($pathOk.ProfilesRoot) {
    $pathOk.ProfilesRoot = try { Test-Path -LiteralPath $settings.ProfilesRoot -PathType Container } catch { $false }
    if (-not $pathOk.ProfilesRoot) {
        $problems.Add("ProfilesRoot: папка '$($settings.ProfilesRoot)' не найдена или недоступна")
    }
}
if ($pathOk.Destination) {
    $drive = try { [IO.Path]::GetPathRoot($settings.Destination) } catch { $null }
    if (-not $drive -or -not (Test-Path -LiteralPath $drive)) {
        $problems.Add("Папка назначения: диск или сетевая папка для '$($settings.Destination)' недоступны")
    }
    elseif ($pathOk.ProfilesRoot -and $settings.Destination.TrimEnd('\') -eq $settings.ProfilesRoot.TrimEnd('\')) {
        $problems.Add('Папка назначения совпадает с ProfilesRoot - складывать копии в саму папку профилей нельзя')
    }
}
foreach ($key in 'User', 'ExcludeUser') {
    if (@(@($settings[$key]) | Where-Object { $_ -isnot [string] -or -not $_.Trim() }).Count -gt 0) {
        $problems.Add("${key}: в списке должны быть только непустые строки в кавычках")
    }
}
if (@($settings.User).Count -eq 0) { $problems.Add('User: список пуст - обрабатывать некого') }
if (-not $RelativePath.Trim() -or $RelativePath -match '^\s*([A-Za-z]:|[\\/]{2})' -or
    $RelativePath -match '[*?]' -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
    $problems.Add("RelativePath: '$RelativePath' - нужен точный путь к файлу относительно корня профиля, без масок")
}

if ($problems.Count -gt 0) {
    $source = if ($ConfigPath) { "файл $ConfigPath" } else { 'файл конфигурации не найден, только параметры запуска' }
    $list = $problems -join "`n  - "
    throw "Настройки не прошли проверку ($source):`n  - $list"
}

$ProfilesRoot = (Resolve-Path -LiteralPath $settings.ProfilesRoot).ProviderPath
$Destination = $settings.Destination
$User = $settings.User
$ExcludeUser = $settings.ExcludeUser
$RelativePath = $RelativePath.Trim().Trim('\', '/')
$fileName = Split-Path $RelativePath -Leaf

Write-Host "Настройки:  $(if ($ConfigPath) { $ConfigPath } else { 'параметры запуска, файла конфигурации нет' })"
Write-Host "Источник:   $ProfilesRoot"
Write-Host "Назначение: $Destination"
Write-Host "Файл:       $RelativePath"
Write-Host "Исключены:  $(if ($ExcludeUser) { $ExcludeUser -join ', ' } else { '(никто)' })"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $ProfilesRoot.StartsWith('\\')) {
    Write-Warning 'Скрипт запущен без прав администратора: чужие профили, скорее всего, прочитать не получится.'
}

$userDirs = @(Get-ChildItem -LiteralPath $ProfilesRoot -Directory -Force | Where-Object {
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
        (Test-Like $_.Name $User) -and -not (Test-Like $_.Name $ExcludeUser) -and
        # папка назначения, если она лежит прямо в папке профилей, - не профиль
        $_.FullName.TrimEnd('\') -ne $Destination.TrimEnd('\')
    })
if ($userDirs.Count -eq 0) {
    Write-Warning "В $ProfilesRoot не найдено подходящих профилей."
    return
}

$copied = 0
$results = foreach ($userDir in $userDirs) {
    $source = Join-Path $userDir.FullName $RelativePath
    $target = Join-Path (Join-Path $Destination $userDir.Name) $fileName
    $status = 'файла нет'
    try {
        # Пробное открытие вместо Test-Path: тот на недоступном профиле ответил бы «файла нет»,
        # а здесь отказ в доступе приходит ошибкой и попадает в столбец Status.
        [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete').Dispose()
        if ($PSCmdlet.ShouldProcess($source, "копировать в $target")) {
            $existed = Test-Path -LiteralPath $target
            [void][IO.Directory]::CreateDirectory((Split-Path $target))
            # прежняя копия могла унаследовать от оригинала «только чтение» - иначе её не заменить
            if ($existed) { [IO.File]::SetAttributes($target, [IO.FileAttributes]::Normal) }
            [IO.File]::Copy($source, $target, $true)
            $copied++
            $status = if ($existed) { 'скопирован, прежняя копия заменена' } else { 'скопирован' }
        }
        else { $status = 'будет скопирован' }
    }
    catch {
        $failure = $_.Exception.GetBaseException()
        $missing = $failure -is [IO.FileNotFoundException] -or $failure -is [IO.DirectoryNotFoundException]
        if (-not $missing) { $status = "ошибка: $($failure.Message)" }
    }

    [pscustomobject]@{ User = $userDir.Name; Status = $status }
}

$results | Format-Table -AutoSize -Wrap
Write-Host "Скопировано файлов: $copied (профилей просмотрено: $($userDirs.Count))."
if ($results | Where-Object { $_.Status -like 'ошибка*' }) {
    Write-Warning 'У части профилей файл скопировать не удалось - смотрите столбец Status.'
}
