import pandas as pd, numpy as np, MetaTrader5 as mt5, datetime as dtm
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
SYM="XAUUSDm"

def run(start,end,cfg,label,balance0=18873.64):
    r1=mt5.copy_rates_range(SYM,mt5.TIMEFRAME_M1,start,end)
    rH=mt5.copy_rates_range(SYM,mt5.TIMEFRAME_H1,start,end)
    if r1 is None or len(r1)<2000: print(label,"SIN DATOS"); return
    df=pd.DataFrame(r1); df['time']=pd.to_datetime(df['time'],unit='s')
    dfH=pd.DataFrame(rH); dfH['time']=pd.to_datetime(dfH['time'],unit='s')
    # AGG M15 para el filtro direccional
    d15=df.set_index('time').resample('15min').agg({'open':'first','high':'max','low':'min','close':'last'}).dropna().reset_index()
    d15['atr']=(d15['high']-d15['low']).ewm(alpha=1/14,adjust=False).mean()
    d15['ef']=d15['close'].ewm(span=21,adjust=False).mean()
    d15['es']=d15['close'].ewm(span=55,adjust=False).mean()
    d15['signal']=np.where(d15['ef']>d15['es'],1,np.where(d15['ef']<d15['es'],-1,0)).astype(float)
    d15=d15.set_index('time').reindex(df['time'],method='ffill').reset_index()
    df['atr15']=d15['atr'].values; df['sig15']=d15['signal'].values
    df['hour']=df['time'].dt.hour
    tr=np.maximum(df['high']-df['low'],np.maximum(abs(df['high']-df['close'].shift()),abs(df['low']-df['close'].shift())))
    df['atr']=tr.ewm(alpha=1/14,adjust=False).mean()
    dfH['e200']=dfH['close'].ewm(span=200,adjust=False).mean().shift(1)
    hmap=dfH.set_index('time')['e200'].sort_index().ffill().reindex(df['time'],method='ffill')
    df['e200']=hmap.values
    LOTBASE=cfg['lotbase']; PINT=cfg['pint']; KQ=0.0001; KR=0.005
    RDATR=0.60; MAXREC=cfg['maxrec']; RMULT=cfg['rmult']; STOPUSD=cfg['stop']
    BTPUSD=cfg['tpusd']; BEATR=0.40; BEMIN=1.0; TRAILATR=0.80; TRAILMIN=2.0
    MPL=100.0; sp=0.2602; margin1=120.0; WARMUP=500
    SES_INI,SES_FIN=cfg['sess']
    positions=[]; lastPrim=0; lastRec=0
    beLocked=False; trailActive=False; peakProfit=0.0; peakFav=0.0
    cycles=0; stops_=0; winC=0; lossC=0; sumW=0; sumL=0; primCount=0; balance=balance0; slHarvest=0
    eqpeak=balance0; maxdd=0; mineq=1e18
    def pnl_block():
        return sum((bid-p['op'])*MPL*p['lot'] if p['dir']==1 else (p['op']-ask)*MPL*p['lot'] for p in positions)
    for i in range(WARMUP,len(df)):
        row=df.iloc[i]; t=row['time'].timestamp(); mid=row['close']; bid=mid-sp/2; ask=mid+sp/2
        atr=row['atr']; e200=row['e200']; sig=row['sig15']
        if positions:
            for p in list(positions):
                if p['sl']>0:
                    if p['dir']==1 and row['low']<=p['sl']:
                        balance+=p['lot']*(p['sl']-p['op'])*MPL; positions.remove(p); slHarvest+=1
                    elif p['dir']==-1 and row['high']>=p['sl']:
                        balance+=p['lot']*(p['op']-p['sl'])*MPL; positions.remove(p); slHarvest+=1
        prof=pnl_block() if positions else 0.0
        if positions:
            if prof<=STOPUSD:
                balance+=prof; stops_+=1; lossC+=1; sumL+=abs(prof)
                positions.clear(); beLocked=False; trailActive=False; peakProfit=0; peakFav=0
                lastPrim=t; lastRec=0
                continue
            dyn=BTPUSD
            if atr>0: dyn=max(BTPUSD, (atr*0.60*MPL)*0.5+BTPUSD)
            if prof>=dyn:
                balance+=prof; cycles+=1
                if prof>0: winC+=1; sumW+=prof
                else: lossC+=1; sumL+=abs(prof)
                positions.clear(); beLocked=False; trailActive=False; peakProfit=0; peakFav=0
                lastPrim=t; lastRec=0
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
                retr=peakProfit-prof; trailUSD=atr*TRAILATR*MPL
                if trailUSD<=0: trailUSD=BTPUSD
                if retr>=trailUSD and prof>=BTPUSD:
                    balance+=prof; cycles+=1; winC+=1; sumW+=prof
                    positions.clear(); beLocked=False; trailActive=False; peakProfit=0; peakFav=0
                    lastPrim=t; lastRec=0
                    continue
            recs=len(positions)-1
            if prof<0 and recs<MAXREC and t-lastRec>=5:
                pd_=1 if positions[0]['dir']==1 else -1
                rdir=pd_
                lastp=positions[-1]['op']
                dist=(bid-lastp) if rdir==1 else (lastp-ask)
                adverse=(bid<lastp) if rdir==1 else (bid>lastp)
                if adverse and abs(dist)>=atr*RDATR:
                    lot=min(0.5, LOTBASE*(RMULT**(recs+1)))
                    positions.append(dict(dir=rdir,lot=lot,op=(ask if rdir==1 else bid),sl=0.0,time=t))
                    lastRec=t
        else:
            if row['hour']>=SES_INI and row['hour']<SES_FIN and t-lastPrim>=PINT:
                if sig!=0:
                    if not (e200>0 and ((sig==1 and mid<=e200) or (sig==-1 and mid>=e200))):
                        positions.append(dict(dir=sig,lot=LOTBASE,op=(ask if sig==1 else bid),sl=0.0,time=t))
                        lastPrim=t; primCount+=1
        eq=balance+prof
        if eq<mineq: mineq=eq
        eqpeak=max(eqpeak,eq); maxdd=max(maxdd,eqpeak-eq)
    finalfl=pnl_block() if positions else 0.0
    n=cycles+stops_
    wr=100*winC/max(1,n) if n else 0
    print(f"{label}: PnL ${balance-balance0:+.0f} ({100*(balance-balance0)/balance0:+.1f}%) | ciclos {cycles}+stops {stops_} | WR {wr:.0f}% | PF {sumW/sumL if sumL else float('inf'):.2f} | PnL/mes ${(balance-balance0)/5.35:+.0f} | DD ${maxdd:.0f} ({100*maxdd/balance0:.0f}%) | minEq ${mineq:.0f} | prim {primCount} | harvest {slHarvest} | finalOpen {len(positions)} ({finalfl:+.0f})")

print("--- ENTRADAS M15 + SESION ---")
run(dtm.datetime(2026,3,1),dtm.datetime(2026,8,11),dict(lotbase=0.05,pint=600,maxrec=2,rmult=1.5,stop=-60.0,tpusd=8.0,sess=(7,21)),"S1 M15 sesion 7-21 (London+NY)")
run(dtm.datetime(2026,3,1),dtm.datetime(2026,8,11),dict(lotbase=0.05,pint=600,maxrec=3,rmult=2.0,stop=-100.0,tpusd=8.0,sess=(13,21)),"S2 M15 sesion 13-21 (NY)")
run(dtm.datetime(2026,3,1),dtm.datetime(2026,8,11),dict(lotbase=0.05,pint=900,maxrec=2,rmult=1.5,stop=-60.0,tpusd=8.0,sess=(7,21)),"S3 M15 15min entre primarias")
run(dtm.datetime(2026,6,1),dtm.datetime(2026,8,1),dict(lotbase=0.05,pint=600,maxrec=2,rmult=1.5,stop=-60.0,tpusd=8.0,sess=(7,21)),"S1 lateral")
