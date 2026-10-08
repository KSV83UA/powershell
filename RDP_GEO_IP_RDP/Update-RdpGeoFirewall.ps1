#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Обновляет правила Windows Firewall для доступа к RDP только из geo-зоны Украины.

.DESCRIPTION
    Загружает списки адресов Украины из нескольких источников (по регистрации
    блока и по геолокации), объединяет их, сравнивает с кэшем и при изменениях
    пересоздаёт набор правил firewall с учётом лимита адресов на одно правило.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [switch]$Force
)

. (Join-Path $PSScriptRoot '_FirewallCommon.ps1')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-FirewallPrioritySupported {
    return (Get-Command New-NetFirewallRule -ErrorAction Stop).Parameters.ContainsKey('Priority')
}

function New-ManagedFirewallRule {
    param(
        [hashtable]$Rule
    )

    if (-not (Test-FirewallPrioritySupported)) {
        $null = $Rule.Remove('Priority')
    }

    New-NetFirewallRule @Rule -ErrorAction Stop | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Write-Host $line

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
}

function Get-MaxAddressesPerRuleLimit {
    param([int]$ConfiguredLimit)

    if ($ConfiguredLimit -gt 0) {
        return $ConfiguredLimit
    }

    $build = [System.Environment]::OSVersion.Version.Build
    if ($build -ge 22000) {
        return 10000
    }

    return 1000
}

function ConvertTo-IpNumber {
    param([string]$Address)

    $octets = $Address.Split('.')
    return ([long]$octets[0] -shl 24) + ([long]$octets[1] -shl 16) + ([long]$octets[2] -shl 8) + [long]$octets[3]
}

function ConvertFrom-IpNumber {
    param([long]$Number)

    return '{0}.{1}.{2}.{3}' -f (($Number -shr 24) -band 255), (($Number -shr 16) -band 255), (($Number -shr 8) -band 255), ($Number -band 255)
}

# Скачивает один источник и добавляет его диапазоны (start, end) в $Target.
#   Cidr     — по строке CIDR (ipdeny: страна по регистрации блока в RIR)
#   RangeCsv — "start,end,CC" (ip-location-db: страна по геолокации), берутся строки с $CountryCode
function Add-SourceRanges {
    param(
        [hashtable]$Source,
        [string]$CountryCode,
        [System.Collections.Generic.List[long[]]]$Target
    )

    if (-not $Source.ContainsKey('Url') -or -not $Source.Url -or -not $Source.ContainsKey('Type')) {
        throw 'Каждый элемент IpSources должен содержать Type и Url.'
    }

    $name = if ($Source.ContainsKey('Name') -and $Source.Name) { [string]$Source.Name } else { [string]$Source.Url }

    Write-Log "Загрузка geo-списка '$name': $($Source.Url)"
    $content = (Invoke-WebRequest -Uri $Source.Url -UseBasicParsing -TimeoutSec 120).Content
    $before = $Target.Count

    switch ($Source.Type) {
        'Cidr' {
            foreach ($line in ($content -split '\r?\n')) {
                $cidr = $line.Trim()
                if (-not $cidr -or $cidr.StartsWith('#')) {
                    continue
                }

                if (-not (Test-ValidCidr $cidr)) {
                    throw "В geo-списке '$name' найден некорректный CIDR: $cidr"
                }

                $address, $prefix = $cidr.Split('/')
                $size = [long]1 -shl (32 - [int]$prefix)
                $start = ConvertTo-IpNumber $address
                $start -= $start % $size
                $Target.Add([long[]]@($start, ($start + $size - 1)))
            }
        }
        'RangeCsv' {
            $pattern = '(?m)^(\d{1,3}(?:\.\d{1,3}){3}),(\d{1,3}(?:\.\d{1,3}){3}),' + $CountryCode + '[ \t\r]*$'
            foreach ($match in [regex]::Matches($content, $pattern)) {
                $first = $match.Groups[1].Value
                $last = $match.Groups[2].Value

                if (-not ((Test-ValidIpv4 $first) -and (Test-ValidIpv4 $last))) {
                    throw "В geo-списке '$name' найден некорректный диапазон: $($match.Value)"
                }

                $Target.Add([long[]]@((ConvertTo-IpNumber $first), (ConvertTo-IpNumber $last)))
            }
        }
        default {
            throw "Неизвестный Type источника '$name': $($Source.Type) (допустимы Cidr и RangeCsv)"
        }
    }

    $added = $Target.Count - $before
    if ($added -eq 0) {
        throw "Geo-список '$name' пуст или не удалось его разобрать."
    }

    Write-Log "Источник '$name': $added записей"
}

# Склеивает пересекающиеся и соседние диапазоны; возвращает "IP" или "start-end" (формат RemoteAddress).
function Merge-IpRanges {
    param([System.Collections.Generic.List[long[]]]$Ranges)

    $count = $Ranges.Count
    $starts = [long[]]::new($count)
    $ends = [long[]]::new($count)
    for ($i = 0; $i -lt $count; $i++) {
        $starts[$i] = $Ranges[$i][0]
        $ends[$i] = $Ranges[$i][1]
    }
    [Array]::Sort($starts, $ends)

    $result = [System.Collections.Generic.List[string]]::new()
    $curStart = $starts[0]
    $curEnd = $ends[0]

    for ($i = 1; $i -le $count; $i++) {
        if ($i -lt $count -and $starts[$i] -le $curEnd + 1) {
            if ($ends[$i] -gt $curEnd) {
                $curEnd = $ends[$i]
            }
            continue
        }

        if ($curStart -eq $curEnd) {
            $result.Add((ConvertFrom-IpNumber $curStart))
        }
        else {
            $result.Add(('{0}-{1}' -f (ConvertFrom-IpNumber $curStart), (ConvertFrom-IpNumber $curEnd)))
        }

        if ($i -lt $count) {
            $curStart = $starts[$i]
            $curEnd = $ends[$i]
        }
    }

    return [string[]]$result
}

function Test-ValidIpv4 {
    param([string]$Address)

    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        return $false
    }

    foreach ($octet in $Address.Split('.')) {
        $value = [int]$octet
        if ($value -lt 0 -or $value -gt 255) {
            return $false
        }
    }

    return $true
}

function Test-ValidCidr {
    param([string]$Cidr)

    if ($Cidr -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
        $parts = $Cidr.Split('/')
        $prefix = [int]$parts[1]
        return (Test-ValidIpv4 $parts[0]) -and $prefix -ge 0 -and $prefix -le 32
    }

    return $false
}

function Test-ValidRemoteAddress {
    param([string]$Address)

    if (Test-ValidIpv4 $Address) {
        return $true
    }

    if (Test-ValidCidr $Address) {
        return $true
    }

    if ($Address -match '^(\d{1,3}(?:\.\d{1,3}){3})-(\d{1,3}(?:\.\d{1,3}){3})$') {
        return (Test-ValidIpv4 $Matches[1]) -and (Test-ValidIpv4 $Matches[2])
    }

    return $false
}

function Get-WhitelistAddresses {
    param(
        [string[]]$ConfigAddresses,
        [string]$WhitelistFile
    )

    $addresses = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($ConfigAddresses)) {
        $value = [string]$entry
        if ($value) {
            $addresses.Add($value.Trim())
        }
    }

    if ($WhitelistFile -and (Test-Path $WhitelistFile)) {
        $fileEntries = Get-Content -Path $WhitelistFile -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^\s*#' }

        foreach ($entry in @($fileEntries)) {
            $addresses.Add([string]$entry)
        }
    }
    elseif ($WhitelistFile) {
        Write-Log "Файл whitelist не найден: $WhitelistFile — адреса из файла не добавлены." 'WARN'
    }

    return @($addresses | Sort-Object -Unique)
}

function Split-IntoChunks {
    param(
        [string[]]$Items,
        [int]$ChunkSize
    )

    $Items = [string[]]@($Items)
    $itemCount = Get-CollectionCount $Items

    $chunks = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $itemCount; $i += $ChunkSize) {
        $end = [Math]::Min($i + $ChunkSize - 1, $itemCount - 1)
        $chunks.Add(@($Items[$i..$end]))
    }

    return $chunks
}

function Get-ManagedFirewallRules {
    param([string]$Prefix)

    @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -like "$Prefix*" -or
            $_.DisplayName -eq "${Prefix}_BLOCK_NON_GEO"
        })
}

function Remove-ManagedFirewallRules {
    param([string]$Prefix)

    $rules = @(Get-ManagedFirewallRules -Prefix $Prefix)
    foreach ($rule in $rules) {
        Write-Log "Удаление правила: $($rule.DisplayName)"
        Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
    }
}

function Set-DefaultRdpRulesState {
    param(
        [bool]$Disable,
        [int]$Port,
        [string]$ExcludePrefix
    )

    $defaultRules = Get-BuiltinRdpFirewallRules -Port $Port -ExcludePrefix $ExcludePrefix

    if ((Get-CollectionCount $defaultRules) -eq 0) {
        Write-Log 'Встроенные правила RDP не найдены.' 'WARN'
        return
    }

    foreach ($rule in $defaultRules) {
        if ($Disable) {
            if ($rule.Enabled -ne 'False') {
                Write-Log "Отключение встроенного правила RDP: $($rule.DisplayName) [$($rule.Name)]"
                Disable-NetFirewallRule -Name $rule.Name -ErrorAction Stop
            }
        }
        else {
            if ($rule.Enabled -ne 'True') {
                Write-Log "Включение встроенного правила RDP: $($rule.DisplayName) [$($rule.Name)]"
                Enable-NetFirewallRule -Name $rule.Name -ErrorAction Stop
            }
        }
    }
}

function New-WhitelistAllowRules {
    param(
        [string]$Prefix,
        [int]$Port,
        [string[]]$Addresses,
        [int]$MaxPerRule,
        [string[]]$Protocols = @('TCP', 'UDP')
    )

    $Addresses = [string[]]@($Addresses)
    if ((Get-CollectionCount $Addresses) -eq 0) {
        return
    }

    foreach ($proto in $Protocols) {
        $chunkIndex = 1
        foreach ($chunk in @(Split-IntoChunks -Items $Addresses -ChunkSize $MaxPerRule)) {
            $displayName = if ((Get-CollectionCount $Addresses) -le $MaxPerRule) {
                "${Prefix}_WHITELIST_${proto}"
            }
            else {
                '{0}_WHITELIST_{1}_{2:D3}' -f $Prefix, $proto, $chunkIndex
            }

            Write-Log ("Создание whitelist-правила '$displayName' ({0} адресов)" -f (Get-CollectionCount $chunk))

            New-ManagedFirewallRule @{
                DisplayName  = $displayName
                Description  = "RDP ($proto) access from whitelist (office/VPN, managed by Update-RdpGeoFirewall.ps1)"
                Direction    = 'Inbound'
                Action       = 'Allow'
                Enabled      = 'True'
                Profile      = 'Any'
                Protocol     = $proto
                LocalPort    = $Port
                RemoteAddress = $chunk
                Priority     = 10 + $chunkIndex
            }

            $chunkIndex++
        }
    }
}

function New-GeoAllowRules {
    param(
        [string]$Prefix,
        [int]$Port,
        [string[]]$Blocks,
        [int]$MaxPerRule,
        [int]$PriorityOffset = 100,
        [string[]]$Protocols = @('TCP', 'UDP')
    )

    $Blocks = [string[]]@($Blocks)
    foreach ($proto in $Protocols) {
        $chunkIndex = 1
        foreach ($chunk in @(Split-IntoChunks -Items $Blocks -ChunkSize $MaxPerRule)) {
            $displayName = '{0}_{1}_{2:D3}' -f $Prefix, $proto, $chunkIndex
            Write-Log ("Создание allow-правила '$displayName' ({0} диапазонов)" -f (Get-CollectionCount $chunk))

            New-ManagedFirewallRule @{
                DisplayName   = $displayName
                Description   = "RDP ($proto) access from Ukraine geo zone (managed by Update-RdpGeoFirewall.ps1)"
                Direction     = 'Inbound'
                Action        = 'Allow'
                Enabled       = 'True'
                Profile       = 'Any'
                Protocol      = $proto
                LocalPort     = $Port
                RemoteAddress = $chunk
                Priority      = $PriorityOffset + $chunkIndex
            }

            $chunkIndex++
        }
    }
}

function New-GeoBlockRule {
    param(
        [string]$Prefix,
        [int]$Port,
        [string[]]$Protocols = @('TCP', 'UDP')
    )

    if (-not (Test-FirewallPrioritySupported)) {
        Write-Log 'Параметр Priority не поддерживается — block-правило пропущено. Доступ ограничен allow-правилами и отключённым RDP по умолчанию.' 'WARN'
        return
    }

    foreach ($proto in $Protocols) {
        $displayName = "${Prefix}_BLOCK_NON_GEO_${proto}"

        Write-Log "Создание block-правила '$displayName' для порта $Port"

        New-ManagedFirewallRule @{
            DisplayName   = $displayName
            Description   = "Block RDP ($proto) from non-geo addresses (managed by Update-RdpGeoFirewall.ps1)"
            Direction     = 'Inbound'
            Action        = 'Block'
            Enabled       = 'True'
            Profile       = 'Any'
            Protocol      = $proto
            LocalPort     = $Port
            RemoteAddress = 'Any'
            Priority      = 50000
        }
    }
}

# --- main ---

if (-not (Test-Path $ConfigPath)) {
    throw "Файл конфигурации не найден: $ConfigPath"
}

$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
$configDir = Split-Path -Parent $ConfigPath
$config = Import-PowerShellDataFile -Path $ConfigPath

$rdpPort = [int]$config.RdpPort
$prefix = [string]$config.RuleNamePrefix

# Относительные пути из конфига считаются от папки с config.psd1
$dataDir = if ($config.ContainsKey('DataDirectory') -and $config.DataDirectory) { [string]$config.DataDirectory } else { 'data' }
$dataDir = Resolve-ConfigRelativePath -Path $dataDir -BaseDirectory $configDir
$whitelistFile = if ($config.ContainsKey('WhitelistFile')) { [string]$config.WhitelistFile } else { '' }
$whitelistFile = Resolve-ConfigRelativePath -Path $whitelistFile -BaseDirectory $configDir
$cacheFile = Join-Path $dataDir 'ua-cidr-cache.txt'
$hashFile = Join-Path $dataDir 'ua-cidr-hash.txt'

if (-not (Test-Path $dataDir)) {
    New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
}

$script:LogFile = Join-Path $dataDir 'update.log'
$maxPerRule = Get-MaxAddressesPerRuleLimit -ConfiguredLimit ([int]$config.MaxAddressesPerRule)

$protocols = if ($config.ContainsKey('Protocols')) {
    [string[]]@($config.Protocols | ForEach-Object { ([string]$_).ToUpperInvariant() } | Select-Object -Unique)
}
else {
    [string[]]@('TCP', 'UDP')
}
$protocolsInvalid = @($protocols | Where-Object { $_ -notin @('TCP', 'UDP') })
if ((Get-CollectionCount $protocols) -eq 0 -or (Get-CollectionCount $protocolsInvalid) -gt 0) {
    throw "Некорректное значение Protocols в конфигурации (допустимы TCP и UDP): $($protocols -join ', ')"
}

Write-Log "=== Запуск обновления RDP geo-firewall ==="
Write-Log "Порт RDP: $rdpPort, протоколы: $($protocols -join ', '), лимит CIDR на правило: $maxPerRule"
if (-not (Test-FirewallPrioritySupported)) {
    Write-Log 'Priority не поддерживается этой версией Windows — block-правило не будет создано.' 'WARN'
}

$whitelist = [string[]]@(Get-WhitelistAddresses `
    -ConfigAddresses @($config.WhitelistAddresses) `
    -WhitelistFile $whitelistFile)

$whitelistInvalid = @($whitelist | Where-Object { -not (Test-ValidRemoteAddress $_) })
if ((Get-CollectionCount $whitelistInvalid) -gt 0) {
    throw "В whitelist найдены некорректные адреса: $($whitelistInvalid[0])"
}

$countryCode = if ($config.ContainsKey('CountryCode')) { ([string]$config.CountryCode).ToUpperInvariant() } else { 'UA' }
if ($countryCode -notmatch '^[A-Z]{2}$') {
    throw "Некорректный CountryCode в конфигурации: $countryCode"
}

$sources = if ($config.ContainsKey('IpSources') -and $config.IpSources) {
    @($config.IpSources)
}
elseif ($config.ContainsKey('IpSourceUrl') -and $config.IpSourceUrl) {
    Write-Log 'IpSources не задан — используется только IpSourceUrl (страна по регистрации блока). Часть украинских IP за рубежными провайдерами будет блокироваться.' 'WARN'
    @(@{ Name = 'IpSourceUrl'; Type = 'Cidr'; Url = [string]$config.IpSourceUrl })
}
else {
    throw 'В конфигурации не задан IpSources.'
}

# Адрес разрешён, если его считает «своим» хотя бы один источник.
# Любая ошибка загрузки прерывает скрипт ДО изменения правил — текущие правила остаются как были.
$allRanges = [System.Collections.Generic.List[long[]]]::new()
foreach ($source in $sources) {
    Add-SourceRanges -Source $source -CountryCode $countryCode -Target $allRanges
}

$blocks = [string[]]@(Merge-IpRanges -Ranges $allRanges)
$invalid = @($blocks | Where-Object { -not (Test-ValidRemoteAddress $_) })
if ((Get-CollectionCount $invalid) -gt 0) {
    throw "В объединённом geo-списке найден некорректный адрес: $($invalid[0])"
}

$hashPayload = @(
    'GEO'
    ($blocks -join "`n")
    'WHITELIST'
    ($whitelist -join "`n")
    'PORT'
    $rdpPort
    'PROTOCOLS'
    ($protocols -join ',')
) -join "`n"

$newHash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($hashPayload))) -Algorithm SHA256).Hash
$oldHash = if (Test-Path $hashFile) { Get-Content -Path $hashFile -Raw } else { '' }

if (-not $Force -and $newHash -eq $oldHash.Trim()) {
    Write-Log 'Список IP не изменился, обновление firewall не требуется.'
    exit 0
}

$whitelistCount = Get-CollectionCount $whitelist
$blocksCount = Get-CollectionCount $blocks

Write-Log "Whitelist: $whitelistCount адресов"
Write-Log "Объединено диапазонов: $blocksCount (из $($allRanges.Count) записей источников). Потребуется правил на протокол: $([Math]::Ceiling($blocksCount / [double]$maxPerRule))"

Remove-ManagedFirewallRules -Prefix $prefix
New-WhitelistAllowRules -Prefix $prefix -Port $rdpPort -Addresses $whitelist -MaxPerRule $maxPerRule -Protocols $protocols
New-GeoAllowRules -Prefix $prefix -Port $rdpPort -Blocks $blocks -MaxPerRule $maxPerRule -Protocols $protocols

if ([bool]$config.BlockNonGeoRdp) {
    New-GeoBlockRule -Prefix $prefix -Port $rdpPort -Protocols $protocols
}

if ([bool]$config.DisableDefaultRdpRules) {
    Set-DefaultRdpRulesState -Disable $true -Port $rdpPort -ExcludePrefix $prefix
}

$blocks | Set-Content -Path $cacheFile -Encoding UTF8
Set-Content -Path $hashFile -Value $newHash -Encoding UTF8 -NoNewline

Write-Log 'Обновление правил firewall завершено успешно.'
