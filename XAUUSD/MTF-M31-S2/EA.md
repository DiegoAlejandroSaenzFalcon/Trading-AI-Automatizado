# 02 · MTF MultiTimeframe r31 — XAUUSDm (slot S2 destacado)

**Estatus: ⚠️ candidato — probar más en demo antes de real.**

## Datos

| Item | Valor |
|---|---|
| Símbolo / TF | XAUUSDm · H1 |
| Magic | **910001** (slots S1–S8 → 910001..910008) |
| Live demo | **M31_S2: 1/1 (+364)**; set completo S1 +638 |
| Backtest | r31 validado **PF 1,22** en 3 periodos (2024H2–2026A), ~277 trades/mes |
| Ficheros | `Pure_Fractal_MultiTimeframe_XAUUSD_r31.mq5` · `MTF_M31_S2_XAUUSD_REAL.set` |

## Configuración

- El `.set` usa el **set completo validado de 8 slots** (cada slot = ventana horaria + estrategia). S2 = ventana 02–04h (según el set) con estrategia 3, TP 2.0, TTL 48.
- Riesgo: `InpRiskPerTradeUSD=20`, `InpMaxLotSize=2.0`, circuito diario OFF.
- **Verificación obligatoria:** en el gráfico el magic debe decir **910001** (si ves 910001 en un r32 o M32 en r31, NO operar — compilación con magic heredado).

## Recomendación

- Es un scalper de alto ritmo (277 trades/mes): el riesgo por trade debe ser **≤0,5%** de equity para no abrasar por comisiones/spread.
- Los 3 trades ganadores de M32X_S2 fueron a las ~22–23h (ventana de cierre de sesión); si quieres replicar el comportamiento de solo esa franja, ajusta el slot correspondiente en lugar de correr el set completo.
