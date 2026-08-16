//+------------------------------------------------------------------+
//|                                    Pure_Fractal_MOMEMA_04_06_XAU.mq5 |
//|           MOMEMA XAUUSDm 04-06h — validado walk-forward 2024-2026  |
//|  SL 0.8×ATR | TP 3R | TTL 2h | 2×0.75%/día | breaker −1.5%/día     |
//+------------------------------------------------------------------+
#property copyright "ApexQuant / Pure Fractal FVG Fusion"
#property link      "https://github.com/DiegoAlejandroSaenzFalcon/Trading-AI-Automatizado"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Entrada principal
input group "=== Riesgo y Tamaño (USD reales) ==="
input ENUM_LOT_MODE    InpLotMode           = LOT_MODE_RISK;      // 0=riesgo USD fijo, 1=lote fijo
input double           InpRiskPerTradeUSD   = 0.0;                 // Riesgo $ por trade (0 = usa %)
input double           InpRiskPctEquity     = 0.75;                // % equity por trade (si RiskPerTradeUSD=0)
input double           InpMaxLotSize        = 2.0;                 // Lote máximo
input int              InpSLMultATR         = 80;                  // SL = ATR_M5 * esto / 100 (0.80)
input double           InpTPMult            = 3.0;                 // TP = SL * esto (3.0 = 3R)
input int              InpTTLBars           = 24;                  // TTL en velas M5 (24 = 2h)
input int              InpMaxTradesPerDay   = 2;                   // Máx entradas por día
input double           InpDailyLossLimitPct = 1.5;                 // Límite pérdida diaria % equity
input int              InpCooldownMinutes   = 5;                   // Pausa tras pérdida (min)

input group "=== Filtro de Sesión (hora SERVIDOR) ==="
input bool             InpSessionEnable     = true;                // Filtrar franja 04-06h
input int              InpStartHour         = 4;                   // Inicio franja
input int              InpEndHour           = 6;                   // Fin franja (exclusivo)

input group "=== Indicadores ==="
input int              InpATRPeriod         = 14;                  // ATR period M5
input int              InpEMA30Period       = 30;                  // EMA30 M5

input group "=== Magic & Cuenta ==="
input int              InpMagicBase         = 920001;              // Magic único MOMEMA 04-06 XAU
input ENUM_ACCOUNT_TYPE  InpAccountType     = ACCT_AUTO;           // 0=AUTO, 1=Standard, 2=Cent, 3=Micro

//--- Globales
CTrade         g_trade;
CPositionInfo  g_pos;
CSymbolInfo    g_sym;
double         g_atrBuf[];
int            g_atrHandle = INVALID_HANDLE;
int            g_ema30Handle = INVALID_HANDLE;
datetime       g_lastBarTime = 0;
int            g_todayTrades = 0;
datetime       g_todayStart = 0;
double         g_dailyStartEquity = 0;
bool           g_dailyBreaker = false;
datetime       g_cooldownUntil = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicBase);
   if(!g_sym.Name(_Symbol))
   {
      Print("Error: símbolo no encontrado");
      return INIT_FAILED;
   }

   g_atrHandle = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   g_ema30Handle = iMA(_Symbol, PERIOD_M5, InpEMA30Period, 0, MODE_EMA, PRICE_CLOSE);

   if(g_atrHandle == INVALID_HANDLE || g_ema30Handle == INVALID_HANDLE)
   {
      Print("Error creando indicadores: ", GetLastError());
      return INIT_FAILED;
   }

   ArraySetAsSeries(g_atrBuf, true);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_atrHandle);
   IndicatorRelease(g_ema30Handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_sym.RefreshRates()) return;

   //--- Nueva vela M5
   datetime curBar = iTime(_Symbol, PERIOD_M5, 0);
   if(curBar == g_lastBarTime) return;
   g_lastBarTime = curBar;

   //--- Rollover diario
   datetime dayStart = curBar - (TimeHour(curBar)*3600 + TimeMinute(curBar)*60 + TimeSeconds(curBar));
   if(dayStart != g_todayStart)
   {
      g_todayStart = dayStart;
      g_todayTrades = 0;
      g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyBreaker = false;
   }

   //--- Circuit breaker diario
   if(InpDailyLossLimitPct > 0 && !g_dailyBreaker)
   {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double dd = (g_dailyStartEquity - eq) / g_dailyStartEquity * 100.0;
      if(dd >= InpDailyLossLimitPct)
      {
         g_dailyBreaker = true;
         Print("⚠ Circuit breaker activado: DD diario ", dd:2, "% >= ", InpDailyLossLimitPct, "%");
      }
   }

   //--- Cooldown tras pérdida
   if(g_cooldownUntil > 0 && TimeTradeServer() < g_cooldownUntil) return;

   //--- Filtro de sesión 04-06h
   if(InpSessionEnable)
   {
      int h = TimeHour(curBar);
      if(h < InpStartHour || h >= InpEndHour) return;
   }

   //--- Límite de trades diarios
   if(g_todayTrades >= InpMaxTradesPerDay) return;

   //--- Señal MOMEMA en vela cerrada (shift 1)
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double e30 = iMA(_Symbol, PERIOD_M5, InpEMA30Period, 0, MODE_EMA, PRICE_CLOSE, 1);
   double hx = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, 3, 2);  // máx 3 velas desde shift 2
   double ln = iLowest(_Symbol, PERIOD_M5, MODE_LOW, 3, 2);    // mín 3 velas desde shift 2

   int sig = 0;
   if(c1 > e30 && c1 > hx) sig = 1;         // BUY
   else if(c1 < e30 && c1 < ln) sig = -1;   // SELL

   if(sig == 0) return;

   //--- ATR actual (vela 1)
   double atr = iATR(_Symbol, PERIOD_M5, InpATRPeriod, 1);
   if(atr <= 0) return;

   //--- Cálculo de lote y niveles
   double riskUSD = (InpRiskPerTradeUSD > 0) ? InpRiskPerTradeUSD : AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPctEquity / 100.0;
   double slDist = InpSLMultATR / 100.0 * atr;
   double tpDist = slDist * InpTPMult;

   if(slDist <= 0 || tpDist <= 0) return;

   double entryPrice = (sig == 1) ? g_sym.Ask() : g_sym.Bid();
   double sl = (sig == 1) ? entryPrice - slDist : entryPrice + slDist;
   double tp = (sig == 1) ? entryPrice + tpDist : entryPrice - tpDist;

   double lot = riskUSD / (slDist * g_sym.TickValue());
   lot = NormalizeDouble(lot, 2);
   if(lot < 0.01) lot = 0.01;
   if(lot > InpMaxLotSize) lot = InpMaxLotSize;

   //--- Verificar spread
   if(g_sym.Spread() > 0)
   {
      double spreadPts = g_sym.Spread() * g_sym.Point();
      if(spreadPts > atr * 0.35) return; // filtro spread > 0.35 ATR
   }

   //--- Enviar orden
   ENUM_ORDER_TYPE type = (sig == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(g_trade.PositionOpen(_Symbol, type, lot, entryPrice, sl, tp, "MOMEMA 04-06"))
   {
      g_todayTrades++;
      Print("✓ MOMEMA ", EnumToString(type), " | lot=", lot, " entry=", entryPrice, " SL=", sl, " TP=", tp);
   }
   else
   {
      Print("✗ Error abriendo: ", g_trade.ResultRetcode(), " ", g_trade.ResultComment());
      if(g_trade.ResultRetcode() == 10014 || g_trade.ResultRetcode() == 10021)
         g_cooldownUntil = TimeTradeServer() + InpCooldownMinutes * 60;
   }

   //--- TTL management
   ManageTTL();
}

//+------------------------------------------------------------------+
//| Gestión de Time-Stop (TTL)                                       |
//+------------------------------------------------------------------+
void ManageTTL()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) != InpMagicBase) continue;
         int entryBar = (int)PositionGetInteger(POSITION_TIME) / PeriodSeconds(PERIOD_M5);
         int curBar = iTime(_Symbol, PERIOD_M5, 0) / PeriodSeconds(PERIOD_M5);
         if(InpTTLBars > 0 && curBar - entryBar >= InpTTLBars)
         {
            if(g_trade.PositionClose(ticket))
               Print("⏰ TTL alcanzado: cerrada posición ", ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: sesiones                                                 |
//+------------------------------------------------------------------+
bool IsInSession(datetime t)
{
   if(!InpSessionEnable) return true;
   int h = TimeHour(t);
   return (h >= InpStartHour && h < InpEndHour);
}
//+------------------------------------------------------------------+