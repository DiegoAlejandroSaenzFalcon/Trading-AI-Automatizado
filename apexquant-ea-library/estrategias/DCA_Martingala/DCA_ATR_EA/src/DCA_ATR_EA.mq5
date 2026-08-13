//+------------------------------------------------------------------+
//|                                                  DCA_ATR_EA.mq5 |
//|   EA de Distribucion Asimetrica de Ordenes (DCA estructurado)   |
//|   basado en volatilidad dinamica (ATR).                         |
//|                                                                   |
//|   Diseñado para cuenta Standard Cent - Exness (Real, 1:1000)     |
//|   Compatible con XAUUSD, BTCUSD, EURUSD y otros simbolos, ya     |
//|   que TODOS los calculos usan SYMBOL_TRADE_TICK_VALUE /          |
//|   SYMBOL_TRADE_TICK_SIZE / SYMBOL_VOLUME_* leidos del broker en  |
//|   tiempo real (el broker ya entrega TickValue en USC en cuentas  |
//|   Cent, por lo que NO se requiere conversion manual adicional).  |
//+------------------------------------------------------------------+
#property copyright "Arquitectura Cuantitativa MQL5"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== RIESGO Y CAPITAL ==="
input double InpRiskPercent      = 1.0;     // Riesgo total por ciclo (% del Balance)

input group "=== ATR Y DISTANCIAS (Periodo 14) ==="
input int    InpATR_Period       = 14;      // Periodo del ATR
input double InpSL_ATR_Mult      = 4.0;     // SL = Entrada1 +/- (Mult * ATR). DEBE ser > Entry3_ATR_Mult
input double InpEntry2_ATR_Mult  = 2.0;     // Distancia Entrada 2 respecto a Entrada 1 (en ATR)
input double InpEntry3_ATR_Mult  = 3.0;     // Distancia Entrada 3 respecto a Entrada 1 (en ATR)

input group "=== DISTRIBUCION DE VOLUMEN (deben sumar 100) ==="
input double InpEntry1Pct        = 25.0;    // % Entrada 1 (Market)
input double InpEntry2Pct        = 40.0;    // % Entrada 2 (Limit)
input double InpEntry3Pct        = 35.0;    // % Entrada 3 (Limit)

input group "=== SALIDAS (TP / BREAK EVEN) ==="
input double InpRR_Ratio         = 1.5;     // Risk/Reward para el TP dinamico (desde Precio Promedio)
input double InpBE_ATR_Trigger   = 1.0;     // Umbral de ganancia (en ATR) para activar Break Even
input int    InpBE_BufferPoints  = 20;      // Colchon en puntos sobre el precio promedio al mover a BE

input group "=== EJECUCION Y PROTECCION ==="
input int    InpMaxSpreadPoints  = 300;     // Spread maximo (puntos) permitido para abrir Entrada 1
input int    InpSlippagePoints   = 30;      // Desviacion maxima permitida (puntos)
input ulong  InpMagicNumber      = 990011;  // Magic Number del EA
input string InpComment          = "DCA_ATR"; // Prefijo de comentario de las ordenes

input group "=== SEÑAL DE ENTRADA (PLACEHOLDER - reemplazable) ==="
input int    InpEMA_Fast         = 9;       // Periodo EMA rapida
input int    InpEMA_Slow         = 21;      // Periodo EMA lenta

//====================================================================
// ESTRUCTURA DE ESTADO DEL CICLO
//====================================================================
struct SCycle
{
   bool   active;          // true si hay un ciclo en curso
   int    direction;       // 1 = compra, -1 = venta
   double slPrice;         // SL unificado (mismo para las 3 ordenes)
   double entry1Price;     // precio de referencia de la Entrada 1
   double atrAtSignal;     // valor del ATR usado al momento de la señal (fijo para todo el ciclo)
   ulong  ticket1;         // ticket de POSICION de la Entrada 1
   ulong  ticket2;         // ticket de ORDEN pendiente -> luego ticket de POSICION cuando se llena
   ulong  ticket3;         // idem para Entrada 3
   double lot1, lot2, lot3;
   bool   entry2Filled;
   bool   entry3Filled;
   bool   beActivated;
};

SCycle g_cycle;

int g_handleATR      = INVALID_HANDLE;
int g_handleEMAFast  = INVALID_HANDLE;
int g_handleEMASlow  = INVALID_HANDLE;

//====================================================================
// OnInit
//====================================================================
int OnInit()
{
   g_handleATR     = iATR(_Symbol, PERIOD_CURRENT, InpATR_Period);
   g_handleEMAFast = iMA(_Symbol, PERIOD_CURRENT, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow = iMA(_Symbol, PERIOD_CURRENT, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(g_handleATR == INVALID_HANDLE || g_handleEMAFast == INVALID_HANDLE || g_handleEMASlow == INVALID_HANDLE)
   {
      Print("ERROR: no se pudieron crear los handles de indicadores.");
      return(INIT_FAILED);
   }

   // Validacion: los porcentajes de distribucion deben sumar 100%
   if(MathAbs((InpEntry1Pct + InpEntry2Pct + InpEntry3Pct) - 100.0) > 0.001)
   {
      Print("ERROR: InpEntry1Pct + InpEntry2Pct + InpEntry3Pct debe sumar 100.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // Validacion critica de geometria: si el SL no esta suficientemente lejos,
   // la Entrada 3 (o la 2) tendrian distancia negativa/cero al SL, lo cual es
   // matematicamente invalido para el calculo de riesgo.
   if(InpSL_ATR_Mult <= InpEntry3_ATR_Mult)
   {
      Print("ERROR: InpSL_ATR_Mult debe ser mayor que InpEntry3_ATR_Mult (de lo contrario la distancia SL-Entrada3 es <= 0).");
      return(INIT_PARAMETERS_INCORRECT);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol); // respeta el modo de llenado que soporta el broker/simbolo

   ZeroMemory(g_cycle);

   return(INIT_SUCCEEDED);
}

//====================================================================
// OnDeinit
//====================================================================
void OnDeinit(const int reason)
{
   if(g_handleATR != INVALID_HANDLE)     IndicatorRelease(g_handleATR);
   if(g_handleEMAFast != INVALID_HANDLE) IndicatorRelease(g_handleEMAFast);
   if(g_handleEMASlow != INVALID_HANDLE) IndicatorRelease(g_handleEMASlow);
}

//====================================================================
// OnTick - Bucle principal
//====================================================================
void OnTick()
{
   if(!g_cycle.active)
   {
      TryOpenNewCycle();
      return;
   }

   // --- Verificar si el ciclo completo ya termino (todas las posiciones cerradas) ---
   bool pos1Open = PositionSelectByTicket(g_cycle.ticket1);
   bool pos2Open = g_cycle.entry2Filled && PositionSelectByTicket(g_cycle.ticket2);
   bool pos3Open = g_cycle.entry3Filled && PositionSelectByTicket(g_cycle.ticket3);

   if(!pos1Open && !pos2Open && !pos3Open)
   {
      // Seguridad: si quedan ordenes limit pendientes sin llenar, se cancelan
      CancelPendingIfExists(g_cycle.ticket2, g_cycle.entry2Filled);
      CancelPendingIfExists(g_cycle.ticket3, g_cycle.entry3Filled);
      Print("Ciclo finalizado (todas las posiciones cerradas). Reiniciando estado del EA.");
      ResetCycle();
      return;
   }

   // Mientras el ciclo este activo, evaluar Break Even en cada tick
   CheckBreakEven();
}

//====================================================================
// OnTradeTransaction - Detecta el llenado de las ordenes Limit
// (patron recomendado en MT5: evita condiciones de carrera del polling)
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!g_cycle.active) return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;

   long   dealOrder = HistoryDealGetInteger(dealTicket, DEAL_ORDER);
   long   posId     = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   long   dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);

   if((ulong)dealMagic != InpMagicNumber) return;

   if(!g_cycle.entry2Filled && (ulong)dealOrder == g_cycle.ticket2)
   {
      g_cycle.entry2Filled = true;
      g_cycle.ticket2 = (ulong)posId;   // a partir de aqui, ticket2 referencia la POSICION, no la orden
      PrintFormat("[DCA_ATR] Entrada 2 ejecutada. Deal #%I64u -> Posicion #%I64u", dealTicket, posId);
      UpdateAveragePriceAndTP();
   }
   else if(!g_cycle.entry3Filled && (ulong)dealOrder == g_cycle.ticket3)
   {
      g_cycle.entry3Filled = true;
      g_cycle.ticket3 = (ulong)posId;
      PrintFormat("[DCA_ATR] Entrada 3 ejecutada. Deal #%I64u -> Posicion #%I64u", dealTicket, posId);
      UpdateAveragePriceAndTP();
   }
}

//====================================================================
// CheckEntrySignal - PLACEHOLDER modular (cruce EMA9/EMA21)
// El usuario puede reemplazar el contenido de esta funcion por su
// propia logica (Fibonacci, FVG, etc.) sin tocar el resto del EA.
//====================================================================
bool CheckEntrySignal(int &signalDirection)
{
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(g_handleEMAFast, 0, 0, 3, fast) < 3) return false;
   if(CopyBuffer(g_handleEMASlow, 0, 0, 3, slow) < 3) return false;

   // Cruce confirmado usando la vela cerrada (indice 1) para evitar repintado
   if(fast[2] < slow[2] && fast[1] > slow[1])
   {
      signalDirection = 1; // cruce alcista -> compra
      return true;
   }
   if(fast[2] > slow[2] && fast[1] < slow[1])
   {
      signalDirection = -1; // cruce bajista -> venta
      return true;
   }
   return false;
}

//====================================================================
// Utilidades
//====================================================================
double GetATRValue()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_handleATR, 0, 0, 2, buf) < 2) return -1.0;
   return buf[1]; // valor de la vela cerrada
}

double GetSpreadPoints()
{
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

// Normaliza un lote respetando VOLUME_STEP/VOLUME_MIN/VOLUME_MAX del broker.
// Usa MathFloor (nunca redondea hacia arriba) para no exceder el riesgo calculado,
// salvo el caso limite en que el propio minimo del broker obligue a subir el lote.
double NormalizeLot(double lot, double &wasForcedToMin)
{
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double norm = MathFloor(lot / stepVol) * stepVol;

   wasForcedToMin = 0;
   if(norm < minVol)
   {
      wasForcedToMin = minVol - lot; // magnitud del "override" aplicado
      norm = minVol;
   }
   if(norm > maxVol) norm = maxVol;

   // Redondeo de precision segun los decimales del step (evita basura de punto flotante)
   int digits = 0;
   double s = stepVol;
   while(s < 0.999999 && digits < 8) { s *= 10.0; digits++; }
   norm = NormalizeDouble(norm, digits);

   return norm;
}

//====================================================================
// TryOpenNewCycle - Calcula el lotaje y coloca las 3 ordenes del ciclo
//====================================================================
void TryOpenNewCycle()
{
   if(g_cycle.active) return;

   if(GetSpreadPoints() > InpMaxSpreadPoints) return; // proteccion de spread dilatado

   int dir;
   if(!CheckEntrySignal(dir)) return;

   double atr = GetATRValue();
   if(atr <= 0)
   {
      Print("ERROR: ATR invalido, se omite la señal.");
      return;
   }

   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0)
   {
      Print("ERROR: TickValue/TickSize invalidos para el simbolo.");
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry1Price = (dir == 1) ? ask : bid;

   // --- Distancias geometricas (todas positivas si SL_ATR_Mult > Entry3_ATR_Mult) ---
   double slDist = InpSL_ATR_Mult * atr;
   double e2Dist = InpEntry2_ATR_Mult * atr;
   double e3Dist = InpEntry3_ATR_Mult * atr;

   double distSL1 = slDist;          // distancia Entrada1 -> SL
   double distSL2 = slDist - e2Dist; // distancia Entrada2 -> SL (Entrada2 esta MAS CERCA del SL que Entrada1)
   double distSL3 = slDist - e3Dist; // distancia Entrada3 -> SL

   if(distSL2 <= 0 || distSL3 <= 0)
   {
      Print("ERROR: Distancias al SL invalidas para este ATR. Ciclo abortado (revisar InpSL_ATR_Mult).");
      return;
   }

   double slPrice, entry2Price, entry3Price;
   if(dir == 1) // COMPRA
   {
      slPrice     = entry1Price - slDist;
      entry2Price = entry1Price - e2Dist;
      entry3Price = entry1Price - e3Dist;
   }
   else // VENTA
   {
      slPrice     = entry1Price + slDist;
      entry2Price = entry1Price + e2Dist;
      entry3Price = entry1Price + e3Dist;
   }

   // --- Verificar Stops Level minimo del broker para las ordenes Limit ---
   long   stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist  = stopLevelPts * point;
   if(MathAbs(entry1Price - entry2Price) < minStopDist || MathAbs(entry1Price - entry3Price) < minStopDist)
   {
      Print("ERROR: La distancia de las ordenes Limit es menor al Stops Level del broker. Ciclo abortado.");
      return;
   }

   //=================================================================
   // CALCULO MATEMATICO DEL LOTE (nucleo del sistema)
   //
   // RiesgoUSD = V * [ pct1*D1 + pct2*D2 + pct3*D3 ] * (TickValue / TickSize)
   //
   // => V = RiesgoUSD / ( (TickValue/TickSize) * [pct1*D1 + pct2*D2 + pct3*D3] )
   //
   // NOTA CUENTA CENT: SYMBOL_TRADE_TICK_VALUE ya es entregado por el
   // broker en la moneda de la cuenta (USC). No se aplica ninguna
   // conversion manual adicional: el broker resuelve la microestructura.
   //=================================================================
   double pct1 = InpEntry1Pct / 100.0;
   double pct2 = InpEntry2Pct / 100.0;
   double pct3 = InpEntry3Pct / 100.0;

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);

   double moneyPerLotUnit = (pct1 * distSL1 + pct2 * distSL2 + pct3 * distSL3) * (tickValue / tickSize);
   if(moneyPerLotUnit <= 0)
   {
      Print("ERROR: Calculo de riesgo por lote invalido.");
      return;
   }

   double totalVolume = riskMoney / moneyPerLotUnit;

   double lot1raw = totalVolume * pct1;
   double lot2raw = totalVolume * pct2;
   double lot3raw = totalVolume * pct3;

   double f1, f2, f3;
   double lot1 = NormalizeLot(lot1raw, f1);
   double lot2 = NormalizeLot(lot2raw, f2);
   double lot3 = NormalizeLot(lot3raw, f3);

   if(f1 > 0 || f2 > 0 || f3 > 0)
   {
      PrintFormat("ADVERTENCIA: Lotaje calculado (%.5f / %.5f / %.5f) inferior al minimo del broker. "
                  "Se aplico VOLUME_MIN y el riesgo REAL de este ciclo superara el %.2f%% configurado.",
                  lot1raw, lot2raw, lot3raw, InpRiskPercent);
   }

   //=================================================================
   // ENVIO DE ORDENES
   //=================================================================
   bool ok1 = (dir == 1)
              ? trade.Buy(lot1, _Symbol, 0, 0, 0, InpComment + "_1")
              : trade.Sell(lot1, _Symbol, 0, 0, 0, InpComment + "_1");

   if(!ok1)
   {
      PrintFormat("ERROR al abrir Entrada 1: retcode=%d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
   }

   // Obtener el ticket REAL de la posicion (no el de la orden de mercado)
   ulong dealTicket1 = trade.ResultDeal();
   ulong posTicket1  = 0;
   if(HistoryDealSelect(dealTicket1))
      posTicket1 = (ulong)HistoryDealGetInteger(dealTicket1, DEAL_POSITION_ID);

   if(posTicket1 == 0)
   {
      Print("ERROR: no se pudo resolver el ticket de posicion de la Entrada 1. Ciclo abortado.");
      return;
   }

   // Fijar el SL inicial de la Entrada 1 (se abrio sin SL para no depender de precio de ejecucion estimado)
   trade.PositionModify(posTicket1, slPrice, 0);

   // Colocar las ordenes Limit 2 y 3
   ulong ticket2 = 0, ticket3 = 0;
   if(dir == 1)
   {
      if(trade.BuyLimit(lot2, entry2Price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, InpComment + "_2"))
         ticket2 = trade.ResultOrder();
      if(trade.BuyLimit(lot3, entry3Price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, InpComment + "_3"))
         ticket3 = trade.ResultOrder();
   }
   else
   {
      if(trade.SellLimit(lot2, entry2Price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, InpComment + "_2"))
         ticket2 = trade.ResultOrder();
      if(trade.SellLimit(lot3, entry3Price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, InpComment + "_3"))
         ticket3 = trade.ResultOrder();
   }

   if(ticket2 == 0 || ticket3 == 0)
      Print("ADVERTENCIA: alguna orden Limit (Entrada 2/3) no pudo colocarse. El ciclo continua solo con las ordenes exitosas.");

   // --- Registrar el estado del ciclo ---
   g_cycle.active        = true;
   g_cycle.direction     = dir;
   g_cycle.slPrice       = slPrice;
   g_cycle.entry1Price   = entry1Price;
   g_cycle.atrAtSignal   = atr;
   g_cycle.ticket1       = posTicket1;
   g_cycle.ticket2       = ticket2;
   g_cycle.ticket3       = ticket3;
   g_cycle.lot1 = lot1; g_cycle.lot2 = lot2; g_cycle.lot3 = lot3;
   g_cycle.entry2Filled  = false;
   g_cycle.entry3Filled  = false;
   g_cycle.beActivated   = false;

   PrintFormat("[DCA_ATR] Ciclo abierto. Dir=%s | Lotes=%.5f/%.5f/%.5f | SL=%.5f | ATR=%.5f",
               (dir==1?"BUY":"SELL"), lot1, lot2, lot3, slPrice, atr);

   UpdateAveragePriceAndTP();
}

//====================================================================
// UpdateAveragePriceAndTP - Recalcula el precio promedio y el TP
// dinamico, y sincroniza SL/TP en todas las posiciones del ciclo.
//====================================================================
void UpdateAveragePriceAndTP()
{
   double sumVolPrice = 0, sumVol = 0;

   if(PositionSelectByTicket(g_cycle.ticket1))
   {
      sumVolPrice += PositionGetDouble(POSITION_VOLUME) * PositionGetDouble(POSITION_PRICE_OPEN);
      sumVol      += PositionGetDouble(POSITION_VOLUME);
   }
   if(g_cycle.entry2Filled && PositionSelectByTicket(g_cycle.ticket2))
   {
      sumVolPrice += PositionGetDouble(POSITION_VOLUME) * PositionGetDouble(POSITION_PRICE_OPEN);
      sumVol      += PositionGetDouble(POSITION_VOLUME);
   }
   if(g_cycle.entry3Filled && PositionSelectByTicket(g_cycle.ticket3))
   {
      sumVolPrice += PositionGetDouble(POSITION_VOLUME) * PositionGetDouble(POSITION_PRICE_OPEN);
      sumVol      += PositionGetDouble(POSITION_VOLUME);
   }

   if(sumVol <= 0) return;

   double avgPrice = sumVolPrice / sumVol;

   // TP dinamico = Precio Promedio +/- (distancia Promedio->SL) * RR
   double slDist = MathAbs(avgPrice - g_cycle.slPrice);
   double tp = (g_cycle.direction == 1) ? avgPrice + slDist * InpRR_Ratio
                                         : avgPrice - slDist * InpRR_Ratio;

   ModifyIfOpen(g_cycle.ticket1, g_cycle.slPrice, tp);
   if(g_cycle.entry2Filled) ModifyIfOpen(g_cycle.ticket2, g_cycle.slPrice, tp);
   if(g_cycle.entry3Filled) ModifyIfOpen(g_cycle.ticket3, g_cycle.slPrice, tp);
}

void ModifyIfOpen(ulong ticket, double sl, double tp)
{
   if(ticket == 0) return;
   if(!PositionSelectByTicket(ticket)) return;

   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);

   // Solo enviar modificacion si realmente hay un cambio (evita spam de requests)
   if(MathAbs(curSL - sl) > _Point || MathAbs(curTP - tp) > _Point)
      trade.PositionModify(ticket, sl, tp);
}

//====================================================================
// CheckBreakEven - Mueve el SL unificado a break even + colchon
// cuando el precio promedio avanza [InpBE_ATR_Trigger * ATR] a favor.
//====================================================================
void CheckBreakEven()
{
   if(g_cycle.beActivated) return;

   double sumVolPrice = 0, sumVol = 0;
   if(PositionSelectByTicket(g_cycle.ticket1))
   {
      sumVolPrice += PositionGetDouble(POSITION_VOLUME) * PositionGetDouble(POSITION_PRICE_OPEN);
      sumVol      += PositionGetDouble(POSITION_VOLUME);
   }
   if(g_cycle.entry2Filled && PositionSelectByTicket(g_cycle.ticket2))
   {
      sumVolPrice += PositionGetDouble(POSITION_VOLUME) * PositionGetDouble(POSITION_PRICE_OPEN);
      sumVol      += PositionGetDouble(POSITION_VOLUME);
   }
   if(g_cycle.entry3Filled && PositionSelectByTicket(g_cycle.ticket3))
   {
      sumVolPrice += PositionGetDouble(POSITION_VOLUME) * PositionGetDouble(POSITION_PRICE_OPEN);
      sumVol      += PositionGetDouble(POSITION_VOLUME);
   }
   if(sumVol <= 0) return;

   double avgPrice = sumVolPrice / sumVol;
   double currentPrice = (g_cycle.direction == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                    : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitDist = (g_cycle.direction == 1) ? (currentPrice - avgPrice) : (avgPrice - currentPrice);

   if(profitDist >= InpBE_ATR_Trigger * g_cycle.atrAtSignal)
   {
      double buffer = InpBE_BufferPoints * _Point;
      double beSL = (g_cycle.direction == 1) ? avgPrice + buffer : avgPrice - buffer;

      // Solo mover el SL si realmente mejora la proteccion (nunca hacia atras)
      bool improves = (g_cycle.direction == 1) ? (beSL > g_cycle.slPrice) : (beSL < g_cycle.slPrice);
      if(improves)
      {
         g_cycle.slPrice = beSL;
         g_cycle.beActivated = true;
         UpdateAveragePriceAndTP();
         PrintFormat("[DCA_ATR] Break Even activado. Nuevo SL unificado: %.5f", beSL);
      }
   }
}

//====================================================================
// Utilidades de limpieza
//====================================================================
void CancelPendingIfExists(ulong ticket, bool wasFilled)
{
   if(ticket == 0 || wasFilled) return; // si ya se lleno, ticket referencia una posicion, no una orden
   if(OrderSelect(ticket))
      trade.OrderDelete(ticket);
}

void ResetCycle()
{
   ZeroMemory(g_cycle);
}
//+------------------------------------------------------------------+
