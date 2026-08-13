# Trading Automatizado — Paquete de Despliegue REAL

Conjunto de EAs de la familia **Pure Fractal** listos para operar en cuenta real.
Cada subcarpeta contiene: el **código fuente (.mq5)**, el **.set REAL** y su **README** de despliegue.

---

## Índice de EAs

| Carpeta | EA | Símbolo | TF | Magic | Resultado live demo (10–13 Ago) |
|---|---|---|---|---|---|
| `01_KF11_v11_XAUUSD` | Pure_Fractal_FVG_Fusion_v11.0 | XAUUSDm | H1 | **104** | +3 052 · 9 trades · WR 66,7% · PF 4,76 ⭐ |
| `02_MTF_M31_S2_XAUUSD` | MultiTimeframe r31 | XAUUSDm | H1 | **910001** | S2 1/1 (+364) · set completo validado PF 1,22 |
| `03_MTF_M32X_S2_XAUUSD` | MultiTimeframe r32_XAU | XAUUSDm | H1 | **915001** | S2 3/3 (+955) |
| `04_FVG_v12_BTCUSD` | Pure_Fractal_FVG_Fusion_v12.0 | BTCUSDm | H1 | **12** | +11 (1/1) · backtest sesión NY PF 2,2 |
| `05_FVG_r30_BTCUSD` | Pure_Fractal_FVG_Fusion_BTCUSD_r30 | BTCUSDm | H1 | **30** | +30 (1/1) · backtest 10–15h |

---

## ⚠️ Advertencias antes de operar real

1. **Muestra live muy corta.** Los MTF (S2), v12 y r30 tienen **1–3 operaciones** en demo. La base sólida es el **backtest walk-forward** (r31: PF 1,22 en 3 periodos; v12: sesión 16–19h PF 2,2; r30: 10–15h robusto en 2 subperiodos). KF11 XAU respalda el forward live (+3 052).
2. **KF11 en BTC no está en este paquete**: el backtest 2026 va negativo (-33k) y el live coincide (-3 009). Revisar antes de considerarlo.
3. **Sizing REAL = riesgo fijo 0,5–1% del equity por trade.** Todos los `.set` REAL ya usan `InpLotMode=0` (riesgo por USD). **NUNCA usar lote fijo 10** (el SL de lote 10 en demo fue -4 883).
4. **Verificar el magic compilado** antes de montar (en el gráfico debe mostrar el magic de la tabla). Los MTF r32 tuvieron un historial de magic mal heredado (M31/M32 compartiendo 910001). Ver `../MAGIC_REGISTRY.txt`.
5. **Prueba de 3–5 días en demo con el mismo sizing** para validar slippage/spread real del broker antes de fondear.

---

## Despliegue (por EA)

1. Compilar el `.mq5` con MetaEditor (F7).
2. Arrastrar el EA al gráfico del símbolo indicado (TF H1).
3. Cargar el `.set` de la carpeta → **verificar el número de magic** en la pestaña "Parámetros de entrada".
4. Activar trading automático (Algoritmos) y confirmar en el diario que OnInit pasó sin errores.

> Nota sobre magics: no cambiar nunca el magic de una versión con posiciones abiertas — quedan huérfanas. Cada versión del paquete tiene magic único.

---

## Registro de identidad

Ver `MAGIC_REGISTRY.txt` en la raíz del repo para la tabla completa magic → comentario → GlobalVariables.
