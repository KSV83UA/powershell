# === Настройки ===
# Внешний IP сервера: по нему находится WAN-адаптер, на который вешаются правила.
# Запуск: .\blockAllPortsWithoutRDP.ps1 -PublicIP <внешний IP сервера>
param(
    [Parameter(Mandatory = $true)]
    [string]$PublicIP,

    [int]$RdpPort = 3389
)

# === Внешний адаптер определяется по IP ===
$wan = (Get-NetIPAddress -IPAddress $publicIP -ErrorAction Stop).InterfaceAlias
Write-Host "WAN adapter: $wan"

# === Удаление прежних версий правил ===
Get-NetFirewallRule -DisplayName 'WAN: block*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule

# === TCP: снаружи доступен только RDP ===
New-NetFirewallRule -DisplayName 'WAN: block TCP except RDP' `
  -Direction Inbound -Action Block -Protocol TCP -InterfaceAlias $wan `
  -LocalPort "1-$($rdpPort-1)", "$($rdpPort+1)-65535" | Out-Null

# === UDP: не блокируются 68 (DHCP), 123 (NTP) и RDP ===
New-NetFirewallRule -DisplayName 'WAN: block UDP except DHCP/NTP/RDP' `
  -Direction Inbound -Action Block -Protocol UDP -InterfaceAlias $wan `
  -LocalPort '1-67', '69-122', "124-$($rdpPort-1)", "$($rdpPort+1)-65535" | Out-Null

# === Проверка: правила, аренда DHCP, время ===
Get-NetFirewallRule -DisplayName 'WAN: block*' |
  Select-Object DisplayName, Enabled, Action | Format-Table -AutoSize

ipconfig /renew | Out-Null
Get-NetIPAddress -InterfaceAlias $wan -AddressFamily IPv4 |
  Select-Object IPAddress, PrefixOrigin | Format-Table -AutoSize

w32tm /resync /force
w32tm /query /status