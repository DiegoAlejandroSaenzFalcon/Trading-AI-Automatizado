# Trading-AI Automatizado

Repositorio de refera de **trading automatizado profesional**: arquitectura Kalman + FVG y estrategias multitiempo, validadas con walk-forward y forward demo, lista para llevar a **cuenta real con riesgo porcentual**.

> Metodología: <kbd>docs/metodologia.md</kbd> · Riesgo: <kbd>docs/gestion-de-riesgo.md</kbd> · Demo→Real: <kbd>docs/despliegue-demo-a-real.md</kbd>

---

## 📂 Estructura del repositorio (organizada por activo)

```
├── docs/                      # Manuales educativos (metodología, riesgo, despliegue)
├── XAUUSD/                    # Estrategias de ORO (mejor forward demo)
│   ├── KF11-v11/             # ⭐ TOP 1 — FVG+Kalman, SELL fuerte, +3 052 (demo)
│   ├── MTF-M31-S2/           # MultiTimeframe r31, slot S2
│   └── MTF-M32X-S2/          # MultiTimeframe r32_XAU, slot S2 (3/3 TP)
├── BTCUSD/                    # Estrategias de BITCOIN (sesión filtrada)
│   ├── KF11-v12/             # v12.0, sesión NY 16-19h, PF 2.2
│   └── FVG-r30/              # r30, ventana 10-15h (robusto)
├── configuracion/             # Magic registry + sets + runbook
├── reportes/                  # Performance live vs backtest
├── backtests/                 # Walk-forward (trades, .set, .ini)
└── herramientas/              # MCP para consultar la cuenta via LLM
```

---

## 🏆 Ranking de EAs (demo 10–13 Ago 2026)

| Rank | Estrategia | Símbolo | Neto | WR | PF | Para real |
|---|---|---|---|---|---|---|
| 1 | KF11-v11 | XAUUSDm | **+3 052** | 66,7% | 4,76 | ⭐ Sí |
| 2 | MTF-M32X-S2 | XAUUSDm | +955 | 100% | ∞ | demo (muy pocos) |
| 4 | MTF-M31-S2 | XAUUSDm | +364 | 100% | ∞ | demo (1 op) |
| 5 | FVG-v12 | BTCUSDm | +41 | 100% | ∞ | sí, con risk |
| — | KF11-v11 | BTCUSDm | **-3 009** | 70% | 0,43 | ❌ No (2026↓) |

> El detalle completo, con el análisis live vs backtest y la desagregación por lado (SELL), está en `reportes/ranking_EA_para_real.md`.

---

## ⭐ Starter recomendado para real

**KF11-v11 en XAUUSDm, H1**, sizing 0,5–1% equity, cap lote 1.0, sesión 20–23h local (franja SELL ganadora). Ver `XAUUSD/KF11-v11/EA.md`.

---

## 🆕 Primeros pasos

1. Lee `docs/metodologia.md` y `docs/gestion-de-riesgo.md`.
2. Revisa `configuracion/MAGIC_REGISTRY.txt` (un magic = una versión).
3. Abre `reportes/ranking_EA_para_real.md` y escoge tu estrategia.
4. Sigue la checklist `docs/despliegue-demo-a-real.md` para pasar a real.
