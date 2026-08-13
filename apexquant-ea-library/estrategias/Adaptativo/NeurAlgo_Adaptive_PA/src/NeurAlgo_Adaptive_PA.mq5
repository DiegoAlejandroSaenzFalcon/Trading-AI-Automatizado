//+------------------------------------------------------------------+
//|                                       NeurAlgo_Adaptive_PA.mq5   |
//|                                  Grado Institucional Quant-SRE   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Grado Institucional Quant-SRE"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

// Inclusion de la libreria estandar de ejecucion
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| ENUMS DEL SISTEMA                                                |
//+------------------------------------------------------------------+
enum ENUM_MARKET_REGIME {
   REGIME_TREND_EXPANSIVE,  // Tendencia con volatilidad sana
   REGIME_TREND_EXHAUSTED,  // Tendencia sobreextendida (Riesgo de Reversion)
   REGIME_RANGE_COMPRESSED, // Consolidacion estrecha (Pre-Ruptura)
   REGIME_RANGE_NOISY       // Rango con alto ruido (Veto Operativo)
};

enum ENUM_MARKET_BIAS {
   BIAS_BULLISH,
   BIAS_BEARISH,
   BIAS_NEUTRAL
};

//+------------------------------------------------------------------+
//| INPUTS PARAMETRICOS (UNICAMENTE DE CONTROL Y RIESGO OPERATIVO)   |
//+------------------------------------------------------------------+
input group "--- GESTION DE RIESGO DE ELITE ---"
input double   InpRiskPercentage    = 1.0;       // Porcentaje de Riesgo por Operacion (%)
input double   InpMaxDailyDrawdown  = 4.0;       // Circuito Breaker: Drawdown Maximo Diario (%)
input ulong    InpMagicNumber       = 88261025;  // Identificador Unico de Operaciones (Magic)

input group "--- CALIBRACION DE ENTORNOS INTEGRADOS ---"
input int      InpBasePeriod        = 20;        // Periodo base para calculos estadisticos (ER/ATR/StdDev)
input double   InpMaxSpreadFactor   = 2.2;       // Multiplicador maximo sobre el Spread Medio para ejecucion
input bool     InpLogDiagnostics    = true;      // Imprimir diagnosticos cientificos en el registro

//+------------------------------------------------------------------+
//| VARIABLE GLOBALES Y CONTENEDORES DE MEMORIA                      |
//+------------------------------------------------------------------+
CTrade      TradeEngine;
string      BaseSymbol;

// Estructuras de control de sincronizacion temporal (Event-Driven)
datetime    dtLastBarD1, dtLastBarH4, dtLastBarH1, dtLastBarM15, dtLastBarM5;

// Handles de Indicadores Nativos (Asignados unicamente en OnInit)
int         hFractalsD1, hFractalsH4, hFractalsH1, hFractalsM5;
int         hATR_M15, hStdDev_M15;

// Variables dinamicas auto-calibradas
ENUM_MARKET_REGIME   CurrentRegime;
ENUM_MARKET_BIAS     CurrentBias;
double               DynamicSpreadMA;
double               LastDailyEquityHigh;

//+------------------------------------------------------------------+
//| ESTRUCTURAS DE DATOS PARA PUNTOS DE INTERES Y ESTRUCTURA         |
//+------------------------------------------------------------------+
struct MarketStructurePoint {
   double price;
   datetime time;
   bool isHigh;
};

MarketStructurePoint LastPOI_H1;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION FUNCTION                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   BaseSymbol = _Symbol;
   TradeEngine.SetExpertMagicNumber(InpMagicNumber);
   TradeEngine.SetTypeFillingBySymbol(BaseSymbol);
   
   // Sincronizacion inicial de variables de tiempo
   dtLastBarD1  = 0;
   dtLastBarH4  = 0;
   dtLastBarH1  = 0;
   dtLastBarM15 = 0;
   dtLastBarM5  = 0;
   
   DynamicSpreadMA     = 0.0;
   LastDailyEquityHigh = AccountInfoDouble(ACCOUNT_EQUITY);
   CurrentRegime       = REGIME_RANGE_NOISY;
   CurrentBias         = BIAS_NEUTRAL;
   
   LastPOI_H1.price    = 0.0;
   LastPOI_H1.time     = 0;
   LastPOI_H1.isHigh   = false;

   // Inicializacion de handles nativos para analisis estructural asincrono
   hFractalsD1 = iFractals(BaseSymbol, PERIOD_D1);
   hFractalsH4 = iFractals(BaseSymbol, PERIOD_H4);
   hFractalsH1 = iFractals(BaseSymbol, PERIOD_H1);
   hFractalsM5 = iFractals(BaseSymbol, PERIOD_M5);
   
   hATR_M15    = iATR(BaseSymbol, PERIOD_M15, InpBasePeriod);
   hStdDev_M15 = iStdDev(BaseSymbol, PERIOD_M15, InpBasePeriod, 0, MODE_SMA, PRICE_CLOSE);
   
   if(hFractalsD1 == INVALID_HANDLE || hFractalsH4 == INVALID_HANDLE || 
      hFractalsH1 == INVALID_HANDLE || hFractalsM5 == INVALID_HANDLE || 
      hATR_M15 == INVALID_HANDLE    || hStdDev_M15 == INVALID_HANDLE)
   {
      Print("[ERROR CRITICO] Fallo en la inicializacion de handles matematicos del terminal.");
      return(INIT_FAILED);
   }

   Print("[SISTEMA INICIALIZADO] Motor de auto-calibracion cientifica listo para XAUUSD en Exness.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION FUNCTION                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hFractalsD1);
   IndicatorRelease(hFractalsH4);
   IndicatorRelease(hFractalsH1);
   IndicatorRelease(hFractalsM5);
   IndicatorRelease(hATR_M15);
   IndicatorRelease(hStdDev_M15);
   Print("[SISTEMA APAGADO] Handles liberados de manera segura. Codigo de salida: ", reason);
}

//+------------------------------------------------------------------+
//| EXPERT TICK FUNCTION                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. CONTROL DE SEGURIDAD OPERATIVA (CIRCUITO BREAKER)
   if(EvaluateCircuitBreakers()) return;
   
   // 2. ACTUALIZACION DEL FILTRO DE SPREAD DINAMICO
   double currentSpread = SymbolInfoInteger(BaseSymbol, SYMBOL_SPREAD) * SymbolInfoDouble(BaseSymbol, SYMBOL_POINT);
   if(DynamicSpreadMA == 0.0) DynamicSpreadMA = currentSpread;
   else DynamicSpreadMA = (DynamicSpreadMA * 99.0 + currentSpread) / 100.0; // MA Exponencial de ventana ultra-rapida

   // 3. MOTORES EVENT-DRIVEN POR VELOCIDAD DE CAMBIO DE VELAS
   bool isNewM15 = CheckNewBar(PERIOD_M15, dtLastBarM15);
   bool isNewH4  = CheckNewBar(PERIOD_H4, dtLastBarH4);
   bool isNewH1  = CheckNewBar(PERIOD_H1, dtLastBarH1);
   bool isNewM5  = CheckNewBar(PERIOD_M5, dtLastBarM5);
   
   // Recalculo asincrono de regimenes de volatilidad y clasificacion de mercado (Evita estrangulamiento de CPU)
   if(isNewM15) {
      CurrentRegime = RecalculateMarketRegime();
   }
   
   if(isNewH4) {
      CurrentBias = RecalculateMarketBias();
   }
   
   if(isNewH1) {
      UpdatePointOfInterest();
   }
   
   // 4. MOTOR DE GESTION DE TRAILING DIRECTO (SE CORRE EN CADA TICK, O(1) COMPLEXITY)
   ManageOpenPositions();

   // Veto operativo si el regimen es puro ruido estadistico o el spread se encuentra en anomalia transitoria (Exness News Edge)
   if(CurrentRegime == REGIME_RANGE_NOISY || currentSpread > (DynamicSpreadMA * InpMaxSpreadFactor)) {
      return;
   }

   // 5. MOTOR DE DISPARO (GATILLO EN M5)
   if(isNewM5 && CurrentBias != BIAS_NEUTRAL) {
      EvaluateMarketTrigger();
   }
}

//+------------------------------------------------------------------+
//| EVALUACION DE CIRCUIT BREAKERS INSTITUCIONALES                   |
//+------------------------------------------------------------------+
bool EvaluateCircuitBreakers()
{
   MqlDateTime currentDateTime;
   TimeToStruct(TimeCurrent(), currentDateTime);
   
   // Reinicio del pico de equidad al inicio del dia comercial
   if(currentDateTime.hour == 0 && currentDateTime.min == 0) {
      LastDailyEquityHigh = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity > LastDailyEquityHigh) {
      LastDailyEquityHigh = currentEquity;
   }
   
   double dailyDrawdown = ((LastDailyEquityHigh - currentEquity) / LastDailyEquityHigh) * 100.0;
   if(dailyDrawdown >= InpMaxDailyDrawdown) {
      if(InpLogDiagnostics && PositionsTotal() > 0) {
         Print("[CIRCUITO BREAKER INTERVENIDO] Umbral de Drawdown Diario alcanzado. Operacion Congelada.");
      }
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ARQUITECTURA DE DETECCION DE BARRA POR EVENTO                    |
//+------------------------------------------------------------------+
bool CheckNewBar(ENUM_TIMEFRAMES tf, datetime &lastBarTime)
{
   datetime currentBarTime = iTime(BaseSymbol, tf, 0);
   if(currentBarTime != lastBarTime) {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| MOTOR DE REGIMEN MATEMATICO (METRICAS RAW SIN SUAVIZADO)         |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME RecalculateMarketRegime()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(BaseSymbol, PERIOD_M15, 0, InpBasePeriod + 1, rates) <= 0) return REGIME_RANGE_NOISY;
   
   // 1. Efficiency Ratio de Kaufman (Medida pura de direccionalidad frente a ruido)
   double noisePriceSum = 0.0;
   for(int i = 0; i < InpBasePeriod; i++) {
      noisePriceSum += MathAbs(rates[i].close - rates[i+1].close);
   }
   double totalSignal = MathAbs(rates[0].close - rates[InpBasePeriod].close);
   double kaufmanER = (noisePriceSum > 0) ? (totalSignal / noisePriceSum) : 0;
   
   // 2. Analisis de Desviacion Estandar Relativa al ATR (Rango de Compresion Index)
   double atrValues[], stdDevValues[];
   if(CopyBuffer(hATR_M15, 0, 0, 1, atrValues) <= 0 || CopyBuffer(hStdDev_M15, 0, 0, 1, stdDevValues) <= 0) {
      return REGIME_RANGE_NOISY;
   }
   
   double atrValue = atrValues[0];
   double stdDevValue = stdDevValues[0];
   double compressionIndex = (atrValue > 0) ? (stdDevValue / atrValue) : 0;

   // Clasificacion cientifica matricial de estados de mercado de transicion
   if(kaufmanER > 0.6) {
      if(compressionIndex > 1.2) return REGIME_TREND_EXHAUSTED; // Agotamiento por expansion parabolica
      return REGIME_TREND_EXPANSIVE;
   } else {
      if(compressionIndex < 0.4) return REGIME_RANGE_COMPRESSED; // Compresion extrema para ruptura (Volatilidad oculta)
      return REGIME_RANGE_NOISY; // Mercado lateral ineficiente sin estructura limpia
   }
}

//+------------------------------------------------------------------+
//| MOTOR DE CLASIFICACION MULTI-TEMPORAL DEL SESGO MACRO             |
//+------------------------------------------------------------------+
ENUM_MARKET_BIAS RecalculateMarketBias()
{
   // Mapeo estructural de Fractales en H4
   double upperFractalBuffer[], lowerFractalBuffer[];
   ArraySetAsSeries(upperFractalBuffer, true);
   ArraySetAsSeries(lowerFractalBuffer, true);
   
   if(CopyBuffer(hFractalsH4, 0, 0, 100, upperFractalBuffer) < 100 || 
      CopyBuffer(hFractalsH4, 1, 0, 100, lowerFractalBuffer) < 100) {
      return BIAS_NEUTRAL;
   }
   
   double lastHighs[2] = {0.0, 0.0};
   double lastLows[2]  = {0.0, 0.0};
   int highsCount = 0, lowsCount = 0;
   
   for(int i = 0; i < 100 && (highsCount < 2 || lowsCount < 2); i++) {
      if(upperFractalBuffer[i] != EMPTY_VALUE && upperFractalBuffer[i] > 0 && highsCount < 2) {
         lastHighs[highsCount] = upperFractalBuffer[i];
         highsCount++;
      }
      if(lowerFractalBuffer[i] != EMPTY_VALUE && lowerFractalBuffer[i] > 0 && lowsCount < 2) {
         lastLows[lowsCount] = lowerFractalBuffer[i];
         lowsCount++;
      }
   }
   
   if(highsCount < 2 || lowsCount < 2) return BIAS_NEUTRAL;
   
   // Estructura de Mercado Clasica de Price Action (Secuenciacion Estricta de Altos/Bajos)
   bool structuralBullish = (lastHighs[0] > lastHighs[1]) && (lastLows[0] > lastLows[1]);
   bool structuralBearish = (lastHighs[0] < lastHighs[1]) && (lastLows[0] < lastLows[1]);
   
   // Filtro de confirmacion de sesgo Macro en Temporalidad D1 para evitar contratendencias mortales
   MqlRates d1Rates[];
   if(CopyRates(BaseSymbol, PERIOD_D1, 1, 1, d1Rates) > 0) {
      if(structuralBullish && d1Rates[0].close > d1Rates[0].open) return BIAS_BULLISH;
      if(structuralBearish && d1Rates[0].close < d1Rates[0].open) return BIAS_BEARISH;
   }
   
   return BIAS_NEUTRAL;
}

//+------------------------------------------------------------------+
//| LOCALIZADOR DINAMICO DE PUNTOS DE INTERES (POI DE H1)            |
//+------------------------------------------------------------------+
void UpdatePointOfInterest()
{
   double upperFractalBuffer[], lowerFractalBuffer[];
   datetime timeBuffer[];
   ArraySetAsSeries(upperFractalBuffer, true);
   ArraySetAsSeries(lowerFractalBuffer, true);
   ArraySetAsSeries(timeBuffer, true);
   
   if(CopyBuffer(hFractalsH1, 0, 0, 50, upperFractalBuffer) <= 0 || 
      CopyBuffer(hFractalsH1, 1, 0, 50, lowerFractalBuffer) <= 0 ||
      CopyTime(BaseSymbol, PERIOD_H1, 0, 50, timeBuffer) <= 0) {
      return;
   }
   
   // Encontrar el fractal mas fresco del mercado para mapear la inyeccion de liquidez institucional previa
   for(int i = 0; i < 50; i++) {
      if(upperFractalBuffer[i] != EMPTY_VALUE && upperFractalBuffer[i] > 0) {
         LastPOI_H1.price = upperFractalBuffer[i];
         LastPOI_H1.time = timeBuffer[i];
         LastPOI_H1.isHigh = true;
         return;
      }
      if(lowerFractalBuffer[i] != EMPTY_VALUE && lowerFractalBuffer[i] > 0) {
         LastPOI_H1.price = lowerFractalBuffer[i];
         LastPOI_H1.time = timeBuffer[i];
         LastPOI_H1.isHigh = false;
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| EVALUACION MATEMATICA DEL GATILLO COMPLETO (DISPARO EN M5 - BOS)  |
//+------------------------------------------------------------------+
void EvaluateMarketTrigger()
{
   // Chequeo de existencia de operaciones vivas bajo nuestro control para mitigar exposicion
   if(CountOpenPositions() > 0) return;
   if(LastPOI_H1.price == 0.0) return;
   
   double currentBid = SymbolInfoDouble(BaseSymbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(BaseSymbol, SYMBOL_ASK);
   
   // Medidor de Volatilidad Estructural M5 para calculos elasticos de proximidad
   double atrValuesM15[];
   if(CopyBuffer(hATR_M15, 0, 0, 1, atrValuesM15) <= 0) return;
   double structuralBuffer = atrValuesM15[0] * 1.5; // Umbral adaptativo dinamico
   
   MqlRates m5Rates[];
   ArraySetAsSeries(m5Rates, true);
   if(CopyRates(BaseSymbol, PERIOD_M5, 0, 4, m5Rates) < 4) return;
   
   // LÓGICA DE COMPRA (BULLISH TRADING SETUP)
   if(CurrentBias == BIAS_BULLISH && !LastPOI_H1.isHigh) {
      // Proximidad al POI Estructural de H1 (Inyeccion Liquida de Descuento)
      if(MathAbs(currentBid - LastPOI_H1.price) <= structuralBuffer) {
         // Ruptura micro de estructura en M5 (BOS Confirmado por Cierre)
         double microResistance = MathMax(m5Rates[1].high, m5Rates[2].high);
         if(m5Rates[0].close > microResistance) {
            ExecuteOrder(ORDER_TYPE_BUY, currentAsk, m5Rates[0].low);
         }
      }
   }
   
   // LÓGICA DE VENTA (BEARISH TRADING SETUP)
   if(CurrentBias == BIAS_BEARISH && LastPOI_H1.isHigh) {
      // Proximidad al POI Estructural de H1 (Inyeccion Liquida de Prima)
      if(MathAbs(LastPOI_H1.price - currentBid) <= structuralBuffer) {
         // Ruptura micro de estructura en M5 (BOS Confirmado por Cierre)
         double microSupport = MathMin(m5Rates[1].low, m5Rates[2].low);
         if(m5Rates[0].close < microSupport) {
            ExecuteOrder(ORDER_TYPE_SELL, currentBid, m5Rates[0].high);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| MOTOR DE EJECUCION CON CALCULO INTEGRADO DE MICROESTRUCTURA      |
//+------------------------------------------------------------------+
void ExecuteOrder(ENUM_ORDER_TYPE orderType, double entryPrice, double structuralStopLevel)
{
   double balance        = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickValue      = SymbolInfoDouble(BaseSymbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize       = SymbolInfoDouble(BaseSymbol, SYMBOL_TRADE_TICK_SIZE);
   double point          = SymbolInfoDouble(BaseSymbol, SYMBOL_POINT);
   double volumeStep     = SymbolInfoDouble(BaseSymbol, SYMBOL_VOLUME_STEP);
   double volumeMin      = SymbolInfoDouble(BaseSymbol, SYMBOL_VOLUME_MIN);
   double volumeMax      = SymbolInfoDouble(BaseSymbol, SYMBOL_VOLUME_MAX);
   
   // Seguridad de Stop Loss Estructural frente a volatilidad de ticks
   double atrValuesM15[];
   if(CopyBuffer(hATR_M15, 0, 0, 1, atrValuesM15) <= 0) return;
   double safetyColch = atrValuesM15[0] * 0.15;
   
   double targetSL = 0.0;
   double distancePoints = 0.0;
   
   if(orderType == ORDER_TYPE_BUY) {
      targetSL = structuralStopLevel - safetyColch;
      distancePoints = (entryPrice - targetSL) / point;
   } else {
      targetSL = structuralStopLevel + safetyColch;
      distancePoints = (targetSL - entryPrice) / point;
   }
   
   if(distancePoints <= 0) return;
   
   // Adaptacion Matematica Agnóstica a Tipo de Cuenta Exness (Cent vs Raw vs Standard)
   double cashRisk = balance * (InpRiskPercentage / 100.0);
   double pointsToTicks = distancePoints * (point / tickSize);
   double rawLotSize = cashRisk / (pointsToTicks * tickValue);
   
   // Normalizacion Estricta del Lotaje segun especificaciones dinámicas del pool de Exness
   double normalizedLot = MathRound(rawLotSize / volumeStep) * volumeStep;
   if(normalizedLot < volumeMin) normalizedLot = volumeMin;
   if(normalizedLot > volumeMax) normalizedLot = volumeMax;
   
   // Validacion del Stop Level del Servidor de Exness en Tiempo de Ejecucion
   double minStopLevelPoints = (double)SymbolInfoInteger(BaseSymbol, SYMBOL_TRADE_STOPLEVEL) * point;
   double actualDistancePrice = MathAbs(entryPrice - targetSL);
   if(actualDistancePrice < minStopLevelPoints) {
      targetSL = (orderType == ORDER_TYPE_BUY) ? (entryPrice - minStopLevelPoints) : (entryPrice + minStopLevelPoints);
   }
   
   // Ratio Riesgo/Beneficio Calibrado Asincronamente por Regimen Actual de Estructura
   double targetTP = 0.0;
   double riskRewardRatio = (CurrentRegime == REGIME_TREND_EXPANSIVE) ? 2.5 : 1.5;
   
   if(orderType == ORDER_TYPE_BUY) {
      targetTP = entryPrice + (MathAbs(entryPrice - targetSL) * riskRewardRatio);
   } else {
      targetTP = entryPrice - (MathAbs(entryPrice - targetSL) * riskRewardRatio);
   }
   
   // Verificacion de Cobertura de Margen Antes del Envio de la Orden Electrónica
   double requiredMargin = 0.0;
   if(!OrderCalcMargin(orderType, BaseSymbol, normalizedLot, entryPrice, requiredMargin)) return;
   if(requiredMargin > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      if(InpLogDiagnostics) Print("[ALERTA] Orden abortada: Margen insuficiente para ejecucion liquida.");
      return;
   }
   
   // Envio institucional de la orden con control de reintentos asincronos
   int maxRetries = 3;
   for(int i = 0; i < maxRetries; i++) {
      if(orderType == ORDER_TYPE_BUY) {
         if(TradeEngine.Buy(normalizedLot, BaseSymbol, entryPrice, targetSL, targetTP, "NeurAlgo Institutional Engine")) {
            if(TradeEngine.ResultRetcode() == TRADE_RETCODE_DONE) break;
         }
      } else {
         if(TradeEngine.Sell(normalizedLot, BaseSymbol, entryPrice, targetSL, targetTP, "NeurAlgo Institutional Engine")) {
            if(TradeEngine.ResultRetcode() == TRADE_RETCODE_DONE) break;
         }
      }
      Sleep(100); // Latencia controlada de alivio para el gateway de Exness en picos de alta carga
   }
}

//+------------------------------------------------------------------+
//| MANAGEMENT ACTIVO EN CADA TICK DE POSICIONES EN VIVO             |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   double point = SymbolInfoDouble(BaseSymbol, SYMBOL_POINT);
   double atrValuesM15[];
   if(CopyBuffer(hATR_M15, 0, 0, 1, atrValuesM15) <= 0) return;
   double dynamicAtrPoints = atrValuesM15[0] / point;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == BaseSymbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         ulong ticket       = PositionGetInteger(POSITION_TICKET);
         double currentSL   = PositionGetDouble(POSITION_SL);
         double currentTP   = PositionGetDouble(POSITION_TP);
         double openPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice= (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(BaseSymbol, SYMBOL_BID) : SymbolInfoDouble(BaseSymbol, SYMBOL_ASK);
         
         double distanceFromOpenPoints = MathAbs(currentPrice - openPrice) / point;
         
         // 1. GESTION DE ARQUITECTURA BREAK-EVEN (Mitigacion de Riesgo de Cola al alcanzar 1:1)
         double triggerDistancePoints = (MathAbs(openPrice - currentSL) / point); 
         
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            if(currentPrice > openPrice && distanceFromOpenPoints >= triggerDistancePoints && currentSL < openPrice) {
               double secureStop = openPrice + (2.0 * point); // Colchón de comisiones/spread
               TradeEngine.PositionModify(ticket, secureStop, currentTP);
               continue;
            }
            
            // 2. TRAILING STOP ADAPTATIVO POR VELOCIDAD DE REGIMEN ESTRUCTURAL (Mover tras fractales confirmados M5)
            double m5FractalLows[];
            if(CopyBuffer(hFractalsM5, 1, 1, 10, m5FractalLows) > 0) {
               for(int j = 0; j < 10; j++) {
                  if(m5FractalLows[j] != EMPTY_VALUE && m5FractalLows[j] > currentSL && m5FractalLows[j] < currentPrice) {
                     TradeEngine.PositionModify(ticket, m5FractalLows[j], currentTP);
                     break;
                  }
               }
            }
         } 
         else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
            if(currentPrice < openPrice && distanceFromOpenPoints >= triggerDistancePoints && (currentSL > openPrice || currentSL == 0.0)) {
               double secureStop = openPrice - (2.0 * point);
               TradeEngine.PositionModify(ticket, secureStop, currentTP);
               continue;
            }
            
            // Trailing Stop para posiciones cortas basado en fractales altos M5
            double m5FractalHighs[];
            if(CopyBuffer(hFractalsM5, 0, 1, 10, m5FractalHighs) > 0) {
               for(int j = 0; j < 10; j++) {
                  if(m5FractalHighs[j] != EMPTY_VALUE && m5FractalHighs[j] < currentSL && m5FractalHighs[j] > currentPrice) {
                     TradeEngine.PositionModify(ticket, m5FractalHighs[j], currentTP);
                     break;
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| AUXILIAR: CONTADOR COMPACTO DE POSICIONES DE NUESTRO CLUSTER     |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == BaseSymbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         count++;
      }
   }
   return count;
}