# Metodología de desarrollo y validación

Este repositorio no prueba EAs "a ojo". Cada estrategia pasa por un pipe de validación reproducible:

1. **Idea → Ingreso** (señal de Kalman + FVG / slots multitiempo + estrategia por hora).
2. **Backtest histórico (in-sample + out-of-sample).** Walk-forward en bloques: se calibran parámetros en un período y se validan en el siguiente. Ejemplo del KF11 en BTC: 2 868 operaciones 2025→2026, con subperiodos 2025 (+355k) y 2026 (-33k) → el 2026 señaló debilidad antes de operar.
3. **Forward testing en demo.** Los trades del ledger (10–13 Ago) son forward demo real; se cruzan con el backtest para confirmar que la señal sigue igual en vivo.
4. **Checks de robustez.** PF ≥1 en OOS, RR real ≥0.3, max DD aceptable, y **win rate no es suficiente** (un 80% WR con RR 0.1 se rompe en un par de stops).
5. **Control de contaminación.** Cada versión usa un MAGIC único y GV con prefijo de versión y símbolo → `MAGIC_REGISTRY.txt`. Cambiar el magic deja posiciones huérfanas.

**Conclusión profesional:** un EA pasa a real sólo si (a) OOS y forward coinciden en signo, y (b) el sizing es por riesgo, no por lote fijo.
