# Configuraciones EAs para Cuenta Real
**Fecha:** 16/08/2026  
**Cuenta demo origen:** 198816526 (Exness-MT5Trial11)  
**Resultado demo:** +$4,000 (+40%) en 2 días | KF11-BTC: 5/5 ganadores | r32: 2/2 perdedores

---

## 1. KF11 v11 — BTCUSDm (magic 104) ⭐ EL QUE GANA
**Archivo:** `config_real/KF11_v11_BTCUSDm_REAL.set`

| Parámetro | Demo (peligroso) | REAL (este set) |
|---|---|---|
| **Lote** | Fijo 10.0 | **Riesgo 0.75% equity** (máx 1.0 lote) |
| SL / TP | 2×ATR / 4×ATR (2R) | 2×ATR / 4×ATR (2R) |
| Sesión | OFF | **16-19h** (hora servidor Exness = UTC+3) |
| Max trades/día | Ilimitado | **2** |
| Breaker diario | $30 | **−1.5% equity** |
| Cooldown | 2 min | 2 min |
| Breakeven / Trail | 0.5 / 0.35 ATR | Igual |

> ⚠ **ADVERTENCIA:** KF11 en BTC está **DESCARTADO** en `STRATEGIES_INDEX.md` — backtest 2026 = −33,021; demo anterior = −3,009. La racha actual (5/5) es muestra mínima. Si lo usas en real, reduce `InpMaxLotSize` a 0.5 y monitorea de cerca.

---

## 2. MTF r32 M32B_S2 — BTCUSDm (magic 910002) ❌ NO USAR EN REAL
**Archivo:** `config_real/MTF_r32_M32B_S2_BTCUSD_DEMO.set`

- Demo actual: 2 trades, **−$184** (0% WR)
- Live anterior (cuenta 198790722): 4 trades, 0% WR, −$195
- Magic compartido (910002 = M31_S2 + M32X_S2 mezclados)
- **Descartado definitivamente** — no pasar a real.

---

## 3. MOMEMA 04-06h — XAUUSDm (magic 920001) ✅ RECOMENDADO PARA REAL
**Archivo:** `Pure_Fractal_MOMEMA_04_06_XAU_REAL.set` (en raíz)

| Parámetro | Valor |
|---|---|
| Símbolo / TF | XAUUSDm M5 |
| Riesgo | 0.75% equity / trade |
| Máx trades/día | 2 |
| Breaker diario | −1.5% equity |
| SL / TP | 0.8×ATR / **3R** (2.4×ATR) |
| Time-stop | 2h (24 velas M5) |
| Sesión | 04-06h hora servidor |
| Cooldown | 5 min |
| **BE / Trail** | **NINGUNO** (destruye la estrategia) |

> **Backtest 2026 (ene-jul):** +68% · PF 1.31 · MaxDD 18.9% · 299 trades  
> **Backtest 2 años (2024-2026):** +202% · PF 1.21  
> **Mejor resultado del proyecto validado.**

---

## Checklist para pasar a real

### KF11-BTC (si insistes)
- [ ] `InpMaxLotSize` = 0.5 (no 1.0)
- [ ] Verificar hora servidor = UTC+3 (Exness Trial)
- [ ] Capital mínimo sugerido: $5,000 (0.75% = $37.5/trade)
- [ ] Monitoreo diario: si 2 días seguidos −1.5% → apagar

### MOMEMA-XAU (recomendado)
- [ ] Compilar `Pure_Fractal_MOMEMA_04_06_XAU.mq5` (F7 en MetaEditor)
- [ ] Cargar `.set` en gráfico XAUUSDm M5
- [ ] Capital mínimo: $2,000 (0.75% = $15/trade)
- [ ] Verificar sesión 04-06h en tu broker

---

**Resumen cuenta demo 198816526:**
- Inicio: $10,000 (15/08)
- Actual: ~$14,000 (+40%)
- KF11-BTC: 5/5 ganadores (+$1,822)
- r32-BTC: 2/2 perdedores (−$184)
- Posición abierta: 0
- **Conclusión:** KF11-BTC "invicto" por ahora, pero backtest dice que caerá. MOMEMA-XAU es la apuesta validada.