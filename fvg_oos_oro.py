import warnings; warnings.filterwarnings("ignore")
import MetaTrader5 as mt5
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
src=open(r"C:\Users\H2R\Documents\Default Project\backtest_r30_xau.py",encoding="utf-8-sig").read()
src=src.replace("frm = datetime(2026, 2, 1)","frm = datetime(2026, 5, 13)")
src=src.replace("to = datetime(2026, 5, 13)","to = datetime(2026, 8, 11)")
g={}; exec(compile(src,"b","exec"),g)
def stats(trades,label):
    if not trades:
        print(f"{label}: sin trades"); return
    tot=sum(t["pnl"] for t in trades); wins=sum(1 for t in trades if t["pnl"]>0)
    losses=sum(1 for t in trades if t["pnl"]<=0)
    avgW=sum(t["pnl"] for t in trades if t["pnl"]>0)/max(1,wins)
    avgL=sum(-t["pnl"] for t in trades if t["pnl"]<=0)/max(1,losses)
    pf=sum(t['pnl'] for t in trades if t['pnl']>0)/max(0.01,sum(-t['pnl'] for t in trades if t['pnl']<=0))
    print(f"{label}: trades {len(trades)} | PnL {tot:+.2f} | win {100*wins/len(trades):.0f}% | avgW {avgW:+.2f} avgL {avgL:.2f} | PF {pf:.2f}")
for lbl,h1,h2 in [("OOS 14-16",14,16),("OOS 19-20",19,20),("OOS 14-16 + 19-20",None,None)]:
    if lbl.startswith("OOS 14-16 +"):
        g["INP"]["SessionFilterEnable"]=True; g["INP"]["StartHour"]=14; g["INP"]["EndHour"]=16
        t1,d1=g["run"](True)
        g["INP"]["StartHour"]=19; g["INP"]["EndHour"]=20
        t2,d2=g["run"](True)
        if t1 and t2: stats(t1+t2,lbl)
        elif t1: stats(t1,lbl)
        elif t2: stats(t2,lbl)
    else:
        g["INP"]["SessionFilterEnable"]=True; g["INP"]["StartHour"]=h1; g["INP"]["EndHour"]=h2
        t,d=g["run"](True)
        stats(t,lbl)
