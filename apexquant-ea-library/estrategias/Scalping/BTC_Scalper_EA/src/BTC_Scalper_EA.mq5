//+------------------------------------------------------------------+
//|                          BTC_Scalper_EA.mq5                      |
//|              Scalping de Alta Frecuencia — BTCUSD M1             |
//|         v1.1 — Fix: stops válidos para BTC (price units)        |
//+------------------------------------------------------------------+
#property copyright   "BTC Scalper EA"
#property link        ""
#property version     "1.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//|  PARÁMETROS EXTERNOS (INPUTS)                                    |
//+------------------------------------------------------------------+

// ── Indicadores ──────────────────────────────────────────────────
input group "=== INDICADORES ==="
input int              InpEmaFastPeriod  = 20;       // Período EMA rápida
input int              InpEmaSlowPeriod  = 50;       // Período EMA lenta
input ENUM_MA_METHOD   InpMaMethod       = MODE_EMA; // Método MA (EMA / SMA)
input int              InpVwapBars       = 1440;     // Barras para VWAP (1440 = 1 día M1)

// ── Stop Loss / Take Profit ───────────────────────────────────────
// NOTA BTC: Los valores son en DÓLARES (USD), no en pips tradicionales.
// Ejemplo: InpStopLossUSD = 500 → SL a $500 del precio de entrada.
input group "=== SL / TP / TRAILING (en USD para BTC) ==="
input double   InpStopLossUSD     = 500.0;   // Stop Loss en USD (distancia de precio)
input double   InpTakeProfitUSD   = 1000.0;  // Take Profit en USD (distancia de precio)
input double   InpTrailingUSD     = 300.0;   // Trailing Stop en USD
input double   InpBreakevenUSD    = 250.0;   // Activar breakeven al llegar a X USD de beneficio
input bool     InpUseATRTrailing  = true;   // Usar ATR para trailing (true) o USD fijos (false)
input int      InpATRPeriod       = 14;      // Período ATR
input double   InpATRMultiplier   = 1.5;     // Multiplicador ATR para trailing

// ── Gestión de Riesgo ─────────────────────────────────────────────
input group "=== GESTIÓN DE RIESGO ==="
input double   InpRiskPercent     = 1.0;    // Riesgo por operación (% del balance)
input double   InpMaxSpreadPoints = 2000.0;  // Spread máximo en puntos (BTC: 100-500 normal)

// ── Filtro de Días ────────────────────────────────────────────────
input group "=== FILTRO DE DÍAS ==="
input bool     InpTradeSunday     = false;
input bool     InpTradeMonday     = false;
input bool     InpTradeTuesday    = true;
input bool     InpTradeWednesday  = true;
input bool     InpTradeThursday   = true;
input bool     InpTradeFriday     = false;
input bool     InpTradeSaturday   = false;

// ── Filtro de Sesión ──────────────────────────────────────────────
input group "=== FILTRO DE SESIÓN (GMT) ==="
input int      InpLondonOpen      = 8;
input int      InpLondonClose     = 17;
input int      InpNewYorkOpen     = 13;
input int      InpNewYorkClose    = 22;

// ── Configuración General ─────────────────────────────────────────
input group "=== CONFIGURACIÓN GENERAL ==="
input int      InpMagicNumber     = 202401;
input string   InpEaComment       = "BTC_Scalper";
input bool     InpEnableAlerts    = true;

//+------------------------------------------------------------------+
//|  VARIABLES GLOBALES                                              |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CAccountInfo   accountInfo;

int    handleEmaFast  = INVALID_HANDLE;
int    handleEmaSlow  = INVALID_HANDLE;
int    handleATR      = INVALID_HANDLE;

double pointSize      = 0.0;
datetime lastBarTime  = 0;

//+------------------------------------------------------------------+
//|  OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(500);           // 500 puntos slippage para BTC
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Tamaño de punto del símbolo
   pointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Crear handles
   handleEmaFast = iMA(_Symbol, _Period, InpEmaFastPeriod, 0, InpMaMethod, PRICE_CLOSE);
   handleEmaSlow = iMA(_Symbol, _Period, InpEmaSlowPeriod, 0, InpMaMethod, PRICE_CLOSE);
   handleATR     = iATR(_Symbol, _Period, InpATRPeriod);

   if(handleEmaFast == INVALID_HANDLE ||
      handleEmaSlow == INVALID_HANDLE ||
      handleATR     == INVALID_HANDLE)
   {
      Alert("BTC_Scalper: Error al crear handles. Código: ", GetLastError());
      return INIT_FAILED;
   }

   if(InpEmaFastPeriod >= InpEmaSlowPeriod)
   {
      Alert("BTC_Scalper: EMA rápida debe ser menor que EMA lenta.");
      return INIT_PARAMETERS_INCORRECT;
   }

   // ── Información diagnóstica en el log ────────────────────────
   double minStop = GetMinStopDistance();
   Print("════════════════════════════════════════════");
   Print("BTC_Scalper EA v1.1 inicializado");
   Print("Símbolo       : ", _Symbol);
   Print("SYMBOL_POINT  : ", pointSize);
   Print("Dígitos       : ", SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   Print("Stop mínimo   : ", minStop, " USD (broker)");
   Print("SL configurado: ", InpStopLossUSD, " USD");
   Print("TP configurado: ", InpTakeProfitUSD, " USD");

   if(InpStopLossUSD < minStop)
      Print("⚠ ADVERTENCIA: SL (", InpStopLossUSD, ") < stop mínimo del broker (", minStop, "). Ajusta InpStopLossUSD.");

   Print("════════════════════════════════════════════");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleEmaFast != INVALID_HANDLE) IndicatorRelease(handleEmaFast);
   if(handleEmaSlow != INVALID_HANDLE) IndicatorRelease(handleEmaSlow);
   if(handleATR     != INVALID_HANDLE) IndicatorRelease(handleATR);
   Print("BTC_Scalper EA desactivado. Razón: ", reason);
}

//+------------------------------------------------------------------+
//|  OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsTradeAllowed()) return;
   if(!IsConnected())    return;

   // Gestión continua de posiciones (trailing/breakeven en cada tick)
   ManageOpenPositions();

   // Lógica de entrada solo en nueva vela
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   if(!IsSessionAllowed())   return;
   if(!IsDayAllowed())       return;
   if(!IsSpreadAllowed())    return;

   double emaFast    = GetIndicatorValue(handleEmaFast, 1);
   double emaSlow    = GetIndicatorValue(handleEmaSlow, 1);
   double vwap       = CalculateVWAP(InpVwapBars);
   double closePrice = iClose(_Symbol, _Period, 1);

   if(emaFast == EMPTY_VALUE || emaSlow == EMPTY_VALUE || vwap == 0.0) return;

   int signal = GetSignal(closePrice, emaFast, emaSlow, vwap);

   if(!HasOpenPosition())
   {
      if(signal ==  1) OpenBuy();
      if(signal == -1) OpenSell();
   }
}

//+------------------------------------------------------------------+
//|  GetMinStopDistance — Distancia mínima de stop del broker en USD |
//+------------------------------------------------------------------+
double GetMinStopDistance()
{
   // SYMBOL_TRADE_STOPS_LEVEL devuelve el nivel mínimo en PUNTOS
   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   // Convertir puntos a USD
   return stopsLevel * pointSize;
}

//+------------------------------------------------------------------+
//|  ValidateStops — Ajusta SL/TP para que cumplan el mínimo broker  |
//|  Devuelve true si los stops son válidos                          |
//+------------------------------------------------------------------+
bool ValidateStops(double entryPrice, double &sl, double &tp, bool isBuy)
{
   double minDist = GetMinStopDistance();
   // Agregar un pequeño margen extra (10 puntos) sobre el mínimo
   double safeMin = minDist + 10 * pointSize;
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(isBuy)
   {
      // Para BUY: SL debe ser < entryPrice, TP debe ser > entryPrice
      double requiredSL = entryPrice - safeMin;
      double requiredTP = entryPrice + safeMin;

      if(sl > requiredSL)
      {
         Print("⚠ SL ajustado: ", sl, " → ", requiredSL,
               " (mínimo broker: ", minDist, " USD)");
         sl = NormalizeDouble(requiredSL, digits);
      }
      if(tp < requiredTP)
      {
         Print("⚠ TP ajustado: ", tp, " → ", requiredTP,
               " (mínimo broker: ", minDist, " USD)");
         tp = NormalizeDouble(requiredTP, digits);
      }
   }
   else
   {
      // Para SELL: SL debe ser > entryPrice, TP debe ser < entryPrice
      double requiredSL = entryPrice + safeMin;
      double requiredTP = entryPrice - safeMin;

      if(sl < requiredSL)
      {
         Print("⚠ SL ajustado: ", sl, " → ", requiredSL,
               " (mínimo broker: ", minDist, " USD)");
         sl = NormalizeDouble(requiredSL, digits);
      }
      if(tp > requiredTP)
      {
         Print("⚠ TP ajustado: ", tp, " → ", requiredTP,
               " (mínimo broker: ", minDist, " USD)");
         tp = NormalizeDouble(requiredTP, digits);
      }
   }

   // Validación final: rechazar si el SL configurado es menor que el mínimo del broker
   double slDist = MathAbs(entryPrice - sl);
   double tpDist = MathAbs(entryPrice - tp);

   if(slDist < minDist || tpDist < minDist)
   {
      Print("✖ Stops inválidos tras ajuste. SL dist: ", slDist,
            " | TP dist: ", tpDist, " | Min: ", minDist);
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//|  GetSignal                                                       |
//+------------------------------------------------------------------+
int GetSignal(double price, double emaFast, double emaSlow, double vwap)
{
   bool bullTrend    = (emaFast > emaSlow) && (price > vwap);
   bool bearTrend    = (emaFast < emaSlow) && (price < vwap);
   bool aboveEma     = (price > emaFast);
   bool belowEma     = (price < emaFast);

   if(bullTrend && aboveEma) return  1;
   if(bearTrend && belowEma) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//|  OpenBuy                                                         |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl = NormalizeDouble(ask - InpStopLossUSD,   digits);
   double tp = NormalizeDouble(ask + InpTakeProfitUSD, digits);

   // Validar y ajustar stops al mínimo del broker
   if(!ValidateStops(ask, sl, tp, true)) return;

   double lots = CalculateLotSize(InpStopLossUSD);
   if(lots <= 0)
   {
      Print("Error: lotaje calculado = 0. Revisa balance y parámetros.");
      return;
   }

   Print("Intentando BUY | Ask:", ask, " | SL:", sl, " | TP:", tp, " | Lots:", lots);

   if(trade.Buy(lots, _Symbol, ask, sl, tp, InpEaComment))
   {
      if(InpEnableAlerts)
         Alert("BTC_Scalper | BUY | Lots:", lots, " | SL:", sl, " | TP:", tp);
   }
   else
      Print("✖ Error BUY: ", trade.ResultRetcode(), " — ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//|  OpenSell                                                        |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl = NormalizeDouble(bid + InpStopLossUSD,   digits);
   double tp = NormalizeDouble(bid - InpTakeProfitUSD, digits);

   if(!ValidateStops(bid, sl, tp, false)) return;

   double lots = CalculateLotSize(InpStopLossUSD);
   if(lots <= 0) return;

   Print("Intentando SELL | Bid:", bid, " | SL:", sl, " | TP:", tp, " | Lots:", lots);

   if(trade.Sell(lots, _Symbol, bid, sl, tp, InpEaComment))
   {
      if(InpEnableAlerts)
         Alert("BTC_Scalper | SELL | Lots:", lots, " | SL:", sl, " | TP:", tp);
   }
   else
      Print("✖ Error SELL: ", trade.ResultRetcode(), " — ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//|  ManageOpenPositions — Trailing Stop y Breakeven por tick        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic()  != InpMagicNumber) continue;
      if(posInfo.Symbol() != _Symbol)        continue;

      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      double currentTP = posInfo.TakeProfit();
      ulong  ticket    = posInfo.Ticket();
      int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      // Calcular distancia de trailing
      double trailingDist = InpTrailingUSD;
      if(InpUseATRTrailing)
      {
         double atrVal = GetIndicatorValue(handleATR, 1);
         if(atrVal != EMPTY_VALUE && atrVal > 0)
            trailingDist = atrVal * InpATRMultiplier;
      }

      double minDist = GetMinStopDistance() + 10 * pointSize;
      double newSL   = currentSL;

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitDist = bid - openPrice;

         // Breakeven
         if(profitDist >= InpBreakevenUSD && currentSL < openPrice)
         {
            double beLevel = NormalizeDouble(openPrice + minDist, digits);
            if(beLevel > currentSL) newSL = beLevel;
         }

         // Trailing
         double trailLevel = NormalizeDouble(bid - trailingDist, digits);
         if(trailLevel > newSL && (bid - trailLevel) >= minDist)
            newSL = trailLevel;

         if(newSL > currentSL + pointSize)
            ModifyPosition(ticket, newSL, currentTP);
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitDist = openPrice - ask;

         // Breakeven
         if(profitDist >= InpBreakevenUSD && (currentSL > openPrice || currentSL == 0))
         {
            double beLevel = NormalizeDouble(openPrice - minDist, digits);
            if(currentSL == 0 || beLevel < currentSL) newSL = beLevel;
         }

         // Trailing
         double trailLevel = NormalizeDouble(ask + trailingDist, digits);
         if((currentSL == 0 || trailLevel < newSL) && (trailLevel - ask) >= minDist)
            newSL = trailLevel;

         if(currentSL == 0 || newSL < currentSL - pointSize)
            ModifyPosition(ticket, newSL, currentTP);
      }
   }
}

//+------------------------------------------------------------------+
//|  ModifyPosition                                                  |
//+------------------------------------------------------------------+
void ModifyPosition(ulong ticket, double newSL, double newTP)
{
   if(!trade.PositionModify(ticket, newSL, newTP))
      Print("Error al modificar #", ticket, ": ", trade.ResultRetcode());
}

//+------------------------------------------------------------------+
//|  CalculateLotSize — Lotaje dinámico por % riesgo                 |
//|  Para BTC: el valor por lote está en USD directamente            |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistanceUSD)
{
   double balance    = accountInfo.Balance();
   double riskAmount = balance * InpRiskPercent / 100.0;

   // Valor de 1 lote para este símbolo (cuántos USD vale 1 USD de movimiento × 1 lote)
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue == 0 || tickSize == 0 || slDistanceUSD == 0) return 0;

   // Pérdida en USD si el precio se mueve slDistanceUSD con 1 lote
   double lossPerLot = (slDistanceUSD / tickSize) * tickValue;
   if(lossPerLot == 0) return 0;

   double lots    = riskAmount / lossPerLot;
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, lotMin);
   lots = MathMin(lots, lotMax);

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//|  CalculateVWAP                                                   |
//+------------------------------------------------------------------+
double CalculateVWAP(int bars)
{
   double cumPV  = 0.0;
   double cumVol = 0.0;
   int available = (int)SeriesInfoInteger(_Symbol, _Period, SERIES_BARS_COUNT);
   if(bars > available) bars = available;

   for(int i = 1; i <= bars; i++)
   {
      double high  = iHigh  (_Symbol, _Period, i);
      double low   = iLow   (_Symbol, _Period, i);
      double close = iClose (_Symbol, _Period, i);
      double vol   = (double)iVolume(_Symbol, _Period, i);
      if(vol <= 0) continue;
      cumPV  += ((high + low + close) / 3.0) * vol;
      cumVol += vol;
   }
   return (cumVol == 0) ? 0.0 : cumPV / cumVol;
}

//+------------------------------------------------------------------+
//|  GetIndicatorValue                                               |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int shift)
{
   if(handle == INVALID_HANDLE) return EMPTY_VALUE;
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, shift, 1, buffer) <= 0) return EMPTY_VALUE;
   return buffer[0];
}

//+------------------------------------------------------------------+
//|  HasOpenPosition                                                 |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Magic() == InpMagicNumber && posInfo.Symbol() == _Symbol)
            return true;
   return false;
}

//+------------------------------------------------------------------+
//|  IsDayAllowed                                                    |
//+------------------------------------------------------------------+
bool IsDayAllowed()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   switch(dt.day_of_week)
   {
      case 0: return InpTradeSunday;
      case 1: return InpTradeMonday;
      case 2: return InpTradeTuesday;
      case 3: return InpTradeWednesday;
      case 4: return InpTradeThursday;
      case 5: return InpTradeFriday;
      case 6: return InpTradeSaturday;
      default: return false;
   }
}

//+------------------------------------------------------------------+
//|  IsSessionAllowed                                                |
//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int hour = dt.hour;
   bool london  = (hour >= InpLondonOpen  && hour < InpLondonClose);
   bool newYork = (hour >= InpNewYorkOpen && hour < InpNewYorkClose);
   return (london || newYork);
}

//+------------------------------------------------------------------+
//|  IsSpreadAllowed                                                 |
//+------------------------------------------------------------------+
bool IsSpreadAllowed()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > (long)InpMaxSpreadPoints)
   {
      static datetime lastLog = 0;
      if(TimeCurrent() - lastLog > 60)
      {
         Print("Spread elevado (", spread, " pts > ", InpMaxSpreadPoints, "). Entrada bloqueada.");
         lastLog = TimeCurrent();
      }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//|  IsConnected                                                     |
//+------------------------------------------------------------------+
bool IsConnected()
{
   return TerminalInfoInteger(TERMINAL_CONNECTED) == 1;
}

//+------------------------------------------------------------------+
//|  IsTradeAllowed                                                  |
//+------------------------------------------------------------------+
bool IsTradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return false;
   return true;
}


/*
╔══════════════════════════════════════════════════════════════════╗
║       GUÍA v1.1 — CORRECCIÓN "INVALID STOPS" EN BTCUSD         ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  CAUSA DEL ERROR                                                 ║
║  ─────────────────────────────────────────────────────────────  ║
║  BTCUSD tiene SYMBOL_POINT = 0.01                               ║
║  → "50 pips" = 50 × 0.01 = solo $0.50 de distancia             ║
║  → El broker exige mínimo ~$10-$100 de distancia en BTC         ║
║  → MT5 rechaza la orden: "invalid stops" (código 10016)         ║
║                                                                  ║
║  CAMBIOS REALIZADOS EN v1.1                                     ║
║  ─────────────────────────────────────────────────────────────  ║
║  1. Inputs ahora en USD (no pips): SL=500 = $500 de distancia  ║
║  2. Nueva función ValidateStops() ajusta automáticamente        ║
║     SL/TP si están por debajo del mínimo del broker             ║
║  3. GetMinStopDistance() lee SYMBOL_TRADE_STOPS_LEVEL           ║
║     y convierte a USD real                                       ║
║  4. Slippage aumentado a 500 puntos (BTC es muy volátil)        ║
║  5. Logs detallados muestran stop mínimo en OnInit              ║
║                                                                  ║
║  PARÁMETROS RECOMENDADOS PARA BTCUSD                            ║
║  ─────────────────────────────────────────────────────────────  ║
║  InpStopLossUSD   : 500   (SL a $500 del precio)               ║
║  InpTakeProfitUSD : 1000  (TP a $1000 del precio)              ║
║  InpTrailingUSD   : 300   (Trailing a $300)                     ║
║  InpBreakevenUSD  : 250   (Breakeven al ganar $250)             ║
║  InpMaxSpreadPoints: 200  (spread normal BTC ~50-150 pts)       ║
║  InpRiskPercent   : 1.0   (1% del balance)                      ║
║                                                                  ║
║  CÓMO VERIFICAR EL STOP MÍNIMO DE TU BROKER                    ║
║  ─────────────────────────────────────────────────────────────  ║
║  En el Diario de OnInit verás este mensaje:                     ║
║  "Stop mínimo: XXX USD (broker)"                                ║
║  → Asegúrate que InpStopLossUSD > ese valor                     ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
*/