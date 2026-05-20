# Kiosko YARG en Windows IoT Enterprise

Este paquete prepara Windows IoT Enterprise para arrancar YARG como shell usando la cuenta default/actual del sistema, sin crear usuarios adicionales y sin automatizar drivers de video.

El canal de YARG se puede elegir entre `stable` y `nightly`.

## Fuentes usadas

- Microsoft Learn: preparar entorno de laboratorio, instalar Windows IoT Enterprise y entrar en modo auditoria.
- Microsoft Learn: personalizar el dispositivo en modo auditoria con Device Lockdown, Custom Logon, Unbranded Boot y Shell Launcher.
- Microsoft Learn: ejecutar Sysprep, capturar la imagen con WinPE/DISM y desplegarla en otro dispositivo.
- GitHub Releases de `YARC-Official/YARG` para stable y `YARC-Official/YARG-BleedingEdge` para nightly.

## Flujo recomendado

1. Instala Windows IoT Enterprise y entra en modo auditoria con `Ctrl+Shift+F3`.
2. Abre PowerShell como administrador.
3. Ejecuta la etapa inicial del instalador.
4. Reinicia y deja que Windows termine de habilitar Device Lockdown.
5. Instala manualmente los drivers de video AMD, NVIDIA o Intel desde el instalador oficial del fabricante.
6. Reinicia y confirma resolucion correcta, aceleracion de GPU, audio y controles.
7. Ejecuta la etapa `Kiosk` para descargar YARG y aplicar Shell Launcher.
8. Cuando todo este validado, ejecuta Sysprep y captura la imagen desde WinPE.

## Instalacion

Stable, etapa inicial:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Install-YargKiosk.ps1 -Channel stable
```

Nightly, etapa inicial:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Install-YargKiosk.ps1 -Channel nightly
```

Despues del reinicio, instala manualmente drivers de video. Cuando el escritorio se vea bien, ejecuta:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\ProgramData\YARG-Kiosk\Install-YargKiosk.ps1 -Stage Kiosk -ConfigPath C:\ProgramData\YARG-Kiosk\install-config.json
```

Para probar sin filtrar teclado:

```powershell
C:\ProgramData\YARG-Kiosk\Install-YargKiosk.ps1 -Stage Kiosk -ConfigPath C:\ProgramData\YARG-Kiosk\install-config.json -SkipKeyboardFilter
```

## Drivers

Los drivers ya no son parte de la automatizacion. Instala manualmente el paquete correcto antes de la etapa `Kiosk`:

- AMD Radeon: usa AMD Software Adrenalin para tu GPU.
- NVIDIA: usa el driver GeForce/RTX/Quadro correspondiente.
- Intel: usa Intel Graphics Driver/Arc & Iris Xe segun el hardware.

Haz este paso despues del primer reinicio del script y antes de aplicar Shell Launcher. Reinicia las veces necesarias hasta que la resolucion y el administrador de dispositivos se vean correctos.

## Que configura

- Descarga YARG desde el ultimo release segun canal:
  - `stable`: `YARC-Official/YARG`
  - `nightly`: `YARC-Official/YARG-BleedingEdge`
- Extrae YARG bajo `C:\YARG\<canal>-<tag>`.
- Aplica Shell Launcher al SID del usuario que ejecuta la etapa `Kiosk`.
- Mantiene `explorer.exe` como shell por defecto para otros usuarios.
- Limpia restos de AutoLogon de versiones anteriores del script.
- Lanza `YARG.exe` directamente como shell.
- Habilita Custom Logon.
- Habilita Keyboard Filter, salvo que uses `-SkipKeyboardFilter`.
- Configura `Home` cinco veces como tecla de escape.

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
