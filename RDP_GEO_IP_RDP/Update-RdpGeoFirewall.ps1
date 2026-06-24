#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Обновляет правила Windows Firewall для доступа к RDP только из geo-зоны Украины.

.DESCRIPTION
    Загружает актуальный список CIDR-блоков Украины, сравнивает с кэшем
    и при изменениях пересоздаёт набор правил firewall с учётом лимита
    адресов на одно правило.
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

function Get-GeoIpBlocks {
    param([string]$Url)

    Write-Log "Загрузка geo-списка: $Url"
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 120

    $blocks = [string[]]@(
        $response.Content -split '\r?\n' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^\s*#' }
    )

    if ((Get-CollectionCount $blocks) -eq 0) {
        throw 'Geo-список пуст или не удалось его разобрать.'
    }

    return [string[]]@($blocks | Sort-Object -Unique)
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
        [int]$MaxPerRule
    )

    $Addresses = [string[]]@($Addresses)
    if ((Get-CollectionCount $Addresses) -eq 0) {
        return
    }

    $chunkIndex = 1
    foreach ($chunk in @(Split-IntoChunks -Items $Addresses -ChunkSize $MaxPerRule)) {
        $displayName = if ((Get-CollectionCount $Addresses) -le $MaxPerRule) {
            "${Prefix}_WHITELIST"
        }
        else {
            '{0}_WHITELIST_{1:D3}' -f $Prefix, $chunkIndex
        }

        Write-Log ("Создание whitelist-правила '$displayName' ({0} адресов)" -f (Get-CollectionCount $chunk))

        New-ManagedFirewallRule @{
            DisplayName  = $displayName
            Description  = 'RDP access from whitelist (office/VPN, managed by Update-RdpGeoFirewall.ps1)'
            Direction    = 'Inbound'
            Action       = 'Allow'
            Enabled      = 'True'
            Profile      = 'Any'
            Protocol     = 'TCP'
            LocalPort    = $Port
            RemoteAddress = $chunk
            Priority     = 10 + $chunkIndex
        }

        $chunkIndex++
    }
}

function New-GeoAllowRules {
    param(
        [string]$Prefix,
        [int]$Port,
        [string[]]$Blocks,
        [int]$MaxPerRule,
        [int]$PriorityOffset = 100
    )

    $Blocks = [string[]]@($Blocks)
    $chunkIndex = 1
    foreach ($chunk in @(Split-IntoChunks -Items $Blocks -ChunkSize $MaxPerRule)) {
        $displayName = '{0}_{1:D3}' -f $Prefix, $chunkIndex
        Write-Log ("Создание allow-правила '$displayName' ({0} CIDR)" -f (Get-CollectionCount $chunk))

        New-ManagedFirewallRule @{
            DisplayName   = $displayName
            Description   = 'RDP access from Ukraine geo zone (managed by Update-RdpGeoFirewall.ps1)'
            Direction     = 'Inbound'
            Action        = 'Allow'
            Enabled       = 'True'
            Profile       = 'Any'
            Protocol      = 'TCP'
            LocalPort     = $Port
            RemoteAddress = $chunk
            Priority      = $PriorityOffset + $chunkIndex
        }

        $chunkIndex++
    }
}

function New-GeoBlockRule {
    param(
        [string]$Prefix,
        [int]$Port
    )

    $displayName = "${Prefix}_BLOCK_NON_GEO"

    if (-not (Test-FirewallPrioritySupported)) {
        Write-Log 'Параметр Priority не поддерживается — block-правило пропущено. Доступ ограничен allow-правилами и отключённым RDP по умолчанию.' 'WARN'
        return
    }

    Write-Log "Создание block-правила '$displayName' для порта $Port"

    New-ManagedFirewallRule @{
        DisplayName   = $displayName
        Description   = 'Block RDP from non-geo addresses (managed by Update-RdpGeoFirewall.ps1)'
        Direction     = 'Inbound'
        Action        = 'Block'
        Enabled       = 'True'
        Profile       = 'Any'
        Protocol      = 'TCP'
        LocalPort     = $Port
        RemoteAddress = 'Any'
        Priority      = 50000
    }
}

# --- main ---

if (-not (Test-Path $ConfigPath)) {
    throw "Файл конфигурации не найден: $ConfigPath"
}

$config = Import-PowerShellDataFile -Path $ConfigPath

$rdpPort = [int]$config.RdpPort
$prefix = [string]$config.RuleNamePrefix
$dataDir = [string]$config.DataDirectory
$cacheFile = Join-Path $dataDir 'ua-cidr-cache.txt'
$hashFile = Join-Path $dataDir 'ua-cidr-hash.txt'

if (-not (Test-Path $dataDir)) {
    New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
}

$script:LogFile = Join-Path $dataDir 'update.log'
$maxPerRule = Get-MaxAddressesPerRuleLimit -ConfiguredLimit ([int]$config.MaxAddressesPerRule)

Write-Log "=== Запуск обновления RDP geo-firewall ==="
Write-Log "Порт RDP: $rdpPort, лимит CIDR на правило: $maxPerRule"
if (-not (Test-FirewallPrioritySupported)) {
    Write-Log 'Priority не поддерживается этой версией Windows — block-правило не будет создано.' 'WARN'
}

$whitelist = [string[]]@(Get-WhitelistAddresses `
    -ConfigAddresses @($config.WhitelistAddresses) `
    -WhitelistFile ([string]$config.WhitelistFile))

$whitelistInvalid = @($whitelist | Where-Object { -not (Test-ValidRemoteAddress $_) })
if ((Get-CollectionCount $whitelistInvalid) -gt 0) {
    throw "В whitelist найдены некорректные адреса: $($whitelistInvalid[0])"
}

$blocks = [string[]]@(Get-GeoIpBlocks -Url $config.IpSourceUrl)
$invalid = @($blocks | Where-Object { -not (Test-ValidCidr $_) })
if ((Get-CollectionCount $invalid) -gt 0) {
    throw "В geo-списке найдены некорректные CIDR: $($invalid[0])"
}

$hashPayload = @(
    'GEO'
    ($blocks -join "`n")
    'WHITELIST'
    ($whitelist -join "`n")
    'PORT'
    $rdpPort
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
Write-Log "Получено CIDR-блоков: $blocksCount. Потребуется правил: $([Math]::Ceiling($blocksCount / [double]$maxPerRule))"

Remove-ManagedFirewallRules -Prefix $prefix
New-WhitelistAllowRules -Prefix $prefix -Port $rdpPort -Addresses $whitelist -MaxPerRule $maxPerRule
New-GeoAllowRules -Prefix $prefix -Port $rdpPort -Blocks $blocks -MaxPerRule $maxPerRule

if ([bool]$config.BlockNonGeoRdp) {
    New-GeoBlockRule -Prefix $prefix -Port $rdpPort
}

if ([bool]$config.DisableDefaultRdpRules) {
    Set-DefaultRdpRulesState -Disable $true -Port $rdpPort -ExcludePrefix $prefix
}

$blocks | Set-Content -Path $cacheFile -Encoding UTF8
Set-Content -Path $hashFile -Value $newHash -Encoding UTF8 -NoNewline

Write-Log 'Обновление правил firewall завершено успешно.'
