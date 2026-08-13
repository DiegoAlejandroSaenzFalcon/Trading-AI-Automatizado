//+------------------------------------------------------------------+
//|                    Pure_Fractal_FVG_Fusion_v9.mq5                 |
//|   v10.12 — Auditoria de microestructura para cuentas Cent/Micro   |
//|   en activos volatiles (XAUUSD, BTCUSD). Historial resumido:      |
//|     v10.10: se elimino el Time-Stop fijo y el circuit breaker de  |
//|       cuenta porque forzaban cierres en negativo antes de SL/TP.  |
//|     v10.11: se agrego InpLotMode (lote fijo manual vs riesgo USD).|
//|                                                                    |
//|   v10.12 (esta version) corrige 4 vectores de falla especificos   |
//|   de microestructura retail:                                      |
//|                                                                    |
//|   1) SL/TP conscientes del spread (ComputeAdaptiveSLTP): el SL ya |
//|      no es un multiplo fijo de ATR. Se calcula un piso minimo =   |
//|      spread promedio x InpSLSpreadBufferMult, y si el spread      |
//|      ACTUAL se dispara muy por encima de su promedio (cacería de  |
//|      stops / spike de noticias) el SL y el TP se ensanchan        |
//|      proporcionalmente (mismo factor, para conservar el ratio     |
//|      R:R), con tope duro en InpMaxSLSpreadExpansion. El lotaje    |
//|      por riesgo sigue derivandose de esta distancia ya ajustada,  |
//|      por lo que el riesgo en USD se mantiene constante.           |
//|                                                                    |
//|   2) Robustez temporal del motor Kalman: el termino de aceleracion|
//|      (a_hat) es una derivada numerica (delta-velocidad/delta-t).  |
//|      Diferenciar numericamente amplifica ruido de alta frecuencia |
//|      (resultado clasico de analisis numerico) y el "tick          |
//|      clustering" tipico de servidores retail puede hacer que dt   |
//|      caiga cerca de cero y dispare a_hat a valores que saturan el |
//|      sigmoide, generando señales falsas. Mitigado con: (a) piso   |
//|      realista InpKalmanMinDt en vez de 1 microsegundo, (b)        |
//|      suavizado EWMA (paso-bajo) del dt usado SOLO para a_hat (la  |
//|      propagacion del filtro sigue usando el dt real floored, que  |
//|      es lo correcto para un DKF de tiempo variable), y (c) un     |
//|      clamp duro sobre |a_hat| (InpMaxAccelHatAbs) independiente   |
//|      del ajuste de parametros.                                    |
//|                                                                    |
//|   3) Circuit breaker de perdida diaria (InpMaxDailyLossUSD): a    |
//|      diferencia del removido en v10.10, NO cierra posiciones ni   |
//|      las fuerza a un SL prematuro. Unicamente BLOQUEA NUEVAS      |
//|      entradas una vez que la perdida REALIZADA del dia alcanza el |
//|      limite; lo abierto sigue su SL/TP y trailing normal.         |
//|                                                                    |
//|   4) Time-Stop dinamico por colapso de volatilidad                |
//|      (InpVolTimeStopEnable): tampoco es un timer fijo. Compara el |
//|      ATR actual contra el ATR de entrada; si cae bajo             |
//|      InpVolCollapseRatio (la expansion de rango que motivo el     |
//|      trade ya se disipo) y pasaron InpVolTimeStopMinBars barras,  |
//|      cierra. Solo actua MIENTRAS el SL sigue en su nivel original |
//|      (breakeven/trailing aun no tomaron el control); en cuanto lo |
//|      hacen, este mecanismo se aparta.                             |
//|                                                                    |
//|   ADVERTENCIA: esto es ingenieria de reduccion de riesgo, NO una  |
//|   promesa de rentabilidad. Reduce vectores de falla identificados |
//|   (asfixia por spread, ruido numerico del Kalman, ausencia de     |
//|   cortocircuitos) pero el resultado real depende del broker, el   |
//|   simbolo, el regimen de mercado y el resto de parametros. ANTES  |
//|   de escalar lotaje real: (a) forward test en DEMO durante varias |
//|   semanas y distintos regimenes de volatilidad, (b) validacion en |
//|   cuenta CENT/MICRO real -el backtest de MT5 modela spread/tick   |
//|   de forma imperfecta frente al feed real-, (c) registro           |
//|   estadistico (profit factor, expectancy, max drawdown, win rate) |
//|   sobre una muestra suficiente antes de sacar conclusiones sobre  |
//|   cualquier parametro individual.                                  |
//+------------------------------------------------------------------+
#property copyright "APEXQUANT / NeurAlgo project"
#property version   "10.12"
#property strict
#property description "Fusion Kalman + FVG/PA - SL/TP conscientes del spread, Kalman robusto a tick clustering, circuit breaker diario y time-stop por colapso de volatilidad"

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

//===================================================================
//  INPUT PARAMETERS
//===================================================================
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

input group "=== Filtro de Tendencia Macro (EMA/TEMA) ==="
input bool               InpMacroBiasEnable    = true;
input int                InpMacroPeriod        = 200;
input ENUM_MACRO_MODE    InpMacroMode          = MACRO_MODE_EMA;
input double              InpMacroPenaltyGamma = 0.70;

input group "=== Ruido Adaptativo (AKF) ==="
input bool   InpAKF_Enable       = true;
input int    InpAKF_Window       = 30;
input double InpAKF_Alpha        = 50.0;

input group "=== Zonas FVG + Confluencia de Accion del Precio ==="
input ENUM_TIMEFRAMES InpFVGTimeframe      = PERIOD_M15;
input double            InpMinGapATR       = 0.15;
input int               InpMaxZoneAgeBars  = 60;
input int               InpMaxActiveZones  = 8;
input double            InpZoneInvalidateATR = 0.5;
input double            InpZoneToleranceATR  = 0.3;
input int               InpLookbackBars      = 20;
input double            InpConfluenceBoost   = 0.15;

input group "=== Riesgo Adaptativo: SL/TP conscientes del Spread ==="
input double InpSLSpreadBufferMult   = 1.5;  // El SL nunca es mas estrecho que (spread promedio x este factor)
input double InpSpreadSpikeThreshold = 1.8;  // Si spread_actual/spread_promedio supera esto, se considera "spike"
input double InpMaxSLSpreadExpansion = 2.0;  // Tope maximo de ensanche de SL/TP durante un spike de spread

input group "=== Riesgo y Tamano de Posicion ==="
input ENUM_LOT_MODE InpLotMode        = LOT_MODE_RISK; // Modo de lote: por riesgo o fijo manual
input double InpFixedLotSize     = 0.01;  // Lote fijo manual (usado si InpLotMode = LOT_MODE_FIXED)
input double InpRiskPerTradeUSD  = 5.0;   // Riesgo por operacion -> define el lote (si InpLotMode = LOT_MODE_RISK)
input double InpMaxLotSize       = 0.10;
input double InpSLMultiplier     = 0.6;   // SL base = ATR x esto (antes del ajuste por spread, ver arriba)
input double InpTPMultiplier     = 1.2;
input int    InpMaxOpenPositions = 1;     // Limite duro de exposicion: posiciones simultaneas de este EA

input group "=== Filtro de Spread ==="
input double InpMaxSpreadATR     = 0.15;

input group "=== Salida: Breakeven y Trailing Progresivo (continuo) ==="
input double InpBreakevenTriggerATR = 0.5;   // Avance a favor que activa la proteccion (x ATR)
input double InpBreakevenLockATR    = 0.10;  // Piso positivo asegurado al activarse (x ATR)
input double InpTrailBaseATR        = 0.40;  // Distancia de trailing justo al activarse (holgada)
input double InpTrailTightenRate    = 0.35;  // Cuanto se aprieta la distancia por cada ATR adicional a favor
input double InpTrailMinATR         = 0.10;  // Distancia minima de trailing (nunca mas ajustado que esto)

input group "=== Controles Macro: Circuit Breaker Diario y Time-Stop por Volatilidad ==="
input bool   InpDailyLossLimitEnable = true;
input double InpMaxDailyLossUSD      = 30.0;  // Perdida REALIZADA maxima del dia -> bloquea nuevas entradas (no toca lo abierto)
input bool   InpVolTimeStopEnable    = true;
input double InpVolCollapseRatio     = 0.50;  // Si ATR_actual/ATR_al_entrar cae debajo de esto...
input int    InpVolTimeStopMinBars   = 6;     // ...y ya pasaron al menos esta cantidad de barras desde la entrada...
input ENUM_TIMEFRAMES InpVolTimeStopBarTF = PERIOD_CURRENT; // ...se cierra (solo si el breakeven aun no se activo)

input group "=== Pausa Tras Perdida ==="
input int    InpCooldownMinutes  = 2;

input group "=== Filtro de Sesion ==="
input bool   InpSessionFilterEnable = false;
input int    InpStartHour        = 7;
input int    InpStartMinute      = 0;
input int    InpEndHour          = 19;
input int    InpEndMinute        = 0;

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
//  GLOBAL STATE — KALMAN ENGINE
//===================================================================
double g_kxP = 0.0, g_kxV = 0.0;
double g_kP00 = 1.0, g_kP01 = 0.0, g_kP10 = 0.0, g_kP11 = 1.0;
double g_kQpos = 1e-4, g_kQvel = 1e-2;
double g_kR = 1e-3;
bool   g_kInit = false;
ulong  g_lastTickUs = 0;
double g_lastTickDt = 0.1;
double g_smoothedDt = 0.1;     // dt suavizado (EWMA); usado SOLO para el termino de aceleracion (ver KalmanUpdate)
double g_prevVelocity = 0.0;

int    g_hATR;
double g_bufATR[];
ulong  g_magic = 999;
datetime g_cooldownUntil = 0;
double   g_avgSpread = 0.0;    // spread promedio (rolling), alimentado desde UpdateAdaptiveNoise
double   g_entryATR  = 0.0;    // ATR vigente al momento de la ultima entrada (para el time-stop por volatilidad)

//===================================================================
//  GLOBAL STATE — CIRCUIT BREAKER DIARIO
//===================================================================
double   g_dayRealizedPL   = 0.0;
datetime g_currentDayStart = 0;
bool     g_dailyLimitHit   = false;

int      g_hMacroEMA;
bool     g_macroInit        = false;
datetime g_lastMacroBarTime = 0;
double   g_macroEMA  = 0.0, g_macroTEMA = 0.0;
double   g_tema_ema2 = 0.0, g_tema_ema3 = 0.0;

double g_tickBuf[];
double g_spreadBuf[];
int    g_akfWindow = 30, g_akfBufIdx = 0, g_akfBufCount = 0;
bool   g_akfInit = false;
double g_lastMid = 0.0;

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
//  OnInit
//===================================================================
int OnInit()
{
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
    if(InpDtSmoothingAlpha <= 0.0 || InpDtSmoothingAlpha > 1.0)
        Print("[FVG_FUSION] AVISO: InpDtSmoothingAlpha fuera de (0,1]; valor tipico recomendado entre 0.05 y 0.5.");
    if(InpMaxSLSpreadExpansion < 1.0)
        Print("[FVG_FUSION] AVISO: InpMaxSLSpreadExpansion < 1.0 podria ESTRECHAR el SL durante un spike; revisa el parametro.");
    if(InpDailyLossLimitEnable && InpMaxDailyLossUSD <= 0.0)
    {
        Print("ERROR: InpMaxDailyLossUSD debe ser mayor a 0 cuando InpDailyLossLimitEnable = true. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpVolTimeStopEnable && (InpVolCollapseRatio <= 0.0 || InpVolCollapseRatio >= 1.0))
    {
        Print("ERROR: InpVolCollapseRatio debe estar en (0,1) cuando InpVolTimeStopEnable = true. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpMaxOpenPositions < 1)
    {
        Print("ERROR: InpMaxOpenPositions debe ser al menos 1. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }

    trade.SetExpertMagicNumber(g_magic);
    trade.SetTypeFilling(GetBestFillingMode(_Symbol));

    g_hATR = iATR(_Symbol, _Period, InpATRPeriod);
    if(g_hATR == INVALID_HANDLE)
    {
        Print("ERROR: ATR handle creation failed.");
        return INIT_FAILED;
    }
    ArraySetAsSeries(g_bufATR, true);

    g_hMacroEMA = iMA(_Symbol, _Period, InpMacroPeriod, 0, MODE_EMA, PRICE_CLOSE);
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
    ArrayResize(g_spreadBuf, g_akfWindow);
    ArrayInitialize(g_tickBuf, 0.0);
    ArrayInitialize(g_spreadBuf, 0.0);
    g_akfInit = false; g_akfBufIdx = 0; g_akfBufCount = 0; g_lastMid = 0.0;
    g_avgSpread = 0.0;

    g_kxP = 0.0; g_kxV = 0.0;
    g_kP00 = 1.0; g_kP01 = 0.0; g_kP10 = 0.0; g_kP11 = 1.0;
    g_kQpos = MathMax(1e-12, InpKalmanQ11);
    g_kQvel = MathMax(1e-12, InpKalmanQ22);
    g_kR    = MathMax(1e-12, InpKalmanR);
    g_kInit = false; g_lastTickUs = 0; g_lastTickDt = InpKalmanDtFallback; g_smoothedDt = InpKalmanDtFallback; g_prevVelocity = 0.0;

    g_cooldownUntil = 0;
    g_entryATR = 0.0;

    g_dayRealizedPL   = 0.0;
    g_currentDayStart = 0;
    g_dailyLimitHit   = false;

    ArrayResize(zones, 0);
    g_paFvgBias = 0; g_paFvgZoneIdx = -1;
    g_lastStructBarTime = 0; g_lastFastBarTime = 0;
    g_entryCounter = 0;

    ArrayResize(g_kalHistPrice, 0);
    ArrayResize(g_kalHistTime, 0);
    g_kalHistCount = 0;

    CreateDashboard();

    PrintFormat("Pure_Fractal_FVG_Fusion v10.12 initialised | SLx=%.2f TPx=%.2f Thr=%.2f | LotMode=%s FixedLot=%.2f RiskPerTrade=%.2f MaxLot=%.2f MaxOpenPos=%d",
                InpSLMultiplier, InpTPMultiplier, InpBiasThreshold,
                (InpLotMode == LOT_MODE_FIXED ? "FIJO" : "RIESGO"), InpFixedLotSize, InpRiskPerTradeUSD, InpMaxLotSize, InpMaxOpenPositions);
    PrintFormat("[FVG_FUSION] Salida: BE_Trig=%.2f BE_Lock=%.2f | TrailBase=%.2f TightenRate=%.2f TrailMin=%.2f",
                InpBreakevenTriggerATR, InpBreakevenLockATR, InpTrailBaseATR, InpTrailTightenRate, InpTrailMinATR);
    PrintFormat("[FVG_FUSION] SL adaptativo al spread: BufferMult=%.2fx SpikeThr=%.2fx MaxExpand=%.2fx | Kalman: MinDt=%.4fs DtSmoothAlpha=%.2f MaxAccelHat=%.2f",
                InpSLSpreadBufferMult, InpSpreadSpikeThreshold, InpMaxSLSpreadExpansion,
                InpKalmanMinDt, InpDtSmoothingAlpha, InpMaxAccelHatAbs);
    PrintFormat("[FVG_FUSION] Circuit breakers: DailyLossLimit=%s | VolTimeStop=%s | Session=%s",
                (InpDailyLossLimitEnable ? ("ON(" + DoubleToString(InpMaxDailyLossUSD,2) + " USD)") : "OFF"),
                (InpVolTimeStopEnable ? ("ON(ratio<" + DoubleToString(InpVolCollapseRatio,2) + ", minBars=" + IntegerToString(InpVolTimeStopMinBars) + ")") : "OFF"),
                (InpSessionFilterEnable ? "ON" : "OFF"));

    return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
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

    UpdateAdaptiveNoise(mid, ask, bid);
    KalmanUpdate(mid);
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

    // Entrada y gestion de salidas se evaluan por separado (no if/else): si
    // InpMaxOpenPositions > 1, esto evita que intentar una entrada "olvide"
    // gestionar (trailing/time-stop) una posicion que ya esta abierta.
    bool canAttemptEntry = (CountPositions() < InpMaxOpenPositions)
                            && !InCooldown()
                            && !(InpDailyLossLimitEnable && g_dailyLimitHit)
                            && !(InpSessionFilterEnable && !IsWithinSession());

    if(canAttemptEntry)
        ExecuteBiasedEntry(pLongAdj, atr, ask, bid);

    if(CountPositions() > 0)
        ManageExitsAndProtection();
}
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    ulong dealTicket = trans.deal;
    if(!HistoryDealSelect(dealTicket)) return;

    long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
    if(dealMagic != g_magic) return;

    long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY) return;

    double dealResult = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                       + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                       + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

    if(dealResult < 0.0 && InpCooldownMinutes > 0)
    {
        g_cooldownUntil = TimeTradeServer() + InpCooldownMinutes * 60;
        PrintFormat("[FVG_FUSION] Anti-Revenge Cooldown activo hasta %s (perdida: %.2f)",
                    TimeToString(g_cooldownUntil, TIME_DATE | TIME_MINUTES), dealResult);
    }

    CheckDayRollover();
    g_dayRealizedPL += dealResult;
    if(InpDailyLossLimitEnable && !g_dailyLimitHit && g_dayRealizedPL <= -MathAbs(InpMaxDailyLossUSD))
    {
        g_dailyLimitHit = true;
        PrintFormat("[FVG_FUSION] CIRCUIT BREAKER DIARIO activado: perdida realizada del dia=%.2f (limite %.2f). "
                    "NUEVAS entradas bloqueadas hasta el proximo dia de trading. Las posiciones abiertas NO se ven afectadas.",
                    g_dayRealizedPL, -MathAbs(InpMaxDailyLossUSD));
    }
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

    double tickDelta = mid - g_lastMid;
    g_lastMid = mid;

    g_tickBuf[g_akfBufIdx]   = tickDelta;
    g_spreadBuf[g_akfBufIdx] = spread;
    g_akfBufIdx = (g_akfBufIdx + 1) % g_akfWindow;
    if(g_akfBufCount < g_akfWindow) g_akfBufCount++;

    // El spread promedio (rolling) se mantiene SIEMPRE, independientemente de si el
    // AKF esta habilitado: lo usa tambien ComputeAdaptiveSLTP() para el SL/TP
    // conscientes del spread, que es una proteccion separada del ruido adaptativo
    // del Kalman.
    double meanSpread = 0.0;
    for(int i = 0; i < g_akfBufCount; i++) meanSpread += g_spreadBuf[i];
    meanSpread /= g_akfBufCount;
    g_avgSpread = meanSpread;

    if(!InpAKF_Enable)      { g_kR = Rbase; return; }
    if(g_akfBufCount < 2)   { g_kR = Rbase; return; }

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
        // Piso realista de dt: por debajo de InpKalmanMinDt, dos ticks se tratan como
        // parte del mismo evento de mercado (tick clustering del servidor), no como
        // observaciones independientes en el tiempo. El piso original (1e-6, es decir
        // 1 microsegundo) era irreal para un feed retail y dejaba la puerta abierta a
        // divisiones por un denominador casi nulo en el termino de aceleracion.
        dt = MathMax(InpKalmanMinDt, MathMin(60.0, rawDt));

        // Suavizado EWMA (filtro paso-bajo) del dt: se usa EXCLUSIVAMENTE para el
        // termino de aceleracion en ComputeBiasProbability(). La propagacion del
        // filtro de Kalman en si (mas abajo) sigue usando el dt real ya con piso, que
        // es lo matematicamente correcto para un DKF de tiempo variable. El suavizado
        // evita que una rafaga de ticks agrupados (dt real ~ piso) alterne
        // violentamente con el siguiente intervalo normal y contamine la derivada
        // numerica de la velocidad (aceleracion) con ruido de alta frecuencia -un
        // problema clasico de diferenciacion numerica de señales ruidosas.
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

    double y = mid - xp0;
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

    datetime curBarTime = iTime(_Symbol, _Period, 0);
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

    double v_hat = g_kxV / atr;
    double D = (mid - g_kxP) / atr;

    double a_hat = 0.0;
    if(g_smoothedDt > 1e-6)
    {
        // dt SUAVIZADO (EWMA), no el crudo: dividir por un dt instantaneo
        // potencialmente casi-cero (tick clustering) amplificaria el ruido de la
        // derivada hasta valores sin sentido fisico. Ver KalmanUpdate().
        double a_k = (g_kxV - g_prevVelocity) / g_smoothedDt;
        a_hat = a_k / atr;

        // Clamp duro independiente del ajuste de parametros: ninguna rafaga aislada
        // de ticks puede, por si sola, saturar el sigmoide via el termino de
        // aceleracion. Red de seguridad numerica adicional al suavizado de arriba.
        a_hat = MathMax(-InpMaxAccelHatAbs, MathMin(InpMaxAccelHatAbs, a_hat));
    }

    double arg = InpVelocitySens * v_hat + InpDisplacementW * D + InpAccelerationW * a_hat;
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

   double atr = g_bufATR[0];
   if(atr <= 0) return;
   double minGap = atr * InpMinGapATR;

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
      ObjectSetInteger(0, "DASH_BG", OBJPROP_YSIZE, 146);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_BGCOLOR, C'20,20,25');
      ObjectSetInteger(0, "DASH_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_COLOR, clrGray);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_BACK, false);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
     }

   string labels[7] = {"DASH_Title","DASH_State","DASH_Prob","DASH_ATR","DASH_Spread","DASH_Zones","DASH_Risk"};
   for(int i = 0; i < 7; i++)
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
   ObjectSetString(0, "DASH_Title", OBJPROP_TEXT, "Pure_Fractal FVG Fusion v10.12");
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
   ObjectSetString(0, "DASH_State",  OBJPROP_TEXT, "Estado: " + state);
   ObjectSetString(0, "DASH_Prob",   OBJPROP_TEXT, StringFormat("P(Long): %.1f%%  (umbral %.0f%%)", pLong*100, InpBiasThreshold*100));
   ObjectSetString(0, "DASH_ATR",    OBJPROP_TEXT, "ATR: " + DoubleToString(atr, digits));
   ObjectSetString(0, "DASH_Spread", OBJPROP_TEXT, StringFormat("Spread: %s (avg %s, max %.0f%% ATR)", DoubleToString(spread,digits), DoubleToString(g_avgSpread,digits), InpMaxSpreadATR*100));
   ObjectSetString(0, "DASH_Zones",  OBJPROP_TEXT, StringFormat("Zonas FVG activas: %d | Lote: %s", CountActiveZones(),
                   (InpLotMode == LOT_MODE_FIXED) ? DoubleToString(InpFixedLotSize,2) + " fijo" : "por riesgo"));
   ObjectSetString(0, "DASH_Risk",   OBJPROP_TEXT, StringFormat("PL dia: %.2f (limite %s)", g_dayRealizedPL,
                   InpDailyLossLimitEnable ? DoubleToString(-MathAbs(InpMaxDailyLossUSD),2) : "OFF"));
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
//  (manual o por riesgo)
//===================================================================
bool SpreadOK(double atr)
  {
   if(InpMaxSpreadATR <= 0.0) return true;
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return(spread <= atr * InpMaxSpreadATR);
  }
//---------------------------------------------------------------------
// ComputeAdaptiveSLTP: calcula la distancia de SL/TP integrando el
// spread en tiempo real, para que el SL no quede mas estrecho que el
// ruido natural del bid/ask en cuentas Cent/Micro ("asfixia por SL").
//
//  1) Piso minimo: el SL nunca es mas estrecho que (spread promedio x
//     InpSLSpreadBufferMult). Si ATR*InpSLMultiplier ya es mayor que ese
//     piso, se usa el valor de ATR sin cambios (caso normal, sin spread
//     anormal).
//  2) Ensanche por spike: si el spread ACTUAL esta muy por encima de su
//     promedio reciente (posible cacería de stops / expansion por
//     noticias), el SL Y el TP se ensanchan por el MISMO factor -para
//     conservar el ratio riesgo:beneficio original- con un tope duro en
//     InpMaxSLSpreadExpansion.
//
// El lotaje (cuando InpLotMode = LOT_MODE_RISK) se deriva de la
// distancia de SL YA ajustada aqui, por lo que el riesgo en USD de la
// operacion se mantiene constante aunque el SL se ensanche.
//---------------------------------------------------------------------
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

   double moneyPerPriceUnit = tickValue / tickSize;
   double lots = InpRiskPerTradeUSD / (slDistance * moneyPerPriceUnit);
   return NormalizeVolumeForRisk(lots);
  }
//---------------------------------------------------------------------
// GetTradeLotSize: punto unico de decision del lotaje.
// - LOT_MODE_FIXED : usa InpFixedLotSize tal cual el usuario lo escribio,
//   solo se normaliza a los pasos/min/max que exige el broker y al
//   tope InpMaxLotSize (para no romper la ejecucion en el broker).
// - LOT_MODE_RISK  : comportamiento original, calculado desde
//   InpRiskPerTradeUSD y la distancia del SL.
//---------------------------------------------------------------------
double GetTradeLotSize(double slDistance)
  {
   if(InpLotMode == LOT_MODE_FIXED)
      return NormalizeVolumeForRisk(InpFixedLotSize);

   return CalcLotSizeForRisk(slDistance);
  }
//===================================================================
//  Entrada: Kalman + confluencia PA+FVG, SL/TP adaptativos al spread
//  (ver ComputeAdaptiveSLTP)
//===================================================================
void ExecuteBiasedEntry(double pLong, double atr, double ask, double bid)
  {
   if(atr <= 0.0) return;
   if(!SpreadOK(atr)) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool usedConfluence = (g_paFvgBias != 0);

   double pShort = 1.0 - pLong;
   bool goLong;
   if(pLong >= InpBiasThreshold)       goLong = true;
   else if(pShort >= InpBiasThreshold) goLong = false;
   else return;

   double slDistance = 0.0, tpDistance = 0.0;
   ComputeAdaptiveSLTP(atr, slDistance, tpDistance);

   double lots = GetTradeLotSize(slDistance);
   if(lots <= 0.0) return;

   bool sent = false;
   double entryPrice = 0.0;
   if(goLong)
     {
      double sl = NormalizeDouble(ask - slDistance, digits);
      double tp = NormalizeDouble(ask + tpDistance, digits);
      sent = trade.Buy(lots, _Symbol, ask, sl, tp, usedConfluence ? "KF10+FVG Buy" : "KF10 Buy");
      entryPrice = ask;
     }
   else
     {
      double sl = NormalizeDouble(bid + slDistance, digits);
      double tp = NormalizeDouble(bid - tpDistance, digits);
      sent = trade.Sell(lots, _Symbol, bid, sl, tp, usedConfluence ? "KF10+FVG Sell" : "KF10 Sell");
      entryPrice = bid;
     }

   if(sent)
     {
      g_entryATR = atr;

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
  }
//===================================================================
int CountPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == g_magic)
         count++;
   return count;
  }
//---------------------------------------------------------------------
// CheckVolatilityTimeStop: sustituto del Time-Stop fijo removido en
// v10.10 (aquel forzaba cierres en negativo por simple paso del tiempo,
// sin relacion con si la tesis de la operacion seguia vigente). Este
// mecanismo cierra UNICAMENTE si la volatilidad (ATR) que motivo la
// entrada se desplomo -la expansion de rango que justificaba el trade
// ya no esta ocurriendo- y ya paso un numero minimo de barras. Solo
// actua MIENTRAS el SL sigue en su nivel original (el trailing/
// breakeven de ManageExitsAndProtection aun no tomo el control); en
// cuanto lo toma, este mecanismo se aparta para no interferir con una
// operacion que ya esta protegida en breakeven o mejor.
//
// Devuelve true si cerro la posicion (el llamador debe hacer 'continue'
// y no intentar modificar un ticket que ya no existe).
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

   PrintFormat("[FVG_FUSION] Volatility Time-Stop: ATR_actual/ATR_entrada=%.3f (< %.3f) tras %d barras. "
               "La volatilidad que motivo la operacion se disipo; cerrando ticket #%s antes de dejarla morir de inactividad.",
               ratio, InpVolCollapseRatio, barsElapsed, (string)ticket);
   return trade.PositionClose(ticket);
  }
//===================================================================
//  ManageExitsAndProtection — breakeven + trailing PROGRESIVO CONTINUO
//  Un solo mecanismo: se activa al cruzar InpBreakevenTriggerATR y
//  desde ahi, cada tick, la distancia de trailing se va apretando
//  (nunca ensanchando) conforme la operacion avanza mas a favor.
//  Antes de eso, CheckVolatilityTimeStop() puede cerrar la operacion si
//  la volatilidad que la motivo colapso (ver comentario arriba).
//===================================================================
void ManageExitsAndProtection()
  {
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double atr    = g_bufATR[0];
   if(atr <= 0.0) return;

   double beTrigger = atr * InpBreakevenTriggerATR;
   double beLock    = atr * InpBreakevenLockATR;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != g_magic) continue;

      ulong    ticket   = PositionGetTicket(i);
      double   open     = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl       = PositionGetDouble(POSITION_SL);
      double   tp       = PositionGetDouble(POSITION_TP);
      double   bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double   ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      long     posType  = PositionGetInteger(POSITION_TYPE);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      if(CheckVolatilityTimeStop(ticket, atr, open, sl, posType, openTime))
         continue;

      if(posType == POSITION_TYPE_BUY)
        {
         double favorable = bid - open;
         if(favorable >= beTrigger)
           {
            double extraATR   = (favorable - beTrigger) / atr;
            double trailATR   = MathMax(InpTrailMinATR, InpTrailBaseATR - InpTrailTightenRate*extraATR);
            double candidate  = MathMax(open + beLock, bid - atr*trailATR);
            if(candidate > sl)
               trade.PositionModify(ticket, NormalizeDouble(candidate, digits), tp);
           }
        }
      else
        {
         double favorable = open - ask;
         if(favorable >= beTrigger)
           {
            double extraATR   = (favorable - beTrigger) / atr;
            double trailATR   = MathMax(InpTrailMinATR, InpTrailBaseATR - InpTrailTightenRate*extraATR);
            double candidate  = MathMin(open - beLock, ask + atr*trailATR);
            if(sl == 0.0 || candidate < sl)
               trade.PositionModify(ticket, NormalizeDouble(candidate, digits), tp);
           }
        }
     }
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
//---------------------------------------------------------------------
// CheckDayRollover: detecta el cambio de dia (hora de servidor) y
// resetea el circuit breaker diario (g_dayRealizedPL / g_dailyLimitHit).
// Se llama al inicio de OnTick() y tambien tras cada cierre de posicion
// en OnTradeTransaction(), para que el reset nunca dependa de que llegue
// un tick exactamente en el instante del cambio de dia.
//---------------------------------------------------------------------
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
      if(PositionGetInteger(POSITION_MAGIC) != (long)g_magic) continue;

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
