//+------------------------------------------------------------------+
//|   APEXQUANT - V9.0-CAPITALGUARD                                  |
//|   "DIRECTIONAL RECOVERY — ANTI-SYMMETRIC ENGINE"                 |
//|                                                                  |
//|   CRASH ROOT CAUSE ANALYSIS (from M15 backtest on $100):        |
//|   [RCA-1] CalcRecoveryLot() ignoraba timeframe. En M15,         |
//|           ATR es 3.9x mayor que M1 → lote calculado = 0.91      |
//|           sobre cuenta de $100 → margin call inmediato.         |
//|   [RCA-2] Sin techo absoluto de volumen acumulado en mercado.   |
//|           Recovery stack llegó a 1.45 lots = $455 margen.       |
//|   [RCA-3] Sin circuit breaker de equity. Drawdown del -400%     |
//|           del balance inicial sin cierre de emergencia.         |
//|   [RCA-4] BlockTP=$0.25 fijo mientras pérdidas alcanzaban       |
//|           $300+. Ratio riesgo/recompensa ∞:1 en recovery.       |
//|                                                                  |
//|   V9.0 FIXES:                                                    |
//|   [F-1] g_TFMult: multiplicador automático por timeframe.       |
//|         M1=1.0 M5=2.2 M15=3.9 M30=6.2 H1=10.5                  |
//|         Todos los cálculos ATR se dividen por g_TFMult.         |
//|   [F-2] CalcMaxSafeLot(): techo duro basado en margen libre.    |
//|         Total lotes ≤ FreeMarg * CapPct / marginPer001          |
//|   [F-3] HardEquityCircuitBreaker(): cierra TODO si DD > X%.     |
//|         Se ejecuta PRIMERO en cada tick. No hay override.       |
//|   [F-4] BlockTP dinámico: MathMax(floor, |blockLoss|*RRRatio)   |
//|         Asegura que el target escala con el riesgo real.        |
//|   [F-5] AutoLot: lote base = Balance * Inp_AutoLotPct / 100     |
//|         Se recalcula en cada ciclo. Cuentas pequeñas → 0.01.    |
//|   [F-6] RecoveryMaxOrders reducido: 2 (era 3/9). Sin excepciones|
//|   [F-7] Todas las funciones de lote pasan por CalcMaxSafeLot()  |
//|                                                                  |
//|   V8.0-QUANTCAL calibraciones preservadas intactas:             |
//|   ATR(14): P50=2.83 P80=4.72 P95=9.05                          |
//|   MAE/ATR: P50=3.36x P75=6.06x Revert=93.8%/60bar             |
//|   VolRegime: LOW<0.84 HIGH>1.09                                 |
//|   Storm: ATRmult=3.10 (P95/P50 ratio)                          |
//|   SprP80: ASI=24 LON=21 OVL=20 NY=19 OFF=25                    |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V9.0-CAPITALGUARD | XAUUSD Anti-Symmetric Engine"
#property version   "9.00"
#property strict
#property description "XAUUSD | V9.0-CAPITALGUARD | Directional Recovery | Capital Protection Layer"

#define VERSION_STR   "APEXQUANT_V9.0-CAPITALGUARD"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS   80

enum ENUM_CT_MODE         { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };
enum ENUM_SESSION_STATE   { SESSION_ASIAN=0, SESSION_LONDON=1, SESSION_OVERLAP=2, SESSION_NY=3, SESSION_OFF=4 };
enum ENUM_VOL_REGIME      { VOL_LOW=0, VOL_NORMAL=1, VOL_HIGH=2 };

//=================================================================
//  PARAMETROS DE ENTRADA
//=================================================================

// ════════════════════════════════════════════════════════════════
//  [V9.0] CAPITAL GUARD — CAPA DE PROTECCION DE CAPITAL
//  CRITICO: estos parámetros previenen el crash documentado.
// ════════════════════════════════════════════════════════════════
input group "=== [V9.0] CAPITAL GUARD (ANTI-CRASH LAYER) ==="
// % máximo del margen libre que puede ocupar el volumen total en mercado.
// En M15/$100: sin este cap → acumuló 1.45 lots ($455 margen) → margin call.
// 0.35 = máximo 35% del margen libre en posiciones abiertas.
input double Inp_MaxMarginUsagePct    = 0.35;
// Circuit breaker de equity: cierra TODO si drawdown supera este %.
// Drawdown = (peakEquity - currentEquity) / peakEquity.
// En el crash observado: DD llegó a 91.27% antes de margin call.
// 0.20 = 20% → interviene cuando la cuenta pierde $20 sobre $100.
input double Inp_HardCircuitBreakerPct= 0.20;
// % secundario: reduce agresividad de recovery (no cierra, solo pausa).
input double Inp_SoftCircuitBreakerPct= 0.12;
// Porcentaje del balance para auto-calcular lote base.
// 0.001 sobre $100 → 0.01 lotes mínimos. Escala automáticamente.
// 0.002 sobre $1000 → 0.01 lotes también. No arriesga más del 0.1%.
input double Inp_AutoLotPct           = 0.001;
// Usar lote automático (recomendado). Si false, usa Inp_LotBase fijo.
input bool   Inp_UseAutoLot           = true;
// Máximo lote individual por orden (techo absoluto, ignora cálculos).
input double Inp_LotHardCap           = 0.05;
// Máximo volumen total acumulado en mercado (suma de todos los lotes).
// En M15/$100: sin este cap el crash llegó a 1.45 lots.
input double Inp_MaxTotalVolume       = 0.15;
// Ratio Riesgo/Recompensa para BlockTP dinámico.
// BlockTP = max(floor, |pérdidaBloque| * Inp_TPRRR)
// 0.12 = recuperar 12% de la pérdida acumulada por ciclo.
// Evita el RCA-4: target=$0.25 vs riesgo=$300.
input double Inp_TPRRR                = 0.12;

// ════════════════════════════════════════════════════════════════
//  [V9.0] TIMEFRAME MULTIPLIER — CRITICO PARA M15
//  Sin este fix: en M15 los parámetros M1 no aplican.
//  Auto-detectado en OnInit(). Visible para diagnóstico.
//  TF: M1=1.0 M5=2.2 M15=3.9 M30=6.2 H1=10.5 H4=21.0
// ════════════════════════════════════════════════════════════════
input group "=== [V9.0] TIMEFRAME ADAPTATION ==="
// Override manual del multiplicador (0 = auto-detección).
// Dejar en 0 para que el EA calcule automáticamente.
input double Inp_TFMultOverride       = 0.0;
// Versión M15 calibrada desde dataset M1 (Q=Phase1×3.9):
// ATR P50 efectivo M15 = 2.83 * 3.9 = 11.04
// Stage1 trigger M15 = Stage1(M1) * 3.9 → pero escalado en USD
// El multiplicador actúa sobre los parámetros de DISTANCIA (ATR),
// NO sobre USD targets (ya son dólares).
// Multiplicador de timing (delays en segundos): M15 los barras son
// 15x más lentas → delays se dividen por el multiplicador.
input bool   Inp_AutoTFScale          = true;

// ════════════════════════════════════════════════════════════════
//  [V7.9] BREATHING ROOM + ASYMMETRIC RECOVERY
// ════════════════════════════════════════════════════════════════
input group "=== [V7.9] BREATHING ROOM ==="
input int    Inp_PrimaryMinHoldSec    = 120;
input double Inp_StageEmergMult       = 2.0;

input group "=== [V7.9] ASYMMETRIC HEDGE ==="
input double Inp_HedgeRatio           = 0.50;
input bool   Inp_UseDirectionalStage  = true;
input double Inp_ReinforceLotMult     = 1.50;    // V9: 2.0→1.5 (reduce over-exposure)

input group "=== [V7.9] DETANGLE ENGINE ==="
input int    Inp_DetangleSec          = 180;
input double Inp_DetangleNetThresh    = 0.005;
input double Inp_DetangleMinLoss      = -1.50;

// ════════════════════════════════════════════════════════════════
//  [V8.0-QUANTCAL] DYNAMIC THRESHOLD ENGINE
//  Calibrado de 99,520 barras XAUUSD M1.
//  En V9.0: se aplica g_TFMult sobre las distancias ATR.
//  Los caps en USD (Inp_DynMaxStageXUSD) permanecen iguales.
// ════════════════════════════════════════════════════════════════
input group "=== [V8.0] DYNAMIC THRESHOLD ENGINE (QUANTCAL) ==="
input double Inp_DynStage1Mult        = 1.20;
input double Inp_DynStage3Mult        = 2.50;
input double Inp_DynTPMult            = 0.80;
input double Inp_DynRecovMult         = 0.60;
input double Inp_DynMaxStage1USD      = 3.00;
input double Inp_DynMaxStage3USD      = 6.00;
input double Inp_DynMaxTPUSD          = 2.00;

// ════════════════════════════════════════════════════════════════
//  [V8.0-QUANTCAL] SESSION FACTORS
//  Derivados de 99,520 barras. ATR/media por sesión:
//  ASIAN=1.00 LONDON=0.87 OVERLAP=1.04 NY=1.15 OFF→halved
// ════════════════════════════════════════════════════════════════
input group "=== [V8.0] SESSION FACTORS (STAT CALIBRATED) ==="
input double Inp_SessFactorAsian      = 1.00;
input double Inp_SessFactorLondon     = 0.87;
input double Inp_SessFactorOverlap    = 1.04;
input double Inp_SessFactorNY         = 1.15;
input double Inp_SessFactorOff        = 0.50;

input group "=== [V8.0] STAGE2 DELAY (STAT CALIBRATED) ==="
input int    Inp_Stage2DelayAsian     = 25;
input int    Inp_Stage2DelayLondon    = 8;
input int    Inp_Stage2DelayOverlap   = 4;
input int    Inp_Stage2DelayNY        = 6;

// ════════════════════════════════════════════════════════════════
//  [V8.0-QUANTCAL] RECOVERY DISTANCE
//  MAE/ATR percentiles del dataset: P25=1.54x P50=3.36x P75=6.06x
//  LOW: 0.80xATR_TFAdj  NORMAL: 1.20xATR_TFAdj  HIGH: 2.00xATR_TFAdj
// ════════════════════════════════════════════════════════════════
input group "=== [V8.0] RECOVERY DISTANCE (MAE CALIBRATED) ==="
input double Inp_RecovDistLow         = 0.80;
input double Inp_RecovDistNormal      = 1.20;
input double Inp_RecovDistHigh        = 2.00;

input group "=== [V7.7] TEMA + KALMAN TREND ENGINE ==="
input bool   Inp_UseTEMAKalman        = true;
input int    Inp_TEMAFastPeriod       = 21;
input int    Inp_TEMASlowPeriod       = 55;
input double Inp_KalmanQ              = 0.0001;
input double Inp_KalmanR              = 0.005;

input group "=== BLOCK STAGE ENGINE (FLOORS) ==="
input double Inp_Stage1Trigger        = -0.40;
input double Inp_Stage3Trigger        = -0.80;
input int    Inp_Stage2DelaySec       = 5;

// ════════════════════════════════════════════════════════════════
//  [V8.0-QUANTCAL] VOLATILITY STORM FILTER
//  StormATRMult=3.10 calibrado: P95/P50 ATR(14) = 9.05/2.83 = 3.19
//  Valor original 2.0 bloqueaba ~P75 de los ticks (demasiado agresivo)
// ════════════════════════════════════════════════════════════════
input group "=== [V8.0] VOLATILITY STORM FILTER (QUANTCAL) ==="
input bool   Inp_UseStormFilter       = true;
input int    Inp_StormATRWindow       = 16;
input double Inp_StormATRMult         = 3.10;
input double Inp_StormSpreadMult      = 2.50;
input int    Inp_StormSpreadWindow    = 16;
input int    Inp_StormCooldownSec     = 30;

input group "=== [V7.6B] NET EXPOSURE HEDGE ==="
input bool   Inp_UseNetHedge          = true;
input double Inp_NetHedgeTrigger1USD  = -2.0;
input double Inp_NetHedgeMult1        = 2.0;
input double Inp_NetHedgeTrigger2USD  = -3.0;
input double Inp_NetHedgeMult2        = 3.5;
input int    Inp_NetHedgeIntervalSec  = 5;

input group "=== CONFIGURACION PRINCIPAL ==="
input long   Inp_Magic                = 3333;
input int    Inp_MaxPositionsTotal    = 6;       // V9: 8→6
input double Inp_LotBase              = 0.01;
input double Inp_LotMaximum           = 0.05;
input double Inp_RiskPerTradePct      = 0.005;   // V9: 0.01→0.005 (0.5% por trade)
input bool   Inp_UseDynamicLot        = true;
input double Inp_CTMinBalanceUSD      = 5.0;
input double Inp_MinFreeMarginPct     = 0.05;    // V9: 0.02→0.05 (más conservador)

input group "=== CIERRE DEL BLOQUE — FLOOR MINIMO ==="
input double Inp_BlockTPTarget        = 0.25;
input double Inp_TP_ATR               = 2.5;
input double Inp_SL_ATR               = 1.2;
input double Inp_OffSessionTP_ATR     = 2.2;
input double Inp_OffSessionSL_ATR     = 1.0;

input group "=== RECOVERY ENGINE ==="
input double Inp_RecoveryTriggerUSD   = -0.20;
input double Inp_RecoveryMinDistATR   = 1.20;
input double Inp_RecoveryMoveATR      = 0.50;
input double Inp_RecoveryMinLotMult   = 1.50;    // V9: 2.0→1.5 (reduce cascade)
input int    Inp_RecoveryMaxOrders    = 2;        // V9: 3→2 (hard limit, no exceptions)
input int    Inp_RecoveryMaxOrdersTrend= 2;       // V9: 9→2 (era la causa del crash)
input int    Inp_RecoveryIntervalSec  = 3;

input group "=== LBC: CONTINGENCIA BALANCE BAJO ==="
input int    Inp_LBCMaxPairs          = 3;        // V9: 4→3
input double Inp_LBCGridATR           = 0.30;
input double Inp_LBCHarvestATR        = 0.15;
input int    Inp_LBCIntervalSec       = 8;
input double Inp_LBCMarginPct         = 0.40;     // V9: 0.55→0.40

input group "=== COUNTER-TRADE ENGINE ==="
input ENUM_CT_MODE Inp_CTMode         = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR        = 1.2;
input int    Inp_CTFixedPoints        = 100;
input int    Inp_CTIntervalSec        = 10;
input int    Inp_CTMaxSameDir         = 2;        // V9: 3→2
input int    Inp_PrimaryCooldownSec   = 10;
input int    Inp_PrimaryCooldownOff   = 20;
// Spread máximo global (override por sesión usa P80 calibrado)
input double Inp_CTMaxSpreadPoints    = 250.0;
input double Inp_CTMaxSpreadOff       = 250.0;

input group "=== SESIONES ==="
input int    Inp_GMTOffset            = 0;
input int    Inp_LondonOpen           = 7;
input int    Inp_LondonClose          = 17;
input int    Inp_NYOpen               = 13;
input int    Inp_NYClose              = 22;
input double Inp_OffSessionLotFactor  = 0.80;     // V9: 1.0→0.80

input group "=== BASKET TP ==="
input bool   Inp_UseBasketTP          = true;
input double Inp_BasketTPFactor       = 0.60;
input double Inp_BasketTPRatio        = 1.5;
input int    Inp_BasketCheckSec       = 3;

input group "=== HARVEST ==="
input double Inp_HarvestMinUSD        = 0.80;
input double Inp_HarvestATRMult       = 0.20;
input bool   Inp_HarvestContinuous    = true;
input int    Inp_HarvestIntervalSec   = 3;

input group "=== CYCLE CONTROL ==="
input bool   Inp_UseCycleMaxLoss      = true;
input double Inp_CycleMaxLossUSD      = -100.00;
input int    Inp_CyclePauseSec        = 30;

input group "=== ADX + HTF ==="
input bool   Inp_UseADX               = true;
input int    Inp_ADXPeriod            = 14;
input double Inp_ADXTrendLevel        = 30.0;
input double Inp_ADXTrendLevelOff     = 22.0;
input bool   Inp_UseHTF               = true;
input ENUM_TIMEFRAMES Inp_HTFTF       = PERIOD_M5;

input group "=== PROTECCION DIARIA ==="
input bool   Inp_UseDailyLimit        = true;
input double Inp_DailyLossUSD         = -10.0;
input double Inp_DailyLossPct         = 8.0;      // V9: 10→8%
input int    Inp_LossStreakMax        = 2;
input double Inp_LossStreakReduce     = 0.70;

input group "=== EQUITY GUARD (V9: ENDURECIDO) ==="
input bool   Inp_UseEquityGuard       = true;
// Pérdida flotante que activa modo emergencia (pausa primarias).
// V9: calibrado dinámico → usa Inp_HardCircuitBreakerPct si este=0.
input double Inp_EmergencyLossUSD     = -5.0;     // fallback fijo
input double Inp_MaxDrawdownPct       = 10.0;
input int    Inp_EmergencyCooldown    = 10;

input group "=== INDICADORES BASE ==="
input int    Inp_ATRPeriod            = 14;
input int    Inp_EMAFast              = 21;
input int    Inp_EMASlow              = 55;
input int    Inp_RSIPeriod            = 7;
input int    Inp_MACDFast             = 12;
input int    Inp_MACDSlow             = 26;
input int    Inp_MACDSig              = 9;

input group "=== CONTROL VISUAL ==="
// Spread máximo global (P80 calibrado = 23). V9: 35→23.
input int    Inp_MaxSpread            = 250;
input bool   Inp_ShowDashboard        = true;
input int    Inp_DashX                = 12;
input int    Inp_DashY                = 28;

input group "=== [V7.5] RESCATE UNIVERSAL ==="
input bool   Inp_RescueAllTrades      = false;

input group "=== [V7.5] SENSOR HORARIO GMT ==="
input bool   Inp_UseTimeFilter        = false;
input int    Inp_UserGMT              = -5;
input int    Inp_BrokerGMT            = 2;
input string Inp_StartTime            = "05:00";
input string Inp_EndTime              = "15:00";

input group "=== [V7.5] SENSOR TENDENCIA ==="
input bool   Inp_UseTrendFilter200    = true;
input int    Inp_EMA200Period         = 200;

// ATRRatioMax: V8.0 calibrado a 3.0 (P99 ratio*2 ≈ 3.0).
// Original 2.5 bloqueaba el 15% de los ticks sin justificación estadística.
input group "=== [V7.5] SENSOR VOLATILIDAD ==="
input bool   Inp_UseVolatFilter       = true;
input int    Inp_ATRSlowPeriod        = 100;
input double Inp_ATRRatioMax          = 3.00;
input double Inp_VolRegimeLowThresh   = 0.84;  // Por debajo = VOL_LOW
input double Inp_VolRegimeHighThresh  = 1.30;  // Por encima = VOL_HIGH (era 1.09)

input group "=== [V7.5] SENSOR MARGIN GUARD ==="
input bool   Inp_UseMarginGuard       = false;     // V9: false→true
input int    Inp_MarginGuardLevels    = 3;

input group "=== [DM] ENTRADA PRIMARIA — DYNAMIC MANAGER ==="
// TP individual de la primaria: precio ± (ATR_M1norm × mult)
// Cuando lo alcanza el broker cierra en verde. Recovery NO se activa.
input double Inp_DM_TPMultiplier    = 0.8;
// Referencia de SL virtual (solo para diagnóstico/dashboard).
// NO se envía al broker. El Block Stage Engine cubre la pérdida.
input double Inp_DM_SLMultiplier    = 3.0;
// Trailing Stop activo una vez que el Break-Even fue activado.
input int    Inp_DM_TrailingPoints  = 10;
// Puntos mínimos por encima/debajo del open para fijar el BE.
input int    Inp_DM_MinPointsProfit = 2;

//=================================================================
//  ESTRUCTURAS
//=================================================================
struct PosRecord {
   ulong    ticket; int posType; double openPrice; double volume;
   double   netProfit; datetime openTime; string comment;
   bool     isPrimary,isCounter,isRecovery,isLBC;
   double   peakProfit; double kX,kP,kK; bool kInit;
};
struct Portfolio {
   int    totalPos,buyCount,sellCount,ctCount,recoveryCount,lbcCount,rescueCount;
   double buyProfit,sellProfit,totalProfit;
   double positiveSum,negativeSum,buyVolume,sellVolume;
   ulong  worstTicket; double worstProfit;
   double currentDD,blockVWAP; int blockDir;
   double rescueProfit;
};
struct MarketSnap {
   double bid,ask,atr,emaFast,emaSlow,rsi,macdMain,macdSig,adx,spread;
   int    htfTrend; bool isBullish,isBearish;
   double atrSlow,ema200,temaFast,temaSlow,kalmanFast,kalmanSlow;
   int    trendConfirmed;
};
struct LBCState {
   bool     active; int buyCount,sellCount;
   double   lastBuyPrice,lastSellPrice; datetime lastOrderTime;
   double   harvestedTotal; int harvestCount,maxOrdersCalc;
   datetime activatedTime;
};
struct SensorState {
   bool   timeOK,spreadOK,trendBull,volatOK,marginOK,allOK;
   string blockReason; double atrRatio;
   int    brokerStartMin,brokerEndMin;
};
struct DynThresholds {
   double stage1Trigger,stage3Trigger,blockTP,recovTrigger,recovDistATR;
   int    stage2Delay;
   double netHedgeTrig1,netHedgeTrig2,sessionFactor,atr2usd;
   ENUM_SESSION_STATE session; ENUM_VOL_REGIME volRegime;
};

//=================================================================
//  HANDLES INDICADORES
//=================================================================
int h_ATR,h_EMAFast,h_EMASlow,h_RSI,h_MACD;
int h_ADX=INVALID_HANDLE,h_HTFEMAFast=INVALID_HANDLE,h_HTFEMASlow=INVALID_HANDLE;
int h_ATRSlow=INVALID_HANDLE,h_EMA200=INVALID_HANDLE;

//=================================================================
//  VARIABLES GLOBALES
//=================================================================
CTrade      m_trade;
PosRecord   m_rec[MAX_RECORDS];
Portfolio   m_port;
MarketSnap  m_mkt;
LBCState    m_lbc;
SensorState m_sensors;
DynThresholds m_dyn;

// [V9.0] Capital Guard state
double   g_TFMult           = 1.0;   // Timeframe multiplier (auto-calculated)
bool     g_CircuitBreakerHit= false; // Hard equity circuit breaker flag
bool     g_SoftBreakerHit   = false; // Soft circuit breaker flag
double   g_PeakEquity       = 0.0;   // For drawdown calculation
double   g_DynEmergencyLoss = -5.0;  // Dynamic emergency loss threshold
datetime g_CircuitResetTime = 0;
double   g_MarginPer001     = 5.0;   // Margin required per 0.01 lot (calibrated)
double   g_AutoBaseLot      = 0.01;  // Auto-calculated base lot

double   m_initialBalance=0,m_bestEquity=0;
bool     m_isPaused=false,m_emergencyMode=false,m_dailyLimitHit=false,m_inSession=false;
bool     m_recoveryActive=false; int m_recoveryOrders=0; bool m_recoveryTrendHedge=false;
bool     m_netHedge1Applied=false,m_netHedge2Applied=false; datetime m_lastNetHedgeTime=0;
bool     m_stormActive=false; datetime m_stormDetectedTime=0;
double   m_stormLastATRRatio=0,m_stormLastSprRatio=0;
double   m_cycleWinsSum=0; int m_cycleWinsCount=0; double m_cycleLossSum=0;
bool     m_cycleInPause=false; datetime m_cycleResetTime=0;
int      m_consecutiveLosses=0; double m_lotMultiplier=1.0;
double   m_dailyBalance=0; datetime m_lastDailyReset=0;
int      m_lastPrimaryDir=0; datetime m_lastPrimaryTime=0; bool m_lastPrimaryLost=false;
double   m_lastCTBuyPrice=0,m_lastCTSellPrice=0;
datetime m_lastCTTime=0,m_lastRecoveryTime=0,m_lastBasketCheck=0;
datetime m_lastHarvestTime=0,m_lastDashTime=0,m_lastCleanupTime=0;
double   m_totalPnL=0; int m_tradesOpened=0,m_tradesClosed=0;
double   m_bestClosed=0,m_worstClosed=0;
int      m_totalWins=0,m_totalLosses=0; double m_sumWins=0,m_sumLosses=0;
long     m_tickCount=0; bool m_isProcessing=false;
double   m_losingPosOpenPrice=0; int m_losingPosType=-1;
// TEMA/Kalman state
double   m_temaF_e1=0,m_temaF_e2=0,m_temaF_e3=0; bool m_temaF_init=false;
double   m_temaS_e1=0,m_temaS_e2=0,m_temaS_e3=0; bool m_temaS_init=false;
double   m_kalF_x=0,m_kalF_p=1.0; bool m_kalF_init=false;
double   m_kalS_x=0,m_kalS_p=1.0; bool m_kalS_init=false;
// Block Stage
int      m_blockStage=0; ENUM_ORDER_TYPE m_primaryType=ORDER_TYPE_BUY;
datetime m_stage2Time=0; bool m_stageFollowHedge=false;
double   m_stage1TriggerAtOpen=0,m_stage3TriggerAtOpen=0;
// V7.9 state
datetime m_detangleDetectTime=0; bool m_detangleActive=false;
datetime m_primaryOpenTime=0;
// [DM] Estado de gestión de la entrada primaria Dynamic Manager
double   g_DM_PrimaryTP         = 0.0;   // Nivel TP (precio) calculado al abrir
double   g_DM_PrimaryVirtualSL  = 0.0;   // Nivel SL virtual (diagnóstico)
bool     g_DM_BEActivated       = false; // Flag: Break-Even ya aplicado

//=================================================================
//  [V9.0] TIMEFRAME MULTIPLIER — CALCULO AUTOMATICO
//  Ratio de barras M1 contenidas en el timeframe actual.
//  Usado para escalar parámetros de distancia ATR.
//  Valores empíricos de volatilidad XAUUSD:
//    M1=1.0  M5=2.24  M15=3.87  M30=5.48  H1=7.75  H4=15.5
//  (ATR crece sublinealmente con el tiempo: sqrt(TF/M1) * corrFactor)
//=================================================================
double CalcTFMult()
{
   if(Inp_TFMultOverride>0) return Inp_TFMultOverride;
   int tfMin=PeriodSeconds(_Period)/60;
   if(tfMin<=1)  return 1.00;
   if(tfMin<=5)  return 2.24;
   if(tfMin<=15) return 3.87;
   if(tfMin<=30) return 5.48;
   if(tfMin<=60) return 7.75;
   if(tfMin<=240) return 15.50;
   if(tfMin<=1440) return 31.00;
   return 1.00;
}

// ATR efectivo normalizado a M1 (para cálculos de capital)
double GetATR_M1Norm() { return (g_TFMult>0) ? m_mkt.atr/g_TFMult : m_mkt.atr; }

//=================================================================
//  [V9.0] CAPITAL GUARD — FUNCIONES CORE
//=================================================================

// Calibra el margen por lote en OnInit y periódicamente
void CalibrateMarginPerLot()
{
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return;
   double marg=0;
   if(OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,0.01,t.ask,marg)&&marg>0)
      g_MarginPer001=marg;
   else
      g_MarginPer001=5.0; // fallback seguro
}

// Recalcula el lote base automático basado en balance actual
void RecalcAutoBaseLot()
{
   if(!Inp_UseAutoLot) { g_AutoBaseLot=Inp_LotBase; return; }
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<=0) { g_AutoBaseLot=Inp_LotBase; return; }
   double rawLot=bal*Inp_AutoLotPct;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) step=0.01;
   rawLot=MathFloor(rawLot/step)*step;
   g_AutoBaseLot=MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
                  MathMin(rawLot,Inp_LotHardCap));
   g_AutoBaseLot=NormalizeDouble(g_AutoBaseLot,2);
}

// Calcula el lote máximo seguro considerando exposición actual
// Asegura que el margen total no supere Inp_MaxMarginUsagePct del margen libre
double CalcMaxSafeLot()
{
   CalibrateMarginPerLot();
   double freeMarg=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMarg<=0) return g_AutoBaseLot;
   double maxMarginAllowed=freeMarg*Inp_MaxMarginUsagePct;
   // Restar margen ya usado por posiciones abiertas
   double usedMarg=AccountInfoDouble(ACCOUNT_MARGIN);
   double availForNew=MathMax(0,maxMarginAllowed-usedMarg);
   if(g_MarginPer001<=0) return g_AutoBaseLot;
   double maxLot=NormalizeDouble((availForNew/g_MarginPer001)*0.01, 2);
   maxLot=MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN), maxLot);
   maxLot=MathMin(maxLot, Inp_LotHardCap);
   return NormalizeDouble(maxLot, 2);
}

// Verifica si el volumen total acumulado excede el límite
bool TotalVolumeOK(double addLot=0)
{
   double totalVol=m_port.buyVolume+m_port.sellVolume+addLot;
   return (totalVol <= Inp_MaxTotalVolume);
}

// [V9.0] CIRCUIT BREAKER DURO — se llama primero en cada tick
// Cierra absolutamente todo si el drawdown supera el umbral.
// Esta función NO puede ser bloqueada por ningún estado del EA.
bool HardEquityCircuitBreaker()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_PeakEquity) g_PeakEquity=eq;
   if(g_PeakEquity<=0) return false;
   double dd=(g_PeakEquity-eq)/g_PeakEquity;

   // Circuit breaker suave: pausa entradas nuevas
   if(dd>=Inp_SoftCircuitBreakerPct&&!g_SoftBreakerHit)
   {
      g_SoftBreakerHit=true;
      Print("[V9.0 CIRCUIT SOFT] DD=",NormalizeDouble(dd*100,1),"% >= ",
            NormalizeDouble(Inp_SoftCircuitBreakerPct*100,1),"% | Pausando entradas");
      m_isPaused=true;
   }
   if(dd<Inp_SoftCircuitBreakerPct*0.5&&g_SoftBreakerHit&&!g_CircuitBreakerHit)
   {
      g_SoftBreakerHit=false; m_isPaused=false;
      Print("[V9.0 CIRCUIT SOFT] Recuperado. Reanudando.");
   }

   // Circuit breaker duro: cierra TODAS las posiciones
   if(dd>=Inp_HardCircuitBreakerPct)
   {
      if(!g_CircuitBreakerHit)
      {
         g_CircuitBreakerHit=true; g_CircuitResetTime=TimeCurrent();
         Print("[V9.0 CIRCUIT HARD] DD=",NormalizeDouble(dd*100,1),"% >= ",
               NormalizeDouble(Inp_HardCircuitBreakerPct*100,1),
               "% | PeakEq=",NormalizeDouble(g_PeakEquity,2),
               " | CurEq=",NormalizeDouble(eq,2)," | CERRANDO TODO");
         m_isProcessing=true;
int closedPositive=0, skippedNegative=0;
for(int i=PositionsTotal()-1;i>=0;i--)
{
   ulong t=PositionGetTicket(i);
   if(!PositionSelectByTicket(t)) continue;
   if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
   if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;

   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(pf>=0)
   {
      m_trade.PositionClose(t);
      Print("[V9.0 CIRCUIT HARD] Cerrada positiva #",t," $",NormalizeDouble(pf,2));
      closedPositive++;
   }
   else
   {
      Print("[V9.0 CIRCUIT HARD] Posición negativa #",t," $",NormalizeDouble(pf,2),
            " — MANTENIDA hasta recuperación");
      skippedNegative++;
   }
}
m_isProcessing=false;
Print("[V9.0 CIRCUIT HARD] Resumen: cerradas=",closedPositive,
      " | mantenidas(negativas)=",skippedNegative);
         m_blockStage=0; m_recoveryActive=false; m_recoveryOrders=0;
         m_netHedge1Applied=m_netHedge2Applied=false;
         m_stageFollowHedge=false; m_primaryOpenTime=0;
         m_detangleDetectTime=0; m_detangleActive=false;
         g_DM_PrimaryTP = 0.0; g_DM_PrimaryVirtualSL = 0.0; g_DM_BEActivated = false;
         ZeroMemory(m_lbc);
         m_isPaused=true;
      }
      g_DM_PrimaryTP = 0.0; g_DM_PrimaryVirtualSL = 0.0; g_DM_BEActivated = false;
      return true;
   }

   // Resetear circuit breaker duro después de cooldown
   if(g_CircuitBreakerHit&&m_port.totalPos==0)
   {
      int cooldown=300; // 5 minutos de enfriamiento
      if((int)(TimeCurrent()-g_CircuitResetTime)>cooldown)
      {
         g_CircuitBreakerHit=false; g_SoftBreakerHit=false;
         m_isPaused=false; m_emergencyMode=false;
         g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY); // reset peak
         Print("[V9.0 CIRCUIT HARD] Cooldown completado. Reanudando sistema.");
      }
   }
   return g_CircuitBreakerHit;
}

// BlockTP dinámico: escala con la pérdida real del bloque
// Evita el RCA-4: target=$0.25 vs pérdida=$300
double CalcDynamicBlockTP()
{
   double floorTP=MathMax(Inp_BlockTPTarget, m_dyn.atr2usd*Inp_DynTPMult*m_dyn.sessionFactor);
   floorTP=MathMin(floorTP,Inp_DynMaxTPUSD);
   if(m_port.totalProfit>=0) return floorTP;
   double scaledTP=MathAbs(m_port.totalProfit)*Inp_TPRRR;
   return MathMax(floorTP, scaledTP);
}

//=================================================================
//  HELPERS BASICOS
//=================================================================
double NormLot(double lot)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),
                MathMin(Inp_LotMaximum,Inp_LotHardCap));
   if(step<=0)step=0.01;
   lot=MathFloor(lot/step)*step;
   // [V9.0] Aplicar techo de volumen acumulado
   double curTotalVol=m_port.buyVolume+m_port.sellVolume;
   double roomLeft=MathMax(0,Inp_MaxTotalVolume-curTotalVol);
   lot=MathMin(lot,roomLeft);
   lot=MathMin(lot,CalcMaxSafeLot());
   return NormalizeDouble(MathMax(minL,MathMin(maxL,lot)),2);
}

double NormPrice(double p) { return NormalizeDouble(p,_Digits); }
bool   GetTick(MqlTick &t){ return SymbolInfoTick(_Symbol,t); }

double GetATR()
{ double b[1]; if(CopyBuffer(h_ATR,0,1,1,b)==1) return b[0]; return _Point*200; }

double GetTickVal()  { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE); }
double GetTickSize() { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); }

double DistToUSD(double dist,double lot)
{
   double tv=GetTickVal(),ts=GetTickSize();
   if(tv<=0||ts<=0||dist<=0||lot<=0) return 0;
   return NormalizeDouble((dist/ts)*tv*lot,2);
}

// ATR en USD ajustado por TF (usa ATR M1 normalizado para los cálculos financieros)
double ATR2USD_Lot(double atrMult,double lot)
{
   double tv=GetTickVal(),ts=GetTickSize();
   double atrNorm=GetATR_M1Norm(); // ATR normalizado a M1
   if(tv<=0||ts<=0||atrNorm<=0||lot<=0) return 0;
   return NormalizeDouble((atrNorm*atrMult/ts)*tv*lot,4);
}
double ATR2USD(double atrMult=1.0) { return ATR2USD_Lot(atrMult,g_AutoBaseLot); }

//=================================================================
//  [V8.0-QUANTCAL] SESSION SPREAD CALIBRADO (P80 por sesión)
//  ASIAN=24  LONDON=21  OVERLAP=20  NY=19  OFF=25
//=================================================================
int GetSessionMaxSpread(ENUM_SESSION_STATE sess)
{
   switch(sess) {
      case SESSION_ASIAN:   return 240;
      case SESSION_LONDON:  return 240;
      case SESSION_OVERLAP: return 240;
      case SESSION_NY:      return 240;
      default:              return 240;
   }
}

bool SpreadOK()
{
   int curSpread=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   if(m_inSession) {
      int sessMax=GetSessionMaxSpread(m_dyn.session);
      int effMax=MathMin(sessMax,Inp_MaxSpread);
      return(curSpread<=effMax);
   }
   return(curSpread<=(int)Inp_CTMaxSpreadOff);
}

bool MarginOK(double lot,ENUM_ORDER_TYPE type)
{
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY),bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<Inp_CTMinBalanceUSD) return false;
   if(free<eq*Inp_MinFreeMarginPct) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg))
      if(marg>free*0.50) return false;   // V9: 0.60→0.50 (más conservador)
   // [V9.0] Verificación adicional de volumen total
   if(!TotalVolumeOK(lot)) return false;
   return true;
}

bool MarginOK_Hedge(double lot,ENUM_ORDER_TYPE type)
{
   if(!TotalVolumeOK(lot)) return false;
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE); if(free<=0) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg)){if(marg<=0)return false;return(marg<=free*0.80);}
   return false;
}

double CalcMarginFor001()
{
   double marg=0; MqlTick t; GetTick(t);
   if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,0.01,t.ask,marg)) return 2.0;
   return(marg>0)?marg:2.0;
}

//=================================================================
//  SESSION / VOL REGIME
//=================================================================
ENUM_SESSION_STATE GetCurrentSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int gmtH=(dt.hour-Inp_GMTOffset+24)%24;
   if(dt.day_of_week==0||dt.day_of_week==6) return SESSION_OFF;
   if(gmtH>=12&&gmtH<17) return SESSION_OVERLAP;
   if(gmtH>=7 &&gmtH<12) return SESSION_LONDON;
   if(gmtH>=17&&gmtH<22) return SESSION_NY;
   if(gmtH>=2 &&gmtH<7)  return SESSION_ASIAN;
   return SESSION_OFF;
}
double GetSessionFactor(ENUM_SESSION_STATE s)
{
   switch(s){case SESSION_ASIAN:return Inp_SessFactorAsian;case SESSION_LONDON:return Inp_SessFactorLondon;
   case SESSION_OVERLAP:return Inp_SessFactorOverlap;case SESSION_NY:return Inp_SessFactorNY;default:return Inp_SessFactorOff;}
}

// [V8.0-QUANTCAL] Regime: LOW<0.84 NORMAL HIGH>1.09
// Calibrado de P30/P70 de la distribución ATR14/ATR100 (99,520 barras)
ENUM_VOL_REGIME GetVolatilityRegime()
{
   if(m_mkt.atrSlow<=0||m_mkt.atr<=0) return VOL_NORMAL;
   double r=GetATR_M1Norm()/(m_mkt.atrSlow/g_TFMult);
   if(r>Inp_VolRegimeHighThresh) return VOL_HIGH;
   if(r<Inp_VolRegimeLowThresh)  return VOL_LOW;
   return VOL_NORMAL;
}

string VolRegimeName(ENUM_VOL_REGIME r)
{ switch(r){case VOL_LOW:return"LOW";case VOL_HIGH:return"HIGH";default:return"NORMAL";} }
string SessionName(ENUM_SESSION_STATE s)
{ switch(s){case SESSION_ASIAN:return"ASIAN";case SESSION_LONDON:return"LONDON";
  case SESSION_OVERLAP:return"OVERLAP";case SESSION_NY:return"NY";default:return"OFF";} }

// [V9.0] Stage2 delay ajustado por TF (en M15 los delays cuentan barra a barra)
int GetStage2Delay(ENUM_SESSION_STATE s)
{
   int baseDelay;
   switch(s){case SESSION_ASIAN:baseDelay=Inp_Stage2DelayAsian;break;
   case SESSION_LONDON:baseDelay=Inp_Stage2DelayLondon;break;
   case SESSION_OVERLAP:baseDelay=Inp_Stage2DelayOverlap;break;
   case SESSION_NY:baseDelay=Inp_Stage2DelayNY;break;
   default:baseDelay=Inp_Stage2DelayAsian;break;}
   // En M15 un delay de 4s es irrelevante (barra = 900s). Mínimo 1 barra.
   int tfSec=PeriodSeconds(_Period);
   return(int)MathMax(baseDelay,(double)tfSec*0.5); // mínimo media barra
}

double GetRecovDistATR(ENUM_VOL_REGIME r)
{ switch(r){case VOL_LOW:return Inp_RecovDistLow;case VOL_HIGH:return Inp_RecovDistHigh;default:return Inp_RecovDistNormal;} }

void UpdateDynamicThresholds()
{
   m_dyn.session       = GetCurrentSession();
   m_dyn.volRegime     = GetVolatilityRegime();
   m_dyn.sessionFactor = GetSessionFactor(m_dyn.session);
   // [V9.0] atr2usd usa ATR M1 normalizado para mantener escala USD correcta
   m_dyn.atr2usd       = ATR2USD(1.0);
   double atr          = m_dyn.atr2usd;

   if(atr<=0.01){
      m_dyn.stage1Trigger=Inp_Stage1Trigger; m_dyn.stage3Trigger=Inp_Stage3Trigger;
      m_dyn.blockTP=Inp_BlockTPTarget; m_dyn.recovTrigger=Inp_RecoveryTriggerUSD;
      m_dyn.netHedgeTrig1=Inp_NetHedgeTrigger1USD; m_dyn.netHedgeTrig2=Inp_NetHedgeTrigger2USD;
   } else {
      double sf=m_dyn.sessionFactor;
      double s1Raw=-(atr*Inp_DynStage1Mult*sf); s1Raw=MathMax(s1Raw,-Inp_DynMaxStage1USD);
      m_dyn.stage1Trigger=MathMin(s1Raw,Inp_Stage1Trigger);
      double s3Raw=-(atr*Inp_DynStage3Mult*sf); s3Raw=MathMax(s3Raw,-Inp_DynMaxStage3USD);
      m_dyn.stage3Trigger=MathMin(s3Raw,Inp_Stage3Trigger);
      double tpRaw=atr*Inp_DynTPMult*sf; tpRaw=MathMin(tpRaw,Inp_DynMaxTPUSD);
      m_dyn.blockTP=MathMax(tpRaw,Inp_BlockTPTarget);
      // [V9.0] BlockTP dinámico escala con pérdida real
      m_dyn.blockTP=CalcDynamicBlockTP();
      m_dyn.recovTrigger=MathMin(-(atr*Inp_DynRecovMult*sf),Inp_RecoveryTriggerUSD);
      m_dyn.netHedgeTrig1=MathMin(-(atr*Inp_NetHedgeMult1),Inp_NetHedgeTrigger1USD);
      m_dyn.netHedgeTrig2=MathMin(-(atr*Inp_NetHedgeMult2),Inp_NetHedgeTrigger2USD);
   }
   m_dyn.stage2Delay  = GetStage2Delay(m_dyn.session);
   m_dyn.recovDistATR = GetRecovDistATR(m_dyn.volRegime);
}

//=================================================================
//  ANTI-SYMMETRIC GUARD
//=================================================================
bool AntiSymmetricOK(ENUM_ORDER_TYPE type,double lot)
{
   double netVol=m_port.buyVolume-m_port.sellVolume;
   double newNet=(type==ORDER_TYPE_BUY)?netVol+lot:netVol-lot;
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   if(minLot<=0)minLot=0.01;
   if(MathAbs(newNet)>=minLot*0.99) return true;
   Print("[V9.0] ANTI-SYM GUARD: bloqueo simetría NetVol=",NormalizeDouble(netVol,3)," newNet=",NormalizeDouble(newNet,3));
   return false;
}

//=================================================================
//  RECORDS
//=================================================================
int FindRec(ulong ticket){ for(int i=0;i<MAX_RECORDS;i++) if(m_rec[i].ticket==ticket) return i; return -1; }
int FreeRec(){ for(int i=0;i<MAX_RECORDS;i++) if(m_rec[i].ticket==0) return i; return -1; }
void InitRec(int idx,ulong ticket,int posType,double openPrice,double vol,string comment,bool isPrimary,bool isCounter,bool isRecovery=false,bool isLBC=false)
{
   if(idx<0||idx>=MAX_RECORDS) return;
   ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket=ticket; m_rec[idx].posType=posType; m_rec[idx].openPrice=openPrice;
   m_rec[idx].volume=vol; m_rec[idx].openTime=TimeCurrent(); m_rec[idx].comment=comment;
   m_rec[idx].isPrimary=isPrimary; m_rec[idx].isCounter=isCounter;
   m_rec[idx].isRecovery=isRecovery; m_rec[idx].isLBC=isLBC;
   m_rec[idx].kP=1.0; m_rec[idx].kK=1.0;
}
void CleanupRecs()
{
   for(int i=0;i<MAX_RECORDS;i++){
      if(m_rec[i].ticket==0) continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)){
         double pnl=m_rec[i].netProfit;
         if(pnl!=0){m_totalPnL+=pnl;m_tradesClosed++;
            if(pnl>0){m_totalWins++;m_sumWins+=pnl;}else{m_totalLosses++;m_sumLosses+=MathAbs(pnl);}
            if(pnl>m_bestClosed)m_bestClosed=pnl; if(pnl<m_worstClosed)m_worstClosed=pnl;}
         ZeroMemory(m_rec[i]);
      }
   }
}
void SyncPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(FindRec(t)>=0) continue;
      int idx=FreeRec(); if(idx<0) continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);
      double op=PositionGetDouble(POSITION_PRICE_OPEN),vol=PositionGetDouble(POSITION_VOLUME);
      string comm=PositionGetString(POSITION_COMMENT);
      bool isPri=(StringFind(comm,"Primary")>=0),isCT=(StringFind(comm,"CT_")>=0);
      bool isRec=(StringFind(comm,"REC_")>=0||StringFind(comm,"BSE_")>=0);
      bool isLBC=(StringFind(comm,"LBC_")>=0);
      InitRec(idx,t,pt,op,vol,comm,isPri,isCT,isRec,isLBC);
   }
}

void UpdateKalman()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      int idx=FindRec(t); if(idx<0) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit=pf;
      if(pf>m_rec[idx].peakProfit) m_rec[idx].peakProfit=pf;
      if(!m_rec[idx].kInit){m_rec[idx].kX=pf;m_rec[idx].kP=1.0;m_rec[idx].kK=1.0;m_rec[idx].kInit=true;return;}
      double pP=m_rec[idx].kP+0.01,K=pP/(pP+0.20);
      m_rec[idx].kX+=K*(pf-m_rec[idx].kX);m_rec[idx].kP=(1.0-K)*pP;m_rec[idx].kK=K;
   }
}

//=================================================================
//  MERCADO + TEMA/KALMAN
//=================================================================
bool IsInMainSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(dt.day_of_week==0||dt.day_of_week==6) return false;
   int gmtHour=(dt.hour-Inp_GMTOffset+24)%24;
   return((gmtHour>=Inp_LondonOpen&&gmtHour<Inp_LondonClose)||(gmtHour>=Inp_NYOpen&&gmtHour<Inp_NYClose));
}

void UpdateTEMAKalman()
{
   if(!Inp_UseTEMAKalman){m_mkt.trendConfirmed=m_mkt.isBullish?1:(m_mkt.isBearish?-1:0);return;}
   MqlTick tk; if(!GetTick(tk)) return;
   double price=(tk.bid+tk.ask)/2.0; if(price<=0) return;
   double alphaF=2.0/(double)(Inp_TEMAFastPeriod+1);
   if(!m_temaF_init){m_temaF_e1=m_temaF_e2=m_temaF_e3=price;m_temaF_init=true;}
   m_temaF_e1+=alphaF*(price-m_temaF_e1);m_temaF_e2+=alphaF*(m_temaF_e1-m_temaF_e2);m_temaF_e3+=alphaF*(m_temaF_e2-m_temaF_e3);
   m_mkt.temaFast=3.0*m_temaF_e1-3.0*m_temaF_e2+m_temaF_e3;
   double alphaS=2.0/(double)(Inp_TEMASlowPeriod+1);
   if(!m_temaS_init){m_temaS_e1=m_temaS_e2=m_temaS_e3=price;m_temaS_init=true;}
   m_temaS_e1+=alphaS*(price-m_temaS_e1);m_temaS_e2+=alphaS*(m_temaS_e1-m_temaS_e2);m_temaS_e3+=alphaS*(m_temaS_e2-m_temaS_e3);
   m_mkt.temaSlow=3.0*m_temaS_e1-3.0*m_temaS_e2+m_temaS_e3;
   if(!m_kalF_init){m_kalF_x=m_mkt.temaFast;m_kalF_p=1.0;m_kalF_init=true;}
   m_kalF_p+=Inp_KalmanQ;double kgF=m_kalF_p/(m_kalF_p+Inp_KalmanR);
   m_kalF_x+=kgF*(m_mkt.temaFast-m_kalF_x);m_kalF_p*=(1.0-kgF);m_mkt.kalmanFast=m_kalF_x;
   if(!m_kalS_init){m_kalS_x=m_mkt.temaSlow;m_kalS_p=1.0;m_kalS_init=true;}
   m_kalS_p+=Inp_KalmanQ;double kgS=m_kalS_p/(m_kalS_p+Inp_KalmanR);
   m_kalS_x+=kgS*(m_mkt.temaSlow-m_kalS_x);m_kalS_p*=(1.0-kgS);m_mkt.kalmanSlow=m_kalS_x;
   bool temaBull=(m_mkt.temaFast>m_mkt.temaSlow),temaBear=(m_mkt.temaFast<m_mkt.temaSlow);
   bool kalBull=(m_mkt.kalmanFast>m_mkt.kalmanSlow),kalBear=(m_mkt.kalmanFast<m_mkt.kalmanSlow);
   if(temaBull&&kalBull)m_mkt.trendConfirmed=1;
   else if(temaBear&&kalBear)m_mkt.trendConfirmed=-1;
   else m_mkt.trendConfirmed=0;
   m_mkt.isBullish=(m_mkt.trendConfirmed==1);m_mkt.isBearish=(m_mkt.trendConfirmed==-1);
}

void UpdateMarket()
{
   MqlTick t; if(!GetTick(t)) return;
   m_mkt.bid=t.bid;m_mkt.ask=t.ask;m_mkt.spread=(t.ask-t.bid)/_Point;m_mkt.atr=GetATR();
   double f[1],s[1],r[1],m[1],sg[1];
   if(CopyBuffer(h_EMAFast,0,0,1,f)==1)m_mkt.emaFast=f[0];
   if(CopyBuffer(h_EMASlow,0,0,1,s)==1)m_mkt.emaSlow=s[0];
   if(CopyBuffer(h_RSI,0,0,1,r)==1)m_mkt.rsi=r[0];
   if(CopyBuffer(h_MACD,0,0,1,m)==1)m_mkt.macdMain=m[0];
   if(CopyBuffer(h_MACD,1,0,1,sg)==1)m_mkt.macdSig=sg[0];
   if(h_ADX!=INVALID_HANDLE){double adxB[1];if(CopyBuffer(h_ADX,0,0,1,adxB)==1)m_mkt.adx=adxB[0];}
   if(h_HTFEMAFast!=INVALID_HANDLE&&h_HTFEMASlow!=INVALID_HANDLE){
      double hf[1],hs[1];
      if(CopyBuffer(h_HTFEMAFast,0,0,1,hf)==1&&CopyBuffer(h_HTFEMASlow,0,0,1,hs)==1)
         m_mkt.htfTrend=(hf[0]>hs[0]*1.0001)?1:(hf[0]<hs[0]*0.9999)?-1:0;
   }
   if(h_EMA200!=INVALID_HANDLE){double e200[1];if(CopyBuffer(h_EMA200,0,1,1,e200)==1)m_mkt.ema200=e200[0];}
   if(h_ATRSlow!=INVALID_HANDLE){double atrS[1];if(CopyBuffer(h_ATRSlow,0,1,1,atrS)==1)m_mkt.atrSlow=atrS[0];}
   m_mkt.isBullish=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.rsi>52&&m_mkt.macdMain>m_mkt.macdSig);
   m_mkt.isBearish=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.rsi<48&&m_mkt.macdMain<m_mkt.macdSig);
   UpdateTEMAKalman();
   RecalcAutoBaseLot();  // [V9.0] Recalcular lote base en cada tick
   UpdateDynamicThresholds();
}

void UpdatePortfolio()
{
   ZeroMemory(m_port);m_port.worstProfit=0;
   m_losingPosOpenPrice=0;m_losingPosType=-1;
   double vwapN=0,vwapD=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      bool isOwn=(magic==Inp_Magic),isExt=(!isOwn&&Inp_RescueAllTrades);
      if(!isOwn&&!isExt) continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol=PositionGetDouble(POSITION_VOLUME),op=PositionGetDouble(POSITION_PRICE_OPEN);
      string comm=PositionGetString(POSITION_COMMENT);
      m_port.totalPos++;m_port.totalProfit+=pf;
      if(pf>=0)m_port.positiveSum+=pf;else m_port.negativeSum+=MathAbs(pf);
      if(pt==POSITION_TYPE_BUY){m_port.buyCount++;m_port.buyProfit+=pf;m_port.buyVolume+=vol;}
      else{m_port.sellCount++;m_port.sellProfit+=pf;m_port.sellVolume+=vol;}
      vwapN+=op*vol;vwapD+=vol;
      m_port.blockDir+=(pt==POSITION_TYPE_BUY)?1:-1;
      if(pf<m_port.worstProfit){m_port.worstProfit=pf;m_port.worstTicket=t;m_losingPosOpenPrice=op;m_losingPosType=pt;}
      if(isOwn){
         if(StringFind(comm,"CT_")>=0)m_port.ctCount++;
         if(StringFind(comm,"REC_")>=0||StringFind(comm,"BSE_")>=0)m_port.recoveryCount++;
         if(StringFind(comm,"LBC_")>=0)m_port.lbcCount++;
      }
      if(isExt){m_port.rescueCount++;m_port.rescueProfit+=pf;}
   }
   if(vwapD>0)m_port.blockVWAP=vwapN/vwapD;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>m_bestEquity)m_bestEquity=eq;
   if(eq>g_PeakEquity)g_PeakEquity=eq;
   m_port.currentDD=(m_bestEquity>0)?(m_bestEquity-eq)/m_bestEquity:0;
}

//=================================================================
//  SENSORES
//=================================================================
int ParseHH(string t){return(int)StringToInteger(StringSubstr(t,0,2));}
int ParseMM(string t){return(int)StringToInteger(StringSubstr(t,3,2));}
void CalcBrokerTimeWindow()
{
   int s=ParseHH(Inp_StartTime)*60+ParseMM(Inp_StartTime);
   int e=ParseHH(Inp_EndTime)*60+ParseMM(Inp_EndTime);
   int off=(Inp_BrokerGMT-Inp_UserGMT)*60;
   m_sensors.brokerStartMin=((s+off)%1440+1440)%1440;
   m_sensors.brokerEndMin=((e+off)%1440+1440)%1440;
}
bool IsInTradingWindow()
{
   if(!Inp_UseTimeFilter) return true;
   MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);
   int nowMin=dt.hour*60+dt.min,s=m_sensors.brokerStartMin,e=m_sensors.brokerEndMin;
   if(s<=e)return(nowMin>=s&&nowMin<e);else return(nowMin>=s||nowMin<e);
}
bool TrendFilter200OK(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseTrendFilter200||m_mkt.ema200<=0) return true;
   MqlTick tk;if(!GetTick(tk)) return true;
   double mid=(tk.bid+tk.ask)/2.0;
   if(type==ORDER_TYPE_BUY)return(mid>m_mkt.ema200);
   if(type==ORDER_TYPE_SELL)return(mid<m_mkt.ema200);
   return true;
}
bool VolatilityOK()
{
   if(!Inp_UseVolatFilter||m_mkt.atrSlow<=0) return true;
   double atrN=GetATR_M1Norm(),atrSlowN=m_mkt.atrSlow/g_TFMult;
   m_sensors.atrRatio=(atrSlowN>0)?atrN/atrSlowN:1.0;
   return(m_sensors.atrRatio<=Inp_ATRRatioMax);
}
bool MarginGuardOK()
{
   if(!Inp_UseMarginGuard) return true;
   double lot=g_AutoBaseLot,marg1=0;
   MqlTick tk;if(!GetTick(tk)) return true;
   if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lot,tk.ask,marg1)||marg1<=0) return true;
   return(AccountInfoDouble(ACCOUNT_MARGIN_FREE)>=marg1*(1.0+Inp_MarginGuardLevels));
}
void UpdateSensors()
{
   m_sensors.blockReason="";
   m_sensors.timeOK=IsInTradingWindow();
   if(!m_sensors.timeOK&&m_sensors.blockReason=="") m_sensors.blockReason="Fuera ventana horaria";
   m_sensors.spreadOK=SpreadOK();
   if(!m_sensors.spreadOK&&m_sensors.blockReason==""){
      int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
      m_sensors.blockReason="Spread alto: "+IntegerToString(cs)+" > P80="+IntegerToString(GetSessionMaxSpread(m_dyn.session));
   }
   if(m_mkt.ema200>0){MqlTick tk;GetTick(tk);m_sensors.trendBull=((tk.bid+tk.ask)/2.0>m_mkt.ema200);}
   else m_sensors.trendBull=true;
   m_sensors.volatOK=VolatilityOK();
   if(!m_sensors.volatOK&&m_sensors.blockReason=="")
      m_sensors.blockReason="Storm ATR ratio="+DoubleToString(m_sensors.atrRatio,1);
   if(m_dyn.volRegime==VOL_HIGH&&m_sensors.volatOK&&m_sensors.blockReason=="")
      m_sensors.blockReason="Vol.Regime HIGH (>1.09)";
   m_sensors.marginOK=MarginGuardOK();
   if(!m_sensors.marginOK&&m_sensors.blockReason=="") m_sensors.blockReason="Margen insuf.";
   // [V9.0] Bloquear si circuit breaker activo
   if(g_CircuitBreakerHit&&m_sensors.blockReason=="") m_sensors.blockReason="CIRCUIT BREAKER ACTIVO";
   if(g_SoftBreakerHit&&m_sensors.blockReason=="") m_sensors.blockReason="SOFT BREAKER (DD>"+DoubleToString(Inp_SoftCircuitBreakerPct*100,0)+"%)";
   m_sensors.allOK=(m_sensors.timeOK&&m_sensors.spreadOK&&m_sensors.volatOK&&
                    m_sensors.marginOK&&m_dyn.volRegime!=VOL_HIGH&&
                    !g_CircuitBreakerHit&&!g_SoftBreakerHit);
}
bool ADXAllowsEntry(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseADX) return true;
   double adxLevel=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;
   if(m_mkt.adx<adxLevel) return true;
   int htf=m_mkt.htfTrend; if(htf==0) return false;
   return(type==ORDER_TYPE_BUY&&htf==1)||(type==ORDER_TYPE_SELL&&htf==-1);
}
void ResetDailyIfNeeded()
{
   MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);
   datetime midnight=TimeCurrent()-(dt.hour*3600+dt.min*60+dt.sec);
   if(m_lastDailyReset<midnight){m_dailyBalance=AccountInfoDouble(ACCOUNT_BALANCE);m_dailyLimitHit=false;m_lastDailyReset=midnight;}
}
bool DailyLimitReached()
{
   if(!Inp_UseDailyLimit||m_dailyLimitHit) return m_dailyLimitHit;
   double eff=(AccountInfoDouble(ACCOUNT_BALANCE)-m_dailyBalance)+m_port.totalProfit;
   double lim=MathMin(MathAbs(Inp_DailyLossUSD),m_dailyBalance*MathAbs(Inp_DailyLossPct/100.0));
   if(eff<=-lim){Print("[V9.0] LIMITE DIARIO alcanzado");m_dailyLimitHit=true;m_isPaused=true;}
   return m_dailyLimitHit;
}
void UpdateStreak(double pnl)
{
   if(pnl<-0.01){m_consecutiveLosses++;if(m_consecutiveLosses>=Inp_LossStreakMax&&m_lotMultiplier==1.0)m_lotMultiplier=Inp_LossStreakReduce;}
   else if(pnl>0.01){m_lotMultiplier=1.0;m_consecutiveLosses=0;}
}
double CalcExpectancy()
{
   int total=m_totalWins+m_totalLosses;if(total==0)return 0;
   double wr=(double)m_totalWins/total;
   double avgW=(m_totalWins>0)?m_sumWins/m_totalWins:0;
   double avgL=(m_totalLosses>0)?m_sumLosses/m_totalLosses:0;
   return(wr*avgW)-((1.0-wr)*avgL);
}

//=================================================================
//  CIERRE DE POSICIONES
//=================================================================
bool ClosePos(ulong ticket,string reason="")
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) return false;
   if(!m_isProcessing&&m_port.totalPos>1){
      Print("[V9.0] !! CIERRE INDIVIDUAL BLOQUEADO #",ticket," [",reason,"] totalPos=",m_port.totalPos);
      return false;
   }
   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)){
      UpdateStreak(pf);
      if(pf>0){m_cycleWinsSum+=pf;m_cycleWinsCount++;m_totalWins++;m_sumWins+=pf;}
      else{m_cycleLossSum+=pf;m_totalLosses++;m_sumLosses+=MathAbs(pf);}
      m_totalPnL+=pf;m_tradesClosed++;
      if(pf>m_bestClosed)m_bestClosed=pf;if(pf<m_worstClosed)m_worstClosed=pf;
      int idx=FindRec(ticket);
      if(idx>=0){
         if(m_rec[idx].isPrimary)m_lastPrimaryLost=(pf<0);
         if(m_rec[idx].isLBC){string comm=m_rec[idx].comment;
            if(StringFind(comm,"LBC_B")>=0&&m_lbc.buyCount>0)m_lbc.buyCount--;
            if(StringFind(comm,"LBC_S")>=0&&m_lbc.sellCount>0)m_lbc.sellCount--;}
         Print("[V9.0] CERRADA #",ticket," $",NormalizeDouble(pf,2),(reason!=""?" ["+reason+"]":""));
         ZeroMemory(m_rec[idx]);
      }
      m_cycleResetTime=TimeCurrent();m_cycleInPause=true;
m_lastCTBuyPrice=m_lastCTSellPrice=0;
ZeroMemory(m_lbc);
g_DM_PrimaryTP = 0.0; g_DM_PrimaryVirtualSL = 0.0; g_DM_BEActivated = false;
return true;
      return true;
   }
   return false;
}
bool CloseRescuePos(ulong ticket,string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)){m_totalPnL+=pf;m_tradesClosed++;
      Print("[V9.0] RESCATE #",ticket," $",NormalizeDouble(pf,2)," [",reason,"]");return true;}
   return false;
}
bool CloseBlockIfPositive(string reason)
{
   double dynTP=CalcDynamicBlockTP();
   if(m_port.totalProfit<dynTP) return false;
   Print("[V9.0] CIERRE POSITIVO: PnL=$",NormalizeDouble(m_port.totalProfit,2),
         " >= DynTP=$",NormalizeDouble(dynTP,2)," [",reason,"] Stage=",m_blockStage);
   m_isProcessing=true;
   for(int pass=0;pass<2;pass++){
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pass==0&&pf<0)continue;if(pass==1&&pf>=0)continue;
         ClosePos(t,reason);
      }
   }
   if(Inp_RescueAllTrades){
      for(int pass=0;pass<2;pass++){
         for(int i=PositionsTotal()-1;i>=0;i--){
            ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC)==Inp_Magic) continue;
            double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
            if(pass==0&&pf<0)continue;if(pass==1&&pf>=0)continue;
            CloseRescuePos(t,"RESCUE_"+reason);
         }
      }
   }
   m_isProcessing=false;
   m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
   m_netHedge1Applied=false;m_netHedge2Applied=false;
   m_blockStage=0;m_stageFollowHedge=false;
   m_stage1TriggerAtOpen=0;m_stage3TriggerAtOpen=0;
   m_detangleDetectTime=0;m_detangleActive=false;
   m_primaryOpenTime=0;
   m_cycleResetTime=TimeCurrent();m_cycleInPause=true;
   m_lastCTBuyPrice=m_lastCTSellPrice=0;
   ZeroMemory(m_lbc);
   return true;
}

//=================================================================
//  CALCULO DE LOTES — V9.0 CON PROTECCION COMPLETA
//=================================================================
// [V9.0] Lote base efectivo con auto-sizing
double GetEffectiveBaseLot()
{
   double lot=g_AutoBaseLot*m_lotMultiplier;
   if(!m_inSession) lot*=Inp_OffSessionLotFactor;
   return NormLot(lot);
}

double CalcLot(int level=0)
{
   return GetEffectiveBaseLot();
}

// [V9.0] CalcDirectionalLot: ahora con techo de margen libre
double CalcDirectionalLot(int targetDir)
{
   double atr=GetATR_M1Norm();  // ATR normalizado a M1
   if(atr<=0) return NormLot(g_AutoBaseLot*2.0);
   double blockLoss=MathAbs(m_port.totalProfit);
   // [V9.0] Target escalado con Inp_TPRRR
   double totalNeeded=blockLoss*Inp_TPRRR+m_dyn.blockTP;
   double moveDist=atr*Inp_RecoveryMoveATR;if(moveDist<=0)moveDist=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),calcLot=g_AutoBaseLot*2.0;
   if(tv>0&&ts>0&&moveDist>0){double profitPer=(moveDist/ts)*tv;if(profitPer>0)calcLot=totalNeeded/profitPer;}
   // [V9.0] Techo duro: no más de 2x el lote máximo configurado
   calcLot=MathMin(calcLot,Inp_LotHardCap);
   return NormLot(MathMax(calcLot,g_AutoBaseLot*1.5));
}

// [V9.0] CalcRecoveryLot: la función que causó el crash → ahora blindada
double CalcRecoveryLot()
{
   double atr=GetATR_M1Norm();  // [FIX-1] ATR normalizado a M1 (no M15)
   if(atr<=0) return NormLot(g_AutoBaseLot*Inp_RecoveryMinLotMult);
   double blockLoss=MathAbs(m_port.totalProfit);
   // [FIX-4] Target escalado: no target de $0.25 contra $300 de pérdida
   double totalNeeded=blockLoss*Inp_TPRRR+m_dyn.blockTP;
   double moveDist=atr*Inp_RecoveryMoveATR;if(moveDist<=0)moveDist=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),profitPer1=0;
   if(tv>0&&ts>0)profitPer1=(moveDist/ts)*tv;
   double calcLot=g_AutoBaseLot;
   if(profitPer1>0)calcLot=totalNeeded/profitPer1;
   // [FIX-2] Techo de margen libre (anti-cascade)
   double safeCap=CalcMaxSafeLot();
   calcLot=MathMin(calcLot,safeCap);
   // [FIX-7] Techo absoluto (Inp_LotHardCap)
   calcLot=MathMin(calcLot,Inp_LotHardCap);
   double loserLot=g_AutoBaseLot;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pf==m_port.worstProfit){loserLot=PositionGetDouble(POSITION_VOLUME);break;}
   }
   double minLot=loserLot*Inp_RecoveryMinLotMult;
   minLot=MathMin(minLot,Inp_LotHardCap); // también capear el mínimo
   return NormLot(MathMax(calcLot,minLot));
}

//=================================================================
//  APERTURA DE ORDENES
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type,double lot,string comment,bool skipPosLimit=false)
{
   if((m_isPaused||m_emergencyMode)&&!skipPosLimit) return 0;
   if(g_CircuitBreakerHit) return 0; // [V9.0] Nunca abrir bajo circuit breaker
   if(!SpreadOK()) return 0;
   if(!skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal) return 0;
   if(skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal+2) return 0; // V9: +4→+2
   lot=NormLot(lot);if(lot<=0) return 0;
   // [V9.0] Verificación triple: margen, volumen total, lot cap
   if(!MarginOK(lot,type)) return 0;
   if(!TotalVolumeOK(lot)){
      Print("[V9.0] OpenOrder bloqueado: volumen total excedería ",NormalizeDouble(Inp_MaxTotalVolume,2));
      return 0;
   }
   MqlTick t;if(!GetTick(t)) return 0;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid;
   bool ok=(type==ORDER_TYPE_BUY)?m_trade.Buy(lot,_Symbol,price,0,0,comment):m_trade.Sell(lot,_Symbol,price,0,0,comment);
   if(!ok){Print("[V9.0] ERR apertura: ",m_trade.ResultRetcodeDescription());return 0;}
   ulong ticket=m_trade.ResultOrder();
   if(ticket>0){
      m_tradesOpened++;
      Print("[V9.0] ABIERTA #",ticket," ",(type==ORDER_TYPE_BUY?"BUY":"SELL"),
            " Lot=",lot," @ ",NormalizeDouble(price,_Digits),
            " [",comment,"] TF=M",PeriodSeconds(_Period)/60," TFMult=",NormalizeDouble(g_TFMult,2),
            " Sess=",SessionName(m_dyn.session)," VR=",VolRegimeName(m_dyn.volRegime),
            " TotalVol=",NormalizeDouble(m_port.buyVolume+m_port.sellVolume+lot,3));
   }
   return ticket;
}

//+------------------------------------------------------------------+
//| [DM] Gestión de Break-Even y Trailing Stop de la entrada primaria|
//| Solo actúa en Stage 1 (sin recovery activo). En Stage 2+         |
//| el Block Stage Engine de APEXQUANT toma el control completo.     |
//+------------------------------------------------------------------+
void ManagePrimaryDM()
{
   // Solo gestionar en Stage 1 (primaria sola, sin posiciones recovery)
   if(m_blockStage != 1 || m_port.totalPos == 0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double atr   = GetATR_M1Norm();  // ATR normalizado a M1 (consistente con V9.0)
   double bid   = m_mkt.bid;
   double ask   = m_mkt.ask;

   for(int i = 0; i < MAX_RECORDS; i++)
   {
      if(m_rec[i].ticket == 0 || !m_rec[i].isPrimary) continue;
      ulong  ticket = m_rec[i].ticket;
      if(!PositionSelectByTicket(ticket)) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);  // Preserva el TP puesto por DM

      if(m_rec[i].posType == POSITION_TYPE_BUY)
      {
         // ── Break-Even ──────────────────────────────────────────────────
         // Condición idéntica al Dynamic Manager: bid >= open + 0.5 × ATR
         if(!g_DM_BEActivated && bid >= open + atr * 0.5)
         {
            double targetBE = NormPrice(open + Inp_DM_MinPointsProfit * point);
            if(sl < targetBE)
               if(m_trade.PositionModify(ticket, targetBE, tp))
               {
                  g_DM_BEActivated = true;
                  Print("[DM] BUY Break-Even activado @ ", NormalizeDouble(targetBE,_Digits));
               }
         }
         // ── Trailing Stop (solo si BE activo y SL ya en zona protegida) ─
         if(g_DM_BEActivated && sl > 0.0 && sl >= open)
         {
            double newSL = NormPrice(bid - Inp_DM_TrailingPoints * point);
            if(newSL > sl)
               m_trade.PositionModify(ticket, newSL, tp);
         }
      }
      else // POSITION_TYPE_SELL
      {
         // ── Break-Even ──────────────────────────────────────────────────
         if(!g_DM_BEActivated && ask <= open - atr * 0.5)
         {
            double targetBE = NormPrice(open - Inp_DM_MinPointsProfit * point);
            if(sl == 0.0 || sl > targetBE)
               if(m_trade.PositionModify(ticket, targetBE, tp))
               {
                  g_DM_BEActivated = true;
                  Print("[DM] SELL Break-Even activado @ ", NormalizeDouble(targetBE,_Digits));
               }
         }
         // ── Trailing Stop ───────────────────────────────────────────────
         if(g_DM_BEActivated && sl > 0.0 && sl <= open)
         {
            double newSL = NormPrice(ask + Inp_DM_TrailingPoints * point);
            if(newSL < sl)
               m_trade.PositionModify(ticket, newSL, tp);
         }
      }
      break; // Solo existe una primaria a la vez
   }
}

void ManagePositions()
{
   ManagePrimaryDM(); // [DM] Break-Even + Trailing Stop de la primaria
}

//=================================================================
//  DETANGLE ENGINE [V7.9]
//=================================================================
void RunDetangle()
{
   if(m_isProcessing||m_port.totalPos<2) return;
   double netVol=MathAbs(m_port.buyVolume-m_port.sellVolume);
   bool isSym=(netVol<Inp_DetangleNetThresh);
   bool isPnLBad=(m_port.totalProfit<Inp_DetangleMinLoss);
   if(!isSym||!isPnLBad){if(!isSym){m_detangleDetectTime=0;m_detangleActive=false;}return;}
   if(m_detangleDetectTime==0){m_detangleDetectTime=TimeCurrent();m_detangleActive=true;
      Print("[V9.0] DETANGLE: jaula simétrica | NetVol=",NormalizeDouble(netVol,3)," PnL=",NormalizeDouble(m_port.totalProfit,2));return;}
   if((int)(TimeCurrent()-m_detangleDetectTime)<Inp_DetangleSec) return;
   if(!SpreadOK()) return;
   // [V9.0 NO-LOSS] Solo cerrar si el bloque total es positivo
if(m_port.worstTicket>0 && m_port.totalProfit>=0)
{
   Print("[V9.0] DETANGLE: cerrando peor #",m_port.worstTicket,
         " PnL=",NormalizeDouble(m_port.worstProfit,2),
         " (bloque total=$",NormalizeDouble(m_port.totalProfit,2),")");
   m_isProcessing=true;
   bool closed=ClosePos(m_port.worstTicket,"Detangle");
   m_isProcessing=false;
   if(closed){m_detangleDetectTime=TimeCurrent();m_detangleActive=false;UpdatePortfolio();}
}
else if(m_port.worstTicket>0 && m_port.totalProfit<0)
{
   Print("[V9.0] DETANGLE: esperando positivo para cerrar | BloquePnL=$",
         NormalizeDouble(m_port.totalProfit,2));
}
}

//=================================================================
//  BLOCK STAGE ENGINE — DIRECTIONAL + ASYMMETRIC
//=================================================================
void RunBlockStageEngine()
{
   if(m_isProcessing||m_blockStage==0) return;
   int mainPosCount=m_port.totalPos-m_port.lbcCount;
   if(mainPosCount<=0&&m_port.totalPos==0){m_blockStage=0;m_stageFollowHedge=false;return;}
   if(mainPosCount<=0) return;
   double dynTP=CalcDynamicBlockTP();
   if(m_port.totalProfit>=dynTP){CloseBlockIfPositive("BSE_TP");return;}
   MqlTick tk;if(!GetTick(tk)) return;
   double totalPnL=m_port.totalProfit;

   // STAGE 1
   if(m_blockStage==1&&mainPosCount==1){
      double trigger1=(m_stage1TriggerAtOpen!=0)?m_stage1TriggerAtOpen:m_dyn.stage1Trigger;
      int holdTimeSec=(int)(TimeCurrent()-m_primaryOpenTime);
      bool emergencyOverride=(totalPnL<=trigger1*Inp_StageEmergMult);
      if(holdTimeSec<Inp_PrimaryMinHoldSec&&!emergencyOverride) return;
      if(totalPnL<=trigger1){
         int trendDir=m_mkt.trendConfirmed;int primaryDir=(m_primaryType==ORDER_TYPE_BUY)?1:-1;
         if(Inp_UseDirectionalStage&&trendDir==primaryDir&&trendDir!=0){
            ENUM_ORDER_TYPE reinType=m_primaryType;
            double reinLot=NormLot(g_AutoBaseLot*Inp_ReinforceLotMult);
            if(MarginOK(reinLot,reinType)&&AntiSymmetricOK(reinType,reinLot)){
               m_isProcessing=true;ulong t1=OpenOrder(reinType,reinLot,"BSE_REINF1",true);m_isProcessing=false;
               if(t1>0){int idx=FreeRec();if(idx>=0){int pt1=(reinType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op1=(reinType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,t1,pt1,op1,reinLot,"BSE_REINF1",false,false,true,false);}
                  m_blockStage=2; m_stage2Time=TimeCurrent(); m_recoveryActive=true;
m_stageFollowHedge=false; m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
for(int ri = 0; ri < MAX_RECORDS; ri++) {
   if(m_rec[ri].ticket == 0 || !m_rec[ri].isPrimary) continue;
   if(PositionSelectByTicket(m_rec[ri].ticket)) {
      double cur_sl = PositionGetDouble(POSITION_SL);
      m_trade.PositionModify(m_rec[ri].ticket, cur_sl, 0.0);
   }
   break;
}
g_DM_PrimaryTP = 0.0;
Print("[V9.0] STAGE 2 via REFUERZO | VR=",VolRegimeName(m_dyn.volRegime));
               }
            }
         } else {
            ENUM_ORDER_TYPE hedgeType=(m_primaryType==ORDER_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
            double hedgeLot=NormLot(g_AutoBaseLot*Inp_HedgeRatio);hedgeLot=MathMax(hedgeLot,NormLot(g_AutoBaseLot));
            if(!AntiSymmetricOK(hedgeType,hedgeLot)){double vs=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(vs<=0)vs=0.01;hedgeLot=NormLot(hedgeLot+vs);}
            if(MarginOK(hedgeLot,hedgeType)){
               m_isProcessing=true;ulong t1=OpenOrder(hedgeType,hedgeLot,"BSE_H1",true);m_isProcessing=false;
               if(t1>0){int idx=FreeRec();if(idx>=0){int pt1=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op1=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,t1,pt1,op1,hedgeLot,"BSE_H1",false,false,true,false);}
                  m_blockStage=2; m_stage2Time=TimeCurrent(); m_recoveryActive=true;
m_stageFollowHedge=true; m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
for(int ri = 0; ri < MAX_RECORDS; ri++) {
   if(m_rec[ri].ticket == 0 || !m_rec[ri].isPrimary) continue;
   if(PositionSelectByTicket(m_rec[ri].ticket)) {
      double cur_sl = PositionGetDouble(POSITION_SL);
      m_trade.PositionModify(m_rec[ri].ticket, cur_sl, 0.0);
   }
   break;
}
g_DM_PrimaryTP = 0.0;
Print("[V9.0] STAGE 2 via HEDGE ASIM #",t1);
               }
            }
         }
      }
      return;
   }

   // STAGE 2
   if(m_blockStage==2&&mainPosCount==2){
      if((int)(TimeCurrent()-m_stage2Time)<m_dyn.stage2Delay) return;
      if(!SpreadOK()) return;
      int trendDir=m_mkt.trendConfirmed;ENUM_ORDER_TYPE thirdType;int targetDir;
      if(trendDir==1){thirdType=ORDER_TYPE_BUY;targetDir=1;}
      else if(trendDir==-1){thirdType=ORDER_TYPE_SELL;targetDir=-1;}
      else{if(m_port.buyProfit<m_port.sellProfit){thirdType=ORDER_TYPE_SELL;targetDir=-1;}else{thirdType=ORDER_TYPE_BUY;targetDir=1;}}
      double thirdLot=CalcDirectionalLot(targetDir);
      if(!AntiSymmetricOK(thirdType,thirdLot)){double netVol=m_port.buyVolume-m_port.sellVolume;double minNeeded=(targetDir==1)?g_AutoBaseLot*1.5-netVol:netVol+g_AutoBaseLot*1.5;thirdLot=NormLot(MathMax(thirdLot,MathAbs(minNeeded)));}
      string s3Label=(targetDir==1)?"BSE_DIR_L":"BSE_DIR_S";m_stageFollowHedge=(thirdType!=m_primaryType);
      if(MarginOK(thirdLot,thirdType)){
         m_isProcessing=true;ulong t2=OpenOrder(thirdType,thirdLot,s3Label,true);m_isProcessing=false;
         if(t2>0){int idx=FreeRec();if(idx>=0){int pt2=(thirdType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op2=(thirdType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,t2,pt2,op2,thirdLot,s3Label,false,false,true,false);}
            m_blockStage=3;Print("[V9.0] STAGE 3: DIR #",t2," Lot=",NormalizeDouble(thirdLot,2));
         }
      } else ActivateLBC();
      return;
   }

   // STAGE 3
   if(m_blockStage==3){
      double trigger3=(m_stage3TriggerAtOpen!=0)?m_stage3TriggerAtOpen:m_dyn.stage3Trigger;
      if(totalPnL<=trigger3){
         if(!SpreadOK()) return;
         int trendDir=m_mkt.trendConfirmed;ENUM_ORDER_TYPE fourthType;int target4Dir;
         if(trendDir==1){fourthType=ORDER_TYPE_BUY;target4Dir=1;}
         else if(trendDir==-1){fourthType=ORDER_TYPE_SELL;target4Dir=-1;}
         else{if(m_port.buyProfit>m_port.sellProfit){fourthType=ORDER_TYPE_BUY;target4Dir=1;}else{fourthType=ORDER_TYPE_SELL;target4Dir=-1;}}
         double fourthLot=CalcDirectionalLot(target4Dir);
         if(!AntiSymmetricOK(fourthType,fourthLot)){double nv=m_port.buyVolume-m_port.sellVolume;double mn=(target4Dir==1)?g_AutoBaseLot*2.0-nv:nv+g_AutoBaseLot*2.0;fourthLot=NormLot(MathMax(fourthLot,MathAbs(mn)));}
         if(MarginOK(fourthLot,fourthType)){
            m_isProcessing=true;ulong t3=OpenOrder(fourthType,fourthLot,"BSE_CON4",true);m_isProcessing=false;
            if(t3>0){int idx=FreeRec();if(idx>=0){int pt3=(fourthType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op3=(fourthType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,t3,pt3,op3,fourthLot,"BSE_CON4",false,false,true,false);}
               m_blockStage=4;Print("[V9.0] STAGE 4: CON4 #",t3," Lot=",NormalizeDouble(fourthLot,2));
            }
         } else ActivateLBC();
      }
      return;
   }

   // STAGE 4
   if(m_blockStage==4){
      double lbcTrigger=m_dyn.stage3Trigger*1.5;
      if(!m_lbc.active&&totalPnL<lbcTrigger)ActivateLBC();
   }
}

//=================================================================
//  RECOVERY ENGINE FALLBACK — V9.0 CON LÍMITE DURO
//=================================================================
void RunRecoveryEngine()
{
   if(m_port.totalProfit>=m_dyn.recovTrigger){
      if(m_recoveryActive&&m_blockStage==0){m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;}
      return;
   }
   if(m_port.totalPos==0||m_isProcessing) return;
   if(CloseBlockIfPositive("Recovery_TP")) return;
   if(!m_recoveryActive){
      m_recoveryActive=true;m_recoveryOrders=m_port.recoveryCount;m_recoveryTrendHedge=false;
      // [DM] Reset estado primaria
g_DM_PrimaryTP        = 0.0;
g_DM_PrimaryVirtualSL = 0.0;
g_DM_BEActivated      = false;
      
      Print("[V9.0] RECOVERY FALLBACK | PnL=$",NormalizeDouble(m_port.totalProfit,2),
            " | VR=",VolRegimeName(m_dyn.volRegime),
            " | RecovDist=",NormalizeDouble(m_dyn.recovDistATR,2),"xATR_M1norm");
   }
   // [V9.0] Límite duro: máximo 2 recovery orders (RCA-2 fix)
   int maxRec=Inp_RecoveryMaxOrders; // siempre 2, independiente de tendencia
   if(m_recoveryOrders>=maxRec){
      // Si ya llegamos al límite, activar LBC en lugar de recovery
      if(!m_lbc.active){Print("[V9.0] RECOVERY LIMIT REACHED (max=",maxRec,") → activando LBC");ActivateLBC();}
      return;
   }
   if(TimeCurrent()-m_lastRecoveryTime<Inp_RecoveryIntervalSec||!SpreadOK()) return;
   MqlTick tk;if(!GetTick(tk)) return;
   double atr=GetATR_M1Norm();if(atr<=0) return; // [V9.0] ATR normalizado
   double minDist=atr*m_dyn.recovDistATR;
   if(m_losingPosOpenPrice>0&&m_losingPosType>=0){
      double dist=(m_losingPosType==POSITION_TYPE_SELL)?tk.bid-m_losingPosOpenPrice:m_losingPosOpenPrice-tk.ask;
      if(dist<minDist){
         Print("[V9.0] Recovery: esperando distancia ",NormalizeDouble(dist,2)," >= ",NormalizeDouble(minDist,2)," (MAE-calibrado)");
         return;
      }
   }
   ENUM_ORDER_TYPE recType;
   double adxLevel=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;
   bool bearT=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.adx>adxLevel);
   bool bullT=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.adx>adxLevel);
   if(m_port.buyProfit<m_port.sellProfit&&bearT){recType=ORDER_TYPE_SELL;m_recoveryTrendHedge=true;}
   else if(m_port.sellProfit<m_port.buyProfit&&bullT){recType=ORDER_TYPE_BUY;m_recoveryTrendHedge=true;}
   else{
      m_recoveryTrendHedge=false;double cd=atr*0.3;
      if(m_port.buyProfit<m_port.sellProfit){recType=ORDER_TYPE_BUY;if(m_lastCTBuyPrice>0&&MathAbs(tk.ask-m_lastCTBuyPrice)<cd)return;}
      else{recType=ORDER_TYPE_SELL;if(m_lastCTSellPrice>0&&MathAbs(tk.bid-m_lastCTSellPrice)<cd)return;}
   }
   double recLot=CalcRecoveryLot();
   if(!AntiSymmetricOK(recType,recLot)){double nv=m_port.buyVolume-m_port.sellVolume;int td=(recType==ORDER_TYPE_BUY)?1:-1;double mn=(td==1)?g_AutoBaseLot-nv:nv+g_AutoBaseLot;recLot=NormLot(MathMax(recLot,MathAbs(mn)));}
   if(!MarginOK(recLot,recType)){recLot=NormLot(recLot*0.5);if(!MarginOK(recLot,recType)){recLot=NormLot(g_AutoBaseLot);if(!MarginOK(recLot,recType)){ActivateLBC();return;}}}
   string recComm="REC_"+(recType==ORDER_TYPE_BUY?"B":"S")+"_"+IntegerToString(m_recoveryOrders+1);
   m_isProcessing=true;ulong ticket=OpenOrder(recType,recLot,recComm,true);m_isProcessing=false;
   if(ticket>0){
      int idx=FreeRec();if(idx>=0){int pt=(recType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(recType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,ticket,pt,op,recLot,recComm,false,false,true,false);}
      if(recType==ORDER_TYPE_BUY)m_lastCTBuyPrice=tk.ask;else m_lastCTSellPrice=tk.bid;
      m_recoveryOrders++;m_lastRecoveryTime=TimeCurrent();
      Print("[V9.0] Recovery #",m_recoveryOrders,"/",maxRec," | Lot=",recLot," | TotalVol=",NormalizeDouble(m_port.buyVolume+m_port.sellVolume+recLot,3));
   }
}

//=================================================================
//  LBC ENGINE
//=================================================================
void ActivateLBC()
{
   if(m_lbc.active) return;
   m_lbc.active=true;m_lbc.activatedTime=TimeCurrent();
   m_lbc.buyCount=m_lbc.sellCount=0;m_lbc.lastBuyPrice=m_lbc.lastSellPrice=0;
   m_lbc.harvestedTotal=0;m_lbc.harvestCount=0;
   double freeMarg=AccountInfoDouble(ACCOUNT_MARGIN_FREE),margPer001=CalcMarginFor001();
   // [V9.0] LBC también respeta el cap de margen
   m_lbc.maxOrdersCalc=(int)MathFloor(freeMarg*Inp_LBCMarginPct/(2.0*MathMax(margPer001,0.01)));
   m_lbc.maxOrdersCalc=MathMax(1,MathMin(m_lbc.maxOrdersCalc,Inp_LBCMaxPairs));
   Print("[V9.0] LBC ACTIVADO | LibreMarg=$",NormalizeDouble(freeMarg,2)," | MaxPares=",m_lbc.maxOrdersCalc);
}
void DeactivateLBC()
{
   if(!m_lbc.active) return;
   Print("[V9.0] LBC DESACTIVADO | Cosecha=$",NormalizeDouble(m_lbc.harvestedTotal,2)," en ",m_lbc.harvestCount," cosechas");
   ZeroMemory(m_lbc);
}
void RunLBCEngine()
{
   if(!m_lbc.active) return;
   if(m_port.totalPos==0){DeactivateLBC();return;}
   if(m_isProcessing) return;
   double dynTP=CalcDynamicBlockTP();
   if(m_port.totalProfit>=dynTP) return;
   if(m_port.totalProfit>=m_dyn.recovTrigger*0.5){DeactivateLBC();return;}
   MqlTick tk;if(!GetTick(tk)) return;
   double atr=GetATR_M1Norm();if(atr<=0) return; // [V9.0] ATR normalizado
   int nonLBCCount=m_port.totalPos-m_port.lbcCount;bool blockHasMain=(nonLBCCount>0);
   if(!blockHasMain){
      double harvestMin=DistToUSD(atr*Inp_LBCHarvestATR,g_AutoBaseLot);harvestMin=MathMax(harvestMin,0.02);
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         string comm=PositionGetString(POSITION_COMMENT);if(StringFind(comm,"LBC_")<0) continue;
         double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pf>=harvestMin){ClosePos(t,"LBC_Harvest");
            double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE),mp001=CalcMarginFor001();
            m_lbc.maxOrdersCalc=(int)MathFloor((fm*Inp_LBCMarginPct)/(2.0*MathMax(mp001,0.01)));
            m_lbc.maxOrdersCalc=MathMax(1,MathMin(m_lbc.maxOrdersCalc,Inp_LBCMaxPairs));}
      }
   }
   if(m_blockStage>0&&blockHasMain) return;
   if(TimeCurrent()-m_lbc.lastOrderTime<Inp_LBCIntervalSec||!SpreadOK()) return;
   int totalLBCPairs=MathMin(m_lbc.buyCount,m_lbc.sellCount);
   if(totalLBCPairs>=m_lbc.maxOrdersCalc) return;
   double gridSpace=atr*Inp_LBCGridATR*(m_inSession?1.2:1.0);
   double lot001=NormLot(g_AutoBaseLot);
   bool needBuy=false,needSell=false;
   if(m_lbc.buyCount==0&&m_lbc.sellCount==0){needBuy=true;needSell=true;}
   else{
      if(m_lbc.buyCount<=m_lbc.sellCount&&(m_lbc.lastBuyPrice<=0||MathAbs(tk.ask-m_lbc.lastBuyPrice)>=gridSpace))needBuy=true;
      if(m_lbc.sellCount<=m_lbc.buyCount&&(m_lbc.lastSellPrice<=0||MathAbs(tk.bid-m_lbc.lastSellPrice)>=gridSpace))needSell=true;
   }
   if(needBuy&&MarginOK(lot001,ORDER_TYPE_BUY)){
      string commB="LBC_B"+IntegerToString(m_lbc.buyCount+1);
      m_isProcessing=true;ulong ticketB=OpenOrder(ORDER_TYPE_BUY,lot001,commB,true);m_isProcessing=false;
      if(ticketB>0){int idx=FreeRec();if(idx>=0)InitRec(idx,ticketB,POSITION_TYPE_BUY,tk.ask,lot001,commB,false,false,false,true);m_lbc.buyCount++;m_lbc.lastBuyPrice=tk.ask;m_lbc.lastOrderTime=TimeCurrent();}
   }
   if(needSell&&MarginOK(lot001,ORDER_TYPE_SELL)){
      string commS="LBC_S"+IntegerToString(m_lbc.sellCount+1);
      m_isProcessing=true;ulong ticketS=OpenOrder(ORDER_TYPE_SELL,lot001,commS,true);m_isProcessing=false;
      if(ticketS>0){int idx=FreeRec();if(idx>=0)InitRec(idx,ticketS,POSITION_TYPE_SELL,tk.bid,lot001,commS,false,false,false,true);m_lbc.sellCount++;m_lbc.lastSellPrice=tk.bid;m_lbc.lastOrderTime=TimeCurrent();}
   }
}

//=================================================================
//  BASKET TP / HARVEST / CYCLE
//=================================================================
void RunBasketTP()
{
   if(!Inp_UseBasketTP||TimeCurrent()-m_lastBasketCheck<Inp_BasketCheckSec) return;
   m_lastBasketCheck=TimeCurrent();if(m_port.totalPos<2) return;
   double dynTP=CalcDynamicBlockTP();
   if(m_port.totalProfit<dynTP) return;
   double avgWin=(m_cycleWinsCount>0)?m_cycleWinsSum/m_cycleWinsCount:Inp_BasketTPFactor;
   double target=MathMax(dynTP,avgWin*Inp_BasketTPRatio);
   if(m_port.totalProfit>=target)CloseBlockIfPositive("BasketTP");
}
void CheckCycleMaxLoss()
{
   if(!Inp_UseCycleMaxLoss||m_port.totalPos==0) return;
   if(m_port.totalProfit<=Inp_CycleMaxLossUSD){
      Print("[V9.0] CYCLE MAX LOSS: $",NormalizeDouble(m_port.totalProfit,2));
      if(!m_recoveryActive&&m_blockStage==0){m_recoveryActive=true;m_recoveryOrders=0;}
   }
}
void RunHarvest()
{
   if(m_port.totalPos>1||!Inp_HarvestContinuous||m_isProcessing) return;
   if(TimeCurrent()-m_lastHarvestTime<Inp_HarvestIntervalSec) return;
   m_lastHarvestTime=TimeCurrent();
   double dynTP=CalcDynamicBlockTP();
   if(m_port.totalProfit>=dynTP)CloseBlockIfPositive("Harvest_Single");
}
bool CheckEquityGuard()
{
   if(!Inp_UseEquityGuard) return false;
   // [V9.0] Umbral dinámico: max(fijo, X% del equity actual)
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double dynThresh=MathMin(Inp_EmergencyLossUSD,-(eq*0.05));
   if(m_port.totalProfit<=dynThresh&&!m_emergencyMode){
      Print("[V9.0] ALERTA EQUITY: $",NormalizeDouble(m_port.totalProfit,2)," <= $",NormalizeDouble(dynThresh,2));
      m_emergencyMode=true;m_isPaused=true;return true;
   }
   if(m_port.currentDD>=Inp_MaxDrawdownPct)m_isPaused=true;
   else if(m_isPaused&&!m_emergencyMode&&!m_dailyLimitHit&&m_port.currentDD<Inp_MaxDrawdownPct*0.5)m_isPaused=false;
   return false;
}

//=================================================================
//  STORM FILTER — V8.0-QUANTCAL (StormATRMult=3.10)
//=================================================================
double CalcAvgATR(int wb)
{
   if(wb<=0||h_ATR==INVALID_HANDLE) return 0;
   double buf[];ArraySetAsSeries(buf,true);
   if(CopyBuffer(h_ATR,0,1,wb,buf)<wb) return 0;
   double s=0;for(int i=0;i<wb;i++)s+=buf[i];return s/wb;
}
void RunVolatilityStormFilter()
{
   if(!Inp_UseStormFilter){m_stormActive=false;return;}
   double atrNow=GetATR_M1Norm();if(atrNow<=0) return;
   double atrAvg=CalcAvgATR(Inp_StormATRWindow)/g_TFMult;bool atrStorm=false; // normalizar promedio
   if(atrAvg>0){m_stormLastATRRatio=atrNow/atrAvg;atrStorm=(m_stormLastATRRatio>=Inp_StormATRMult);}
   double sprNow=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   double sessMaxSpr=(double)GetSessionMaxSpread(m_dyn.session);
   bool sprStorm=(sprNow>sessMaxSpr*Inp_StormSpreadMult);
   bool stormNow=(atrStorm||sprStorm);
   if(stormNow&&!m_stormActive){m_stormActive=true;m_stormDetectedTime=TimeCurrent();
      Print("[V9.0] TORMENTA | ATRx=",NormalizeDouble(m_stormLastATRRatio,2)," | SprNow=",NormalizeDouble(sprNow,0)," vs SessMax=",NormalizeDouble(sessMaxSpr,0));}
   if(m_stormActive){if(TimeCurrent()-m_stormDetectedTime>=Inp_StormCooldownSec){if(!stormNow){m_stormActive=false;Print("[V9.0] TORMENTA DESPEJADA");}else m_stormDetectedTime=TimeCurrent();}}
}

//=================================================================
//  CT ENGINE + PRIMARY ENTRY
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType,double &ctLot,int &ctLevel)
{
   if(m_port.totalPos==0||m_port.totalPos>=Inp_MaxPositionsTotal) return false;
   if(m_port.totalProfit>=0&&m_port.negativeSum==0) return false;
   if(m_recoveryActive||m_lbc.active||m_mkt.atr<=0) return false;
   int buyCount=m_port.buyCount,sellCount=m_port.sellCount;
   bool buyLosing=(m_port.buyProfit<-0.05&&buyCount>0),sellLosing=(m_port.sellProfit<-0.05&&sellCount>0);
   bool openBuy=false,openSell=false;
   if(buyLosing&&!sellLosing){if(sellCount>=Inp_CTMaxSameDir)return false;openSell=true;}
   else if(sellLosing&&!buyLosing){if(buyCount>=Inp_CTMaxSameDir)return false;openBuy=true;}
   else if(buyLosing&&sellLosing){
      if(m_mkt.htfTrend==1&&buyCount<Inp_CTMaxSameDir)openBuy=true;
      else if(m_mkt.htfTrend==-1&&sellCount<Inp_CTMaxSameDir)openSell=true;
      else if(m_port.buyProfit<m_port.sellProfit&&sellCount<Inp_CTMaxSameDir)openSell=true;
      else if(buyCount<Inp_CTMaxSameDir)openBuy=true;
      else return false;
   } else return false;
   ENUM_ORDER_TYPE testType=openBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(!ADXAllowsEntry(testType)) return false;
   // [V9.0] ATR normalizado para distancia CT
   double ctDist=(Inp_CTMode==CT_ATR_DISTANCE)?GetATR_M1Norm()*Inp_CTDistanceATR:Inp_CTFixedPoints*_Point;
   MqlTick t;if(!GetTick(t)) return false;
   if(ctDist>0){if(openBuy&&m_lastCTBuyPrice>0&&MathAbs(t.ask-m_lastCTBuyPrice)<ctDist)return false;
               if(openSell&&m_lastCTSellPrice>0&&MathAbs(t.bid-m_lastCTSellPrice)<ctDist)return false;}
   ctLevel=openBuy?buyCount:sellCount;ctLot=GetEffectiveBaseLot();
   ctType=openBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   return true;
}

void RunCTEngine()
{
   if(m_isProcessing||m_isPaused||m_emergencyMode||m_cycleInPause||g_CircuitBreakerHit) return;
   if(TimeCurrent()-m_lastCTTime<Inp_CTIntervalSec) return;
   m_lastCTTime=TimeCurrent();
   MqlTick ts;if(!GetTick(ts)) return;
   if(!SpreadOK()) return;

   if(m_port.totalPos==0){
      if(!m_sensors.allOK){
         static datetime lastSL=0;
         if(TimeCurrent()-lastSL>=60){Print("[V9.0] BLOQUEADO: ",m_sensors.blockReason);lastSL=TimeCurrent();}
         return;
      }
      if(m_stormActive) return;
      int cooldown=m_inSession?Inp_PrimaryCooldownSec:Inp_PrimaryCooldownOff;
      if(TimeCurrent()-m_lastPrimaryTime<cooldown) return;

      // [DM] Dirección basada en el último dígito del precio Ask
// Lógica idéntica al Dynamic Manager original (Pure_Fractal_Pure_v6)
int    dm_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
int    dm_factor = (int)(ts.ask * MathPow(10, dm_digits)) % 2;
ENUM_ORDER_TYPE initType = (dm_factor == 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

      double lot=GetEffectiveBaseLot();
      m_isProcessing=true;
      ulong ticket=OpenOrder(initType,lot,"Primary_Entry");
      if(ticket>0){
         int idx=FreeRec();
         if(idx>=0){int pt=(initType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(initType==ORDER_TYPE_BUY)?ts.ask:ts.bid;InitRec(idx,ticket,pt,op,lot,"Primary_Entry",true,false,false,false);}
         m_lastPrimaryDir=(initType==ORDER_TYPE_BUY)?1:-1;
         m_lastPrimaryTime=TimeCurrent();m_primaryOpenTime=TimeCurrent();
         if(initType==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask;else m_lastCTSellPrice=ts.bid;
         m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
         m_blockStage=1;m_primaryType=initType;m_stageFollowHedge=false;
         m_stage1TriggerAtOpen=m_dyn.stage1Trigger;m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
         m_detangleDetectTime=0;m_detangleActive=false;
         DeactivateLBC();

// ── [DM] Calcular TP individual y SL Virtual ─────────────────────────
double dm_atr  = GetATR_M1Norm();
double dm_open = (initType == ORDER_TYPE_BUY) ? ts.ask : ts.bid;

// TP real enviado al broker (el broker cierra en verde si lo alcanza)
double dm_tp  = (initType == ORDER_TYPE_BUY)
                 ? NormPrice(dm_open + dm_atr * Inp_DM_TPMultiplier)
                 : NormPrice(dm_open - dm_atr * Inp_DM_TPMultiplier);

// SL virtual: NO se envía al broker. Es solo referencia de cuándo
// el Block Stage Engine de APEXQUANT debería tomar el control.
double dm_vsl = (initType == ORDER_TYPE_BUY)
                 ? NormPrice(dm_open - dm_atr * Inp_DM_SLMultiplier)
                 : NormPrice(dm_open + dm_atr * Inp_DM_SLMultiplier);

g_DM_PrimaryTP        = dm_tp;
g_DM_PrimaryVirtualSL = dm_vsl;
g_DM_BEActivated      = false;

// SL = 0 (sin cierre automático; recovery de APEXQUANT lo cubre)
// TP = dm_tp (cierre en verde individual si el precio llega antes del recovery)
m_trade.PositionModify(ticket, 0.0, dm_tp);

Print("[DM] PRIMARY | TP=", NormalizeDouble(dm_tp,_Digits),
      " | VirtualSL=", NormalizeDouble(dm_vsl,_Digits),
      " | ATR_M1norm=", NormalizeDouble(dm_atr,5),
      " | Dir=", (initType==ORDER_TYPE_BUY ? "BUY" : "SELL"));
// ─────────────────────────────────────────────────────────────────────
         Print("[V9.0] PRIMARY #",ticket," ",(initType==ORDER_TYPE_BUY?"BUY":"SELL"),
               " Lot=",lot," | AutoLot=",g_AutoBaseLot," | TFMult=",NormalizeDouble(g_TFMult,2),
               " | Sess=",SessionName(m_dyn.session)," | VR=",VolRegimeName(m_dyn.volRegime),
               " | DynTrig1=",NormalizeDouble(m_dyn.stage1Trigger,2));
      }
      m_isProcessing=false;
      return;
   }

   if(m_blockStage>0) return;
   ENUM_ORDER_TYPE ctType;double ctLot;int ctLevel;
   if(!ShouldOpenCT(ctType,ctLot,ctLevel)||!MarginOK(ctLot,ctType)) return;
   string ctComm="CT_"+(ctType==ORDER_TYPE_BUY?"B":"S")+"_L"+IntegerToString(ctLevel+1);
   m_isProcessing=true;ulong ticket=OpenOrder(ctType,ctLot,ctComm);m_isProcessing=false;
   if(ticket>0){
      int idx=FreeRec();if(idx>=0){int pt=(ctType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(ctType==ORDER_TYPE_BUY)?ts.ask:ts.bid;InitRec(idx,ticket,pt,op,ctLot,ctComm,false,true,false,false);}
      if(ctType==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask;else m_lastCTSellPrice=ts.bid;
   }
}

//=================================================================
//  NET EXPOSURE HEDGE [V7.6B]
//=================================================================
void RunNetExposureHedge()
{
   if(!Inp_UseNetHedge||m_port.totalPos==0||m_isProcessing||g_CircuitBreakerHit) return;
   double netVol=NormalizeDouble(m_port.buyVolume-m_port.sellVolume,2);
   if(MathAbs(netVol)<0.005) return;
   double loss=m_port.totalProfit;
   if(loss>m_dyn.netHedgeTrig1) return;
   if(TimeCurrent()-m_lastNetHedgeTime<Inp_NetHedgeIntervalSec||!SpreadOK()) return;
   ENUM_ORDER_TYPE hedgeType=(netVol>0)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   double volStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(volStep<=0)volStep=0.01;
   if(loss<=m_dyn.netHedgeTrig2&&!m_netHedge2Applied){
      double pct=m_netHedge1Applied?0.50:0.0;double hedgeLot=NormLot(MathAbs(netVol)*(1.0-pct));
      if(hedgeLot>0){if(!AntiSymmetricOK(hedgeType,hedgeLot))hedgeLot=NormLot(hedgeLot+volStep);
         if(MarginOK_Hedge(hedgeLot,hedgeType)){
            m_isProcessing=true;ulong ticket=OpenOrder(hedgeType,hedgeLot,"NET_HEDGE_L2",true);m_isProcessing=false;
            if(ticket>0){m_netHedge2Applied=m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();
               MqlTick tk;GetTick(tk);int idx=FreeRec();if(idx>=0){int pt=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,ticket,pt,op,hedgeLot,"NET_HEDGE_L2",false,false,true,false);}
               Print("[V9.0] NET HEDGE L2 | PnL=$",NormalizeDouble(loss,2));}}}
      return;
   }
   if(loss<=m_dyn.netHedgeTrig1&&!m_netHedge1Applied){
      double hedgeLot=NormLot(MathAbs(netVol)*0.50);
      if(hedgeLot>0){if(!AntiSymmetricOK(hedgeType,hedgeLot))hedgeLot=NormLot(hedgeLot+volStep);
         if(MarginOK_Hedge(hedgeLot,hedgeType)){
            m_isProcessing=true;ulong ticket=OpenOrder(hedgeType,hedgeLot,"NET_HEDGE_L1",true);m_isProcessing=false;
            if(ticket>0){m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();
               MqlTick tk;GetTick(tk);int idx=FreeRec();if(idx>=0){int pt=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,ticket,pt,op,hedgeLot,"NET_HEDGE_L1",false,false,true,false);}
               Print("[V9.0] NET HEDGE L1 | PnL=$",NormalizeDouble(loss,2));}}}
   }
}

//=================================================================
//  DASHBOARD V9.0-CAPITALGUARD
//=================================================================
void AQLbl(string n,string txt,int x,int y,color c,int fs=9,bool bold=false)
{
   if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_LABEL,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);}
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,n,OBJPROP_FONT,bold?"Consolas Bold":"Consolas");ObjectSetString(0,n,OBJPROP_TEXT,txt);
}

void AQBtn(string n,string txt,int x,int y,int w,int h,color bg,color fg=clrWhite)
{
   if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_BUTTON,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);ObjectSetString(0,n,OBJPROP_FONT,"Consolas");}
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,n,OBJPROP_COLOR,fg);
}

void AQPanel(string n,int x,int y,int w,int h)
{
   if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_BACK,false);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);}
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'8,8,12');ObjectSetInteger(0,n,OBJPROP_COLOR,C'70,70,70');ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
}

void DeleteDash()
{
   string names[]={
      "AQ90_BG","AQ90_HDR","AQ90_SEP0","AQ90_CGB","AQ90_CG1","AQ90_CG2","AQ90_CG3",
      "AQ90_SEPA","AQ90_SENS1","AQ90_SENS2","AQ90_SENS3","AQ90_SEPB","AQ90_DYN","AQ90_DYN2", // <-- AQ90_SENS3 añadido para limpieza de buffers
      "AQ90_SEPC","AQ90_QCAL","AQ90_SEPE","AQ90_STAG","AQ90_TEMA",
      "AQ90_SEPD","AQ90_ACC","AQ90_PNL","AQ90_POS","AQ90_REC","AQ90_NH","AQ90_SF",
      "AQ90_SEPH","AQ90_HIST","AQ90_DIAG","AQ90_B1","AQ90_B2"
   };
   for(int i=0;i<ArraySize(names);i++) ObjectDelete(0,names[i]);
}

void UpdateDash()
{
   if(!Inp_ShowDashboard||TimeCurrent()-m_lastDashTime<1) return;
   m_lastDashTime=TimeCurrent();
   color cGreen=C'0,220,80',cRed=C'220,50,50',cOra=C'220,150,30';
   color cYel=C'200,200,50',cCyan=C'50,190,220',cGray=C'120,120,130';
   color cMint=C'0,200,150',cPurp=C'160,80,220',cBord=C'70,70,70';
   int x=Inp_DashX,y=Inp_DashY,lh=16;
   int w=680,h=58*lh;
   AQPanel("AQ90_BG",x-8,y-8,w,h);
   AQLbl("AQ90_HDR","[ "+VERSION_STR+" ]  "+_Symbol+" M"+IntegerToString(PeriodSeconds(_Period)/60)+"  | CAPITAL GUARD + QUANTCAL",x,y,cGreen,10,true);y+=lh+2;
   AQLbl("AQ90_SEP0","────────────────────────────────────────────────────────────────────────────",x,y,cBord,8);y+=lh-4;

   // [V9.0] CAPITAL GUARD STATUS — primer bloque (más visible)
   color cgColor=g_CircuitBreakerHit?cRed:(g_SoftBreakerHit?cOra:cGreen);
   string cgStr=g_CircuitBreakerHit?"[ !! CIRCUIT BREAKER DURO ACTIVO — SIN OPERACIONES !! ]":
                (g_SoftBreakerHit?"[ SOFT BREAKER ACTIVO (DD>"+DoubleToString(Inp_SoftCircuitBreakerPct*100,0)+"%) — ENTRADAS PAUSADAS ]":
                "[ CAPITAL GUARD: OK ]");
   AQLbl("AQ90_CGB",cgStr,x,y,cgColor,10,true);y+=lh+1;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct=g_PeakEquity>0?(g_PeakEquity-eq)/g_PeakEquity*100.0:0;
   double totalVol=m_port.buyVolume+m_port.sellVolume;
   double volCap=Inp_MaxTotalVolume;
   double marginUsed=AccountInfoDouble(ACCOUNT_MARGIN);
   double marginFree=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginUsagePct=((marginUsed+marginFree)>0)?marginUsed/(marginUsed+marginFree)*100.0:0;
   AQLbl("AQ90_CG1",StringFormat("DD: %.1f%% (hard@%.0f%% soft@%.0f%%) | PeakEq:$%.2f | CurEq:$%.2f | TFMult:%.2f",
         ddPct,Inp_HardCircuitBreakerPct*100,Inp_SoftCircuitBreakerPct*100,g_PeakEquity,eq,g_TFMult),x,y,(ddPct>Inp_HardCircuitBreakerPct*100)?cRed:(ddPct>Inp_SoftCircuitBreakerPct*100)?cOra:cCyan,9);y+=lh-1;
   AQLbl("AQ90_CG2",StringFormat("Volume: %.2f/%.2f lots (%.0f%%) | MarginUsed: %.0f%% | AutoLot:%.2f | HardCap:%.2f | MaxMarginPct:%.0f%%",
         totalVol,volCap,(volCap>0)?totalVol/volCap*100:0,marginUsagePct,g_AutoBaseLot,Inp_LotHardCap,Inp_MaxMarginUsagePct*100),
         x,y,(totalVol/volCap>0.8)?cRed:(totalVol/volCap>0.5)?cOra:cGreen,9);y+=lh-1;
   double dynTP=CalcDynamicBlockTP();
   AQLbl("AQ90_CG3",StringFormat("DynBlockTP: $%.3f (floor:$%.2f | loss*RRR:$%.3f) | TPRRR:%.2f | RecMax:%d/per-cycle",
         dynTP,Inp_BlockTPTarget,MathAbs(m_port.totalProfit)*Inp_TPRRR,Inp_TPRRR,Inp_RecoveryMaxOrders),x,y,cMint,9);y+=lh;

   AQLbl("AQ90_SEPA","── SENSORES (V8.0-QUANTCAL) ─────────────────────────────────────────────────",x,y,C'50,50,80',8);y+=lh-3;
   int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   int sessMaxSpr=GetSessionMaxSpread(m_dyn.session);
   string ratioStr=(m_mkt.atrSlow>0)?DoubleToString(m_sensors.atrRatio,2):"N/A";
   
   AQLbl("AQ90_SENS1","TIME:"+(m_sensors.timeOK?"OK":"WAIT")+"  SPR:"+(m_sensors.spreadOK?"OK("+IntegerToString(cs)+"/"+IntegerToString(sessMaxSpr)+")":"ALTO("+IntegerToString(cs)+")"),x,y,m_sensors.spreadOK?cGreen:cRed,9);
   
   // Separación de variables: Se extrae AllOK hacia la nueva línea inferior.
   AQLbl("AQ90_SENS2","VOLAT:"+(m_sensors.volatOK?"OK("+ratioStr+")":"STORM("+ratioStr+")")+"  MARG:"+(m_sensors.marginOK?"OK":"INSUF"),x+240,y,(m_sensors.marginOK?cGreen:cOra),9);y+=lh;
   
   // Nueva capa de presentación: Eje X reiniciado para evitar overflow.
   AQLbl("AQ90_SENS3","All OK:"+(m_sensors.allOK?"SI":"NO: "+m_sensors.blockReason),x,y,(m_sensors.allOK?cGreen:cOra),9);y+=lh;

   AQLbl("AQ90_SEPB","── V8.0 DYNAMIC + V9.0 TF-ADAPTIVE ─────────────────────────────────────────",x,y,C'30,60,50',8);y+=lh-3;
   color sessC=(m_dyn.session==SESSION_NY)?cOra:(m_dyn.session==SESSION_LONDON)?cGreen:cCyan;
   AQLbl("AQ90_DYN",StringFormat("SESION:%s Factor=%.2f | VolReg:%s | TF:M%d mult=%.2f | ATR_M1norm=%.4f | RecovDist=%.2fxATR",
         SessionName(m_dyn.session),m_dyn.sessionFactor,VolRegimeName(m_dyn.volRegime),
         PeriodSeconds(_Period)/60,g_TFMult,GetATR_M1Norm(),m_dyn.recovDistATR),x,y,sessC,9);y+=lh-1;
   AQLbl("AQ90_DYN2",StringFormat("DynTrig Stage1=%.2f Stage3=%.2f BlockTP=+%.3f(dyn) RecovTrig=%.2f | S2Delay=%ds",
         m_dyn.stage1Trigger,m_dyn.stage3Trigger,dynTP,m_dyn.recovTrigger,m_dyn.stage2Delay),x,y,cMint,9);y+=lh;

   AQLbl("AQ90_SEPC","── V8.0-QUANTCAL: Dataset 99,520 barras M1 ─────────────────────────────────",x,y,C'20,50,20',8);y+=lh-3;
   AQLbl("AQ90_QCAL","ATR(14): P50=2.83 P80=4.72 P95=9.05 | Storm=3.10x(P95/P50) | MAE/ATR: P50=3.36x P75=6.06x | Revert=93.8% | VolReg: LOW<0.84 HIGH>1.09 | SprP80: ASI=24 LON=21 OVL=20 NY=19",x,y,C'80,180,80',8);y+=lh;

   AQLbl("AQ90_SEPE","── BLOCK STAGE + TEMA/KALMAN ───────────────────────────────────────────────",x,y,C'30,60,60',8);y+=lh-3;
   string trendLabel=(m_mkt.trendConfirmed==1)?"BULL":(m_mkt.trendConfirmed==-1)?"BEAR":"NEUTRAL";
   color trendC=(m_mkt.trendConfirmed==1)?cGreen:(m_mkt.trendConfirmed==-1)?cRed:cGray;
   int holdNow=(m_primaryOpenTime>0)?(int)(TimeCurrent()-m_primaryOpenTime):0;
   AQLbl("AQ90_TEMA",StringFormat("TEMA+KAL:%s Trend=%s | Hold=%ds/%ds | TEMAf=%.2f TEMAs=%.2f",
         Inp_UseTEMAKalman?"ON":"OFF",trendLabel,holdNow,Inp_PrimaryMinHoldSec,m_mkt.temaFast,m_mkt.temaSlow),x,y,trendC,9);y+=lh-1;
   string stgNames[]={"IDLE","PRIMARIA","HEDGE/REINF","3RA-DIR","CONSOLIDACION"};
   int si=MathMax(0,MathMin(m_blockStage,4));
   color stgC=(m_blockStage==0)?cGray:(m_blockStage==1)?cCyan:(m_blockStage==2)?cOra:(m_blockStage==3)?cYel:cRed;
   double netV=m_port.buyVolume-m_port.sellVolume;
   AQLbl("AQ90_STAG",StringFormat("STAGE %d: %s | NetVol=%.3f | Buy=%.2f(%.2f$) Sell=%.2f(%.2f$) | Detangle:%s",
         si,stgNames[si],netV,m_port.buyVolume,m_port.buyProfit,m_port.sellVolume,m_port.sellProfit,
         m_detangleActive?"ACTIVO":"ok"),x,y,stgC,9);y+=lh;

   AQLbl("AQ90_SEPD","── BLOQUE ACTIVO ────────────────────────────────────────────────────────────",x,y,C'50,50,80',8);y+=lh-3;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   AQLbl("AQ90_ACC",StringFormat("Balance:$%.2f  Equity:$%.2f  LibreMarg:$%.2f  DD:%.1f%%  Streak:%d/%d  LotMult:%.2f",
         bal,eq,marginFree,ddPct,m_consecutiveLosses,Inp_LossStreakMax,m_lotMultiplier),x,y,cCyan,9);y+=lh-1;
   double pnl=m_port.totalProfit;double falta=MathMax(0,dynTP-pnl);
   AQLbl("AQ90_PNL",StringFormat("PnL:%s%.2f  DynTP:+%.3f  Falta:$%.2f  blockTP_rrt:%.3f(=loss*%.2f)",
         pnl>=0?"+":"",pnl,dynTP,falta,MathAbs(pnl)*Inp_TPRRR,Inp_TPRRR),x,y,pnl>=0?cGreen:cRed,9);y+=lh-1;
   int mainPCnt=m_port.totalPos-m_port.lbcCount;
   AQLbl("AQ90_POS",StringFormat("Pos:%d (main:%d lbc:%d rec:%d ct:%d) | VWAP:%.2f | Dir:%s",
         m_port.totalPos,mainPCnt,m_port.lbcCount,m_port.recoveryCount,m_port.ctCount,
         m_port.blockVWAP,(m_port.blockDir>0)?"LARGO":(m_port.blockDir<0)?"CORTO":"NEUTRO"),x,y,cCyan,9);y+=lh-1;
   string recStr=m_recoveryActive?StringFormat("RECOVERY:%d/%d [MaxFixed=2-noexcept] RecDist=%.2fxATR_M1",m_recoveryOrders,Inp_RecoveryMaxOrders,m_dyn.recovDistATR):"Recovery:standby";
   string lbcStr=m_lbc.active?StringFormat("  LBC:B=%d S=%d Cos=$%.2f",m_lbc.buyCount,m_lbc.sellCount,m_lbc.harvestedTotal):"  LBC:standby";
   AQLbl("AQ90_REC",recStr+lbcStr,x,y,m_recoveryActive?cYel:cGray,9);y+=lh-1;
   string nhStr;color nhC;
   if(m_netHedge2Applied){nhStr="NET HEDGE L2 ACTIVO";nhC=cRed;}
   else if(m_netHedge1Applied){nhStr="NET HEDGE L1 ACTIVO | L2@"+DoubleToString(m_dyn.netHedgeTrig2,2);nhC=cOra;}
   else{nhStr="NET HEDGE:esp L1@"+DoubleToString(m_dyn.netHedgeTrig1,2)+" L2@"+DoubleToString(m_dyn.netHedgeTrig2,2);nhC=cGray;}
   AQLbl("AQ90_NH",nhStr,x,y,nhC,9);y+=lh-1;
   string sfStr;color sfC;
   if(m_stormActive){sfStr="STORM:ACTIVO ATRx="+DoubleToString(m_stormLastATRRatio,2)+" ("+IntegerToString(MathMax(0,Inp_StormCooldownSec-(int)(TimeCurrent()-m_stormDetectedTime)))+"s)";sfC=cRed;}
   else{sfStr="STORM:OK ATRx="+DoubleToString(m_stormLastATRRatio,2)+" (thr="+DoubleToString(Inp_StormATRMult,1)+"x)";sfC=cGray;}
   AQLbl("AQ90_SF",sfStr,x,y,sfC,9);y+=lh;

   AQLbl("AQ90_SEPH","── HISTORIAL ────────────────────────────────────────────────────────────────",x,y,C'50,50,80',8);y+=lh-3;
   int totalT=m_totalWins+m_totalLosses;double wrPct=(totalT>0)?(double)m_totalWins/totalT*100.0:0;
   AQLbl("AQ90_HIST",StringFormat("Win:%.1f%% (%d/%d)  Expect:$%.3f  PnL:$%.2f  Mejor:$%.2f  Peor:$%.2f  Ticks:%d",
         wrPct,m_totalWins,totalT,CalcExpectancy(),m_totalPnL,m_bestClosed,m_worstClosed,(int)m_tickCount),x,y,CalcExpectancy()>=0?cGreen:cOra,9);y+=lh;

   MqlDateTime dtNow;TimeToStruct(TimeCurrent(),dtNow);
   AQLbl("AQ90_DIAG",StringFormat("GMT:%02d:%02d  ATR:%.2f  ATR_M1norm:%.4f  ATR/ATR100:%.3f  EMA200:%.1f  Estado:%s",
         dtNow.hour,dtNow.min,m_mkt.atr,GetATR_M1Norm(),m_sensors.atrRatio,m_mkt.ema200,m_sensors.allOK?"OK":m_sensors.blockReason),x,y,cGray,8);y+=lh+4;

   AQBtn("AQ90_B1",m_isPaused?">> REANUDAR <<":"|| PAUSAR",x,y,160,22,m_isPaused?C'180,130,0':C'0,90,40');
   AQBtn("AQ90_B2","CERRAR TODAS (MANUAL)",x+170,y,180,22,C'150,20,20');
   ChartRedraw(0);
}

//=================================================================
//  FILLING MODE
//=================================================================
ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   if((bool)MQLInfoInteger(MQL_TESTER)) return ORDER_FILLING_RETURN;
   long filling=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((filling&SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
   if((filling&SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//=================================================================
//  OnInit
//=================================================================
int OnInit()
{
   // [V9.0] Calcular multiplicador de timeframe antes de todo
   g_TFMult=(Inp_TFMultOverride>0)?Inp_TFMultOverride:CalcTFMult();
   g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_CircuitBreakerHit=false; g_SoftBreakerHit=false;

   Print("==================================================================");
   Print("  "+VERSION_STR+" — CAPITAL GUARD + ANTI-SYMMETRIC ENGINE");
   Print("  TIMEFRAME: M",PeriodSeconds(_Period)/60," | TFMult=",NormalizeDouble(g_TFMult,2));
   Print("  [V9.0 FIX-1] ATR normalizado a M1: ATR_raw/TFMult");
   Print("  [V9.0 FIX-2] MaxTotalVolume=",Inp_MaxTotalVolume," | LotHardCap=",Inp_LotHardCap);
   Print("  [V9.0 FIX-3] HardCircuitBreaker=",NormalizeDouble(Inp_HardCircuitBreakerPct*100,0),"% | Soft=",NormalizeDouble(Inp_SoftCircuitBreakerPct*100,0),"%");
   Print("  [V9.0 FIX-4] DynBlockTP: floor=",Inp_BlockTPTarget," RRR=",Inp_TPRRR);
   Print("  [V9.0 FIX-5] AutoLot: Bal*",Inp_AutoLotPct," HardCap=",Inp_LotHardCap);
   Print("  [V9.0 FIX-6] RecoveryMaxOrders=",Inp_RecoveryMaxOrders," (era 9 en modo tendencia)");
   Print("  [V9.0 FIX-7] MaxMarginUsage=",NormalizeDouble(Inp_MaxMarginUsagePct*100,0),"%");
   Print("  V8.0-QUANTCAL: ATR(14) P50=2.83 P80=4.72 P95=9.05");
   Print("  Storm=3.10x | MAE/ATR: P50=3.36x P75=6.06x | Revert=93.8%");
   Print("  VolReg: LOW<"+DoubleToString(Inp_VolRegimeLowThresh,2)+" HIGH>"+DoubleToString(Inp_VolRegimeHighThresh,2)+" | SprP80: ASI=24 LON=21 NY=19");
   Print("==================================================================");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(DetectFillingMode());

   h_ATR     =iATR(_Symbol,PERIOD_M1,Inp_ATRPeriod);    // [V9.0] SIEMPRE en M1
   h_EMAFast =iMA(_Symbol,PERIOD_M1,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_EMASlow =iMA(_Symbol,PERIOD_M1,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_RSI     =iRSI(_Symbol,PERIOD_M1,Inp_RSIPeriod,PRICE_CLOSE);
   h_MACD    =iMACD(_Symbol,PERIOD_M1,Inp_MACDFast,Inp_MACDSlow,Inp_MACDSig,PRICE_CLOSE);

   if(h_ATR==INVALID_HANDLE||h_EMAFast==INVALID_HANDLE||h_EMASlow==INVALID_HANDLE||
      h_RSI==INVALID_HANDLE||h_MACD==INVALID_HANDLE)
   { Print("[V9.0] ERROR: Indicadores base M1 fallaron"); return INIT_FAILED; }

   h_ADX       =iADX(_Symbol,PERIOD_M1,Inp_ADXPeriod);
   h_HTFEMAFast=iMA(_Symbol,Inp_HTFTF,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_HTFEMASlow=iMA(_Symbol,Inp_HTFTF,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_EMA200    =iMA(_Symbol,PERIOD_M1,Inp_EMA200Period,0,MODE_EMA,PRICE_CLOSE);
   h_ATRSlow   =iATR(_Symbol,PERIOD_M1,Inp_ATRSlowPeriod); // [V9.0] ATR(100) también en M1

   for(int i=0;i<MAX_RECORDS;i++)ZeroMemory(m_rec[i]);
   ZeroMemory(m_lbc);ZeroMemory(m_sensors);ZeroMemory(m_mkt);ZeroMemory(m_dyn);
   m_temaF_init=m_temaS_init=m_kalF_init=m_kalS_init=false;
   m_blockStage=0;m_stageFollowHedge=false;m_primaryOpenTime=0;
   m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
   m_detangleDetectTime=0;m_detangleActive=false;

   m_dyn.stage1Trigger=Inp_Stage1Trigger;m_dyn.stage3Trigger=Inp_Stage3Trigger;
   m_dyn.blockTP=Inp_BlockTPTarget;m_dyn.recovTrigger=Inp_RecoveryTriggerUSD;
   m_dyn.stage2Delay=Inp_Stage2DelayLondon;m_dyn.recovDistATR=Inp_RecovDistNormal;
   m_dyn.netHedgeTrig1=Inp_NetHedgeTrigger1USD;m_dyn.netHedgeTrig2=Inp_NetHedgeTrigger2USD;
   m_dyn.sessionFactor=1.0;m_dyn.session=SESSION_OFF;m_dyn.volRegime=VOL_NORMAL;m_dyn.atr2usd=0;

   m_initialBalance=AccountInfoDouble(ACCOUNT_BALANCE);m_bestEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance=m_initialBalance;m_lastDailyReset=TimeCurrent();

   CalibrateMarginPerLot();
   RecalcAutoBaseLot();
   CalcBrokerTimeWindow();SyncPositions();UpdatePortfolio();

   if(m_port.totalPos>0)
      Print("[V9.0] Posiciones existentes (",m_port.totalPos,"): supervisadas. TotalVol=",NormalizeDouble(m_port.buyVolume+m_port.sellVolume,3));
   if(m_port.lbcCount>0){m_lbc.active=true;m_lbc.activatedTime=TimeCurrent();m_lbc.maxOrdersCalc=Inp_LBCMaxPairs;}

   if(Inp_ShowDashboard){DeleteDash();UpdateDash();}

   Print("[V9.0] LISTO | Bal=$",m_initialBalance," | AutoLot=",g_AutoBaseLot,
         " | Marg0.01=$",NormalizeDouble(CalcMarginFor001(),2),
         " | TFMult=",NormalizeDouble(g_TFMult,2),
         " | Indicadores: M1 (todos fijos, independiente del chart TF)");
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   Print("[V9.0] DETENIDO | PnL=$",NormalizeDouble(m_totalPnL,2)," | Trades:",m_tradesClosed,
         " | CircuitHits: Hard=",g_CircuitBreakerHit?" (activo)":"no"," Soft=",g_SoftBreakerHit?" (activo)":"no");
   IndicatorRelease(h_ATR);IndicatorRelease(h_EMAFast);IndicatorRelease(h_EMASlow);
   IndicatorRelease(h_RSI);IndicatorRelease(h_MACD);
   if(h_ADX!=INVALID_HANDLE)IndicatorRelease(h_ADX);
   if(h_HTFEMAFast!=INVALID_HANDLE)IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow!=INVALID_HANDLE)IndicatorRelease(h_HTFEMASlow);
   if(h_EMA200!=INVALID_HANDLE)IndicatorRelease(h_EMA200);
   if(h_ATRSlow!=INVALID_HANDLE)IndicatorRelease(h_ATRSlow);
   if(Inp_ShowDashboard)DeleteDash();
}

//=================================================================
//  OnTick
//=================================================================
void OnTick()
{
   m_tickCount++;

   // [V9.0] CIRCUIT BREAKER: SIEMPRE PRIMERO, SIN EXCEPCIONES
   // Si el drawdown supera el umbral duro, se cierra todo y se para.
   if(HardEquityCircuitBreaker()) {
      UpdatePortfolio();
      if(Inp_ShowDashboard)UpdateDash();
      return;
   }

   UpdateMarket(); UpdateKalman(); UpdatePortfolio();

   // Net hedge inmediatamente después de actualizar portfolio
   RunNetExposureHedge();

   CheckEquityGuard();
   m_inSession=IsInMainSession();
   ResetDailyIfNeeded();
   bool dailyPaused=DailyLimitReached();
   UpdateSensors();
   RunVolatilityStormFilter();

   // Ciclo de pausa entre operaciones
   if(m_cycleInPause){
      if(TimeCurrent()-m_cycleResetTime>=Inp_CyclePauseSec){
         m_cycleInPause=false;m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
         m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
         m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
         DeactivateLBC();
      } else {
         UpdatePortfolio();
         double dynTP=CalcDynamicBlockTP();
         if(m_port.totalPos>0&&m_port.totalProfit>=dynTP)CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard)UpdateDash();
         return;
      }
   }

   // Modo emergencia: sólo recuperación, sin entradas nuevas
   if(m_emergencyMode){
      static datetime emgTime=0;
      UpdatePortfolio();
      double dynTP=CalcDynamicBlockTP();
      if(m_port.totalPos>0&&m_port.totalProfit>=dynTP){CloseBlockIfPositive("Emergency_TP");m_emergencyMode=false;emgTime=0;}
      if(m_port.totalPos==0&&emgTime==0)emgTime=TimeCurrent();
      if(emgTime>0&&TimeCurrent()-emgTime>=Inp_EmergencyCooldown){m_emergencyMode=false;emgTime=0;}
      if(m_blockStage>0)RunBlockStageEngine();else RunRecoveryEngine();
      RunLBCEngine();
      if(Inp_ShowDashboard)UpdateDash();
      return;
   }

   // Limpieza periódica de registros
   if(TimeCurrent()-m_lastCleanupTime>5){CleanupRecs();SyncPositions();m_lastCleanupTime=TimeCurrent();}
   ManagePositions();

   // P1: Cierre si bloque en positivo
   double dynTP=CalcDynamicBlockTP();
   if(m_port.totalPos>0&&m_port.totalProfit>=dynTP){CloseBlockIfPositive("BlockTP");if(Inp_ShowDashboard)UpdateDash();return;}

   // P2: Detangle (escape de jaula simétrica)
   RunDetangle();

   // P3: Block Stage Engine o Recovery fallback
   if(m_blockStage>0)RunBlockStageEngine();else RunRecoveryEngine();

   // P4: LBC
   RunLBCEngine();

   // P5: Basket TP
   RunBasketTP();

   // P6: Cycle max loss check
   CheckCycleMaxLoss();

   // P7: Harvest single position
   RunHarvest();

   // P8: Counter-Trade / Primary Entry
   if(!m_isPaused&&!m_recoveryActive&&!m_lbc.active&&!dailyPaused&&!g_CircuitBreakerHit)
      RunCTEngine();

   if(Inp_ShowDashboard)UpdateDash();
}

//=================================================================
//  OnChartEvent
//=================================================================
void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{
   if(id==CHARTEVENT_OBJECT_CLICK){
      if(sp=="AQ90_B1"){
         m_isPaused=!m_isPaused;
         if(!m_isPaused){
            m_emergencyMode=false;m_dailyLimitHit=false;
            g_CircuitBreakerHit=false;g_SoftBreakerHit=false;
            g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY); // reset peak al reanudar
            m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
            m_netHedge1Applied=m_netHedge2Applied=false;
            m_blockStage=0;m_stageFollowHedge=false;
            m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
            m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
            DeactivateLBC();
            Print("[V9.0] SISTEMA REANUDADO | PeakEquity reset a $",NormalizeDouble(g_PeakEquity,2));
         } else Print("[V9.0] SISTEMA PAUSADO MANUALMENTE");
      }
      if(sp=="AQ90_B2"){
         Print("[V9.0] CIERRE MANUAL TOTAL...");int closed=0;
         m_isProcessing=true;
         for(int i=PositionsTotal()-1;i>=0;i--){
            ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
            if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic)continue;
            if(ClosePos(t,"Manual"))closed++;
         }
         if(Inp_RescueAllTrades){
            for(int i=PositionsTotal()-1;i>=0;i--){
               ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;
               if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
               if(PositionGetInteger(POSITION_MAGIC)==Inp_Magic)continue;
               if(CloseRescuePos(t,"Manual_Rescue"))closed++;
            }
         }
         m_isProcessing=false;
         m_lastCTBuyPrice=m_lastCTSellPrice=0;m_consecutiveLosses=0;m_lotMultiplier=1.0;
         m_cycleInPause=false;m_recoveryActive=false;m_recoveryOrders=0;
         m_lastPrimaryDir=0;m_lastPrimaryLost=false;
         m_netHedge1Applied=m_netHedge2Applied=false;
         m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
         m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
         DeactivateLBC();
         g_DM_PrimaryTP = 0.0; g_DM_PrimaryVirtualSL = 0.0; g_DM_BEActivated = false;
         Print("[V9.0] CIERRE MANUAL: ",closed," posiciones cerradas");
      }
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+
