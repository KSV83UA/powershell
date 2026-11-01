<#
  Replaces infobase paths in ibases.v8i.
  The original is saved as ibases.bak (if it already exists - ibases_yyyyMMdd_HHmmss.bak).

  Usage:
    .\Fix-IBases.ps1                    # file next to the script, else current user's %APPDATA%\1C\1CEStart
    .\Fix-IBases.ps1 -Folder "D:\x"     # explicit folder
    .\Fix-IBases.ps1 -AllProfiles       # every user profile on this machine (run as Administrator)
    .\Fix-IBases.ps1 -AllProfiles -WhatIf   # dry run: show what would change, write nothing

  Run with:  powershell -ExecutionPolicy Bypass -File .\Fix-IBases.ps1 [params]
#>
param(
    [string]$Folder,
    [switch]$AllProfiles,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# old path -> new path
$map = [ordered]@{
    'C:\BASBases\338_1' = 'D:\BAS\ShutenkoSO'
    'C:\BASBases\338_3' = 'D:\BAS\PovolockiiAG'
    'C:\BASBases\338_2' = 'D:\BAS\ZhnyvAgro'
}

function Update-IBasesFile {
    param([string]$File)

    Write-Host ""
    Write-Host "=== $File" -ForegroundColor Cyan

    try {
        # detect encoding (1C usually writes UTF-8 with BOM)
        $bytes = [System.IO.File]::ReadAllBytes($File)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $enc = New-Object System.Text.UTF8Encoding($true)
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $enc = [System.Text.Encoding]::Unicode
        } else {
            $enc = New-Object System.Text.UTF8Encoding($false)
        }
        $text = $enc.GetString($bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

        # replace (case-insensitive; 338_1 will NOT match 338_10, 338_1a, etc.)
        $new = $text
        foreach ($old in $map.Keys) {
            $pattern = '(?i)' + [regex]::Escape($old) + '(?![\w])'
            $count = [regex]::Matches($new, $pattern).Count
            if ($count -gt 0) {
                $new = [regex]::Replace($new, $pattern, $map[$old].Replace('$', '$$'))
                Write-Host ("  {0} -> {1}  ({2})" -f $old, $map[$old], $count) -ForegroundColor Green
            }
        }

        if ($new -ceq $text) {
            Write-Host "  nothing to change" -ForegroundColor DarkGray
            return 'unchanged'
        }
        if ($WhatIf) {
            Write-Host "  [WhatIf] would be changed" -ForegroundColor Yellow
            return 'changed'
        }

        $dir = Split-Path $File -Parent
        $bak = Join-Path $dir 'ibases.bak'
        if (Test-Path $bak) {
            $bak = Join-Path $dir ('ibases_{0}.bak' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        }
        Copy-Item -LiteralPath $File -Destination $bak
        [System.IO.File]::WriteAllText($File, $new, $enc)
        Write-Host "  saved, backup: $(Split-Path $bak -Leaf)" -ForegroundColor Green
        return 'changed'
    }
    catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        return 'error'
    }
}

# --- build file list ---
$files = @()

if ($AllProfiles) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Run as Administrator for -AllProfiles (other users' folders are not readable otherwise)." -ForegroundColor Red
        exit 1
    }

    # profile roots: registry ProfileList + everything under C:\Users
    $roots = @()
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
            if ($p) { $roots += [Environment]::ExpandEnvironmentVariables($p) }
        }
    $usersDir = Join-Path $env:SystemDrive 'Users'
    if (Test-Path $usersDir) {
        $roots += Get-ChildItem $usersDir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object FullName
    }
    $roots = $roots | Sort-Object -Unique

    foreach ($r in $roots) {
        $f = Join-Path $r 'AppData\Roaming\1C\1CEStart\ibases.v8i'
        if (Test-Path -LiteralPath $f) { $files += $f }
    }
}
else {
    if (-not $Folder) {
        $Folder = $PSScriptRoot
        if (-not (Test-Path (Join-Path $Folder 'ibases.v8i'))) {
            $Folder = Join-Path $env:APPDATA '1C\1CEStart'
        }
    }
    $f = Join-Path $Folder 'ibases.v8i'
    if (Test-Path -LiteralPath $f) { $files += $f }
}

if ($files.Count -eq 0) {
    Write-Host "No ibases.v8i found." -ForegroundColor Red
    exit 1
}

# warn if 1C launcher is running (it may overwrite ibases.v8i on exit)
$running = Get-Process -Name '1cestart', '1cv8', '1cv8c', '1cv8s' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host ("WARNING: 1C/BAS processes are running ({0}). Users should close the launcher, or it may overwrite the file." -f $running.Count) -ForegroundColor Yellow
}

# --- process ---
$stats = @{ changed = 0; unchanged = 0; error = 0 }
foreach ($f in $files) {
    $res = Update-IBasesFile -File $f
    $stats[$res]++
}

Write-Host ""
Write-Host ("Files: {0}   changed: {1}   unchanged: {2}   errors: {3}" -f $files.Count, $stats.changed, $stats.unchanged, $stats.error) -ForegroundColor Cyan
if ($WhatIf) { Write-Host "(WhatIf mode - nothing was written)" -ForegroundColor Yellow }
