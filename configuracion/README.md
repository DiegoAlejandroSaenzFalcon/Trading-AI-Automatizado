# Configuración

Todo lo necesario para identificar y respaldar cada versión de EA tras reinicio o cambio de cuenta.

| Archivo | Propósito |
|---|---|
| `MAGIC_REGISTRY.txt` | Tabla maestra: versión ↔ magic ↔ comentario ↔ GlobalVariables. |
| `CONFIGURACIONES_ACTUALES.md` | Runbook de recuperación. |
| `sets/` | Copia de seguridad de todos los `.set` REAL. |

Regla inamovible: **un magic por versión**. Ver `MAGIC_REGISTRY.txt` antes de compilar.
