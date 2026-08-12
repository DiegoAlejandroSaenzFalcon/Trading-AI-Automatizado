import warnings; warnings.filterwarnings("ignore")
import MetaTrader5 as mt5
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
src=open(r"C:\Users\H2R\Documents\Default Project\backtest_r30_xau.py",encoding="utf-8-sig").read()
g={}; exec(compile(src,"b","exec"),g)
def stats(trades,label):
    if not trades:
        print(f"{label}: sin trades"); return
    tot=sum(t["pnl"] for t in trades); wins=sum(1 for t in trades if t["pnl"]>0)
    losses=sum(1 for t in trades if t["pnl"]<=0)
    avgW=sum(t["pnl"] for t in trades if t["pnl"]>0)/max(1,wins)
    avgL=sum(-t["pnl"] for t in trades if t["pnl"]<=0)/max(1,losses)
    print(f"{label}: trades {len(trades)} | PnL {tot:+.2f} | win {100*wins/len(trades):.0f}% | avgW {avgW:+.2f} avgL {avgL:.2f} | PF {sum(t['pnl'] for t in trades if t['pnl']>0)/max(0.01,sum(-t['pnl'] for t in trades if t['pnl']<=0)):.2f}")
for lbl,h1,h2 in [("FVG sesion 12-15",12,15),("FVG sesion 19-20",19,20),("FVG sesion 09-12",9,12),("FVG sesion 14-16",14,16)]:
    g["INP"]["SessionFilterEnable"]=True; g["INP"]["StartHour"]=h1; g["INP"]["EndHour"]=h2
    t,d=g["run"](True)
    stats(t,lbl)
