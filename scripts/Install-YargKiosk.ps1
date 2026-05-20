#requires -version 5.1
[CmdletBinding()]
param(
    [ValidateSet('stable', 'nightly')]
    [string]$Channel = 'stable',

    [string]$InstallRoot = 'C:\YARG',
    [string]$KioskUser = 'YargKiosk',
    [string]$KioskFullName = 'YARG Kiosk',
    [securestring]$KioskPassword,

    [string]$AmdDriverUrl = 'https://drivers.amd.com/drivers/whql-amd-software-adrenalin-edition-26.5.1-win11-a.exe',
    [switch]$SkipAmdDriverDownload,
    [switch]$InstallAmdDriver,

    [string]$YargArguments = '-screen-fullscreen 1',
    [switch]$NoAutoLogon,
    [switch]$EnableUnbrandedBoot,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Ejecuta este script desde PowerShell como administrador.'
    }
}

function ConvertTo-PlainText {
    param([securestring]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function New-RandomPassword {
    $bytes = New-Object byte[] 18
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes) -replace '[+/=]', 'x'
}

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$IgnoreExitCode
    )

    Write-Host ">> $FilePath $($ArgumentList -join ' ')"
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle Hidden
    if (-not $IgnoreExitCode -and $process.ExitCode -ne 0) {
        throw "$FilePath termino con codigo $($process.ExitCode)."
    }
}

function Enable-OptionalFeatureIfNeeded {
    param([Parameter(Mandatory)][string]$FeatureName)

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
    if ($null -eq $feature) {
        Write-Warning "No se encontro la feature '$FeatureName'. Verifica que estes en Windows IoT/Enterprise/Education."
        return
    }

    if ($feature.State -ne 'Enabled') {
        Invoke-LoggedProcess -FilePath dism.exe -ArgumentList @('/online', '/enable-feature', "/featurename:$FeatureName", '/NoRestart') -IgnoreExitCode
    }
}

function Get-LatestYargReleaseAsset {
    param([ValidateSet('stable', 'nightly')][string]$SelectedChannel)

    $repo = if ($SelectedChannel -eq 'stable') { 'YARC-Official/YARG' } else { 'YARC-Official/YARG-BleedingEdge' }
    $headers = @{ 'User-Agent' = 'yarg-iot-kiosk-setup' }
    try {
        $release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$repo/releases/latest"
    }
    catch {
        $releases = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$repo/releases?per_page=1"
        if ($releases.Count -lt 1) {
            throw "No encontre releases publicados en $repo."
        }
        $release = $releases[0]
    }

    $asset = $release.assets |
        Where-Object {
            $_.name -match '(?i)(windows|win).*(x64|64).*\.zip$' -or
            $_.name -match '(?i)(x64|64).*(windows|win).*\.zip$'
        } |
        Select-Object -First 1

    if ($null -eq $asset) {
        $names = ($release.assets | ForEach-Object { $_.name }) -join ', '
        throw "No encontre asset Windows x64 .zip en $repo release $($release.tag_name). Assets disponibles: $names"
    }

    [pscustomobject]@{
        Repo = $repo
        Tag = $release.tag_name
        Name = $asset.name
        Url = $asset.browser_download_url
    }
}

function Download-File {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    Write-Host "Descargando: $Uri"
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
}

function Install-Yarg {
    param([ValidateSet('stable', 'nightly')][string]$SelectedChannel)

    $asset = Get-LatestYargReleaseAsset -SelectedChannel $SelectedChannel
    $safeTag = ($asset.Tag -replace '[^\w\.-]', '_')
    $downloadDir = Join-Path $env:ProgramData 'YARG-Kiosk\Downloads'
    $zipPath = Join-Path $downloadDir $asset.Name
    $targetDir = Join-Path $InstallRoot "$SelectedChannel-$safeTag"

    if ((Test-Path $targetDir) -and -not $Force) {
        Write-Host "YARG ya existe en $targetDir. Usa -Force para reextraer."
    }
    else {
        Download-File -Uri $asset.Url -OutFile $zipPath
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $targetDir -Force
    }

    $exe = Get-ChildItem -Path $targetDir -Filter 'YARG.exe' -Recurse -File | Select-Object -First 1
    if ($null -eq $exe) {
        throw "No encontre YARG.exe debajo de $targetDir."
    }

    [pscustomobject]@{
        ExePath = $exe.FullName
        InstallDir = $exe.DirectoryName
        Channel = $SelectedChannel
        Repo = $asset.Repo
        Tag = $asset.Tag
    }
}

function Ensure-KioskUser {
    param(
        [string]$UserName,
        [securestring]$Password,
        [string]$FullName
    )

    $existing = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        New-LocalUser -Name $UserName -Password $Password -FullName $FullName -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    }
    else {
        Set-LocalUser -Name $UserName -Password $Password -PasswordNeverExpires $true
        Enable-LocalUser -Name $UserName
    }

    $accountName = "$env:COMPUTERNAME\$UserName"
    $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
    $adminsGroup = Get-LocalGroup -SID 'S-1-5-32-544'

    if (-not (Get-LocalGroupMember -Group $usersGroup.Name | Where-Object { $_.Name -eq $accountName })) {
        Add-LocalGroupMember -Group $usersGroup.Name -Member $accountName
    }

    if (Get-LocalGroupMember -Group $adminsGroup.Name | Where-Object { $_.Name -eq $accountName }) {
        Remove-LocalGroupMember -Group $adminsGroup.Name -Member $accountName
    }

    ([Security.Principal.NTAccount]::new($env:COMPUTERNAME, $UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Write-YargLauncher {
    param(
        [string]$YargExe,
        [string]$Arguments
    )

    $stateDir = Join-Path $env:ProgramData 'YARG-Kiosk'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

    $launcherPath = Join-Path $stateDir 'Start-YARG.ps1'
    $escapedExe = $YargExe.Replace("'", "''")
    $escapedDir = (Split-Path -Parent $YargExe).Replace("'", "''")
    $escapedArgs = $Arguments.Replace("'", "''")

    $content = @"
`$ErrorActionPreference = 'Continue'
`$logDir = 'C:\ProgramData\YARG-Kiosk\Logs'
New-Item -ItemType Directory -Force -Path `$logDir | Out-Null
`$log = Join-Path `$logDir ('YARG-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
Set-Location -LiteralPath '$escapedDir'
Add-Content -Path `$log -Value "Starting YARG: $escapedExe $escapedArgs"
`$argLine = '$escapedArgs'
`$splitArgs = if ([string]::IsNullOrWhiteSpace(`$argLine)) { @() } else { `$argLine -split ' ' }
`$process = Start-Process -FilePath '$escapedExe' -ArgumentList `$splitArgs -PassThru -Wait
Add-Content -Path `$log -Value "YARG exited with code `$(`$process.ExitCode)"
exit `$process.ExitCode
"@

    Set-Content -Path $launcherPath -Value $content -Encoding ASCII
    $launcherPath
}

function Enable-YargShellLauncher {
    param(
        [string]$KioskSid,
        [string]$LauncherPath
    )

    Enable-OptionalFeatureIfNeeded -FeatureName 'Client-DeviceLockdown'
    Enable-OptionalFeatureIfNeeded -FeatureName 'Client-EmbeddedShellLauncher'

    $class = [wmiclass]'\\localhost\root\standardcimv2\embedded:WESL_UserSetting'
    $restartShell = 0
    $adminsSid = 'S-1-5-32-544'
    $shell = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$LauncherPath`""

    $class.SetDefaultShell('explorer.exe', $restartShell) | Out-Null
    $class.SetCustomShell($adminsSid, 'explorer.exe', $null, $null, $restartShell) | Out-Null
    $class.SetCustomShell($KioskSid, $shell, $null, $null, $restartShell) | Out-Null
    $class.SetEnabled($true) | Out-Null
}

function Enable-CustomLogon {
    Enable-OptionalFeatureIfNeeded -FeatureName 'Client-DeviceLockdown'
    Enable-OptionalFeatureIfNeeded -FeatureName 'Client-EmbeddedLogon'

    reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows Embedded\EmbeddedLogon' /v BrandingNeutral /t REG_DWORD /d 1 /f | Out-Null
    reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows Embedded\EmbeddedLogon' /v HideAutoLogonUI /t REG_DWORD /d 1 /f | Out-Null
    reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows Embedded\EmbeddedLogon' /v HideFirstLogonAnimation /t REG_DWORD /d 1 /f | Out-Null
    reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI' /v AnimationDisabled /t REG_DWORD /d 1 /f | Out-Null
    reg.exe add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization' /v NoLockScreen /t REG_DWORD /d 1 /f | Out-Null
    reg.exe add 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' /v UIVerbosityLevel /t REG_DWORD /d 1 /f | Out-Null
}

function Enable-AutoLogon {
    param(
        [string]$UserName,
        [string]$Password
    )

    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    New-Item -Path $path -Force | Out-Null
    Set-ItemProperty -Path $path -Name AutoAdminLogon -Value '1'
    Set-ItemProperty -Path $path -Name DefaultUserName -Value $UserName
    Set-ItemProperty -Path $path -Name DefaultDomainName -Value $env:COMPUTERNAME
    Set-ItemProperty -Path $path -Name DefaultPassword -Value $Password
}

function Download-AmdDriver {
    param([string]$DriverUrl)

    $fileName = Split-Path -Leaf ([Uri]$DriverUrl).AbsolutePath
    $outFile = Join-Path $env:ProgramData "YARG-Kiosk\Downloads\$fileName"
    if (-not (Test-Path $outFile) -or $Force) {
        Download-File -Uri $DriverUrl -OutFile $outFile
    }
    $outFile
}

Assert-Admin
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($null -eq $KioskPassword) {
    $plainPassword = New-RandomPassword
    $KioskPassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
}
else {
    $plainPassword = ConvertTo-PlainText -SecureString $KioskPassword
}

$yarg = Install-Yarg -SelectedChannel $Channel
$kioskSid = Ensure-KioskUser -UserName $KioskUser -Password $KioskPassword -FullName $KioskFullName
$launcher = Write-YargLauncher -YargExe $yarg.ExePath -Arguments $YargArguments

Enable-CustomLogon
Enable-YargShellLauncher -KioskSid $kioskSid -LauncherPath $launcher

if (-not $NoAutoLogon) {
    Enable-AutoLogon -UserName $KioskUser -Password $plainPassword
}

if ($EnableUnbrandedBoot) {
    Enable-OptionalFeatureIfNeeded -FeatureName 'Client-EmbeddedBootExp'
    Invoke-LoggedProcess -FilePath bcdedit.exe -ArgumentList @('-set', '{globalsettings}', 'advancedoptions', 'false') -IgnoreExitCode
    Invoke-LoggedProcess -FilePath bcdedit.exe -ArgumentList @('-set', '{globalsettings}', 'optionsedit', 'false') -IgnoreExitCode
    Invoke-LoggedProcess -FilePath bcdedit.exe -ArgumentList @('-set', '{globalsettings}', 'bootuxdisabled', 'on') -IgnoreExitCode
}

$driverPath = $null
if (-not $SkipAmdDriverDownload) {
    $driverPath = Download-AmdDriver -DriverUrl $AmdDriverUrl
    if ($InstallAmdDriver) {
        Invoke-LoggedProcess -FilePath $driverPath -ArgumentList @('-INSTALL') -IgnoreExitCode
    }
}

$manifest = [pscustomobject]@{
    ConfiguredAt = (Get-Date).ToString('s')
    Channel = $Channel
    Repo = $yarg.Repo
    Tag = $yarg.Tag
    YargExe = $yarg.ExePath
    KioskUser = $KioskUser
    KioskSid = $kioskSid
    AutoLogon = (-not $NoAutoLogon)
    AmdDriver = $driverPath
}

$manifestPath = Join-Path $env:ProgramData 'YARG-Kiosk\manifest.json'
$manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding ASCII

Write-Host ''
Write-Host 'YARG kiosk configurado.'
Write-Host "YARG: $($yarg.ExePath)"
Write-Host "Usuario kiosk: $KioskUser ($kioskSid)"
Write-Host "Manifest: $manifestPath"
if (-not $NoAutoLogon) {
    Write-Warning 'AutoLogon usa DefaultPassword en Winlogon. La cuenta no es admin, pero la clave queda disponible para administradores locales.'
}
Write-Host 'Reinicia para probar. Si todo esta bien, ejecuta Sysprep y captura la imagen desde WinPE.'
