# RDP Geo Firewall (Украина)

Скрипт ограничивает входящий доступ к RDP только IP-адресами из geo-зоны Украины и дополнительным whitelist (офис, VPN, админы). Список IP обновляется по расписанию, правила Windows Firewall пересоздаются автоматически.

## Состав проекта

| Файл | Назначение |
|------|------------|
| `config.psd1` | Основные настройки |
| `whitelist.txt` | Дополнительные IP/CIDR вне geo-зоны |
| `Update-RdpGeoFirewall.ps1` | Загрузка списка IP и обновление firewall |
| `Install-RdpGeoFirewallTask.ps1` | Установка задачи в планировщике Windows |
| `Uninstall-RdpGeoFirewall.ps1` | Удаление правил и задачи |
| `_FirewallCommon.ps1` | Общие функции поиска встроенных RDP-правил (не зависит от языка ОС) |
| `data\` | Логи и кэш (создаётся автоматически) |

## Требования

- Windows Server или Windows 10/11
- PowerShell 5.1+
- Права **администратора**
- Доступ в интернет для загрузки geo-списка

> **Кодировка:** все `.ps1` и `config.psd1` должны быть в **UTF-8 с BOM**.  
> PowerShell 5.1 без BOM неправильно читает кириллицу и выдаёт ошибку `Unexpected token`.  
> Если файлы редактируете в другом редакторе — сохраняйте как «UTF-8 with BOM».

## Быстрый старт

### 1. Настройка

Откройте `config.psd1` и при необходимости измените параметры:

```powershell
RdpPort = 3389                    # порт RDP (можно задать другой)
Protocols = @('TCP', 'UDP')       # протоколы, для которых создаются правила
UpdateIntervalHours = 24          # интервал автообновления (часы)
DisableDefaultRdpRules = $true    # отключить встроенные правила RDP
BlockNonGeoRdp = $true            # блокировать RDP с остальных IP
```

Добавьте постоянные IP в `whitelist.txt` (один адрес на строку):

```
203.0.113.10
198.51.100.0/24
10.0.0.1-10.0.0.50
```

Строки, начинающиеся с `#`, считаются комментариями.

### 2. Первый запуск

Папку со скриптами можно разместить на любом диске — пути к `whitelist.txt` и `data\` считаются от папки с `config.psd1`.

Откройте PowerShell **от имени администратора** и перейдите в папку со скриптами (ниже для примера `C:\Script\RDP_GEO_IP_RDP`):

```powershell
cd C:\Script\RDP_GEO_IP_RDP
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Update-RdpGeoFirewall.ps1
```

### 3. Автообновление по таймеру

```powershell
.\Install-RdpGeoFirewallTask.ps1
```

Задача `RDP_GEO_UA_Firewall_Update` будет запускаться от SYSTEM с интервалом из `UpdateIntervalHours` (по умолчанию каждые 24 часа).

## Как это работает

1. Скрипт скачивает актуальный список CIDR-блоков Украины с [ipdeny.com](https://www.ipdeny.com/ipblocks/data/aggregated/ua-aggregated.zone).
2. Объединяет его с адресами из `whitelist.txt` и `config.psd1`.
3. Сравнивает хеш списка с кэшем — если ничего не изменилось, firewall не трогает.
4. При изменениях удаляет старые управляемые правила и создаёт новые — отдельный набор для каждого протокола из `Protocols` (по умолчанию TCP и UDP):
   - `RDP_GEO_UA_WHITELIST_TCP`, `RDP_GEO_UA_WHITELIST_UDP` — allow для whitelist (высший приоритет)
   - `RDP_GEO_UA_TCP_001`, `_002`, … и `RDP_GEO_UA_UDP_001`, `_002`, … — allow для geo-зоны Украины
   - `RDP_GEO_UA_BLOCK_NON_GEO_TCP`, `RDP_GEO_UA_BLOCK_NON_GEO_UDP` — block для остальных IP на порту RDP
5. Отключает встроенные правила RDP (по системному имени `RemoteDesktop*` и по порту — **работает на любой локали Windows**, в т.ч. украинской).

### Лимит IP на одно правило

Windows ограничивает количество адресов в одном правиле firewall:

| ОС | Лимит CIDR на правило |
|----|------------------------|
| Windows 10 / Server до 2022 | 1000 |
| Windows 11 / Server 2022+ | 10000 |

Для Украины (~2656 CIDR) на старых системах создаётся **3 allow-правила на каждый протокол** (6 при TCP и UDP). Лимит настраивается в `MaxAddressesPerRule` (`0` = автоопределение).

## Настройки config.psd1

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `RdpPort` | Порт RDP | `3389` |
| `Protocols` | Протоколы правил (`TCP`, `UDP`) | `TCP`, `UDP` |
| `CountryCode` | Код страны (для справки) | `UA` |
| `IpSourceUrl` | URL geo-списка CIDR | ipdeny aggregated UA |
| `RuleNamePrefix` | Префикс имён правил firewall | `RDP_GEO_UA` |
| `MaxAddressesPerRule` | Лимит CIDR на правило (`0` = авто) | `0` |
| `DisableDefaultRdpRules` | Отключить встроенные правила RDP | `$true` |
| `BlockNonGeoRdp` | Блокировать RDP с остальных IP | `$true` |
| `WhitelistAddresses` | IP/CIDR в конфиге | пусто |
| `WhitelistFile` | Путь к файлу whitelist (относительный — от папки с `config.psd1`) | `whitelist.txt` |
| `UpdateIntervalHours` | Интервал планировщика (часы) | `24` |
| `DataDirectory` | Каталог логов и кэша (относительный — от папки с `config.psd1`) | `data` |
| `ScheduledTaskName` | Имя задачи планировщика | `RDP_GEO_UA_Firewall_Update` |

## Whitelist (офис, VPN)

Адреса из whitelist **не зависят** от geo-зоны и всегда получают доступ к RDP.

Поддерживаемые форматы:

- Один IP: `203.0.113.10`
- Подсеть: `198.51.100.0/24`
- Диапазон: `10.0.0.1-10.0.0.50`

Задать можно двумя способами (оба объединяются):

1. Файл `whitelist.txt`
2. Массив `WhitelistAddresses` в `config.psd1`

После изменения whitelist:

```powershell
.\Update-RdpGeoFirewall.ps1 -Force
```

## Полезные команды

```powershell
# Принудительное обновление (игнорировать кэш)
.\Update-RdpGeoFirewall.ps1 -Force

# Ручной запуск задачи планировщика
Start-ScheduledTask -TaskName 'RDP_GEO_UA_Firewall_Update'

# Просмотр созданных правил
Get-NetFirewallRule -DisplayName 'RDP_GEO_UA*' | Format-Table DisplayName, Enabled, Action

# Просмотр лога (из папки со скриптами)
Get-Content .\data\update.log -Tail 30

# Удаление правил и задачи
.\Uninstall-RdpGeoFirewall.ps1
```

## Удаление

```powershell
cd C:\Script\RDP_GEO_IP_RDP
.\Uninstall-RdpGeoFirewall.ps1
```

Скрипт удалит все правила с префиксом `RDP_GEO_UA` и задачу планировщика. Встроенные правила RDP будут снова включены.

Чтобы оставить встроенные правила RDP отключёнными:

```powershell
.\Uninstall-RdpGeoFirewall.ps1 -KeepDefaultRdpRulesDisabled
```

## Важные замечания

1. **Запуск только от администратора** — без этого скрипт не сможет менять firewall.
2. **Риск блокировки** — перед применением убедитесь, что есть альтернативный доступ к серверу (консоль хостинга, IPMI, VPN). Добавьте свой IP в `whitelist.txt` заранее.
3. **Geo-списки приблизительные** — IP определяются по стране регистрации, а не по фактическому местоположению пользователя. Возможны ложные срабатывания и пропуски.
4. **Интернет обязателен** — для загрузки geo-списка нужен доступ к ipdeny.com.
5. **Порядок правил** — whitelist имеет приоритет выше geo-правил; block-правило — самый низкий приоритет среди управляемых правил.

## Устранение неполадок

| Проблема | Решение |
|----------|---------|
| `Access is denied` | Запустите PowerShell от администратора |
| `ExecutionPolicy` блокирует скрипт | `Set-ExecutionPolicy -Scope Process Bypass` |
| «Файл … не имеет цифровой подписи» | Файлы скачаны из интернета: `Unblock-File .\*.ps1` или `Set-ExecutionPolicy -Scope Process Bypass` |
| Нет правил для UDP | Обновите `Update-RdpGeoFirewall.ps1` и проверьте, что в `Protocols` есть `'UDP'`; старые правила без `_TCP`/`_UDP` в имени удалятся при следующем запуске |
| `Unexpected token` / кракозябры в ошибке | Файл сохранён без BOM — пересохраните в UTF-8 с BOM |
| Старые правила RDP не отключились | Запустите `.\Update-RdpGeoFirewall.ps1 -Force` — поиск правил теперь по имени `RemoteDesktop*` и порту, не по английскому DisplayName |
| `Priority` parameter not found | Нормально для старых Windows — скрипт работает без block-правила |
| В логе `Файл whitelist не найден` | Проверьте `WhitelistFile` в `config.psd1` — путь должен вести к существующему файлу (относительный считается от папки с конфигом) |
| Не могу подключиться по RDP | Проверьте whitelist, убедитесь что ваш IP в списке; проверьте правила в `wf.msc` |
| Скрипт не обновляет правила | Список не изменился — используйте `-Force` |
| Ошибка загрузки geo-списка | Проверьте интернет и доступность ipdeny.com |

## Просмотр правил в GUI

Откройте **Брандмауэр Windows в режиме повышенной безопасности** (`wf.msc`) → **Правила для входящих подключений** → найдите правила `RDP_GEO_UA*`.
