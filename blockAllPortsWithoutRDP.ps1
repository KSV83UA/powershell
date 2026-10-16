#Requires -RunAsAdministrator
<#
  Блокирует все входящие порты на WAN-адаптере, кроме портов-исключений.
  Повторный запуск пересоздаёт правила по текущим спискам исключений.

  Запуск: .\blockAllPortsWithoutRDP.ps1 -PublicIP <внешний IP сервера>
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$PublicIP,

    [int]$RdpPort = 3389
)

# ======================= ИСКЛЮЧЕНИЯ (править здесь) =======================
# Порты, которые остаются открытыми снаружи.
# Одиночный порт: 443      Диапазон: '8000-8010'
# После правки просто запустите скрипт ещё раз: старые правила заменятся новыми.
$AllowTcp = @(
    $RdpPort        # RDP
    # 443           # HTTPS
    # '8000-8010'   # пример диапазона
)

$AllowUdp = @(
    68              # DHCP-клиент
    123             # NTP
    $RdpPort        # RDP по UDP
    1194          # OpenVPN
)
# ==========================================================================

$ErrorActionPreference = 'Stop'
$group = 'WAN block (script)'

# Список портов/диапазонов -> отсортированные пары Lo/Hi с проверкой
function ConvertTo-PortRanges {
    param([object[]]$Ports)
    foreach ($p in $Ports) {
        $s = "$p".Trim()
        if ($s -match '^(\d+)$') {
            $lo = $hi = [int]$Matches[1]
        }
        elseif ($s -match '^(\d+)\s*-\s*(\d+)$') {
            $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
        }
        else { throw "Invalid port: '$s'" }

        if ($lo -lt 1 -or $hi -gt 65535 -or $lo -gt $hi) { throw "Port out of range: '$s'" }
        [pscustomobject]@{ Lo = $lo; Hi = $hi }
    }
}

function Format-Range($lo, $hi) { if ($lo -eq $hi) { "$lo" } else { "$lo-$hi" } }

# Исключения -> диапазоны, которые надо блокировать (всё 1-65535 минус исключения)
function Get-BlockRanges {
    param([object[]]$Allow)
    $result = [System.Collections.Generic.List[string]]::new()
    $next = 1
    foreach ($r in (ConvertTo-PortRanges $Allow | Sort-Object Lo)) {
        if ($r.Lo -gt $next) { $result.Add((Format-Range $next ($r.Lo - 1))) }
        if ($r.Hi + 1 -gt $next) { $next = $r.Hi + 1 }
    }
    if ($next -le 65535) { $result.Add((Format-Range $next 65535)) }
    , $result.ToArray()
}

# === Внешний адаптер определяется по IP ===
$wan = (Get-NetIPAddress -IPAddress $PublicIP).InterfaceAlias
Write-Host "WAN adapter: $wan"

# === Запоминаем прежние правила (удаляются ПОСЛЕ создания новых, чтобы не было окна без защиты) ===
$oldRules = @(Get-NetFirewallRule -DisplayName 'WAN: block*' -ErrorAction SilentlyContinue)

# === Создание новых правил ===
foreach ($cfg in @(
        @{ Proto = 'TCP'; Allow = $AllowTcp },
        @{ Proto = 'UDP'; Allow = $AllowUdp })) {

    $openText = (ConvertTo-PortRanges $cfg.Allow | Sort-Object Lo |
        ForEach-Object { Format-Range $_.Lo $_.Hi }) -join ', '
    if (-not $openText) { $openText = 'none' }

    $block = Get-BlockRanges $cfg.Allow
    if ($block.Count -eq 0) {
        Write-Warning "$($cfg.Proto): all ports are in exceptions, block rule not created"
        continue
    }

    New-NetFirewallRule -DisplayName "WAN: block $($cfg.Proto)" -Group $group `
        -Description "Open: $openText" `
        -Direction Inbound -Action Block -Protocol $cfg.Proto -InterfaceAlias $wan `
        -LocalPort $block | Out-Null

    Write-Host ("{0} open: {1}" -f $cfg.Proto, $openText)
}

# === Удаление прежних правил ===
if ($oldRules.Count) {
    $oldRules | Remove-NetFirewallRule
    Write-Host "Removed old rules: $($oldRules.Count)"
}

# === Проверка: правила, аренда DHCP, время ===
Get-NetFirewallRule -DisplayName 'WAN: block*' |
    Select-Object DisplayName, Enabled, Action, Description | Format-Table -AutoSize

ipconfig /renew "$wan" | Out-Null
Get-NetIPAddress -InterfaceAlias $wan -AddressFamily IPv4 |
    Select-Object IPAddress, PrefixOrigin | Format-Table -AutoSize

w32tm /resync /force
w32tm /query /status
