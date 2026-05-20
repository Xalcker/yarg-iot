#requires -version 5.1
[CmdletBinding()]
param(
    [string]$KioskUser = 'YargKiosk',
    [string]$KioskPasswordText = 'YargKiosk123!',
    [switch]$DisableAuditModeMarkers,
    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Ejecuta este script desde PowerShell como administrador.'
}

$securePassword = ConvertTo-SecureString $KioskPasswordText -AsPlainText -Force
if (-not (Get-LocalUser -Name $KioskUser -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $KioskUser -Password $securePassword -FullName 'YARG Kiosk' -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
}
else {
    Set-LocalUser -Name $KioskUser -Password $securePassword -PasswordNeverExpires $true
    Enable-LocalUser -Name $KioskUser
}

net.exe user $KioskUser $KioskPasswordText /active:yes /passwordchg:no /expires:never | Out-Null

$accountName = "$env:COMPUTERNAME\$KioskUser"
$usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
$adminsGroup = Get-LocalGroup -SID 'S-1-5-32-544'
if (-not (Get-LocalGroupMember -Group $usersGroup.Name | Where-Object { $_.Name -eq $accountName })) {
    Add-LocalGroupMember -Group $usersGroup.Name -Member $accountName
}
if (Get-LocalGroupMember -Group $adminsGroup.Name | Where-Object { $_.Name -eq $accountName }) {
    Remove-LocalGroupMember -Group $adminsGroup.Name -Member $accountName
}

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
New-Item -Path $winlogon -Force | Out-Null
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1'
Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value ".\$KioskUser"
Remove-ItemProperty -Path $winlogon -Name DefaultDomainName -ErrorAction SilentlyContinue
Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value $KioskPasswordText

if ($DisableAuditModeMarkers) {
    Set-ItemProperty -Path $winlogon -Name AuditInProgress -Value 0 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $winlogon -Name ForceUnlockLogon -Value 0 -ErrorAction SilentlyContinue
}

Write-Host 'AutoLogon actual:'
Get-ItemProperty -Path $winlogon |
    Select-Object AutoAdminLogon, DefaultUserName, DefaultDomainName, Shell, AuditInProgress |
    Format-List

Write-Host "Cuenta local reparada: .\$KioskUser"
if ($DisableAuditModeMarkers) {
    Write-Warning 'Se marcaron indicadores de modo auditoria en Winlogon como 0. Para salir formalmente de auditoria usa Sysprep /oobe cuando termines.'
}

if ($Restart) {
    Restart-Computer
}
