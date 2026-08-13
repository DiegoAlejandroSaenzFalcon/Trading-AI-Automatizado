# XAUUSD_NeurAlgo_M1_V3

- **Activo:** XAUUSD
- **Estrategia:** Scalping
- **Magic:** 
- **Estado:** POR_REVISAR (score 0/3)
- **Archivo:** XAUUSD NeurAlgo M1 V3.mq5

## Descripcion
APEXQUANT - V9.0-CAPITALGUARD                                  |; "DIRECTIONAL RECOVERY — ANTI-SYMMETRIC ENGINE"                 |; CRASH ROOT CAUSE ANALYSIS (from M15 backtest on $100):        |; [RCA-1] CalcRecoveryLot() ignoraba timeframe. En M15,         |; ATR es 3.9x mayor que M1 → lote calculado = 0.91      |; sobre cuenta de $100 → margin call inmediato.         |; [RCA-2] Sin techo absoluto de volumen acumulado en mercado.   |; Recovery stack llegó a 1.45 lots = $455 margen.       |

## Resultados

| Metricas | Valor |
|---|---|
| R xTrade |  |
| Max DD % |  |
| Winrate |  |

## Config
Ver `src/XAUUSD NeurAlgo M1 V3.mq5` y el `.set` del EA.

*Configuracion inicial auto-generada el 2026-08-12 (editar con datos reales de validacion).*
