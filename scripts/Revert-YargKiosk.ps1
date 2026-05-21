#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Ejecuta este script desde PowerShell como administrador.'
}

try {
    $class = [wmiclass]'\\localhost\root\standardcimv2\embedded:WESL_UserSetting'
    $class.SetDefaultShell('explorer.exe', 0) | Out-Null

    # Intenta leer el SID del manifiesto de instalación para limpiar la shell personalizada
    $manifestPath = Join-Path $env:ProgramData 'YARG-Kiosk\manifest.json'
    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
            $sid = $manifest.ShellSid
            if ($sid) {
                Write-Host "Eliminando shell personalizada en WMI para el SID: $sid"
                $class.RemoveCustomShell($sid) | Out-Null
            }
        }
        catch {
            Write-Warning "No pude limpiar la shell personalizada especifica para el SID: $($_.Exception.Message)"
        }
    }

    $class.SetEnabled($false) | Out-Null
}
catch {
    Write-Warning "No pude desactivar Shell Launcher por WMI: $($_.Exception.Message)"
}

$blockedPredefinedKeys = @(
    'Ctrl+Alt+Del',
    'Shift+Ctrl+Esc',
    'Ctrl+Esc',
    'Alt+Tab',
    'Alt+F4',
    'Alt+Space',
    'Win+L',
    'Win+R',
    'Win+E',
    'Win+I',
    'Win+U',
    'Win+X',
    'Win+Tab',
    'Windows'
)

try {
    $keyboardClass = [wmiclass]'\\localhost\root\standardcimv2\embedded:WEKF_PredefinedKey'
    foreach ($key in $blockedPredefinedKeys) {
        $keyboardClass.Disable($key) | Out-Null
    }

    $settings = Get-WmiObject -Namespace 'root\standardcimv2\embedded' -Class WEKF_Settings -ErrorAction SilentlyContinue
    foreach ($setting in $settings) {
        if ($setting.Name -eq 'ForceOffAccessibility') {
            $setting.Value = 'false'
            $setting.Put() | Out-Null
        }
        elseif ($setting.Name -eq 'DisableKeyboardFilterForAdministrators') {
            $setting.Value = 'true'
            $setting.Put() | Out-Null
        }
    }
}
catch {
    Write-Warning "No pude revertir Keyboard Filter: $($_.Exception.Message)"
}

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0'
Set-ItemProperty -Path $winlogon -Name Shell -Value 'explorer.exe'
Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $winlogon -Name DefaultUserName -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $winlogon -Name DefaultDomainName -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'YARG Kiosk Stage 2' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'YARG Kiosk Kiosk' -ErrorAction SilentlyContinue

Start-Process explorer.exe -ErrorAction SilentlyContinue

Write-Host 'Shell Launcher desactivado, Keyboard Filter desbloqueado, RunOnce limpiado y AutoLogon eliminado. Reinicia para volver a Explorer.'
