# Índice de Estrategias — NOMBRES CLAROS (abre ESTOS archivos)

Este archivo existe para que **no abras nunca un EA equivocado**. Cada estrategia tiene su carpeta y magic único. Abre los `.set` y `.mq5` listados aquí **exactamente**; ignora los demás.

---

## ✅ ESTOS son los que debes abrir

| Estrategia | Magic | Símbolo/TF | Estado | Archivo `.mq5` a abrir (MetaEditor) | Archivo `.set` a cargar |
|---|---|---|---|---|---|
| **KF11-v11** | **104** | XAUUSDm H1 | ⭐ REAL | `XAUUSD/KF11-v11/src/Pure_Fractal_FVG_Fusion_v11.0.mq5` | `XAUUSD/KF11-v11/KF11_v11_XAUUSD_REAL.set` |
| **MTF-M32X-S2** | **915002** | XAUUSDm H1 | demo (3/3) | `XAUUSD/MTF-M32X-S2/src/Pure_Fractal_MultiTimeframe_XAUUSD_r32_XAU.mq5` | `XAUUSD/MTF-M32X-S2/MTF_M32X_S2_XAUUSD_REAL.set` |
| **MTF-M31-S2** | **910002** | XAUUSDm H1 | demo (1/1) | `XAUUSD/MTF-M31-S2/src/Pure_Fractal_MultiTimeframe_XAUUSD_r31.mq5` | `XAUUSD/MTF-M31-S2/MTF_M31_S2_XAUUSD_REAL.set` |
| **FVG-v12** | **12** | BTCUSDm H1 | sí (con risk) | `BTCUSD/KF11-v12/src/Pure_Fractal_FVG_Fusion_BTCUSD_v12.0.mq5` | `BTCUSD/KF11-v12/FVG_v12_BTCUSD_REAL.set` |
| **FVG-r30** | **30** | BTCUSDm H1 | sí (con risk) | `BTCUSD/FVG-r30/src/Pure_Fractal_FVG_Fusion_BTCUSD_r30.mq5` | `BTCUSD/FVG-r30/FVG_r30_BTCUSD_REAL.set` |

---

## ❌ NO abras — descartado
| Estrategia | Magic | Motivo | 
|---|---|---|
| **KF11-v11 en BTC** | 104 | El `Pure_Fractal_FVG_Fusion_v11.0` es SOLO para XAU. En BTC perdió -3 009 en 2026. |

---

## ⚠️ Descuida — NO usar para operar
Los siguientes sets existen como copia de respaldo dentro de `configuracion/sets/`, **no los abras para operar** (pueden confundirte):
- `configuracion/sets/KF11_v11_XAUUSD_REAL.set`
- `configuracion/sets/MTF_M31_XAU.set`, `MTF_M31_BTC.set`
- `configuracion/sets/MTF_M32X_XAU.set`, `MTF_M32X_BTC.set`
- `configuracion/sets/FVG_XAUUSD_r30.set`

---

## Regla infalible al cargar un EA
1. Abre el `.mq5` de tu carpeta elegida.
2. En MT5, al arrregarar el EA, **carga SIEMPRE el `.set` de la MISMA carpeta** (no el de `configuracion/sets/`).
3. Verifica en el gráfico que el **magic** mostrado coincida con el de esta tabla (`104`, `910002`, `915002`, `12`, `30`).
