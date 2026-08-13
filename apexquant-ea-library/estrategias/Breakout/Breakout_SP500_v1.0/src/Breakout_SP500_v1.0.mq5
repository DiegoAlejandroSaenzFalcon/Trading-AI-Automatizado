//+------------------------------------------------------------------+
//|                                        Breakout_SP500_v1.0.mq5   |
//|                                                                  |
//|  EA DE RUPTURA (BREAKOUT) PARA S&P 500 - TEMPORALIDAD D1         |
//|  Broker objetivo: Exness (validar contract size / tick value)   |
//|                                                                  |
//|  LOGICA: identica a la validada en Python (backtest 70/30) y en |
//|  el PineScript v6 entregado previamente:                        |
//|    - Canal Donchian de N velas (excluyendo la vela en curso)    |
//|    - Filtro de tendencia: SMA larga desfasada 1 vela             |
//|    - Stop = ATR(simple, no Wilder) x multiplicador               |
//|    - Take profit = distancia del stop x RR (1:2 por defecto)     |
//|    - Sizing = (riesgo% x equity) / distancia al stop en dinero   |
//|      calculado via tick value / tick size (universal, valido    |
//|      para cualquier simbolo con cualquier contract size)         |
//|    - Una sola posicion abierta a la vez, sin piramidar           |
//|    - Freno de circuito semanal a 4R (real, medido por deals)     |
//|                                                                  |
//|  Version: 1.0                                                    |
//+------------------------------------------------------------------+
#property copyright "Diego - Estrategia Breakout SP500"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//+------------------------------------------------------------------+
input group "=== RUPTURA (DONCHIAN) ==="
input int      InpDonchianLen     = 30;      // Longitud canal Donchian
input bool     InpAllowShort      = true;    // Permitir posiciones cortas

input group "=== STOP / TAKE PROFIT ==="
input int      InpATRPeriod       = 14;      // Periodo ATR (media SIMPLE del True Range, no Wilder)
input double   InpATRMultSL       = 2.0;     // Multiplicador ATR para el stop loss
input double   InpRR              = 2.0;     // Ratio Riesgo:Beneficio (TP = distancia_stop * RR)

input group "=== FILTRO DE TENDENCIA ==="
input bool     InpUseTrendFilter  = true;    // Activar filtro de tendencia
input int      InpTrendSMALen     = 100;     // Periodo SMA de tendencia (desfasada 1 vela)

input group "=== GESTION DE RIESGO ==="
input double   InpRiskPercent     = 0.25;    // Riesgo por operacion (% del equity) - INNEGOCIABLE
input double   InpMaxWeeklyLossR  = 4.0;     // Freno semanal en multiplos de R (4R ~ 1%)

input group "=== EJECUCION ==="
input int      InpMagicNumber     = 20260712;// Numero magico
input int      InpSlippagePoints  = 30;      // Slippage maximo permitido (puntos)
input string   InpTradeComment    = "BreakoutSP500_v1.0"; // Comentario de las ordenes

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                                |
//+------------------------------------------------------------------+
CTrade trade;

datetime g_lastBarTime   = 0;     // ultima vela D1 procesada (evita reprocesar la misma vela)
datetime g_weekStart     = 0;     // inicio (lunes 00:00) de la semana de trading actual
double   g_weeklyRealizedR = 0.0; // R acumulado (realizado) en la semana actual
bool     g_weeklyBreakerHit = false; // true si ya se supero el freno semanal

// Mapa manual ticket->riesgo en dinero, para poder calcular el R real al cerrar cada posicion
#define MAX_TRACKED_POS 50
ulong  g_trackTicket[MAX_TRACKED_POS];
double g_trackRisk[MAX_TRACKED_POS];
int    g_trackCount = 0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   ArrayInitialize(g_trackTicket, 0);
   ArrayInitialize(g_trackRisk, 0.0);
   g_trackCount = 0;

   g_weekStart = GetWeekStart(TimeCurrent());
   g_weeklyRealizedR = 0.0;
   g_weeklyBreakerHit = false;

   PrintFormat("Breakout_SP500_v1.0 inicializado. Simbolo=%s Riesgo=%.2f%% RR=1:%.1f DonchianLen=%d ATRxMult=%.1f",
               _Symbol, InpRiskPercent, InpRR, InpDonchianLen, InpATRMultSL);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   PrintFormat("Breakout_SP500_v1.0 detenido. Razon=%d", reason);
  }

//+------------------------------------------------------------------+
//| Devuelve el lunes 00:00 (hora del servidor) de la semana que      |
//| contiene el datetime dado. Usado para resetear el freno semanal. |
//+------------------------------------------------------------------+
datetime GetWeekStart(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   // day_of_week: 0=domingo, 1=lunes, ... 6=sabado
   int daysFromMonday = (dt.day_of_week == 0) ? 6 : (dt.day_of_week - 1);
   datetime dayStart = t - (dt.hour*3600 + dt.min*60 + dt.sec);
   return(dayStart - daysFromMonday*86400);
  }

//+------------------------------------------------------------------+
//| Revisa si ha empezado una nueva semana y, si es asi, resetea el   |
//| freno de circuito y el contador de R semanal.                    |
//+------------------------------------------------------------------+
void CheckWeekRollover()
  {
   datetime currentWeekStart = GetWeekStart(TimeCurrent());
   if(currentWeekStart != g_weekStart)
     {
      PrintFormat("Nueva semana de trading. R realizado semana anterior=%.2fR. Reseteando freno.", g_weeklyRealizedR);
      g_weekStart = currentWeekStart;
      g_weeklyRealizedR = 0.0;
      g_weeklyBreakerHit = false;
     }
  }

//+------------------------------------------------------------------+
//| Detecta si hay una vela D1 nueva desde la ultima procesada.       |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t0 = iTime(_Symbol, PERIOD_D1, 0);
   if(t0 != g_lastBarTime)
     {
      g_lastBarTime = t0;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Calcula el ATR como MEDIA SIMPLE del True Range (NO Wilder/RMA), |
//| exactamente igual que en el backtest de Python y en el Pine.     |
//| signalShift = indice de la vela senal (normalmente 1 = ultima    |
//| vela cerrada). El ATR usa TR desde signalShift hasta             |
//| signalShift+period-1 (period valores), igual que                |
//| tr.rolling(period).mean() en la vela de senal.                   |
//+------------------------------------------------------------------+
double CalculateATRSimple(int period, int signalShift)
  {
   int needed = signalShift + period + 1; // +1 para el close previo del ultimo TR
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   if(CopyHigh(_Symbol, PERIOD_D1, 0, needed, high) < needed)  return(-1.0);
   if(CopyLow(_Symbol, PERIOD_D1, 0, needed, low)   < needed)  return(-1.0);
   if(CopyClose(_Symbol, PERIOD_D1, 0, needed, close) < needed) return(-1.0);

   double sumTR = 0.0;
   for(int k = signalShift; k < signalShift + period; k++)
     {
      double trHL = high[k] - low[k];
      double trHC = MathAbs(high[k] - close[k+1]);
      double trLC = MathAbs(low[k]  - close[k+1]);
      double tr   = MathMax(trHL, MathMax(trHC, trLC));
      sumTR += tr;
     }
   return(sumTR / period);
  }

//+------------------------------------------------------------------+
//| Calcula el canal Donchian (max/min) EXCLUYENDO la vela senal,     |
//| igual que high.shift(1).rolling(N).max() en Python: usa las N    |
//| velas inmediatamente anteriores a la vela de senal.               |
//+------------------------------------------------------------------+
bool CalculateDonchian(int len, int signalShift, double &outHigh, double &outLow)
  {
   int needed = signalShift + len + 1;
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

   if(CopyHigh(_Symbol, PERIOD_D1, 0, needed, high) < needed) return(false);
   if(CopyLow(_Symbol, PERIOD_D1, 0, needed, low)   < needed) return(false);

   double hh = -DBL_MAX;
   double ll = DBL_MAX;
   // rango: indices [signalShift+1 .. signalShift+len]  (N velas ANTES de la vela senal)
   for(int k = signalShift + 1; k <= signalShift + len; k++)
     {
      if(high[k] > hh) hh = high[k];
      if(low[k]  < ll) ll = low[k];
     }
   outHigh = hh;
   outLow  = ll;
   return(true);
  }

//+------------------------------------------------------------------+
//| Calcula la SMA de tendencia desfasada 1 vela respecto a la senal, |
//| igual que Close.rolling(len).mean().shift(1): usa los "len"      |
//| cierres ANTERIORES a la vela de senal (no incluye su propio cierre)|
//+------------------------------------------------------------------+
double CalculateTrendSMA(int len, int signalShift)
  {
   int needed = signalShift + len + 1;
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(_Symbol, PERIOD_D1, 0, needed, close) < needed) return(-1.0);

   double sum = 0.0;
   for(int k = signalShift + 1; k <= signalShift + len; k++)
      sum += close[k];
   return(sum / len);
  }

//+------------------------------------------------------------------+
//| Convierte una distancia de precio (stopDistPrice) y un riesgo en |
//| dinero (riskMoney) en un volumen (lotes) valido para el simbolo, |
//| usando tick value / tick size -> funciona para CUALQUIER simbolo |
//| y contract size (universal), y normaliza a volume step/min/max.  |
//+------------------------------------------------------------------+
double CalculateLotSize(double riskMoney, double stopDistPrice)
  {
   if(stopDistPrice <= 0) return(0.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0)
     {
      Print("ERROR: tick value o tick size invalidos para ", _Symbol);
      return(0.0);
     }

   // dinero de riesgo por 1.0 lote si el precio se mueve stopDistPrice
   double moneyPerLotAtStopDist = (stopDistPrice / tickSize) * tickValue;
   if(moneyPerLotAtStopDist <= 0) return(0.0);

   double rawLots = riskMoney / moneyPerLotAtStopDist;

   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double normLots = MathFloor(rawLots / volStep) * volStep; // redondeo hacia abajo: nunca arriesgar mas de lo calculado
   if(normLots < volMin)
     {
      PrintFormat("AVISO: lote calculado (%.4f) por debajo del minimo del broker (%.4f). No se abre operacion (evita sobre-arriesgar).", rawLots, volMin);
      return(0.0);
     }
   if(normLots > volMax) normLots = volMax;

   return(NormalizeDouble(normLots, 2));
  }

//+------------------------------------------------------------------+
//| Ajusta SL/TP para respetar la distancia minima del broker         |
//| (SYMBOL_TRADE_STOPS_LEVEL). Devuelve true si los niveles finales  |
//| son validos.                                                       |
//+------------------------------------------------------------------+
bool ValidateAndAdjustStops(bool isLong, double refPrice, double &sl, double &tp)
  {
   int stopsLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = stopsLevelPoints * point;

   if(minDist <= 0) return(true); // el broker no impone distancia minima

   if(isLong)
     {
      if((refPrice - sl) < minDist)
        {
         sl = refPrice - minDist;
         PrintFormat("AVISO: SL ajustado al minimo permitido por el broker (%d puntos).", stopsLevelPoints);
        }
      if((tp - refPrice) < minDist)
        {
         tp = refPrice + minDist;
         PrintFormat("AVISO: TP ajustado al minimo permitido por el broker (%d puntos).", stopsLevelPoints);
        }
     }
   else
     {
      if((sl - refPrice) < minDist)
        {
         sl = refPrice + minDist;
         PrintFormat("AVISO: SL ajustado al minimo permitido por el broker (%d puntos).", stopsLevelPoints);
        }
      if((refPrice - tp) < minDist)
        {
         tp = refPrice - minDist;
         PrintFormat("AVISO: TP ajustado al minimo permitido por el broker (%d puntos).", stopsLevelPoints);
        }
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Cuenta las posiciones abiertas por ESTE EA en este simbolo.       |
//+------------------------------------------------------------------+
int CountMyOpenPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Guarda el riesgo en dinero asociado a un ticket de posicion,      |
//| para poder calcular el R real cuando se cierre.                   |
//+------------------------------------------------------------------+
void TrackPositionRisk(ulong ticket, double riskMoney)
  {
   if(g_trackCount >= MAX_TRACKED_POS)
     {
      // desplazar el array si se llena (muy improbable con 1 posicion a la vez)
      for(int i = 1; i < MAX_TRACKED_POS; i++)
        {
         g_trackTicket[i-1] = g_trackTicket[i];
         g_trackRisk[i-1]   = g_trackRisk[i];
        }
      g_trackCount = MAX_TRACKED_POS - 1;
     }
   g_trackTicket[g_trackCount] = ticket;
   g_trackRisk[g_trackCount]   = riskMoney;
   g_trackCount++;
  }

//+------------------------------------------------------------------+
//| Busca el riesgo guardado para un ticket de posicion (position id) |
//+------------------------------------------------------------------+
double PopTrackedRisk(ulong posId)
  {
   for(int i = 0; i < g_trackCount; i++)
     {
      if(g_trackTicket[i] == posId)
        {
         double risk = g_trackRisk[i];
         // eliminar del array (compactar)
         for(int j = i; j < g_trackCount - 1; j++)
           {
            g_trackTicket[j] = g_trackTicket[j+1];
            g_trackRisk[j]   = g_trackRisk[j+1];
           }
         g_trackCount--;
         return(risk);
        }
     }
   return(-1.0); // no encontrado
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction: detecta el cierre de deals de este EA para    |
//| acumular el R REAL realizado en la semana (freno de circuito).    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ulong posId = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                     + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                     + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      double riskMoney = PopTrackedRisk(posId);
      if(riskMoney > 0)
        {
         double rMultiple = profit / riskMoney;
         g_weeklyRealizedR += rMultiple;
         PrintFormat("Posicion %I64u cerrada. PnL=%.2f RiesgoAsociado=%.2f R=%.2f | R semanal acumulado=%.2f",
                     posId, profit, riskMoney, rMultiple, g_weeklyRealizedR);

         if(g_weeklyRealizedR <= -MathAbs(InpMaxWeeklyLossR))
           {
            g_weeklyBreakerHit = true;
            PrintFormat("FRENO DE CIRCUITO SEMANAL ACTIVADO: R semanal=%.2f <= -%.2f. No se abriran nuevas operaciones hasta la proxima semana.",
                        g_weeklyRealizedR, InpMaxWeeklyLossR);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Intenta abrir una operacion (long o short) segun la senal.        |
//+------------------------------------------------------------------+
void TryOpenPosition(bool isLong, double signalClose, double stopDist)
  {
   double tp = isLong ? signalClose + stopDist * InpRR : signalClose - stopDist * InpRR;
   double sl = isLong ? signalClose - stopDist          : signalClose + stopDist;

   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPercent / 100.0);
   double lots = CalculateLotSize(riskMoney, stopDist);
   if(lots <= 0.0)
     {
      Print("No se abre operacion: lote calculado invalido o por debajo del minimo del broker.");
      return;
     }

   double refPrice = isLong ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ValidateAndAdjustStops(isLong, refPrice, sl, tp);

   bool sent;
   if(isLong)
      sent = trade.Buy(lots, _Symbol, 0.0, sl, tp, InpTradeComment);
   else
      sent = trade.Sell(lots, _Symbol, 0.0, sl, tp, InpTradeComment);

   if(sent)
     {
      // localizamos el position id de la posicion recien abierta (unica para este simbolo+magic)
      ulong posId = 0;
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            posId = PositionGetInteger(POSITION_IDENTIFIER);
        }
      if(posId > 0) TrackPositionRisk(posId, riskMoney);

      PrintFormat("%s ABIERTO. Lotes=%.2f SL=%.2f TP=%.2f RiesgoDinero=%.2f (%.2f%% equity)",
                  isLong ? "LONG" : "SHORT", lots, sl, tp, riskMoney, InpRiskPercent);
     }
   else
     {
      PrintFormat("ERROR al enviar orden %s. Codigo=%d Descripcion=%s",
                  isLong ? "LONG" : "SHORT", trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   CheckWeekRollover();

   if(!IsNewBar()) return; // solo actuamos una vez por vela D1 cerrada, igual que el backtest

   // señal evaluada sobre la ULTIMA VELA CERRADA (indice 1). El indice 0 es la vela D1
   // que acaba de abrir - entrar ahora equivale a "entrar en la apertura de la vela siguiente"
   int signalShift = 1;

   if(CountMyOpenPositions() > 0) return; // una sola posicion a la vez, sin piramidar

   if(g_weeklyBreakerHit)
     {
      Print("Freno de circuito semanal activo. Se omite la busqueda de nuevas entradas esta semana.");
      return;
     }

   double atr = CalculateATRSimple(InpATRPeriod, signalShift);
   if(atr <= 0)
     {
      Print("ATR invalido o datos insuficientes. Se omite esta vela.");
      return;
     }

   double donchHigh, donchLow;
   if(!CalculateDonchian(InpDonchianLen, signalShift, donchHigh, donchLow))
     {
      Print("No se pudo calcular el canal Donchian (datos insuficientes).");
      return;
     }

   double trendSMA = -1.0;
   if(InpUseTrendFilter)
     {
      trendSMA = CalculateTrendSMA(InpTrendSMALen, signalShift);
      if(trendSMA <= 0)
        {
         Print("No se pudo calcular la SMA de tendencia (datos insuficientes).");
         return;
        }
     }

   double signalClose = iClose(_Symbol, PERIOD_D1, signalShift);

   bool longSignal  = (signalClose > donchHigh) && (!InpUseTrendFilter || signalClose > trendSMA);
   bool shortSignal  = InpAllowShort && (signalClose < donchLow) && (!InpUseTrendFilter || signalClose < trendSMA);

   double stopDist = atr * InpATRMultSL;
   if(stopDist <= 0) return;

   if(longSignal)
      TryOpenPosition(true, signalClose, stopDist);
   else if(shortSignal)
      TryOpenPosition(false, signalClose, stopDist);
  }
//+------------------------------------------------------------------+
