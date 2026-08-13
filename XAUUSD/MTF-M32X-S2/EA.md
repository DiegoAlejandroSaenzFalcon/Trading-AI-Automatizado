# 03 · MTF MultiTimeframe r32_XAU — XAUUSDm (slot S2 destacado)

**Estatus: ⚠️ candidato — probar más en demo antes de real.**

## Datos

| Item | Valor |
|---|---|
| Símbolo / TF | XAUUSDm · H1 |
| Magic | **915001** (slots S1–S8 → 915001..915008) |
| Live demo | **M32X_S2: 3/3 (+955)** (TP, ventana ~22–23h) |
| Ficheros | `Pure_Fractal_MultiTimeframe_XAUUSD_r32_XAU.mq5` · `MTF_M32X_S2_XAUUSD_REAL.set` |

## Configuración

- `.set` con el **conjunto validado de 7 slots** (el slot 06 está OFF: Strategy=0). S2 = ventana 02–04h, estrategia 3, TP 2.0, TTL 48.
- Riesgo por equity: `InpUseRiskPctEquity=true`, `InpRiskPctEquity=1.2`, `InpMaxLotSize=2.0`, **circuito diario 4%**.
- **Verificación obligatoria:** el magic en el gráfico debe ser **915001**. En el historial live estos trades aparecieron con magic **910002** (heredado de r31) — por eso solo el comentario `M32X_S2` los identifica. Recompilar/verificar antes de operar.

## Recomendación

- Misma regla que r31: riesgo ≤0,5–1% por trade; los 3/3 live fueron TP con hold <1h.
- El slot S2 está configurado en la ventana 02–04h del set; si quieres replicar la franja live (~22–23h), revisa cuál slot cubre esa hora y ajusta.
