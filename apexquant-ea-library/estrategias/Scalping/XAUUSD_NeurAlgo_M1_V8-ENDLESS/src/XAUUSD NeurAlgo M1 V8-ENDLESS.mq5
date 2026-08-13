//+------------------------------------------------------------------+
//|   APEXQUANT V8-ENDLESS — XAUUSD 24/7 DIRECTIONAL CYCLE           |
//|                                                                  |
//|   REDISEÑO TOTAL (V8-ENDLESS) basado en V7.9.2-XAU:             |
//|                                                                  |
//|   1) OPERACION 24/7: sin sesiones, sin ventana horaria,          |
//|      entradas primarias cada ~Inp_PrimaryIntervalSec.            |
//|   2) RECUPERACION SIN LIMITE FIJO: no hay Inp_RecoveryMaxOrders. |
//|      El bloque agrega posiciones mientras este en perdida,       |
//|      hasta cerrar en positivo. Solo el margen libre lo frena.    |
//|   3) CIERRE CON MAS GANANCIA: target dinamico = ATR del          |
//|      momento + ganancia media del ciclo (se amplia si se puede). |
//|   4) BREAK-EVEN OBLIGATORIO: si el bloque toca 0+, todos los     |
//|      SL suben al precio de entrada. NUNCA vuelve a negativo.     |
//|   5) TRAILING STOP que persigue: mientras siga positivo, el SL   |
//|      persigue al precio; si revierte Inp_TrailATR, cierra con    |
//|      la ganancia acumulada (maximo extraido).                    |
//|   6) LO INNECESARIO ELIMINADO: LBC, detangle, BSE stages 2-4,    |
//|      NET_HEDGE, basket TP, harvest, rescue, sesiones, storms.    |
//|                                                                  |
//|   ADVERTENCIA: la recuperacion sin limite es MARTINGALA.         |
//|   En una tendencia fuerte unidireccional puede acumular perdidas |
//|   grandes hasta que revierta. Valida en DEMO y controla margen.  |
//+------------------------------------------------------------------+
#property copyright "APEXQUANT V8-ENDLESS"
#property version   "8.00"
#property strict
#property description "XAUUSD | V8-ENDLESS | 24/7 | Recovery ilimitada + BE + Trailing"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

#define VERSION_STR   "APEXQUANT_V8-ENDLESS"
#define MAX_POSITIONS 80

//=================================================================
//  INPUTS (simplificados)
//=================================================================
input group "=== CONFIGURACION PRINCIPAL ==="
input long   Inp_Magic                 = 1111;
input int    Inp_EntryTimeframe        = 1;      // TF de entradas: 1=M1, 5=M5, 15=M15, 60=H1
input double Inp_LotBase               = 0.05;
input double Inp_LotMaximum            = 2.00;
input double Inp_LotMultiplier         = 1.60;   // Multiplicador de lote por nivel de recovery
input int    Inp_PrimaryIntervalSec    = 30;     // Entrada primaria cada N seg si no hay bloque
input int    Inp_AfterBlockPauseSec    = 5;      // Pausa corta tras cerrar un bloque
input int    Inp_MaxSpreadPoints       = 800;    // Filtro de spread (XAUUSD puntos)

input group "=== ENTRADA PRIMARIA (24/7) ==="
input bool   Inp_UseTEMAKalman         = true;
input int    Inp_TEMAFastPeriod        = 21;
input int    Inp_TEMASlowPeriod        = 55;
input double Inp_KalmanQ               = 0.0001;
input double Inp_KalmanR               = 0.005;
input bool   Inp_UseEMA200Filter       = true;   // Solo primarias a favor del EMA200
input int    Inp_EMA200Period          = 200;

input group "=== RECUPERACION (sin limite fijo) ==="
input double Inp_RecoveryStepUSD       = 3.00;   // PnL negativo que dispara recovery
input double Inp_RecoveryDistATR       = 0.60;   // Distancia minima al lote anterior (x ATR)
input double Inp_RecoveryMoveATR       = 1.20;   // Movimiento esperado para recuperar (x ATR)
input int    Inp_RecoveryIntervalSec   = 5;      // Minimo segundos entre recoveries
input double Inp_RecoveryGainATR       = 0.35;   // Ganancia objetivo en recovery (x ATR)
input bool   Inp_RecoverWithTrend      = true;   // Recoveries en direccion del TEMA si confirma
input double Inp_MaxMarginUsedPct      = 60.0;   // % de margen libre usado: corta recovery

input group "=== CIERRE / BREAK-EVEN / TRAILING ==="
input double Inp_BlockTPUSD            = 4.00;   // Ganancia minima del bloque para cerrar
input double Inp_BlockTPATR            = 0.60;   // Extras de ATR que amplian el target
input double Inp_BE_ATR                = 0.40;   // Avance favorable (x ATR) para activar BE
input double Inp_BE_MinUSD             = 1.00;   // PnL minimo para activar BE
input double Inp_TrailATR              = 0.80;   // Distancia del trailing (x ATR)
input double Inp_TrailMinUSD           = 2.00;   // Trailing solo si la ganancia supera esto
input bool   Inp_CloseLockedOnRetrace  = true;   // Cierra el bloque si el precio revierte del pico

input group "=== PROTECCION (opcional) ==="
input bool   Inp_UseDailyLimit         = false;  // false = 24/7 sin parar (lo que pediste)
input double Inp_DailyLossUSD          = -200.0;
input double Inp_EquityStopPct         = 0.0;    // 0 = desactivado; 20 = para al -20% del balance
input bool   Inp_ShowDashboard         = true;

//=================================================================
//  ENUMS / STRUCTS
//=================================================================
enum ENUM_ENTRY_TF { TF_M1=1, TF_M5=5, TF_M15=15, TF_H1=60 };

struct PosRec {
   ulong    ticket;
   int      posType;
   double   openPrice;
   double   volume;
   datetime openTime;
   string   comment;
   int      level;
};

struct BlockState {
   int      totalPos;
   double   totalProfit;
   double   buyVolume, sellVolume;
   double   avgBuy, avgSell;
   double   peakProfit;       // pico de PnL del bloque (para trailing)
   double   peakFavPrice;     // precio mas favorable alcanzado (para trailing SL)
   bool     beLocked;         // break-even activado
   bool     trailActive;
   double   lockPrice;        // precio de referencia del trailing
   datetime lastEntryTime;
   datetime lastRecoveryTime;
   datetime blockStart;
   int      recoveryCount;
   double   cycleWinsSum;
   int      cycleWinsCount;
   double   realizedPnl;
   int      closedBlocks;
};

//=================================================================
//  HANDLES Y ESTADO
//=================================================================
CTrade      m_trade;
PosRec      m_pos[MAX_POSITIONS];
int         m_posCount=0;
BlockState  m_blk;
double      m_initialBalance=0;
datetime    m_lastPrimaryTime=0;
bool        m_dailyLimitHit=false;
datetime    m_lastDailyReset=0;
int         m_hATR=-1, m_hEMAFast=-1, m_hEMASlow=-1, m_hEMA200=-1, m_hATRSlow=-1;
int         m_hRSI=-1, m_hMACD=-1, m_hADX=-1;
double      m_emaFast=0, m_emaSlow=0, m_ema200=0, m_atr=0, m_atrSlow=0, m_rsi=0;
double      m_macdMain=0, m_macdSig=0, m_adx=0;
int         m_htfTrend=0;
double      m_temaF_e1=0,m_temaF_e2=0,m_temaF_e3=0; bool m_temaF_init=false;
double      m_temaS_e1=0,m_temaS_e2=0,m_temaS_e3=0; bool m_temaS_init=false;
double      m_kalF_x=0,m_kalF_p=1.0; bool m_kalF_init=false;
double      m_kalS_x=0,m_kalS_p=1.0; bool m_kalS_init=false;
int         m_trendConfirmed=0;
bool        m_isPaused=false;
double      m_totalPnL=0;
int         m_tradesClosed=0, m_totalWins=0, m_totalLosses=0;
double      m_sumWins=0, m_sumLosses=0;
double      m_bestEquity=0;
datetime    m_lastDashTime=0;

//=================================================================
//  HELPERS
//=================================================================
double NormLot(double lot)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),Inp_LotMaximum);
   if(step<=0) step=0.01;
   lot=MathFloor(lot/step)*step;
   return NormalizeDouble(MathMax(minL,MathMin(maxL,lot)),2);
}

double GetTickVal()  { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE); }
double GetTickSize() { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); }

double ATR2USD(double atrMult, double lot)
{
   double tv=GetTickVal(),ts=GetTickSize();
   if(tv<=0||ts<=0||m_atr<=0||lot<=0) return 0;
   return NormalizeDouble((m_atr*atrMult/ts)*tv*lot,2);
}

double DistToUSD(double dist, double lot)
{
   double tv=GetTickVal(),ts=GetTickSize();
   if(tv<=0||ts<=0||dist<=0||lot<=0) return 0;
   return NormalizeDouble((dist/ts)*tv*lot,2);
}

bool GetTick(MqlTick &t) { return SymbolInfoTick(_Symbol,t); }

bool SpreadOK()
{
   return (SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=Inp_MaxSpreadPoints);
}

bool MarginOK(double lot, ENUM_ORDER_TYPE type)
{
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double used=AccountInfoDouble(ACCOUNT_MARGIN);
   if(eq<=0) return false;
   double usedPct=(eq>0)?(used+OrderCalcMarginPreview(lot,type))/eq*100.0:100.0;
   if(usedPct>=Inp_MaxMarginUsedPct) return false;
   if(free<eq*0.01) return false;
   return true;
}

double OrderCalcMarginPreview(double lot, ENUM_ORDER_TYPE type)
{
   double marg=0; MqlTick t; if(!GetTick(t)) return 0;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg)) return marg;
   return 0;
}

double CalcTargetLot()
{
   // Lote para recuperar todo el bloque en un movimiento de Inp_RecoveryMoveATR x ATR
   double tv=GetTickVal(),ts=GetTickSize();
   if(m_atr<=0||tv<=0||ts<=0) return Inp_LotBase;
   double moveDist=m_atr*Inp_RecoveryMoveATR;
   double profitPerLot=(moveDist/ts)*tv;
   if(profitPerLot<=0) return Inp_LotBase;
   double loss=MathAbs(m_blk.totalProfit);
   double need=loss+Inp_BlockTPUSD+(loss*0.10); // margen extra del 10%
   double lot=need/profitPerLot;
   lot=MathMax(lot,Inp_LotBase);
   return NormLot(lot);
}

//=================================================================
//  INDICADORES
//=================================================================
void UpdateMarket()
{
   MqlTick t; if(!GetTick(t)) return;
   double b[1];
   if(m_hATR>=0&&CopyBuffer(m_hATR,0,0,1,b)==1) m_atr=b[0];
   if(m_hATRSlow>=0&&CopyBuffer(m_hATRSlow,0,1,1,b)==1) m_atrSlow=b[0];
   if(m_hEMAFast>=0&&CopyBuffer(m_hEMAFast,0,0,1,b)==1) m_emaFast=b[0];
   if(m_hEMASlow>=0&&CopyBuffer(m_hEMASlow,0,0,1,b)==1) m_emaSlow=b[0];
   if(m_hEMA200>=0&&CopyBuffer(m_hEMA200,0,1,1,b)==1) m_ema200=b[0];
   if(m_hRSI>=0&&CopyBuffer(m_hRSI,0,0,1,b)==1) m_rsi=b[0];
   if(m_hMACD>=0){double m2[1],s[1];if(CopyBuffer(m_hMACD,0,0,1,m2)==1)m_macdMain=m2[0];if(CopyBuffer(m_hMACD,1,0,1,s)==1)m_macdSig=s[0];}
   if(m_hADX>=0&&CopyBuffer(m_hADX,0,0,1,b)==1) m_adx=b[0];

   // HTF trend (H1) por EMA
   ENUM_TIMEFRAMES htfEMA=PERIOD_H1;
   static int hHTFFast=-1, hHTFSlow=-1;
   if(hHTFFast<0){hHTFFast=iMA(_Symbol,htfEMA,21,0,MODE_EMA,PRICE_CLOSE);hHTFSlow=iMA(_Symbol,htfEMA,55,0,MODE_EMA,PRICE_CLOSE);}
   double hf[1],hs[1];
   if(hHTFFast>=0&&CopyBuffer(hHTFFast,0,0,1,hf)==1&&hHTFSlow>=0&&CopyBuffer(hHTFSlow,0,0,1,hs)==1)
      m_htfTrend=(hf[0]>hs[0]*1.0001)?1:(hf[0]<hs[0]*0.9999)?-1:0;

   UpdateTEMAKalman((t.bid+t.ask)/2.0);
}

void UpdateTEMAKalman(double price)
{
   if(!Inp_UseTEMAKalman){
      m_trendConfirmed=0; return;
   }
   if(price<=0) return;
   double alphaF=2.0/(double)(Inp_TEMAFastPeriod+1);
   if(!m_temaF_init){m_temaF_e1=m_temaF_e2=m_temaF_e3=price;m_temaF_init=true;}
   m_temaF_e1+=alphaF*(price-m_temaF_e1); m_temaF_e2+=alphaF*(m_temaF_e1-m_temaF_e2);
   m_temaF_e3+=alphaF*(m_temaF_e2-m_temaF_e3);
   double temaFast=3.0*m_temaF_e1-3.0*m_temaF_e2+m_temaF_e3;

   double alphaS=2.0/(double)(Inp_TEMASlowPeriod+1);
   if(!m_temaS_init){m_temaS_e1=m_temaS_e2=m_temaS_e3=price;m_temaS_init=true;}
   m_temaS_e1+=alphaS*(price-m_temaS_e1); m_temaS_e2+=alphaS*(m_temaS_e1-m_temaS_e2);
   m_temaS_e3+=alphaS*(m_temaS_e2-m_temaS_e3);
   double temaSlow=3.0*m_temaS_e1-3.0*m_temaS_e2+m_temaS_e3;

   if(!m_kalF_init){m_kalF_x=temaFast;m_kalF_p=1.0;m_kalF_init=true;}
   m_kalF_p+=Inp_KalmanQ; double kgF=m_kalF_p/(m_kalF_p+Inp_KalmanR);
   m_kalF_x+=kgF*(temaFast-m_kalF_x); m_kalF_p*=(1.0-kgF);

   if(!m_kalS_init){m_kalS_x=temaSlow;m_kalS_p=1.0;m_kalS_init=true;}
   m_kalS_p+=Inp_KalmanQ; double kgS=m_kalS_p/(m_kalS_p+Inp_KalmanR);
   m_kalS_x+=kgS*(temaSlow-m_kalS_x); m_kalS_p*=(1.0-kgS);

   bool temaBull=(temaFast>temaSlow), temaBear=(temaFast<temaSlow);
   bool kalBull=(m_kalF_x>m_kalS_x), kalBear=(m_kalF_x<m_kalS_x);
   if(temaBull&&kalBull) m_trendConfirmed=1;
   else if(temaBear&&kalBear) m_trendConfirmed=-1;
   else m_trendConfirmed=0;
}

//=================================================================
//  PORTFOLIO / BLOQUE
//=================================================================
void UpdateBlock()
{
   ZeroMemory(m_blk);
   m_posCount=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      m_blk.totalPos++; m_blk.totalProfit+=pf;
      if(pt==POSITION_TYPE_BUY){m_blk.buyVolume+=vol;m_blk.avgBuy=op;}
      else{m_blk.sellVolume+=vol;m_blk.avgSell=op;}
      if(m_posCount<MAX_POSITIONS){
         m_pos[m_posCount].ticket=t;m_pos[m_posCount].posType=pt;
         m_pos[m_posCount].openPrice=op;m_pos[m_posCount].volume=vol;
         m_pos[m_posCount].openTime=(datetime)PositionGetInteger(POSITION_TIME);
         m_pos[m_posCount].comment=PositionGetString(POSITION_COMMENT);
         m_posCount++;
      }
   }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>m_bestEquity) m_bestEquity=eq;
}

//=================================================================
//  APERTURA
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type,double lot,string comment,int level=0)
{
   if(!SpreadOK()) return 0;
   lot=NormLot(lot); if(lot<=0) return 0;
   if(!MarginOK(lot,type)) return 0;
   MqlTick t; if(!GetTick(t)) return 0;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid;
   bool ok=(type==ORDER_TYPE_BUY)?m_trade.Buy(lot,_Symbol,price,0,0,comment)
                                 :m_trade.Sell(lot,_Symbol,price,0,0,comment);
   if(!ok){Print("[V8] ERR apertura: ",m_trade.ResultRetcodeDescription());return 0;}
   ulong ticket=m_trade.ResultOrder();
   if(ticket>0){
      Print("[V8] ABIERTA #",ticket," ",(type==ORDER_TYPE_BUY?"BUY":"SELL"),
            " Lot=",lot," @ ",DoubleToString(price,_Digits)," [",comment,"]");
   }
   return ticket;
}

ENUM_ORDER_TYPE GetPrimaryDirection()
{
   MqlTick tk; if(!GetTick(tk)) return ORDER_TYPE_BUY;
   double mid=(tk.bid+tk.ask)/2.0;
   if(m_trendConfirmed==1) return ORDER_TYPE_BUY;
   if(m_trendConfirmed==-1) return ORDER_TYPE_SELL;
   if(m_emaFast>m_emaSlow) return ORDER_TYPE_BUY;
   return ORDER_TYPE_SELL;
}

bool EMA200FilterOK(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseEMA200Filter||m_ema200<=0) return true;
   MqlTick tk; if(!GetTick(tk)) return true;
   double mid=(tk.bid+tk.ask)/2.0;
   if(type==ORDER_TYPE_BUY) return(mid>m_ema200);
   if(type==ORDER_TYPE_SELL) return(mid<m_ema200);
   return true;
}

void TryOpenPrimary()
{
   if(m_blk.totalPos>0) return;
   if(m_isPaused||m_dailyLimitHit) return;
   if(m_trendConfirmed==0&&MathAbs(m_emaFast-m_emaSlow)<m_atr*0.1) return; // sin direccion clara
   if(TimeCurrent()-m_lastPrimaryTime<Inp_PrimaryIntervalSec) return;
   if(TimeCurrent()-m_blk.blockStart<Inp_AfterBlockPauseSec&&m_blk.blockStart>0) return;

   ENUM_ORDER_TYPE dir=GetPrimaryDirection();
   if(!EMA200FilterOK(dir)) return;
   double lot=NormLot(Inp_LotBase);
   if(!MarginOK(lot,dir)) return;
   if(TimeCurrent()-m_lastPrimaryTime<1) return;

   MqlTick tk; if(!GetTick(tk)) return;
   string comm="Primary_Entry";
   m_isPaused=false;
   ulong ticket=OpenOrder(dir,lot,comm,0);
   if(ticket>0){
      m_lastPrimaryTime=TimeCurrent();
      if(m_blk.blockStart==0) m_blk.blockStart=TimeCurrent();
      Print("[V8] PRIMARIA #",ticket," ",(dir==ORDER_TYPE_BUY?"BUY":"SELL")," Lot=",lot);
   }
}

//=================================================================
//  RECOVERY (sin limite de ordenes)
//=================================================================
bool IsPositionLosingSide(int pt)
{
   if(pt==POSITION_TYPE_BUY) return(m_blk.buyVolume>0&&m_blk.totalProfit<0);
   return(m_blk.sellVolume>0&&m_blk.totalProfit<0);
}

void TryRecover()
{
   if(m_blk.totalPos<=0||m_isPaused) return;
   if(m_blk.totalProfit>=0) return;                       // no recovery en positivo
   if(TimeCurrent()-m_blk.lastRecoveryTime<Inp_RecoveryIntervalSec) return;
   if(!SpreadOK()) return;
   if(m_atr<=0) return;

   // Direccion de la recovery
   int primaryDir=0;
   for(int i=0;i<m_posCount;i++){
      if(StringFind(m_pos[i].comment,"Primary")>=0||i==0){
         primaryDir=(m_pos[i].posType==POSITION_TYPE_BUY)?1:-1;
         break;
      }
   }
   if(primaryDir==0) return;

   ENUM_ORDER_TYPE recType=(primaryDir==1)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(Inp_RecoverWithTrend&&m_trendConfirmed!=0){
      int td=m_trendConfirmed;
      if(td!=primaryDir) recType=(td==1)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   }

   // Distancia minima respecto al ultimo lote de recovery (o la primaria)
   MqlTick tk; if(!GetTick(tk)) return;
   double minDist=m_atr*Inp_RecoveryDistATR;
   double lastEntryPrice=0;
   for(int i=0;i<m_posCount;i++){
      if(lastEntryPrice==0||m_pos[i].openTime>m_blk.lastEntryTime||lastEntryPrice==0){
         if(m_pos[i].openTime>=m_pos[i].openTime) lastEntryPrice=m_pos[i].openPrice;
      }
   }
   // usar la entrada mas reciente
   datetime latestT=0;
   for(int i=0;i<m_posCount;i++){
      if(m_pos[i].openTime>=latestT){latestT=m_pos[i].openTime;lastEntryPrice=m_pos[i].openPrice;}
   }
   if(lastEntryPrice>0){
      double dist=(recType==ORDER_TYPE_BUY)?tk.bid-lastEntryPrice:lastEntryPrice-tk.ask;
      // Si el precio NO se alejo del ultimo lote, esperar
      bool adverse=(recType==ORDER_TYPE_BUY)?(tk.bid<lastEntryPrice):(tk.bid>lastEntryPrice);
      // Recoveries: solo cuando el precio se aleja EN CONTRA (0.6 x ATR)
      if(!adverse) return;               // precio a favor: no agregar, esperar cierre
      double distAdv=MathAbs(dist);      // distancia en contra del ultimo lote
      if(distAdv<minDist) return;        // esperar a que se aleje lo suficiente
   }

   double recLot=CalcTargetLot();
   recLot=NormLot(MathMax(recLot,Inp_LotBase));
   if(!MarginOK(recLot,recType)) return;
   if(TimeCurrent()-m_blk.lastRecoveryTime<Inp_RecoveryIntervalSec) return;

   int lvl=m_blk.recoveryCount+1;
   // Multiplicador minimo: nunca menor que el lote base; el lote calculado ya adapta
   ulong ticket=OpenOrder(recType,recLot,"REC_"+IntegerToString(lvl),lvl);
   if(ticket>0){
      m_blk.lastRecoveryTime=TimeCurrent();
      m_blk.lastEntryTime=TimeCurrent();
      m_blk.recoveryCount++;
      Print("[V8] RECOVERY #",lvl," Lot=",recLot," PnL=$",DoubleToString(m_blk.totalProfit,2));
   }
}

//=================================================================
//  BREAK-EVEN + TRAILING
//=================================================================
double GetBlockBEPrice()
{
   // Precio al que el bloque neto queda en cero
   double netVol=m_blk.buyVolume-m_blk.sellVolume;
   if(MathAbs(netVol)<0.001) return 0;
   double bv=0,sv=0;
   for(int i=0;i<m_posCount;i++){
      if(m_pos[i].posType==POSITION_TYPE_BUY) bv+=m_pos[i].openPrice*m_pos[i].volume;
      else sv+=m_pos[i].openPrice*m_pos[i].volume;
   }
   if(netVol>0) return(bv-sv)/netVol;   // precio medio neto (largo)
   return(sv-bv)/MathAbs(netVol);       // precio medio neto (corto)
}

void ApplyBreakEven()
{
   if(m_blk.beLocked) return;
   if(m_blk.totalProfit<Inp_BE_MinUSD) return;
   if(m_atr<=0) return;
   MqlTick tk; if(!GetTick(tk)) return;
   double mid=(tk.bid+tk.ask)/2.0;
   double bePrice=GetBlockBEPrice();
   if(bePrice<=0) return;
   double moveFav=0;
   double netVol=m_blk.buyVolume-m_blk.sellVolume;
   if(netVol>0) moveFav=mid-bePrice;
   else if(netVol<0) moveFav=bePrice-mid;
   if(moveFav<m_atr*Inp_BE_ATR) return;

   // Mover todos los SL al precio de entrada (break-even individual)
   bool any=false;
   for(int i=0;i<m_posCount;i++){
      if(!PositionSelectByTicket(m_pos[i].ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      double sl=(m_pos[i].posType==POSITION_TYPE_BUY)?m_pos[i].openPrice-m_atr*0.05:m_pos[i].openPrice+m_atr*0.05;
      if(m_trade.PositionModify(m_pos[i].ticket,sl,0)) any=true;
   }
   if(any){
      m_blk.beLocked=true;
      m_blk.lockPrice=mid;
      m_blk.peakFavPrice=(netVol>0)?mid:mid;
      Print("[V8] BREAK-EVEN ACTIVADO | PnL=$",DoubleToString(m_blk.totalProfit,2));
   }
}

void ApplyTrailing()
{
   if(!m_blk.beLocked) return;
   if(m_blk.totalProfit<m_blk.peakProfit) return; // solo actualizar en nuevos picos... actualiza el pico
   if(m_blk.totalProfit>m_blk.peakProfit) m_blk.peakProfit=m_blk.totalProfit;

   if(m_blk.totalProfit<Inp_TrailMinUSD) return;
   if(m_atr<=0) return;
   MqlTick tk; if(!GetTick(tk)) return;
   double mid=(tk.bid+tk.ask)/2.0;
   double netVol=m_blk.buyVolume-m_blk.sellVolume;
   if(MathAbs(netVol)<0.001) return;
   bool isLong=(netVol>0);
   double trailDist=m_atr*Inp_TrailATR;

   double newRef=isLong?mid:mid;
   if(isLong&&newRef<m_blk.peakFavPrice) return;
   if(!isLong&&newRef>m_blk.peakFavPrice) return;
   m_blk.peakFavPrice=newRef;
   m_blk.trailActive=true;

   // SL persigue: para largos, SL = pico - trailDist
   for(int i=0;i<m_posCount;i++){
      if(!PositionSelectByTicket(m_pos[i].ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      double curSL=PositionGetDouble(POSITION_SL);
      double newSL=0;
      if(m_pos[i].posType==POSITION_TYPE_BUY){
         double ref=m_pos[i].openPrice>0?m_pos[i].openPrice:mid;
         // SL por posicion: entrada + (pico - entrada) - trailDist
         double fav=m_blk.peakFavPrice-ref;
         newSL=ref+fav-trailDist;
         if(newSL<ref-0.0001) newSL=ref; // nunca bajo el BE
      } else {
         double ref=m_pos[i].openPrice>0?m_pos[i].openPrice:mid;
         double fav=ref-m_blk.peakFavPrice;
         newSL=ref-fav+trailDist;
         if(newSL>ref+0.0001) newSL=ref;
      }
      newSL=NormalizeDouble(newSL,_Digits);
      if(MathAbs(curSL-newSL)>_Point*10){
         if(m_trade.PositionModify(m_pos[i].ticket,newSL,0)){
            // nada
         }
      }
   }
}

void CloseBlockIfPositive()
{
   if(m_blk.totalProfit<Inp_BlockTPUSD) return;
   Print("[V8] CIERRE POSITIVO: PnL=$",DoubleToString(m_blk.totalProfit,2),
         " >= $",DoubleToString(Inp_BlockTPUSD,2));
   for(int pass=0;pass<2;pass++){
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pass==0&&pf<0) continue; if(pass==1&&pf>=0) continue;
         m_trade.PositionClose(t);
      }
   }
   m_blk.cycleWinsSum+=m_blk.totalProfit;
   m_blk.cycleWinsCount++;
   m_totalPnL+=m_blk.totalProfit;
   m_tradesClosed+=m_posCount;
   if(m_blk.totalProfit>0){m_totalWins++;m_sumWins+=m_blk.totalProfit;}
   else{m_totalLosses++;m_sumLosses+=MathAbs(m_blk.totalProfit);}
   m_blk.totalPos=0;m_blk.totalProfit=0;
   m_blk.beLocked=false;m_blk.trailActive=false;
   m_blk.peakProfit=0;m_blk.peakFavPrice=0;
   m_blk.blockStart=TimeCurrent();
   m_blk.recoveryCount=0;
   m_lastPrimaryTime=TimeCurrent();
}

void CheckTrailClose()
{
   if(!Inp_CloseLockedOnRetrace||!m_blk.beLocked) return;
   if(!m_blk.trailActive) return;
   if(m_blk.totalProfit>=m_blk.peakProfit) return;
   double retrace=m_blk.peakProfit-m_blk.totalProfit;
   if(m_atr<=0) return;
   double trailUSD=DistToUSD(m_atr*Inp_TrailATR,1.0);
   if(trailUSD<=0) trailUSD=Inp_BlockTPUSD;
   if(retrace>=trailUSD&&m_blk.totalProfit>=Inp_BlockTPUSD){
      Print("[V8] TRAILING STOP: revirtio del pico en $",DoubleToString(retrace,2),
            " | cierra con $",DoubleToString(m_blk.totalProfit,2));
      m_isPaused=false;
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         m_trade.PositionClose(t);
      }
      m_blk.cycleWinsSum+=m_blk.totalProfit;
      m_blk.cycleWinsCount++;
      m_totalPnL+=m_blk.totalProfit;
      m_tradesClosed+=m_posCount;
      if(m_blk.totalProfit>0){m_totalWins++;m_sumWins+=m_blk.totalProfit;}
      else{m_totalLosses++;m_sumLosses+=MathAbs(m_blk.totalProfit);}
      m_blk.totalPos=0;m_blk.totalProfit=0;
      m_blk.beLocked=false;m_blk.trailActive=false;
      m_blk.peakProfit=0;m_blk.peakFavPrice=0;
      m_blk.blockStart=TimeCurrent();
      m_blk.recoveryCount=0;
      m_lastPrimaryTime=TimeCurrent();
   }
}

//=================================================================
//  PROTECCION DIARIA / EQUITY (opcional)
//=================================================================
void ResetDailyIfNeeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   datetime midnight=TimeCurrent()-(dt.hour*3600+dt.min*60+dt.sec);
   if(m_lastDailyReset<midnight){
      m_dailyLimitHit=false; m_lastDailyReset=midnight;
   }
}

void CheckDailyLimit()
{
   if(!Inp_UseDailyLimit||m_dailyLimitHit) return;
   if(m_totalPnL<=Inp_DailyLossUSD){
      Print("[V8] LIMITE DIARIO alcanzado: $",DoubleToString(m_totalPnL,2));
      m_dailyLimitHit=true;
      m_isPaused=true;
   }
}

void CheckEquityStop()
{
   if(Inp_EquityStopPct<=0) return;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<=0) return;
   double lossPct=(m_initialBalance-bal)/m_initialBalance*100.0;
   if(lossPct>=Inp_EquityStopPct){
      Print("[V8] EQUITY STOP: -",DoubleToString(lossPct,1),"% del balance");
      m_isPaused=true;
   }
}

//=================================================================
//  DASHBOARD
//=================================================================
void AQLbl(string n,string txt,int x,int y,color c,int fs=9,bool bold=false)
{
   if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_LABEL,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);}
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,n,OBJPROP_FONT,bold?"Consolas Bold":"Consolas");ObjectSetString(0,n,OBJPROP_TEXT,txt);
}

void AQPanel(string n,int x,int y,int w,int h)
{
   if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);ObjectSetInteger(0,n,OBJPROP_BACK,false);ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);}
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'8,8,12');ObjectSetInteger(0,n,OBJPROP_COLOR,C'70,70,70');ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
}

void UpdateDash()
{
   if(!Inp_ShowDashboard||TimeCurrent()-m_lastDashTime<1) return;
   m_lastDashTime=TimeCurrent();
   color cGreen=C'0,220,80',cRed=C'220,50,50',cOra=C'220,150,30';
   color cYel=C'200,200,50',cCyan=C'50,190,220',cMint=C'0,200,150',cGray=C'120,120,130';
   int x0=12,y0=28,lh=16,pad=8,w=560,h=26*lh+50;
   AQPanel("V8_BG",x0-pad,y0-pad,w,h);
   int x=x0,y=y0;
   AQLbl("V8_HDR","[ "+VERSION_STR+" ]  "+_Symbol+"  |  24/7 DIRECTIONAL CYCLE",x,y,cGreen,10,true);
   y+=lh+2;
   string stateStr;color stateC;
   if(m_isPaused) stateStr="[ PAUSADO ]"; else if(m_blk.totalPos>0) stateStr="[ BLOQUE ACTIVO ]"; else stateStr="[ BUSCANDO PRIMARIA ]";
   stateC=(m_blk.totalPos>0)?cYel:cGreen;
   if(m_isPaused) stateC=cRed;
   AQLbl("V8_STATE",stateStr,x,y,stateC,10,true);
   y+=lh;
   AQLbl("V8_BE","BreakEven:"+(m_blk.beLocked?"ACTIVO (no vuelve a negativo)":"STANDBY")+"  Trail:"+(m_blk.trailActive?"PERSIGUE":"STANDBY"),x,y,m_blk.beLocked?cMint:cGray,9);
   y+=lh;
   AQLbl("V8_PNL","PnL Bloque: $"+DoubleToString(m_blk.totalProfit,2)+"  Peak: $"+DoubleToString(m_blk.peakProfit,2)+"  Pos:"+IntegerToString(m_blk.totalPos)+"  Recov:"+IntegerToString(m_blk.recoveryCount),x,y,(m_blk.totalProfit>=0)?cGreen:cRed,9);
   y+=lh;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE),eq=AccountInfoDouble(ACCOUNT_EQUITY);
   AQLbl("V8_ACC","Balance: $"+DoubleToString(bal,2)+"  Equity: $"+DoubleToString(eq,2)+"  Margen Libre: $"+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2),x,y,cCyan,9);
   y+=lh;
   int totalT=m_totalWins+m_totalLosses;
   double wr=(totalT>0)?(double)m_totalWins/totalT*100:0;
   AQLbl("V8_HIST","PnL Realizado: $"+DoubleToString(m_totalPnL,2)+"  Ciclos:"+IntegerToString(m_blk.closedBlocks)+"  Win:"+DoubleToString(wr,1)+"% ("+IntegerToString(m_totalWins)+"/"+IntegerToString(totalT)+")",x,y,cCyan,9);
   y+=lh;
   AQLbl("V8_TK","Trend: "+(m_trendConfirmed==1?"BULL":(m_trendConfirmed==-1?"BEAR":"NEUTRAL"))+"  ATR(M1):"+DoubleToString(m_atr,2)+"  ATRslow:"+DoubleToString(m_atrSlow,2)+"  Spread:"+IntegerToString((int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)),x,y,cCyan,9);
   y+=lh;
   double netV=m_blk.buyVolume-m_blk.sellVolume;
   AQLbl("V8_NET","NetVol: "+DoubleToString(netV,2)+" lotes  Dir:"+(netV>0?"LARGO":(netV<0?"CORTO":"-")),x,y,cGray,9);
   ChartRedraw(0);
}

void DeleteDash()
{
   string names[]={"V8_BG","V8_HDR","V8_STATE","V8_BE","V8_PNL","V8_ACC","V8_HIST","V8_TK","V8_NET"};
   for(int i=0;i<ArraySize(names);i++) ObjectDelete(0,names[i]);
}

//=================================================================
//  OnInit / OnDeinit / OnTick
//=================================================================
int OnInit()
{
   Print("==============================================================");
   Print("  "+VERSION_STR+" — 24/7 DIRECTIONAL CYCLE (REDISEÑO TOTAL)");
   Print("  Recovery sin limite fijo + BreakEven + Trailing");
   Print("  LoteBase=",Inp_LotBase," Max=",Inp_LotMaximum," Mult=",Inp_LotMultiplier);
   Print("==============================================================");
   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   ENUM_TIMEFRAMES etf=PERIOD_M1;
   switch(Inp_EntryTimeframe){
      case 5:   etf=PERIOD_M5;  break;
      case 15:  etf=PERIOD_M15; break;
      case 60:  etf=PERIOD_H1;  break;
      default:  etf=PERIOD_M1;  break;
   }

   m_hATR=iATR(_Symbol,etf,14);
   m_hEMAFast=iMA(_Symbol,etf,21,0,MODE_EMA,PRICE_CLOSE);
   m_hEMASlow=iMA(_Symbol,etf,55,0,MODE_EMA,PRICE_CLOSE);
   m_hEMA200=iMA(_Symbol,PERIOD_H1,Inp_EMA200Period,0,MODE_EMA,PRICE_CLOSE);
   m_hATRSlow=iATR(_Symbol,etf,100);
   m_hRSI=iRSI(_Symbol,etf,7,PRICE_CLOSE);
   m_hMACD=iMACD(_Symbol,etf,12,26,9,PRICE_CLOSE);
   m_hADX=iADX(_Symbol,etf,14);
   if(m_hATR<0||m_hEMAFast<0||m_hEMASlow<0||m_hEMA200<0||m_hATRSlow<0){
      Print("[V8] ERROR creando indicadores"); return INIT_FAILED;
   }
   m_initialBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   m_bestEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   m_lastDailyReset=TimeCurrent();
   m_blk.blockStart=0;
   UpdateMarket();
   UpdateBlock();
   Print("[V8] LISTO | Saldo=$",m_initialBalance," | ATR=",m_atr);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("[V8] DETENIDO | PnL=$",DoubleToString(m_totalPnL,2)," | Ciclos:",m_blk.closedBlocks);
   if(m_hATR>=0)IndicatorRelease(m_hATR);
   if(m_hEMAFast>=0)IndicatorRelease(m_hEMAFast);
   if(m_hEMASlow>=0)IndicatorRelease(m_hEMASlow);
   if(m_hEMA200>=0)IndicatorRelease(m_hEMA200);
   if(m_hATRSlow>=0)IndicatorRelease(m_hATRSlow);
   if(m_hRSI>=0)IndicatorRelease(m_hRSI);
   if(m_hMACD>=0)IndicatorRelease(m_hMACD);
   if(m_hADX>=0)IndicatorRelease(m_hADX);
   DeleteDash();
}

void OnTick()
{
   UpdateMarket();
   UpdateBlock();
   ResetDailyIfNeeded();
   CheckDailyLimit();
   CheckEquityStop();

   if(m_isPaused) return;

   // P1: Cierre del bloque en positivo (target dinamico)
   if(m_blk.totalPos>0){
      double dynTarget=Inp_BlockTPUSD;
      if(m_atr>0) dynTarget=MathMax(Inp_BlockTPUSD,ATR2USD(Inp_BlockTPATR,1.0)*0.5+Inp_BlockTPUSD);
      if(m_blk.totalProfit>=dynTarget){
         CloseBlockIfPositive();
         return;
      }
      if(m_blk.totalProfit>m_blk.peakProfit) m_blk.peakProfit=m_blk.totalProfit;

      // P2: Break-even (bloque nunca vuelve a negativo)
      ApplyBreakEven();

      // P3: Trailing (persigue el movimiento positivo)
      ApplyTrailing();
      CheckTrailClose();

      // P4: Recovery (sin limite fijo, hasta cerrar en positivo)
      TryRecover();
   } else {
      // P5: Entrada primaria 24/7 (muy seguida)
      TryOpenPrimary();
   }

   if(Inp_ShowDashboard) UpdateDash();
}
//+------------------------------------------------------------------+
