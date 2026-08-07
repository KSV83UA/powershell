Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow | 
Select-Object DisplayName, 
@{Name='Protocol';E={($PSItem | Get-NetFirewallPortFilter).Protocol}}, 
@{Name='LocalPort';E={($PSItem | Get-NetFirewallPortFilter).LocalPort}}, 
Profile | Sort-Object LocalPort
pause