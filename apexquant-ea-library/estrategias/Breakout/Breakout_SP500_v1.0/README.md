# Breakout_SP500_v1.0

- **Activo:** SP500
- **Estrategia:** Breakout
- **Magic:** 20260712
- **Estado:** POR_REVISAR (score 0/3)
- **Archivo:** Breakout_SP500_v1.0.mq5

## Descripcion
Breakout_SP500_v1.0.mq5   |; EA DE RUPTURA (BREAKOUT) PARA S&P 500 - TEMPORALIDAD D1         |; Broker objetivo: Exness (validar contract size / tick value)   |; LOGICA: identica a la validada en Python (backtest 70/30) y en |; el PineScript v6 entregado previamente:                        |; - Canal Donchian de N velas (excluyendo la vela en curso)    |; - Filtro de tendencia: SMA larga desfasada 1 vela             |; - Stop = ATR(simple, no Wilder) x multiplicador               |

## Resultados

| Metricas | Valor |
|---|---|
| R xTrade |  |
| Max DD % |  |
| Winrate |  |

## Config
Ver `src/Breakout_SP500_v1.0.mq5` y el `.set` del EA.

*Configuracion inicial auto-generada el 2026-08-12 (editar con datos reales de validacion).*
