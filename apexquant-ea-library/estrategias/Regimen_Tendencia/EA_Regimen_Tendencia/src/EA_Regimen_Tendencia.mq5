//+------------------------------------------------------------------+
//|                                        EA_Regimen_Tendencia.mq5   |
//|   Detector de regimen (ADX) + Tendencia (Donchian+EMA) +          |
//|   Reversion a la media (Bollinger+RSI)                            |
//|                                                                    |
//|   Arquitectura completa del proyecto:                             |
//|   ADX > InpADXTrendLevel  -> tendencia (Donchian + EMA200)        |
//|   ADX < InpADXRangeLevel  -> reversion a la media (Bollinger+RSI) |
//|   ADX entre ambos niveles -> sin operar (zona de whipsaw)         |
//+------------------------------------------------------------------+
#property copyright "Proyecto EA educativo"
#property version   "1.10"
#property description "Detector de regimen ADX + tendencia (Donchian+EMA200) + reversion a la media (Bollinger+RSI)"

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== Regimen de mercado (ADX) ==="
input int      InpADXPeriod         = 14;      // Periodo del ADX
input double   InpADXTrendLevel     = 25.0;    // ADX por encima de esto = tendencia
input double   InpADXRangeLevel     = 20.0;    // ADX por debajo de esto = rango
input int      InpConfirmBars       = 2;       // Velas de confirmacion antes de cambiar de regimen

input group "=== Modulo tendencia: Donchian + EMA200 ==="
input int      InpDonchianPeriod    = 20;      // Periodo del canal Donchian
input int      InpEMAPeriod         = 200;     // Periodo de la EMA de filtro

input group "=== Modulo rango: Bollinger + RSI ==="
input int      InpBBPeriod          = 20;      // Periodo de las Bandas de Bollinger
input double   InpBBDeviation       = 2.0;     // Desviacion estandar de las bandas
input int      InpRSIPeriod         = 14;      // Periodo del RSI
input double   InpRSIOversold       = 30.0;    // RSI por debajo de esto = sobreventa (compra)
input double   InpRSIOverbought     = 70.0;    // RSI por encima de esto = sobrecompra (venta)

input group "=== Gestion de riesgo ==="
input double   InpRiskPercent       = 1.0;     // % de la cuenta arriesgado por operacion
input double   InpATRMultiplierSL   = 2.0;     // Multiplicador ATR para el stop (modulo tendencia)
input double   InpATRMultiplierSLRange = 1.5;  // Multiplicador ATR para el stop (modulo rango)
input int      InpATRPeriod         = 14;      // Periodo del ATR
input double   InpDailyLossLimitPct = 3.0;     // % maximo de perdida diaria (se detiene si se alcanza)
input ulong    InpMagicNumber       = 20260731;// Numero magico de este EA

//+------------------------------------------------------------------+
//| Handles de indicadores                                            |
//+------------------------------------------------------------------+
int hADX = INVALID_HANDLE;
int hEMA = INVALID_HANDLE;
int hATR = INVALID_HANDLE;
int hBB  = INVALID_HANDLE;
int hRSI = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Estado del regimen de mercado                                     |
//+------------------------------------------------------------------+
enum ENUM_REGIME
  {
   REGIME_NONE,   // Zona intermedia, sin operar
   REGIME_TREND,  // ADX > nivel de tendencia
   REGIME_RANGE   // ADX < nivel de rango
  };

ENUM_REGIME g_regime        = REGIME_NONE;
ENUM_REGIME g_pendingRegime = REGIME_NONE;
int         g_confirmCount  = 0;

//+------------------------------------------------------------------+
//| Otras variables globales                                          |
//+------------------------------------------------------------------+
datetime g_lastBarTime    = 0;
datetime g_currentDay     = 0;
double   g_dayStartEquity = 0.0;
bool     g_dailyLimitHit  = false;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpADXRangeLevel >= InpADXTrendLevel)
     {
      Print("ERROR: InpADXRangeLevel debe ser menor que InpADXTrendLevel");
      return(INIT_PARAMETERS_INCORRECT);
     }

   hADX = iADX(_Symbol, PERIOD_CURRENT, InpADXPeriod);
   hEMA = iMA(_Symbol, PERIOD_CURRENT, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   hBB  = iBands(_Symbol, PERIOD_CURRENT, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   hRSI = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriod, PRICE_CLOSE);

   if(hADX == INVALID_HANDLE || hEMA == INVALID_HANDLE || hATR == INVALID_HANDLE
      || hBB == INVALID_HANDLE || hRSI == INVALID_HANDLE)
     {
      Print("ERROR: no se pudieron crear los indicadores (ADX/EMA/ATR/Bandas/RSI)");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagicNumber);

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_currentDay      = TimeCurrent() - (TimeCurrent() % 86400);

   PrintFormat("EA_Regimen_Tendencia iniciado | ADX(%d) tendencia>%.1f rango<%.1f | Donchian(%d) EMA(%d) | BB(%d,%.1f) RSI(%d) | riesgo %.1f%% | limite diario %.1f%%",
               InpADXPeriod, InpADXTrendLevel, InpADXRangeLevel,
               InpDonchianPeriod, InpEMAPeriod, InpBBPeriod, InpBBDeviation, InpRSIPeriod,
               InpRiskPercent, InpDailyLossLimitPct);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hADX != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hBB  != INVALID_HANDLE) IndicatorRelease(hBB);
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
  }

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- El control de perdida diaria corre en cada tick para reaccionar rapido
   CheckNewDay();
   if(g_dailyLimitHit)
      return;

//--- El resto de la logica solo se evalua al cierre de una vela nueva
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == g_lastBarTime)
      return;
   g_lastBarTime = barTime;

   UpdateRegime();

   if(g_regime == REGIME_TREND)
      ManageTrendLogic();
   else if(g_regime == REGIME_RANGE)
      ManageRangeLogic();
//--- REGIME_NONE: zona de whipsaw, no se opera intencionalmente

   ManageOpenPosition();
  }

//+------------------------------------------------------------------+
//| Detecta el regimen de mercado con confirmacion de N velas          |
//+------------------------------------------------------------------+
void UpdateRegime()
  {
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   if(CopyBuffer(hADX, 0, 1, 1, adxBuf) <= 0)
      return;

   double adxValue = adxBuf[0];
   ENUM_REGIME rawRegime;

   if(adxValue > InpADXTrendLevel)
      rawRegime = REGIME_TREND;
   else if(adxValue < InpADXRangeLevel)
      rawRegime = REGIME_RANGE;
   else
      rawRegime = REGIME_NONE;

   if(rawRegime == g_regime)
     {
      g_confirmCount = 0;
      return;
     }

   if(rawRegime == g_pendingRegime)
      g_confirmCount++;
   else
     {
      g_pendingRegime = rawRegime;
      g_confirmCount  = 1;
     }

   if(g_confirmCount >= InpConfirmBars)
     {
      PrintFormat("Cambio de regimen: %s -> %s (ADX=%.2f)",
                  EnumToString(g_regime), EnumToString(rawRegime), adxValue);
      g_regime       = rawRegime;
      g_confirmCount = 0;
     }
  }

//+------------------------------------------------------------------+
//| Logica de tendencia: ruptura de canal Donchian + filtro EMA200     |
//+------------------------------------------------------------------+
void ManageTrendLogic()
  {
   if(PositionSelect(_Symbol))
      return; // ya hay una posicion abierta en este simbolo

   double emaBuf[];
   ArraySetAsSeries(emaBuf, true);
   if(CopyBuffer(hEMA, 0, 1, 1, emaBuf) <= 0)
      return;
   double ema200 = emaBuf[0];

   int idxHigh = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpDonchianPeriod, 1);
   int idxLow  = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpDonchianPeriod, 1);
   if(idxHigh < 0 || idxLow < 0)
      return;

   double donchianHigh = iHigh(_Symbol, PERIOD_CURRENT, idxHigh);
   double donchianLow  = iLow(_Symbol, PERIOD_CURRENT, idxLow);
   double closePrev    = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool bullBreak = (closePrev > donchianHigh) && (closePrev > ema200);
   bool bearBreak = (closePrev < donchianLow)  && (closePrev < ema200);

   if(bullBreak)
      OpenTrade(ORDER_TYPE_BUY);
   else if(bearBreak)
      OpenTrade(ORDER_TYPE_SELL);
  }

//+------------------------------------------------------------------+
//| Abre una operacion con SL por ATR y tamano por % de riesgo         |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
  {
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf) <= 0)
      return;
   double atr = atrBuf[0];
   if(atr <= 0)
      return;

   double slDistance = atr * InpATRMultiplierSL;
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;

   double lot = CalculateLotSize(slDistance);
   if(lot <= 0)
      return;

   if(type == ORDER_TYPE_BUY)
      trade.Buy(lot, _Symbol, price, sl, 0, "Tendencia-Donchian");
   else
      trade.Sell(lot, _Symbol, price, sl, 0, "Tendencia-Donchian");
  }

//+------------------------------------------------------------------+
//| Logica de rango: Bandas de Bollinger + RSI                        |
//+------------------------------------------------------------------+
void ManageRangeLogic()
  {
   if(PositionSelect(_Symbol))
      return; // ya hay una posicion abierta en este simbolo

   double bbUpper[], bbLower[];
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   if(CopyBuffer(hBB, 1, 1, 1, bbUpper) <= 0) // 1 = banda superior
      return;
   if(CopyBuffer(hBB, 2, 1, 1, bbLower) <= 0) // 2 = banda inferior
      return;

   double rsiBuf[];
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(hRSI, 0, 1, 1, rsiBuf) <= 0)
      return;
   double rsi = rsiBuf[0];

   double closePrev = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool oversoldSignal   = (closePrev <= bbLower[0]) && (rsi < InpRSIOversold);
   bool overboughtSignal = (closePrev >= bbUpper[0]) && (rsi > InpRSIOverbought);

   if(oversoldSignal)
      OpenRangeTrade(ORDER_TYPE_BUY);
   else if(overboughtSignal)
      OpenRangeTrade(ORDER_TYPE_SELL);
  }

//+------------------------------------------------------------------+
//| Abre una operacion de reversion con SL por ATR (modulo rango)      |
//+------------------------------------------------------------------+
void OpenRangeTrade(ENUM_ORDER_TYPE type)
  {
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf) <= 0)
      return;
   double atr = atrBuf[0];
   if(atr <= 0)
      return;

   double slDistance = atr * InpATRMultiplierSLRange;
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (type == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;

   double lot = CalculateLotSize(slDistance);
   if(lot <= 0)
      return;

   if(type == ORDER_TYPE_BUY)
      trade.Buy(lot, _Symbol, price, sl, 0, "Reversion-BB");
   else
      trade.Sell(lot, _Symbol, price, sl, 0, "Reversion-BB");
  }

//+------------------------------------------------------------------+
//| Calcula el tamano de posicion segun % de riesgo y distancia de SL  |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
  {
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0)
      return 0;

   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return 0;

   double lot = riskMoney / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   return lot;
  }

//+------------------------------------------------------------------+
//| Gestiona la posicion abierta: reparte segun que modulo la abrio    |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(!PositionSelect(_Symbol))
      return;
   if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
      return;

   long   posType    = PositionGetInteger(POSITION_TYPE);
   string posComment = PositionGetString(POSITION_COMMENT);

   if(StringFind(posComment, "Tendencia") >= 0)
      ManageTrendExit(posType);
   else if(StringFind(posComment, "Reversion") >= 0)
      ManageRangeExit(posType);
  }

//+------------------------------------------------------------------+
//| Salida del modulo tendencia: ruptura del canal opuesto             |
//+------------------------------------------------------------------+
void ManageTrendExit(long posType)
  {
   int idxHigh = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpDonchianPeriod, 1);
   int idxLow  = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpDonchianPeriod, 1);
   if(idxHigh < 0 || idxLow < 0)
      return;

   double donchianHigh = iHigh(_Symbol, PERIOD_CURRENT, idxHigh);
   double donchianLow  = iLow(_Symbol, PERIOD_CURRENT, idxLow);
   double closePrev    = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(posType == POSITION_TYPE_BUY && closePrev < donchianLow)
      trade.PositionClose(_Symbol);
   else if(posType == POSITION_TYPE_SELL && closePrev > donchianHigh)
      trade.PositionClose(_Symbol);
  }

//+------------------------------------------------------------------+
//| Salida del modulo rango: retorno a la banda media, o proteccion    |
//| si el regimen ya cambio a tendencia (no pelear contra el mercado)  |
//+------------------------------------------------------------------+
void ManageRangeExit(long posType)
  {
   if(g_regime != REGIME_RANGE)
     {
      trade.PositionClose(_Symbol); // el regimen ya no es de rango, salimos sin esperar mas
      return;
     }

   double bbMiddle[];
   ArraySetAsSeries(bbMiddle, true);
   if(CopyBuffer(hBB, 0, 1, 1, bbMiddle) <= 0) // 0 = banda media (SMA)
      return;

   double closePrev = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(posType == POSITION_TYPE_BUY && closePrev >= bbMiddle[0])
      trade.PositionClose(_Symbol);
   else if(posType == POSITION_TYPE_SELL && closePrev <= bbMiddle[0])
      trade.PositionClose(_Symbol);
  }

//+------------------------------------------------------------------+
//| Controla la perdida diaria maxima                                  |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   datetime today = TimeCurrent() - (TimeCurrent() % 86400);

   if(today != g_currentDay)
     {
      g_currentDay     = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyLimitHit  = false;
      return;
     }

   if(g_dayStartEquity <= 0)
      return;

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;

   if(lossPct >= InpDailyLossLimitPct && !g_dailyLimitHit)
     {
      g_dailyLimitHit = true;
      PrintFormat("Limite de perdida diaria alcanzado (%.2f%%). No se abriran mas operaciones hoy.", lossPct);
      if(PositionSelect(_Symbol) && PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         trade.PositionClose(_Symbol);
     }
  }
//+------------------------------------------------------------------+