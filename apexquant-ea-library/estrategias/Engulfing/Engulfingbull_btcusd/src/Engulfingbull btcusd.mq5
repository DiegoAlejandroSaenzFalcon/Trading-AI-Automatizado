//+------------------------------------------------------------------+
//|  EngulfingBull_NY_EA.mq5                                        |
//|  Engulfing Bull NY Session — EA Visual + AutoTrade v2.0         |
//|  Compatible: Demo · Real · Probador de Estrategias (MT5)        |
//|  Estrategia: Engulfing Alcista · Sesión NY · SL/TP basados ATR  |
//+------------------------------------------------------------------+
#property copyright   "EA Profesional MQL5 v2.0"
#property version     "2.00"
#property strict
#property description "Engulfing Bull NY Session — EA con visualización"
#property description "completa del backtest histórico y auto-trading opcional."
#property description " "
#property description "Para activar operaciones reales/demo ajusta Inp_AutoTrade=true."

#include <Trade\Trade.mqh>

//════════════════════════════════════════════════════════════════════
//  ENTRADAS
//════════════════════════════════════════════════════════════════════
input group "━━━━━ ESTRATEGIA ━━━━━"
input int    Inp_ATR_Period = 272;    // Período del ATR
input double Inp_TP_Mult    = 38.4;   // Multiplicador Take Profit (× ATR)
input double Inp_SL_Mult    = 5.0;   // Multiplicador Stop Loss  (× ATR)
input int    Inp_SessStart  = 13;    // Hora inicio sesión NY (UTC)
input int    Inp_SessEnd    = 17;    // Hora fin sesión NY   (UTC)

input group "━━━━━ AUTO-TRADING ━━━━━"
input bool   Inp_AutoTrade  = false; // ← Activar operaciones automáticas
input double Inp_LotSize    = 0.01;  // Tamaño del lote
input ulong  Inp_Magic      = 202501;// Número mágico del EA
input uint   Inp_Slippage   = 100;    // Deslizamiento máximo (puntos)

input group "━━━━━ VISUAL ━━━━━"
input bool   Inp_ShowZone    = true; // Zona sombreada del trade
input bool   Inp_ShowLabels  = true; // Etiquetas TP / SL / Entry
input bool   Inp_ShowTable   = true; // Panel de estadísticas en pantalla
input bool   Inp_ShowCandles = true; // Colorear velas del patrón
input int    Inp_MaxBars     = 5000; // Barras históricas máximas a escanear

//════════════════════════════════════════════════════════════════════
//  CONSTANTES
//════════════════════════════════════════════════════════════════════
#define TABLE_ROWS   18   // Filas del panel (sin contar cabecera)
#define PFX_ZONE     "EBN_Z_"
#define PFX_ENTRY    "EBN_E_"
#define PFX_LTP      "EBN_T_"
#define PFX_LSL      "EBN_S_"
#define PFX_LABEL    "EBN_L_"
#define PFX_RESULT   "EBN_R_"
#define PFX_BODY     "EBN_BD_"
#define PFX_TABLE    "EBN_TB_"

//════════════════════════════════════════════════════════════════════
//  VARIABLES GLOBALES
//════════════════════════════════════════════════════════════════════
CTrade   g_trade;
int      g_atr_handle    = INVALID_HANDLE;
long     g_chart_id      = 0;
datetime g_last_bar_time = 0;
bool     g_hist_done     = false;

// Estadísticas históricas (escaneo de barras pasadas — solo visual/sim)
int    g_hs = 0;   // hist signals
int    g_hw = 0;   // hist wins
int    g_hl = 0;   // hist losses
double g_hp = 0.0; // hist P&L en unidades ATR

// Estadísticas en vivo (trades reales ejecutados por el EA)
int    g_ls = 0;   // live signals
int    g_lw = 0;   // live wins
int    g_ll = 0;   // live losses
double g_lp = 0.0; // live P&L en divisa de la cuenta

// Estado del trade vivo actualmente abierto
bool     g_in_trade     = false;
datetime g_trade_time   = 0;
double   g_trade_ep     = 0.0;
double   g_trade_tp     = 0.0;
double   g_trade_sl     = 0.0;
ulong    g_trade_ticket = 0;

//════════════════════════════════════════════════════════════════════
//  PROTOTIPOS — declarados para que el compilador los resuelva
//════════════════════════════════════════════════════════════════════
void              _ScanHistory();
void              _CheckForSignal();
void              _ManageLiveTrade();
void              _DrawBody(datetime t_bar, double op, double cl,
                            color col, const string sfx);
void              _DrawOpen(datetime te, double ep, double tp, double sl);
void              _DrawClose(datetime t_close, datetime t_entry,
                             double ep, double tp, double sl, bool is_win);
void              _RefreshStatsPanel();
void              _DeleteAllObjects();
string            _TS(datetime t);
ENUM_ORDER_TYPE_FILLING _BestFillingMode();

//════════════════════════════════════════════════════════════════════
//  OnInit
//════════════════════════════════════════════════════════════════════
int OnInit()
  {
   g_chart_id   = ChartID();
   g_atr_handle = iATR(_Symbol, _Period, Inp_ATR_Period);

   if(g_atr_handle == INVALID_HANDLE)
     {
      Print("ERROR: No se pudo inicializar iATR (período=", Inp_ATR_Period, ").");
      return INIT_FAILED;
     }

   // Configurar CTrade
   g_trade.SetExpertMagicNumber(Inp_Magic);
   g_trade.SetDeviationInPoints(Inp_Slippage);
   g_trade.SetTypeFilling(_BestFillingMode());
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // Reset completo de estado y estadísticas
   g_hist_done     = false;
   g_last_bar_time = 0;
   g_in_trade      = false;
   g_trade_ticket  = 0;
   g_hs = g_hw = g_hl = 0;  g_hp = 0.0;
   g_ls = g_lw = g_ll = 0;  g_lp = 0.0;

   _DeleteAllObjects();
   if(Inp_ShowTable) _RefreshStatsPanel();
   ChartRedraw(g_chart_id);
   return INIT_SUCCEEDED;
  }

//════════════════════════════════════════════════════════════════════
//  OnDeinit
//════════════════════════════════════════════════════════════════════
void OnDeinit(const int reason)
  {
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   _DeleteAllObjects();
   ChartRedraw(g_chart_id);
  }

//════════════════════════════════════════════════════════════════════
//  OnTick  —  núcleo del EA
//════════════════════════════════════════════════════════════════════
void OnTick()
  {
   // 1. Escaneo histórico: una sola vez al arrancar
   if(!g_hist_done)
     {
      _ScanHistory();
      g_hist_done = true;
      if(Inp_ShowTable) _RefreshStatsPanel();
      ChartRedraw(g_chart_id);
     }

   // 2. Detectar nueva barra (el resto del tick no nos interesa)
   datetime bar0_time = iTime(_Symbol, _Period, 0);
   if(bar0_time == g_last_bar_time) return;
   g_last_bar_time = bar0_time;

   // 3. Gestionar trade vivo (si AutoTrade activo)
   if(Inp_AutoTrade && g_in_trade)
      _ManageLiveTrade();

   // 4. Buscar señal en barra[1] (última barra CERRADA)
   _CheckForSignal();

   // 5. Refrescar panel de estadísticas
   if(Inp_ShowTable) _RefreshStatsPanel();
   ChartRedraw(g_chart_id);
  }

//════════════════════════════════════════════════════════════════════
//  _ScanHistory
//  Simula todas las operaciones pasadas (máquina de estados: un trade
//  activo a la vez) y dibuja objetos visuales del backtest.
//════════════════════════════════════════════════════════════════════
void _ScanHistory()
  {
   int total_bars = iBars(_Symbol, _Period);
   if(total_bars < Inp_ATR_Period + 3) return;

   // Barras a procesar + margen para acceso [i+1]
   int limit  = MathMin(total_bars - 2, Inp_MaxBars);
   int n_copy = limit + 3;

   // Arrays de precio y ATR (serie: índice 0 = barra más reciente)
   double   arr_o[], arr_h[], arr_l[], arr_c[], arr_atr[];
   datetime arr_t[];
   ArraySetAsSeries(arr_o,   true);
   ArraySetAsSeries(arr_h,   true);
   ArraySetAsSeries(arr_l,   true);
   ArraySetAsSeries(arr_c,   true);
   ArraySetAsSeries(arr_t,   true);
   ArraySetAsSeries(arr_atr, true);

   // Si cualquier copia falla, salir sin error fatal
   if(CopyOpen  (_Symbol, _Period, 0, n_copy, arr_o)   < n_copy) return;
   if(CopyHigh  (_Symbol, _Period, 0, n_copy, arr_h)   < n_copy) return;
   if(CopyLow   (_Symbol, _Period, 0, n_copy, arr_l)   < n_copy) return;
   if(CopyClose (_Symbol, _Period, 0, n_copy, arr_c)   < n_copy) return;
   if(CopyTime  (_Symbol, _Period, 0, n_copy, arr_t)   < n_copy) return;
   if(CopyBuffer(g_atr_handle, 0, 0, n_copy, arr_atr)  <= 0)     return;

   // ─── Máquina de estados: un solo trade simulado a la vez ───
   bool     sim_active = false;
   double   sim_ep = 0.0, sim_tp = 0.0, sim_sl = 0.0;
   datetime sim_te = 0;

   // Iterar de la barra MÁS ANTIGUA (i=limit) a la MÁS RECIENTE (i=1)
   for(int i = limit; i >= 1; i--)
     {
      // Validar ATR disponible
      if(arr_atr[i] <= 0.0 || arr_atr[i] == EMPTY_VALUE) continue;

      // ═══ GESTIONAR TRADE SIMULADO ACTIVO ═══
      if(sim_active)
        {
         bool hit_sl = (arr_l[i] <= sim_sl); // SL evaluado primero (conservador)
         bool hit_tp = (arr_h[i] >= sim_tp);

         if(hit_sl)
           {
            if(Inp_ShowCandles)
               _DrawBody(arr_t[i], arr_o[i], arr_c[i],
                         clrFireBrick, "CL_" + _TS(arr_t[i]));
            _DrawClose(arr_t[i], sim_te, sim_ep, sim_tp, sim_sl, false);
            g_hl++;
            g_hp -= Inp_SL_Mult;
            sim_active = false;
           }
         else if(hit_tp)
           {
            if(Inp_ShowCandles)
               _DrawBody(arr_t[i], arr_o[i], arr_c[i],
                         clrRoyalBlue, "CL_" + _TS(arr_t[i]));
            _DrawClose(arr_t[i], sim_te, sim_ep, sim_tp, sim_sl, true);
            g_hw++;
            g_hp += Inp_TP_Mult;
            sim_active = false;
           }
         // Nota: velas intermedias del trade no se pintan para mantener
         //       el rendimiento (<5 objetos por trade vs miles de velas).
         //       La zona sombreada ya las cubre visualmente.
         continue; // no buscar nueva señal mientras hay trade activo
        }

      // ═══ FILTRO DE SESIÓN NY ═══
      MqlDateTime dc, dp;
      TimeToStruct(arr_t[i],     dc);
      TimeToStruct(arr_t[i + 1], dp);
      if(dc.hour < Inp_SessStart || dc.hour > Inp_SessEnd) continue;
      if(dp.hour < Inp_SessStart || dp.hour > Inp_SessEnd) continue;

      // ═══ PATRÓN ENGULFING ALCISTA ═══
      bool prev_bear = (arr_c[i + 1] < arr_o[i + 1]);
      bool curr_bull = (arr_c[i]     >= arr_o[i]);
      bool engulf    = (arr_o[i] <= arr_c[i + 1])                            &&
                       (arr_c[i] >= arr_o[i + 1])                            &&
                       ((arr_c[i] - arr_o[i]) > (arr_o[i + 1] - arr_c[i + 1]));

      if(!(prev_bear && curr_bull && engulf)) continue;

      // ═══ SEÑAL DETECTADA — abrir trade simulado ═══
      g_hs++;
      sim_active = true;
      sim_ep     = arr_c[i];
      sim_tp     = arr_c[i] + arr_atr[i] * Inp_TP_Mult;
      sim_sl     = arr_c[i] - arr_atr[i] * Inp_SL_Mult;
      sim_te     = arr_t[i];

      // Pintar velas del patrón (bajista anterior + alcista señal)
      if(Inp_ShowCandles)
        {
         _DrawBody(arr_t[i + 1], arr_o[i + 1], arr_c[i + 1],
                   clrFireBrick, "PT_" + _TS(arr_t[i + 1]));
         _DrawBody(arr_t[i], arr_o[i], arr_c[i],
                   clrLime, "PT_" + _TS(arr_t[i]));
        }

      // Objetos de apertura del trade
      _DrawOpen(arr_t[i], sim_ep, sim_tp, sim_sl);
     }
   // Nota: si sim_active al terminar el bucle, el trade quedó sin cierre
   // visible en el historial (puede ser un trade aún en curso).
  }

//════════════════════════════════════════════════════════════════════
//  _CheckForSignal
//  Analiza la barra[1] (última completamente CERRADA) en cada nueva
//  barra. Si hay señal: dibuja objetos, alerta, y opcionalmente opera.
//════════════════════════════════════════════════════════════════════
void _CheckForSignal()
  {
   // Solo un trade vivo a la vez
   if(g_in_trade) return;

   datetime t1 = iTime(_Symbol, _Period, 1);
   datetime t2 = iTime(_Symbol, _Period, 2);
   if(t1 == 0 || t2 == 0) return;

   // Filtro de sesión para barra[1] y barra[2]
   MqlDateTime dt1, dt2;
   TimeToStruct(t1, dt1);
   TimeToStruct(t2, dt2);
   if(dt1.hour < Inp_SessStart || dt1.hour > Inp_SessEnd) return;
   if(dt2.hour < Inp_SessStart || dt2.hour > Inp_SessEnd) return;

   // OHLC barra[1] (alcista actual) y barra[2] (bajista anterior)
   double o1 = iOpen (_Symbol, _Period, 1);
   double h1 = iHigh (_Symbol, _Period, 1);
   double l1 = iLow  (_Symbol, _Period, 1);
   double c1 = iClose(_Symbol, _Period, 1);
   double o2 = iOpen (_Symbol, _Period, 2);
   double c2 = iClose(_Symbol, _Period, 2);

   // ATR de barra[1]
   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_buf) <= 0) return;
   double atr_val = atr_buf[0];
   if(atr_val <= 0.0 || atr_val == EMPTY_VALUE) return;

   // Patrón Engulfing Alcista
   bool prev_bear = (c2 < o2);
   bool curr_bull = (c1 >= o1);
   bool engulf    = (o1 <= c2) && (c1 >= o2) && ((c1 - o1) > (o2 - c2));
   if(!(prev_bear && curr_bull && engulf)) return;

   // ═════════ SEÑAL VÁLIDA ═════════
   double ep = c1;
   double tp = NormalizeDouble(c1 + atr_val * Inp_TP_Mult, _Digits);
   double sl = NormalizeDouble(c1 - atr_val * Inp_SL_Mult, _Digits);

   // Dibujar velas del patrón en vivo
   if(Inp_ShowCandles)
     {
      _DrawBody(t2, o2, c2, clrFireBrick, "LV_" + _TS(t2));
      _DrawBody(t1, o1, c1, clrLime,      "LV_" + _TS(t1));
     }
   _DrawOpen(t1, ep, tp, sl);

   // Construir mensaje de alerta
   string msg = StringFormat(
      "ENGULFING BULL | %s %s | Entry=%.2f | TP=%.2f | SL=%.2f | ATR=%.4f",
      _Symbol,
      TimeToString(t1, TIME_DATE | TIME_MINUTES),
      ep, tp, sl, atr_val);

   Print(">>> ", msg);
   // Alertas solo fuera del Probador (Alert() congela el tester)
   if(!MQLInfoInteger(MQL_TESTER))
     {
      Alert(msg);
      SendNotification(msg);
     }

   // ─── Ejecutar operación real/demo si AutoTrade activo ───
   if(!Inp_AutoTrade) return;

   g_ls++;
   if(g_trade.Buy(Inp_LotSize, _Symbol, 0.0, sl, tp, "EB_NY"))
     {
      g_in_trade     = true;
      g_trade_ep     = ep;
      g_trade_tp     = tp;
      g_trade_sl     = sl;
      g_trade_time   = t1;
      g_trade_ticket = g_trade.ResultOrder();
      PrintFormat("BUY ABIERTO | Ticket=%I64u | EP=%.2f | TP=%.2f | SL=%.2f",
                  g_trade_ticket, ep, tp, sl);
     }
   else
     {
      g_ls--;
      PrintFormat("ERROR BUY: %s (code=%d)",
                  g_trade.ResultRetcodeDescription(),
                  g_trade.ResultRetcode());
     }
  }

//════════════════════════════════════════════════════════════════════
//  _ManageLiveTrade
//  Detecta el cierre por SL o TP de la posición abierta y actualiza
//  las estadísticas en vivo + objetos visuales de resultado.
//════════════════════════════════════════════════════════════════════
void _ManageLiveTrade()
  {
   if(!g_in_trade || g_trade_ticket == 0) return;

   // Si la posición sigue abierta → nada que hacer
   if(PositionSelectByTicket(g_trade_ticket)) return;

   // Posición cerrada → buscar deal de salida en el historial
   double   exit_profit = 0.0;
   datetime t_close     = TimeCurrent();

   if(HistorySelect(g_trade_time - 60, TimeCurrent() + 60))
     {
      for(int d = HistoryDealsTotal() - 1; d >= 0; d--)
        {
         ulong deal = HistoryDealGetTicket(d);
         if(HistoryDealGetString (deal, DEAL_SYMBOL) != _Symbol)               continue;
         if(HistoryDealGetInteger(deal, DEAL_MAGIC)  != (long)Inp_Magic)       continue;
         if(HistoryDealGetInteger(deal, DEAL_ENTRY)  != (long)DEAL_ENTRY_OUT)  continue;
         exit_profit = HistoryDealGetDouble (deal, DEAL_PROFIT);
         t_close     = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         break;
        }
     }

   bool is_win = (exit_profit >= 0.0);
   if(is_win) g_lw++; else g_ll++;
   g_lp += exit_profit;

   _DrawClose(t_close, g_trade_time,
              g_trade_ep, g_trade_tp, g_trade_sl, is_win);

   PrintFormat("%s CERRADO | Profit=%.2f | Ticket=%I64u",
               is_win ? "WIN" : "LOSS", exit_profit, g_trade_ticket);

   g_in_trade     = false;
   g_trade_ticket = 0;
  }

//════════════════════════════════════════════════════════════════════
//  _DrawBody — cuerpo de vela coloreado (rectángulo precio)
//════════════════════════════════════════════════════════════════════
void _DrawBody(datetime t_bar, double op, double cl,
               color col, const string sfx)
  {
   string nm = PFX_BODY + sfx;
   if(ObjectFind(g_chart_id, nm) >= 0) return; // ya existe, no duplicar

   datetime t_end = t_bar + (datetime)PeriodSeconds(_Period);
   double   top   = MathMax(op, cl);
   double   bot   = MathMin(op, cl);
   if(top - bot < _Point) top = bot + _Point; // rectángulo de altura mínima

   ObjectCreate(g_chart_id, nm, OBJ_RECTANGLE, 0, t_bar, top, t_end, bot);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_COLOR,      col);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_FILL,       true);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_BACK,       false);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_WIDTH,      1);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_STYLE,      STYLE_SOLID);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_HIDDEN,     true);
  }

//════════════════════════════════════════════════════════════════════
//  _DrawOpen — HLine de entry + etiquetas Entry/TP/SL
//════════════════════════════════════════════════════════════════════
void _DrawOpen(datetime te, double ep, double tp, double sl)
  {
   string ts = _TS(te);

   // Línea horizontal del precio de entrada
   string nm_e = PFX_ENTRY + ts;
   if(ObjectFind(g_chart_id, nm_e) < 0)
     {
      ObjectCreate(g_chart_id, nm_e, OBJ_HLINE, 0, 0, ep);
      ObjectSetInteger(g_chart_id, nm_e, OBJPROP_COLOR,      clrGold);
      ObjectSetInteger(g_chart_id, nm_e, OBJPROP_STYLE,      STYLE_DASH);
      ObjectSetInteger(g_chart_id, nm_e, OBJPROP_WIDTH,      1);
      ObjectSetInteger(g_chart_id, nm_e, OBJPROP_BACK,       true);
      ObjectSetInteger(g_chart_id, nm_e, OBJPROP_SELECTABLE, false);
      ObjectSetString (g_chart_id, nm_e, OBJPROP_TOOLTIP,
                       "Entry: " + DoubleToString(ep, _Digits));
     }

   if(!Inp_ShowLabels) return;

   // Etiqueta ">>> Entry"
   string nm_le = PFX_LABEL + "E_" + ts;
   if(ObjectFind(g_chart_id, nm_le) < 0)
     {
      ObjectCreate(g_chart_id, nm_le, OBJ_TEXT, 0, te, ep);
      ObjectSetString (g_chart_id, nm_le, OBJPROP_TEXT,
                       ">>> Entry  " + DoubleToString(ep, _Digits));
      ObjectSetInteger(g_chart_id, nm_le, OBJPROP_COLOR,      clrGold);
      ObjectSetInteger(g_chart_id, nm_le, OBJPROP_FONTSIZE,   8);
      ObjectSetString (g_chart_id, nm_le, OBJPROP_FONT,       "Arial");
      ObjectSetInteger(g_chart_id, nm_le, OBJPROP_ANCHOR,     ANCHOR_LEFT_LOWER);
      ObjectSetInteger(g_chart_id, nm_le, OBJPROP_BACK,       false);
      ObjectSetInteger(g_chart_id, nm_le, OBJPROP_SELECTABLE, false);
     }

   // Etiqueta TP
   string nm_lt = PFX_LABEL + "T_" + ts;
   if(ObjectFind(g_chart_id, nm_lt) < 0)
     {
      ObjectCreate(g_chart_id, nm_lt, OBJ_TEXT, 0, te, tp);
      ObjectSetString (g_chart_id, nm_lt, OBJPROP_TEXT,
                       "TP  " + DoubleToString(tp, _Digits));
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_COLOR,      clrLime);
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_FONTSIZE,   8);
      ObjectSetString (g_chart_id, nm_lt, OBJPROP_FONT,       "Arial");
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_BACK,       false);
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_SELECTABLE, false);
     }

   // Etiqueta SL
   string nm_ls = PFX_LABEL + "S_" + ts;
   if(ObjectFind(g_chart_id, nm_ls) < 0)
     {
      ObjectCreate(g_chart_id, nm_ls, OBJ_TEXT, 0, te, sl);
      ObjectSetString (g_chart_id, nm_ls, OBJPROP_TEXT,
                       "SL  " + DoubleToString(sl, _Digits));
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_COLOR,      clrOrangeRed);
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_FONTSIZE,   8);
      ObjectSetString (g_chart_id, nm_ls, OBJPROP_FONT,       "Arial");
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_ANCHOR,     ANCHOR_LEFT_LOWER);
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_BACK,       false);
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_SELECTABLE, false);
     }
  }

//════════════════════════════════════════════════════════════════════
//  _DrawClose — zona sombreada + líneas TP/SL + etiqueta de resultado
//════════════════════════════════════════════════════════════════════
void _DrawClose(datetime t_close, datetime t_entry,
                double ep, double tp, double sl, bool is_win)
  {
   string tse = _TS(t_entry);
   string tsc = _TS(t_close);

   double exit_price = is_win ? tp    : sl;
   color  zone_col   = is_win ? C'0,55,15'  : C'55,0,0';
   color  lbl_col    = is_win ? clrLime      : clrOrangeRed;
   string result_txt = is_win ? ">>> TP HIT" : ">>> SL HIT";

   // ─── Zona sombreada (rectángulo de precios: entry → close)
   if(Inp_ShowZone)
     {
      string nm_z = PFX_ZONE + tse;
      if(ObjectFind(g_chart_id, nm_z) < 0)
        {
         ObjectCreate(g_chart_id, nm_z, OBJ_RECTANGLE, 0,
                      t_entry, MathMax(tp, ep),
                      t_close, MathMin(sl, ep));
         ObjectSetInteger(g_chart_id, nm_z, OBJPROP_COLOR,      zone_col);
         ObjectSetInteger(g_chart_id, nm_z, OBJPROP_FILL,       true);
         ObjectSetInteger(g_chart_id, nm_z, OBJPROP_BACK,       true);
         ObjectSetInteger(g_chart_id, nm_z, OBJPROP_WIDTH,      1);
         ObjectSetInteger(g_chart_id, nm_z, OBJPROP_STYLE,      STYLE_SOLID);
         ObjectSetInteger(g_chart_id, nm_z, OBJPROP_SELECTABLE, false);
        }
     }

   // ─── Línea de nivel TP (entry → close, sin extensión)
   string nm_lt = PFX_LTP + tse;
   if(ObjectFind(g_chart_id, nm_lt) < 0)
     {
      ObjectCreate(g_chart_id, nm_lt, OBJ_TREND, 0,
                   t_entry, tp, t_close, tp);
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_COLOR,      clrLime);
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_STYLE,      STYLE_DOT);
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_WIDTH,      1);
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_RAY_RIGHT,  false);
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_BACK,       true);
      ObjectSetInteger(g_chart_id, nm_lt, OBJPROP_SELECTABLE, false);
     }

   // ─── Línea de nivel SL (entry → close, sin extensión)
   string nm_ls = PFX_LSL + tse;
   if(ObjectFind(g_chart_id, nm_ls) < 0)
     {
      ObjectCreate(g_chart_id, nm_ls, OBJ_TREND, 0,
                   t_entry, sl, t_close, sl);
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_COLOR,      clrOrangeRed);
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_STYLE,      STYLE_DOT);
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_WIDTH,      1);
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_RAY_RIGHT,  false);
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_BACK,       true);
      ObjectSetInteger(g_chart_id, nm_ls, OBJPROP_SELECTABLE, false);
     }

   // ─── Etiqueta de resultado (TP HIT / SL HIT)
   if(Inp_ShowLabels)
     {
      string nm_r = PFX_RESULT + tsc;
      if(ObjectFind(g_chart_id, nm_r) < 0)
        {
         ObjectCreate(g_chart_id, nm_r, OBJ_TEXT, 0, t_close, exit_price);
         ObjectSetString (g_chart_id, nm_r, OBJPROP_TEXT,       result_txt);
         ObjectSetInteger(g_chart_id, nm_r, OBJPROP_COLOR,      lbl_col);
         ObjectSetInteger(g_chart_id, nm_r, OBJPROP_FONTSIZE,   9);
         ObjectSetString (g_chart_id, nm_r, OBJPROP_FONT,       "Arial Bold");
         ObjectSetInteger(g_chart_id, nm_r, OBJPROP_ANCHOR,     ANCHOR_LEFT);
         ObjectSetInteger(g_chart_id, nm_r, OBJPROP_BACK,       false);
         ObjectSetInteger(g_chart_id, nm_r, OBJPROP_SELECTABLE, false);
        }
     }
  }

//════════════════════════════════════════════════════════════════════
//  _RefreshStatsPanel — panel de estadísticas (esquina superior-derecha)
//  Se llama en OnInit y en cada nueva barra para mostrar datos vivos.
//════════════════════════════════════════════════════════════════════
void _RefreshStatsPanel()
  {
   // ─── Calcular métricas ───
   int    ht  = g_hw + g_hl;
   double hwr = ht > 0 ? (double)g_hw / ht * 100.0 : 0.0;
   double hex = g_hs > 0 ? g_hp / g_hs : 0.0;

   int    lt  = g_lw + g_ll;
   double lwr = lt > 0 ? (double)g_lw / lt * 100.0 : 0.0;

   // Modo actual del EA
   string mode_str;
   if(!Inp_AutoTrade)  mode_str = "SOLO VISUAL";
   else if(g_in_trade) mode_str = "TRADE ABIERTO";
   else                mode_str = "EN ESPERA";

   // Período como texto legible ("M1", "H1", etc.)
   string period_str = EnumToString(_Period);
   StringReplace(period_str, "PERIOD_", "");

   // ─── Construir las filas del panel ───
   string rows[TABLE_ROWS];
   rows[0]  = StringFormat("Activo    : %s  [%s]",       _Symbol, period_str);
   rows[1]  = StringFormat("Sesion NY : %02d:00-%02d:59 UTC",
                            Inp_SessStart, Inp_SessEnd);
   rows[2]  = StringFormat("Config    : TP x%.1f  |  SL x%.1f",
                            Inp_TP_Mult, Inp_SL_Mult);
   rows[3]  = "-----------------------------";   // separador
   rows[4]  = "[ BACKTEST HISTORICO ]";          // sección
   rows[5]  = StringFormat("Senales   : %d",             g_hs);
   rows[6]  = StringFormat("Ganadas   : %d  (%.1f%%)",   g_hw, hwr);
   rows[7]  = StringFormat("Perdidas  : %d",             g_hl);
   rows[8]  = StringFormat("PnL ATR   : %+.2f units",    g_hp);
   rows[9]  = StringFormat("Esperanza : %+.4f ATR/op",   hex);
   rows[10] = "-----------------------------";   // separador
   rows[11] = "[ SESION EN VIVO ]";             // sección
   rows[12] = StringFormat("Modo      : %s",             mode_str);
   rows[13] = StringFormat("Lot=%.2f  | Magic=%I64u",
                            Inp_LotSize, (ulong)Inp_Magic);
   rows[14] = StringFormat("Senales   : %d",             g_ls);
   rows[15] = StringFormat("W / L     : %d / %d  (%.1f%%)",
                            g_lw, g_ll, lwr);
   rows[16] = StringFormat("P&L       : %+.2f  %s",
                            g_lp, AccountInfoString(ACCOUNT_CURRENCY));
   rows[17] = StringFormat("AutoTrade : %s",
                            Inp_AutoTrade ? "ACTIVO" : "DESACTIVADO");

   // ─── Parámetros de posición del panel ───
   const int X_DIST  = 278;
   const int Y_GAP   = 17;
   const int Y_START = 22;

   // ─── Cabecera del panel ───
   string nm_h = PFX_TABLE + "00";
   if(ObjectFind(g_chart_id, nm_h) < 0)
      ObjectCreate(g_chart_id, nm_h, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_XDISTANCE,  X_DIST);
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_YDISTANCE,  Y_START);
   ObjectSetString (g_chart_id, nm_h, OBJPROP_TEXT,
                    "=== Engulfing Bull  NY Session ===");
   ObjectSetString (g_chart_id, nm_h, OBJPROP_FONT,       "Courier New");
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_FONTSIZE,   8);
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_COLOR,      clrGold);
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_BACK,       false);
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_SELECTABLE, false);

   // ─── Filas de datos ───
   for(int k = 0; k < TABLE_ROWS; k++)
     {
      // Asignar color según tipo de fila
      color row_col = clrSilver;
      if(k == 3 || k == 10) row_col = C'65,65,65';    // separadores "----"
      if(k == 4 || k == 11) row_col = clrAquamarine;  // encabezados de sección

      string nm = PFX_TABLE + IntegerToString(k + 1);
      if(ObjectFind(g_chart_id, nm) < 0)
         ObjectCreate(g_chart_id, nm, OBJ_LABEL, 0, 0, 0);

      ObjectSetInteger(g_chart_id, nm, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
      ObjectSetInteger(g_chart_id, nm, OBJPROP_XDISTANCE,  X_DIST);
      ObjectSetInteger(g_chart_id, nm, OBJPROP_YDISTANCE,  Y_START + (k + 1) * Y_GAP);
      ObjectSetString (g_chart_id, nm, OBJPROP_TEXT,       rows[k]);
      ObjectSetString (g_chart_id, nm, OBJPROP_FONT,       "Courier New");
      ObjectSetInteger(g_chart_id, nm, OBJPROP_FONTSIZE,   8);
      ObjectSetInteger(g_chart_id, nm, OBJPROP_COLOR,      row_col);
      ObjectSetInteger(g_chart_id, nm, OBJPROP_BACK,       false);
      ObjectSetInteger(g_chart_id, nm, OBJPROP_SELECTABLE, false);
     }
  }

//════════════════════════════════════════════════════════════════════
//  _DeleteAllObjects — limpieza total de objetos gráficos del EA
//════════════════════════════════════════════════════════════════════
void _DeleteAllObjects()
  {
   ObjectsDeleteAll(g_chart_id, PFX_ZONE);
   ObjectsDeleteAll(g_chart_id, PFX_ENTRY);
   ObjectsDeleteAll(g_chart_id, PFX_LTP);
   ObjectsDeleteAll(g_chart_id, PFX_LSL);
   ObjectsDeleteAll(g_chart_id, PFX_LABEL);
   ObjectsDeleteAll(g_chart_id, PFX_RESULT);
   ObjectsDeleteAll(g_chart_id, PFX_BODY);

   // La tabla usa nombres enumerados → borrar individualmente
   ObjectDelete(g_chart_id, PFX_TABLE + "00");
   for(int k = 1; k <= TABLE_ROWS; k++)
      ObjectDelete(g_chart_id, PFX_TABLE + IntegerToString(k));
  }

//════════════════════════════════════════════════════════════════════
//  _TS — timestamp sanitizado para crear nombres de objeto únicos
//════════════════════════════════════════════════════════════════════
string _TS(datetime t)
  {
   string s = TimeToString(t, TIME_DATE | TIME_MINUTES);
   StringReplace(s, ":", "");
   StringReplace(s, ".", "");
   StringReplace(s, " ", "_");
   return s;
  }

//════════════════════════════════════════════════════════════════════
//  _BestFillingMode — devuelve el modo de llenado compatible
//  con el símbolo/broker actual (evita Error 10014)
//════════════════════════════════════════════════════════════════════
ENUM_ORDER_TYPE_FILLING _BestFillingMode()
  {
   uint modes = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }
//+------------------------------------------------------------------+
