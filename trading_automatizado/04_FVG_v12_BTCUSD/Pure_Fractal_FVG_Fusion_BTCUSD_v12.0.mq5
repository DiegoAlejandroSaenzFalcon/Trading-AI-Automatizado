//+------------------------------------------------------------------+
//|            Pure_Fractal_FVG_Fusion_BTCUSD_v12.0.mq5              |
//|   v12.0 — ADAPTACION COMPLETA PARA BTCUSD M1                      |
//|   Base: v11.0 (auditoria profunda, XAUUSD M15).                   |
//|                                                                    |
//|   ADAPTACION A BTCUSD (estudio de 99.520 velas M1, 04-mar a       |
//|   13-may-2026, +69 dias, rango 64.895-82.827):                    |
//|   A1) FVG: el gap minimo (InpMinGapATR) ahora se calcula con el   |
//|       ATR del timeframe FVG (no el ATR M1 del grafico). Con el    |
//|       ATR M1 (~66 USD) el umbral anterior era irrisorio           |
//|       (0.15 x 66 = ~10 USD) y aceptaba casi cualquier hueco de    |
//|       M15; con el ATR del TF FVG (~250-400 USD) el filtro es      |
//|       real.                                                       |
//|   A2) SPREAD: el broker registra SPREAD=1500 pts (~15 USD,        |
//|       0.02% del precio, ~23% del rango medio M1). Todos los       |
//|       pisos, trailing y filtros se ajustan a esa realidad:        |
//|       - InpMaxSpreadATR=0.35 (antes 0.15, que BLOQUEABA todo:     |
//|         15/66=0.23 > 0.15).                                       |
//|       - InpTrailSpreadFloorMult=2.0 y InpTrailMinATR=0.20 para    |
//|         que el trailing nunca se asfixie con el spread.           |
//|   A3) HORAS: segun el estudio, la sesion NY (16-19h del broker)   |
//|       tiene el mayor rango (0.10-0.13%) y mas ticks (255-262).    |
//|       Filtro de sesion ON por defecto (15:00-22:00).              |
//|   A4) MACRO: en M1 la EMA50/200 se cruzo 663 veces (ruido puro).  |
//|       El sesgo macro ahora se calcula en H4 (InpMacroTimeframe=   |
//|       PERIOD_H4) para filtrar solo la tendencia estructural.      |
//|   A5) REGIMEN: ATR M1 con colas extremas (vela max 2.04%,         |
//|       mediana 55.99 vs media 65.68). InpRegimeATRWindow=240       |
//|       velas (4h) para la media de regimen; SL mas holgado          |
//|       (InpSLMultiplier=0.8) porque el stop medio XAU no aplica:   |
//|       el SL base M1 (0.6xATR=~40 USD) queda sobre el piso de      |
//|       spread (~22-30 USD).                                        |
//|   A6) RIESGO: valores conservadores por defecto (riesgo 3 USD,    |
//|       limite diario 12 USD, cooldown 5 min, confirmacion de vela  |
//|       + 1 vela minima entre entradas).                            |
//|                                                                    |
//|   ADVERTENCIA: esto es adaptacion estadistica, NO promesa de      |
//|   rentabilidad. Valida en DEMO con muestreo amplio y con tu       |
//|   broker real (spread/datos del CSV son de tu broker).            |
//+------------------------------------------------------------------+
#property copyright "APEXQUANT / NeurAlgo project"
#property version   "12.0"
#property strict
#property description "Fusion Kalman + FVG/PA v12 BTCUSD — adaptado a M1 BTCUSD (estudio 99.520 velas): FVG con ATR del TF, spread-aware, sesion NY, macro H4"

#include <Trade\Trade.mqh>
CTrade trade;

enum ENUM_MACRO_MODE
{
    MACRO_MODE_EMA  = 0,
    MACRO_MODE_TEMA = 1
};

enum ENUM_LOT_MODE
{
    LOT_MODE_RISK  = 0,   // Calcular lote segun riesgo en USD (InpRiskPerTradeUSD)
    LOT_MODE_FIXED = 1    // Usar lote fijo manual (InpFixedLotSize)
};

enum ENUM_ACCOUNT_TYPE
{
    ACCT_AUTO     = 0,    // Auto-deteccion (recomendado)
    ACCT_STANDARD = 1,    // Forzar Standard
    ACCT_CENT     = 2,    // Forzar Cent
    ACCT_MICRO    = 3     // Forzar Micro
};

enum ENUM_SIGNAL_MODE
{
    SIG_LEGACY    = 0,    // Legado v10.12 (sin normalizar)
    SIG_BALANCED  = 1     // Normalizado por barra + z-score (recomendado)
};

enum ENUM_AKF_MODE
{
    AKF_VARTICK   = 0,    // Legado: varianza de deltas de tick
    AKF_INNOV     = 1     // Innovaciones del filtro (Mehra-lite, recomendado)
};

//===================================================================
//  INPUT PARAMETERS
//===================================================================
input group "=== Tipo de Cuenta (Cent/Standard/Micro Auto) ==="
input ENUM_ACCOUNT_TYPE InpAccountType = ACCT_AUTO; // 0=AUTO (recomendado), 1=Standard, 2=Cent, 3=Micro
input int               InpMacroTimeframe = PERIOD_H4; // TF del sesgo macro (0=grafico, H4 recomendado BTC)

input group "=== Motor Kalman: Filtro y Sigmoide ==="
input int    InpATRPeriod        = 14;
input double InpKalmanQ11        = 1e-4;
input double InpKalmanQ22        = 1e-2;
input double InpKalmanR          = 1e-3;
input double InpKalmanDtFallback = 0.1;
input double InpKalmanMinDt      = 0.001;  // Piso minimo de dt (segundos); evita dt~0 por tick clustering
input double InpDtSmoothingAlpha = 0.20;   // Suavizado EWMA (0-1) del dt usado SOLO para el termino de aceleracion
input double InpMaxAccelHatAbs   = 3.0;    // Clamp duro sobre |a_hat| antes del sigmoide (red de seguridad numerica)
input double InpVelocitySens     = 50.0;
input double InpDisplacementW    = 3.0;
input double InpAccelerationW    = 10.0;
input double InpBiasThreshold    = 0.60;
input ENUM_SIGNAL_MODE InpSignalMode = SIG_BALANCED; // Modo de senal: 1=balanceado (rec), 0=legado v10.12

input group "=== Entradas: Confirmacion de Vela y Cadencia ==="
input bool   InpBarConfirmEntry      = true;  // Usar probabilidad de la vela CERRADA (no intrabarra)
input int    InpMinBarsBetweenEntries= 1;     // Vela(s) minimas entre entradas

input group "=== Filtro de Tendencia Macro (EMA/TEMA) ==="
input bool               InpMacroBiasEnable    = true;
input int                InpMacroPeriod        = 200;
input ENUM_MACRO_MODE    InpMacroMode          = MACRO_MODE_EMA;
input double             InpMacroPenaltyGamma  = 0.70;

input group "=== Ruido Adaptativo (AKF) ==="
input bool        InpAKF_Enable = true;
input int         InpAKF_Window = 30;
input double      InpAKF_Alpha  = 50.0;
input ENUM_AKF_MODE InpAKFMode  = AKF_INNOV; // 1=innovaciones (rec), 0=varianza de ticks

input group "=== Zonas FVG + Confluencia de Accion del Precio ==="
input ENUM_TIMEFRAMES InpFVGTimeframe      = PERIOD_M15;
input double            InpMinGapATR       = 0.15;
input int               InpMaxZoneAgeBars  = 60;
input int               InpMaxActiveZones  = 8;
input double            InpZoneInvalidateATR = 0.5;
input double            InpZoneToleranceATR  = 0.3;
input int               InpLookbackBars      = 20;
input double            InpConfluenceBoost   = 0.15;
input bool              InpRequireZoneProximity = true; // Exigir precio cerca de zona FVG activa para entrar (recomendado BTC)
input bool              InpRegimeFilterEnable   = false; // Bloquear entradas si ATR < % de su media
input double            InpRegimeATRMult        = 0.80;  // Umbral del filtro de regimen (x media ATR)
input int               InpRegimeATRWindow      = 240;   // Velas de la media ATR del regimen (M1: 240 = 4 horas)

input group "=== Riesgo Adaptativo: SL/TP conscientes del Spread ==="
input double InpSLSpreadBufferMult   = 1.5;  // El SL nunca es mas estrecho que (spread promedio x este factor)
input double InpSpreadSpikeThreshold = 1.8;  // Si spread_actual/spread_promedio supera esto, se considera "spike"
input double InpMaxSLSpreadExpansion = 2.0;  // Tope maximo de ensanche de SL/TP durante un spike de spread

input group "=== Riesgo y Tamano de Posicion (USD reales) ==="
input ENUM_LOT_MODE InpLotMode        = LOT_MODE_RISK; // Modo de lote: por riesgo o fijo manual
input double InpFixedLotSize     = 0.01;  // Lote fijo manual (usado si InpLotMode = LOT_MODE_FIXED)
input double InpRiskPerTradeUSD  = 12.0;  // Riesgo por operacion EN USD (ganador del barrido de sizing)
input double InpMaxLotSize       = 0.25;
input double InpSLMultiplier     = 0.8;   // SL base = ATR x esto (BTC M1: 0.8 x ~66USD = ~53USD, sobre piso de spread)
input double InpTPMultiplier     = 2.0;   // TP base = ATR x esto (R:R 2.5 - optimizado M30/H1)
input int    InpMaxOpenPositions = 1;     // Limite duro de exposicion: posiciones simultaneas de este EA

input group "=== Filtro de Spread ==="
input double InpMaxSpreadATR     = 0.35;  // BTC M1: spread tipico 15USD = 0.23 x ATR66; 0.35 permite operar fuera de spikes

input group "=== Salida: Parciales, Breakeven y Trailing Progresivo ==="
input bool   InpPartialTPEnable       = false; // Cerrar parcial de la posicion al llegar a X ATR
input double InpPartialFactor         = 0.50;  // Fraccion a cerrar en el parcial (0-1)
input double InpPartialTriggerATR     = 1.5;   // ATR a favor que dispara el parcial
input double InpBreakevenTriggerATR   = 1.0;   // Avance a favor que activa la proteccion (x ATR; BTC: 1.0x66 ~ 1 vela media)
input double InpBreakevenLockATR      = 0.25;  // Piso positivo asegurado al activarse (x ATR)
input double InpTrailBaseATR          = 0.35;  // Distancia de trailing justo al activarse (optimizado: 0.35 best)
input double InpTrailTightenRate      = 0.35;  // Cuanto se aprieta la distancia por cada ATR adicional a favor
input double InpTrailMinATR           = 0.20;  // Distancia minima de trailing (0.2x66=13USD, el piso de spread manda)
input double InpTrailSpreadFloorMult  = 2.0;   // Piso de trailing/BE en x spread promedio (BTC: 2x15=30USD)

input group "=== Controles Macro: Circuit Breaker Diario y Time-Stop por Volatilidad ==="
input bool   InpDailyLossLimitEnable = true;
input double InpMaxDailyLossUSD      = 48.0;  // Perdida REALIZADA maxima del dia EN USD (4x riesgo) -> bloquea nuevas entradas
input bool   InpVolTimeStopEnable    = true;
input double InpVolCollapseRatio     = 0.50;
input int    InpVolTimeStopMinBars   = 6;
input ENUM_TIMEFRAMES InpVolTimeStopBarTF = PERIOD_CURRENT;

input group "=== Pausa Tras Perdida ==="
input int    InpCooldownMinutes  = 5;

input group "=== Filtro de Sesion (mejor ventana segun estudio: NY 16-19h) ==="
input bool   InpSessionFilterEnable = true;
input int    InpStartHour        = 16;
input int    InpStartMinute      = 0;
input int    InpEndHour          = 19;
input int    InpEndMinute        = 0;

input group "=== Persistencia de Estado (GlobalVariables) ==="
input bool   InpPersistState = true;   // Guarda limite diario y cooldown entre reinicios

input group "=== Visualizacion: Zonas, Estructura y Panel ==="
input color  InpColorTP            = clrTeal;
input color  InpColorSL            = clrCrimson;
input color  InpColorBullFVG       = clrDodgerBlue;
input color  InpColorBearFVG       = clrOrange;
input color  InpColorLevels        = clrDarkGray;
input color  InpColorBuyArrow      = clrLime;
input color  InpColorSellArrow     = clrRed;
input color  InpColorKalmanLine    = clrYellow;
input color  InpColorStructure     = clrDimGray;
input bool   InpShowKalmanLine     = true;
input bool   InpShowStructure      = true;
input bool   InpShowAllPatterns    = true;
input bool   InpShowMacroTrendLine = true;
input bool   InpShowDashboard      = true;
input int    InpBoxExtendBars      = 5;
input int    InpZoneExtendBars     = 20;
input bool   InpShowLabels         = true;

//===================================================================
//  GLOBAL STATE — CUENTA Y ESCALA
//===================================================================
double g_acctUnit = 1.0;     // USD por 1 unidad de cuenta (Standard=1, Cent=0.01, Micro=0.001)
string g_acctName = "STANDARD";
int    g_macroTF  = 0;       // TF efectivo del sesgo macro

//===================================================================
//  GLOBAL STATE — KALMAN ENGINE
//===================================================================
double g_kxP = 0.0, g_kxV = 0.0;
double g_kP00 = 1.0, g_kP01 = 0.0, g_kP10 = 0.0, g_kP11 = 1.0;
double g_kQpos = 1e-4, g_kQvel = 1e-2;
double g_kR = 1e-3;
bool   g_kInit = false;
ulong  g_lastTickUs = 0;
double g_lastTickDt = 0.1;
double g_smoothedDt = 0.1;
double g_prevVelocity = 0.0;
double g_lastInnovation = 0.0;  // innovacion del ultimo paso (para AKF por innovacion)
double g_lastPpred00    = 1.0;  // P_pred[0][0] del ultimo paso

// Denominadores EWMA de la senal balanceada
double g_sigEVel = 0.0, g_sigEDis = 0.0, g_sigEAcc = 0.0;
bool   g_sigWarm = false;

int    g_hATR;
int    g_hATRFVG;            // ATR del timeframe FVG (para gap real de zona)
double g_bufATR[];
input ulong  InpMagicBase = 12; // MAGIC UNICO de esta version (asignable en .set)
datetime g_cooldownUntil = 0;
double   g_avgSpread = 0.0;
double   g_entryATR  = 0.0;

//===================================================================
//  GLOBAL STATE — CIRCUIT BREAKER DIARIO
//===================================================================
double   g_dayRealizedPL   = 0.0;   // en unidades de cuenta
datetime g_currentDayStart = 0;
bool     g_dailyLimitHit   = false;

int      g_hMacroEMA;
bool     g_macroInit        = false;
datetime g_lastMacroBarTime = 0;
double   g_macroEMA  = 0.0, g_macroTEMA = 0.0;
double   g_tema_ema2 = 0.0, g_tema_ema3 = 0.0;

double g_tickBuf[];
double g_innovBuf[];
double g_spreadBuf[];
int    g_akfWindow = 30, g_akfBufIdx = 0, g_akfBufCount = 0;
bool   g_akfInit = false;
double g_lastMid = 0.0;

//===================================================================
//  GLOBAL STATE — ENTRADA (confirmacion de vela) Y REGIMEN
//===================================================================
double   g_entrySignalP   = 0.5;   // probabilidad de la vela CERRADA (si InpBarConfirmEntry)
double   g_lastTickP      = 0.5;   // ultima probabilidad calculada tick a tick
datetime g_lastEntryBarTime = 0;
datetime g_prevBarTime    = 0;

double   g_atrHist[];              // historial de ATR para filtro de regimen
int      g_atrHistIdx = 0, g_atrHistCnt = 0;

ulong    g_partialTickets[];       // tickets que ya hicieron parcial

int      g_modifyErrCnt = 0;       // contador de fallos de modify (log limitado)

//===================================================================
//  GLOBAL STATE — FVG + PRICE ACTION
//===================================================================
struct FVGZone
  {
   double   top;
   double   bottom;
   datetime time;
   int      type;
   bool     active;
   string   objName;
  };
FVGZone zones[];

int      g_paFvgBias       = 0;
int      g_paFvgZoneIdx    = -1;
datetime g_paFvgBarTime    = 0;
double   g_paFvgCandleHigh = 0.0;
double   g_paFvgCandleLow  = 0.0;
datetime g_lastStructBarTime = 0;
datetime g_lastFastBarTime   = 0;
int      g_entryCounter    = 0;

//===================================================================
//  GLOBAL STATE — VISUAL: LINEA KALMAN
//===================================================================
#define KAL_HISTORY_MAX 150
double   g_kalHistPrice[];
datetime g_kalHistTime[];
int      g_kalHistCount = 0;

//===================================================================
//  Persistencia (GlobalVariables)
//===================================================================
string GV_DayStart(){ return("PFVG12_"+_Symbol+"_"+IntegerToString(InpMagicBase)+"_dayStart"); }
string GV_DayPL()   { return("PFVG12_"+_Symbol+"_"+IntegerToString(InpMagicBase)+"_dayPL"); }
string GV_Cooldown(){ return("PFVG12_"+_Symbol+"_"+IntegerToString(InpMagicBase)+"_cooldown"); }

//===================================================================
//  OnInit
//===================================================================
int OnInit()
{
    //--- Deteccion automatica de tipo de cuenta
    DetectAccountType();

    if(InpLotMode == LOT_MODE_RISK && InpRiskPerTradeUSD <= 0.0)
    {
        Print("ERROR: InpRiskPerTradeUSD debe ser mayor a 0 cuando InpLotMode = LOT_MODE_RISK. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpLotMode == LOT_MODE_FIXED && InpFixedLotSize <= 0.0)
    {
        Print("ERROR: InpFixedLotSize debe ser mayor a 0 cuando InpLotMode = LOT_MODE_FIXED. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpMacroPenaltyGamma <= 0.0 || InpMacroPenaltyGamma > 1.0)
        Print("[FVG_FUSION] AVISO: InpMacroPenaltyGamma fuera de (0,1].");
    if(InpKalmanMinDt <= 0.0)
    {
        Print("ERROR: InpKalmanMinDt debe ser mayor a 0. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpMaxSLSpreadExpansion < 1.0)
        Print("[FVG_FUSION] AVISO: InpMaxSLSpreadExpansion < 1.0 podria ESTRECHAR el SL durante un spike.");
    if(InpDailyLossLimitEnable && InpMaxDailyLossUSD <= 0.0)
    {
        Print("ERROR: InpMaxDailyLossUSD debe ser mayor a 0. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpVolTimeStopEnable && (InpVolCollapseRatio <= 0.0 || InpVolCollapseRatio >= 1.0))
    {
        Print("ERROR: InpVolCollapseRatio debe estar en (0,1). EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpMaxOpenPositions < 1)
    {
        Print("ERROR: InpMaxOpenPositions debe ser al menos 1. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpRegimeFilterEnable && (InpRegimeATRMult <= 0.0 || InpRegimeATRMult > 1.0))
    {
        Print("ERROR: InpRegimeATRMult debe estar en (0,1]. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpPartialTPEnable && (InpPartialFactor <= 0.0 || InpPartialFactor >= 1.0))
    {
        Print("ERROR: InpPartialFactor debe estar en (0,1). EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }

    trade.SetExpertMagicNumber(InpMagicBase);
    trade.SetTypeFilling(GetBestFillingMode(_Symbol));

    g_hATR = iATR(_Symbol, _Period, InpATRPeriod);
    if(g_hATR == INVALID_HANDLE)
    {
        Print("ERROR: ATR handle creation failed.");
        return INIT_FAILED;
    }
    ArraySetAsSeries(g_bufATR, true);

    g_hATRFVG = iATR(_Symbol, InpFVGTimeframe, InpATRPeriod);
    if(g_hATRFVG == INVALID_HANDLE)
    {
        Print("ERROR: FVG ATR handle creation failed.");
        return INIT_FAILED;
    }

    g_macroTF = (InpMacroTimeframe == PERIOD_CURRENT) ? _Period : InpMacroTimeframe;
    g_hMacroEMA = iMA(_Symbol, (ENUM_TIMEFRAMES)g_macroTF, InpMacroPeriod, 0, MODE_EMA, PRICE_CLOSE);
    if(g_hMacroEMA == INVALID_HANDLE)
    {
        Print("ERROR: Macro EMA handle creation failed.");
        return INIT_FAILED;
    }
    if(InpShowMacroTrendLine)
        ChartIndicatorAdd(0, 0, g_hMacroEMA);

    g_macroInit = false; g_lastMacroBarTime = 0;
    g_macroEMA = 0.0; g_macroTEMA = 0.0; g_tema_ema2 = 0.0; g_tema_ema3 = 0.0;

    g_akfWindow = InpAKF_Window;
    if(g_akfWindow < 2) g_akfWindow = 2;
    ArrayResize(g_tickBuf, g_akfWindow);
    ArrayResize(g_innovBuf, g_akfWindow);
    ArrayResize(g_spreadBuf, g_akfWindow);
    ArrayInitialize(g_tickBuf, 0.0);
    ArrayInitialize(g_innovBuf, 0.0);
    ArrayInitialize(g_spreadBuf, 0.0);
    g_akfInit = false; g_akfBufIdx = 0; g_akfBufCount = 0; g_lastMid = 0.0;
    g_avgSpread = 0.0;

    g_kxP = 0.0; g_kxV = 0.0;
    g_kP00 = 1.0; g_kP01 = 0.0; g_kP10 = 0.0; g_kP11 = 1.0;
    g_kQpos = MathMax(1e-12, InpKalmanQ11);
    g_kQvel = MathMax(1e-12, InpKalmanQ22);
    g_kR    = MathMax(1e-12, InpKalmanR);
    g_kInit = false; g_lastTickUs = 0; g_lastTickDt = InpKalmanDtFallback; g_smoothedDt = InpKalmanDtFallback; g_prevVelocity = 0.0;
    g_lastInnovation = 0.0; g_lastPpred00 = 1.0;

    g_sigEVel = 0.0; g_sigEDis = 0.0; g_sigEAcc = 0.0; g_sigWarm = false;

    g_cooldownUntil = 0;
    g_entryATR = 0.0;

    g_dayRealizedPL   = 0.0;
    g_currentDayStart = 0;
    g_dailyLimitHit   = false;

    g_entrySignalP = 0.5; g_lastTickP = 0.5;
    g_lastEntryBarTime = 0; g_prevBarTime = 0;

    ArrayResize(g_atrHist, InpRegimeATRWindow);
    ArrayInitialize(g_atrHist, 0.0);
    g_atrHistIdx = 0; g_atrHistCnt = 0;

    ArrayResize(g_partialTickets, 0);
    g_modifyErrCnt = 0;

    ArrayResize(zones, 0);
    g_paFvgBias = 0; g_paFvgZoneIdx = -1;
    g_lastStructBarTime = 0; g_lastFastBarTime = 0;
    g_entryCounter = 0;

    ArrayResize(g_kalHistPrice, 0);
    ArrayResize(g_kalHistTime, 0);
    g_kalHistCount = 0;

    //--- Restaurar estado persistido (limite diario + cooldown)
    if(InpPersistState)
        LoadPersistedState();

    CreateDashboard();

    PrintFormat("Pure_Fractal_FVG_Fusion_BTCUSD v12.0 initialised | Cuenta=%s (1 unidad = %.3f USD) | Senal=%s | AKF=%s | Entradas=%s | MacroTF=%s",
                g_acctName, g_acctUnit,
                (InpSignalMode == SIG_BALANCED ? "BALANCEADA" : "LEGADO"),
                (InpAKFMode == AKF_INNOV ? "INNOVACION" : "VARTICK"),
                (InpBarConfirmEntry ? "VELA CERRADA" : "INTRABARRA"),
                EnumToString((ENUM_TIMEFRAMES)g_macroTF));
    PrintFormat("[FVG_FUSION] Riesgo/Trade: %.2f USD (%s) | Limite diario: %.2f USD | Lote fijo: %.2f | MaxLot: %.2f | MaxOpen: %d",
                InpRiskPerTradeUSD, (InpLotMode == LOT_MODE_RISK ? "por riesgo" : "fijo"),
                InpMaxDailyLossUSD, InpFixedLotSize, InpMaxLotSize, InpMaxOpenPositions);
    PrintFormat("[FVG_FUSION] Salida: BE=%.2fATR Lock=%.2fATR | TrailBase=%.2f Tighten=%.2f Min=%.2f FloorSpread=x%.2f | Parcial: %s",
                InpBreakevenTriggerATR, InpBreakevenLockATR, InpTrailBaseATR, InpTrailTightenRate, InpTrailMinATR, InpTrailSpreadFloorMult,
                (InpPartialTPEnable ? ("ON " + DoubleToString(InpPartialFactor*100,0) + "% a " + DoubleToString(InpPartialTriggerATR,1) + "ATR") : "OFF"));
    PrintFormat("[FVG_FUSION] Filtros: ZoneProximity=%s | Regimen=%s | Cooldown=%dmin | Session=%s",
                (InpRequireZoneProximity ? "ON" : "OFF"),
                (InpRegimeFilterEnable ? ("ON (ATR>" + DoubleToString(InpRegimeATRMult,2) + "x media de " + IntegerToString(InpRegimeATRWindow) + " v)") : "OFF"),
                InpCooldownMinutes, (InpSessionFilterEnable ? "ON" : "OFF"));

    return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(InpPersistState)
        SavePersistedState();

    if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
    if(g_hATRFVG != INVALID_HANDLE) IndicatorRelease(g_hATRFVG);
    if(g_hMacroEMA != INVALID_HANDLE) IndicatorRelease(g_hMacroEMA);
    ObjectsDeleteAll(0, "TRD_");
    ObjectsDeleteAll(0, "FVGZ_");
    ObjectsDeleteAll(0, "ENTRY_");
    ObjectsDeleteAll(0, "SIGCANDLE_");
    ObjectsDeleteAll(0, "LVL_");
    ObjectsDeleteAll(0, "KALLINE_");
    ObjectsDeleteAll(0, "STRUCT_");
    ObjectsDeleteAll(0, "PATT_");
    ObjectsDeleteAll(0, "DASH_");
}
//+------------------------------------------------------------------+
//  Deteccion de tipo de cuenta
//+------------------------------------------------------------------+
void DetectAccountType()
{
    g_acctUnit = 1.0;
    g_acctName = "STANDARD";

    if(InpAccountType == ACCT_STANDARD) { g_acctUnit = 1.0;   g_acctName = "STANDARD"; return; }
    if(InpAccountType == ACCT_CENT)     { g_acctUnit = 0.01;  g_acctName = "CENT";     return; }
    if(InpAccountType == ACCT_MICRO)    { g_acctUnit = 0.001; g_acctName = "MICRO";    return; }

    //--- AUTO: 1) moneda de la cuenta termina en 'C' -> cent (USC, EUC, GBC, CHC, AUC, CAC...)
    string cur = AccountInfoString(ACCOUNT_CURRENCY);
    bool centByCurrency = false;
    if(StringLen(cur) >= 3)
    {
        string lastC = StringSubstr(cur, StringLen(cur)-1, 1);
        if(lastC == "C")
            centByCurrency = true;
    }

    //--- AUTO: 2) heuristica contrato vs tick value: ratio = contrato*tickSize / tickValue
    //---       Standard ~= 1.0 ; Cent ~= 100 ; Micro ~= 1000
    double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
    double tSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double tValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ratio = 1.0;
    if(tSize > 0.0 && tValue > 0.0)
        ratio = contract * tSize / tValue;

    int heuristic = 1; // 1=standard, 2=cent, 3=micro
    if(ratio >= 500.0) heuristic = 3;
    else if(ratio >= 50.0) heuristic = 2;

    if(centByCurrency && heuristic >= 2) heuristic = 2;

    if(heuristic == 2) { g_acctUnit = 0.01;  g_acctName = "CENT"; }
    else if(heuristic == 3) { g_acctUnit = 0.001; g_acctName = "MICRO"; }
    else { g_acctUnit = 1.0; g_acctName = "STANDARD"; }

    PrintFormat("[FVG_FUSION] Cuenta detectada: %s (moneda=%s, ratio contrato/tick=%.2f, 1 unidad = %.4f USD)",
                g_acctName, cur, ratio, g_acctUnit);
    Print("[FVG_FUSION] Si la deteccion es incorrecta, fija InpAccountType manualmente (1=Standard, 2=Cent, 3=Micro).");
}
//+------------------------------------------------------------------+
//  Persistencia de estado (GlobalVariables)
//+------------------------------------------------------------------+
void SavePersistedState()
{
    GlobalVariableSet(GV_DayStart(), (double)g_currentDayStart);
    GlobalVariableSet(GV_DayPL(),    g_dayRealizedPL);
    GlobalVariableSet(GV_Cooldown(), (double)g_cooldownUntil);
}
void LoadPersistedState()
{
    if(GlobalVariableCheck(GV_Cooldown()))
    {
        datetime cd = (datetime)GlobalVariableGet(GV_Cooldown());
        if(cd > TimeTradeServer())
        {
            g_cooldownUntil = cd;
            PrintFormat("[FVG_FUSION] Cooldown restaurado hasta %s", TimeToString(cd, TIME_DATE | TIME_MINUTES));
        }
    }
    datetime now = TimeTradeServer();
    MqlDateTime dtNow; TimeToStruct(now, dtNow);
    datetime dayStart = now - (dtNow.hour * 3600 + dtNow.min * 60 + dtNow.sec);
    if(GlobalVariableCheck(GV_DayStart()))
    {
        datetime stored = (datetime)GlobalVariableGet(GV_DayStart());
        if(stored == dayStart)
        {
            g_currentDayStart = dayStart;
            g_dayRealizedPL   = GlobalVariableGet(GV_DayPL());
            if(InpDailyLossLimitEnable && g_dayRealizedPL <= -MathAbs(InpMaxDailyLossUSD)/g_acctUnit)
            {
                g_dailyLimitHit = true;
                Print("[FVG_FUSION] Limite diario restaurado (BLoqueo de entradas vigente).");
            }
        }
    }
}
//+------------------------------------------------------------------+
//  OnTick
//+------------------------------------------------------------------+
void OnTick()
{
    if(CopyBuffer(g_hATR, 0, 0, 1, g_bufATR) < 1) return;

    CheckDayRollover();

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double mid = (ask + bid) * 0.5;
    double atr = g_bufATR[0];

    KalmanUpdate(mid);                     // primero (usa g_kR del tick anterior)
    UpdateAdaptiveNoise(mid, ask, bid);    // despues (puede usar la innovacion)
    UpdateMacroFilter();

    double pLongNow = ComputeBiasProbability(mid, atr);
    double pLongAdj = pLongNow;
    if(g_paFvgBias == 1)       pLongAdj = MathMin(0.98, pLongNow + InpConfluenceBoost);
    else if(g_paFvgBias == -1) pLongAdj = MathMax(0.02, pLongNow - InpConfluenceBoost);

    UpdateTradeVisuals();
    CleanupClosedVisuals();
    ManageZoneLifecycle();
    UpdateActiveZoneBoxes();
    UpdateDashboard(pLongAdj, atr, ask - bid);

    datetime curFastBar = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(curFastBar != g_lastFastBarTime)
    {
        g_lastFastBarTime = curFastBar;
        SampleKalmanHistory();
        UpdateMarketStructure();
        TrimOldStructureMarkers();
    }

    //--- Confirmacion de vela: al abrir una vela nueva, congelamos la
    //    probabilidad de la vela que acaba de CERRAR (la calculada en
    //    el tick anterior). La entrada usara ese valor si el modo esta ON.
    if(curFastBar != g_prevBarTime)
    {
        g_prevBarTime = curFastBar;
        g_entrySignalP = g_lastTickP;

        //--- historial ATR para filtro de regimen (una muestra por vela)
        if(InpRegimeFilterEnable && InpRegimeATRWindow > 1)
        {
            g_atrHist[g_atrHistIdx] = atr;
            g_atrHistIdx = (g_atrHistIdx + 1) % InpRegimeATRWindow;
            if(g_atrHistCnt < InpRegimeATRWindow) g_atrHistCnt++;
        }
    }

    datetime curStructBar = iTime(_Symbol, InpFVGTimeframe, 0);
    if(curStructBar != g_lastStructBarTime)
    {
        g_lastStructBarTime = curStructBar;
        DetectNewFVG();
        UpdateLevels();
        UpdatePriceActionFVGBias();
        TrimZones();
        TrimEntryMarkers();
        TrimOldSignalCandles();
        TrimOldPatternMarkers();
    }

    bool canAttemptEntry = (CountPositions() < InpMaxOpenPositions)
                            && !InCooldown()
                            && !(InpDailyLossLimitEnable && g_dailyLimitHit)
                            && !(InpSessionFilterEnable && !IsWithinSession())
                            && BarsSinceEntryOK();

    if(canAttemptEntry)
    {
        //--- Si la confirmacion de vela esta ON, se usa la probabilidad
        //    congelada al cierre de la vela anterior; de lo contrario la
        //    probabilidad intrabarra en vivo.
        double pEntry = InpBarConfirmEntry ? g_entrySignalP : pLongAdj;
        ExecuteBiasedEntry(pEntry, atr, ask, bid);
    }

    if(CountPositions() > 0)
        ManageExitsAndProtection();

    g_lastTickP = pLongAdj;
}
//+------------------------------------------------------------------+
//  OnTradeTransaction
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    ulong dealTicket = trans.deal;
    if(!HistoryDealSelect(dealTicket)) return;

    long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
    if(dealMagic != InpMagicBase) return;

    long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY) return;

    double dealResult = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                       + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                       + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

    if(dealResult < 0.0 && InpCooldownMinutes > 0)
    {
        g_cooldownUntil = TimeTradeServer() + InpCooldownMinutes * 60;
        if(InpPersistState)
            GlobalVariableSet(GV_Cooldown(), (double)g_cooldownUntil);
        PrintFormat("[FVG_FUSION] Anti-Revenge Cooldown activo hasta %s (perdida: %.2f)",
                    TimeToString(g_cooldownUntil, TIME_DATE | TIME_MINUTES), dealResult);
    }

    CheckDayRollover();
    g_dayRealizedPL += dealResult;
    if(InpDailyLossLimitEnable && !g_dailyLimitHit && g_dayRealizedPL <= -MathAbs(InpMaxDailyLossUSD)/g_acctUnit)
    {
        g_dailyLimitHit = true;
        PrintFormat("[FVG_FUSION] CIRCUIT BREAKER DIARIO activado: perdida del dia=%.2f USD (limite %.2f). Entradas bloqueadas hasta el proximo dia.",
                    g_dayRealizedPL * g_acctUnit, InpMaxDailyLossUSD);
    }
    if(InpPersistState)
        GlobalVariableSet(GV_DayPL(), g_dayRealizedPL);
}
//===================================================================
//  Motor Kalman + sesgo macro
//===================================================================
void UpdateAdaptiveNoise(double mid, double ask, double bid)
{
    double Rbase  = MathMax(1e-12, InpKalmanR);
    double spread = ask - bid;

    if(!g_akfInit)
    {
        g_lastMid   = mid;
        g_akfInit   = true;
        g_avgSpread = spread;
        g_kR        = Rbase;
        return;
    }

    g_lastMid = mid;

    if(InpAKFMode == AKF_INNOV)
    {
        g_innovBuf[g_akfBufIdx] = g_lastInnovation;
    }
    else
    {
        g_tickBuf[g_akfBufIdx] = mid - g_lastMid;
    }
    g_spreadBuf[g_akfBufIdx] = spread;
    g_akfBufIdx = (g_akfBufIdx + 1) % g_akfWindow;
    if(g_akfBufCount < g_akfWindow) g_akfBufCount++;

    //--- Spread promedio (rolling) SIEMPRE, para SL/TP conscientes del spread
    double meanSpread = 0.0;
    for(int i = 0; i < g_akfBufCount; i++) meanSpread += g_spreadBuf[i];
    meanSpread /= g_akfBufCount;
    g_avgSpread = meanSpread;

    if(!InpAKF_Enable)      { g_kR = Rbase; return; }
    if(g_akfBufCount < 2)   { g_kR = Rbase; return; }

    if(InpAKFMode == AKF_INNOV)
    {
        //--- Mehra-lite: la varianza empirica de las innovaciones se
        //    aproxima a (P_pred + R). Restamos P_pred y obtenemos R.
        double meanI = 0.0;
        for(int i = 0; i < g_akfBufCount; i++) meanI += g_innovBuf[i];
        meanI /= g_akfBufCount;

        double varI = 0.0;
        for(int i = 0; i < g_akfBufCount; i++)
        {
            double d = g_innovBuf[i] - meanI;
            varI += d * d;
        }
        varI /= g_akfBufCount;

        double Rtarget = varI - g_lastPpred00;
        Rtarget = MathMax(Rbase, Rtarget);
        Rtarget = MathMin(Rbase * 100.0, Rtarget);
        g_kR = 0.85 * g_kR + 0.15 * Rtarget;
        g_kR = MathMax(Rbase, g_kR);
    }
    else
    {
        double meanTick = 0.0;
        for(int i = 0; i < g_akfBufCount; i++) meanTick += g_tickBuf[i];
        meanTick /= g_akfBufCount;

        double varTick = 0.0;
        for(int i = 0; i < g_akfBufCount; i++)
        {
            double d = g_tickBuf[i] - meanTick;
            varTick += d * d;
        }
        varTick /= g_akfBufCount;

        double spreadRatio     = (meanSpread > 0.0) ? (spread / meanSpread) : 1.0;
        double spreadAmplifier = MathMax(1.0, spreadRatio);
        double sigmaTickSqEff  = varTick * spreadAmplifier;

        g_kR = MathMax(1e-12, Rbase * (1.0 + InpAKF_Alpha * sigmaTickSqEff));
    }
}

void KalmanUpdate(double mid)
{
    ulong  nowUs = GetMicrosecondCount();
    double dt;
    if(!g_kInit || g_lastTickUs == 0)
    {
        dt = InpKalmanDtFallback;
        g_smoothedDt = dt;
    }
    else
    {
        double rawDt = (double)(nowUs - g_lastTickUs) * 1e-6;
        dt = MathMax(InpKalmanMinDt, MathMin(60.0, rawDt));
        g_smoothedDt = g_smoothedDt + InpDtSmoothingAlpha * (dt - g_smoothedDt);
    }
    g_lastTickUs = nowUs;
    g_lastTickDt = dt;

    if(!g_kInit)
    {
        g_kxP = mid; g_kxV = 0.0; g_prevVelocity = 0.0; g_kInit = true;
        return;
    }

    g_prevVelocity = g_kxV;

    double xp0 = g_kxP + dt * g_kxV;
    double xp1 = g_kxV;

    double t00 = g_kP00 + dt * g_kP10;
    double t01 = g_kP01 + dt * g_kP11;
    double t10 = g_kP10;
    double t11 = g_kP11;

    double pp00 = t00 + t01 * dt + g_kQpos;
    double pp01 = t01;
    double pp10 = t10 + t11 * dt;
    double pp11 = t11 + g_kQvel;
    g_lastPpred00 = pp00;

    double y = mid - xp0;
    g_lastInnovation = y;
    double S = pp00 + g_kR;

    if(S < 1e-12)
    {
        g_kxP = xp0; g_kxV = xp1;
        g_kP00 = pp00 + g_kQpos; g_kP01 = pp01;
        g_kP10 = pp10; g_kP11 = pp11 + g_kQvel;
        return;
    }

    double K0 = pp00 / S;
    double K1 = pp10 / S;

    g_kxP = xp0 + K0 * y;
    g_kxV = xp1 + K1 * y;

    g_kP00 = MathMax((1.0 - K0) * pp00, 1e-12);
    g_kP01 =         (1.0 - K0) * pp01;
    g_kP10 = pp10 - K1 * pp00;
    g_kP11 = MathMax(pp11 - K1 * pp01, 1e-12);
}

void UpdateMacroFilter()
{
    if(!InpMacroBiasEnable) return;

    datetime curBarTime = iTime(_Symbol, (ENUM_TIMEFRAMES)g_macroTF, 0);
    if(curBarTime == g_lastMacroBarTime) return;
    g_lastMacroBarTime = curBarTime;

    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(g_hMacroEMA, 0, 0, 1, buf) < 1) return;
    double ema1 = buf[0];

    if(!g_macroInit)
    {
        g_tema_ema2 = ema1; g_tema_ema3 = ema1; g_macroInit = true;
    }
    else
    {
        double alpha = 2.0 / (InpMacroPeriod + 1.0);
        g_tema_ema2 += alpha * (ema1 - g_tema_ema2);
        g_tema_ema3 += alpha * (g_tema_ema2 - g_tema_ema3);
    }

    g_macroEMA  = ema1;
    g_macroTEMA = 3.0 * ema1 - 3.0 * g_tema_ema2 + g_tema_ema3;
}

double GetMacroFilterValue()
{
    return (InpMacroMode == MACRO_MODE_TEMA) ? g_macroTEMA : g_macroEMA;
}

double ComputeBiasProbability(double mid, double atr)
{
    if(atr <= 0.0 || !g_kInit) return 0.5;

    double arg = 0.0;

    if(InpSignalMode == SIG_BALANCED)
    {
        //--- Modo balanceado (v11/v12): terminos normalizados por
        //    barra y por su propia magnitud tipica (z-score EWMA).
        //    v: ATR por barra | D: ATR | a: ATR por barra^2 (clamp)
        double barSec = PeriodSeconds(_Period);

        double vNorm = g_kxV * barSec / atr;
        double dNorm = (mid - g_kxP) / atr;

        double aNorm = 0.0;
        if(g_smoothedDt > 1e-6)
        {
            aNorm = ((g_kxV - g_prevVelocity) / g_smoothedDt) * barSec * barSec / atr;
            aNorm = MathMax(-InpMaxAccelHatAbs, MathMin(InpMaxAccelHatAbs, aNorm));
        }

        //--- EWMA de magnitud tipica de cada termino (z-score)
        double alpha = 0.005;
        if(!g_sigWarm)
        {
            g_sigEVel = MathAbs(vNorm); g_sigEDis = MathAbs(dNorm); g_sigEAcc = MathAbs(aNorm);
            g_sigWarm = true;
        }
        else
        {
            g_sigEVel += alpha * (MathAbs(vNorm) - g_sigEVel);
            g_sigEDis += alpha * (MathAbs(dNorm) - g_sigEDis);
            g_sigEAcc += alpha * (MathAbs(aNorm) - g_sigEAcc);
        }

        double eps = 1e-6;
        double vZ = (g_sigEVel > eps) ? (vNorm / g_sigEVel) : 0.0;
        double dZ = (g_sigEDis > eps) ? (dNorm / g_sigEDis) : 0.0;
        double aZ = (g_sigEAcc > eps) ? (aNorm / g_sigEAcc) : 0.0;

        arg = InpVelocitySens * vZ + InpDisplacementW * dZ + InpAccelerationW * aZ;
    }
    else
    {
        //--- Modo legado v10.12 (para comparacion A/B)
        double v_hat = g_kxV / atr;
        double D = (mid - g_kxP) / atr;

        double a_hat = 0.0;
        if(g_smoothedDt > 1e-6)
        {
            double a_k = (g_kxV - g_prevVelocity) / g_smoothedDt;
            a_hat = a_k / atr;
            a_hat = MathMax(-InpMaxAccelHatAbs, MathMin(InpMaxAccelHatAbs, a_hat));
        }

        arg = InpVelocitySens * v_hat + InpDisplacementW * D + InpAccelerationW * a_hat;
    }

    arg = MathMax(-20.0, MathMin(20.0, arg));
    double pLong = 1.0 / (1.0 + MathExp(-arg));

    if(InpMacroBiasEnable && g_macroInit)
    {
        double macroRef = GetMacroFilterValue();
        if(pLong >= 0.5 && g_kxP < macroRef)
        {
            pLong = pLong * InpMacroPenaltyGamma;
        }
        else if(pLong < 0.5 && g_kxP > macroRef)
        {
            double pShort = 1.0 - pLong;
            pShort = pShort * InpMacroPenaltyGamma;
            pLong  = 1.0 - pShort;
        }
    }

    return pLong;
}

//===================================================================
//  Patrones de velas (accion del precio)
//===================================================================
bool IsBullishEngulfing(const MqlRates &r[], int i)
  {
   bool prevBear = r[i+1].close < r[i+1].open;
   bool currBull = r[i].close > r[i].open;
   bool engulf   = r[i].open <= r[i+1].close && r[i].close >= r[i+1].open;
   return(prevBear && currBull && engulf);
  }
bool IsBearishEngulfing(const MqlRates &r[], int i)
  {
   bool prevBull = r[i+1].close > r[i+1].open;
   bool currBear = r[i].close < r[i].open;
   bool engulf   = r[i].open >= r[i+1].close && r[i].close <= r[i+1].open;
   return(prevBull && currBear && engulf);
  }
bool IsBullishPinBar(const MqlRates &r[], int i)
  {
   double range = r[i].high - r[i].low;
   if(range <= 0) return(false);
   double body      = MathAbs(r[i].close - r[i].open);
   double lowerWick = MathMin(r[i].open, r[i].close) - r[i].low;
   double upperWick = r[i].high - MathMax(r[i].open, r[i].close);
   return(body <= range*0.35 && lowerWick >= range*0.55 && upperWick <= range*0.20);
  }
bool IsBearishPinBar(const MqlRates &r[], int i)
  {
   double range = r[i].high - r[i].low;
   if(range <= 0) return(false);
   double body      = MathAbs(r[i].close - r[i].open);
   double upperWick = r[i].high - MathMax(r[i].open, r[i].close);
   double lowerWick = MathMin(r[i].open, r[i].close) - r[i].low;
   return(body <= range*0.35 && upperWick >= range*0.55 && lowerWick <= range*0.20);
  }
//===================================================================
//  Zonas FVG: creacion, dibujo y ciclo de vida
//===================================================================
void DrawFVGBox(int idx)
  {
   datetime t1 = zones[idx].time;
   datetime t2 = t1 + PeriodSeconds(InpFVGTimeframe) * InpZoneExtendBars;
   color clr = (zones[idx].type == 1) ? InpColorBullFVG : InpColorBearFVG;
   string name = "FVGZ_" + IntegerToString(idx) + "_" + IntegerToString((int)t1);
   zones[idx].objName = name;

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, zones[idx].bottom, t2, zones[idx].top);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }

   if(InpShowLabels)
     {
      string lbl = name + "_lbl";
      string txt = (zones[idx].type==1 ? "FVG Soporte " : "FVG Resistencia ") +
                   DoubleToString(zones[idx].bottom,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS)) + "-" +
                   DoubleToString(zones[idx].top,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
      if(ObjectFind(0, lbl) < 0)
        {
         ObjectCreate(0, lbl, OBJ_TEXT, 0, t1, zones[idx].type==1 ? zones[idx].bottom : zones[idx].top);
         ObjectSetInteger(0, lbl, OBJPROP_COLOR, clr);
         ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 7);
         ObjectSetString(0, lbl, OBJPROP_FONT, "Arial");
         ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_LEFT);
         ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, lbl, OBJPROP_HIDDEN, true);
         ObjectSetString(0, lbl, OBJPROP_TEXT, txt);
        }
     }
  }
void ExpireZone(int i)
  {
   if(zones[i].objName != "")
     {
      ObjectDelete(0, zones[i].objName);
      ObjectDelete(0, zones[i].objName + "_lbl");
     }
   zones[i].active = false;
  }
void MarkZoneConsumed(int i)
  {
   zones[i].active = false;
  }
int CountActiveZones()
  {
   int cnt = 0;
   for(int i = 0; i < ArraySize(zones); i++)
      if(zones[i].active) cnt++;
   return(cnt);
  }
void AddZone(double bottom, double top, datetime t, int type)
  {
   if(CountActiveZones() >= InpMaxActiveZones) return;

   int n = ArraySize(zones);
   ArrayResize(zones, n+1);
   zones[n].top = top; zones[n].bottom = bottom; zones[n].time = t;
   zones[n].type = type; zones[n].active = true; zones[n].objName = "";

   DrawFVGBox(n);
  }
void TrimZones()
  {
   int total = ArraySize(zones);
   if(total <= InpMaxActiveZones*3) return;

   FVGZone tmp[];
   int cnt = 0;
   for(int i = 0; i < total; i++) if(zones[i].active) cnt++;

   ArrayResize(tmp, cnt);
   int idx = 0;
   for(int i = 0; i < total; i++)
      if(zones[i].active) { tmp[idx] = zones[i]; idx++; }

   ArrayResize(zones, cnt);
   for(int i = 0; i < cnt; i++) zones[i] = tmp[i];
  }
void DetectNewFVG()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpFVGTimeframe, 0, 4, r) < 4) return;

   double atrFVG = 0.0;
   double bufFVG[];
   ArraySetAsSeries(bufFVG, true);
   if(CopyBuffer(g_hATRFVG, 0, 0, 1, bufFVG) < 1) return;
   atrFVG = bufFVG[0];
   if(atrFVG <= 0) return;
   double minGap = atrFVG * InpMinGapATR;

   if(r[3].high < r[1].low && (r[1].low - r[3].high) >= minGap)
      AddZone(r[3].high, r[1].low, r[1].time, 1);

   if(r[3].low > r[1].high && (r[3].low - r[1].high) >= minGap)
      AddZone(r[1].high, r[3].low, r[1].time, -1);
  }
void UpdateActiveZoneBoxes()
  {
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(zones); i++)
     {
      if(!zones[i].active || zones[i].objName == "") continue;
      ObjectMove(0, zones[i].objName, 1, now, zones[i].top);
     }
  }
void ManageZoneLifecycle()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = g_bufATR[0];
   if(atr <= 0) return;

   for(int i = ArraySize(zones)-1; i >= 0; i--)
     {
      if(!zones[i].active) continue;

      if(TimeCurrent() - zones[i].time > PeriodSeconds(InpFVGTimeframe) * InpMaxZoneAgeBars)
        {
         ExpireZone(i);
         continue;
        }

      if(zones[i].type == 1 && bid < zones[i].bottom - atr*InpZoneInvalidateATR)
         ExpireZone(i);
      else
        if(zones[i].type == -1 && ask > zones[i].top + atr*InpZoneInvalidateATR)
           ExpireZone(i);
     }
  }
//===================================================================
//  Niveles de estructura
//===================================================================
void DrawLevelLine(string name, datetime t1, datetime t2, double price, string text)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpColorLevels);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
   else
     {
      ObjectMove(0, name, 0, t1, price);
      ObjectMove(0, name, 1, t2, price);
     }

   if(!InpShowLabels) return;
   string lbl = name + "_lbl";
   if(ObjectFind(0, lbl) < 0)
     {
      ObjectCreate(0, lbl, OBJ_TEXT, 0, t2, price);
      ObjectSetInteger(0, lbl, OBJPROP_COLOR, InpColorLevels);
      ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 7);
      ObjectSetString(0, lbl, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_RIGHT);
      ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lbl, OBJPROP_HIDDEN, true);
     }
   else
      ObjectMove(0, lbl, 0, t2, price);
   ObjectSetString(0, lbl, OBJPROP_TEXT, text);
  }
void UpdateLevels()
  {
   int need = InpLookbackBars + 1;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpFVGTimeframe, 0, need, r) < need) return;

   double hi = r[1].high, lo = r[1].low;
   for(int k = 1; k < need; k++)
     {
      if(r[k].high > hi) hi = r[k].high;
      if(r[k].low  < lo) lo = r[k].low;
     }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   datetime t1 = r[need-1].time;
   datetime t2 = TimeCurrent() + PeriodSeconds(InpFVGTimeframe) * InpBoxExtendBars;

   DrawLevelLine("LVL_Res", t1, t2, hi, "Resistencia " + DoubleToString(hi, digits));
   DrawLevelLine("LVL_Sop", t1, t2, lo, "Soporte " + DoubleToString(lo, digits));
  }
//===================================================================
//  Sesgo de confluencia PA + FVG
//===================================================================
void DrawPatternMarker(datetime t, double price, bool isBull)
  {
   string name = "PATT_" + (isBull?"B_":"S_") + IntegerToString((int)t);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, isBull ? OBJ_ARROW_UP : OBJ_ARROW_DOWN, 0, t, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrSilver);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }
void TrimOldPatternMarkers()
  {
   datetime cutoff = TimeCurrent() - PeriodSeconds(InpFVGTimeframe) * InpMaxZoneAgeBars;
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total-1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, "PATT_") != 0) continue;
      string rest = StringSubstr(name, 7);
      datetime ot = (datetime)StringToInteger(StringSubstr(rest, 2));
      if(ot > 0 && ot < cutoff) ObjectDelete(0, name);
     }
  }
void UpdatePriceActionFVGBias()
  {
   g_paFvgBias = 0;
   g_paFvgZoneIdx = -1;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpFVGTimeframe, 0, 5, r) < 5) return;

   double atr = g_bufATR[0];
   if(atr <= 0) return;
   double tol = atr * InpZoneToleranceATR;

   bool bullPattern = IsBullishEngulfing(r,1) || IsBullishPinBar(r,1);
   bool bearPattern = IsBearishEngulfing(r,1) || IsBearishPinBar(r,1);

   if(InpShowAllPatterns)
     {
      if(bullPattern) DrawPatternMarker(r[1].time, r[1].low, true);
      if(bearPattern) DrawPatternMarker(r[1].time, r[1].high, false);
     }

   g_paFvgBarTime    = r[1].time;
   g_paFvgCandleHigh = r[1].high;
   g_paFvgCandleLow  = r[1].low;

   if(bullPattern)
     {
      for(int i = 0; i < ArraySize(zones); i++)
        {
         if(!zones[i].active || zones[i].type != 1) continue;
         bool overlap = (r[1].low <= zones[i].top + tol) && (r[1].low >= zones[i].bottom - tol);
         if(overlap) { g_paFvgBias = 1; g_paFvgZoneIdx = i; break; }
        }
     }
   else if(bearPattern)
     {
      for(int i = 0; i < ArraySize(zones); i++)
        {
         if(!zones[i].active || zones[i].type != -1) continue;
         bool overlap = (r[1].high >= zones[i].bottom - tol) && (r[1].high <= zones[i].top + tol);
         if(overlap) { g_paFvgBias = -1; g_paFvgZoneIdx = i; break; }
        }
     }
  }
//===================================================================
//  VISUAL: linea del precio filtrado por Kalman
//===================================================================
void SampleKalmanHistory()
  {
   if(ArraySize(g_kalHistPrice) < KAL_HISTORY_MAX)
     {
      ArrayResize(g_kalHistPrice, KAL_HISTORY_MAX);
      ArrayResize(g_kalHistTime, KAL_HISTORY_MAX);
     }

   if(g_kalHistCount >= KAL_HISTORY_MAX)
     {
      for(int i = 0; i < KAL_HISTORY_MAX-1; i++)
        {
         g_kalHistPrice[i] = g_kalHistPrice[i+1];
         g_kalHistTime[i]  = g_kalHistTime[i+1];
        }
      g_kalHistCount = KAL_HISTORY_MAX-1;
     }
   g_kalHistPrice[g_kalHistCount] = g_kxP;
   g_kalHistTime[g_kalHistCount]  = TimeCurrent();
   g_kalHistCount++;

   DrawKalmanLine();
  }
void DrawKalmanLine()
  {
   if(!InpShowKalmanLine) return;
   for(int i = 0; i < g_kalHistCount-1; i++)
     {
      string name = "KALLINE_" + IntegerToString(i);
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_TREND, 0, g_kalHistTime[i], g_kalHistPrice[i], g_kalHistTime[i+1], g_kalHistPrice[i+1]);
         ObjectSetInteger(0, name, OBJPROP_COLOR, InpColorKalmanLine);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
         ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, name, OBJPROP_BACK, false);
        }
      else
        {
         ObjectMove(0, name, 0, g_kalHistTime[i], g_kalHistPrice[i]);
         ObjectMove(0, name, 1, g_kalHistTime[i+1], g_kalHistPrice[i+1]);
        }
     }
  }
//===================================================================
//  VISUAL: estructura de mercado (fractales de 5 velas)
//===================================================================
void DrawFractal(datetime t, double price, bool isHigh)
  {
   string name = "STRUCT_" + (isHigh?"H_":"L_") + IntegerToString((int)t);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, isHigh ? OBJ_ARROW_DOWN : OBJ_ARROW_UP, 0, t, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpColorStructure);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }
void UpdateMarketStructure()
  {
   if(!InpShowStructure) return;

   int need = InpLookbackBars + 4;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, need, r) < need) return;

   for(int i = 2; i < need-2; i++)
     {
      bool fractalHigh = r[i].high > r[i-1].high && r[i].high > r[i-2].high &&
                         r[i].high > r[i+1].high && r[i].high > r[i+2].high;
      bool fractalLow  = r[i].low  < r[i-1].low  && r[i].low  < r[i-2].low  &&
                         r[i].low  < r[i+1].low  && r[i].low  < r[i+2].low;

      if(fractalHigh) DrawFractal(r[i].time, r[i].high, true);
      if(fractalLow)  DrawFractal(r[i].time, r[i].low, false);
     }
  }
void TrimOldStructureMarkers()
  {
   datetime cutoff = TimeCurrent() - PeriodSeconds(PERIOD_CURRENT) * (InpLookbackBars + 10);
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total-1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, "STRUCT_") != 0) continue;
      string rest = StringSubstr(name, 7);
      datetime ot = (datetime)StringToInteger(StringSubstr(rest, 2));
      if(ot > 0 && ot < cutoff) ObjectDelete(0, name);
     }
  }
//===================================================================
//  VISUAL: panel de estado en vivo
//===================================================================
void CreateDashboard()
  {
   if(!InpShowDashboard) return;

   if(ObjectFind(0, "DASH_BG") < 0)
     {
      ObjectCreate(0, "DASH_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_XSIZE, 250);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_YSIZE, 190);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_BGCOLOR, C'20,20,25');
      ObjectSetInteger(0, "DASH_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_COLOR, clrGray);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_BACK, false);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
     }

   string labels[9] = {"DASH_Title","DASH_Acct","DASH_State","DASH_Prob","DASH_ATR","DASH_Spread","DASH_Zones","DASH_Risk","DASH_Signal"};
   for(int i = 0; i < 9; i++)
     {
      if(ObjectFind(0, labels[i]) < 0)
        {
         ObjectCreate(0, labels[i], OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, labels[i], OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, labels[i], OBJPROP_XDISTANCE, 20);
         ObjectSetInteger(0, labels[i], OBJPROP_YDISTANCE, 28 + i*16);
         ObjectSetInteger(0, labels[i], OBJPROP_COLOR, clrWhite);
         ObjectSetInteger(0, labels[i], OBJPROP_FONTSIZE, 8);
         ObjectSetString(0, labels[i], OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, labels[i], OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, labels[i], OBJPROP_HIDDEN, true);
        }
     }
   ObjectSetString(0, "DASH_Title", OBJPROP_TEXT, "Pure_Fractal FVG Fusion v12.0 BTC");
   ObjectSetInteger(0, "DASH_Title", OBJPROP_COLOR, clrDodgerBlue);
  }
void UpdateDashboard(double pLong, double atr, double spread)
  {
   if(!InpShowDashboard) return;

   string state = (CountPositions() > 0) ? "En posicion" : "Plano";
   if(InCooldown()) state += " | Cooldown";
   if(InpSessionFilterEnable && !IsWithinSession()) state += " | Fuera de sesion";
   if(InpDailyLossLimitEnable && g_dailyLimitHit) state += " | LIMITE DIARIO";

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   ObjectSetString(0, "DASH_Acct",   OBJPROP_TEXT, StringFormat("Cuenta: %s (1u=%.4f USD) | Senal: %s", g_acctName, g_acctUnit,
                   (InpSignalMode == SIG_BALANCED ? "BAL" : "LEG")));
   ObjectSetString(0, "DASH_State",  OBJPROP_TEXT, "Estado: " + state);
   ObjectSetString(0, "DASH_Prob",   OBJPROP_TEXT, StringFormat("P(Long): %.1f%% (umbral %.0f%%)", pLong*100, InpBiasThreshold*100));
   ObjectSetString(0, "DASH_ATR",    OBJPROP_TEXT, "ATR: " + DoubleToString(atr, digits));
   ObjectSetString(0, "DASH_Spread", OBJPROP_TEXT, StringFormat("Spread: %s (avg %s, max %.0f%% ATR)", DoubleToString(spread,digits), DoubleToString(g_avgSpread,digits), InpMaxSpreadATR*100));
   ObjectSetString(0, "DASH_Zones",  OBJPROP_TEXT, StringFormat("Zonas FVG: %d | Lote: %s", CountActiveZones(),
                   (InpLotMode == LOT_MODE_FIXED) ? DoubleToString(InpFixedLotSize,2) + " fijo" : "por riesgo"));
   ObjectSetString(0, "DASH_Risk",   OBJPROP_TEXT, StringFormat("PL dia: %.2f USD (limite %.2f)", g_dayRealizedPL*g_acctUnit,
                   InpDailyLossLimitEnable ? InpMaxDailyLossUSD : 0.0));
   ObjectSetString(0, "DASH_Signal", OBJPROP_TEXT, StringFormat("AKF:%s | Entry:%s | R:%.3f",
                   (InpAKFMode == AKF_INNOV ? "Inn" : "VarT"), (InpBarConfirmEntry ? "Vela" : "Tick"), g_kR));
  }
//===================================================================
//  Marcadores de entrada y vela de senal
//===================================================================
void DrawEntryMarker(int direction, double price, string text)
  {
   g_entryCounter++;
   string name = "ENTRY_" + IntegerToString(g_entryCounter) + "_" + (string)direction;
   datetime t = TimeCurrent();
   double offset = g_bufATR[0] * 0.3;
   double arrowPrice = (direction == 1) ? price - offset : price + offset;
   color clr = (direction == 1) ? InpColorBuyArrow : InpColorSellArrow;

   ObjectCreate(0, name, (direction==1) ? OBJ_ARROW_UP : OBJ_ARROW_DOWN, 0, t, arrowPrice);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);

   if(!InpShowLabels) return;
   string lbl = name + "_lbl";
   ObjectCreate(0, lbl, OBJ_TEXT, 0, t, arrowPrice);
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, lbl, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, (direction==1) ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, lbl, OBJPROP_HIDDEN, true);
   ObjectSetString(0, lbl, OBJPROP_TEXT, text);
  }
void HighlightSignalCandle(datetime t, double high, double low, bool isBull)
  {
   string name = "SIGCANDLE_" + IntegerToString((int)t);
   datetime t2 = t + PeriodSeconds(InpFVGTimeframe);
   color clr = isBull ? InpColorBuyArrow : InpColorSellArrow;

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t, high, t2, low);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_FILL, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }
void TrimEntryMarkers()
  {
   int maxKeep = 100;
   if(g_entryCounter <= maxKeep) return;
   int cutoff = g_entryCounter - maxKeep;

   int total = ObjectsTotal(0, 0, -1);
   for(int i = total-1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, "ENTRY_") != 0) continue;
      string rest = StringSubstr(name, 6);
      int p = StringFind(rest, "_");
      if(p <= 0) continue;
      int num = (int)StringToInteger(StringSubstr(rest, 0, p));
      if(num > 0 && num <= cutoff)
        {
         ObjectDelete(0, name);
         ObjectDelete(0, name + "_lbl");
        }
     }
  }
void TrimOldSignalCandles()
  {
   datetime cutoff = TimeCurrent() - PeriodSeconds(InpFVGTimeframe) * InpMaxZoneAgeBars;
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total-1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, "SIGCANDLE_") != 0) continue;
      string rest = StringSubstr(name, 10);
      datetime ot = (datetime)StringToInteger(rest);
      if(ot > 0 && ot < cutoff)
         ObjectDelete(0, name);
     }
  }
//===================================================================
//  Filtro de spread, SL/TP adaptativos al spread, y sizing de lote
//===================================================================
bool SpreadOK(double atr)
  {
   if(InpMaxSpreadATR <= 0.0) return true;
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return(spread <= atr * InpMaxSpreadATR);
  }
double GetMinStopDistPrice()
  {
   //--- distancia minima SL/TP que exige el broker (puntos) en precio
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stopsLevel * _Point;
   return minDist;
  }
double SanitizeSL(double price, double sl, bool isBuy, double atr)
  {
   //--- valida que el SL respete: piso de spread + stop level del broker
   double floor = MathMax(g_avgSpread * InpSLSpreadBufferMult, GetMinStopDistPrice());
   double dist = isBuy ? (price - sl) : (sl - price);
   if(dist < floor)
     {
      if(isBuy) sl = price - floor;
      else      sl = price + floor;
      PrintFormat("[FVG_FUSION] SL ajustado a piso (%s): %.5f", (dist < GetMinStopDistPrice() ? "stop level broker" : "spread"), sl);
     }
   return sl;
  }
double SanitizeTP(double price, double tp, bool isBuy, double atr)
  {
   double floor = MathMax(g_avgSpread * InpSLSpreadBufferMult, GetMinStopDistPrice());
   double dist = isBuy ? (tp - price) : (price - tp);
   if(dist < floor)
     {
      if(isBuy) tp = price + floor;
      else      tp = price - floor;
     }
   return tp;
  }
void ComputeAdaptiveSLTP(double atr, double &slDist, double &tpDist)
  {
   double baseSL = atr * InpSLMultiplier;
   double baseTP = atr * InpTPMultiplier;

   double spreadFloor = MathMax(0.0, g_avgSpread) * MathMax(0.0, InpSLSpreadBufferMult);
   slDist = MathMax(baseSL, spreadFloor);
   tpDist = baseTP;

   if(g_avgSpread > 1e-12)
     {
      double curSpread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ratio = curSpread / g_avgSpread;
      if(ratio > InpSpreadSpikeThreshold)
        {
         double widenFactor = MathMin(InpMaxSLSpreadExpansion, ratio / InpSpreadSpikeThreshold);
         slDist *= widenFactor;
         tpDist *= widenFactor;
        }
     }
  }
double NormalizeVolumeForRisk(double vol)
  {
   double brokerMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double brokerMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepVol <= 0.0) stepVol = (brokerMin > 0.0) ? brokerMin : 0.01;

   double steps      = MathFloor(vol / stepVol + 1e-8);
   double normalized = steps * stepVol;

   double lo = brokerMin;
   double hi = MathMin(brokerMax, InpMaxLotSize);
   if(normalized < lo) normalized = lo;
   if(normalized > hi) normalized = hi;

   int stepDigits = 2;
   if(stepVol >= 0.09999) stepDigits = 1;
   if(stepVol >= 0.9999)  stepDigits = 0;
   return NormalizeDouble(normalized, stepDigits);
  }
double CalcLotSizeForRisk(double slDistance)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || tickValue <= 0.0 || slDistance <= 0.0)
      return NormalizeVolumeForRisk(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

   //--- riesgo en unidades de cuenta (el tick value ya viene en unidades de
   //    cuenta, asi que el calculo es directo y sirve para Cent y Standard)
   double riskAcct = InpRiskPerTradeUSD / g_acctUnit;
   double moneyPerPriceUnit = tickValue / tickSize;
   double lots = riskAcct / (slDistance * moneyPerPriceUnit);
   return NormalizeVolumeForRisk(lots);
  }
double GetTradeLotSize(double slDistance)
  {
   if(InpLotMode == LOT_MODE_FIXED)
      return NormalizeVolumeForRisk(InpFixedLotSize);

   return CalcLotSizeForRisk(slDistance);
  }
//===================================================================
//  Filtros de confluencia y regimen
//===================================================================
bool NearActiveZone(int dir, double price)
  {
   if(!InpRequireZoneProximity) return true;
   double atr = g_bufATR[0];
   if(atr <= 0) return false;
   double tol = atr * InpZoneToleranceATR;

   for(int i = 0; i < ArraySize(zones); i++)
     {
      if(!zones[i].active || zones[i].type != dir) continue;
      if(price >= zones[i].bottom - tol && price <= zones[i].top + tol)
         return true;
     }
   return false;
  }
bool RegimeOK()
  {
   if(!InpRegimeFilterEnable) return true;
   if(g_atrHistCnt < MathMin(20, InpRegimeATRWindow)) return true; // aun calentando

   double sum = 0.0;
   for(int i = 0; i < g_atrHistCnt; i++) sum += g_atrHist[i];
   double meanATR = sum / g_atrHistCnt;
   if(meanATR <= 0) return true;

   double atr = g_bufATR[0];
   return (atr >= meanATR * InpRegimeATRMult);
  }
bool BarsSinceEntryOK()
  {
   if(g_lastEntryBarTime <= 0) return true;
   int bars = iBarShift(_Symbol, PERIOD_CURRENT, g_lastEntryBarTime, false);
   if(bars < 0) return true;
   return (bars >= InpMinBarsBetweenEntries);
  }
//===================================================================
//  Entrada: Kalman + confluencia PA+FVG, SL/TP adaptativos al spread
//===================================================================
void ExecuteBiasedEntry(double pLong, double atr, double ask, double bid)
  {
   if(atr <= 0.0) return;
   if(!SpreadOK(atr)) return;
   if(!RegimeOK()) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool usedConfluence = (g_paFvgBias != 0);

   double pShort = 1.0 - pLong;
   bool goLong;
   if(pLong >= InpBiasThreshold)       goLong = true;
   else if(pShort >= InpBiasThreshold) goLong = false;
   else return;

   //--- Filtro opcional: el precio debe estar cerca de una zona FVG activa
   if(InpRequireZoneProximity)
     {
      double entryPrice = goLong ? ask : bid;
      if(!NearActiveZone(goLong ? 1 : -1, entryPrice))
         return;
     }

   double slDistance = 0.0, tpDistance = 0.0;
   ComputeAdaptiveSLTP(atr, slDistance, tpDistance);

   double lots = GetTradeLotSize(slDistance);
   if(lots <= 0.0) return;

   bool sent = false;
   double entryPrice = 0.0;
   if(goLong)
     {
      double sl = SanitizeSL(ask, NormalizeDouble(ask - slDistance, digits), true, atr);
      double tp = SanitizeTP(ask, NormalizeDouble(ask + tpDistance, digits), true, atr);
      sent = trade.Buy(lots, _Symbol, ask, sl, tp, usedConfluence ? "KF12+FVG Buy" : "KF12 Buy");
      entryPrice = ask;
     }
   else
     {
      double sl = SanitizeSL(bid, NormalizeDouble(bid + slDistance, digits), false, atr);
      double tp = SanitizeTP(bid, NormalizeDouble(bid - tpDistance, digits), false, atr);
      sent = trade.Sell(lots, _Symbol, bid, sl, tp, usedConfluence ? "KF12+FVG Sell" : "KF12 Sell");
      entryPrice = bid;
     }

   if(sent)
     {
      g_entryATR = atr;
      g_lastEntryBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

      if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
        {
         PrintFormat("[FVG_FUSION] Entrada enviada pero retcode=%s (%d)", trade.ResultRetcodeDescription(), trade.ResultRetcode());
        }

      DrawEntryMarker(goLong ? 1 : -1, entryPrice,
                      usedConfluence ? (goLong ? "COMPRA: Kalman+FVG/PA" : "VENTA: Kalman+FVG/PA")
                                     : (goLong ? "COMPRA: Kalman" : "VENTA: Kalman"));

      if(usedConfluence && g_paFvgZoneIdx >= 0 && g_paFvgZoneIdx < ArraySize(zones))
        {
         MarkZoneConsumed(g_paFvgZoneIdx);
         HighlightSignalCandle(g_paFvgBarTime, g_paFvgCandleHigh, g_paFvgCandleLow, goLong);
        }
      g_paFvgBias = 0;
     }
   else
     {
      if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
         PrintFormat("[FVG_FUSION] Entrada RECHAZADA: %s (%d)", trade.ResultRetcodeDescription(), trade.ResultRetcode());
     }
  }
//===================================================================
int CountPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicBase)
         count++;
   return count;
  }
//---------------------------------------------------------------------
//  Parciales: cerrar una fraccion al alcanzar X ATR a favor
//---------------------------------------------------------------------
bool PartialDone(ulong ticket)
  {
   for(int i = 0; i < ArraySize(g_partialTickets); i++)
      if(g_partialTickets[i] == ticket) return true;
   return false;
  }
void MarkPartialDone(ulong ticket)
  {
   int n = ArraySize(g_partialTickets);
   ArrayResize(g_partialTickets, n+1);
   g_partialTickets[n] = ticket;
  }
void CleanupPartialTickets()
  {
   for(int i = ArraySize(g_partialTickets)-1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_partialTickets[i]))
        {
         g_partialTickets[i] = g_partialTickets[ArraySize(g_partialTickets)-1];
         ArrayResize(g_partialTickets, ArraySize(g_partialTickets)-1);
        }
     }
  }
bool TryPartialTP(ulong ticket, double vol, double favorable)
  {
   if(!InpPartialTPEnable) return false;
   if(vol <= 0.0) return false;
   if(PartialDone(ticket)) return false;

   double atr = g_bufATR[0];
   if(atr <= 0) return false;
   if(favorable < atr * InpPartialTriggerATR) return false;

   double partialVol = NormalizeVolumeForRisk(vol * InpPartialFactor);
   if(partialVol <= 0.0) return false;
   if(partialVol >= vol) return false;

   if(trade.PositionClosePartial(ticket, partialVol))
     {
      MarkPartialDone(ticket);
      PrintFormat("[FVG_FUSION] Parcial cerrado: %.2f de %.2f lotes (%.2f ATR a favor).",
                  partialVol, vol, favorable / atr);
      return true;
     }
   else
      PrintFormat("[FVG_FUSION] Parcial FALLIDO: %s (%d)", trade.ResultRetcodeDescription(), trade.ResultRetcode());
   return false;
  }
//---------------------------------------------------------------------
//  CheckVolatilityTimeStop
//---------------------------------------------------------------------
bool CheckVolatilityTimeStop(ulong ticket, double atrNow, double openPrice, double sl, long posType, datetime posOpenTime)
  {
   if(!InpVolTimeStopEnable) return false;
   if(g_entryATR <= 0.0)     return false;

   if(posType == POSITION_TYPE_BUY  && sl >= openPrice)             return false;
   if(posType == POSITION_TYPE_SELL && sl > 0.0 && sl <= openPrice) return false;

   int barsElapsed = iBarShift(_Symbol, InpVolTimeStopBarTF, posOpenTime, false);
   if(barsElapsed < InpVolTimeStopMinBars) return false;

   double ratio = atrNow / g_entryATR;
   if(ratio >= InpVolCollapseRatio) return false;

   PrintFormat("[FVG_FUSION] Volatility Time-Stop: ATR_actual/ATR_entrada=%.3f (< %.3f) tras %d barras. Cerrando ticket #%s.",
               ratio, InpVolCollapseRatio, barsElapsed, (string)ticket);
   return trade.PositionClose(ticket);
  }
//===================================================================
//  ManageExitsAndProtection — breakeven + trailing PROGRESIVO CONTINUO
//  con piso de spread y validacion del stop level del broker
//===================================================================
void ManageExitsAndProtection()
  {
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double atr    = g_bufATR[0];
   if(atr <= 0.0) return;

   double beTrigger = atr * InpBreakevenTriggerATR;
   double spreadFloor = g_avgSpread * InpTrailSpreadFloorMult;
   double minStopDist = GetMinStopDistPrice();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicBase) continue;

      ulong    ticket   = PositionGetTicket(i);
      double   open     = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl       = PositionGetDouble(POSITION_SL);
      double   tp       = PositionGetDouble(POSITION_TP);
      double   vol      = PositionGetDouble(POSITION_VOLUME);
      double   bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double   ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      long     posType  = PositionGetInteger(POSITION_TYPE);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      if(CheckVolatilityTimeStop(ticket, atr, open, sl, posType, openTime))
         continue;

      double favorable = (posType == POSITION_TYPE_BUY) ? (bid - open) : (open - ask);

      //--- Parcial opcional
      TryPartialTP(ticket, vol, favorable);

      if(posType == POSITION_TYPE_BUY)
        {
         if(favorable >= beTrigger)
           {
            double extraATR   = (favorable - beTrigger) / atr;
            double trailATR   = MathMax(InpTrailMinATR, InpTrailBaseATR - InpTrailTightenRate*extraATR);
            double beLockDist = MathMax(atr * InpBreakevenLockATR, spreadFloor);
            double trailDist  = MathMax(atr * trailATR, spreadFloor);
            double candidate  = MathMax(open + beLockDist, bid - trailDist);

            //--- validacion: el nuevo SL debe estar lejos del precio actual
            if(bid - candidate < minStopDist)
               candidate = bid - minStopDist;
            if(candidate > sl)
              {
               if(trade.PositionModify(ticket, NormalizeDouble(candidate, digits), tp))
                 {
                  if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
                    {
                     g_modifyErrCnt++;
                     if(g_modifyErrCnt <= 10)
                        PrintFormat("[FVG_FUSION] Modify BUY retcode=%s (%d) ticket=%s",
                                    trade.ResultRetcodeDescription(), trade.ResultRetcode(), (string)ticket);
                    }
                 }
              }
           }
        }
      else
        {
         if(favorable >= beTrigger)
           {
            double extraATR   = (favorable - beTrigger) / atr;
            double trailATR   = MathMax(InpTrailMinATR, InpTrailBaseATR - InpTrailTightenRate*extraATR);
            double beLockDist = MathMax(atr * InpBreakevenLockATR, spreadFloor);
            double trailDist  = MathMax(atr * trailATR, spreadFloor);
            double candidate  = MathMin(open - beLockDist, ask + trailDist);

            if(candidate - ask < minStopDist)
               candidate = ask + minStopDist;
            if(sl == 0.0 || candidate < sl)
              {
               if(trade.PositionModify(ticket, NormalizeDouble(candidate, digits), tp))
                 {
                  if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
                    {
                     g_modifyErrCnt++;
                     if(g_modifyErrCnt <= 10)
                        PrintFormat("[FVG_FUSION] Modify SELL retcode=%s (%d) ticket=%s",
                                    trade.ResultRetcodeDescription(), trade.ResultRetcode(), (string)ticket);
                    }
                 }
              }
           }
        }
     }

   //--- limpiar registro de parciales cuyas posiciones ya no existen
   if(InpPartialTPEnable)
      CleanupPartialTickets();
  }
//===================================================================
//  SESION Y COOLDOWN
//===================================================================
bool IsWithinSession()
  {
   MqlDateTime tstruct;
   TimeToStruct(TimeTradeServer(), tstruct);

   int nowMinutes   = tstruct.hour * 60 + tstruct.min;
   int startMinutes = InpStartHour * 60 + InpStartMinute;
   int endMinutes   = InpEndHour   * 60 + InpEndMinute;

   if(startMinutes == endMinutes) return true;
   if(startMinutes < endMinutes)
      return (nowMinutes >= startMinutes && nowMinutes < endMinutes);
   else
      return (nowMinutes >= startMinutes || nowMinutes < endMinutes);
  }
bool InCooldown()
  {
   return (g_cooldownUntil > 0 && TimeTradeServer() < g_cooldownUntil);
  }
void CheckDayRollover()
  {
   datetime now = TimeTradeServer();
   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);
   datetime dayStart = now - (dtNow.hour * 3600 + dtNow.min * 60 + dtNow.sec);

   if(dayStart == g_currentDayStart) return;

   bool firstRun = (g_currentDayStart == 0);
   g_currentDayStart = dayStart;
   g_dayRealizedPL   = 0.0;
   g_dailyLimitHit    = false;

   if(InpPersistState)
   {
      GlobalVariableSet(GV_DayStart(), (double)g_currentDayStart);
      GlobalVariableSet(GV_DayPL(),    0.0);
   }

   if(!firstRun)
      Print("[FVG_FUSION] Nuevo dia de trading (servidor). Reset de perdida diaria realizada y del circuit breaker.");
  }
//===================================================================
//  Visualizacion de operaciones (cajas TP/SL sombreadas)
//===================================================================
void DrawTradeBox(string name, datetime t1, datetime t2, double p1, double p2, color clr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
      ObjectMove(0, name, 1, t2, p2);
  }
void DrawTradeLine(string name, datetime t1, datetime t2, double price, color clr)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
      ObjectMove(0, name, 1, t2, price);
  }
void DrawTradeLabel(string name, datetime t, double price, string text, ENUM_ANCHOR_POINT anchor)
  {
   if(!InpShowLabels) return;
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
   else
      ObjectMove(0, name, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }
void UpdateTradeVisuals()
  {
   datetime now = TimeCurrent();
   int barSeconds = PeriodSeconds(PERIOD_CURRENT);
   datetime extTime = now + barSeconds * InpBoxExtendBars;

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicBase) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl         = PositionGetDouble(POSITION_SL);
      double tp         = PositionGetDouble(POSITION_TP);
      double volume     = PositionGetDouble(POSITION_VOLUME);
      long   type       = PositionGetInteger(POSITION_TYPE);
      double profit     = PositionGetDouble(POSITION_PROFIT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      string base = "TRD_" + (string)ticket + "_";

      if(tp > 0)
        {
         DrawTradeBox(base+"TP", openTime, extTime, openPrice, tp, InpColorTP);
         DrawTradeLine(base+"TPLine", openTime, extTime, tp, InpColorTP);
         double tpPct = (type==POSITION_TYPE_BUY) ? (tp-openPrice)/openPrice*100.0 : (openPrice-tp)/openPrice*100.0;
         DrawTradeLabel(base+"TPLabel", extTime, tp, StringFormat("Objetivo: %s (%.2f%%)  Vol: %.2f", DoubleToString(tp,digits), tpPct, volume), ANCHOR_RIGHT);
        }
      if(sl > 0)
        {
         DrawTradeBox(base+"SL", openTime, extTime, openPrice, sl, InpColorSL);
         DrawTradeLine(base+"SLLine", openTime, extTime, sl, InpColorSL);
         double slPct = (type==POSITION_TYPE_BUY) ? (openPrice-sl)/openPrice*100.0 : (sl-openPrice)/openPrice*100.0;
         DrawTradeLabel(base+"SLLabel", extTime, sl, StringFormat("Stop: %s (%.2f%%)  P/L: %.2f", DoubleToString(sl,digits), slPct, profit), ANCHOR_RIGHT);
        }
      DrawTradeLine(base+"OpenLine", openTime, extTime, openPrice, clrSilver);
     }
  }
void CleanupClosedVisuals()
  {
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total-1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, "TRD_") != 0) continue;
      string rest = StringSubstr(name, 4);
      int p = StringFind(rest, "_");
      if(p <= 0) continue;
      ulong ticket = (ulong)StringToInteger(StringSubstr(rest, 0, p));
      if(!PositionSelectByTicket(ticket))
         ObjectDelete(0, name);
     }
  }
//===================================================================
ENUM_ORDER_TYPE_FILLING GetBestFillingMode(string symbol)
{
    int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
    if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}
//+------------------------------------------------------------------+
