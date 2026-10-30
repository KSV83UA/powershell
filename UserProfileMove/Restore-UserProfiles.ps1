#Requires -Version 5.1

<#
.SYNOPSIS
    Переносит данные пользователей из архивов Backup-UserProfiles.ps1 в их профили на новом сервере.

.DESCRIPTION
    Для каждой папки пользователя в BackupRoot (так их раскладывает Backup-UserProfiles.ps1):
      - берёт самый свежий архив из этой папки;
      - находит локальную учётную запись с тем же логином, что и имя папки (учётные записи нужно
        создать заранее, например скриптом New-ServerUsers.ps1);
      - если пользователь уже входил на сервер, копирует данные в его существующий профиль;
        если профиля ещё нет, создаёт его - входить под пользователем не нужно;
      - если папка с именем пользователя есть, но это профиль другой (например, удалённой)
        учётной записи, пропускает пользователя и сообщает об этом;
      - распаковывает архив в профиль: Рабочий стол, Документы и остальное ложится на свои места;
      - если рядом с архивом лежит ibases.v8i (от Copy-1CBaseList.ps1), а в профиле своего
        ещё нет, кладёт его в AppData\Roaming\1C\1CEStart.

    Файлы, которые в профиле уже есть, не перезаписываются. Поэтому повторный запуск безопасен
    и не затрёт то, что пользователь успел изменить на новом сервере. Пропущенные и не распакованные
    файлы перечисляются в <Пользователь>_restore_<дата_время>.log рядом с архивом.

    Профиль пользователя, который сейчас в системе, не трогается - сначала завершите его сеанс.

    Запускать на новом сервере от имени администратора, лучше до первого входа пользователей.

.PARAMETER ConfigPath
    Файл конфигурации, из которого берётся BackupRoot. По умолчанию - Backup-UserProfiles.config.psd1
    рядом со скриптом.

.PARAMETER BackupRoot
    Папка с бэкапом: в ней папки пользователей с архивами. Имеет приоритет над файлом конфигурации.

.PARAMETER User
    Каких пользователей восстанавливать: имена папок в BackupRoot, можно с * и ?. По умолчанию - всех.

.EXAMPLE
    .\Restore-UserProfiles.ps1 -BackupRoot D:\ProfileBackup -WhatIf
    Показывает, кого и из какого архива можно восстановить, ничего не меняя.

.EXAMPLE
    .\Restore-UserProfiles.ps1 -BackupRoot D:\ProfileBackup

.EXAMPLE
    .\Restore-UserProfiles.ps1 -BackupRoot D:\ProfileBackup -User i.petrenko
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Backup-UserProfiles.config.psd1'),

    [string]$BackupRoot,

    [string[]]$User = '*'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
# Модуль загружаем сами и не в режиме -WhatIf: иначе при загрузке он выводит десяток строк «What if: Set Alias»
$savedWhatIf = $WhatIfPreference
$WhatIfPreference = $false
Import-Module CimCmdlets
$WhatIfPreference = $savedWhatIf

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

# Профиль пользователя: путь и признак «пользователь сейчас в системе». $null - профиля ещё нет.
function Get-UserProfile([string]$Sid) {
    $found = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$Sid'"
    if ($found) { [pscustomobject]@{ Path = $found.LocalPath; Loaded = [bool]$found.Loaded } }
}

# CreateProfile создаёт профиль так же, как первый вход в систему, но без входа под пользователем
function New-UserProfile([string]$Sid, [string]$Login) {
    $path = New-Object Text.StringBuilder 260
    $result = [RestoreUserProfiles.Native]::CreateProfile($Sid, $Login, $path, [uint32]$path.Capacity)
    if ($result -ne 0) {
        throw "не удалось создать профиль: $([Runtime.InteropServices.Marshal]::GetExceptionForHR($result).Message)"
    }
    $path.ToString()
}

# --- BackupRoot: параметр командной строки > файл конфигурации ---
$config = @{}
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
    # Читаем сами, а не через Import-PowerShellDataFile: тот в PowerShell 5.1 принимает UTF-8 без BOM
    # за ANSI и молча портит кириллицу. Здесь годятся UTF-8 (с BOM и без) и ANSI.
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

if (-not $PSBoundParameters.ContainsKey('BackupRoot')) { $BackupRoot = $config['BackupRoot'] }
if ($BackupRoot -isnot [string] -or -not $BackupRoot.Trim()) {
    throw 'Не задана папка с бэкапом: укажите -BackupRoot или заполните BackupRoot в файле конфигурации.'
}
if ($BackupRoot -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') {
    throw "BackupRoot: '$BackupRoot' - нужен полный путь: с буквой диска или вида \\сервер\папка"
}
# try: на пути с недопустимыми символами Test-Path не возвращает $false, а падает
$backupExists = try { Test-Path -LiteralPath $BackupRoot -PathType Container } catch { $false }
if (-not $backupExists) {
    throw "Папка с бэкапом не найдена или недоступна: $BackupRoot"
}

if (-not (Get-Command Get-LocalUser -ErrorAction SilentlyContinue)) {
    throw 'Не найдены командлеты локальных учётных записей (Get-LocalUser). Нужна 64-разрядная консоль Windows PowerShell 5.1.'
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $WhatIfPreference) {
    throw 'Запустите PowerShell от имени администратора: создавать профили и писать в них может только администратор.'
}

Add-Type -Namespace RestoreUserProfiles -Name Native -MemberDefinition @'
[DllImport("userenv.dll", CharSet = CharSet.Unicode)]
public static extern int CreateProfile(string pszUserSid, string pszUserName, System.Text.StringBuilder pszProfilePath, uint cchProfilePath);
'@
# Папка, в которой Windows создаёт новые профили (обычно C:\Users)
$profilesDirectory = [Environment]::ExpandEnvironmentVariables(
    (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList').ProfilesDirectory)

Write-Host "Бэкап:      $BackupRoot"
Write-Host "Настройки:  $(if ($ConfigPath -and -not $PSBoundParameters.ContainsKey('BackupRoot')) { $ConfigPath } else { 'параметры запуска' })"

$backupDirs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Where-Object { Test-Like $_.Name $User })
if ($backupDirs.Count -eq 0) {
    Write-Warning "В $BackupRoot нет подходящих папок пользователей."
    return
}

# Щелчок мышью в окне консоли включает выделение текста (QuickEdit), и скрипт замирает на первом же
# выводе, пока не нажмут Enter. На время работы отключаем этот режим, в конце возвращаем как было.
$savedConsoleMode = $null
try {
    Add-Type -Namespace RestoreUserProfiles -Name ConsoleMode -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@
    $stdinHandle = [RestoreUserProfiles.ConsoleMode]::GetStdHandle(-10)
    [uint32]$mode = 0
    if ([RestoreUserProfiles.ConsoleMode]::GetConsoleMode($stdinHandle, [ref]$mode)) {
        $savedConsoleMode = $mode
        # снять ENABLE_QUICK_EDIT_MODE (0x40); без ENABLE_EXTENDED_FLAGS (0x80) изменение не применяется
        [void][RestoreUserProfiles.ConsoleMode]::SetConsoleMode($stdinHandle, [uint32](($mode -band 0xFFFFFFBF) -bor 0x80))
    }
}
catch { }   # консоли нет (планировщик задач, ISE) - отключать нечего

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
try {
    $n = 0
    $results = foreach ($backupDir in $backupDirs) {
        $n++
        $login = $backupDir.Name
        $status = "$login ($n из $($backupDirs.Count))"
        Write-Progress -Activity 'Восстановление профилей' -Status $status -PercentComplete (100 * ($n - 1) / $backupDirs.Count)
        $result = [pscustomobject]@{ User = $login; Archive = ''; Profile = ''; Restored = 0; Existing = 0; Errors = 0; Status = '' }

        # самый свежий архив; по времени файла, а не по имени - папку могли переименовать под новый логин
        $archive = Get-ChildItem -LiteralPath $backupDir.FullName -File |
            Where-Object { $_.Extension -eq '.zip' } | Sort-Object LastWriteTime | Select-Object -Last 1
        if (-not $archive) { $result.Status = 'в папке нет архива'; $result; continue }
        $result.Archive = $archive.Name

        $account = Get-LocalUser -Name $login -ErrorAction SilentlyContinue
        if (-not $account) {
            $result.Status = 'нет учётной записи с таким логином - сначала создайте её'
            $result; continue
        }
        $sid = $account.SID.Value

        # Профиль ищем по учётной записи, а не по папке: если пользователь уже входил,
        # Windows знает, где его профиль, и данные копируются туда без создания нового.
        $userProfile = Get-UserProfile $sid
        if ($userProfile) {
            $result.Profile = $userProfile.Path
            if ($userProfile.Loaded) {
                $result.Status = 'пользователь сейчас в системе - завершите его сеанс и запустите снова'
                $result; continue
            }
        }
        else {
            # Папка с именем пользователя есть, а профиля у этой учётной записи нет - значит, папка
            # чужая (например, от удалённой учётной записи с тем же логином). Windows создала бы новый
            # профиль рядом, в <логин>.<имя сервера>, и пользователь не увидел бы ни старой папки, ни данных.
            $expected = Join-Path $profilesDirectory $login
            if (Test-Path -LiteralPath $expected) {
                $result.Profile = $expected
                $result.Status = 'папка профиля уже есть, но принадлежит не этой учётной записи - удалите старый профиль ' +
                    '(Свойства системы - Профили пользователей) или переименуйте папку и запустите снова'
                $result; continue
            }
        }
        if (-not $PSCmdlet.ShouldProcess($login, "восстановить из $($archive.Name)")) {
            $result.Status = if ($userProfile) { 'профиль есть - данные будут скопированы в него' } else { 'профиля нет - будет создан, затем данные скопированы' }
            $result; continue
        }

        $created = $false
        if (-not $userProfile) {
            try { $userProfile = [pscustomobject]@{ Path = (New-UserProfile $sid $login); Loaded = $false } }
            catch { $result.Status = "ошибка: $(Get-ErrorText $_)"; $result; continue }
            $created = $true
        }
        $result.Profile = $userProfile.Path
        $root = ConvertTo-LongPath $userProfile.Path.TrimEnd('\')
        $log = New-Object 'System.Collections.Generic.List[string]'
        $clock = [Diagnostics.Stopwatch]::StartNew()

        $zip = [IO.Compression.ZipFile]::OpenRead($archive.FullName)
        try {
            foreach ($entry in $zip.Entries) {
                $relative = $entry.FullName.Replace('/', '\').Trim('\')
                # путь, который вывел бы файл за пределы профиля, не распаковываем
                if (-not $relative -or $relative -match '(^|\\)\.\.(\\|$)' -or $relative.Contains(':')) {
                    $log.Add("$($entry.FullName)`tнедопустимый путь в архиве")
                    $result.Errors++
                    continue
                }
                $target = "$root\$relative"
                if ($entry.FullName.EndsWith('/')) {
                    [void][IO.Directory]::CreateDirectory($target)
                    continue
                }
                if ([IO.File]::Exists($target)) {
                    $log.Add("$relative`tуже есть в профиле - не перезаписан")
                    $result.Existing++
                    continue
                }
                try {
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
                    $result.Restored++
                }
                catch {
                    $log.Add("$relative`t$(Get-ErrorText $_)")
                    $result.Errors++
                }

                # не чаще раза в секунду: Write-Progress в PowerShell 5.1 медленный
                if ($clock.ElapsedMilliseconds -ge 1000) {
                    Write-Progress -Activity 'Восстановление профилей' -Status $status -PercentComplete (100 * ($n - 1) / $backupDirs.Count) `
                        -CurrentOperation "файлов: $($result.Restored) - $relative"
                    $clock.Restart()
                }
            }
        }
        finally { $zip.Dispose() }

        # список баз 1С, собранный Copy-1CBaseList.ps1, - если в архиве его не было
        $baseList = Join-Path $backupDir.FullName 'ibases.v8i'
        $baseListTarget = "$root\AppData\Roaming\1C\1CEStart\ibases.v8i"
        if ([IO.File]::Exists($baseList) -and -not [IO.File]::Exists($baseListTarget)) {
            try {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($baseListTarget))
                [IO.File]::Copy($baseList, $baseListTarget)
                $result.Restored++
            }
            catch {
                $log.Add("AppData\Roaming\1C\1CEStart\ibases.v8i`t$(Get-ErrorText $_)")
                $result.Errors++
            }
        }

        if ($log.Count -gt 0) {
            $logPath = Join-Path $backupDir.FullName "${login}_restore_$stamp.log"
            try { Set-Content -LiteralPath $logPath -Value $log -Encoding UTF8 }
            catch { Write-Warning "Не удалось записать лог ${logPath}: $(Get-ErrorText $_)" }
        }

        $result.Status = if ($created) { 'профиль создан, данные скопированы' } else { 'данные скопированы в существующий профиль' }
        if ($result.Errors -gt 0) { $result.Status += ' - есть ошибки, смотрите лог' }
        $result
    }
}
finally {
    Write-Progress -Activity 'Восстановление профилей' -Completed
    if ($null -ne $savedConsoleMode) {
        [void][RestoreUserProfiles.ConsoleMode]::SetConsoleMode($stdinHandle, $savedConsoleMode)
    }
}

$results | Format-Table User, Profile, Restored, Existing, Errors, Status -AutoSize -Wrap
if ($results | Where-Object { $_.Errors -gt 0 -or $_.Existing -gt 0 }) {
    Write-Warning "Часть файлов не распакована или уже была в профиле - смотрите *_restore_$stamp.log в папках пользователей в $BackupRoot."
}
