# CONFIGURACIÓN ACTUAL — Inventario y Runbook de Recuperación

**Última actualización:** 13/08/2026
**Propósito:** reconstruir todo el entorno tras reinicio del sistema o cambio de cuenta, identificando cada versión por su MAGIC, comentario y .set.

---

## 1. Cuenta y entorno

| Item | Valor |
|---|---|
| Login | 198790722 |
| Broker / server | Exness · **Exness-MT5Trial11** (demo trial) |
| Divisa / apalancamiento | USD · 1:2000 |
| Terminal | `C:\Program Files\MetaTrader 5\terminal64.exe` |
| Carpeta de datos terminal | `C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075` |
| Datos del tester (backtest) | `...\Terminal\D0E8...\Tester\` (config.ini, config_last.ini) |
| Repo del proyecto | `C:\Users\H2R\Documents\Default Project` |
| Símbolos Exness usados | **XAUUSDm** (oro) y **BTCUSDm** (bitcoin) |

---

## 2. Mapa de despliegue OBSERVADO en vivo (10–13 Ago 2026)

El ledger solo guarda magic + comentario → el **comentario es la firma fiable de versión** (el magic se contaminó entre versiones MTF).

| Magic (vivo) | Comentario | Versión real (repo) | Símbolo | Resultado demo |
|---|---|---|---|---|
| **104** | KF11 Buy / KF11 Sell | Pure_Fractal_FVG_Fusion_v11.0 | XAUUSDm | +3 052 (SELL: +3 830) ⭐ |
| **104** | KF11 Buy / KF11 Sell | idem v11.0 | BTCUSDm | -3 009 (no llevar a real hoy) |
| 910001 | M31_S1 | MTF r31 (XAU) | XAUUSDm | +638 |
| 910002 | **M31_S2 + M32X_S2** ⚠ | r31 (XAU) + r32_XAU mezclados | XAUUSDm | +364 / +955 |
| 910003 | M32X_S3 | r32_XAU (con magic de r31 ⚠) | XAUUSDm | -1 085 |
| 910004 | M32B_S4 | r32_BTC (con magic de r31 ⚠) | BTCUSDm | -195 |
| 910005 | M31_S5 | r31 (XAU) | BTCUSDm | -394 |
| 12 | KF12 | Pure_Fractal_FVG_Fusion_BTCUSD_v12.0 | BTCUSDm | +11 |
| 30 | R30B | Pure_Fractal_FVG_Fusion_BTCUSD_r30 | BTCUSDm | +30 |
| 1111 | BSE_*/REC_*/NET_* | NeurAlgo M1 (XAU) | XAUUSDm | +39 (breakeven) |
| 0 | (manual) | — tú operando a mano | XAU/BTC | descartado |

> ⚠ **Regla para el futuro:** antes de volver a montar cualquier MTF r32, recompilar con su magic correcto (r32_XAU=915001, r32_BTC=914001). Ver §3 y `MAGIC_REGISTRY.txt`.

---

## 3. Identidad de versiones (magic / comentario / GV) — fuente: MAGIC_REGISTRY.txt

| Versión | Magic | Comentario | GlobalVariables | .set asignable |
|---|---|---|---|---|
| FVG v11.0 | **104** | KF11 Buy/Sell | PFVG11_`<SYM>`_`<MAGIC>`_* | `MAGIC_Pure_Fractal_FVG_Fusion_v11.0.set` |
| FVG v12.0 (BTC) | **12** | KF12 | PFVG12_... | `MAGIC_Pure_Fractal_FVG_Fusion_BTCUSD_v12.0.set` |
| FVG r30 BTC | **30** | R30B | PFVG30B_... | `config_backup_20260810\...r30*.set` |
| FVG r30 XAU | **31** (corregido de 30) | R30X | PFVG30X_... | `MAGIC_Pure_Fractal_FVG_Fusion_XAUUSD_r30.set` |
| MTF r31 XAU | 910001 | M31X_S1..8 | M31X_`<SYM>`_* | `MAGIC_..._r31_XAU.set` |
| MTF r31 BTC | 910101 | M31B_S1..8 | M31B_... | `MAGIC_..._r31_BTC.set` |
| MTF r31 BTC v2 | 910201 | M31C_S1..8 | M31C_... | (solo fuente) |
| MTF r32 BTC | **914001** | M32B_S1..8 | M32B_... | `MAGIC_..._r32_BTC.set` |
| MTF r32 XAU | **915001** | M32X_S1..8 | M32X_... | `MAGIC_..._r32_XAU.set` |
| NeurAlgo M1 | 1111 | BSE_*/REC_* | — | `BTCUSD NeurAlgo M1 V2.set` / `XAUUSD NeurAlgo M1*.set` |

**Localización de fuentes:** `apexquant-ea-library\estrategias\{FVG,MultiTimeframe,Scalping}\<EA>\src\*.mq5`
**Binarios compilados (terminal):** `...\Terminal\D0E8...\MQL5\Experts\*.ex5`

---

## 4. Backtest (comandos / configs guardados)

| Test | Config ini | .set | Rango | Reporte |
|---|---|---|---|---|
| KF11 BTC (lote 10) | `backtests\v11_btc_lote10\tester_v11_btc_lote10.ini` | `...v11.0_BTC_lote10.set` | 2025-01-01 → 2026-08-11 | `backtests\v11_btc_lote10\trades_v11_btc_lote10.csv` |

Resultado de referencia (KF11 BTC): 2 868 trades · WR 77,6% · PF 1,05 · neto +322 876 (+323%) · **2026 negativo -33 021** · RR 0,30 · maxDD 51 459.

---

## 5. Runbook — después de reinicio / cambio de cuenta

1. **Abrir terminal:** `C:\Program Files\MetaTrader 5\terminal64.exe` y loguear (Exness, login 198790722 demo).
2. **Verificar símbolos:** Market Watch → agregar `XAUUSDm` y `BTCUSDm` (Exness usa sufijo `m`).
3. **Compilar EAs si hiciera falta** (solo si el `.ex5` no está): MetaEditor → abrir fuente → F7 (o `Ctrl+F7`).
4. **Cargar KF11 (lo que vamos a real):** arrastrar `Pure_Fractal_FVG_Fusion_v11.0` a un gráfico **XAUUSDm H1** → cargar el `.set` `MAGIC_Pure_Fractal_FVG_Fusion_v11.0.set` → verificar magic=104 y riesgo fijo (0,5–1% equity por trade).
5. **MTF (solo demo):** por cada slot usar su `.set` MAGIC_*.set; **verificar en el gráfico que el magic mostrado coincide con el de la tabla §3** antes de dar OK (si dice 910001 en un r32, NO operar — está mal compilado).
6. **Reconstruir historial:** si cambiaste de cuenta, descargar ticks/historia de XAUUSDm H1 en el Strategy Tester antes de backtests.

---

## 6. Estado de respaldo (git)

- ✅ Commit base: `18c62e0 Backup inicial` (parcial).
- ⚠️ **Sin commitear (untracked):** `apexquant-ea-library/`, `backtests/`, `opencode-tools/`, `MAGIC_REGISTRY.txt`, `MAGIC_*.set`, `ranking_EA_para_real.md`, `reporte_cuenta_198790722.md`, `config_backup_20260810/`, etc.
- ➡️ **Acción pendiente:** `git add -A` + commit para que el inventario y configs queden asegurados en el repo.
