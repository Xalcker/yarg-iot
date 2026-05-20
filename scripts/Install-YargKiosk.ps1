#requires -version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Features', 'Kiosk')]
    [string]$Stage = 'Auto',

    [string]$ConfigPath,

    [ValidateSet('stable', 'nightly')]
    [string]$Channel = 'stable',

    [string]$InstallRoot = 'C:\YARG',
    [string]$KioskUser = 'YargKiosk',
    [string]$KioskFullName = 'YARG Kiosk',
    [securestring]$KioskPassword,

    [string]$AmdDriverUrl = 'https://drivers.amd.com/drivers/whql-amd-software-adrenalin-edition-26.5.1-win11-a.exe',
    [switch]$SkipAmdDriverDownload,
    [switch]$InstallAmdDriver,

    [switch]$SkipKeyboardFilter,
    [string[]]$BlockedPredefinedKeys = @(
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
    ),
    [int]$KeyboardBreakoutKeyScanCode = 71,

    [string]$YargArguments = '-screen-fullscreen 1',
    [switch]$NoAutoLogon,
    [switch]$EnableUnbrandedBoot,
    [switch]$NoRestart,
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

function Get-StateDir {
    Join-Path $env:ProgramData 'YARG-Kiosk'
}

function Save-InstallConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PlainPassword
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    $config = [pscustomobject]@{
        Channel = $Channel
        InstallRoot = $InstallRoot
        KioskUser = $KioskUser
        KioskFullName = $KioskFullName
        PlainPassword = $PlainPassword
        AmdDriverUrl = $AmdDriverUrl
        SkipAmdDriverDownload = [bool]$SkipAmdDriverDownload
        InstallAmdDriver = [bool]$InstallAmdDriver
        SkipKeyboardFilter = [bool]$SkipKeyboardFilter
        BlockedPredefinedKeys = $BlockedPredefinedKeys
        KeyboardBreakoutKeyScanCode = $KeyboardBreakoutKeyScanCode
        YargArguments = $YargArguments
        NoAutoLogon = [bool]$NoAutoLogon
        EnableUnbrandedBoot = [bool]$EnableUnbrandedBoot
        Force = [bool]$Force
    }

    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding ASCII
}

function Import-InstallConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "No existe el archivo de configuracion por etapas: $Path"
    }

    $config = Get-Content -Path $Path -Raw | ConvertFrom-Json
    $script:Channel = $config.Channel
    $script:InstallRoot = $config.InstallRoot
    $script:KioskUser = $config.KioskUser
    $script:KioskFullName = $config.KioskFullName
    $script:KioskPassword = ConvertTo-SecureString ([string]$config.PlainPassword) -AsPlainText -Force
    $script:AmdDriverUrl = $config.AmdDriverUrl
    $script:SkipAmdDriverDownload = [bool]$config.SkipAmdDriverDownload
    $script:InstallAmdDriver = [bool]$config.InstallAmdDriver
    $script:SkipKeyboardFilter = [bool]$config.SkipKeyboardFilter
    $script:BlockedPredefinedKeys = @($config.BlockedPredefinedKeys)
    $script:KeyboardBreakoutKeyScanCode = [int]$config.KeyboardBreakoutKeyScanCode
    $script:YargArguments = $config.YargArguments
    $script:NoAutoLogon = [bool]$config.NoAutoLogon
    $script:EnableUnbrandedBoot = [bool]$config.EnableUnbrandedBoot
    $script:Force = [bool]$config.Force

    [string]$config.PlainPassword
}

function Register-StageTwo {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$SavedConfigPath
    )

    $command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Stage Kiosk -ConfigPath `"$SavedConfigPath`""
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'YARG Kiosk Stage 2' -Value $command
}

function Enable-RequiredFeatures {
    Enable-OptionalFeatureIfNeeded -FeatureName 'Client-DeviceLockdown'
    Enable-OptionalFeatureIfNeeded -FeatureName 'Client-EmbeddedShellLauncher'
    Enable-OptionalFeatureIfNeeded -FeatureName 'Client-EmbeddedLogon'
    if (-not $SkipKeyboardFilter) {
        Enable-OptionalFeatureIfNeeded -FeatureName 'Client-KeyboardFilter'
    }
    if ($EnableUnbrandedBoot) {
        Enable-OptionalFeatureIfNeeded -FeatureName 'Client-EmbeddedBootExp'
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
    $class = [wmiclass]'\\localhost\root\standardcimv2\embedded:WESL_UserSetting'
    $restartShell = 0
    $adminsSid = 'S-1-5-32-544'
    $shell = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$LauncherPath`""

    $class.SetDefaultShell('explorer.exe', $restartShell) | Out-Null
    $class.SetCustomShell($adminsSid, 'explorer.exe', $null, $null, $restartShell) | Out-Null
    $class.SetCustomShell($KioskSid, $shell, $null, $null, $restartShell) | Out-Null
    $class.SetEnabled($true) | Out-Null
}

function Set-KeyboardFilterSetting {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $setting = Get-WmiObject -Namespace 'root\standardcimv2\embedded' -Class WEKF_Settings -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $Name }

    if ($null -eq $setting) {
        Write-Warning "No pude configurar Keyboard Filter '$Name'. Puede requerir reinicio tras habilitar la feature."
        return
    }

    $setting.Value = $Value
    $setting.Put() | Out-Null
}

function Enable-YargKeyboardFilter {
    param(
        [string[]]$Keys,
        [int]$BreakoutScanCode
    )
    Set-KeyboardFilterSetting -Name 'DisableKeyboardFilterForAdministrators' -Value 'true'
    Set-KeyboardFilterSetting -Name 'ForceOffAccessibility' -Value 'true'
    Set-KeyboardFilterSetting -Name 'BreakoutKeyScanCode' -Value ([string]$BreakoutScanCode)

    try {
        $class = [wmiclass]'\\localhost\root\standardcimv2\embedded:WEKF_PredefinedKey'
    }
    catch {
        Write-Warning 'No pude abrir WEKF_PredefinedKey. Reinicia y vuelve a ejecutar el script para aplicar las teclas bloqueadas.'
        return
    }

    foreach ($key in $Keys) {
        try {
            $result = $class.Enable($key)
            if ($result.ReturnValue -ne 0) {
                Write-Warning "Keyboard Filter no acepto '$key' (ReturnValue=$($result.ReturnValue))."
            }
        }
        catch {
            Write-Warning "Keyboard Filter no pudo bloquear '$key': $($_.Exception.Message)"
        }
    }
}

function Enable-CustomLogon {
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
$stateDir = Get-StateDir
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $stateDir 'install-config.json'
}

if ($Stage -eq 'Kiosk') {
    $plainPassword = Import-InstallConfig -Path $ConfigPath
}
else {
    if ($null -eq $KioskPassword) {
        $plainPassword = New-RandomPassword
        $KioskPassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    }
    else {
        $plainPassword = ConvertTo-PlainText -SecureString $KioskPassword
    }
}

if ($Stage -eq 'Auto' -or $Stage -eq 'Features') {
    $sourceScript = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $stagedScript = Join-Path $stateDir 'Install-YargKiosk.ps1'
    Copy-Item -LiteralPath $sourceScript -Destination $stagedScript -Force
    $revertSource = Join-Path (Split-Path -Parent $sourceScript) 'Revert-YargKiosk.ps1'
    if (Test-Path $revertSource) {
        Copy-Item -LiteralPath $revertSource -Destination (Join-Path $stateDir 'Revert-YargKiosk.ps1') -Force
    }

    Save-InstallConfig -Path $ConfigPath -PlainPassword $plainPassword
    Enable-RequiredFeatures
    Register-StageTwo -ScriptPath $stagedScript -SavedConfigPath $ConfigPath

    Write-Host ''
    Write-Host 'Etapa 1 completada: features de Device Lockdown habilitadas.'
    Write-Host "Etapa 2 agendada con RunOnce: $stagedScript"
    Write-Host 'Despues del reinicio, entra con la cuenta administradora/auditoria para completar la configuracion del kiosko.'

    if ($NoRestart) {
        Write-Host 'Reinicio omitido por -NoRestart. Reinicia manualmente para continuar.'
    }
    else {
        Write-Host 'Reiniciando en 10 segundos...'
        Start-Sleep -Seconds 10
        Restart-Computer
    }

    exit 0
}

$yarg = Install-Yarg -SelectedChannel $Channel
$kioskSid = Ensure-KioskUser -UserName $KioskUser -Password $KioskPassword -FullName $KioskFullName
$launcher = Write-YargLauncher -YargExe $yarg.ExePath -Arguments $YargArguments

Enable-CustomLogon
Enable-YargShellLauncher -KioskSid $kioskSid -LauncherPath $launcher

if (-not $SkipKeyboardFilter) {
    Enable-YargKeyboardFilter -Keys $BlockedPredefinedKeys -BreakoutScanCode $KeyboardBreakoutKeyScanCode
}

if (-not $NoAutoLogon) {
    Enable-AutoLogon -UserName $KioskUser -Password $plainPassword
}

if ($EnableUnbrandedBoot) {
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
    KeyboardFilter = (-not $SkipKeyboardFilter)
    KeyboardBreakoutKeyScanCode = if ($SkipKeyboardFilter) { $null } else { $KeyboardBreakoutKeyScanCode }
    BlockedPredefinedKeys = if ($SkipKeyboardFilter) { @() } else { $BlockedPredefinedKeys }
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
if (-not $SkipKeyboardFilter) {
    Write-Host "Keyboard Filter activo para usuarios no admin. Pulsa Home 5 veces para salir a la pantalla de bienvenida."
}
if ($NoRestart) {
    Write-Host 'Reinicio final omitido por -NoRestart. Reinicia manualmente para probar el kiosko.'
}
else {
    Write-Host 'Reiniciando en 10 segundos para probar el kiosko...'
    Start-Sleep -Seconds 10
    Restart-Computer
}
