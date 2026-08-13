//+------------------------------------------------------------------+
//|                    Pure_Fractal_FVG_Fusion_v9.mq5                 |
//|   v10.11 — Parche: se agrega modo de LOTAJE MANUAL.                |
//|   1. Eliminado el Time-Stop (InpMaxHoldingSeconds): no aportaba,  |
//|      solo forzaba cierres en negativo si la operacion aun no      |
//|      habia llegado a SL/TP.                                       |
//|   2. Eliminado el circuit breaker de cuenta (InpMaxAccountRiskUSD |
//|      / CheckHardRiskLimit) y todo Damage Control (dependia del    |
//|      mismo umbral): tambien forzaba cierres en negativo antes de  |
//|      SL/TP.                                                       |
//|   3. Breakeven + trailing rediseñados como UN SOLO mecanismo      |
//|      continuo: en cuanto el precio avanza InpBreakevenTriggerATR  |
//|      a favor, el SL salta a un piso positivo (InpBreakevenLockATR)|
//|      y desde ahi, cada tick, la distancia de trailing se reduce   |
//|      progresivamente conforme la operacion avanza mas (empieza    |
//|      holgada en InpTrailBaseATR, se aprieta a razon de            |
//|      InpTrailTightenRate por cada ATR adicional de avance, con    |
//|      piso en InpTrailMinATR). Nunca retrocede, nunca vuelve a      |
//|      negativo una vez cruzado el disparo.                         |
//|   4. NUEVO (v10.11): InpLotMode permite elegir entre calcular el  |
//|      lote por riesgo en USD (como antes) o escribir directamente  |
//|      el lotaje deseado en InpFixedLotSize.                        |
//|                                                                    |
//|  NOTA: esta version parte de la base v10.00 tal como se dejo, sin |
//|  el filtro de regimen ADX ni el contador de estadisticas que se    |
//|  habian añadido despues en otra rama (v11/v12).                    |
//+------------------------------------------------------------------+
#property copyright "APEXQUANT / NeurAlgo project"
#property version   "10.11"
#property strict
#property description "Fusion Kalman + FVG/Price Action - trailing progresivo continuo, sin cierres forzados"

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

input group "=== Riesgo y Tamano de Posicion ==="
input ENUM_LOT_MODE InpLotMode        = LOT_MODE_RISK; // Modo de lote: por riesgo o fijo manual
input double InpFixedLotSize     = 0.01;  // Lote fijo manual (usado si InpLotMode = LOT_MODE_FIXED)
input double InpRiskPerTradeUSD  = 5.0;   // Riesgo por operacion -> define el lote (si InpLotMode = LOT_MODE_RISK)
input double InpMaxLotSize       = 0.10;
input double InpSLMultiplier     = 0.6;   // SL = ATR x esto. Lo ejecuta el broker, no el EA.
input double InpTPMultiplier     = 1.2;

input group "=== Filtro de Spread ==="
input double InpMaxSpreadATR     = 0.15;

input group "=== Salida: Breakeven y Trailing Progresivo (continuo) ==="
input double InpBreakevenTriggerATR = 0.5;   // Avance a favor que activa la proteccion (x ATR)
input double InpBreakevenLockATR    = 0.10;  // Piso positivo asegurado al activarse (x ATR)
input double InpTrailBaseATR        = 0.40;  // Distancia de trailing justo al activarse (holgada)
input double InpTrailTightenRate    = 0.35;  // Cuanto se aprieta la distancia por cada ATR adicional a favor
input double InpTrailMinATR         = 0.10;  // Distancia minima de trailing (nunca mas ajustado que esto)

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
double g_prevVelocity = 0.0;

int    g_hATR;
double g_bufATR[];
ulong  g_magic = 890;
datetime g_cooldownUntil = 0;

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

    g_kxP = 0.0; g_kxV = 0.0;
    g_kP00 = 1.0; g_kP01 = 0.0; g_kP10 = 0.0; g_kP11 = 1.0;
    g_kQpos = MathMax(1e-12, InpKalmanQ11);
    g_kQvel = MathMax(1e-12, InpKalmanQ22);
    g_kR    = MathMax(1e-12, InpKalmanR);
    g_kInit = false; g_lastTickUs = 0; g_lastTickDt = InpKalmanDtFallback; g_prevVelocity = 0.0;

    g_cooldownUntil = 0;

    ArrayResize(zones, 0);
    g_paFvgBias = 0; g_paFvgZoneIdx = -1;
    g_lastStructBarTime = 0; g_lastFastBarTime = 0;
    g_entryCounter = 0;

    ArrayResize(g_kalHistPrice, 0);
    ArrayResize(g_kalHistTime, 0);
    g_kalHistCount = 0;

    CreateDashboard();

    Print("Pure_Fractal_FVG_Fusion v10.11 initialised | SLx=", InpSLMultiplier, " TPx=", InpTPMultiplier,
          " | Thr=", InpBiasThreshold,
          " | LotMode=", (InpLotMode == LOT_MODE_FIXED ? "FIJO" : "RIESGO"),
          " | FixedLot=", InpFixedLotSize, " RiskPerTrade=", InpRiskPerTradeUSD, " | MaxLot=", InpMaxLotSize,
          " | BE_Trig=", InpBreakevenTriggerATR, " BE_Lock=", InpBreakevenLockATR,
          " | TrailBase=", InpTrailBaseATR, " TightenRate=", InpTrailTightenRate, " TrailMin=", InpTrailMinATR,
          " | Sin Time-Stop, sin circuit breaker de cuenta, sin Damage Control (removidos)",
          " | Session=", (InpSessionFilterEnable ? "ON" : "OFF"));

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

    if(CountPositions() == 0)
    {
        if(InCooldown()) return;
        if(InpSessionFilterEnable && !IsWithinSession()) return;
        ExecuteBiasedEntry(pLongAdj, atr, ask, bid);
    }
    else
    {
        ManageExitsAndProtection();
    }
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
}
//===================================================================
//  Motor Kalman + sesgo macro
//===================================================================
void UpdateAdaptiveNoise(double mid, double ask, double bid)
{
    double Rbase = MathMax(1e-12, InpKalmanR);
    if(!InpAKF_Enable) { g_kR = Rbase; return; }

    double spread = ask - bid;
    if(!g_akfInit) { g_lastMid = mid; g_akfInit = true; g_kR = Rbase; return; }

    double tickDelta = mid - g_lastMid;
    g_lastMid = mid;

    g_tickBuf[g_akfBufIdx]   = tickDelta;
    g_spreadBuf[g_akfBufIdx] = spread;
    g_akfBufIdx = (g_akfBufIdx + 1) % g_akfWindow;
    if(g_akfBufCount < g_akfWindow) g_akfBufCount++;

    if(g_akfBufCount < 2) { g_kR = Rbase; return; }

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

    double meanSpread = 0.0;
    for(int i = 0; i < g_akfBufCount; i++) meanSpread += g_spreadBuf[i];
    meanSpread /= g_akfBufCount;

    double spreadRatio     = (meanSpread > 0.0) ? (spread / meanSpread) : 1.0;
    double spreadAmplifier = MathMax(1.0, spreadRatio);
    double sigmaTickSqEff  = varTick * spreadAmplifier;

    g_kR = MathMax(1e-12, Rbase * (1.0 + InpAKF_Alpha * sigmaTickSqEff));
}

void KalmanUpdate(double mid)
{
    ulong  nowUs = GetMicrosecondCount();
    double dt;
    if(!g_kInit || g_lastTickUs == 0) dt = InpKalmanDtFallback;
    else
    {
        double rawDt = (double)(nowUs - g_lastTickUs) * 1e-6;
        dt = MathMax(1e-6, MathMin(60.0, rawDt));
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
    if(g_lastTickDt > 1e-6)
    {
        double a_k = (g_kxV - g_prevVelocity) / g_lastTickDt;
        a_hat = a_k / atr;
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
      ObjectSetInteger(0, "DASH_BG", OBJPROP_XSIZE, 235);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_YSIZE, 130);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_BGCOLOR, C'20,20,25');
      ObjectSetInteger(0, "DASH_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_COLOR, clrGray);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_BACK, false);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, "DASH_BG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
     }

   string labels[6] = {"DASH_Title","DASH_State","DASH_Prob","DASH_ATR","DASH_Spread","DASH_Zones"};
   for(int i = 0; i < 6; i++)
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
   ObjectSetString(0, "DASH_Title", OBJPROP_TEXT, "Pure_Fractal FVG Fusion v10.11");
   ObjectSetInteger(0, "DASH_Title", OBJPROP_COLOR, clrDodgerBlue);
  }
void UpdateDashboard(double pLong, double atr, double spread)
  {
   if(!InpShowDashboard) return;

   string state = (CountPositions() > 0) ? "En posicion" : "Plano";
   if(InCooldown()) state += " | Cooldown";
   if(InpSessionFilterEnable && !IsWithinSession()) state += " | Fuera de sesion";

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   ObjectSetString(0, "DASH_State",  OBJPROP_TEXT, "Estado: " + state);
   ObjectSetString(0, "DASH_Prob",   OBJPROP_TEXT, StringFormat("P(Long): %.1f%%  (umbral %.0f%%)", pLong*100, InpBiasThreshold*100));
   ObjectSetString(0, "DASH_ATR",    OBJPROP_TEXT, "ATR: " + DoubleToString(atr, digits));
   ObjectSetString(0, "DASH_Spread", OBJPROP_TEXT, StringFormat("Spread: %s (max %.0f%% ATR)", DoubleToString(spread,digits), InpMaxSpreadATR*100));
   ObjectSetString(0, "DASH_Zones",  OBJPROP_TEXT, StringFormat("Zonas FVG activas: %d | Lote: %s", CountActiveZones(),
                   (InpLotMode == LOT_MODE_FIXED) ? DoubleToString(InpFixedLotSize,2) + " fijo" : "por riesgo"));
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
//  Filtro de spread + sizing de lote (manual o por riesgo)
//===================================================================
bool SpreadOK(double atr)
  {
   if(InpMaxSpreadATR <= 0.0) return true;
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return(spread <= atr * InpMaxSpreadATR);
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
//  Entrada: Kalman + confluencia PA+FVG, SL/TP puros en ATR
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

   double slDistance = atr * InpSLMultiplier;
   double tpDistance = atr * InpTPMultiplier;
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
//===================================================================
//  ManageExitsAndProtection — breakeven + trailing PROGRESIVO CONTINUO
//  Un solo mecanismo: se activa al cruzar InpBreakevenTriggerATR y
//  desde ahi, cada tick, la distancia de trailing se va apretando
//  (nunca ensanchando) conforme la operacion avanza mas a favor.
//  Sin Time-Stop: la unica salida antes de SL/TP es este trailing.
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

      ulong ticket = PositionGetTicket(i);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
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
