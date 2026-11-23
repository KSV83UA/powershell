<#
.SYNOPSIS
    Выключает серверы Windows и Linux по описанию инфраструктуры из infrastructure.psd1.

.DESCRIPTION
    Серверы выключаются очередями (Stage): сначала все серверы очереди 1, скрипт ждёт, пока они
    перестанут отвечать, затем очередь 2 и т.д. Так сначала гасятся приложения и терминальные
    серверы, потом базы данных, в конце — хранилища и гипервизоры.

      Linux                 — по SSH с ключом (ssh.exe, встроен в Windows 10 1809+ / Server 2019+)
      Windows               — Stop-Computer по WMI (DCOM) или WinRM; либо по SSH, если стоит OpenSSH Server

    Сервер, который не отвечает ещё до начала, считается выключенным и пропускается.
    Если сервер очереди не выключился за StageTimeoutSec, скрипт всё равно переходит к следующей
    очереди (при отключении питания ждать бесконечно нельзя) и отмечает его в итоге как ошибку.

    Перед выключением показывается план и запрашивается подтверждение (YES).
    Для запуска без вопросов — из ПО ИБП или планировщика — ключ -Force.

    Код возврата: 0 — всё выключено (или уже было выключено), 1 — были ошибки или отмена.

.PARAMETER ConfigPath
    Файл описания инфраструктуры. По умолчанию infrastructure.psd1 рядом со скриптом.
.PARAMETER Name
    Выключить только эти серверы (имена из конфигурации, можно с * и ?).
    С -SaveCredential — сервер, для которого сохраняется своя учётка.
.PARAMETER Stage
    Выключить только эти очереди.
.PARAMETER List
    Показать описание инфраструктуры и выйти. Сеть не трогает.
.PARAMETER Check
    Проверить доступность и вход на каждый сервер (SSH-ключ, sudo, права WMI/WinRM), ничего не выключая.
.PARAMETER DryRun
    Показать, какие серверы, в каком порядке и какой командой будут выключены, и выйти.
.PARAMETER Force
    Не спрашивать подтверждение.
.PARAMETER SaveCredential
    Запросить учётные данные администратора Windows и сохранить их: без -Name — в общий CredentialFile,
    с -Name — в CredentialFile этого сервера (сервер не в домене или с другим администратором).
    Файл шифруется DPAPI: прочитать его сможет только тот же пользователь на этом же компьютере.

.EXAMPLE
    .\Stop-Servers.ps1 -List
.EXAMPLE
    .\Stop-Servers.ps1 -Check
.EXAMPLE
    .\Stop-Servers.ps1 -Stage 1 -DryRun
.EXAMPLE
    .\Stop-Servers.ps1 -Name DB1, FILES
.EXAMPLE
    .\Stop-Servers.ps1 -SaveCredential -Name BACKUP
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\ShutdownServers\Stop-Servers.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'infrastructure.psd1'),
    [string[]]$Name,
    [int[]]$Stage,
    [switch]$List,
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SaveCredential
)

$ErrorActionPreference = 'Stop'

# ======================= общие функции =======================

function Get-ErrorText {
    param($ErrorRecord)
    $text = $ErrorRecord.Exception.Message
    if (-not $text) { $text = [string]$ErrorRecord }
    ($text -replace '\s+', ' ').Trim()
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host $Message -ForegroundColor $color
    if ($script:LogFile) {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        # лог не должен мешать выключению: если файл занят или диска нет — просто пропускаем
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

# Таблица -> текст: и на экран, и в лог
function Write-Table {
    param([object[]]$Rows)
    $text = ($Rows | Format-Table -AutoSize -Wrap | Out-String -Width 220).TrimEnd()
    foreach ($line in ($text -split "`r?`n")) { Write-Log $line }
}

function Resolve-ConfigPath {
    param([string]$Path, [string]$BaseDirectory)
    if (-not $Path) { return '' }
    $p = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $BaseDirectory $p }
    [IO.Path]::GetFullPath($p)
}

function Read-ConfigFile {
    param([string]$Path)
    # Читаем сами, а не через Import-PowerShellDataFile: тот в PowerShell 5.1 принимает UTF-8 без BOM
    # за ANSI и молча портит кириллицу. Здесь годятся UTF-8 (с BOM и без) и ANSI.
    $text = [IO.File]::ReadAllText($Path)
    if ($text.Contains([string][char]0xFFFD)) { $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::Default) }
    try {
        $block = [scriptblock]::Create($text)
        # в файле допустимы только данные, без команд и переменных
        $block.CheckRestrictedLanguage([string[]]@(), [string[]]@(), $false)
        $data = & $block
    }
    catch { throw "Файл конфигурации $Path не читается: $(Get-ErrorText $_)" }
    if ($data -isnot [hashtable]) { throw "Файл конфигурации $Path должен содержать одну таблицу @{ ... }." }
    $data
}

function Get-IntValue {
    param($Value, [int]$Min, [int]$Max)
    $n = 0
    if ($null -ne $Value -and $Value -isnot [bool] -and [int]::TryParse([string]$Value, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
    $null
}

# Аргумент командной строки по правилам Windows (кавычки, обратные слэши перед кавычками)
function ConvertTo-CommandLineArgument {
    param([string]$Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    '"' + (($Value -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

function Get-SshExe {
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    # 32-битный PowerShell (так запускают некоторые программы ИБП) не видит System32\OpenSSH
    $native = Join-Path $env:windir 'Sysnative\OpenSSH\ssh.exe'
    if (Test-Path -LiteralPath $native) { return $native }
    $null
}

function New-Result {
    param([bool]$Ok, [string]$Message)
    [pscustomobject]@{ Ok = $Ok; Message = $Message }
}

function Get-LastLine {
    param([string]$Text)
    $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count) { $lines[-1].Trim() } else { '' }
}

# ======================= сеть =======================

function Test-Ping {
    param([string]$Address, [int]$TimeoutMs = 1000)
    $ping = New-Object Net.NetworkInformation.Ping
    try { $ping.Send($Address, $TimeoutMs).Status -eq 'Success' }
    catch { $false }
    finally { $ping.Dispose() }
}

function Test-TcpPort {
    param([string]$Address, [int]$Port, [int]$TimeoutMs = 1500)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        $true
    }
    catch { $false }
    finally { $client.Close() }
}

# Сервер «жив», пока отвечает хотя бы одно: порт управления или ping
# (ping в Windows часто закрыт брандмауэром, а порт SSH у Linux закрывается раньше, чем пропадает ping).
function Test-ServerAlive {
    param($Server)
    (Test-TcpPort -Address $Server.Address -Port $Server.CheckPort) -or (Test-Ping -Address $Server.Address)
}

function Invoke-Ssh {
    param($Server, [string]$RemoteCommand, [int]$TimeoutSec)

    $argList = New-Object 'System.Collections.Generic.List[string]'
    $argList.AddRange([string[]]@(
        '-o', 'BatchMode=yes'                      # никогда не спрашивать пароль: скрипт работает без людей
        '-o', "ConnectTimeout=$script:SshConnectTimeoutSec"
        '-o', 'StrictHostKeyChecking=accept-new'   # новый сервер запомнить, подменённый ключ — отклонить
    ))
    if ($script:KnownHostsFile) {
        $argList.Add('-o'); $argList.Add('UserKnownHostsFile="' + ($script:KnownHostsFile -replace '\\', '/') + '"')
    }
    if ($Server.KeyFile) { $argList.Add('-i'); $argList.Add($Server.KeyFile) }
    $argList.AddRange([string[]]@('-p', [string]$Server.Port, '-l', $Server.User, $Server.Address, $RemoteCommand))

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:SshExe
    $psi.Arguments = ($argList | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # вывод с Linux приходит в UTF-8 (например, сообщения sudo на русском)
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true

    $process = [Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
        try { $process.Kill() } catch { }
        return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = "ssh не завершился за $TimeoutSec с" }
    }
    $process.WaitForExit()   # дочитать вывод
    [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result.Trim(); Error = $stderr.Result.Trim() }
}

function Get-ServerCredential {
    param($Server)
    $path = $Server.CredentialFile
    if (-not $path) { return $null }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if ($Server.CredentialExplicit) { throw "файл учётных данных не найден: $path" }
        return $null   # общий файл не создан — работаем с правами текущего пользователя
    }
    if (-not $script:CredentialCache.ContainsKey($path)) {
        try { $cred = Import-Clixml -LiteralPath $path }
        catch { throw "не удалось прочитать $path (создан другим пользователем или на другом компьютере?): $(Get-ErrorText $_)" }
        if ($cred -isnot [System.Management.Automation.PSCredential]) { throw "$path не содержит учётных данных" }
        $script:CredentialCache[$path] = $cred
    }
    $script:CredentialCache[$path]
}

function Test-UsesCredentialFile {
    param($Server)
    $Server.CredentialFile -and ($Server.CredentialExplicit -or (Test-Path -LiteralPath $Server.CredentialFile -PathType Leaf))
}

function Get-CredentialText {
    param($Server)
    if (Test-UsesCredentialFile $Server) {
        $file = Split-Path -Leaf $Server.CredentialFile
        try { return "под $((Get-ServerCredential $Server).UserName) из $file" }
        catch { return "учётка из $file" }   # саму ошибку чтения покажет попытка входа
    }
    "под $script:CurrentUser (текущий пользователь)"
}

function Test-AccessDenied {
    param($ErrorRecord)
    # 0x80070005 — отказано в доступе, 0x8007052E — неверное имя пользователя или пароль
    for ($e = $ErrorRecord.Exception; $e; $e = $e.InnerException) {
        if ($e.HResult -eq 0x80070005 -or $e.HResult -eq 0x8007052E) { return $true }
    }
    # WinRM и Stop-Computer заворачивают код в своё исключение — остаётся текст (английский или русский)
    (Get-ErrorText $ErrorRecord) -match 'access is denied|отказано в доступе|user name or password|имя пользователя или (неверный )?пароль|logon failure'
}

function Get-WindowsFailureText {
    param($Server, $ErrorRecord)
    $text = "$($Server.Method): $(Get-ErrorText $ErrorRecord)"
    if (-not (Test-AccessDenied $ErrorRecord)) { return $text }

    $save = if ($Server.CredentialExplicit) { ".\Stop-Servers.ps1 -SaveCredential -Name $($Server.Name)" } else { '.\Stop-Servers.ps1 -SaveCredential' }
    if (Test-UsesCredentialFile $Server) {
        return "$text Вход $(Get-CredentialText $Server): неверный пароль или у этой учётки нет прав администратора на сервере. Пересохранить: $save"
    }
    if (-not $Server.CredentialFile) {
        return "$text Вход $(Get-CredentialText $Server), а CredentialFile не задан. Укажите его в описании инфраструктуры и сохраните учётку администратора сервера: $save"
    }
    "$text Вход $(Get-CredentialText $Server), файла $(Split-Path -Leaf $Server.CredentialFile) нет. Сохраните учётку администратора сервера: $save"
}

function Get-ActionText {
    param($Server)
    if ($Server.Method -eq 'SSH') { return "ssh $($Server.User)@$($Server.Address):$($Server.Port) -> $($Server.Command)" }
    "Stop-Computer -Force по $($Server.Method), $(Get-CredentialText $Server)"
}

# ======================= выключение и проверка =======================

function Invoke-ServerShutdown {
    param($Server)

    if ($Server.Method -eq 'SSH') {
        if ($Server.KeyFile -and -not (Test-Path -LiteralPath $Server.KeyFile -PathType Leaf)) {
            return New-Result $false "ключ SSH не найден: $($Server.KeyFile)"
        }
        $timeout = $script:SshConnectTimeoutSec + 20
        $r = Invoke-Ssh -Server $Server -RemoteCommand $Server.Command -TimeoutSec $timeout
        $err = Get-LastLine $r.Error
        if ($r.ExitCode -eq 0) { return New-Result $true 'команда выключения выполнена' }
        # сервер начал выключаться и оборвал сеанс раньше, чем ssh получил код возврата
        if ($r.ExitCode -eq 255 -and $r.Error -match 'closed by remote host|client_loop') {
            return New-Result $true "соединение закрыто сервером — выключается ($err)"
        }
        # сеанс повис после подключения — обычно это тоже уже идущее выключение; проверим ожиданием
        if ($r.ExitCode -eq -1) { return New-Result $true "ssh не ответил за $timeout с — проверяем, выключается ли сервер" }
        if ($r.ExitCode -eq 255) { return New-Result $false "не удалось войти по SSH: $err" }
        return New-Result $false "команда '$($Server.Command)' вернула код $($r.ExitCode): $err"
    }

    $params = @{
        ComputerName = $Server.Address
        Force        = $true                 # завершить и сеансы пользователей, и зависшие программы
        Protocol     = if ($Server.Method -eq 'WinRM') { 'WSMan' } else { 'DCOM' }
        ErrorAction  = 'Stop'
    }
    try {
        $cred = Get-ServerCredential $Server
        if ($cred) { $params.Credential = $cred }
        Stop-Computer @params
        New-Result $true 'команда выключения принята'
    }
    catch { New-Result $false (Get-WindowsFailureText $Server $_) }
}

function Test-ServerAccess {
    param($Server)

    if ($Server.Method -eq 'SSH') {
        if ($Server.KeyFile -and -not (Test-Path -LiteralPath $Server.KeyFile -PathType Leaf)) {
            return New-Result $false "ключ SSH не найден: $($Server.KeyFile)"
        }
        # для sudo проверяем, что именно эта команда разрешена без пароля (sudo -l ничего не выполняет)
        $usesSudo = $Server.Command -match '^\s*sudo\s'
        $probe = if ($usesSudo) { $Server.Command -replace '^\s*sudo\s+(-n\s+)?', 'sudo -n -l ' } else { 'exit 0' }
        $r = Invoke-Ssh -Server $Server -RemoteCommand $probe -TimeoutSec ($script:SshConnectTimeoutSec + 20)
        $err = Get-LastLine $r.Error
        if ($r.ExitCode -eq 0) { if ($usesSudo) { return New-Result $true 'вход по ключу и sudo без пароля — OK' } else { return New-Result $true 'вход по ключу — OK' } }
        if ($r.ExitCode -eq 255) { return New-Result $false "вход не удался: $err" }
        if ($r.ExitCode -eq -1) { return New-Result $false $r.Error }
        if ($usesSudo) { return New-Result $false "вход OK, но sudo не разрешает '$($Server.Command)' без пароля: $err" }
        return New-Result $false "вход OK, проверка вернула код $($r.ExitCode): $err"
    }

    try {
        $cred = Get-ServerCredential $Server
        if ($Server.Method -eq 'WinRM') {
            $params = @{ ComputerName = $Server.Address; ScriptBlock = { (Get-CimInstance Win32_OperatingSystem).Caption }; ErrorAction = 'Stop' }
            if ($cred) { $params.Credential = $cred }
            $caption = Invoke-Command @params
        }
        else {
            $params = @{ Class = 'Win32_OperatingSystem'; ComputerName = $Server.Address; ErrorAction = 'Stop' }
            if ($cred) { $params.Credential = $cred }
            $caption = (Get-WmiObject @params).Caption
        }
        New-Result $true "$($Server.Method) — OK ($caption, $(Get-CredentialText $Server))"
    }
    catch { New-Result $false (Get-WindowsFailureText $Server $_) }
}

# ======================= конфигурация =======================

$modes = @(@{ List = $List; Check = $Check; DryRun = $DryRun; SaveCredential = $SaveCredential }.GetEnumerator() | Where-Object { $_.Value.IsPresent })
if ($modes.Count -gt 1) { throw "Ключи $(($modes | ForEach-Object { '-' + $_.Key }) -join ', ') нельзя использовать вместе." }

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    $example = Join-Path (Split-Path -Parent $ConfigPath) 'infrastructure.example.psd1'
    $hint = if (Test-Path -LiteralPath $example) { " Скопируйте пример и впишите свои серверы:`n    Copy-Item '$example' '$ConfigPath'" } else { '' }
    throw "Файл конфигурации не найден: $ConfigPath.$hint"
}
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
$configDir = Split-Path -Parent $ConfigPath
$config = Read-ConfigFile -Path $ConfigPath

$defaults = @{
    Description          = ''
    StageTimeoutSec      = 300
    PollIntervalSec      = 5
    SshUser              = 'root'
    SshPort              = 22
    SshKeyFile           = ''
    SshKnownHostsFile    = 'known_hosts'
    SshConnectTimeoutSec = 10
    WindowsMethod        = 'WMI'
    CredentialFile       = 'windows.cred.xml'
    LogDirectory         = 'logs'
}
$settingNames = 'Description', 'StageTimeoutSec', 'PollIntervalSec', 'SshUser', 'SshPort', 'SshKeyFile', 'SshKnownHostsFile',
                'SshConnectTimeoutSec', 'WindowsMethod', 'CredentialFile', 'LogDirectory'
$serverKeys = 'Name', 'Address', 'OS', 'Stage', 'Role', 'Notes', 'Enabled', 'Method', 'User', 'Port', 'KeyFile', 'Command', 'CredentialFile'
$methodsByOs = @{ Windows = @('WMI', 'WinRM', 'SSH'); Linux = @('SSH') }

# собираем все ошибки сразу, чтобы не исправлять файл по одной
$problems = New-Object 'System.Collections.Generic.List[string]'
foreach ($key in $config.Keys) {
    if ($key -ne 'Servers' -and $settingNames -notcontains $key) {
        $problems.Add("${key}: неизвестная настройка. Допустимые: Servers, $($settingNames -join ', ')")
    }
}
$cfg = @{}
foreach ($key in $settingNames) { $cfg[$key] = if ($config.ContainsKey($key)) { $config[$key] } else { $defaults[$key] } }

$intRanges = @{ StageTimeoutSec = 5, 7200; PollIntervalSec = 1, 60; SshPort = 1, 65535; SshConnectTimeoutSec = 1, 120 }
foreach ($key in $intRanges.Keys) {
    $value = Get-IntValue $cfg[$key] $intRanges[$key][0] $intRanges[$key][1]
    if ($null -eq $value) { $problems.Add("${key}: нужно целое число от $($intRanges[$key][0]) до $($intRanges[$key][1]), сейчас '$($cfg[$key])'") }
    else { $cfg[$key] = $value }
}
$windowsMethod = @($methodsByOs.Windows | Where-Object { $_ -eq [string]$cfg.WindowsMethod })
if (-not $windowsMethod) { $problems.Add("WindowsMethod: допустимо $($methodsByOs.Windows -join ' | '), сейчас '$($cfg.WindowsMethod)'") }
if (-not ([string]$cfg.SshUser).Trim()) { $problems.Add('SshUser: не задан пользователь SSH') }

$servers = New-Object 'System.Collections.Generic.List[object]'
$rawServers = @($config['Servers'] | Where-Object { $null -ne $_ })
if ($rawServers.Count -eq 0) { $problems.Add('Servers: список серверов пуст') }

$index = 0
foreach ($raw in $rawServers) {
    $index++
    $label = "Servers[$index]"
    if ($raw -isnot [hashtable]) { $problems.Add("${label}: каждый сервер задаётся таблицей @{ ... }"); continue }
    if ($raw['Name']) { $label = "Servers[$index] ($($raw['Name']))" }
    foreach ($key in $raw.Keys) {
        if ($serverKeys -notcontains $key) { $problems.Add("${label}: неизвестный параметр $key. Допустимые: $($serverKeys -join ', ')") }
    }

    $serverName = ([string]$raw['Name']).Trim()
    $address = ([string]$raw['Address']).Trim()
    if (-not $serverName) { $problems.Add("${label}: не задан Name") }
    if (-not $address) { $problems.Add("${label}: не задан Address") }

    $os = @('Windows', 'Linux') | Where-Object { $_ -eq [string]$raw['OS'] }
    if (-not $os) { $problems.Add("${label}: OS должно быть Windows или Linux, сейчас '$($raw['OS'])'"); continue }

    $serverStage = Get-IntValue $raw['Stage'] 1 99
    if ($null -eq $serverStage) { $problems.Add("${label}: Stage — номер очереди от 1 до 99, сейчас '$($raw['Stage'])'") }

    $enabled = $true
    if ($raw.ContainsKey('Enabled')) {
        if ($raw['Enabled'] -is [bool]) { $enabled = $raw['Enabled'] }
        else { $problems.Add("${label}: Enabled должно быть `$true или `$false") }
    }

    $method = if ($raw['Method']) { [string]$raw['Method'] } elseif ($os -eq 'Linux') { 'SSH' } else { [string]$windowsMethod }
    $method = @($methodsByOs[$os] | Where-Object { $_ -eq $method })
    if (-not $method) { $problems.Add("${label}: Method для $os — $($methodsByOs[$os] -join ' | '), сейчас '$($raw['Method'])'"); continue }
    $method = [string]$method[0]
    if ($os -eq 'Windows' -and $method -eq 'SSH' -and -not $raw['User']) {
        $problems.Add("${label}: для Windows по SSH укажите User — администратора Windows (SshUser '$($cfg.SshUser)' — для Linux)")
    }
    # параметры не того способа молча игнорировались бы — а человек думает, что они работают
    if ($method -eq 'SSH') {
        if ($raw.ContainsKey('CredentialFile')) {
            $problems.Add("${label}: CredentialFile — для Windows по WMI/WinRM, а этот сервер выключается по SSH с ключом. Уберите CredentialFile")
        }
    }
    else {
        $saveHint = if ($raw['CredentialFile']) { ".\Stop-Servers.ps1 -SaveCredential -Name $serverName" } else { '.\Stop-Servers.ps1 -SaveCredential' }
        if ($raw.ContainsKey('User')) {
            $problems.Add("${label}: User — пользователь SSH, а сервер выключается по ${method}: учётка Windows берётся из файла учётных данных. Уберите User и сохраните учётку: $saveHint")
        }
        $sshOnly = @('Port', 'KeyFile', 'Command' | Where-Object { $raw.ContainsKey($_) })
        if ($sshOnly.Count -eq 1) { $problems.Add("${label}: $($sshOnly[0]) — параметр SSH, а сервер выключается по $method. Уберите его") }
        elseif ($sshOnly.Count) { $problems.Add("${label}: $($sshOnly -join ', ') — параметры SSH, а сервер выключается по $method. Уберите их") }
    }

    $port = $cfg.SshPort
    if ($raw.ContainsKey('Port')) {
        $port = Get-IntValue $raw['Port'] 1 65535
        if ($null -eq $port) { $problems.Add("${label}: Port — число от 1 до 65535, сейчас '$($raw['Port'])'") }
    }

    $user = if ($raw['User']) { ([string]$raw['User']).Trim() } else { ([string]$cfg.SshUser).Trim() }
    $keyFile = Resolve-ConfigPath $(if ($raw['KeyFile']) { [string]$raw['KeyFile'] } else { [string]$cfg.SshKeyFile }) $configDir
    $command = ([string]$raw['Command']).Trim()
    if (-not $command) {
        $command = if ($os -eq 'Windows') { 'shutdown /s /f /t 0' }
                   elseif ($user -eq 'root') { 'shutdown -h now' }
                   else { 'sudo -n shutdown -h now' }
    }
    $credExplicit = [bool]$raw['CredentialFile']
    $credFile = Resolve-ConfigPath $(if ($credExplicit) { [string]$raw['CredentialFile'] } else { [string]$cfg.CredentialFile }) $configDir

    $servers.Add([pscustomobject]@{
        Index              = $index
        Name               = $serverName
        Address            = $address
        OS                 = $os
        Stage              = $serverStage
        Role               = [string]$raw['Role']
        Notes              = [string]$raw['Notes']
        Enabled            = $enabled
        Method             = $method
        User               = $user
        Port               = $port
        KeyFile            = $keyFile
        Command            = $command
        CredentialFile     = $credFile
        CredentialExplicit = $credExplicit
        # по какому порту судить, что сервер ещё работает
        CheckPort          = switch ($method) { 'SSH' { $port } 'WMI' { 135 } 'WinRM' { 5985 } }
    })
}
foreach ($dup in ($servers | Where-Object Name | Group-Object Name | Where-Object Count -gt 1)) {
    $problems.Add("Name '$($dup.Name)' встречается $($dup.Count) раза — имена серверов должны быть уникальными")
}
if ($problems.Count) {
    throw ("В файле $ConfigPath найдены ошибки:`n  - " + ($problems -join "`n  - "))
}

$StageTimeoutSec = $cfg.StageTimeoutSec
$PollIntervalSec = $cfg.PollIntervalSec
$script:SshConnectTimeoutSec = $cfg.SshConnectTimeoutSec
$script:KnownHostsFile = Resolve-ConfigPath ([string]$cfg.SshKnownHostsFile) $configDir
$script:CredentialCache = @{}
$script:CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# ======================= выбор серверов =======================

# .ToArray(), а не @($servers): в PowerShell 5.1 @() от List[object] падает с «Argument types do not match»
$filtered = $servers.ToArray()
if ($Name) {
    foreach ($pattern in $Name) {
        if (-not @($servers | Where-Object { $_.Name -like $pattern }).Count) {
            throw "Сервер '$pattern' не найден в $ConfigPath. Есть: $(($servers | ForEach-Object Name) -join ', ')"
        }
    }
    $filtered = @($filtered | Where-Object { $n = $_.Name; @($Name | Where-Object { $n -like $_ }).Count -gt 0 })
}
if ($Stage) { $filtered = @($filtered | Where-Object { $Stage -contains $_.Stage }) }
$filtered = @($filtered | Sort-Object Stage, Index)

# ======================= -SaveCredential =======================

if ($SaveCredential) {
    if ($Stage) { throw '-SaveCredential и -Stage нельзя использовать вместе: учётка сохраняется для сервера (-Name) или общая (без ключей).' }
    if ($Name) {
        # свой файл сервера: сервер не в домене или с другим администратором
        $ssh = @($filtered | Where-Object Method -eq 'SSH')
        if ($ssh.Count) { throw "$(($ssh | ForEach-Object Name) -join ', '): выключается по SSH с ключом — учётные данные Windows не нужны." }
        $shared = @($filtered | Where-Object { -not $_.CredentialExplicit })
        if ($shared.Count) {
            throw ("У $(($shared | ForEach-Object Name) -join ', ') нет своего файла учётных данных — используется общий $(Split-Path -Leaf ([string]$cfg.CredentialFile)).`n" +
                   "Чтобы задать отдельного администратора, добавьте серверу в $(Split-Path -Leaf $ConfigPath) строку`n" +
                   "    CredentialFile = '$($shared[0].Name.ToLower()).cred.xml'`n" +
                   "и повторите команду. Общую учётку сохраняет .\Stop-Servers.ps1 -SaveCredential без -Name.")
        }
        $paths = @($filtered | ForEach-Object CredentialFile | Sort-Object -Unique)
        if ($paths.Count -gt 1) { throw "У $(($filtered | ForEach-Object Name) -join ', ') разные файлы учётных данных — укажите в -Name один сервер." }
        $path = $paths[0]
        $users = @($servers | Where-Object { $_.Method -ne 'SSH' -and $_.CredentialFile -eq $path })
    }
    else {
        $path = Resolve-ConfigPath ([string]$cfg.CredentialFile) $configDir
        if (-not $path) { throw "CredentialFile в $ConfigPath пуст — некуда сохранять." }
        $users = @($servers | Where-Object { $_.Method -ne 'SSH' -and -not $_.CredentialExplicit })
    }
    $forText = if ($users.Count) { "для $(($users | ForEach-Object Name) -join ', ')" } else { '(пока ни один сервер его не использует)' }

    $cred = Get-Credential -Message "Администратор Windows $forText.`nИмя: ДОМЕН\пользователь — доменная учётка, ИМЯСЕРВЕРА\пользователь — локальная учётка сервера.`nБудет сохранён в $path"
    if (-not $cred) { Write-Host 'Отменено.' -ForegroundColor Yellow; exit 1 }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cred | Export-Clixml -LiteralPath $path
    Write-Host "Сохранено: $path — $($cred.UserName) $forText" -ForegroundColor Green
    if ($cred.UserName -notmatch '[\\@]' -or $cred.UserName -like '.\*') {
        Write-Host "Имя '$($cred.UserName)' без домена или имени сервера: удалённый вход может не пройти. Лучше ДОМЕН\пользователь или ИМЯСЕРВЕРА\пользователь — пересохраните, если -Check покажет отказ." -ForegroundColor Yellow
    }
    Write-Host "Файл расшифрует только $script:CurrentUser на компьютере $env:COMPUTERNAME — запускайте выключение от этой же учётной записи." -ForegroundColor Yellow
    $checkArgs = if ($users.Count) { " -Name $(($users | ForEach-Object Name) -join ', ')" } else { '' }
    Write-Host "Проверка: .\Stop-Servers.ps1 -Check$checkArgs"
    exit 0
}

# ======================= -List =======================

if ($List) {
    if ($cfg.Description) { Write-Host $cfg.Description; Write-Host '' }
    $rows = $filtered | ForEach-Object {
        [pscustomobject]@{
            'Очередь'    = $_.Stage
            'Имя'        = $_.Name
            'Адрес'      = $_.Address
            'ОС'         = $_.OS
            'Способ'     = if ($_.Method -eq 'SSH') { "SSH $($_.User), порт $($_.Port)" } else { $_.Method }
            'Роль'       = $_.Role
            'Примечание' = $_.Notes
            'Вкл'        = if ($_.Enabled) { 'да' } else { 'нет' }
        }
    }
    Write-Table $rows
    exit 0
}

# ======================= подготовка к работе с сетью =======================

$selected = @($filtered | Where-Object Enabled)
foreach ($s in ($filtered | Where-Object { -not $_.Enabled })) {
    Write-Host "$($s.Name): Enabled = `$false — пропущен." -ForegroundColor Yellow
}
if (-not $selected.Count) { Write-Host 'Нет серверов для выключения (проверьте -Name, -Stage и Enabled).' -ForegroundColor Yellow; exit 0 }

$logDir = Resolve-ConfigPath ([string]$cfg.LogDirectory) $configDir
if ($logDir) {
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $script:LogFile = Join-Path $logDir ('Stop-Servers_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    }
    catch { Write-Host "Папку логов $logDir создать не удалось — лог не пишется: $(Get-ErrorText $_)" -ForegroundColor Yellow }
}

$modeText = if ($Check) { 'проверка' } elseif ($DryRun) { 'план (DryRun)' } else { 'выключение' }
Write-Log "=== Stop-Servers: $modeText | $script:CurrentUser на $env:COMPUTERNAME | $ConfigPath ==="

if (@($selected | Where-Object Method -eq 'SSH').Count) {
    $script:SshExe = Get-SshExe
    if (-not $script:SshExe -and -not $DryRun) {
        Write-Log 'Не найден ssh.exe. Установите клиент OpenSSH: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0' 'ERROR'
        exit 1
    }
}

# ======================= -Check =======================

if ($Check) {
    $rows = foreach ($s in $selected) {
        Write-Host "Проверка $($s.Name) ($($s.Address))..." -ForegroundColor DarkGray
        $portOpen = Test-TcpPort -Address $s.Address -Port $s.CheckPort
        $pingOk = Test-Ping -Address $s.Address
        $access = if ($portOpen) { Test-ServerAccess $s }
                  elseif ($pingOk) { New-Result $false "ping есть, но порт $($s.CheckPort) закрыт (служба не запущена или брандмауэр)" }
                  else { New-Result $false 'не отвечает' }
        [pscustomobject]@{
            'Очередь'   = $s.Stage
            'Имя'       = $s.Name
            'Адрес'     = $s.Address
            'Ping'      = if ($pingOk) { 'да' } else { 'нет' }
            'Порт'      = "$($s.CheckPort) $(if ($portOpen) { 'открыт' } else { 'закрыт' })"
            'Результат' = $(if ($access.Ok) { 'OK: ' } else { 'ОШИБКА: ' }) + $access.Message
            Ok          = $access.Ok
        }
    }
    $rows = @($rows)
    Write-Table ($rows | Select-Object * -ExcludeProperty Ok)
    $bad = @($rows | Where-Object { -not $_.Ok }).Count
    if ($bad) { Write-Log "Проблемы: $bad из $($rows.Count). Пока они не исправлены, эти серверы не выключатся." 'WARN'; exit 1 }
    Write-Log "Все $($rows.Count) серверов готовы к выключению." 'OK'
    exit 0
}

# ======================= план =======================

$stages = @($selected | Group-Object Stage | Sort-Object { [int]$_.Name })
Write-Log ''
Write-Log "План выключения (ожидание каждой очереди — до $StageTimeoutSec с):"
foreach ($group in $stages) {
    Write-Log "  Очередь $($group.Name):"
    foreach ($s in $group.Group) {
        $role = if ($s.Role) { " — $($s.Role)" } else { '' }
        Write-Log "    $($s.Name) ($($s.Address), $($s.OS))$role"
        Write-Log "        $(Get-ActionText $s)"
    }
}
Write-Log ''

if ($DryRun) { Write-Log 'DryRun: ничего не выключалось.' 'OK'; exit 0 }

if (-not $Force) {
    $answer = Read-Host "Будет выключено серверов: $($selected.Count). Для продолжения введите YES"
    if ($answer -ne 'YES') { Write-Log 'Отменено пользователем.' 'WARN'; exit 1 }
}

# ======================= выключение =======================

$results = New-Object 'System.Collections.Generic.List[object]'
function Add-ServerResult {
    param($Server, [ValidateSet('Off', 'Skipped', 'Failed')][string]$Kind, [string]$Text)
    $results.Add([pscustomobject]@{ Stage = $Server.Stage; Index = $Server.Index; Name = $Server.Name; Address = $Server.Address; Kind = $Kind; Text = $Text })
}

foreach ($group in $stages) {
    $members = @($group.Group | Sort-Object Index)
    Write-Log "--- Очередь $($group.Name): $(($members | ForEach-Object Name) -join ', ') ---"

    $waiting = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $members) {
        if (-not (Test-ServerAlive $s)) {
            Write-Log "$($s.Name): не отвечает — уже выключен или недоступен, пропущен." 'WARN'
            Add-ServerResult $s Skipped 'не отвечал ещё до начала — пропущен'
            continue
        }
        Write-Log "$($s.Name): выключаю — $(Get-ActionText $s)"
        $r = Invoke-ServerShutdown $s
        if ($r.Ok) { Write-Log "$($s.Name): $($r.Message)" 'OK'; $waiting.Add($s) }
        else { Write-Log "$($s.Name): ОШИБКА — $($r.Message)" 'ERROR'; Add-ServerResult $s Failed "ошибка: $($r.Message)" }
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($waiting.Count -and $timer.Elapsed.TotalSeconds -lt $StageTimeoutSec) {
        Start-Sleep -Seconds $PollIntervalSec
        foreach ($s in $waiting.ToArray()) {   # копия: из $waiting удаляем по ходу
            if (-not (Test-ServerAlive $s)) {
                $sec = [int]$timer.Elapsed.TotalSeconds
                Write-Log "$($s.Name): выключен ($sec с)" 'OK'
                Add-ServerResult $s Off "выключен за $sec с"
                [void]$waiting.Remove($s)
            }
        }
    }
    foreach ($s in $waiting) {
        Write-Log "$($s.Name): всё ещё отвечает через $StageTimeoutSec с — перехожу к следующей очереди." 'ERROR'
        Add-ServerResult $s Failed "не выключился за $StageTimeoutSec с"
    }
}

# ======================= итог =======================

Write-Log ''
Write-Log 'Итог:'
Write-Table ($results | Sort-Object Stage, Index | ForEach-Object {
    [pscustomobject]@{ 'Очередь' = $_.Stage; 'Имя' = $_.Name; 'Адрес' = $_.Address; 'Результат' = $_.Text }
})
$off = @($results | Where-Object Kind -eq 'Off').Count
$skipped = @($results | Where-Object Kind -eq 'Skipped').Count
$failed = @($results | Where-Object Kind -eq 'Failed')
$summary = "выключено $off, уже не отвечали $skipped"
if ($failed.Count) {
    Write-Log "Готово с ошибками: $summary, НЕ выключены $($failed.Count): $(($failed | ForEach-Object Name) -join ', '). Подробности — в логе $script:LogFile" 'ERROR'
    exit 1
}
Write-Log "Готово: $summary." 'OK'
exit 0
