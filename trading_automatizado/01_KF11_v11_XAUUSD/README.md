# 01 · KF11 / Pure_Fractal_FVG_Fusion_v11.0 — XAUUSDm

**Estatus: ⭐ RECOMENDADO para real** (único con forward live positivo consistente).

## Datos

| Item | Valor |
|---|---|
| Símbolo / TF | XAUUSDm · H1 |
| Magic | **104** (comentario "KF11 Buy/Sell") |
| Live demo (10–13 Ago) | **+3 052** · 9 trades · WR 66,7% · PF **4,76** · DD máx 494 |
| Lado fuerte | **SELL**: 7/7 con +3 830 (avg +547), franja 20–23h local |
| Ficheros | `Pure_Fractal_FVG_Fusion_v11.0.mq5` · `KF11_v11_XAUUSD_REAL.set` |

## Cambios respecto al set de demo (críticos)

| Parámetro | Demo (peligroso) | REAL (este set) |
|---|---|---|
| InpLotMode | 1 (lote fijo) | **0 (riesgo USD)** |
| InpFixedLotSize | 1.0 | 0.01 |
| InpMaxLotSize | **10.0** | **1.0** |
| InpRiskPerTradeUSD | 5.0 | **10.0** (ajustar: 0,5–1% equity) |
| InpMaxDailyLossUSD | 30.0 | 50.0 |
| InpSessionFilterEnable | false | false (ver nota) |

## Ajuste que debes hacer tú

- `InpRiskPerTradeUSD`: 0,5–1% de tu equity real (p.ej. equity $2 000 → 10–20 USD).
- Franja horaria: las ganadoras live fueron ~20:00–23:00 hora local. Si quieres filtrar, activa `InpSessionFilterEnable=true` con tus horas **de servidor** (Exness Trial suele ser UTC+3).

## Riesgos

- Sistema **WR alto / RR bajo**: gana seguido y pierde poco... hasta que aparece el SL gordo. El sizing por riesgo es obligatorio.
- No montar junto a otras versiones en el mismo símbolo sin magic distinto.
