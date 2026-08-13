//+------------------------------------------------------------------+
//|                                                    ApexQuant.mq5 |
//|                                  Version 26.0 - CRYPTO READY     |
//|                          Lógica: Rompimiento M1 + Ajuste Margen  |
//+------------------------------------------------------------------+
#property copyright "ApexQuant Pro"
#property version   "26.00"
#property strict

#include <Trade/Trade.mqh>

input double   Inp_LotSize       = 0.01;      // BAJADO A 0.01 PARA CRYPTO
input int      Inp_EMAPeriod     = 20;        
input int      Inp_Magic         = 20260209;

CTrade   trade;
bool     isPaused = false;
int      handleEMA;
datetime lastTradeBar;

int OnInit() {
   trade.SetExpertMagicNumber(Inp_Magic);
   trade.SetTypeFillingBySymbol(_Symbol);
   handleEMA = iMA(_Symbol, PERIOD_M1, Inp_EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   CreateUI();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { 
   ObjectsDeleteAll(0, "AQ_"); 
   IndicatorRelease(handleEMA);
}

void OnTick() {
   if(isPaused) return;
   if(PositionsTotalCount() > 0) return;

   double high1 = iHigh(_Symbol, PERIOD_M1, 1);
   double low1  = iLow(_Symbol, PERIOD_M1, 1);
   double ema[];
   ArraySetAsSeries(ema, true);
   CopyBuffer(handleEMA, 0, 0, 1, ema);
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // DIBUJAR LÍNEAS DE GATILLO
   DrawLines(high1, low1);

   datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
   if(currentBar == lastTradeBar) return;

   // VERIFICACIÓN DE MARGEN ANTES DE TIRAR
   double marginRequired;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, Inp_LotSize, ask, marginRequired)) {
      Print("Error calculando margen");
   }

   bool buySig  = (ask > high1) && (ask > ema[0]); 
   bool sellSig = (bid < low1) && (bid < ema[0]);

   if(buySig || sellSig) {
      if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) > marginRequired) {
         if(trade.PositionOpen(_Symbol, (buySig?ORDER_TYPE_BUY:ORDER_TYPE_SELL), Inp_LotSize, (buySig?ask:bid), 0, 0)) {
            lastTradeBar = currentBar;
         }
      } else {
         Comment("ERROR: MARGEN INSUFICIENTE\nNecesitas: $", DoubleToString(marginRequired, 2), "\nTienes: $", DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
      }
   }
}

void DrawLines(double h, double l) {
   ObjectCreate(0, "AQ_High", OBJ_HLINE, 0, 0, h);
   ObjectSetInteger(0, "AQ_High", OBJPROP_COLOR, clrCyan);
   ObjectMove(0, "AQ_High", 0, 0, h);
   ObjectCreate(0, "AQ_Low", OBJ_HLINE, 0, 0, l);
   ObjectSetInteger(0, "AQ_Low", OBJPROP_COLOR, clrMagenta);
   ObjectMove(0, "AQ_Low", 0, 0, l);
}

int PositionsTotalCount() {
   int c=0; for(int i=0; i<PositionsTotal(); i++) 
      if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC)==Inp_Magic) c++;
   return c;
}

void CreateUI() {
   ObjectCreate(0, "AQ_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "AQ_BG", OBJPROP_XDISTANCE, 10); ObjectSetInteger(0, "AQ_BG", OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, "AQ_BG", OBJPROP_XSIZE, 200); ObjectSetInteger(0, "AQ_BG", OBJPROP_YSIZE, 60);
   ObjectSetInteger(0, "AQ_BG", OBJPROP_BGCOLOR, clrBlack);
   ObjectCreate(0, "AQ_P", OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, "AQ_P", OBJPROP_XDISTANCE, 20); ObjectSetInteger(0, "AQ_P", OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, "AQ_P", OBJPROP_XSIZE, 80); ObjectSetInteger(0, "AQ_P", OBJPROP_YSIZE, 25);
   ObjectSetString(0, "AQ_P", OBJPROP_TEXT, "PAUSE");
   ObjectCreate(0, "AQ_X", OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, "AQ_X", OBJPROP_XDISTANCE, 110); ObjectSetInteger(0, "AQ_X", OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, "AQ_X", OBJPROP_XSIZE, 80); ObjectSetInteger(0, "AQ_X", OBJPROP_YSIZE, 25);
   ObjectSetString(0, "AQ_X", OBJPROP_TEXT, "PANIC");
}