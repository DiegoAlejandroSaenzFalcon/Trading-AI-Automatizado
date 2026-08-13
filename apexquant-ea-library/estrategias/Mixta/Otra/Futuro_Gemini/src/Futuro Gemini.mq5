//+------------------------------------------------------------------+
//|   APEXQUANT - V7.9.2-ASYMMETRIC-XAUUSD                            |
//|   "DIRECTIONAL RECOVERY — ANTI-SYMMETRIC ENGINE"                 |
//|                                                                  |
//| BASE: V7.9.1-ASYMMETRIC-BTC (rama BTCUSD del linaje APEXQUANT)   |
//| ASSET TARGET: XAUUSD (retargeting + recalibracion con datos)     |
//|                                                                  |
//| RE-ADAPTACION A XAUUSD (desde la rama BTC):                      |
//|   - [XAU-1] Restaurado el cierre de fin de semana (Sabado        |
//|     completo + Domingo antes de reapertura + tramo final del     |
//|     Viernes) via IsMarketClosed(), ausente en la rama BTC 24/7.  |
//|   - [XAU-2] Spread y todos los umbrales en USD recalibrados      |
//|     con barras M5 reales (XAUUSDm, Ene-Jul 2026, 40366 velas).  |
//|     Symbol Digits=3/Point=0.001 en este feed -> el spread real   |
//|     opera 160-600 puntos (mediana 260), muy distinto de los      |
//|     2500 pts heredados de BTC o del "35" original documentado    |
//|     (esa cifra corresponde a otra convencion de digitos).        |
//|   - [XAU-3] Factores de sesion recalculados con ATR14 real por   |
//|     hora de servidor: la sesion "Off" NO es la mas tranquila     |
//|     (hay un repunte tras la reapertura diaria) y "Overlap" es    |
//|     la unica que ya coincidia con el supuesto original.          |
//|   - [XAU-4] Restaurado MaxSafeLot(): tope dinamico de lote por   |
//|     orden ligado a margen libre, presente en el fix historico de |
//|     "jaula simetrica" de la rama XAUUSD pero ausente en esta     |
//|     rama BTC.                                                    |
//|   - [HOTFIX] AntiSymmetric Guard: referencia corregida a         |
//|     SYMBOL_VOLUME_STEP (antes VOLUME_MIN) para operar en el      |
//|     espacio real de paso de lote del broker.                    |
//|                                                                  |
//| Ver comentarios "[CALIBRACION]" junto a cada input recalibrado   |
//| para el razonamiento y la cifra de origen en los datos.          |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V7.9.2-XAU | XAUUSD Anti-Symmetric Engine"
#property version   "7.92"
#property strict
#property description "XAUUSD | V7.9.2-ASYMMETRIC | Directional Recovery | Anti-Symmetric Guard"

#define VERSION_STR   "APEXQUANT_V7.9.2-XAU"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS   80

enum ENUM_CT_MODE { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };

enum ENUM_SESSION_STATE {
   SESSION_ASIAN   = 0,
   SESSION_LONDON  = 1,
   SESSION_OVERLAP = 2,
   SESSION_NY      = 3,
   SESSION_OFF     = 4
};

enum ENUM_VOL_REGIME {
   VOL_LOW    = 0,
   VOL_NORMAL = 1,
   VOL_HIGH   = 2
};

//=================================================================
//  PARAMETROS
//=================================================================

// ================================================================
//  [V7.9] BREATHING ROOM + ASYMMETRIC RECOVERY
// ================================================================
input group "=== [V7.9] BREATHING ROOM ==="
// Segundos minimos que debe vivir la primaria antes de que Stage1
// pueda activar el hedge. Permite que el precio respire.
input int    Inp_PrimaryMinHoldSec   = 120;
// Multiplicador del trigger normal para el override de emergencia
input double Inp_StageEmergMult      = 2.0;

input group "=== [V7.9] ASYMMETRIC HEDGE ==="
// Ratio del lote del hedge vs lote de la primaria en Stage1.
// 0.5 = hedge con mitad del lote → mantiene sesgo neto hacia primaria.
input double Inp_HedgeRatio          = 0.50;
// Si TEMA+Kalman confirma tendencia EN FAVOR de la primaria durante
// Stage1, reforzar primaria en lugar de abrir hedge opuesto.
input bool   Inp_UseDirectionalStage = true;
// Lote del refuerzo de primaria (como multiplo del lote base)
input double Inp_ReinforceLotMult    = 2.0;

input group "=== [V7.9] DETANGLE ENGINE ==="
// Segundos que el bloque debe estar atascado (net ~0) antes de
// activar el detangle (cerrar posicion mas perdedora para romper simetria)
input int    Inp_DetangleSec         = 180;
// Umbral de volumen neto para considerar el bloque "simetrico"
input double Inp_DetangleNetThresh   = 0.005;
// PnL minimo de perdida para activar detangle (negativo)
input double Inp_DetangleMinLoss     = -1.20; // [CALIBRACION] ~0.5x mediana ATR(M1) XAUUSD

// ================================================================
//  [V7.8] DYNAMIC THRESHOLD ENGINE
// ================================================================
input group "=== [V7.8] DYNAMIC THRESHOLD ENGINE ==="
input double Inp_DynStage1Mult       = 1.20;
input double Inp_DynStage3Mult       = 2.50;
input double Inp_DynTPMult           = 0.80;
input double Inp_DynRecovMult        = 0.60;
input double Inp_DynMaxStage1USD     = 5.00; // [CALIBRACION] ~P90 ATR(M1) XAUUSD (dataset Ene-Jul26)
input double Inp_DynMaxStage3USD     = 9.00; // [CALIBRACION] ~P95-P99 ATR(M1), cubre regimen Feb-Mar26
input double Inp_DynMaxTPUSD         = 3.50; // [CALIBRACION] techo de TP dinamico acorde a ATR real

// ================================================================
//  [V7.8] SESSION ADAPTIVE FACTORS
// ================================================================
input group "=== [V7.8] SESSION FACTORS (XAUUSD) ==="
// [CALIBRACION] Recalculados con ATR14(M5) real por hora de servidor
// (dataset XAUUSDm Ene-Jul26). Overlap ya coincidia con lo asumido;
// las demas sesiones estaban mal calibradas -- en particular "Off"
// NO es la mas tranquila (repunte de volatilidad tras la reapertura
// diaria en horas 0-1 servidor). Verifica Inp_GMTOffset en tu bróker:
// estos factores se calibraron directamente sobre la hora de servidor
// del feed, no sobre GMT real.
input double Inp_SessFactorAsian     = 0.90;
input double Inp_SessFactorLondon    = 0.90;
input double Inp_SessFactorOverlap   = 1.20;
input double Inp_SessFactorNY        = 1.00;
input double Inp_SessFactorOff       = 0.95;

input group "=== [V7.8] STAGE2 DELAY POR SESION ==="
input int    Inp_Stage2DelayAsian    = 20;
input int    Inp_Stage2DelayLondon   = 6;
input int    Inp_Stage2DelayOverlap  = 3;
input int    Inp_Stage2DelayNY       = 5;

input group "=== [V7.8] RECOVERY DISTANCE ADAPTATIVO ==="
input double Inp_RecovDistLow        = 0.30;
input double Inp_RecovDistNormal     = 0.50;
input double Inp_RecovDistHigh       = 0.85;

input group "=== [V7.7] TEMA + KALMAN TREND ENGINE ==="
input bool   Inp_UseTEMAKalman       = true;
input int    Inp_TEMAFastPeriod      = 21;
input int    Inp_TEMASlowPeriod      = 55;
input double Inp_KalmanQ             = 0.0001;
input double Inp_KalmanR             = 0.005;

input group "=== [V7.7] BLOCK STAGE ENGINE (FLOORS) ==="
input double Inp_Stage1Trigger       = -0.90; // [CALIBRACION] piso; el motor dinamico opera por encima en la mayoria de regimenes
input double Inp_Stage3Trigger       = -1.80; // [CALIBRACION] piso equivalente a ~2x Stage1
input int    Inp_Stage2DelaySec      = 5;

input group "=== [V7.6C] VOLATILITY STORM FILTER ==="
input bool   Inp_UseStormFilter       = true;
input int    Inp_StormATRWindow       = 20;
input double Inp_StormATRMult         = 2.0;
input double Inp_StormSpreadMult      = 2.5;
input int    Inp_StormSpreadWindow    = 30;
input int    Inp_StormCooldownSec     = 30;

input group "=== [V7.6B] NET EXPOSURE HEDGE ==="
input bool   Inp_UseNetHedge          = true;
input double Inp_NetHedgeTrigger1USD  = -2.50; // [CALIBRACION] escala real XAUUSD
input double Inp_NetHedgeTrigger2USD  = -4.50; // [CALIBRACION] escala real XAUUSD
input double Inp_NetHedgeMult1        = 2.0;
input double Inp_NetHedgeMult2        = 3.5;
input int    Inp_NetHedgeIntervalSec  = 5;

input group "=== CONFIGURACION PRINCIPAL ==="
input long   Inp_Magic               = 1111;
input int    Inp_MaxPositionsTotal   = 8;
input double Inp_LotBase             = 0.01;
input double Inp_LotMaximum          = 0.05;
input double Inp_RiskPerTradePct     = 0.01;
input bool   Inp_UseDynamicLot       = true;
input double Inp_CTMinBalanceUSD     = 5.0;
input double Inp_MinFreeMarginPct    = 0.02;
// [XAU-4] Restaura el tope de seguridad de lote presente en el fix historico
// de "jaula simetrica" de la rama XAUUSD (ausente en la rama BTC). Ninguna
// orden individual (hedge/refuerzo/recovery/directional) puede consumir mas
// que este % del margen libre, ademas del tope estatico Inp_LotMaximum.
input double Inp_MaxSafeLotMarginPct = 0.15;

input group "=== CIERRE DEL BLOQUE — FLOOR MINIMO ==="
input double Inp_BlockTPTarget       = 1.00; // [CALIBRACION] floor TP acorde a ATR real XAUUSD
input double Inp_TP_ATR              = 2.5;
input double Inp_SL_ATR              = 1.2;
input double Inp_OffSessionTP_ATR    = 2.2;
input double Inp_OffSessionSL_ATR    = 1.0;

input group "=== RECOVERY ENGINE (fallback) ==="
input double Inp_RecoveryTriggerUSD  = -0.60; // [CALIBRACION] escala real XAUUSD
input double Inp_RecoveryMinDistATR  = 0.5;
input double Inp_RecoveryMoveATR     = 0.5;
input double Inp_RecoveryMinLotMult  = 2.0;
input int    Inp_RecoveryMaxOrders   = 3;
input int    Inp_RecoveryMaxOrdersTrend = 9;
input int    Inp_RecoveryIntervalSec = 3;

input group "=== LBC: CONTINGENCIA BALANCE BAJO ==="
input int    Inp_LBCMaxPairs         = 4;
input double Inp_LBCGridATR          = 0.30;
input double Inp_LBCHarvestATR       = 0.15;
input int    Inp_LBCIntervalSec      = 8;
input double Inp_LBCMarginPct        = 0.55;

input group "=== COUNTER-TRADE ENGINE ==="
input ENUM_CT_MODE Inp_CTMode        = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR       = 1.2;
input int    Inp_CTFixedPoints       = 2500; // [CALIBRACION] ~1.2xATR en puntos (Point=0.001, modo alterno no-default)
input int    Inp_CTIntervalSec       = 10;
input int    Inp_CTMaxSameDir        = 3;
input int    Inp_PrimaryCooldownSec  = 10;
input int    Inp_PrimaryCooldownOff  = 20;
input double Inp_CTMaxSpreadPoints   = 320;  // [AUDITORIA] No referenciado en la logica actual (revisa si tu build lo usa antes de borrarlo)
input double Inp_CTMaxSpreadOff      = 380;  // [CALIBRACION] ~techo superior de spread observado fuera de sesion principal

input group "=== SESIONES ==="
input int    Inp_GMTOffset           = 0;
input int    Inp_LondonOpen          = 7;
input int    Inp_LondonClose         = 17;
input int    Inp_NYOpen              = 13;
input int    Inp_NYClose             = 22;
input double Inp_OffSessionLotFactor = 1.0;
// [XAU-1] Cierre de fin de semana (ausente en la rama BTC 24/7).
// Horas en tiempo de SERVIDOR (mismo reloj que ve TimeCurrent()).
// Dataset real: cierre Viernes ~20:55-21:55 (antes en feriados EE.UU.
// como Juneteenth/4-Jul), reapertura Domingo ~22:00-23:05.
input int    Inp_WeekendCloseHour    = 21; // Desde esta hora el Viernes, se considera cierre
input int    Inp_WeekendReopenHour   = 22; // Antes de esta hora el Domingo, mercado cerrado

input group "=== BASKET TP ==="
input bool   Inp_UseBasketTP         = true;
input double Inp_BasketTPFactor      = 0.60;
input double Inp_BasketTPRatio       = 1.5;
input int    Inp_BasketCheckSec      = 3;

input group "=== HARVEST ==="
input double Inp_HarvestMinUSD       = 0.80;
input double Inp_HarvestATRMult      = 0.20;
input bool   Inp_HarvestContinuous   = true;
input int    Inp_HarvestIntervalSec  = 3;

input group "=== CYCLE CONTROL ==="
input bool   Inp_UseCycleMaxLoss     = true;
input double Inp_CycleMaxLossUSD     = -100.00;
input int    Inp_CyclePauseSec       = 30;

input group "=== ADX + HTF ==="
input bool   Inp_UseADX              = true;
input int    Inp_ADXPeriod           = 14;
input double Inp_ADXTrendLevel       = 30.0;
input double Inp_ADXTrendLevelOff    = 22.0;
input bool   Inp_UseHTF              = true;
input ENUM_TIMEFRAMES Inp_HTFTF      = PERIOD_M5;

input group "=== PROTECCION DIARIA ==="
input bool   Inp_UseDailyLimit       = true;
input double Inp_DailyLossUSD        = -40.0;
input double Inp_DailyLossPct        = 0.30; // [BUG FIX] estaba en 30.0; DailyLimitReached() lo usa como fraccion directa (bal*Pct), igual que Inp_MaxDrawdownPct. Con 30.0 este limite porcentual nunca era el vinculante (quedaba inerte frente al tope fijo de $40)
input int    Inp_LossStreakMax       = 1;
input double Inp_LossStreakReduce    = 0.70;

input group "=== EQUITY GUARD ==="
input bool   Inp_UseEquityGuard      = true;
input double Inp_EmergencyLossUSD    = -7.00; // [CALIBRACION] escala real XAUUSD
input double Inp_MaxDrawdownPct      = 0.45; // [MEJORA] 100% (=1.0) equivalia a nunca disparar; ajustado a 45% real. currentDD esta en fraccion (0-1), no en %
input int    Inp_EmergencyCooldown   = 10;

input group "=== INDICADORES BASE ==="
input int    Inp_ATRPeriod           = 14;
input int    Inp_EMAFast             = 21;
input int    Inp_EMASlow             = 55;
input int    Inp_RSIPeriod           = 7;
input int    Inp_MACDFast            = 12;
input int    Inp_MACDSlow            = 26;
input int    Inp_MACDSig             = 9;

input group "=== CONTROL VISUAL ==="
input int    Inp_MaxSpread            = 300; // [CALIBRACION] spread real: mediana 260, P90 280, P95 360 pts (Digits=3)
input bool   Inp_ShowDashboard       = true;
input int    Inp_DashX               = 12;
input int    Inp_DashY               = 28;

input group "=== [V7.5] RESCATE UNIVERSAL ==="
input bool   Inp_RescueAllTrades     = true;

input group "=== [V7.5] SENSOR HORARIO GMT ==="
input bool   Inp_UseTimeFilter       = false;
input int    Inp_UserGMT             = -5;
input int    Inp_BrokerGMT           = 2;
input string Inp_StartTime           = "00:00"; // Filtro horario opcional (Inp_UseTimeFilter), OFF por defecto
input string Inp_EndTime             = "23:59"; // El cierre real de fin de semana lo maneja IsMarketClosed()

input group "=== [V7.5] SENSOR TENDENCIA ==="
input bool   Inp_UseTrendFilter200   = true;
input int    Inp_EMA200Period        = 200;

input group "=== [V7.5] SENSOR VOLATILIDAD ==="
input bool   Inp_UseVolatFilter      = true;
input int    Inp_ATRSlowPeriod       = 100;
input double Inp_ATRRatioMax         = 2.5;

input group "=== [V7.5] SENSOR MARGIN GUARD ==="
input bool   Inp_UseMarginGuard      = false;
input int    Inp_MarginGuardLevels   = 3;

//=================================================================
//  ESTRUCTURAS
//=================================================================
struct PosRecord {
   ulong    ticket;
   int      posType;
   double   openPrice;
   double   volume;
   double   netProfit;
   datetime openTime;
   string   comment;
   bool     isPrimary;
   bool     isCounter;
   bool     isRecovery;
   bool     isLBC;
   double   peakProfit;
   double   kX, kP, kK;
   bool     kInit;
};

struct Portfolio {
   int    totalPos;
   int    buyCount, sellCount;
   double buyProfit, sellProfit;
   double totalProfit;
   double positiveSum, negativeSum;
   ulong  worstTicket;
   double worstProfit;
   int    ctCount;
   int    recoveryCount;
   int    lbcCount;
   double currentDD;
   double blockVWAP;
   int    blockDir;
   int    rescueCount;
   double rescueProfit;
   double buyVolume;
   double sellVolume;
};

struct MarketSnap {
   double bid, ask, atr, emaFast, emaSlow, rsi, macdMain, macdSig, adx, spread;
   int    htfTrend;
   bool   isBullish, isBearish;
   double atrSlow;
   double ema200;
   double temaFast, temaSlow;
   double kalmanFast, kalmanSlow;
   int    trendConfirmed;
};

struct LBCState {
   bool     active;
   int      buyCount, sellCount;
   double   lastBuyPrice, lastSellPrice;
   datetime lastOrderTime;
   double   harvestedTotal;
   int      harvestCount;
   int      maxOrdersCalc;
   datetime activatedTime;
};

struct SensorState {
   bool   timeOK, spreadOK, trendBull, volatOK, marginOK, marketOpen, allOK;
   string blockReason;
   double atrRatio;
   int    brokerStartMin, brokerEndMin;
};

struct DynThresholds {
   double stage1Trigger;
   double stage3Trigger;
   double blockTP;
   double recovTrigger;
   double recovDistATR;
   int    stage2Delay;
   double netHedgeTrig1;
   double netHedgeTrig2;
   double sessionFactor;
   ENUM_SESSION_STATE session;
   ENUM_VOL_REGIME    volRegime;
   double atr2usd;
};

//=================================================================
//  HANDLES
//=================================================================
int h_ATR, h_EMAFast, h_EMASlow, h_RSI, h_MACD;
int h_ADX=INVALID_HANDLE, h_HTFEMAFast=INVALID_HANDLE, h_HTFEMASlow=INVALID_HANDLE;
int h_ATRSlow=INVALID_HANDLE, h_EMA200=INVALID_HANDLE;

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade      m_trade;
PosRecord   m_rec[MAX_RECORDS];
Portfolio   m_port;
MarketSnap  m_mkt;
LBCState    m_lbc;
SensorState m_sensors;
DynThresholds m_dyn;

double   m_initialBalance=0, m_bestEquity=0;
bool     m_isPaused=false, m_emergencyMode=false, m_dailyLimitHit=false, m_inSession=false;
bool     m_recoveryActive=false;
int      m_recoveryOrders=0;
bool     m_recoveryTrendHedge=false;

bool     m_netHedge1Applied=false, m_netHedge2Applied=false;
datetime m_lastNetHedgeTime=0;

bool     m_stormActive=false;
datetime m_stormDetectedTime=0;
double   m_stormLastATRRatio=0.0, m_stormLastSprRatio=0.0;

double   m_cycleWinsSum=0;
int      m_cycleWinsCount=0;
double   m_cycleLossSum=0;
bool     m_cycleInPause=false;
datetime m_cycleResetTime=0;

int      m_consecutiveLosses=0;
double   m_lotMultiplier=1.0;
double   m_dailyBalance=0;
datetime m_lastDailyReset=0;

int      m_lastPrimaryDir=0;
datetime m_lastPrimaryTime=0;
bool     m_lastPrimaryLost=false;

double   m_lastCTBuyPrice=0, m_lastCTSellPrice=0;
datetime m_lastCTTime=0, m_lastRecoveryTime=0, m_lastBasketCheck=0;
datetime m_lastHarvestTime=0, m_lastDashTime=0, m_lastCleanupTime=0;

double   m_totalPnL=0;
int      m_tradesOpened=0, m_tradesClosed=0;
double   m_bestClosed=0, m_worstClosed=0;
int      m_totalWins=0, m_totalLosses=0;
double   m_sumWins=0, m_sumLosses=0;

long     m_tickCount=0;
bool     m_isProcessing=false;

double   m_losingPosOpenPrice=0;
int      m_losingPosType=-1;

// TEMA state
double   m_temaF_e1=0,m_temaF_e2=0,m_temaF_e3=0; bool m_temaF_init=false;
double   m_temaS_e1=0,m_temaS_e2=0,m_temaS_e3=0; bool m_temaS_init=false;
double   m_kalF_x=0,m_kalF_p=1.0; bool m_kalF_init=false;
double   m_kalS_x=0,m_kalS_p=1.0; bool m_kalS_init=false;

// Block Stage Engine
int              m_blockStage=0;
ENUM_ORDER_TYPE  m_primaryType=ORDER_TYPE_BUY;
datetime         m_stage2Time=0;
bool             m_stageFollowHedge=false;
double           m_stage1TriggerAtOpen=0.0;
double           m_stage3TriggerAtOpen=0.0;

// V7.9: Detangle state
datetime         m_detangleDetectTime=0;   
bool             m_detangleActive=false;   

// V7.9: Track primary open time
datetime         m_primaryOpenTime=0;

//=================================================================
//  V7.8: DYNAMIC THRESHOLD ENGINE
//=================================================================
double ATR2USD_Lot(double atrMult, double lot)
{
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0||m_mkt.atr<=0||lot<=0) return 0;
   return NormalizeDouble((m_mkt.atr*atrMult/ts)*tv*lot,4);
}
double ATR2USD(double atrMult=1.0) { return ATR2USD_Lot(atrMult,Inp_LotBase); }

// [XAU-1] XAUUSD no cotiza 24/7 como BTC: Sabado completo cerrado,
// Domingo cerrado hasta la reapertura, y tramo final del Viernes
// tratado como cierre para no abrir nuevas primarias justo antes
// del gap de fin de semana. MQL5 day_of_week: 0=Domingo..6=Sabado.
bool IsMarketClosed()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(dt.day_of_week==6) return true;                                  // Sabado
   if(dt.day_of_week==0&&dt.hour<Inp_WeekendReopenHour) return true;    // Domingo antes de reapertura
   if(dt.day_of_week==5&&dt.hour>=Inp_WeekendCloseHour) return true;    // Viernes tras el cierre
   return false;
}

ENUM_SESSION_STATE GetCurrentSession()
{
   if(IsMarketClosed()) return SESSION_OFF;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int gmtH=(dt.hour-Inp_GMTOffset+24)%24;
   if(gmtH>=12&&gmtH<17) return SESSION_OVERLAP;
   if(gmtH>=7 &&gmtH<12) return SESSION_LONDON;
   if(gmtH>=17&&gmtH<22) return SESSION_NY;
   if(gmtH>=2 &&gmtH<7)  return SESSION_ASIAN;
   return SESSION_OFF;
}

double GetSessionFactor(ENUM_SESSION_STATE s)
{
   switch(s){
      case SESSION_ASIAN:   return Inp_SessFactorAsian;
      case SESSION_LONDON:  return Inp_SessFactorLondon;
      case SESSION_OVERLAP: return Inp_SessFactorOverlap;
      case SESSION_NY:      return Inp_SessFactorNY;
      default:              return Inp_SessFactorOff;
   }
}

ENUM_VOL_REGIME GetVolatilityRegime()
{
   if(m_mkt.atrSlow<=0||m_mkt.atr<=0) return VOL_NORMAL;
   double r=m_mkt.atr/m_mkt.atrSlow;
   if(r>1.50) return VOL_HIGH;
   if(r<0.65) return VOL_LOW;
   return VOL_NORMAL;
}

string VolRegimeName(ENUM_VOL_REGIME r)
{ switch(r){case VOL_LOW:return "LOW";case VOL_HIGH:return "HIGH";default:return "NORMAL";} }

string SessionName(ENUM_SESSION_STATE s)
{ switch(s){case SESSION_ASIAN:return"ASIAN";case SESSION_LONDON:return"LONDON";
  case SESSION_OVERLAP:return"OVERLAP";case SESSION_NY:return"NY";default:return"OFF";} }

int GetStage2Delay(ENUM_SESSION_STATE s)
{
   switch(s){
      case SESSION_ASIAN:   return Inp_Stage2DelayAsian;
      case SESSION_LONDON:  return Inp_Stage2DelayLondon;
      case SESSION_OVERLAP: return Inp_Stage2DelayOverlap;
      case SESSION_NY:      return Inp_Stage2DelayNY;
      default:              return Inp_Stage2DelayAsian;
   }
}

double GetRecovDistATR(ENUM_VOL_REGIME r)
{
   switch(r){case VOL_LOW:return Inp_RecovDistLow;case VOL_HIGH:return Inp_RecovDistHigh;
   default:return Inp_RecovDistNormal;}
}

void UpdateDynamicThresholds()
{
   m_dyn.session       = GetCurrentSession();
   m_dyn.volRegime     = GetVolatilityRegime();
   m_dyn.sessionFactor = GetSessionFactor(m_dyn.session);
   m_dyn.atr2usd       = ATR2USD(1.0);
   double atr          = m_dyn.atr2usd;

   if(atr<=0.01){
      m_dyn.stage1Trigger=Inp_Stage1Trigger; m_dyn.stage3Trigger=Inp_Stage3Trigger;
      m_dyn.blockTP=Inp_BlockTPTarget;       m_dyn.recovTrigger=Inp_RecoveryTriggerUSD;
      m_dyn.netHedgeTrig1=Inp_NetHedgeTrigger1USD; m_dyn.netHedgeTrig2=Inp_NetHedgeTrigger2USD;
   } else {
      double sf=m_dyn.sessionFactor;
      double s1Raw=-(atr*Inp_DynStage1Mult*sf); s1Raw=MathMax(s1Raw,-Inp_DynMaxStage1USD);
      m_dyn.stage1Trigger=MathMin(s1Raw,Inp_Stage1Trigger);
      double s3Raw=-(atr*Inp_DynStage3Mult*sf); s3Raw=MathMax(s3Raw,-Inp_DynMaxStage3USD);
      m_dyn.stage3Trigger=MathMin(s3Raw,Inp_Stage3Trigger);
      double tpRaw=atr*Inp_DynTPMult*sf; tpRaw=MathMin(tpRaw,Inp_DynMaxTPUSD);
      m_dyn.blockTP=MathMax(tpRaw,Inp_BlockTPTarget);
      m_dyn.recovTrigger=MathMin(-(atr*Inp_DynRecovMult*sf),Inp_RecoveryTriggerUSD);
      m_dyn.netHedgeTrig1=MathMin(-(atr*Inp_NetHedgeMult1),Inp_NetHedgeTrigger1USD);
      m_dyn.netHedgeTrig2=MathMin(-(atr*Inp_NetHedgeMult2),Inp_NetHedgeTrigger2USD);
   }
   m_dyn.stage2Delay  = GetStage2Delay(m_dyn.session);
   m_dyn.recovDistATR = GetRecovDistATR(m_dyn.volRegime);
}

//=================================================================
//  [V7.9.1] ANTI-SYMMETRIC GUARD (Refactored)
//=================================================================
bool AntiSymmetricOK(ENUM_ORDER_TYPE type, double lot)
{
   double netVol = m_port.buyVolume - m_port.sellVolume;
   double newNet = (type==ORDER_TYPE_BUY) ? netVol+lot : netVol-lot;
   
   // [HOTFIX] El umbral minimo aceptable de exposicion neta debe operar en el
   // paso real de lote del broker (VOLUME_STEP), no en el lote minimo (VOLUME_MIN).
   // En la mayoria de brokers ambos coinciden, pero cuando difieren, VOLUME_STEP
   // es la granularidad que realmente puede re-simetrizar el neto.
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;
   
   // Floating-point safe comparison
   if(MathAbs(newNet) >= lotStep * 0.99) return true;
   
   Print("[AQ V7.9.2-XAU] ANTI-SYMMETRIC GUARD: apertura bloqueada - crea simetria | NetVol=",
         NormalizeDouble(netVol,3), " newNet=", NormalizeDouble(newNet,3));
   return false;
}

//=================================================================
//  HELPERS
//=================================================================
double NormLot(double lot)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),Inp_LotMaximum);
   if(step<=0) step=0.01;
   lot=MathFloor(lot/step)*step;
   return NormalizeDouble(MathMax(minL,MathMin(maxL,lot)),2);
}

// [XAU-4] MaxSafeLot: aplica NormLot() (tope estatico Inp_LotMaximum +
// paso/minimo del broker) y ademas recorta el lote si su margen requerido
// excede Inp_MaxSafeLotMarginPct del margen libre actual. Pensado para
// llamarse en los calculos de lote de hedge/refuerzo/recovery/directional,
// donde el lote crece con la perdida acumulada del bloque.
double MaxSafeLot(double proposedLot, ENUM_ORDER_TYPE type=ORDER_TYPE_BUY)
{
   double capped=NormLot(proposedLot);
   if(capped<=0) return capped;
   MqlTick tk; if(!GetTick(tk)) return capped;
   double price=(type==ORDER_TYPE_BUY)?tk.ask:tk.bid;
   double testMargin=0;
   if(!OrderCalcMargin(type,_Symbol,capped,price,testMargin)||testMargin<=0) return capped;
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double maxMarginAllowed=freeMargin*Inp_MaxSafeLotMarginPct;
   if(testMargin>maxMarginAllowed&&maxMarginAllowed>0){
      double scale=maxMarginAllowed/testMargin;
      double scaledLot=NormLot(capped*scale);
      if(scaledLot<capped){
         Print("[AQ V7.9.2-XAU] MaxSafeLot: recorte de ",capped," a ",scaledLot,
               " (margen requerido $",NormalizeDouble(testMargin,2),
               " > ",NormalizeDouble(Inp_MaxSafeLotMarginPct*100,0),"% del libre $",NormalizeDouble(freeMargin,2),")");
         capped=scaledLot;
      }
   }
   return capped;
}

double NormPrice(double p)  { return NormalizeDouble(p,_Digits); }
bool   GetTick(MqlTick &t) { return SymbolInfoTick(_Symbol,t); }

double GetATR()
{ double b[1]; if(CopyBuffer(h_ATR,0,1,1,b)==1) return b[0]; return _Point*200; }

double GetTickVal()  { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE); }
double GetTickSize() { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); }

double DistToUSD(double dist, double lot)
{
   double tv=GetTickVal(),ts=GetTickSize();
   if(tv<=0||ts<=0||dist<=0||lot<=0) return 0;
   return NormalizeDouble((dist/ts)*tv*lot,2);
}

bool SpreadOK()
{
   int maxSpr=m_inSession?Inp_MaxSpread:(int)Inp_CTMaxSpreadOff;
   return (SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=maxSpr);
}

bool MarginOK(double lot, ENUM_ORDER_TYPE type)
{
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY),bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<Inp_CTMinBalanceUSD) return false;
   if(free<eq*Inp_MinFreeMarginPct) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg)) if(marg>free*0.60) return false;
   return true;
}

bool MarginOK_Hedge(double lot, ENUM_ORDER_TYPE type)
{
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE); if(free<=0) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg)){if(marg<=0)return false;return(marg<=free*0.90);}
   return false;
}

double CalcMarginFor001()
{
   double marg=0; MqlTick t; GetTick(t);
   if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,0.01,t.ask,marg)) return 2.0;
   return (marg>0)?marg:2.0;
}

//=================================================================
//  RECORDS
//=================================================================
int FindRec(ulong ticket)
{ for(int i=0;i<MAX_RECORDS;i++) if(m_rec[i].ticket==ticket) return i; return -1; }

int FreeRec()
{ for(int i=0;i<MAX_RECORDS;i++) if(m_rec[i].ticket==0) return i; return -1; }

void InitRec(int idx,ulong ticket,int posType,double openPrice,double vol,
             string comment,bool isPrimary,bool isCounter,
             bool isRecovery=false,bool isLBC=false)
{
   if(idx<0||idx>=MAX_RECORDS) return;
   ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket=ticket; m_rec[idx].posType=posType; m_rec[idx].openPrice=openPrice;
   m_rec[idx].volume=vol;    m_rec[idx].openTime=TimeCurrent(); m_rec[idx].comment=comment;
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
         if(pnl!=0){
            m_totalPnL+=pnl; m_tradesClosed++;
            if(pnl>0){m_totalWins++;m_sumWins+=pnl;}
            else{m_totalLosses++;m_sumLosses+=MathAbs(pnl);}
            if(pnl>m_bestClosed)m_bestClosed=pnl;
            if(pnl<m_worstClosed)m_worstClosed=pnl;
         }
         ZeroMemory(m_rec[i]);
      }
   }
}

void SyncPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
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

//=================================================================
//  KALMAN (suavizador PnL)
//=================================================================
void KalmanUpdate(int idx,double meas)
{
   if(!m_rec[idx].kInit){m_rec[idx].kX=meas;m_rec[idx].kP=1.0;m_rec[idx].kK=1.0;m_rec[idx].kInit=true;return;}
   double pP=m_rec[idx].kP+0.01,K=pP/(pP+0.20);
   m_rec[idx].kX+=K*(meas-m_rec[idx].kX); m_rec[idx].kP=(1.0-K)*pP; m_rec[idx].kK=K;
}

void UpdateKalman()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      int idx=FindRec(t); if(idx<0) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit=pf;
      if(pf>m_rec[idx].peakProfit) m_rec[idx].peakProfit=pf;
      KalmanUpdate(idx,pf);
   }
}

//=================================================================
//  SESION
//=================================================================
bool IsInMainSession()
{
   if(IsMarketClosed()) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int gmtHour=(dt.hour-Inp_GMTOffset+24)%24;
   return ((gmtHour>=Inp_LondonOpen&&gmtHour<Inp_LondonClose)||(gmtHour>=Inp_NYOpen&&gmtHour<Inp_NYClose));
}

//=================================================================
//  TEMA + KALMAN
//=================================================================
void UpdateTEMAKalman()
{
   if(!Inp_UseTEMAKalman){
      m_mkt.trendConfirmed=m_mkt.isBullish?1:(m_mkt.isBearish?-1:0); return;
   }
   MqlTick tk; if(!GetTick(tk)) return;
   double price=(tk.bid+tk.ask)/2.0; if(price<=0) return;

   double alphaF=2.0/(double)(Inp_TEMAFastPeriod+1);
   if(!m_temaF_init){m_temaF_e1=m_temaF_e2=m_temaF_e3=price;m_temaF_init=true;}
   m_temaF_e1+=alphaF*(price-m_temaF_e1); m_temaF_e2+=alphaF*(m_temaF_e1-m_temaF_e2);
   m_temaF_e3+=alphaF*(m_temaF_e2-m_temaF_e3);
   m_mkt.temaFast=3.0*m_temaF_e1-3.0*m_temaF_e2+m_temaF_e3;

   double alphaS=2.0/(double)(Inp_TEMASlowPeriod+1);
   if(!m_temaS_init){m_temaS_e1=m_temaS_e2=m_temaS_e3=price;m_temaS_init=true;}
   m_temaS_e1+=alphaS*(price-m_temaS_e1); m_temaS_e2+=alphaS*(m_temaS_e1-m_temaS_e2);
   m_temaS_e3+=alphaS*(m_temaS_e2-m_temaS_e3);
   m_mkt.temaSlow=3.0*m_temaS_e1-3.0*m_temaS_e2+m_temaS_e3;

   if(!m_kalF_init){m_kalF_x=m_mkt.temaFast;m_kalF_p=1.0;m_kalF_init=true;}
   m_kalF_p+=Inp_KalmanQ; double kgF=m_kalF_p/(m_kalF_p+Inp_KalmanR);
   m_kalF_x+=kgF*(m_mkt.temaFast-m_kalF_x); m_kalF_p*=(1.0-kgF); m_mkt.kalmanFast=m_kalF_x;

   if(!m_kalS_init){m_kalS_x=m_mkt.temaSlow;m_kalS_p=1.0;m_kalS_init=true;}
   m_kalS_p+=Inp_KalmanQ; double kgS=m_kalS_p/(m_kalS_p+Inp_KalmanR);
   m_kalS_x+=kgS*(m_mkt.temaSlow-m_kalS_x); m_kalS_p*=(1.0-kgS); m_mkt.kalmanSlow=m_kalS_x;

   bool temaBull=(m_mkt.temaFast>m_mkt.temaSlow), temaBear=(m_mkt.temaFast<m_mkt.temaSlow);
   bool kalBull=(m_mkt.kalmanFast>m_mkt.kalmanSlow), kalBear=(m_mkt.kalmanFast<m_mkt.kalmanSlow);
   if(temaBull&&kalBull) m_mkt.trendConfirmed=1;
   else if(temaBear&&kalBear) m_mkt.trendConfirmed=-1;
   else m_mkt.trendConfirmed=0;
   m_mkt.isBullish=(m_mkt.trendConfirmed==1); m_mkt.isBearish=(m_mkt.trendConfirmed==-1);
}

//=================================================================
//  ACTUALIZACION DE MERCADO
//=================================================================
void UpdateMarket()
{
   MqlTick t; if(!GetTick(t)) return;
   m_mkt.bid=t.bid; m_mkt.ask=t.ask; m_mkt.spread=(t.ask-t.bid)/_Point; m_mkt.atr=GetATR();

   double f[1],s[1],r[1],m[1],sg[1];
   if(CopyBuffer(h_EMAFast,0,0,1,f)==1) m_mkt.emaFast=f[0];
   if(CopyBuffer(h_EMASlow,0,0,1,s)==1) m_mkt.emaSlow=s[0];
   if(CopyBuffer(h_RSI,0,0,1,r)==1) m_mkt.rsi=r[0];
   if(CopyBuffer(h_MACD,0,0,1,m)==1) m_mkt.macdMain=m[0];
   if(CopyBuffer(h_MACD,1,0,1,sg)==1) m_mkt.macdSig=sg[0];
   if(h_ADX!=INVALID_HANDLE){double adxB[1];if(CopyBuffer(h_ADX,0,0,1,adxB)==1) m_mkt.adx=adxB[0];}
   if(h_HTFEMAFast!=INVALID_HANDLE&&h_HTFEMASlow!=INVALID_HANDLE){
      double hf[1],hs[1];
      if(CopyBuffer(h_HTFEMAFast,0,0,1,hf)==1&&CopyBuffer(h_HTFEMASlow,0,0,1,hs)==1)
         m_mkt.htfTrend=(hf[0]>hs[0]*1.0001)?1:(hf[0]<hs[0]*0.9999)?-1:0;
   }
   if(h_EMA200!=INVALID_HANDLE){double e200[1];if(CopyBuffer(h_EMA200,0,1,1,e200)==1) m_mkt.ema200=e200[0];}
   if(h_ATRSlow!=INVALID_HANDLE){double atrS[1];if(CopyBuffer(h_ATRSlow,0,1,1,atrS)==1) m_mkt.atrSlow=atrS[0];}

   m_mkt.isBullish=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.rsi>52&&m_mkt.macdMain>m_mkt.macdSig);
   m_mkt.isBearish=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.rsi<48&&m_mkt.macdMain<m_mkt.macdSig);
   UpdateTEMAKalman();
   UpdateDynamicThresholds();
}

//=================================================================
//  PORTFOLIO
//=================================================================
void UpdatePortfolio()
{
   ZeroMemory(m_port); m_port.worstProfit=0;
   m_losingPosOpenPrice=0; m_losingPosType=-1;
   double vwapN=0,vwapD=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      bool isOwn=(magic==Inp_Magic), isExt=(!isOwn&&Inp_RescueAllTrades);
      if(!isOwn&&!isExt) continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol=PositionGetDouble(POSITION_VOLUME),op=PositionGetDouble(POSITION_PRICE_OPEN);
      string comm=PositionGetString(POSITION_COMMENT);
      m_port.totalPos++; m_port.totalProfit+=pf;
      if(pf>=0) m_port.positiveSum+=pf; else m_port.negativeSum+=MathAbs(pf);
      if(pt==POSITION_TYPE_BUY){m_port.buyCount++;m_port.buyProfit+=pf;m_port.buyVolume+=vol;}
      else{m_port.sellCount++;m_port.sellProfit+=pf;m_port.sellVolume+=vol;}
      vwapN+=op*vol; vwapD+=vol;
      m_port.blockDir+=(pt==POSITION_TYPE_BUY)?1:-1;
      if(pf<m_port.worstProfit){
         m_port.worstProfit=pf;m_port.worstTicket=t;
         m_losingPosOpenPrice=op;m_losingPosType=pt;
      }
      if(isOwn){
         if(StringFind(comm,"CT_")>=0) m_port.ctCount++;
         if(StringFind(comm,"REC_")>=0||StringFind(comm,"BSE_")>=0) m_port.recoveryCount++;
         if(StringFind(comm,"LBC_")>=0) m_port.lbcCount++;
      }
      if(isExt){m_port.rescueCount++;m_port.rescueProfit+=pf;}
   }
   if(vwapD>0) m_port.blockVWAP=vwapN/vwapD;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>m_bestEquity) m_bestEquity=eq;
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
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int nowMin=dt.hour*60+dt.min,s=m_sensors.brokerStartMin,e=m_sensors.brokerEndMin;
   if(s<=e) return(nowMin>=s&&nowMin<e); else return(nowMin>=s||nowMin<e);
}

bool TrendFilter200OK(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseTrendFilter200||m_mkt.ema200<=0) return true;
   MqlTick tk; if(!GetTick(tk)) return true;
   double mid=(tk.bid+tk.ask)/2.0;
   if(type==ORDER_TYPE_BUY) return(mid>m_mkt.ema200);
   if(type==ORDER_TYPE_SELL) return(mid<m_mkt.ema200);
   return true;
}

bool VolatilityOK()
{
   if(!Inp_UseVolatFilter||m_mkt.atrSlow<=0) return true;
   m_sensors.atrRatio=m_mkt.atr/m_mkt.atrSlow;
   return(m_sensors.atrRatio<=Inp_ATRRatioMax);
}

bool MarginGuardOK()
{
   if(!Inp_UseMarginGuard) return true;
   double lot=CalcLot(0),marg1=0;
   MqlTick tk; if(!GetTick(tk)) return true;
   if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lot,tk.ask,marg1)||marg1<=0) return true;
   return(AccountInfoDouble(ACCOUNT_MARGIN_FREE)>=marg1*(1.0+Inp_MarginGuardLevels));
}

void UpdateSensors()
{
   m_sensors.blockReason="";
   m_sensors.marketOpen=!IsMarketClosed();
   if(!m_sensors.marketOpen&&m_sensors.blockReason=="") m_sensors.blockReason="Mercado cerrado (fin de semana)";
   m_sensors.timeOK=IsInTradingWindow();
   if(!m_sensors.timeOK&&m_sensors.blockReason=="") m_sensors.blockReason="Fuera de ventana horaria";
   m_sensors.spreadOK=SpreadOK();
   if(!m_sensors.spreadOK&&m_sensors.blockReason==""){
      int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
      m_sensors.blockReason="Spread: "+IntegerToString(cs)+" pts";
   }
   if(m_mkt.ema200>0){MqlTick tk;GetTick(tk);m_sensors.trendBull=((tk.bid+tk.ask)/2.0>m_mkt.ema200);}
   else m_sensors.trendBull=true;
   m_sensors.volatOK=VolatilityOK();
   if(!m_sensors.volatOK&&m_sensors.blockReason=="")
      m_sensors.blockReason="Tormenta ATR ratio="+DoubleToString(m_sensors.atrRatio,1);
   if(m_dyn.volRegime==VOL_HIGH&&m_sensors.volatOK&&m_sensors.blockReason=="")
      m_sensors.blockReason="Vol.Regime HIGH";
   m_sensors.marginOK=MarginGuardOK();
   if(!m_sensors.marginOK&&m_sensors.blockReason=="")
      m_sensors.blockReason="Margen insuf.";
   m_sensors.allOK=(m_sensors.timeOK&&m_sensors.spreadOK&&m_sensors.volatOK&&
                    m_sensors.marginOK&&m_sensors.marketOpen&&m_dyn.volRegime!=VOL_HIGH);
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
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   datetime midnight=TimeCurrent()-(dt.hour*3600+dt.min*60+dt.sec);
   if(m_lastDailyReset<midnight){m_dailyBalance=AccountInfoDouble(ACCOUNT_BALANCE);m_dailyLimitHit=false;m_lastDailyReset=midnight;}
}

bool DailyLimitReached()
{
   if(!Inp_UseDailyLimit||m_dailyLimitHit) return m_dailyLimitHit;
   double eff=(AccountInfoDouble(ACCOUNT_BALANCE)-m_dailyBalance)+m_port.totalProfit;
   double lim=MathMin(MathAbs(Inp_DailyLossUSD),m_dailyBalance*MathAbs(Inp_DailyLossPct));
   if(eff<=-lim){Print("[AQ V7.9.2-XAU] LIMITE DIARIO");m_dailyLimitHit=true;m_isPaused=true;}
   return m_dailyLimitHit;
}

void UpdateStreak(double pnl)
{
   if(pnl<-0.01){m_consecutiveLosses++;if(m_consecutiveLosses>=Inp_LossStreakMax&&m_lotMultiplier==1.0)m_lotMultiplier=Inp_LossStreakReduce;}
   else if(pnl>0.01){m_lotMultiplier=1.0;m_consecutiveLosses=0;}
}

double CalcExpectancy()
{
   int total=m_totalWins+m_totalLosses; if(total==0) return 0;
   double wr=(double)m_totalWins/total;
   double avgW=(m_totalWins>0)?m_sumWins/m_totalWins:0;
   double avgL=(m_totalLosses>0)?m_sumLosses/m_totalLosses:0;
   return (wr*avgW)-((1.0-wr)*avgL);
}

//=================================================================
//  CIERRE
//=================================================================
bool ClosePos(ulong ticket, string reason="")
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) return false;
   if(!m_isProcessing&&m_port.totalPos>1){
      Print("[AQ V7.9.2-XAU] !! CIERRE INDIVIDUAL BLOQUEADO #",ticket," [",reason,"] totalPos=",m_port.totalPos);
      return false;
   }
   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)){
      UpdateStreak(pf);
      if(pf>0){m_cycleWinsSum+=pf;m_cycleWinsCount++;m_totalWins++;m_sumWins+=pf;}
      else{m_cycleLossSum+=pf;m_totalLosses++;m_sumLosses+=MathAbs(pf);}
      m_totalPnL+=pf;m_tradesClosed++;
      if(pf>m_bestClosed)m_bestClosed=pf; if(pf<m_worstClosed)m_worstClosed=pf;
      int idx=FindRec(ticket);
      if(idx>=0){
         if(m_rec[idx].isPrimary) m_lastPrimaryLost=(pf<0);
         if(m_rec[idx].isLBC){
            string comm=m_rec[idx].comment;
            if(StringFind(comm,"LBC_B")>=0&&m_lbc.buyCount>0)m_lbc.buyCount--;
            if(StringFind(comm,"LBC_S")>=0&&m_lbc.sellCount>0)m_lbc.sellCount--;
            if(pf>0){m_lbc.harvestedTotal+=pf;m_lbc.harvestCount++;}
         }
         Print("[AQ V7.9.2-XAU] CERRADA #",ticket," $",NormalizeDouble(pf,2),(reason!=""?" ["+reason+"]":""));
         ZeroMemory(m_rec[idx]);
      }
      return true;
   }
   return false;
}

bool CloseRescuePos(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)){m_totalPnL+=pf;m_tradesClosed++;
      Print("[AQ V7.9.2-XAU] RESCATE #",ticket," $",NormalizeDouble(pf,2)," [",reason,"]"); return true;}
   return false;
}

bool CloseBlockIfPositive(string reason)
{
   if(m_port.totalProfit<m_dyn.blockTP) return false;
   Print("[AQ V7.9.2-XAU] CIERRE POSITIVO: PnL=$",NormalizeDouble(m_port.totalProfit,2),
         " >= $",NormalizeDouble(m_dyn.blockTP,2)," [",reason,"] Stage=",m_blockStage);
   m_isProcessing=true;
   for(int pass=0;pass<2;pass++){
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pass==0&&pf<0) continue; if(pass==1&&pf>=0) continue;
         ClosePos(t,reason);
      }
   }
   if(Inp_RescueAllTrades){
      for(int pass=0;pass<2;pass++){
         for(int i=PositionsTotal()-1;i>=0;i--){
            ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC)==Inp_Magic) continue;
            double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
            if(pass==0&&pf<0) continue; if(pass==1&&pf>=0) continue;
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
//  LOTES
//=================================================================
double CalcLot(int level=0)
{
   double sessionFactor=m_inSession?1.0:Inp_OffSessionLotFactor;
   if(!Inp_UseDynamicLot||m_mkt.atr<=0) return NormLot(Inp_LotBase*m_lotMultiplier*sessionFactor);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE),riskUSD=bal*Inp_RiskPerTradePct;
   double slATR=m_inSession?Inp_SL_ATR:Inp_OffSessionSL_ATR,slDist=m_mkt.atr*slATR;
   double tv=GetTickVal(),ts=GetTickSize(),lot=Inp_LotBase;
   if(tv>0&&ts>0&&slDist>0){double pipV=tv/ts;if(pipV>0) lot=riskUSD/(slDist*pipV);}
   return NormLot(MathMax(lot,Inp_LotBase)*m_lotMultiplier*sessionFactor);
}

// [V7.9] Calcula lote direccional para recuperar el bloque en 1 movimiento ATR
// Con sesgo NETO positivo en la direccion indicada.
double CalcDirectionalLot(int targetDir)
{
   ENUM_ORDER_TYPE dirType=(targetDir==1)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double atr=m_mkt.atr; if(atr<=0) return MaxSafeLot(Inp_LotBase*2.0,dirType);
   double blockLoss=MathAbs(m_port.totalProfit);
   double totalNeeded=blockLoss+m_dyn.blockTP;
   double moveDist=atr*Inp_RecoveryMoveATR; if(moveDist<=0) moveDist=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),calcLot=Inp_LotBase*2.0;
   if(tv>0&&ts>0&&moveDist>0){
      double profitPer=(moveDist/ts)*tv;
      if(profitPer>0) calcLot=totalNeeded/profitPer;
   }
   // Asegurar que el net volume post-apertura sea >= LotBase en targetDir
   double netVol=m_port.buyVolume-m_port.sellVolume;
   double projectedNet=(targetDir==1)?netVol+calcLot:netVol-calcLot;
   // Si el net proyectado es insuficiente, aumentar el lote
   double minNetNeeded=Inp_LotBase*1.5;
   if(targetDir==1&&projectedNet<minNetNeeded)
      calcLot=MathMax(calcLot,minNetNeeded-netVol);
   else if(targetDir==-1&&projectedNet>-minNetNeeded)
      calcLot=MathMax(calcLot,netVol+minNetNeeded);
   return MaxSafeLot(MathMax(calcLot,Inp_LotBase*2.0),dirType);
}

double CalcRecoveryLot()
{
   double atr=m_mkt.atr;
   if(atr<=0) return NormLot(Inp_LotBase*Inp_RecoveryMinLotMult);
   double blockLoss=MathAbs(m_port.totalProfit),totalNeeded=blockLoss+m_dyn.blockTP;
   double moveDist=atr*Inp_RecoveryMoveATR; if(moveDist<=0) moveDist=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),profitPer1=0;
   if(tv>0&&ts>0) profitPer1=(moveDist/ts)*tv;
   double calcLot=Inp_LotBase;
   if(profitPer1>0) calcLot=totalNeeded/profitPer1;
   double loserLot=Inp_LotBase;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol=PositionGetDouble(POSITION_VOLUME);
      if(pf==m_port.worstProfit){loserLot=vol;break;}
   }
   return NormLot(MathMax(calcLot,loserLot*Inp_RecoveryMinLotMult));
}

//=================================================================
//  APERTURA
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type,double lot,string comment,bool skipPosLimit=false)
{
   if((m_isPaused||m_emergencyMode)&&!skipPosLimit) return 0;
   if(!SpreadOK()) return 0;
   if(!skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal) return 0;
   if(skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal+4) return 0;
   lot=NormLot(lot); if(lot<=0) return 0;
   if(!MarginOK(lot,type)) return 0;
   MqlTick t; if(!GetTick(t)) return 0;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid;
   bool ok=(type==ORDER_TYPE_BUY)?m_trade.Buy(lot,_Symbol,price,0,0,comment):m_trade.Sell(lot,_Symbol,price,0,0,comment);
   if(!ok){Print("[AQ V7.9.2-XAU] ERR apertura: ",m_trade.ResultRetcodeDescription());return 0;}
   ulong ticket=m_trade.ResultOrder();
   if(ticket>0){
      m_tradesOpened++;
      Print("[AQ V7.9.2-XAU] ABIERTA #",ticket," ",(type==ORDER_TYPE_BUY?"BUY":"SELL"),
            " Lot=",lot," @ ",NormalizeDouble(price,_Digits),
            " SL=0 TP=0 [",comment,"] Stage=",m_blockStage,
            " Sesion=",SessionName(m_dyn.session));
   }
   return ticket;
}

void ManagePositions() {}

//=================================================================
//  [V7.9] DETANGLE ENGINE
//=================================================================
void RunDetangle()
{
   if(m_isProcessing||m_port.totalPos<2) return;

   // Detectar simetria: net volume cerca de cero
   double netVol=MathAbs(m_port.buyVolume-m_port.sellVolume);
   bool isSym=(netVol<Inp_DetangleNetThresh);
   bool isPnLBad=(m_port.totalProfit<Inp_DetangleMinLoss);

   if(!isSym||!isPnLBad){
      // Resetear timer si ya no hay simetria
      if(!isSym){m_detangleDetectTime=0;m_detangleActive=false;}
      return;
   }

   // Iniciar timer si acaba de detectarse
   if(m_detangleDetectTime==0){
      m_detangleDetectTime=TimeCurrent();
      m_detangleActive=true;
      Print("[AQ V7.9.2-XAU] DETANGLE: jaula simetrica detectada | NetVol=",
            NormalizeDouble(netVol,3)," PnL=",NormalizeDouble(m_port.totalProfit,2));
      return;
   }

   // Esperar el tiempo configurado
   if((int)(TimeCurrent()-m_detangleDetectTime)<Inp_DetangleSec) return;
   if(!SpreadOK()) return;

   // ACCION: cerrar la posicion mas perdedora para romper simetria
   if(m_port.worstTicket>0&&m_port.worstProfit<0){
      Print("[AQ V7.9.2-XAU] DETANGLE EJECUTANDO: cerrando peor pos #",m_port.worstTicket,
            " PnL=",NormalizeDouble(m_port.worstProfit,2),
            " | Rompe simetria en beneficio del lado contrario");
      m_isProcessing=true;
      bool closed=ClosePos(m_port.worstTicket,"Detangle_BreakSym");
      m_isProcessing=false;
      if(closed){
         m_detangleDetectTime=TimeCurrent(); 
         m_detangleActive=false;
         UpdatePortfolio();
      }
   }
}

//=================================================================
//  [V7.9.1] BLOCK STAGE ENGINE — DIRECTIONAL + ASYMMETRIC
//=================================================================
void RunBlockStageEngine()
{
   if(m_isProcessing)    return;
   if(m_blockStage==0)   return;

   int mainPosCount=m_port.totalPos-m_port.lbcCount;

   if(mainPosCount<=0&&m_port.totalPos==0){m_blockStage=0;m_stageFollowHedge=false;return;}
   if(mainPosCount<=0) return; 

   if(CloseBlockIfPositive("BSE_TP")) return;

   MqlTick tk; if(!GetTick(tk)) return;
   double totalPnL=m_port.totalProfit;

   // ── STAGE 1: Primaria activa — espera trigger dinamico ───────
   if(m_blockStage==1&&mainPosCount==1){
      double trigger1=(m_stage1TriggerAtOpen!=0)?m_stage1TriggerAtOpen:m_dyn.stage1Trigger;
      int holdTimeSec=(int)(TimeCurrent()-m_primaryOpenTime);
      bool emergencyOverride=(totalPnL<=trigger1*Inp_StageEmergMult);

      if(holdTimeSec<Inp_PrimaryMinHoldSec&&!emergencyOverride){
         return;
      }

      if(totalPnL<=trigger1){
         int trendDir=m_mkt.trendConfirmed;
         int primaryDir=(m_primaryType==ORDER_TYPE_BUY)?1:-1;

         if(Inp_UseDirectionalStage&&trendDir==primaryDir&&trendDir!=0){
            // REINFORCE LOGIC
            ENUM_ORDER_TYPE reinType=m_primaryType;
            double reinLot=MaxSafeLot(Inp_LotBase*Inp_ReinforceLotMult,reinType);

            if(MarginOK(reinLot,reinType)&&AntiSymmetricOK(reinType,reinLot)){
               m_isProcessing=true;
               ulong t1=OpenOrder(reinType,reinLot,"BSE_REINF1",true);
               m_isProcessing=false;
               if(t1>0){
                  int idx=FreeRec();
                  if(idx>=0){
                     int pt1=(reinType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
                     double op1=(reinType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
                     InitRec(idx,t1,pt1,op1,reinLot,"BSE_REINF1",false,false,true,false);
                  }
                  m_blockStage=2;m_stage2Time=TimeCurrent();m_recoveryActive=true;
                  m_stageFollowHedge=false; 
                  m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
                  Print("[AQ V7.9.2-XAU] >>> STAGE 2 via REFUERZO...");
               }
            }
         } else {
            // HEDGE LOGIC
            ENUM_ORDER_TYPE hedgeType=(m_primaryType==ORDER_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
            double hedgeLot=MaxSafeLot(MathMax(Inp_LotBase*Inp_HedgeRatio,Inp_LotBase),hedgeType);

            // DYNAMIC ASYMMETRY ENFORCEMENT
            if(!AntiSymmetricOK(hedgeType, hedgeLot)) {
                double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
                if (volStep <= 0) volStep = 0.01;
                // Inflate hedge slightly to ensure dynamic bias
                hedgeLot = NormLot(hedgeLot + volStep);
                Print("[AQ V7.9.2-XAU] HEDGE ADJUSTED: Forzando asimetria matemática. Nuevo lote: ", hedgeLot);
            }

            if(MarginOK(hedgeLot,hedgeType)){
               m_isProcessing=true;
               ulong t1=OpenOrder(hedgeType,hedgeLot,"BSE_H1",true);
               m_isProcessing=false;
               if(t1>0){
                  int idx=FreeRec();
                  if(idx>=0){
                     int pt1=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
                     double op1=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
                     InitRec(idx,t1,pt1,op1,hedgeLot,"BSE_H1",false,false,true,false);
                  }
                  m_blockStage=2;m_stage2Time=TimeCurrent();m_recoveryActive=true;
                  m_stageFollowHedge=true; 
                  m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
                  Print("[AQ V7.9.2-XAU] >>> STAGE 2 via HEDGE ASIMETRICO: H1 #",t1);
               }
            }
         }
      }
      return;
   }

   // ── STAGE 2: Analisis y 3ra orden DIRECCIONAL ────────────────
   if(m_blockStage==2&&mainPosCount==2){
      if((int)(TimeCurrent()-m_stage2Time)<m_dyn.stage2Delay) return;
      if(!SpreadOK()) return;

      int trendDir=m_mkt.trendConfirmed;
      ENUM_ORDER_TYPE thirdType;
      int targetDir;

      if(trendDir==1){
         thirdType=ORDER_TYPE_BUY; targetDir=1;
      } else if(trendDir==-1){
         thirdType=ORDER_TYPE_SELL; targetDir=-1;
      } else {
         if(m_port.buyProfit<m_port.sellProfit){
            thirdType=ORDER_TYPE_SELL; targetDir=-1;
         } else {
            thirdType=ORDER_TYPE_BUY; targetDir=1;
         }
      }

      double thirdLot=CalcDirectionalLot(targetDir);

      if(!AntiSymmetricOK(thirdType,thirdLot)){
         double netVol=m_port.buyVolume-m_port.sellVolume;
         double minNeeded=(targetDir==1)?Inp_LotBase*1.5-netVol:netVol+Inp_LotBase*1.5;
         thirdLot=NormLot(MathMax(thirdLot,MathAbs(minNeeded)));
      }

      string stage3Label=(targetDir==1)?"BSE_DIR_LONG":"BSE_DIR_SHORT";
      m_stageFollowHedge=(thirdType!=m_primaryType);

      if(MarginOK(thirdLot,thirdType)){
         m_isProcessing=true;
         ulong t2=OpenOrder(thirdType,thirdLot,stage3Label,true);
         m_isProcessing=false;
         if(t2>0){
            int idx=FreeRec();
            if(idx>=0){
               int pt2=(thirdType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
               double op2=(thirdType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
               InitRec(idx,t2,pt2,op2,thirdLot,stage3Label,false,false,true,false);
            }
            m_blockStage=3;
            double newNet=(targetDir==1)?(m_port.buyVolume+thirdLot-m_port.sellVolume):
                                         (m_port.buyVolume-m_port.sellVolume-thirdLot);
            Print("[AQ V7.9.2-XAU] >>> STAGE 3: 3ra DIRECCIONAL #",t2,
                  " ",(thirdType==ORDER_TYPE_BUY?"BUY":"SELL"),
                  " Lot=",NormalizeDouble(thirdLot,2),
                  " | NetVol proyectado=",NormalizeDouble(newNet,3));
         }
      } else {
         ActivateLBC();
      }
      return;
   }

   // ── STAGE 3: Monitorea trigger. Si se dispara, consolida hacia el trend ─
   if(m_blockStage==3){
      double trigger3=(m_stage3TriggerAtOpen!=0)?m_stage3TriggerAtOpen:m_dyn.stage3Trigger;
      if(totalPnL<=trigger3){
         if(!SpreadOK()) return;
         int trendDir=m_mkt.trendConfirmed;
         ENUM_ORDER_TYPE fourthType;
         int target4Dir;
         if(trendDir==1){fourthType=ORDER_TYPE_BUY;target4Dir=1;}
         else if(trendDir==-1){fourthType=ORDER_TYPE_SELL;target4Dir=-1;}
         else{
            if(m_port.buyProfit>m_port.sellProfit){fourthType=ORDER_TYPE_BUY;target4Dir=1;}
            else{fourthType=ORDER_TYPE_SELL;target4Dir=-1;}
         }
         double fourthLot=CalcDirectionalLot(target4Dir);
         if(!AntiSymmetricOK(fourthType,fourthLot)){
            double netVol=m_port.buyVolume-m_port.sellVolume;
            double minN=(target4Dir==1)?Inp_LotBase*2.0-netVol:netVol+Inp_LotBase*2.0;
            fourthLot=NormLot(MathMax(fourthLot,MathAbs(minN)));
         }
         if(MarginOK(fourthLot,fourthType)){
            m_isProcessing=true;
            ulong t3=OpenOrder(fourthType,fourthLot,"BSE_CON4",true);
            m_isProcessing=false;
            if(t3>0){
               int idx=FreeRec();
               if(idx>=0){
                  int pt3=(fourthType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
                  double op3=(fourthType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
                  InitRec(idx,t3,pt3,op3,fourthLot,"BSE_CON4",false,false,true,false);
               }
               m_blockStage=4;
               Print("[AQ V7.9.2-XAU] >>> STAGE 4: Consolidacion #",t3,
                     " Lot=",NormalizeDouble(fourthLot,2));
            }
         } else {ActivateLBC();}
      }
      return;
   }

   // ── STAGE 4: Exposicion maxima. Espera cierre positivo + LBC si necesario ─
   if(m_blockStage==4){
      double lbcTrigger=m_dyn.stage3Trigger*1.5;
      if(!m_lbc.active&&totalPnL<lbcTrigger) ActivateLBC();
   }
}

//=================================================================
//  RECOVERY ENGINE FALLBACK
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
      Print("[AQ V7.9.2-XAU] RECOVERY FALLBACK | PnL=$",NormalizeDouble(m_port.totalProfit,2));
   }
   int maxRec=m_recoveryTrendHedge?Inp_RecoveryMaxOrdersTrend:Inp_RecoveryMaxOrders;
   if(m_recoveryOrders>=maxRec||TimeCurrent()-m_lastRecoveryTime<Inp_RecoveryIntervalSec||!SpreadOK()) return;
   MqlTick tk; if(!GetTick(tk)) return;
   double atr=m_mkt.atr; if(atr<=0) return;
   double minDist=atr*m_dyn.recovDistATR;
   if(m_losingPosOpenPrice>0&&m_losingPosType>=0){
      double dist=(m_losingPosType==POSITION_TYPE_SELL)?tk.bid-m_losingPosOpenPrice:m_losingPosOpenPrice-tk.ask;
      if(dist<minDist) return;
   }
   ENUM_ORDER_TYPE recType;
   double adxLevel=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;
   bool bearT=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.adx>adxLevel);
   bool bullT=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.adx>adxLevel);
   if(m_port.buyProfit<m_port.sellProfit&&bearT){recType=ORDER_TYPE_SELL;m_recoveryTrendHedge=true;}
   else if(m_port.sellProfit<m_port.buyProfit&&bullT){recType=ORDER_TYPE_BUY;m_recoveryTrendHedge=true;}
   else{
      m_recoveryTrendHedge=false; double cd=atr*0.3;
      if(m_port.buyProfit<m_port.sellProfit){recType=ORDER_TYPE_BUY;if(m_lastCTBuyPrice>0&&MathAbs(tk.ask-m_lastCTBuyPrice)<cd)return;}
      else{recType=ORDER_TYPE_SELL;if(m_lastCTSellPrice>0&&MathAbs(tk.bid-m_lastCTSellPrice)<cd)return;}
   }
   
   double recLot=MaxSafeLot(CalcRecoveryLot(),recType);
   if(!AntiSymmetricOK(recType,recLot)){
      double netVol=m_port.buyVolume-m_port.sellVolume;
      int targetDir=(recType==ORDER_TYPE_BUY)?1:-1;
      double minN=(targetDir==1)?Inp_LotBase-netVol:netVol+Inp_LotBase;
      recLot=NormLot(MathMax(recLot,MathAbs(minN)));
   }
   if(!MarginOK(recLot,recType)){recLot=NormLot(recLot*0.5);if(!MarginOK(recLot,recType)){recLot=NormLot(Inp_LotBase);if(!MarginOK(recLot,recType)){ActivateLBC();return;}}}
   string recComm="REC_"+(recType==ORDER_TYPE_BUY?"B":"S")+"_"+IntegerToString(m_recoveryOrders+1);
   m_isProcessing=true;
   ulong ticket=OpenOrder(recType,recLot,recComm,true);
   m_isProcessing=false;
   if(ticket>0){
      int idx=FreeRec();
      if(idx>=0){int pt=(recType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(recType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,ticket,pt,op,recLot,recComm,false,false,true,false);}
      if(recType==ORDER_TYPE_BUY)m_lastCTBuyPrice=tk.ask; else m_lastCTSellPrice=tk.bid;
      m_recoveryOrders++;m_lastRecoveryTime=TimeCurrent();
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
   m_lbc.maxOrdersCalc=(int)MathFloor(freeMarg*Inp_LBCMarginPct/(2.0*MathMax(margPer001,0.01)));
   m_lbc.maxOrdersCalc=MathMax(1,MathMin(m_lbc.maxOrdersCalc,Inp_LBCMaxPairs));
   Print("[AQ V7.9.2-XAU] LBC ACTIVADO | LibreMarg=$",NormalizeDouble(freeMarg,2)," | MaxPares=",m_lbc.maxOrdersCalc);
}

void DeactivateLBC()
{
   if(!m_lbc.active) return;
   Print("[AQ V7.9.2-XAU] LBC DESACTIVADO | Cosechado:$",NormalizeDouble(m_lbc.harvestedTotal,2)," en ",m_lbc.harvestCount," cosechas");
   ZeroMemory(m_lbc);
}

void RunLBCEngine()
{
   if(!m_lbc.active) return;
   if(m_port.totalPos==0){DeactivateLBC();return;}
   if(m_isProcessing) return;
   if(m_port.totalProfit>=m_dyn.blockTP) return;
   if(m_port.totalProfit>=m_dyn.recovTrigger*0.5){DeactivateLBC();return;}
   MqlTick tk; if(!GetTick(tk)) return;
   double atr=m_mkt.atr; if(atr<=0) return;
   int nonLBCCount=m_port.totalPos-m_port.lbcCount;
   bool blockHasMainPositions=(nonLBCCount>0);

   if(!blockHasMainPositions){
      double harvestMin=DistToUSD(atr*Inp_LBCHarvestATR,0.01);
      harvestMin=MathMax(harvestMin,0.02);
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         string comm=PositionGetString(POSITION_COMMENT);
         if(StringFind(comm,"LBC_")<0) continue;
         double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pf>=harvestMin){
            ClosePos(t,"LBC_Harvest");
            double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE),mp001=CalcMarginFor001();
            m_lbc.maxOrdersCalc=(int)MathFloor((fm*Inp_LBCMarginPct)/(2.0*MathMax(mp001,0.01)));
            m_lbc.maxOrdersCalc=MathMax(1,MathMin(m_lbc.maxOrdersCalc,Inp_LBCMaxPairs));
         }
      }
   }

   if(m_blockStage>0&&blockHasMainPositions){
      return;
   }

   if(TimeCurrent()-m_lbc.lastOrderTime<Inp_LBCIntervalSec||!SpreadOK()) return;
   int totalLBCPairs=MathMin(m_lbc.buyCount,m_lbc.sellCount);
   if(totalLBCPairs>=m_lbc.maxOrdersCalc) return;
   double gridSpace=atr*Inp_LBCGridATR*(m_inSession?1.2:1.0);
   double lot001=NormLot(Inp_LotBase);
   bool needBuy=false,needSell=false;
   if(m_lbc.buyCount==0&&m_lbc.sellCount==0){needBuy=true;needSell=true;}
   else{
      if(m_lbc.buyCount<=m_lbc.sellCount&&(m_lbc.lastBuyPrice<=0||MathAbs(tk.ask-m_lbc.lastBuyPrice)>=gridSpace)) needBuy=true;
      if(m_lbc.sellCount<=m_lbc.buyCount&&(m_lbc.lastSellPrice<=0||MathAbs(tk.bid-m_lbc.lastSellPrice)>=gridSpace)) needSell=true;
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

void RunBasketTP()
{
   if(!Inp_UseBasketTP||TimeCurrent()-m_lastBasketCheck<Inp_BasketCheckSec) return;
   m_lastBasketCheck=TimeCurrent(); if(m_port.totalPos<2) return;
   if(m_port.totalProfit<m_dyn.blockTP) return;
   double avgWin=(m_cycleWinsCount>0)?m_cycleWinsSum/m_cycleWinsCount:Inp_BasketTPFactor;
   double target=MathMax(m_dyn.blockTP,avgWin*Inp_BasketTPRatio);
   if(m_port.totalProfit>=target) CloseBlockIfPositive("BasketTP");
}

void CheckCycleMaxLoss()
{
   if(!Inp_UseCycleMaxLoss||m_port.totalPos==0) return;
   if(m_port.totalProfit<=Inp_CycleMaxLossUSD){
      Print("[AQ V7.9.2-XAU] CYCLE MAX LOSS: $",NormalizeDouble(m_port.totalProfit,2));
      if(!m_recoveryActive&&m_blockStage==0){m_recoveryActive=true;m_recoveryOrders=0;}
   }
}

void RunHarvest()
{
   if(m_port.totalPos>1||!Inp_HarvestContinuous||m_isProcessing) return;
   if(TimeCurrent()-m_lastHarvestTime<Inp_HarvestIntervalSec) return;
   m_lastHarvestTime=TimeCurrent();
   if(m_port.totalProfit>=m_dyn.blockTP) CloseBlockIfPositive("Harvest_Single");
}

bool CheckEquityGuard()
{
   if(!Inp_UseEquityGuard) return false;
   if(m_port.totalProfit<=Inp_EmergencyLossUSD&&!m_emergencyMode){
      Print("[AQ V7.9.2-XAU] ALERTA EQUITY: $",NormalizeDouble(m_port.totalProfit,2)," -> Pausa primarias.");
      m_emergencyMode=true;m_isPaused=true;return true;
   }
   if(m_port.currentDD>=Inp_MaxDrawdownPct) m_isPaused=true;
   else if(m_isPaused&&!m_emergencyMode&&!m_dailyLimitHit&&m_port.currentDD<Inp_MaxDrawdownPct*0.5) m_isPaused=false;
   return false;
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
      if(m_mkt.htfTrend==1&&buyCount<Inp_CTMaxSameDir) openBuy=true;
      else if(m_mkt.htfTrend==-1&&sellCount<Inp_CTMaxSameDir) openSell=true;
      else if(m_port.buyProfit<m_port.sellProfit&&sellCount<Inp_CTMaxSameDir) openSell=true;
      else if(buyCount<Inp_CTMaxSameDir) openBuy=true;
      else return false;
   } else return false;
   ENUM_ORDER_TYPE testType=openBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(!ADXAllowsEntry(testType)) return false;
   double ctDist=(Inp_CTMode==CT_ATR_DISTANCE)?m_mkt.atr*Inp_CTDistanceATR:Inp_CTFixedPoints*_Point;
   MqlTick t; if(!GetTick(t)) return false;
   if(ctDist>0){
      if(openBuy&&m_lastCTBuyPrice>0&&MathAbs(t.ask-m_lastCTBuyPrice)<ctDist) return false;
      if(openSell&&m_lastCTSellPrice>0&&MathAbs(t.bid-m_lastCTSellPrice)<ctDist) return false;
   }
   ctLevel=openBuy?buyCount:sellCount; ctLot=CalcLot(ctLevel);
   ctType=openBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   return true;
}

void RunCTEngine()
{
   if(m_isProcessing||m_isPaused||m_emergencyMode||m_cycleInPause) return;
   if(TimeCurrent()-m_lastCTTime<Inp_CTIntervalSec) return;
   m_lastCTTime=TimeCurrent();
   MqlTick ts; if(!GetTick(ts)) return;
   double maxSpr=m_inSession?(double)Inp_MaxSpread:Inp_CTMaxSpreadOff;
   if((ts.ask-ts.bid)/_Point>maxSpr) return;

   if(m_port.totalPos==0){
      if(!m_sensors.allOK){
         static datetime lastSL=0;
         if(TimeCurrent()-lastSL>=60){Print("[AQ V7.9.2-XAU] ENTRADA BLOQUEADA: ",m_sensors.blockReason);lastSL=TimeCurrent();}
         return;
      }
      if(m_stormActive) return;
      int cooldown=m_inSession?Inp_PrimaryCooldownSec:Inp_PrimaryCooldownOff;
      if(TimeCurrent()-m_lastPrimaryTime<cooldown) return;

      ENUM_ORDER_TYPE initType;
      if(m_mkt.trendConfirmed==1)         initType=ORDER_TYPE_BUY;
      else if(m_mkt.trendConfirmed==-1)   initType=ORDER_TYPE_SELL;
      else if(m_mkt.isBullish)            initType=ORDER_TYPE_BUY;
      else if(m_mkt.isBearish)            initType=ORDER_TYPE_SELL;
      else if(m_mkt.emaFast>m_mkt.emaSlow) initType=ORDER_TYPE_BUY;
      else                                initType=ORDER_TYPE_SELL;

      if(m_lastPrimaryLost&&m_lastPrimaryDir!=0){
         ENUM_ORDER_TYPE alt=(m_lastPrimaryDir==1)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
         if(initType!=alt){initType=alt;m_lastPrimaryLost=false;}
      }
      if(!ADXAllowsEntry(initType)||!TrendFilter200OK(initType)) return;
      if(!m_inSession){bool cs=(m_mkt.isBullish&&initType==ORDER_TYPE_BUY)||(m_mkt.isBearish&&initType==ORDER_TYPE_SELL);if(!cs)return;}

      double lot=NormLot(Inp_LotBase);
      m_isProcessing=true;
      ulong ticket=OpenOrder(initType,lot,"Primary_Entry");
      if(ticket>0){
         int idx=FreeRec();
         if(idx>=0){int pt=(initType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(initType==ORDER_TYPE_BUY)?ts.ask:ts.bid;InitRec(idx,ticket,pt,op,lot,"Primary_Entry",true,false,false,false);}
         m_lastPrimaryDir=(initType==ORDER_TYPE_BUY)?1:-1;
         m_lastPrimaryTime=TimeCurrent();
         m_primaryOpenTime=TimeCurrent();
         if(initType==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask; else m_lastCTSellPrice=ts.bid;
         m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
         m_blockStage=1;m_primaryType=initType;m_stageFollowHedge=false;
         m_stage1TriggerAtOpen=m_dyn.stage1Trigger;
         m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
         m_detangleDetectTime=0;m_detangleActive=false;
         DeactivateLBC();
         Print("[AQ V7.9.2-XAU] PRIMARY #",ticket," ",(initType==ORDER_TYPE_BUY?"BUY":"SELL"));
      }
      m_isProcessing=false;
      return;
   }

   if(m_blockStage>0) return; 

   ENUM_ORDER_TYPE ctType; double ctLot; int ctLevel;
   if(!ShouldOpenCT(ctType,ctLot,ctLevel)||!MarginOK(ctLot,ctType)) return;
   string ctComm="CT_"+(ctType==ORDER_TYPE_BUY?"B":"S")+"_L"+IntegerToString(ctLevel+1);
   m_isProcessing=true; ulong ticket=OpenOrder(ctType,ctLot,ctComm); m_isProcessing=false;
   if(ticket>0){
      int idx=FreeRec();
      if(idx>=0){int pt=(ctType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(ctType==ORDER_TYPE_BUY)?ts.ask:ts.bid;InitRec(idx,ticket,pt,op,ctLot,ctComm,false,true,false,false);}
      if(ctType==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask; else m_lastCTSellPrice=ts.bid;
   }
}

//=================================================================
//  [V7.9.1] NET EXPOSURE HEDGE
//=================================================================
void RunNetExposureHedge()
{
   if(!Inp_UseNetHedge||m_port.totalPos==0||m_isProcessing) return;
   double netVol=NormalizeDouble(m_port.buyVolume-m_port.sellVolume,2);
   if(MathAbs(netVol)<0.005) return;
   
   double loss=m_port.totalProfit;
   if(loss>m_dyn.netHedgeTrig1) return;
   if(TimeCurrent()-m_lastNetHedgeTime<Inp_NetHedgeIntervalSec||!SpreadOK()) return;
   
   ENUM_ORDER_TYPE hedgeType=(netVol>0)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (volStep <= 0) volStep = 0.01;

   if(loss<=m_dyn.netHedgeTrig2&&!m_netHedge2Applied){
      double pct=m_netHedge1Applied?0.50:0.0;
      double hedgeLot=MaxSafeLot(MathAbs(netVol)*(1.0-pct),hedgeType);
      
      if(hedgeLot>0) {
         if(!AntiSymmetricOK(hedgeType, hedgeLot)) {
            hedgeLot = NormLot(hedgeLot + volStep);
            Print("[AQ V7.9.2-XAU] NET HEDGE L2 ADJUSTED to prevent 0.00 Net Volume.");
         }
         
         if(MarginOK_Hedge(hedgeLot,hedgeType)){
            m_isProcessing=true;ulong ticket=OpenOrder(hedgeType,hedgeLot,"NET_HEDGE_L2",true);m_isProcessing=false;
            if(ticket>0){m_netHedge2Applied=m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();
               MqlTick tk;GetTick(tk);int idx=FreeRec();
               if(idx>=0){int pt=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,ticket,pt,op,hedgeLot,"NET_HEDGE_L2",false,false,true,false);}
               Print("[AQ V7.9.2-XAU] NET HEDGE L2 | PnL=$",NormalizeDouble(loss,2));}
         }
      }
      return;
   }
   
   if(loss<=m_dyn.netHedgeTrig1&&!m_netHedge1Applied){
      double hedgeLot=MaxSafeLot(MathAbs(netVol)*0.50,hedgeType);
      
      if(hedgeLot>0) {
         if(!AntiSymmetricOK(hedgeType, hedgeLot)) {
            hedgeLot = NormLot(hedgeLot + volStep);
            Print("[AQ V7.9.2-XAU] NET HEDGE L1 ADJUSTED to prevent 0.00 Net Volume.");
         }

         if(MarginOK_Hedge(hedgeLot,hedgeType)){
            m_isProcessing=true;ulong ticket=OpenOrder(hedgeType,hedgeLot,"NET_HEDGE_L1",true);m_isProcessing=false;
            if(ticket>0){m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();
               MqlTick tk;GetTick(tk);int idx=FreeRec();
               if(idx>=0){int pt=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,ticket,pt,op,hedgeLot,"NET_HEDGE_L1",false,false,true,false);}
               Print("[AQ V7.9.2-XAU] NET HEDGE L1 | PnL=$",NormalizeDouble(loss,2));}
         }
      }
   }
}

//=================================================================
//  VOLATILITY STORM FILTER
//=================================================================
double CalcAvgATR(int wb)
{
   if(wb<=0||h_ATR==INVALID_HANDLE) return 0;
   double buf[];ArraySetAsSeries(buf,true);
   if(CopyBuffer(h_ATR,0,1,wb,buf)<wb) return 0;
   double s=0;for(int i=0;i<wb;i++)s+=buf[i];return s/wb;
}
double CalcAvgSpread(int wb)
{
   if(wb<=0) return(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   MqlRates r[];ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,PERIOD_M1,1,wb,r)<wb) return(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   double s=0;for(int i=0;i<wb;i++)s+=(r[i].high-r[i].low)/_Point;return s/wb;
}
void RunVolatilityStormFilter()
{
   if(!Inp_UseStormFilter){m_stormActive=false;return;}
   double atrNow=m_mkt.atr; if(atrNow<=0) return;
   double atrAvg=CalcAvgATR(Inp_StormATRWindow); bool atrStorm=false;
   if(atrAvg>0){m_stormLastATRRatio=atrNow/atrAvg;atrStorm=(m_stormLastATRRatio>=Inp_StormATRMult);}
   double sprNow=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   double sprAvg=CalcAvgSpread(Inp_StormSpreadWindow); bool sprStorm=false;
   if(sprAvg>0){m_stormLastSprRatio=sprNow/sprAvg;sprStorm=(sprNow/(double)MathMax(Inp_MaxSpread,1)>Inp_StormSpreadMult*0.5);}
   bool stormNow=(atrStorm||sprStorm);
   if(stormNow&&!m_stormActive){m_stormActive=true;m_stormDetectedTime=TimeCurrent();Print("[AQ V7.9.2-XAU] TORMENTA | ATRx=",NormalizeDouble(m_stormLastATRRatio,2));}
   if(m_stormActive){if(TimeCurrent()-m_stormDetectedTime>=Inp_StormCooldownSec){if(!stormNow){m_stormActive=false;Print("[AQ V7.9.2-XAU] TORMENTA DESPEJADA");}else m_stormDetectedTime=TimeCurrent();}}
}

ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   if((bool)MQLInfoInteger(MQL_TESTER)) return ORDER_FILLING_RETURN;
   long filling=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((filling&SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
   if((filling&SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//=================================================================
//  DASHBOARD V7.9.1
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
      "AQ79_BG","AQ79_HDR","AQ79_SEP1","AQ79_STATE","AQ79_REASON",
      "AQ79_SEP2","AQ79_S1","AQ79_S2","AQ79_S3","AQ79_S4","AQ79_S5",
      "AQ79_SEP_DYN","AQ79_SESS","AQ79_DYN1","AQ79_DYN2",
      "AQ79_SEP_ASYM","AQ79_ASYM1","AQ79_ASYM2",
      "AQ79_SEP_TK","AQ79_TEMA","AQ79_STAGE",
      "AQ79_SEP4","AQ79_ACC","AQ79_SEP5","AQ79_PNL","AQ79_POS",
      "AQ79_VWAP","AQ79_REC","AQ79_NH","AQ79_SF",
      "AQ79_SEP6","AQ79_HIST","AQ79_SEP7","AQ79_DIAG","AQ79_B1","AQ79_B2"
   };
   for(int i=0;i<ArraySize(names);i++) ObjectDelete(0,names[i]);
}

void UpdateDash()
{
   if(!Inp_ShowDashboard||TimeCurrent()-m_lastDashTime<1) return;
   m_lastDashTime=TimeCurrent();
   color cBG=C'8,8,12',cBord=C'70,70,70',cGray=C'120,120,130';
   color cGreen=C'0,220,80',cRed=C'220,50,50',cOra=C'220,150,30';
   color cYel=C'200,200,50',cCyan=C'50,190,220',cMint=C'0,200,150',cPurp=C'160,80,220';
   int x0=Inp_DashX,y0=Inp_DashY,lh=16,pad=8,w=580,h=46*lh+60;
   AQPanel("AQ79_BG",x0-pad,y0-pad,w,h);
   int x=x0,y=y0;

   AQLbl("AQ79_HDR","[ "+VERSION_STR+" ]  "+_Symbol+"  |  DIRECTIONAL ASYMMETRIC RECOVERY",x,y,cGreen,10,true);
   y+=lh+2;
   AQLbl("AQ79_SEP1","────────────────────────────────────────────────────────────────────────",x,y,cBord,8);
   y+=lh-4;

   string stateStr;color stateC;
   if(m_emergencyMode)    {stateStr="[ ALERTA EQUITY — RECOVERY ACTIVO ]";stateC=cRed;}
   else if(m_dailyLimitHit){stateStr="[ LIMITE DIARIO — GESTION CONTINUA ]";stateC=cOra;}
   else if(m_lbc.active) {stateStr="[ MODO LBC ACTIVO — MICRO-GRID ]";stateC=cOra;}
   else if(m_detangleActive){stateStr="[ DETANGLE ACTIVO — ROMPIENDO SIMETRIA ]";stateC=cPurp;}
   else if(m_blockStage>=2){
      string sn[]={"","PRIMARY","HEDGE/REINF","3RA_DIR","CON_MAX"};
      stateStr="[ BSE STAGE "+IntegerToString(MathMin(m_blockStage,4))+": "+sn[MathMin(m_blockStage,4)]+(m_stageFollowHedge?" (vs.primaria)":"")+" ]";
      stateC=cYel;
   }
   else if(m_blockStage==1){stateStr="[ BSE STAGE 1: PRIMARIA — Breathing "+IntegerToString(Inp_PrimaryMinHoldSec)+"s ]";stateC=cCyan;}
   else if(m_recoveryActive){stateStr="[ RECOVERY FALLBACK ]";stateC=cYel;}
   else if(m_cycleInPause) {stateStr="[ PAUSA ENTRE CICLOS ]";stateC=cGray;}
   else if(m_isPaused)     {stateStr="[ PAUSADO — RECOVERY OPERA ]";stateC=cYel;}
   else if(!m_sensors.allOK){stateStr="[ BUSCANDO CONDICIONES ]";stateC=cGray;}
   else                    {stateStr="[ BUSCANDO ENTRADA PRIMARIA ]";stateC=cGreen;}
   AQLbl("AQ79_STATE",stateStr,x,y,stateC,10,true);
   y+=lh+2;
   string diagStr="";
   if(!m_sensors.allOK&&m_port.totalPos==0) diagStr="  Bloqueo: "+m_sensors.blockReason;
   else if(m_port.totalPos>0&&m_port.totalProfit<0) diagStr="  Bloque en perdida | Sesgo neto: "+DoubleToString(m_port.buyVolume-m_port.sellVolume,3)+" lotes";
   AQLbl("AQ79_REASON",diagStr,x,y,cGray,8);
   y+=lh-2;

   AQLbl("AQ79_SEP2","── SENSORES ──────────────────────────────────────────────────────────",x,y,C'50,50,80',8);
   y+=lh-3;
   int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   string ratioStr=(m_mkt.atrSlow>0)?DoubleToString(m_sensors.atrRatio,2):"N/A";
   AQLbl("AQ79_S1","TIME:"+(m_sensors.timeOK?"PASS":"WAIT"),x,y,m_sensors.timeOK?cGreen:cRed,9);
   AQLbl("AQ79_S2","SPR:"+(m_sensors.spreadOK?"PASS("+IntegerToString(cs)+")":"ALTO("+IntegerToString(cs)+")"),x+110,y,m_sensors.spreadOK?cGreen:cRed,9);
   AQLbl("AQ79_S3","TEND:"+(m_sensors.trendBull?"BULL":"BEAR"),x+240,y,m_sensors.trendBull?cGreen:cOra,9);
   AQLbl("AQ79_S4","VOLAT:"+(m_sensors.volatOK?"OK("+ratioStr+")":"STORM("+ratioStr+")"),x+350,y,m_sensors.volatOK?cGreen:cRed,9);
   y+=lh-1;
   AQLbl("AQ79_S5","MARG:"+(m_sensors.marginOK?"PASS":"WAIT"),x,y,m_sensors.marginOK?cGreen:cOra,9);
   y+=lh;

   AQLbl("AQ79_SEP_DYN","── V7.8 DYNAMIC ENGINE ──────────────────────────────────────────────",x,y,C'30,60,50',8);
   y+=lh-3;
   color sessC=(m_dyn.session==SESSION_OVERLAP)?cRed:(m_dyn.session==SESSION_NY)?cOra:(m_dyn.session==SESSION_LONDON)?cGreen:cGray;
   AQLbl("AQ79_SESS","SESION:"+SessionName(m_dyn.session)+"  Factor="+DoubleToString(m_dyn.sessionFactor,2)+"  VOL:"+VolRegimeName(m_dyn.volRegime)+"  ATR2USD="+DoubleToString(m_dyn.atr2usd,3)+"  RecovDist="+DoubleToString(m_dyn.recovDistATR,2)+"xATR",x,y,sessC,9);
   y+=lh-1;
   AQLbl("AQ79_DYN1","DYN TRIG  Stage1="+DoubleToString(m_dyn.stage1Trigger,2)+"  Stage3="+DoubleToString(m_dyn.stage3Trigger,2)+"  BlockTP=+"+DoubleToString(m_dyn.blockTP,2)+"  RecovTrig="+DoubleToString(m_dyn.recovTrigger,2),x,y,cMint,9);
   y+=lh-1;
   AQLbl("AQ79_DYN2","NET HEDGE  L1="+DoubleToString(m_dyn.netHedgeTrig1,2)+"  L2="+DoubleToString(m_dyn.netHedgeTrig2,2)+"  Floors: S1="+DoubleToString(Inp_Stage1Trigger,2)+" S3="+DoubleToString(Inp_Stage3Trigger,2)+" TP="+DoubleToString(Inp_BlockTPTarget,2),x,y,cGray,8);
   y+=lh;

   AQLbl("AQ79_SEP_ASYM","── V7.9 ASYMMETRIC ENGINE ───────────────────────────────────────────",x,y,C'60,30,60',8);
   y+=lh-3;
   int holdNow=(m_primaryOpenTime>0)?(int)(TimeCurrent()-m_primaryOpenTime):0;
   bool breathOK=(holdNow>=Inp_PrimaryMinHoldSec||m_primaryOpenTime==0);
   double netV=m_port.buyVolume-m_port.sellVolume;
   AQLbl("AQ79_ASYM1","Breathing:"+IntegerToString(holdNow)+"s/"+IntegerToString(Inp_PrimaryMinHoldSec)+"s ["+(breathOK?"LISTO":"ESPERANDO")+"]  HedgeRatio="+DoubleToString(Inp_HedgeRatio,2)+"x  DirectStage:"+string(Inp_UseDirectionalStage?"ON":"OFF"),x,y,breathOK?cGreen:cCyan,9);
   y+=lh-1;
   bool isSym=(MathAbs(netV)<Inp_DetangleNetThresh);
   color symC=isSym?(m_detangleActive?cPurp:cOra):cGreen;
   int detTime=(m_detangleDetectTime>0)?(int)(TimeCurrent()-m_detangleDetectTime):0;
   AQLbl("AQ79_ASYM2","NetVol="+DoubleToString(netV,3)+" lotes ["+(isSym?"SIMETRICO":"DIRECCIONAL")+"]  "+
         (m_detangleActive?"DETANGLE:"+IntegerToString(detTime)+"s/"+IntegerToString(Inp_DetangleSec)+"s":"Detangle:standby"),x,y,symC,9);
   y+=lh;

   AQLbl("AQ79_SEP_TK","── V7.7 TEMA+KALMAN + BLOCK STAGE ──────────────────────────────────",x,y,C'30,60,60',8);
   y+=lh-3;
   string trendLabel=(m_mkt.trendConfirmed==1)?"BULL CONFIRMADO":(m_mkt.trendConfirmed==-1)?"BEAR CONFIRMADO":"NEUTRAL";
   color trendLbC=(m_mkt.trendConfirmed==1)?cGreen:(m_mkt.trendConfirmed==-1)?cRed:cGray;
   AQLbl("AQ79_TEMA","TEMA+KAL:"+(Inp_UseTEMAKalman?"ON":"OFF")+"  Trend="+trendLabel+"  TEMAf="+DoubleToString(m_mkt.temaFast,_Digits)+" TEMAs="+DoubleToString(m_mkt.temaSlow,_Digits)+"  Kalf="+DoubleToString(m_mkt.kalmanFast,_Digits)+" Kals="+DoubleToString(m_mkt.kalmanSlow,_Digits),x,y,trendLbC,9);
   y+=lh-1;
   string stgNames[]={"INACTIVO","PRIMARIA 0.01","HEDGE ASIM/REINF","3RA DIRECCIONAL","CONSOLIDACION"};
   int si2=MathMax(0,MathMin(m_blockStage,4));
   color stgC=(m_blockStage==0)?cGray:(m_blockStage==1)?cCyan:(m_blockStage==2)?cOra:(m_blockStage==3)?cYel:cRed;
   int mainPCnt=m_port.totalPos-m_port.lbcCount;
   string tInfo="";
   if(m_blockStage==1) tInfo="  DynTrig="+DoubleToString(m_stage1TriggerAtOpen,2)+"  Hold="+IntegerToString(holdNow)+"s  PnL="+DoubleToString(m_port.totalProfit,2);
   else if(m_blockStage==2) tInfo="  Delay="+IntegerToString((int)(TimeCurrent()-m_stage2Time))+"s/"+IntegerToString(m_dyn.stage2Delay)+"s  mainPos="+IntegerToString(mainPCnt);
   else if(m_blockStage==3) tInfo="  DynTrig3="+DoubleToString(m_stage3TriggerAtOpen,2)+"  NetVol="+DoubleToString(netV,3);
   else if(m_blockStage==4) tInfo="  MAX esperando DynTP="+DoubleToString(m_dyn.blockTP,2);
   AQLbl("AQ79_STAGE","STAGE "+IntegerToString(si2)+": "+stgNames[si2]+tInfo,x,y,stgC,9);
   y+=lh;

   AQLbl("AQ79_SEP4","── CUENTA ───────────────────────────────────────────────────────────",x,y,C'50,50,80',8);
   y+=lh-3;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE),eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE),ddPct=m_port.currentDD*100.0;
   AQLbl("AQ79_ACC","Saldo:$"+DoubleToString(bal,2)+"  Equity:$"+DoubleToString(eq,2)+"  LibreMarg:$"+DoubleToString(free,2)+"  DD:"+DoubleToString(ddPct,1)+"%",x,y,cCyan,9);
   y+=lh;

   AQLbl("AQ79_SEP5","── BLOQUE ACTIVO ───────────────────────────────────────────────────",x,y,C'50,50,80',8);
   y+=lh-3;
   double pnl=m_port.totalProfit,falta=MathMax(0,m_dyn.blockTP-pnl);
   AQLbl("AQ79_PNL","PnL:"+((pnl>=0)?"+":"")+DoubleToString(pnl,2)+"  DynTP:+"+DoubleToString(m_dyn.blockTP,2)+"  Falta:$"+DoubleToString(falta,2),x,y,(pnl>=0)?cGreen:cRed,9);
   y+=lh-1;
   AQLbl("AQ79_POS","Pos:"+IntegerToString(m_port.totalPos)+" (main:"+IntegerToString(mainPCnt)+" lbc:"+IntegerToString(m_port.lbcCount)+")  BUY:"+IntegerToString(m_port.buyCount)+"($"+DoubleToString(m_port.buyProfit,2)+")  SELL:"+IntegerToString(m_port.sellCount)+"($"+DoubleToString(m_port.sellProfit,2)+")",x,y,cCyan,9);
   y+=lh-1;
   string vStr=(m_port.blockVWAP>0)?"VWAP:"+DoubleToString(m_port.blockVWAP,_Digits)+"  Dir:"+((m_port.blockDir>0)?"LARGO":(m_port.blockDir<0)?"CORTO":"NEUTRO"):"Sin posiciones";
   AQLbl("AQ79_VWAP",vStr,x,y,cGray,9);
   y+=lh-1;
   string recStr=m_recoveryActive?"RECOVERY FB:ACTIVO ("+IntegerToString(m_recoveryOrders)+"/"+IntegerToString(Inp_RecoveryMaxOrders)+")  RecDist="+DoubleToString(m_dyn.recovDistATR,2)+"xATR":"RECOVERY FB:standby";
   string lbcStr=m_lbc.active?"  LBC:B="+IntegerToString(m_lbc.buyCount)+" S="+IntegerToString(m_lbc.sellCount)+" Cos=$"+DoubleToString(m_lbc.harvestedTotal,2)+(m_blockStage>0?"  [NO abre nuevos pares]":""):"  LBC:standby";
   AQLbl("AQ79_REC",recStr+lbcStr,x,y,m_recoveryActive?cYel:cGray,9);
   y+=lh-1;
   string nhStr;color nhC;
   if(m_netHedge2Applied){nhStr="NET HEDGE L2(100%) ACTIVO";nhC=cRed;}
   else if(m_netHedge1Applied){nhStr="NET HEDGE L1(50%) ACTIVO | L2@$"+DoubleToString(m_dyn.netHedgeTrig2,2);nhC=cOra;}
   else{nhStr="NET HEDGE:esp L1@$"+DoubleToString(m_dyn.netHedgeTrig1,2)+" L2@$"+DoubleToString(m_dyn.netHedgeTrig2,2);nhC=cGray;}
   AQLbl("AQ79_NH",nhStr,x,y,nhC,9);
   y+=lh-1;
   string sfStr;color sfC;
   if(m_stormActive){sfStr="STORM:ACTIVO ATR="+DoubleToString(m_stormLastATRRatio,2)+"x  "+IntegerToString(MathMax(0,Inp_StormCooldownSec-(int)(TimeCurrent()-m_stormDetectedTime)))+"s";sfC=cRed;}
   else{sfStr="STORM:OK ATR="+DoubleToString(m_stormLastATRRatio,2)+"x";sfC=cGray;}
   AQLbl("AQ79_SF",sfStr,x,y,sfC,9);
   y+=lh;

   AQLbl("AQ79_SEP6","── HISTORIAL ───────────────────────────────────────────────────────",x,y,C'50,50,80',8);
   y+=lh-3;
   int totalT=m_totalWins+m_totalLosses;
   double wrPct=(totalT>0)?(double)m_totalWins/totalT*100.0:0;
   AQLbl("AQ79_HIST","Win:"+DoubleToString(wrPct,1)+"% ("+IntegerToString(m_totalWins)+"/"+IntegerToString(totalT)+")  Expect:$"+DoubleToString(CalcExpectancy(),3)+"  PnL:$"+DoubleToString(m_totalPnL,2)+"  Ticks:"+IntegerToString((int)m_tickCount),x,y,(CalcExpectancy()>=0)?cGreen:cOra,9);
   y+=lh;

   AQLbl("AQ79_SEP7","── GMT / INDICADORES ───────────────────────────────────────────────",x,y,C'50,50,80',8);
   y+=lh-3;
   MqlDateTime dtNow;TimeToStruct(TimeCurrent(),dtNow);
   int sm=m_sensors.brokerStartMin,em=m_sensors.brokerEndMin;
   AQLbl("AQ79_DIAG",StringFormat("Hora:%02d:%02d  Vent:%02d:%02d-%02d:%02d",dtNow.hour,dtNow.min,sm/60,sm%60,em/60,em%60)+"  ATR:"+DoubleToString(m_mkt.atr,2)+"  EMA200:"+(m_mkt.ema200>0?DoubleToString(m_mkt.ema200,1):"..."),x,y,cGray,8);
   y+=lh+4;
   AQBtn("AQ79_B1",m_isPaused?">> REANUDAR <<":"|| PAUSAR PRIMARIAS",x,y,185,22,m_isPaused?C'180,130,0':C'0,90,40');
   AQBtn("AQ79_B2","CERRAR TODAS (MANUAL)",x+195,y,185,22,C'150,20,20');
   ChartRedraw(0);
}

//=================================================================
//  OnInit
//=================================================================
int OnInit()
{
   Print("==============================================================");
   Print("  "+VERSION_STR+" — DIRECTIONAL ASYMMETRIC RECOVERY (XAUUSD)");
   Print("  [HOTFIX] AntiSymmetric Guard: referencia corregida a VOLUME_STEP.");
   Print("  [XAU-1] Cierre fin de semana ON | Viernes >=",Inp_WeekendCloseHour,
         "h | Domingo <",Inp_WeekendReopenHour,"h | MaxSpread=",Inp_MaxSpread," pts");
   Print("  [XAU-4] MaxSafeLot ON | tope margen por orden=",NormalizeDouble(Inp_MaxSafeLotMarginPct*100,0),"% libre");
   Print("  Floors: Stage1=$",Inp_Stage1Trigger," Stage3=$",Inp_Stage3Trigger," TP=$",Inp_BlockTPTarget);
   Print("==============================================================");
   m_trade.SetExpertMagicNumber(Inp_Magic);m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);m_trade.SetTypeFilling(DetectFillingMode());
   h_ATR=iATR(_Symbol,PERIOD_M1,Inp_ATRPeriod);
   h_EMAFast=iMA(_Symbol,PERIOD_M1,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_EMASlow=iMA(_Symbol,PERIOD_M1,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_RSI=iRSI(_Symbol,PERIOD_M1,Inp_RSIPeriod,PRICE_CLOSE);
   h_MACD=iMACD(_Symbol,PERIOD_M1,Inp_MACDFast,Inp_MACDSlow,Inp_MACDSig,PRICE_CLOSE);
   if(h_ATR==INVALID_HANDLE||h_EMAFast==INVALID_HANDLE||h_EMASlow==INVALID_HANDLE||h_RSI==INVALID_HANDLE||h_MACD==INVALID_HANDLE){Print("[AQ V7.9.2-XAU] ERROR: Indicadores base");return INIT_FAILED;}
   h_ADX=iADX(_Symbol,PERIOD_M1,Inp_ADXPeriod);
   h_HTFEMAFast=iMA(_Symbol,Inp_HTFTF,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_HTFEMASlow=iMA(_Symbol,Inp_HTFTF,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_EMA200=iMA(_Symbol,PERIOD_M1,Inp_EMA200Period,0,MODE_EMA,PRICE_CLOSE);
   h_ATRSlow=iATR(_Symbol,PERIOD_M1,Inp_ATRSlowPeriod);
   for(int i=0;i<MAX_RECORDS;i++) ZeroMemory(m_rec[i]);
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
   CalcBrokerTimeWindow();SyncPositions();UpdatePortfolio();
   if(m_port.totalPos>0) Print("[AQ V7.9.2-XAU] Posiciones existentes (",m_port.totalPos,"): Stage fallback hasta nueva primaria.");
   if(m_port.lbcCount>0){m_lbc.active=true;m_lbc.activatedTime=TimeCurrent();m_lbc.maxOrdersCalc=Inp_LBCMaxPairs;}
   if(Inp_ShowDashboard){DeleteDash();UpdateDash();}
   Print("[AQ V7.9.2-XAU] LISTO | Saldo=$",m_initialBalance," | Marg0.01=$",NormalizeDouble(CalcMarginFor001(),2));
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   Print("[AQ V7.9.2-XAU] DETENIDO | PnL=$",NormalizeDouble(m_totalPnL,2)," | Trades:",m_tradesClosed);
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
   UpdateMarket();UpdateKalman();UpdatePortfolio();
   RunNetExposureHedge();
   CheckEquityGuard();
   m_inSession=IsInMainSession();ResetDailyIfNeeded();
   bool dailyPaused=DailyLimitReached();
   UpdateSensors();RunVolatilityStormFilter();

   if(m_cycleInPause){
      if(TimeCurrent()-m_cycleResetTime>=Inp_CyclePauseSec){
         m_cycleInPause=false;m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
         m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
         m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
         DeactivateLBC();
      } else {
         UpdatePortfolio();
         if(m_port.totalPos>0&&m_port.totalProfit>=m_dyn.blockTP) CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard)UpdateDash();
         return;
      }
   }

   if(m_emergencyMode){
      static datetime emgTime=0;
      UpdatePortfolio();
      if(m_port.totalPos>0&&m_port.totalProfit>=m_dyn.blockTP){CloseBlockIfPositive("Emergency_TP");m_emergencyMode=false;emgTime=0;}
      if(m_port.totalPos==0&&emgTime==0) emgTime=TimeCurrent();
      if(emgTime>0&&TimeCurrent()-emgTime>=Inp_EmergencyCooldown){m_emergencyMode=false;emgTime=0;}
      if(m_blockStage>0) RunBlockStageEngine(); else RunRecoveryEngine();
      RunLBCEngine();
      if(Inp_ShowDashboard)UpdateDash();
      return;
   }

   if(TimeCurrent()-m_lastCleanupTime>5){CleanupRecs();SyncPositions();m_lastCleanupTime=TimeCurrent();}
   ManagePositions();

   // P1: Cierre positivo
   if(m_port.totalPos>0&&m_port.totalProfit>=m_dyn.blockTP){CloseBlockIfPositive("BlockTP");if(Inp_ShowDashboard)UpdateDash();return;}

   // P2: Detangle — escape de jaula simetrica (ANTES del stage engine para romperla)
   RunDetangle();

   // P3: BSE o Recovery fallback
   if(m_blockStage>0) RunBlockStageEngine(); else RunRecoveryEngine();

   // P4: LBC (no abre nuevos pares cuando BSE activo)
   RunLBCEngine();

   // P5: Basket TP
   RunBasketTP();

   // P6: Cycle max loss
   CheckCycleMaxLoss();

   // P7: Harvest
   RunHarvest();

   // P8: CT Engine / Primary Entry
   if(!m_isPaused&&!m_recoveryActive&&!m_lbc.active&&!dailyPaused) RunCTEngine();

   if(Inp_ShowDashboard)UpdateDash();
}

//=================================================================
//  OnChartEvent
//=================================================================
void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{
   if(id==CHARTEVENT_OBJECT_CLICK){
      if(sp=="AQ79_B1"){
         m_isPaused=!m_isPaused;
         if(!m_isPaused){
            m_emergencyMode=false;m_dailyLimitHit=false;
            m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
            m_netHedge1Applied=m_netHedge2Applied=false;
            m_blockStage=0;m_stageFollowHedge=false;
            m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
            m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
            DeactivateLBC();Print("[AQ V7.9.2-XAU] SISTEMA REANUDADO");
         } else Print("[AQ V7.9.2-XAU] SISTEMA PAUSADO");
      }
      if(sp=="AQ79_B2"){
         Print("[AQ V7.9.2-XAU] CIERRE MANUAL...");int closed=0;
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
         DeactivateLBC();Print("[AQ V7.9.2-XAU] CIERRE MANUAL: ",closed," posiciones cerradas");
      }
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+