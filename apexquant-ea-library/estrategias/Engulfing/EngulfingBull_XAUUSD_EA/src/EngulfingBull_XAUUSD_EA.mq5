//+------------------------------------------------------------------+
//| EngulfingBull_XAUUSD_EA.mq5                                     |
//| Engulfing Bull — XAUUSD | Sesion NY 13-17 UTC | EA v2.0         |
//| Dashboard dual: Backtest (visual) / Live (autotrading)          |
//+------------------------------------------------------------------+
#property copyright   "EA Profesional MQL5 v2.0 — XAUUSD"
#property version     "2.00"
#property strict
#property description "Engulfing Bull XAUUSD | Sesion NY 13:00-17:59 UTC"
#property description "Dashboard dual: visual=backtest, auto=trading en vivo."

#include <Trade\Trade.mqh>

#define ASSET_LABEL "XAUUSD"

//--- ENTRADAS
input group "━━━━━ ESTRATEGIA ━━━━━"
input int    Inp_ATR_Period    = 770;
input double Inp_TP_Mult       = 120.0;
input double Inp_SL_Mult       = 5.0;
input int    Inp_SessStart     = 13;
input int    Inp_SessEnd       = 17;

input group "━━━━━ CONTROL DE RIESGO ━━━━━"
input int    Inp_MaxConcurrent = 3;
input double Inp_MinDistATR    = 10.0;

input group "━━━━━ AUTO-TRADING ━━━━━"
input bool   Inp_AutoTrade  = false;
input double Inp_LotSize    = 0.01;
input ulong  Inp_Magic      = 202501;
input uint   Inp_Slippage   = 800;

input group "━━━━━ VISUAL ━━━━━"
input bool   Inp_ShowZone    = true;
input bool   Inp_ShowLabels  = true;
input bool   Inp_ShowTable   = true;
input bool   Inp_ShowCandles = true;
input int    Inp_MaxBars     = 5000;

//--- CONSTANTES
#define TABLE_ROWS_MAX 20
#define MAX_TRADES     50

#define PFX_ZONE    "EBXAU_Z_"
#define PFX_ENTRY   "EBXAU_E_"
#define PFX_LTP     "EBXAU_T_"
#define PFX_LSL     "EBXAU_S_"
#define PFX_LABEL   "EBXAU_L_"
#define PFX_RESULT  "EBXAU_R_"
#define PFX_BODY    "EBXAU_BD_"
#define PFX_TABLE   "EBXAU_TB_"

//--- ESTRUCTURA TRADE EN VIVO
struct LiveTrade { ulong ticket; double ep,tp,sl; datetime te; };

//--- VARIABLES GLOBALES
CTrade    g_trade;
int       g_atr_handle    = INVALID_HANDLE;
long      g_chart_id      = 0;
datetime  g_last_bar_time = 0;
bool      g_hist_done     = false;

int    g_hs=0, g_hw=0, g_hl=0;
double g_hp=0.0;
int    g_ls=0, g_lw=0, g_ll=0;
double g_lp=0.0;

LiveTrade g_live_trades[MAX_TRADES];
int       g_live_count = 0;

//--- PROTOTIPOS
void _ScanHistory();
void _CheckForSignal();
void _ManageLiveTrades();
bool _AddLiveTrade(ulong ticket, double ep, double tp, double sl, datetime te);
void _RemoveLiveTrade(int idx);
void _DrawBody(datetime t, double op, double cl, color c, const string sfx);
void _DrawOpen(datetime te, double ep, double tp, double sl);
void _DrawClose(datetime tc, datetime te, double ep, double tp, double sl, bool win);
void _RefreshStatsPanel();
void _DeleteAllObjects();
string _TS(datetime t);
int    _UTCOffset();
ENUM_ORDER_TYPE_FILLING _BestFillingMode();

//+------------------------------------------------------------------+
int OnInit()
{
   g_chart_id   = ChartID();
   g_atr_handle = iATR(_Symbol, _Period, Inp_ATR_Period);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Alert("ERROR: No se pudo crear iATR(", Inp_ATR_Period, ").");
      return INIT_FAILED;
   }
   g_trade.SetExpertMagicNumber(Inp_Magic);
   g_trade.SetDeviationInPoints(Inp_Slippage);
   g_trade.SetTypeFilling(_BestFillingMode());
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_hist_done=false; g_last_bar_time=0; g_live_count=0;
   g_hs=g_hw=g_hl=0; g_hp=0.0;
   g_ls=g_lw=g_ll=0; g_lp=0.0;

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

void OnTick()
{
   if(!g_hist_done)
   {
      _ScanHistory();
      g_hist_done = true;
      if(Inp_ShowTable) _RefreshStatsPanel();
      ChartRedraw(g_chart_id);
   }
   datetime bar0 = iTime(_Symbol, _Period, 0);
   if(bar0 == g_last_bar_time) return;
   g_last_bar_time = bar0;

   if(Inp_AutoTrade && g_live_count > 0) _ManageLiveTrades();
   _CheckForSignal();
   if(Inp_ShowTable) _RefreshStatsPanel();
   ChartRedraw(g_chart_id);
}

int _UTCOffset() { return (int)(TimeCurrent() - TimeGMT()); }

bool _AddLiveTrade(ulong ticket, double ep, double tp, double sl, datetime te)
{
   if(g_live_count >= MAX_TRADES) return false;
   g_live_trades[g_live_count].ticket = ticket;
   g_live_trades[g_live_count].ep     = ep;
   g_live_trades[g_live_count].tp     = tp;
   g_live_trades[g_live_count].sl     = sl;
   g_live_trades[g_live_count].te     = te;
   g_live_count++;
   return true;
}

void _RemoveLiveTrade(int idx)
{
   for(int i = idx; i < g_live_count - 1; i++) g_live_trades[i] = g_live_trades[i+1];
   g_live_count--;
}

//+------------------------------------------------------------------+
void _ScanHistory()
{
   int total = iBars(_Symbol, _Period);
   if(total < Inp_ATR_Period + 3) return;
   int limit  = MathMin(total - 2, Inp_MaxBars);
   int n_copy = limit + 3;

   double arr_o[],arr_h[],arr_l[],arr_c[],arr_atr[];
   datetime arr_t[];
   ArraySetAsSeries(arr_o,true); ArraySetAsSeries(arr_h,true);
   ArraySetAsSeries(arr_l,true); ArraySetAsSeries(arr_c,true);
   ArraySetAsSeries(arr_t,true); ArraySetAsSeries(arr_atr,true);

   if(CopyOpen  (_Symbol,_Period,0,n_copy,arr_o)  < n_copy) return;
   if(CopyHigh  (_Symbol,_Period,0,n_copy,arr_h)  < n_copy) return;
   if(CopyLow   (_Symbol,_Period,0,n_copy,arr_l)  < n_copy) return;
   if(CopyClose (_Symbol,_Period,0,n_copy,arr_c)  < n_copy) return;
   if(CopyTime  (_Symbol,_Period,0,n_copy,arr_t)  < n_copy) return;
   if(CopyBuffer(g_atr_handle,0,0,n_copy,arr_atr) <= 0)     return;

   int utc_off = _UTCOffset();

   // Trades simulados concurrentes (estructura local)
   struct SimTrade { double ep; double tp; double sl; datetime te; };
   SimTrade sim[MAX_TRADES];
   int      sim_count = 0;

   for(int i = limit; i >= 1; i--)
   {
      if(arr_atr[i] <= 0.0 || arr_atr[i] == EMPTY_VALUE) continue;
      if((i+1) >= n_copy) continue;

      // --- 1. Evaluar cierres concurrentes (SL primero = conservador)
      for(int j = sim_count - 1; j >= 0; j--)
      {
         bool hit_sl = (arr_l[i] <= sim[j].sl);
         bool hit_tp = (arr_h[i] >= sim[j].tp);
         if(hit_sl || hit_tp)
         {
            bool is_win = !hit_sl;
            if(Inp_ShowCandles)
            {
               color cx = is_win ? C'10,50,120' : C'80,15,15';
               _DrawBody(arr_t[i],arr_o[i],arr_c[i],cx,
                         "CL_"+_TS(arr_t[i])+"_"+IntegerToString(j));
            }
            _DrawClose(arr_t[i],sim[j].te,sim[j].ep,sim[j].tp,sim[j].sl,is_win);
            if(is_win){g_hw++; g_hp+=Inp_TP_Mult;}
            else      {g_hl++; g_hp-=Inp_SL_Mult;}
            for(int k=j;k<sim_count-1;k++) sim[k]=sim[k+1];
            sim_count--;
         }
      }

      // --- 2. Filtro de sesion UTC
      datetime tu      = (datetime)((int)arr_t[i]   - utc_off);
      datetime tu_prev = (datetime)((int)arr_t[i+1] - utc_off);
      MqlDateTime dc, dp;
      TimeToStruct(tu,dc); TimeToStruct(tu_prev,dp);
      if(dc.hour < Inp_SessStart || dc.hour > Inp_SessEnd) continue;
      if(dp.hour < Inp_SessStart || dp.hour > Inp_SessEnd) continue;

      // --- 3. Patron Engulfing Alcista
      bool prev_bear = (arr_c[i+1] < arr_o[i+1]);
      bool curr_bull = (arr_c[i]  >= arr_o[i]);
      double pb = arr_o[i+1] - arr_c[i+1];
      double cb = arr_c[i]   - arr_o[i];
      bool engulf = (arr_o[i] <= arr_c[i+1]) &&
                   (arr_c[i] >= arr_o[i+1]) &&
                   (cb > pb) && (cb > 0.0);
      if(!(prev_bear && curr_bull && engulf)) continue;

      // --- 4. Limite de concurrencia
      if(sim_count >= Inp_MaxConcurrent) continue;

      // --- 5. Filtro de dispersion espacial
      bool too_close = false;
      double dist_req = arr_atr[i] * Inp_MinDistATR;
      for(int j = 0; j < sim_count; j++)
         if(MathAbs(arr_c[i] - sim[j].ep) < dist_req){too_close=true; break;}
      if(too_close) continue;

      // --- 6. Abrir trade simulado
      g_hs++;
      sim[sim_count].ep = arr_c[i];
      sim[sim_count].tp = arr_c[i] + arr_atr[i] * Inp_TP_Mult;
      sim[sim_count].sl = arr_c[i] - arr_atr[i] * Inp_SL_Mult;
      sim[sim_count].te = arr_t[i];
      sim_count++;

      if(Inp_ShowCandles)
      {
         _DrawBody(arr_t[i+1],arr_o[i+1],arr_c[i+1],C'80,15,15',"PT_"+_TS(arr_t[i+1]));
         _DrawBody(arr_t[i],  arr_o[i],  arr_c[i],  C'10,80,30', "PT_"+_TS(arr_t[i]));
      }
      _DrawOpen(arr_t[i], arr_c[i],
                arr_c[i] + arr_atr[i] * Inp_TP_Mult,
                arr_c[i] - arr_atr[i] * Inp_SL_Mult);
   }
}

//+------------------------------------------------------------------+
void _CheckForSignal()
{
   datetime t1 = iTime(_Symbol,_Period,1);
   datetime t2 = iTime(_Symbol,_Period,2);
   if(t1 == 0 || t2 == 0) return;

   int utc_off = _UTCOffset();
   MqlDateTime dt1, dt2;
   TimeToStruct((datetime)((int)t1 - utc_off), dt1);
   TimeToStruct((datetime)((int)t2 - utc_off), dt2);
   if(dt1.hour < Inp_SessStart || dt1.hour > Inp_SessEnd) return;
   if(dt2.hour < Inp_SessStart || dt2.hour > Inp_SessEnd) return;

   double o1=iOpen(_Symbol,_Period,1), c1=iClose(_Symbol,_Period,1);
   double o2=iOpen(_Symbol,_Period,2), c2=iClose(_Symbol,_Period,2);

   double atr_buf[]; ArraySetAsSeries(atr_buf,true);
   if(CopyBuffer(g_atr_handle,0,1,1,atr_buf) <= 0) return;
   double atr_val = atr_buf[0];
   if(atr_val <= 0.0 || atr_val == EMPTY_VALUE) return;

   bool prev_bear=(c2<o2), curr_bull=(c1>=o1);
   bool engulf=(o1<=c2)&&(c1>=o2)&&((c1-o1)>(o2-c2))&&((c1-o1)>0.0);
   if(!(prev_bear && curr_bull && engulf)) return;

   double ep  = c1;
   double tp_p = NormalizeDouble(c1 + atr_val * Inp_TP_Mult, _Digits);
   double sl_p = NormalizeDouble(c1 - atr_val * Inp_SL_Mult, _Digits);

   // Control de cardinalidad y dispersion espacial
   if(g_live_count >= Inp_MaxConcurrent) return;
   double dist_req = atr_val * Inp_MinDistATR;
   for(int i = 0; i < g_live_count; i++)
      if(MathAbs(ep - g_live_trades[i].ep) < dist_req) return;

   if(Inp_ShowCandles)
   {
      _DrawBody(t2,o2,c2,C'80,15,15',"LV_"+_TS(t2));
      _DrawBody(t1,o1,c1,C'10,80,30',"LV_"+_TS(t1));
   }
   _DrawOpen(t1,ep,tp_p,sl_p);

   string msg = StringFormat("ENGULFING BULL | %s | Entry=%.*f | TP=%.*f | SL=%.*f",
                             _Symbol,_Digits,ep,_Digits,tp_p,_Digits,sl_p);
   Print(">>> ",msg);
   if(!MQLInfoInteger(MQL_TESTER)){Alert(msg); SendNotification(msg);}

   if(!Inp_AutoTrade) return;
   g_ls++;
   if(g_trade.Buy(Inp_LotSize,_Symbol,0.0,sl_p,tp_p,"EB_XAU"))
      _AddLiveTrade(g_trade.ResultOrder(), ep, tp_p, sl_p, t1);
   else { g_ls--; Print("ERROR BUY: ",g_trade.ResultRetcodeDescription()); }
}

//+------------------------------------------------------------------+
void _ManageLiveTrades()
{
   for(int idx = g_live_count - 1; idx >= 0; idx--)
   {
      if(PositionSelectByTicket(g_live_trades[idx].ticket)) continue;
      double   exit_profit = 0.0;
      datetime t_close     = TimeCurrent();
      if(HistorySelect(g_live_trades[idx].te - 60, TimeCurrent() + 60))
      {
         for(int d = HistoryDealsTotal()-1; d >= 0; d--)
         {
            ulong deal = HistoryDealGetTicket(d);
            if(HistoryDealGetString(deal,DEAL_SYMBOL) != _Symbol) continue;
            if(HistoryDealGetInteger(deal,DEAL_MAGIC) != (long)Inp_Magic) continue;
            if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
            if((ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID)!=g_live_trades[idx].ticket) continue;
            exit_profit = HistoryDealGetDouble(deal,DEAL_PROFIT);
            t_close     = (datetime)HistoryDealGetInteger(deal,DEAL_TIME);
            break;
         }
      }
      bool is_win = (exit_profit >= 0.0);
      if(is_win) g_lw++; else g_ll++;
      g_lp += exit_profit;
      _DrawClose(t_close, g_live_trades[idx].te,
                 g_live_trades[idx].ep, g_live_trades[idx].tp,
                 g_live_trades[idx].sl, is_win);
      _RemoveLiveTrade(idx);
   }
}

//+------------------------------------------------------------------+
void _DrawBody(datetime t, double op, double cl, color c, const string sfx)
{
   string nm = PFX_BODY + sfx;
   if(ObjectFind(g_chart_id,nm) >= 0) return;
   datetime t2  = t + (datetime)PeriodSeconds(_Period);
   double   top = MathMax(op,cl), bot = MathMin(op,cl);
   if(top - bot < _Point) top = bot + _Point;
   ObjectCreate(g_chart_id,nm,OBJ_RECTANGLE,0,t,top,t2,bot);
   ObjectSetInteger(g_chart_id,nm,OBJPROP_COLOR,c);
   ObjectSetInteger(g_chart_id,nm,OBJPROP_FILL,true);
   ObjectSetInteger(g_chart_id,nm,OBJPROP_BACK,true);
   ObjectSetInteger(g_chart_id,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(g_chart_id,nm,OBJPROP_HIDDEN,true);
}

void _DrawOpen(datetime te, double ep, double tp, double sl)
{
   string ts = _TS(te);
   string nm_e = PFX_ENTRY + ts;
   if(ObjectFind(g_chart_id,nm_e) < 0)
   {
      ObjectCreate(g_chart_id,nm_e,OBJ_HLINE,0,0,ep);
      ObjectSetInteger(g_chart_id,nm_e,OBJPROP_COLOR,clrGold);
      ObjectSetInteger(g_chart_id,nm_e,OBJPROP_STYLE,STYLE_DASH);
      ObjectSetInteger(g_chart_id,nm_e,OBJPROP_WIDTH,1);
      ObjectSetInteger(g_chart_id,nm_e,OBJPROP_BACK,true);
      ObjectSetInteger(g_chart_id,nm_e,OBJPROP_SELECTABLE,false);
   }
   if(!Inp_ShowLabels) return;

   string nm_le = PFX_LABEL+"E_"+ts;
   if(ObjectFind(g_chart_id,nm_le) < 0)
   {
      ObjectCreate(g_chart_id,nm_le,OBJ_TEXT,0,te,ep);
      ObjectSetString (g_chart_id,nm_le,OBJPROP_TEXT,"  Entry "+DoubleToString(ep,_Digits));
      ObjectSetInteger(g_chart_id,nm_le,OBJPROP_COLOR,clrGold);
      ObjectSetInteger(g_chart_id,nm_le,OBJPROP_FONTSIZE,8);
      ObjectSetString (g_chart_id,nm_le,OBJPROP_FONT,"Arial");
      ObjectSetInteger(g_chart_id,nm_le,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
      ObjectSetInteger(g_chart_id,nm_le,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(g_chart_id,nm_le,OBJPROP_HIDDEN,true);
   }
   string nm_lt = PFX_LABEL+"T_"+ts;
   if(ObjectFind(g_chart_id,nm_lt) < 0)
   {
      ObjectCreate(g_chart_id,nm_lt,OBJ_TEXT,0,te,tp);
      ObjectSetString (g_chart_id,nm_lt,OBJPROP_TEXT,"  TP "+DoubleToString(tp,_Digits));
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_COLOR,clrLimeGreen);
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_FONTSIZE,8);
      ObjectSetString (g_chart_id,nm_lt,OBJPROP_FONT,"Arial");
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_HIDDEN,true);
   }
   string nm_ls = PFX_LABEL+"S_"+ts;
   if(ObjectFind(g_chart_id,nm_ls) < 0)
   {
      ObjectCreate(g_chart_id,nm_ls,OBJ_TEXT,0,te,sl);
      ObjectSetString (g_chart_id,nm_ls,OBJPROP_TEXT,"  SL "+DoubleToString(sl,_Digits));
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_COLOR,clrOrangeRed);
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_FONTSIZE,8);
      ObjectSetString (g_chart_id,nm_ls,OBJPROP_FONT,"Arial");
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_HIDDEN,true);
   }
}

void _DrawClose(datetime tc, datetime te, double ep, double tp, double sl, bool win)
{
   string tse    = _TS(te);
   color  zone_c = win ? C'0,38,8'    : C'38,0,0';
   color  line_c = win ? clrLimeGreen : clrOrangeRed;
   string res_tx = win ? "  TP HIT"  : "  SL HIT";
   double exit_p = win ? tp : sl;

   if(Inp_ShowZone)
   {
      string nm_z = PFX_ZONE + tse;
      if(ObjectFind(g_chart_id,nm_z) < 0)
      {
         ObjectCreate(g_chart_id,nm_z,OBJ_RECTANGLE,0,
                      te,MathMax(tp,ep),tc,MathMin(sl,ep));
         ObjectSetInteger(g_chart_id,nm_z,OBJPROP_COLOR,zone_c);
         ObjectSetInteger(g_chart_id,nm_z,OBJPROP_FILL,true);
         ObjectSetInteger(g_chart_id,nm_z,OBJPROP_BACK,true);
         ObjectSetInteger(g_chart_id,nm_z,OBJPROP_SELECTABLE,false);
      }
   }
   string nm_lt = PFX_LTP + tse;
   if(ObjectFind(g_chart_id,nm_lt) < 0)
   {
      ObjectCreate(g_chart_id,nm_lt,OBJ_TREND,0,te,tp,tc,tp);
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_COLOR,clrLimeGreen);
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_WIDTH,1);
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_BACK,true);
      ObjectSetInteger(g_chart_id,nm_lt,OBJPROP_SELECTABLE,false);
   }
   string nm_ls = PFX_LSL + tse;
   if(ObjectFind(g_chart_id,nm_ls) < 0)
   {
      ObjectCreate(g_chart_id,nm_ls,OBJ_TREND,0,te,sl,tc,sl);
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_COLOR,clrOrangeRed);
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_STYLE,STYLE_DOT);
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_WIDTH,1);
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_RAY_RIGHT,false);
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_BACK,true);
      ObjectSetInteger(g_chart_id,nm_ls,OBJPROP_SELECTABLE,false);
   }
   if(Inp_ShowLabels)
   {
      string nm_r = PFX_RESULT + _TS(tc);
      if(ObjectFind(g_chart_id,nm_r) < 0)
      {
         ObjectCreate(g_chart_id,nm_r,OBJ_TEXT,0,tc,exit_p);
         ObjectSetString (g_chart_id,nm_r,OBJPROP_TEXT,res_tx);
         ObjectSetInteger(g_chart_id,nm_r,OBJPROP_COLOR,line_c);
         ObjectSetInteger(g_chart_id,nm_r,OBJPROP_FONTSIZE,9);
         ObjectSetString (g_chart_id,nm_r,OBJPROP_FONT,"Arial Bold");
         ObjectSetInteger(g_chart_id,nm_r,OBJPROP_ANCHOR,ANCHOR_LEFT);
         ObjectSetInteger(g_chart_id,nm_r,OBJPROP_SELECTABLE,false);
      }
   }
}

//+------------------------------------------------------------------+
void _RefreshStatsPanel()
{
   int    ht  = g_hw + g_hl;
   double hwr = ht > 0 ? (double)g_hw / ht * 100.0 : 0.0;
   double hex = g_hs > 0 ? g_hp / (double)g_hs : 0.0;
   int    lt  = g_lw + g_ll;
   double lwr = lt > 0 ? (double)g_lw / lt * 100.0 : 0.0;
   double be_wr = (Inp_TP_Mult + Inp_SL_Mult) > 0.0
                  ? Inp_SL_Mult / (Inp_TP_Mult + Inp_SL_Mult) * 100.0 : 0.0;

   string period_str = EnumToString(_Period);
   StringReplace(period_str,"PERIOD_","");

   int active_pos = 0;
   for(int p = PositionsTotal()-1; p >= 0; p--)
      if(PositionGetSymbol(p)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==(long)Inp_Magic) active_pos++;

   string mode_str = !Inp_AutoTrade ? "SOLO VISUAL"
                   : g_live_count > 0
                     ? StringFormat("%d TRADE(S) ABIERTO(S)", g_live_count)
                     : "EN ESPERA";

   string rows[]; color clrs[]; int n_rows;

   if(!Inp_AutoTrade)
   {
      //=== MODO VISUAL: backtest concurrente =======================
      n_rows = 18; ArrayResize(rows,n_rows); ArrayResize(clrs,n_rows);

      rows[0] =StringFormat(" Activo  : %s  [%s]",_Symbol,period_str);
      clrs[0] =clrSilver;
      rows[1] =StringFormat(" Sesion  : %02d:00 - %02d:59 UTC",Inp_SessStart,Inp_SessEnd);
      clrs[1] =clrSilver;
      rows[2] =StringFormat(" Config  : TP x%.1f | SL x%.1f | ATR(%d)",
                             Inp_TP_Mult,Inp_SL_Mult,Inp_ATR_Period);
      clrs[2] =clrSilver;
      rows[3] =StringFormat(" Concurr.: Max %d | Dist %.1f ATR",
                             Inp_MaxConcurrent,Inp_MinDistATR);
      clrs[3] =C'120,120,150';
      rows[4] =StringFormat(" Break-even: %.1f%%  (actual: %.1f%%)",be_wr,hwr);
      clrs[4] =(hwr >= be_wr) ? clrLimeGreen : clrOrangeRed;
      rows[5] =" ----------------------------------";
      clrs[5] =C'35,35,55';
      rows[6] =" [ BACKTEST CONCURRENTE ]";
      clrs[6] =clrAquamarine;
      rows[7] =StringFormat(" Senales  : %d",g_hs);
      clrs[7] =clrWhite;
      rows[8] =StringFormat(" Ganadas  : %d  (%.1f%%)",g_hw,hwr);
      clrs[8] =clrLimeGreen;
      rows[9] =StringFormat(" Perdidas : %d",g_hl);
      clrs[9] =clrCrimson;
      rows[10]=StringFormat(" PnL ATR  : %+.2f unidades",g_hp);
      clrs[10]=g_hp >= 0.0 ? clrLimeGreen : clrOrangeRed;
      rows[11]=StringFormat(" Esperanza: %+.4f ATR/op",hex);
      clrs[11]=hex >= 0.0 ? clrLimeGreen : clrOrangeRed;
      rows[12]=StringFormat(" Cerrados : %d de %d senales",ht,g_hs);
      clrs[12]=C'120,120,150';
      rows[13]=" ----------------------------------";
      clrs[13]=C'35,35,55';
      rows[14]=StringFormat(" Modo     : %s",mode_str);
      clrs[14]=clrGold;
      rows[15]=" AutoTrade: DESACTIVADO";
      clrs[15]=C'150,150,170';
      rows[16]=StringFormat(" Lot=%.2f | Magic=%I64u",Inp_LotSize,(ulong)Inp_Magic);
      clrs[16]=C'80,80,105';
      rows[17]=" ";
      clrs[17]=clrBlack;
   }
   else
   {
      //=== MODO AUTO-TRADING: solo trading en vivo =================
      n_rows = 15; ArrayResize(rows,n_rows); ArrayResize(clrs,n_rows);

      rows[0] =StringFormat(" Activo  : %s  [%s]",_Symbol,period_str);
      clrs[0] =clrSilver;
      rows[1] =StringFormat(" Sesion  : %02d:00 - %02d:59 UTC",Inp_SessStart,Inp_SessEnd);
      clrs[1] =clrSilver;
      rows[2] =StringFormat(" Config  : TP x%.1f | SL x%.1f | ATR(%d)",
                             Inp_TP_Mult,Inp_SL_Mult,Inp_ATR_Period);
      clrs[2] =clrSilver;
      rows[3] =StringFormat(" Concurr.: Max %d | Dist %.1f ATR",
                             Inp_MaxConcurrent,Inp_MinDistATR);
      clrs[3] =C'120,120,150';
      rows[4] =" ----------------------------------";
      clrs[4] =C'35,35,55';
      rows[5] =" [ TRADING EN VIVO ]";
      clrs[5] =clrGold;
      rows[6] =StringFormat(" Estado   : %s",mode_str);
      clrs[6] =g_live_count > 0 ? clrGold : clrSilver;
      rows[7] =StringFormat(" Posicion : %d abierta(s)",active_pos);
      clrs[7] =active_pos > 0 ? clrGold : clrSilver;
      rows[8] =StringFormat(" Senales  : %d",g_ls);
      clrs[8] =clrWhite;
      rows[9] =StringFormat(" W / L    : %d / %d  (%.1f%%)",g_lw,g_ll,lwr);
      clrs[9] =clrWhite;
      rows[10]=StringFormat(" P&L      : %+.2f %s",
                             g_lp,AccountInfoString(ACCOUNT_CURRENCY));
      clrs[10]=g_lp >= 0.0 ? clrLimeGreen : clrOrangeRed;
      rows[11]=" ----------------------------------";
      clrs[11]=C'35,35,55';
      rows[12]=StringFormat(" Lot=%.2f | Magic=%I64u",Inp_LotSize,(ulong)Inp_Magic);
      clrs[12]=clrSilver;
      rows[13]=" AutoTrade: ACTIVO";
      clrs[13]=clrLimeGreen;
      rows[14]=" ";
      clrs[14]=clrBlack;
   }

   //--- Layout
   const int X_DIST=280, Y_GAP=17, Y_TOP=18, PNL_W=290, PNL_RX=5;
   int panel_h = Y_TOP + (n_rows + 2) * Y_GAP + 14;

   //=== FONDO NEGRO SOLIDO =========================================
   string nm_bg = PFX_TABLE+"BG";
   if(ObjectFind(g_chart_id,nm_bg) < 0)
      ObjectCreate(g_chart_id,nm_bg,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_XDISTANCE,PNL_RX);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_YDISTANCE,Y_TOP-5);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_XSIZE,PNL_W);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_YSIZE,panel_h);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_BGCOLOR,clrBlack);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_COLOR,
                    Inp_AutoTrade ? C'180,130,0' : C'0,160,70');
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_WIDTH,1);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(g_chart_id,nm_bg,OBJPROP_BACK,false);

   //=== CABECERA ===================================================
   string nm_h = PFX_TABLE+"00";
   if(ObjectFind(g_chart_id,nm_h) < 0)
      ObjectCreate(g_chart_id,nm_h,OBJ_LABEL,0,0,0);
   ObjectSetInteger(g_chart_id,nm_h,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(g_chart_id,nm_h,OBJPROP_XDISTANCE,X_DIST);
   ObjectSetInteger(g_chart_id,nm_h,OBJPROP_YDISTANCE,Y_TOP);
   ObjectSetString (g_chart_id,nm_h,OBJPROP_TEXT,
                    " ENGULFING BULL - "+ASSET_LABEL+" EA ");
   ObjectSetString (g_chart_id,nm_h,OBJPROP_FONT,"Courier New");
   ObjectSetInteger(g_chart_id,nm_h,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(g_chart_id,nm_h,OBJPROP_COLOR,C'0,210,88');
   ObjectSetInteger(g_chart_id,nm_h,OBJPROP_BACK,false);
   ObjectSetInteger(g_chart_id,nm_h,OBJPROP_SELECTABLE,false);

   //=== FILAS ======================================================
   for(int k = 0; k < n_rows; k++)
   {
      string nm = PFX_TABLE + IntegerToString(k+1);
      if(ObjectFind(g_chart_id,nm) < 0)
         ObjectCreate(g_chart_id,nm,OBJ_LABEL,0,0,0);
      ObjectSetInteger(g_chart_id,nm,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
      ObjectSetInteger(g_chart_id,nm,OBJPROP_XDISTANCE,X_DIST);
      ObjectSetInteger(g_chart_id,nm,OBJPROP_YDISTANCE,Y_TOP+(k+1)*Y_GAP+2);
      ObjectSetString (g_chart_id,nm,OBJPROP_TEXT,rows[k]);
      ObjectSetString (g_chart_id,nm,OBJPROP_FONT,"Courier New");
      ObjectSetInteger(g_chart_id,nm,OBJPROP_FONTSIZE,8);
      ObjectSetInteger(g_chart_id,nm,OBJPROP_COLOR,clrs[k]);
      ObjectSetInteger(g_chart_id,nm,OBJPROP_BACK,false);
      ObjectSetInteger(g_chart_id,nm,OBJPROP_SELECTABLE,false);
   }
   // Limpiar filas sobrantes del modo anterior
   for(int k = n_rows; k < TABLE_ROWS_MAX; k++)
   {
      string nm = PFX_TABLE+IntegerToString(k+1);
      if(ObjectFind(g_chart_id,nm) >= 0)
         ObjectSetString(g_chart_id,nm,OBJPROP_TEXT,"");
   }
}

void _DeleteAllObjects()
{
   ObjectsDeleteAll(g_chart_id,PFX_ZONE);  ObjectsDeleteAll(g_chart_id,PFX_ENTRY);
   ObjectsDeleteAll(g_chart_id,PFX_LTP);   ObjectsDeleteAll(g_chart_id,PFX_LSL);
   ObjectsDeleteAll(g_chart_id,PFX_LABEL); ObjectsDeleteAll(g_chart_id,PFX_RESULT);
   ObjectsDeleteAll(g_chart_id,PFX_BODY);
   ObjectDelete(g_chart_id,PFX_TABLE+"BG");
   ObjectDelete(g_chart_id,PFX_TABLE+"00");
   for(int k=1; k<=TABLE_ROWS_MAX; k++)
      ObjectDelete(g_chart_id,PFX_TABLE+IntegerToString(k));
}

string _TS(datetime t)
{
   string s = TimeToString(t, TIME_DATE|TIME_MINUTES);
   StringReplace(s,":",""); StringReplace(s,".",""); StringReplace(s," ","_");
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
