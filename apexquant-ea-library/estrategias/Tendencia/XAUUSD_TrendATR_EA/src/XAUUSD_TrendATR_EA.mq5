//+------------------------------------------------------------------+
//|                                        XAUUSD_TrendATR_EA.mq5    |
//|        EA de tendencia (cruce EMA) con gestion de riesgo ATR     |
//|             Optimizado para XAUUSD - Cuentas Cent Exness         |
//+------------------------------------------------------------------+
#property copyright "Alejandro"
#property link      ""
#property version   "1.10"
#property description "EA simple de seguimiento de tendencia (cruce de EMAs) con SL/TP"
#property description "dinamicos basados en ATR y position sizing por % de riesgo via"
#property description "OrderCalcProfit(). Disenado para XAUUSD en cuentas Standard Cent"
#property description "de Exness (ejecucion Market), pero funciona en cualquier broker"
#property description "o simbolo porque nunca se hardcodea el tamano de contrato, el"
#property description "tick value ni la divisa de la cuenta: todo se consulta en runtime."

#include <Trade\Trade.mqh>

//--- Parametros de entrada
input group "=== Estrategia (cruce de EMAs) ==="
input ENUM_TIMEFRAMES InpTimeframe   = PERIOD_M15;  // Timeframe de operacion
input int    InpEMA_Fast             = 9;           // Periodo EMA rapida
input int    InpEMA_Slow             = 21;          // Periodo EMA lenta
input bool   InpUseTrendFilter       = true;        // Usar filtro de tendencia
input int    InpEMA_Trend            = 200;         // Periodo EMA de tendencia (filtro)

input group "=== Gestion de riesgo (ATR) ==="
input double InpRiskPercent          = 1.0;         // Riesgo por operacion (% del balance)
input int    InpATR_Period           = 14;          // Periodo ATR
input double InpATR_SL_Mult          = 1.5;         // Multiplicador ATR para Stop Loss
input double InpATR_TP_Mult          = 3.0;         // Multiplicador ATR para Take Profit
input ulong  InpSlippage             = 30;          // Desviacion maxima permitida (puntos)

input group "=== Break-even ==="
input bool   InpUseBreakeven         = true;        // Activar Break-even
input double InpBreakevenTrigger     = 1.0;         // Trigger BE (multiplo de distancia SL)
input int    InpBE_BufferPoints      = 20;          // Puntos extra al mover SL a BE

input group "=== Filtros ==="
input bool   InpUseSessionFilter     = true;        // Filtrar por horario (hora servidor)
input int    InpSessionStartHour     = 8;            // Hora inicio sesion (0-23)
input int    InpSessionEndHour       = 20;           // Hora fin sesion (0-23)
input int    InpMaxSpreadPoints      = 350;          // Spread maximo permitido (puntos)

input group "=== General ==="
input ulong  InpMagicNumber          = 20260721;    // Numero magico
input string InpTradeComment         = "TrendATR";  // Comentario de las ordenes

input group "=== Diagnostico / Seguridad [FIX_v1.1] ==="
input bool   InpVerboseLog           = true;        // Registrar detalle de cada decision en el Log
input double InpMaxMarginPercent     = 30.0;        // Maximo % del margen libre por operacion (circuit breaker)

//--- Variables globales
CTrade   trade;
int      g_emaFastHandle, g_emaSlowHandle, g_emaTrendHandle, g_atrHandle;
double   g_emaFastBuf[], g_emaSlowBuf[], g_emaTrendBuf[], g_atrBuf[];
datetime g_lastBarTime;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringFind(_Symbol,"XAU")<0)
      Print("Aviso: este EA esta optimizado para XAUUSD. Simbolo actual: ",_Symbol);

   if(InpEMA_Fast>=InpEMA_Slow || (InpUseTrendFilter && InpEMA_Slow>=InpEMA_Trend))
     {
      Print("Error: los periodos deben cumplir Fast < Slow",(InpUseTrendFilter?" < Trend":""));
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpRiskPercent<=0 || InpRiskPercent>10)
     {
      Print("Error: InpRiskPercent debe estar entre 0 y 10");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_emaFastHandle  = iMA(_Symbol,InpTimeframe,InpEMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   g_emaSlowHandle  = iMA(_Symbol,InpTimeframe,InpEMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   g_emaTrendHandle = iMA(_Symbol,InpTimeframe,InpEMA_Trend,0,MODE_EMA,PRICE_CLOSE);
   g_atrHandle      = iATR(_Symbol,InpTimeframe,InpATR_Period);

   if(g_emaFastHandle==INVALID_HANDLE || g_emaSlowHandle==INVALID_HANDLE ||
      g_emaTrendHandle==INVALID_HANDLE || g_atrHandle==INVALID_HANDLE)
     {
      Print("Error creando handles de indicadores. Codigo: ",GetLastError());
      return(INIT_FAILED);
     }

   ArraySetAsSeries(g_emaFastBuf,true);
   ArraySetAsSeries(g_emaSlowBuf,true);
   ArraySetAsSeries(g_emaTrendBuf,true);
   ArraySetAsSeries(g_atrBuf,true);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(DetectFillingMode());

   g_lastBarTime=0;

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_emaFastHandle!=INVALID_HANDLE)  IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle!=INVALID_HANDLE)  IndicatorRelease(g_emaSlowHandle);
   if(g_emaTrendHandle!=INVALID_HANDLE) IndicatorRelease(g_emaTrendHandle);
   if(g_atrHandle!=INVALID_HANDLE)      IndicatorRelease(g_atrHandle);
   Comment("");
   Print("EA finalizado. Razon: ",reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      Comment("AutoTrading deshabilitado. Active el boton 'AutoTrading' en MT5.");
      return;
     }

   if(InpUseBreakeven)
      ManageBreakeven();

   datetime barTime=iTime(_Symbol,InpTimeframe,0);
   bool isNewBar=(barTime!=g_lastBarTime);

   UpdateDashboard();

   if(!isNewBar) return;
   g_lastBarTime=barTime;

   bool hasPos    = HasOpenPosition();
   bool sessionOk = (!InpUseSessionFilter || IsWithinSession());
   bool spreadOk  = IsSpreadOk();

   if(InpVerboseLog)
      PrintFormat("[FIX_v1.1] %s | PosicionAbierta=%s SesionOk=%s SpreadOk=%s (%d/%d pts) | Balance=%.2f %s",
                  TimeToString(barTime,TIME_DATE|TIME_MINUTES),
                  (hasPos?"S":"N"),(sessionOk?"S":"N"),(spreadOk?"S":"N"),
                  (int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD),InpMaxSpreadPoints,
                  AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoString(ACCOUNT_CURRENCY));

   if(hasPos)    return;
   if(!sessionOk) return;
   if(!spreadOk)  return;

   if(CopyBuffer(g_emaFastHandle,0,0,3,g_emaFastBuf)<3)   return;
   if(CopyBuffer(g_emaSlowHandle,0,0,3,g_emaSlowBuf)<3)   return;
   if(CopyBuffer(g_emaTrendHandle,0,0,3,g_emaTrendBuf)<3) return;
   if(CopyBuffer(g_atrHandle,0,0,3,g_atrBuf)<3)           return;

   double atr=g_atrBuf[1];
   if(atr<=0) return;

   bool crossUp   = (g_emaFastBuf[2]<=g_emaSlowBuf[2]) && (g_emaFastBuf[1]>g_emaSlowBuf[1]);
   bool crossDown = (g_emaFastBuf[2]>=g_emaSlowBuf[2]) && (g_emaFastBuf[1]<g_emaSlowBuf[1]);

   double closePrev = iClose(_Symbol,InpTimeframe,1);
   bool trendUp   = closePrev>g_emaTrendBuf[1];
   bool trendDown = closePrev<g_emaTrendBuf[1];

   bool longSignal  = crossUp   && (!InpUseTrendFilter || trendUp);
   bool shortSignal = crossDown && (!InpUseTrendFilter || trendDown);

   if(InpVerboseLog)
      PrintFormat("[FIX_v1.1] Fast=%.2f Slow=%.2f Trend=%.2f ATR=%.2f | CrossUp=%s CrossDown=%s TrendUp=%s TrendDown=%s | Long=%s Short=%s",
                  g_emaFastBuf[1],g_emaSlowBuf[1],g_emaTrendBuf[1],atr,
                  (crossUp?"S":"N"),(crossDown?"S":"N"),(trendUp?"S":"N"),(trendDown?"S":"N"),
                  (longSignal?"S":"N"),(shortSignal?"S":"N"));

   if(longSignal)
      OpenPosition(ORDER_TYPE_BUY,atr);
   else if(shortSignal)
      OpenPosition(ORDER_TYPE_SELL,atr);
  }

//+------------------------------------------------------------------+
//| Detecta el modo de filling soportado por el broker/simbolo        |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillingMode()
  {
   long filling=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
//| Busca una posicion abierta de este EA en este simbolo             |
//+------------------------------------------------------------------+
bool GetMyPosition(ulong &ticket)
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      ticket=t;
      return true;
     }
   ticket=0;
   return false;
  }

bool HasOpenPosition()
  {
   ulong ticket=0;
   return GetMyPosition(ticket);
  }

//+------------------------------------------------------------------+
//| Calcula el lote segun % de riesgo usando OrderCalcProfit          |
//| Mas fiable que SYMBOL_TRADE_TICK_VALUE (hay bugs reportados en    |
//| varios brokers). Funciona igual sin importar la divisa de cuenta, |
//| incluida la denominacion en centavos (USC) de las cuentas Cent.   |
//+------------------------------------------------------------------+
double CalculateLotSize(ENUM_ORDER_TYPE orderType,double entryPrice,double slPrice)
  {
   double minLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(stepLot<=0) return minLot;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance*InpRiskPercent/100.0;

   double lossPerLot=0;
   if(!OrderCalcProfit(orderType,_Symbol,1.0,entryPrice,slPrice,lossPerLot))
     {
      Print("OrderCalcProfit fallo, error: ",GetLastError());
      return minLot;
     }
   lossPerLot=MathAbs(lossPerLot);

   if(lossPerLot<=0) return minLot;

   double lots=riskMoney/lossPerLot;
   lots=MathFloor(lots/stepLot)*stepLot;
   lots=MathMax(minLot,MathMin(maxLot,lots));

   int lotDigits=(int)MathRound(-MathLog10(stepLot));
   if(lotDigits<0) lotDigits=0;

   return NormalizeDouble(lots,lotDigits);
  }

//+------------------------------------------------------------------+
//| Abre una posicion con SL/TP basados en ATR                        |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE orderType,double atr)
  {
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   double price = (orderType==ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                                               : SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double slDist = atr*InpATR_SL_Mult;
   double tpDist = atr*InpATR_TP_Mult;

   double stopLevelPts = (double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist  = stopLevelPts*point;
   if(slDist<minStopDist) slDist=minStopDist;
   if(tpDist<minStopDist) tpDist=minStopDist;

   double sl,tp;
   if(orderType==ORDER_TYPE_BUY)
     {
      sl=price-slDist;
      tp=price+tpDist;
     }
   else
     {
      sl=price+slDist;
      tp=price-tpDist;
     }

   sl=NormalizeDouble(sl,digits);
   tp=NormalizeDouble(tp,digits);

   double lots=CalculateLotSize(orderType,price,sl);

   // [FIX_v1.1] Circuit breaker: nunca comprometer mas de InpMaxMarginPercent del
   // margen libre en una sola operacion, sin importar lo que haya dado el calculo
   // de riesgo. Esto contiene cualquier caso donde OrderCalcProfit devuelva un
   // valor anomalamente pequeno (spread/tick atipico) y el lote salga inflado.
   double marginNeeded=0;
   if(OrderCalcMargin(orderType,_Symbol,lots,price,marginNeeded) && marginNeeded>0)
     {
      double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      double maxMargin =freeMargin*(InpMaxMarginPercent/100.0);
      if(marginNeeded>maxMargin)
        {
         double stepLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         double minLot =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         double scale=maxMargin/marginNeeded;
         double lotsScaled=MathFloor((lots*scale)/stepLot)*stepLot;
         Print("[FIX_v1.1] ALERTA: lote recortado por limite de margen. ",
               DoubleToString(lots,2)," -> ",DoubleToString(lotsScaled,2),
               " (margen requerido ",DoubleToString(marginNeeded,2),
               ", libre ",DoubleToString(freeMargin,2),")");
         lots=(lotsScaled<minLot) ? 0 : lotsScaled;
        }
     }

   if(lots<=0)
     {
      Print("[FIX_v1.1] Operacion cancelada: lote invalido tras el chequeo de margen.");
      return;
     }

   if(InpVerboseLog)
      Print("[FIX_v1.1] Enviando orden -> ",EnumToString(orderType),
            " | Precio=",DoubleToString(price,digits),
            " SL=",DoubleToString(sl,digits)," TP=",DoubleToString(tp,digits),
            " ATR=",DoubleToString(atr,digits)," Lotes=",DoubleToString(lots,2),
            " MargenReq=",DoubleToString(marginNeeded,2));

   bool ok;
   if(orderType==ORDER_TYPE_BUY)
      ok=trade.Buy(lots,_Symbol,price,sl,tp,InpTradeComment);
   else
      ok=trade.Sell(lots,_Symbol,price,sl,tp,InpTradeComment);

   if(!ok)
     {
      Print("Error al abrir posicion (",EnumToString(orderType),"): ",
            trade.ResultRetcodeDescription()," | Lotes: ",lots);
      return;
     }

   // [FIX_v1.1] Verificacion post-orden: confirmar que la posicion realmente
   // quedo con un Stop Loss valido. Si el broker la abrio sin SL (rechazo
   // silencioso de la proteccion), esto lo deja evidente en el Log en vez de
   // descubrirlo despues como una posicion corriendo sin control.
   ulong posTicket=0;
   if(GetMyPosition(posTicket) && PositionSelectByTicket(posTicket))
     {
      double actualSL=PositionGetDouble(POSITION_SL);
      if(actualSL==0)
         Print("[FIX_v1.1] ALERTA CRITICA: posicion #",posTicket,
               " quedo abierta SIN Stop Loss. Cerrar/proteger manualmente.");
      else if(InpVerboseLog)
         Print("[FIX_v1.1] Posicion #",posTicket," confirmada. SL real=",
               DoubleToString(actualSL,digits));
     }
  }

//+------------------------------------------------------------------+
//| Mueve el SL a break-even una vez alcanzado el trigger              |
//+------------------------------------------------------------------+
void ManageBreakeven()
  {
   ulong ticket=0;
   if(!GetMyPosition(ticket)) return;
   if(!PositionSelectByTicket(ticket)) return;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL     = PositionGetDouble(POSITION_SL);
   double curTP     = PositionGetDouble(POSITION_TP);
   long   posType   = PositionGetInteger(POSITION_TYPE);
   double point     = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int    digits    = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   if(curSL==0 || openPrice==0) return;

   double slDistance   = MathAbs(openPrice-curSL);
   double stopLevelPts = (double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist  = stopLevelPts*point;

   if(posType==POSITION_TYPE_BUY)
     {
      double curPrice   = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double triggerPrc = openPrice+slDistance*InpBreakevenTrigger;
      if(curPrice>=triggerPrc && curSL<openPrice)
        {
         double newSL=openPrice+InpBE_BufferPoints*point;
         if(curPrice-newSL<minStopDist) newSL=curPrice-minStopDist;
         trade.PositionModify(ticket,NormalizeDouble(newSL,digits),curTP);
        }
     }
   else if(posType==POSITION_TYPE_SELL)
     {
      double curPrice   = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double triggerPrc = openPrice-slDistance*InpBreakevenTrigger;
      if(curPrice<=triggerPrc && curSL>openPrice)
        {
         double newSL=openPrice-InpBE_BufferPoints*point;
         if(newSL-curPrice<minStopDist) newSL=curPrice+minStopDist;
         trade.PositionModify(ticket,NormalizeDouble(newSL,digits),curTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Filtro de sesion horaria (hora del servidor del broker)           |
//+------------------------------------------------------------------+
bool IsWithinSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   int hour=dt.hour;

   if(InpSessionStartHour<=InpSessionEndHour)
      return(hour>=InpSessionStartHour && hour<InpSessionEndHour);
   else
      return(hour>=InpSessionStartHour || hour<InpSessionEndHour);
  }

//+------------------------------------------------------------------+
//| Filtro de spread maximo                                           |
//+------------------------------------------------------------------+
bool IsSpreadOk()
  {
   int spread=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   return(spread<=InpMaxSpreadPoints);
  }

//+------------------------------------------------------------------+
//| Panel de estado simple (Comment(), sin objetos graficos = 0 fugas)|
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   string txt="=== EA Trend ATR - "+_Symbol+" ===\n";
   txt+="Posicion abierta: "+(HasOpenPosition()?"SI":"NO")+"\n";
   txt+="Spread actual: "+IntegerToString(SymbolInfoInteger(_Symbol,SYMBOL_SPREAD))+" pts (max "+IntegerToString(InpMaxSpreadPoints)+")\n";
   txt+="Sesion activa: "+(IsWithinSession()?"SI":"NO")+"\n";
   txt+="Balance: "+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2)+" "+AccountInfoString(ACCOUNT_CURRENCY)+"\n";
   txt+="Riesgo/operacion: "+DoubleToString(InpRiskPercent,2)+"%";
   Comment(txt);
  }
//+------------------------------------------------------------------+
