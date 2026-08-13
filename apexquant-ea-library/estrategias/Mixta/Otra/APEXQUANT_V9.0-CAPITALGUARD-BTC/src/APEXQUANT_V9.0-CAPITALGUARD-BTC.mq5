//+------------------------------------------------------------------+
//|   APEXQUANT - V9.0-CAPITALGUARD-BTC                              |
//|   "DIRECTIONAL RECOVERY — ANTI-SYMMETRIC ENGINE"                 |
//|   ASSET: BTCUSD (Crypto 24/7)                                    |
//|                                                                  |
//|   V9.0 FIXES heredados y adaptados a BTCUSD:                    |
//|   [F-1] g_TFMult: M1=1.0 M5=2.24 M15=3.87 M30=5.48 H1=7.75   |
//|   [F-2] CalcMaxSafeLot(): techo duro basado en margen libre.    |
//|   [F-3] HardEquityCircuitBreaker(): cierra si DD > X%.          |
//|   [F-4] BlockTP dinámico: MathMax(floor,|blockLoss|*RRRatio)    |
//|   [F-5] AutoLot: Balance * Inp_AutoLotPct                       |
//|   [F-6] RecoveryMaxOrders: 2 (HARD LIMIT)                       |
//|   [F-7] Todas las funciones pasan por CalcMaxSafeLot()          |
//|                                                                  |
//|   ENTRADA PRIMARIA: Dynamic Manager (par/impar último dígito Ask)|
//|   TP individual rápido → BE → Trailing Stop como muro           |
//|   Si llega al Stage1Trigger → Recovery BSE sin TP individual    |
//|   Cierre siempre en bloque positivo cuando hay recovery          |
//|                                                                  |
//|   BTC-QUANTCAL calibraciones (crypto 24/7):                     |
//|   Spread BTC: mu≈1545pts std≈210pts P80≈1700 hardcap=3500       |
//|   ATR(14) M1: P50≈45 P80≈95 P95≈180 (_Point=0.01)             |
//|   VolRegime: LOW<0.65 HIGH>1.50                                 |
//|   Storm: ATRmult=2.0 | SprMult=2.0                             |
//|   SprP80: ASI=2000 LON=1800 OVL=1700 NY=1700 OFF=2500          |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V9.0-CAPITALGUARD-BTC | BTCUSD"
#property version   "9.00"
#property strict
#property description "BTCUSD | V9.0-CAPITALGUARD | DM Entry | Directional Recovery"

#define VERSION_STR "APEXQUANT_V9.0-CAPITALGUARD-BTC"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS 80

enum ENUM_CT_MODE       { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };
enum ENUM_SESSION_STATE { SESSION_ASIAN=0, SESSION_LONDON=1, SESSION_OVERLAP=2, SESSION_NY=3, SESSION_OFF=4 };
enum ENUM_VOL_REGIME    { VOL_LOW=0, VOL_NORMAL=1, VOL_HIGH=2 };

//=================================================================
// PARAMETROS DE ENTRADA
//=================================================================
input group "=== [V9.0] CAPITAL GUARD ==="
input double Inp_MaxMarginUsagePct    = 0.35;
input double Inp_HardCircuitBreakerPct= 0.20;
input double Inp_SoftCircuitBreakerPct= 0.12;
input double Inp_AutoLotPct           = 0.001;
input bool   Inp_UseAutoLot           = true;
input double Inp_LotHardCap           = 0.05;
input double Inp_MaxTotalVolume       = 0.15;
input double Inp_TPRRR                = 0.12;

input group "=== [V9.0] TIMEFRAME ADAPTATION ==="
input double Inp_TFMultOverride       = 0.0;
input bool   Inp_AutoTFScale          = true;

input group "=== [V7.9] BREATHING ROOM ==="
input int    Inp_PrimaryMinHoldSec    = 120;
input double Inp_StageEmergMult       = 2.0;

input group "=== [V7.9] ASYMMETRIC HEDGE ==="
input double Inp_HedgeRatio           = 0.50;
input bool   Inp_UseDirectionalStage  = true;
input double Inp_ReinforceLotMult     = 1.50;

input group "=== [V7.9] DETANGLE ENGINE ==="
input int    Inp_DetangleSec          = 180;
input double Inp_DetangleNetThresh    = 0.005;
input double Inp_DetangleMinLoss      = -3.00;

input group "=== [V8.0] DYNAMIC THRESHOLD ENGINE (BTC) ==="
input double Inp_DynStage1Mult        = 1.20;
input double Inp_DynStage3Mult        = 2.50;
input double Inp_DynTPMult            = 0.80;
input double Inp_DynRecovMult         = 0.60;
input double Inp_DynMaxStage1USD      = 10.00;
input double Inp_DynMaxStage3USD      = 20.00;
input double Inp_DynMaxTPUSD          = 5.00;

input group "=== [V8.0] SESSION FACTORS (BTC) ==="
input double Inp_SessFactorAsian      = 0.65;
input double Inp_SessFactorLondon     = 1.00;
input double Inp_SessFactorOverlap    = 1.25;
input double Inp_SessFactorNY         = 1.10;
input double Inp_SessFactorOff        = 0.55;

input group "=== [V8.0] STAGE2 DELAY (BTC) ==="
input int    Inp_Stage2DelayAsian     = 20;
input int    Inp_Stage2DelayLondon    = 6;
input int    Inp_Stage2DelayOverlap   = 3;
input int    Inp_Stage2DelayNY        = 5;

input group "=== [V8.0] RECOVERY DISTANCE (BTC) ==="
input double Inp_RecovDistLow         = 0.30;
input double Inp_RecovDistNormal      = 0.50;
input double Inp_RecovDistHigh        = 0.85;

input group "=== [V7.7] TEMA + KALMAN ==="
input bool   Inp_UseTEMAKalman        = true;
input int    Inp_TEMAFastPeriod       = 21;
input int    Inp_TEMASlowPeriod       = 55;
input double Inp_KalmanQ              = 0.0001;
input double Inp_KalmanR              = 0.005;

input group "=== BLOCK STAGE ENGINE (BTC) ==="
input double Inp_Stage1Trigger        = -1.50;
input double Inp_Stage3Trigger        = -3.00;
input int    Inp_Stage2DelaySec       = 5;

input group "=== [V8.0] STORM FILTER (BTC) ==="
input bool   Inp_UseStormFilter       = true;
input int    Inp_StormATRWindow       = 16;
input double Inp_StormATRMult         = 2.00;
input double Inp_StormSpreadMult      = 2.00;
input int    Inp_StormSpreadWindow    = 16;
input int    Inp_StormCooldownSec     = 30;

input group "=== [V7.6B] NET EXPOSURE HEDGE ==="
input bool   Inp_UseNetHedge          = true;
input double Inp_NetHedgeTrigger1USD  = -5.0;
input double Inp_NetHedgeMult1        = 2.0;
input double Inp_NetHedgeTrigger2USD  = -8.0;
input double Inp_NetHedgeMult2        = 3.5;
input int    Inp_NetHedgeIntervalSec  = 5;

input group "=== CONFIGURACION PRINCIPAL ==="
input long   Inp_Magic                = 9090;
input int    Inp_MaxPositionsTotal    = 6;
input double Inp_LotBase              = 0.01;
input double Inp_LotMaximum           = 0.05;
input double Inp_RiskPerTradePct      = 0.005;
input bool   Inp_UseDynamicLot        = true;
input double Inp_CTMinBalanceUSD      = 5.0;
input double Inp_MinFreeMarginPct     = 0.05;

input group "=== CIERRE BLOQUE (BTC) ==="
input double Inp_BlockTPTarget        = 2.00;
input double Inp_TP_ATR               = 2.5;
input double Inp_SL_ATR               = 1.2;
input double Inp_OffSessionTP_ATR     = 2.2;
input double Inp_OffSessionSL_ATR     = 1.0;

input group "=== RECOVERY ENGINE ==="
input double Inp_RecoveryTriggerUSD   = -1.00;
input double Inp_RecoveryMinDistATR   = 0.50;
input double Inp_RecoveryMoveATR      = 0.50;
input double Inp_RecoveryMinLotMult   = 1.50;
input int    Inp_RecoveryMaxOrders    = 2;
input int    Inp_RecoveryMaxOrdersTrend= 2;
input int    Inp_RecoveryIntervalSec  = 3;

input group "=== LBC ENGINE ==="
input int    Inp_LBCMaxPairs          = 3;
input double Inp_LBCGridATR           = 0.30;
input double Inp_LBCHarvestATR        = 0.15;
input int    Inp_LBCIntervalSec       = 8;
input double Inp_LBCMarginPct         = 0.40;

input group "=== COUNTER-TRADE ENGINE ==="
input ENUM_CT_MODE Inp_CTMode         = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR        = 1.2;
input int    Inp_CTFixedPoints        = 1000;
input int    Inp_CTIntervalSec        = 10;
input int    Inp_CTMaxSameDir         = 2;
input int    Inp_PrimaryCooldownSec   = 10;
input int    Inp_PrimaryCooldownOff   = 20;
input double Inp_CTMaxSpreadPoints    = 3500.0;
input double Inp_CTMaxSpreadOff       = 2500.0;

input group "=== SESIONES ==="
input int    Inp_GMTOffset            = 0;
input int    Inp_LondonOpen           = 7;
input int    Inp_LondonClose          = 17;
input int    Inp_NYOpen               = 13;
input int    Inp_NYClose              = 22;
input double Inp_OffSessionLotFactor  = 0.80;

input group "=== BASKET TP ==="
input bool   Inp_UseBasketTP          = true;
input double Inp_BasketTPFactor       = 0.60;
input double Inp_BasketTPRatio        = 1.5;
input int    Inp_BasketCheckSec       = 3;

input group "=== HARVEST ==="
input double Inp_HarvestMinUSD        = 2.00;
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
input double Inp_DailyLossUSD         = -40.0;
input double Inp_DailyLossPct         = 8.0;
input int    Inp_LossStreakMax         = 2;
input double Inp_LossStreakReduce      = 0.70;

input group "=== EQUITY GUARD ==="
input bool   Inp_UseEquityGuard       = true;
input double Inp_EmergencyLossUSD     = -15.0;
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

input group "=== VISUAL ==="
input int    Inp_MaxSpread            = 3500;
input bool   Inp_ShowDashboard        = true;
input int    Inp_DashX                = 12;
input int    Inp_DashY                = 28;

input group "=== RESCATE UNIVERSAL ==="
input bool   Inp_RescueAllTrades      = false;

input group "=== SENSOR HORARIO GMT ==="
input bool   Inp_UseTimeFilter        = false;
input int    Inp_UserGMT              = -5;
input int    Inp_BrokerGMT            = 2;
input string Inp_StartTime            = "00:00";
input string Inp_EndTime              = "23:59";

input group "=== SENSOR TENDENCIA ==="
input bool   Inp_UseTrendFilter200    = true;
input int    Inp_EMA200Period         = 200;

input group "=== SENSOR VOLATILIDAD (BTC) ==="
input bool   Inp_UseVolatFilter       = true;
input int    Inp_ATRSlowPeriod        = 100;
input double Inp_ATRRatioMax          = 4.00;
input double Inp_VolRegimeLowThresh   = 0.65;
input double Inp_VolRegimeHighThresh  = 1.50;

input group "=== SENSOR MARGIN GUARD ==="
input bool   Inp_UseMarginGuard       = false;
input int    Inp_MarginGuardLevels    = 3;

input group "=== [DM] ENTRADA PRIMARIA DYNAMIC MANAGER (BTC) ==="
// TP individual: precio +/- (ATR_M1norm x mult). Cierre rapido en positivo.
input double Inp_DM_TPMultiplier    = 0.8;
// SL virtual (diagnostico). NO se envia al broker. BSE cubre la perdida.
input double Inp_DM_SLMultiplier    = 3.0;
// BTC: 1000pts x $0.01 = $10 de trailing. Muro que persigue el precio.
input int    Inp_DM_TrailingPoints  = 1000;
// BTC: 100pts x $0.01 = $1.00 minimo sobre la entrada para BE.
input int    Inp_DM_MinPointsProfit = 100;

//=================================================================
// ESTRUCTURAS
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
// HANDLES
//=================================================================
int h_ATR,h_EMAFast,h_EMASlow,h_RSI,h_MACD;
int h_ADX=INVALID_HANDLE,h_HTFEMAFast=INVALID_HANDLE,h_HTFEMASlow=INVALID_HANDLE;
int h_ATRSlow=INVALID_HANDLE,h_EMA200=INVALID_HANDLE;

//=================================================================
// VARIABLES GLOBALES
//=================================================================
CTrade        m_trade;
PosRecord     m_rec[MAX_RECORDS];
Portfolio     m_port;
MarketSnap    m_mkt;
LBCState      m_lbc;
SensorState   m_sensors;
DynThresholds m_dyn;

double   g_TFMult=1.0,g_PeakEquity=0.0,g_DynEmergencyLoss=-15.0;
double   g_MarginPer001=5.0,g_AutoBaseLot=0.01;
bool     g_CircuitBreakerHit=false,g_SoftBreakerHit=false;
datetime g_CircuitResetTime=0;

double   m_initialBalance=0,m_bestEquity=0,m_dailyBalance=0;
bool     m_isPaused=false,m_emergencyMode=false,m_dailyLimitHit=false,m_inSession=false;
bool     m_recoveryActive=false,m_recoveryTrendHedge=false;
int      m_recoveryOrders=0;
bool     m_netHedge1Applied=false,m_netHedge2Applied=false;
datetime m_lastNetHedgeTime=0;
bool     m_stormActive=false;
datetime m_stormDetectedTime=0;
double   m_stormLastATRRatio=0,m_stormLastSprRatio=0;
double   m_cycleWinsSum=0,m_cycleLossSum=0;
int      m_cycleWinsCount=0;
bool     m_cycleInPause=false;
datetime m_cycleResetTime=0;
int      m_consecutiveLosses=0;
double   m_lotMultiplier=1.0;
datetime m_lastDailyReset=0;
int      m_lastPrimaryDir=0;
datetime m_lastPrimaryTime=0;
bool     m_lastPrimaryLost=false;
double   m_lastCTBuyPrice=0,m_lastCTSellPrice=0;
datetime m_lastCTTime=0,m_lastRecoveryTime=0,m_lastBasketCheck=0;
datetime m_lastHarvestTime=0,m_lastDashTime=0,m_lastCleanupTime=0;
double   m_totalPnL=0;
int      m_tradesOpened=0,m_tradesClosed=0;
double   m_bestClosed=0,m_worstClosed=0;
int      m_totalWins=0,m_totalLosses=0;
double   m_sumWins=0,m_sumLosses=0;
long     m_tickCount=0;
bool     m_isProcessing=false;
double   m_losingPosOpenPrice=0;
int      m_losingPosType=-1;

// TEMA/Kalman
double m_temaF_e1=0,m_temaF_e2=0,m_temaF_e3=0; bool m_temaF_init=false;
double m_temaS_e1=0,m_temaS_e2=0,m_temaS_e3=0; bool m_temaS_init=false;
double m_kalF_x=0,m_kalF_p=1.0;                 bool m_kalF_init=false;
double m_kalS_x=0,m_kalS_p=1.0;                 bool m_kalS_init=false;

// Block Stage
int      m_blockStage=0;
ENUM_ORDER_TYPE m_primaryType=ORDER_TYPE_BUY;
datetime m_stage2Time=0;
bool     m_stageFollowHedge=false;
double   m_stage1TriggerAtOpen=0,m_stage3TriggerAtOpen=0;
datetime m_detangleDetectTime=0;
bool     m_detangleActive=false;
datetime m_primaryOpenTime=0;

// [DM] Estado primaria Dynamic Manager
double g_DM_PrimaryTP        = 0.0;
double g_DM_PrimaryVirtualSL = 0.0;
bool   g_DM_BEActivated      = false;

//=================================================================
// [V9.0] TIMEFRAME MULTIPLIER
// BTC: M1=1.0 M5=2.24 M15=3.87 M30=5.48 H1=7.75 H4=15.5
//=================================================================
double CalcTFMult()
{
   if(Inp_TFMultOverride>0) return Inp_TFMultOverride;
   int tfMin=PeriodSeconds(_Period)/60;
   if(tfMin<=1)    return 1.00;
   if(tfMin<=5)    return 2.24;
   if(tfMin<=15)   return 3.87;
   if(tfMin<=30)   return 5.48;
   if(tfMin<=60)   return 7.75;
   if(tfMin<=240)  return 15.50;
   if(tfMin<=1440) return 31.00;
   return 1.00;
}
double GetATR_M1Norm(){ return (g_TFMult>0)?m_mkt.atr/g_TFMult:m_mkt.atr; }

//=================================================================
// CAPITAL GUARD CORE
//=================================================================
void CalibrateMarginPerLot()
{
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return;
   double marg=0;
   if(OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,0.01,t.ask,marg)&&marg>0) g_MarginPer001=marg;
   else g_MarginPer001=5.0;
}
void RecalcAutoBaseLot()
{
   if(!Inp_UseAutoLot){g_AutoBaseLot=Inp_LotBase;return;}
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<=0){g_AutoBaseLot=Inp_LotBase;return;}
   double rawLot=bal*Inp_AutoLotPct;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0)step=0.01;
   rawLot=MathFloor(rawLot/step)*step;
   g_AutoBaseLot=NormalizeDouble(MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),MathMin(rawLot,Inp_LotHardCap)),2);
}
double CalcMaxSafeLot()
{
   CalibrateMarginPerLot();
   double freeMarg=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMarg<=0) return g_AutoBaseLot;
   double maxAllowed=freeMarg*Inp_MaxMarginUsagePct;
   double used=AccountInfoDouble(ACCOUNT_MARGIN);
   double avail=MathMax(0,maxAllowed-used);
   if(g_MarginPer001<=0) return g_AutoBaseLot;
   double maxLot=NormalizeDouble((avail/g_MarginPer001)*0.01,2);
   return NormalizeDouble(MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),MathMin(maxLot,Inp_LotHardCap)),2);
}
bool TotalVolumeOK(double addLot=0){ return (m_port.buyVolume+m_port.sellVolume+addLot<=Inp_MaxTotalVolume); }

bool HardEquityCircuitBreaker()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>g_PeakEquity) g_PeakEquity=eq;
   if(g_PeakEquity<=0) return false;
   double dd=(g_PeakEquity-eq)/g_PeakEquity;
   if(dd>=Inp_SoftCircuitBreakerPct&&!g_SoftBreakerHit)
   {
      g_SoftBreakerHit=true;
      Print("[BTC-CB-SOFT] DD=",NormalizeDouble(dd*100,1),"% >= ",NormalizeDouble(Inp_SoftCircuitBreakerPct*100,1),"% | Pausando");
      m_isPaused=true;
   }
   if(dd<Inp_SoftCircuitBreakerPct*0.5&&g_SoftBreakerHit&&!g_CircuitBreakerHit)
   { g_SoftBreakerHit=false; m_isPaused=false; Print("[BTC-CB-SOFT] Recuperado."); }
   if(dd>=Inp_HardCircuitBreakerPct)
   {
      if(!g_CircuitBreakerHit)
      {
         g_CircuitBreakerHit=true; g_CircuitResetTime=TimeCurrent();
         Print("[BTC-CB-HARD] DD=",NormalizeDouble(dd*100,1),"% | CERRANDO POSITIVAS");
         m_isProcessing=true;
         int cp=0,sn=0;
         for(int i=PositionsTotal()-1;i>=0;i--)
         {
            ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
            double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
            if(pf>=0){m_trade.PositionClose(t);cp++;}else sn++;
         }
         m_isProcessing=false;
         Print("[BTC-CB-HARD] Cerradas=",cp," Mantenidas(neg)=",sn);
         m_blockStage=0;m_recoveryActive=false;m_recoveryOrders=0;
         m_netHedge1Applied=m_netHedge2Applied=false;
         m_stageFollowHedge=false;m_primaryOpenTime=0;
         m_detangleDetectTime=0;m_detangleActive=false;
         g_DM_PrimaryTP=0.0;g_DM_PrimaryVirtualSL=0.0;g_DM_BEActivated=false;
         ZeroMemory(m_lbc); m_isPaused=true;
      }
      g_DM_PrimaryTP=0.0;g_DM_PrimaryVirtualSL=0.0;g_DM_BEActivated=false;
      return true;
   }
   if(g_CircuitBreakerHit&&m_port.totalPos==0)
   {
      if((int)(TimeCurrent()-g_CircuitResetTime)>300)
      {
         g_CircuitBreakerHit=false;g_SoftBreakerHit=false;m_isPaused=false;m_emergencyMode=false;
         g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
         Print("[BTC-CB-HARD] Cooldown OK. Reanudando.");
      }
   }
   return g_CircuitBreakerHit;
}

double CalcDynamicBlockTP()
{
   double floor=MathMax(Inp_BlockTPTarget,m_dyn.atr2usd*Inp_DynTPMult*m_dyn.sessionFactor);
   floor=MathMin(floor,Inp_DynMaxTPUSD);
   if(m_port.totalProfit>=0) return floor;
   return MathMax(floor,MathAbs(m_port.totalProfit)*Inp_TPRRR);
}

//=================================================================
// HELPERS
//=================================================================
double NormLot(double lot)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),MathMin(Inp_LotMaximum,Inp_LotHardCap));
   if(step<=0)step=0.01;
   lot=MathFloor(lot/step)*step;
   double room=MathMax(0,Inp_MaxTotalVolume-(m_port.buyVolume+m_port.sellVolume));
   lot=MathMin(lot,room);
   lot=MathMin(lot,CalcMaxSafeLot());
   return NormalizeDouble(MathMax(minL,MathMin(maxL,lot)),2);
}
double NormPrice(double p){return NormalizeDouble(p,_Digits);}
bool   GetTick(MqlTick &t){return SymbolInfoTick(_Symbol,t);}
double GetATR(){double b[1];if(CopyBuffer(h_ATR,0,1,1,b)==1)return b[0];return _Point*2000;}
double GetTickVal(){return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);}
double GetTickSize(){return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);}
double DistToUSD(double dist,double lot){double tv=GetTickVal(),ts=GetTickSize();if(tv<=0||ts<=0||dist<=0||lot<=0)return 0;return NormalizeDouble((dist/ts)*tv*lot,2);}
double ATR2USD_Lot(double m,double lot){double tv=GetTickVal(),ts=GetTickSize();double a=GetATR_M1Norm();if(tv<=0||ts<=0||a<=0||lot<=0)return 0;return NormalizeDouble((a*m/ts)*tv*lot,4);}
double ATR2USD(double m=1.0){return ATR2USD_Lot(m,g_AutoBaseLot);}
double CalcMarginFor001(){double mg=0;MqlTick t;GetTick(t);if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,0.01,t.ask,mg))return 2.0;return mg>0?mg:2.0;}

// BTC spread P80 por sesion (puntos, _Point=0.01)
int GetSessionMaxSpread(ENUM_SESSION_STATE s)
{ switch(s){case SESSION_ASIAN:return 2000;case SESSION_LONDON:return 1800;case SESSION_OVERLAP:return 1700;case SESSION_NY:return 1700;default:return 2500;} }

bool SpreadOK()
{
   int cur=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   if(m_inSession){int sm=GetSessionMaxSpread(m_dyn.session);return cur<=MathMin(sm,Inp_MaxSpread);}
   return cur<=(int)Inp_CTMaxSpreadOff;
}
bool MarginOK(double lot,ENUM_ORDER_TYPE type)
{
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE),eq=AccountInfoDouble(ACCOUNT_EQUITY),bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<Inp_CTMinBalanceUSD||free<eq*Inp_MinFreeMarginPct) return false;
   MqlTick t;if(!GetTick(t))return false;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg)&&marg>free*0.50)return false;
   return TotalVolumeOK(lot);
}
bool MarginOK_Hedge(double lot,ENUM_ORDER_TYPE type)
{
   if(!TotalVolumeOK(lot))return false;
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);if(free<=0)return false;
   MqlTick t;if(!GetTick(t))return false;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg)){if(marg<=0)return false;return marg<=free*0.80;}
   return false;
}

//=================================================================
// SESSION / VOL REGIME
//=================================================================
ENUM_SESSION_STATE GetCurrentSession()
{
   MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);
   int h=(dt.hour-Inp_GMTOffset+24)%24;
   if(dt.day_of_week==0||dt.day_of_week==6)return SESSION_OFF;
   if(h>=12&&h<17)return SESSION_OVERLAP;
   if(h>=7 &&h<12)return SESSION_LONDON;
   if(h>=17&&h<22)return SESSION_NY;
   if(h>=2 &&h<7) return SESSION_ASIAN;
   return SESSION_OFF;
}
double GetSessionFactor(ENUM_SESSION_STATE s)
{ switch(s){case SESSION_ASIAN:return Inp_SessFactorAsian;case SESSION_LONDON:return Inp_SessFactorLondon;case SESSION_OVERLAP:return Inp_SessFactorOverlap;case SESSION_NY:return Inp_SessFactorNY;default:return Inp_SessFactorOff;} }
ENUM_VOL_REGIME GetVolatilityRegime()
{
   if(m_mkt.atrSlow<=0||m_mkt.atr<=0)return VOL_NORMAL;
   double r=GetATR_M1Norm()/(m_mkt.atrSlow/g_TFMult);
   if(r>Inp_VolRegimeHighThresh)return VOL_HIGH;
   if(r<Inp_VolRegimeLowThresh)return VOL_LOW;
   return VOL_NORMAL;
}
string VolRegimeName(ENUM_VOL_REGIME r){switch(r){case VOL_LOW:return"LOW";case VOL_HIGH:return"HIGH";default:return"NORMAL";}}
string SessionName(ENUM_SESSION_STATE s){switch(s){case SESSION_ASIAN:return"ASIAN";case SESSION_LONDON:return"LONDON";case SESSION_OVERLAP:return"OVERLAP";case SESSION_NY:return"NY";default:return"OFF";}}
int GetStage2Delay(ENUM_SESSION_STATE s)
{
   int b;switch(s){case SESSION_ASIAN:b=Inp_Stage2DelayAsian;break;case SESSION_LONDON:b=Inp_Stage2DelayLondon;break;case SESSION_OVERLAP:b=Inp_Stage2DelayOverlap;break;case SESSION_NY:b=Inp_Stage2DelayNY;break;default:b=Inp_Stage2DelayAsian;}
   int tf=PeriodSeconds(_Period);return(int)MathMax(b,(double)tf*0.5);
}
double GetRecovDistATR(ENUM_VOL_REGIME r){switch(r){case VOL_LOW:return Inp_RecovDistLow;case VOL_HIGH:return Inp_RecovDistHigh;default:return Inp_RecovDistNormal;}}
void UpdateDynamicThresholds()
{
   m_dyn.session=GetCurrentSession();m_dyn.volRegime=GetVolatilityRegime();
   m_dyn.sessionFactor=GetSessionFactor(m_dyn.session);m_dyn.atr2usd=ATR2USD(1.0);
   double atr=m_dyn.atr2usd;
   if(atr<=0.01){m_dyn.stage1Trigger=Inp_Stage1Trigger;m_dyn.stage3Trigger=Inp_Stage3Trigger;m_dyn.blockTP=Inp_BlockTPTarget;m_dyn.recovTrigger=Inp_RecoveryTriggerUSD;m_dyn.netHedgeTrig1=Inp_NetHedgeTrigger1USD;m_dyn.netHedgeTrig2=Inp_NetHedgeTrigger2USD;}
   else{
      double sf=m_dyn.sessionFactor;
      double s1=-(atr*Inp_DynStage1Mult*sf);s1=MathMax(s1,-Inp_DynMaxStage1USD);m_dyn.stage1Trigger=MathMin(s1,Inp_Stage1Trigger);
      double s3=-(atr*Inp_DynStage3Mult*sf);s3=MathMax(s3,-Inp_DynMaxStage3USD);m_dyn.stage3Trigger=MathMin(s3,Inp_Stage3Trigger);
      double tp=atr*Inp_DynTPMult*sf;tp=MathMin(tp,Inp_DynMaxTPUSD);m_dyn.blockTP=MathMax(tp,Inp_BlockTPTarget);
      m_dyn.blockTP=CalcDynamicBlockTP();
      m_dyn.recovTrigger=MathMin(-(atr*Inp_DynRecovMult*sf),Inp_RecoveryTriggerUSD);
      m_dyn.netHedgeTrig1=MathMin(-(atr*Inp_NetHedgeMult1),Inp_NetHedgeTrigger1USD);
      m_dyn.netHedgeTrig2=MathMin(-(atr*Inp_NetHedgeMult2),Inp_NetHedgeTrigger2USD);
   }
   m_dyn.stage2Delay=GetStage2Delay(m_dyn.session);m_dyn.recovDistATR=GetRecovDistATR(m_dyn.volRegime);
}

bool AntiSymmetricOK(ENUM_ORDER_TYPE type,double lot)
{
   double net=m_port.buyVolume-m_port.sellVolume;
   double nn=(type==ORDER_TYPE_BUY)?net+lot:net-lot;
   double ml=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);if(ml<=0)ml=0.01;
   if(MathAbs(nn)>=ml*0.99)return true;
   Print("[BTC-ANTISYM] bloqueo simetria NetVol=",NormalizeDouble(net,3)," newNet=",NormalizeDouble(nn,3));
   return false;
}

//=================================================================
// RECORDS
//=================================================================
int FindRec(ulong t){for(int i=0;i<MAX_RECORDS;i++)if(m_rec[i].ticket==t)return i;return -1;}
int FreeRec(){for(int i=0;i<MAX_RECORDS;i++)if(m_rec[i].ticket==0)return i;return -1;}
void InitRec(int idx,ulong ticket,int posType,double openPrice,double vol,string comment,bool isPrimary,bool isCounter,bool isRecovery=false,bool isLBC=false)
{
   if(idx<0||idx>=MAX_RECORDS)return;ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket=ticket;m_rec[idx].posType=posType;m_rec[idx].openPrice=openPrice;
   m_rec[idx].volume=vol;m_rec[idx].openTime=TimeCurrent();m_rec[idx].comment=comment;
   m_rec[idx].isPrimary=isPrimary;m_rec[idx].isCounter=isCounter;
   m_rec[idx].isRecovery=isRecovery;m_rec[idx].isLBC=isLBC;m_rec[idx].kP=1.0;m_rec[idx].kK=1.0;
}
void CleanupRecs()
{
   for(int i=0;i<MAX_RECORDS;i++){
      if(m_rec[i].ticket==0)continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)){
         double pnl=m_rec[i].netProfit;
         if(pnl!=0){m_totalPnL+=pnl;m_tradesClosed++;if(pnl>0){m_totalWins++;m_sumWins+=pnl;}else{m_totalLosses++;m_sumLosses+=MathAbs(pnl);}if(pnl>m_bestClosed)m_bestClosed=pnl;if(pnl<m_worstClosed)m_worstClosed=pnl;}
         ZeroMemory(m_rec[i]);
      }
   }
}
void SyncPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      if(FindRec(t)>=0)continue;
      int idx=FreeRec();if(idx<0)continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);double op=PositionGetDouble(POSITION_PRICE_OPEN),vol=PositionGetDouble(POSITION_VOLUME);
      string comm=PositionGetString(POSITION_COMMENT);
      InitRec(idx,t,pt,op,vol,comm,StringFind(comm,"Primary")>=0,StringFind(comm,"CT_")>=0,StringFind(comm,"REC_")>=0||StringFind(comm,"BSE_")>=0,StringFind(comm,"LBC_")>=0);
   }
}
void UpdateKalman()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      int idx=FindRec(t);if(idx<0)continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit=pf;if(pf>m_rec[idx].peakProfit)m_rec[idx].peakProfit=pf;
      if(!m_rec[idx].kInit){m_rec[idx].kX=pf;m_rec[idx].kP=1.0;m_rec[idx].kK=1.0;m_rec[idx].kInit=true;continue;}
      double pP=m_rec[idx].kP+0.01,K=pP/(pP+0.20);m_rec[idx].kX+=K*(pf-m_rec[idx].kX);m_rec[idx].kP=(1.0-K)*pP;m_rec[idx].kK=K;
   }
}

//=================================================================
// MERCADO + TEMA/KALMAN
//=================================================================
bool IsInMainSession()
{
   MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);
   if(dt.day_of_week==0||dt.day_of_week==6)return false;
   int h=(dt.hour-Inp_GMTOffset+24)%24;
   return(h>=Inp_LondonOpen&&h<Inp_LondonClose)||(h>=Inp_NYOpen&&h<Inp_NYClose);
}
void UpdateTEMAKalman()
{
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
void UpdateMarket()
{
   MqlTick t;if(!GetTick(t))return;
   m_mkt.bid=t.bid;m_mkt.ask=t.ask;m_mkt.spread=(t.ask-t.bid)/_Point;m_mkt.atr=GetATR();
   double f[1],s[1],r[1],m[1],sg[1];
   if(CopyBuffer(h_EMAFast,0,0,1,f)==1)m_mkt.emaFast=f[0];if(CopyBuffer(h_EMASlow,0,0,1,s)==1)m_mkt.emaSlow=s[0];
   if(CopyBuffer(h_RSI,0,0,1,r)==1)m_mkt.rsi=r[0];if(CopyBuffer(h_MACD,0,0,1,m)==1)m_mkt.macdMain=m[0];if(CopyBuffer(h_MACD,1,0,1,sg)==1)m_mkt.macdSig=sg[0];
   if(h_ADX!=INVALID_HANDLE){double a[1];if(CopyBuffer(h_ADX,0,0,1,a)==1)m_mkt.adx=a[0];}
   if(h_HTFEMAFast!=INVALID_HANDLE&&h_HTFEMASlow!=INVALID_HANDLE){double hf[1],hs[1];if(CopyBuffer(h_HTFEMAFast,0,0,1,hf)==1&&CopyBuffer(h_HTFEMASlow,0,0,1,hs)==1)m_mkt.htfTrend=(hf[0]>hs[0]*1.0001)?1:(hf[0]<hs[0]*0.9999)?-1:0;}
   if(h_EMA200!=INVALID_HANDLE){double e[1];if(CopyBuffer(h_EMA200,0,1,1,e)==1)m_mkt.ema200=e[0];}
   if(h_ATRSlow!=INVALID_HANDLE){double a[1];if(CopyBuffer(h_ATRSlow,0,1,1,a)==1)m_mkt.atrSlow=a[0];}
   m_mkt.isBullish=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.rsi>52&&m_mkt.macdMain>m_mkt.macdSig);
   m_mkt.isBearish=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.rsi<48&&m_mkt.macdMain<m_mkt.macdSig);
   UpdateTEMAKalman();RecalcAutoBaseLot();UpdateDynamicThresholds();
}
void UpdatePortfolio()
{
   ZeroMemory(m_port);m_port.worstProfit=0;m_losingPosOpenPrice=0;m_losingPosType=-1;
   double vN=0,vD=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;
      long mg=PositionGetInteger(POSITION_MAGIC);bool isOwn=(mg==Inp_Magic),isExt=(!isOwn&&Inp_RescueAllTrades);
      if(!isOwn&&!isExt)continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol=PositionGetDouble(POSITION_VOLUME),op=PositionGetDouble(POSITION_PRICE_OPEN);string comm=PositionGetString(POSITION_COMMENT);
      m_port.totalPos++;m_port.totalProfit+=pf;
      if(pf>=0)m_port.positiveSum+=pf;else m_port.negativeSum+=MathAbs(pf);
      if(pt==POSITION_TYPE_BUY){m_port.buyCount++;m_port.buyProfit+=pf;m_port.buyVolume+=vol;}else{m_port.sellCount++;m_port.sellProfit+=pf;m_port.sellVolume+=vol;}
      vN+=op*vol;vD+=vol;m_port.blockDir+=(pt==POSITION_TYPE_BUY)?1:-1;
      if(pf<m_port.worstProfit){m_port.worstProfit=pf;m_port.worstTicket=t;m_losingPosOpenPrice=op;m_losingPosType=pt;}
      if(isOwn){if(StringFind(comm,"CT_")>=0)m_port.ctCount++;if(StringFind(comm,"REC_")>=0||StringFind(comm,"BSE_")>=0)m_port.recoveryCount++;if(StringFind(comm,"LBC_")>=0)m_port.lbcCount++;}
      if(isExt){m_port.rescueCount++;m_port.rescueProfit+=pf;}
   }
   if(vD>0)m_port.blockVWAP=vN/vD;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);if(eq>m_bestEquity)m_bestEquity=eq;if(eq>g_PeakEquity)g_PeakEquity=eq;
   m_port.currentDD=(m_bestEquity>0)?(m_bestEquity-eq)/m_bestEquity:0;
}

//=================================================================
// SENSORES
//=================================================================
int ParseHH(string t){return(int)StringToInteger(StringSubstr(t,0,2));}
int ParseMM(string t){return(int)StringToInteger(StringSubstr(t,3,2));}
void CalcBrokerTimeWindow(){int s=ParseHH(Inp_StartTime)*60+ParseMM(Inp_StartTime),e=ParseHH(Inp_EndTime)*60+ParseMM(Inp_EndTime),off=(Inp_BrokerGMT-Inp_UserGMT)*60;m_sensors.brokerStartMin=((s+off)%1440+1440)%1440;m_sensors.brokerEndMin=((e+off)%1440+1440)%1440;}
bool IsInTradingWindow(){if(!Inp_UseTimeFilter)return true;MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);int now=dt.hour*60+dt.min,s=m_sensors.brokerStartMin,e=m_sensors.brokerEndMin;if(s<=e)return now>=s&&now<e;else return now>=s||now<e;}
bool TrendFilter200OK(ENUM_ORDER_TYPE type){if(!Inp_UseTrendFilter200||m_mkt.ema200<=0)return true;MqlTick tk;if(!GetTick(tk))return true;double mid=(tk.bid+tk.ask)/2.0;if(type==ORDER_TYPE_BUY)return mid>m_mkt.ema200;if(type==ORDER_TYPE_SELL)return mid<m_mkt.ema200;return true;}
bool VolatilityOK(){if(!Inp_UseVolatFilter||m_mkt.atrSlow<=0)return true;double aN=GetATR_M1Norm(),aS=m_mkt.atrSlow/g_TFMult;m_sensors.atrRatio=(aS>0)?aN/aS:1.0;return m_sensors.atrRatio<=Inp_ATRRatioMax;}
bool MarginGuardOK(){if(!Inp_UseMarginGuard)return true;double lot=g_AutoBaseLot,m1=0;MqlTick tk;if(!GetTick(tk))return true;if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lot,tk.ask,m1)||m1<=0)return true;return AccountInfoDouble(ACCOUNT_MARGIN_FREE)>=m1*(1.0+Inp_MarginGuardLevels);}
void UpdateSensors()
{
   m_sensors.blockReason="";m_sensors.timeOK=IsInTradingWindow();if(!m_sensors.timeOK&&m_sensors.blockReason=="")m_sensors.blockReason="Fuera ventana";
   m_sensors.spreadOK=SpreadOK();if(!m_sensors.spreadOK&&m_sensors.blockReason==""){int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);m_sensors.blockReason="Spread BTC: "+IntegerToString(cs)+"pts";}
   if(m_mkt.ema200>0){MqlTick tk;GetTick(tk);m_sensors.trendBull=((tk.bid+tk.ask)/2.0>m_mkt.ema200);}else m_sensors.trendBull=true;
   m_sensors.volatOK=VolatilityOK();if(!m_sensors.volatOK&&m_sensors.blockReason=="")m_sensors.blockReason="Storm ATR="+DoubleToString(m_sensors.atrRatio,1);
   if(m_dyn.volRegime==VOL_HIGH&&m_sensors.volatOK&&m_sensors.blockReason=="")m_sensors.blockReason="Vol HIGH BTC (>"+DoubleToString(Inp_VolRegimeHighThresh,2)+")";
   m_sensors.marginOK=MarginGuardOK();if(!m_sensors.marginOK&&m_sensors.blockReason=="")m_sensors.blockReason="Margen insuf.";
   if(g_CircuitBreakerHit&&m_sensors.blockReason=="")m_sensors.blockReason="CIRCUIT BREAKER";
   if(g_SoftBreakerHit&&m_sensors.blockReason=="")m_sensors.blockReason="SOFT BREAKER";
   m_sensors.allOK=(m_sensors.timeOK&&m_sensors.spreadOK&&m_sensors.volatOK&&m_sensors.marginOK&&m_dyn.volRegime!=VOL_HIGH&&!g_CircuitBreakerHit&&!g_SoftBreakerHit);
}
bool ADXAllowsEntry(ENUM_ORDER_TYPE type){if(!Inp_UseADX)return true;double lv=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;if(m_mkt.adx<lv)return true;int htf=m_mkt.htfTrend;if(htf==0)return false;return(type==ORDER_TYPE_BUY&&htf==1)||(type==ORDER_TYPE_SELL&&htf==-1);}
void ResetDailyIfNeeded(){MqlDateTime dt;TimeToStruct(TimeCurrent(),dt);datetime mid=TimeCurrent()-(dt.hour*3600+dt.min*60+dt.sec);if(m_lastDailyReset<mid){m_dailyBalance=AccountInfoDouble(ACCOUNT_BALANCE);m_dailyLimitHit=false;m_lastDailyReset=mid;}}
bool DailyLimitReached(){if(!Inp_UseDailyLimit||m_dailyLimitHit)return m_dailyLimitHit;double eff=(AccountInfoDouble(ACCOUNT_BALANCE)-m_dailyBalance)+m_port.totalProfit;double lim=MathMin(MathAbs(Inp_DailyLossUSD),m_dailyBalance*MathAbs(Inp_DailyLossPct/100.0));if(eff<=-lim){Print("[BTC] LIMITE DIARIO");m_dailyLimitHit=true;m_isPaused=true;}return m_dailyLimitHit;}
void UpdateStreak(double pnl){if(pnl<-0.01){m_consecutiveLosses++;if(m_consecutiveLosses>=Inp_LossStreakMax&&m_lotMultiplier==1.0)m_lotMultiplier=Inp_LossStreakReduce;}else if(pnl>0.01){m_lotMultiplier=1.0;m_consecutiveLosses=0;}}
double CalcExpectancy(){int tot=m_totalWins+m_totalLosses;if(tot==0)return 0;double wr=(double)m_totalWins/tot;return(wr*(m_totalWins>0?m_sumWins/m_totalWins:0))-((1.0-wr)*(m_totalLosses>0?m_sumLosses/m_totalLosses:0));}

//=================================================================
// CIERRE DE POSICIONES
//=================================================================
bool ClosePos(ulong ticket,string reason="")
{
   if(!PositionSelectByTicket(ticket))return false;if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic)return false;
   if(!m_isProcessing&&m_port.totalPos>1){Print("[BTC] CIERRE INDIVIDUAL BLOQUEADO #",ticket);return false;}
   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)){
      UpdateStreak(pf);if(pf>0){m_cycleWinsSum+=pf;m_cycleWinsCount++;m_totalWins++;m_sumWins+=pf;}else{m_cycleLossSum+=pf;m_totalLosses++;m_sumLosses+=MathAbs(pf);}
      m_totalPnL+=pf;m_tradesClosed++;if(pf>m_bestClosed)m_bestClosed=pf;if(pf<m_worstClosed)m_worstClosed=pf;
      int idx=FindRec(ticket);if(idx>=0){if(m_rec[idx].isPrimary)m_lastPrimaryLost=(pf<0);if(m_rec[idx].isLBC){string comm=m_rec[idx].comment;if(StringFind(comm,"LBC_B")>=0&&m_lbc.buyCount>0)m_lbc.buyCount--;if(StringFind(comm,"LBC_S")>=0&&m_lbc.sellCount>0)m_lbc.sellCount--;}Print("[BTC] CERRADA #",ticket," $",NormalizeDouble(pf,2),(reason!=""?" ["+reason+"]":""));ZeroMemory(m_rec[idx]);}
      m_cycleResetTime=TimeCurrent();m_cycleInPause=true;m_lastCTBuyPrice=m_lastCTSellPrice=0;ZeroMemory(m_lbc);
      g_DM_PrimaryTP=0.0;g_DM_PrimaryVirtualSL=0.0;g_DM_BEActivated=false;return true;
   }
   return false;
}
bool CloseRescuePos(ulong ticket,string reason){if(!PositionSelectByTicket(ticket))return false;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(m_trade.PositionClose(ticket)){m_totalPnL+=pf;m_tradesClosed++;Print("[BTC] RESCATE #",ticket," $",NormalizeDouble(pf,2)," [",reason,"]");return true;}return false;}
bool CloseBlockIfPositive(string reason)
{
   double dynTP=CalcDynamicBlockTP();if(m_port.totalProfit<dynTP)return false;
   Print("[BTC] CIERRE POSITIVO: $",NormalizeDouble(m_port.totalProfit,2)," >= DynTP=$",NormalizeDouble(dynTP,2)," [",reason,"] Stage=",m_blockStage);
   m_isProcessing=true;
   for(int pass=0;pass<2;pass++){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=Inp_Magic)continue;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(pass==0&&pf<0)continue;if(pass==1&&pf>=0)continue;ClosePos(t,reason);}}
   if(Inp_RescueAllTrades){for(int pass=0;pass<2;pass++){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)==Inp_Magic)continue;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(pass==0&&pf<0)continue;if(pass==1&&pf>=0)continue;CloseRescuePos(t,"RESCUE_"+reason);}}}
   m_isProcessing=false;
   m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;m_netHedge1Applied=false;m_netHedge2Applied=false;
   m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=0;m_stage3TriggerAtOpen=0;m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
   m_cycleResetTime=TimeCurrent();m_cycleInPause=true;m_lastCTBuyPrice=m_lastCTSellPrice=0;ZeroMemory(m_lbc);return true;
}

//=================================================================
// CALCULO DE LOTES
//=================================================================
double GetEffectiveBaseLot(){double lot=g_AutoBaseLot*m_lotMultiplier;if(!m_inSession)lot*=Inp_OffSessionLotFactor;return NormLot(lot);}
double CalcLot(int level=0){return GetEffectiveBaseLot();}
double CalcDirectionalLot(int targetDir)
{
   double atr=GetATR_M1Norm();if(atr<=0)return NormLot(g_AutoBaseLot*2.0);
   double needed=MathAbs(m_port.totalProfit)*Inp_TPRRR+m_dyn.blockTP;double md=atr*Inp_RecoveryMoveATR;if(md<=0)md=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),calc=g_AutoBaseLot*2.0;if(tv>0&&ts>0&&md>0){double pp=(md/ts)*tv;if(pp>0)calc=needed/pp;}
   calc=MathMin(calc,Inp_LotHardCap);return NormLot(MathMax(calc,g_AutoBaseLot*1.5));
}
double CalcRecoveryLot()
{
   double atr=GetATR_M1Norm();if(atr<=0)return NormLot(g_AutoBaseLot*Inp_RecoveryMinLotMult);
   double needed=MathAbs(m_port.totalProfit)*Inp_TPRRR+m_dyn.blockTP;double md=atr*Inp_RecoveryMoveATR;if(md<=0)md=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),pp=0;if(tv>0&&ts>0)pp=(md/ts)*tv;
   double calc=g_AutoBaseLot;if(pp>0)calc=needed/pp;
   double safe=CalcMaxSafeLot();calc=MathMin(MathMin(calc,safe),Inp_LotHardCap);
   double loserLot=g_AutoBaseLot;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic||PositionGetString(POSITION_SYMBOL)!=_Symbol)continue;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(pf==m_port.worstProfit){loserLot=PositionGetDouble(POSITION_VOLUME);break;}}
   double minLot=MathMin(loserLot*Inp_RecoveryMinLotMult,Inp_LotHardCap);return NormLot(MathMax(calc,minLot));
}

//=================================================================
// APERTURA DE ORDENES
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type,double lot,string comment,bool skipPosLimit=false)
{
   if((m_isPaused||m_emergencyMode)&&!skipPosLimit)return 0;if(g_CircuitBreakerHit)return 0;if(!SpreadOK())return 0;
   if(!skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal)return 0;if(skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal+2)return 0;
   lot=NormLot(lot);if(lot<=0)return 0;if(!MarginOK(lot,type))return 0;
   if(!TotalVolumeOK(lot)){Print("[BTC] OpenOrder bloqueado: vol excederia ",Inp_MaxTotalVolume);return 0;}
   MqlTick t;if(!GetTick(t))return 0;double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid;
   bool ok=(type==ORDER_TYPE_BUY)?m_trade.Buy(lot,_Symbol,price,0,0,comment):m_trade.Sell(lot,_Symbol,price,0,0,comment);
   if(!ok){Print("[BTC] ERR apertura: ",m_trade.ResultRetcodeDescription());return 0;}
   ulong ticket=m_trade.ResultOrder();
   if(ticket>0){m_tradesOpened++;Print("[BTC] ABIERTA #",ticket," ",(type==ORDER_TYPE_BUY?"BUY":"SELL")," Lot=",lot," [",comment,"] TFMult=",NormalizeDouble(g_TFMult,2)," Sess=",SessionName(m_dyn.session)," VR=",VolRegimeName(m_dyn.volRegime)," TotalVol=",NormalizeDouble(m_port.buyVolume+m_port.sellVolume+lot,3));}
   return ticket;
}

//+------------------------------------------------------------------+
//| [DM-BTC] Break-Even y Trailing Stop de la primaria              |
//| Solo actua en Stage 1. En Stage 2+ el BSE toma el control.      |
//|                                                                  |
//| COMPORTAMIENTO:                                                   |
//| 1. TP corto (ATR x 0.8) se cierra automaticamente si alcanzado  |
//| 2. BE activa cuando el precio va 0.5xATR a favor                |
//|    → SL se mueve a entrada + $1 (100pts). NUNCA cierra negativo.|
//| 3. Trailing de $10 (1000pts) persigue el precio como MURO.      |
//|    Protege ganancias y no deja retroceder.                       |
//| 4. Si Stage 2 se activa → TP eliminado → cierre en bloque.      |
//+------------------------------------------------------------------+
void ManagePrimaryDM()
{
   if(m_blockStage!=1||m_port.totalPos==0)return;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double atr=GetATR_M1Norm();
   double bid=m_mkt.bid,ask=m_mkt.ask;
   for(int i=0;i<MAX_RECORDS;i++)
   {
      if(m_rec[i].ticket==0||!m_rec[i].isPrimary)continue;
      ulong ticket=m_rec[i].ticket;if(!PositionSelectByTicket(ticket))continue;
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      if(m_rec[i].posType==POSITION_TYPE_BUY)
      {
         // Break-Even: activa cuando bid >= open + 0.5*ATR
         // Una vez activado: SL >= open → NUNCA cierra negativo
         if(!g_DM_BEActivated&&bid>=open+atr*0.5)
         {
            double tBE=NormPrice(open+Inp_DM_MinPointsProfit*point);
            if(sl<tBE)if(m_trade.PositionModify(ticket,tBE,tp)){g_DM_BEActivated=true;Print("[DM-BTC] BUY BE @ ",NormalizeDouble(tBE,_Digits)," (+$",NormalizeDouble((tBE-open)/GetTickSize()*GetTickVal()*m_rec[i].volume,2),")");}
         }
         // Trailing: muro que persigue el precio hacia arriba
         if(g_DM_BEActivated&&sl>0.0&&sl>=open)
         {
            double nSL=NormPrice(bid-Inp_DM_TrailingPoints*point);
            if(nSL>sl)m_trade.PositionModify(ticket,nSL,tp);
         }
      }
      else
      {
         if(!g_DM_BEActivated&&ask<=open-atr*0.5)
         {
            double tBE=NormPrice(open-Inp_DM_MinPointsProfit*point);
            if(sl==0.0||sl>tBE)if(m_trade.PositionModify(ticket,tBE,tp)){g_DM_BEActivated=true;Print("[DM-BTC] SELL BE @ ",NormalizeDouble(tBE,_Digits)," (+$",NormalizeDouble((open-tBE)/GetTickSize()*GetTickVal()*m_rec[i].volume,2),")");}
         }
         if(g_DM_BEActivated&&sl>0.0&&sl<=open)
         {
            double nSL=NormPrice(ask+Inp_DM_TrailingPoints*point);
            if(nSL<sl)m_trade.PositionModify(ticket,nSL,tp);
         }
      }
      break;
   }
}
void ManagePositions(){ManagePrimaryDM();}

//=================================================================
// DETANGLE ENGINE
//=================================================================
void RunDetangle()
{
   if(m_isProcessing||m_port.totalPos<2)return;
   double nv=MathAbs(m_port.buyVolume-m_port.sellVolume);bool isSym=nv<Inp_DetangleNetThresh,bad=m_port.totalProfit<Inp_DetangleMinLoss;
   if(!isSym||!bad){if(!isSym){m_detangleDetectTime=0;m_detangleActive=false;}return;}
   if(m_detangleDetectTime==0){m_detangleDetectTime=TimeCurrent();m_detangleActive=true;Print("[BTC-DETANGLE] jaula simétrica | NetVol=",NormalizeDouble(nv,3)," PnL=",NormalizeDouble(m_port.totalProfit,2));return;}
   if((int)(TimeCurrent()-m_detangleDetectTime)<Inp_DetangleSec)return;if(!SpreadOK())return;
   if(m_port.worstTicket>0&&m_port.totalProfit>=0){m_isProcessing=true;bool cl=ClosePos(m_port.worstTicket,"Detangle");m_isProcessing=false;if(cl){m_detangleDetectTime=TimeCurrent();m_detangleActive=false;UpdatePortfolio();}}
   else if(m_port.worstTicket>0&&m_port.totalProfit<0)Print("[BTC-DETANGLE] esperando positivo | $",NormalizeDouble(m_port.totalProfit,2));
}

//=================================================================
// BLOCK STAGE ENGINE
//=================================================================
void RunBlockStageEngine()
{
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
               if(t1>0){int idx=FreeRec();if(idx>=0){int pt1=(m_primaryType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;InitRec(idx,t1,pt1,(m_primaryType==ORDER_TYPE_BUY)?tk.ask:tk.bid,rL,"BSE_REINF1",false,false,true,false);}
                  m_blockStage=2;m_stage2Time=TimeCurrent();m_recoveryActive=true;m_stageFollowHedge=false;m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
                  // [DM] Quitar TP de primaria → cierre en bloque
                  for(int ri=0;ri<MAX_RECORDS;ri++){if(m_rec[ri].ticket==0||!m_rec[ri].isPrimary)continue;if(PositionSelectByTicket(m_rec[ri].ticket)){double csl=PositionGetDouble(POSITION_SL);m_trade.PositionModify(m_rec[ri].ticket,csl,0.0);}break;}
                  g_DM_PrimaryTP=0.0;Print("[BTC] STAGE 2 REINFORCE");}}
         }else{
            ENUM_ORDER_TYPE hT=(m_primaryType==ORDER_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
            double hL=NormLot(g_AutoBaseLot*Inp_HedgeRatio);hL=MathMax(hL,NormLot(g_AutoBaseLot));
            if(!AntiSymmetricOK(hT,hL)){double vs=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(vs<=0)vs=0.01;hL=NormLot(hL+vs);}
            if(MarginOK(hL,hT)){m_isProcessing=true;ulong t1=OpenOrder(hT,hL,"BSE_H1",true);m_isProcessing=false;
               if(t1>0){int idx=FreeRec();if(idx>=0){int pt1=(hT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;InitRec(idx,t1,pt1,(hT==ORDER_TYPE_BUY)?tk.ask:tk.bid,hL,"BSE_H1",false,false,true,false);}
                  m_blockStage=2;m_stage2Time=TimeCurrent();m_recoveryActive=true;m_stageFollowHedge=true;m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
                  for(int ri=0;ri<MAX_RECORDS;ri++){if(m_rec[ri].ticket==0||!m_rec[ri].isPrimary)continue;if(PositionSelectByTicket(m_rec[ri].ticket)){double csl=PositionGetDouble(POSITION_SL);m_trade.PositionModify(m_rec[ri].ticket,csl,0.0);}break;}
                  g_DM_PrimaryTP=0.0;Print("[BTC] STAGE 2 HEDGE ASIM #",t1);}}
         }
      }return;
   }

   if(m_blockStage==2&&mCnt==2){
      if((int)(TimeCurrent()-m_stage2Time)<m_dyn.stage2Delay)return;if(!SpreadOK())return;
      int tDir=m_mkt.trendConfirmed;ENUM_ORDER_TYPE t3T;int t3D;
      if(tDir==1){t3T=ORDER_TYPE_BUY;t3D=1;}else if(tDir==-1){t3T=ORDER_TYPE_SELL;t3D=-1;}else{if(m_port.buyProfit<m_port.sellProfit){t3T=ORDER_TYPE_SELL;t3D=-1;}else{t3T=ORDER_TYPE_BUY;t3D=1;}}
      double t3L=CalcDirectionalLot(t3D);if(!AntiSymmetricOK(t3T,t3L)){double nv=m_port.buyVolume-m_port.sellVolume;double mn=(t3D==1)?g_AutoBaseLot*1.5-nv:nv+g_AutoBaseLot*1.5;t3L=NormLot(MathMax(t3L,MathAbs(mn)));}
      string lb=(t3D==1)?"BSE_DIR_L":"BSE_DIR_S";m_stageFollowHedge=(t3T!=m_primaryType);
      if(MarginOK(t3L,t3T)){m_isProcessing=true;ulong t2=OpenOrder(t3T,t3L,lb,true);m_isProcessing=false;if(t2>0){int idx=FreeRec();if(idx>=0){int pt2=(t3T==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;InitRec(idx,t2,pt2,(t3T==ORDER_TYPE_BUY)?tk.ask:tk.bid,t3L,lb,false,false,true,false);}m_blockStage=3;Print("[BTC] STAGE 3 #",t2," Lot=",NormalizeDouble(t3L,2));}}else ActivateLBC();
      return;
   }

   if(m_blockStage==3){
      double t3=(m_stage3TriggerAtOpen!=0)?m_stage3TriggerAtOpen:m_dyn.stage3Trigger;
      if(pnl<=t3){if(!SpreadOK())return;
         int tDir=m_mkt.trendConfirmed;ENUM_ORDER_TYPE t4T;int t4D;
         if(tDir==1){t4T=ORDER_TYPE_BUY;t4D=1;}else if(tDir==-1){t4T=ORDER_TYPE_SELL;t4D=-1;}else{if(m_port.buyProfit>m_port.sellProfit){t4T=ORDER_TYPE_BUY;t4D=1;}else{t4T=ORDER_TYPE_SELL;t4D=-1;}}
         double t4L=CalcDirectionalLot(t4D);if(!AntiSymmetricOK(t4T,t4L)){double nv=m_port.buyVolume-m_port.sellVolume;double mn=(t4D==1)?g_AutoBaseLot*2.0-nv:nv+g_AutoBaseLot*2.0;t4L=NormLot(MathMax(t4L,MathAbs(mn)));}
         if(MarginOK(t4L,t4T)){m_isProcessing=true;ulong t3t=OpenOrder(t4T,t4L,"BSE_CON4",true);m_isProcessing=false;if(t3t>0){int idx=FreeRec();if(idx>=0){int pt3=(t4T==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;InitRec(idx,t3t,pt3,(t4T==ORDER_TYPE_BUY)?tk.ask:tk.bid,t4L,"BSE_CON4",false,false,true,false);}m_blockStage=4;Print("[BTC] STAGE 4 #",t3t);}}else ActivateLBC();}
      return;
   }
   if(m_blockStage==4){if(!m_lbc.active&&pnl<m_dyn.stage3Trigger*1.5)ActivateLBC();}
}

//=================================================================
// RECOVERY ENGINE FALLBACK
//=================================================================
void RunRecoveryEngine()
{
   if(m_port.totalProfit>=m_dyn.recovTrigger){if(m_recoveryActive&&m_blockStage==0){m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;}return;}
   if(m_port.totalPos==0||m_isProcessing)return;if(CloseBlockIfPositive("Recovery_TP"))return;
   if(!m_recoveryActive){m_recoveryActive=true;m_recoveryOrders=m_port.recoveryCount;m_recoveryTrendHedge=false;g_DM_PrimaryTP=0.0;g_DM_PrimaryVirtualSL=0.0;g_DM_BEActivated=false;Print("[BTC] RECOVERY | $",NormalizeDouble(m_port.totalProfit,2)," VR=",VolRegimeName(m_dyn.volRegime));}
   if(m_recoveryOrders>=Inp_RecoveryMaxOrders){if(!m_lbc.active){Print("[BTC] RECOVERY LIMIT → LBC");ActivateLBC();}return;}
   if(TimeCurrent()-m_lastRecoveryTime<Inp_RecoveryIntervalSec||!SpreadOK())return;
   MqlTick tk;if(!GetTick(tk))return;double atr=GetATR_M1Norm();if(atr<=0)return;
   double minD=atr*m_dyn.recovDistATR;
   if(m_losingPosOpenPrice>0&&m_losingPosType>=0){double dist=(m_losingPosType==POSITION_TYPE_SELL)?tk.bid-m_losingPosOpenPrice:m_losingPosOpenPrice-tk.ask;if(dist<minD)return;}
   ENUM_ORDER_TYPE recT;double adxLv=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;
   bool bearT=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.adx>adxLv),bullT=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.adx>adxLv);
   if(m_port.buyProfit<m_port.sellProfit&&bearT){recT=ORDER_TYPE_SELL;m_recoveryTrendHedge=true;}
   else if(m_port.sellProfit<m_port.buyProfit&&bullT){recT=ORDER_TYPE_BUY;m_recoveryTrendHedge=true;}
   else{m_recoveryTrendHedge=false;double cd=atr*0.3;if(m_port.buyProfit<m_port.sellProfit){recT=ORDER_TYPE_BUY;if(m_lastCTBuyPrice>0&&MathAbs(tk.ask-m_lastCTBuyPrice)<cd)return;}else{recT=ORDER_TYPE_SELL;if(m_lastCTSellPrice>0&&MathAbs(tk.bid-m_lastCTSellPrice)<cd)return;}}
   double recL=CalcRecoveryLot();
   if(!AntiSymmetricOK(recT,recL)){double nv=m_port.buyVolume-m_port.sellVolume;int td=(recT==ORDER_TYPE_BUY)?1:-1;double mn=(td==1)?g_AutoBaseLot-nv:nv+g_AutoBaseLot;recL=NormLot(MathMax(recL,MathAbs(mn)));}
   if(!MarginOK(recL,recT)){recL=NormLot(recL*0.5);if(!MarginOK(recL,recT)){recL=NormLot(g_AutoBaseLot);if(!MarginOK(recL,recT)){ActivateLBC();return;}}}
   string rc="REC_"+(recT==ORDER_TYPE_BUY?"B":"S")+"_"+IntegerToString(m_recoveryOrders+1);
   m_isProcessing=true;ulong ticket=OpenOrder(recT,recL,rc,true);m_isProcessing=false;
   if(ticket>0){int idx=FreeRec();if(idx>=0){int pt=(recT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;InitRec(idx,ticket,pt,(recT==ORDER_TYPE_BUY)?tk.ask:tk.bid,recL,rc,false,false,true,false);}if(recT==ORDER_TYPE_BUY)m_lastCTBuyPrice=tk.ask;else m_lastCTSellPrice=tk.bid;m_recoveryOrders++;m_lastRecoveryTime=TimeCurrent();Print("[BTC] Recovery #",m_recoveryOrders,"/",Inp_RecoveryMaxOrders," Lot=",recL);}
}

//=================================================================
// LBC ENGINE
//=================================================================
void ActivateLBC(){if(m_lbc.active)return;m_lbc.active=true;m_lbc.activatedTime=TimeCurrent();m_lbc.buyCount=m_lbc.sellCount=0;m_lbc.lastBuyPrice=m_lbc.lastSellPrice=0;m_lbc.harvestedTotal=0;m_lbc.harvestCount=0;double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE),mp=CalcMarginFor001();m_lbc.maxOrdersCalc=(int)MathMax(1,MathMin(Inp_LBCMaxPairs,(int)MathFloor((fm*Inp_LBCMarginPct)/(2.0*MathMax(mp,0.01)))));Print("[BTC] LBC ACTIVADO MaxPares=",m_lbc.maxOrdersCalc);}
void DeactivateLBC(){if(!m_lbc.active)return;Print("[BTC] LBC DESACTIVADO Cosecha=$",NormalizeDouble(m_lbc.harvestedTotal,2));ZeroMemory(m_lbc);}
void RunLBCEngine()
{
   if(!m_lbc.active)return;if(m_port.totalPos==0){DeactivateLBC();return;}if(m_isProcessing)return;
   double dynTP=CalcDynamicBlockTP();if(m_port.totalProfit>=dynTP)return;if(m_port.totalProfit>=m_dyn.recovTrigger*0.5){DeactivateLBC();return;}
   MqlTick tk;if(!GetTick(tk))return;double atr=GetATR_M1Norm();if(atr<=0)return;
   int nonLBC=m_port.totalPos-m_port.lbcCount;bool hasMain=(nonLBC>0);
   if(!hasMain){double hMin=MathMax(DistToUSD(atr*Inp_LBCHarvestATR,g_AutoBaseLot),0.02);for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic||PositionGetString(POSITION_SYMBOL)!=_Symbol||StringFind(PositionGetString(POSITION_COMMENT),"LBC_")<0)continue;double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);if(pf>=hMin){ClosePos(t,"LBC_Harvest");double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE),mp=CalcMarginFor001();m_lbc.maxOrdersCalc=(int)MathMax(1,MathMin(Inp_LBCMaxPairs,(int)MathFloor((fm*Inp_LBCMarginPct)/(2.0*MathMax(mp,0.01)))));}}}
   if(m_blockStage>0&&hasMain)return;if(TimeCurrent()-m_lbc.lastOrderTime<Inp_LBCIntervalSec||!SpreadOK())return;
   if(MathMin(m_lbc.buyCount,m_lbc.sellCount)>=m_lbc.maxOrdersCalc)return;
   double gs=atr*Inp_LBCGridATR*(m_inSession?1.2:1.0),lot=NormLot(g_AutoBaseLot);bool nB=false,nS=false;
   if(m_lbc.buyCount==0&&m_lbc.sellCount==0){nB=true;nS=true;}else{if(m_lbc.buyCount<=m_lbc.sellCount&&(m_lbc.lastBuyPrice<=0||MathAbs(tk.ask-m_lbc.lastBuyPrice)>=gs))nB=true;if(m_lbc.sellCount<=m_lbc.buyCount&&(m_lbc.lastSellPrice<=0||MathAbs(tk.bid-m_lbc.lastSellPrice)>=gs))nS=true;}
   if(nB&&MarginOK(lot,ORDER_TYPE_BUY)){string cB="LBC_B"+IntegerToString(m_lbc.buyCount+1);m_isProcessing=true;ulong tB=OpenOrder(ORDER_TYPE_BUY,lot,cB,true);m_isProcessing=false;if(tB>0){int idx=FreeRec();if(idx>=0)InitRec(idx,tB,POSITION_TYPE_BUY,tk.ask,lot,cB,false,false,false,true);m_lbc.buyCount++;m_lbc.lastBuyPrice=tk.ask;m_lbc.lastOrderTime=TimeCurrent();}}
   if(nS&&MarginOK(lot,ORDER_TYPE_SELL)){string cS="LBC_S"+IntegerToString(m_lbc.sellCount+1);m_isProcessing=true;ulong tS=OpenOrder(ORDER_TYPE_SELL,lot,cS,true);m_isProcessing=false;if(tS>0){int idx=FreeRec();if(idx>=0)InitRec(idx,tS,POSITION_TYPE_SELL,tk.bid,lot,cS,false,false,false,true);m_lbc.sellCount++;m_lbc.lastSellPrice=tk.bid;m_lbc.lastOrderTime=TimeCurrent();}}
}

void RunBasketTP(){if(!Inp_UseBasketTP||TimeCurrent()-m_lastBasketCheck<Inp_BasketCheckSec)return;m_lastBasketCheck=TimeCurrent();if(m_port.totalPos<2)return;double dynTP=CalcDynamicBlockTP();if(m_port.totalProfit<dynTP)return;double avgW=(m_cycleWinsCount>0)?m_cycleWinsSum/m_cycleWinsCount:Inp_BasketTPFactor;double target=MathMax(dynTP,avgW*Inp_BasketTPRatio);if(m_port.totalProfit>=target)CloseBlockIfPositive("BasketTP");}
void CheckCycleMaxLoss(){if(!Inp_UseCycleMaxLoss||m_port.totalPos==0)return;if(m_port.totalProfit<=Inp_CycleMaxLossUSD){Print("[BTC] CYCLE MAX LOSS $",NormalizeDouble(m_port.totalProfit,2));if(!m_recoveryActive&&m_blockStage==0){m_recoveryActive=true;m_recoveryOrders=0;}}}
void RunHarvest(){if(m_port.totalPos>1||!Inp_HarvestContinuous||m_isProcessing)return;if(TimeCurrent()-m_lastHarvestTime<Inp_HarvestIntervalSec)return;m_lastHarvestTime=TimeCurrent();if(m_port.totalProfit>=CalcDynamicBlockTP())CloseBlockIfPositive("Harvest_Single");}
bool CheckEquityGuard(){if(!Inp_UseEquityGuard)return false;double eq=AccountInfoDouble(ACCOUNT_EQUITY);double thr=MathMin(Inp_EmergencyLossUSD,-(eq*0.05));if(m_port.totalProfit<=thr&&!m_emergencyMode){Print("[BTC] ALERTA EQUITY $",NormalizeDouble(m_port.totalProfit,2));m_emergencyMode=true;m_isPaused=true;return true;}if(m_port.currentDD>=Inp_MaxDrawdownPct)m_isPaused=true;else if(m_isPaused&&!m_emergencyMode&&!m_dailyLimitHit&&m_port.currentDD<Inp_MaxDrawdownPct*0.5)m_isPaused=false;return false;}

//=================================================================
// STORM FILTER — BTC (ATRmult=2.0 SprMult=2.0)
//=================================================================
double CalcAvgATR(int wb){if(wb<=0||h_ATR==INVALID_HANDLE)return 0;double buf[];ArraySetAsSeries(buf,true);if(CopyBuffer(h_ATR,0,1,wb,buf)<wb)return 0;double s=0;for(int i=0;i<wb;i++)s+=buf[i];return s/wb;}
void RunVolatilityStormFilter()
{
   if(!Inp_UseStormFilter){m_stormActive=false;return;}double aN=GetATR_M1Norm();if(aN<=0)return;
   double aA=CalcAvgATR(Inp_StormATRWindow)/g_TFMult;bool aS=false;if(aA>0){m_stormLastATRRatio=aN/aA;aS=(m_stormLastATRRatio>=Inp_StormATRMult);}
   double sN=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);double sSMax=(double)GetSessionMaxSpread(m_dyn.session);bool sS=(sN>sSMax*Inp_StormSpreadMult);
   bool now=(aS||sS);
   if(now&&!m_stormActive){m_stormActive=true;m_stormDetectedTime=TimeCurrent();Print("[BTC-STORM] ATRx=",NormalizeDouble(m_stormLastATRRatio,2)," SprNow=",NormalizeDouble(sN,0),"pts vs Max=",NormalizeDouble(sSMax,0),"pts");}
   if(m_stormActive){if(TimeCurrent()-m_stormDetectedTime>=Inp_StormCooldownSec){if(!now){m_stormActive=false;Print("[BTC-STORM] Despejado");}else m_stormDetectedTime=TimeCurrent();}}
}

//=================================================================
// CT ENGINE + PRIMARY ENTRY — DYNAMIC MANAGER BTC
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType,double &ctLot,int &ctLevel)
{
   if(m_port.totalPos==0||m_port.totalPos>=Inp_MaxPositionsTotal)return false;if(m_port.totalProfit>=0&&m_port.negativeSum==0)return false;if(m_recoveryActive||m_lbc.active||m_mkt.atr<=0)return false;
   int bC=m_port.buyCount,sC=m_port.sellCount;bool bL=(m_port.buyProfit<-0.05&&bC>0),sL=(m_port.sellProfit<-0.05&&sC>0);bool oB=false,oS=false;
   if(bL&&!sL){if(sC>=Inp_CTMaxSameDir)return false;oS=true;}else if(sL&&!bL){if(bC>=Inp_CTMaxSameDir)return false;oB=true;}
   else if(bL&&sL){if(m_mkt.htfTrend==1&&bC<Inp_CTMaxSameDir)oB=true;else if(m_mkt.htfTrend==-1&&sC<Inp_CTMaxSameDir)oS=true;else if(m_port.buyProfit<m_port.sellProfit&&sC<Inp_CTMaxSameDir)oS=true;else if(bC<Inp_CTMaxSameDir)oB=true;else return false;}else return false;
   ENUM_ORDER_TYPE tt=oB?ORDER_TYPE_BUY:ORDER_TYPE_SELL;if(!ADXAllowsEntry(tt))return false;
   double ctD=(Inp_CTMode==CT_ATR_DISTANCE)?GetATR_M1Norm()*Inp_CTDistanceATR:Inp_CTFixedPoints*_Point;MqlTick t;if(!GetTick(t))return false;
   if(ctD>0){if(oB&&m_lastCTBuyPrice>0&&MathAbs(t.ask-m_lastCTBuyPrice)<ctD)return false;if(oS&&m_lastCTSellPrice>0&&MathAbs(t.bid-m_lastCTSellPrice)<ctD)return false;}
   ctLevel=oB?bC:sC;ctLot=GetEffectiveBaseLot();ctType=tt;return true;
}

void RunCTEngine()
{
   if(m_isProcessing||m_isPaused||m_emergencyMode||m_cycleInPause||g_CircuitBreakerHit)return;
   if(TimeCurrent()-m_lastCTTime<Inp_CTIntervalSec)return;m_lastCTTime=TimeCurrent();
   MqlTick ts;if(!GetTick(ts))return;if(!SpreadOK())return;

   if(m_port.totalPos==0){
      if(!m_sensors.allOK){static datetime lSL=0;if(TimeCurrent()-lSL>=60){Print("[BTC] BLOQUEADO: ",m_sensors.blockReason);lSL=TimeCurrent();}return;}
      if(m_stormActive)return;
      int cd=m_inSession?Inp_PrimaryCooldownSec:Inp_PrimaryCooldownOff;if(TimeCurrent()-m_lastPrimaryTime<cd)return;

      // [DM-BTC] DIRECCIÓN: par=compra, impar=vende (Dynamic Manager)
      // Lógica identica al Pure_Fractal_Pure_v6 adaptada a BTCUSD
      int    dm_dig=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
      int    dm_fac=(int)(ts.ask*MathPow(10,dm_dig))%2;
      ENUM_ORDER_TYPE initType=(dm_fac==0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;

      double lot=GetEffectiveBaseLot();
      m_isProcessing=true;
      ulong ticket=OpenOrder(initType,lot,"Primary_Entry");
      if(ticket>0){
         int idx=FreeRec();if(idx>=0){int pt=(initType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(initType==ORDER_TYPE_BUY)?ts.ask:ts.bid;InitRec(idx,ticket,pt,op,lot,"Primary_Entry",true,false,false,false);}
         m_lastPrimaryDir=(initType==ORDER_TYPE_BUY)?1:-1;m_lastPrimaryTime=TimeCurrent();m_primaryOpenTime=TimeCurrent();
         if(initType==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask;else m_lastCTSellPrice=ts.bid;
         m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
         m_blockStage=1;m_primaryType=initType;m_stageFollowHedge=false;
         m_stage1TriggerAtOpen=m_dyn.stage1Trigger;m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
         m_detangleDetectTime=0;m_detangleActive=false;DeactivateLBC();

         // [DM-BTC] TP individual rapido + SL virtual para diagnostico
         // TP real: precio +/- (ATR_M1norm x 0.8) → busca cierre rapido en positivo
         // SL virtual: precio +/- (ATR_M1norm x 3.0) → solo diagnostico (NO se envia)
         double dm_atr=GetATR_M1Norm();
         double dm_open=(initType==ORDER_TYPE_BUY)?ts.ask:ts.bid;
         double dm_tp=(initType==ORDER_TYPE_BUY)?NormPrice(dm_open+dm_atr*Inp_DM_TPMultiplier):NormPrice(dm_open-dm_atr*Inp_DM_TPMultiplier);
         double dm_vsl=(initType==ORDER_TYPE_BUY)?NormPrice(dm_open-dm_atr*Inp_DM_SLMultiplier):NormPrice(dm_open+dm_atr*Inp_DM_SLMultiplier);
         g_DM_PrimaryTP=dm_tp;g_DM_PrimaryVirtualSL=dm_vsl;g_DM_BEActivated=false;
         // SL=0 (BSE cubre), TP=dm_tp (cierre individual si alcanzado antes del Stage2)
         m_trade.PositionModify(ticket,0.0,dm_tp);
         Print("[DM-BTC] PRIMARY #",ticket," ",(initType==ORDER_TYPE_BUY?"BUY":"SELL"),
               " TP=",NormalizeDouble(dm_tp,_Digits)," VirtSL=",NormalizeDouble(dm_vsl,_Digits),
               " ATR_M1=",NormalizeDouble(dm_atr,4)," DmFactor=",dm_fac,
               " Lot=",lot," TFMult=",NormalizeDouble(g_TFMult,2));
      }
      m_isProcessing=false;return;
   }

   if(m_blockStage>0)return;
   ENUM_ORDER_TYPE ctT;double ctL;int ctLv;
   if(!ShouldOpenCT(ctT,ctL,ctLv)||!MarginOK(ctL,ctT))return;
   string cc="CT_"+(ctT==ORDER_TYPE_BUY?"B":"S")+"_L"+IntegerToString(ctLv+1);
   m_isProcessing=true;ulong ticket=OpenOrder(ctT,ctL,cc);m_isProcessing=false;
   if(ticket>0){int idx=FreeRec();if(idx>=0){int pt=(ctT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(ctT==ORDER_TYPE_BUY)?ts.ask:ts.bid;InitRec(idx,ticket,pt,op,ctL,cc,false,true,false,false);}if(ctT==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask;else m_lastCTSellPrice=ts.bid;}
}

//=================================================================
// NET EXPOSURE HEDGE
//=================================================================
void RunNetExposureHedge()
{
   if(!Inp_UseNetHedge||m_port.totalPos==0||m_isProcessing||g_CircuitBreakerHit)return;
   double nv=NormalizeDouble(m_port.buyVolume-m_port.sellVolume,2);if(MathAbs(nv)<0.005)return;
   double loss=m_port.totalProfit;if(loss>m_dyn.netHedgeTrig1)return;
   if(TimeCurrent()-m_lastNetHedgeTime<Inp_NetHedgeIntervalSec||!SpreadOK())return;
   ENUM_ORDER_TYPE hT=(nv>0)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;double vs=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(vs<=0)vs=0.01;
   if(loss<=m_dyn.netHedgeTrig2&&!m_netHedge2Applied){double pct=m_netHedge1Applied?0.50:0.0;double hL=NormLot(MathAbs(nv)*(1.0-pct));if(hL>0){if(!AntiSymmetricOK(hT,hL))hL=NormLot(hL+vs);if(MarginOK_Hedge(hL,hT)){m_isProcessing=true;ulong t=OpenOrder(hT,hL,"NET_HEDGE_L2",true);m_isProcessing=false;if(t>0){m_netHedge2Applied=m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();MqlTick tk;GetTick(tk);int idx=FreeRec();if(idx>=0){int pt=(hT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(hT==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,t,pt,op,hL,"NET_HEDGE_L2",false,false,true,false);}Print("[BTC] NET HEDGE L2 $",NormalizeDouble(loss,2));}}}return;}
   if(loss<=m_dyn.netHedgeTrig1&&!m_netHedge1Applied){double hL=NormLot(MathAbs(nv)*0.50);if(hL>0){if(!AntiSymmetricOK(hT,hL))hL=NormLot(hL+vs);if(MarginOK_Hedge(hL,hT)){m_isProcessing=true;ulong t=OpenOrder(hT,hL,"NET_HEDGE_L1",true);m_isProcessing=false;if(t>0){m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();MqlTick tk;GetTick(tk);int idx=FreeRec();if(idx>=0){int pt=(hT==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(hT==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,t,pt,op,hL,"NET_HEDGE_L1",false,false,true,false);}Print("[BTC] NET HEDGE L1 $",NormalizeDouble(loss,2));}}}}
}

//=================================================================
// DASHBOARD V9.0-CAPITALGUARD-BTC
//=================================================================
void AQLbl(string n,string txt,int x,int y,color c,int fs=9,bool bold=false){if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_LABEL,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);}ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(0,n,OBJPROP_COLOR,c);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);ObjectSetString(0,n,OBJPROP_FONT,bold?"Consolas Bold":"Consolas");ObjectSetString(0,n,OBJPROP_TEXT,txt);}
void AQBtn(string n,string txt,int x,int y,int w,int h,color bg,color fg=clrWhite){if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_BUTTON,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);ObjectSetString(0,n,OBJPROP_FONT,"Consolas");}ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);ObjectSetString(0,n,OBJPROP_TEXT,txt);ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);ObjectSetInteger(0,n,OBJPROP_COLOR,fg);}
void AQPanel(string n,int x,int y,int w,int h){if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_BACK,false);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);}ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'8,8,12');ObjectSetInteger(0,n,OBJPROP_COLOR,C'70,70,70');ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);}
void DeleteDash(){for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--){string nm=ObjectName(0,i,0,-1);if(StringFind(nm,"AQ90B_")==0)ObjectDelete(0,nm);}}

void UpdateDash()
{
   if(!Inp_ShowDashboard||TimeCurrent()-m_lastDashTime<1)return;m_lastDashTime=TimeCurrent();
   color cG=C'0,220,80',cR=C'220,50,50',cO=C'220,150,30',cY=C'200,200,50',cC=C'50,190,220',cM=C'0,200,150',cGr=C'120,120,130',cBd=C'70,70,70';
   int x=Inp_DashX,y=Inp_DashY,lh=15;
   AQPanel("AQ90B_BG",x-8,y-8,700,55*lh+70);
   AQLbl("AQ90B_H","[ "+VERSION_STR+" ] "+_Symbol+" M"+IntegerToString(PeriodSeconds(_Period)/60)+" | DM ENTRY + RECOVERY | CAPITALGUARD",x,y,cG,10,true);y+=lh+2;
   AQLbl("AQ90B_SL0","────────────────────────────────────────────────────────────────────────────",x,y,cBd,8);y+=lh-4;
   color cgC=g_CircuitBreakerHit?cR:(g_SoftBreakerHit?cO:cG);
   string cgS=g_CircuitBreakerHit?"[ !! CIRCUIT BREAKER DURO — SIN OPERACIONES !! ]":(g_SoftBreakerHit?"[ SOFT BREAKER (DD>"+DoubleToString(Inp_SoftCircuitBreakerPct*100,0)+"%) — ENTRADAS PAUSADAS ]":"[ CAPITAL GUARD BTC: OK ]");
   AQLbl("AQ90B_CGB",cgS,x,y,cgC,10,true);y+=lh+1;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY),ddPct=(g_PeakEquity>0)?(g_PeakEquity-eq)/g_PeakEquity*100.0:0;
   double tV=m_port.buyVolume+m_port.sellVolume,mU=AccountInfoDouble(ACCOUNT_MARGIN),mF=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double mPct=((mU+mF)>0)?mU/(mU+mF)*100.0:0;
   AQLbl("AQ90B_CG1",StringFormat("DD:%.1f%% (hard@%.0f%% soft@%.0f%%) | PeakEq:$%.2f | CurEq:$%.2f | TFMult:%.2f",ddPct,Inp_HardCircuitBreakerPct*100,Inp_SoftCircuitBreakerPct*100,g_PeakEquity,eq,g_TFMult),x,y,(ddPct>Inp_HardCircuitBreakerPct*100)?cR:(ddPct>Inp_SoftCircuitBreakerPct*100)?cO:cC,9);y+=lh-1;
   AQLbl("AQ90B_CG2",StringFormat("TotalVol:%.2f/%.2f(%.0f%%) | MarginUsed:%.0f%% | AutoLot:%.2f | HardCap:%.2f | MaxMargPct:%.0f%%",tV,Inp_MaxTotalVolume,(Inp_MaxTotalVolume>0)?tV/Inp_MaxTotalVolume*100:0,mPct,g_AutoBaseLot,Inp_LotHardCap,Inp_MaxMarginUsagePct*100),x,y,(tV/Inp_MaxTotalVolume>0.8)?cR:(tV/Inp_MaxTotalVolume>0.5)?cO:cG,9);y+=lh-1;
   double dynTP=CalcDynamicBlockTP();
   AQLbl("AQ90B_CG3",StringFormat("DynTP:$%.3f(floor:$%.2f|loss*RRR:$%.3f) | TPRRR:%.2f | RecMax:%d | DM_TP:%.2f VirtSL:%.2f BE:%s",dynTP,Inp_BlockTPTarget,MathAbs(m_port.totalProfit)*Inp_TPRRR,Inp_TPRRR,Inp_RecoveryMaxOrders,g_DM_PrimaryTP,g_DM_PrimaryVirtualSL,g_DM_BEActivated?"ACTIVO":"pend"),x,y,cM,9);y+=lh;
   AQLbl("AQ90B_SL1","── SENSORES BTC (SprP80: ASI=2000 LON=1800 OVL=1700 NY=1700 OFF=2500) ──────",x,y,C'30,60,50',8);y+=lh-3;
   int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);int ssMax=GetSessionMaxSpread(m_dyn.session);
   color spC=cs>ssMax*2?cR:(cs>ssMax?cO:cG);
   AQLbl("AQ90B_SENS1","SPR:"+(m_sensors.spreadOK?"OK("+IntegerToString(cs)+"/"+IntegerToString(ssMax)+"pts)":"ALTO("+IntegerToString(cs)+"pts)")+"  TIME:"+(m_sensors.timeOK?"OK":"W")+"  VOLAT:"+(m_sensors.volatOK?"OK("+DoubleToString(m_sensors.atrRatio,2)+"x)":"STORM")+"  MARG:"+(m_sensors.marginOK?"OK":"W"),x,y,spC,9);y+=lh-1;
   AQLbl("AQ90B_SENS2","AllOK:"+(m_sensors.allOK?"SI":"NO: "+m_sensors.blockReason),x,y,(m_sensors.allOK?cG:cO),9);y+=lh;
   AQLbl("AQ90B_SL2","── V8.0 DYNAMIC + V9.0 TF-ADAPTIVE ─────────────────────────────────────────",x,y,C'20,50,80',8);y+=lh-3;
   color sessC=(m_dyn.session==SESSION_OVERLAP)?cO:(m_dyn.session==SESSION_NY)?cY:(m_dyn.session==SESSION_LONDON)?cG:cGr;
   AQLbl("AQ90B_DYN",StringFormat("SESS:%s F=%.2f VR:%s | TF:M%d mult=%.2f | ATR_M1=%.4f | RecovDist=%.2fxATR",SessionName(m_dyn.session),m_dyn.sessionFactor,VolRegimeName(m_dyn.volRegime),PeriodSeconds(_Period)/60,g_TFMult,GetATR_M1Norm(),m_dyn.recovDistATR),x,y,sessC,9);y+=lh-1;
   AQLbl("AQ90B_DYN2",StringFormat("S1=%.2f S3=%.2f DynTP=+%.3f RecovTrig=%.2f | S2Delay=%ds",m_dyn.stage1Trigger,m_dyn.stage3Trigger,dynTP,m_dyn.recovTrigger,m_dyn.stage2Delay),x,y,cM,9);y+=lh;
   AQLbl("AQ90B_SL3","── BLOCK STAGE + TEMA/KALMAN ────────────────────────────────────────────────",x,y,C'50,50,80',8);y+=lh-3;
   string tL=(m_mkt.trendConfirmed==1)?"BULL":(m_mkt.trendConfirmed==-1)?"BEAR":"NEUT";
   color tC=(m_mkt.trendConfirmed==1)?cG:(m_mkt.trendConfirmed==-1)?cR:cGr;
   int holdNow=(m_primaryOpenTime>0)?(int)(TimeCurrent()-m_primaryOpenTime):0;
   AQLbl("AQ90B_TEMA",StringFormat("TEMA+KAL:%s Trend=%s | Hold=%ds/%ds | TEMAf=%.2f TEMAs=%.2f",Inp_UseTEMAKalman?"ON":"OFF",tL,holdNow,Inp_PrimaryMinHoldSec,m_mkt.temaFast,m_mkt.temaSlow),x,y,tC,9);y+=lh-1;
   string stgNm[]={"IDLE","PRIMARIA_DM","HEDGE/REINF","3RA-DIR","CONSOLIDACION"};int si=MathMax(0,MathMin(m_blockStage,4));
   color stgC=(m_blockStage==0)?cGr:(m_blockStage==1)?cC:(m_blockStage==2)?cO:(m_blockStage==3)?cY:cR;
   AQLbl("AQ90B_STAG",StringFormat("STAGE %d: %s | NetVol=%.3f | Buy=%.2f($%.2f) Sell=%.2f($%.2f) | Detangle:%s",si,stgNm[si],m_port.buyVolume-m_port.sellVolume,m_port.buyVolume,m_port.buyProfit,m_port.sellVolume,m_port.sellProfit,m_detangleActive?"ACTIVO":"ok"),x,y,stgC,9);y+=lh;
   AQLbl("AQ90B_SL4","── BLOQUE ACTIVO ────────────────────────────────────────────────────────────",x,y,C'50,50,80',8);y+=lh-3;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   AQLbl("AQ90B_ACC",StringFormat("Bal:$%.2f Eq:$%.2f LibMarg:$%.2f DD:%.1f%% Streak:%d/%d LotMult:%.2f",bal,eq,mF,ddPct,m_consecutiveLosses,Inp_LossStreakMax,m_lotMultiplier),x,y,cC,9);y+=lh-1;
   double pnl=m_port.totalProfit;
   AQLbl("AQ90B_PNL",StringFormat("PnL:%s%.2f DynTP:+%.3f Falta:$%.2f Pos:%d(main:%d lbc:%d rec:%d) VWAP:%.2f",pnl>=0?"+":"",pnl,dynTP,MathMax(0,dynTP-pnl),m_port.totalPos,m_port.totalPos-m_port.lbcCount,m_port.lbcCount,m_port.recoveryCount,m_port.blockVWAP),x,y,pnl>=0?cG:cR,9);y+=lh-1;
   string recStr=m_recoveryActive?StringFormat("RECOVERY:%d/%d RecDist=%.2fxATR_M1",m_recoveryOrders,Inp_RecoveryMaxOrders,m_dyn.recovDistATR):"Recovery:standby";
   string lbcStr=m_lbc.active?StringFormat(" LBC:B=%d S=%d Cos=$%.2f",m_lbc.buyCount,m_lbc.sellCount,m_lbc.harvestedTotal):" LBC:standby";
   AQLbl("AQ90B_REC",recStr+lbcStr,x,y,m_recoveryActive?cY:cGr,9);y+=lh-1;
   string nhS;color nhC;if(m_netHedge2Applied){nhS="NET HEDGE L2 ACTIVO";nhC=cR;}else if(m_netHedge1Applied){nhS="NET HEDGE L1 | L2@$"+DoubleToString(m_dyn.netHedgeTrig2,2);nhC=cO;}else{nhS="NH: esp L1@$"+DoubleToString(m_dyn.netHedgeTrig1,2)+" L2@$"+DoubleToString(m_dyn.netHedgeTrig2,2);nhC=cGr;}
   AQLbl("AQ90B_NH",nhS,x,y,nhC,9);y+=lh-1;
   string sfS=m_stormActive?StringFormat("TORMENTA BTC:ACTIVO ATRx=%.2f SPRx=%.2f",m_stormLastATRRatio,m_stormLastSprRatio):"TORMENTA BTC:ok ATRx="+DoubleToString(m_stormLastATRRatio,2)+" (thr="+DoubleToString(Inp_StormATRMult,1)+"x)";
   AQLbl("AQ90B_SF",sfS,x,y,m_stormActive?cR:cGr,9);y+=lh;
   AQLbl("AQ90B_SL5","── HISTORIAL ────────────────────────────────────────────────────────────────",x,y,C'50,50,80',8);y+=lh-3;
   int tot=m_totalWins+m_totalLosses;double wr=(tot>0)?(double)m_totalWins/tot*100.0:0;
   AQLbl("AQ90B_HIST",StringFormat("Win:%.1f%%(%d/%d) Expect:$%.3f PnL:$%.2f Mejor:$%.2f Peor:$%.2f Ticks:%d",wr,m_totalWins,tot,CalcExpectancy(),m_totalPnL,m_bestClosed,m_worstClosed,(int)m_tickCount),x,y,CalcExpectancy()>=0?cG:cO,9);y+=lh+4;
   AQBtn("AQ90B_B1",m_isPaused?">> REANUDAR <<":"|| PAUSAR",x,y,160,22,m_isPaused?C'180,130,0':C'0,90,40');
   AQBtn("AQ90B_B2","CERRAR TODAS (MANUAL)",x+170,y,180,22,C'150,20,20');
   ChartRedraw(0);
}

//=================================================================
// FILLING MODE
//=================================================================
ENUM_ORDER_TYPE_FILLING DetectFillingMode(){if((bool)MQLInfoInteger(MQL_TESTER))return ORDER_FILLING_RETURN;long f=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);if((f&SYMBOL_FILLING_FOK)!=0)return ORDER_FILLING_FOK;if((f&SYMBOL_FILLING_IOC)!=0)return ORDER_FILLING_IOC;return ORDER_FILLING_RETURN;}

//=================================================================
// OnInit
//=================================================================
int OnInit()
{
   g_TFMult=(Inp_TFMultOverride>0)?Inp_TFMultOverride:CalcTFMult();
   g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_CircuitBreakerHit=false;g_SoftBreakerHit=false;
   g_DM_PrimaryTP=0.0;g_DM_PrimaryVirtualSL=0.0;g_DM_BEActivated=false;

   Print("==================================================================");
   Print("  "+VERSION_STR);
   Print("  BTCUSD | TF:M",PeriodSeconds(_Period)/60," | TFMult=",NormalizeDouble(g_TFMult,2)," | Magic=",Inp_Magic);
   Print("  [DM] TPmult=",Inp_DM_TPMultiplier,"x | SLvirt=",Inp_DM_SLMultiplier,"x | Trail=",Inp_DM_TrailingPoints,"pts($",NormalizeDouble(Inp_DM_TrailingPoints*0.01,2),") | MinBE=",Inp_DM_MinPointsProfit,"pts($",NormalizeDouble(Inp_DM_MinPointsProfit*0.01,2),")");
   Print("  [BTCUSD] Stage1=$",MathAbs(Inp_Stage1Trigger)," Stage3=$",MathAbs(Inp_Stage3Trigger)," RecovTrig=$",MathAbs(Inp_RecoveryTriggerUSD));
   Print("  [BTCUSD] Storm=",Inp_StormATRMult,"x | VolReg: LOW<",Inp_VolRegimeLowThresh," HIGH>",Inp_VolRegimeHighThresh);
   Print("  [BTCUSD] NetHedge L1@$",MathAbs(Inp_NetHedgeTrigger1USD)," L2@$",MathAbs(Inp_NetHedgeTrigger2USD));
   Print("  [V9.0] HardCB=",NormalizeDouble(Inp_HardCircuitBreakerPct*100,0),"% SoftCB=",NormalizeDouble(Inp_SoftCircuitBreakerPct*100,0),"% MaxVol=",Inp_MaxTotalVolume," RecMax=",Inp_RecoveryMaxOrders);
   Print("==================================================================");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(50);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(DetectFillingMode());

   h_ATR     =iATR(_Symbol,PERIOD_M1,Inp_ATRPeriod);
   h_EMAFast =iMA(_Symbol,PERIOD_M1,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_EMASlow =iMA(_Symbol,PERIOD_M1,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_RSI     =iRSI(_Symbol,PERIOD_M1,Inp_RSIPeriod,PRICE_CLOSE);
   h_MACD    =iMACD(_Symbol,PERIOD_M1,Inp_MACDFast,Inp_MACDSlow,Inp_MACDSig,PRICE_CLOSE);
   if(h_ATR==INVALID_HANDLE||h_EMAFast==INVALID_HANDLE||h_EMASlow==INVALID_HANDLE||h_RSI==INVALID_HANDLE||h_MACD==INVALID_HANDLE){Print("[BTC] ERROR: Indicadores M1 fallaron");return INIT_FAILED;}
   h_ADX       =iADX(_Symbol,PERIOD_M1,Inp_ADXPeriod);
   h_HTFEMAFast=iMA(_Symbol,Inp_HTFTF,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_HTFEMASlow=iMA(_Symbol,Inp_HTFTF,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_EMA200    =iMA(_Symbol,PERIOD_M1,Inp_EMA200Period,0,MODE_EMA,PRICE_CLOSE);
   h_ATRSlow   =iATR(_Symbol,PERIOD_M1,Inp_ATRSlowPeriod);

   for(int i=0;i<MAX_RECORDS;i++)ZeroMemory(m_rec[i]);
   ZeroMemory(m_lbc);ZeroMemory(m_sensors);ZeroMemory(m_mkt);ZeroMemory(m_dyn);
   m_temaF_init=m_temaS_init=m_kalF_init=m_kalS_init=false;
   m_blockStage=0;m_stageFollowHedge=false;m_primaryOpenTime=0;m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;m_detangleDetectTime=0;m_detangleActive=false;

   m_dyn.stage1Trigger=Inp_Stage1Trigger;m_dyn.stage3Trigger=Inp_Stage3Trigger;m_dyn.blockTP=Inp_BlockTPTarget;m_dyn.recovTrigger=Inp_RecoveryTriggerUSD;
   m_dyn.stage2Delay=Inp_Stage2DelayLondon;m_dyn.recovDistATR=Inp_RecovDistNormal;m_dyn.netHedgeTrig1=Inp_NetHedgeTrigger1USD;m_dyn.netHedgeTrig2=Inp_NetHedgeTrigger2USD;
   m_dyn.sessionFactor=1.0;m_dyn.session=SESSION_OFF;m_dyn.volRegime=VOL_NORMAL;m_dyn.atr2usd=0;

   m_initialBalance=AccountInfoDouble(ACCOUNT_BALANCE);m_bestEquity=AccountInfoDouble(ACCOUNT_EQUITY);m_dailyBalance=m_initialBalance;m_lastDailyReset=TimeCurrent();
   CalibrateMarginPerLot();RecalcAutoBaseLot();CalcBrokerTimeWindow();SyncPositions();UpdatePortfolio();

   if(m_port.totalPos>0)Print("[BTC] Posiciones existentes (",m_port.totalPos,") TotalVol=",NormalizeDouble(m_port.buyVolume+m_port.sellVolume,3));
   if(m_port.lbcCount>0){m_lbc.active=true;m_lbc.activatedTime=TimeCurrent();m_lbc.maxOrdersCalc=Inp_LBCMaxPairs;}
   if(Inp_ShowDashboard){DeleteDash();UpdateDash();}
   Print("[BTC] LISTO | Bal=$",m_initialBalance," | AutoLot=",g_AutoBaseLot," | Marg0.01=$",NormalizeDouble(CalcMarginFor001(),2)," | TFMult=",NormalizeDouble(g_TFMult,2));
   return INIT_SUCCEEDED;
}

//=================================================================
// OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   Print("[BTC] DETENIDO | PnL=$",NormalizeDouble(m_totalPnL,2)," | Trades=",m_tradesClosed," | CB_Hard=",g_CircuitBreakerHit?" ACTIVO":"no");
   IndicatorRelease(h_ATR);IndicatorRelease(h_EMAFast);IndicatorRelease(h_EMASlow);IndicatorRelease(h_RSI);IndicatorRelease(h_MACD);
   if(h_ADX!=INVALID_HANDLE)IndicatorRelease(h_ADX);if(h_HTFEMAFast!=INVALID_HANDLE)IndicatorRelease(h_HTFEMAFast);if(h_HTFEMASlow!=INVALID_HANDLE)IndicatorRelease(h_HTFEMASlow);if(h_EMA200!=INVALID_HANDLE)IndicatorRelease(h_EMA200);if(h_ATRSlow!=INVALID_HANDLE)IndicatorRelease(h_ATRSlow);
   if(Inp_ShowDashboard)DeleteDash();
}

//=================================================================
// OnTick
//=================================================================
void OnTick()
{
   m_tickCount++;
   // [V9.0] CIRCUIT BREAKER SIEMPRE PRIMERO
   if(HardEquityCircuitBreaker()){UpdatePortfolio();if(Inp_ShowDashboard)UpdateDash();return;}
   UpdateMarket();UpdateKalman();UpdatePortfolio();
   RunNetExposureHedge();CheckEquityGuard();
   m_inSession=IsInMainSession();ResetDailyIfNeeded();bool dP=DailyLimitReached();
   UpdateSensors();RunVolatilityStormFilter();

   if(m_cycleInPause){
      if(TimeCurrent()-m_cycleResetTime>=Inp_CyclePauseSec){
         m_cycleInPause=false;m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
         m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
         m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
         g_DM_PrimaryTP=0.0;g_DM_PrimaryVirtualSL=0.0;g_DM_BEActivated=false;DeactivateLBC();
      }else{
         UpdatePortfolio();double dynTP=CalcDynamicBlockTP();
         if(m_port.totalPos>0&&m_port.totalProfit>=dynTP)CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard)UpdateDash();return;
      }
   }

   if(m_emergencyMode){
      static datetime emgT=0;UpdatePortfolio();double dynTP=CalcDynamicBlockTP();
      if(m_port.totalPos>0&&m_port.totalProfit>=dynTP){CloseBlockIfPositive("Emergency_TP");m_emergencyMode=false;emgT=0;}
      if(m_port.totalPos==0&&emgT==0)emgT=TimeCurrent();
      if(emgT>0&&TimeCurrent()-emgT>=Inp_EmergencyCooldown){m_emergencyMode=false;emgT=0;}
      if(m_blockStage>0)RunBlockStageEngine();else RunRecoveryEngine();
      RunLBCEngine();if(Inp_ShowDashboard)UpdateDash();return;
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
void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{
   if(id==CHARTEVENT_OBJECT_CLICK){
      if(sp=="AQ90B_B1"){
         m_isPaused=!m_isPaused;
         if(!m_isPaused){
            m_emergencyMode=false;m_dailyLimitHit=false;g_CircuitBreakerHit=false;g_SoftBreakerHit=false;
            g_PeakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
            m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
            m_netHedge1Applied=m_netHedge2Applied=false;
            m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
            m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
            g_DM_PrimaryTP=0.0;g_DM_PrimaryVirtualSL=0.0;g_DM_BEActivated=false;
            DeactivateLBC();Print("[BTC] REANUDADO | PeakEq=$",NormalizeDouble(g_PeakEquity,2));
         }else Print("[BTC] PAUSADO MANUALMENTE");
      }
      if(sp=="AQ90B_B2"){
         Print("[BTC] CIERRE MANUAL TOTAL...");int closed=0;m_isProcessing=true;
         for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=Inp_Magic)continue;if(ClosePos(t,"Manual"))closed++;}
         if(Inp_RescueAllTrades){for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)==Inp_Magic)continue;if(CloseRescuePos(t,"Manual_Rescue"))closed++;}}
         m_isProcessing=false;
         m_lastCTBuyPrice=m_lastCTSellPrice=0;m_consecutiveLosses=0;m_lotMultiplier=1.0;m_cycleInPause=false;
         m_recoveryActive=false;m_recoveryOrders=0;m_lastPrimaryDir=0;m_lastPrimaryLost=false;
         m_netHedge1Applied=m_netHedge2Applied=false;m_blockStage=0;m_stageFollowHedge=false;
         m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
         g_DM_PrimaryTP=0.0;g_DM_PrimaryVirtualSL=0.0;g_DM_BEActivated=false;DeactivateLBC();
         Print("[BTC] CIERRE MANUAL: ",closed," posiciones");
      }
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+
