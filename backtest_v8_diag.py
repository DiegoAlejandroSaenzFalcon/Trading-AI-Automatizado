import pandas as pd
import numpy as np
import MetaTrader5 as mt5
import datetime as dtm

mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
SYM="XAUUSDm"; start=dtm.datetime(2026,3,1); end=dtm.datetime(2026,8,11)
r1=mt5.copy_rates_range(SYM,mt5.TIMEFRAME_M1,start,end)
rH=mt5.copy_rates_range(SYM,mt5.TIMEFRAME_H1,start,end)
mt5.shutdown()
df=pd.DataFrame(r1); df['time']=pd.to_datetime(df['time'],unit='s')
dfH=pd.DataFrame(rH); dfH['time']=pd.to_datetime(dfH['time'],unit='s')
tr=np.maximum(df['high']-df['low'],np.maximum(abs(df['high']-df['close'].shift()),abs(df['low']-df['close'].shift())))
df['atr']=tr.ewm(alpha=1/14,adjust=False).mean()
df['ef']=df['close'].ewm(span=21,adjust=False).mean()
df['es']=df['close'].ewm(span=55,adjust=False).mean()
dfH['e200']=dfH['close'].ewm(span=200,adjust=False).mean().shift(1)
hmap=dfH.set_index('time')['e200'].sort_index().ffill().reindex(df['time'],method='ffill')
df['e200']=hmap.values
LOTBASE=0.05; LOTMAX=2.0; PINT=30; KQ=0.0001; KR=0.005; TFAST=21; TSLOW=55
RDATR=0.60; RMATR=1.20; MARGINPCT=60.0; BTPUSD=4.0; BTPATR=0.60; BEATR=0.40; BEMIN=1.0; TRAILATR=0.80; TRAILMIN=2.0
MOVEPERLOT=100.0; sp=0.2602; balance=18873.64; margin1=120.0
positions=[]; WARMUP=500; lastPrim=0; lastRec=0; blockStart=0
beLocked=False; trailActive=False; peakProfit=0.0; peakFav=0.0; trendConf=0
temaF_e1=temaF_e2=temaF_e3=0; temaS_e1=temaS_e2=temaS_e3=0; kalF_x=0; kalF_p=1.0; kalS_x=0; kalS_p=1.0; tema_init=False
cycles=[]; curMaxNeg=0; recCount=0; maxRec=0; maxLots=0; beCount=0; trailCloses=0; primCount=0; slHarvest=0
openBlockStart=None

def marginused(lots,price): return lots*margin1*price/2400.0
for i in range(WARMUP,len(df)):
    row=df.iloc[i]; t=row['time'].timestamp(); mid=row['close']; bid=mid-sp/2; ask=mid+sp/2
    atr=row['atr']; ef=row['ef']; es=row['es']; e200=row['e200']
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
    if positions:
        for p in list(positions):
            if p['sl']>0:
                if p['dir']==1 and row['low']<=p['sl']:
                    balance+=p['lot']*(p['sl']-p['op']); positions.remove(p); slHarvest+=1
                elif p['dir']==-1 and row['high']>=p['sl']:
                    balance+=p['lot']*(p['op']-p['sl']); positions.remove(p); slHarvest+=1
    def pnl_block():
        return sum((bid-p['op'])*p['lot'] if p['dir']==1 else (p['op']-ask)*p['lot'] for p in positions)
    if positions:
        prof=pnl_block(); curMaxNeg=min(curMaxNeg,prof)
        dyn=BTPUSD
        if atr>0: dyn=max(BTPUSD, ((atr*BTPATR/ts)*tv if False else (atr*BTPATR/0.001)*0.1)*0.5+BTPUSD)
        if prof>=dyn:
            balance+=prof
            cycles.append(dict(t=dtm.datetime.fromtimestamp(t),pnl=prof,orders=len(positions),maxneg=curMaxNeg,rec=recCount))
            maxRec=max(maxRec,recCount); positions.clear(); beLocked=False; trailActive=False
            peakProfit=0; peakFav=0; blockStart=t; lastPrim=t; recCount=0; curMaxNeg=0
            continue
        if prof>peakProfit: peakProfit=prof
        if not beLocked and prof>=BEMIN and atr>0:
            net=sum(p['lot']*p['dir'] for p in positions)
            bv=sum(p['op']*p['lot'] for p in positions if p['dir']==1)
            sv=sum(p['op']*p['lot'] for p in positions if p['dir']==-1)
            if net!=0:
                beP=(bv-sv)/net if net>0 else (sv-bv)/abs(net)
                fav=(mid-beP) if net>0 else (beP-mid)
                if fav>=atr*BEATR:
                    for p in positions: p['sl']=p['op']+atr*0.05 if p['dir']==1 else p['op']-atr*0.05
                    beLocked=True; peakFav=mid; beCount+=1
        if beLocked and prof>=TRAILMIN and atr>0:
            net=sum(p['lot']*p['dir'] for p in positions)
            if net>0:
                if mid>=peakFav:
                    peakFav=mid; trailActive=True
                    for p in positions:
                        if p['dir']==1:
                            nsl=p['op']+(peakFav-p['op'])-atr*TRAILATR
                            p['sl']=max(nsl,p['op'])
            elif net<0:
                if mid<=peakFav:
                    peakFav=mid; trailActive=True
                    for p in positions:
                        if p['dir']==-1:
                            nsl=p['op']-(p['op']-peakFav)+atr*TRAILATR
                            p['sl']=min(nsl,p['op'])
        if beLocked and trailActive and prof<peakProfit and atr>0:
            retr=peakProfit-prof; trailUSD=(atr*TRAILATR/0.001)*0.1*1.0
            if trailUSD<=0: trailUSD=BTPUSD
            if retr>=trailUSD and prof>=BTPUSD:
                balance+=prof
                cycles.append(dict(t=dtm.datetime.fromtimestamp(t),pnl=prof,orders=len(positions),maxneg=curMaxNeg,rec=recCount))
                maxRec=max(maxRec,recCount); positions.clear(); beLocked=False; trailActive=False
                peakProfit=0; peakFav=0; blockStart=t; lastPrim=t; recCount=0; curMaxNeg=0
                trailCloses+=1; continue
        if prof<0 and t-lastRec>=5:
            pd_=1 if positions[0]['dir']==1 else -1
            rdir=pd_
            if trendConf!=0 and trendConf!=pd_: rdir=trendConf
            lastp=positions[-1]['op']
            dist=(bid-lastp) if rdir==1 else (lastp-ask)
            adverse=(bid<lastp) if rdir==1 else (bid>lastp)
            if adverse and abs(dist)>=atr*RDATR:
                need=abs(prof)+BTPUSD+abs(prof)*0.10
                moveD=atr*RMATR; ppl=moveD*MOVEPERLOT
                lot=max(need/ppl,LOTBASE) if ppl>0 else LOTBASE
                lot=min(LOTMAX,max(0.01,round(lot/0.01)*0.01))
                eq=balance+prof; used=marginused(sum(p['lot'] for p in positions)+lot,mid); free=eq-used
                if used/eq*100<MARGINPCT and free>=eq*0.01:
                    positions.append(dict(dir=rdir,lot=lot,op=(ask if rdir==1 else bid),sl=0.0,time=t))
                    lastRec=t; recCount+=1
                    maxLots=max(maxLots,sum(p['lot'] for p in positions))
    else:
        if not (trendConf==0 and abs(ef-es)<atr*0.1) and t-lastPrim>=PINT:
            dir_=1 if trendConf==1 else (-1 if trendConf==-1 else (1 if ef>es else -1))
            if not (e200>0 and ((dir_==1 and mid<=e200) or (dir_==-1 and mid>=e200))):
                positions.append(dict(dir=dir_,lot=LOTBASE,op=(ask if dir_==1 else bid),sl=0.0,time=t))
                lastPrim=t; primCount+=1; openBlockStart=openBlockStart or dtm.datetime.fromtimestamp(t)
print(f"Primarias abiertas: {primCount} | Ciclos cerrados: {len(cycles)} | Cosechas SL: {slHarvest} | BE: {beCount} | Trail closes: {trailCloses}")
print(f"Balance final ${balance:.2f} | PnL ${balance-18873.64:.2f} | PnL por cosecha SL ${slHarvest and (balance-18873.64-sum(c['pnl'] for c in cycles))/slHarvest:.2f}")
print(f"Bloque abierto final: inicio {openBlockStart} | {len(positions)} ordenes | vol total {sum(p['lot'] for p in positions):.2f}")
bv=sum(p['lot'] for p in positions if p['dir']==1); sv=sum(p['lot'] for p in positions if p['dir']==-1)
print(f"  -> volumen BUY {bv:.2f} / SELL {sv:.2f} | neto {(bv-sv):+.2f}")
pf=sum((bid-p['op'])*p['lot'] if p['dir']==1 else (p['op']-ask)*p['lot'] for p in positions)
print(f"  -> flotante ${pf:.2f} | precio medio neto {(bv-sv) and ((sum(p['op']*p['lot'] for p in positions if p['dir']==1)-sum(p['op']*p['lot'] for p in positions if p['dir']==-1))/(bv-sv)):.2f} | ultimo {df.iloc[-1]['close']:.2f}")
