@{
    # Порт RDP (по умолчанию 3389)
    RdpPort = 3389

    # Протоколы, для которых создаются правила (RDP использует TCP и UDP)
    Protocols = @('TCP', 'UDP')

    # Код страны для источников типа RangeCsv (ISO 3166-1 alpha-2).
    # Источники типа Cidr страну определяют своим URL (ipdeny — ua-aggregated.zone).
    CountryCode = 'UA'

    # Источники geo-списка. Адрес разрешён, если его считает украинским ХОТЯ БЫ ОДИН источник;
    # пересекающиеся диапазоны склеиваются. Если любой источник не загрузился — правила не меняются.
    #   Cidr     — файл со строками CIDR. ipdeny определяет страну по регистрации блока в RIR,
    #              поэтому украинские IP у зарубежно зарегистрированных провайдеров он НЕ видит.
    #   RangeCsv — CSV "start,end,CC" (ip-location-db). Страна по геолокации, ловит такие IP.
    IpSources = @(
        @{ Name = 'ipdeny';   Type = 'Cidr';     Url = 'https://www.ipdeny.com/ipblocks/data/aggregated/ua-aggregated.zone' }
        @{ Name = 'geolite2'; Type = 'RangeCsv'; Url = 'https://cdn.jsdelivr.net/npm/@ip-location-db/geolite2-country/geolite2-country-ipv4.csv' }
        @{ Name = 'dbip';     Type = 'RangeCsv'; Url = 'https://cdn.jsdelivr.net/npm/@ip-location-db/dbip-country/dbip-country-ipv4.csv' }
    )

    # Префикс имён правил Windows Firewall (к правилам добавляется _001, _002, ...)
    RuleNamePrefix = 'RDP_GEO_UA'

    # Максимум адресов/диапазонов в одном правиле (0 = авто: 10000 для Win11/Server2022+, иначе 1000)
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
