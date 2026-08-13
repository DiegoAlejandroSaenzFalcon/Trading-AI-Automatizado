# 04 · FVG Fusion v12.0 — BTCUSDm

**Estatus: ⚠️ candidato (backtest sólido de sesión, muestra live mínima).**

## Datos

| Item | Valor |
|---|---|
| Símbolo / TF | BTCUSDm · H1 |
| Magic | **12** (comentario "KF12") |
| Live demo | +11 (1/1, SL) |
| Backtest | sesión **16–19h** + TP 2.0 + trail 0.35 → **PF 2,2** (barrido MT5) |
| Ficheros | `Pure_Fractal_FVG_Fusion_BTCUSD_v12.0.mq5` · `FVG_v12_BTCUSD_REAL.set` |

## Configuración

- Riesgo: `InpLotMode=0`, `InpRiskPerTradeUSD=30` (ajustar a 0,5–1% equity), `InpMaxLotSize=0.40`, tope diario $120.
- Filtro de sesión **activo: 16–19h (hora broker)** — ventana ganadora del estudio.
- `InpMacroTimeframe=16386` (H2) para el sesgo macro.

## Notas

- Este es el mismo "KF11" renovado pero con enfoque de sesión NY en BTC y magic 12. No confundir con la v11 (magic 104).
- Es más conservador que v11 (TP 2.0 vs 4.0): menor varianza por trade.
