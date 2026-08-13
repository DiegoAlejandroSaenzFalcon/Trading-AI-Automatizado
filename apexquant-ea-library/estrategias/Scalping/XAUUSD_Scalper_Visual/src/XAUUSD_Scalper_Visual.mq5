//+------------------------------------------------------------------+
//|                                    XAUUSD_Scalper_Visual.mq5      |
//|                                   APEXQUANT / NeurAlgo project    |
//+------------------------------------------------------------------+
#property copyright "APEXQUANT"
#property version   "1.00"
#property strict
#property description "Scalper XAUUSD con visualizacion de SL/TP tipo TradingView"

#include <Trade\Trade.mqh>
CTrade trade;

//--- Estrategia
input group "=== Estrategia ==="
input int      InpFastEMA         = 8;
input int      InpSlowEMA         = 21;
input int      InpRSIPeriod       = 14;
input double   InpRSIOverbought   = 70.0;
input double   InpRSIOversold     = 30.0;
input int      InpATRPeriod       = 14;

//--- Gestion de riesgo
input group "=== Gestion de Riesgo ==="
input double   InpRiskPercent     = 1.0;      // % de balance por operacion
input double   InpSL_ATR_Mult     = 1.5;
input double   InpTP_ATR_Mult     = 3.0;
input bool     InpUseTrailing     = true;
input double   InpTrailStart_ATR  = 1.0;
input double   InpTrailStep_ATR   = 0.5;

//--- Gestion general
input group "=== Gestion General ==="
input ulong    InpMagicNumber     = 202607;
input int      InpMaxSpreadPoints = 350;
input bool     InpOneTradeAtATime = true;

//--- Visualizacion
input group "=== Visualizacion ==="
input color    InpColorTP         = clrTeal;
input color    InpColorSL         = clrCrimson;
input int      InpBoxExtendBars   = 5;
input bool     InpShowLabels      = true;

//--- handles
int hEMAFast, hEMASlow, hRSI, hATR;
ulong knownTickets[];

//+------------------------------------------------------------------+
int OnInit()
  {
   hEMAFast = iMA(_Symbol, PERIOD_CURRENT, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow = iMA(_Symbol, PERIOD_CURRENT, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriod, PRICE_CLOSE);
   hATR     = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);

   if(hEMAFast==INVALID_HANDLE || hEMASlow==INVALID_HANDLE || hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE)
     {
      Print("Error creando indicadores");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "TRD_");
  }
//+------------------------------------------------------------------+
double GetATR()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hATR, 0, 0, 1, buf) <= 0) return(0);
   return(buf[0]);
  }
//+------------------------------------------------------------------+
int GetSignal()
  {
   double emaFast[], emaSlow[], rsi[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsi, true);

   if(CopyBuffer(hEMAFast, 0, 0, 3, emaFast) <= 0) return(0);
   if(CopyBuffer(hEMASlow, 0, 0, 3, emaSlow) <= 0) return(0);
   if(CopyBuffer(hRSI, 0, 0, 3, rsi) <= 0) return(0);

   bool crossUp   = (emaFast[2] <= emaSlow[2]) && (emaFast[1] > emaSlow[1]);
   bool crossDown = (emaFast[2] >= emaSlow[2]) && (emaFast[1] < emaSlow[1]);

   if(crossUp && rsi[1] < InpRSIOverbought)   return(1);
   if(crossDown && rsi[1] > InpRSIOversold)   return(-1);
   return(0);
  }
//+------------------------------------------------------------------+
double CalcLotSize(double slPoints)
  {
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickSize <= 0 || tickValue <= 0 || slPoints <= 0) return(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));

   double moneyPerPoint = (tickValue / tickSize) * point;
   double lots = riskMoney / (slPoints * moneyPerPoint);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return(NormalizeDouble(lots, 2));
  }
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spread <= InpMaxSpreadPoints);
  }
//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int cnt = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         cnt++;
     }
   return(cnt);
  }
//+------------------------------------------------------------------+
void OpenTrade(int direction)
  {
   double atr = GetATR();
   if(atr <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double slDist = atr * InpSL_ATR_Mult;
   double tpDist = atr * InpTP_ATR_Mult;
   double slPoints = slDist / point;

   double lots = CalcLotSize(slPoints);
   if(lots <= 0) return;

   bool ok = false;
   if(direction == 1)
     {
      double sl = NormalizeDouble(ask - slDist, digits);
      double tp = NormalizeDouble(ask + tpDist, digits);
      ok = trade.Buy(lots, _Symbol, ask, sl, tp, "XAU_Scalp_Buy");
     }
   else
     {
      double sl = NormalizeDouble(bid + slDist, digits);
      double tp = NormalizeDouble(bid - tpDist, digits);
      ok = trade.Sell(lots, _Symbol, bid, sl, tp, "XAU_Scalp_Sell");
     }

   if(!ok)
      Print("Error al abrir orden: ", trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
void ManageTrailing()
  {
   if(!InpUseTrailing) return;
   double atr = GetATR();
   if(atr <= 0) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      long   type      = PositionGetInteger(POSITION_TYPE);

      double startDist = atr * InpTrailStart_ATR;
      double stepDist  = atr * InpTrailStep_ATR;

      if(type == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid - openPrice >= startDist)
           {
            double newSL = NormalizeDouble(bid - stepDist, digits);
            if(newSL > curSL && newSL < bid)
               trade.PositionModify(ticket, newSL, curTP);
           }
        }
      else
        if(type == POSITION_TYPE_SELL)
          {
           double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
           if(openPrice - ask >= startDist)
             {
              double newSL = NormalizeDouble(ask + stepDist, digits);
              if((newSL < curSL || curSL == 0) && newSL > ask)
                 trade.PositionModify(ticket, newSL, curTP);
             }
          }
     }
  }
//+------------------------------------------------------------------+
//| Visualizacion de operaciones (cajas TP/SL sombreadas)             |
//+------------------------------------------------------------------+
void DrawTradeBox(string prefix, datetime t1, datetime t2, double p1, double p2, color clr)
  {
   string name = prefix;
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
     {
      ObjectMove(0, name, 1, t2, p2);
     }
  }
//+------------------------------------------------------------------+
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
     {
      ObjectMove(0, name, 1, t2, price);
     }
  }
//+------------------------------------------------------------------+
void DrawTradeLabel(string name, datetime t, double price, string text, color clr, ENUM_ANCHOR_POINT anchor)
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
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   else
     {
      ObjectMove(0, name, 0, t, price);
     }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }
//+------------------------------------------------------------------+
void UpdateTradeVisuals()
  {
   datetime now = TimeCurrent();
   int barSeconds = PeriodSeconds(PERIOD_CURRENT);
   datetime extendedTime = now + barSeconds * InpBoxExtendBars;

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl         = PositionGetDouble(POSITION_SL);
      double tp         = PositionGetDouble(POSITION_TP);
      double volume     = PositionGetDouble(POSITION_VOLUME);
      long   type       = PositionGetInteger(POSITION_TYPE);
      double profit     = PositionGetDouble(POSITION_PROFIT);

      string base = "TRD_" + (string)ticket + "_";
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      if(tp > 0)
        {
         DrawTradeBox(base+"TP", openTime, extendedTime, openPrice, tp, ColorToARGB(InpColorTP, 60));
         DrawTradeLine(base+"TPLine", openTime, extendedTime, tp, InpColorTP);
         double tpPct = (type==POSITION_TYPE_BUY) ? (tp-openPrice)/openPrice*100.0 : (openPrice-tp)/openPrice*100.0;
         string tpTxt = StringFormat("Objetivo: %s (%.2f%%)  Vol: %.2f", DoubleToString(tp,digits), tpPct, volume);
         DrawTradeLabel(base+"TPLabel", extendedTime, tp, tpTxt, InpColorTP, ANCHOR_RIGHT);
        }

      if(sl > 0)
        {
         DrawTradeBox(base+"SL", openTime, extendedTime, openPrice, sl, ColorToARGB(InpColorSL, 60));
         DrawTradeLine(base+"SLLine", openTime, extendedTime, sl, InpColorSL);
         double slPct = (type==POSITION_TYPE_BUY) ? (openPrice-sl)/openPrice*100.0 : (sl-openPrice)/openPrice*100.0;
         string slTxt = StringFormat("Stop: %s (%.2f%%)  P/L: %.2f", DoubleToString(sl,digits), slPct, profit);
         DrawTradeLabel(base+"SLLabel", extendedTime, sl, slTxt, InpColorSL, ANCHOR_RIGHT);
        }

      DrawTradeLine(base+"OpenLine", openTime, extendedTime, openPrice, clrSilver);
     }
  }
//+------------------------------------------------------------------+
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
      string ticketStr = StringSubstr(rest, 0, p);
      ulong ticket = (ulong)StringToInteger(ticketStr);

      if(!PositionSelectByTicket(ticket))
         ObjectDelete(0, name);
     }
  }
//+------------------------------------------------------------------+
color ColorToARGB(color clr, int alpha)
  {
   return((color)clr);
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateTradeVisuals();
   CleanupClosedVisuals();
   ManageTrailing();

   static datetime lastBarTime = 0;
   datetime curBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBarTime == lastBarTime) return;
   lastBarTime = curBarTime;

   if(InpOneTradeAtATime && CountMyPositions() > 0) return;
   if(!SpreadOK()) return;

   int signal = GetSignal();
   if(signal != 0)
      OpenTrade(signal);
  }
//+------------------------------------------------------------------+
