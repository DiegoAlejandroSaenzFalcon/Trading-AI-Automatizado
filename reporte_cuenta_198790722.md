# Reporte de Cuenta MT5 — 198790722 (Exness-MT5Trial11)

**Fecha de análisis:** 13/08/2026 · **Divisa:** USD · **Apalancamiento:** 1:2000
**Alcance:** todo el historial reportado por el servidor (745 deals → **371 posiciones cerradas**, 0 abiertas).

---

## 1. Resumen general

| Métrica | Valor |
|---|---|
| Balance actual | 14 460,25 |
| Equity actual | 14 460,25 |
| Posiciones cerradas | 371 |
| P&L total (suma de posiciones) | **-10 987,42** |
| Balance inicial implícito | ≈ 25 447,67 (no hay deals de depósito/retiro en el historial) |

> Nota: el historial disponible cubre **10–13 Ago 2026**. La cuenta llegó a sufrir un stop-out importante que explica la mayor parte de la pérdida acumulada (ver §4).

---

## 2. Resultado por EA (magic)

| Magic | EA (fuente) | Trades | Winrate | Profit Factor | Neto | Max DD | Símbolos |
|---|---|---|---|---|---|---|---|
| **104** | **KF11 · Pure_Fractal_FVG_Fusion_v11.0** | 19 | 68,4% | 1,01 | **+43,33** | 4 883,60 | XAUUSDm + BTCUSDm |
| 1111 | NeurAlgo scalper (BSE_*) | 136 | 30,1% | 1,08 | +39,22 | 175,72 | XAUUSDm |
| 910001 | MTF r31 · M31_S1 | 8 | 37,5% | 1,85 | +638,43 | 574,45 | XAUUSDm |
| 910002 | MTF · M31_S2 + **M32X_S2** ⚠ | 4 | 100% | ∞ | +1 318,36 | 0,00 | XAUUSDm |
| 910003 | MTF · **M32X_S3** | 7 | 0% | 0,00 | -1 084,76 | 1 084,76 | XAUUSDm |
| 910004 | MTF · **M32B_S4** | 4 | 25% | 0,65 | -194,92 | 562,80 | BTCUSDm |
| 910005 | MTF · M31_S5 | 2 | 0% | 0,00 | -394,12 | 394,12 | BTCUSDm |
| 30 | Pure_Fractal_FVG_Fusion_BTCUSD_r30 | 1 | 100% | ∞ | +29,78 | — | BTCUSDm |
| 12 | Pure_Fractal_FVG_Fusion_BTCUSD_v12.0 | 1 | 100% | ∞ | +11,17 | — | BTCUSDm |
| **0** | Manual / EAs sin magic (martingala-hedge) | 189 | 68,3% | 0,80 | **-11 393,91** | **40 189,74** | XAUUSDm |

**Lectura:** el único grupo que hunde la cuenta es el de magic 0 (+28 795 obtenido en 160 cierres normales, pero **-40 189 en 29 stop-outs**). Los EAs con magic asignado suman +402 (ligeramente positivo).

---

## 3. Foco: KF11 (magic 104) — el que estás viendo en XAUUSD

**Global 104:** 19 trades · WR 68,4% · PF 1,01 · neto +43,33 · hold medio 1,7 h.

### 3.1 Por símbolo

| Símbolo | Trades | Winrate | Neto | Nota |
|---|---|---|---|---|
| **XAUUSDm** | 9 | **66,7%** | **+3 052,10** | Las operaciones buenas que ves |
| BTCUSDm | 10 | 70% (7/10) | **-3 008,77** | Un solo SL de vol 10: **-4 883,60** |

**En XAUUSD, KF11 es claramente rentable** (promedio +339/trade). **En BTC** queda en negativo solo por ese único SL grande (vol 10, hold 13,3 h).

### 3.2 Secuencia completa (XAUUSDm)

| Cierre (UTC) | Dirección | Vol | Apertura → Cierre | PnL |
|---|---|---|---|---|
| 11/08 19:04 | BUY | 1,00 | 4371,62 → 4368,12 | -349,30 |
| 11/08 20:00 | SELL | 1,00 | 4381,01 → 4381,36 | -34,90 |
| 11/08 22:05 | SELL | 1,00 | 4411,36 → 4408,67 | +269,20 |
| 11/08 23:01 | SELL | 1,00 | 4402,42 → 4402,33 | +8,90 |
| 12/08 00:03 | SELL | 1,00 | 4400,76 → 4400,35 | +40,20 |
| 12/08 01:17 | BUY | 1,00 | 4392,76 → 4388,48 | -428,30 (stop-out) |
| 12/08 20:52 | SELL | 1,00 | 4414,72 → 4411,05 | +367,80 |
| 12/08 23:14 | SELL | 1,00 | 4411,06 → 4395,45 | +1 561,20 |
| 13/08 01:06 | SELL | 1,00 | 4395,49 → 4379,32 | +1 617,30 |

### 3.3 Comportamiento temporal (XAUUSD)

- Mejor franja: entradas **20:00–23:00 UTC** → +1 499 / +1 626 (sesión europea tarde / NY).
- Peores: la **madrugada UTC (00:00–03:00)**, donde están las 2 pérdidas (-428 stop-out y la otra).
- PnL por día de cierre: 11/08 +3,00 · 12/08 +3 306,63 · 13/08 -3 266,30 (mitigado por el SL de BTC).

### 3.4 Riesgos KF11

- **Asimetría de lote:** opera vol 1 y vol 10 en la misma lógica (config de lote). El SL de vol 10 en BTC (-4 883,60) anula semanas de resultados. Conviene unificar/capear el riesgo por operación (p.ej. lote en función de SL, nunca fijo 10).
- **Winrate alto + PF 1,01** → la rentabilidad depende de pocos ganadores grandes; un río de pérdidas de cola rompe la curva.

---

## 4. El evento que domina la cuenta (magic 0)

- 189 operaciones, 68,3% winrate, pero **29 stop-outs = -40 189,74**.
- Comentarios tipo `[so -447.67 ...]`: sistema de **recuperación con lotes crecientes** (estilo martingala/hedge) sin magic asignado.
- **Este sistema, no KF11, explica el -10 987 de la cuenta.** Recomendación: desactivarlo o limitar la multiplicación de lote.

---

## 5. Observaciones y recomendaciones

1. **KF11 en XAUUSD = bueno** (+3 052 en 9 trades, 3 días). Mantener, preferentemente con horario filtrado 18:00–24:00 UTC.
2. **KF11 en BTC = riesgo dominante** (un SL de vol 10 = -4 883). Revisar sizing y/o SL.
3. **Apagar o rediseñar el sistema magic 0** (martingala/hedge) — es la fuente del ~104% de la pérdida.
4. La serie MTF tiene resultados **muy dispares por variante**: M32X_S2 (3/3) y M31_S2 (1/1) = **todo aciertos**; M32X_S3 (0/7) y M31_S5 (0/2) = todo SL (ver §5.1: magic compartido entre familias).
5. **Pendiente:** re-backtest de validación de KF11 (v11.0 recompilada hoy) en BTCUSDm H1 2025→2026, para confirmar que el rendimiento sigue intacto tras la limpieza de código.

### 5.1 ⚠ Reutilización de magic entre versiones (serie MTF)

Análisis por **comentario** (firma de versión en el EA) — el número de magic ya no es fiable para atribuir la serie MTF:

| Magic | Comentarios observados en vivo | Base correcta en el repo |
|---|---|---|
| 910001 | M31_S1 | ✓ (r31 = 910001) |
| 910002 | **M31_S2 + M32X_S2** (mezcla) | r31=910001 / r32_XAU=915001 |
| 910003 | M32X_S3 | r32_XAU=915001 (✗ en rango r31) |
| 910004 | M32B_S4 | r32_BTC=914001 (✗ en rango r31) |
| 910005 | M31_S5 | ✓ (r31) |

**Conclusión:** el binario desplegado de r32 XAU/BTC se compiló arrastrando el magic base de r31 (910001). Los trades de **M32X_S2/S3** y **M32B_S4** solo se identifican por comentario, no por magic. **Acción:** recompilar los r32 con 915001/914001 (ya correctos en el repo) y reservar magic exclusivo por versión antes de operarlos de nuevo.

---

*Datos extraídos vía MetaTrader5 API (terminal en vivo). Historial: 10–13/08/2026 — el que el broker entrega para esta cuenta demo.*
