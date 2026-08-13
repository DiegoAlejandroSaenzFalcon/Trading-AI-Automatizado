//+------------------------------------------------------------------+
//|                                            EngulfingBull_NY_EA.mq5 |
//|                     Engulfing Bull NY Session — EA v3.1 (Fixed)    |
//|               Concurrent Trades + Spatial Dispersion Filter        |
//|  Compatible: Demo · Real · Probador de Estrategias (MT5)           |
//+------------------------------------------------------------------+
#property copyright   "EA Profesional MQL5 v3.1"
#property version     "3.10"
#property strict
#property description "Arquitectura concurrente con control cuantitativo de"
#property description "exposición espacial (Signal Clustering Prevention)"
#property description "y entorno visual oscuro con proyecciones futuras."

#include <Trade\Trade.mqh>

//════════════════════════════════════════════════════════════════════
//  ENTRADAS PARAMÉTRICAS
//════════════════════════════════════════════════════════════════════
input group "━━━━━ ESTRATEGIA ━━━━━"
input int    Inp_ATR_Period = 770;    // Período del ATR
input double Inp_TP_Mult    = 120.0;   // Multiplicador Take Profit (× ATR)
input double Inp_SL_Mult    = 5.0;    // Multiplicador Stop Loss  (× ATR)
input int    Inp_SessStart  = 13;     // Hora inicio sesión NY (UTC)
input int    Inp_SessEnd    = 17;     // Hora fin sesión NY   (UTC)

input group "━━━━━ CONTROL DE RIESGO ━━━━━"
input int    Inp_MaxConcurrent = 3;   // Máx. operaciones concurrentes
input double Inp_MinDistATR    = 10.0; // Distancia espacial mínima (x ATR)

input group "━━━━━ AUTO-TRADING ━━━━━"
input bool   Inp_AutoTrade  = false;  // ← Activar operaciones automáticas
input double Inp_LotSize    = 0.01;   // Tamaño del lote
input ulong  Inp_Magic      = 202501; // Número mágico del EA
input uint   Inp_Slippage   = 800;    // Deslizamiento máximo (puntos)

input group "━━━━━ ENTORNO VISUAL ━━━━━"
input bool   Inp_ShowZone    = true;  // Zonas sombreadas TP/SL proyectadas
input bool   Inp_ShowLabels  = true;  // Etiquetas TP / SL / Entry
input bool   Inp_ShowTable   = true;  // Panel de estadísticas en pantalla
input bool   Inp_ShowCandles = true;  // Colorear velas del patrón
input int    Inp_MaxBars     = 5000;  // Barras históricas máximas a escanear

//════════════════════════════════════════════════════════════════════
//  CONSTANTES DE SISTEMA
//════════════════════════════════════════════════════════════════════
#define TABLE_ROWS   20      // Filas del panel
#define MAX_TRADES   100     // Capacidad máxima de rastreo de arrays
#define PROJ_BARS    300     // Barras proyectadas al futuro visualmente

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

// ── Estadísticas Históricas
int    g_hs = 0, g_hw = 0, g_hl = 0;
double g_hp = 0.0;

// ── Estadísticas en Vivo
int    g_ls = 0, g_lw = 0, g_ll = 0;
double g_lp = 0.0;

// ── Arrays para Gestión de Trades Concurrentes
ulong    g_tickets[MAX_TRADES];
double   g_eps[MAX_TRADES];
double   g_tps[MAX_TRADES];
double   g_sls[MAX_TRADES];
datetime g_etimes[MAX_TRADES];
int      g_trade_count = 0;

// Estructura de soporte para simulación concurrente histórica
struct SimTrade { double ep; double tp; double sl; datetime te; };

//════════════════════════════════════════════════════════════════════
//  PROTOTIPOS
//════════════════════════════════════════════════════════════════════
void  _ScanHistory();
void  _CheckForSignal();
void  _ManageLiveTrade();
bool  _AddTrade(ulong ticket, double ep, double tp, double sl, datetime te);
void  _RemoveTrade(int idx);
void  _DrawBody(datetime t_bar, double op, double cl, color col, const string sfx);
void  _DrawOpen(datetime te, double ep, double tp, double sl);
void  _DrawClose(datetime t_close, datetime t_entry, double ep, double tp, double sl, bool is_win);
void  _RefreshStatsPanel();
void  _DeleteAllObjects();
string _TS(datetime t);
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
      Print("CRITICAL ERROR: No se pudo inicializar iATR.");
      return INIT_FAILED;
     }

   // ── Forzar Propiedades del Chart (Black UI Estricta) ──
   ChartSetInteger(g_chart_id, CHART_COLOR_BACKGROUND,  clrBlack);
   ChartSetInteger(g_chart_id, CHART_COLOR_FOREGROUND,  clrSilver);
   ChartSetInteger(g_chart_id, CHART_COLOR_GRID,        clrBlack);
   ChartSetInteger(g_chart_id, CHART_SHOW_GRID,         false);
   ChartSetInteger(g_chart_id, CHART_COLOR_CANDLE_BULL, clrLime);
   ChartSetInteger(g_chart_id, CHART_COLOR_CANDLE_BEAR, clrRed);
   ChartSetInteger(g_chart_id, CHART_COLOR_CHART_UP,    clrLime);
   ChartSetInteger(g_chart_id, CHART_COLOR_CHART_DOWN,  clrRed);
   ChartSetInteger(g_chart_id, CHART_COLOR_VOLUME,      clrDodgerBlue);
   ChartSetInteger(g_chart_id, CHART_COLOR_ASK,         clrRed);
   ChartSetInteger(g_chart_id, CHART_COLOR_BID,         clrSilver);
   ChartSetInteger(g_chart_id, CHART_SHOW_OHLC,         true);
   
   // CTrade Init
   g_trade.SetExpertMagicNumber(Inp_Magic);
   g_trade.SetDeviationInPoints(Inp_Slippage);
   g_trade.SetTypeFilling(_BestFillingMode());
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   // Reseteo de memoria
   g_hist_done     = false;
   g_last_bar_time = 0;
   g_trade_count   = 0;
   g_hs = g_hw = g_hl = 0;  g_hp = 0.0;
   g_ls = g_lw = g_ll = 0;  g_lp = 0.0;

   _DeleteAllObjects();
   if(Inp_ShowTable) _RefreshStatsPanel();
   ChartRedraw(g_chart_id);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   _DeleteAllObjects();
   ChartRedraw(g_chart_id);
  }

//════════════════════════════════════════════════════════════════════
//  OnTick
//════════════════════════════════════════════════════════════════════
void OnTick()
  {
   if(!g_hist_done)
     {
      _ScanHistory();
      g_hist_done = true;
      if(Inp_ShowTable) _RefreshStatsPanel();
      ChartRedraw(g_chart_id);
     }

   datetime bar0_time = iTime(_Symbol, _Period, 0);
   if(bar0_time == g_last_bar_time) return;
   g_last_bar_time = bar0_time;

   if(Inp_AutoTrade && g_trade_count > 0) _ManageLiveTrade();
   _CheckForSignal();

   if(Inp_ShowTable) _RefreshStatsPanel();
   ChartRedraw(g_chart_id);
  }

//════════════════════════════════════════════════════════════════════
//  Gestión de Arrays para Múltiples Operaciones
//════════════════════════════════════════════════════════════════════
bool _AddTrade(ulong ticket, double ep, double tp, double sl, datetime te)
  {
   if(g_trade_count >= MAX_TRADES) return false;
   g_tickets[g_trade_count] = ticket;
   g_eps    [g_trade_count] = ep;
   g_tps    [g_trade_count] = tp;
   g_sls    [g_trade_count] = sl;
   g_etimes [g_trade_count] = te;
   g_trade_count++;
   return true;
  }

void _RemoveTrade(int idx)
  {
   for(int i = idx; i < g_trade_count - 1; i++)
     {
      g_tickets[i] = g_tickets[i + 1];
      g_eps    [i] = g_eps    [i + 1];
      g_tps    [i] = g_tps    [i + 1];
      g_sls    [i] = g_sls    [i + 1];
      g_etimes [i] = g_etimes [i + 1];
     }
   g_trade_count--;
  }

//════════════════════════════════════════════════════════════════════
//  _ScanHistory (Simulador Concurrente Mejorado)
//════════════════════════════════════════════════════════════════════
void _ScanHistory()
  {
   int total_bars = iBars(_Symbol, _Period);
   if(total_bars < Inp_ATR_Period + 3) return;

   int limit  = MathMin(total_bars - 2, Inp_MaxBars);
   int n_copy = limit + 3;

   double   arr_o[], arr_h[], arr_l[], arr_c[], arr_atr[];
   datetime arr_t[];
   ArraySetAsSeries(arr_o, true); ArraySetAsSeries(arr_h, true);
   ArraySetAsSeries(arr_l, true); ArraySetAsSeries(arr_c, true);
   ArraySetAsSeries(arr_t, true); ArraySetAsSeries(arr_atr, true);

   if(CopyOpen  (_Symbol, _Period, 0, n_copy, arr_o)   < n_copy) return;
   if(CopyHigh  (_Symbol, _Period, 0, n_copy, arr_h)   < n_copy) return;
   if(CopyLow   (_Symbol, _Period, 0, n_copy, arr_l)   < n_copy) return;
   if(CopyClose (_Symbol, _Period, 0, n_copy, arr_c)   < n_copy) return;
   if(CopyTime  (_Symbol, _Period, 0, n_copy, arr_t)   < n_copy) return;
   if(CopyBuffer(g_atr_handle, 0, 0, n_copy, arr_atr)  <= 0)     return;

   SimTrade sim_t[MAX_TRADES];
   int sim_count = 0;

   // Iteración histórica: Desde el pasado hasta el presente
   for(int i = limit; i >= 1; i--)
     {
      if(arr_atr[i] <= 0.0 || arr_atr[i] == EMPTY_VALUE) continue;

      // 1. Evaluar cierres de operaciones simuladas concurrentes
      for(int j = sim_count - 1; j >= 0; j--)
        {
         bool hit_sl = (arr_l[i] <= sim_t[j].sl);
         bool hit_tp = (arr_h[i] >= sim_t[j].tp);

         if(hit_sl || hit_tp)
           {
            color cl_col = hit_tp ? clrRoyalBlue : clrFireBrick;
            if(Inp_ShowCandles) _DrawBody(arr_t[i], arr_o[i], arr_c[i], cl_col, "CL_" + _TS(arr_t[i]));
            _DrawClose(arr_t[i], sim_t[j].te, sim_t[j].ep, sim_t[j].tp, sim_t[j].sl, hit_tp);
            
            if(hit_tp) { g_hw++; g_hp += Inp_TP_Mult; } 
            else       { g_hl++; g_hp -= Inp_SL_Mult; }

            // Remover trade cerrado del array (shift izq)
            for(int k = j; k < sim_count - 1; k++) sim_t[k] = sim_t[k+1];
            sim_count--;
           }
        }

      // 2. Filtro de Sesión
      MqlDateTime dc, dp;
      TimeToStruct(arr_t[i], dc);
      TimeToStruct(arr_t[i + 1], dp);
      if(dc.hour < Inp_SessStart || dc.hour > Inp_SessEnd) continue;
      if(dp.hour < Inp_SessStart || dp.hour > Inp_SessEnd) continue;

      // 3. Patrón Engulfing
      bool prev_bear = (arr_c[i + 1] < arr_o[i + 1]);
      bool curr_bull = (arr_c[i]     >= arr_o[i]);
      bool engulf    = (arr_o[i] <= arr_c[i + 1]) && (arr_c[i] >= arr_o[i + 1]) && ((arr_c[i] - arr_o[i]) > (arr_o[i + 1] - arr_c[i + 1]));

      if(!(prev_bear && curr_bull && engulf)) continue;

      // 4. Gestión de Riesgo (Backtest Concurrent Logic)
      if(sim_count >= Inp_MaxConcurrent) continue;
      
      bool too_close = false;
      double dist_req = arr_atr[i] * Inp_MinDistATR;
      for(int j = 0; j < sim_count; j++)
        {
         if(MathAbs(arr_c[i] - sim_t[j].ep) < dist_req) { too_close = true; break; }
        }
      if(too_close) continue;

      // 5. Apertura Simulada
      g_hs++;
      sim_t[sim_count].ep = arr_c[i];
      sim_t[sim_count].tp = arr_c[i] + arr_atr[i] * Inp_TP_Mult;
      sim_t[sim_count].sl = arr_c[i] - arr_atr[i] * Inp_SL_Mult;
      sim_t[sim_count].te = arr_t[i];
      sim_count++;

      if(Inp_ShowCandles)
        {
         _DrawBody(arr_t[i + 1], arr_o[i + 1], arr_c[i + 1], clrFireBrick, "PT_" + _TS(arr_t[i + 1]));
         _DrawBody(arr_t[i], arr_o[i], arr_c[i], clrLime, "PT_" + _TS(arr_t[i]));
        }
      _DrawOpen(arr_t[i], arr_c[i], arr_c[i] + arr_atr[i] * Inp_TP_Mult, arr_c[i] - arr_atr[i] * Inp_SL_Mult);
     }
  }

//════════════════════════════════════════════════════════════════════
//  _CheckForSignal (Ejecución en Vivo con Filtros)
//════════════════════════════════════════════════════════════════════
void _CheckForSignal()
  {
   datetime t1 = iTime(_Symbol, _Period, 1);
   datetime t2 = iTime(_Symbol, _Period, 2);
   if(t1 == 0 || t2 == 0) return;

   MqlDateTime dt1, dt2;
   TimeToStruct(t1, dt1);
   TimeToStruct(t2, dt2);
   if(dt1.hour < Inp_SessStart || dt1.hour > Inp_SessEnd) return;
   if(dt2.hour < Inp_SessStart || dt2.hour > Inp_SessEnd) return;

   double o1 = iOpen(_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double o2 = iOpen(_Symbol, _Period, 2), c2 = iClose(_Symbol, _Period, 2);

   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_buf) <= 0) return;
   double atr_val = atr_buf[0];
   if(atr_val <= 0.0 || atr_val == EMPTY_VALUE) return;

   bool prev_bear = (c2 < o2);
   bool curr_bull = (c1 >= o1);
   bool engulf    = (o1 <= c2) && (c1 >= o2) && ((c1 - o1) > (o2 - c2));
   if(!(prev_bear && curr_bull && engulf)) return;

   double ep = c1;
   double tp = NormalizeDouble(c1 + atr_val * Inp_TP_Mult, _Digits);
   double sl = NormalizeDouble(c1 - atr_val * Inp_SL_Mult, _Digits);

   // ─── ALGORITMO DE CONTROL DE RIESGO ESPACIAL ───
   if(g_trade_count >= Inp_MaxConcurrent) return; // Limite de cardinalidad
   
   double dist_req = atr_val * Inp_MinDistATR;
   for(int i = 0; i < g_trade_count; i++)         // Filtro de dispersión
     {
      if(MathAbs(ep - g_eps[i]) < dist_req) return;
     }
   // ───────────────────────────────────────────────

   if(Inp_ShowCandles)
     {
      _DrawBody(t2, o2, c2, clrFireBrick, "LV_" + _TS(t2));
      _DrawBody(t1, o1, c1, clrLime,      "LV_" + _TS(t1));
     }
   _DrawOpen(t1, ep, tp, sl);

   string msg = StringFormat("ENGULFING BULL | Entry=%.*f | TP=%.*f | SL=%.*f", _Digits, ep, _Digits, tp, _Digits, sl);
   Print(">>> ", msg);

   if(!Inp_AutoTrade) return;

   g_ls++;
   if(g_trade.Buy(Inp_LotSize, _Symbol, 0.0, sl, tp, "EB_NY"))
     {
      ulong ticket = g_trade.ResultOrder();
      _AddTrade(ticket, ep, tp, sl, t1);
     }
   else
     {
      g_ls--;
      Print("ERROR BUY: ", g_trade.ResultRetcodeDescription());
     }
  }

//════════════════════════════════════════════════════════════════════
//  _ManageLiveTrade
//════════════════════════════════════════════════════════════════════
void _ManageLiveTrade()
  {
   for(int idx = g_trade_count - 1; idx >= 0; idx--)
     {
      ulong ticket = g_tickets[idx];
      if(PositionSelectByTicket(ticket)) continue;

      double   exit_profit = 0.0;
      datetime t_close     = TimeCurrent();

      if(HistorySelect(g_etimes[idx] - 60, TimeCurrent() + 60))
        {
         for(int d = HistoryDealsTotal() - 1; d >= 0; d--)
           {
            ulong deal = HistoryDealGetTicket(d);
            if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
            if(HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)Inp_Magic) continue;
            if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
            if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != ticket) continue;

            exit_profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
            t_close     = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
            break;
           }
        }

      bool is_win = (exit_profit >= 0.0);
      if(is_win) g_lw++; else g_ll++;
      g_lp += exit_profit;

      _DrawClose(t_close, g_etimes[idx], g_eps[idx], g_tps[idx], g_sls[idx], is_win);
      _RemoveTrade(idx);
     }
  }

//════════════════════════════════════════════════════════════════════
//  Visual Rendering Logic
//════════════════════════════════════════════════════════════════════
void _DrawBody(datetime t_bar, double op, double cl, color col, const string sfx)
  {
   string nm = PFX_BODY + sfx;
   if(ObjectFind(g_chart_id, nm) >= 0) return;
   double top = MathMax(op, cl), bot = MathMin(op, cl);
   if(top - bot < _Point) top = bot + _Point;

   ObjectCreate(g_chart_id, nm, OBJ_RECTANGLE, 0, t_bar, top, t_bar + PeriodSeconds(_Period), bot);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_COLOR, col);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_FILL, true);
   ObjectSetInteger(g_chart_id, nm, OBJPROP_BACK, false);
  }

void _DrawOpen(datetime te, double ep, double tp, double sl)
  {
   string ts = _TS(te);
   string nm_e = PFX_ENTRY + ts;
   if(ObjectFind(g_chart_id, nm_e) < 0)
     {
      ObjectCreate(g_chart_id, nm_e, OBJ_HLINE, 0, 0, ep);
      ObjectSetInteger(g_chart_id, nm_e, OBJPROP_COLOR, clrGold);
      ObjectSetInteger(g_chart_id, nm_e, OBJPROP_STYLE, STYLE_DASH);
     }

   if(Inp_ShowZone)
     {
      datetime t_proj = te + (datetime)(PeriodSeconds(_Period) * PROJ_BARS);
      string nm_ztp = PFX_ZONE + "TP_" + ts, nm_zsl = PFX_ZONE + "SL_" + ts;
      
      if(ObjectFind(g_chart_id, nm_ztp) < 0)
        {
         ObjectCreate(g_chart_id, nm_ztp, OBJ_RECTANGLE, 0, te, tp, t_proj, ep);
         ObjectSetInteger(g_chart_id, nm_ztp, OBJPROP_COLOR, C'0,40,10');
         ObjectSetInteger(g_chart_id, nm_ztp, OBJPROP_FILL, true);
         ObjectSetInteger(g_chart_id, nm_ztp, OBJPROP_BACK, true);
        }
      if(ObjectFind(g_chart_id, nm_zsl) < 0)
        {
         ObjectCreate(g_chart_id, nm_zsl, OBJ_RECTANGLE, 0, te, ep, t_proj, sl);
         ObjectSetInteger(g_chart_id, nm_zsl, OBJPROP_COLOR, C'40,0,0');
         ObjectSetInteger(g_chart_id, nm_zsl, OBJPROP_FILL, true);
         ObjectSetInteger(g_chart_id, nm_zsl, OBJPROP_BACK, true);
        }
     }
  }

void _DrawClose(datetime t_close, datetime t_entry, double ep, double tp, double sl, bool is_win)
  {
   string tse = _TS(t_entry);
   
   if(Inp_ShowZone)
     {
      if(ObjectFind(g_chart_id, PFX_ZONE + "TP_" + tse) >= 0) ObjectMove(g_chart_id, PFX_ZONE + "TP_" + tse, 1, t_close, ep);
      if(ObjectFind(g_chart_id, PFX_ZONE + "SL_" + tse) >= 0) ObjectMove(g_chart_id, PFX_ZONE + "SL_" + tse, 1, t_close, sl);
     }

   string nm_l = (is_win ? PFX_LTP : PFX_LSL) + tse;
   ObjectCreate(g_chart_id, nm_l, OBJ_TREND, 0, t_entry, (is_win?tp:sl), t_close, (is_win?tp:sl));
   ObjectSetInteger(g_chart_id, nm_l, OBJPROP_COLOR, (is_win?clrLime:clrOrangeRed));
   ObjectSetInteger(g_chart_id, nm_l, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(g_chart_id, nm_l, OBJPROP_RAY_RIGHT, false);
  }

//════════════════════════════════════════════════════════════════════
//  Panel Updates & Cleanup
//════════════════════════════════════════════════════════════════════
void _RefreshStatsPanel()
  {
   int ht = g_hw + g_hl; double hwr = ht > 0 ? (double)g_hw / ht * 100.0 : 0.0;
   double hex = g_hs > 0 ? g_hp / g_hs : 0.0;
   int lt = g_lw + g_ll; double lwr = lt > 0 ? (double)g_lw / lt * 100.0 : 0.0;

   int active_pos = 0;
   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      if(PositionGetSymbol(p) == _Symbol && PositionGetInteger(POSITION_MAGIC) == (long)Inp_Magic) active_pos++;
     }

   string rows[TABLE_ROWS];
   rows[0]  = StringFormat("Activo    : %s", _Symbol);
   rows[1]  = StringFormat("Sesion NY : %02d:00-%02d:59 UTC", Inp_SessStart, Inp_SessEnd);
   rows[2]  = StringFormat("Estrategia: TP x%.1f | SL x%.1f", Inp_TP_Mult, Inp_SL_Mult);
   rows[3]  = StringFormat("Riesgo    : Max %d | Dist %.1f ATR", Inp_MaxConcurrent, Inp_MinDistATR);
   rows[4]  = "-----------------------------";
   rows[5]  = "[ BACKTEST CONCURRENTE ]";
   rows[6]  = StringFormat("Senales   : %d", g_hs);
   rows[7]  = StringFormat("Win Rate  : %.1f%% (%d W / %d L)", hwr, g_hw, g_hl);
   rows[8]  = StringFormat("PnL ATR   : %+.2f units", g_hp);
   rows[9]  = StringFormat("Esperanza : %+.4f ATR/op", hex);
   rows[10] = "-----------------------------";
   rows[11] = "[ SESION EN VIVO ]";
   rows[12] = StringFormat("AutoTrade : %s", Inp_AutoTrade ? "ACTIVO" : "DESACTIVADO");
   rows[13] = StringFormat("Posiciones: %d abiertas", active_pos);
   rows[14] = StringFormat("Senales   : %d", g_ls);
   rows[15] = StringFormat("W / L     : %d / %d  (%.1f%%)", g_lw, g_ll, lwr);
   rows[16] = StringFormat("P&L       : %+.2f %s", g_lp, AccountInfoString(ACCOUNT_CURRENCY));
   rows[17] = StringFormat("Lot=%.2f | Magic=%I64u", Inp_LotSize, (ulong)Inp_Magic);

   string nm_h = PFX_TABLE + "00";
   if(ObjectFind(g_chart_id, nm_h) < 0) ObjectCreate(g_chart_id, nm_h, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_XDISTANCE, 278);
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_YDISTANCE, 22);
   ObjectSetString (g_chart_id, nm_h, OBJPROP_TEXT, "=== EB NY Quant Edition v3.1 ===");
   ObjectSetString (g_chart_id, nm_h, OBJPROP_FONT, "Courier New");
   ObjectSetInteger(g_chart_id, nm_h, OBJPROP_COLOR, clrGold);

   for(int k = 0; k < 18; k++)
     {
      color r_col = clrSilver;
      if(k==4 || k==10) r_col = C'80,80,80';
      if(k==5 || k==11) r_col = clrAquamarine;
      if(k==13 && active_pos>0) r_col = clrGold;

      string nm = PFX_TABLE + IntegerToString(k + 1);
      if(ObjectFind(g_chart_id, nm) < 0) ObjectCreate(g_chart_id, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(g_chart_id, nm, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(g_chart_id, nm, OBJPROP_XDISTANCE, 278);
      ObjectSetInteger(g_chart_id, nm, OBJPROP_YDISTANCE, 22 + (k + 1) * 17);
      ObjectSetString (g_chart_id, nm, OBJPROP_TEXT, rows[k]);
      ObjectSetString (g_chart_id, nm, OBJPROP_FONT, "Courier New");
      ObjectSetInteger(g_chart_id, nm, OBJPROP_COLOR, r_col);
     }
  }

void _DeleteAllObjects()
  {
   ObjectsDeleteAll(g_chart_id, PFX_ZONE); ObjectsDeleteAll(g_chart_id, PFX_ENTRY);
   ObjectsDeleteAll(g_chart_id, PFX_LTP);  ObjectsDeleteAll(g_chart_id, PFX_LSL);
   ObjectsDeleteAll(g_chart_id, PFX_BODY);
   ObjectDelete(g_chart_id, PFX_TABLE + "00");
   for(int k=1; k<=TABLE_ROWS; k++) ObjectDelete(g_chart_id, PFX_TABLE + IntegerToString(k));
  }

string _TS(datetime t)
  {
   string s = TimeToString(t, TIME_DATE | TIME_MINUTES);
   StringReplace(s, ":", ""); StringReplace(s, ".", ""); StringReplace(s, " ", "_");
   return s;
  }

ENUM_ORDER_TYPE_FILLING _BestFillingMode()
  {
   uint modes = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }
//+------------------------------------------------------------------+