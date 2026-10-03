@{
    # Порт RDP (по умолчанию 3389)
    RdpPort = 3389

    # Протоколы, для которых создаются правила (RDP использует TCP и UDP)
    Protocols = @('TCP', 'UDP')

    # Код страны для geo-списка (ISO 3166-1 alpha-2)
    CountryCode = 'UA'

    # URL со списком CIDR-блоков (aggregated — меньше записей, удобнее для firewall)
    IpSourceUrl = 'https://www.ipdeny.com/ipblocks/data/aggregated/ua-aggregated.zone'

    # Префикс имён правил Windows Firewall (к правилам добавляется _001, _002, ...)
    RuleNamePrefix = 'RDP_GEO_UA'

    # Максимум адресов/CIDR в одном правиле (0 = авто: 10000 для Win11/Server2022+, иначе 1000)
    MaxAddressesPerRule = 0

    # Отключить встроенные правила «Remote Desktop» (рекомендуется при geo-ограничении)
    DisableDefaultRdpRules = $true

    # Блокировать RDP с остальных IP (после allow-правил для geo-зоны)
    BlockNonGeoRdp = $true

    # Дополнительные IP/CIDR вне geo-зоны (офис, VPN и т.д.)
    # Форматы: 203.0.113.10 | 198.51.100.0/24 | 10.0.0.1-10.0.0.50
    WhitelistAddresses = @(
        # '203.0.113.10'
        # '198.51.100.0/24'
    )

    # Файл whitelist (один адрес/CIDR на строку, строки с # — комментарии)
    # Адреса из файла объединяются с WhitelistAddresses
    # Относительный путь считается от папки с config.psd1; можно указать и абсолютный
    WhitelistFile = 'whitelist.txt'

    # Интервал обновления для планировщика (часы)
    UpdateIntervalHours = 24

    # Каталог для логов и кэша списка IP (относительный путь — от папки с config.psd1)
    DataDirectory = 'data'

    # Имя задачи в планировщике Windows
    ScheduledTaskName = 'RDP_GEO_UA_Firewall_Update'
}
