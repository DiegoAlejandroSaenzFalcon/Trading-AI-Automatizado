//+------------------------------------------------------------------+
//|                                      XAUUSD_AutoCalib_EA.mq5      |
//|        Motor Adaptativo Multi-Temporal - Price Action Puro        |
//|              XAUUSD | Exness | Auto-Calibracion Dinamica          |
//+------------------------------------------------------------------+
#property copyright "Arquitectura Cuantitativa - Auto-Calibracion Dinamica v1.10"
#property version   "1.10"
#property description "EA de Price Action puro con auto-calibracion MTF para XAUUSD. Adaptado a Exness MT5Real22, cuenta Standard Cent (Hedging), 1:1000."

#include <Trade\Trade.mqh>

//======================================================================
// DOCUMENTACION DE ARQUITECTURA
// ---------------------------------------------------------------------
// 1. MOTOR DE ESTRUCTURA (fractales nativos iFractals) -> sesgo macro D1/H4
// 2. CLASIFICADOR DE REGIMEN (Efficiency Ratio + ATR Expansion + StdDev/ATR)
// 3. LOCALIZADOR DE POI (H1) y GATILLO BOS (M5)
// 4. MOTOR DE RIESGO (position sizing agnostico de tipo de cuenta via tick value)
// 5. MOTOR DE EJECUCION (CTrade + reintentos + filtro de spread dinamico)
//
// Cadencia de actualizacion (resuelve el costo computacional de la Fase 1-Q1):
//   - Sesgo Macro (D1/H4):     recalculado solo en cierre de vela H4
//   - POI (H1):                recalculado solo en cierre de vela H1
//   - Regimen (M15):           recalculado solo en cierre de vela M15
//   - Gatillo/Ejecucion (M5):  evaluado solo en cierre de vela M5
//   - Trailing / Circuit breaker: chequeo ligero en cada tick (lectura de
//     cache ya calculado, NO recalculo pesado)
//
// El EA funciona identico sin importar la temporalidad del grafico donde se
// adjunte: todas las temporalidades usadas estan fijas en el codigo (D1,
// H4, H1, M15, M5, M1), nunca PERIOD_CURRENT.
//
// --- ADAPTACION v1.10 (Exness MT5Real22 | Standard Cent | Hedging | 1:1000) ---
// - Gestion de posiciones migrada a PositionsTotal()/PositionGetTicket()/
//   PositionSelectByTicket() -- obligatorio en cuentas HEDGING, donde puede
//   haber mas de una posicion simultanea para el mismo simbolo.
// - Filling Mode resuelto dinamicamente via SYMBOL_FILLING_MODE para evitar
//   el error 10030 (Invalid Fill) en XAUUSDc.
// - CRiskEngine admite bypass explicito del lote minimo del broker para
//   escenarios de micro-capitalizacion (InpBypassMicroCapitalLimits).
//======================================================================

//--- Enumeraciones
enum ENUM_MARKET_REGIME
  {
   REGIME_TRENDING,     // ER alto + expansion ATR > umbral
   REGIME_RANGING,      // ER bajo, sin compresion extrema
   REGIME_CONTRACTING,  // compresion StdDev/ATR muy baja (posible ruptura)
   REGIME_UNDEFINED     // historia insuficiente todavia
  };

enum ENUM_MACRO_BIAS
  {
   BIAS_BULLISH,
   BIAS_BEARISH,
   BIAS_NEUTRAL
  };

//--- Estructura de un swing (fractal) confirmado
struct SwingPoint
  {
   datetime          time;
   double            price;
   bool              isHigh;
   bool              valid;
  };

//--- Estructura auxiliar para verificacion de historia disponible
struct TFRequirement
  {
   ENUM_TIMEFRAMES   tf;
   int               minBars;
   string            label;
  };

//======================================================================
// INPUTS - Minimizados a proposito (ver auditoria del brief).
// Solo se exponen parametros de TOLERANCIA AL RIESGO / OPERATIVOS.
// Ningun parametro de "trading" (SL, TP, umbrales de entrada) es un input:
// todos se calculan en vivo a partir de la estructura de mercado.
//======================================================================
input group "=== Riesgo y Seguridad (tolerancia del trader, no curve-fitting) ==="
input double InpRiskPercent            = 0.5;      // Riesgo % por operacion (sobre min(balance,equity))
input double InpMaxDailyDrawdownPct    = 3.0;       // Circuit breaker: perdida diaria maxima %
input double InpMaxSpreadMultiplier    = 2.5;       // Descarta entrada si spread > N x spread promedio movil
input int    InpMaxSlippagePoints      = 30;        // Tolerancia de deslizamiento en puntos
input ulong  InpMagicNumber            = 20260710;  // Identificador de operaciones del EA
input bool   InpBypassMicroCapitalLimits = true;    // [INYECCION] Forzar lote minimo si el calculo por riesgo cae debajo de SYMBOL_VOLUME_MIN (solo testing forward, capital micro)
input group "=== Comportamiento Operativo ==="
input bool   InpUseStructuralTrailing  = true;      // Trailing stop basado en estructura (no en pips fijos)
input bool   InpAllowContractionBreak  = true;      // Permitir entradas de ruptura en regimen de contraccion

//--- Objeto de trading
CTrade g_trade;

//--- Cache de "nueva vela" por temporalidad relevante
datetime g_lastBarH4  = 0;
datetime g_lastBarH1  = 0;
datetime g_lastBarM15 = 0;
datetime g_lastBarM5  = 0;
datetime g_lastBarM1  = 0;

//--- Handles de indicadores nativos (creados UNA sola vez en OnInit)
int g_hFractalsD1;
int g_hFractalsH4;
int g_hFractalsH1;
int g_hFractalsM5;
int g_hATR_M15;
int g_hATR_M5;
int g_hStdDev_M15;

//--- Estado cacheado de sesgo/regimen/POI (se recalculan solo en cierres de vela)
ENUM_MACRO_BIAS    g_macroBias = BIAS_NEUTRAL;
ENUM_MARKET_REGIME g_regime    = REGIME_UNDEFINED;
double             g_poiPrice  = 0.0;
bool               g_poiIsLow  = true;

//--- Circuit breaker de drawdown diario
double g_dayStartEquity = 0.0;
int    g_currentDay     = -1;
bool   g_tradingHalted  = false;

//--- Buffer circular de spread (muestreado en cierre de M1, no en cada tick)
#define SPREAD_BUFFER_SIZE 50
double g_spreadBuffer[SPREAD_BUFFER_SIZE];
int    g_spreadBufferIdx    = 0;
int    g_spreadSamplesCount = 0;

//+------------------------------------------------------------------+
//| Detecta cierre de nueva vela para evitar recalculo en cada tick   |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &cache)
  {
   datetime t = iTime(_Symbol, tf, 0);
   if(t != cache)
     {
      cache = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Efficiency Ratio de Kaufman: mide "eficiencia direccional"        |
//| ER = |Close[0]-Close[N]| / Suma(|Close[i]-Close[i+1]|), i=0..N-1  |
//| ER -> 1 : movimiento eficiente y direccional (tendencia)          |
//| ER -> 0 : movimiento ineficiente / ruido (rango)                  |
//+------------------------------------------------------------------+
double CalculateEfficiencyRatio(string symbol, ENUM_TIMEFRAMES tf, int period)
  {
   double close[];
   ArraySetAsSeries(close, true);
   int copied = CopyClose(symbol, tf, 0, period + 1, close);
   if(copied < period + 1)
      return -1.0; // historia insuficiente

   double netChange = MathAbs(close[0] - close[period]);
   double sumChanges = 0.0;
   for(int i = 0; i < period; i++)
      sumChanges += MathAbs(close[i] - close[i+1]);

   if(sumChanges < _Point)
      return 0.0; // evita division por cero en mercados sin movimiento

   return netChange / sumChanges;
  }

//+------------------------------------------------------------------+
//| Ratio de Expansion de Volatilidad: ATR actual contra su propio    |
//| promedio historico reciente (baseline movil). >1 expansion,       |
//| <1 contraccion. No usa un umbral fijo en pips.                    |
//+------------------------------------------------------------------+
double CalculateATRExpansionRatio(int atrHandle, int baselinePeriod)
  {
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   int need = baselinePeriod + 1;
   if(CopyBuffer(atrHandle, 0, 0, need, atrBuffer) < need)
      return -1.0;

   double currentATR = atrBuffer[0];
   double baselineSum = 0.0;
   for(int i = 1; i <= baselinePeriod; i++)
      baselineSum += atrBuffer[i];
   double baselineATR = baselineSum / baselinePeriod;

   if(baselineATR < _Point)
      return 1.0;

   return currentATR / baselineATR;
  }

//+------------------------------------------------------------------+
//| Indice de Compresion de Rango: StdDev(Close,N) / ATR(N)           |
//| Bajo = precio "comprimido" respecto a su rango real (posible      |
//| ruptura inminente). Alto = expansion ya en curso.                 |
//+------------------------------------------------------------------+
double CalculateCompressionIndex(int stdDevHandle, int atrHandle)
  {
   double stdBuf[], atrBuf[];
   ArraySetAsSeries(stdBuf, true);
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(stdDevHandle, 0, 0, 1, stdBuf) < 1)
      return -1.0;
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuf) < 1)
      return -1.0;
   if(atrBuf[0] < _Point)
      return 1.0;
   return stdBuf[0] / atrBuf[0];
  }

//+------------------------------------------------------------------+
//| Clasifica el regimen actual combinando 3 metricas puras de accion |
//| de precio (sin osciladores suavizados clasicos). Los 3 umbrales   |
//| son puntos de corte estadisticamente razonables sobre el rango    |
//| teorico de cada metrica -- NO son valores optimizados contra      |
//| backtests. Se recomienda validarlos con datos propios.            |
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME ClassifyRegime()
  {
   double er = CalculateEfficiencyRatio(_Symbol, PERIOD_M15, 20);
   double atrExpansion = CalculateATRExpansionRatio(g_hATR_M15, 96);
   double compression = CalculateCompressionIndex(g_hStdDev_M15, g_hATR_M15);

   if(er < 0 || atrExpansion < 0 || compression < 0)
      return REGIME_UNDEFINED;

   const double ER_TREND_THRESHOLD    = 0.35;
   const double EXPANSION_THRESHOLD   = 1.15;
   const double COMPRESSION_THRESHOLD = 0.55;

   if(compression < COMPRESSION_THRESHOLD && atrExpansion < 1.0)
      return REGIME_CONTRACTING;

   if(er >= ER_TREND_THRESHOLD && atrExpansion >= EXPANSION_THRESHOLD)
      return REGIME_TRENDING;

   return REGIME_RANGING;
  }

//+------------------------------------------------------------------+
//| Recolecta hasta maxSwings fractales confirmados (mas recientes    |
//| primero) de un buffer de fractales nativo.                        |
//| bufferIndex: 0 = fractal superior (swing high), 1 = inferior      |
//+------------------------------------------------------------------+
int CollectSwings(int fractalHandle, int bufferIndex, ENUM_TIMEFRAMES tf, int lookback, SwingPoint &results[], int maxSwings)
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   int copied = CopyBuffer(fractalHandle, bufferIndex, 0, lookback, buf);
   if(copied <= 0)
      return 0;

   int found = 0;
   ArrayResize(results, maxSwings);
   for(int i = 0; i < copied && found < maxSwings; i++)
     {
      if(buf[i] != EMPTY_VALUE && buf[i] != 0.0)
        {
         results[found].price  = buf[i];
         results[found].time   = iTime(_Symbol, tf, i);
         results[found].isHigh = (bufferIndex == 0);
         results[found].valid  = true;
         found++;
        }
     }
   return found;
  }

//+------------------------------------------------------------------+
//| Sesgo Macro: clasifica la secuencia de los ultimos 2 swings H4.   |
//| HH+HL -> alcista | LH+LL -> bajista | mixto -> neutral (sin trade)|
//| Filtrado por Efficiency Ratio de H4 y vetado si D1 muestra una    |
//| secuencia claramente CONTRARIA (confluencia de marco superior).   |
//+------------------------------------------------------------------+
ENUM_MACRO_BIAS CalculateMacroBias()
  {
   SwingPoint highsH4[], lowsH4[];
   int nH = CollectSwings(g_hFractalsH4, 0, PERIOD_H4, 100, highsH4, 2);
   int nL = CollectSwings(g_hFractalsH4, 1, PERIOD_H4, 100, lowsH4, 2);
   if(nH < 2 || nL < 2)
      return BIAS_NEUTRAL; // estructura H4 insuficiente para confirmar secuencia

   double erH4 = CalculateEfficiencyRatio(_Symbol, PERIOD_H4, 20);
   const double ER_MACRO_FILTER = 0.30;
   if(erH4 >= 0 && erH4 < ER_MACRO_FILTER)
      return BIAS_NEUTRAL; // H4 demasiado ineficiente/ruidoso para confiar en el sesgo

   ENUM_MACRO_BIAS biasH4 = BIAS_NEUTRAL;
   if(highsH4[0].price > highsH4[1].price && lowsH4[0].price > lowsH4[1].price)
      biasH4 = BIAS_BULLISH;
   else
      if(highsH4[0].price < highsH4[1].price && lowsH4[0].price < lowsH4[1].price)
         biasH4 = BIAS_BEARISH;

   if(biasH4 == BIAS_NEUTRAL)
      return BIAS_NEUTRAL;

//--- Filtro de confluencia D1: veta el sesgo H4 solo si D1 muestra una
//--- secuencia clara y CONTRARIA. Si D1 es ambiguo, no se veta.
   SwingPoint highsD1[], lowsD1[];
   int nHd = CollectSwings(g_hFractalsD1, 0, PERIOD_D1, 60, highsD1, 2);
   int nLd = CollectSwings(g_hFractalsD1, 1, PERIOD_D1, 60, lowsD1, 2);
   if(nHd >= 2 && nLd >= 2)
     {
      bool d1Bullish = highsD1[0].price > highsD1[1].price && lowsD1[0].price > lowsD1[1].price;
      bool d1Bearish = highsD1[0].price < highsD1[1].price && lowsD1[0].price < lowsD1[1].price;

      if(biasH4 == BIAS_BULLISH && d1Bearish)
         return BIAS_NEUTRAL;
      if(biasH4 == BIAS_BEARISH && d1Bullish)
         return BIAS_NEUTRAL;
     }

   return biasH4;
  }

//+------------------------------------------------------------------+
//| Localiza el POI (Point of Interest) en H1: el swing mas reciente  |
//| OPUESTO a la direccion del sesgo (zona de pullback / origen del   |
//| impulso), usado como zona de interes para el gatillo de entrada.  |
//+------------------------------------------------------------------+
bool CalculatePOI(ENUM_MACRO_BIAS bias, double &poiPrice, bool &poiIsLow)
  {
   SwingPoint swing[];
   if(bias == BIAS_BULLISH)
     {
      int n = CollectSwings(g_hFractalsH1, 1, PERIOD_H1, 60, swing, 1); // swing low
      if(n < 1)
         return false;
      poiPrice = swing[0].price;
      poiIsLow = true;
      return true;
     }
   if(bias == BIAS_BEARISH)
     {
      int n = CollectSwings(g_hFractalsH1, 0, PERIOD_H1, 60, swing, 1); // swing high
      if(n < 1)
         return false;
      poiPrice = swing[0].price;
      poiIsLow = false;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Gatillo de entrada (Break of Structure) en M5: exige que el       |
//| precio haya tocado/aproximado el POI de H1 y que se confirme un   |
//| quiebre del ultimo micro-fractal M5 en la direccion del sesgo.     |
//| Devuelve el nivel estructural para el SL si hay señal valida.     |
//+------------------------------------------------------------------+
bool CheckBOSTrigger(ENUM_MACRO_BIAS bias, double poiPrice, double atrM5, double &slStructuralPrice)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double proximityTolerance = atrM5 * 1.0; // "cerca del POI" en terminos de ATR, no en pips fijos
   double refPrice = (bias == BIAS_BULLISH) ? tick.bid : tick.ask;

   if(MathAbs(refPrice - poiPrice) > proximityTolerance)
      return false;

   if(bias == BIAS_BULLISH)
     {
      SwingPoint microHigh[];
      int n = CollectSwings(g_hFractalsM5, 0, PERIOD_M5, 30, microHigh, 1);
      if(n < 1)
         return false;
      if(tick.bid > microHigh[0].price)
        {
         SwingPoint recentLow[];
         int nl = CollectSwings(g_hFractalsM5, 1, PERIOD_M5, 30, recentLow, 1);
         if(nl < 1)
            return false;
         slStructuralPrice = recentLow[0].price;
         return true;
        }
     }
   else
      if(bias == BIAS_BEARISH)
        {
         SwingPoint microLow[];
         int n = CollectSwings(g_hFractalsM5, 1, PERIOD_M5, 30, microLow, 1);
         if(n < 1)
            return false;
         if(tick.ask < microLow[0].price)
           {
            SwingPoint recentHigh[];
            int nh = CollectSwings(g_hFractalsM5, 0, PERIOD_M5, 30, recentHigh, 1);
            if(nh < 1)
               return false;
            slStructuralPrice = recentHigh[0].price;
            return true;
           }
        }

   return false;
  }

//+------------------------------------------------------------------+
//| Gatillo alternativo para regimen de CONTRACCION: exige una vela   |
//| impulsiva (cuerpo >= 1.2x ATR) que rompa el rango de compresion    |
//| reciente. No depende del sesgo macro D1/H4 (ruptura fresca).      |
//+------------------------------------------------------------------+
bool CheckContractionBreakout(double atrM5, bool &isBullishBreak, double &slStructuralPrice)
  {
   double high[], low[], open[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(close, true);

   int lookback = 20;
   if(CopyHigh(_Symbol, PERIOD_M5, 0, lookback, high) < lookback)
      return false;
   if(CopyLow(_Symbol, PERIOD_M5, 0, lookback, low)   < lookback)
      return false;
   if(CopyOpen(_Symbol, PERIOD_M5, 0, 2, open) < 2)
      return false;
   if(CopyClose(_Symbol, PERIOD_M5, 0, 2, close) < 2)
      return false;

   double rangeHigh = high[ArrayMaximum(high, 1, lookback - 1)];
   double rangeLow  = low[ArrayMinimum(low, 1, lookback - 1)];

   double lastBody = MathAbs(close[1] - open[1]);
   bool impulsive = (lastBody >= atrM5 * 1.2);
   if(!impulsive)
      return false;

   if(close[1] > rangeHigh)
     {
      isBullishBreak = true;
      slStructuralPrice = rangeLow; // stop amplio: base del rango de compresion
      return true;
     }
   if(close[1] < rangeLow)
     {
      isBullishBreak = false;
      slStructuralPrice = rangeHigh;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| TP dinamico: usa el swing opuesto mas reciente en H1 como objetivo|
//| estructural si implica al menos 1.2R; si no, cae a un fallback 2R.|
//+------------------------------------------------------------------+
double CalculateStructuralTakeProfit(bool isBuy, double entryPrice, double slDistance)
  {
   SwingPoint opposite[];
   int bufIdx = isBuy ? 0 : 1; // swing high (compra) o swing low (venta) como objetivo
   int n = CollectSwings(g_hFractalsH1, bufIdx, PERIOD_H1, 80, opposite, 1);

   double fallbackTP = isBuy ? entryPrice + slDistance * 2.0 : entryPrice - slDistance * 2.0;
   if(n < 1)
      return fallbackTP;

   double structuralTarget = opposite[0].price;
   double structuralDistance = MathAbs(structuralTarget - entryPrice);

   if(structuralDistance < slDistance * 1.2)
      return fallbackTP; // objetivo demasiado cercano, no compensa el riesgo

   return structuralTarget;
  }

//+------------------------------------------------------------------+
//| Verifica que exista historia suficiente en cada temporalidad      |
//| relevante. Diagnostico no bloqueante: las funciones de calculo    |
//| ya tienen sus propias guardas defensivas independientes de esto.  |
//+------------------------------------------------------------------+
bool VerifyHistorySynchronization()
  {
   TFRequirement reqs[] =
     {
        {PERIOD_D1,  60,  "D1"},
        {PERIOD_H4,  100, "H4"},
        {PERIOD_H1,  60,  "H1"},
        {PERIOD_M15, 100, "M15"},
        {PERIOD_M5,  30,  "M5"}
     };

   bool allReady = true;
   for(int i = 0; i < ArraySize(reqs); i++)
     {
      int available = Bars(_Symbol, reqs[i].tf);
      if(available < reqs[i].minBars)
        {
         Print("AVISO: historia insuficiente en ", reqs[i].label, " (", available, "/", reqs[i].minBars, "). ",
               "El EA operara con cautela hasta que el terminal descargue mas historia.");
         allReady = false;
        }
     }
   return allReady;
  }

//+------------------------------------------------------------------+
//| CRiskEngine: dimensionamiento de posicion agnostico al tipo de    |
//| cuenta (Cent/Raw/Standard) mediante el tick value real del broker.|
//| Tambien gestiona el circuit breaker de drawdown diario.           |
//+------------------------------------------------------------------+
class CRiskEngine
  {
private:
   double            m_riskPercent;
   double            m_maxDailyDrawdownPct;
   bool              m_bypassMicroCapitalLimits;

public:
   void              Init(double riskPercent, double maxDailyDrawdownPct, bool bypassMicroCapitalLimits)
     {
      m_riskPercent = riskPercent;
      m_maxDailyDrawdownPct = maxDailyDrawdownPct;
      m_bypassMicroCapitalLimits = bypassMicroCapitalLimits;
     }

   //--- Calcula el lote correcto sin importar si la cuenta es Cent o Raw:
   //--- el tick value reportado por el broker ya refleja la denominacion
   //--- real de la cuenta y el tamaño de contrato -- por eso NO se necesita
   //--- una rama "if(cuenta cent)...else..." como se planteaba originalmente.
   double            CalculateLotSize(double slDistancePrice, bool isBuy)
     {
      if(slDistancePrice <= 0)
         return 0.0;

      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue <= 0 || tickSize <= 0)
        {
         Print("CRiskEngine: tick value/size invalido para ", _Symbol);
         return 0.0;
        }

      double valuePerPriceUnit = tickValue / tickSize;
      double lossPerLot = slDistancePrice * valuePerPriceUnit;
      if(lossPerLot <= 0)
         return 0.0;

      double capital = MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));
      double riskAmount = capital * (m_riskPercent / 100.0);
      double rawLots = riskAmount / lossPerLot;

      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

      double steppedLots = MathFloor(rawLots / lotStep) * lotStep;

      //--- [INYECCION - Micro-capitalizacion] Punto critico: con capital de
      //--- pocos dolares (ej. 1376 USC = 13.76 USD reales) y un SL estructural
      //--- amplio, el lote por riesgo puede caer debajo de SYMBOL_VOLUME_MIN.
      //--- CORRECCION DE DISEÑO respecto a v1.0: aqui el chequeo se hace
      //--- ANTES del clamp final (MathMax de abajo). En v1.0 el clamp ya
      //--- forzaba el minimo antes de este chequeo, dejando el "return 0.0"
      //--- como codigo muerto que nunca se ejecutaba. Ahora la decision
      //--- (rechazar vs. forzar) tiene efecto real.
      if(steppedLots < minLot)
        {
         if(m_bypassMicroCapitalLimits)
           {
            double impliedRiskPct = (minLot * lossPerLot / capital) * 100.0;
            Print("CRiskEngine [BYPASS MICRO-CAPITAL]: lote por riesgo (", DoubleToString(rawLots, 5),
                  ") < minimo del broker (", DoubleToString(minLot, 2), "). Forzando lote minimo. ",
                  "Riesgo real de esta operacion: ", DoubleToString(impliedRiskPct, 2),
                  "% (objetivo configurado: ", DoubleToString(m_riskPercent, 2), "%). ",
                  "Uso previsto: recoleccion de datos de testing forward -- desactivar en cuanto el capital real lo permita.");
            steppedLots = minLot;
           }
         else
           {
            Print("CRiskEngine: lote por riesgo (", DoubleToString(rawLots, 5),
                  ") por debajo del minimo del broker (", DoubleToString(minLot, 2), "). Operacion rechazada. ",
                  "Active InpBypassMicroCapitalLimits para forzar el lote minimo.");
            return 0.0;
           }
        }

      steppedLots = MathMax(minLot, MathMin(maxLot, steppedLots));

      //--- Verificacion de margen disponible antes de confirmar el lote
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
         return 0.0;

      ENUM_ORDER_TYPE ot = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double checkPrice  = isBuy ? tick.ask : tick.bid;
      double marginRequired;
      if(!OrderCalcMargin(ot, _Symbol, steppedLots, checkPrice, marginRequired))
        {
         Print("CRiskEngine: fallo OrderCalcMargin, err=", GetLastError());
         return 0.0;
        }

      double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(marginRequired > freeMargin * 0.9) // colchon de seguridad del 10%
        {
         Print("CRiskEngine: margen insuficiente. Requerido=", marginRequired, " Libre=", freeMargin);
         return 0.0;
        }

      return steppedLots;
     }

   //--- Circuit breaker de drawdown diario. Devuelve true si el trading
   //--- debe detenerse por el resto del dia.
   bool              CheckDailyDrawdownBreaker(double &dayStartEquity, int &cachedDay)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day != cachedDay)
        {
         cachedDay = dt.day;
         dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         return false; // reinicio de dia, breaker liberado
        }

      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(dayStartEquity <= 0)
         return false;

      double ddPct = (dayStartEquity - currentEquity) / dayStartEquity * 100.0;
      return (ddPct >= m_maxDailyDrawdownPct);
     }
  };

//+------------------------------------------------------------------+
//| CExecutionEngine: envoltura sobre CTrade con reintentos, filtro   |
//| de spread dinamico (no fijo) y gestion de trailing estructural.   |
//+------------------------------------------------------------------+
class CExecutionEngine
  {
private:
   CTrade            *m_trade;
   int               m_maxRetries;

public:
   void              Init(CTrade &tradeObj, int maxRetries = 3)
     {
      m_trade = GetPointer(tradeObj);
      m_maxRetries = maxRetries;
     }

   //--- Filtro de spread dinamico: compara el spread actual contra su
   //--- propio promedio movil reciente (no un umbral fijo en puntos)
   bool              IsSpreadAcceptable(const double &spreadBuffer[], int bufferCount, double maxMultiplier)
     {
      if(bufferCount < 10)
         return true; // buffer insuficiente aun, se permite operar por defecto

      double sum = 0.0;
      for(int i = 0; i < bufferCount; i++)
         sum += spreadBuffer[i];
      double avgSpread = sum / bufferCount;
      if(avgSpread <= 0)
         return true;

      long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      return ((double)currentSpread <= avgSpread * maxMultiplier);
     }

   bool              ExecuteMarketOrder(bool isBuy, double lots, double sl, double tp, string comment)
     {
      int attempts = 0;
      while(attempts < m_maxRetries)
        {
         bool result;
         if(isBuy)
            result = m_trade.Buy(lots, _Symbol, 0.0, sl, tp, comment);
         else
            result = m_trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);

         uint retcode = m_trade.ResultRetcode();

         if(result && retcode == TRADE_RETCODE_DONE)
           {
            Print("CExecutionEngine: orden ejecutada. Ticket=", m_trade.ResultOrder());
            return true;
           }

         if(retcode == TRADE_RETCODE_REQUOTE   || retcode == TRADE_RETCODE_PRICE_CHANGED ||
            retcode == TRADE_RETCODE_PRICE_OFF || retcode == TRADE_RETCODE_TIMEOUT ||
            retcode == TRADE_RETCODE_CONNECTION)
           {
            attempts++;
            Print("CExecutionEngine: reintento ", attempts, " retcode=", retcode,
                  " (", m_trade.ResultRetcodeDescription(), ")");
            Sleep(200);
            continue;
           }

         Print("CExecutionEngine: fallo no recuperable. retcode=", retcode,
               " (", m_trade.ResultRetcodeDescription(), ")");
         return false;
        }

      Print("CExecutionEngine: se agotaron los reintentos (", m_maxRetries, ")");
      return false;
     }

   //--- [INYECCION - Hedging] Trailing stop estructural: ya NO usa
   //--- PositionSelect(_Symbol) (no fiable con multiples posiciones por
   //--- simbolo en cuentas HEDGING). Recorre PositionsTotal(), filtra por
   //--- simbolo + InpMagicNumber via PositionGetTicket()/PositionSelectByTicket(),
   //--- y modifica cada posicion propia individualmente por su ticket.
   void              UpdateStructuralTrailing(int fractalHandleM5)
     {
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
            continue;

         long   posType   = PositionGetInteger(POSITION_TYPE);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);

         bool isBuy = (posType == POSITION_TYPE_BUY);
         int  bufIdx = isBuy ? 1 : 0; // swing lows para trailing en compra, swing highs en venta

         SwingPoint sp[];
         int n = CollectSwings(fractalHandleM5, bufIdx, PERIOD_M5, 30, sp, 1);
         if(n < 1)
            continue;

         double newSL = sp[0].price;

         //--- Ratchet: el SL solo se mueve a favor, nunca se afloja
         if(isBuy && newSL > currentSL)
            m_trade.PositionModify(ticket, newSL, currentTP);
         else
            if(!isBuy && (newSL < currentSL || currentSL == 0))
               m_trade.PositionModify(ticket, newSL, currentTP);
        }
     }
  };

//--- Instancias globales de los motores (declaradas despues de sus clases)
CRiskEngine      g_riskEngine;
CExecutionEngine g_execEngine;

//+------------------------------------------------------------------+
//| [INYECCION - Filling Mode] Resuelve dinamicamente el modo de      |
//| llenado soportado por el simbolo/broker actual, evitando el error |
//| 10030 (Invalid Fill) causado por asumir un modo fijo que Exness   |
//| pudiera no soportar para XAUUSDc en MT5Real22.                    |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING ResolveFillingMode(string symbol)
  {
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);

   Print("Diagnostico Filling Mode | ", symbol, " | mascara cruda=", filling,
         " | FOK soportado=", ((filling & SYMBOL_FILLING_FOK) != 0),
         " | IOC soportado=", ((filling & SYMBOL_FILLING_IOC) != 0));

   if((filling & SYMBOL_FILLING_FOK) != 0)
     {
      Print("Filling Mode seleccionado: ORDER_FILLING_FOK");
      return ORDER_FILLING_FOK;
     }

   if((filling & SYMBOL_FILLING_IOC) != 0)
     {
      Print("Filling Mode seleccionado: ORDER_FILLING_IOC");
      return ORDER_FILLING_IOC;
     }

   Print("AVISO: ", symbol, " no reporta FOK ni IOC explicitamente en SYMBOL_FILLING_MODE. Fallback a ORDER_FILLING_RETURN.");
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| [INYECCION - Hedging] Cuenta las posiciones abiertas que          |
//| pertenecen a este EA (mismo simbolo + mismo numero magico)         |
//| recorriendo PositionsTotal()/PositionGetTicket(). Sustituye a      |
//| PositionSelect(_Symbol), que no es fiable en cuentas HEDGING       |
//| porque puede haber mas de una posicion simultanea para el mismo   |
//| simbolo (cada una con su propio ticket).                           |
//+------------------------------------------------------------------+
int CountEAPositions()
  {
   int count = 0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber)
         continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- [INYECCION - Aislamiento de sufijo] StringFind ya localizaba "XAU"
//--- dentro de "XAUUSDc" porque es busqueda de subcadena (el sufijo del
//--- broker no afecta el prefijo). Se blinda ademas contra variantes de
//--- mayusculas/minusculas comparando sobre una copia en mayusculas.
   string symbolCheck = _Symbol;
   StringToUpper(symbolCheck);
   if(StringFind(symbolCheck, "XAU") < 0)
     {
      Print("ERROR: Este EA esta diseñado exclusivamente para instrumentos XAU. Simbolo actual: ", _Symbol);
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpRiskPercent <= 0 || InpRiskPercent > 10)
     {
      Print("ERROR: InpRiskPercent fuera de un rango prudente (0-10%). Valor actual: ", InpRiskPercent);
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxSlippagePoints);

//--- [INYECCION - Filling Mode / Error 10030] Resolucion dinamica real:
//--- se consulta el modo de llenado que XAUUSDc soporta en Exness
//--- (MT5Real22) y se fija explicitamente en CTrade, en vez de asumir
//--- un modo fijo que el broker podria rechazar.
   ENUM_ORDER_TYPE_FILLING resolvedFilling = ResolveFillingMode(_Symbol);
   g_trade.SetTypeFilling(resolvedFilling);

   g_hFractalsD1 = iFractals(_Symbol, PERIOD_D1);
   g_hFractalsH4 = iFractals(_Symbol, PERIOD_H4);
   g_hFractalsH1 = iFractals(_Symbol, PERIOD_H1);
   g_hFractalsM5 = iFractals(_Symbol, PERIOD_M5);
   g_hATR_M15    = iATR(_Symbol, PERIOD_M15, 14);
   g_hATR_M5     = iATR(_Symbol, PERIOD_M5, 14);
   g_hStdDev_M15 = iStdDev(_Symbol, PERIOD_M15, 20, 0, MODE_SMA, PRICE_CLOSE);

   if(g_hFractalsD1 == INVALID_HANDLE || g_hFractalsH4 == INVALID_HANDLE ||
      g_hFractalsH1 == INVALID_HANDLE || g_hFractalsM5 == INVALID_HANDLE ||
      g_hATR_M15 == INVALID_HANDLE    || g_hATR_M5 == INVALID_HANDLE     ||
      g_hStdDev_M15 == INVALID_HANDLE)
     {
      Print("ERROR: fallo al crear uno o mas handles de indicadores nativos.");
      return(INIT_FAILED);
     }

   g_riskEngine.Init(InpRiskPercent, InpMaxDailyDrawdownPct, InpBypassMicroCapitalLimits);
   g_execEngine.Init(g_trade, 3);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_currentDay = dt.day;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   ArrayInitialize(g_spreadBuffer, 0.0);
   g_spreadBufferIdx = 0;
   g_spreadSamplesCount = 0;

   bool historyReady = VerifyHistorySynchronization();
   if(!historyReady)
      Print("Advertencia: continuando con historia parcial; las guardas defensivas de cada funcion evitaran calculos prematuros.");

   Print("=== EA Auto-Calibrado XAU inicializado ===");
   Print("Simbolo: ", _Symbol,
         " | Moneda de cuenta: ", AccountInfoString(ACCOUNT_CURRENCY),
         " | Contract Size: ", SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE),
         " | Tick Value: ", SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE),
         " | Riesgo/operacion: ", InpRiskPercent, "%");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(g_hFractalsD1);
   IndicatorRelease(g_hFractalsH4);
   IndicatorRelease(g_hFractalsH1);
   IndicatorRelease(g_hFractalsM5);
   IndicatorRelease(g_hATR_M15);
   IndicatorRelease(g_hATR_M5);
   IndicatorRelease(g_hStdDev_M15);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- 1) Circuit breaker: chequeo ligero O(1) en cada tick
   g_tradingHalted = g_riskEngine.CheckDailyDrawdownBreaker(g_dayStartEquity, g_currentDay);
   if(g_tradingHalted)
     {
      //--- [INYECCION - Hedging] CountEAPositions() sustituye a PositionSelect(_Symbol)
      if(CountEAPositions() > 0)
         g_execEngine.UpdateStructuralTrailing(g_hFractalsM5);
      return;
     }

//--- 2) Muestreo de spread en cierre de M1 (barato, evita trabajo por tick)
   if(IsNewBar(PERIOD_M1, g_lastBarM1))
     {
      g_spreadBuffer[g_spreadBufferIdx] = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      g_spreadBufferIdx = (g_spreadBufferIdx + 1) % SPREAD_BUFFER_SIZE;
      if(g_spreadSamplesCount < SPREAD_BUFFER_SIZE)
         g_spreadSamplesCount++;
     }

//--- 3) Recalculo de sesgo macro solo en cierre de H4
   if(IsNewBar(PERIOD_H4, g_lastBarH4))
      g_macroBias = CalculateMacroBias();

//--- 4) Recalculo de regimen solo en cierre de M15
   if(IsNewBar(PERIOD_M15, g_lastBarM15))
      g_regime = ClassifyRegime();

//--- 5) Recalculo de POI solo en cierre de H1
   if(IsNewBar(PERIOD_H1, g_lastBarH1))
      CalculatePOI(g_macroBias, g_poiPrice, g_poiIsLow);

//--- 6) Gestion de posiciones abiertas (trailing) en cada tick (lectura barata)
//--- [INYECCION - Hedging] CountEAPositions() filtra por simbolo + numero
//--- magico y es valido con multiples posiciones simultaneas por simbolo.
   int openPositions = CountEAPositions();
   if(openPositions > 0)
     {
      if(InpUseStructuralTrailing)
         g_execEngine.UpdateStructuralTrailing(g_hFractalsM5);
      return; // ya hay posicion(es) de este EA en este simbolo: no se busca nueva entrada
     }

//--- 7) Busqueda de entrada solo en cierre de M5 (temporalidad de gatillo)
   if(!IsNewBar(PERIOD_M5, g_lastBarM5))
      return;

   double atrBufM5[];
   ArraySetAsSeries(atrBufM5, true);
   if(CopyBuffer(g_hATR_M5, 0, 0, 1, atrBufM5) < 1)
      return;
   double atrM5 = atrBufM5[0];

   double slPrice = 0.0;
   bool   haveSignal  = false;
   bool   isBuySignal = false;

   if(g_regime == REGIME_TRENDING && g_macroBias != BIAS_NEUTRAL)
     {
      if(CheckBOSTrigger(g_macroBias, g_poiPrice, atrM5, slPrice))
        {
         haveSignal  = true;
         isBuySignal = (g_macroBias == BIAS_BULLISH);
        }
     }
   else
      if(g_regime == REGIME_CONTRACTING && InpAllowContractionBreak)
        {
         bool bullBreak;
         if(CheckContractionBreakout(atrM5, bullBreak, slPrice))
           {
            haveSignal  = true;
            isBuySignal = bullBreak;
           }
        }
//--- REGIME_RANGING y REGIME_UNDEFINED: el EA permanece deliberadamente al
//--- margen. No forzar operaciones en condiciones estadisticamente adversas
//--- es, en si mismo, parte de la "inteligencia" del sistema.

   if(!haveSignal)
      return;

   if(!g_execEngine.IsSpreadAcceptable(g_spreadBuffer, g_spreadSamplesCount, InpMaxSpreadMultiplier))
     {
      Print("Entrada descartada: spread anomalo respecto al promedio movil.");
      return;
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double entryPrice = isBuySignal ? tick.ask : tick.bid;
   double slBuffer   = atrM5 * 0.15; // colchon sobre el swing exacto (evita caza de stops)
   double finalSL    = isBuySignal ? (slPrice - slBuffer) : (slPrice + slBuffer);
   double slDistance = MathAbs(entryPrice - finalSL);

   if(slDistance < _Point * 2)
      return; // distancia no operable

   double lots = g_riskEngine.CalculateLotSize(slDistance, isBuySignal);
   if(lots <= 0)
     {
      Print("Entrada descartada: dimensionamiento de posicion invalido (riesgo/margen insuficiente).");
      return;
     }

   double takeProfit = CalculateStructuralTakeProfit(isBuySignal, entryPrice, slDistance);
   string comment = StringFormat("AutoCalib_%s_%s", EnumToString(g_regime), (isBuySignal ? "BUY" : "SELL"));

   g_execEngine.ExecuteMarketOrder(isBuySignal, lots, finalSL, takeProfit, comment);
  }

//======================================================================
// NOTAS DE EXTENSION FUTURA - v1.10 (adaptacion MT5Real22 / Standard Cent / Hedging)
// ---------------------------------------------------------------------
// 1. [RESUELTO EN v1.10] Modo de cuenta: soporte HEDGING nativo via
//    CountEAPositions() y UpdateStructuralTrailing() basados en tickets
//    (PositionsTotal + PositionGetTicket + PositionSelectByTicket), filtrando
//    siempre por simbolo + InpMagicNumber. El EA sigue limitando su PROPIA
//    logica a una posicion abierta a la vez -- es decision de estrategia
//    (una senal direccional a la vez), no limitacion tecnica de la cuenta.
//    Para permitir piramidar/multiples entradas simultaneas del propio EA,
//    hay que relajar el gate del paso 6 en OnTick.
// 2. [RESUELTO EN v1.10] Filling Mode: resuelto dinamicamente en OnInit via
//    ResolveFillingMode() + SYMBOL_FILLING_MODE, evitando el error 10030.
// 3. [RESUELTO EN v1.10] Micro-capitalizacion: InpBypassMicroCapitalLimits
//    fuerza SYMBOL_VOLUME_MIN cuando el capital es insuficiente para
//    respetar el riesgo% configurado con el SL estructural calculado. Es
//    una herramienta de TESTING FORWARD, no una practica recomendada con
//    capital real -- desactivar (false) en cuanto el capital lo permita.
// 4. D1 se usa como FILTRO DE VETO de la estructura H4, no como driver
//    independiente. Se puede promover a un segundo motor de estructura
//    completo reutilizando CollectSwings() sobre PERIOD_D1 si se requiere
//    mayor peso del marco temporal superior.
// 5. CTrade opera en modo SINCRONO (por simplicidad y fiabilidad). Para baja
//    latencia real, activar g_trade.SetAsyncMode(true) y mover la confirmacion
//    de ejecucion a OnTradeTransaction().
// 6. El gatillo de entrada usa M5 como temporalidad de disparo. M1 puede
//    sustituirlo cambiando PERIOD_M5 -> PERIOD_M1 en CheckBOSTrigger() y en
//    la deteccion de nueva vela correspondiente, para entradas mas finas
//    a costa de mas señales (y mas ruido).
//======================================================================
