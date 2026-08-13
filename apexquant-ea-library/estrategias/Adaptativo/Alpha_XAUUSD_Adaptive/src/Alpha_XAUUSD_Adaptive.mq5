//+------------------------------------------------------------------+
//|                                    Alpha_XAUUSD_Adaptive.mq5     |
//|                                  Copyright 2026, Quant Algo Lab  |
//|                                      https://www.quantalgolab.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Quant Algo Lab"
#property link      "https://www.quantalgolab.com"
#property version   "1.00"
#property description "EA de Acción del Precio Cuantitativo y Auto-Calibrado para XAUUSD en Exness"
#property description "Diseñado para mitigación de sobreajuste mediante detección de régimen multi-temporal."

#include <Trade\Trade.mqh>

//--- Parámetros de Control de Riesgo y Operación (No Estratégicos)
input group "---- GESTIÓN DE RIESGO DE ÉLITE ----"
input double   InpRiskPercent             = 1.0;       // Riesgo por Operación (% del Balance)
input double   InpMaxDailyDrawdownPercent = 3.0;       // Filtro de Seguridad: Drawdown Diario Máximo (%)
input double   InpMaxSpreadFactor         = 2.0;       // Filtro de Spread Dinámico (x Spread Promedio Móvil)

input group "---- CONFIGURACIÓN DEL SISTEMA ----"
input ulong    InpMagicNumber             = 882626;    // Identificador único del Algoritmo (Magic Number)
input string   InpTradeComment            = "Alpha_XAUUSD_Adaptive";

//--- Enumeraciones del Régimen de Mercado
enum ENUM_MARKET_REGIME {
   REGIME_TREND_BULL,
   REGIME_TREND_BEAR,
   REGIME_RANGE,
   REGIME_COMPRESSION
};

//+------------------------------------------------------------------+
//| CLASE PRINCIPAL: ARQUITECTURA DEL EXPERT ADVISOR                 |
//+------------------------------------------------------------------+
class CAdaptiveQuantEA {
private:
   //--- Instancias de Ejecución
   CTrade            m_trade;
   
   //--- Handles de Indicadores Estructurales Nativos (Asignados una sola vez)
   int               m_handle_atr_m15;
   int               m_handle_fractals_d1;
   int               m_handle_fractals_h4;
   int               m_handle_fractals_h1;
   int               m_handle_fractals_m5;
   
   //--- Variables de Estado e Historial de Barras (Control de Cadencia por Evento)
   datetime          m_last_time_d1;
   datetime          m_last_time_h4;
   datetime          m_last_time_h1;
   datetime          m_last_time_m15;
   datetime          m_last_time_m5;
   
   //--- Memoria de Variables del Entorno de Mercado
   ENUM_MARKET_REGIME m_current_regime;
   int               m_macro_bias;        // 1 = Alcista, -1 = Bajista, 0 = Neutral
   double            m_poi_price;         // Precio del Punto de Interés (Estructura H1)
   double            m_rolling_spread[];  // Cache para el cálculo de spread dinámico
   int               m_spread_idx;
   
   //--- Registro de Capital Diario (Circuit Breaker)
   datetime          m_last_day;
   double            m_initial_day_balance;

   //--- Métodos Internos de Cálculo Científico
   bool              IsNewBar(ENUM_TIMEFRAMES tf, datetime &stored_time);
   void              UpdateMarketRegime();
   void              UpdateMacroBias();
   void              UpdatePointOfInterest();
   void              EvaluateTriggerAndExecute();
   void              ManageActivePositions();
   double            CalculateKaufmanER(int periods);
   double            CalculateAdaptiveLot(double sl_distance);
   double            GetRollingSpreadAverage();
   bool              CheckCircuitBreaker();
   double            GetLatestFractalPrice(int handle, int fractal_type, int max_bars=100);

public:
                     CAdaptiveQuantEA();
                    ~CAdaptiveQuantEA();
   bool              Initialize();
   void              OnTickEngine();
};

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CAdaptiveQuantEA::CAdaptiveQuantEA() : 
   m_handle_atr_m15(INVALID_HANDLE),
   m_handle_fractals_d1(INVALID_HANDLE),
   m_handle_fractals_h4(INVALID_HANDLE),
   m_handle_fractals_h1(INVALID_HANDLE),
   m_handle_fractals_m5(INVALID_HANDLE),
   m_macro_bias(0),
   m_poi_price(0.0),
   m_current_regime(REGIME_RANGE),
   m_spread_idx(0),
   m_initial_day_balance(0.0),
   m_last_day(0)
{
   ArrayResize(m_rolling_spread, 50); // Muestra móvil para el spread dinámico
   ArrayInitialize(m_rolling_spread, 0.0);
}

//+------------------------------------------------------------------+
//| Destructor                                                       |
//+------------------------------------------------------------------+
CAdaptiveQuantEA::~CAdaptiveQuantEA() {
   IndicatorRelease(m_handle_atr_m15);
   IndicatorRelease(m_handle_fractals_d1);
   IndicatorRelease(m_handle_fractals_h4);
   IndicatorRelease(m_handle_fractals_h1);
   IndicatorRelease(m_handle_fractals_m5);
}

//+------------------------------------------------------------------+
//| Inicialización y Sincronización del Entorno                      |
//+------------------------------------------------------------------+
bool CAdaptiveQuantEA::Initialize() {
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(_Symbol);

   //--- Instanciación única de los handles nativos para mitigar latencia
   m_handle_atr_m15     = iATR(_Symbol, PERIOD_M15, 96); // 96 barras M15 = 1 Día de mercado para el Oro
   m_handle_fractals_d1 = iFractals(_Symbol, PERIOD_D1);
   m_handle_fractals_h4 = iFractals(_Symbol, PERIOD_H4);
   m_handle_fractals_h1 = iFractals(_Symbol, PERIOD_H1);
   m_handle_fractals_m5 = iFractals(_Symbol, PERIOD_M5);

   if(m_handle_atr_m15 == INVALID_HANDLE || m_handle_fractals_d1 == INVALID_HANDLE ||
      m_handle_fractals_h4 == INVALID_HANDLE || m_handle_fractals_h1 == INVALID_HANDLE ||
      m_handle_fractals_m5 == INVALID_HANDLE) {
      Print("[ERROR CRISIS] Fallo crítico al inicializar handles estructurales de MQL5.");
      return false;
   }

   //--- Sincronización inicial del historial preventivo
   m_initial_day_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   m_last_day = iTime(_Symbol, PERIOD_D1, 0);

   Print("[INFO] Inicialización exitosa de la arquitectura adaptativa Alpha para XAUUSD.");
   return true;
}

//+------------------------------------------------------------------+
//| Motor Principal en OnTick: Ejecución Dirigida por Eventos        |
//+------------------------------------------------------------------+
void CAdaptiveQuantEA::OnTickEngine() {
   // 1. Monitoreo constante del spread en tiempo real para la muestra móvil
   double current_spread = double(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) * _Point;
   m_rolling_spread[m_spread_idx] = current_spread;
   m_spread_idx = (m_spread_idx + 1) % 50;

   // 2. Ejecución del Circuit Breaker de Drawdown Diario
   if(!CheckCircuitBreaker()) return;

   // 3. Gestión en tiempo real de órdenes abiertas (Trailing Stop dinámico)
   ManageActivePositions();

   // 4. Actualización del Sesgo Macro (Cadencia: Cierre de vela H4)
   if(IsNewBar(PERIOD_H4, m_last_time_h4)) {
      UpdateMacroBias();
   }

   // 5. Clasificación Matemática del Régimen del Mercado (Cadencia: Cierre de vela M15)
   if(IsNewBar(PERIOD_M15, m_last_time_m15)) {
      UpdateMarketRegime();
   }

   // 6. Localización del Punto de Interés Estructural (Cadencia: Cierre de vela H1)
   if(IsNewBar(PERIOD_H1, m_last_time_h1)) {
      UpdatePointOfInterest();
   }

   // 7. Motor de Decisión del Gatillo de Entrada (Cadencia: Cierre de vela M5)
   if(IsNewBar(PERIOD_M5, m_last_time_m5)) {
      EvaluateTriggerAndExecute();
   }
}

//+------------------------------------------------------------------+
//| Control de Cadencia de Cómputo por Eventos de Cierre de Vela     |
//+------------------------------------------------------------------+
bool CAdaptiveQuantEA::IsNewBar(ENUM_TIMEFRAMES tf, datetime &stored_time) {
   datetime current_bar_time = iTime(_Symbol, tf, 0);
   if(current_bar_time == 0) return false; // La historia no está sincronizada en este tick
   
   if(current_bar_time != stored_time) {
      stored_time = current_bar_time;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| FASE 1 - PREGUNTA 2: CLASIFICACIÓN CIENTÍFICA DEL RÉGIMEN         |
//+------------------------------------------------------------------+
void CAdaptiveQuantEA::UpdateMarketRegime() {
   double er = CalculateKaufmanER(14);
   
   double atr_buffer[];
   ArraySetAsSeries(atr_buffer, true);
   if(CopyBuffer(m_handle_atr_m15, 0, 0, 2, atr_buffer) < 2) return;
   
   // Ratio de Expansión del Rango respecto a su propia media histórica diaria
   double atr_ratio = atr_buffer[0] / (atr_buffer[1] == 0.0 ? 1.0 : atr_buffer[1]);

   // Clasificación por corte estadístico puro del comportamiento del precio bruto
   if(er > 0.6 && atr_ratio > 1.05) {
      m_current_regime = (iClose(_Symbol, PERIOD_M15, 0) > iOpen(_Symbol, PERIOD_M15, 14)) ? REGIME_TREND_BULL : REGIME_TREND_BEAR;
   } else if(er < 0.3) {
      m_current_regime = REGIME_COMPRESSION;
   } else {
      m_current_regime = REGIME_RANGE;
   }
}

//+------------------------------------------------------------------+
//| FASE 1 - PREGUNTA 4: MOTOR DE DECISIÓN MULTI-TEMPORAL            |
//+------------------------------------------------------------------+
void CAdaptiveQuantEA::UpdateMacroBias() {
   double hh_h4 = GetLatestFractalPrice(m_handle_fractals_h4, UPPER_LINE);
   double ll_h4 = GetLatestFractalPrice(m_handle_fractals_h4, LOWER_LINE);
   double close_h4 = iClose(_Symbol, PERIOD_H4, 1);

   // Verificación estructural limpia cruzada con el filtro fractal D1 para evitar trampas macro
   double hh_d1 = GetLatestFractalPrice(m_handle_fractals_d1, UPPER_LINE);
   double ll_d1 = GetLatestFractalPrice(m_handle_fractals_d1, LOWER_LINE);

   if(close_h4 > hh_h4 && iClose(_Symbol, PERIOD_D1, 0) > ll_d1) {
      m_macro_bias = 1;  // Sesgo Alcista Confirmado Estructuralmente
   } else if(close_h4 < ll_h4 && iClose(_Symbol, PERIOD_D1, 0) < hh_d1) {
      m_macro_bias = -1; // Sesgo Bajista Confirmado Estructuralmente
   } else {
      m_macro_bias = 0;  // Estructura lateral o conflictiva (Filtro Preventivo)
   }
}

//+------------------------------------------------------------------+
//| DETERMINACIÓN DEL PUNTO DE INTERÉS (POI) EN LA ESTRUCTURA H1     |
//+------------------------------------------------------------------+
void CAdaptiveQuantEA::UpdatePointOfInterest() {
   if(m_macro_bias == 1) {
      // El origen del último impulso alcista: último soporte fractal H1 válido
      m_poi_price = GetLatestFractalPrice(m_handle_fractals_h1, LOWER_LINE);
   } else if(m_macro_bias == -1) {
      // El origen del último impulso bajista: última resistencia fractal H1 válida
      m_poi_price = GetLatestFractalPrice(m_handle_fractals_h1, UPPER_LINE);
   } else {
      m_poi_price = 0.0;
   }
}

//+------------------------------------------------------------------+
//| EVALUACIÓN DEL GATILLO (BOS EN M5) Y EJECUCIÓN CON FILTRO EXNESS |
//+------------------------------------------------------------------+
void CAdaptiveQuantEA::EvaluateTriggerAndExecute() {
   if(m_macro_bias == 0 || m_poi_price == 0.0) return;
   
   // Validación rigurosa de las especificaciones dinámicas de Exness
   double avg_spread = GetRollingSpreadAverage();
   double current_spread = double(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) * _Point;
   if(current_spread > (avg_spread * InpMaxSpreadFactor)) {
      Print("[VETO EJECUCIÓN] Spread anómalo en Exness detectado de forma dinámica.");
      return;
   }

   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double atr_m5_buffer[];
   
   int handle_atr_m5 = iATR(_Symbol, PERIOD_M5, 14);
   if(handle_atr_m5 == INVALID_HANDLE) return;
   
   ArraySetAsSeries(atr_m5_buffer, true);
   if(CopyBuffer(handle_atr_m5, 0, 0, 1, atr_m5_buffer) < 1) {
      IndicatorRelease(handle_atr_m5);
      return;
   }
   double atr_m5 = atr_m5_buffer[0];
   IndicatorRelease(handle_atr_m5);

   // Proximidad Estructural al POI de H1 medida en múltiplos del ATR, nunca en pips fijos
   double distance_to_poi = MathAbs(current_price - m_poi_price);
   if(distance_to_poi > (atr_m5 * 10.0)) return; 

   // Lectura de Fractales M5 para confirmación de Break of Structure (BOS) de ejecución
   double trigger_high = GetLatestFractalPrice(m_handle_fractals_m5, UPPER_LINE);
   double trigger_low  = GetLatestFractalPrice(m_handle_fractals_m5, LOWER_LINE);
   double close_m5     = iClose(_Symbol, PERIOD_M5, 1);

   // Si ya tenemos una posición del mismo tipo abierta bajo este Magic Number, omitimos entradas consecutivas
   if(PositionsTotal() > 0) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) return;
      }
   }

   // COMPRA: Sesgo alcista, régimen de tendencia y precio rompiendo el máximo fractal reciente en M5
   if(m_macro_bias == 1 && m_current_regime == REGIME_TREND_BULL && close_m5 > trigger_high) {
      double sl = trigger_low - (atr_m5 * 0.15); // Colchón de seguridad adaptativo contra barridos de liquidez
      double sl_dist = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - sl;
      double lots = CalculateAdaptiveLot(sl_dist);
      
      if(lots > 0.0) {
         m_trade.Buy(lots, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), sl, 0.0, InpTradeComment);
      }
   }
   // VENTA: Sesgo bajista, régimen de tendencia y precio rompiendo el mínimo fractal reciente en M5
   else if(m_macro_bias == -1 && m_current_regime == REGIME_TREND_BEAR && close_m5 < trigger_low) {
      double sl = trigger_high + (atr_m5 * 0.15);
      double sl_dist = sl - SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double lots = CalculateAdaptiveLot(sl_dist);
      
      if(lots > 0.0) {
         m_trade.Sell(lots, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), sl, 0.0, InpTradeComment);
      }
   }
}

//+------------------------------------------------------------------+
//| GESTIÓN ACTIVA: TRAILING STOP BASADO ESTRICTAMENTE EN ESTRUCTURA|
//+------------------------------------------------------------------+
void CAdaptiveQuantEA::ManageActivePositions() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double current_sl = PositionGetDouble(POSITION_SL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         double atr_m5_buf[];
         int h_atr = iATR(_Symbol, PERIOD_M5, 14);
         ArraySetAsSeries(atr_m5_buf, true);
         if(CopyBuffer(h_atr, 0, 0, 1, atr_m5_buf) < 1) { IndicatorRelease(h_atr); continue; }
         double atr_m5 = atr_m5_buf[0];
         IndicatorRelease(h_atr);

         if(type == POSITION_TYPE_BUY) {
            double new_structural_sl = GetLatestFractalPrice(m_handle_fractals_m5, LOWER_LINE) - (atr_m5 * 0.15);
            // El stop loss solo se mueve a favor de la operación (Trailing puro de protección estructural)
            if(new_structural_sl > current_sl && SymbolInfoDouble(_Symbol, SYMBOL_BID) - new_structural_sl > atr_m5) {
               m_trade.PositionModify(ticket, NormalizeDouble(new_structural_sl, _Digits), 0.0);
            }
         } 
         else if(type == POSITION_TYPE_SELL) {
            double new_structural_sl = GetLatestFractalPrice(m_handle_fractals_m5, UPPER_LINE) + (atr_m5 * 0.15);
            if((new_structural_sl < current_sl || current_sl == 0.0) && new_structural_sl - SymbolInfoDouble(_Symbol, SYMBOL_ASK) > atr_m5) {
               m_trade.PositionModify(ticket, NormalizeDouble(new_structural_sl, _Digits), 0.0);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| FASE 1 - PREGUNTA 3: CÁLCULO DE RIESGO MONETARIO INTEGRAL         |
//+------------------------------------------------------------------+
double CAdaptiveQuantEA::CalculateAdaptiveLot(double sl_distance) {
   if(sl_distance <= 0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_cash = balance * (InpRiskPercent / 100.0);
   
   // Consultas del entorno en vivo de Exness (Correcto en cuentas Cent, Standard y Raw por construcción)
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double step_vol   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(tick_value <= 0 || tick_size <= 0) return 0.0;

   // Ecuación agnóstica al tipo de contrato o nomenclatura del símbolo
   double points = sl_distance / _Point;
   double point_value = tick_value * (_Point / tick_size);
   double lot = risk_cash / (points * point_value);

   // Normalización estricta bajo los límites operativos impuestos por el servidor de Exness
   lot = MathFloor(lot / step_vol) * step_vol;
   
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   if(lot < min_lot) return 0.0; // El capital es insuficiente para el tamaño estructural del Stop Loss requerido
   if(lot > max_lot) lot = max_lot;

   // Simulación y verificación estricta de margen libre antes de dar la instrucción de envío
   double margin_required;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin_required)) return 0.0;
   if(margin_required > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      Print("[AVISO DE MARGEN] Lote adaptativo recalculado a la baja por margen insuficiente.");
      lot = lot * (AccountInfoDouble(ACCOUNT_MARGIN_FREE) / margin_required) * 0.9;
      lot = MathFloor(lot / step_vol) * step_vol;
   }

   return (lot >= min_lot) ? lot : 0.0;
}

//+------------------------------------------------------------------+
//| AUXILIAR: IMPLEMENTACIÓN EFICIENTE DEL ER DE KAUFMAN             |
//+------------------------------------------------------------------+
double CAdaptiveQuantEA::CalculateKaufmanER(int periods) {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, periods + 1, rates) < periods + 1) return 0.5;

   double net_change = MathAbs(rates[0].close - rates[periods].close);
   double sum_total_changes = 0.0;

   for(int i = 0; i < periods; i++) {
      sum_total_changes += MathAbs(rates[i].close - rates[i+1].close);
   }

   return (sum_total_changes == 0.0) ? 0.0 : net_change / sum_total_changes;
}

//+------------------------------------------------------------------+
//| AUXILIAR: BÚSQUEDA DINÁMICA DE FRACTALES COMPATIBLE CON CACHÉ     |
//+------------------------------------------------------------------+
double CAdaptiveQuantEA::GetLatestFractalPrice(int handle, int fractal_type, int max_bars) {
   double buffer[];
   ArraySetAsSeries(buffer, true);
   
   if(CopyBuffer(handle, fractal_type, 0, max_bars, buffer) > 0) {
      for(int i = 2; i < max_bars; i++) { // Iniciamos en la barra 2 para asegurar la confirmación del fractal nativo
         if(buffer[i] != EMPTY_VALUE && buffer[i] > 0) return buffer[i];
      }
   }
   return (fractal_type == UPPER_LINE) ? 999999.0 : 0.0;
}

//+------------------------------------------------------------------+
//| AUXILIAR: MEDIA MÓVIL DEL SPREAD DINÁMICO                        |
//+------------------------------------------------------------------+
double CAdaptiveQuantEA::GetRollingSpreadAverage() {
   double sum = 0.0;
   int count = 0;
   int size = ArraySize(m_rolling_spread);
   for(int i = 0; i < size; i++) {
      if(m_rolling_spread[i] > 0.0) {
         sum += m_rolling_spread[i];
         count++;
      }
   }
   return (count > 0) ? (sum / double(count)) : (double(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) * _Point);
}

//+------------------------------------------------------------------+
//| CIRCUIT BREAKER INSTITUCIONAL: CONTROL DE DRAWDOWN DIARIO        |
//+------------------------------------------------------------------+
bool CAdaptiveQuantEA::CheckCircuitBreaker() {
   datetime current_day = iTime(_Symbol, PERIOD_D1, 0);
   if(current_day != m_last_day) {
      m_last_day = current_day;
      m_initial_day_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double daily_loss = m_initial_day_balance - current_equity;
   double max_allowed_loss = m_initial_day_balance * (InpMaxDailyDrawdownPercent / 100.0);

   if(daily_loss >= max_allowed_loss) {
      // Desactivación preventiva e inmediata ante eventos de cola o pérdidas extremas intradía
      if(PositionsTotal() > 0) {
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
               m_trade.PositionClose(PositionGetInteger(POSITION_TICKET));
            }
         }
      }
      static bool alert_sent = false;
      if(!alert_sent) {
         Print("[CIRCUIT BREAKER] Detención inmediata. Se ha alcanzado el límite de riesgo diario.");
         alert_sent = true;
      }
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| EVENTOS DE ENTRADA GLOBALES DE METATRADER 5                      |
//+------------------------------------------------------------------+
CAdaptiveQuantEA ea_instance;

int OnInit() {
   if(!ea_instance.Initialize()) return INIT_FAILED;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   // Destructor interno maneja la liberación de handles nativos automáticamente
}

void OnTick() {
   ea_instance.OnTickEngine();
}