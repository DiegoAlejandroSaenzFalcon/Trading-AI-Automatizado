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
MOVEPERLOT=100.0; sp=0.2602; margin1=120.0
HSTART=15.0; HDATR=0.80; HMATR=1.20; MAXVOL=10.0
positions=[]; WARMUP=500; lastPrim=0; lastRec=0; blockStart=0
beLocked=False; trailActive=False; peakProfit=0.0; peakFav=0.0; trendConf=0
temaF_e1=temaF_e2=temaF_e3=0; temaS_e1=temaS_e2=temaS_e3=0; kalF_x=0; kalF_p=1.0; kalS_x=0; kalS_p=1.0; tema_init=False
cycles=[]; curMaxNeg=0; recCount=0; hedgeCount=0; lastHedgePrice=0; lastHedgeDir=0; maxLots=0
eqpeak=18873.64; maxdd=0; primCount=0; balance=18873.64; slHarvest=0
mineq=1e18; mineqT=None; maxnegfl=0; maxnegT=None; maxposfl=0; eqhist=[]

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
        if atr>0: dyn=max(BTPUSD, ((atr*BTPATR/0.001)*0.1)*0.5+BTPUSD)
        if prof>=dyn:
            balance+=prof
            cycles.append(dict(t=dtm.datetime.fromtimestamp(t),pnl=prof,orders=len(positions),maxneg=curMaxNeg,rec=recCount,hedge=hedgeCount))
            positions.clear(); beLocked=False; trailActive=False; peakProfit=0; peakFav=0
            blockStart=t; lastPrim=t; recCount=0; hedgeCount=0; curMaxNeg=0; lastHedgePrice=0; lastHedgeDir=0
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
                    beLocked=True; peakFav=mid
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
                cycles.append(dict(t=dtm.datetime.fromtimestamp(t),pnl=prof,orders=len(positions),maxneg=curMaxNeg,rec=recCount,hedge=hedgeCount))
                positions.clear(); beLocked=False; trailActive=False; peakProfit=0; peakFav=0
                blockStart=t; lastPrim=t; recCount=0; hedgeCount=0; curMaxNeg=0; lastHedgePrice=0; lastHedgeDir=0
                continue
        net=sum(p['lot']*p['dir'] for p in positions)
        vol=sum(p['lot'] for p in positions)
        hedgeActive = (prof < -HSTART)
        if prof<0 and hedgeActive and vol<MAXVOL:
            hdir = -1 if net>0 else 1
            if lastHedgeDir==0: lastHedgeDir=hdir; lastHedgePrice=(bid if hdir==1 else ask)
            if hdir!=lastHedgeDir:
                lastHedgeDir=hdir; lastHedgePrice=(bid if hdir==1 else ask)
            moved = (bid-lastHedgePrice) if hdir==1 else (lastHedgePrice-ask)
            if moved>=atr*HDATR:
                need=abs(prof)+BTPUSD+abs(prof)*0.10
                moveD=atr*HMATR; ppl=moveD*MOVEPERLOT
                lot=max(need/ppl,LOTBASE) if ppl>0 else LOTBASE
                lot=min(LOTMAX,max(0.01,round(lot/0.01)*0.01))
                eq=balance+prof; used=marginused(vol+lot,mid); free=eq-used
                if used/eq*100<MARGINPCT and free>=eq*0.01:
                    positions.append(dict(dir=hdir,lot=lot,op=(ask if hdir==1 else bid),sl=0.0,time=t))
                    lastHedgePrice=(bid if hdir==1 else ask); lastHedgeDir=hdir
                    hedgeCount+=1; lastRec=t
                    maxLots=max(maxLots,sum(p['lot'] for p in positions))
        if prof<0 and not hedgeActive and vol<MAXVOL and t-lastRec>=5:
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
                eq=balance+prof; used=marginused(vol+lot,mid); free=eq-used
                if used/eq*100<MARGINPCT and free>=eq*0.01:
                    positions.append(dict(dir=rdir,lot=lot,op=(ask if rdir==1 else bid),sl=0.0,time=t))
                    lastRec=t; recCount+=1
                    maxLots=max(maxLots,sum(p['lot'] for p in positions))
    else:
        if not (trendConf==0 and abs(ef-es)<atr*0.1) and t-lastPrim>=PINT:
            dir_=1 if trendConf==1 else (-1 if trendConf==-1 else (1 if ef>es else -1))
            if not (e200>0 and ((dir_==1 and mid<=e200) or (dir_==-1 and mid>=e200))):
                positions.append(dict(dir=dir_,lot=LOTBASE,op=(ask if dir_==1 else bid),sl=0.0,time=t))
                lastPrim=t; primCount+=1
    eq=balance+pnl_block()
    if eq<mineq: mineq=eq; mineqT=dtm.datetime.fromtimestamp(t)
    if positions:
        prof=pnl_block()
        if prof<0 and prof<maxnegfl: maxnegfl=prof; maxnegT=dtm.datetime.fromtimestamp(t)
        if prof>maxposfl: maxposfl=prof
    eqpeak=max(eqpeak,eq); maxdd=max(maxdd,eqpeak-eq)

print(f"slHarvest={slHarvest} | balance=${balance:.2f} | PnL=${balance-18873.64:.2f} | ciclos={len(cycles)}")
print(f"Min equity ${mineq:.2f} el {mineqT:%d/%m %H:%M} | MaxDD ${maxdd:.2f} ({maxdd/18873.64*100:.1f}%)")
print(f"Max flotante NEGATIVO ${maxnegfl:.2f} el {maxnegT:%d/%m %H:%M} | Max flotante POSITIVO ${maxposfl:.2f}")
if positions:
    bv=sum(p['lot'] for p in positions if p['dir']==1); sv=sum(p['lot'] for p in positions if p['dir']==-1)
    abv=sum(p['op']*p['lot'] for p in positions if p['dir']==1)/(bv or 1)
    asv=sum(p['op']*p['lot'] for p in positions if p['dir']==-1)/(sv or 1)
    pf=sum((bid-p['op'])*p['lot'] if p['dir']==1 else (p['op']-ask)*p['lot'] for p in positions)
    print(f"Final: {len(positions)} ord | BUY {bv:.2f}L media {abv:.0f} | SELL {sv:.2f}L media {asv:.0f} | neto {bv-sv:+.2f} | flot ${pf:.2f}")
    print(f"Ultimo precio {df.iloc[-1]['close']:.2f} | % flotante/balance {pf/balance*100:.1f}%")
