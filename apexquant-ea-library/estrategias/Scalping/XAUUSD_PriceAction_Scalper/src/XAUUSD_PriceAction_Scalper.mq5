//+------------------------------------------------------------------+
//|                                    XAUUSD_FVG_Scalper.mq5         |
//|                              APEXQUANT / NeurAlgo project         |
//+------------------------------------------------------------------+
#property copyright "APEXQUANT"
#property version   "1.00"
#property strict
#property description "Scalper XAUUSD - Fair Value Gaps (imbalance de 3 velas)"

#include <Trade\Trade.mqh>
CTrade trade;

input group "=== Estrategia (FVG) ==="
input double   InpMinGapATR       = 0.15;   // tamano minimo del gap (x ATR)
input int      InpMaxZoneAgeBars  = 50;      // expira zona no tocada tras N barras
input int      InpMaxActiveZones  = 8;
input double   InpZoneInvalidateATR = 0.5;   // invalida zona si el precio la rompe por esto (x ATR)

input group "=== Gestion de Riesgo ==="
input double   InpRiskPercent     = 1.0;
input double   InpRR              = 2.0;
input int      InpATRPeriod       = 14;
input double   InpSLBufferATR     = 0.3;
input bool     InpUseTrailing     = true;
input double   InpTrailStart_ATR  = 1.0;
input double   InpTrailStep_ATR   = 0.5;

input group "=== Gestion General ==="
input ulong    InpMagicNumber     = 202672;
input int      InpMaxSpreadPoints = 350;
input bool     InpOneTradeAtATime = true;

input group "=== Visualizacion ==="
input color    InpColorTP         = clrTeal;
input color    InpColorSL         = clrCrimson;
input color    InpColorBullFVG    = clrDodgerBlue;
input color    InpColorBearFVG    = clrOrange;
input int      InpBoxExtendBars   = 5;
input int      InpZoneExtendBars  = 30;
input bool     InpShowLabels      = true;

int hATR;

struct FVGZone
  {
   double   top;
   double   bottom;
   datetime time;
   int      type;      // 1 alcista (soporte), -1 bajista (resistencia)
   bool     active;
   string   objName;
  };
FVGZone zones[];

//+------------------------------------------------------------------+
int OnInit()
  {
   hATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(hATR == INVALID_HANDLE)
     {
      Print("Error creando ATR");
      return(INIT_FAILED);
     }
   ArrayResize(zones, 0);
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "TRD_");
   ObjectsDeleteAll(0, "FVGZ_");
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
//| Deteccion y dibujo de zonas FVG                                   |
//+------------------------------------------------------------------+
void DrawFVGBox(int idx)
  {
   datetime t1 = zones[idx].time;
   datetime t2 = t1 + PeriodSeconds(PERIOD_CURRENT) * InpZoneExtendBars;
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
  }
//+------------------------------------------------------------------+
void DeactivateZone(int i)
  {
   if(zones[i].objName != "")
      ObjectDelete(0, zones[i].objName);
   zones[i].active = false;
  }
//+------------------------------------------------------------------+
int CountActiveZones()
  {
   int cnt = 0;
   for(int i = 0; i < ArraySize(zones); i++)
      if(zones[i].active) cnt++;
   return(cnt);
  }
//+------------------------------------------------------------------+
void AddZone(double bottom, double top, datetime t, int type)
  {
   if(CountActiveZones() >= InpMaxActiveZones) return;

   int n = ArraySize(zones);
   ArrayResize(zones, n+1);
   zones[n].top     = top;
   zones[n].bottom  = bottom;
   zones[n].time    = t;
   zones[n].type    = type;
   zones[n].active  = true;
   zones[n].objName = "";

   DrawFVGBox(n);
  }
//+------------------------------------------------------------------+
void TrimZones()
  {
   int total = ArraySize(zones);
   if(total <= InpMaxActiveZones*3) return;

   FVGZone tmp[];
   int cnt = 0;
   for(int i = 0; i < total; i++)
      if(zones[i].active) cnt++;

   ArrayResize(tmp, cnt);
   int idx = 0;
   for(int i = 0; i < total; i++)
     {
      if(zones[i].active)
        {
         tmp[idx] = zones[i];
         idx++;
        }
     }
   ArrayResize(zones, cnt);
   for(int i = 0; i < cnt; i++)
      zones[i] = tmp[i];
  }
//+------------------------------------------------------------------+
void DetectNewFVG()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 4, r) < 4) return;

   double atr = GetATR();
   if(atr <= 0) return;
   double minGap = atr * InpMinGapATR;

   // r[1] = vela mas reciente cerrada (C), r[2] = vela impulsiva (B), r[3] = vela mas antigua (A)
   if(r[3].high < r[1].low && (r[1].low - r[3].high) >= minGap)
      AddZone(r[3].high, r[1].low, r[1].time, 1);

   if(r[3].low > r[1].high && (r[3].low - r[1].high) >= minGap)
      AddZone(r[1].high, r[3].low, r[1].time, -1);
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
void OpenTrade(int direction, double structPrice)
  {
   double atr = GetATR();
   if(atr <= 0) return;
   double buffer = atr * InpSLBufferATR;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   bool ok = false;
   if(direction == 1)
     {
      double sl = NormalizeDouble(structPrice - buffer, digits);
      double slDist = ask - sl;
      if(slDist <= 0) return;
      double tp = NormalizeDouble(ask + slDist*InpRR, digits);
      double lots = CalcLotSize(slDist/point);
      if(lots <= 0) return;
      ok = trade.Buy(lots, _Symbol, ask, sl, tp, "XAU_FVG_Buy");
     }
   else
     {
      double sl = NormalizeDouble(structPrice + buffer, digits);
      double slDist = sl - bid;
      if(slDist <= 0) return;
      double tp = NormalizeDouble(bid - slDist*InpRR, digits);
      double lots = CalcLotSize(slDist/point);
      if(lots <= 0) return;
      ok = trade.Sell(lots, _Symbol, bid, sl, tp, "XAU_FVG_Sell");
     }

   if(!ok)
      Print("Error al abrir orden: ", trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
void ManageZones()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr = GetATR();
   if(atr <= 0) return;

   for(int i = ArraySize(zones)-1; i >= 0; i--)
     {
      if(!zones[i].active) continue;

      if(TimeCurrent() - zones[i].time > PeriodSeconds(PERIOD_CURRENT) * InpMaxZoneAgeBars)
        {
         DeactivateZone(i);
         continue;
        }

      if(zones[i].type == 1)
        {
         if(bid < zones[i].bottom - atr*InpZoneInvalidateATR)
           {
            DeactivateZone(i);
            continue;
           }
         if(bid <= zones[i].top && bid >= zones[i].bottom)
           {
            if(InpOneTradeAtATime && CountMyPositions() > 0) continue;
            if(!SpreadOK()) continue;
            OpenTrade(1, zones[i].bottom);
            DeactivateZone(i);
           }
        }
      else
        {
         if(ask > zones[i].top + atr*InpZoneInvalidateATR)
           {
            DeactivateZone(i);
            continue;
           }
         if(ask >= zones[i].bottom && ask <= zones[i].top)
           {
            if(InpOneTradeAtATime && CountMyPositions() > 0) continue;
            if(!SpreadOK()) continue;
            OpenTrade(-1, zones[i].top);
            DeactivateZone(i);
           }
        }
     }
  }
//+------------------------------------------------------------------+
void ManageTrailing()
  {
   if(!InpUseTrailing) return;
   double atr = GetATR();
   if(atr <= 0) return;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

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
      ObjectMove(0, name, 1, t2, price);
  }
//+------------------------------------------------------------------+
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
//+------------------------------------------------------------------+
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
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

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
      ulong ticket = (ulong)StringToInteger(StringSubstr(rest, 0, p));
      if(!PositionSelectByTicket(ticket))
         ObjectDelete(0, name);
     }
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateTradeVisuals();
   CleanupClosedVisuals();
   ManageTrailing();
   ManageZones();

   static datetime lastBarTime = 0;
   datetime curBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBarTime != lastBarTime)
     {
      lastBarTime = curBarTime;
      DetectNewFVG();
      TrimZones();
     }
  }
//+------------------------------------------------------------------+