# PLAN DEL PROYECTO — EAs Multi-Version (ApexQuant / NeurAlgo)

Estado: 12/08/2026 · Repo trabajo = "Default Project" (main, 1 commit)
Objetivo general: transformar la acumulación de EAs en una fábrica ordenada,
segura y pública (GitHub), con identidad inmutable por versión y decisiones de
parámetros basadas en evidencia.

=====================================================================
0. AUDITORÍA DEL ESTADO ACTUAL (verificado, no supuesto)
=====================================================================
[OK]  9 EAs de las 3 familias compilados hoy con 0 errores/0 warnings.
      - FVG Fusion: v11.0, v12.0, r30-BTC, r30-XAU
      - MultiTimeframe: r31(XAU), r31_BTC, r31_BTC_2, r32_BTC, r32_XAU
[OK]  Identidad unica por version (magic+comentario+GV) aplicada y verificada
      por agente Code Reviewer. Se corrigieron ademas:
      - GV de persistencia ahora llevan _Symbol y prefijo de version
        (antes "M31_DAYPL" compartida => breaker diario contaminado)
      - OnTradeTransaction ahora valida DEAL_SYMBOL == _Symbol
      - OnInit de r32 valida segun el modo de riesgo activo (%equity o USD)
      - r30X magic 30 -> 31 (colisionaba con r30B)
[OK]  Biblioteca publica generada (62 EAs, 12 tipos de estrategia, indice por
      efectividad/activo/estrategia, generador build_library.py).
[!!]  DEUDA principal: las 3 familias siguen siendo copias monoliticas.
      Una nueva version/imput = editar el motor manualmente = riesgoso.
[!!]  Efectividad: registry.csv en POR_REVISAR; sin scores reales.
[!!]  Mejora XAU: pendiente de evidencia; se evitara cambiar parametros a ciegas.
[!!]  Libreria publica: sin git init ni publicacion.

=====================================================================
1. ARQUITECTURA OBJETIVO (diseno)
=====================================================================
Principio: la IDENTIDAD de una version es un manifiesto, NUNCA codigo suelto.

  MQL5\Include\NeurAlgo\
    Identity.mqh       // VER_MAGIC, VER_TAG (de #defines) -> GV/comment/log derivados
    Risk.mqh           // SizeLot (USD fijo o %equity) + DailyCircuitBreaker
    Strategies.mqh     // senales puras -1/0/+1 (FVG, BREAK48, MOMEMA, EMACROSS,
                       // RETEST48, VWAP, RSI2) reutilizables entre familias
    PF_FVG_Core.mqh    // motor FVG (OnInit/OnTick/OnDeinit) SIN inputs ni literales
    PF_TF_Core.mqh     // motor multihorario: 8 slots declarativos por macro+loop
  MQL5\Experts\        // manifiestos delgados (compilan el .ex5, mismo nombre)
    Pure_Fractal_FVG_Fusion_v11.0.mq5   // #define VER_MAGIC 104 ... + #include PF_FVG_Core
    ... (cada version = ~15 lineas de manifiesto + core)

Nueva version = copiar manifiesto y cambiar 6 #defines. Prohibido tocar el core.
MQL5 no soporta arrays de inputs => slots con #define SLOT(n) macro + carga en loop.

=====================================================================
2. PLAN POR FASES (urgencia x esfuerzo)
=====================================================================
FASE 1 — REFACTOR A CORE COMPARTIDO    [CRITICA, riesgo medio]
  1.1 Identity.mqh + Risk.mqh (no toca logica)
  1.2 Migrar MultiTimeframe r31/r32 -> PF_TF_Core + manifiestos
  1.3 Migrar FVG v11/v12/r30 -> PF_FVG_Core + manifiestos
  1.4 Verify: mismos .ex5, mismas GV (posiciones siguen) + compile-check
  1.5 Regla: git commit por version migrada
  PUEDE APLICARSE: Software Architect (diseño), Code Reviewer (cada migración),
                   Git Workflow Master (ramas/commits convencionales)

FASE 2 — EFECTIVIDAD CON EVIDENCIA     [ALTA, riesgo bajo]
  2.1 Model QA audita las validaciones existentes (walk-forward 3 periodos,
      demos, logs MT5) -> matriz de realidad por EA
  2.2 Llenar registry.csv: status, score (3/2/1/0), r_mult, max_dd_pct, winrate
  2.3 Regenerar indices (build_library.py) + marcar la libreria publica
  PUEDE APLICARSE: Model QA Specialist, Test Results Analyzer, Reality Checker

FASE 3 — MEJORA XAU MEDIDA             [MEDIA, riesgo alto si se hace mal]
  3.1 Con matriz de la Fase 2, identificar la franja horaria + motor que
      realmente aporta en XAU (no cambios a ciegas en slots)
  3.2 Probar en backtest multi-periodo y 1 semana demo (gate Reality Checker)
  3.3 Si pasa, nueva version r33_XAU con manifiesto + set versionado
  PUEDE APLICARSE: Model QA, Performance Benchmarker, Reality Checker

FASE 4 — PUBLICACION GITHUB            [ALTA, riesgo legal/estrategico]
  4.1 Decision: repo publico con o sin fuentes .mq5 (ver Riesgos + Decisiones)
  4.2 git init en apexquant-ea-library + README/LICENSE/disclaimer + commit
  4.3 gh repo create --public; CI: GitHub Action que regenere indices
  4.4 CHANGELOG por version + tag de versiones
  PUEDE APLICARSE: Git Workflow Master, Technical Writer, Security Engineer

FASE 5 — GOBERNANZA (continua)
  5.1 Regla de oro: identidad nunca a mano (manifiesto = unica fuente)
  5.2 Compile-check automatizado tras cada cambio (script local; CI si GitHub)
  5.3 Revision mensual de resultados demo -> actualizar scores/registry
  PUEDE APLICARSE: Incident Response Commander (live), Compliance Auditor
                   (cuentas prop/funded), Analytics Reporter (dashboards)

=====================================================================
3. RIESGOS Y MITIGACIONES
=====================================================================
R1  Cambiar magic/MIGRAR deja posiciones huerfanas.
    Mitigacion: identidad = const de compilacion (manifiesto), aviso de cierre
    antes de migrar, pruebas en demo.
R2  Overfitting en parametros.
    Mitigacion: solo se acepta score>=2 con WF multi-periodo O demo 1sem+
    (gate del Reality Checker). Prohibido calibrar con 1 solo periodo.
R3  MT5 exige nombre de EA unico por .ex5.
    Mitigacion: el manifiesto conserva el nombre (mismo .ex5, mismo nombre).
R4  No existe CI para MQL5.
    Mitigacion: script local de compile-check (MetaEditor /compile + parse de log)
    integrado como paso de la Fase 5.
R5  Publicar codigo fuente de estrategias = exponer la investigacion.
    Mitigacion: Decision del usuario (ver Decisiones). Opcion: repository solo
    con docs/indices + codigo privado, o publico con fuentes (LICENSE MIT).

=====================================================================
4. AGENTES DE LA BIBLIOTECA APLICABLES (priorizados)
=====================================================================
URGENTES (Fase 1-2): Software Architect, Code Reviewer, Model QA Specialist,
                      Reality Checker, Git Workflow Master
OPERATIVOS (Fase 2-4): Test Results Analyzer, Performance Benchmarker,
                        Technical Writer, Security Engineer
FUTURO (Fase 4-5): Incident Response Commander, Compliance Auditor,
                    Analytics Reporter, Document Generator
FUERA DE ALCANCE: marketing/sales/XR/china-ecom/game design/etc.

=====================================================================
5. DECISIONES PENDIENTES DEL USUARIO
=====================================================================
D1  Repo publico: (a) fuentes .mq5 publicas con MIT, (b) solo docs+indices con
    codigo privado? (define R5)
D2  Alcance de la Fase 1: migrar primero MultiTimeframe (pequeno, ~600 lineas)
    o FVG (grande, ~2000)? Recomendado: MultiTimeframe primero (menos riesgo).
D3  Prioridad inmediata tras este doc: Fase 1 (refactor) o Fase 2 (evidencia)?
    Recomendado: Fase 2 rapida (bajo riesgo, alimenta la libreria) y Fase 1 en
    paralelo por parejas de versiones.
D4  Web de proyecto / branding: mantener "ApexQuant/NeurAlgo" y autor en LICENSE?
D5  Nombre del repo publico: apexquant-ea-library (recomendado) u otro.
=====================================================================
Documento vivo. Replanificar al cerrar cada fase.