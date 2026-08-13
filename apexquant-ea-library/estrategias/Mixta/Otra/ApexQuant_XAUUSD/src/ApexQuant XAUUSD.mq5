//+------------------------------------------------------------------+
//|      DIEGO SAENZ 24H - V7.3  (FIX DEADLOCK + RECOVERY TOTAL)   |
//|                                                                  |
//|  BUGS CORREGIDOS EN V7.3:                                       |
//|                                                                  |
//|  BUG #1 — DEADLOCK PRINCIPAL (por qué se queda sola):          |
//|  Emergency mode activaba m_isPaused=true y OpenOrder bloqueaba  |
//|  recovery. Posición sola → nunca se recuperaba → pérdida ∞      |
//|  FIX: OpenOrder acepta forceEntry=true para recovery aunque     |
//|  esté en pausa/emergencia. Recovery siempre puede abrir.        |
//|                                                                  |
//|  BUG #2 — EMERGENCY MODE NO LLAMABA RECOVERY:                  |
//|  OnTick hacía return antes de RunRecoveryEngine()               |
//|  FIX: En emergency mode SE LLAMA RunRecoveryEngine() antes      |
//|  del return. La emergencia no bloquea la recuperación.          |
//|                                                                  |
//|  BUG #3 — isPaused NO SE RESETEABA AL CERRAR POSITIVO:         |
//|  CloseBlockIfPositive() y emergency TP no reseteaban isPaused   |
//|  FIX: Al cerrar el bloque positivo, isPaused=false,             |
//|  emergencyMode=false, dailyLimitHit=false                        |
//|                                                                  |
//|  BUG #4 — RECOVERY COUNTER STUCK:                              |
//|  Cuando recoveryOrders >= Max, nunca se reseteaba si el precio  |
//|  seguía moviéndose y las recovery ya estaban cerradas           |
//|  FIX: m_recoveryOrders se sincroniza con las posiciones reales  |
//|                                                                  |
//|  BUG #5 — CT ENGINE BLOQUEADO EN RECOVERY:                     |
//|  ShouldOpenCT devolvía false si recoveryActive, incluso cuando  |
//|  recovery ya estaba lleno y no podía abrir más                  |
//|  FIX: CT puede abrir cuando recovery está lleno como respaldo   |
//|                                                                  |
//|  MEJORA: Status muestra "REC-EMERG" cuando recovery opera       |
//|  en modo emergencia para visibilidad                            |
//|                                                                  |
//|  REGLAS INAMOVIBLES (sin cambios):                              |
//|  ► SL = 0 en todas las órdenes                                 |
//|  ► TP individual = 0                                            |
//|  ► ÚNICO cierre: bloque neto > BlockTPTarget                   |
//|  ► DailyLimit / EquityGuard = solo pausa, NUNCA cierra         |
//+------------------------------------------------------------------+
#property copyright "DiegoSaenz Recovery EA V7.3"
#property version   "7.30"
#property strict
#property description "XAUUSD 24/7 | Recovery matemático | NUNCA cierra en negativo | V7.3 Fix Deadlock"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS   60
#define VERSION_STR   "DS_24H_V7.3"

enum ENUM_CT_MODE { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };

//=================================================================
//  PARÁMETROS
//=================================================================
input group "═══ CONFIGURACIÓN PRINCIPAL ═══"
input long   Inp_Magic               = 7001;
input int    Inp_MaxPositionsTotal   = 8;
input double Inp_LotBase             = 0.01;
input double Inp_LotMaximum          = 0.10;
input double Inp_RiskPerTradePct     = 0.01;
input bool   Inp_UseDynamicLot       = true;
input double Inp_CTMinBalanceUSD     = 40.0;
input double Inp_MinFreeMarginPct    = 0.20;

input group "═══ CIERRE DEL BLOQUE — ÚNICO MODO DE CIERRE ═══"
input double Inp_BlockTPTarget       = 0.30;
input double Inp_TP_ATR              = 2.5;
input double Inp_SL_ATR              = 1.2;
input double Inp_OffSessionTP_ATR    = 2.2;
input double Inp_OffSessionSL_ATR    = 1.0;

input group "═══ RECOVERY ENGINE V7.3 ═══"
input double Inp_RecoveryTriggerUSD  = -0.80;
input double Inp_RecoveryMinDistATR  = 1.5;
input double Inp_RecoveryMoveATR     = 0.5;
input double Inp_RecoveryMinLotMult  = 2.0;
input int    Inp_RecoveryMaxOrders   = 3;
input int    Inp_RecoveryIntervalSec = 15;
// V7.3: Tiempo máximo bloqueado antes de resetear contador recovery
input int    Inp_RecoveryStuckSec    = 90;   // Si stuck >90s, resetea contador
input int    Inp_RecoveryMaxResets   = 5;    // Máximo de resets por ciclo

input group "═══ COUNTER-TRADE ENGINE ═══"
input ENUM_CT_MODE Inp_CTMode        = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR       = 1.2;
input int    Inp_CTFixedPoints       = 100;
input int    Inp_CTIntervalSec       = 10;
input int    Inp_CTMaxSameDir        = 3;
input int    Inp_PrimaryCooldownSec  = 90;
input int    Inp_PrimaryCooldownOff  = 150;
input double Inp_CTMaxSpreadPoints   = 30;
input double Inp_CTMaxSpreadOff      = 20;

input group "═══ SESIONES ═══"
input int    Inp_GMTOffset           = 0;
input int    Inp_LondonOpen          = 7;
input int    Inp_LondonClose         = 17;
input int    Inp_NYOpen              = 13;
input int    Inp_NYClose             = 22;
input double Inp_OffSessionLotFactor = 0.50;

input group "═══ BASKET TP ═══"
input bool   Inp_UseBasketTP         = true;
input double Inp_BasketTPFactor      = 0.60;
input double Inp_BasketTPRatio       = 1.5;
input int    Inp_BasketCheckSec      = 3;

input group "═══ HARVEST ═══"
input double Inp_HarvestMinUSD       = 0.80;
input double Inp_HarvestATRMult      = 0.20;
input bool   Inp_HarvestContinuous   = true;
input int    Inp_HarvestIntervalSec  = 3;

input group "═══ CYCLE CONTROL ═══"
input bool   Inp_UseCycleMaxLoss     = true;
input double Inp_CycleMaxLossUSD     = -3.00;
input int    Inp_CyclePauseSec       = 30;

input group "═══ ADX + HTF ═══"
input bool   Inp_UseADX              = true;
input int    Inp_ADXPeriod           = 14;
input double Inp_ADXTrendLevel       = 30.0;
input double Inp_ADXTrendLevelOff    = 22.0;
input bool   Inp_UseHTF              = true;
input ENUM_TIMEFRAMES Inp_HTFTF      = PERIOD_M5;

input group "═══ PROTECCIÓN DIARIA (solo pausa) ═══"
input bool   Inp_UseDailyLimit       = true;
input double Inp_DailyLossUSD        = -5.0;
input double Inp_DailyLossPct        = 0.025;
input int    Inp_LossStreakMax        = 4;
input double Inp_LossStreakReduce     = 0.70;

input group "═══ EQUITY GUARD (solo pausa) ═══"
input bool   Inp_UseEquityGuard      = true;
input double Inp_EmergencyLossUSD    = -8.0;
input double Inp_MaxDrawdownPct      = 0.20;
input int    Inp_EmergencyCooldown   = 180;

input group "═══ INDICADORES ═══"
input int    Inp_ATRPeriod           = 14;
input int    Inp_EMAFast             = 21;
input int    Inp_EMASlow             = 55;
input int    Inp_RSIPeriod           = 7;
input int    Inp_MACDFast            = 12;
input int    Inp_MACDSlow            = 26;
input int    Inp_MACDSig             = 9;

input group "═══ CONTROL ═══"
input int    Inp_MaxSpread           = 35;
input bool   Inp_ShowDashboard       = true;
input int    Inp_DashX               = 12;
input int    Inp_DashY               = 28;

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
   double currentDD;
};

struct MarketSnap {
   double bid, ask, atr, emaFast, emaSlow, rsi, macdMain, macdSig, adx, spread;
   int    htfTrend;
   bool   isBullish, isBearish;
};

//=================================================================
//  HANDLES Y ESTADO GLOBAL
//=================================================================
int h_ATR, h_EMAFast, h_EMASlow, h_RSI, h_MACD;
int h_ADX = INVALID_HANDLE;
int h_HTFEMAFast = INVALID_HANDLE, h_HTFEMASlow = INVALID_HANDLE;

CTrade    m_trade;
PosRecord m_rec[MAX_RECORDS];
Portfolio m_port;
MarketSnap m_mkt;

double   m_initialBalance  = 0;
double   m_bestEquity      = 0;
bool     m_isPaused        = false;
bool     m_emergencyMode   = false;
bool     m_dailyLimitHit   = false;
bool     m_inSession       = false;
bool     m_recoveryActive  = false;
int      m_recoveryOrders  = 0;

// V7.3: Control de recovery stuck
datetime m_recoveryStuckTime  = 0;
int      m_recoveryResetCount = 0;

double   m_cycleWinsSum    = 0;
int      m_cycleWinsCount  = 0;
double   m_cycleLossSum    = 0;
bool     m_cycleInPause    = false;
datetime m_cycleResetTime  = 0;

int      m_consecutiveLosses = 0;
double   m_lotMultiplier     = 1.0;
double   m_dailyBalance      = 0;
datetime m_lastDailyReset    = 0;

int      m_lastPrimaryDir    = 0;
datetime m_lastPrimaryTime   = 0;
bool     m_lastPrimaryLost   = false;

double   m_lastCTBuyPrice    = 0;
double   m_lastCTSellPrice   = 0;
datetime m_lastCTTime        = 0;
datetime m_lastRecoveryTime  = 0;
datetime m_lastBasketCheck   = 0;
datetime m_lastHarvestTime   = 0;
datetime m_lastDashTime      = 0;
datetime m_lastCleanupTime   = 0;

double   m_totalPnL          = 0;
int      m_tradesOpened      = 0;
int      m_tradesClosed      = 0;
double   m_bestClosed        = 0;
double   m_worstClosed       = 0;
long     m_tickCount         = 0;
bool     m_isProcessing      = false;

double   m_losingPosOpenPrice = 0;
int      m_losingPosType      = -1;

//=================================================================
//  HELPERS
//=================================================================
double NormLot(double lot) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), Inp_LotMaximum);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   return NormalizeDouble(MathMax(minL, MathMin(maxL, lot)), 2);
}

double NormPrice(double p) { return NormalizeDouble(p, _Digits); }
bool GetTick(MqlTick &t)   { return SymbolInfoTick(_Symbol, t); }

double GetATR() {
   double b[1];
   if(CopyBuffer(h_ATR, 0, 1, 1, b) == 1) return b[0];
   return _Point * 200;
}

double GetTickVal()  { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); }
double GetTickSize() { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); }

double DistToUSD(double dist, double lot) {
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv <= 0 || ts <= 0 || dist <= 0 || lot <= 0) return 0;
   return NormalizeDouble((dist / ts) * tv * lot, 2);
}

double ProfitPerLotPerPoint() {
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv <= 0 || ts <= 0) return 1.0;
   return tv / ts;
}

bool SpreadOK() {
   int maxSpr = m_inSession ? Inp_MaxSpread : (int)Inp_CTMaxSpreadOff;
   return (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= maxSpr);
}

bool MarginOK(double lot, ENUM_ORDER_TYPE type) {
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < Inp_CTMinBalanceUSD) return false;
   if(free < eq * Inp_MinFreeMarginPct) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marg))
      if(marg > free * 0.60) return false;
   return true;
}

//=================================================================
//  RECORDS
//=================================================================
int FindRec(ulong ticket) {
   for(int i = 0; i < MAX_RECORDS; i++)
      if(m_rec[i].ticket == ticket) return i;
   return -1;
}

int FreeRec() {
   for(int i = 0; i < MAX_RECORDS; i++)
      if(m_rec[i].ticket == 0) return i;
   return -1;
}

void InitRec(int idx, ulong ticket, int posType, double openPrice, double vol,
             string comment, bool isPrimary, bool isCounter, bool isRecovery = false) {
   if(idx < 0 || idx >= MAX_RECORDS) return;
   ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket     = ticket;
   m_rec[idx].posType    = posType;
   m_rec[idx].openPrice  = openPrice;
   m_rec[idx].volume     = vol;
   m_rec[idx].openTime   = TimeCurrent();
   m_rec[idx].comment    = comment;
   m_rec[idx].isPrimary  = isPrimary;
   m_rec[idx].isCounter  = isCounter;
   m_rec[idx].isRecovery = isRecovery;
   m_rec[idx].kP         = 1.0;
   m_rec[idx].kK         = 1.0;
}

void CleanupRecs() {
   for(int i = 0; i < MAX_RECORDS; i++) {
      if(m_rec[i].ticket == 0) continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)) {
         double pnl = m_rec[i].netProfit;
         if(pnl != 0) {
            m_totalPnL += pnl;
            m_tradesClosed++;
            if(pnl > m_bestClosed)  m_bestClosed  = pnl;
            if(pnl < m_worstClosed) m_worstClosed = pnl;
         }
         ZeroMemory(m_rec[i]);
      }
   }
}

void SyncPositions() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(FindRec(t) >= 0) continue;
      int idx = FreeRec(); if(idx < 0) continue;
      int    pt   = (int)PositionGetInteger(POSITION_TYPE);
      double op   = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      string comm = PositionGetString(POSITION_COMMENT);
      bool isPri  = (StringFind(comm, "Primary") >= 0);
      bool isCT   = (StringFind(comm, "CT_")     >= 0);
      bool isRec  = (StringFind(comm, "REC_")    >= 0);
      InitRec(idx, t, pt, op, vol, comm, isPri, isCT, isRec);
   }
}

//=================================================================
//  KALMAN
//=================================================================
void KalmanUpdate(int idx, double meas) {
   if(!m_rec[idx].kInit) {
      m_rec[idx].kX = meas; m_rec[idx].kP = 1.0;
      m_rec[idx].kK = 1.0;  m_rec[idx].kInit = true;
      return;
   }
   double pP = m_rec[idx].kP + 0.01;
   double K  = pP / (pP + 0.20);
   m_rec[idx].kX = m_rec[idx].kX + K * (meas - m_rec[idx].kX);
   m_rec[idx].kP = (1.0 - K) * pP;
   m_rec[idx].kK = K;
}

void UpdateKalman() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      int idx = FindRec(t); if(idx < 0) continue;
      double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit = pf;
      if(pf > m_rec[idx].peakProfit) m_rec[idx].peakProfit = pf;
      KalmanUpdate(idx, pf);
   }
}

//=================================================================
//  SESIÓN
//=================================================================
bool IsInMainSession() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   int gmtHour = (dt.hour - Inp_GMTOffset + 24) % 24;
   return ((gmtHour >= Inp_LondonOpen && gmtHour < Inp_LondonClose) ||
           (gmtHour >= Inp_NYOpen     && gmtHour < Inp_NYClose));
}

double GetSessionQuality() {
   if(m_inSession) return 1.0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = (dt.hour - Inp_GMTOffset + 24) % 24;
   return (h >= 0 && h < Inp_LondonOpen) ? 0.4 : 0.6;
}

//=================================================================
//  MERCADO Y PORTFOLIO
//=================================================================
void UpdateMarket() {
   MqlTick t; if(!GetTick(t)) return;
   m_mkt.bid    = t.bid;
   m_mkt.ask    = t.ask;
   m_mkt.spread = (t.ask - t.bid) / _Point;
   m_mkt.atr    = GetATR();

   double f[1], s[1], r[1], m[1], sg[1];
   if(CopyBuffer(h_EMAFast, 0, 0, 1, f)  == 1) m_mkt.emaFast  = f[0];
   if(CopyBuffer(h_EMASlow, 0, 0, 1, s)  == 1) m_mkt.emaSlow  = s[0];
   if(CopyBuffer(h_RSI,     0, 0, 1, r)  == 1) m_mkt.rsi      = r[0];
   if(CopyBuffer(h_MACD,    0, 0, 1, m)  == 1) m_mkt.macdMain = m[0];
   if(CopyBuffer(h_MACD,    1, 0, 1, sg) == 1) m_mkt.macdSig  = sg[0];
   if(h_ADX != INVALID_HANDLE) {
      double adxB[1];
      if(CopyBuffer(h_ADX, 0, 0, 1, adxB) == 1) m_mkt.adx = adxB[0];
   }
   if(h_HTFEMAFast != INVALID_HANDLE && h_HTFEMASlow != INVALID_HANDLE) {
      double hf[1], hs[1];
      if(CopyBuffer(h_HTFEMAFast, 0, 0, 1, hf) == 1 &&
         CopyBuffer(h_HTFEMASlow, 0, 0, 1, hs) == 1) {
         m_mkt.htfTrend = (hf[0] > hs[0] * 1.0001) ? 1 : (hf[0] < hs[0] * 0.9999) ? -1 : 0;
      }
   }
   m_mkt.isBullish = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.rsi > 52 && m_mkt.macdMain > m_mkt.macdSig);
   m_mkt.isBearish = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.rsi < 48 && m_mkt.macdMain < m_mkt.macdSig);
}

void UpdatePortfolio() {
   ZeroMemory(m_port);
   m_port.worstProfit     = 0;
   m_losingPosOpenPrice   = 0;
   m_losingPosType        = -1;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;

      int    pt   = (int)PositionGetInteger(POSITION_TYPE);
      double pf   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      string comm = PositionGetString(POSITION_COMMENT);

      m_port.totalPos++;
      m_port.totalProfit += pf;
      if(pf >= 0) m_port.positiveSum += pf;
      else        m_port.negativeSum += MathAbs(pf);

      if(pt == POSITION_TYPE_BUY) { m_port.buyCount++;  m_port.buyProfit  += pf; }
      else                        { m_port.sellCount++; m_port.sellProfit += pf; }

      if(pf < m_port.worstProfit) {
         m_port.worstProfit     = pf;
         m_port.worstTicket     = t;
         m_losingPosOpenPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
         m_losingPosType        = pt;
      }
      if(StringFind(comm, "CT_")  >= 0) m_port.ctCount++;
      if(StringFind(comm, "REC_") >= 0) m_port.recoveryCount++;
   }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > m_bestEquity) m_bestEquity = eq;
   m_port.currentDD = (m_bestEquity > 0) ? (m_bestEquity - eq) / m_bestEquity : 0;
}

//=================================================================
//  ADX
//=================================================================
bool ADXAllowsEntry(ENUM_ORDER_TYPE type) {
   if(!Inp_UseADX) return true;
   double adxLevel = m_inSession ? Inp_ADXTrendLevel : Inp_ADXTrendLevelOff;
   if(m_mkt.adx < adxLevel) return true;
   int htf = m_mkt.htfTrend;
   if(htf == 0) return false;
   return (type == ORDER_TYPE_BUY && htf == 1) || (type == ORDER_TYPE_SELL && htf == -1);
}

//=================================================================
//  DIARIO
//=================================================================
void ResetDailyIfNeeded() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int sec = dt.hour * 3600 + dt.min * 60 + dt.sec;
   datetime midnight = TimeCurrent() - sec;
   if(m_lastDailyReset < midnight) {
      m_dailyBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      m_dailyLimitHit  = false;
      m_lastDailyReset = midnight;
      // V7.3: Reset diario también limpia pausa por límite diario
      if(m_isPaused && !m_emergencyMode) {
         m_isPaused = false;
         Print(">>> V7.3: Reset diario - pausa levantada");
      }
   }
}

bool DailyLimitReached() {
   if(!Inp_UseDailyLimit) return false;
   if(m_dailyLimitHit) return true;
   double eff = (AccountInfoDouble(ACCOUNT_BALANCE) - m_dailyBalance) + m_port.totalProfit;
   double lim = MathMin(MathAbs(Inp_DailyLossUSD), m_dailyBalance * MathAbs(Inp_DailyLossPct));
   if(eff <= -lim) {
      Print(">>> LÍMITE DIARIO V7.3: pausa nuevas entradas, recovery SIGUE activo");
      m_dailyLimitHit = true;
      m_isPaused      = true;
   }
   return m_dailyLimitHit;
}

void UpdateStreak(double pnl) {
   if(pnl < -0.01) {
      m_consecutiveLosses++;
      if(m_consecutiveLosses >= Inp_LossStreakMax && m_lotMultiplier == 1.0)
         m_lotMultiplier = Inp_LossStreakReduce;
   } else if(pnl > 0.01) {
      m_lotMultiplier     = 1.0;
      m_consecutiveLosses = 0;
   }
}

//=================================================================
//  CIERRE
//=================================================================
bool ClosePos(ulong ticket, string reason = "") {
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) return false;
   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)) {
      UpdateStreak(pf);
      if(pf > 0) { m_cycleWinsSum += pf; m_cycleWinsCount++; }
      else         m_cycleLossSum += pf;
      m_totalPnL += pf; m_tradesClosed++;
      if(pf > m_bestClosed)  m_bestClosed  = pf;
      if(pf < m_worstClosed) m_worstClosed = pf;
      int idx = FindRec(ticket);
      if(idx >= 0) {
         if(m_rec[idx].isPrimary) m_lastPrimaryLost = (pf < 0);
         Print(">>> CERRADA V7.3 #", ticket, " $", NormalizeDouble(pf, 2),
               (reason != "" ? " [" + reason + "]" : ""));
         ZeroMemory(m_rec[idx]);
      }
      return true;
   }
   return false;
}

// ╔══════════════════════════════════════════════════════════════╗
// ║  V7.3: CloseBlockIfPositive resetea TODOS los flags         ║
// ╚══════════════════════════════════════════════════════════════╝
bool CloseBlockIfPositive(string reason) {
   if(m_port.totalProfit < Inp_BlockTPTarget) return false;
   Print(">>> ✅ CIERRE POSITIVO V7.3: PnL=$", NormalizeDouble(m_port.totalProfit, 2),
         " >= $", Inp_BlockTPTarget, " [", reason, "]");
   m_isProcessing = true;
   // Primero ganadoras, luego perdedoras
   for(int pass = 0; pass < 2; pass++) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
         double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(pass == 0 && pf <  0) continue;
         if(pass == 1 && pf >= 0) continue;
         ClosePos(t, reason);
      }
   }
   m_isProcessing   = false;
   m_recoveryActive = false;
   m_recoveryOrders = 0;
   // V7.3 FIX #3: Resetear TODOS los flags de pausa al cerrar positivo
   m_isPaused           = false;
   m_emergencyMode      = false;
   m_dailyLimitHit      = false;
   m_recoveryStuckTime  = 0;
   m_recoveryResetCount = 0;
   m_cycleResetTime     = TimeCurrent();
   m_cycleInPause       = true;
   m_lastCTBuyPrice     = m_lastCTSellPrice = 0;
   Print(">>> V7.3: Todos los flags reseteados tras cierre positivo");
   return true;
}

//=================================================================
//  LOTES
//=================================================================
double CalcLot(int level = 0) {
   double sessionFactor = m_inSession ? 1.0 : Inp_OffSessionLotFactor;
   if(!Inp_UseDynamicLot || m_mkt.atr <= 0)
      return NormLot(Inp_LotBase * m_lotMultiplier * sessionFactor);
   double bal     = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskUSD = bal * Inp_RiskPerTradePct;
   double slATR   = m_inSession ? Inp_SL_ATR : Inp_OffSessionSL_ATR;
   double slDist  = m_mkt.atr * slATR;
   double tv = GetTickVal(), ts = GetTickSize();
   double lot = Inp_LotBase;
   if(tv > 0 && ts > 0 && slDist > 0) {
      double pipV = tv / ts;
      if(pipV > 0) lot = riskUSD / (slDist * pipV);
   }
   return NormLot(MathMax(lot, Inp_LotBase) * m_lotMultiplier * sessionFactor);
}

double CalcRecoveryLot() {
   double atr = m_mkt.atr;
   if(atr <= 0) return NormLot(Inp_LotBase * Inp_RecoveryMinLotMult);

   double blockLoss    = MathAbs(m_port.totalProfit);
   double totalNeeded  = blockLoss + Inp_BlockTPTarget;
   double moveDist     = atr * Inp_RecoveryMoveATR;
   if(moveDist <= 0) moveDist = atr * 0.5;

   double tv = GetTickVal(), ts = GetTickSize();
   double profitPer1LotPerDist = 0;
   if(tv > 0 && ts > 0)
      profitPer1LotPerDist = (moveDist / ts) * tv;

   double calcLot = Inp_LotBase;
   if(profitPer1LotPerDist > 0)
      calcLot = totalNeeded / profitPer1LotPerDist;

   double loserLot = Inp_LotBase;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(pf == m_port.worstProfit) { loserLot = vol; break; }
   }

   double minRecLot = loserLot * Inp_RecoveryMinLotMult;
   double finalLot  = MathMax(calcLot, minRecLot);

   Print(">>> REC LOT V7.3: necesito=$", NormalizeDouble(totalNeeded, 2),
         " moveDist=", NormalizeDouble(moveDist, _Digits),
         " 1lot=$", NormalizeDouble(profitPer1LotPerDist, 2),
         " calc=", NormalizeDouble(calcLot, 2),
         " min=", NormalizeDouble(minRecLot, 2),
         " FINAL=", NormalizeDouble(NormLot(finalLot), 2));

   return NormLot(finalLot);
}

//=================================================================
//  ╔══════════════════════════════════════════════════════════════╗
//  ║  V7.3 FIX #1: OpenOrder acepta forceEntry para recovery     ║
//  ║  forceEntry=true bypasea isPaused y emergencyMode           ║
//  ║  Esto rompe el deadlock: recovery SIEMPRE puede abrir       ║
//  ╚══════════════════════════════════════════════════════════════╝
ulong OpenOrder(ENUM_ORDER_TYPE type, double lot, string comment,
                bool skipPosLimit = false, bool forceEntry = false) {
   // V7.3: Solo bloquear si NO es forceEntry (recovery lo bypasea)
   if(!forceEntry && (m_isPaused || m_emergencyMode)) return 0;
   if(!SpreadOK()) return 0;
   if(!skipPosLimit && PositionsTotal() >= Inp_MaxPositionsTotal) return 0;
   if(skipPosLimit  && PositionsTotal() >= Inp_MaxPositionsTotal + 2) return 0;
   lot = NormLot(lot); if(lot <= 0) return 0;
   if(!MarginOK(lot, type)) return 0;

   MqlTick t; if(!GetTick(t)) return 0;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;

   bool ok = (type == ORDER_TYPE_BUY)
      ? m_trade.Buy(lot,  _Symbol, price, 0, 0, comment)
      : m_trade.Sell(lot, _Symbol, price, 0, 0, comment);

   if(!ok) { Print(">>> ERR V7.3: ", m_trade.ResultRetcodeDescription()); return 0; }

   ulong ticket = m_trade.ResultOrder();
   if(ticket > 0) {
      m_tradesOpened++;
      Print(">>> ABIERTA V7.3 #", ticket, " ",
            (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " Lot=", lot, " @ ", NormalizeDouble(price, _Digits),
            " SL=0 TP=0",
            (m_inSession ? " [SES]" : " [OFF]"),
            (forceEntry ? " [FORCE-REC]" : ""),
            " [", comment, "]");
   }
   return ticket;
}

//=================================================================
//  ManagePositions
//=================================================================
void ManagePositions() {
   // Sin SL/TP/Trailing — el bloque es la unidad de cierre
}

//=================================================================
//  ████ RECOVERY ENGINE V7.3 — CON FIXES DEADLOCK ████
//
//  CAMBIOS V7.3:
//  1. Llama OpenOrder con forceEntry=true → bypasea isPaused/emergency
//  2. Sincroniza m_recoveryOrders con posiciones reales antes de verificar
//  3. Detecta stuck y resetea contador si necesario
//  4. Funciona incluso durante emergency mode (llamado desde ese bloque)
//=================================================================
void RunRecoveryEngine() {
   if(m_port.totalProfit >= Inp_RecoveryTriggerUSD) {
      if(m_recoveryActive) {
         m_recoveryActive     = false;
         m_recoveryOrders     = 0;
         m_recoveryStuckTime  = 0;
         m_recoveryResetCount = 0;
      }
      return;
   }
   if(m_port.totalPos == 0) return;
   if(m_isProcessing)        return;

   if(CloseBlockIfPositive("Recovery_TP")) return;

   if(!m_recoveryActive) {
      m_recoveryActive     = true;
      m_recoveryStuckTime  = 0;
      m_recoveryResetCount = 0;
      Print(">>> RECOVERY ACTIVADO V7.3 | PnL=$", NormalizeDouble(m_port.totalProfit, 2));
   }

   // V7.3 FIX #4: Sincronizar m_recoveryOrders con posiciones reales
   // Evita que el contador quede desincronizado después de cierres parciales
   m_recoveryOrders = m_port.recoveryCount;

   // V7.3 FIX #4: Detectar stuck y resetear si es necesario
   if(m_recoveryOrders >= Inp_RecoveryMaxOrders) {
      if(m_recoveryStuckTime == 0) {
         m_recoveryStuckTime = TimeCurrent();
         Print(">>> RECOVERY: contador lleno (", m_recoveryOrders, "/", Inp_RecoveryMaxOrders,
               "), iniciando timer stuck");
      } else if(TimeCurrent() - m_recoveryStuckTime > Inp_RecoveryStuckSec) {
         if(m_recoveryResetCount < Inp_RecoveryMaxResets) {
            Print(">>> RECOVERY RESET V7.3: stuck ", Inp_RecoveryStuckSec, "s | reset #",
                  m_recoveryResetCount + 1, " | PnL=$", NormalizeDouble(m_port.totalProfit, 2));
            m_recoveryOrders    = m_port.recoveryCount; // recount
            m_recoveryStuckTime = 0;
            m_recoveryResetCount++;
            // Después del reset, si aún está lleno, esperar
            if(m_recoveryOrders >= Inp_RecoveryMaxOrders) return;
         } else {
            Print(">>> RECOVERY: máximo de resets alcanzado, esperando cierre del bloque");
            return;
         }
      } else {
         return; // Aún en timer, esperar
      }
   }

   if(TimeCurrent() - m_lastRecoveryTime < Inp_RecoveryIntervalSec) return;
   if(!SpreadOK()) return;

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   // Verificar distancia mínima del perdedor
   if(m_losingPosOpenPrice > 0 && m_losingPosType >= 0) {
      double distFromLoser = 0;
      if(m_losingPosType == POSITION_TYPE_SELL)
         distFromLoser = tk.bid - m_losingPosOpenPrice;
      else
         distFromLoser = m_losingPosOpenPrice - tk.ask;

      double minDist = atr * Inp_RecoveryMinDistATR;
      if(distFromLoser < minDist) {
         Print(">>> RECOVERY: esperando distancia | actual=",
               NormalizeDouble(distFromLoser, _Digits),
               " / necesito=", NormalizeDouble(minDist, _Digits));
         return;
      }
   }

   ENUM_ORDER_TYPE recType;
   if(m_port.buyProfit < m_port.sellProfit) {
      recType = ORDER_TYPE_BUY;
      if(m_lastCTBuyPrice > 0 &&
         MathAbs(tk.ask - m_lastCTBuyPrice) < atr * 0.3) return;
   } else {
      recType = ORDER_TYPE_SELL;
      if(m_lastCTSellPrice > 0 &&
         MathAbs(tk.bid - m_lastCTSellPrice) < atr * 0.3) return;
   }

   double recLot = CalcRecoveryLot();

   if(!MarginOK(recLot, recType)) {
      recLot = NormLot(recLot * 0.5);
      if(!MarginOK(recLot, recType)) {
         recLot = NormLot(Inp_LotBase);
         if(!MarginOK(recLot, recType)) {
            Print(">>> RECOVERY V7.3: Sin margen suficiente");
            return;
         }
      }
   }

   string recComm = "REC_" + (recType == ORDER_TYPE_BUY ? "B" : "S") +
                    "_" + IntegerToString(m_recoveryOrders + 1);
   m_isProcessing = true;
   // V7.3 FIX #1: forceEntry=true — bypasea pausa y emergencia
   ulong ticket = OpenOrder(recType, recLot, recComm, true, true);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (recType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (recType == ORDER_TYPE_BUY) ? tk.ask : tk.bid;
         InitRec(idx, ticket, pt, op, recLot, recComm, false, false, true);
      }
      if(recType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = tk.ask;
      else                            m_lastCTSellPrice = tk.bid;
      m_recoveryOrders++;
      m_recoveryStuckTime = 0; // Reset stuck timer al abrir exitosamente
      m_lastRecoveryTime  = TimeCurrent();
   }
}

//=================================================================
//  BASKET TP
//=================================================================
void RunBasketTP() {
   if(!Inp_UseBasketTP) return;
   if(TimeCurrent() - m_lastBasketCheck < Inp_BasketCheckSec) return;
   m_lastBasketCheck = TimeCurrent();
   if(m_port.totalPos < 2) return;
   if(m_port.totalProfit < Inp_BlockTPTarget) return;
   double avgWin  = (m_cycleWinsCount > 0) ? m_cycleWinsSum / m_cycleWinsCount : Inp_BasketTPFactor;
   double target  = MathMax(Inp_BlockTPTarget, avgWin * Inp_BasketTPRatio);
   if(m_port.totalProfit >= target) CloseBlockIfPositive("BasketTP");
}

void CheckCycleMaxLoss() {
   if(!Inp_UseCycleMaxLoss || m_port.totalPos == 0) return;
   if(m_port.totalProfit <= Inp_CycleMaxLossUSD) {
      Print(">>> CYCLE MAX LOSS V7.3: $", NormalizeDouble(m_port.totalProfit, 2),
            " — Forzando Recovery");
      if(!m_recoveryActive) { m_recoveryActive = true; m_recoveryOrders = m_port.recoveryCount; }
   }
}

//=================================================================
//  HARVEST
//=================================================================
void RunHarvest() {
   if(!Inp_HarvestContinuous || m_isProcessing) return;
   if(TimeCurrent() - m_lastHarvestTime < Inp_HarvestIntervalSec) return;
   m_lastHarvestTime = TimeCurrent();
   if(m_port.totalProfit < Inp_BlockTPTarget) return;

   double atr = m_mkt.atr, tv = GetTickVal(), ts = GetTickSize();
   double sessMult = m_inSession ? 1.0 : 1.5;
   double hMin = Inp_HarvestMinUSD * sessMult;
   if(atr > 0 && tv > 0 && ts > 0) {
      double minL   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double atrUSD = (atr / ts) * tv * minL * Inp_HarvestATRMult * sessMult;
      hMin = MathMax(hMin, NormalizeDouble(atrUSD, 2));
   }

   int harvested = 0; double totalH = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      int    idx = FindRec(t);
      double kpf = (idx >= 0 && m_rec[idx].kInit) ? m_rec[idx].kX : pf;
      if(m_port.negativeSum > pf * 1.5 && pf > 0) continue;
      bool doH = (pf >= hMin * 3.0) ||
                 (kpf >= hMin && idx >= 0 && m_rec[idx].kInit && m_rec[idx].kK <= 0.30);
      if(doH && ClosePos(t, "Harvest")) { harvested++; totalH += pf; }
   }
   if(harvested > 0) Print(">>> HARVEST V7.3: ", harvested, " | $", NormalizeDouble(totalH, 2));
}

// SOLO pausa — nunca cierra
bool CheckEquityGuard() {
   if(!Inp_UseEquityGuard) return false;
   if(m_port.totalProfit <= Inp_EmergencyLossUSD && !m_emergencyMode) {
      Print(">>> ALERTA EQUITY V7.3: $", NormalizeDouble(m_port.totalProfit, 2),
            " — Pausa entradas nuevas. Recovery SIGUE activo.");
      m_emergencyMode = true;
      m_isPaused      = true;
      return true;
   }
   if(m_port.currentDD >= Inp_MaxDrawdownPct)
      m_isPaused = true;
   else if(m_isPaused && !m_emergencyMode && !m_dailyLimitHit &&
           m_port.currentDD < Inp_MaxDrawdownPct * 0.5)
      m_isPaused = false;
   return false;
}

//=================================================================
//  CT ENGINE
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType, double &ctLot, int &ctLevel) {
   if(m_port.totalPos == 0) return false;
   if(m_port.totalPos >= Inp_MaxPositionsTotal) return false;
   if(m_port.totalProfit >= 0 && m_port.negativeSum == 0) return false;
   // V7.3 FIX #5: CT puede abrir como respaldo cuando recovery está
   // lleno (maxOrders alcanzado y stuck), pero NO cuando está activo normalmente
   bool recoveryFull = m_recoveryActive &&
                       (m_recoveryOrders >= Inp_RecoveryMaxOrders) &&
                       (m_recoveryResetCount >= Inp_RecoveryMaxResets);
   if(m_recoveryActive && !recoveryFull) return false;
   if(m_mkt.atr <= 0) return false;

   int    buyCount  = m_port.buyCount;
   int    sellCount = m_port.sellCount;
   bool   buyLosing  = (m_port.buyProfit  < -0.05 && buyCount  > 0);
   bool   sellLosing = (m_port.sellProfit < -0.05 && sellCount > 0);
   bool   openBuy = false, openSell = false;

   if(buyLosing && !sellLosing) {
      if(sellCount >= Inp_CTMaxSameDir) return false;
      openSell = true;
   } else if(sellLosing && !buyLosing) {
      if(buyCount >= Inp_CTMaxSameDir) return false;
      openBuy = true;
   } else if(buyLosing && sellLosing) {
      if(m_mkt.htfTrend == 1  && buyCount  < Inp_CTMaxSameDir) openBuy  = true;
      else if(m_mkt.htfTrend == -1 && sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(m_port.buyProfit < m_port.sellProfit && sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(buyCount < Inp_CTMaxSameDir) openBuy = true;
      else return false;
   } else return false;

   ENUM_ORDER_TYPE testType = openBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!ADXAllowsEntry(testType)) return false;

   double ctDist = (Inp_CTMode == CT_ATR_DISTANCE)
      ? m_mkt.atr * Inp_CTDistanceATR
      : Inp_CTFixedPoints * _Point;
   MqlTick t; if(!GetTick(t)) return false;
   if(ctDist > 0) {
      if(openBuy  && m_lastCTBuyPrice  > 0 && MathAbs(t.ask - m_lastCTBuyPrice)  < ctDist) return false;
      if(openSell && m_lastCTSellPrice > 0 && MathAbs(t.bid - m_lastCTSellPrice) < ctDist) return false;
   }
   ctLevel = openBuy ? buyCount : sellCount;
   ctLot   = CalcLot(ctLevel);
   ctType  = openBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   return true;
}

void RunCTEngine() {
   if(m_isProcessing || m_isPaused || m_emergencyMode || m_cycleInPause) return;
   if(TimeCurrent() - m_lastCTTime < Inp_CTIntervalSec) return;
   m_lastCTTime = TimeCurrent();

   MqlTick ts; if(!GetTick(ts)) return;
   double maxSpr = m_inSession ? (double)Inp_MaxSpread : Inp_CTMaxSpreadOff;
   if((ts.ask - ts.bid) / _Point > maxSpr) return;

   if(m_port.totalPos == 0) {
      int cooldown = m_inSession ? Inp_PrimaryCooldownSec : Inp_PrimaryCooldownOff;
      if(TimeCurrent() - m_lastPrimaryTime < cooldown) return;

      ENUM_ORDER_TYPE initType;
      if(m_mkt.isBullish)               initType = ORDER_TYPE_BUY;
      else if(m_mkt.isBearish)          initType = ORDER_TYPE_SELL;
      else if(m_mkt.emaFast > m_mkt.emaSlow) initType = ORDER_TYPE_BUY;
      else                              initType = ORDER_TYPE_SELL;

      if(m_lastPrimaryLost && m_lastPrimaryDir != 0) {
         ENUM_ORDER_TYPE alt = (m_lastPrimaryDir == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         if(initType != alt) { initType = alt; m_lastPrimaryLost = false; }
      }
      if(!ADXAllowsEntry(initType)) return;
      if(!m_inSession) {
         bool clearSignal = (m_mkt.isBullish && initType == ORDER_TYPE_BUY) ||
                            (m_mkt.isBearish && initType == ORDER_TYPE_SELL);
         if(!clearSignal) return;
      }

      double lot = CalcLot(0);
      m_isProcessing = true;
      ulong ticket = OpenOrder(initType, lot, "Primary_Entry");
      if(ticket > 0) {
         int idx = FreeRec();
         if(idx >= 0) {
            int    pt = (initType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
            double op = (initType == ORDER_TYPE_BUY) ? ts.ask : ts.bid;
            InitRec(idx, ticket, pt, op, lot, "Primary_Entry", true, false, false);
         }
         m_lastPrimaryDir  = (initType == ORDER_TYPE_BUY) ? 1 : -1;
         m_lastPrimaryTime = TimeCurrent();
         if(initType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = ts.ask;
         else                             m_lastCTSellPrice = ts.bid;
         m_recoveryActive     = false;
         m_recoveryOrders     = 0;
         m_recoveryStuckTime  = 0;
         m_recoveryResetCount = 0;
      }
      m_isProcessing = false;
      return;
   }

   ENUM_ORDER_TYPE ctType; double ctLot; int ctLevel;
   if(!ShouldOpenCT(ctType, ctLot, ctLevel)) return;
   if(!MarginOK(ctLot, ctType)) return;

   string ctComm = "CT_" + (ctType == ORDER_TYPE_BUY ? "B" : "S") +
                   "_L" + IntegerToString(ctLevel + 1);
   m_isProcessing = true;
   ulong ticket = OpenOrder(ctType, ctLot, ctComm);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (ctType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (ctType == ORDER_TYPE_BUY) ? ts.ask : ts.bid;
         InitRec(idx, ticket, pt, op, ctLot, ctComm, false, true, false);
      }
      if(ctType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = ts.ask;
      else                           m_lastCTSellPrice = ts.bid;
   }
}

//=================================================================
//  DASHBOARD V7.3
//=================================================================
void Lbl(string n, string txt, int x, int y, color c, int fs = 9) {
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, fs);
      ObjectSetString(0,  n, OBJPROP_FONT, "Consolas");
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     c);
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
}

void Btn(string n, string txt, int x, int y, int w, int h, color bg) {
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0,  n, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,   bg);
}

void DeleteDash() {
   string ns[] = {"D73_T","D73_R","D73_S","D73_SES","D73_BAL",
                  "D73_PNL","D73_POS","D73_REC","D73_MKT",
                  "D73_PERF","D73_DD","D73_B1","D73_B2"};
   for(int i = 0; i < ArraySize(ns); i++) ObjectDelete(0, ns[i]);
}

void UpdateDash() {
   if(!Inp_ShowDashboard) return;
   if(TimeCurrent() - m_lastDashTime < 1) return;
   m_lastDashTime = TimeCurrent();

   int    x = Inp_DashX, y = Inp_DashY, lh = 15;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   color cG = clrLimeGreen, cR = clrTomato, cN = clrSilver, cC = clrCyan, cY = clrGold;
   color pnlC = (m_port.totalProfit >= 0) ? cG : cR;
   color ddC  = (m_port.currentDD > 0.10) ? cR : (m_port.currentDD > 0.05) ? clrOrange : cG;
   color recC = m_recoveryActive ? clrOrange : cN;

   // V7.3: Nuevo estado "REC-EMERG" para mayor visibilidad
   string stStr;
   color  stC;
   if(m_emergencyMode && m_recoveryActive) {
      stStr = "REC-EMERG (recovery activo)";
      stC   = clrOrange;
   } else if(m_emergencyMode) {
      stStr = "EMERG-PAUSA";
      stC   = clrOrange;
   } else if(m_dailyLimitHit) {
      stStr = "DIA-PAUSA";
      stC   = clrOrange;
   } else if(m_recoveryActive) {
      stStr = "RECOVERY";
      stC   = clrOrange;
   } else if(m_cycleInPause) {
      stStr = "PAUSA-CICLO";
      stC   = clrOrange;
   } else if(m_isPaused) {
      stStr = "PAUSADO";
      stC   = cY;
   } else {
      stStr = "ACTIVO 24/7";
      stC   = cG;
   }

   double falta = Inp_BlockTPTarget - m_port.totalProfit;

   double distFromLoser = 0;
   if(m_losingPosOpenPrice > 0 && m_losingPosType >= 0) {
      MqlTick tk; GetTick(tk);
      if(m_losingPosType == POSITION_TYPE_SELL) distFromLoser = tk.bid - m_losingPosOpenPrice;
      else                                       distFromLoser = m_losingPosOpenPrice - tk.ask;
   }
   double minRecDist = m_mkt.atr * Inp_RecoveryMinDistATR;

   // V7.3: Mostrar info de stuck en el dashboard
   string stuckStr = "";
   if(m_recoveryStuckTime > 0) {
      int stuckSecs = (int)(TimeCurrent() - m_recoveryStuckTime);
      stuckStr = " STUCK:" + IntegerToString(stuckSecs) + "s";
   }

   Lbl("D73_T",   "══ " + VERSION_STR + " | XAUUSD 24/7 ══",              x, y, cY, 10); y += lh + 2;
   Lbl("D73_R",   "✅ SL=0 | Cierra bloque POSITIVO | Recovery en EMERGENCIA OK", x, y, cG, 9); y += lh;
   Lbl("D73_S",   "Estado: " + stStr + " | Ticks:" + IntegerToString((int)m_tickCount), x, y, stC); y += lh;
   Lbl("D73_SES", "Sesion:" + (m_inSession ? "PRINC" : "FUERA") +
                  " | ADX:" + DoubleToString(m_mkt.adx, 1) +
                  " | HTF:" + (m_mkt.htfTrend == 1 ? "BULL" : m_mkt.htfTrend == -1 ? "BEAR" : "NEUT") +
                  " | ATR:" + DoubleToString(m_mkt.atr, _Digits),          x, y, m_inSession ? cG : clrOrange); y += lh;
   Lbl("D73_BAL", "Bal:$" + DoubleToString(bal, 2) +
                  "  Eq:$" + DoubleToString(eq, 2) +
                  "  Peak:$" + DoubleToString(m_bestEquity, 2),             x, y, cC); y += lh;
   Lbl("D73_PNL", "PnL Bloque: $" + DoubleToString(m_port.totalProfit, 2) +
                  " | Target: $" + DoubleToString(Inp_BlockTPTarget, 2) +
                  " | Falta: $" + DoubleToString(MathMax(falta, 0), 2),    x, y, pnlC); y += lh;
   Lbl("D73_POS", "Pos:" + IntegerToString(m_port.totalPos) +
                  "  B:" + IntegerToString(m_port.buyCount) +
                  " $" + DoubleToString(m_port.buyProfit, 2) +
                  " | S:" + IntegerToString(m_port.sellCount) +
                  " $" + DoubleToString(m_port.sellProfit, 2),              x, y, cC); y += lh;
   Lbl("D73_REC", "Recovery:" + (m_recoveryActive ? "ACTIVO" : "inact") +
                  " | Ord:" + IntegerToString(m_recoveryOrders) +
                  "/" + IntegerToString(Inp_RecoveryMaxOrders) +
                  " | Resets:" + IntegerToString(m_recoveryResetCount) +
                  stuckStr +
                  " | Dist:" + DoubleToString(distFromLoser, _Digits) +
                  "/min:" + DoubleToString(minRecDist, _Digits),            x, y, recC); y += lh;
   Lbl("D73_MKT", "RSI:" + DoubleToString(m_mkt.rsi, 0) +
                  "  Sprd:" + IntegerToString((int)m_mkt.spread) +
                  "  " + (m_mkt.isBullish ? "ALCISTA" : m_mkt.isBearish ? "BAJISTA" : "LATERAL"), x, y,
                  m_mkt.isBullish ? cG : m_mkt.isBearish ? cR : cN); y += lh;
   Lbl("D73_PERF","Abierts:" + IntegerToString(m_tradesOpened) +
                  "  Cerrd:" + IntegerToString(m_tradesClosed) +
                  "  Mejor:$" + DoubleToString(m_bestClosed, 2) +
                  "  Peor:$" + DoubleToString(m_worstClosed, 2),            x, y, cC); y += lh;
   Lbl("D73_DD",  "DD:" + DoubleToString(m_port.currentDD * 100, 1) + "%" +
                  "  Alerta<$" + DoubleToString(Inp_EmergencyLossUSD, 1) +
                  " (pausa entradas, recovery OK)",                          x, y, ddC); y += lh + 4;
   Btn("D73_B1", m_isPaused ? "REANUDAR" : "PAUSAR",  x,      y, 80, 20, m_isPaused ? clrGoldenrod : clrDarkGreen);
   Btn("D73_B2", "CERRAR TODO (MANUAL)",               x + 88, y, 130, 20, clrDarkRed);
   ChartRedraw(0);
}

//=================================================================
//  OnInit
//=================================================================
int OnInit() {
   Print("══════════════════════════════════════════════════════════");
   Print("  ", VERSION_STR, " — FIX DEADLOCK + RECOVERY EN EMERGENCIA");
   Print("  ✅ Recovery bypasea isPaused/emergencyMode (forceEntry)");
   Print("  ✅ Emergency mode llama RunRecoveryEngine() antes de return");
   Print("  ✅ CloseBlockIfPositive resetea TODOS los flags");
   Print("  ✅ Recovery counter se sincroniza con posiciones reales");
   Print("  ✅ Anti-stuck: reset automático cada ", Inp_RecoveryStuckSec, "s");
   Print("══════════════════════════════════════════════════════════");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(ORDER_FILLING_FOK);

   h_ATR     = iATR(_Symbol, PERIOD_M1, Inp_ATRPeriod);
   h_EMAFast = iMA(_Symbol,  PERIOD_M1, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMASlow = iMA(_Symbol,  PERIOD_M1, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI     = iRSI(_Symbol, PERIOD_M1, Inp_RSIPeriod, PRICE_CLOSE);
   h_MACD    = iMACD(_Symbol, PERIOD_M1, Inp_MACDFast, Inp_MACDSlow, Inp_MACDSig, PRICE_CLOSE);

   if(h_ATR == INVALID_HANDLE || h_EMAFast == INVALID_HANDLE ||
      h_EMASlow == INVALID_HANDLE || h_RSI == INVALID_HANDLE ||
      h_MACD == INVALID_HANDLE) {
      Print(">>> ERROR: Handles no creados"); return INIT_FAILED;
   }
   h_ADX        = iADX(_Symbol, PERIOD_M1, Inp_ADXPeriod);
   h_HTFEMAFast = iMA(_Symbol, Inp_HTFTF, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_HTFEMASlow = iMA(_Symbol, Inp_HTFTF, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);

   for(int i = 0; i < MAX_RECORDS; i++) ZeroMemory(m_rec[i]);
   m_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   m_bestEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance   = m_initialBalance;
   m_lastDailyReset = TimeCurrent();

   SyncPositions();
   if(Inp_ShowDashboard) { DeleteDash(); UpdateDash(); }
   Print(">>> V7.3 LISTO | Bal=$", m_initialBalance);
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason) {
   Print(">>> DEINIT V7.3 | PnL=$", NormalizeDouble(m_totalPnL, 2),
         " | Abiertas:", m_tradesOpened, " Cerradas:", m_tradesClosed);
   IndicatorRelease(h_ATR);   IndicatorRelease(h_EMAFast);
   IndicatorRelease(h_EMASlow); IndicatorRelease(h_RSI);
   IndicatorRelease(h_MACD);
   if(h_ADX        != INVALID_HANDLE) IndicatorRelease(h_ADX);
   if(h_HTFEMAFast != INVALID_HANDLE) IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow != INVALID_HANDLE) IndicatorRelease(h_HTFEMASlow);
   if(Inp_ShowDashboard) DeleteDash();
}

//=================================================================
//  ████ OnTick V7.3 — EMERGENCY MODE YA NO BLOQUEA RECOVERY ████
//=================================================================
void OnTick() {
   m_tickCount++;
   UpdateMarket();
   UpdateKalman();
   UpdatePortfolio();

   CheckEquityGuard();
   m_inSession = IsInMainSession();
   ResetDailyIfNeeded();
   bool dailyPaused = DailyLimitReached();

   if(m_cycleInPause) {
      if(TimeCurrent() - m_cycleResetTime >= Inp_CyclePauseSec) {
         m_cycleInPause       = false;
         m_recoveryActive     = false;
         m_recoveryOrders     = 0;
         m_recoveryStuckTime  = 0;
         m_recoveryResetCount = 0;
      } else {
         UpdatePortfolio();
         if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget)
            CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard) UpdateDash();
         return;
      }
   }

   // ╔══════════════════════════════════════════════════════════════╗
   // ║  V7.3 FIX #2: Emergency mode YA LLAMA RunRecoveryEngine()  ║
   // ║  Antes: solo monitoreaba y hacía return → DEADLOCK          ║
   // ║  Ahora: intenta recovery aunque esté en emergencia          ║
   // ╚══════════════════════════════════════════════════════════════╝
   if(m_emergencyMode) {
      static datetime emgTime = 0;
      UpdatePortfolio();

      // Si el bloque llegó a positivo, cerrar y salir de emergencia
      if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget) {
         CloseBlockIfPositive("Emergency_TP");
         // V7.3 FIX #3: CloseBlockIfPositive ya resetea emergencyMode e isPaused
         emgTime = 0;
         if(Inp_ShowDashboard) UpdateDash();
         return;
      }

      // V7.3 FIX #2: Intentar recovery aunque esté en emergencia
      // RunRecoveryEngine usa forceEntry=true en OpenOrder → bypasea isPaused
      if(m_port.totalPos > 0) {
         RunRecoveryEngine();
      }

      // Cooldown de emergencia cuando no hay posiciones
      if(m_port.totalPos == 0 && emgTime == 0) emgTime = TimeCurrent();
      if(emgTime > 0 && TimeCurrent() - emgTime >= Inp_EmergencyCooldown) {
         m_emergencyMode = false;
         m_isPaused      = false; // V7.3: También resetear isPaused
         emgTime         = 0;
         Print(">>> V7.3: Cooldown emergencia completado, EA reanudado");
      }

      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   if(TimeCurrent() - m_lastCleanupTime > 5) {
      CleanupRecs(); SyncPositions();
      m_lastCleanupTime = TimeCurrent();
   }

   ManagePositions();

   // PRIORIDAD 1: Bloque positivo → Cerrar
   if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget) {
      CloseBlockIfPositive("BlockTP");
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // PRIORIDAD 2: Recovery matemático
   RunRecoveryEngine();

   // PRIORIDAD 3: Basket TP
   RunBasketTP();

   // PRIORIDAD 4: Cycle max loss
   CheckCycleMaxLoss();

   // PRIORIDAD 5: Harvest
   RunHarvest();

   // PRIORIDAD 6: CT Engine
   if(!m_isPaused && !m_recoveryActive && !dailyPaused) RunCTEngine();

   if(Inp_ShowDashboard) UpdateDash();
}

//=================================================================
//  OnChartEvent
//=================================================================
void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp) {
   if(id == CHARTEVENT_OBJECT_CLICK) {
      if(sp == "D73_B1") {
         m_isPaused = !m_isPaused;
         if(!m_isPaused) {
            m_emergencyMode      = false;
            m_dailyLimitHit      = false;
            m_recoveryActive     = false;
            m_recoveryOrders     = 0;
            m_recoveryStuckTime  = 0;
            m_recoveryResetCount = 0;
            Print(">>> EA V7.3 REANUDADO MANUAL");
         } else Print(">>> EA V7.3 PAUSADO MANUAL");
      }
      if(sp == "D73_B2") {
         int closed = 0;
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
            if(ClosePos(t, "Manual")) closed++;
         }
         m_lastCTBuyPrice     = m_lastCTSellPrice = 0;
         m_consecutiveLosses  = 0;
         m_lotMultiplier      = 1.0;
         m_cycleInPause       = false;
         m_recoveryActive     = false;
         m_recoveryOrders     = 0;
         m_recoveryStuckTime  = 0;
         m_recoveryResetCount = 0;
         m_lastPrimaryDir     = 0;
         m_lastPrimaryLost    = false;
         m_isPaused           = false;
         m_emergencyMode      = false;
         m_dailyLimitHit      = false;
         Print(">>> CIERRE MANUAL V7.3: ", closed, " posiciones | todos los flags reseteados");
      }
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+