import pandas as pd
import numpy as np
import MetaTrader5 as mt5
import datetime as dtm

mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

SYM="XAUUSDm"
start=dtm.datetime(2026,3,1); end=dtm.datetime(2026,8,11)
r1=mt5.copy_rates_range(SYM,mt5.TIMEFRAME_M1,start,end)
rH=mt5.copy_rates_range(SYM,mt5.TIMEFRAME_H1,start,end)
ticks=mt5.copy_ticks_range(SYM,dtm.datetime(2026,8,10),dtm.datetime(2026,8,11),mt5.COPY_TICKS_ALL)
tv=0.1; ts=0.001  # symbol info
sp=float(np.mean(ticks['ask']-ticks['bid'])) if ticks is not None and len(ticks)>0 else 0.25
margin1=mt5.order_calc_margin(mt5.ORDER_TYPE_BUY,SYM,1.0,2400.0)
mt5.shutdown()
print(f"spread medio (tics reales 1 dia) = {sp:.4f}  | margen 1.0 lote = {margin1}")

df=pd.DataFrame(r1)
df['time']=pd.to_datetime(df['time'],unit='s')
dfH=pd.DataFrame(rH)
dfH['time']=pd.to_datetime(dfH['time'],unit='s')

# ---- indicadores ----
tr=np.maximum(df['high']-df['low'],np.maximum(abs(df['high']-df['close'].shift()),abs(df['low']-df['close'].shift())))
df['atr']=tr.ewm(alpha=1/14,adjust=False).mean()
df['atrs']=tr.ewm(alpha=1/100,adjust=False).mean()
df['ef']=df['close'].ewm(span=21,adjust=False).mean()
df['es']=df['close'].ewm(span=55,adjust=False).mean()
dfH['e200']=dfH['close'].ewm(span=200,adjust=False).mean().shift(1)  # CopyBuffer shift=1 -> barra H1 cerrada
hmap=dfH.set_index('time')['e200'].sort_index().ffill().reindex(df['time'],method='ffill')
df['e200']=hmap.values

# ---- config (mismos inputs que el EA) ----
LOTBASE=0.05; LOTMAX=2.0; PINT=30; MAXSPREAD=800
KQ=0.0001; KR=0.005; TFAST=21; TSLOW=55
RSUSD=3.0; RDATR=0.60; RMATR=1.20; RGATR=0.35; RECWTREND=True; MARGINPCT=60.0
BTPUSD=4.0; BTPATR=0.60; BEATR=0.40; BEMIN=1.0; TRAILATR=0.80; TRAILMIN=2.0
MOVEPERLOT=tv/ts  # 100 usd por $1 de movimiento por lote

# ---- estado ----
balance=18873.64
positions=[]   # {dir(1/-1),lot,op,sl,time}
WARMUP=500
lastPrim=0; lastRec=0; blockStart=0
beLocked=False; trailActive=False; peakProfit=0.0; peakFav=0.0
trendConf=0; temaF_e1=temaF_e2=temaF_e3=0; temaS_e1=temaS_e2=temaS_e3=0
kalF_x=0; kalF_p=1.0; kalS_x=0; kalS_p=1.0
tema_init=False
wins=0; losses=0; sumW=0; sumL=0
cycles=[]; eqpeak=balance; maxdd=0; worstCycle=None; curMaxNeg=0
recCount=0; maxRec=0; maxLots=0; beCount=0; trailCloses=0
started=False

t0=dtm.datetime.now()

def marginused(lots,price):
    return lots*margin1*price/2400.0  # aprox: margen ~precio*100/2000

for i in range(WARMUP,len(df)):
    row=df.iloc[i]
    t=row['time'].timestamp()
    mid=row['close']; bid=mid-sp/2; ask=mid+sp/2
    atr=row['atr']; atrs=row['atrs']; ef=row['ef']; es=row['es']; e200=row['e200']
    # TEMA+Kalman (por barra)
    if not tema_init:
        temaF_e1=temaF_e2=temaF_e3=mid; temaS_e1=temaS_e2=temaS_e3=mid; tema_init=True
    aF=2.0/(TFAST+1); aS=2.0/(TSLOW+1)
    temaF_e1+=aF*(mid-temaF_e1); temaF_e2+=aF*(temaF_e1-temaF_e2); temaF_e3+=aF*(temaF_e2-temaF_e3)
    tf=3*temaF_e1-3*temaF_e2+temaF_e3
    temaS_e1+=aS*(mid-temaS_e1); temaS_e2+=aS*(temaS_e1-temaS_e2); temaS_e3+=aS*(temaS_e2-temaS_e3)
    ts_=3*temaS_e1-3*temaS_e2+temaS_e3
    kalF_p+=KQ; kg=kalF_p/(kalF_p+KR); kalF_x+=kg*(tf-kalF_x); kalF_p*=(1-kg)
    kalS_p+=KQ; kg=kalS_p/(kalS_p+KR); kalS_x+=kg*(ts_-kalS_x); kalS_p*=(1-kg)
    trendConf = 1 if (tf>ts_ and kalF_x>kalS_x) else (-1 if (tf<ts_ and kalF_x<kalS_x) else 0)

    # SL hit
    if positions:
        for p in list(positions):
            if p['sl']>0:
                if p['dir']==1 and row['low']<=p['sl']:
                    pnl=p['lot']*(p['sl']-p['op']); balance+=pnl
                    positions.remove(p)
                elif p['dir']==-1 and row['high']>=p['sl']:
                    pnl=p['lot']*(p['op']-p['sl']); balance+=pnl
                    positions.remove(p)

    if not started and i>WARMUP+300:
        started=True

    def pnl_block():
        return sum((bid-p['op'])*p['lot'] if p['dir']==1 else (p['op']-ask)*p['lot'] for p in positions)

    if positions:
        prof=pnl_block()
        curMaxNeg=min(curMaxNeg,prof)
        # P1 close
        dyn=BTPUSD
        if atr>0: dyn=max(BTPUSD, ((atr*BTPATR/ts)*tv*1.0)*0.5+BTPUSD)
        if prof>=dyn:
            if prof>0: wins+=1; sumW+=prof
            else: losses+=1; sumL+=abs(prof)
            balance+=prof
            cycles.append(dict(t=dtm.datetime.fromtimestamp(t),pnl=prof,orders=len(positions),maxneg=curMaxNeg,rec=recCount,lots=sum(p['lot'] for p in positions)))
            maxRec=max(maxRec,recCount)
            positions.clear(); beLocked=False; trailActive=False; peakProfit=0; peakFav=0
            blockStart=t; lastPrim=t; recCount=0; curMaxNeg=0
            continue
        if prof>peakProfit: peakProfit=prof
        # P2 BE
        if not beLocked and prof>=BEMIN and atr>0:
            net=sum(p['lot']*p['dir'] for p in positions)
            bv=sum(p['op']*p['lot'] for p in positions if p['dir']==1)
            sv=sum(p['op']*p['lot'] for p in positions if p['dir']==-1)
            beP=(bv-sv)/net if net>0 else (sv-bv)/abs(net)
            fav=(mid-beP) if net>0 else (beP-mid)
            if fav>=atr*BEATR:
                for p in positions:
                    p['sl']=p['op']+atr*0.05 if p['dir']==1 else p['op']-atr*0.05
                beLocked=True; peakFav=mid; beCount+=1
        # P3 trailing
        if beLocked and prof>=TRAILMIN and atr>0:
            net=sum(p['lot']*p['dir'] for p in positions)
            isLong=net>0
            if isLong and mid>=peakFav:
                peakFav=mid; trailActive=True
                for p in positions:
                    if p['dir']==1:
                        newSL=p['op']+(peakFav-p['op'])-atr*TRAILATR
                        if newSL<p['op']: newSL=p['op']
                        p['sl']=newSL
            elif not isLong and mid<=peakFav:
                peakFav=mid; trailActive=True
                for p in positions:
                    if p['dir']==-1:
                        newSL=p['op']-(p['op']-peakFav)+atr*TRAILATR
                        if newSL>p['op']: newSL=p['op']
                        p['sl']=newSL
        # P3b trail close
        if beLocked and trailActive and prof<peakProfit and atr>0:
            retr=peakProfit-prof
            trailUSD=(atr*TRAILATR/ts)*tv*1.0
            if trailUSD<=0: trailUSD=BTPUSD
            if retr>=trailUSD and prof>=BTPUSD:
                wins+=1; sumW+=prof; balance+=prof
                cycles.append(dict(t=dtm.datetime.fromtimestamp(t),pnl=prof,orders=len(positions),maxneg=curMaxNeg,rec=recCount,lots=sum(p['lot'] for p in positions)))
                maxRec=max(maxRec,recCount)
                positions.clear(); beLocked=False; trailActive=False; peakProfit=0; peakFav=0
                blockStart=t; lastPrim=t; recCount=0; curMaxNeg=0
                trailCloses+=1
                continue
        # P4 recovery
        if prof<0 and t-lastRec>=5:
            pd_=1 if positions[0]['dir']==1 else -1
            rdir=pd_
            if RECWTREND and trendConf!=0 and trendConf!=pd_:
                rdir=trendConf
            lastp=positions[-1]['op']
            dist=(bid-lastp) if rdir==1 else (lastp-ask)
            adverse=(bid<lastp) if rdir==1 else (bid>lastp)
            if not adverse:
                pass
            elif abs(dist)>=atr*RDATR:
                need=abs(prof)+BTPUSD+abs(prof)*0.10
                moveD=atr*RMATR
                ppl=moveD*MOVEPERLOT
                lot=max(need/ppl,LOTBASE) if ppl>0 else LOTBASE
                lot=min(LOTMAX,max(0.01,round(lot/0.01)*0.01))
                eq=balance+prof
                used=marginused(sum(p['lot'] for p in positions)+lot,mid)
                free=eq-used
                if used/eq*100<MARGINPCT and free>=eq*0.01:
                    positions.append(dict(dir=rdir,lot=lot,op=(ask if rdir==1 else bid),sl=0.0,time=t))
                    lastRec=t; recCount+=1
                    maxLots=max(maxLots,sum(p['lot'] for p in positions))
    else:
        if trendConf==0 and abs(ef-es)<atr*0.1:
            pass
        elif t-lastPrim>=PINT:
            dir_=1 if trendConf==1 else (-1 if trendConf==-1 else (1 if ef>es else -1))
            if e200>0 and ((dir_==1 and mid<=e200) or (dir_==-1 and mid>=e200)):
                pass
            else:
                positions.append(dict(dir=dir_,lot=LOTBASE,op=(ask if dir_==1 else bid),sl=0.0,time=t))
                lastPrim=t
                if blockStart==0: blockStart=t

    eq=balance+pnl_block()
    eqpeak=max(eqpeak,eq)
    maxdd=max(maxdd,eqpeak-eq)

print(f"took {(dtm.datetime.now()-t0).seconds}s | velas: {len(df)-WARMUP}")
n=len(cycles)
tp=sum(c['pnl'] for c in cycles if c['pnl']>0); tl=sum(-c['pnl'] for c in cycles if c['pnl']<0)
finalOpen=positions
print(f"=== RESULTADOS V8-ENDLESS en XAUUSDm {start:%d/%m} - {end:%d/%m} (spread {sp:.2f}) ===")
print(f"Balance inicial $18873.64 -> final ${balance:.2f} | PnL realizado ${balance-18873.64:.2f}")
if finalOpen:
    print(f"BLOQUE ABIERTO al final: {len(finalOpen)} ordenes, volumen total {sum(p['lot'] for p in finalOpen):.2f}, flotante ${sum((bid-p['op'])*p['lot'] if p['dir']==1 else (p['op']-ask)*p['lot'] for p in finalOpen):.2f}")
print(f"Ciclos cerrados: {n} | Ganadores {len([c for c in cycles if c['pnl']>0])} | Perdedores {len([c for c in cycles if c['pnl']<0])}")
print(f"Sum wins ${tp:.2f} | Sum losses ${tl:.2f} | PF {tp/tl if tl>0 else float('inf'):.2f} | PnL/ciclo ${(sum(c['pnl'] for c in cycles)/n if n else 0):.2f} | PnL/mes ${(balance-18873.64)/(5.35):.2f}")
print(f"Max drawdown (equity): ${maxdd:.2f} ({maxdd/18873.64*100:.1f}%)")
print(f"Max recovery orders en un bloque: {maxRec} | Max lote total: {maxLots:.2f}")
print(f"BE activados: {beCount} | Cierres por trailing: {trailCloses}")
if cycles:
    worst=min(cycles,key=lambda c:c['pnl'])
    print(f"Peor ciclo: {worst['pnl']:.2f} en {worst['t']:%d/%m %H:%M} ({worst['orders']} ordenes, maxneg ${worst['maxneg']:.2f}, {worst['rec']} recoveries)")
    for c in sorted(cycles,key=lambda c:c['maxneg'])[:3]:
        print(f"  maxneg ${c['maxneg']:.2f} -> pnl {c['pnl']:.2f} | {c['t']:%d/%m %H:%M} | {c['orders']} ord | lots {c['lots']:.2f} | {c['rec']} rec")
