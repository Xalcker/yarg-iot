# Kiosko YARG en Windows IoT Enterprise

Este paquete deja una imagen de referencia de Windows IoT Enterprise lista para arrancar directo a YARG usando Shell Launcher en una cuenta local no administradora. El canal de YARG se puede elegir entre `stable` y `nightly`.

## Fuentes usadas

- Microsoft Learn: preparar entorno de laboratorio, instalar Windows IoT Enterprise y entrar en modo auditoria.
- Microsoft Learn: personalizar el dispositivo en modo auditoria con Device Lockdown, Custom Logon, Unbranded Boot y Shell Launcher.
- Microsoft Learn: ejecutar Sysprep, capturar la imagen con WinPE/DISM y desplegarla en otro dispositivo.
- GitHub Releases de `YARC-Official/YARG` para stable y `YARC-Official/YARG-BleedingEdge` para nightly.
- AMD Radeon RX 6400 driver page. A fecha 2026-05-20 el driver recomendado publicado en la pagina enlazada es Adrenalin 26.5.1 para Windows 11 64-bit, release date 2026-05-06.

## Flujo recomendado

1. En el PC tecnico, instala Windows ADK con Deployment Tools, Configuration Designer y Windows PE add-on.
2. Crea el USB de instalacion de Windows 11 IoT Enterprise LTSC 2024 y arranca el equipo objetivo.
3. Cuando Windows Setup llegue a OOBE, en la pantalla de region, entra en modo auditoria con `Ctrl+Shift+F3`. No termines OOBE todavia.
4. En modo auditoria, abre PowerShell como administrador y ejecuta el instalador de este repo.
5. El script hace una primera etapa, reinicia, y se reanuda solo con `RunOnce` para aplicar Shell Launcher/Keyboard Filter cuando las clases WMI ya existen.
6. Tras el segundo reinicio debe iniciar sesion automaticamente como `YargKiosk` y abrir YARG.
7. Cuando este validado, ejecuta Sysprep y captura la imagen desde WinPE.

## Instalacion rapida

Ejecutar desde PowerShell elevado en el dispositivo de referencia:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Install-YargKiosk.ps1 -Channel stable
```

Por defecto la cuenta local `YargKiosk` usa la contrasena `YargKiosk123!`. Puedes cambiarla:

```powershell
.\scripts\Install-YargKiosk.ps1 -Channel stable -KioskPasswordText "UnaClaveLocal123!"
```

Nightly:

```powershell
.\scripts\Install-YargKiosk.ps1 -Channel nightly
```

Con instalacion silenciosa del paquete AMD descargado:

```powershell
.\scripts\Install-YargKiosk.ps1 -Channel stable -InstallAmdDriver
```

El script descarga el instalador AMD RX 6400 al cache local siempre que no uses `-SkipAmdDriverDownload`. La instalacion silenciosa usa `-INSTALL`, que AMD documenta para Radeon Software; si falla en una version concreta, ejecuta el `.exe` descargado manualmente o extrae el paquete y lanza su `Setup.exe -INSTALL`.

El comportamiento por defecto es por etapas:

- Etapa 1: habilita features de Device Lockdown y agenda la etapa 2 con `RunOnce`.
- Reinicio 1: Windows termina de instalar las features.
- Etapa AMD, solo si usas `-InstallAmdDriver`: descarga/ejecuta el instalador AMD mientras todavia estas en Explorer/admin.
- Reinicio AMD: deja que Windows termine de aplicar el driver de video antes del kiosko.
- Etapa Kiosk: descarga YARG, crea usuario, aplica Custom Logon, Keyboard Filter, Shell Launcher y AutoLogon.
- Reinicio final: prueba real del kiosko.

Si quieres que AMD se instale con otros argumentos, por ejemplo auto-reinicio del propio instalador:

```powershell
.\scripts\Install-YargKiosk.ps1 -Channel stable -InstallAmdDriver -AmdInstallArguments '-INSTALL','-boot'
```

Para hacer las etapas sin reiniciar automaticamente:

```powershell
.\scripts\Install-YargKiosk.ps1 -Channel stable -NoRestart
```

Si necesitas dejar temporalmente el teclado sin filtrar durante pruebas:

```powershell
.\scripts\Install-YargKiosk.ps1 -Channel stable -SkipKeyboardFilter
```

## Que configura el script

- Descarga el ultimo release de GitHub segun canal:
  - `stable`: `YARC-Official/YARG`
  - `nightly`: `YARC-Official/YARG-BleedingEdge`
- Extrae YARG bajo `C:\YARG\<canal>-<tag>`.
- Crea o actualiza la cuenta local `YargKiosk` sin privilegios de administrador. Por defecto usa `YargKiosk123!`, o el valor de `-KioskPasswordText`.
- Habilita Shell Launcher y asigna a `YargKiosk` un shell personalizado que arranca YARG.
- Deja `explorer.exe` para el grupo local Administrators.
- Configura inicio de sesion automatico para `YargKiosk`, salvo que pases `-NoAutoLogon`.
- Habilita Custom Logon para ocultar elementos de inicio de sesion comunes.
- Habilita Keyboard Filter para usuarios no administradores y bloquea combinaciones de salida como `Ctrl+Alt+Del`, `Shift+Ctrl+Esc`, `Ctrl+Esc`, `Alt+Tab`, `Alt+F4`, `Win+L`, `Win+R`, `Win+E`, `Win+I`, `Win+U`, `Win+X`, `Win+Tab` y la tecla Windows.
- Deja Keyboard Filter desactivado para administradores y configura `Home` cinco veces como tecla de escape a la pantalla de bienvenida.
- El arranque sin marca queda disponible con `-EnableUnbrandedBoot`, porque cambia opciones de `bcdedit` que conviene probar por hardware antes de capturar imagen.

## Captura e implementacion

Cuando el dispositivo de referencia ya este probado:

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

No vuelvas a arrancar Windows despues de Sysprep hasta capturar la imagen. Arranca WinPE y captura la particion de Windows:

```cmd
Dism /capture-image /imagefile:D:\YARG-IoT.wim /CaptureDir:W:\ /Name:"Windows IoT Enterprise YARG Kiosk"
wpeutil shutdown
```

Para desplegar en otro disco desde WinPE:

```cmd
Dism /Apply-Image /ImageFile:D:\YARG-IoT.wim /ApplyDir:W:\ /Index:1
W:\Windows\System32\bcdboot W:\Windows /s S:
wpeutil reboot
```

Antes de estos comandos debes identificar correctamente las letras de unidad con `diskpart`, tal como indica Microsoft: normalmente `W:` para Windows, `S:` para EFI y `D:` para la particion/USB donde esta el WIM. Los comandos `diskpart clean` borran discos completos; verifica dos veces el numero de disco.

## Revertir

Para desactivar el kiosko y volver a Explorer:

```powershell
.\scripts\Revert-YargKiosk.ps1
```

Esto desactiva Shell Launcher, restaura el shell por defecto a `explorer.exe` y elimina el autologon configurado por este paquete.

## Recuperacion de pantalla negra

Si el equipo queda en negro antes de aplicar esta version por etapas:

1. Intenta mantener `Shift` presionado durante el arranque para saltarte AutoLogon y entrar con una cuenta administradora.
2. Si Keyboard Filter quedo activo, pulsa `Home` cinco veces para volver a la pantalla de bienvenida.
3. Si puedes abrir Task Manager, usa `File > Run new task`, marca privilegios de administrador y ejecuta `powershell`.
4. Desde PowerShell elevado:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Revert-YargKiosk.ps1
```

La etapa 1 tambien copia una salida de emergencia a:

```powershell
C:\ProgramData\YARG-Kiosk\Revert-YargKiosk.ps1
```

Si no puedes abrir sesion, arranca en WinRE/WinPE y usa System Restore o carga la instalacion para eliminar AutoLogon. La version nueva retrasa Shell Launcher hasta despues del primer reinicio para evitar ese estado.

## Reparar AutoLogon

Si despues de la segunda etapa Windows muestra `The user name or password is incorrect`, entra al escritorio admin/auditoria, abre PowerShell como administrador y fuerza una clave conocida:

```powershell
net user YargKiosk "YargKiosk123!" /active:yes /passwordchg:no /expires:never
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d ".\YargKiosk" /f
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultDomainName /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d "YargKiosk123!" /f
shutdown /r /t 0
```

Que aparezca `System Preparation Tool` al entrar al escritorio admin es normal mientras sigas en modo auditoria.

Tambien puedes usar el script de reparacion:

```powershell
.\scripts\Repair-YargAutoLogon.ps1 -Restart
```

Si Windows insiste en volver al admin de auditoria aunque el usuario/clave esten bien:

```powershell
.\scripts\Repair-YargAutoLogon.ps1 -DisableAuditModeMarkers -Restart
```

Esto no reemplaza el cierre formal con Sysprep; solo sirve para probar el kiosko antes de capturar.
