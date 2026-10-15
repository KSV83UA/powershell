<#
.SYNOPSIS
    Бэкап пользовательских данных из профилей RDP-сервера: один zip-архив на пользователя.

.DESCRIPTION
    Для каждого профиля из -ProfilesRoot создаёт папку <BackupRoot>\<Пользователь>
    и кладёт в неё архив <Пользователь>_<дата_время>.zip.

    В архив попадает всё содержимое профиля (Рабочий стол, Документы, Загрузки, Изображения,
    Видео, Музыка, Избранное и любые папки и файлы, созданные пользователем), кроме системного:
      - AppData и прочие папки и файлы из -Exclude (в корне профиля или на любой глубине),
        если только они не названы в -Include;
      - скрытые и системные объекты в корне профиля (NTUSER.DAT и т.п.);
      - системные файлы внутри папок (desktop.ini, Thumbs.db);
      - junction-ссылки и символические ссылки на папки.

    Файлы, которые не удалось прочитать (заняты другим процессом, нет доступа), пропускаются
    и перечисляются в <Пользователь>_<дата_время>.log рядом с архивом.
    Пока архив пишется, он называется *.zip.partial.

    Запускать от имени администратора, иначе чужие профили не прочитать.

    Настройки берутся из файла конфигурации Backup-UserProfiles.config.psd1 рядом со скриптом
    (откуда копировать, куда, какие профили исключить). Перед началом работы настройки
    проверяются, и при ошибках скрипт перечисляет их все и ничего не копирует.
    Любой параметр командной строки имеет приоритет над значением из файла.

.PARAMETER ConfigPath
    Путь к файлу конфигурации. По умолчанию - Backup-UserProfiles.config.psd1 рядом со скриптом.

.PARAMETER ProfilesRoot
    Папка с профилями, полный путь. Локальная (C:\Users) или сетевая (\\RDS01\C$\Users).

.PARAMETER BackupRoot
    Куда складывать бэкап, полный путь.

.PARAMETER User
    Имена папок профилей, которые нужно обработать (можно с * и ?). По умолчанию - все.

.PARAMETER ExcludeUser
    Профили, которые обрабатывать не нужно (можно с * и ?).

.PARAMETER Exclude
    Папки и файлы, которые не попадают в архив. Каждая запись - путь относительно корня профиля,
    можно с * и ? (* заменяет любое число символов, включая \):
      'AppData'                  - папка в корне профиля;
      'Documents\Outlook Files'  - вложенная папка;
      'Downloads\*.iso'          - файлы по маске в одной папке и её подпапках;
      '*\Cache'                  - папка Cache на любой глубине, кроме корня;
      '*.tmp'                    - файлы по маске где угодно.
    Список действует на все профили.

.PARAMETER Include
    Файлы и папки, которые попадают в архив, даже если лежат в исключённой папке (например,
    в AppData) или скрыты. Каждая запись - точный путь относительно корня профиля, без масок:
      'AppData\Roaming\1C\1CEStart\ibases.v8i'  - один файл;
      'AppData\Roaming\1C\1CEStart'             - папка целиком.
    В архиве объект лежит по тому же пути. У кого его в профиле нет, для того запись не срабатывает.

.PARAMETER CompressionLevel
    Optimal - меньше размер, Fastest - заметно быстрее на больших объёмах, NoCompression - без сжатия.

.EXAMPLE
    .\Backup-UserProfiles.ps1
    Все настройки - из Backup-UserProfiles.config.psd1 рядом со скриптом.

.EXAMPLE
    .\Backup-UserProfiles.ps1 -WhatIf
    Проверяет настройки и показывает, какие профили будут обработаны, ничего не копируя.

.EXAMPLE
    .\Backup-UserProfiles.ps1 -ConfigPath D:\Scripts\rds02.psd1 -User ivanov, petrov*
    Другой файл конфигурации, и только выбранные пользователи.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Backup-UserProfiles.config.psd1'),

    [string]$ProfilesRoot,

    [string]$BackupRoot,

    [string[]]$User,

    [string[]]$ExcludeUser,

    [string[]]$Exclude,

    [string[]]$Include,

    [ValidateSet('Optimal', 'Fastest', 'NoCompression')]
    [string]$CompressionLevel
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Test-Like([string]$Name, [string[]]$Patterns) {
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    return $false
}

# Префикс \\?\ снимает ограничение в 260 символов. Понимает его только .NET 4.6.2+,
# на более старых системах работаем без него (слишком длинные пути попадут в лог).
$useLongPath = try { [IO.Directory]::Exists('\\?\' + $env:SystemRoot) } catch { $false }
function ConvertTo-LongPath([string]$Path) {
    if (-not $useLongPath -or $Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}
# Текст ошибки для лога, без служебного префикса \\?\ в путях
function Get-ErrorText($ErrorRecord) {
    $ErrorRecord.Exception.GetBaseException().Message.Replace('\\?\UNC\', '\\').Replace('\\?\', '')
}

# --- Настройки: параметр командной строки > файл конфигурации > значение по умолчанию ---
$defaults = @{
    User             = @('*')
    ExcludeUser      = @('Public', 'Default', 'Default User', 'All Users', 'defaultuser*', 'TEMP', 'TEMP.*', '.NET v*', 'MSSQL*')
    Exclude          = @('AppData', 'Searches', 'Links', 'Saved Games', '3D Objects', 'MicrosoftEdgeBackups', 'IntelGraphicsProfiles', '.*')
    Include          = @()
    CompressionLevel = 'Optimal'
}
$settingNames = 'ProfilesRoot', 'BackupRoot', 'User', 'ExcludeUser', 'Exclude', 'Include', 'CompressionLevel'
$problems = New-Object 'System.Collections.Generic.List[string]'

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
    foreach ($key in $config.Keys) {
        if ($settingNames -notcontains $key) {
            $problems.Add("${key}: неизвестная настройка. Допустимые: $($settingNames -join ', ')")
        }
    }
}
elseif ($PSBoundParameters.ContainsKey('ConfigPath')) { throw "Файл конфигурации не найден: $ConfigPath" }
else { $ConfigPath = $null }

$settings = @{}
foreach ($key in $settingNames) {
    if ($PSBoundParameters.ContainsKey($key)) { $settings[$key] = $PSBoundParameters[$key] }
    elseif ($config.ContainsKey($key)) { $settings[$key] = $config[$key] }
    else { $settings[$key] = $defaults[$key] }
}

# --- Проверка настроек: собираем все ошибки сразу, чтобы не исправлять по одной ---
$pathOk = @{}
foreach ($key in 'ProfilesRoot', 'BackupRoot') {
    $value = $settings[$key]
    $pathOk[$key] = $false
    if ($null -eq $value -or ($value -is [string] -and -not $value.Trim())) { $problems.Add("${key}: не задан") }
    elseif ($value -isnot [string]) { $problems.Add("${key}: должен быть одной строкой с путём") }
    elseif ($value -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') {
        # относительный путь зависел бы от текущей папки, а у задания планировщика это System32
        $problems.Add("${key}: '$value' - нужен полный путь: с буквой диска или вида \\сервер\папка")
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
if ($pathOk.BackupRoot) {
    $backupDrive = try { [IO.Path]::GetPathRoot($settings.BackupRoot) } catch { $null }
    if (-not $backupDrive -or -not (Test-Path -LiteralPath $backupDrive)) {
        $problems.Add("BackupRoot: диск или сетевая папка для '$($settings.BackupRoot)' недоступны")
    }
    elseif ($pathOk.ProfilesRoot -and $settings.BackupRoot.TrimEnd('\') -eq $settings.ProfilesRoot.TrimEnd('\')) {
        $problems.Add('BackupRoot: совпадает с ProfilesRoot - складывать бэкап в саму папку профилей нельзя')
    }
}
foreach ($key in 'User', 'ExcludeUser', 'Exclude', 'Include') {
    if (@(@($settings[$key]) | Where-Object { $_ -isnot [string] -or -not $_.Trim() }).Count -gt 0) {
        $problems.Add("${key}: в списке должны быть только непустые строки в кавычках")
    }
}
foreach ($key in 'Exclude', 'Include') {
    foreach ($value in @($settings[$key])) {
        if ($value -is [string] -and $value -match '^\s*([A-Za-z]:|[\\/]{2})') {
            $problems.Add("${key}: '$value' - нужен путь относительно корня профиля, например 'Documents\Архив', а не полный")
        }
    }
}
foreach ($value in @($settings.Include)) {
    if ($value -isnot [string]) { continue }
    if ($value -match '[*?]') { $problems.Add("Include: '$value' - маски здесь не работают, нужен точный путь к файлу или папке") }
    if ($value -match '(^|[\\/])\.\.([\\/]|$)') { $problems.Add("Include: '$value' - путь не должен выходить из профиля через '..'") }
}
if (@($settings.User).Count -eq 0) { $problems.Add('User: список пуст - обрабатывать некого') }
$levels = 'Optimal', 'Fastest', 'NoCompression'
if ($levels -notcontains $settings.CompressionLevel) {
    $problems.Add("CompressionLevel: '$($settings.CompressionLevel)' - допустимо только $($levels -join ', ')")
}

if ($problems.Count -gt 0) {
    $source = if ($ConfigPath) { "файл $ConfigPath" } else { 'файл конфигурации не найден, только параметры запуска' }
    $list = $problems -join "`n  - "
    throw "Настройки не прошли проверку ($source):`n  - $list"
}

$ProfilesRoot = (Resolve-Path -LiteralPath $settings.ProfilesRoot).ProviderPath
$BackupRoot = $settings.BackupRoot
$User = $settings.User
$ExcludeUser = $settings.ExcludeUser
$Exclude = $settings.Exclude
$Include = $settings.Include
$CompressionLevel = $settings.CompressionLevel
$backupLong = (ConvertTo-LongPath $BackupRoot).TrimEnd('\')

Write-Host "Настройки:  $(if ($ConfigPath) { $ConfigPath } else { 'параметры запуска, файла конфигурации нет' })"
Write-Host "Источник:   $ProfilesRoot"
Write-Host "Назначение: $BackupRoot"
Write-Host "Исключены:  $(if ($ExcludeUser) { $ExcludeUser -join ', ' } else { '(никто)' })"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $ProfilesRoot.StartsWith('\\')) {
    Write-Warning 'Скрипт запущен без прав администратора: чужие профили, скорее всего, прочитать не получится.'
}

$fa = [IO.FileAttributes]
$hiddenOrSystem = $fa::Hidden -bor $fa::System
# Offline | RECALL_ON_DATA_ACCESS: файл OneDrive лежит только в облаке, чтение запустило бы его скачивание
$cloudOnly = 0x1000 -bor 0x400000
# Исключения сравниваются с путём объекта внутри архива, а там разделитель - '/'
$excludePatterns = @($Exclude | ForEach-Object { $_.Replace('\', '/').Trim('/') })
# Include - точные пути, которые берутся в архив вопреки исключениям. Запись, лежащая внутри
# другой записи, лишняя: папка и так берётся целиком, а дважды в архив попадать нельзя.
$includeAll = @($Include | ForEach-Object { $_.Replace('\', '/').Trim('/') } | Where-Object { $_ } | Sort-Object -Unique)
$includePaths = @($includeAll | Where-Object {
        $path = $_
        -not ($includeAll | Where-Object { $path.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) })
    })
$share = [IO.FileShare]'ReadWrite, Delete'
$level = [IO.Compression.CompressionLevel]$CompressionLevel
$buffer = New-Object byte[] 1MB
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'

$userDirs = @(Get-ChildItem -LiteralPath $ProfilesRoot -Directory -Force | Where-Object {
        -not ($_.Attributes -band $fa::ReparsePoint) -and
        (Test-Like $_.Name $User) -and -not (Test-Like $_.Name $ExcludeUser) -and
        # папка бэкапа, если она лежит прямо в папке профилей, - не профиль
        $_.FullName.TrimEnd('\') -ne $BackupRoot.TrimEnd('\')
    })
if ($userDirs.Count -eq 0) {
    Write-Warning "В $ProfilesRoot не найдено подходящих профилей."
    return
}

# Щелчок мышью в окне консоли включает выделение текста (QuickEdit), и скрипт замирает на первом же
# выводе, пока не нажмут Enter. На время работы отключаем этот режим, в конце возвращаем как было.
$savedConsoleMode = $null
try {
    Add-Type -Namespace BackupUserProfiles -Name ConsoleMode -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@
    $stdinHandle = [BackupUserProfiles.ConsoleMode]::GetStdHandle(-10)
    [uint32]$mode = 0
    if ([BackupUserProfiles.ConsoleMode]::GetConsoleMode($stdinHandle, [ref]$mode)) {
        $savedConsoleMode = $mode
        # снять ENABLE_QUICK_EDIT_MODE (0x40); без ENABLE_EXTENDED_FLAGS (0x80) изменение не применяется
        [void][BackupUserProfiles.ConsoleMode]::SetConsoleMode($stdinHandle, [uint32](($mode -band 0xFFFFFFBF) -bor 0x80))
    }
}
catch { }   # консоли нет (планировщик задач, ISE) - отключать нечего

try {
    $n = 0
    $summary = foreach ($userDir in $userDirs) {
        $n++
        $name = $userDir.Name
        $destDir = Join-Path $BackupRoot $name
        $zipPath = Join-Path $destDir "${name}_$stamp.zip"
        $tmpPath = "$zipPath.partial"
        if (-not $PSCmdlet.ShouldProcess($userDir.FullName, "архивировать в $zipPath")) { continue }

        $status = "$name ($n из $($userDirs.Count))"
        $percent = 100 * ($n - 1) / $userDirs.Count
        Write-Progress -Activity 'Бэкап профилей' -Status $status -PercentComplete $percent
        Write-Host "[$n/$($userDirs.Count)] $name ... " -NoNewline

        [void][IO.Directory]::CreateDirectory($destDir)
        $skipped = New-Object 'System.Collections.Generic.List[string]'
        $files = 0
        $bytes = [long]0
        $readBytes = [long]0
        $clock = [Diagnostics.Stopwatch]::StartNew()

        $fs = [IO.File]::Open($tmpPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $zip = New-Object IO.Compression.ZipArchive ($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            # Обход без рекурсии. В стеке четвёрки: полный путь папки, её путь внутри архива,
            # признак «взять всё вопреки исключениям» (Include) и имя единственного нужного объекта.
            $stack = New-Object System.Collections.Stack
            $stack.Push(@((ConvertTo-LongPath $userDir.FullName), '', $false, $null))
            foreach ($path in $includePaths) {
                # заходим в папку, где лежит объект из Include, и берём из неё только его
                $cut = $path.LastIndexOf('/')
                $parentRel = ''
                $parent = $userDir.FullName
                if ($cut -ge 0) {
                    $parentRel = $path.Substring(0, $cut)
                    $parent = Join-Path $parent $parentRel.Replace('/', '\')
                }
                $parent = ConvertTo-LongPath $parent
                # у кого такой папки нет, для того запись просто не срабатывает
                if ([IO.Directory]::Exists($parent)) { $stack.Push(@($parent, $parentRel, $true, $path.Substring($cut + 1))) }
            }
            while ($stack.Count -gt 0) {
                $dir, $rel, $forced, $only = $stack.Pop()
                try {
                    $info = New-Object IO.DirectoryInfo $dir
                    $items = @(if ($only) { $info.GetFileSystemInfos($only) | Where-Object { $_.Name -eq $only } }
                        else { $info.GetFileSystemInfos() })
                }
                catch {
                    $skipped.Add("$rel/`t$(Get-ErrorText $_)")
                    continue
                }
                if ($items.Count -eq 0) {
                    # пустую папку сохраняем отдельной записью, иначе она пропадёт из архива
                    if ($rel -and -not $only) { [void]$zip.CreateEntry("$rel/") }
                    continue
                }

                foreach ($item in $items) {
                    $attr = $item.Attributes
                    $itemRel = $item.Name
                    if ($rel) { $itemRel = "$rel/$itemRel" }

                    if (-not $forced) {
                        # в корне профиля пропускаем скрытое и системное, глубже - только системное (desktop.ini)
                        if ($rel) { if ($attr -band $fa::System) { continue } }
                        elseif ($attr -band $hiddenOrSystem) { continue }
                        # без вызова функции: проверка выполняется для каждого файла
                        $excluded = $false
                        foreach ($pattern in $excludePatterns) { if ($itemRel -like $pattern) { $excluded = $true; break } }
                        if ($excluded) { continue }
                        # объект из Include добавляется своим проходом, второй раз он не нужен
                        if ($includePaths -contains $itemRel) { continue }
                    }

                    if ($attr -band $fa::Directory) {
                        # Ссылки не обходим: в профиле это ссылки совместимости («Моя музыка» и т.п.).
                        # Папку бэкапа тоже, если она оказалась внутри профиля.
                        if (($attr -band $fa::ReparsePoint) -or $item.FullName.TrimEnd('\') -eq $backupLong) { continue }
                        $stack.Push(@($item.FullName, $itemRel, $forced, $null))
                        continue
                    }

                    if ([int]$attr -band $cloudOnly) {
                        $skipped.Add("$itemRel`tфайл только в облаке (OneDrive), локальной копии нет")
                        continue
                    }

                    try { $src = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share) }
                    catch {
                        $skipped.Add("$itemRel`t$(Get-ErrorText $_)")
                        continue
                    }
                    try {
                        $entry = $zip.CreateEntry($itemRel, $level)
                        # zip хранит даты только в диапазоне 1980-2107
                        $year = $item.LastWriteTime.Year
                        if ($year -ge 1980 -and $year -le 2107) { $entry.LastWriteTime = $item.LastWriteTime }

                        $dst = $entry.Open()
                        try {
                            # Читаем вручную, а не через CopyTo: ошибка чтения - это пропуск одного файла,
                            # а ошибка записи (кончилось место, пропала сеть) должна остановить скрипт.
                            $complete = $true
                            while ($true) {
                                try { $read = $src.Read($buffer, 0, $buffer.Length) }
                                catch {
                                    $skipped.Add("$itemRel`tпрочитан не полностью: $(Get-ErrorText $_)")
                                    $complete = $false
                                    break
                                }
                                if ($read -le 0) { break }
                                $dst.Write($buffer, 0, $read)

                                # Ход работы внутри профиля, чтобы большой профиль не выглядел зависшим.
                                # Не чаще раза в секунду: Write-Progress в PowerShell 5.1 медленный.
                                $readBytes += $read
                                if ($clock.ElapsedMilliseconds -ge 1000) {
                                    Write-Progress -Activity 'Бэкап профилей' -Status $status -PercentComplete $percent `
                                        -CurrentOperation ('файлов: {0}, {1:n0} МБ - {2}' -f $files, ($readBytes / 1MB), $itemRel)
                                    $clock.Restart()
                                }
                            }
                        }
                        finally { $dst.Dispose() }
                        if ($complete) { $files++; $bytes += $item.Length }
                    }
                    finally { $src.Dispose() }
                }
            }
        }
        finally {
            $zip.Dispose()
            $fs.Dispose()
        }

        if ($files -gt 0) { [IO.File]::Move($tmpPath, $zipPath) }
        else { [IO.File]::Delete($tmpPath) }

        if ($skipped.Count -gt 0) {
            Set-Content -LiteralPath (Join-Path $destDir "${name}_$stamp.log") -Value $skipped -Encoding UTF8
        }
        elseif ($files -eq 0 -and -not (Get-ChildItem -LiteralPath $destDir -Force)) {
            # в профиле нет пользовательских данных - пустую папку не оставляем
            [IO.Directory]::Delete($destDir)
        }

        $archiveMB = if ($files -gt 0) { [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1) } else { 0 }
        $sourceMB = [math]::Round($bytes / 1MB, 1)
        Write-Host "файлов: $files, $sourceMB МБ -> $archiveMB МБ, пропущено: $($skipped.Count)"

        [pscustomobject]@{
            User      = $name
            Files     = $files
            SourceMB  = $sourceMB
            ArchiveMB = $archiveMB
            Skipped   = $skipped.Count
        }
    }
}
finally {
    Write-Progress -Activity 'Бэкап профилей' -Completed
    if ($null -ne $savedConsoleMode) {
        [void][BackupUserProfiles.ConsoleMode]::SetConsoleMode($stdinHandle, $savedConsoleMode)
    }
}

$summary | Format-Table -AutoSize
if ($summary | Where-Object { $_.Skipped -gt 0 }) {
    Write-Warning "Часть файлов пропущена - смотрите *_$stamp.log в папках пользователей в $BackupRoot."
}
