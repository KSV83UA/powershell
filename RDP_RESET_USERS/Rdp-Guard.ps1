# =====================================================================
# Rdp-Guard.ps1
# Завершает отключённые (disconnected) RDP-сессии с простоем от 1 минуты,
# кроме пользователей из белого списка. Работает только с 17:00 до 07:00.
#
# Расположение: C:\Scripts\Rdp-Guard.ps1
# Лог:          C:\Scripts\Rdp-Guard.log
# Запуск:       планировщиком заданий от SYSTEM (см. Install-RdpGuard.ps1)
# =====================================================================

# Белый список: сессии этих пользователей никогда не завершаются.
# Указывайте имена РОВНО так, как их показывает команда quser
# (на русской Windows встроенный администратор — «администратор»).
# Можно указывать как короткое имя (admin), так и DOMAIN\admin.
# Регистр не важен.
$WhiteList = @(
    'Administrator',
    'администратор',
    'admin',
    'service-user',
    'Anna Nizola'
)

# Минимальный простой отключённой сессии перед завершением
$MinimumIdleTime = [TimeSpan]::FromMinutes(1)

$LogFile  = 'C:\Scripts\Rdp-Guard.log'

# $true — подробный лог (сырой вывод quser, причины пропуска сессий).
# Включать только на время отладки.
$DebugRaw = $false

# ---------------------------------------------------------------------

$logDir = Split-Path $LogFile
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Ротация: при превышении 5 МБ текущий лог переименовывается в .old
if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 5MB)) {
    Move-Item $LogFile "$LogFile.old" -Force
}

function Write-GuardLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "$timestamp $Message" -Encoding UTF8
}

function Convert-IdleTime {
    param([string]$Value)

    # Нет простоя
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq '.' -or
        $Value -ieq 'none' -or $Value -ieq 'нет') {
        return [TimeSpan]::Zero
    }
    # Формат: 2+03:15 — 2 дня, 3 часа, 15 минут
    if ($Value -match '^(?<Days>\d+)\+(?<Hours>\d+):(?<Minutes>\d+)$') {
        return New-TimeSpan -Days ([int]$Matches.Days) -Hours ([int]$Matches.Hours) -Minutes ([int]$Matches.Minutes)
    }
    # Формат: 1:30 — 1 час, 30 минут
    if ($Value -match '^(?<Hours>\d+):(?<Minutes>\d+)$') {
        return New-TimeSpan -Hours ([int]$Matches.Hours) -Minutes ([int]$Matches.Minutes)
    }
    # Формат: 45 — 45 минут
    if ($Value -match '^\d+$') {
        return New-TimeSpan -Minutes ([int]$Value)
    }
    return [TimeSpan]::Zero
}

Write-GuardLog "Запуск скрипта"

# Работаем только с 17:00 до 07:00
$currentTime = (Get-Date).TimeOfDay
if ($currentTime -lt [TimeSpan]::FromHours(17) -and $currentTime -ge [TimeSpan]::FromHours(7)) {
    Write-GuardLog "Выход: вне рабочего окна (текущее время $currentTime)"
    exit 0
}

# Полные пути: из 32-битного PowerShell путь System32 перенаправляется
# в SysWOW64, где quser.exe отсутствует — тогда берём Sysnative
$quserPath  = Join-Path $env:windir 'System32\quser.exe'
$logoffPath = Join-Path $env:windir 'System32\logoff.exe'
if (-not (Test-Path $quserPath)) {
    $quserPath  = Join-Path $env:windir 'Sysnative\quser.exe'
    $logoffPath = Join-Path $env:windir 'Sysnative\logoff.exe'
}

try {
    $raw = & $quserPath 2>&1

    $stderr = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    $lines  = @($raw | Where-Object { $_ -is [string] -and $_.Trim() })

    if ($stderr.Count -gt 0) {
        Write-GuardLog "quser stderr: $($stderr -join ' | ')"
    }
    if ($DebugRaw) {
        Write-GuardLog "quser raw: $($lines -join ' || ')"
    }
    if ($lines.Count -le 1) {
        Write-GuardLog "Выход: quser вернул $($lines.Count) строк (сессий нет)"
        exit 0
    }

    # Вывод quser — таблица с фиксированными колонками. Определяем границы
    # по заголовку: первые три заголовка (USERNAME/ПОЛЬЗОВАТЕЛЬ, SESSIONNAME/СЕАНС,
    # ID) — всегда одиночные слова в любой локали. Имя пользователя может
    # содержать пробелы, поэтому разбор по токенам не годится.
    $header = $lines[0]
    $cols = [regex]::Matches($header, '\S+')
    if ($cols.Count -lt 3) {
        Write-GuardLog "Не удалось разобрать заголовок quser: $header"
        exit 0
    }
    $sessStart = $cols[1].Index                     # начало колонки SESSIONNAME
    $idEnd     = $cols[2].Index + $cols[2].Length   # правый край колонки ID

    $lines | Select-Object -Skip 1 | ForEach-Object {
        $line = $_.PadRight($idEnd + 60)

        # Колонка имени: от позиции 1 (позиция 0 — маркер '>' текущей сессии)
        $user = $line.Substring(1, $sessStart - 1).Trim()

        # Область SESSIONNAME + ID: у отключённой сессии имя сессии пусто,
        # остаётся только числовой ID — это и есть признак Disconnected,
        # независимый от языка ОС и кодировки.
        $sessRegion = $line.Substring($sessStart, $idEnd - $sessStart).Trim()
        $rest       = $line.Substring($idEnd)

        if ($sessRegion -notmatch '^(?<Sess>\S*?)\s*(?<Id>\d+)$') {
            if ($DebugRaw) { Write-GuardLog "Не распознана строка: $line" }
            return
        }
        $sessionName = $Matches.Sess
        $sessionId   = [int]$Matches.Id

        $state = ''; $idleRaw = ''
        if ($rest -match '^\s*(?<State>\S+)\s+(?<Idle>\S+)') {
            $state   = $Matches.State
            $idleRaw = $Matches.Idle
        }
        $idleTime = Convert-IdleTime $idleRaw

        $isDisconnected = [string]::IsNullOrEmpty($sessionName)

        $shortUser = ($user -split '\\')[-1]
        $isAllowed = $false
        foreach ($allowedUser in $WhiteList) {
            if ($user -ieq $allowedUser -or $shortUser -ieq (($allowedUser -split '\\')[-1])) {
                $isAllowed = $true
                break
            }
        }

        if ($isDisconnected -and $idleTime -ge $MinimumIdleTime -and -not $isAllowed) {
            Write-GuardLog "Завершение сессии: пользователь=$user; ID=$sessionId; статус=$state; простой=$idleTime"

            & $logoffPath $sessionId

            if ($LASTEXITCODE -ne 0) {
                Write-GuardLog "Ошибка завершения сессии ID=$sessionId; код=$LASTEXITCODE"
            }
        }
        elseif ($DebugRaw) {
            Write-GuardLog "Пропуск: пользователь=$user; ID=$sessionId; сеанс='$sessionName'; статус=$state; простой=$idleTime; whitelist=$isAllowed"
        }
    }
}
catch {
    Write-GuardLog "Ошибка: $($_.Exception.Message) | строка $($_.InvocationInfo.ScriptLineNumber)"
}
