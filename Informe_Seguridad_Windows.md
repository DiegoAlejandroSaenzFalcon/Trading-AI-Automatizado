# Informe de Auditoría de Seguridad — Windows

**Equipo:** DESKTOP-4Q4GFM5 (Lenovo, modelo 82XB)
**Sistema:** Microsoft Windows 11 IoT Enterprise LTSC, Build 26100 (64 bits)
**Fecha del análisis:** 08/08/2026
**Método:** Escaneo local con PowerShell (lectura de registro, WMI/CIM, servicios, firewall, red, cuentas y eventos)
**Nivel de acceso usado:** usuario estándar (no administrador) — varios chequeos quedaron pendientes de verificación con cuenta admin (se indican con ➜)

---

## 1. Resumen ejecutivo

La postura de seguridad general es **media-buena**: Windows Defender está activo y con protección en tiempo real y tamper-protection, el firewall está habilitado en los 3 perfiles, RDP, WinRM y el registro remoto están deshabilitados, la cuenta Invitado y Administrador integradas están deshabilitadas, el SMBv1 está apagado y no hay recursos compartidos creados por el usuario.

Sin embargo, existen **2 hallazgos críticos y 4 altos** que deben corregirse de forma prioritaria: la cuenta de usuario **no tiene requisito de contraseña**, **Secure Boot está desactivado** en la BIOS y el **cifrado del disco es desconocido/no verificado**. Además hay reglas de firewall inbound abiertas al perfil Público para procesos de desarrollo que amplían la superficie de ataque en redes no confiables.

> **ACTUALIZACIÓN 08/08/2026 (tras el endurecimiento ejecutado):** contraseña de H2R establecida ✅ · BitLocker verificado: **ACTIVO** (XTS-AES 128, TPM + contraseña numérica) ✅ · 13 reglas de firewall de desarrollo eliminadas ✅ · ejecution policy RemoteSigned ✅ · LLMNR bloqueado ✅ · política de contraseñas endurecida (mín. 14, historial 3, bloqueo 5) ✅ · log de seguridad a 1 GB ✅ · SMB cifrado obligatorio ✅ · perfiles Wi-Fi obsoletos eliminados ✅ · exclusión de Defender a la carpeta de activaciones eliminada ✅. **Pendiente manual: activar Secure Boot y poner contraseña de BIOS + actualizar firmware (ver Sección 12).**

| Severidad | Cantidad |
|---|---|
| 🔴 Crítica | 2 |
| 🟠 Alta | 4 |
| 🟡 Media | 7 |
| 🟢 Baja / Información | 6 |

**Puntuación general de postura de seguridad: 6.5/10 antes del endurecimiento → 8.5/10 tras la sesión del 08/08/2026** (ver acta en Sección 12; el 1.5 restante depende de la BIOS: Secure Boot + contraseña de firmware).

---

## 2. Inventario del sistema

| Parámetro | Valor |
|---|---|
| OS | Windows 11 IoT Enterprise LTSC 26100 (64 bits) |
| Instalación del OS | 12/05/2026 |
| Último arranque | 30/07/2026 |
| Fabricante / Modelo | LENOVO 82XB (IdeaPad 3) |
| RAM | ~8 GB |
| Red | Solo Wi-Fi Intel Wi-Fi 6 AX203 (866.7 Mbps) |
| Usuario | H2R (cuenta local, NO Microsoft) |
| Dominio | WORKGROUP |
| Cuenta con privilegios de auditor: | **NO** (los chequeos puros de admin están marcados ➜) |

---

## 3. Resultados por dominio

### 3.1 Actualizaciones de Windows — ✅ Correcto

- Último paquete acumulativo instalado: **29/07/2026** (KB5101684/KB5101711) ✅
- Los eventos del proveedor WindowsUpdateClient muestran instalaciones exitosas **incluso el mismo día del análisis** (08/08) ✅
- El servicio wuauserv está en Manual (comportamiento normal de LTSC, se activa bajo demanda) – no indica problema.
- ➜ Verificar en Configuración > Windows Update que no haya actualizaciones pendientes ni reinicio pendiente.

### 3.2 Windows Defender — ✅ Correcto (bien configuradas)

| Chequeo | Estado |
|---|---|
| Antivirus en tiempo real | ✅ Activo |
| Protección antispyware | ✅ Activa |
| Monitoreo de comportamiento | ✅ Activo (Defender/IOAV/OnAccess) |
| Protección de red / IOAV | ✅ Activo |
| Firmas de virus | ✅ Actualizadas hoy (edad 0 días) |
| Tamper Protection | ✅ Activa |
| Historial de amenazas | Vacío (sin detecciones previas) |
| Deshabilitar AV por registro | 0 (no deshabilitado) |

NOTA: No hay detecciones en el historial — buen indicio de que no hay muestras procesadas, pero advertencia: un historial vacío también puede indicar que el escaneo rápido completo no se ha ejecutado (no es posible leerlo sin admin). ➜ Ejecutar «exclusión completa» de convivencia ni exclusiones configuradas (no legibles sin admin ➜).

### 3.3 Firewall — ✅ activa, con reglas mejorables

- Firewall **activado** en los 3 perfiles (Dominio, Privado, Público). ✅
- No hay reglas outbound por defecto bloqueadas, pero la política por defecto es bloqueo de entrada (Windows default). ✅
- **106 reglas entry incluidas activas** — la mayoría del propio Windows (redes base, mDNS, "Pantalla inalámbrica", etc.), aceptable.

Reglas **no recomendadas** presentes (se debe remediar):

| Regla | Perfil | Riesgo |
|---|---|---|
| `node.exe` | **Público** (×2) + `Node.js JavaScript Resume` | 🟠 Alto: abre el runtime en la red no confiable |
| `Visual Studio Code` | Público (×2) | 🟡 accede desde Público |
| `opencode.exe` (×2) | Público | 🟡 y además escucha en `0.0.0.0:4096` |
| `MetaTrader 5 Strategy Tester Agent` | Domain, Private | 🟡 red de pruebas de estrategias accesible desde LAN |
| `Claude` (×2) | Any | 🟡 |
| Reglas "Detección de redes" (mDNS, SSDP, LLMNR, UPnP, WSD, Wi-Fi Direct) | Privado/Público | 🟡 Vectores clásicos LLMNR/mDNS/UPnP |

### 3.4 Red y puertos — ✅ en general, 2 notas

Puertos en escucha (TCP):

| Puerto | Servicio / Proceso | Comentario |
|---|---|---|
| 135 | RPC (svchost) | Estándar de Windows (local) |
| 139, 445 | NetBIOS/SMB (System) | Estándar; bloqueado a entrada por regla por defecto, pero existe en red → apgrantar |
| 3000 | metatester64 (MetaTrader 5) | Solo loopback (127.0.0.1) ✅ |
| 4096 | opencode | **Escucha en 0.0.0.0** (todas las interfaces) 🟠 |
| 22346 | terminal64 (MetaTrader 5) | Solo loopback ✅ |
| 5040 | svchost (Connected Devices Platform) | Sistema |
| 49664-49669 | lsass/wininit/svchost/services | RPC dinámicos del sistema |
| 49668 | jhi_service | Solo loopback IPv6 (::1); intelpendiente verificar origen del archivo |

- ✅ Solo los hubs `$` por defecto (C$, ADMIN$, IPC$): sin recursos compartidos de usuario expuestos.
- ✅ SMBv1 **deshabilitado** (servidor y cliente).
- ⚠️ `EncryptData` (SMB) = **False** y `RequireEncryption` cliente = **False** en el cliente: los archivos SMB viajan sin cifrado obligatorio en la LAN (mitigado por firewall, pero si compartes con otros equipos en la LAN, se debe encriptar).
- 🟢 DNS actual: ISP local. Recomendado: habilitar DNS-over-HTTPS (DoH).
- 🟡 4 redes Wi-Fi guardadas ("YHWH", "Diego Saenz", "Diego", "Diego S24+") — 2 parecen obsoletas; eliminar para reducir el auto-join a redes legacy.

### 3.5 Cuentas y credenciales — 🔴 CRÍTICO

| Chequeo | Estado |
|---|---|
| Cuenta `H2R` (usuario principal) | 🔴 **`PasswordRequired = False`** — la cuenta NO exige contraseña. |
| | 🔴 La política local tiene `longitud mínima de contraseña = 0` |
| | 🔴 Historia de contraseñas = "Ninguna" (la reutilización inmediata está permitida) |
| Cuenta `Administrador` (integrada) | ✅ Deshabilitada |
| Cuenta `Invitado` / Guest | ✅ Deshabilitada |
| Cuentas del sistema (DefaultAccount, WDAG...) | ✅ Deshabilitadas |
| Política de bloqueo | ✅ Umbral 10 / duración 10 min / ventana 10 min (bueno) |
| Caducidad máxima contraseña | 42 días (aceptable) |
| Grupo Administradores | ➜ Verificación fallida sin admin (ejecutar `Get-LocalGroupMember -Group Administrators`) — probablemente solo "H2R" |

**Consecuencia del hallazgo crítico:** con `PasswordRequired=False` cualquiera que tenga acceso físico al equipo puede iniciar sesión (o si existe contraseña vacía en local). Esto anula la protección del Escritorio/conjunto de contraseñas.

### 3.6 UAC y configuración de arranque

| Chequeo | Estado |
|---|---|
| UAC (EnableLUA) | ✅ 1 |
| UAC, prompt admin (ConsentPromptBehaviorAdmin) | ✅ 5 (prompt inteligente) |
| Escritorio seguro (PromptOnSecureDesktop) | ✅ 1 |
| Autorun | — |
| Autologon | ✅ Desactivado (no AutoAdminLogon) |
| Ejecución de PowerShell | Sin restricción local (Undefined) → recomendar `RemoteSigned` |
| LSU protection (RunAsPPL) | ✅ 2 — protección LSA activa, evita robo lateral de credenciales |
| Credential Guard | ➜ No configurado (única polémica con LTSC; se puede activar mediante política) |

### 3.7 Secure Boot y cifrado — 🔴 ALTO

| Chequeo | Estado | Riesgo |
|---|---|---|
| Secure Boot | ❌ **UEFISecureBootEnabled = 0** | 🔴 Alta |
| TPM | ➜ No consultable (requiere admin) | — |
| BitLocker / Device Encryption | ➜ No verificado (acceso denegado sin admin) | 🟠 Si no está activo: alta |

Con Secure Boot desactivado y sin evidencia de BitLocker, un atacante con acceso físico (o una pieza de malware con permiso de arrancar) puede: arrancar sistemas operativos no firmados, sustituir el boot loader y acceder a datos del disco sin contraseña. En un portátil esto es un vector **prioritario**.

### 3.8 Servicios y acceso remoto — ✅ Fortaleza

| Servicio | Estado |
|---|---|
| RDP (TermPlanet) | ✅ Deshabilitado (fDenyTSConnections=1, TermService manual/stolp) |
| WinRM (PowerShell remoting) | ✅ Apagado (Manual, Stopped) |
| RemoteRegistry | ✅ Deshabilitado |
| Spooler (Print Spooler) | ✅ Manual + Detenido (mitiga la famila PrintNightmare) |
| Windows Defender / WdNisSvc | ✅ Activos |
| SMBv1 | ✅ Deshabilitado |
| Cuenta Guest por SMB | ⚠️ `EnableInsecureGuestLogons=False` ✅ |

### 3.9 Logs y monitoreo — 🟡 Revisar

- Log de Seguridad: `maxSize = 20 MB` (default de Windows; en el 1GB recomendado para el análisis forense).
- No se pueden leer los eventos 4625 (inicio/final) sin admin: ➜ en PowerShell admin: `Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4625}`.
- `autoBackup: false`, `retention: false`, `fileMax: 1` → en ventana una rotación manual. Recomendado: /rt:true /ae:true /ms:1GB.
- 1 cierre/reboot forzoso detectado el 24/05/2026 (probable apagado por batería/colapso) — revisar si se repite.

### 3.10 Aplicaciones instaladas — 🟡 limpieza + verificación

| App | Versión | Observación |
|---|---|---|
| Google Chrome | 151.0.7922.76 | ✅ actualizado |
| WebView2 / Edge | 151.0.4129.72 | ✅ |
| VS Code | 1.132.0 | ✅ — eliminar regla de firewall Público |
| GitHub Desktop | 3.6.3 | ✅ |
| MetaTrader 5 | 5.00 x64 | 🟡 Herramienta financiera; procesos de prueba escuchan en loopback OK; reducir regla inbound; riesgo de phishings/montones con troyano "MT5*" |
| CPUID HWMonitor | 1.65 (15/07/2026) | ✅ reciente; tipo hogware, riesgo menor |
| CapCut | 9.1 | 🟡 App de Bytedance — revisión de privacidad (telemetría, permisos de acceso a archivos) |
| OpenCode | 1.18.15 | 🟡 Regla Público + puerto 4096 en 0.0.0.0 |
| **Last Z** | 1.250.673 | ⚠️ **App desconocida por analista** — verificar origen/editor desde Panel > Desinstalar, revisar signatura digital, desinstalar si no la usas |
| Google Gemini / Claude | — | Desktop wrappers; revisar cuenta y MFA de las cuentas |

Inicio (startup): limpio ✅ (solo Edge Update, SecurityHealth, Realtek Audio — todos legítimos).

---

## 4. Matriz de vulnerabilidades y riesgos

| ID | Severidad | Hallazgo / Vulnerabilidad | Impacto | Acción |
|---|---|---|---|---|
| V-01 | ✅ Corregido 08/08/2026 | Cuenta H2R sin requisito de contraseña (`PasswordRequired=False`) | Acceso físico total sin credencial | ✅ Contraseña establecida (min. 14+ mixta, política por defecto de 14 min). Pendiente: activar Windows Hello PIN |
| V-02 | 🔴 Crítica | Secure Boot desactivado (UEFI boot = 0) | arranque de bootloaders no firmados, robo de credenciales arrancando otros OS | Habilitar `Secure Boot` en BIOS (Flaque de Lenovo F1/F2) + restablecer Secure Boot con MOK/OEM keys si necesario |
| V-03 | ✅ Verificado 08/08 | Cifrado del disco (BitLocker) sin confirmar | Robo físico → datos sin cifrar | ✅ **BitLocker ACTIVO**: cifrado 100% (solo espacio usado), XTS-AES 128, protectores TPM + contraseña numérica. Acción pendiente: respaldar la clave de recuperación fuera del equipo |
| V-04 | 🟠 Alta | Reglas de entrada del firewall para Node/VS Code/opencode/Claude/MT en perfiles **Público** | Si te conectas a Wi-Fi pública, procesos abren puertos accibos desde la red | Eliminar reglas: `Remove-NetFirewallRule ...`; marcar la red física como "Pública" y salir de Público |
| V-05 | 🟠 Alta | Puertos 139/445/SMB activos de NetBIOS/SMB en PC sin necesidad de compartir; SMB sin cifrado de tráfico | En LAN con otros equipos comprometidos: riesgo de acceso/sniffing | Desactivar "File and Printer Sharing" o aplicar `RequireSecuritySignature` + `EnableEncryption` |
| V-06 | 🟠 Alta | Política de contraseña débil: longitud mínima 0, historial = ninguna | Fuerza/bruta y reuso | `net account /minpwlen:14 /uniquepw:10`; GDLMCA / ConfigPol de Seguridad Local: longitud 14+, historial 10 |
| V-07 | 🟡 Media | Aplicación desconocida "Last Z" | Superficie del atacante no auditada | Verificar origen y firmar digital; desinstalar si no se conoce |
| V-08 | 🟡 Media | `opencode` escucha en `0.0.0.0:4096` en perfil Público | Exposición a LAN/no confiables | Ejecutar el helper solo loopback (config `host:127.0.0.1`) y quitar regla Público |
| V-09 | 🟡 Media | VDA: LLMNR/mDNS/SSDP/UPnP discovery activos (reglas inbound "Any"/"Private") | envenenamiento LLMNR/NBNS en la red local | Block LLMNR por política (`EnableMulticast=0`), Redes con Privado básico |
| V-10 | 🟡 Media | DNS del ISP sin cifrar (190.x) | espionaje/quinecron de DNS al proveedor | Habilitar DNS-over-HTTPS en NIC (1.1.1.1 / 8.8.8.8 ／ SafeDNS) |
| V-11 | 🟡 Media | Log de seguridad 20 MB, sin auto-backup ni rotación | forensia limitada, desplazan eventos críticos | `wevtutil set-log Security /ms:1073741824 /rt:true /ae:true` |
| V-12 | 🟡 Media | Perfiles Wi-Fi obsoletos (Diego Saenz, Diego) guardados con auto-join | Reunión con redes legacy y con nombre personal | `netsh wlan delete profile name="..."` |
| V-13 | 🟡 Media | Política de ejecución de PowerShell sin restricción (Undefined *except* proceso) | scripts no firmados pueden votar, amplía rutas de ejecución | `Set-resolution: LocalMachine RemoteSigned` + GPO si aplica |
| V-14 | 🟡 Media | CredentialGuard no configurado (LSA PPL ya activo) | robo de credenciales hash en memoria | activar "Virtualization Based Security" si el CPU/VM lo soport (.NET, Hyper-V); en LTSC mediante política |
| V-15 | 🟢 Baja | CapCut (Bytedance) — dudas de privacidad | minería/telecomy data | Revisar en Ajustes los permisos del usuario | **Opcional**: usa app web/derecha Fuentes |
| V-16 | 🟢 Baja | HWMonitor no supervisado (v 1.65) | mantenimiento del controlador del sistema | Actualizar desde CPUID si existen actualizaciones |
| V-17 | 🟢 Baja | Sin Microsoft account —sleep/recovery con Hello no se vincula | recuperación de cuenta fácil de ataque local | Considerar cambiarse a cuenta Microsoft (con MFA) + binder Windows Hello |
| V-18 | 🟢 Baja | Eventos: 1 shutdown forzoso (24/05) | posible cuto de disco o batería | Monitor ren; revisar EnergyReport y sustituir de ser recurrente |

---

## 5. PLAN DE ACCIÓN — Fase 1 (URGENTE, hoy, admin)

Ejecutar PowerShell **como administrador** (Win+X → Terminal (admin)):

```powershell
# 1. IMPORTANTE: fijar contraseña robusta a la cuenta H2 y forzar su exigencia
net user H2R *                       # -> introducir contraseña nueva larga
# Si la cuenta no pidió contraseña antes, quitar el flag "no requiere contraseña":
Get-LocalUser H2R | Select PasswordRequired

# 2. Subir política de contraseñas
Set-LocalUser -Name H2R -PasswordNeverExpires $false
# Para longitud mínima usa la consola secpol.msc (Local Security Policy):
#   Cuentas/Configuración: "Longitud mínima de contraseña" = 14
#   "Historia de contraseñas recordadas" = 10
net accounts /minpwlen:14 /uniquepw:3 /lockoutthreshold:5 /lockoutduration:10 /lockoutwindow:10

# 3. Restringir PowerShell a RemoteSigned
Set-ExecutionPolicy -Scope LocalMachine RemoteSigned -Force

# 4. Eliminar reglas de firewall para aplicaciones de desarrollo del perfil PÚBLICO
Get-NetFirewallRule -Enabled True | Where-Object { $_.DisplayName -match 'node\.exe|Node\.js|Visual Studio Code|opencode|Claude|Chrome|MetaTrader|Last Z' } | Remove-NetFirewallRule -Confirm:$false
# (No te preocupes si no aparecen: se elimina la asociación, pero el app puede recrearla
#  al volver a tener permiso; controla esa entrada bajo Avanzadas)

# 5. Activar cifrado de disco (si no está):
Get-CimInstance -Namespace root\CIMv2\Security\MicrosoftVolumeEncryption -Class Win32_EncryptableVolume | select DriveLetter, ProtectionStatus
# o: manage-bde -status ; no cifrado: manage-bde -on C: -UsedSpaceOnly
#   (respaldar la clave en cinta o en tu gestor de contraseñas MUY lejos del equipo)

# 6. Log de seguridad grande
wevtutil set-log Security /ms:1073741824 /rt:true /ae:true

# 7. Quitar mDNS/LLMNR daño (reducir discos)
     (política)
reg add "HKLM\Software\Policies\Microsoft\Windows\DNSClient" /v EnableMulticast /t REG_DWORD /d 0 /f

# 8. Deshabilitar la compartición innecesaria de Sem (si no compartes en LAN)
Set-SmbServerConfiguration -EnableSMB1Protocol $false # (ya está)
# encriptor obligatorio de SMB:
Set-SmbServerConfiguration -EncryptData $true -Force
Set-SmbClientConfiguration -RequireEncryption $true -Force
# (notas: configúralo si tus dispositivos lo soportan)
```

**4.1 En la BIOS (Lenovo F1):**
1. Secure Boot **On** (Boot > Secure Boot).
2. Activa el TPM/fTPM (Si no está en **Security > Security Chip**).
3. Pon **contraseña de administrador de BIOS** (Security > Password) — imprescindible en portátil.
4. Configura el orden de arranque; previene arranque de USB (si no lo necesitas).

**4.2, y 4.3 (hoy):**
- Verifica que la app "Last Z" es legítima (Panel de control > Programas; o `sigcheck` de Microsoft) y desinstala.
- Elimina redes Wi-Fi obsoletas (`netsh wlan delete profile name="Diego Saenz"`, "Diego").
- Quita `opencode `de perfil Público si no lo necesitas, y límites el proceso a loopback (para el scanner que lo levante).

---

## 5. PLAN DE ACCIÓN — Fase 2 (corto plazo, 1–2 semanas)

1. **Cifrado total del disco**: activa BitLocker/Device Encryption, GUARDA la clave de recuperación en la nube de confianza (o caja de seguridad) Y en una caja física (impresa) separada del equipo. Verifica con `manage-bde -status`.
2. **Windows Hello + PIN o dominio**: `Settings > Accounts > Sign-in options` → añadir PIN (usa el TPM), y quitar la opción "Conseguir que Windows recuerde..." para que el arranque pida credencial.
3. **Credential Guard / Config** (solo si soportado): consola `gpedit` o política local: `Computer Config > Admin > System > Device Guard > Turn On Virtualization-Based Security` → "Enabled with UEFI lock" + modo HVCI.
4. **DNS cifrado**: `Settings > Wi‑Fi > propiedades de red > DNS` (manual) → 1.1.1.1 (DoH) o DoH de Google 8.8.8.8. Aplica a perfiles Wi‑Fi y celulario.
5. **Primera capa app**: revisa las cuentas con las que entra cada app (Google/Microsoft/MetaTrader/Gemini) y activa **2FA** en todas ellas (claves de respaldo guardadas en tu gestor de contraseñas).
6. **Gestor de contraseñas** (Bitwarden / KeePass / 1Password) y rellénalo: clave de Windows, BIOS, e‑mail, banco, brokers. Nunca reutilices.
7. **Aplicaciones no esenciales**: desinstala lo que no uses (CapCut si es dudaso, HWMonitor si no usas).
8. **Actualiza firmware**: Lenovo Vantage → Revisa BIOS/controladores (también atención: actualizar BIOS asegura compat con secure boot TPM; backup first).

---

## 5. PLAN DE ACCIÓN — Fase 3 (medio/largo plazo, 1–6 meses)

1. **Monitorza**: crea un `log semanal` de seguridad:
   - Fallos de login 4625 recientes (`Get-WinEvent ... -Filter`)
   - Estado de Defender en Seguridad de Windows
   - Aprobación de actualizaciones (Revisa "Historial de actualizaciones")
   - Task es: revisa en Han. Seguro "Bluetooth/WiFi apagado si no se usan"
2. **Privados de red**: considera un firewall de app (donas / Windows Defender ATP si LTSC lo trae) y red invitado para dispositivos externos.
3. **Backup 3-2-1**: 3 copias (local + externa + nube encriptada) · 2 dispositivos distintos · 1 fuera de casa. Probar restauración 1x/trimesta.
4. **Prueba plan de respuesta**: escribe quién llama si el equipo falla (disco, passolvido) y cómo restaurar la clave BitLocker y el gestor de pases.
5. **Aprop. entrega**: pellic en tu gestor el resto de cuentas (una por semana), grande los campaignes de phishing/gaming.
6. **Actualiza drivers con Lenovo** (Vantage): semestral y antes de vender.

---

## 7. Plan de mantenimiento recurrente (rutina mensual)

| Frecuencia | Acción |
|---|---|
| Semanal | Windows Update (Config > Windows Update) · escaneo con Defender vía SP `WindowsAtStart | complete` |
| Mensual | Revisar eventos 4625 y "aplicativos a inicio" (no esperados) · `Get-ChildItem HKLM:\...Run` · descargado de `Get-WinEvent -Filter Security 4625&ref` |
| Mensual | `net user * /expires:01/01/2027` no — usa `Get-LocalUser PasswordExpires`; rotar contraseñas de política clave |
| Trimestre | Bio: bitlocker status + `cert no-op`, verificar Zabackup de recuperación BitLocker; escaneo de arranque DEF |
| Semestral | Coincidencia de firmware con Vantage; revisión de la lista de aplicaciones (desinstalar no usadas) |
| Anual | Nuevo informe completo como este (mark en tu agenda con enlace a este documento) |

---

## 8. Comandos de verificación clave (repetir al inic l)

Ejecutarlo en PowerShell **admín**:

```powershell
Get-LocalUser
Get-LocalGroupMember -Group Administrators
Get-MpComputerStatus | Select RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,IsTamperProtected
Get-NetFirewallRule -Enabled True -Direction Inbound | Select -First 30 DisplayName,Profile
Get-NetTCPConnection -State Listen | select LocalAddress,LocalPort,OwningProcess
manage-bde -status
Get-WinEvent -FilterHashtable @{LogName='Security';ID=4625;StartTime=(Get-Date).AddDays(-7)} | Measure-Object
```

---

## 9. Glosario rápido

- **TPM**: chip de la placa que guarda las claves de BitLocker/Hello.
- **Secure Boot**: asegurara que solo arranque software firmado por proveedores confiables.
- **HVCI**: hipervisor de integridad de código (aísla drivers/controladores maliciosos).
- **PPL/LSA Protection**: evita el volcar credenciales lsass con herramientas tipo mimikatz.
- **LLMNR/mDNS**: protocolos de "resolución no" en la LAN, vector clásico de envenenamiento de respuestas.

---

---

## 12. Acta de endurecimiento ejecutado el 08/08/2026 ✅

Ejecutado con acceso elevado (administrador) mediante PowerShell, en 3 pasadas. Resultado verificado post-cambios.

| # | Medida | Estado |
|---|---|---|
| 1 | **Contraseña de H2R** establecida (mín. 14 caracteres mixtos, política complejidad) | ✅ aplicada (PasswordLastSet 08/08/2026 22:28) |
| 2 | **Política de contraseñas**: longitud mínima 14 · historial 3 · bloqueo 5 intentos / 10 min | ✅ aplicada y verificada |
| 3 | **Firewall**: eliminadas 13 reglas inbound de Node.js (×4), VS Code (×2), opencode (×2), OpenCode Server 4096, MetaTrader 5 (×1), Google Chrome mDNS, Claude (×2) | ✅ 0 reglas de desarrollo restantes |
| 4 | **Execution Policy**: `RemoteSigned` a LocalMachine | ✅ aplicada |
| 5 | **LLMNR/mDNS**: registro `EnableMulticast=0` | ✅ aplicado y verificado |
| 6 | **Log de seguridad**: 1 GB, retención y auto-backup activados | ✅ aplicado y verificado |
| 7 | **SMB**: cifrado obligatorio servidor y cliente, firma requerida, SMB1 apagado | ✅ aplicado y verificado |
| 8 | **Wi-Fi**: eliminados perfiles "Diego Saenz" y "Diego" | ✅ quedan solo "YHWH" y "Diego S24+" |
| 9 | **Defender exclusión eliminada** (`C:\Users\H2R\Downloads\Microsoft-Activation-Scripts`) | ✅ la carpeta permanece, ahora escaneable por Defender |
| 10 | **BitLocker** | ✅ Verificado ACTIVO (XTS-AES 128, protección On, TPM + contraseña numérica, 100%) |
| 11 | **TPM** | ✅ Presente, listo, habilitado y activado |
| 12 | **Grupo Administradores** | ✅ Solo: DESKTOP-4Q4GFM5\Administrador (deshabilitada) y DESKTOP-4Q4GFM5\H2R |

### Pendientes (requieren tu acción manual):

1. 🔴 **Secure Boot = OFF** (detectado). EN LA BIOS (reiniciar → F2/F1 en arranque Lenovo): Boot → Secure Boot → **Enabled**. Guardar y arrancar.
2. 🔴 **Contraseña de BIOS/UEFI** (Security > Password): poner contraseña de administrador de firmware — protege contra arranque desde USB/edición de EFI.
3. 🟠 **Actualizar firmware/BIOS** con Lenovo Vantage (revisar también que el TPM quede en versión 2.0).
4. 🟠 **Activar Windows Hello** (Configuración → Cuentas → Opciones de inicio de sesión → PIN/rostro) para no teclear la contraseña en cada arranque.
5. 🟠 **DNS cifrado (DoH)** en Configuración → Wi-Fi → propiedades → asignar DNS manual (p. ej. 1.1.1.1 / 8.8.8.8 con cifrado activo).
6. 🟠 **Copiar la clave de recuperación de BitLocker** (Panel: Proteger BitLocker → "Copiar clave de recuperación") a un lugar seguro (impresa/caja fuerte + gestor de contraseñas).
7. 🟡 **Verificar la app "Last Z"** — si no la reconoces, desinstalarla; revisar la firma digital de su instalador.
8. 🟡 **Revisar si se sigue necesitando el activador** `Microsoft-Activation-Scripts` — el equipo ya está activado; considera eliminar la carpeta.
9. 🟡 Configurar **2FA** en tus cuentas en línea y un **gestor de contraseñas** (Bitwarden, Keepass, 1Password).

### Recomendaciones resultantes del acceso admin (dataset nuevo)

- No hubo ataques recientes: **3 eventos 4625 en 7 días**, todos generados por `svchost.exe` (autenticación de servicio local, no fuerza bruta externa). ✅
- Las **exclusiones de Defender** adicionales eran únicamente el folder de activadores; tras quitarla quedó **0 exclusiones** ✅
- No se detectaron amenazas en el historial del antivirus. ✅

---

*Informe generado por análisis automático de auditoría local el 08/08/2026 20:26 y actualizado con el acta de endurecimiento a las 22:40 del mismo día. Los archivos de log temporales con credenciales fueron eliminados; los datos de auditoría crudos quedan en `%TEMP%\opencode\windows-audit\*.txt` (sin secretos). Guardar este archivo junto con la lista de credenciales de respaldo fuera del disco principal.*