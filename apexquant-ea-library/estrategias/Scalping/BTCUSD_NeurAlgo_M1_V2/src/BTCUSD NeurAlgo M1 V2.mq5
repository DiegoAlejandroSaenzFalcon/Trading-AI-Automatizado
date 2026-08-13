//+------------------------------------------------------------------+
//|   APEXQUANT V9.1-BTC-CAPITALGUARD                                |
//|   "DIRECTIONAL RECOVERY - ANTI-SYMMETRIC ENGINE"                 |
//|   ASSET: BTCUSD (Crypto 24/7)                                    |
//|                                                                  |
//| FUSION: V8.0-BTC-ADAPTIVE + V9.0-XAUUSD-CAPITALGUARD            |
//|                                                                  |
//| FROM V9.0-CAPITALGUARD (adapted from XAUUSD crash RCA):         |
//| [V9-F1] g_TFMult: auto TF multiplier M1=1.0 M5=2.2 M15=3.9     |
//| [V9-F2] CalcMaxSafeLot(): hard cap on free margin usage          |
//| [V9-F3] HardEquityCircuitBreaker(): closes all if DD > X%        |
//| [V9-F4] Dynamic BlockTP = max(floor, |loss|*RRRatio)             |
//| [V9-F5] AutoLot: Balance * AutoLotPct, recalc each cycle         |
//| [V9-F6] RecoveryMaxOrders hard-capped (no trend exception)       |
//| [V9-F7] All lot funcs pass through CalcMaxSafeLot()              |
//| [V9-F8] MaxTotalVolume: absolute vol cap in market               |
//| [V9-F9] SoftCircuitBreaker: pauses new entries at DD threshold   |
//|                                                                  |
//| FROM V8.0-BTC-ADAPTIVE (BTC-specific engines):                   |
//| [V8-SPR] Adaptive spread: rolling mean+2sigma (data: mu=1545)    |
//| [V8-LIQ] BTC liquidity: CHAOTIC/ACTIVE/DEAD/NORMAL via ATR vel  |
//| [V8-DIR] 5-factor directional score (min 0.50 to enter)          |
//| [V8-VOL] Vol lot factors: HIGH=0.60x LOW=1.20x NORMAL=1.00x     |
//|                                                                  |
//| PRESERVED (V7.x):                                                |
//| AntiSymmetric Guard | BSE 4 Stages | TEMA+Kalman | Detangle      |
//| LBC | Net Hedge | Dynamic Thresholds | Storm Filter              |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V9.1-BTC-CAPITALGUARD"
#property version   "9.10"
#property strict
#property description "BTCUSD V9.1 CapitalGuard + Adaptive Directional Recovery"

#define VERSION_STR     "APEXQUANT_V9.1-BTC-CAPITALGUARD"
#define SPREAD_BUF_SIZE 60
#define ATR_VEL_SIZE    10
#define MAX_RECORDS     80

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

enum ENUM_CT_MODE       { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };
enum ENUM_SESSION_STATE { SESSION_ASIAN=0,SESSION_LONDON=1,SESSION_OVERLAP=2,SESSION_NY=3,SESSION_OFF=4 };
enum ENUM_VOL_REGIME    { VOL_LOW=0,VOL_NORMAL=1,VOL_HIGH=2 };
enum ENUM_BTC_LIQUIDITY { BTC_LIQ_DEAD=0,BTC_LIQ_NORMAL=1,BTC_LIQ_ACTIVE=2,BTC_LIQ_CHAOTIC=3 };

//=================================================================
// INPUT PARAMETERS
//=================================================================

// ================================================================
// [V9.0] CAPITAL GUARD — ANTI-CRASH LAYER
// ================================================================
input group "=== [V9.0] CAPITAL GUARD (ANTI-CRASH) ==="
input double Inp_MaxMarginUsagePct     = 0.35;
input double Inp_HardCircuitBreakerPct = 0.20;
input double Inp_SoftCircuitBreakerPct = 0.12;
input double Inp_AutoLotPct            = 0.001;
input bool   Inp_UseAutoLot            = true;
input double Inp_LotHardCap            = 0.05;
input double Inp_MaxTotalVolume        = 0.15;
input double Inp_TPRRR                 = 0.12;

// ================================================================
// [V9.0] TIMEFRAME ADAPTATION
// ================================================================
input group "=== [V9.0] TIMEFRAME ADAPTATION ==="
input double Inp_TFMultOverride        = 0.0;
input bool   Inp_AutoTFScale           = true;

// ================================================================
// [V8.0] ADAPTIVE SPREAD — DATA: mean=1545 std=210
// ================================================================
input group "=== [V8.0] ADAPTIVE SPREAD === mu=1545 std=210"
input int    Inp_AdaptSpreadWindow     = 60;
input double Inp_AdaptSpreadK          = 2.0;
input int    Inp_AdaptSpreadHardCap    = 3500;
input double Inp_AdaptSpreadRecovF     = 1.5;
input int    Inp_AdaptSpreadFloor      = 1600;

// ================================================================
// [V8.0] BTC LIQUIDITY CYCLE — CHAOTIC=0.67% ACTIVE=14.5%
// ================================================================
input group "=== [V8.0] BTC LIQUIDITY === CHAOTIC=0.67% ACTIVE=14.5%"
input double Inp_BTCLiqChaoticRatio    = 0.75;
input double Inp_BTCLiqDeadRatio       = 0.50;
input double Inp_BTCLiqActiveRatio     = 1.20;
input double Inp_BTCLiqChaoticLotF     = 0.50;
input double Inp_BTCLiqActiveLotF      = 1.10;
input double Inp_BTCLiqDeadLotF        = 0.80;
input bool   Inp_BTCLiqBlockChaotic    = true;

// ================================================================
// [V8.0] DIRECTIONAL SCORE FILTER
// ================================================================
input group "=== [V8.0] DIRECTIONAL VALIDATOR ==="
input bool   Inp_UseDirValidator       = true;
input double Inp_DirMinScore           = 0.50;
input double Inp_DirRSIBullMin         = 52.0;
input double Inp_DirRSIBearMax         = 48.0;
input double Inp_DirEMASepATR          = 0.10;

// ================================================================
// [V8.0] VOL LOT SIZING — HIGH=3.7% LOW=1.4% of bars
// ================================================================
input group "=== [V8.0] VOL LOT SIZING ==="
input double Inp_VolHighLotFactor      = 0.60;
input double Inp_VolLowLotFactor       = 1.20;
input double Inp_VolNormalLotFactor    = 1.00;

// ================================================================
// [V7.9] BREATHING / ASYMMETRIC
// ================================================================
input group "=== [V7.9] BREATHING / ASYMMETRIC ==="
input int    Inp_PrimaryMinHoldSec     = 120;
input double Inp_StageEmergMult        = 2.0;
input double Inp_HedgeRatio            = 0.50;
input bool   Inp_UseDirectionalStage   = true;
input double Inp_ReinforceLotMult      = 1.50;

// ================================================================
// [V7.9] DETANGLE
// ================================================================
input group "=== [V7.9] DETANGLE ==="
input int    Inp_DetangleSec           = 180;
input double Inp_DetangleNetThresh     = 0.005;
input double Inp_DetangleMinLoss       = -3.00;

// ================================================================
// [V7.8] DYNAMIC THRESHOLDS
// ================================================================
input group "=== [V7.8] DYNAMIC THRESHOLDS ==="
input double Inp_DynStage1Mult         = 1.20;
input double Inp_DynStage3Mult         = 2.50;
input double Inp_DynTPMult             = 0.80;
input double Inp_DynRecovMult          = 0.60;
input double Inp_DynMaxStage1USD       = 10.00;
input double Inp_DynMaxStage3USD       = 20.00;
input double Inp_DynMaxTPUSD           = 5.00;

// ================================================================
// [V7.8] SESSION FACTORS
// ================================================================
input group "=== [V7.8] SESSION FACTORS ==="
input double Inp_SessFactorAsian       = 0.65;
input double Inp_SessFactorLondon      = 1.00;
input double Inp_SessFactorOverlap     = 1.25;
input double Inp_SessFactorNY          = 1.10;
input double Inp_SessFactorOff         = 0.55;
input int    Inp_Stage2DelayAsian      = 20;
input int    Inp_Stage2DelayLondon     = 6;
input int    Inp_Stage2DelayOverlap    = 3;
input int    Inp_Stage2DelayNY         = 5;

// ================================================================
// [V7.8] RECOVERY DISTANCE
// ================================================================
input group "=== [V7.8] RECOVERY DISTANCE ==="
input double Inp_RecovDistLow          = 0.30;
input double Inp_RecovDistNormal       = 0.50;
input double Inp_RecovDistHigh         = 0.85;

// ================================================================
// [V7.7] TEMA + KALMAN
// ================================================================
input group "=== [V7.7] TEMA + KALMAN ==="
input bool   Inp_UseTEMAKalman         = true;
input int    Inp_TEMAFastPeriod        = 21;
input int    Inp_TEMASlowPeriod        = 55;
input double Inp_KalmanQ               = 0.0001;
input double Inp_KalmanR               = 0.005;

// ================================================================
// BLOCK STAGE ENGINE
// ================================================================
input group "=== BLOCK STAGE ENGINE ==="
input double Inp_Stage1Trigger         = -1.50;
input double Inp_Stage3Trigger         = -3.00;
input int    Inp_Stage2DelaySec        = 5;

// ================================================================
// [V7.6C] STORM FILTER
// ================================================================
input group "=== [V7.6C] STORM FILTER ==="
input bool   Inp_UseStormFilter        = true;
input int    Inp_StormATRWindow        = 20;
input double Inp_StormATRMult          = 2.0;
input double Inp_StormSpreadMult       = 2.5;
input int    Inp_StormCooldownSec      = 30;

// ================================================================
// [V7.6B] NET EXPOSURE HEDGE
// ================================================================
input group "=== [V7.6B] NET EXPOSURE HEDGE ==="
input bool   Inp_UseNetHedge           = true;
input double Inp_NetHedgeTrigger1USD   = -5.0;
input double Inp_NetHedgeTrigger2USD   = -8.0;
input double Inp_NetHedgeMult1         = 2.0;
input double Inp_NetHedgeMult2         = 3.5;
input int    Inp_NetHedgeIntervalSec   = 5;

// ================================================================
// MAIN CONFIG
// ================================================================
input group "=== MAIN CONFIG ==="
input long   Inp_Magic                 = 1111;
input int    Inp_MaxPositionsTotal     = 6;
input double Inp_LotBase               = 0.01;
input double Inp_LotMaximum            = 0.05;
input double Inp_RiskPerTradePct       = 0.005;
input bool   Inp_UseDynamicLot         = true;
input double Inp_CTMinBalanceUSD       = 5.0;
input double Inp_MinFreeMarginPct      = 0.05;

// ================================================================
// BLOCK TP / SL
// ================================================================
input group "=== BLOCK TP/SL ==="
input double Inp_BlockTPTarget         = 2.00;
input double Inp_SL_ATR                = 1.2;
input double Inp_OffSessionSL_ATR      = 1.0;

// ================================================================
// RECOVERY ENGINE
// ================================================================
input group "=== RECOVERY ENGINE ==="
input double Inp_RecoveryTriggerUSD    = -1.00;
input double Inp_RecoveryMoveATR       = 0.5;
input double Inp_RecoveryMinLotMult    = 1.50;
input int    Inp_RecoveryMaxOrders     = 2;
input int    Inp_RecoveryIntervalSec   = 3;

// ================================================================
// LBC ENGINE
// ================================================================
input group "=== LBC ENGINE ==="
input int    Inp_LBCMaxPairs           = 3;
input double Inp_LBCGridATR            = 0.30;
input double Inp_LBCHarvestATR         = 0.15;
input int    Inp_LBCIntervalSec        = 8;
input double Inp_LBCMarginPct          = 0.40;

// ================================================================
// CT ENGINE
// ================================================================
input group "=== CT ENGINE ==="
input ENUM_CT_MODE Inp_CTMode          = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR         = 1.2;
input int    Inp_CTFixedPoints         = 1000;
input int    Inp_CTIntervalSec         = 10;
input int    Inp_CTMaxSameDir          = 2;
input int    Inp_PrimaryCooldownSec    = 10;
input int    Inp_PrimaryCooldownOff    = 20;

// ================================================================
// SESSIONS
// ================================================================
input group "=== SESSIONS ==="
input int    Inp_GMTOffset             = 0;
input int    Inp_LondonOpen            = 7;
input int    Inp_LondonClose           = 17;
input int    Inp_NYOpen                = 13;
input int    Inp_NYClose               = 22;
input double Inp_OffSessionLotFactor   = 0.80;

// ================================================================
// BASKET TP / HARVEST / CYCLE
// ================================================================
input group "=== BASKET TP ==="
input bool   Inp_UseBasketTP           = true;
input double Inp_BasketTPFactor        = 0.60;
input double Inp_BasketTPRatio         = 1.5;
input int    Inp_BasketCheckSec        = 3;

input group "=== HARVEST ==="
input bool   Inp_HarvestContinuous     = true;
input int    Inp_HarvestIntervalSec    = 3;

input group "=== CYCLE CONTROL ==="
input bool   Inp_UseCycleMaxLoss       = true;
input double Inp_CycleMaxLossUSD       = -100.00;
input int    Inp_CyclePauseSec         = 30;

// ================================================================
// ADX + HTF
// ================================================================
input group "=== ADX + HTF ==="
input bool   Inp_UseADX                = true;
input int    Inp_ADXPeriod             = 14;
input double Inp_ADXTrendLevel         = 30.0;
input double Inp_ADXTrendLevelOff      = 22.0;
input bool   Inp_UseHTF                = true;
input ENUM_TIMEFRAMES Inp_HTFTF        = PERIOD_M5;

// ================================================================
// DAILY PROTECTION
// ================================================================
input group "=== DAILY PROTECTION ==="
input bool   Inp_UseDailyLimit         = true;
input double Inp_DailyLossUSD          = -40.0;
input double Inp_DailyLossPct          = 8.0;
input int    Inp_LossStreakMax          = 1;
input double Inp_LossStreakReduce       = 0.70;

// ================================================================
// EQUITY GUARD
// ================================================================
input group "=== EQUITY GUARD ==="
input bool   Inp_UseEquityGuard        = true;
input double Inp_EmergencyLossUSD      = -15.0;
input double Inp_MaxDrawdownPct        = 10.0;
input int    Inp_EmergencyCooldown     = 10;

// ================================================================
// INDICATORS
// ================================================================
input group "=== INDICATORS ==="
input int    Inp_ATRPeriod             = 14;
input int    Inp_EMAFast               = 21;
input int    Inp_EMASlow               = 55;
input int    Inp_RSIPeriod             = 7;
input int    Inp_MACDFast              = 12;
input int    Inp_MACDSlow              = 26;
input int    Inp_MACDSig               = 9;
input int    Inp_ATRSlowPeriod         = 100;
input int    Inp_EMA200Period          = 200;

// ================================================================
// FILTERS
// ================================================================
input group "=== FILTERS ==="
input bool   Inp_UseTimeFilter         = false;
input int    Inp_UserGMT               = -5;
input int    Inp_BrokerGMT             = 2;
input string Inp_StartTime             = "00:00";
input string Inp_EndTime               = "23:59";
input bool   Inp_UseTrendFilter200     = true;
input bool   Inp_UseVolatFilter        = true;
input double Inp_ATRRatioMax           = 2.5;
input double Inp_VolRegimeLowThresh    = 0.65;
input double Inp_VolRegimeHighThresh   = 1.50;
input bool   Inp_UseMarginGuard        = false;
input int    Inp_MarginGuardLevels     = 3;
input bool   Inp_RescueAllTrades       = true;

// ================================================================
// VISUAL
// ================================================================
input group "=== VISUAL ==="
input bool   Inp_ShowDashboard         = true;
input int    Inp_DashX                 = 12;
input int    Inp_DashY                 = 28;

//=================================================================
// STRUCTURES
//=================================================================
struct PosRecord {
   ulong    ticket; int posType; double openPrice,volume,netProfit,peakProfit,kX,kP,kK;
   datetime openTime; string comment;
   bool     isPrimary,isCounter,isRecovery,isLBC,kInit;
};
struct Portfolio {
   int    totalPos,buyCount,sellCount,ctCount,recoveryCount,lbcCount,rescueCount,blockDir;
   double buyProfit,sellProfit,totalProfit,positiveSum,negativeSum,worstProfit;
   ulong  worstTicket;
   double currentDD,blockVWAP,buyVolume,sellVolume,rescueProfit;
};
struct MarketSnap {
   double bid,ask,atr,emaFast,emaSlow,rsi,macdMain,macdSig,adx,spread;
   int    htfTrend,trendConfirmed; bool isBullish,isBearish;
   double atrSlow,ema200,temaFast,temaSlow,kalmanFast,kalmanSlow;
};
struct LBCState {
   bool active; int buyCount,sellCount,harvestCount,maxOrdersCalc;
   double lastBuyPrice,lastSellPrice,harvestedTotal;
   datetime lastOrderTime,activatedTime;
};
struct SensorState {
   bool timeOK,spreadOK,trendBull,volatOK,marginOK,allOK;
   string blockReason; double atrRatio;
   int brokerStartMin,brokerEndMin;
};
struct DynThresholds {
   double stage1Trigger,stage3Trigger,blockTP,recovTrigger,recovDistATR;
   double netHedgeTrig1,netHedgeTrig2,sessionFactor,atr2usd;
   int stage2Delay;
   ENUM_SESSION_STATE session; ENUM_VOL_REGIME volRegime;
};
struct AdaptiveSpreadState {
   double buf[SPREAD_BUF_SIZE]; int pos,count;
   double rollingMean,rollingVar,rollingStd,adaptiveThreshold,recovThreshold,spikeRatio;
   bool isSpikeNow; datetime lastUpdateTime;
};
struct LiquidityCycleState {
   ENUM_BTC_LIQUIDITY mode;
   double atrBuf[ATR_VEL_SIZE]; int atrBufPos,atrBufCount;
   double atrVelocity,spreadAtrRatio,lotFactor;
   bool blockEntry; datetime lastUpdate;
};
struct DirectionalScore {
   double bull,bear,compTEMA,compRSI,compMACD,compADX,compEMA;
   bool bullReady,bearReady; string topFactor;
};

//=================================================================
// HANDLES
//=================================================================
int h_ATR,h_EMAFast,h_EMASlow,h_RSI,h_MACD;
int h_ADX=INVALID_HANDLE,h_HTFEMAFast=INVALID_HANDLE,h_HTFEMASlow=INVALID_HANDLE;
int h_ATRSlow=INVALID_HANDLE,h_EMA200=INVALID_HANDLE;

//=================================================================
// GLOBAL STATE
//=================================================================
CTrade m_trade;
PosRecord m_rec[MAX_RECORDS];
Portfolio m_port; MarketSnap m_mkt; LBCState m_lbc;
SensorState m_sensors; DynThresholds m_dyn;
AdaptiveSpreadState  m_adaptSpread;
LiquidityCycleState  m_btcLiq;
DirectionalScore     m_dirScore;

// [V9.0] Capital Guard state
double   g_TFMult            = 1.0;
bool     g_CircuitBreakerHit = false;
bool     g_SoftBreakerHit    = false;
double   g_PeakEquity        = 0.0;
datetime g_CircuitResetTime  = 0;
double   g_MarginPer001      = 5.0;
double   g_AutoBaseLot       = 0.01;

double   m_initialBalance=0,m_bestEquity=0,m_dailyBalance=0;
bool     m_isPaused=false,m_emergencyMode=false,m_dailyLimitHit=false,m_inSession=false;
bool     m_recoveryActive=false,m_recoveryTrendHedge=false; int m_recoveryOrders=0;
bool     m_netHedge1Applied=false,m_netHedge2Applied=false; datetime m_lastNetHedgeTime=0;
bool     m_stormActive=false; datetime m_stormDetectedTime=0;
double   m_stormLastATRRatio=0,m_stormLastSprRatio=0;
double   m_cycleWinsSum=0; int m_cycleWinsCount=0;
bool     m_cycleInPause=false; datetime m_cycleResetTime=0;
int      m_consecutiveLosses=0; double m_lotMultiplier=1.0;
datetime m_lastDailyReset=0;
int      m_lastPrimaryDir=0; datetime m_lastPrimaryTime=0; bool m_lastPrimaryLost=false;
double   m_lastCTBuyPrice=0,m_lastCTSellPrice=0;
datetime m_lastCTTime=0,m_lastRecoveryTime=0,m_lastBasketCheck=0;
datetime m_lastHarvestTime=0,m_lastDashTime=0,m_lastCleanupTime=0;
double   m_totalPnL=0; int m_tradesOpened=0,m_tradesClosed=0;
double   m_bestClosed=0,m_worstClosed=0;
int      m_totalWins=0,m_totalLosses=0; double m_sumWins=0,m_sumLosses=0;
long     m_tickCount=0; bool m_isProcessing=false;
double   m_losingPosOpenPrice=0; int m_losingPosType=-1;
double   m_temaF_e1=0,m_temaF_e2=0,m_temaF_e3=0; bool m_temaF_init=false;
double   m_temaS_e1=0,m_temaS_e2=0,m_temaS_e3=0; bool m_temaS_init=false;
double   m_kalF_x=0,m_kalF_p=1.0; bool m_kalF_init=false;
double   m_kalS_x=0,m_kalS_p=1.0; bool m_kalS_init=false;
int      m_blockStage=0; ENUM_ORDER_TYPE m_primaryType=ORDER_TYPE_BUY;
datetime m_stage2Time=0; bool m_stageFollowHedge=false;
double   m_stage1TriggerAtOpen=0,m_stage3TriggerAtOpen=0;
datetime m_detangleDetectTime=0; bool m_detangleActive=false;
datetime m_primaryOpenTime=0;

//=================================================================
// [V9-F1] TIMEFRAME MULTIPLIER
// BTC volatility ratios: M1=1.0 M5=2.24 M15=3.87 M30=5.48 H1=7.75
//=================================================================
double CalcTFMult() {
   if(Inp_TFMultOverride>0) return Inp_TFMultOverride;
   int tfMin=PeriodSeconds(_Period)/60;
   if(tfMin<=1)   return 1.00;
   if(tfMin<=5)   return 2.24;
   if(tfMin<=15)  return 3.87;
   if(tfMin<=30)  return 5.48;
   if(tfMin<=60)  return 7.75;
   if(tfMin<=240) return 15.50;
   return 1.00;
}
double GetATR_M1Norm() { return (g_TFMult>0)?m_mkt.atr/g_TFMult:m_mkt.atr; }

//=================================================================
// [V9-F2][V9-F5] CAPITAL GUARD — LOT MANAGEMENT
//=================================================================
void CalibrateMarginPerLot() {
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return;
   double marg=0;
   if(OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,0.01,t.ask,marg)&&marg>0) g_MarginPer001=marg;
   else g_MarginPer001=5.0;
}
void RecalcAutoBaseLot() {
   if(!Inp_UseAutoLot){g_AutoBaseLot=Inp_LotBase;return;}
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<=0){g_AutoBaseLot=Inp_LotBase;return;}
   double rawLot=bal*Inp_AutoLotPct;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(step<=0)step=0.01;
   rawLot=MathFloor(rawLot/step)*step;
   g_AutoBaseLot=NormalizeDouble(MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),MathMin(rawLot,Inp_LotHardCap)),2);
}
double CalcMaxSafeLot() {
   CalibrateMarginPerLot();
   double freeMarg=AccountInfoDouble(ACCOUNT_MARGIN_FREE);if(freeMarg<=0)return g_AutoBaseLot;
   double maxMarginAllowed=freeMarg*Inp_MaxMarginUsagePct;
   double usedMarg=AccountInfoDouble(ACCOUNT_MARGIN);
   double availForNew=MathMax(0,maxMarginAllowed-usedMarg);
   if(g_MarginPer001<=0)return g_AutoBaseLot;
   double maxLot=NormalizeDouble((availForNew/g_MarginPer001)*0.01,2);
   return NormalizeDouble(MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),MathMin(maxLot,Inp_LotHardCap)),2);
}
bool TotalVolumeOK(double addLot=0){return(m_port.buyVolume+m_port.sellVolume+addLot<=Inp_MaxTotalVolume);}

//=================================================================
// [V9-F3] HARD EQUITY CIRCUIT BREAKER
//=================================================================
bool HardEquityCircuitBreaker() {
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_PeakEquity) g_PeakEquity=eq;
   if(g_PeakEquity<=0) return false;
   double dd=(g_PeakEquity-eq)/g_PeakEquity;
   if(dd>=Inp_SoftCircuitBreakerPct&&!g_SoftBreakerHit){
      g_SoftBreakerHit=true; m_isPaused=true;
      Print("[V9.1-BTC] SOFT BREAKER: DD=",NormalizeDouble(dd*100,1),"% >= ",NormalizeDouble(Inp_SoftCircuitBreakerPct*100,1),"% | Pausando entradas");
   }
   if(dd<Inp_SoftCircuitBreakerPct*0.5&&g_SoftBreakerHit&&!g_CircuitBreakerHit){
      g_SoftBreakerHit=false; m_isPaused=false;
      Print("[V9.1-BTC] SOFT BREAKER recuperado");
   }
   if(dd>=Inp_HardCircuitBreakerPct) {
      if(!g_CircuitBreakerHit) {
         g_CircuitBreakerHit=true; g_CircuitResetTime=TimeCurrent();
         Print("[V9.1-BTC] HARD CIRCUIT BREAKER: DD=",NormalizeDouble(dd*100,1),"% | PeakEq=$",NormalizeDouble(g_PeakEquity,2)," CurEq=$",NormalizeDouble(eq,2));
         m_isProcessing=true;
         for(int i=PositionsTotal()-1;i>=0;i--) {
            ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
            if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic)continue;
            double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
            if(pf>=0){m_trade.PositionClose(t);Print("[V9.1-BTC] CB closed #",t," $",NormalizeDouble(pf,2));}
            else Print("[V9.1-BTC] CB held negative #",t," $",NormalizeDouble(pf,2));
         }
         m_isProcessing=false;
         m_blockStage=0;m_recoveryActive=false;m_recoveryOrders=0;
         m_netHedge1Applied=m_netHedge2Applied=false;
         m_stageFollowHedge=false;m_primaryOpenTime=0;
         m_detangleDetectTime=0;m_detangleActive=false;
         ZeroMemory(m_lbc); m_isPaused=true;
      }
      return true;
   }
   if(g_CircuitBreakerHit&&m_port.totalPos==0) {
      if((int)(TimeCurrent()-g_CircuitResetTime)>300) {
         g_CircuitBreakerHit=false;g_SoftBreakerHit=false;m_isPaused=false;m_emergencyMode=false;
         g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
         Print("[V9.1-BTC] Hard circuit breaker cooldown completo. Reanudando.");
      }
   }
   return g_CircuitBreakerHit;
}

//=================================================================
// [V9-F4] DYNAMIC BLOCK TP
//=================================================================
double CalcDynamicBlockTP() {
   double floorTP=MathMax(Inp_BlockTPTarget,m_dyn.atr2usd*Inp_DynTPMult*m_dyn.sessionFactor);
   floorTP=MathMin(floorTP,Inp_DynMaxTPUSD);
   if(m_port.totalProfit>=0) return floorTP;
   return MathMax(floorTP,MathAbs(m_port.totalProfit)*Inp_TPRRR);
}

//=================================================================
// [V8-SPR] ADAPTIVE SPREAD ENGINE
//=================================================================
void UpdateAdaptiveSpread(double cur) {
   m_adaptSpread.buf[m_adaptSpread.pos]=cur;
   m_adaptSpread.pos=(m_adaptSpread.pos+1)%SPREAD_BUF_SIZE;
   if(m_adaptSpread.count<SPREAD_BUF_SIZE)m_adaptSpread.count++;
   int n=m_adaptSpread.count;
   if(n<5){m_adaptSpread.rollingMean=1545.0;m_adaptSpread.rollingStd=210.0;
      m_adaptSpread.adaptiveThreshold=MathMax((double)Inp_AdaptSpreadFloor,1545.0+Inp_AdaptSpreadK*210.0);
      m_adaptSpread.recovThreshold=m_adaptSpread.adaptiveThreshold*Inp_AdaptSpreadRecovF;return;}
   double sum=0,sumSq=0;
   for(int i=0;i<n;i++){double v=m_adaptSpread.buf[i];sum+=v;sumSq+=v*v;}
   m_adaptSpread.rollingMean=sum/n;
   m_adaptSpread.rollingVar=MathMax(0.0,(sumSq/n)-(m_adaptSpread.rollingMean*m_adaptSpread.rollingMean));
   m_adaptSpread.rollingStd=MathSqrt(m_adaptSpread.rollingVar);
   double rawT=m_adaptSpread.rollingMean+Inp_AdaptSpreadK*m_adaptSpread.rollingStd;
   rawT=MathMax((double)Inp_AdaptSpreadFloor,MathMin((double)Inp_AdaptSpreadHardCap,rawT));
   m_adaptSpread.adaptiveThreshold=rawT;
   m_adaptSpread.recovThreshold=MathMin((double)Inp_AdaptSpreadHardCap,rawT*Inp_AdaptSpreadRecovF);
   m_adaptSpread.spikeRatio=(m_adaptSpread.rollingMean>0)?cur/m_adaptSpread.rollingMean:1.0;
   m_adaptSpread.isSpikeNow=(cur>m_adaptSpread.adaptiveThreshold);
   m_adaptSpread.lastUpdateTime=TimeCurrent();
}
bool AdaptiveSpreadOK(bool forRecovery=false){
   double cur=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   if(cur>(double)Inp_AdaptSpreadHardCap)return false;
   return cur<=(forRecovery?m_adaptSpread.recovThreshold:m_adaptSpread.adaptiveThreshold);
}
bool SpreadOK(bool forRecovery=false){return AdaptiveSpreadOK(forRecovery);}

//=================================================================
// [V8-LIQ] BTC LIQUIDITY CYCLE ENGINE
//=================================================================
void UpdateBTCLiquidityCycle(){
   if(m_mkt.atr<=0||m_mkt.atrSlow<=0)return;
   double atrNorm=GetATR_M1Norm();
   m_btcLiq.atrBuf[m_btcLiq.atrBufPos]=atrNorm;
   m_btcLiq.atrBufPos=(m_btcLiq.atrBufPos+1)%ATR_VEL_SIZE;
   if(m_btcLiq.atrBufCount<ATR_VEL_SIZE)m_btcLiq.atrBufCount++;
   if(m_btcLiq.atrBufCount>=5)m_btcLiq.atrVelocity=atrNorm-m_btcLiq.atrBuf[m_btcLiq.atrBufPos];
   m_btcLiq.spreadAtrRatio=(atrNorm>0)?((double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)*_Point/atrNorm):0;
   double atrSlowNorm=(g_TFMult>0)?m_mkt.atrSlow/g_TFMult:m_mkt.atrSlow;
   double atrRatio=(atrSlowNorm>0)?(atrNorm/atrSlowNorm):1.0;
   ENUM_BTC_LIQUIDITY prev=m_btcLiq.mode;
   bool hardSpike=((double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)>(double)Inp_AdaptSpreadHardCap*0.85);
   if(m_btcLiq.spreadAtrRatio>=Inp_BTCLiqChaoticRatio||hardSpike)m_btcLiq.mode=BTC_LIQ_CHAOTIC;
   else if(atrRatio<Inp_BTCLiqDeadRatio)m_btcLiq.mode=BTC_LIQ_DEAD;
   else if(atrRatio>=Inp_BTCLiqActiveRatio)m_btcLiq.mode=BTC_LIQ_ACTIVE;
   else m_btcLiq.mode=BTC_LIQ_NORMAL;
   switch(m_btcLiq.mode){
      case BTC_LIQ_CHAOTIC:m_btcLiq.lotFactor=Inp_BTCLiqChaoticLotF;m_btcLiq.blockEntry=Inp_BTCLiqBlockChaotic;break;
      case BTC_LIQ_DEAD:m_btcLiq.lotFactor=Inp_BTCLiqDeadLotF;m_btcLiq.blockEntry=false;break;
      case BTC_LIQ_ACTIVE:m_btcLiq.lotFactor=Inp_BTCLiqActiveLotF;m_btcLiq.blockEntry=false;break;
      default:m_btcLiq.lotFactor=1.0;m_btcLiq.blockEntry=false;
   }
   if(prev!=m_btcLiq.mode){string mn[]={"DEAD","NORMAL","ACTIVE","CHAOTIC"};Print("[V9.1-BTC] LIQ: ",mn[prev],"->",mn[m_btcLiq.mode]);}
}
string BTCLiqName(ENUM_BTC_LIQUIDITY m){switch(m){case BTC_LIQ_DEAD:return"DEAD";case BTC_LIQ_ACTIVE:return"ACTIVE";case BTC_LIQ_CHAOTIC:return"CHAOTIC";default:return"NORMAL";}}

//=================================================================
// [V8-VOL] VOL LOT FACTOR
//=================================================================
double GetVolLotFactor(){
   switch(m_dyn.volRegime){case VOL_HIGH:return Inp_VolHighLotFactor;case VOL_LOW:return Inp_VolLowLotFactor;default:return Inp_VolNormalLotFactor;}
}

//=================================================================
// [V8-DIR] 5-FACTOR DIRECTIONAL SCORE
//=================================================================
void CalcDirectionalScore(){
   if(!Inp_UseDirValidator){m_dirScore.bull=m_mkt.isBullish?1.0:0.0;m_dirScore.bear=m_mkt.isBearish?1.0:0.0;m_dirScore.bullReady=m_mkt.isBullish;m_dirScore.bearReady=m_mkt.isBearish;m_dirScore.topFactor="DISABLED";return;}
   double b=0,d=0;
   double w1=0.25;if(m_mkt.trendConfirmed==1){b+=w1;m_dirScore.compTEMA=w1;}else if(m_mkt.trendConfirmed==-1){d+=w1;m_dirScore.compTEMA=-w1;}else m_dirScore.compTEMA=0;
   double w2=0.20;if(m_mkt.rsi>=Inp_DirRSIBullMin){b+=w2;m_dirScore.compRSI=w2;}else if(m_mkt.rsi<=Inp_DirRSIBearMax){d+=w2;m_dirScore.compRSI=-w2;}else m_dirScore.compRSI=0;
   double w3=0.15;double md=m_mkt.macdMain-m_mkt.macdSig;if(md>0){b+=w3;m_dirScore.compMACD=w3;}else if(md<0){d+=w3;m_dirScore.compMACD=-w3;}else m_dirScore.compMACD=0;
   double w4=0.20;double adxLvl=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;
   if(m_mkt.adx>=adxLvl){if(m_mkt.htfTrend==1){b+=w4;m_dirScore.compADX=w4;}else if(m_mkt.htfTrend==-1){d+=w4;m_dirScore.compADX=-w4;}else m_dirScore.compADX=0;}else{b+=w4*0.25;d+=w4*0.25;m_dirScore.compADX=0;}
   double w5=0.20;double sep=MathAbs(m_mkt.emaFast-m_mkt.emaSlow);double minSep=(m_mkt.atr>0)?m_mkt.atr*Inp_DirEMASepATR:0;
   if(sep>=minSep){if(m_mkt.emaFast>m_mkt.emaSlow){b+=w5;m_dirScore.compEMA=w5;}else{d+=w5;m_dirScore.compEMA=-w5;}}else m_dirScore.compEMA=0;
   m_dirScore.bull=NormalizeDouble(b,4);m_dirScore.bear=NormalizeDouble(d,4);
   m_dirScore.bullReady=(m_dirScore.bull>=Inp_DirMinScore);m_dirScore.bearReady=(m_dirScore.bear>=Inp_DirMinScore);
   double mx=MathMax(MathAbs(m_dirScore.compTEMA),MathMax(MathAbs(m_dirScore.compRSI),MathMax(MathAbs(m_dirScore.compMACD),MathMax(MathAbs(m_dirScore.compADX),MathAbs(m_dirScore.compEMA)))));
   if(mx==MathAbs(m_dirScore.compTEMA))m_dirScore.topFactor="TEMA/KAL";
   else if(mx==MathAbs(m_dirScore.compRSI))m_dirScore.topFactor="RSI";
   else if(mx==MathAbs(m_dirScore.compMACD))m_dirScore.topFactor="MACD";
   else if(mx==MathAbs(m_dirScore.compADX))m_dirScore.topFactor="ADX/HTF";
   else m_dirScore.topFactor="EMA-SEP";
}

//=================================================================
// DYNAMIC THRESHOLDS
//=================================================================
double ATR2USD(double mult=1.0){
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double atrN=GetATR_M1Norm();if(tv<=0||ts<=0||atrN<=0)return 0;
   return NormalizeDouble((atrN*mult/ts)*tv*g_AutoBaseLot,4);
}
ENUM_SESSION_STATE GetCurrentSession(){
   MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);int h=(dt.hour-Inp_GMTOffset+24)%24;
   if(h>=12&&h<17)return SESSION_OVERLAP;if(h>=7&&h<12)return SESSION_LONDON;
   if(h>=17&&h<22)return SESSION_NY;if(h>=2&&h<7)return SESSION_ASIAN;return SESSION_OFF;
}
double GetSessionFactor(ENUM_SESSION_STATE s){switch(s){case SESSION_ASIAN:return Inp_SessFactorAsian;case SESSION_LONDON:return Inp_SessFactorLondon;case SESSION_OVERLAP:return Inp_SessFactorOverlap;case SESSION_NY:return Inp_SessFactorNY;default:return Inp_SessFactorOff;}}
ENUM_VOL_REGIME GetVolatilityRegime(){
   if(m_mkt.atrSlow<=0||m_mkt.atr<=0)return VOL_NORMAL;
   double atrN=GetATR_M1Norm();double atrSlowN=(g_TFMult>0)?m_mkt.atrSlow/g_TFMult:m_mkt.atrSlow;
   double r=(atrSlowN>0)?atrN/atrSlowN:1.0;
   if(r>Inp_VolRegimeHighThresh)return VOL_HIGH;if(r<Inp_VolRegimeLowThresh)return VOL_LOW;return VOL_NORMAL;
}
string VolRegimeName(ENUM_VOL_REGIME r){switch(r){case VOL_LOW:return"LOW";case VOL_HIGH:return"HIGH";default:return"NORM";}}
string SessionName(ENUM_SESSION_STATE s){switch(s){case SESSION_ASIAN:return"ASIAN";case SESSION_LONDON:return"LON";case SESSION_OVERLAP:return"OVR";case SESSION_NY:return"NY";default:return"OFF";}}
int GetStage2Delay(ENUM_SESSION_STATE s){
   int base;switch(s){case SESSION_ASIAN:base=Inp_Stage2DelayAsian;break;case SESSION_LONDON:base=Inp_Stage2DelayLondon;break;case SESSION_OVERLAP:base=Inp_Stage2DelayOverlap;break;case SESSION_NY:base=Inp_Stage2DelayNY;break;default:base=Inp_Stage2DelayAsian;}
   int tfSec=PeriodSeconds(_Period);return(int)MathMax((double)base,(double)tfSec*0.5);
}
double GetRecovDistATR(ENUM_VOL_REGIME r){switch(r){case VOL_LOW:return Inp_RecovDistLow;case VOL_HIGH:return Inp_RecovDistHigh;default:return Inp_RecovDistNormal;}}
void UpdateDynamicThresholds(){
   m_dyn.session=GetCurrentSession();m_dyn.volRegime=GetVolatilityRegime();
   m_dyn.sessionFactor=GetSessionFactor(m_dyn.session);m_dyn.atr2usd=ATR2USD(1.0);
   double atr=m_dyn.atr2usd;
   if(atr<=0.01){m_dyn.stage1Trigger=Inp_Stage1Trigger;m_dyn.stage3Trigger=Inp_Stage3Trigger;m_dyn.blockTP=Inp_BlockTPTarget;m_dyn.recovTrigger=Inp_RecoveryTriggerUSD;m_dyn.netHedgeTrig1=Inp_NetHedgeTrigger1USD;m_dyn.netHedgeTrig2=Inp_NetHedgeTrigger2USD;}
   else{double sf=m_dyn.sessionFactor;
      double s1=-(atr*Inp_DynStage1Mult*sf);s1=MathMax(s1,-Inp_DynMaxStage1USD);m_dyn.stage1Trigger=MathMin(s1,Inp_Stage1Trigger);
      double s3=-(atr*Inp_DynStage3Mult*sf);s3=MathMax(s3,-Inp_DynMaxStage3USD);m_dyn.stage3Trigger=MathMin(s3,Inp_Stage3Trigger);
      double tp=atr*Inp_DynTPMult*sf;tp=MathMin(tp,Inp_DynMaxTPUSD);m_dyn.blockTP=MathMax(tp,Inp_BlockTPTarget);
      m_dyn.blockTP=CalcDynamicBlockTP();
      m_dyn.recovTrigger=MathMin(-(atr*Inp_DynRecovMult*sf),Inp_RecoveryTriggerUSD);
      m_dyn.netHedgeTrig1=MathMin(-(atr*Inp_NetHedgeMult1),Inp_NetHedgeTrigger1USD);
      m_dyn.netHedgeTrig2=MathMin(-(atr*Inp_NetHedgeMult2),Inp_NetHedgeTrigger2USD);}
   m_dyn.stage2Delay=GetStage2Delay(m_dyn.session);m_dyn.recovDistATR=GetRecovDistATR(m_dyn.volRegime);
}

//=================================================================
// ANTI-SYMMETRIC GUARD
//=================================================================
bool AntiSymmetricOK(ENUM_ORDER_TYPE type,double lot){
   double net=m_port.buyVolume-m_port.sellVolume;double newNet=(type==ORDER_TYPE_BUY)?net+lot:net-lot;
   double ml=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);if(ml<=0)ml=0.01;
   if(MathAbs(newNet)>=ml*0.99)return true;
   Print("[V9.1-BTC] ANTI-SYM GUARD net=",NormalizeDouble(net,3)," newNet=",NormalizeDouble(newNet,3));return false;
}

//=================================================================
// HELPERS
//=================================================================
double NormLot(double lot){
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),MathMin(Inp_LotMaximum,Inp_LotHardCap));
   if(step<=0)step=0.01;lot=MathFloor(lot/step)*step;
   double roomLeft=MathMax(0,Inp_MaxTotalVolume-(m_port.buyVolume+m_port.sellVolume));
   lot=MathMin(lot,roomLeft);lot=MathMin(lot,CalcMaxSafeLot());
   return NormalizeDouble(MathMax(minL,MathMin(maxL,lot)),2);
}
bool GetTick(MqlTick &t){return SymbolInfoTick(_Symbol,t);}
double GetATR(){double b[1];if(CopyBuffer(h_ATR,0,1,1,b)==1)return b[0];return _Point*200;}
double GetTickVal(){return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);}
double GetTickSize(){return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);}
double DistToUSD(double dist,double lot){double tv=GetTickVal(),ts=GetTickSize();if(tv<=0||ts<=0||dist<=0||lot<=0)return 0;return NormalizeDouble((dist/ts)*tv*lot,2);}
bool MarginOK(double lot,ENUM_ORDER_TYPE type){
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE),eq=AccountInfoDouble(ACCOUNT_EQUITY),bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<Inp_CTMinBalanceUSD)return false;if(free<eq*Inp_MinFreeMarginPct)return false;
   MqlTick t;if(!GetTick(t))return false;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg))if(marg>free*0.50)return false;
   if(!TotalVolumeOK(lot))return false;return true;
}
bool MarginOK_Hedge(double lot,ENUM_ORDER_TYPE type){
   if(!TotalVolumeOK(lot))return false;double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);if(free<=0)return false;
   MqlTick t;if(!GetTick(t))return false;double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg)){if(marg<=0)return false;return(marg<=free*0.80);}return false;
}
double CalcMarginFor001(){double marg=0;MqlTick t;GetTick(t);if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,0.01,t.ask,marg))return 2.0;return(marg>0)?marg:2.0;}

//=================================================================
// RECORDS
//=================================================================
int FindRec(ulong ticket){for(int i=0;i<MAX_RECORDS;i++)if(m_rec[i].ticket==ticket)return i;return -1;}
int FreeRec(){for(int i=0;i<MAX_RECORDS;i++)if(m_rec[i].ticket==0)return i;return -1;}
void InitRec(int idx,ulong ticket,int posType,double openPrice,double vol,string comment,bool isPrimary,bool isCounter,bool isRecovery=false,bool isLBC=false){
   if(idx<0||idx>=MAX_RECORDS)return;ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket=ticket;m_rec[idx].posType=posType;m_rec[idx].openPrice=openPrice;
   m_rec[idx].volume=vol;m_rec[idx].openTime=TimeCurrent();m_rec[idx].comment=comment;
   m_rec[idx].isPrimary=isPrimary;m_rec[idx].isCounter=isCounter;
   m_rec[idx].isRecovery=isRecovery;m_rec[idx].isLBC=isLBC;m_rec[idx].kP=1.0;m_rec[idx].kK=1.0;
}
void CleanupRecs(){
   for(int i=0;i<MAX_RECORDS;i++){if(m_rec[i].ticket==0)continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)){
         double pnl=m_rec[i].netProfit;
         if(pnl!=0){m_totalPnL+=pnl;m_tradesClosed++;if(pnl>0){m_totalWins++;m_sumWins+=pnl;}else{m_totalLosses++;m_sumLosses+=MathAbs(pnl);}
            if(pnl>m_bestClosed)m_bestClosed=pnl;if(pnl<m_worstClosed)m_worstClosed=pnl;}ZeroMemory(m_rec[i]);}}
}
void SyncPositions(){
   for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if(FindRec(t)>=0)continue;int idx=FreeRec();if(idx<0)continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);double op=PositionGetDouble(POSITION_PRICE_OPEN),vol=PositionGetDouble(POSITION_VOLUME);
      string comm=PositionGetString(POSITION_COMMENT);
      InitRec(idx,t,pt,op,vol,comm,StringFind(comm,"Primary")>=0,StringFind(comm,"CT_")>=0,
              StringFind(comm,"REC_")>=0||StringFind(comm,"BSE_")>=0,StringFind(comm,"LBC_")>=0);}
}
void UpdateKalman(){
   for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      int idx=FindRec(t);if(idx<0)continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit=pf;if(pf>m_rec[idx].peakProfit)m_rec[idx].peakProfit=pf;
      if(!m_rec[idx].kInit){m_rec[idx].kX=pf;m_rec[idx].kP=1.0;m_rec[idx].kK=1.0;m_rec[idx].kInit=true;continue;}
      double pP=m_rec[idx].kP+0.01,K=pP/(pP+0.20);m_rec[idx].kX+=K*(pf-m_rec[idx].kX);m_rec[idx].kP=(1.0-K)*pP;m_rec[idx].kK=K;}
}

//=================================================================
// MARKET / TEMA / SESSION
//=================================================================
bool IsInMainSession(){MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);int h=(dt.hour-Inp_GMTOffset+24)%24;return((h>=Inp_LondonOpen&&h<Inp_LondonClose)||(h>=Inp_NYOpen&&h<Inp_NYClose));}
void UpdateTEMAKalman(){
   if(!Inp_UseTEMAKalman){m_mkt.trendConfirmed=m_mkt.isBullish?1:(m_mkt.isBearish?-1:0);return;}
   MqlTick tk;if(!GetTick(tk))return;double price=(tk.bid+tk.ask)/2.0;if(price<=0)return;
   double aF=2.0/(double)(Inp_TEMAFastPeriod+1);
   if(!m_temaF_init){m_temaF_e1=m_temaF_e2=m_temaF_e3=price;m_temaF_init=true;}
   m_temaF_e1+=aF*(price-m_temaF_e1);m_temaF_e2+=aF*(m_temaF_e1-m_temaF_e2);m_temaF_e3+=aF*(m_temaF_e2-m_temaF_e3);
   m_mkt.temaFast=3.0*m_temaF_e1-3.0*m_temaF_e2+m_temaF_e3;
   double aS=2.0/(double)(Inp_TEMASlowPeriod+1);
   if(!m_temaS_init){m_temaS_e1=m_temaS_e2=m_temaS_e3=price;m_temaS_init=true;}
   m_temaS_e1+=aS*(price-m_temaS_e1);m_temaS_e2+=aS*(m_temaS_e1-m_temaS_e2);m_temaS_e3+=aS*(m_temaS_e2-m_temaS_e3);
   m_mkt.temaSlow=3.0*m_temaS_e1-3.0*m_temaS_e2+m_temaS_e3;
   if(!m_kalF_init){m_kalF_x=m_mkt.temaFast;m_kalF_p=1.0;m_kalF_init=true;}
   m_kalF_p+=Inp_KalmanQ;double kgF=m_kalF_p/(m_kalF_p+Inp_KalmanR);m_kalF_x+=kgF*(m_mkt.temaFast-m_kalF_x);m_kalF_p*=(1.0-kgF);m_mkt.kalmanFast=m_kalF_x;
   if(!m_kalS_init){m_kalS_x=m_mkt.temaSlow;m_kalS_p=1.0;m_kalS_init=true;}
   m_kalS_p+=Inp_KalmanQ;double kgS=m_kalS_p/(m_kalS_p+Inp_KalmanR);m_kalS_x+=kgS*(m_mkt.temaSlow-m_kalS_x);m_kalS_p*=(1.0-kgS);m_mkt.kalmanSlow=m_kalS_x;
   bool tB=(m_mkt.temaFast>m_mkt.temaSlow),tBr=(m_mkt.temaFast<m_mkt.temaSlow);
   bool kB=(m_mkt.kalmanFast>m_mkt.kalmanSlow),kBr=(m_mkt.kalmanFast<m_mkt.kalmanSlow);
   if(tB&&kB)m_mkt.trendConfirmed=1;else if(tBr&&kBr)m_mkt.trendConfirmed=-1;else m_mkt.trendConfirmed=0;
   m_mkt.isBullish=(m_mkt.trendConfirmed==1);m_mkt.isBearish=(m_mkt.trendConfirmed==-1);
}
void UpdateMarket(){
   MqlTick t;if(!GetTick(t))return;
   m_mkt.bid=t.bid;m_mkt.ask=t.ask;m_mkt.spread=(t.ask-t.bid)/_Point;m_mkt.atr=GetATR();
   UpdateAdaptiveSpread(m_mkt.spread);
   double f[1],s[1],r[1],m[1],sg[1];
   if(CopyBuffer(h_EMAFast,0,0,1,f)==1)m_mkt.emaFast=f[0];if(CopyBuffer(h_EMASlow,0,0,1,s)==1)m_mkt.emaSlow=s[0];
   if(CopyBuffer(h_RSI,0,0,1,r)==1)m_mkt.rsi=r[0];if(CopyBuffer(h_MACD,0,0,1,m)==1)m_mkt.macdMain=m[0];if(CopyBuffer(h_MACD,1,0,1,sg)==1)m_mkt.macdSig=sg[0];
   if(h_ADX!=INVALID_HANDLE){double a[1];if(CopyBuffer(h_ADX,0,0,1,a)==1)m_mkt.adx=a[0];}
   if(h_HTFEMAFast!=INVALID_HANDLE&&h_HTFEMASlow!=INVALID_HANDLE){double hf[1],hs[1];if(CopyBuffer(h_HTFEMAFast,0,0,1,hf)==1&&CopyBuffer(h_HTFEMASlow,0,0,1,hs)==1)m_mkt.htfTrend=(hf[0]>hs[0]*1.0001)?1:(hf[0]<hs[0]*0.9999)?-1:0;}
   if(h_EMA200!=INVALID_HANDLE){double e[1];if(CopyBuffer(h_EMA200,0,1,1,e)==1)m_mkt.ema200=e[0];}
   if(h_ATRSlow!=INVALID_HANDLE){double a[1];if(CopyBuffer(h_ATRSlow,0,1,1,a)==1)m_mkt.atrSlow=a[0];}
   m_mkt.isBullish=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.rsi>52&&m_mkt.macdMain>m_mkt.macdSig);
   m_mkt.isBearish=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.rsi<48&&m_mkt.macdMain<m_mkt.macdSig);
   UpdateTEMAKalman();RecalcAutoBaseLot();UpdateDynamicThresholds();UpdateBTCLiquidityCycle();CalcDirectionalScore();
}

//=================================================================
// PORTFOLIO
//=================================================================
void UpdatePortfolio(){
   ZeroMemory(m_port);m_port.worstProfit=0;m_losingPosOpenPrice=0;m_losingPosType=-1;
   double vN=0,vD=0;
   for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      long mg=PositionGetInteger(POSITION_MAGIC);bool isOwn=(mg==Inp_Magic),isExt=(!isOwn&&Inp_RescueAllTrades);
      if(!isOwn&&!isExt)continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol=PositionGetDouble(POSITION_VOLUME),op=PositionGetDouble(POSITION_PRICE_OPEN);
      string comm=PositionGetString(POSITION_COMMENT);
      m_port.totalPos++;m_port.totalProfit+=pf;
      if(pf>=0)m_port.positiveSum+=pf;else m_port.negativeSum+=MathAbs(pf);
      if(pt==POSITION_TYPE_BUY){m_port.buyCount++;m_port.buyProfit+=pf;m_port.buyVolume+=vol;}
      else{m_port.sellCount++;m_port.sellProfit+=pf;m_port.sellVolume+=vol;}
      vN+=op*vol;vD+=vol;m_port.blockDir+=(pt==POSITION_TYPE_BUY)?1:-1;
      if(pf<m_port.worstProfit){m_port.worstProfit=pf;m_port.worstTicket=t;m_losingPosOpenPrice=op;m_losingPosType=pt;}
      if(isOwn){if(StringFind(comm,"CT_")>=0)m_port.ctCount++;if(StringFind(comm,"REC_")>=0||StringFind(comm,"BSE_")>=0)m_port.recoveryCount++;if(StringFind(comm,"LBC_")>=0)m_port.lbcCount++;}
      if(isExt){m_port.rescueCount++;m_port.rescueProfit+=pf;}}
   if(vD>0)m_port.blockVWAP=vN/vD;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);if(eq>m_bestEquity)m_bestEquity=eq;if(eq>g_PeakEquity)g_PeakEquity=eq;
   m_port.currentDD=(m_bestEquity>0)?(m_bestEquity-eq)/m_bestEquity:0;
}

//=================================================================
// SENSORS
//=================================================================
int ParseHH(string t){return(int)StringToInteger(StringSubstr(t,0,2));}
int ParseMM(string t){return(int)StringToInteger(StringSubstr(t,3,2));}
void CalcBrokerTimeWindow(){
   int s=ParseHH(Inp_StartTime)*60+ParseMM(Inp_StartTime),e=ParseHH(Inp_EndTime)*60+ParseMM(Inp_EndTime);
   int off=(Inp_BrokerGMT-Inp_UserGMT)*60;m_sensors.brokerStartMin=((s+off)%1440+1440)%1440;m_sensors.brokerEndMin=((e+off)%1440+1440)%1440;
}
bool IsInTradingWindow(){if(!Inp_UseTimeFilter)return true;MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);int now=dt.hour*60+dt.min,s=m_sensors.brokerStartMin,e=m_sensors.brokerEndMin;if(s<=e)return(now>=s&&now<e);else return(now>=s||now<e);}
bool TrendFilter200OK(ENUM_ORDER_TYPE type){if(!Inp_UseTrendFilter200||m_mkt.ema200<=0)return true;MqlTick tk;if(!GetTick(tk))return true;double mid=(tk.bid+tk.ask)/2.0;if(type==ORDER_TYPE_BUY)return(mid>m_mkt.ema200);if(type==ORDER_TYPE_SELL)return(mid<m_mkt.ema200);return true;}
bool VolatilityOK(){if(!Inp_UseVolatFilter||m_mkt.atrSlow<=0)return true;double aN=GetATR_M1Norm();double aSlowN=(g_TFMult>0)?m_mkt.atrSlow/g_TFMult:m_mkt.atrSlow;m_sensors.atrRatio=(aSlowN>0)?aN/aSlowN:1.0;return(m_sensors.atrRatio<=Inp_ATRRatioMax);}
double CalcLot(int level=0);
bool MarginGuardOK(){if(!Inp_UseMarginGuard)return true;double lot=g_AutoBaseLot,marg1=0;MqlTick tk;if(!GetTick(tk))return true;if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lot,tk.ask,marg1)||marg1<=0)return true;return(AccountInfoDouble(ACCOUNT_MARGIN_FREE)>=marg1*(1.0+Inp_MarginGuardLevels));}
void UpdateSensors(){
   m_sensors.blockReason="";m_sensors.timeOK=IsInTradingWindow();if(!m_sensors.timeOK&&m_sensors.blockReason=="")m_sensors.blockReason="Outside time window";
   m_sensors.spreadOK=AdaptiveSpreadOK(false);
   if(!m_sensors.spreadOK&&m_sensors.blockReason==""){int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);m_sensors.blockReason="Spread "+IntegerToString(cs)+"pts>"+IntegerToString((int)m_adaptSpread.adaptiveThreshold)+"adaptive";}
   if(m_btcLiq.blockEntry&&m_sensors.blockReason=="")m_sensors.blockReason="CHAOTIC liq SPR/ATR="+DoubleToString(m_btcLiq.spreadAtrRatio,3);
   if(g_CircuitBreakerHit&&m_sensors.blockReason=="")m_sensors.blockReason="HARD CIRCUIT BREAKER";
   if(g_SoftBreakerHit&&m_sensors.blockReason=="")m_sensors.blockReason="SOFT BREAKER DD>"+DoubleToString(Inp_SoftCircuitBreakerPct*100,0)+"%";
   if(m_mkt.ema200>0){MqlTick tk;GetTick(tk);m_sensors.trendBull=((tk.bid+tk.ask)/2.0>m_mkt.ema200);}else m_sensors.trendBull=true;
   m_sensors.volatOK=VolatilityOK();if(!m_sensors.volatOK&&m_sensors.blockReason=="")m_sensors.blockReason="Storm ATR="+DoubleToString(m_sensors.atrRatio,1);
   if(m_dyn.volRegime==VOL_HIGH&&m_sensors.volatOK&&m_sensors.blockReason=="")m_sensors.blockReason="VOL_HIGH regime";
   m_sensors.marginOK=MarginGuardOK();if(!m_sensors.marginOK&&m_sensors.blockReason=="")m_sensors.blockReason="Margin low";
   m_sensors.allOK=(m_sensors.timeOK&&m_sensors.spreadOK&&m_sensors.volatOK&&m_sensors.marginOK&&m_dyn.volRegime!=VOL_HIGH&&!m_btcLiq.blockEntry&&!g_CircuitBreakerHit&&!g_SoftBreakerHit);
}
bool ADXAllowsEntry(ENUM_ORDER_TYPE type){if(!Inp_UseADX)return true;double adxLvl=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;if(m_mkt.adx<adxLvl)return true;int htf=m_mkt.htfTrend;if(htf==0)return false;return(type==ORDER_TYPE_BUY&&htf==1)||(type==ORDER_TYPE_SELL&&htf==-1);}
void ResetDailyIfNeeded(){MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);datetime midnight=TimeCurrent()-(dt.hour*3600+dt.min*60+dt.sec);if(m_lastDailyReset<midnight){m_dailyBalance=AccountInfoDouble(ACCOUNT_BALANCE);m_dailyLimitHit=false;m_lastDailyReset=midnight;}}
bool DailyLimitReached(){if(!Inp_UseDailyLimit||m_dailyLimitHit)return m_dailyLimitHit;double eff=(AccountInfoDouble(ACCOUNT_BALANCE)-m_dailyBalance)+m_port.totalProfit;double lim=MathMin(MathAbs(Inp_DailyLossUSD),m_dailyBalance*MathAbs(Inp_DailyLossPct/100.0));if(eff<=-lim){Print("[V9.1-BTC] DAILY LIMIT HIT");m_dailyLimitHit=true;m_isPaused=true;}return m_dailyLimitHit;}
void UpdateStreak(double pnl){if(pnl<-0.01){m_consecutiveLosses++;if(m_consecutiveLosses>=Inp_LossStreakMax&&m_lotMultiplier==1.0)m_lotMultiplier=Inp_LossStreakReduce;}else if(pnl>0.01){m_lotMultiplier=1.0;m_consecutiveLosses=0;}}
double CalcExpectancy(){int tot=m_totalWins+m_totalLosses;if(tot==0)return 0;double wr=(double)m_totalWins/tot;return(wr*(m_totalWins>0?m_sumWins/m_totalWins:0))-((1.0-wr)*(m_totalLosses>0?m_sumLosses/m_totalLosses:0));}

//=================================================================
// LOT CALCULATION
//=================================================================
double GetEffectiveBaseLot(){
   double lot=g_AutoBaseLot*m_lotMultiplier*GetVolLotFactor()*m_btcLiq.lotFactor;
   if(!m_inSession)lot*=Inp_OffSessionLotFactor;
   return NormLot(lot);
}
double CalcLot(int level=0){return GetEffectiveBaseLot();}
double CalcDirectionalLot(int targetDir){
   double atr=GetATR_M1Norm();if(atr<=0)return NormLot(g_AutoBaseLot*2.0);
   double needed=MathAbs(m_port.totalProfit)*Inp_TPRRR+CalcDynamicBlockTP();
   double mD=atr*Inp_RecoveryMoveATR;if(mD<=0)mD=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),calcLot=g_AutoBaseLot*2.0;
   if(tv>0&&ts>0&&mD>0){double pp=(mD/ts)*tv;if(pp>0)calcLot=needed/pp;}
   calcLot=MathMin(calcLot,Inp_LotHardCap);
   double nv=m_port.buyVolume-m_port.sellVolume;
   double mn=(targetDir==1)?g_AutoBaseLot*1.5-nv:nv+g_AutoBaseLot*1.5;
   return NormLot(MathMin(MathMax(calcLot,MathMax(g_AutoBaseLot*1.5,MathAbs(mn))),Inp_LotHardCap));
}
double CalcRecoveryLot(){
   double atr=GetATR_M1Norm();if(atr<=0)return NormLot(g_AutoBaseLot*Inp_RecoveryMinLotMult);
   double needed=MathAbs(m_port.totalProfit)*Inp_TPRRR+CalcDynamicBlockTP();
   double mD=atr*Inp_RecoveryMoveATR;if(mD<=0)mD=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),pp=0;if(tv>0&&ts>0)pp=(mD/ts)*tv;
   double calcLot=g_AutoBaseLot;if(pp>0)calcLot=needed/pp;
   double safeCap=CalcMaxSafeLot();calcLot=MathMin(MathMin(calcLot,safeCap),Inp_LotHardCap);
   double loserLot=g_AutoBaseLot;
   for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(pf==m_port.worstProfit){loserLot=PositionGetDouble(POSITION_VOLUME);break;}}
   double minLot=MathMin(loserLot*Inp_RecoveryMinLotMult,Inp_LotHardCap);
   return NormLot(MathMax(calcLot,minLot));
}

//=================================================================
// ORDER OPENING
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type,double lot,string comment,bool skipPosLimit=false){
   if((m_isPaused||m_emergencyMode)&&!skipPosLimit)return 0;
   if(g_CircuitBreakerHit)return 0;
   if(!SpreadOK(skipPosLimit))return 0;
   if(!skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal)return 0;
   if(skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal+2)return 0;
   lot=NormLot(lot);if(lot<=0)return 0;
   if(!MarginOK(lot,type))return 0;
   if(!TotalVolumeOK(lot)){Print("[V9.1-BTC] Volume cap hit TotalVol=",NormalizeDouble(m_port.buyVolume+m_port.sellVolume,3)," + ",lot," > ",Inp_MaxTotalVolume);return 0;}
   MqlTick t;if(!GetTick(t))return 0;double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid;
   bool ok=(type==ORDER_TYPE_BUY)?m_trade.Buy(lot,_Symbol,price,0,0,comment):m_trade.Sell(lot,_Symbol,price,0,0,comment);
   if(!ok){Print("[V9.1-BTC] ERR: ",m_trade.ResultRetcodeDescription());return 0;}
   ulong ticket=m_trade.ResultOrder();
   if(ticket>0)Print("[V9.1-BTC] OPEN #",ticket," ",(type==ORDER_TYPE_BUY?"BUY":"SELL")," L=",lot," [",comment,"] Liq=",BTCLiqName(m_btcLiq.mode)," Vol=",VolRegimeName(m_dyn.volRegime)," TotalVol=",NormalizeDouble(m_port.buyVolume+m_port.sellVolume+lot,3));
   return ticket;
}
void ManagePositions(){}

//=================================================================
// CLOSE FUNCTIONS
//=================================================================
bool ClosePos(ulong ticket,string reason=""){
   if(!PositionSelectByTicket(ticket))return false;if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic)return false;
   if(!m_isProcessing&&m_port.totalPos>1){Print("[V9.1-BTC] Individual close BLOCKED #",ticket);return false;}
   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)){UpdateStreak(pf);
      if(pf>0){m_cycleWinsSum+=pf;m_cycleWinsCount++;m_totalWins++;m_sumWins+=pf;}else{m_totalLosses++;m_sumLosses+=MathAbs(pf);}
      m_totalPnL+=pf;m_tradesClosed++;if(pf>m_bestClosed)m_bestClosed=pf;if(pf<m_worstClosed)m_worstClosed=pf;
      int idx=FindRec(ticket);if(idx>=0){if(m_rec[idx].isPrimary)m_lastPrimaryLost=(pf<0);
         if(m_rec[idx].isLBC){if(StringFind(m_rec[idx].comment,"LBC_B")>=0&&m_lbc.buyCount>0)m_lbc.buyCount--;if(StringFind(m_rec[idx].comment,"LBC_S")>=0&&m_lbc.sellCount>0)m_lbc.sellCount--;if(pf>0){m_lbc.harvestedTotal+=pf;m_lbc.harvestCount++;}}
         Print("[V9.1-BTC] CLOSED #",ticket," $",NormalizeDouble(pf,2),(reason!=""?" ["+reason+"]":""));ZeroMemory(m_rec[idx]);}return true;}return false;
}
bool CloseRescuePos(ulong ticket,string reason){if(!PositionSelectByTicket(ticket))return false;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(m_trade.PositionClose(ticket)){m_totalPnL+=pf;m_tradesClosed++;Print("[V9.1-BTC] RESCUE #",ticket," $",NormalizeDouble(pf,2)," [",reason,"]");return true;}return false;}
void ResetBlockState(){m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;m_netHedge1Applied=false;m_netHedge2Applied=false;m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=0;m_stage3TriggerAtOpen=0;m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;m_lastCTBuyPrice=m_lastCTSellPrice=0;ZeroMemory(m_lbc);}
bool CloseBlockIfPositive(string reason){
   double dynTP=CalcDynamicBlockTP();if(m_port.totalProfit<dynTP)return false;
   Print("[V9.1-BTC] POSITIVE CLOSE: $",NormalizeDouble(m_port.totalProfit,2)," >= DynTP=$",NormalizeDouble(dynTP,2)," [",reason,"]");
   m_isProcessing=true;
   for(int pass=0;pass<2;pass++){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=Inp_Magic)continue;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(pass==0&&pf<0)continue;if(pass==1&&pf>=0)continue;ClosePos(t,reason);}}
   if(Inp_RescueAllTrades){for(int pass=0;pass<2;pass++){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)==Inp_Magic)continue;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(pass==0&&pf<0)continue;if(pass==1&&pf>=0)continue;CloseRescuePos(t,"RESCUE_"+reason);}}}
   m_isProcessing=false;ResetBlockState();m_cycleResetTime=TimeCurrent();m_cycleInPause=true;return true;
}

//=================================================================
// DETANGLE (V7.9)
//=================================================================
void RunDetangle(){
   if(m_isProcessing||m_port.totalPos<2)return;
   double nv=MathAbs(m_port.buyVolume-m_port.sellVolume);
   if(!(nv<Inp_DetangleNetThresh&&m_port.totalProfit<Inp_DetangleMinLoss)){if(nv>=Inp_DetangleNetThresh){m_detangleDetectTime=0;m_detangleActive=false;}return;}
   if(m_detangleDetectTime==0){m_detangleDetectTime=TimeCurrent();m_detangleActive=true;Print("[V9.1-BTC] DETANGLE sym cage P&L=",NormalizeDouble(m_port.totalProfit,2));return;}
   if((int)(TimeCurrent()-m_detangleDetectTime)<Inp_DetangleSec)return;
   if(!SpreadOK())return;
   if(m_port.worstTicket>0&&m_port.worstProfit<0){m_isProcessing=true;bool cl=ClosePos(m_port.worstTicket,"Detangle");m_isProcessing=false;if(cl){m_detangleDetectTime=TimeCurrent();m_detangleActive=false;UpdatePortfolio();}}
}

//=================================================================
// BLOCK STAGE ENGINE (V7.9.1 + V9 capital guard)
//=================================================================
void RunBlockStageEngine(){
   if(m_isProcessing||m_blockStage==0)return;
   int mCnt=m_port.totalPos-m_port.lbcCount;
   if(mCnt<=0&&m_port.totalPos==0){m_blockStage=0;m_stageFollowHedge=false;return;}if(mCnt<=0)return;
   double dynTP=CalcDynamicBlockTP();if(m_port.totalProfit>=dynTP){CloseBlockIfPositive("BSE_TP");return;}
   MqlTick tk;if(!GetTick(tk))return;double pnl=m_port.totalProfit;

   if(m_blockStage==1&&mCnt==1){
      double trig1=(m_stage1TriggerAtOpen!=0)?m_stage1TriggerAtOpen:m_dyn.stage1Trigger;
      int hold=(int)(TimeCurrent()-m_primaryOpenTime);bool emg=(pnl<=trig1*Inp_StageEmergMult);
      if(hold<Inp_PrimaryMinHoldSec&&!emg)return;
      if(pnl<=trig1){
         int tDir=m_mkt.trendConfirmed,pDir=(m_primaryType==ORDER_TYPE_BUY)?1:-1;
         if(Inp_UseDirectionalStage&&tDir==pDir&&tDir!=0){
            double rL=NormLot(g_AutoBaseLot*Inp_ReinforceLotMult);
            if(MarginOK(rL,m_primaryType)&&AntiSymmetricOK(m_primaryType,rL)){
               m_isProcessing=true;ulong t1=OpenOrder(m_primaryType,rL,"BSE_REINF1",true);m_isProcessing=false;
               if(t1>0){int idx=FreeRec();if(idx>=0)InitRec(idx,t1,(m_primaryType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(m_primaryType==ORDER_TYPE_BUY)?tk.ask:tk.bid,rL,"BSE_REINF1",false,false,true,false);m_blockStage=2;m_stage2Time=TimeCurrent();m_recoveryActive=true;m_stageFollowHedge=false;m_stage3TriggerAtOpen=m_dyn.stage3Trigger;Print("[V9.1-BTC] STAGE 2 REINFORCE");}
            }
         }else{
            ENUM_ORDER_TYPE hT=(m_primaryType==ORDER_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
            double hL=NormLot(MathMax(g_AutoBaseLot*Inp_HedgeRatio,g_AutoBaseLot));
            if(!AntiSymmetricOK(hT,hL)){double vs=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(vs<=0)vs=0.01;hL=NormLot(hL+vs);}
            if(MarginOK(hL,hT)){m_isProcessing=true;ulong t1=OpenOrder(hT,hL,"BSE_H1",true);m_isProcessing=false;
               if(t1>0){int idx=FreeRec();if(idx>=0)InitRec(idx,t1,(hT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(hT==ORDER_TYPE_BUY)?tk.ask:tk.bid,hL,"BSE_H1",false,false,true,false);m_blockStage=2;m_stage2Time=TimeCurrent();m_recoveryActive=true;m_stageFollowHedge=true;m_stage3TriggerAtOpen=m_dyn.stage3Trigger;Print("[V9.1-BTC] STAGE 2 HEDGE #",t1);}}}
      }return;
   }
   if(m_blockStage==2&&mCnt==2){
      if((int)(TimeCurrent()-m_stage2Time)<m_dyn.stage2Delay)return;if(!SpreadOK(true))return;
      int tDir=m_mkt.trendConfirmed;ENUM_ORDER_TYPE t3T;int t3D;
      if(tDir==1){t3T=ORDER_TYPE_BUY;t3D=1;}else if(tDir==-1){t3T=ORDER_TYPE_SELL;t3D=-1;}else{if(m_port.buyProfit<m_port.sellProfit){t3T=ORDER_TYPE_SELL;t3D=-1;}else{t3T=ORDER_TYPE_BUY;t3D=1;}}
      double t3L=CalcDirectionalLot(t3D);if(!AntiSymmetricOK(t3T,t3L)){double nv=m_port.buyVolume-m_port.sellVolume;double mn=(t3D==1)?g_AutoBaseLot*1.5-nv:nv+g_AutoBaseLot*1.5;t3L=NormLot(MathMax(t3L,MathAbs(mn)));}
      m_stageFollowHedge=(t3T!=m_primaryType);string lb=(t3D==1)?"BSE_DIR_L":"BSE_DIR_S";
      if(MarginOK(t3L,t3T)){m_isProcessing=true;ulong t2=OpenOrder(t3T,t3L,lb,true);m_isProcessing=false;
         if(t2>0){int idx=FreeRec();if(idx>=0)InitRec(idx,t2,(t3T==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(t3T==ORDER_TYPE_BUY)?tk.ask:tk.bid,t3L,lb,false,false,true,false);m_blockStage=3;Print("[V9.1-BTC] STAGE 3 #",t2," L=",NormalizeDouble(t3L,2));}
      }else{ActivateLBC();}return;
   }
   if(m_blockStage==3){
      double t3=(m_stage3TriggerAtOpen!=0)?m_stage3TriggerAtOpen:m_dyn.stage3Trigger;
      if(pnl<=t3){if(!SpreadOK(true))return;
         int tDir=m_mkt.trendConfirmed;ENUM_ORDER_TYPE t4T;int t4D;
         if(tDir==1){t4T=ORDER_TYPE_BUY;t4D=1;}else if(tDir==-1){t4T=ORDER_TYPE_SELL;t4D=-1;}else{if(m_port.buyProfit>m_port.sellProfit){t4T=ORDER_TYPE_BUY;t4D=1;}else{t4T=ORDER_TYPE_SELL;t4D=-1;}}
         double t4L=CalcDirectionalLot(t4D);if(!AntiSymmetricOK(t4T,t4L)){double nv=m_port.buyVolume-m_port.sellVolume;double mn=(t4D==1)?g_AutoBaseLot*2.0-nv:nv+g_AutoBaseLot*2.0;t4L=NormLot(MathMax(t4L,MathAbs(mn)));}
         if(MarginOK(t4L,t4T)){m_isProcessing=true;ulong t3t=OpenOrder(t4T,t4L,"BSE_CON4",true);m_isProcessing=false;
            if(t3t>0){int idx=FreeRec();if(idx>=0)InitRec(idx,t3t,(t4T==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(t4T==ORDER_TYPE_BUY)?tk.ask:tk.bid,t4L,"BSE_CON4",false,false,true,false);m_blockStage=4;Print("[V9.1-BTC] STAGE 4 #",t3t);}
         }else{ActivateLBC();}}return;
   }
   if(m_blockStage==4){if(!m_lbc.active&&pnl<m_dyn.stage3Trigger*1.5)ActivateLBC();}
}

//=================================================================
// RECOVERY ENGINE (V9: hard 2-order limit)
//=================================================================
void RunRecoveryEngine(){
   if(m_port.totalProfit>=m_dyn.recovTrigger){if(m_recoveryActive&&m_blockStage==0){m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;}return;}
   if(m_port.totalPos==0||m_isProcessing)return;
   double dynTP=CalcDynamicBlockTP();if(m_port.totalProfit>=dynTP){CloseBlockIfPositive("Recovery_TP");return;}
   if(!m_recoveryActive){m_recoveryActive=true;m_recoveryOrders=m_port.recoveryCount;m_recoveryTrendHedge=false;Print("[V9.1-BTC] RECOVERY | P&L=$",NormalizeDouble(m_port.totalProfit,2));}
   if(m_recoveryOrders>=Inp_RecoveryMaxOrders){if(!m_lbc.active){Print("[V9.1-BTC] RECOVERY LIMIT (max=",Inp_RecoveryMaxOrders,") -> LBC");ActivateLBC();}return;}
   if(TimeCurrent()-m_lastRecoveryTime<Inp_RecoveryIntervalSec||!SpreadOK(true))return;
   MqlTick tk;if(!GetTick(tk))return;double atr=GetATR_M1Norm();if(atr<=0)return;
   double minD=atr*m_dyn.recovDistATR;
   if(m_losingPosOpenPrice>0&&m_losingPosType>=0){double dist=(m_losingPosType==POSITION_TYPE_SELL)?tk.bid-m_losingPosOpenPrice:m_losingPosOpenPrice-tk.ask;if(dist<minD)return;}
   ENUM_ORDER_TYPE recT;double adxLvl=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;
   bool bearT=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.adx>adxLvl),bullT=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.adx>adxLvl);
   if(m_port.buyProfit<m_port.sellProfit&&bearT){recT=ORDER_TYPE_SELL;m_recoveryTrendHedge=true;}
   else if(m_port.sellProfit<m_port.buyProfit&&bullT){recT=ORDER_TYPE_BUY;m_recoveryTrendHedge=true;}
   else{m_recoveryTrendHedge=false;double cd=atr*0.3;if(m_port.buyProfit<m_port.sellProfit){recT=ORDER_TYPE_BUY;if(m_lastCTBuyPrice>0&&MathAbs(tk.ask-m_lastCTBuyPrice)<cd)return;}else{recT=ORDER_TYPE_SELL;if(m_lastCTSellPrice>0&&MathAbs(tk.bid-m_lastCTSellPrice)<cd)return;}}
   double recL=CalcRecoveryLot();
   if(!AntiSymmetricOK(recT,recL)){double nv=m_port.buyVolume-m_port.sellVolume;int td=(recT==ORDER_TYPE_BUY)?1:-1;double mn=(td==1)?g_AutoBaseLot-nv:nv+g_AutoBaseLot;recL=NormLot(MathMax(recL,MathAbs(mn)));}
   if(!MarginOK(recL,recT)){recL=NormLot(recL*0.5);if(!MarginOK(recL,recT)){recL=NormLot(g_AutoBaseLot);if(!MarginOK(recL,recT)){ActivateLBC();return;}}}
   string rc="REC_"+(recT==ORDER_TYPE_BUY?"B":"S")+"_"+IntegerToString(m_recoveryOrders+1);
   m_isProcessing=true;ulong ticket=OpenOrder(recT,recL,rc,true);m_isProcessing=false;
   if(ticket>0){int idx=FreeRec();if(idx>=0)InitRec(idx,ticket,(recT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(recT==ORDER_TYPE_BUY)?tk.ask:tk.bid,recL,rc,false,false,true,false);if(recT==ORDER_TYPE_BUY)m_lastCTBuyPrice=tk.ask;else m_lastCTSellPrice=tk.bid;m_recoveryOrders++;m_lastRecoveryTime=TimeCurrent();Print("[V9.1-BTC] Recovery #",m_recoveryOrders,"/",Inp_RecoveryMaxOrders," L=",recL);}
}

//=================================================================
// LBC ENGINE
//=================================================================
void ActivateLBC(){if(m_lbc.active)return;m_lbc.active=true;m_lbc.activatedTime=TimeCurrent();m_lbc.buyCount=m_lbc.sellCount=0;m_lbc.lastBuyPrice=m_lbc.lastSellPrice=0;m_lbc.harvestedTotal=0;m_lbc.harvestCount=0;double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE),mp=CalcMarginFor001();m_lbc.maxOrdersCalc=(int)MathMax(1,MathMin(Inp_LBCMaxPairs,(int)MathFloor((fm*Inp_LBCMarginPct)/(2.0*MathMax(mp,0.01)))));Print("[V9.1-BTC] LBC ACTIVATED MaxPairs=",m_lbc.maxOrdersCalc);}
void DeactivateLBC(){if(!m_lbc.active)return;Print("[V9.1-BTC] LBC DEACTIVATED Harvested=$",NormalizeDouble(m_lbc.harvestedTotal,2));ZeroMemory(m_lbc);}
void RunLBCEngine(){
   if(!m_lbc.active)return;if(m_port.totalPos==0){DeactivateLBC();return;}if(m_isProcessing)return;
   double dynTP=CalcDynamicBlockTP();if(m_port.totalProfit>=dynTP)return;if(m_port.totalProfit>=m_dyn.recovTrigger*0.5){DeactivateLBC();return;}
   MqlTick tk;if(!GetTick(tk))return;double atr=GetATR_M1Norm();if(atr<=0)return;
   int nonLBC=m_port.totalPos-m_port.lbcCount;bool hasMain=(nonLBC>0);
   if(!hasMain){double hMin=MathMax(DistToUSD(atr*Inp_LBCHarvestATR,g_AutoBaseLot),0.02);
      for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic||PositionGetString(POSITION_SYMBOL)!=_Symbol||StringFind(PositionGetString(POSITION_COMMENT),"LBC_")<0)continue;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(pf>=hMin){ClosePos(t,"LBC_Harvest");double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE),mp=CalcMarginFor001();m_lbc.maxOrdersCalc=(int)MathMax(1,MathMin(Inp_LBCMaxPairs,(int)MathFloor((fm*Inp_LBCMarginPct)/(2.0*MathMax(mp,0.01)))));}}}
   if(m_blockStage>0&&hasMain)return;
   if(TimeCurrent()-m_lbc.lastOrderTime<Inp_LBCIntervalSec||!SpreadOK())return;
   if(MathMin(m_lbc.buyCount,m_lbc.sellCount)>=m_lbc.maxOrdersCalc)return;
   double gs=atr*Inp_LBCGridATR*(m_inSession?1.2:1.0),lot=NormLot(g_AutoBaseLot);
   bool nB=false,nS=false;
   if(m_lbc.buyCount==0&&m_lbc.sellCount==0){nB=true;nS=true;}
   else{if(m_lbc.buyCount<=m_lbc.sellCount&&(m_lbc.lastBuyPrice<=0||MathAbs(tk.ask-m_lbc.lastBuyPrice)>=gs))nB=true;if(m_lbc.sellCount<=m_lbc.buyCount&&(m_lbc.lastSellPrice<=0||MathAbs(tk.bid-m_lbc.lastSellPrice)>=gs))nS=true;}
   if(nB&&MarginOK(lot,ORDER_TYPE_BUY)){string cB="LBC_B"+IntegerToString(m_lbc.buyCount+1);m_isProcessing=true;ulong tB=OpenOrder(ORDER_TYPE_BUY,lot,cB,true);m_isProcessing=false;if(tB>0){int idx=FreeRec();if(idx>=0)InitRec(idx,tB,POSITION_TYPE_BUY,tk.ask,lot,cB,false,false,false,true);m_lbc.buyCount++;m_lbc.lastBuyPrice=tk.ask;m_lbc.lastOrderTime=TimeCurrent();}}
   if(nS&&MarginOK(lot,ORDER_TYPE_SELL)){string cS="LBC_S"+IntegerToString(m_lbc.sellCount+1);m_isProcessing=true;ulong tS=OpenOrder(ORDER_TYPE_SELL,lot,cS,true);m_isProcessing=false;if(tS>0){int idx=FreeRec();if(idx>=0)InitRec(idx,tS,POSITION_TYPE_SELL,tk.bid,lot,cS,false,false,false,true);m_lbc.sellCount++;m_lbc.lastSellPrice=tk.bid;m_lbc.lastOrderTime=TimeCurrent();}}
}

void RunBasketTP(){if(!Inp_UseBasketTP||TimeCurrent()-m_lastBasketCheck<Inp_BasketCheckSec)return;m_lastBasketCheck=TimeCurrent();if(m_port.totalPos<2)return;double dynTP=CalcDynamicBlockTP();if(m_port.totalProfit<dynTP)return;double avgW=(m_cycleWinsCount>0)?m_cycleWinsSum/m_cycleWinsCount:0.60;if(m_port.totalProfit>=MathMax(dynTP,avgW*Inp_BasketTPRatio))CloseBlockIfPositive("BasketTP");}
void CheckCycleMaxLoss(){if(!Inp_UseCycleMaxLoss||m_port.totalPos==0)return;if(m_port.totalProfit<=Inp_CycleMaxLossUSD&&!m_recoveryActive&&m_blockStage==0){Print("[V9.1-BTC] CYCLE MAX LOSS $",NormalizeDouble(m_port.totalProfit,2));m_recoveryActive=true;m_recoveryOrders=0;}}
void RunHarvest(){if(m_port.totalPos>1||!Inp_HarvestContinuous||m_isProcessing)return;if(TimeCurrent()-m_lastHarvestTime<Inp_HarvestIntervalSec)return;m_lastHarvestTime=TimeCurrent();double dynTP=CalcDynamicBlockTP();if(m_port.totalProfit>=dynTP)CloseBlockIfPositive("Harvest");}
bool CheckEquityGuard(){if(!Inp_UseEquityGuard)return false;double eq=AccountInfoDouble(ACCOUNT_EQUITY);double dynThresh=MathMin(Inp_EmergencyLossUSD,-(eq*0.05));if(m_port.totalProfit<=dynThresh&&!m_emergencyMode){Print("[V9.1-BTC] EQUITY ALERT $",NormalizeDouble(m_port.totalProfit,2));m_emergencyMode=true;m_isPaused=true;return true;}if(m_port.currentDD>=Inp_MaxDrawdownPct)m_isPaused=true;else if(m_isPaused&&!m_emergencyMode&&!m_dailyLimitHit&&m_port.currentDD<Inp_MaxDrawdownPct*0.5)m_isPaused=false;return false;}

//=================================================================
// NET HEDGE (V7.6B)
//=================================================================
void RunNetExposureHedge(){
   if(!Inp_UseNetHedge||m_port.totalPos==0||m_isProcessing||g_CircuitBreakerHit)return;
   double nv=NormalizeDouble(m_port.buyVolume-m_port.sellVolume,2);if(MathAbs(nv)<0.005)return;
   double loss=m_port.totalProfit;if(loss>m_dyn.netHedgeTrig1)return;
   if(TimeCurrent()-m_lastNetHedgeTime<Inp_NetHedgeIntervalSec||!SpreadOK(true))return;
   ENUM_ORDER_TYPE hT=(nv>0)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   double vs=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(vs<=0)vs=0.01;
   if(loss<=m_dyn.netHedgeTrig2&&!m_netHedge2Applied){double pct=m_netHedge1Applied?0.50:0.0;double hL=NormLot(MathAbs(nv)*(1.0-pct));if(hL>0){if(!AntiSymmetricOK(hT,hL))hL=NormLot(hL+vs);if(MarginOK_Hedge(hL,hT)){m_isProcessing=true;ulong t=OpenOrder(hT,hL,"NET_HEDGE_L2",true);m_isProcessing=false;if(t>0){m_netHedge2Applied=m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();MqlTick tk;GetTick(tk);int idx=FreeRec();if(idx>=0)InitRec(idx,t,(hT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(hT==ORDER_TYPE_BUY)?tk.ask:tk.bid,hL,"NET_HEDGE_L2",false,false,true,false);Print("[V9.1-BTC] NET HEDGE L2 P&L=$",NormalizeDouble(loss,2));}}}return;}
   if(loss<=m_dyn.netHedgeTrig1&&!m_netHedge1Applied){double hL=NormLot(MathAbs(nv)*0.50);if(hL>0){if(!AntiSymmetricOK(hT,hL))hL=NormLot(hL+vs);if(MarginOK_Hedge(hL,hT)){m_isProcessing=true;ulong t=OpenOrder(hT,hL,"NET_HEDGE_L1",true);m_isProcessing=false;if(t>0){m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();MqlTick tk;GetTick(tk);int idx=FreeRec();if(idx>=0)InitRec(idx,t,(hT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(hT==ORDER_TYPE_BUY)?tk.ask:tk.bid,hL,"NET_HEDGE_L1",false,false,true,false);Print("[V9.1-BTC] NET HEDGE L1 P&L=$",NormalizeDouble(loss,2));}}}}
}

//=================================================================
// STORM FILTER
//=================================================================
double CalcAvgATR(int wb){if(wb<=0||h_ATR==INVALID_HANDLE)return 0;double buf[];ArraySetAsSeries(buf,true);if(CopyBuffer(h_ATR,0,1,wb,buf)<wb)return 0;double s=0;for(int i=0;i<wb;i++)s+=buf[i];return s/wb;}
void RunVolatilityStormFilter(){
   if(!Inp_UseStormFilter){m_stormActive=false;return;}
   double aN=GetATR_M1Norm();if(aN<=0)return;
   double aA=CalcAvgATR(Inp_StormATRWindow);if(g_TFMult>0)aA/=g_TFMult;bool aS=false;
   if(aA>0){m_stormLastATRRatio=aN/aA;aS=(m_stormLastATRRatio>=Inp_StormATRMult);}
   double sN=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);bool sS=false;
   if(m_adaptSpread.rollingMean>0){m_stormLastSprRatio=sN/m_adaptSpread.rollingMean;sS=(m_stormLastSprRatio>=Inp_StormSpreadMult);}else sS=(sN>(double)Inp_AdaptSpreadHardCap*0.8);
   bool now=(aS||sS);
   if(now&&!m_stormActive){m_stormActive=true;m_stormDetectedTime=TimeCurrent();Print("[V9.1-BTC] STORM ATRx=",NormalizeDouble(m_stormLastATRRatio,2)," SPRx=",NormalizeDouble(m_stormLastSprRatio,2));}
   if(m_stormActive){if(TimeCurrent()-m_stormDetectedTime>=Inp_StormCooldownSec){if(!now){m_stormActive=false;Print("[V9.1-BTC] STORM CLEARED");}else m_stormDetectedTime=TimeCurrent();}}
}

//=================================================================
// CT ENGINE + PRIMARY ENTRY
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType,double &ctLot,int &ctLevel){
   if(m_port.totalPos==0||m_port.totalPos>=Inp_MaxPositionsTotal)return false;
   if(m_port.totalProfit>=0&&m_port.negativeSum==0)return false;
   if(m_recoveryActive||m_lbc.active||m_mkt.atr<=0)return false;
   bool bL=(m_port.buyProfit<-0.05&&m_port.buyCount>0),sL=(m_port.sellProfit<-0.05&&m_port.sellCount>0);
   bool oB=false,oS=false;
   if(bL&&!sL){if(m_port.sellCount>=Inp_CTMaxSameDir)return false;oS=true;}
   else if(sL&&!bL){if(m_port.buyCount>=Inp_CTMaxSameDir)return false;oB=true;}
   else if(bL&&sL){if(m_mkt.htfTrend==1&&m_port.buyCount<Inp_CTMaxSameDir)oB=true;else if(m_mkt.htfTrend==-1&&m_port.sellCount<Inp_CTMaxSameDir)oS=true;else if(m_port.buyProfit<m_port.sellProfit&&m_port.sellCount<Inp_CTMaxSameDir)oS=true;else if(m_port.buyCount<Inp_CTMaxSameDir)oB=true;else return false;}else return false;
   ENUM_ORDER_TYPE tt=oB?ORDER_TYPE_BUY:ORDER_TYPE_SELL;if(!ADXAllowsEntry(tt))return false;
   double ctD=(Inp_CTMode==CT_ATR_DISTANCE)?GetATR_M1Norm()*Inp_CTDistanceATR:Inp_CTFixedPoints*_Point;
   MqlTick t;if(!GetTick(t))return false;
   if(ctD>0){if(oB&&m_lastCTBuyPrice>0&&MathAbs(t.ask-m_lastCTBuyPrice)<ctD)return false;if(oS&&m_lastCTSellPrice>0&&MathAbs(t.bid-m_lastCTSellPrice)<ctD)return false;}
   ctLevel=oB?m_port.buyCount:m_port.sellCount;ctLot=GetEffectiveBaseLot();ctType=tt;return true;
}
void RunCTEngine(){
   if(m_isProcessing||m_isPaused||m_emergencyMode||m_cycleInPause||g_CircuitBreakerHit)return;
   if(TimeCurrent()-m_lastCTTime<Inp_CTIntervalSec)return;m_lastCTTime=TimeCurrent();
   MqlTick ts;if(!GetTick(ts))return;if(!AdaptiveSpreadOK(false))return;
   if(m_port.totalPos==0){
      if(!m_sensors.allOK){static datetime lSL=0;if(TimeCurrent()-lSL>=60){Print("[V9.1-BTC] BLOCKED: ",m_sensors.blockReason);lSL=TimeCurrent();}return;}
      if(m_stormActive)return;
      if(m_btcLiq.blockEntry){static datetime lLB=0;if(TimeCurrent()-lLB>=120){Print("[V9.1-BTC] CHAOTIC LIQ SPR/ATR=",NormalizeDouble(m_btcLiq.spreadAtrRatio,3));lLB=TimeCurrent();}return;}
      int cd=m_inSession?Inp_PrimaryCooldownSec:Inp_PrimaryCooldownOff;if(TimeCurrent()-m_lastPrimaryTime<cd)return;
      ENUM_ORDER_TYPE iT;
      if(m_mkt.trendConfirmed==1)iT=ORDER_TYPE_BUY;else if(m_mkt.trendConfirmed==-1)iT=ORDER_TYPE_SELL;
      else if(m_mkt.isBullish)iT=ORDER_TYPE_BUY;else if(m_mkt.isBearish)iT=ORDER_TYPE_SELL;
      else if(m_mkt.emaFast>m_mkt.emaSlow)iT=ORDER_TYPE_BUY;else iT=ORDER_TYPE_SELL;
      if(m_lastPrimaryLost&&m_lastPrimaryDir!=0){ENUM_ORDER_TYPE alt=(m_lastPrimaryDir==1)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;if(iT!=alt){iT=alt;m_lastPrimaryLost=false;}}
      if(!ADXAllowsEntry(iT)||!TrendFilter200OK(iT))return;
      if(!m_inSession){bool cs=(m_mkt.isBullish&&iT==ORDER_TYPE_BUY)||(m_mkt.isBearish&&iT==ORDER_TYPE_SELL);if(!cs)return;}
      if(Inp_UseDirValidator){bool dOK=(iT==ORDER_TYPE_BUY)?m_dirScore.bullReady:m_dirScore.bearReady;
         if(!dOK){static datetime lDB=0;if(TimeCurrent()-lDB>=60){Print("[V9.1-BTC] DIR SCORE LOW: ",(iT==ORDER_TYPE_BUY?"BULL":"BEAR"),"=",NormalizeDouble((iT==ORDER_TYPE_BUY?m_dirScore.bull:m_dirScore.bear),3)," < ",Inp_DirMinScore);lDB=TimeCurrent();}return;}}
      double lot=GetEffectiveBaseLot();
      m_isProcessing=true;ulong ticket=OpenOrder(iT,lot,"Primary_Entry");
      if(ticket>0){int idx=FreeRec();if(idx>=0)InitRec(idx,ticket,(iT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(iT==ORDER_TYPE_BUY)?ts.ask:ts.bid,lot,"Primary_Entry",true,false,false,false);
         m_lastPrimaryDir=(iT==ORDER_TYPE_BUY)?1:-1;m_lastPrimaryTime=TimeCurrent();m_primaryOpenTime=TimeCurrent();
         if(iT==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask;else m_lastCTSellPrice=ts.bid;
         m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
         m_blockStage=1;m_primaryType=iT;m_stageFollowHedge=false;
         m_stage1TriggerAtOpen=m_dyn.stage1Trigger;m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
         m_detangleDetectTime=0;m_detangleActive=false;DeactivateLBC();
         Print("[V9.1-BTC] PRIMARY #",ticket," ",(iT==ORDER_TYPE_BUY?"BUY":"SELL")," L=",lot," DirScore=",NormalizeDouble((iT==ORDER_TYPE_BUY?m_dirScore.bull:m_dirScore.bear),3)," Liq=",BTCLiqName(m_btcLiq.mode)," TFMult=",NormalizeDouble(g_TFMult,2));}
      m_isProcessing=false;return;
   }
   if(m_blockStage>0)return;
   ENUM_ORDER_TYPE ctT;double ctL;int ctLv;
   if(!ShouldOpenCT(ctT,ctL,ctLv)||!MarginOK(ctL,ctT))return;
   string cc="CT_"+(ctT==ORDER_TYPE_BUY?"B":"S")+"_L"+IntegerToString(ctLv+1);
   m_isProcessing=true;ulong ticket=OpenOrder(ctT,ctL,cc);m_isProcessing=false;
   if(ticket>0){int idx=FreeRec();if(idx>=0)InitRec(idx,ticket,(ctT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(ctT==ORDER_TYPE_BUY)?ts.ask:ts.bid,ctL,cc,false,true,false,false);if(ctT==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask;else m_lastCTSellPrice=ts.bid;}
}

//=================================================================
// DASHBOARD V9.1-BTC
//=================================================================
void AQLbl(string n,string txt,int x,int y,color c,int fs=9,bool bold=false){if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_LABEL,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);}ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(0,n,OBJPROP_COLOR,c);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);ObjectSetString(0,n,OBJPROP_FONT,bold?"Consolas Bold":"Consolas");ObjectSetString(0,n,OBJPROP_TEXT,txt);}
void AQBtn(string n,string txt,int x,int y,int w,int h,color bg,color fg=clrWhite){if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_BUTTON,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);ObjectSetString(0,n,OBJPROP_FONT,"Consolas");}ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);ObjectSetString(0,n,OBJPROP_TEXT,txt);ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,n,OBJPROP_COLOR,fg);}
void AQPanel(string n,int x,int y,int w,int h){if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_BACK,false);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);}ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'8,8,12');ObjectSetInteger(0,n,OBJPROP_COLOR,C'70,70,70');ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);}
void DeleteDash(){for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--){string nm=ObjectName(0,i,0,-1);if(StringFind(nm,"AQ91_")==0)ObjectDelete(0,nm);}}
void UpdateDash(){
   if(!Inp_ShowDashboard||TimeCurrent()-m_lastDashTime<1)return;m_lastDashTime=TimeCurrent();
   color cG=C'0,220,80',cR=C'220,50,50',cO=C'220,150,30',cY=C'200,200,50',cC=C'50,190,220',cM=C'0,200,150',cP=C'160,80,220',cGr=C'120,120,130',cBd=C'70,70,70';
   int x=Inp_DashX,y=Inp_DashY,lh=15;
   AQPanel("AQ91_BG",x-8,y-8,680,60*lh+70);
   AQLbl("AQ91_H","[ "+VERSION_STR+" ] "+_Symbol+" M"+IntegerToString(PeriodSeconds(_Period)/60)+" | CAPITALGUARD + ADAPTIVE",x,y,cG,10,true);y+=lh+2;
   AQLbl("AQ91_SL0","─────────────────────────────────────────────────────────────────────",x,y,cBd,8);y+=lh-4;
   // Capital Guard block
   color cgC=g_CircuitBreakerHit?cR:(g_SoftBreakerHit?cO:cG);
   string cgS=g_CircuitBreakerHit?"[ !! HARD CIRCUIT BREAKER ACTIVE — NO TRADING !! ]":g_SoftBreakerHit?"[ SOFT BREAKER (DD>"+DoubleToString(Inp_SoftCircuitBreakerPct*100,0)+"%) — ENTRIES PAUSED ]":"[ CAPITAL GUARD: OK ]";
   AQLbl("AQ91_CGB",cgS,x,y,cgC,10,true);y+=lh+1;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct=(g_PeakEquity>0)?(g_PeakEquity-eq)/g_PeakEquity*100.0:0;
   double totalVol=m_port.buyVolume+m_port.sellVolume;
   double mU=AccountInfoDouble(ACCOUNT_MARGIN),mF=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double mPct=((mU+mF)>0)?mU/(mU+mF)*100.0:0;
   AQLbl("AQ91_CG1",StringFormat("DD:%.1f%% (hard@%.0f%% soft@%.0f%%) | PeakEq:$%.2f | CurEq:$%.2f | TFMult:%.2f",ddPct,Inp_HardCircuitBreakerPct*100,Inp_SoftCircuitBreakerPct*100,g_PeakEquity,eq,g_TFMult),x,y,(ddPct>Inp_HardCircuitBreakerPct*100)?cR:(ddPct>Inp_SoftCircuitBreakerPct*100)?cO:cC,9);y+=lh-1;
   AQLbl("AQ91_CG2",StringFormat("TotalVol:%.2f/%.2f(%.0f%%) | MarginUsed:%.0f%% | AutoLot:%.2f | HardCap:%.2f | MaxMargPct:%.0f%%",totalVol,Inp_MaxTotalVolume,(Inp_MaxTotalVolume>0)?totalVol/Inp_MaxTotalVolume*100:0,mPct,g_AutoBaseLot,Inp_LotHardCap,Inp_MaxMarginUsagePct*100),x,y,(totalVol/Inp_MaxTotalVolume>0.8)?cR:(totalVol/Inp_MaxTotalVolume>0.5)?cO:cG,9);y+=lh-1;
   double dynTP=CalcDynamicBlockTP();
   AQLbl("AQ91_CG3",StringFormat("DynTP:$%.3f (floor:$%.2f | loss*RRR:$%.3f) | TPRRR:%.2f | RecMax:%d",dynTP,Inp_BlockTPTarget,MathAbs(m_port.totalProfit)*Inp_TPRRR,Inp_TPRRR,Inp_RecoveryMaxOrders),x,y,cM,9);y+=lh;
   // V8 BTC Engines
   AQLbl("AQ91_SL1","── V8.0 BTC ADAPTIVE ENGINES ───────────────────────────────────────",x,y,C'20,50,80',8);y+=lh-3;
   int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   color spC=m_adaptSpread.isSpikeNow?cR:(cs>m_adaptSpread.rollingMean*1.3?cO:cG);
   AQLbl("AQ91_SPR",StringFormat("SPREAD: cur=%d | mu=%.0f sig=%.0f | thr=%.0f(cap=%d) | ratio=%.2fx | recovThr=%.0f",cs,m_adaptSpread.rollingMean,m_adaptSpread.rollingStd,m_adaptSpread.adaptiveThreshold,Inp_AdaptSpreadHardCap,m_adaptSpread.spikeRatio,m_adaptSpread.recovThreshold),x,y,spC,9);y+=lh-1;
   color lC=(m_btcLiq.mode==BTC_LIQ_CHAOTIC)?cR:(m_btcLiq.mode==BTC_LIQ_ACTIVE)?cG:(m_btcLiq.mode==BTC_LIQ_DEAD)?cGr:cC;
   AQLbl("AQ91_LIQ",StringFormat("LIQUIDITY:%s | LotF=%.2fx | SPR/ATR=%.3f | ATRvel=%.2f | Entry:%s",BTCLiqName(m_btcLiq.mode),m_btcLiq.lotFactor,m_btcLiq.spreadAtrRatio,m_btcLiq.atrVelocity,m_btcLiq.blockEntry?"BLOCKED":"OK"),x,y,lC,9);y+=lh-1;
   color dC=(m_dirScore.bullReady||m_dirScore.bearReady)?cG:cGr;
   AQLbl("AQ91_DIR",StringFormat("DIR: BULL=%.2f%s BEAR=%.2f%s | Top=%s | Thr=%.2f | VolF=%.2fx",m_dirScore.bull,m_dirScore.bullReady?"[RDY]":"",m_dirScore.bear,m_dirScore.bearReady?"[RDY]":"",m_dirScore.topFactor,Inp_DirMinScore,GetVolLotFactor()),x,y,dC,9);y+=lh;
   // Sensors + Dynamic
   AQLbl("AQ91_SL2","── SENSORS + V7.8 DYNAMIC ──────────────────────────────────────────",x,y,C'30,60,50',8);y+=lh-3;
   AQLbl("AQ91_SEN",StringFormat("TIME:%s SPR:%s%d<%.0f 200EMA:%s VOL:%s(%.2fx) MARG:%s All:%s",m_sensors.timeOK?"OK":"W",m_sensors.spreadOK?"OK(":"SPIKE(",cs,m_adaptSpread.adaptiveThreshold,m_sensors.trendBull?"BULL":"BEAR",m_sensors.volatOK?"OK":"HIGH",m_sensors.atrRatio,m_sensors.marginOK?"OK":"W",m_sensors.allOK?"YES":("NO:"+m_sensors.blockReason)),x,y,m_sensors.allOK?cG:cO,9);y+=lh-1;
   color sessC=(m_dyn.session==SESSION_OVERLAP)?cO:(m_dyn.session==SESSION_NY)?cY:(m_dyn.session==SESSION_LONDON)?cG:cGr;
   AQLbl("AQ91_DYN",StringFormat("SESS:%s F=%.2f VR:%s | S1=%.2f S3=%.2f DynTP=+%.3f RecTrig=%.2f | ATR_M1norm=%.2f TFMult=%.2f",SessionName(m_dyn.session),m_dyn.sessionFactor,VolRegimeName(m_dyn.volRegime),m_dyn.stage1Trigger,m_dyn.stage3Trigger,dynTP,m_dyn.recovTrigger,GetATR_M1Norm(),g_TFMult),x,y,sessC,9);y+=lh;
   // Block state
   AQLbl("AQ91_SL3","── ACTIVE BLOCK ─────────────────────────────────────────────────────",x,y,C'50,50,80',8);y+=lh-3;
   double pnl=m_port.totalProfit;
   string stgNm[]={"IDLE","PRIMARY","HEDGE/REINF","3RD-DIR","CON-MAX"};int si=MathMax(0,MathMin(m_blockStage,4));
   color stgC=(m_blockStage==0)?cGr:(m_blockStage==1)?cC:(m_blockStage==2)?cO:(m_blockStage==3)?cY:cR;
   AQLbl("AQ91_PNL",StringFormat("PnL:%s%.2f DynTP:+%.3f Stage:%d(%s) Pos:%d(LBC:%d) BUY:%.2f($%.2f) SELL:%.2f($%.2f)",pnl>=0?"+":"",pnl,dynTP,si,stgNm[si],m_port.totalPos,m_port.lbcCount,m_port.buyVolume,m_port.buyProfit,m_port.sellVolume,m_port.sellProfit),x,y,pnl>=0?cG:cR,9);y+=lh-1;
   AQLbl("AQ91_STG",StringFormat("NetVol:%.3f VWAP:%.1f | Detangle:%s | Hold:%ds | TEMA+KAL:%s",m_port.buyVolume-m_port.sellVolume,m_port.blockVWAP,m_detangleActive?"ACTIVE":"ok",(m_primaryOpenTime>0)?(int)(TimeCurrent()-m_primaryOpenTime):0,(m_mkt.trendConfirmed==1?"BULL":(m_mkt.trendConfirmed==-1?"BEAR":"NEUT"))),x,y,stgC,9);y+=lh-1;
   string nhS;color nhC;if(m_netHedge2Applied){nhS="NET HEDGE L2 ACTIVE";nhC=cR;}else if(m_netHedge1Applied){nhS="NET HEDGE L1 | L2@$"+DoubleToString(m_dyn.netHedgeTrig2,2);nhC=cO;}else{nhS="NH: wait L1@$"+DoubleToString(m_dyn.netHedgeTrig1,2)+" L2@$"+DoubleToString(m_dyn.netHedgeTrig2,2);nhC=cGr;}
   AQLbl("AQ91_NH",nhS,x,y,nhC,9);y+=lh-1;
   string recStr=m_recoveryActive?StringFormat("RECOVERY:%d/%d(HARD-LIMIT) | RecDist=%.2fxATR_M1",m_recoveryOrders,Inp_RecoveryMaxOrders,m_dyn.recovDistATR):"Recovery:standby";
   string lbcStr=m_lbc.active?StringFormat(" LBC:B=%d S=%d Harv=$%.2f",m_lbc.buyCount,m_lbc.sellCount,m_lbc.harvestedTotal):" LBC:standby";
   AQLbl("AQ91_REC",recStr+lbcStr,x,y,m_recoveryActive?cY:cGr,9);y+=lh-1;
   string sfStr=m_stormActive?StringFormat("STORM:ACTIVE ATRx=%.2f SPRx=%.2f",m_stormLastATRRatio,m_stormLastSprRatio):"STORM:ok ATRx="+DoubleToString(m_stormLastATRRatio,2);
   AQLbl("AQ91_SF",sfStr,x,y,m_stormActive?cR:cGr,9);y+=lh;
   // History
   AQLbl("AQ91_SL4","── HISTORY ──────────────────────────────────────────────────────────",x,y,C'50,50,80',8);y+=lh-3;
   int tot=m_totalWins+m_totalLosses;double wr=(tot>0)?(double)m_totalWins/tot*100.0:0;
   AQLbl("AQ91_HST",StringFormat("Win:%.1f%%(%d/%d) | Exp:$%.3f | TotPnL:$%.2f | Best:$%.2f Worst:$%.2f | Ticks:%d",wr,m_totalWins,tot,CalcExpectancy(),m_totalPnL,m_bestClosed,m_worstClosed,(int)m_tickCount),x,y,CalcExpectancy()>=0?cG:cO,9);y+=lh+4;
   AQBtn("AQ91_B1",m_isPaused?">> RESUME <<":"|| PAUSE ENTRIES",x,y,180,22,m_isPaused?C'180,130,0':C'0,90,40');
   AQBtn("AQ91_B2","CLOSE ALL (MANUAL)",x+190,y,180,22,C'150,20,20');
   ChartRedraw(0);
}

ENUM_ORDER_TYPE_FILLING DetectFillingMode(){if((bool)MQLInfoInteger(MQL_TESTER))return ORDER_FILLING_RETURN;long fm=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);if((fm&SYMBOL_FILLING_FOK)!=0)return ORDER_FILLING_FOK;if((fm&SYMBOL_FILLING_IOC)!=0)return ORDER_FILLING_IOC;return ORDER_FILLING_RETURN;}

//=================================================================
// OnInit
//=================================================================
int OnInit(){
   g_TFMult=(Inp_TFMultOverride>0)?Inp_TFMultOverride:CalcTFMult();
   g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);g_CircuitBreakerHit=false;g_SoftBreakerHit=false;
   Print("==============================================================");
   Print("  "+VERSION_STR+" | BTCUSD M",PeriodSeconds(_Period)/60," TFMult=",NormalizeDouble(g_TFMult,2));
   Print("  [V9-F1] ATR normalized to M1 by TFMult");
   Print("  [V9-F2] MaxTotalVolume=",Inp_MaxTotalVolume," LotHardCap=",Inp_LotHardCap);
   Print("  [V9-F3] HardCB=",NormalizeDouble(Inp_HardCircuitBreakerPct*100,0),"% SoftCB=",NormalizeDouble(Inp_SoftCircuitBreakerPct*100,0),"%");
   Print("  [V9-F4] DynBlockTP: floor=",Inp_BlockTPTarget," RRR=",Inp_TPRRR);
   Print("  [V9-F5] AutoLot: Bal*",Inp_AutoLotPct," HardCap=",Inp_LotHardCap);
   Print("  [V9-F6] RecoveryMaxOrders=",Inp_RecoveryMaxOrders," (hard limit)");
   Print("  [V8-SPR] Adaptive spread: mu+",Inp_AdaptSpreadK,"sig | cap=",Inp_AdaptSpreadHardCap,"pts");
   Print("  [V8-LIQ] BTC Liquidity: CHAOTIC/ACTIVE/DEAD/NORMAL");
   Print("  [V8-DIR] Dir score filter: minScore=",Inp_DirMinScore);
   Print("  [V8-VOL] Vol lot: HIGH=",Inp_VolHighLotFactor,"x LOW=",Inp_VolLowLotFactor,"x");
   Print("==============================================================");
   m_trade.SetExpertMagicNumber(Inp_Magic);m_trade.SetDeviationInPoints(25);m_trade.SetAsyncMode(false);m_trade.SetTypeFilling(DetectFillingMode());
   // All indicators fixed to M1 (V9-F1 compliance)
   h_ATR=iATR(_Symbol,PERIOD_M1,Inp_ATRPeriod);
   h_EMAFast=iMA(_Symbol,PERIOD_M1,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_EMASlow=iMA(_Symbol,PERIOD_M1,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_RSI=iRSI(_Symbol,PERIOD_M1,Inp_RSIPeriod,PRICE_CLOSE);
   h_MACD=iMACD(_Symbol,PERIOD_M1,Inp_MACDFast,Inp_MACDSlow,Inp_MACDSig,PRICE_CLOSE);
   if(h_ATR==INVALID_HANDLE||h_EMAFast==INVALID_HANDLE||h_EMASlow==INVALID_HANDLE||h_RSI==INVALID_HANDLE||h_MACD==INVALID_HANDLE){Print("[V9.1-BTC] ERROR: Base M1 indicators failed");return INIT_FAILED;}
   h_ADX=iADX(_Symbol,PERIOD_M1,Inp_ADXPeriod);
   h_HTFEMAFast=iMA(_Symbol,Inp_HTFTF,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_HTFEMASlow=iMA(_Symbol,Inp_HTFTF,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_EMA200=iMA(_Symbol,PERIOD_M1,Inp_EMA200Period,0,MODE_EMA,PRICE_CLOSE);
   h_ATRSlow=iATR(_Symbol,PERIOD_M1,Inp_ATRSlowPeriod);
   for(int i=0;i<MAX_RECORDS;i++)ZeroMemory(m_rec[i]);
   ZeroMemory(m_lbc);ZeroMemory(m_sensors);ZeroMemory(m_mkt);ZeroMemory(m_dyn);
   ZeroMemory(m_adaptSpread);
   m_adaptSpread.rollingMean=1545.0;m_adaptSpread.rollingStd=210.0;
   m_adaptSpread.adaptiveThreshold=MathMax((double)Inp_AdaptSpreadFloor,1545.0+Inp_AdaptSpreadK*210.0);
   m_adaptSpread.recovThreshold=m_adaptSpread.adaptiveThreshold*Inp_AdaptSpreadRecovF;
   ZeroMemory(m_btcLiq);m_btcLiq.mode=BTC_LIQ_NORMAL;m_btcLiq.lotFactor=1.0;
   ZeroMemory(m_dirScore);
   m_temaF_init=m_temaS_init=m_kalF_init=m_kalS_init=false;
   m_blockStage=0;m_stageFollowHedge=false;m_primaryOpenTime=0;m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
   m_detangleDetectTime=0;m_detangleActive=false;
   m_dyn.stage1Trigger=Inp_Stage1Trigger;m_dyn.stage3Trigger=Inp_Stage3Trigger;m_dyn.blockTP=Inp_BlockTPTarget;
   m_dyn.recovTrigger=Inp_RecoveryTriggerUSD;m_dyn.stage2Delay=Inp_Stage2DelayLondon;m_dyn.recovDistATR=Inp_RecovDistNormal;
   m_dyn.netHedgeTrig1=Inp_NetHedgeTrigger1USD;m_dyn.netHedgeTrig2=Inp_NetHedgeTrigger2USD;m_dyn.sessionFactor=1.0;m_dyn.atr2usd=0;
   m_initialBalance=AccountInfoDouble(ACCOUNT_BALANCE);m_bestEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance=m_initialBalance;m_lastDailyReset=TimeCurrent();
   CalibrateMarginPerLot();RecalcAutoBaseLot();CalcBrokerTimeWindow();SyncPositions();UpdatePortfolio();
   if(m_port.totalPos>0)Print("[V9.1-BTC] ",m_port.totalPos," existing positions. TotalVol=",NormalizeDouble(m_port.buyVolume+m_port.sellVolume,3));
   if(m_port.lbcCount>0){m_lbc.active=true;m_lbc.activatedTime=TimeCurrent();m_lbc.maxOrdersCalc=Inp_LBCMaxPairs;}
   if(Inp_ShowDashboard){DeleteDash();UpdateDash();}
   Print("[V9.1-BTC] READY | Bal=$",m_initialBalance," | AutoLot=",g_AutoBaseLot," | SpreadThresh=",NormalizeDouble(m_adaptSpread.adaptiveThreshold,0),"pts | TFMult=",NormalizeDouble(g_TFMult,2));
   return INIT_SUCCEEDED;
}

//=================================================================
// OnDeinit
//=================================================================
void OnDeinit(const int reason){
   Print("[V9.1-BTC] STOPPED | PnL=$",NormalizeDouble(m_totalPnL,2)," | Trades=",m_tradesClosed," | CB_Hard=",g_CircuitBreakerHit);
   IndicatorRelease(h_ATR);IndicatorRelease(h_EMAFast);IndicatorRelease(h_EMASlow);IndicatorRelease(h_RSI);IndicatorRelease(h_MACD);
   if(h_ADX!=INVALID_HANDLE)IndicatorRelease(h_ADX);if(h_HTFEMAFast!=INVALID_HANDLE)IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow!=INVALID_HANDLE)IndicatorRelease(h_HTFEMASlow);if(h_EMA200!=INVALID_HANDLE)IndicatorRelease(h_EMA200);
   if(h_ATRSlow!=INVALID_HANDLE)IndicatorRelease(h_ATRSlow);if(Inp_ShowDashboard)DeleteDash();
}

//=================================================================
// OnTick
//=================================================================
void OnTick(){
   m_tickCount++;
   // [V9-F3] HARD CIRCUIT BREAKER: ALWAYS FIRST, NO EXCEPTIONS
   if(HardEquityCircuitBreaker()){UpdatePortfolio();if(Inp_ShowDashboard)UpdateDash();return;}
   UpdateMarket();UpdateKalman();UpdatePortfolio();
   RunNetExposureHedge();CheckEquityGuard();
   m_inSession=IsInMainSession();ResetDailyIfNeeded();bool dP=DailyLimitReached();
   UpdateSensors();RunVolatilityStormFilter();
   if(m_cycleInPause){
      if(TimeCurrent()-m_cycleResetTime>=Inp_CyclePauseSec){m_cycleInPause=false;m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=0;m_stage3TriggerAtOpen=0;m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;DeactivateLBC();Print("[V9.1-BTC] CYCLE PAUSE ENDED");}
      else{UpdatePortfolio();double dTP=CalcDynamicBlockTP();if(m_port.totalPos>0&&m_port.totalProfit>=dTP)CloseBlockIfPositive("CyclePause_TP");if(Inp_ShowDashboard)UpdateDash();return;}
   }
   if(m_emergencyMode){
      static datetime eT=0;UpdatePortfolio();double dTP=CalcDynamicBlockTP();
      if(m_port.totalPos>0&&m_port.totalProfit>=dTP){CloseBlockIfPositive("Emg_TP");m_emergencyMode=false;eT=0;}
      if(m_port.totalPos==0&&eT==0)eT=TimeCurrent();if(eT>0&&TimeCurrent()-eT>=Inp_EmergencyCooldown){m_emergencyMode=false;eT=0;}
      if(m_blockStage>0)RunBlockStageEngine();else RunRecoveryEngine();RunLBCEngine();if(Inp_ShowDashboard)UpdateDash();return;
   }
   if(TimeCurrent()-m_lastCleanupTime>5){CleanupRecs();SyncPositions();m_lastCleanupTime=TimeCurrent();}
   ManagePositions();
   double dynTP=CalcDynamicBlockTP();
   if(m_port.totalPos>0&&m_port.totalProfit>=dynTP){CloseBlockIfPositive("BlockTP");if(Inp_ShowDashboard)UpdateDash();return;}
   RunDetangle();
   if(m_blockStage>0)RunBlockStageEngine();else RunRecoveryEngine();
   RunLBCEngine();RunBasketTP();CheckCycleMaxLoss();RunHarvest();
   if(!m_isPaused&&!m_recoveryActive&&!m_lbc.active&&!dP&&!g_CircuitBreakerHit)RunCTEngine();
   if(Inp_ShowDashboard)UpdateDash();
}

//=================================================================
// OnChartEvent
//=================================================================
void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp){
   if(id==CHARTEVENT_OBJECT_CLICK){
      if(sp=="AQ91_B1"){m_isPaused=!m_isPaused;
         if(!m_isPaused){m_emergencyMode=false;m_dailyLimitHit=false;g_CircuitBreakerHit=false;g_SoftBreakerHit=false;g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;m_netHedge1Applied=m_netHedge2Applied=false;m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=0;m_stage3TriggerAtOpen=0;m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;DeactivateLBC();Print("[V9.1-BTC] RESUMED | PeakEq reset $",NormalizeDouble(g_PeakEquity,2));}else Print("[V9.1-BTC] PAUSED");}
      if(sp=="AQ91_B2"){Print("[V9.1-BTC] MANUAL CLOSE ALL...");int closed=0;m_isProcessing=true;
         for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=Inp_Magic)continue;if(ClosePos(t,"Manual"))closed++;}
         if(Inp_RescueAllTrades){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)==Inp_Magic)continue;if(CloseRescuePos(t,"Manual"))closed++;}}
         m_isProcessing=false;m_lastCTBuyPrice=m_lastCTSellPrice=0;m_consecutiveLosses=0;m_lotMultiplier=1.0;m_cycleInPause=false;m_recoveryActive=false;m_recoveryOrders=0;m_lastPrimaryDir=0;m_lastPrimaryLost=false;m_netHedge1Applied=m_netHedge2Applied=false;m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=0;m_stage3TriggerAtOpen=0;m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;DeactivateLBC();
         Print("[V9.1-BTC] MANUAL CLOSE: ",closed," positions | Full reset");}
      ChartRedraw(0);}
}
//+------------------------------------------------------------------+