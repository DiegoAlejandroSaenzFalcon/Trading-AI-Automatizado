# Ranking de EAs — Qué probar en REAL

**Fuente de datos:**
1. **Live forward demo** (cuenta 198790722, 10–13 Ago 2026, 371 posiciones, **excluido el magic 0 manual**).
2. **Backtest walk-forward disponible**: KF11 v11 BTCUSD H1, 01.01.2025→11.08.2026, depósito 100k, 2 868 trades.

---

## 1. Ranking por variante (live demo)

| # | Variante | Símbolo | N | WR | PF | Neto | Avg | Max DD | Veredicto |
|---|---|---|---|---|---|---|---|---|---|
| 1 | **KF11 / v11** | XAUUSDm | 9 | 66,7% | **4,76** | **+3 052** | +339 | 494 | ⭐ SIGUE EN REAL |
| 2 | MTF • M32X_S2 | XAUUSDm | 3 | 100% | ∞ | +955 | +318 | 0 | muestra mínima |
| 3 | MTF • M31_S1 | XAUUSDm | 8 | 37,5% | 1,85 | +638 | +80 | 574 | vigilar (n pequeño) |
| 4 | MTF • M32X_S2 / M31_S2 | XAUUSDm | 1-3 | 100% | ∞ | +364 | +364 | 0 | muestra mínima |
| 5 | v12.0 / r30 | BTCUSDm | 2 | 100% | ∞ | +41 | +20 | 0 | muestra mínima |
| 6 | NeurAlgo (1111) | XAUUSDm | 136 | 30,1% | 1,08 | **+39** | 0 | 176 | ❌ breakeven |
| 7 | MTF • M32B_S4 | BTCUSDm | 4 | 25% | 0,65 | -195 | -49 | 563 | ❌ |
| 8 | MTF • M31_S5 | BTCUSDm | 2 | 0% | 0 | -394 | -197 | 394 | ❌ |
| 9 | MTF • M32X_S3 | XAUUSDm | 7 | 0% | 0 | -1 085 | -155 | 1 085 | ❌ |
| 10 | **KF11 / v11** | BTCUSDm | 10 | 70% | 0,43 | **-3 009** | -301 | 4 884 | ❌ hoy |

### Dato fino dentro de KF11 XAU (el mejor)

| Lado | Trades | PnL |
|---|---|---|
| KF11 **Sell** | 7 | **+3 830** (avg **+547**/trade) |
| KF11 Buy | 2 | -778 (incluye 1 stop-out -428) |

La fortaleza actual de KF11 en XAUUSD es direccional, por el lado **SELL** (oro bajando de 4414→4379), sesión 18:00–24:00 UTC.

---

## 2. Cruce con el backtest (KF11)

| Métrica | Backtest v11·BTC (2025→ago26) | Live 104·BTC |
|---|---|---|
| Trades | 2 868 | 10 |
| Winrate | 77,6% | 70% |
| Profit factor | 1,05 | 0,43 |
| Neto | +322 876 (+323%) | -3 009 |
| Avg win / avg loss (RR) | 2 984 / 9 842 (**0,30**) | — |
| Max DD | **51 459** (51% del depósito) | 4 884 |
| **2025** | +355 896 | — |
| **2026** | **-33 021** | negativo |

**Lectura honesta:**
- KF11 es **WR-alto / PF-bajo / RR 0,30**: gana poquito seguido y pierde mucho de vez en cuando (68 cierres MARKET = -268 666).
- En **2026 el año va negativo** (-33k). El live actual en BTC (10 trades) **coincide** con esa fase débil → el -4 883 de lote 10 es comportamiento real de v11, no otra IA.
- El resultado de XAUUSD live (PF 4,76) es el único punto claramente positivo y no tiene contrapartida negativa en la muestra.

---

## 3. Recomendación para REAL

### ⭐ Probar: **KF11 v11 — XAUUSDm**
- Gráfico **H1**, cuenta con los parámetros del `.set` validado.
- **Sizing seguro**: riesgo fijo ≈ **0,5–1% del equity por trade** (NO lote fijo 10). En XAUUSD un lote 1.00 con SL ~15-20$ = arriesga ~$1,5-2k → para cuenta de ~5k usa 0.01–0.05.
- Opcional y recomendado: **solo lado SELL** y filtro horario **18:00–24:00 UTC** (donde van los +1 561 y +1 617) mientras dure la tendencia.
- Magicos: **reservar magic propio** (104 ya se usa; no mezclar con BTC).

### ⏳ Vigilar en demo (NO real todavía): MTF M31_S1 y M32X_S2
- Muestra de 3-8 operaciones no decide nada. Déjalos 2-3 semanas more demo.
- **Antes de usarlos**: recompilar r32 con magics 915001 (XAU) / 914001 (BTC) para que el ledger no mezcle otra vez M31/M32.

### ❌ No llevar a real por ahora
- **KF11 en BTC**: backtest 2026 negativo + RR 0,30 + serie live negativa → solo cuando el backtest 2026 remonte.
- **NeurAlgo (1111)**: breakeven tras 136 trades.
- **M32X_S3, M31_S5, M32B_S4**: perdedores en la muestra.

---

## 4. Checklist antes de mover a real
1. [ ] Recompilar KF11 v11 con la versión limpia (hecha hoy, 0 errores) y **magic exclusivo** para XAU.
2. [ ] Definir **riesgo fijo por trade** (0,5–1%), no lotes fijos grandes.
3. [ ] Probar 3–5 días en demo con ese sizing para validar slippage real del broker.
4. [ ] Atribución limpia: NO tocar el magic del binary desplegado en adelante.
5. [ ] Definir regla de parada (p.ej. 10% DD diario o semanal apaga el EA).

*Datos: MetaTrader5 API (live) + backtest repo. Muestra live = 3 días; el ranking premia consistencia+expectancia, no solo neto, y descarta magics sin (comentario,símbolo) limpio.*