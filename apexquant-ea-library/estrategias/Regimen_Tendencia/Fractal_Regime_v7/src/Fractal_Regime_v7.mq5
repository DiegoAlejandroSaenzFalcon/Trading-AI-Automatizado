//+------------------------------------------------------------------+
//|                          Fractal_Regime_v7.mq5                   |
//|          Trend-Following & Regime-Change Detection System        |
//|        Refactored from Pure_Fractal_Pure_v6 (pseudo-random)      |
//|                                                                  |
//|  ENTRY ARCHITECTURE: Multi-Layer Regime Classification (MLRCS)  |
//|    Layer 1 | ADX Gate        : Regime energy threshold           |
//|    Layer 2 | EMA Alignment   : Hierarchical directional vector   |
//|    Layer 3 | DMI Conviction  : Directional spread confirmation   |
//|    Layer 4 | RSI Quality     : Momentum health / exhaustion      |
//+------------------------------------------------------------------+
#property copyright "Asistente de Programación"
#property version   "7.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//====================================================================
//  PARÁMETROS DE ENTRADA
//====================================================================

//--- [I] GESTIÓN DE CAPITAL
input double   InpLotSize         = 0.01;  // [I]  Tamaño del Lote
input double   InpTPMultiplier    = 0.8;   // [I]  Multiplicador TP (unidades ATR)
input double   InpSLMultiplier    = 3.0;   // [I]  Multiplicador SL de Emergencia (unidades ATR)
input int      InpTrailingPoints  = 10;    // [I]  Puntos de Trailing Stop
input int      InpMinPointsProfit = 2;     // [I]  Puntos mínimos de beneficio para Break-Even

//--- [II] ATR - VOLATILIDAD BASE
input int      InpATRPeriod       = 14;    // [II] Periodo ATR

//--- [III] FILTRO DE ESTRUCTURA TENDENCIAL (EMAs)
input int      InpEMAFastPeriod   = 21;    // [III] EMA Rápida  | Táctica       (periodo)
input int      InpEMASlowPeriod   = 55;    // [III] EMA Lenta   | Estratégica   (periodo)
input int      InpEMAMacroPeriod  = 200;   // [III] EMA Macro   | Ancla Estructural (periodo)

//--- [IV] RÉGIMEN DE MERCADO (ADX / DMI)
input int      InpADXPeriod       = 14;    // [IV] Periodo ADX
input double   InpADXTrendMin     = 22.0;  // [IV] ADX mínimo para régimen tendencial válido
input double   InpADXExhaustMax   = 48.0;  // [IV] ADX máximo: por encima con giro = agotamiento parabólico
input double   InpDISpreadMin     = 5.0;   // [IV] Diferencial mínimo |DI+ - DI-| para convicción

//--- [V] CALIDAD DE MOMENTUM Y AGOTAMIENTO (RSI)
input int      InpRSIPeriod       = 14;    // [V]  Periodo RSI
input double   InpRSIBullMin      = 45.0;  // [V]  RSI piso COMPRAS  | momentum alcista mínimo
input double   InpRSIBullMax      = 72.0;  // [V]  RSI techo COMPRAS | evita entrar sobrecomprado
input double   InpRSIBearMin      = 28.0;  // [V]  RSI piso VENTAS   | evita entrar sobrevendido
input double   InpRSIBearMax      = 55.0;  // [V]  RSI techo VENTAS  | momentum bajista mínimo

//====================================================================
//  VARIABLES GLOBALES
//====================================================================

int      handleATR;
int      handleEMAFast;
int      handleEMASlow;
int      handleEMAMacro;
int      handleADX;
int      handleRSI;

double   bufferATR[];
double   bufferEMAFast[];
double   bufferEMASlow[];
double   bufferEMAMacro[];
double   bufferADX[];      // ADX: buffer index 0
double   bufferDIPlus[];   // +DI: buffer index 1
double   bufferDIMinus[];  // -DI: buffer index 2
double   bufferRSI[];

ulong    magicNumber   = 999;
datetime g_lastBarTime = 0;   // Control de nueva barra para entradas

//+------------------------------------------------------------------+
//| OnInit: Inicialización y validación de todos los handles         |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(magicNumber);

   //--- [II] ATR
   handleATR = iATR(_Symbol, _Period, InpATRPeriod);
   if(handleATR == INVALID_HANDLE)
   {
      Print("[ERROR] Fractal_Regime_v7: Fallo al crear handle ATR.");
      return(INIT_FAILED);
   }

   //--- [III] Tres EMAs (Estructura Tendencial)
   handleEMAFast  = iMA(_Symbol, _Period, InpEMAFastPeriod,  0, MODE_EMA, PRICE_CLOSE);
   handleEMASlow  = iMA(_Symbol, _Period, InpEMASlowPeriod,  0, MODE_EMA, PRICE_CLOSE);
   handleEMAMacro = iMA(_Symbol, _Period, InpEMAMacroPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(handleEMAFast  == INVALID_HANDLE) { Print("[ERROR] Fractal_Regime_v7: Fallo handle EMA Rápida.");  return(INIT_FAILED); }
   if(handleEMASlow  == INVALID_HANDLE) { Print("[ERROR] Fractal_Regime_v7: Fallo handle EMA Lenta.");   return(INIT_FAILED); }
   if(handleEMAMacro == INVALID_HANDLE) { Print("[ERROR] Fractal_Regime_v7: Fallo handle EMA Macro.");   return(INIT_FAILED); }

   //--- [IV] ADX (incluye DI+ y DI- en buffers 1 y 2)
   handleADX = iADX(_Symbol, _Period, InpADXPeriod);
   if(handleADX == INVALID_HANDLE)
   {
      Print("[ERROR] Fractal_Regime_v7: Fallo al crear handle ADX.");
      return(INIT_FAILED);
   }

   //--- [V] RSI
   handleRSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   if(handleRSI == INVALID_HANDLE)
   {
      Print("[ERROR] Fractal_Regime_v7: Fallo al crear handle RSI.");
      return(INIT_FAILED);
   }

   //--- Configurar todos los buffers como series temporales
   //    Índice 0 = barra actual (en formación)
   //    Índice 1 = última barra cerrada (confirmada)
   //    Índice 2 = penúltima barra cerrada
   ArraySetAsSeries(bufferATR,      true);
   ArraySetAsSeries(bufferEMAFast,  true);
   ArraySetAsSeries(bufferEMASlow,  true);
   ArraySetAsSeries(bufferEMAMacro, true);
   ArraySetAsSeries(bufferADX,      true);
   ArraySetAsSeries(bufferDIPlus,   true);
   ArraySetAsSeries(bufferDIMinus,  true);
   ArraySetAsSeries(bufferRSI,      true);

   Print("[OK] Fractal_Regime_v7 inicializado. Símbolo: ", _Symbol,
         " | Timeframe: ", EnumToString(_Period));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit: Liberación de recursos con validación previa           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleATR      != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleEMAFast  != INVALID_HANDLE) IndicatorRelease(handleEMAFast);
   if(handleEMASlow  != INVALID_HANDLE) IndicatorRelease(handleEMASlow);
   if(handleEMAMacro != INVALID_HANDLE) IndicatorRelease(handleEMAMacro);
   if(handleADX      != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleRSI      != INVALID_HANDLE) IndicatorRelease(handleRSI);
}

//+------------------------------------------------------------------+
//| OnTick: Ciclo principal de ejecución                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Cargar 3 valores por buffer (barra_0, barra_1, barra_2)
   //    necesarios para cálculos de pendiente y confirmación de señal
   if(CopyBuffer(handleATR,      0, 0, 3, bufferATR)      < 3) return;
   if(CopyBuffer(handleEMAFast,  0, 0, 3, bufferEMAFast)  < 3) return;
   if(CopyBuffer(handleEMASlow,  0, 0, 3, bufferEMASlow)  < 3) return;
   if(CopyBuffer(handleEMAMacro, 0, 0, 3, bufferEMAMacro) < 3) return;
   if(CopyBuffer(handleADX,      0, 0, 3, bufferADX)      < 3) return;  // Buffer 0 = ADX
   if(CopyBuffer(handleADX,      1, 0, 3, bufferDIPlus)   < 3) return;  // Buffer 1 = +DI
   if(CopyBuffer(handleADX,      2, 0, 3, bufferDIMinus)  < 3) return;  // Buffer 2 = -DI
   if(CopyBuffer(handleRSI,      0, 0, 3, bufferRSI)      < 3) return;

   int totalPositions = CountPositions();

   if(totalPositions == 0)
   {
      //--- Control de nueva barra: las entradas se evalúan UNA VEZ por vela
      //    Esto previene re-entradas múltiples dentro de la misma barra
      //    mientras mantiene la filosofía de re-entrada continua tras cierre
      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(currentBarTime != g_lastBarTime)
      {
         g_lastBarTime = currentBarTime;
         ExecuteTrendFollowingEntry();
      }
   }
   else
   {
      //--- La gestión de protección se ejecuta tick-a-tick para
      //    máxima reactividad en mercados volátiles (XAUUSD)
      ManageExitsAndProtection();
   }
}

//+------------------------------------------------------------------+
//| CountPositions: Conteo de posiciones activas de este EA          |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)magicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| ClassifyMarketRegime: Clasificador de Régimen Cuantitativo       |
//|                                                                  |
//| Implementa el sistema MLRCS de cuatro capas ortogonales.         |
//| Usa barra[1] (última vela CERRADA) como base de cálculo para     |
//| eliminar el efecto de repainting en señales en tiempo real.      |
//|                                                                  |
//| Retorna:  +1 = Señal LARGA confirmada                            |
//|           -1 = Señal CORTA confirmada                            |
//|            0 = Sin señal (régimen indeterminado o agotamiento)   |
//+------------------------------------------------------------------+
int ClassifyMarketRegime()
{
   //--- Extracción de valores de la última barra CERRADA (índice 1)
   //    para garantizar señales sin repainting
   double emaFast_1  = bufferEMAFast[1];   // EMA rápida, barra-1
   double emaFast_2  = bufferEMAFast[2];   // EMA rápida, barra-2 (base para pendiente)
   double emaSlow_1  = bufferEMASlow[1];   // EMA lenta,  barra-1
   double emaMacro_1 = bufferEMAMacro[1];  // EMA macro,  barra-1
   double adx_1      = bufferADX[1];       // ADX, barra-1
   double adx_2      = bufferADX[2];       // ADX, barra-2 (base para detectar giro)
   double diPlus_1   = bufferDIPlus[1];    // +DI, barra-1
   double diMinus_1  = bufferDIMinus[1];   // -DI, barra-1
   double rsi_1      = bufferRSI[1];       // RSI, barra-1
   double close_1    = iClose(_Symbol, _Period, 1); // Cierre confirmado, barra-1

   //================================================================
   //  CAPA 1: GATE DE RÉGIMEN (ADX)
   //  Principio: Solo operar cuando el mercado tiene energía
   //  direccional suficiente para sustentar una tendencia.
   //  ADX bajo = mercado en equilibrio = señales sin valor predictivo.
   //================================================================
   if(adx_1 < InpADXTrendMin) return 0;

   //--- Filtro de Agotamiento Parabólico:
   //    ADX > umbral máximo AND está girando hacia abajo indica que
   //    la tendencia ha consumido su energía (fase de distribución/reversión).
   //    El riesgo de reversión de cola gorda es máximo en este punto.
   if(adx_1 > InpADXExhaustMax && adx_1 < adx_2) return 0;

   //================================================================
   //  CAPA 2: ALINEACIÓN ESTRUCTURAL DE EMAs
   //  Principio: Las EMAs deben confirmar la misma dirección en
   //  múltiples horizontes temporales.
   //  - EMA_fast > EMA_slow:  estructura alcista táctica
   //  - close > EMA_macro:    precio en territorio estructural alcista
   //  - Pendiente EMA_fast:   la tendencia debe estar acelerando,
   //                          no desacelerando (anti-entrada tardía)
   //================================================================
   bool bullStructure = (emaFast_1 >  emaSlow_1)  &&
                        (close_1   >  emaMacro_1) &&
                        (emaFast_1 >  emaFast_2); // Pendiente positiva activa

   bool bearStructure = (emaFast_1 <  emaSlow_1)  &&
                        (close_1   <  emaMacro_1) &&
                        (emaFast_1 <  emaFast_2); // Pendiente negativa activa

   //================================================================
   //  CAPA 3: CONVICCIÓN DIRECCIONAL (DMI)
   //  Principio: El diferencial DI+/-DI- debe ser significativo.
   //  Un ADX alto con DI+/DI- muy próximos = alta volatilidad sin
   //  dirección clara (e.g., spike de noticias bidireccional).
   //  El spread mínimo garantiza convicción real, no ruido amplificado.
   //================================================================
   double diSpread = MathAbs(diPlus_1 - diMinus_1);
   bool   bullDMI  = (diPlus_1  > diMinus_1) && (diSpread >= InpDISpreadMin);
   bool   bearDMI  = (diMinus_1 > diPlus_1)  && (diSpread >= InpDISpreadMin);

   //================================================================
   //  CAPA 4: CALIDAD DE MOMENTUM (RSI)
   //  Principio: RSI actúa como filtro de calidad, NO como oscilador
   //  de reversión a la media.
   //  En uptrends, RSI tiende a oscilar en [40, 80].
   //  En downtrends, RSI tiende a oscilar en [20, 60].
   //  Las bandas asimétricas capturan la zona de continuación sana
   //  y excluyen las entradas en extremos de agotamiento de onda.
   //================================================================
   bool bullRSI = (rsi_1 > InpRSIBullMin) && (rsi_1 < InpRSIBullMax);
   bool bearRSI = (rsi_1 > InpRSIBearMin) && (rsi_1 < InpRSIBearMax);

   //================================================================
   //  DECISIÓN FINAL: Las 4 capas deben alinearse en la misma
   //  dirección. Cualquier contradicción = 0 (sin señal).
   //================================================================
   if(bullStructure && bullDMI && bullRSI) return  1;  // SEÑAL LARGA
   if(bearStructure && bearDMI && bearRSI) return -1;  // SEÑAL CORTA

   return 0; // SIN SEÑAL
}

//+------------------------------------------------------------------+
//| ExecuteTrendFollowingEntry: Abre posición si el régimen lo avala |
//+------------------------------------------------------------------+
void ExecuteTrendFollowingEntry()
{
   int signal = ClassifyMarketRegime();
   if(signal == 0) return; // Sin señal cuantificada, no actuar

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double atr    = bufferATR[0]; // ATR barra actual: volatilidad en tiempo real para sizing
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(signal == 1) // ENTRADA LARGA — Régimen alcista multi-capa confirmado
   {
      double sl = NormalizeDouble(ask - (atr * InpSLMultiplier), digits);
      double tp = NormalizeDouble(ask + (atr * InpTPMultiplier), digits);

      if(!trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "Trend Long v7"))
         Print("[WARN] Fallo apertura LONG | Retcode: ", trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription());
      else
         Print("[LONG] ASK=", ask, " | SL=", sl, " | TP=", tp,
               " | ATR=", DoubleToString(atr, digits), " | ADX=",
               DoubleToString(bufferADX[1], 2));
   }
   else // ENTRADA CORTA — Régimen bajista multi-capa confirmado
   {
      double sl = NormalizeDouble(bid + (atr * InpSLMultiplier), digits);
      double tp = NormalizeDouble(bid - (atr * InpTPMultiplier), digits);

      if(!trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "Trend Short v7"))
         Print("[WARN] Fallo apertura SHORT | Retcode: ", trade.ResultRetcode(),
               " | ", trade.ResultRetcodeDescription());
      else
         Print("[SHORT] BID=", bid, " | SL=", sl, " | TP=", tp,
               " | ATR=", DoubleToString(atr, digits), " | ADX=",
               DoubleToString(bufferADX[1], 2));
   }
}

//+------------------------------------------------------------------+
//| ManageExitsAndProtection: Break-Even + Trailing Stop             |
//|                                                                  |
//| Sistema heredado de v6 sin modificaciones. Se ejecuta en cada   |
//| tick para máxima reactividad en la gestión de posiciones abiertas|
//+------------------------------------------------------------------+
void ManageExitsAndProtection()
{
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double atr    = bufferATR[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      //--- Filtro: solo posiciones de este EA en este símbolo
      if(PositionGetSymbol(i) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != (long)magicNumber)
         continue;

      ulong  ticket = PositionGetTicket(i);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         //--- Break-Even Inteligente:
         //    Se activa cuando el precio se mueve 0.5×ATR a favor.
         //    Mueve el SL a entrada + mínimo garantizado.
         if(bid >= open + (atr * 0.5))
         {
            double targetBE = open + (InpMinPointsProfit * point);
            if(sl < targetBE)
               trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
         }

         //--- Trailing Stop Agresivo:
         //    Solo se activa DESPUÉS de que el BE está garantizado (sl >= open).
         //    Persigue el precio cerrando el diferencial con cada nuevo tick.
         if(sl >= open)
         {
            double newSL = NormalizeDouble(bid - (InpTrailingPoints * point), digits);
            if(newSL > sl)
               trade.PositionModify(ticket, newSL, tp);
         }
      }
      else // POSITION_TYPE_SELL
      {
         //--- Break-Even Inteligente (lógica espejo para cortos)
         if(ask <= open - (atr * 0.5))
         {
            double targetBE = open - (InpMinPointsProfit * point);
            if(sl == 0.0 || sl > targetBE)
               trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
         }

         //--- Trailing Stop Agresivo (lógica espejo para cortos)
         if(sl > 0.0 && sl <= open)
         {
            double newSL = NormalizeDouble(ask + (InpTrailingPoints * point), digits);
            if(newSL < sl)
               trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}
//+------------------------------------------------------------------+
