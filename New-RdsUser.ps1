<#
  Створює локального користувача на RDP-сервері:
   - питає ім'я, прізвище, телефон
   - транслітерує (офіційна українська, КМУ 2010; російські літери теж обробляються)
   - генерує пароль, додає в "Remote Desktop Users" і "Users"
   - дописує рядок Login;FullName;Phone;Password у найсвіжіший
     New-ServerUsers.passwords_*.csv на робочому столі (або створює новий)

  Запуск (від адміністратора):
    powershell -ExecutionPolicy Bypass -File .\New-RdsUser.ps1
#>

$ErrorActionPreference = 'Stop'

# ---------- налаштування ----------
# Шаблон логіна: {f} = перша літера імені, {first} = ім'я, {last} = прізвище
$LoginTemplate  = '{f}.{last}'
$PasswordLength = 12
$FilePattern    = 'New-ServerUsers.passwords_*.csv'
# ----------------------------------

# --- права адміністратора ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Запустіть від імені адміністратора.' -ForegroundColor Red; exit 1 }

# --- транслітерація ---
function Convert-ToLatin {
    param([string]$Text)

    # на початку слова
    $start = @{ 'є'='ye'; 'ї'='yi'; 'й'='y'; 'ю'='yu'; 'я'='ya'; 'ё'='yo' }
    # в інших позиціях
    $map = @{
        'а'='a'; 'б'='b'; 'в'='v'; 'г'='h'; 'ґ'='g'; 'д'='d'; 'е'='e'; 'є'='ie'; 'ж'='zh'
        'з'='z'; 'и'='y'; 'і'='i'; 'ї'='i'; 'й'='i'; 'к'='k'; 'л'='l'; 'м'='m'; 'н'='n'
        'о'='o'; 'п'='p'; 'р'='r'; 'с'='s'; 'т'='t'; 'у'='u'; 'ф'='f'; 'х'='kh'; 'ц'='ts'
        'ч'='ch'; 'ш'='sh'; 'щ'='shch'; 'ь'=''; 'ю'='iu'; 'я'='ia'
        # російські
        'ы'='y'; 'э'='e'; 'ё'='io'; 'ъ'=''
    }
    # апострофи (типографські задаємо кодами: PowerShell вважає їх лапками)
    $apos = @("'", '`', [string][char]0x2019, [string][char]0x02BC, [string][char]0x2018)
    foreach ($a in $apos) { $map[$a] = '' }
    $letterOrApos = '[\p{L}' + [regex]::Escape(-join $apos) + ']'

    $s = $Text.ToLower()
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = [string]$s[$i]
        $prev = if ($i -gt 0) { [string]$s[$i-1] } else { '' }
        $atStart = ($i -eq 0) -or ($prev -notmatch $letterOrApos)

        # "зг" -> "zgh" (щоб не плутати з "zh")
        if ($c -eq 'г' -and $prev -eq 'з') { [void]$sb.Append('gh'); continue }

        if ($atStart -and $start.ContainsKey($c)) { [void]$sb.Append($start[$c]) }
        elseif ($map.ContainsKey($c))            { [void]$sb.Append($map[$c]) }
        else                                     { [void]$sb.Append($c) }
    }
    $sb.ToString()
}

function Get-CleanPart { param([string]$s) ((Convert-ToLatin $s) -replace '[^a-z0-9]', '') }

function New-Password {
    param([int]$Length = 12)
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnpqrstuvwxyz'
    $digit = '23456789'
    $sym   = '!#%*-_+='
    $all   = $upper + $lower + $digit
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = {
        param($set)
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        $set[[BitConverter]::ToUInt32($b, 0) % $set.Length]
    }
    $chars = @( (& $pick $upper), (& $pick $lower), (& $pick $digit), (& $pick $sym) )
    while ($chars.Count -lt $Length) { $chars += (& $pick $all) }
    # перемішати
    -join ($chars | Sort-Object { $b = New-Object byte[] 4; $rng.GetBytes($b); [BitConverter]::ToUInt32($b, 0) })
}

# --- файл паролів ---
function Get-PasswordFile {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $f = Get-ChildItem -Path $desktop -Filter $FilePattern -File -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName }

    $path = Join-Path $desktop ('New-ServerUsers.passwords_{0}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    # новий файл: UTF-8 з BOM + ';' -> Excel відкриває коректно з кирилицею
    [IO.File]::WriteAllText($path, "Login;FullName;Phone;Password`r`n", (New-Object Text.UTF8Encoding($true)))
    Write-Host "Створено новий файл: $path" -ForegroundColor Yellow
    return $path
}

function Add-PasswordLine {
    param([string]$Path, [string]$Login, [string]$FullName, [string]$Phone, [string]$Password)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    # дописуємо без BOM; якщо BOM немає - файл в ANSI (cp1251)
    $enc = if ($hasBom) { New-Object Text.UTF8Encoding($false) } else { [Text.Encoding]::Default }
    $content = if ($hasBom) { (New-Object Text.UTF8Encoding($true)).GetString($bytes) } else { $enc.GetString($bytes) }

    # роздільник беремо з заголовка
    $header = ($content -split "`r?`n")[0]
    $delim = if ($header -match ';') { ';' } elseif ($header -match "`t") { "`t" } else { ',' }

    $q = { param($v) if ($v -match '[;,"\t]') { '"' + ($v -replace '"', '""') + '"' } else { $v } }
    $line = (& $q $Login), (& $q $FullName), (& $q $Phone), (& $q $Password) -join $delim

    $prefix = if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { "`r`n" } else { '' }
    [IO.File]::AppendAllText($Path, $prefix + $line + "`r`n", $enc)
}

# ================== основний цикл ==================
$rdpGroup   = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-555')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
$usersGroup = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]

do {
    Write-Host ''
    $first = (Read-Host "Ім'я").Trim()
    $last  = (Read-Host 'Прізвище').Trim()
    if (-not $first -or -not $last) { Write-Host "Ім'я і прізвище обов'язкові." -ForegroundColor Red; continue }
    $phone = (Read-Host 'Телефон (Enter - пропустити)').Trim()

    $fl = Get-CleanPart $first
    $ll = Get-CleanPart $last
    $suggested = $LoginTemplate.Replace('{first}', $fl).Replace('{last}', $ll).Replace('{f}', $fl.Substring(0,1))

    # унікальність
    $base = $suggested; $n = 2
    while (Get-LocalUser -Name $suggested -ErrorAction SilentlyContinue) { $suggested = "$base$n"; $n++ }

    $login = (Read-Host "Логін [$suggested]").Trim()
    if (-not $login) { $login = $suggested }

    if ($login.Length -gt 20)              { Write-Host 'Логін довший за 20 символів - Windows не дозволить.' -ForegroundColor Red; continue }
    if ($login -match '[\\/\[\]:;|=,+*?<>"@]') { Write-Host 'Логін містить недопустимі символи.' -ForegroundColor Red; continue }
    if (Get-LocalUser -Name $login -ErrorAction SilentlyContinue) { Write-Host "Користувач $login вже існує." -ForegroundColor Red; continue }

    $fullName = "$first $last"
    $password = New-Password -Length $PasswordLength

    try {
        $sec = ConvertTo-SecureString $password -AsPlainText -Force
        New-LocalUser -Name $login -FullName $fullName -Password $sec -PasswordNeverExpires -AccountNeverExpires | Out-Null
        Add-LocalGroupMember -Group $usersGroup -Member $login -ErrorAction SilentlyContinue
        Add-LocalGroupMember -Group $rdpGroup   -Member $login
    }
    catch {
        Write-Host "Помилка створення: $($_.Exception.Message)" -ForegroundColor Red
        Remove-LocalUser -Name $login -ErrorAction SilentlyContinue
        continue
    }

    Write-Host ''
    Write-Host "Створено: $login  ($fullName)" -ForegroundColor Green
    Write-Host "Пароль:   $password" -ForegroundColor Green

    # запис у файл (якщо файл відкритий в Excel - пропонуємо повторити)
    $file = Get-PasswordFile
    $saved = $false
    while (-not $saved) {
        try {
            Add-PasswordLine -Path $file -Login $login -FullName $fullName -Phone $phone -Password $password
            Write-Host "Записано в: $(Split-Path $file -Leaf)" -ForegroundColor Green
            $saved = $true
        }
        catch {
            Write-Host "Не вдалося записати у файл (відкритий в Excel?): $($_.Exception.Message)" -ForegroundColor Yellow
            $r = Read-Host 'Закрийте файл і натисніть Enter для повтору, або введіть s щоб пропустити'
            if ($r -eq 's') { Write-Host 'Збережіть логін/пароль вручну!' -ForegroundColor Red; break }
        }
    }

    $more = Read-Host 'Створити ще одного? (y/n)'
} while ($more -match '^(y|т|д|yes)$')
