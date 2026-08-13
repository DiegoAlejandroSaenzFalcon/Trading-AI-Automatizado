//+------------------------------------------------------------------+
//|                                XAUUSD_LiquidityScalper_EA.mq5    |
//|  Liquidity Scalper - EA multi-timeframe basado en liquidez       |
//|  institucional, estructura de mercado (BOS/CHoCH), Order Blocks  |
//|  y Fair Value Gaps, para XAUUSD intradia/scalping.                |
//|                                                                    |
//|  Arquitectura:                                                    |
//|   H4  -> sesgo direccional macro                                  |
//|   H1  -> mapa de zonas (Order Blocks / Fair Value Gaps)           |
//|   M15 -> ejecucion: swings, pools de liquidez, barridos, BOS/CHoCH|
//|   M5  -> (opcional) afinado del Stop Loss                          |
//|                                                                    |
//|  Diseno sin repintado: toda confirmacion ocurre al CIERRE de vela.|
//|  IMPORTANTE: adjuntar este EA a un grafico en la temporalidad      |
//|  configurada en InpTF_Exec (M15 por defecto).                     |
//+------------------------------------------------------------------+
#property copyright "Liquidity Scalper"
#property version   "2.00"
#property description "EA de liquidez institucional multi-timeframe para XAUUSD. Motor de confluencia (barridos, BOS/CHoCH, Order Blocks, FVG) con capa visual completa, alertas y trading automatico opcional."
#property strict

#include <Trade\Trade.mqh>
#include "LS_Types.mqh"
#include "LS_Utils.mqh"
#include "LS_Structure.mqh"
#include "LS_Patterns.mqh"
#include "LS_Zones.mqh"
#include "LS_Drawing.mqh"
#include "LS_Alerts.mqh"

//======================================================================
//  INPUTS
//======================================================================
input group "================ GENERAL ================"
input bool     InpEnableAutoTrading    = false;           // Activar ejecucion automatica (ademas de senales visuales)
input int      InpMagicNumber          = 20260803;         // Numero magico
input bool     InpShowDashboard        = true;              // Mostrar panel de informacion
input ENUM_DASH_CORNER InpDashCorner   = DASH_TOP_LEFT;     // Posicion del panel

input group "================ TEMPORALIDADES (Multi-Timeframe) ================"
input ENUM_TIMEFRAMES InpTF_Bias  = PERIOD_H4;    // Temporalidad de sesgo macro
input ENUM_TIMEFRAMES InpTF_Zones = PERIOD_H1;    // Temporalidad de mapeo de zonas (OB/FVG)
input ENUM_TIMEFRAMES InpTF_Exec  = PERIOD_M15;   // Temporalidad de ejecucion (adjuntar el EA aqui)
input bool     InpUseM5Refinement = true;          // Afinar el Stop Loss con estructura M5

input group "================ ESTRUCTURA Y SWINGS ================"
input int      InpSwingLookback_Bias = 3;      // Velas a cada lado para swing en temporalidad de sesgo
input int      InpSwingLookback_Exec = 7;      // Velas a cada lado para swing en temporalidad de ejecucion
input int      InpBiasHistoryBars    = 300;    // Velas de sesgo a analizar al iniciar
input int      InpExecHistoryBars    = 1500;   // Velas de ejecucion a analizar al iniciar
input int      InpZonesHistoryBars   = 600;    // Velas de zonas a analizar al iniciar

input group "================ LIQUIDEZ ================"
input double   InpPoolToleranceATRMult = 0.15;  // Tolerancia para agrupar maximos/minimos "iguales" (x ATR)
input int      InpSweepValidityBars    = 3;     // Velas tras el barrido en que la confluencia sigue vigente
input int      InpMaxActivePools       = 30;    // Maximo de pools de liquidez visibles

input group "================ ZONAS (Order Blocks / FVG) ================"
input bool     InpEnableOrderBlocks = true;
input bool     InpEnableFVG         = true;
input double   InpOBImpulseATRMult  = 1.5;      // Impulso minimo (x ATR) para validar un Order Block
input int      InpMaxActiveZones    = 15;       // Maximo de zonas OB/FVG activas simultaneas

input group "================ MOTOR DE SENALES (confluencia) ================"
input int      InpMinSignalScore       = 7;     // Umbral de disparo: bajar=mas frecuencia | subir=mas selectivo
input int      InpSessionStartHour     = 13;    // Inicio ventana de mayor liquidez (hora servidor, ver README)
input int      InpSessionEndHour       = 16;    // Fin ventana de mayor liquidez
input bool     InpRequireSessionWindow = false; // Si TRUE, exige operar solo dentro de la ventana horaria
input int      InpATRPeriod            = 14;

input group "================ GESTION DE RIESGO ================"
input ENUM_LOT_MODE InpLotMode         = LOT_RISK_PERCENT;
input double   InpFixedLot             = 0.01;
input double   InpRiskPercent          = 1.5;    // % de balance arriesgado por operacion (perfil agresivo: 1-2%)
input double   InpSLBufferATRMult      = 0.20;   // Colchon extra del SL mas alla del extremo barrido (x ATR)
input double   InpMinRiskReward        = 1.3;    // R:R minimo si no hay pool opuesto disponible como TP
input bool     InpUseNextPoolAsTP      = true;   // Usar el proximo pool de liquidez opuesto como TP
input double   InpReduceRiskAfterChoch = 0.5;    // Multiplicador de riesgo tras un CHoCH sin BOS confirmatorio
input int      InpMaxSpreadPoints      = 400;    // Spread maximo permitido (puntos) para operar
input int      InpMaxDailyTrades       = 8;      // Maximo de operaciones por dia
input int      InpMaxConcurrentTrades  = 2;      // Maximo de operaciones simultaneas
input double   InpMaxDailyLossPercent  = 4.0;    // Circuit breaker: pausa el EA por el resto del dia

input group "================ VISUAL ================"
input bool     InpShowSwingLabels    = false;   // Etiquetas de precio junto a cada linea (apagado = grafico mas limpio)
input bool     InpShowLiquidityPools = true;
input bool     InpShowZones          = true;
input int      InpMaxActiveLevels    = 20;      // Maximo de niveles de swing activos simultaneos
input int      InpMaxActiveSignals   = 30;
input color    InpBullColor      = clrDodgerBlue;
input color    InpBearColor      = clrCrimson;
input color    InpOBColorDemand  = C'205,230,250';
input color    InpOBColorSupply  = C'250,205,205';
input color    InpFVGColorBull   = C'220,245,220';
input color    InpFVGColorBear   = C'250,230,210';
input color    InpMitigatedColor = clrGainsboro;

input group "================ ALERTAS ================"
input bool     InpAlertPopup     = true;
input bool     InpAlertPush      = false;
input bool     InpAlertEmail     = false;
input bool     InpAlertTelegram  = false;
input string   InpTelegramToken  = "";
input string   InpTelegramChatID = "";

input group "================ LIMPIEZA ================"
input bool     InpDeleteObjectsOnRemove = false; // Borrar todos los dibujos al quitar el EA del grafico

//======================================================================
//  ESTADO GLOBAL
//======================================================================
CTrade g_trade;

string g_objPrefix = "LQS_";
string g_uiPrefix  = "LQS_UI_";

int g_atrHandleBias  = INVALID_HANDLE;
int g_atrHandleZones = INVALID_HANDLE;
int g_atrHandleExec  = INVALID_HANDLE;

StructureState g_structH4;
StructureState g_structM15;

SwingPoint    g_swings[];
LiquidityPool g_pools[];
SDZone        g_zones[];
string        g_signalNames[];

int  g_sweepBarsAgo = -1;
bool g_sweepWasHighPool = false;
int  g_lastSweptPoolTouches = 0;
bool g_awaitingBosConfirm = false;

datetime g_lastBiasBar  = 0;
datetime g_lastZonesBar = 0;
datetime g_lastExecBar  = 0;

double   g_dayStartBalance = 0;
datetime g_currentDay = 0;
int      g_tradesToday = 0;

TradeSignal g_lastSignal;
datetime    g_lastSignalTime = 0;
int         g_digits = 5;

//======================================================================
//  CICLO DE VIDA DEL EA
//======================================================================
int OnInit()
{
   g_digits = (int)_Digits;

   if(InpSwingLookback_Bias < 1 || InpSwingLookback_Exec < 1)
   {
      Print("LiquidityScalper: los lookback de swing deben ser >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMinSignalScore < 1)
   {
      Print("LiquidityScalper: InpMinSignalScore debe ser >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_atrHandleBias  = LS_CreateATRHandle(_Symbol, InpTF_Bias,  InpATRPeriod);
   g_atrHandleZones = LS_CreateATRHandle(_Symbol, InpTF_Zones, InpATRPeriod);
   g_atrHandleExec  = LS_CreateATRHandle(_Symbol, InpTF_Exec,  InpATRPeriod);
   if(g_atrHandleBias==INVALID_HANDLE || g_atrHandleZones==INVALID_HANDLE || g_atrHandleExec==INVALID_HANDLE)
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(30);

   ZeroMemory(g_structH4);
   ZeroMemory(g_structM15);
   g_structH4.bias  = BIAS_NEUTRAL;
   g_structM15.bias = BIAS_NEUTRAL;

   CheckNewDay();
   CreateDashboardControls();
   RecalculateAll();

   EventSetTimer(1);
   Print("LiquidityScalper: inicializado. Sesgo H4=", EnumToString(g_structH4.bias),
         " | Pools=", ArraySize(g_pools), " | Zonas=", ArraySize(g_zones));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, g_uiPrefix);
   if(InpDeleteObjectsOnRemove)
      ClearDataObjects();
   ChartRedraw();
}

void OnTick()
{
   CheckNewDay();

   if(LS_IsNewBar(_Symbol, InpTF_Bias, g_lastBiasBar))
      OnBiasNewBar();

   if(LS_IsNewBar(_Symbol, InpTF_Zones, g_lastZonesBar))
      OnZonesNewBar();

   if(LS_IsNewBar(_Symbol, InpTF_Exec, g_lastExecBar))
      OnExecNewBar();
}

void OnTimer()
{
   UpdateDashboard();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;

   if(sparam == g_uiPrefix+"BTN_RECALC")
   {
      RecalculateAll();
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
   else if(sparam == g_uiPrefix+"BTN_CLEAR")
   {
      ClearDataObjects();
      ArrayResize(g_swings, 0);
      ArrayResize(g_pools, 0);
      ArrayResize(g_zones, 0);
      ArrayResize(g_signalNames, 0);
      ChartRedraw();
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   }
}

//======================================================================
//  RECALCULO COMPLETO (arranque y boton "Recalcular Historial")
//======================================================================
void RecalculateAll()
{
   ClearDataObjects();
   ArrayResize(g_swings, 0);
   ArrayResize(g_pools, 0);
   ArrayResize(g_zones, 0);
   ArrayResize(g_signalNames, 0);
   g_sweepBarsAgo = -1;
   g_awaitingBosConfirm = false;

   double lh, ll; datetime lht, llt;
   g_structH4.bias = LS_BootstrapStructure(_Symbol, InpTF_Bias, InpSwingLookback_Bias, InpBiasHistoryBars, lh, ll, lht, llt);
   g_structH4.lastSwingHigh = lh;  g_structH4.lastSwingLow = ll;
   g_structH4.lastSwingHighTime = lht; g_structH4.lastSwingLowTime = llt;

   g_structM15.bias = LS_BootstrapStructure(_Symbol, InpTF_Exec, InpSwingLookback_Exec, InpExecHistoryBars, lh, ll, lht, llt);
   g_structM15.lastSwingHigh = lh; g_structM15.lastSwingLow = ll;
   g_structM15.lastSwingHighTime = lht; g_structM15.lastSwingLowTime = llt;

   BootstrapExecHistory();
   BootstrapZonesHistory();

   DrawAllPools();
   DrawAllZones();
   UpdateDashboard();
   ChartRedraw();
}

void ClearDataObjects()
{
   ObjectsDeleteAll(0, g_objPrefix+"LVL_");
   ObjectsDeleteAll(0, g_objPrefix+"LBL_");
   ObjectsDeleteAll(0, g_objPrefix+"LQ_");
   ObjectsDeleteAll(0, g_objPrefix+"OB_");
   ObjectsDeleteAll(0, g_objPrefix+"FVG_");
   ObjectsDeleteAll(0, g_objPrefix+"SIG_");
   ObjectsDeleteAll(0, g_objPrefix+"SWEEP_");
}

//======================================================================
//  BOOTSTRAP HISTORICO
//======================================================================
void AddSwingVisual(datetime t, double price, bool isHigh)
{
   int n = ArraySize(g_swings);
   ArrayResize(g_swings, n+1);
   string tag = TimeToString(t, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   g_swings[n].time = t;
   g_swings[n].price = price;
   g_swings[n].isHigh = isHigh;
   g_swings[n].objName = g_objPrefix + "LVL_" + (isHigh?"H_":"L_") + tag;
   g_swings[n].lblName = g_objPrefix + "LBL_" + (isHigh?"H_":"L_") + tag;

   color clr = isHigh ? InpBearColor : InpBullColor;
   LS_DrawLevelLine(g_swings[n].objName, t, price, clr, STYLE_DOT, 1);
   if(InpShowSwingLabels)
      LS_DrawLabel(g_swings[n].lblName, t, price, LS_FormatPrice(price,g_digits), clr, 7, isHigh?ANCHOR_LOWER:ANCHOR_UPPER);

   if(ArraySize(g_swings) > InpMaxActiveLevels)
   {
      ObjectDelete(0, g_swings[0].objName);
      ObjectDelete(0, g_swings[0].lblName);
      for(int i=0;i<ArraySize(g_swings)-1;i++) g_swings[i]=g_swings[i+1];
      ArrayResize(g_swings, ArraySize(g_swings)-1);
   }
}

void BootstrapExecHistory()
{
   int totalBars = Bars(_Symbol, InpTF_Exec);
   int scan = MathMin(InpExecHistoryBars, totalBars - InpSwingLookback_Exec - 2);
   if(scan < InpSwingLookback_Exec+1)
   {
      Print("LiquidityScalper: historial insuficiente en temporalidad de ejecucion");
      return;
   }
   int need = scan + InpSwingLookback_Exec + 2;

   double high[], low[]; datetime tt[];
   ArraySetAsSeries(high,true); ArraySetAsSeries(low,true); ArraySetAsSeries(tt,true);
   if(CopyHigh(_Symbol, InpTF_Exec, 0, need, high) <= 0) return;
   if(CopyLow(_Symbol,  InpTF_Exec, 0, need, low)  <= 0) return;
   if(CopyTime(_Symbol, InpTF_Exec, 0, need, tt)   <= 0) return;

   double atrBuf[];
   ArraySetAsSeries(atrBuf,true);
   if(CopyBuffer(g_atrHandleExec, 0, 0, need, atrBuf) <= 0) return;

   int found = 0;
   for(int i = scan; i >= InpSwingLookback_Exec; i--)
   {
      double atrHere = atrBuf[i];
      if(atrHere <= 0) atrHere = 50*_Point;
      double tolerance = atrHere * InpPoolToleranceATRMult;

      if(LS_IsSwingHighAt(i, high, InpSwingLookback_Exec))
      {
         AddSwingVisual(tt[i], high[i], true);
         LS_BuildLiquidityPool(g_pools, g_objPrefix, tt[i], high[i], true, tolerance, InpMaxActivePools);
         found++;
      }
      if(LS_IsSwingLowAt(i, low, InpSwingLookback_Exec))
      {
         AddSwingVisual(tt[i], low[i], false);
         LS_BuildLiquidityPool(g_pools, g_objPrefix, tt[i], low[i], false, tolerance, InpMaxActivePools);
         found++;
      }
   }
   Print("LiquidityScalper: ", found, " swings detectados en ", scan, " velas de ejecucion (", ArraySize(g_pools), " pools formados)");
}

void BootstrapZonesHistory()
{
   int totalBars = Bars(_Symbol, InpTF_Zones);
   int scan = MathMin(InpZonesHistoryBars, totalBars - 5);
   if(scan < 5) return;
   int need = scan + 3;

   double o[],h[],l[],c[]; datetime tt[];
   ArraySetAsSeries(o,true);ArraySetAsSeries(h,true);ArraySetAsSeries(l,true);ArraySetAsSeries(c,true);ArraySetAsSeries(tt,true);
   if(CopyOpen(_Symbol,InpTF_Zones,0,need,o)<=0) return;
   if(CopyHigh(_Symbol,InpTF_Zones,0,need,h)<=0) return;
   if(CopyLow(_Symbol,InpTF_Zones,0,need,l)<=0) return;
   if(CopyClose(_Symbol,InpTF_Zones,0,need,c)<=0) return;
   if(CopyTime(_Symbol,InpTF_Zones,0,need,tt)<=0) return;

   double atrBuf[];
   ArraySetAsSeries(atrBuf,true);
   if(CopyBuffer(g_atrHandleZones,0,0,need,atrBuf)<=0) return;

   if(InpEnableOrderBlocks)
   {
      for(int i = scan; i >= 1; i--)
         LS_ProcessOrderBlockAt(g_zones, g_objPrefix, i, o,h,l,c,tt, atrBuf[i], InpOBImpulseATRMult, InpMaxActiveZones);
   }

   if(InpEnableFVG)
   {
      for(int i = scan; i >= 1; i--)
      {
         double gapLow, gapHigh;
         if(LS_DetectBullishFVG(l[i], h[i+2], gapLow, gapHigh))
            LS_AddSDZone(g_zones, g_objPrefix, tt[i+1], gapHigh, gapLow, ZONE_FVG, true, InpMaxActiveZones);
         else if(LS_DetectBearishFVG(h[i], l[i+2], gapLow, gapHigh))
            LS_AddSDZone(g_zones, g_objPrefix, tt[i+1], gapHigh, gapLow, ZONE_FVG, false, InpMaxActiveZones);
      }
   }
   Print("LiquidityScalper: zonas H1 detectadas -> ", ArraySize(g_zones), " (Order Blocks + FVG)");
}

//======================================================================
//  MANEJO DE NUEVA VELA POR TEMPORALIDAD
//======================================================================
void OnBiasNewBar()
{
   double h[], l[]; datetime tt[];
   ArraySetAsSeries(h,true); ArraySetAsSeries(l,true); ArraySetAsSeries(tt,true);
   int need = InpSwingLookback_Bias*2 + 2;
   if(CopyHigh(_Symbol,InpTF_Bias,0,need,h)<=0) return;
   if(CopyLow(_Symbol,InpTF_Bias,0,need,l)<=0) return;
   if(CopyTime(_Symbol,InpTF_Bias,0,need,tt)<=0) return;

   int i = InpSwingLookback_Bias;
   if(LS_IsSwingHighAt(i,h,InpSwingLookback_Bias)) LS_UpdateStructureSwing(g_structH4,true,h[i],tt[i]);
   if(LS_IsSwingLowAt(i,l,InpSwingLookback_Bias))  LS_UpdateStructureSwing(g_structH4,false,l[i],tt[i]);

   double lastClose = iClose(_Symbol,InpTF_Bias,1);
   datetime lastT = iTime(_Symbol,InpTF_Bias,1);
   bool brokeUp;
   ENUM_STRUCTURE_EVENT ev = LS_CheckStructureBreak(g_structH4, lastClose, lastT, brokeUp);
   if(ev != STRUCT_NONE)
      Print("LiquidityScalper: [H4] ", EnumToString(ev), " -> sesgo macro ahora ", EnumToString(g_structH4.bias));
}

void OnZonesNewBar()
{
   double o[],h[],l[],c[]; datetime tt[];
   ArraySetAsSeries(o,true);ArraySetAsSeries(h,true);ArraySetAsSeries(l,true);ArraySetAsSeries(c,true);ArraySetAsSeries(tt,true);
   int need = 5;
   if(CopyOpen(_Symbol,InpTF_Zones,0,need,o)<=0) return;
   if(CopyHigh(_Symbol,InpTF_Zones,0,need,h)<=0) return;
   if(CopyLow(_Symbol,InpTF_Zones,0,need,l)<=0) return;
   if(CopyClose(_Symbol,InpTF_Zones,0,need,c)<=0) return;
   if(CopyTime(_Symbol,InpTF_Zones,0,need,tt)<=0) return;
   double atrBuf[]; ArraySetAsSeries(atrBuf,true);
   if(CopyBuffer(g_atrHandleZones,0,0,need,atrBuf)<=0) return;

   if(InpEnableOrderBlocks)
      LS_ProcessOrderBlockAt(g_zones, g_objPrefix, 1, o,h,l,c,tt, atrBuf[1], InpOBImpulseATRMult, InpMaxActiveZones);

   if(InpEnableFVG)
   {
      double gapLow,gapHigh;
      if(LS_DetectBullishFVG(l[1],h[3],gapLow,gapHigh))
         LS_AddSDZone(g_zones, g_objPrefix, tt[2], gapHigh, gapLow, ZONE_FVG, true, InpMaxActiveZones);
      else if(LS_DetectBearishFVG(h[1],l[3],gapLow,gapHigh))
         LS_AddSDZone(g_zones, g_objPrefix, tt[2], gapHigh, gapLow, ZONE_FVG, false, InpMaxActiveZones);
   }
   DrawAllZones();
}

void OnExecNewBar()
{
   double o[],h[],l[],c[]; datetime tt[];
   ArraySetAsSeries(o,true);ArraySetAsSeries(h,true);ArraySetAsSeries(l,true);ArraySetAsSeries(c,true);ArraySetAsSeries(tt,true);
   int need = InpSwingLookback_Exec*2 + 3;
   if(CopyOpen(_Symbol,InpTF_Exec,0,need,o)<=0) return;
   if(CopyHigh(_Symbol,InpTF_Exec,0,need,h)<=0) return;
   if(CopyLow(_Symbol,InpTF_Exec,0,need,l)<=0) return;
   if(CopyClose(_Symbol,InpTF_Exec,0,need,c)<=0) return;
   if(CopyTime(_Symbol,InpTF_Exec,0,need,tt)<=0) return;

   double atrExec = LS_GetATR(g_atrHandleExec,1);
   if(atrExec<=0) atrExec = 50*_Point;
   double tolerance = atrExec*InpPoolToleranceATRMult;

   // 1) Nuevo swing -> pools de liquidez + estructura M15
   int i = InpSwingLookback_Exec;
   if(LS_IsSwingHighAt(i,h,InpSwingLookback_Exec))
   {
      AddSwingVisual(tt[i], h[i], true);
      LS_BuildLiquidityPool(g_pools, g_objPrefix, tt[i], h[i], true, tolerance, InpMaxActivePools);
      LS_UpdateStructureSwing(g_structM15, true, h[i], tt[i]);
   }
   if(LS_IsSwingLowAt(i,l,InpSwingLookback_Exec))
   {
      AddSwingVisual(tt[i], l[i], false);
      LS_BuildLiquidityPool(g_pools, g_objPrefix, tt[i], l[i], false, tolerance, InpMaxActivePools);
      LS_UpdateStructureSwing(g_structM15, false, l[i], tt[i]);
   }

   // 2) Barrido de liquidez sobre la ultima vela cerrada
   int sweptIdx = -1;
   for(int p = ArraySize(g_pools)-1; p>=0; p--)
   {
      if(LS_CheckPoolSweep(g_pools[p], h[1], l[1], c[1]))
      {
         g_pools[p].swept = true;
         g_pools[p].sweepTime = tt[1];
         sweptIdx = p;
         color sweepColor = g_pools[p].isHigh ? InpBearColor : InpBullColor;
         double sweepPrice = g_pools[p].isHigh ? h[1] : l[1];
         string sweepName = g_objPrefix+"SWEEP_"+TimeToString(tt[1],TIME_DATE|TIME_MINUTES|TIME_SECONDS);
         LS_DrawSweepMark(sweepName, tt[1], sweepPrice, sweepColor);
         break;
      }
   }
   if(sweptIdx >= 0)
   {
      g_sweepBarsAgo = 0;
      g_sweepWasHighPool = g_pools[sweptIdx].isHigh;
      g_lastSweptPoolTouches = g_pools[sweptIdx].touches;
   }
   else if(g_sweepBarsAgo >= 0)
   {
      g_sweepBarsAgo++;
      if(g_sweepBarsAgo > InpSweepValidityBars) g_sweepBarsAgo = -1;
   }

   // 3) Ruptura de estructura M15 (BOS / CHoCH)
   bool brokeUp;
   ENUM_STRUCTURE_EVENT ev = LS_CheckStructureBreak(g_structM15, c[1], tt[1], brokeUp);
   if(ev == STRUCT_CHOCH) g_awaitingBosConfirm = true;
   if(ev == STRUCT_BOS)   g_awaitingBosConfirm = false;

   // 4) Mitigacion de zonas H1 (Order Blocks / FVG) con el cierre M15
   LS_UpdateZoneMitigation(g_zones, c[1]);

   // 5) Evaluacion del motor de senales
   EvaluateAndFireSignal(ev, brokeUp, o[1], h[1], l[1], c[1], tt[1], atrExec);

   // 6) Refresco visual
   DrawAllPools();
   DrawAllZones();
}

//======================================================================
//  MOTOR DE SENALES (confluencia)
//======================================================================
void EvaluateAndFireSignal(ENUM_STRUCTURE_EVENT ev, bool brokeUp, double o1, double h1, double l1, double c1,
                            datetime t1, double atrExec)
{
   if(ev == STRUCT_NONE) return;

   bool isBuy = brokeUp;
   bool sweepValid = (g_sweepBarsAgo >= 0 && g_sweepBarsAgo <= InpSweepValidityBars);
   bool hasSweepConfluence = sweepValid && (g_sweepWasHighPool == !isBuy);

   int score = 0;
   string reasons = "";

   if(hasSweepConfluence)
   {
      score += 4;
      reasons += "Barrido+Estructura; ";
      g_sweepBarsAgo = -1; // se consume: evita reutilizar el mismo barrido en otra senal
   }
   else if(ev == STRUCT_BOS)
   {
      score += 2;
      reasons += "Continuacion BOS; ";
   }
   else
   {
      score += 1;
      reasons += "CHoCH sin barrido previo; ";
   }

   if((isBuy && g_structH4.bias==BIAS_BULLISH) || (!isBuy && g_structH4.bias==BIAS_BEARISH))
   {
      score += 2; reasons += "Alineado con sesgo H4; ";
   }
   else if(g_structH4.bias != BIAS_NEUTRAL)
   {
      score -= 1; reasons += "Contra sesgo H4; ";
   }

   if(InpEnableOrderBlocks && LS_PriceTouchedZoneType(g_zones, isBuy, ZONE_ORDER_BLOCK, l1, h1))
   { score += 2; reasons += "Reaccion en Order Block; "; }

   if(InpEnableFVG && LS_PriceTouchedZoneType(g_zones, isBuy, ZONE_FVG, l1, h1))
   { score += 2; reasons += "Relleno de FVG; "; }

   if(hasSweepConfluence && g_lastSweptPoolTouches >= 2)
   { score += 1; reasons += "Pool multi-toque (liquidez genuina); "; }

   bool pattern = isBuy ? LS_IsBullishPinBar(o1,h1,l1,c1) : LS_IsBearishPinBar(o1,h1,l1,c1);
   if(pattern) { score += 1; reasons += "Vela de rechazo; "; }

   bool inSession = LS_IsInHourWindow(t1, InpSessionStartHour, InpSessionEndHour);
   if(inSession) { score += 1; reasons += "Ventana de alta liquidez; "; }
   if(InpRequireSessionWindow && !inSession) return;

   if(score < InpMinSignalScore) return;

   TradeSignal sig;
   sig.time  = t1;
   sig.isBuy = isBuy;
   sig.entry = isBuy ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double slFallback = isBuy ? (l1 - atrExec*InpSLBufferATRMult) : (h1 + atrExec*InpSLBufferATRMult);
   double slFinal = slFallback;
   if(InpUseM5Refinement) RefineStopWithM5(isBuy, slFallback, slFinal);
   sig.sl = slFinal;

   double risk = MathAbs(sig.entry - sig.sl);
   if(risk <= 0) risk = (atrExec>0) ? atrExec : 50*_Point;

   double tp = InpUseNextPoolAsTP ? LS_FindNextPoolTarget(g_pools, isBuy, sig.entry) : 0;
   if(tp <= 0) tp = isBuy ? sig.entry + risk*InpMinRiskReward : sig.entry - risk*InpMinRiskReward;
   sig.tp = tp;
   sig.score = score;
   sig.reasons = reasons;

   FireSignal(sig);
}

//--- Afina el SL usando la estructura de las 3 ultimas velas M5 cerradas (solo si es mas ajustado que el respaldo)
void RefineStopWithM5(bool isBuy, double fallbackSL, double &refinedSL)
{
   if(InpTF_Exec == PERIOD_M1 || InpTF_Exec == PERIOD_M5)
   { refinedSL = fallbackSL; return; } // el TF de ejecucion ya es de resolucion M5 o menor

   double h[], l[];
   ArraySetAsSeries(h,true); ArraySetAsSeries(l,true);
   if(CopyHigh(_Symbol,PERIOD_M5,0,4,h)<=0 || CopyLow(_Symbol,PERIOD_M5,0,4,l)<=0)
   { refinedSL = fallbackSL; return; }

   double extreme = isBuy ? l[1] : h[1];
   for(int k=2;k<=3;k++)
      extreme = isBuy ? MathMin(extreme,l[k]) : MathMax(extreme,h[k]);

   if(isBuy && extreme > fallbackSL)       refinedSL = extreme;
   else if(!isBuy && extreme < fallbackSL) refinedSL = extreme;
   else                                     refinedSL = fallbackSL;
}

void FireSignal(TradeSignal &sig)
{
   string tag = TimeToString(sig.time, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   string sigName = g_objPrefix + "SIG_" + (sig.isBuy?"B_":"S_") + tag;

   LS_DrawSignalArrow(sigName, sig.time, sig.entry, sig.isBuy, InpBullColor, InpBearColor);

   double rr = MathAbs(sig.entry-sig.sl) > 0 ? MathAbs(sig.tp-sig.entry)/MathAbs(sig.entry-sig.sl) : 0;
   string txt = StringFormat("%s (score %d)\nEntrada: %s\nSL: %s\nTP: %s\nR:R 1:%.2f",
                  sig.isBuy?"COMPRA":"VENTA", sig.score,
                  LS_FormatPrice(sig.entry,g_digits), LS_FormatPrice(sig.sl,g_digits), LS_FormatPrice(sig.tp,g_digits), rr);
   LS_DrawLabel(sigName+"_lbl", sig.time, sig.entry, txt, sig.isBuy?InpBullColor:InpBearColor, 8,
                sig.isBuy?ANCHOR_UPPER:ANCHOR_LOWER);

   string alertMsg = StringFormat("%s %s | %s | Score %d | Entrada %s SL %s TP %s (R:R 1:%.2f)\nMotivos: %s",
                        _Symbol, sig.isBuy?"COMPRA":"VENTA", EnumToString(InpTF_Exec), sig.score,
                        LS_FormatPrice(sig.entry,g_digits), LS_FormatPrice(sig.sl,g_digits), LS_FormatPrice(sig.tp,g_digits),
                        rr, sig.reasons);
   LS_SendAllAlerts(alertMsg, InpAlertPopup, InpAlertPush, InpAlertEmail, InpAlertTelegram,
                     InpTelegramToken, InpTelegramChatID, _Symbol);

   int n = ArraySize(g_signalNames);
   ArrayResize(g_signalNames, n+1);
   g_signalNames[n] = sigName;
   if(ArraySize(g_signalNames) > InpMaxActiveSignals)
   {
      ObjectDelete(0, g_signalNames[0]);
      ObjectDelete(0, g_signalNames[0]+"_lbl");
      for(int k=0;k<ArraySize(g_signalNames)-1;k++) g_signalNames[k]=g_signalNames[k+1];
      ArrayResize(g_signalNames, ArraySize(g_signalNames)-1);
   }

   g_lastSignal = sig;
   g_lastSignalTime = sig.time;

   TryExecuteTrade(sig);
}

//======================================================================
//  GESTION DE RIESGO Y EJECUCION
//======================================================================
void CheckNewDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime dayStart = TimeCurrent() - (dt.hour*3600 + dt.min*60 + dt.sec);
   if(dayStart != g_currentDay)
   {
      g_currentDay = dayStart;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_tradesToday = 0;
   }
}

bool DailyLossLimitHit()
{
   if(g_dayStartBalance <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (g_dayStartBalance - equity) / g_dayStartBalance * 100.0;
   return lossPct >= InpMaxDailyLossPercent;
}

int PositionsTotalByMagic()
{
   int count = 0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC)==InpMagicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol)
         count++;
   }
   return count;
}

double CalculateLotSize(double slDistance, double riskMultiplier)
{
   if(InpLotMode == LOT_FIXED) return LS_NormalizeLot(InpFixedLot, _Symbol);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (InpRiskPercent/100.0) * riskMultiplier;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || slDistance <= 0) return LS_NormalizeLot(InpFixedLot, _Symbol);

   double lossPerLot = (slDistance/tickSize) * tickValue;
   if(lossPerLot <= 0) return LS_NormalizeLot(InpFixedLot, _Symbol);

   double lot = riskMoney / lossPerLot;
   return LS_NormalizeLot(lot, _Symbol);
}

void TryExecuteTrade(TradeSignal &sig)
{
   if(!InpEnableAutoTrading) return;
   if(DailyLossLimitHit())
   {
      Print("LiquidityScalper: limite de perdida diaria alcanzado (", InpMaxDailyLossPercent, "%). Trading pausado hasta manana.");
      return;
   }
   if(g_tradesToday >= InpMaxDailyTrades) return;
   if(PositionsTotalByMagic() >= InpMaxConcurrentTrades) return;

   double spread = (SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID)) / _Point;
   if(spread > InpMaxSpreadPoints)
   {
      Print("LiquidityScalper: spread excesivo (", spread, " pts), senal omitida.");
      return;
   }

   double riskMult = g_awaitingBosConfirm ? InpReduceRiskAfterChoch : 1.0;
   double lot = CalculateLotSize(MathAbs(sig.entry - sig.sl), riskMult);

   bool ok;
   string comment = "LiqScalper S"+IntegerToString(sig.score);
   if(sig.isBuy) ok = g_trade.Buy(lot, _Symbol, 0, sig.sl, sig.tp, comment);
   else          ok = g_trade.Sell(lot, _Symbol, 0, sig.sl, sig.tp, comment);

   if(ok) g_tradesToday++;
   else   Print("LiquidityScalper: error al abrir orden -> ", g_trade.ResultRetcodeDescription());
}

//======================================================================
//  DASHBOARD
//======================================================================
string BiasToText(ENUM_BIAS b)
{
   if(b==BIAS_BULLISH) return "ALCISTA";
   if(b==BIAS_BEARISH) return "BAJISTA";
   return "NEUTRAL";
}
color BiasToColor(ENUM_BIAS b)
{
   if(b==BIAS_BULLISH) return InpBullColor;
   if(b==BIAS_BEARISH) return InpBearColor;
   return clrSilver;
}

void CreateDashboardControls()
{
   if(!InpShowDashboard) return;
   int corner = LS_CornerToEnum(InpDashCorner);
   LS_CreatePanelBackground(g_uiPrefix+"PANEL", corner, 10, 10, 270, 235, C'24,26,32', C'115,118,128');
   LS_CreateButton(g_uiPrefix+"BTN_RECALC", "Recalcular Historial", corner, 15, 200, 118, 24, clrDarkSlateGray, clrWhite);
   LS_CreateButton(g_uiPrefix+"BTN_CLEAR", "Limpiar Dibujos", corner, 139, 200, 118, 24, clrDarkSlateGray, clrWhite);
}

void UpdateDashboard()
{
   if(!InpShowDashboard) return;
   int corner = LS_CornerToEnum(InpDashCorner);
   int x = 18, y = 18;

   LS_CreateLabelXY(g_uiPrefix+"T1","LIQUIDITY SCALPER XAUUSD",corner,x,y,clrWhite,9); y+=18;
   LS_CreateLabelXY(g_uiPrefix+"T2",StringFormat("Sesgo H4: %s", BiasToText(g_structH4.bias)),corner,x,y,BiasToColor(g_structH4.bias),9); y+=16;
   LS_CreateLabelXY(g_uiPrefix+"T3",StringFormat("Estructura M15: %s", BiasToText(g_structM15.bias)),corner,x,y,BiasToColor(g_structM15.bias),9); y+=16;

   int activePools=0, sweptPools=0;
   for(int i=0;i<ArraySize(g_pools);i++) if(g_pools[i].swept) sweptPools++; else activePools++;
   int activeZones=0, mitZones=0;
   for(int i=0;i<ArraySize(g_zones);i++) if(g_zones[i].mitigated) mitZones++; else activeZones++;

   LS_CreateLabelXY(g_uiPrefix+"T4",StringFormat("Pools: %d activos / %d barridos", activePools, sweptPools),corner,x,y,clrSilver,9); y+=16;
   LS_CreateLabelXY(g_uiPrefix+"T5",StringFormat("Zonas: %d activas / %d mitigadas", activeZones, mitZones),corner,x,y,clrSilver,9); y+=16;

   double spread = (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/_Point;
   LS_CreateLabelXY(g_uiPrefix+"T6",StringFormat("Spread: %.0f pts (max %d)", spread, InpMaxSpreadPoints),corner,x,y,
                     spread>InpMaxSpreadPoints?InpBearColor:clrSilver,9); y+=16;

   LS_CreateLabelXY(g_uiPrefix+"T7",StringFormat("Auto-Trading: %s", InpEnableAutoTrading?"ACTIVO":"INACTIVO"),corner,x,y,
                     InpEnableAutoTrading?clrOrange:clrGray,9); y+=16;

   LS_CreateLabelXY(g_uiPrefix+"T8",StringFormat("Operaciones hoy: %d / %d", g_tradesToday, InpMaxDailyTrades),corner,x,y,clrSilver,9); y+=16;

   string lastSig = g_lastSignalTime>0 ? StringFormat("%s (score %d)", g_lastSignal.isBuy?"COMPRA":"VENTA", g_lastSignal.score) : "Ninguna";
   LS_CreateLabelXY(g_uiPrefix+"T9","Ultima senal: "+lastSig,corner,x,y,clrSilver,9); y+=16;

   bool inSession = LS_IsInHourWindow(TimeCurrent(), InpSessionStartHour, InpSessionEndHour);
   LS_CreateLabelXY(g_uiPrefix+"T10",StringFormat("Ventana de sesion: %s", inSession?"DENTRO":"fuera"),corner,x,y,
                     inSession?InpBullColor:clrGray,9); y+=16;

   double dailyLossPct = g_dayStartBalance>0 ? (g_dayStartBalance-AccountInfoDouble(ACCOUNT_EQUITY))/g_dayStartBalance*100.0 : 0;
   color lossClr = DailyLossLimitHit()?InpBearColor:clrSilver;
   LS_CreateLabelXY(g_uiPrefix+"T11",StringFormat("Perdida diaria: %.2f%% (limite %.1f%%)", dailyLossPct, InpMaxDailyLossPercent),corner,x,y,lossClr,9);
}

//======================================================================
//  DIBUJO MASIVO
//======================================================================
void DrawAllPools()
{
   if(!InpShowLiquidityPools) return;
   for(int i=0;i<ArraySize(g_pools);i++)
      LS_DrawPool(g_pools[i], g_pools[i].isHigh?InpBearColor:InpBullColor, InpMitigatedColor, InpShowSwingLabels);
}

void DrawAllZones()
{
   if(!InpShowZones) return;
   datetime rightTime = TimeCurrent() + PeriodSeconds(InpTF_Zones)*20;
   for(int i=0;i<ArraySize(g_zones);i++)
      LS_DrawZone(g_zones[i], rightTime, InpOBColorDemand, InpOBColorSupply, InpFVGColorBull, InpFVGColorBear,
                  InpMitigatedColor, InpShowSwingLabels);
}
//+------------------------------------------------------------------+
