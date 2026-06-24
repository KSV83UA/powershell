#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Удаляет задачу планировщика и управляемые правила firewall.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [switch]$KeepDefaultRdpRulesDisabled
)

. (Join-Path $PSScriptRoot '_FirewallCommon.ps1')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ManagedFirewallRules {
    param([string]$Prefix)

    @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -like "$Prefix*" -or
            $_.DisplayName -eq "${Prefix}_BLOCK_NON_GEO"
        })
}

if (-not (Test-Path $ConfigPath)) {
    throw "Файл конфигурации не найден: $ConfigPath"
}

$config = Import-PowerShellDataFile -Path $ConfigPath
$prefix = [string]$config.RuleNamePrefix
$taskName = [string]$config.ScheduledTaskName

$rules = Get-ManagedFirewallRules -Prefix $prefix

foreach ($rule in $rules) {
    Write-Host "Удаление правила: $($rule.DisplayName)"
    Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
}

if ((Get-CollectionCount $rules) -eq 0) {
    Write-Host 'Управляемые правила firewall не найдены.'
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Задача планировщика удалена: $taskName"
}

if (-not $KeepDefaultRdpRulesDisabled) {
    $rdpPort = [int]$config.RdpPort
    $defaultRules = Get-BuiltinRdpFirewallRules -Port $rdpPort -ExcludePrefix $prefix

    foreach ($rule in @($defaultRules)) {
        if ($rule.Enabled -ne 'True') {
            Write-Host "Включение встроенного правила RDP: $($rule.DisplayName) [$($rule.Name)]"
            Enable-NetFirewallRule -Name $rule.Name -ErrorAction Stop
        }
    }
}

Write-Host 'Удаление завершено.'
