# Reporte de Cuenta MT5 — 198816526 (Exness-MT5Trial11)

**Fecha de análisis:** 16/08/2026 · **Divisa:** USD · **Apalancamiento:** 1:2000
**Alcance:** historial desde apertura de la cuenta (15/08/2026) → **3 posiciones cerradas**, 0 abiertas.

---

## 1. Resumen general

| Métrica | Valor |
|---|---|
| Balance actual | 10 979,60 |
| Equity actual | 10 979,60 |
| Posiciones cerradas | 3 |
| P&L total (suma de posiciones) | **+979,60** |
| Depósito inicial (trial) | +10 000,00 (`D-trial-USD`, 15/08/2026) |

> Nota: cuenta demo nueva (abierta 15/08/2026), operada exclusivamente por el EA **KF11 (magic 104)** en BTCUSDm con lote fijo 10,0. Sin posiciones abiertas al momento del análisis.

---

## 2. Resultado por EA (magic)

| Magic | EA (fuente) | Trades | Winrate | Profit Factor | Neto | Max DD | Símbolos |
|---|---|---|---|---|---|---|---|
| **104** | **KF11 · Pure_Fractal_FVG_Fusion_v11.0** | 3 | 100% | ∞ | **+979,60** | 0,00 | BTCUSDm |

**Lectura:** única estrategia activa en esta cuenta; muestra mínima (1 día), pero 3/3 aciertos cerrados todos en zona de ganancia.

---

## 3. Foco: KF11 (magic 104) — BTCUSDm

**Global 104:** 3 trades · WR 100% · PF ∞ · neto +979,60 (+9,8% del balance) · sin drawdown.

### 3.1 Secuencia completa

| Cierre (UTC) | Dirección | Vol | Apertura → Cierre | PnL | Hold |
|---|---|---|---|---|---|
| 15/08 19:37 | SELL | 10,00 | 63060,76 → 63022,48 | +382,80 | 1h 37m |
| 15/08 20:40 | SELL | 10,00 | 63013,54 → 62969,97 | +435,70 | 1h 03m |
| 16/08 05:25 | SELL | 10,00 | 62956,62 → 62940,51 | +161,10 | 8h 45m |

- Las 3 salidas registran comentario `[sl …]`, pero siempre en **zona de ganancia** (nivel de stop por debajo de la entrada en SELL, distancia ≈ 39-49 ptos, equivalente a ~2 × ATR).
- Entradas: 18:00, 19:37 y 20:40 UTC (15/08) — franja NY.
- PnL por día de cierre: 15/08 +818,50 · 16/08 +161,10.

### 3.2 Riesgos KF11 en BTC

- **Lote fijo 10,0 ≈ 630K USD nocional**: un movimiento adverso de 50 ptos son -500. En la cuenta anterior (198790722) un único SL de vol 10 en BTC fue **-4 883,60** y el backtest KF11 BTC 2026 fue **negativo (-33 021)**.
- **Muestra mínima**: 3 trades en 1 día no validan nada; la doc del repo (STRATEGIES_INDEX.md) marca **KF11 en BTC como descartado** (demo -3 009, RR 0,30). El 100% de hoy no cambia esa conclusión.
- **Sesgo unidireccional**: las 3 operaciones fueron SELL; vigilar si el sesgo de sesión/mercado se revierte.

---

## 4. Observaciones y recomendaciones

1. **KF11 en XAUUSD = bueno** (cuenta anterior: +3 052 en 9 trades); **KF11 en BTC = configuración de alto riesgo** por lote 10 y resultados previos negativos. Considerar mover KF11 a XAUUSDm o capar lote (≤1,0) y añadir filtro de sesión.
2. **Capear el lote**: la asimetría de sizing (vol 1 vs vol 10) es lo que domina el riesgo de la familia KF11; recomendación: lote en función del SL (riesgo $ fijo), nunca lote fijo 10.
3. **Seguimiento**: revisar tras ≥20 trades y un drawdown real antes de concluir nada sobre esta cuenta.
4. **Sesión**: entradas 18:00–20:40 UTC funcionando bien en esta muestra; mantener observación sobre madrugada UTC (donde en XAU estuvieron las pérdidas).

---

*Datos extraídos vía MetaTrader5 API (terminal en vivo). Historial: 15–16/08/2026 — desde la apertura de la cuenta demo.*