//+------------------------------------------------------------------+
//| Pure_Fractal_MultiTimeframe_XAUUSD_r32_BTC.mq5                   |
//| EA MULTIHORARIO: cada franja horaria usa su estrategia validada   |
//| Validacion walk-forward 3 periodos (2024H2-2026A): 25 configs     |
//| XAU: 00-02 MOMEMA3.0 | 02-04 MOMEMA2.0 | 04-06 BREAK48+MOMEMA3.0 |
//|      06-08 BREAK483.0 | 10-12 RETEST483.0 | 14-16 EMACROSS2.0    |
//|      16-18 RETEST482.0 | 22-24 BREAK483.0  (riesgo 20 USD)       |
//| BTC: 16-18 RETEST482.0 + 18-20 VWAP2.0 (solo slots validados)  |
//|      riesgo 300 USD, TTL 24 velas (fiel al sim)                 |
//| Cuentas Standard/Cent/Micro: deteccion automatica                |
//+------------------------------------------------------------------+
#property copyright "APEXQUANT / NeurAlgo project"
#property version   "32.0"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

enum ENUM_ACCOUNT_TYPE2 { ACCT_AUTO=0, ACCT_STANDARD=1, ACCT_CENT=2, ACCT_MICRO=3 };
enum ENUM_LOT_MODE2 { LOT_MODE_RISK=0, LOT_MODE_FIXED=1 };
enum ENUM_SLOT_STRATEGY
{
   STRAT_OFF=0,      // OFF
   STRAT_BREAK48=1,  // Breakout rango 48 velas M5
   STRAT_BREAK24=2,  // Breakout rango 24 velas M5
   STRAT_MOMEMA=3,   // Momentum EMA30 + ruptura 3 velas
   STRAT_EMACROSS=4, // Cruce EMA20/EMA60
   STRAT_RETEST48=5, // Retest extremo 48 velas
   STRAT_RETEST24=6, // Retest extremo 24 velas
   STRAT_VWAP=7      // Cruce VWAP del dia
};

input group "=== Tipo de Cuenta ==="
input ENUM_ACCOUNT_TYPE2 InpAccountType = ACCT_AUTO; // 0=AUTO (rec), 1=Standard, 2=Cent, 3=Micro

input group "=== Riesgo y Tamano ==="
input ENUM_LOT_MODE2 InpLotMode        = LOT_MODE_RISK; // Modo lote
input double InpFixedLotSize           = 0.01;           // Lote fijo (si LOT_MODE_FIXED)
input bool   InpUseRiskPctEquity       = true;           // [r32] Usar % de Equity en vez de USD fijo
input double InpRiskPctEquity          = 1.5;            // [r32] % Riesgo por trade sobre Equity
input double InpRiskPerTradeUSD        = 300.0;          // Riesgo por trade en USD (si InpUseRiskPctEquity = false)
input double InpMaxLotSize             = 4.0;
input int    InpSLMultiplierATR        = 80;             // SL = ATR_M5 x esto / 100 (0.80)
input double InpMaxSpreadATR           = 0.50;           // Filtro spread: bloquear si spread > ATR x esto (0=off)

input group "=== Circuit Breaker Diario ==="
input bool   InpDailyLossLimitEnable   = true;           // [r32] Bloquear entradas tras perdida diaria
input double InpMaxDailyLossPct        = 6.0;            // [r32] Max Loss Diario en % de Equity
input double InpMaxDailyLossUSD        = 1200.0;         // Max Loss Diario en USD (si InpUseRiskPctEquity = false)
input int    InpCooldownMinutes        = 0;              // Pausa global tras trade perdedor (0=off)

input group "=== Slot 01: OFF ==="
input ENUM_SLOT_STRATEGY InpSlot01Strategy = STRAT_OFF;
input int  InpSlot01Start = 0;
input int  InpSlot01End   = 24;
input double InpSlot01TP  = 2.0;
input int  InpSlot01TTL   = 24;

input group "=== Slot 02: 16-18h RETEST48 (validado) ==="
input ENUM_SLOT_STRATEGY InpSlot02Strategy = STRAT_RETEST48;
input int  InpSlot02Start = 16;
input int  InpSlot02End   = 18;
input double InpSlot02TP  = 2.0;
input int  InpSlot02TTL   = 24;

input group "=== Slot 03: 18-20h VWAP (validado) ==="
input ENUM_SLOT_STRATEGY InpSlot03Strategy = STRAT_VWAP;
input bool  InpSlot03AltEnable = false;
input int  InpSlot03Start = 18;
input int  InpSlot03End   = 20;
input double InpSlot03TP  = 2.0;
input int  InpSlot03TTL   = 24;

input group "=== Slot 04: 04-06h VWAP (validado) ==="
input ENUM_SLOT_STRATEGY InpSlot04Strategy = STRAT_VWAP;
input int  InpSlot04Start = 4;
input int  InpSlot04End   = 6;
input double InpSlot04TP  = 2.5;
input int  InpSlot04TTL   = 24;

input group "=== Slot 05: 20-22h RETEST48 (validado) ==="
input ENUM_SLOT_STRATEGY InpSlot05Strategy = STRAT_RETEST48;
input int  InpSlot05Start = 20;
input int  InpSlot05End   = 22;
input double InpSlot05TP  = 2.5;
input int  InpSlot05TTL   = 24;

input group "=== Slot 06: OFF ==="
input ENUM_SLOT_STRATEGY InpSlot06Strategy = STRAT_OFF;
input int  InpSlot06Start = 0;
input int  InpSlot06End   = 24;
input double InpSlot06TP  = 3.0;
input int  InpSlot06TTL   = 48;

input group "=== Slot 07: OFF ==="
input ENUM_SLOT_STRATEGY InpSlot07Strategy = STRAT_OFF;
input int  InpSlot07Start = 0;
input int  InpSlot07End   = 24;
input double InpSlot07TP  = 3.0;
input int  InpSlot07TTL   = 48;

input group "=== Slot 08: OFF ==="
input ENUM_SLOT_STRATEGY InpSlot08Strategy = STRAT_OFF;
input int  InpSlot08Start = 0;
input int  InpSlot08End   = 24;
input double InpSlot08TP  = 3.0;
input int  InpSlot08TTL   = 48;

input group "=== Persistencia ==="
input bool   InpPersistState = true;
input long   InpMagicBase    = 914001;

#define MAX_SLOTS 8
#define TF PERIOD_M5

//--- cuenta
double g_acctUnit = 1.0;
string g_acctName = "STANDARD";

//--- slots
struct SlotDef
{
   int          strategy;
   bool         altEnable;
   int          startHour;
   int          endHour;
   double       tpMult;
   int          ttlBars;
   int          magic;
   ulong        ticket;
   int          entryBarIdx;
};
SlotDef g_slots[MAX_SLOTS];

//--- estado
datetime g_dayStart = 0;
double   g_dayRealizedPL = 0.0;
bool     g_dailyLimitHit = false;
datetime g_cooldownUntil = 0;

//--- indicadores
int    g_hATR = INVALID_HANDLE;
int    g_hEMA20 = INVALID_HANDLE;
int    g_hEMA30 = INVALID_HANDLE;
int    g_hEMA60 = INVALID_HANDLE;

//--- vwap (media de precio tipico del dia, exacta al backtest)
double g_vwapBuf[4096];
double g_cumTypical = 0.0;
int    g_dayStartIdx = 0;
int    g_vwapCount = 0;
int    g_barIdx = 0;

CTrade  g_trade;
CPositionInfo g_pos;

//+------------------------------------------------------------------+
//  Deteccion de tipo de cuenta (misma logica que FVG Fusion)
//+------------------------------------------------------------------+
void DetectAccountType()
{
   g_acctUnit = 1.0;
   g_acctName = "STANDARD";

   if(InpAccountType == ACCT_STANDARD) { g_acctUnit = 1.0;  g_acctName = "STANDARD"; return; }
   if(InpAccountType == ACCT_CENT)     { g_acctUnit = 0.01; g_acctName = "CENT";     return; }
   if(InpAccountType == ACCT_MICRO)    { g_acctUnit = 0.001;g_acctName = "MICRO";    return; }

   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   bool centByCurrency = false;
   if(StringLen(cur) >= 3)
   {
      string lastC = StringSubstr(cur, StringLen(cur)-1, 1);
      if(lastC == "C") centByCurrency = true;
   }

   double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double tSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ratio = 1.0;
   if(tSize > 0.0 && tValue > 0.0)
      ratio = contract * tSize / tValue;

   int heuristic = 1;
   if(ratio >= 500.0) heuristic = 3;
   else if(ratio >= 50.0) heuristic = 2;

   if(centByCurrency) heuristic = 2;  // la moneda USC/EUC... manda (fix cuentas cent)

   if(heuristic == 2)      { g_acctUnit = 0.01;  g_acctName = "CENT"; }
   else if(heuristic == 3) { g_acctUnit = 0.001; g_acctName = "MICRO"; }
   else                    { g_acctUnit = 1.0;   g_acctName = "STANDARD"; }

   PrintFormat("[MULTI32] Cuenta detectada: %s (moneda=%s, ratio=%.2f, 1 unidad=%.4f USD)",
               g_acctName, cur, ratio, g_acctUnit);
   Print("[MULTI32] Si la deteccion es incorrecta, fija InpAccountType manualmente (1=Std, 2=Cent, 3=Micro).");
}
//+------------------------------------------------------------------+
//  Lotes
//+------------------------------------------------------------------+
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
   
   double riskUSD = InpRiskPerTradeUSD;
   if(InpUseRiskPctEquity)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > 0.0)
         riskUSD = equity * (InpRiskPctEquity / 100.0);
   }
   
   double riskAcct = riskUSD / g_acctUnit;
   double moneyPerPriceUnit = tickValue / tickSize;
   double lots = riskAcct / (slDistance * moneyPerPriceUnit);
   return NormalizeVolumeForRisk(lots);
}
double GetTradeLotSize(double slDistance)
{
   if(InpLotMode == LOT_MODE_FIXED) return NormalizeVolumeForRisk(InpFixedLotSize);
   return CalcLotSizeForRisk(slDistance);
}
//+------------------------------------------------------------------+
//  VWAP del dia (media de precio tipico, resetea a las 00:00 server)
//+------------------------------------------------------------------+
void OnNewBar()
{
   int bars = Bars(_Symbol, TF);
   if(bars <= g_barIdx) return;
   int newBars = bars - g_barIdx;
   for(int k = 0; k < newBars && k < 512; k++)
   {
      int shift = newBars - 1 - k;   // la mas reciente primero
      double h = iHigh(_Symbol, TF, shift);
      double l = iLow(_Symbol, TF, shift);
      double c = iClose(_Symbol, TF, shift);
      datetime t = iTime(_Symbol, TF, shift);
      datetime day = (datetime)(((long)t) / 86400 * 86400);
      datetime dayPrev = (g_vwapCount > 0) ? (datetime)(((long)iTime(_Symbol, TF, shift + 1)) / 86400 * 86400) : 0;
      if(day != dayPrev)
      {
         g_cumTypical = 0.0;
         g_dayStartIdx = g_vwapCount;
      }
      g_cumTypical += (h + l + c) / 3.0;
      if(g_vwapCount >= 4096) g_vwapCount = 0;
      g_vwapBuf[g_vwapCount] = g_cumTypical / (double)(g_vwapCount - g_dayStartIdx + 1);
      g_vwapCount++;
   }
   g_barIdx = bars;
}
//+------------------------------------------------------------------+
//  Acceso a indicadores por shift (CopyBuffer sobre handles)
//+------------------------------------------------------------------+
double ATRAt(int shift)
{
   double buf[1];
   if(CopyBuffer(g_hATR, 0, shift, 1, buf) < 1) return 0.0;
   return buf[0];
}
double EMAAt(int handle, int shift)
{
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) < 1) return 0.0;
   return buf[0];
}
double HighestAt(int count, int start)
{
   int idx = iHighest(_Symbol, TF, MODE_HIGH, count, start);
   if(idx < 0) return 0.0;
   return iHigh(_Symbol, TF, idx);
}
double LowestAt(int count, int start)
{
   int idx = iLowest(_Symbol, TF, MODE_LOW, count, start);
   if(idx < 0) return 0.0;
   return iLow(_Symbol, TF, idx);
}
//+------------------------------------------------------------------+
//  Senales sobre vela cerrada (shift 1) - misma logica que el backtest
//+------------------------------------------------------------------+
int SignalForSlot(int slot)
{
   int st = g_slots[slot].strategy;
   if(st == STRAT_OFF) return 0;

   double atr = ATRAt(1);
   if(atr <= 0.0) return 0;

   double c1 = iClose(_Symbol, TF, 1);
   double c2 = iClose(_Symbol, TF, 2);

   int sig = 0;

   if(st == STRAT_BREAK48 || st == STRAT_BREAK24)
   {
      int n = (st == STRAT_BREAK48) ? 48 : 24;
      double hx = HighestAt(n, 2);
      double ln = LowestAt(n, 2);
      if(c1 > hx) sig = 1;
      else if(c1 < ln) sig = -1;
   }
   else if(st == STRAT_MOMEMA)
   {
      double e30 = EMAAt(g_hEMA30, 1);
      if(c1 > e30 && c1 > HighestAt(3, 2)) sig = 1;
      else if(c1 < e30 && c1 < LowestAt(3, 2)) sig = -1;
   }
   else if(st == STRAT_EMACROSS)
   {
      double e20a = EMAAt(g_hEMA20, 1);
      double e60a = EMAAt(g_hEMA60, 1);
      double e20b = EMAAt(g_hEMA20, 2);
      double e60b = EMAAt(g_hEMA60, 2);
      if(e20a > e60a && e20b <= e60b) sig = 1;
      else if(e20a < e60a && e20b >= e60b) sig = -1;
   }
   else if(st == STRAT_RETEST48 || st == STRAT_RETEST24)
   {
      int n = (st == STRAT_RETEST48) ? 48 : 24;
      double hx = HighestAt(n, 2);
      double ln = LowestAt(n, 2);
      double h1 = iHigh(_Symbol, TF, 1);
      double l1 = iLow(_Symbol, TF, 1);
      if(h1 >= hx && c1 < hx - 0.1*atr) sig = -1;
      else if(l1 <= ln && c1 > ln + 0.1*atr) sig = 1;
   }
   else if(st == STRAT_VWAP)
   {
      double v1 = VwapShift(1);
      double v2 = VwapShift(2);
      if(v1 > 0.0 && v2 > 0.0)
      {
         if(c1 > v1 && c2 <= v2) sig = 1;
         else if(c1 < v1 && c2 >= v2) sig = -1;
      }
   }

   //--- senal alternativa (slot 3: BREAK48 prioritario + MOMEMA)
   if(sig == 0 && g_slots[slot].altEnable)
   {
      double e30 = EMAAt(g_hEMA30, 1);
      if(c1 > e30 && c1 > HighestAt(3, 2)) sig = 1;
      else if(c1 < e30 && c1 < LowestAt(3, 2)) sig = -1;
   }

   return sig;
}
double VwapShift(int shift)
{
   int idx = g_vwapCount - 1 - shift;
   if(idx < 0) return 0.0;
   if(idx >= 4096) return 0.0;
   return g_vwapBuf[idx];
}
//+------------------------------------------------------------------+
//  Gestion de posiciones y TTL
//+------------------------------------------------------------------+
bool ClosePosition(ulong ticket)
{
   if(ticket == 0) return true;
   if(PositionSelectByTicket(ticket))
   {
      double pnl = g_pos.Profit() + g_pos.Swap() + g_pos.Commission();
      bool ok = g_trade.PositionClose(ticket);
      if(ok && pnl < 0.0 && InpCooldownMinutes > 0)
         g_cooldownUntil = TimeTradeServer() + InpCooldownMinutes * 60;
      return ok;
   }
   return true;
}
void ManagePositions()
{
   int bars = Bars(_Symbol, TF);
   for(int s = 0; s < MAX_SLOTS; s++)
   {
      if(g_slots[s].ticket == 0) continue;
      if(!PositionSelectByTicket(g_slots[s].ticket))
      {
         g_slots[s].ticket = 0;   // se cerro (SL/TP/servidor)
         continue;
      }
      //--- TTL: cerrar si supero el maximo de velas
      if(g_slots[s].ttlBars > 0 && bars - g_slots[s].entryBarIdx >= g_slots[s].ttlBars)
      {
         ClosePosition(g_slots[s].ticket);
         g_slots[s].ticket = 0;
      }
   }
}
//+------------------------------------------------------------------+
//  Entradas
//+------------------------------------------------------------------+
void TryEntries()
{
   if(g_dailyLimitHit) return;
   if(InpCooldownMinutes > 0 && TimeTradeServer() < g_cooldownUntil) return;

   MqlDateTime dtNow;
   TimeToStruct(TimeTradeServer(), dtNow);
   int hourNow = dtNow.hour;

   for(int s = 0; s < MAX_SLOTS; s++)
   {
      if(g_slots[s].strategy == STRAT_OFF) continue;
      if(g_slots[s].ticket != 0) continue;
      if(hourNow < g_slots[s].startHour || hourNow >= g_slots[s].endHour) continue;

      double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID));
      double atr = ATRAt(1);
      if(atr <= 0.0) continue;
      if(InpMaxSpreadATR > 0.0 && spread > atr * InpMaxSpreadATR) continue;

      int sig = SignalForSlot(s);
      if(sig == 0) continue;

      //--- SL/TP del backtest: referencia close de la vela senal
      double refPrice = iClose(_Symbol, TF, 1);
      double slDist = atr * ((double)InpSLMultiplierATR / 100.0);
      double slPrice = refPrice - sig * slDist;
      double tpPrice = refPrice + sig * slDist * g_slots[s].tpMult;

      //--- saneamiento SL
      if(sig == 1 && slPrice >= SymbolInfoDouble(_Symbol, SYMBOL_BID)) continue;
      if(sig == -1 && slPrice <= SymbolInfoDouble(_Symbol, SYMBOL_ASK)) continue;

      double lots = GetTradeLotSize(slDist);
      if(lots < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) continue;

      g_trade.SetExpertMagicNumber(g_slots[s].magic);
      g_trade.SetDeviationInPoints(50);
      bool ok = (sig == 1) ?
         g_trade.Buy(lots, _Symbol, 0.0, slPrice, tpPrice, "M32B_S" + IntegerToString(s + 1)) :
         g_trade.Sell(lots, _Symbol, 0.0, slPrice, tpPrice, "M32B_S" + IntegerToString(s + 1));
      if(ok)
      {
         g_slots[s].ticket = g_trade.ResultOrder();
         g_slots[s].entryBarIdx = Bars(_Symbol, TF);
         PrintFormat("[MULTI32] %s SLOT%d %s lote=%.2f SL=%.2f TP=%.2f",
                     _Symbol, s + 1, (sig == 1 ? "BUY" : "SELL"), lots, slPrice, tpPrice);
      }
   }
}
//+------------------------------------------------------------------+
//  OnTradeTransaction: PnL diario realizado
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   ulong dealTicket = trans.deal;
   if(dealTicket == 0) return;
   if(!HistoryDealSelect(dealTicket)) return;
   long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   if(dealMagic < InpMagicBase || dealMagic >= InpMagicBase + MAX_SLOTS) return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) return;
   if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                   HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                   HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   double profitReal = profit * g_acctUnit;
   g_dayRealizedPL += profitReal;
   CheckDayRollover();

   double maxLossUSD = InpMaxDailyLossUSD;
   if(InpUseRiskPctEquity)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > 0.0)
         maxLossUSD = equity * (InpMaxDailyLossPct / 100.0);
   }

   if(InpDailyLossLimitEnable && !g_dailyLimitHit && g_dayRealizedPL <= -MathAbs(maxLossUSD))
   {
      g_dailyLimitHit = true;
      Print("[MULTI32] Limite diario alcanzado: bloqueo de entradas por hoy.");
   }
}
//+------------------------------------------------------------------+
//  Estado diario + persistencia
//+------------------------------------------------------------------+
void CheckDayRollover()
{
   datetime now = TimeTradeServer();
   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);
   datetime dayStart = now - (dtNow.hour * 3600 + dtNow.min * 60 + dtNow.sec);
   if(dayStart != g_dayStart)
   {
      g_dayStart = dayStart;
      g_dayRealizedPL = 0.0;
      g_dailyLimitHit = false;
   }
}
void SavePersistedState()
{
   if(!InpPersistState) return;
   GlobalVariableSet("M32B_DAYSTART", (double)g_dayStart);
   GlobalVariableSet("M32B_DAYPL", g_dayRealizedPL);
   GlobalVariableSet("M32B_COOLDOWN", (double)g_cooldownUntil);
}
void LoadPersistedState()
{
   if(!InpPersistState) return;
   datetime now = TimeTradeServer();
   MqlDateTime dtNow; TimeToStruct(now, dtNow);
   datetime dayStart = now - (dtNow.hour * 3600 + dtNow.min * 60 + dtNow.sec);
   if(GlobalVariableCheck("M32B_COOLDOWN"))
   {
      datetime cd = (datetime)GlobalVariableGet("M32B_COOLDOWN");
      if(cd > now) g_cooldownUntil = cd;
   }
   if(GlobalVariableCheck("M32B_DAYSTART"))
   {
      datetime stored = (datetime)GlobalVariableGet("M32B_DAYSTART");
      if(stored == dayStart)
      {
         g_dayStart = dayStart;
         g_dayRealizedPL = GlobalVariableGet("M32B_DAYPL");
         double maxLossUSD = InpMaxDailyLossUSD;
         if(InpUseRiskPctEquity)
         {
            double equity = AccountInfoDouble(ACCOUNT_EQUITY);
            if(equity > 0.0)
               maxLossUSD = equity * (InpMaxDailyLossPct / 100.0);
         }
         if(InpDailyLossLimitEnable && g_dayRealizedPL <= -MathAbs(maxLossUSD))
            g_dailyLimitHit = true;
      }
   }
}
//+------------------------------------------------------------------+
//  OnInit / OnTick / OnDeinit
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpLotMode == LOT_MODE_RISK)
   {
      if(InpUseRiskPctEquity)
      {
         if(InpRiskPctEquity <= 0.0)
         {
            Print("ERROR: InpRiskPctEquity debe ser > 0.");
            return INIT_PARAMETERS_INCORRECT;
         }
      }
      else if(InpRiskPerTradeUSD <= 0.0)
      {
         Print("ERROR: InpRiskPerTradeUSD debe ser > 0.");
         return INIT_PARAMETERS_INCORRECT;
      }
   }
   if(InpDailyLossLimitEnable)
   {
      if(InpUseRiskPctEquity)
      {
         if(InpMaxDailyLossPct <= 0.0)
         {
            Print("ERROR: InpMaxDailyLossPct debe ser > 0.");
            return INIT_PARAMETERS_INCORRECT;
         }
      }
      else if(InpMaxDailyLossUSD <= 0.0)
      {
         Print("ERROR: InpMaxDailyLossUSD debe ser > 0.");
         return INIT_PARAMETERS_INCORRECT;
      }
   }

   DetectAccountType();

   //--- slots
   int starts[MAX_SLOTS]   = {InpSlot01Start, InpSlot02Start, InpSlot03Start, InpSlot04Start,
                              InpSlot05Start, InpSlot06Start, InpSlot07Start, InpSlot08Start};
   int ends[MAX_SLOTS]     = {InpSlot01End, InpSlot02End, InpSlot03End, InpSlot04End,
                              InpSlot05End, InpSlot06End, InpSlot07End, InpSlot08End};
   int strats[MAX_SLOTS]   = {InpSlot01Strategy, InpSlot02Strategy, InpSlot03Strategy, InpSlot04Strategy,
                              InpSlot05Strategy, InpSlot06Strategy, InpSlot07Strategy, InpSlot08Strategy};
   double tps[MAX_SLOTS]   = {InpSlot01TP, InpSlot02TP, InpSlot03TP, InpSlot04TP,
                              InpSlot05TP, InpSlot06TP, InpSlot07TP, InpSlot08TP};
   int ttls[MAX_SLOTS]     = {InpSlot01TTL, InpSlot02TTL, InpSlot03TTL, InpSlot04TTL,
                              InpSlot05TTL, InpSlot06TTL, InpSlot07TTL, InpSlot08TTL};

   for(int s = 0; s < MAX_SLOTS; s++)
   {
      g_slots[s].strategy   = strats[s];
      g_slots[s].altEnable  = (s == 2) ? InpSlot03AltEnable : false;
      g_slots[s].startHour  = starts[s];
      g_slots[s].endHour    = ends[s];
      g_slots[s].tpMult     = tps[s];
      g_slots[s].ttlBars    = ttls[s];
      g_slots[s].magic      = (int)(InpMagicBase + s);
      g_slots[s].ticket     = 0;
   }

   g_hATR  = iATR(_Symbol, TF, 14);
   g_hEMA20 = iMA(_Symbol, TF, 20, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA30 = iMA(_Symbol, TF, 30, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA60 = iMA(_Symbol, TF, 60, 0, MODE_EMA, PRICE_CLOSE);

   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetExpertMagicNumber(InpMagicBase);

   g_barIdx = Bars(_Symbol, TF);
   OnNewBar();
   LoadPersistedState();

   PrintFormat("[MULTI32] EA cargado: %s | ModoRiesgo: %s (%.2f%s) | MaxLote %.2f",
               _Symbol, (InpUseRiskPctEquity ? "PctEquity" : "USD_Fijo"), (InpUseRiskPctEquity ? InpRiskPctEquity : InpRiskPerTradeUSD), (InpUseRiskPctEquity ? "%" : " USD"), InpMaxLotSize);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   SavePersistedState();
   if(g_hATR != INVALID_HANDLE)   IndicatorRelease(g_hATR);
   if(g_hEMA20 != INVALID_HANDLE) IndicatorRelease(g_hEMA20);
   if(g_hEMA30 != INVALID_HANDLE) IndicatorRelease(g_hEMA30);
   if(g_hEMA60 != INVALID_HANDLE) IndicatorRelease(g_hEMA60);
}
void OnTick()
{
   static int lastBars = 0;
   int bars = Bars(_Symbol, TF);
   if(bars != lastBars)
   {
      lastBars = bars;
      OnNewBar();
      CheckDayRollover();
      ManagePositions();
      TryEntries();
   }
}
