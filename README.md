# Kiosko YARG en Windows IoT Enterprise

Este paquete prepara una imagen de referencia de Windows IoT Enterprise para arrancar YARG como shell usando la cuenta default/actual del sistema, sin crear una cuenta local adicional.

El canal de YARG se puede elegir entre `stable` y `nightly`.

## Fuentes usadas

- Microsoft Learn: preparar entorno de laboratorio, instalar Windows IoT Enterprise y entrar en modo auditoria.
- Microsoft Learn: personalizar el dispositivo en modo auditoria con Device Lockdown, Custom Logon, Unbranded Boot y Shell Launcher.
- Microsoft Learn: ejecutar Sysprep, capturar la imagen con WinPE/DISM y desplegarla en otro dispositivo.
- GitHub Releases de `YARC-Official/YARG` para stable y `YARC-Official/YARG-BleedingEdge` para nightly.
- AMD Radeon RX 6400 driver page. A fecha 2026-05-20 el driver recomendado publicado en la pagina enlazada es Adrenalin 26.5.1 para Windows 11 64-bit, release date 2026-05-06.

## Flujo recomendado

1. Instala Windows IoT Enterprise y entra en modo auditoria con `Ctrl+Shift+F3`.
2. Abre PowerShell como administrador.
3. Ejecuta el instalador desde este repo.
4. El script habilita features, reinicia y se reanuda con `RunOnce`.
5. Si usas `-InstallAmdDriver`, instala AMD en una etapa separada antes del kiosko.
6. La etapa final aplica Shell Launcher al usuario actual/default y reinicia.
7. Cuando todo este validado, ejecuta Sysprep y captura la imagen desde WinPE.

## Instalacion rapida

Stable:

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

Para probar sin filtrar teclado:

```powershell
.\scripts\Install-YargKiosk.ps1 -Channel stable -SkipKeyboardFilter
```

## Etapas

- Etapa 1: habilita Device Lockdown, Shell Launcher, Custom Logon, Keyboard Filter y opcionalmente Unbranded Boot.
- Reinicio 1: Windows termina de instalar features.
- Etapa AMD, solo si usas `-InstallAmdDriver`: ejecuta el driver AMD mientras sigues en Explorer/admin.
- Reinicio AMD: permite que Windows termine de aplicar el driver.
- Etapa Kiosk: descarga YARG, crea el launcher, aplica Custom Logon, Keyboard Filter y Shell Launcher al usuario actual/default.
- Reinicio final: prueba real del kiosko.

El script ya no crea `YargKiosk`, no cambia contrasenas y no configura AutoLogon. En modo auditoria, Windows normalmente vuelve a entrar al administrador/audit user; ese mismo usuario sera el que reciba Shell Launcher.

## Que configura

- Descarga YARG desde el ultimo release segun canal:
  - `stable`: `YARC-Official/YARG`
  - `nightly`: `YARC-Official/YARG-BleedingEdge`
- Extrae YARG bajo `C:\YARG\<canal>-<tag>`.
- Aplica Shell Launcher al SID del usuario que ejecuta la etapa `Kiosk`.
- Mantiene `explorer.exe` como shell por defecto para otros usuarios.
- Limpia restos de AutoLogon de versiones anteriores del script.
- Habilita Custom Logon.
- Habilita Keyboard Filter, salvo que uses `-SkipKeyboardFilter`.
- Configura `Home` cinco veces como tecla de escape.
- Descarga el instalador AMD RX 6400 al cache local, salvo que uses `-SkipAmdDriverDownload`.

El cache queda en:

```powershell
C:\ProgramData\YARG-Kiosk\Downloads
```

## Driver AMD

Por defecto el script solo descarga el instalador AMD. Si pasas `-InstallAmdDriver`, lo ejecuta en etapa separada con:

```powershell
-INSTALL
```

Puedes cambiar argumentos:

```powershell
.\scripts\Install-YargKiosk.ps1 -Channel stable -InstallAmdDriver -AmdInstallArguments '-INSTALL','-boot'
```

Si el instalador no completa, ejecuta manualmente el `.exe` desde:

```powershell
C:\ProgramData\YARG-Kiosk\Downloads
```

## Revertir

Para desactivar el kiosko y volver a Explorer:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Revert-YargKiosk.ps1
```

El revert desactiva Shell Launcher, desbloquea Keyboard Filter, limpia `RunOnce`, restaura `Winlogon\Shell=explorer.exe` y elimina restos de AutoLogon de versiones anteriores del script.

## Captura

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

Verifica las letras con `diskpart`; los comandos de particionado pueden borrar discos completos.
