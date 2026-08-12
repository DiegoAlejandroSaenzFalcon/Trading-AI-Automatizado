import MetaTrader5 as mt5
import datetime as dtm
import numpy as np
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

def load(sym, frm, to):
    raw = mt5.copy_rates_range(sym, mt5.TIMEFRAME_M5, frm, to)
    d = np.empty(len(raw), dtype=[("time","i8"),("open","f8"),("high","f8"),("low","f8"),("close","f8")])
    for k in ["time","open","high","low","close"]:
        d[k] = raw[k]
    return d

def wilder_atr(h, n=14):
    tr = np.maximum(h["high"][1:]-h["low"][1:], np.maximum(np.abs(h["high"][1:]-h["close"][:-1]), np.abs(h["low"][1:]-h["close"][:-1])))
    out = np.empty(len(h)); out[0] = tr[0]
    for i in range(1, len(tr)):
        out[i] = (out[i-1]*(n-1)+tr[i-1])/n
    out[len(tr):] = out[len(tr)-1]
    return out

def ema_arr(v, n):
    a = np.empty(len(v)); a[0] = v[0]
    k = 2.0/(n+1)
    for i in range(1, len(v)):
        a[i] = v[i]*k + a[i-1]*(1-k)
    return a

d = load("XAUUSDm", dtm.datetime(2024,7,1), dtm.datetime(2025,6,30))
n = len(d)
atr = wilder_atr(d)
ema20 = ema_arr(d["close"],20); ema60 = ema_arr(d["close"],60)
closes = d["close"]; highs = d["high"]; lows = d["low"]
trades = []
pos = None
cnt = 0
for i in range(80, n):
    hour = (d["time"][i] % 86400) // 3600
    at = atr[i]
    if pos is not None:
        dd_, e, sl, tp_l, ttl_i = pos
        if dd_ == 1:
            if lows[i] <= sl: trades.append(-1.0); pos = None; continue
            if highs[i] >= tp_l: trades.append(2.0); pos = None; continue
        else:
            if highs[i] >= sl: trades.append(-1.0); pos = None; continue
            if lows[i] <= tp_l: trades.append(2.0); pos = None; continue
        if i >= ttl_i: trades.append(0.0); pos = None
        continue
    if not (16 <= hour < 18) or at <= 0: continue
    sig = 0
    if i >= 1:
        if ema20[i] > ema60[i] and ema20[i-1] <= ema60[i-1]: sig = 1
        elif ema20[i] < ema60[i] and ema20[i-1] >= ema60[i-1]: sig = -1
    if sig != 0:
        sl_d = 0.8*at; tp_d = 2.0*sl_d
        pos = (sig, closes[i], closes[i]-sig*sl_d, closes[i]+sig*tp_d, i+24)
a = np.array(trades)
w = (a>0).sum()/len(a)*100
wins = a[a>0].sum(); losses = -a[a<0].sum()
print(f"DEBUG P1 EMACROSS tp2.0 ttl24: n={len(a)} pnlR={a.sum():.1f} win={w:.1f}% PF={wins/losses:.2f} DD={np.min(np.cumsum(a)-np.maximum.accumulate(np.cumsum(a))):.1f}")
# inspeccionar primeros 10 trades
for t in a[:10]: print(f"  R={t:+.1f}")
mt5.shutdown()
