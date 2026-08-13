# 05 · FVG Fusion r30 — BTCUSDm (ventana 10–15h)

**Estatus: ⚠️ candidato (backtest de ventana robusto, muestra live mínima).**

## Datos

| Item | Valor |
|---|---|
| Símbolo / TF | BTCUSDm · H1 |
| Magic | **30** (comentario "R30B") |
| Live demo | +30 (1/1, SL) |
| Backtest | ventana **10–15h**: +1 285 (Feb–May 2026) y +869 (May–Ago 2026) — gana en ambos subperiodos |
| Ficheros | `Pure_Fractal_FVG_Fusion_BTCUSD_r30.mq5` · `FVG_r30_BTCUSD_REAL.set` |

## Configuración

- Riesgo: `InpLotMode=0`, `InpRiskPerTradeUSD=15` (0,5–1% equity), `InpMaxLotSize=0.30`, tope diario $60.
- Filtro de sesión **activo: 10–15h (hora broker)** — ventana ganadora del estudio.

## Notas

- Variante de la familia Kalman+FVG con SL/TP más ajustados (SL 0.8 / TP 2.0) y sesión restringida a mañana de Nueva York.
- Se añadió `InpMagicBase=30` explícito en el set para evitar heredar otro magic.
