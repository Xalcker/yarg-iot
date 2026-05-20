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
5. Prueba el reinicio del dispositivo. Debe iniciar sesion automaticamente como `YargKiosk` y abrir YARG.
6. Cuando este validado, ejecuta Sysprep y captura la imagen desde WinPE.

## Instalacion rapida

Ejecutar desde PowerShell elevado en el dispositivo de referencia:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Install-YargKiosk.ps1 -Channel stable
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

## Que configura el script

- Descarga el ultimo release de GitHub segun canal:
  - `stable`: `YARC-Official/YARG`
  - `nightly`: `YARC-Official/YARG-BleedingEdge`
- Extrae YARG bajo `C:\YARG\<canal>-<tag>`.
- Crea o actualiza la cuenta local `YargKiosk` sin privilegios de administrador.
- Habilita Shell Launcher y asigna a `YargKiosk` un shell personalizado que arranca YARG.
- Deja `explorer.exe` para el grupo local Administrators.
- Configura inicio de sesion automatico para `YargKiosk`, salvo que pases `-NoAutoLogon`.
- Habilita Custom Logon para ocultar elementos de inicio de sesion comunes.

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
