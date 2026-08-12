import importlib.util, sys
spec = importlib.util.spec_from_file_location("br", r"C:\Users\H2R\Documents\Default Project\backtest_r30.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)
import MetaTrader5 as mt5
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

cands = [
    (16, 19, "ACTUAL 16-19h"),
    (16, 19, "16-19h (val)"),
    (11, 15, "11-15h"),
    (12, 15, "12-15h"),
    (10, 15, "10-15h"),
    (11, 16, "11-16h"),
    (12, 16, "12-16h"),
    (21, 2,  "21-02h"),
    (19, 23, "19-23h"),
    (0, 3,   "00-03h"),
    (22, 2,  "22-02h"),
]
print(f"{'Ventana':<14}{'PnL':>10}{'Trades':>8}{'Win%':>8}")
results = {}
for h0, h1, label in cands:
    br.INP["SessionFilterEnable"] = True
    br.INP["StartHour"] = h0
    br.INP["StartMinute"] = 0
    br.INP["EndHour"] = h1
    br.INP["EndMinute"] = 0
    trades, dbg = br.run(True)
    tot = sum(t["pnl"] for t in trades) if trades else 0.0
    n = len(trades) if trades else 0
    w = (sum(1 for t in trades if t["pnl"] > 0)/n*100) if n else 0
    print(f"{label:<14}{tot:>10.1f}{n:>8}{w:>7.1f}%")
    results[label] = (tot, n, w)
mt5.shutdown()
