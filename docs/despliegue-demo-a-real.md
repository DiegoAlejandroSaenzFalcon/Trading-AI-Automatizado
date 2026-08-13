# Despliegue: demo → real (checklist)

Pasos antes de fondear tu primer EA:

1. **Confirma el sizing** (`docs/gestion-de-riesgo.md`): pasa `InpLotMode` a 0 y fija `InpRiskPerTradeUSD` al 0,5–1% de tu equity.
2. **Demo fresh con el mismo set REAL** 72h: verifica slippage/spread real del broker (especialmente BTC). No hagas backtest y pases directo.
3. **Verifica el magic** en el gráfico → debe coincidir con `configuracion/MAGIC_REGISTRY.txt` y con `reportes/ranking_EA_para_real.md`.
4. **Activa Circuit Breaker** (`InpMaxDailyLossUSD`) y `InpVolTimeStopEnable=true`.
5. **Revisa la sesión**: abre/cierra dentro de la franja horaria validada (no operar 24/7).
6. **Equity <3x drawdown permitido** → pausa. Usa un 0.5% (mitad) mientras validas en real.
7. **Log de operaciones**: deja correr min 1 semana y revisa que el lado ganador (ej. SELL en XAU) siga activo.

Checklist de seguridad:
- [ ] No lote fijo >1.
- [ ] 1 trade abierto por estrategia/símbolo.
- [ ] Circuit Breaker ON.
- [ ] Sesión filtrada.
- [ ] Risk ≤1%/operación.
