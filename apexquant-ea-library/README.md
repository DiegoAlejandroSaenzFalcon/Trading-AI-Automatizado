# ApexQuant — Librería Pública de EAs (MetaTrader 5)

Repositorio abierto de Expert Advisors en MQL5. Contiene **todos** los EAs del
proyecto — los validados, los que están en demo, los experimentales y los que
no pasaron la validación — organizados para poder navegarlos por **activo**,
por **tipo de estrategia** y por **efectividad**, sin perder nada.

> ⚠️ **IMPORTANTE**: EAs de trading real. El contenido es con fines
> **educativos y de investigación**. No es asesoría financiera. Backtests
> pasados no garantizan rentabilidad futura. Úsalo bajo tu propia
> responsabilidad y primero en demo / paper trading.

---

## Estructura óptima (por qué es así)

| Enfoque | Solución | Por qué |
|---|---|---|
| Todos los EAs, ninguno descartado | El repositorio NIEGA los EAs, pero el **estado** y **score** los catalogan (validado / demo / backtest / archivado) | Navegar sin borrar |
| Organizar por activo | Vista virtual **`POR_ACTIVO.md`** (generada) + columna `activo` en el registro | El activo no duplica código |
| Organizar por tipo de estrategia | Carpeta física **`estrategias/<tipo>/<EA>/`** (FVG, Breakout, Engulfing, MultiTimeframe, Scalping…) | Es la característica estructural del código |
| Organizar por efectividad | **`INDEX.md`** ordenado por score (3→0) + columna `score` en `registry.csv` | Ranking sin reordenar carpetas |
| Fuente de verdad | **`registro/registry.csv`** (extensible: R, MaxDD%, winrate) | Todo lo demás se auto-genera de aquí |

```
apexquant-ea-library/
├── README.md                → esta guía
├── INDEX.md                 → RANKING por efectividad (auto-generado)
├── POR_ACTIVO.md            → vista por activo (auto-generado)
├── POR_ESTRATEGIA.md        → vista por estrategia (auto-generado)
├── registro/
│   └── registry.csv         → FUENTE DE VERDAD (editar aquí los resultados)
├── estrategias/
│   └── <tipo_estrategia>/
│       └── <EA>/
│           ├── README.md    → descripción, magic, configuración, resultados
│           └── src/         → <EA>.mq5 (+ .set opcional)
├── scripts/
│   └── build_library.py     → regenera índices y READMEs desde registry.csv
└── LICENSE
```

## Score de efectividad (columna `score` en registry.csv)

| Score | Significado |
|---|---|
| 3 | Validado por walk-forward multi-periodo en backtest |
| 2 | Demo positiva ≥ 1 semana con trades reales |
| 1 | Backtest marginal o solo un periodo |
| 0 | Sin probar / no pasó validación / prototipo |

Cada EA con score 2+ debería tener `r_mult`, `max_dd_pct` y `winrate` completos
en el CSV (así sale todo en los índices sin tocar carpetas).

## Cómo se mantiene

1. Edita `registro/registry.csv` con un nuevo EA o con los resultados reales.
2. Corre el generador:

```bash
python scripts/build_library.py
```

3. Commit de los `.md` regenerados. (El CSV es la única pieza editada a mano.)

## Config rápida de cada EA

Cada `src/` incluye el `.mq5`. Los parámetros (magic, riesgo, slots) se asignan
cargando el `.set` correspondiente al EA en MetaTrader 5 (ver `MAGIC_REGISTRY`
del proyecto local para la tabla de magics únicos por versión).

## Licencia

MIT — ver `LICENSE`. El código se ofrece "as is", **sin garantías**.