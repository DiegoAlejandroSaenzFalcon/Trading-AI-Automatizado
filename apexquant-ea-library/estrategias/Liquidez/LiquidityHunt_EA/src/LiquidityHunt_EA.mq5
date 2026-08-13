//+------------------------------------------------------------------+
//|                                          LiquidityHunt_EA.mq5     |
//|         Estrategia de Caza de Liquidez y Fallo de Estructura      |
//|                                     Copyright 2026, Alejandro     |
//+------------------------------------------------------------------+
#property copyright "Alejandro"
#property version   "1.00"
#property description "Caza de Liquidez y Fallo de Estructura: detecta rupturas falsas de PDH, PDL, Maximo y Minimo Asiatico, confirmadas por volumen y patrones de velas (Pin Bar / Envolvente) en M5, dentro de las ventanas de Londres y Nueva York."

#include <Trade\Trade.mqh>

#define PREFIX "LHF_"

//+------------------------------------------------------------------+
//| PARAMETROS DE ENTRADA                                             |
//+------------------------------------------------------------------+
input group "=== SESIONES DE TRADING (Hora de Servidor del Broker) ==="
input int      InpAsianStartHour    = 0;        // Inicio sesion Asiatica
input int      InpAsianEndHour      = 8;        // Fin sesion Asiatica (calculo AH/AL)
input bool     InpTradeLondon       = true;     // Operar en sesion de Londres
input int      InpLondonStartHour   = 9;        // Inicio sesion Londres
input int      InpLondonWindowHrs   = 3;        // Ventana operativa Londres (horas)
input bool     InpTradeNewYork      = true;     // Operar en sesion de Nueva York
input int      InpNewYorkStartHour  = 15;       // Inicio sesion Nueva York
input int      InpNewYorkWindowHrs  = 3;        // Ventana operativa Nueva York (horas)

input group "=== CONFIRMACION DE VOLUMEN ==="
input int      InpVolumeMAPeriod    = 20;       // Periodo de la media de volumen
input double   InpVolumeMultiplier  = 1.5;      // Multiplo minimo sobre la media

input group "=== PATRONES DE VELAS DE RECHAZO ==="
input double   InpPinBarWickRatio   = 2.0;      // Ratio minimo mecha/cuerpo (Pin Bar)
input double   InpPinBarBodyMaxPct  = 35.0;     // Cuerpo maximo como % del rango total

input group "=== GESTION DE RIESGO ==="
input bool     InpUseFixedLot       = false;    // Usar lote fijo (si no, % de riesgo)
input double   InpFixedLotSize      = 0.01;     // Lote fijo
input double   InpRiskPercent       = 1.0;      // Riesgo % del balance por operacion
input int      InpSLBufferPoints    = 100;      // Buffer de Stop Loss en puntos
input int      InpMinSLDistPoints   = 150;      // Distancia MINIMA de SL en puntos (evita SL demasiado ajustado y lotes sobredimensionados)
input double   InpMinRR             = 1.5;      // Relacion Riesgo:Beneficio MINIMA
input double   InpMaxRR             = 4.0;      // Relacion Riesgo:Beneficio MAXIMA (limita un TP demasiado lejano)
input int      InpMaxSpreadPoints   = 300;      // Spread maximo permitido (puntos)
input int      InpSlippage          = 30;       // Slippage maximo permitido (puntos)

input group "=== PROTECCION DE GANANCIAS (Break-even / Trailing Stop) ==="
input bool     InpUseBreakeven        = true;   // Activar movimiento a Break-even
input double   InpBreakevenTriggerR   = 1.0;    // Mover a Break-even al alcanzar N veces el riesgo (1R)
input int      InpBreakevenLockPoints = 20;     // Puntos de beneficio asegurados en Break-even
input bool     InpUseTrailing         = true;   // Activar Trailing Stop
input int      InpTrailStartPoints    = 300;    // Beneficio en puntos para activar el Trailing
input int      InpTrailStepPoints     = 150;    // Distancia del Trailing respecto al precio actual

input group "=== GESTION DE OPERACIONES ==="
input bool     InpOneTradeAtATime   = true;     // Solo una operacion simultanea
input int      InpMaxTradesPerDay   = 4;        // Maximo de operaciones por dia
input ulong    InpMagicNumber       = 20260805; // Numero magico
input string   InpTradeComment      = "LiquidityHunt"; // Comentario de operacion

input group "=== VISUALIZACION EN GRAFICO ==="
input bool     InpShowDashboard     = true;             // Mostrar panel de informacion
input bool     InpShowSessionZones  = true;              // Mostrar lineas de inicio de sesion
input color    InpPDHColor          = clrRed;             // Color linea PDH
input color    InpPDLColor          = clrLimeGreen;       // Color linea PDL
input color    InpAHColor           = clrOrange;          // Color linea AH
input color    InpALColor           = clrDeepSkyBlue;     // Color linea AL

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                                |
//+------------------------------------------------------------------+
CTrade   trade;

double   g_PDH = 0, g_PDL = 0, g_AH = 0, g_AL = 0;
bool     g_PDH_Traded = false, g_PDL_Traded = false, g_AH_Traded = false, g_AL_Traded = false;
datetime g_lastLevelDay = 0;
datetime g_lastBarTime  = 0;
int      g_tradesToday  = 0;

//+------------------------------------------------------------------+
//| EVENTO: INICIALIZACION                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpAsianStartHour<0 || InpAsianStartHour>23 || InpAsianEndHour<0 || InpAsianEndHour>23 || InpAsianStartHour>=InpAsianEndHour)
   {
      Alert("Parametros de sesion Asiatica invalidos.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpLondonStartHour<0 || InpLondonStartHour>23 || InpNewYorkStartHour<0 || InpNewYorkStartHour>23)
   {
      Alert("Horas de sesion Londres/Nueva York invalidas.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpVolumeMAPeriod<=0 || InpPinBarWickRatio<=0 || InpRiskPercent<=0 || InpRiskPercent>100 || InpMinRR<=0)
   {
      Alert("Parametros de riesgo o patrones invalidos.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpSlippage<0 || InpMaxSpreadPoints<0 || InpSLBufferPoints<0)
   {
      Alert("Los parametros en puntos no pueden ser negativos.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints((ulong)InpSlippage);
   ConfigureFillingMode();

   g_lastBarTime  = 0;
   g_lastLevelDay = 0;
   g_tradesToday  = 0;
   g_PDH_Traded = false; g_PDL_Traded = false; g_AH_Traded = false; g_AL_Traded = false;
   g_PDH = 0; g_PDL = 0; g_AH = 0; g_AL = 0;

   CalculateLevels();
   DrawLevels();
   DrawSessionMarkers();

   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   if(dtNow.hour >= InpAsianEndHour)
      g_lastLevelDay = TimeCurrent() - (dtNow.hour*3600 + dtNow.min*60 + dtNow.sec);

   if(Period() != PERIOD_M5)
      Print("Recomendacion: adjunte el EA a un grafico M5. La logica interna procesa velas M5 independientemente del grafico visible.");

   Print("EA 'Caza de Liquidez y Fallo de Estructura' inicializado correctamente en ", _Symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| EVENTO: DESINICIALIZACION                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PREFIX);
}

//+------------------------------------------------------------------+
//| EVENTO: TICK                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageOpenPositions();

   static datetime lastDashboardUpdate = 0;
   if(InpShowDashboard && TimeCurrent() != lastDashboardUpdate)
   {
      UpdateDashboard();
      lastDashboardUpdate = TimeCurrent();
   }

   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime == g_lastBarTime) return;
   g_lastBarTime = currentBarTime;

   UpdateDailyLevels();
   DrawLevels();

   if(!LevelsAreValid()) return;
   if(!IsWithinTradingSession()) return;
   if(InpOneTradeAtATime && CountEAPositions() > 0) return;
   if(g_tradesToday >= InpMaxTradesPerDay) return;

   double spreadPoints = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spreadPoints > InpMaxSpreadPoints) return;

   CheckLevelSignal(g_PDH, true,  g_PDH_Traded, "PDH");
   CheckLevelSignal(g_AH,  true,  g_AH_Traded,  "AH");
   CheckLevelSignal(g_PDL, false, g_PDL_Traded, "PDL");
   CheckLevelSignal(g_AL,  false, g_AL_Traded,  "AL");
}

//+------------------------------------------------------------------+
//| NIVELES: actualizacion diaria                                    |
//+------------------------------------------------------------------+
void UpdateDailyLevels()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayMidnight = TimeCurrent() - (dt.hour*3600 + dt.min*60 + dt.sec);

   if(todayMidnight != g_lastLevelDay && dt.hour >= InpAsianEndHour)
   {
      CalculateLevels();
      DrawSessionMarkers();
      g_lastLevelDay = todayMidnight;
      g_PDH_Traded = false; g_PDL_Traded = false; g_AH_Traded = false; g_AL_Traded = false;
      g_tradesToday = 0;
      Print("Niveles del dia recalculados y contadores reiniciados.");
   }
}

//+------------------------------------------------------------------+
//| NIVELES: calculo de PDH, PDL, AH, AL                              |
//+------------------------------------------------------------------+
void CalculateLevels()
{
   double pdh = iHigh(_Symbol, PERIOD_D1, 1);
   double pdl = iLow(_Symbol, PERIOD_D1, 1);
   if(pdh > 0) g_PDH = pdh;
   if(pdl > 0) g_PDL = pdl;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = InpAsianStartHour; dt.min = 0; dt.sec = 0;
   datetime asianStart = StructToTime(dt);
   dt.hour = InpAsianEndHour; dt.min = 0; dt.sec = 0;
   datetime asianEnd = StructToTime(dt);

   if(asianEnd > asianStart)
   {
      int shiftStart = iBarShift(_Symbol, PERIOD_M5, asianEnd);
      int shiftEnd   = iBarShift(_Symbol, PERIOD_M5, asianStart);

      if(shiftStart >= 0 && shiftEnd >= shiftStart)
      {
         int count   = shiftEnd - shiftStart + 1;
         int idxHigh = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, count, shiftStart);
         int idxLow  = iLowest(_Symbol, PERIOD_M5, MODE_LOW, count, shiftStart);
         if(idxHigh >= 0) g_AH = iHigh(_Symbol, PERIOD_M5, idxHigh);
         if(idxLow  >= 0) g_AL = iLow(_Symbol, PERIOD_M5, idxLow);
      }
   }

   PrintFormat("Niveles actualizados -> PDH:%s PDL:%s AH:%s AL:%s",
               DoubleToString(g_PDH,_Digits), DoubleToString(g_PDL,_Digits),
               DoubleToString(g_AH,_Digits), DoubleToString(g_AL,_Digits));
}

//+------------------------------------------------------------------+
//| NIVELES: validacion                                               |
//+------------------------------------------------------------------+
bool LevelsAreValid()
{
   return (g_PDH>0 && g_PDL>0 && g_AH>0 && g_AL>0 && g_PDH>g_PDL);
}

//+------------------------------------------------------------------+
//| SESION: ventana de trading activa                                 |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;

   bool inLondon = false;
   if(InpTradeLondon)
   {
      int endH = InpLondonStartHour + InpLondonWindowHrs;
      if(endH <= 24)
         inLondon = (h >= InpLondonStartHour && h < endH);
      else
         inLondon = (h >= InpLondonStartHour || h < (endH-24));
   }

   bool inNewYork = false;
   if(InpTradeNewYork)
   {
      int endH = InpNewYorkStartHour + InpNewYorkWindowHrs;
      if(endH <= 24)
         inNewYork = (h >= InpNewYorkStartHour && h < endH);
      else
         inNewYork = (h >= InpNewYorkStartHour || h < (endH-24));
   }

   return (inLondon || inNewYork);
}

//+------------------------------------------------------------------+
//| OPERACIONES: conteo de posiciones propias del EA                  |
//+------------------------------------------------------------------+
int CountEAPositions()
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = total-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| OPERACIONES: Break-even + Trailing Stop de posiciones abiertas    |
//| Evita que una operacion con beneficio flotante grande termine     |
//| revirtiendo hasta el Stop Loss original.                          |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!InpUseBreakeven && !InpUseTrailing) return;

   double point      = _Point;
   int    stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   int total = PositionsTotal();
   for(int i = total-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   posType    = PositionGetInteger(POSITION_TYPE);
      double newSL      = currentSL;

      if(posType == POSITION_TYPE_BUY)
      {
         if(InpUseBreakeven && currentSL>0 && currentSL < openPrice)
         {
            double riskDist = openPrice - currentSL;
            double profit   = bid - openPrice;
            if(riskDist > 0 && profit >= riskDist*InpBreakevenTriggerR)
            {
               double be = openPrice + InpBreakevenLockPoints*point;
               if(be > newSL) newSL = be;
            }
         }
         if(InpUseTrailing)
         {
            double profit = bid - openPrice;
            if(profit > InpTrailStartPoints*point)
            {
               double trailSL = bid - InpTrailStepPoints*point;
               if(trailSL > newSL) newSL = trailSL;
            }
         }
         if(newSL > currentSL && (bid-newSL) >= stopsLevel*point)
         {
            if(trade.PositionModify(ticket, NormalizeDouble(newSL,_Digits), currentTP))
               Print("SL movido (BUY) ticket ", ticket, " -> ", DoubleToString(newSL,_Digits));
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         if(InpUseBreakeven && currentSL>0 && currentSL > openPrice)
         {
            double riskDist = currentSL - openPrice;
            double profit   = openPrice - ask;
            if(riskDist > 0 && profit >= riskDist*InpBreakevenTriggerR)
            {
               double be = openPrice - InpBreakevenLockPoints*point;
               if(be < newSL) newSL = be;
            }
         }
         if(InpUseTrailing)
         {
            double profit = openPrice - ask;
            if(profit > InpTrailStartPoints*point)
            {
               double trailSL = ask + InpTrailStepPoints*point;
               if(trailSL < newSL) newSL = trailSL;
            }
         }
         if(newSL < currentSL && (newSL-ask) >= stopsLevel*point)
         {
            if(trade.PositionModify(ticket, NormalizeDouble(newSL,_Digits), currentTP))
               Print("SL movido (SELL) ticket ", ticket, " -> ", DoubleToString(newSL,_Digits));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OPERACIONES: modo de llenado compatible con el broker             |
//+------------------------------------------------------------------+
void ConfigureFillingMode()
{
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| SENALES: deteccion de Pin Bar / Envolvente en un nivel             |
//+------------------------------------------------------------------+
void CheckLevelSignal(double level, bool isResistance, bool &tradedFlag, string levelName)
{
   if(tradedFlag || level <= 0) return;

   double o1=iOpen(_Symbol,PERIOD_M5,1), h1=iHigh(_Symbol,PERIOD_M5,1), l1=iLow(_Symbol,PERIOD_M5,1), c1=iClose(_Symbol,PERIOD_M5,1);
   double o2=iOpen(_Symbol,PERIOD_M5,2), h2=iHigh(_Symbol,PERIOD_M5,2), l2=iLow(_Symbol,PERIOD_M5,2), c2=iClose(_Symbol,PERIOD_M5,2);

   double body1  = MathAbs(c1-o1);
   double range1 = h1-l1;

   bool   signalFound    = false;
   double patternExtreme = 0;
   double breakoutVolume = 0;
   string patternType    = "";

   // --- 1. Pin Bar (vela unica de rechazo) ---
   if(range1 > 0)
   {
      if(isResistance)
      {
         double upperWick = h1 - MathMax(o1,c1);
         if(h1>level && c1<level && upperWick>=body1*InpPinBarWickRatio && (body1/range1)*100.0<=InpPinBarBodyMaxPct)
         {
            signalFound=true; patternExtreme=h1; breakoutVolume=(double)iVolume(_Symbol,PERIOD_M5,1); patternType="PinBar";
         }
      }
      else
      {
         double lowerWick = MathMin(o1,c1) - l1;
         if(l1<level && c1>level && lowerWick>=body1*InpPinBarWickRatio && (body1/range1)*100.0<=InpPinBarBodyMaxPct)
         {
            signalFound=true; patternExtreme=l1; breakoutVolume=(double)iVolume(_Symbol,PERIOD_M5,1); patternType="PinBar";
         }
      }
   }

   // --- 2. Envolvente (dos velas: ruptura + confirmacion) ---
   if(!signalFound)
   {
      double bodyHigh2 = MathMax(o2,c2);
      double bodyLow2  = MathMin(o2,c2);

      if(isResistance)
      {
         if(h2>level && c1<level && o1>=bodyHigh2 && c1<=bodyLow2 && c1<o1)
         {
            signalFound=true;
            patternExtreme=MathMax(h1,h2);
            breakoutVolume=MathMax((double)iVolume(_Symbol,PERIOD_M5,1),(double)iVolume(_Symbol,PERIOD_M5,2));
            patternType="Engulfing";
         }
      }
      else
      {
         if(l2<level && c1>level && o1<=bodyLow2 && c1>=bodyHigh2 && c1>o1)
         {
            signalFound=true;
            patternExtreme=MathMin(l1,l2);
            breakoutVolume=MathMax((double)iVolume(_Symbol,PERIOD_M5,1),(double)iVolume(_Symbol,PERIOD_M5,2));
            patternType="Engulfing";
         }
      }
   }

   if(!signalFound) return;

   double avgVolume = GetAverageVolume(InpVolumeMAPeriod, 2);
   if(avgVolume<=0 || breakoutVolume < avgVolume*InpVolumeMultiplier)
   {
      PrintFormat("Senal %s en %s descartada por volumen insuficiente (Vol=%.0f Media=%.0f)", patternType, levelName, breakoutVolume, avgVolume);
      return;
   }

   ExecuteSignal(isResistance, level, patternExtreme, levelName, patternType);
   tradedFlag = true;
}

//+------------------------------------------------------------------+
//| SENALES: promedio de volumen (tick volume)                        |
//+------------------------------------------------------------------+
double GetAverageVolume(int period, int startShift)
{
   if(period <= 0) return 0;
   long sum = 0;
   for(int i = startShift; i < startShift+period; i++)
      sum += iVolume(_Symbol, PERIOD_M5, i);
   return (double)sum / period;
}

//+------------------------------------------------------------------+
//| OPERACIONES: ejecucion de la senal confirmada                     |
//+------------------------------------------------------------------+
void ExecuteSignal(bool isSell, double level, double patternExtreme, string levelName, string patternType)
{
   double point       = _Point;
   int    stopsLevel  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int    minStopPts  = stopsLevel + 5;

   double entryPrice, sl, tp;

   if(isSell)
   {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      double rawDist = (patternExtreme + InpSLBufferPoints*point) - entryPrice;
      double slDist  = MathMax(rawDist, (double)InpMinSLDistPoints*point);
      slDist         = MathMax(slDist, minStopPts*point);
      sl = entryPrice + slDist;

      double nextLevel = FindNextLevelBelow(entryPrice);
      double minTPDist = slDist * InpMinRR;
      double maxTPDist = slDist * InpMaxRR;
      double tpDist    = minTPDist;
      if(nextLevel > 0 && (entryPrice-nextLevel) > tpDist) tpDist = entryPrice - nextLevel;
      tpDist = MathMin(tpDist, maxTPDist);
      tp = entryPrice - tpDist;
      if((entryPrice-tp) < minStopPts*point) tp = entryPrice - minStopPts*point;
   }
   else
   {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double rawDist = entryPrice - (patternExtreme - InpSLBufferPoints*point);
      double slDist  = MathMax(rawDist, (double)InpMinSLDistPoints*point);
      slDist         = MathMax(slDist, minStopPts*point);
      sl = entryPrice - slDist;

      double nextLevel = FindNextLevelAbove(entryPrice);
      double minTPDist = slDist * InpMinRR;
      double maxTPDist = slDist * InpMaxRR;
      double tpDist    = minTPDist;
      if(nextLevel > 0 && (nextLevel-entryPrice) > tpDist) tpDist = nextLevel - entryPrice;
      tpDist = MathMin(tpDist, maxTPDist);
      tp = entryPrice + tpDist;
      if((tp-entryPrice) < minStopPts*point) tp = entryPrice + minStopPts*point;
   }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   double slDistancePrice = MathAbs(entryPrice-sl);
   double lots = InpUseFixedLot ? InpFixedLotSize : CalculateLotSize(slDistancePrice, InpRiskPercent);

   string cmt = InpTradeComment+"_"+levelName+"_"+patternType;
   bool sent;
   if(isSell) sent = trade.Sell(lots, _Symbol, 0, sl, tp, cmt);
   else       sent = trade.Buy(lots, _Symbol, 0, sl, tp, cmt);

   uint rc = trade.ResultRetcode();
   if(sent && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_DONE_PARTIAL))
   {
      g_tradesToday++;
      DrawSignalArrow(isSell, entryPrice, levelName, patternType);
      PrintFormat("Operacion ejecutada: %s | Nivel:%s | Patron:%s | Lote:%.2f | SL:%s | TP:%s",
                  isSell?"VENTA":"COMPRA", levelName, patternType, lots,
                  DoubleToString(sl,_Digits), DoubleToString(tp,_Digits));
   }
   else
   {
      PrintFormat("Error al abrir %s en %s. Retcode:%d (%s)",
                  isSell?"VENTA":"COMPRA", levelName, (int)rc, trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| OPERACIONES: siguiente nivel estructural (arriba/abajo)           |
//+------------------------------------------------------------------+
double FindNextLevelBelow(double price)
{
   double best = -1;
   double lv[4] = {g_PDH, g_PDL, g_AH, g_AL};
   for(int i=0;i<4;i++)
      if(lv[i]>0 && lv[i]<price && (best<0 || lv[i]>best))
         best = lv[i];
   return best;
}

double FindNextLevelAbove(double price)
{
   double best = -1;
   double lv[4] = {g_PDH, g_PDL, g_AH, g_AL};
   for(int i=0;i<4;i++)
      if(lv[i]>0 && lv[i]>price && (best<0 || lv[i]<best))
         best = lv[i];
   return best;
}

//+------------------------------------------------------------------+
//| RIESGO: calculo de lote segun % de riesgo (compatible cta. Cent)  |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice, double riskPercent)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(slDistancePrice <= 0 || lotStep <= 0) return minLot;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) balance = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = balance * riskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue<=0 || tickSize<=0) return minLot;

   double lossPerLot = (slDistancePrice/tickSize)*tickValue;
   if(lossPerLot<=0) return minLot;

   double lots = riskAmount/lossPerLot;
   lots = MathFloor(lots/lotStep)*lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   int lotDigits = 2;
   if(lotStep>=0.1) lotDigits=1;
   else if(lotStep<0.01) lotDigits=3;

   return NormalizeDouble(lots, lotDigits);
}

//+------------------------------------------------------------------+
//| VISUAL: lineas de niveles (PDH, PDL, AH, AL)                      |
//+------------------------------------------------------------------+
void DrawLevels()
{
   DrawLevelLine(PREFIX+"PDH", g_PDH, InpPDHColor, "PDH");
   DrawLevelLine(PREFIX+"PDL", g_PDL, InpPDLColor, "PDL");
   DrawLevelLine(PREFIX+"AH",  g_AH,  InpAHColor,  "AH");
   DrawLevelLine(PREFIX+"AL",  g_AL,  InpALColor,  "AL");
}

void DrawLevelLine(string baseName, double price, color clr, string tag)
{
   if(price <= 0) return;
   string lineName = baseName+"_LINE";
   string textName = baseName+"_TEXT";

   if(ObjectFind(0, lineName) < 0)
   {
      ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, lineName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, lineName, OBJPROP_BACK, true);
      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lineName, OBJPROP_HIDDEN, true);
   }
   else
      ObjectSetDouble(0, lineName, OBJPROP_PRICE, price);

   datetime labelTime = TimeCurrent() + PeriodSeconds(PERIOD_M5)*5;
   string   txt = tag+" "+DoubleToString(price,_Digits);

   if(ObjectFind(0, textName) < 0)
   {
      ObjectCreate(0, textName, OBJ_TEXT, 0, labelTime, price);
      ObjectSetInteger(0, textName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, textName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, textName, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, textName, OBJPROP_HIDDEN, true);
   }
   else
      ObjectMove(0, textName, 0, labelTime, price);

   ObjectSetString(0, textName, OBJPROP_TEXT, txt);
}

//+------------------------------------------------------------------+
//| VISUAL: marcadores verticales de apertura de sesion                |
//+------------------------------------------------------------------+
void DrawSessionMarkers()
{
   if(!InpShowSessionZones) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpTradeLondon)
   {
      dt.hour=InpLondonStartHour; dt.min=0; dt.sec=0;
      DrawVLine(PREFIX+"LDN", StructToTime(dt), clrDodgerBlue, "Apertura Londres");
   }
   if(InpTradeNewYork)
   {
      dt.hour=InpNewYorkStartHour; dt.min=0; dt.sec=0;
      DrawVLine(PREFIX+"NY", StructToTime(dt), clrOrangeRed, "Apertura Nueva York");
   }
}

void DrawVLine(string name, datetime t, color clr, string tag)
{
   if(ObjectFind(0,name) < 0)
   {
      ObjectCreate(0, name, OBJ_VLINE, 0, t, 0);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   else
      ObjectMove(0, name, 0, t, 0);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tag);
}

//+------------------------------------------------------------------+
//| VISUAL: flecha de senal ejecutada                                  |
//+------------------------------------------------------------------+
void DrawSignalArrow(bool isSell, double price, string levelName, string patternType)
{
   string name = PREFIX+"SIG_"+levelName+"_"+IntegerToString((int)TimeCurrent());
   ObjectCreate(0, name, isSell?OBJ_ARROW_DOWN:OBJ_ARROW_UP, 0, TimeCurrent(), price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isSell?clrRed:clrLimeGreen);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, levelName+" - "+patternType);
}

//+------------------------------------------------------------------+
//| VISUAL: panel de informacion (dashboard)                          |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   int x=12, y=18, lh=15;

   SetLabel(PREFIX+"D_TTL", "CAZA DE LIQUIDEZ Y FALLO DE ESTRUCTURA", x, y, clrGold, 9, true); y+=lh+3;
   SetLabel(PREFIX+"D_SYM", "Simbolo: "+_Symbol, x, y, clrWhite, 8, false); y+=lh;

   double spr = (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/_Point;
   SetLabel(PREFIX+"D_SPR", "Spread: "+DoubleToString(spr,1)+" pts", x, y, clrSilver, 8, false); y+=lh;

   bool active = IsWithinTradingSession();
   SetLabel(PREFIX+"D_SES", "Sesion: "+(active?"ACTIVA":"INACTIVA"), x, y, active?clrLimeGreen:clrTomato, 8, false); y+=lh+3;

   SetLabel(PREFIX+"D_PDH", "PDH: "+(g_PDH>0?DoubleToString(g_PDH,_Digits):"N/D"), x, y, InpPDHColor, 8, false); y+=lh;
   SetLabel(PREFIX+"D_PDL", "PDL: "+(g_PDL>0?DoubleToString(g_PDL,_Digits):"N/D"), x, y, InpPDLColor, 8, false); y+=lh;
   SetLabel(PREFIX+"D_AH",  "AH:  "+(g_AH>0 ?DoubleToString(g_AH,_Digits):"N/D"),  x, y, InpAHColor,  8, false); y+=lh;
   SetLabel(PREFIX+"D_AL",  "AL:  "+(g_AL>0 ?DoubleToString(g_AL,_Digits):"N/D"),  x, y, InpALColor,  8, false); y+=lh+3;

   SetLabel(PREFIX+"D_TRD", "Operaciones hoy: "+IntegerToString(g_tradesToday)+"/"+IntegerToString(InpMaxTradesPerDay), x, y, clrSilver, 8, false); y+=lh;
   SetLabel(PREFIX+"D_POS", "Posiciones abiertas: "+IntegerToString(CountEAPositions()), x, y, clrSilver, 8, false); y+=lh;
   SetLabel(PREFIX+"D_PROT", "BE:"+(InpUseBreakeven?"ON":"OFF")+"  Trailing:"+(InpUseTrailing?"ON":"OFF"), x, y, clrSilver, 8, false);
}

void SetLabel(string name, string text, int x, int y, color clr, int fontSize, bool bold=false)
{
   if(ObjectFind(0,name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, name, OBJPROP_FONT, bold?"Arial Bold":"Arial");
   }
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}
//+------------------------------------------------------------------+