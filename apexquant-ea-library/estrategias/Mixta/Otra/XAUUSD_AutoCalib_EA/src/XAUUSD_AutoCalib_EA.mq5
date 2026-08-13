//+------------------------------------------------------------------+
//|                                       XAUUSD_AutoCalib_EA.mq5    |
//|  Expert Advisor de Price Action MTF con Auto-Calibración         |
//|  Dinámica para XAUUSD — Exness (cuentas Real y Cent)             |
//|                                                                    |
//|  RESUMEN DE ARQUITECTURA (ver también los .mqh incluidos):        |
//|    MarketStructure.mqh  -> fractales, volatilidad estructural,   |
//|                             Efficiency Ratio, régimen (por TF)   |
//|    DecisionEngine.mqh   -> combina 6 temporalidades (D1..M1) en  |
//|                             una señal MTF con SL basado en       |
//|                             estructura                            |
//|    RiskManager.mqh      -> lotaje agnóstico al tipo de cuenta +  |
//|                             circuit breaker de drawdown diario   |
//|    ExecutionEngine.mqh  -> CTrade + filtro de spread auto-       |
//|                             calibrado + reintentos + stops level |
//|                                                                    |
//|  IMPORTANTE — LEER ANTES DE USAR:                                 |
//|  Este código fue escrito y revisado fuera de MetaEditor (no hay  |
//|  compilador MQL5 disponible en el entorno donde se generó). No   |
//|  reemplaza: (1) compilar y revisar advertencias en MetaEditor,   |
//|  (2) probar en Strategy Tester con datos reales de Exness sobre  |
//|  varios regímenes de mercado, (3) correr en cuenta demo antes de |
//|  cualquier uso con dinero real. Ver README.md para el checklist. |
//|  Este EA usa heurísticas de análisis técnico cuantitativo         |
//|  defendibles, no una fórmula que "prueba" hacia dónde va el      |
//|  precio — eso no existe. Ninguna auto-calibración elimina el      |
//|  riesgo de pérdida.                                                |
//+------------------------------------------------------------------+
#property copyright "Sistema de Auto-Calibracion Dinamica MTF"
#property version   "1.00"
#property description "EA de Price Action MTF con auto-calibracion de riesgo, estructura y regimen de mercado para XAUUSD en Exness."

#include "MarketStructure.mqh"
#include "RiskManager.mqh"
#include "DecisionEngine.mqh"
#include "ExecutionEngine.mqh"

input group "=== Gestion de Riesgo ==="
input double InpRiskPercent             = 1.0;         // Riesgo por operacion (% del equity)
input double InpMaxDailyDrawdownPercent = 5.0;         // Circuit breaker: drawdown diario maximo (%)
input int    InpMaxSlippagePoints       = 30;          // Desviacion maxima aceptada (puntos)
input long   InpMagicNumber             = 20260710;    // Identificador unico de ordenes del EA

//--- Instancias globales de los motores modulares
CDecisionEngine   g_decisionEngine;
CRiskManager      g_riskManager;
CExecutionEngine  g_execEngine;

//--- Prototipos (definidos al final del archivo)
bool WaitForHistory(string symbol, ENUM_TIMEFRAMES tf, int minBars);
void ManageOpenPosition();

//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringFind(_Symbol, "XAU")<0)
     {
      PrintFormat("Este EA fue disenado especificamente para XAUUSD/XAUUSDc. Simbolo actual: %s", _Symbol);
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpRiskPercent<=0.0 || InpRiskPercent>10.0)
     {
      Print("InpRiskPercent fuera de rango razonable (0-10%). Ajuste el parametro.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // Gestion de historia robusta: verifica que las 6 temporalidades
   // relevantes esten disponibles Y sincronizadas antes de permitir
   // que el EA calcule nada sobre ellas.
   ENUM_TIMEFRAMES requiredTFs[] = {PERIOD_D1, PERIOD_H4, PERIOD_H1, PERIOD_M15, PERIOD_M5, PERIOD_M1};
   for(int i=0; i<ArraySize(requiredTFs); i++)
     {
      if(!WaitForHistory(_Symbol, requiredTFs[i], 120))
        {
         PrintFormat("Historial insuficiente o no sincronizado en %s para %s. Verifique conexion/broker.",
                     EnumToString(requiredTFs[i]), _Symbol);
         return(INIT_FAILED);
        }
     }

   if(!g_decisionEngine.Init(_Symbol))
     {
      Print("Fallo al inicializar el motor de decision MTF.");
      return(INIT_FAILED);
     }

   g_riskManager.Init(_Symbol, InpRiskPercent);
   g_riskManager.InitCircuitBreaker(InpMaxDailyDrawdownPercent);
   g_execEngine.Init(_Symbol, InpMagicNumber, InpMaxSlippagePoints);

   Print("=== XAUUSD Auto-Calib EA inicializado ===");
   Print(g_riskManager.DescribeAccountContext());
   Print("NOTA: este codigo no fue compilado en MetaEditor antes de la entrega. Revise la pestana de errores al compilar.");

   EventSetTimer(5);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   PrintFormat("EA detenido. Razon: %d", reason);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   g_execEngine.SampleSpread();
   g_decisionEngine.Update();

   // Nota de diseno: se asume cuenta en modo netting (una posicion por
   // simbolo), que es el modo por defecto de la mayoria de cuentas MT5
   // retail. No se ha probado en cuentas de hedging con multiples
   // posiciones simultaneas sobre el mismo simbolo.
   ManageOpenPosition();

   if(PositionSelect(_Symbol))
      return; // ya hay una posicion abierta del simbolo; no buscar nueva entrada

   if(g_riskManager.IsCircuitBreakerTripped())
     {
      static datetime lastWarn = 0;
      if(TimeCurrent()-lastWarn > 3600) // no saturar el log
        {
         Print("Circuit breaker activo: drawdown diario maximo alcanzado. Entradas bloqueadas hasta el proximo dia.");
         lastWarn = TimeCurrent();
        }
      return;
     }

   // Gatillo de ejecucion en M1 (Pregunta 4): se evalua una sola vez
   // por vela M1 cerrada, no en cada tick, para no reevaluar la misma
   // decision decenas de veces dentro de la misma vela.
   static datetime lastEvalBar = 0;
   datetime m1Time = iTime(_Symbol, PERIOD_M1, 0);
   if(m1Time==lastEvalBar)
      return;
   lastEvalBar = m1Time;

   TradeSignal sig = g_decisionEngine.Evaluate();
   if(!sig.valid)
      return;

   double slDistance = MathAbs(sig.entryPrice-sig.slPrice);
   double lots = g_riskManager.CalculateLotSize(slDistance);
   if(lots<=0.0)
     {
      Print("Lote calculado invalido (0). Revisar SL/Equity/Simbolo.");
      return;
     }

   ENUM_ORDER_TYPE ot = sig.isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!g_riskManager.HasSufficientMargin(lots, ot, sig.entryPrice))
     {
      Print("Margen libre insuficiente para el lote calculado por riesgo.");
      return;
     }

   if(g_execEngine.ExecuteSignal(sig, lots))
      PrintFormat("Entrada ejecutada: %s | Lotes=%.2f | Entry=%.2f | SL=%.2f | TP=%.2f | %s",
                  sig.isBuy ? "BUY" : "SELL", lots, sig.entryPrice, sig.slPrice, sig.tpPrice, sig.reason);
   else
      PrintFormat("Senal valida pero ejecucion fallida: %s", sig.reason);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   // Watchdog liviano: en sesiones de tick-rate bajo (rollover,
   // festivos) esto mantiene alimentada la muestra de spread y sirve
   // de heartbeat verificable en la pestana "Expertos" del log.
   g_execEngine.SampleSpread();
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
  {
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
      PrintFormat("Transaccion: Deal=%d Symbol=%s TipoDeal=%d Volumen=%.2f Precio=%.2f",
                  (int)trans.deal, trans.symbol, (int)trans.deal_type, trans.volume, trans.price);
  }

//+------------------------------------------------------------------+
//| Espera a que el historial de una temporalidad este disponible Y  |
//| sincronizado antes de permitir que el EA opere sobre el.         |
//+------------------------------------------------------------------+
bool WaitForHistory(string symbol, ENUM_TIMEFRAMES tf, int minBars)
  {
   int tries = 0;
   while(tries<100)
     {
      bool enoughBars = (Bars(symbol, tf) >= minBars);
      bool synced     = (bool)SeriesInfoInteger(symbol, tf, SERIES_SYNCHRONIZED);
      if(enoughBars && synced)
         return true;
      Sleep(50);
      tries++;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Trailing stop estructural: una vez que el precio avanzo al menos |
//| 1x la volatilidad estructural del TF de disparo (M1) desde la    |
//| entrada, el SL se ajusta a 0.75x esa volatilidad detras del      |
//| precio actual. Nunca se afloja, solo se ajusta a favor.          |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(!PositionSelect(_Symbol))
      return;
   if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)
      return;

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double currentSL    = PositionGetDouble(POSITION_SL);
   double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentPrice = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                      : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double vol = g_decisionEngine.GetMicroStructuralVolatility();
   if(vol<=0.0)
      return;

   double advanced = (type==POSITION_TYPE_BUY) ? (currentPrice-openPrice) : (openPrice-currentPrice);
   if(advanced<vol)
      return; // aun no avanzo lo suficiente para justificar mover el SL

   double newSL = (type==POSITION_TYPE_BUY) ? (currentPrice-vol*0.75) : (currentPrice+vol*0.75);
   bool improves = (type==POSITION_TYPE_BUY) ? (newSL>currentSL) : (currentSL==0.0 || newSL<currentSL);
   if(!improves)
      return;

   double tp = PositionGetDouble(POSITION_TP);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_execEngine.ModifyPosition(NormalizeDouble(newSL, digits), tp);
  }
