# Gestión de riesgo

## Principio base: nunca arriesgues más de 1–2% del equity por operación

| Parámetro | Valor profesional |
|---|---|
| Riesgo por operación | 0.5–1.0% del equity |
| Riesgo diario máximo | 4x el riesgo por operación (Circuit Breaker) |
| Max lot size | cap que limite la perdida a <2% aunque el SL se dispare |
| Posición abierta | 1 sola por estrategia/simbolo (no acumular) |

## Cómo calcularlo en estos EAs

- `InpLotMode=0` → el EA ajusta el lote al `InpRiskPerTradeUSD` o `InpRiskPctEquity`.
- Ejemplo: equity $2 000 → riesgo 1% = $20 → `InpRiskPerTradeUSD=20`.
- Ejemplo: XAUUSD 1 lote pierde ~$15-20 por SL ~15-20$ → con 1% ($20) cabe 1 lote; si tu SL es 40$, el lote debe ser ~0.5.

## La regla de oro (usar siempre)

```
risk_por_trade_USD = equity_actual * 0.01   (1%)
lote = risk_por_trade_USD / (distancia_SL_puntos * valor_por_punto)
```

## Circuit Breaker diario

`InpMaxDailyLossEnable=true` y fija `InpMaxDailyLossUSD = 4 × InpRiskPerTradeUSD`. Si el día pierde 4 operaciones seguidas, el EA se pausa.

## Por qué el demo usaba lote 10 (y tú no

el demo del KF11 v11 usaba `InpLotMode=1`, `InpMaxLotSize=10` → un SL de lote 10 costó -4 883 (más del 30% del balance demo). Es la tracción del ML, no un bug. En real, **el lote fijo grande es lo que rompe cuentas**; el `.set` REAL ya usa riesgo por USD. Ajusta `InpRiskPerTradeUSD` a 0,5–1% de tu equity y deja `InpMaxLotSize` como techo de seguridad.
