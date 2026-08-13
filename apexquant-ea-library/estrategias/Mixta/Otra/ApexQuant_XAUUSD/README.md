# ApexQuant_XAUUSD

- **Activo:** XAUUSD
- **Estrategia:** Mixta/Otra
- **Magic:** 
- **Estado:** POR_REVISAR (score 0/3)
- **Archivo:** ApexQuant XAUUSD.mq5

## Descripcion
DIEGO SAENZ 24H - V7.3  (FIX DEADLOCK + RECOVERY TOTAL)   |; BUGS CORREGIDOS EN V7.3:                                       |; BUG #1 — DEADLOCK PRINCIPAL (por qué se queda sola):          |; Emergency mode activaba m_isPaused=true y OpenOrder bloqueaba  |; recovery. Posición sola → nunca se recuperaba → pérdida ∞      |; FIX: OpenOrder acepta forceEntry=true para recovery aunque     |; esté en pausa/emergencia. Recovery siempre puede abrir.        |; BUG #2 — EMERGENCY MODE NO LLAMABA RECOVERY:                  |

## Resultados

| Metricas | Valor |
|---|---|
| R xTrade |  |
| Max DD % |  |
| Winrate |  |

## Config
Ver `src/ApexQuant XAUUSD.mq5` y el `.set` del EA.

*Configuracion inicial auto-generada el 2026-08-12 (editar con datos reales de validacion).*
