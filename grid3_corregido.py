import MetaTrader5 as mt5
import datetime as dtm
import numpy as np
import csv

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

def rsi2(close):
    out = np.full(len(close), 50.0)
    for i in range(1, len(close)):
        d = close[i]-close[i-1]
        g = max(d, 0.0); l = max(-d, 0.0)
        if l == 0: out[i] = 100.0 if g > 0 else out[i-1]
        else: out[i] = 100.0*g/(g+l)
    return out

def vwap_day(time, typical):
    n = len(time)
    cs = np.cumsum(typical)
    out = np.full(n, np.nan)
    day0 = time[0] - time[0] % 86400
    start = 0
    for i in range(n):
        day = time[i] - time[i] % 86400
        if day != day0:
            start = i; day0 = day
        out[i] = (cs[i] - (cs[start-1] if start > 0 else 0.0)) / (i - start + 1)
    return out

def build_cache(sym, frm, to):
    d = load(sym, frm, to)
    return {
        "d": d, "n": len(d),
        "atr": wilder_atr(d),
        "ema20": ema_arr(d["close"], 20), "ema30": ema_arr(d["close"], 30), "ema60": ema_arr(d["close"], 60),
        "rsi2": rsi2(d["close"]),
        "vwap": vwap_day(d["time"], (d["high"]+d["low"]+d["close"])/3.0),
    }

def sig_at(c, i, st):
    d = c["d"]; h = d["high"]; l = d["low"]; cl = d["close"]
    atr = c["atr"]
    if st == "BREAK24":
        if cl[i] > h[i-24:i].max(): return 1
        if cl[i] < l[i-24:i].min(): return -1
    elif st == "BREAK48":
        if cl[i] > h[i-48:i].max(): return 1
        if cl[i] < l[i-48:i].min(): return -1
    elif st == "MOMEMA":
        if cl[i] > c["ema30"][i] and cl[i] > h[i-3:i].max(): return 1
        if cl[i] < c["ema30"][i] and cl[i] < l[i-3:i].min(): return -1
    elif st == "EMACROSS":
        if i < 1: return 0
        if c["ema20"][i] > c["ema60"][i] and c["ema20"][i-1] <= c["ema60"][i-1]: return 1
        if c["ema20"][i] < c["ema60"][i] and c["ema20"][i-1] >= c["ema60"][i-1]: return -1
    elif st == "RETEST24":
        mx = h[i-24:i].max(); mn = l[i-24:i].min()
        if h[i] >= mx and cl[i] < mx - 0.1*atr[i]: return -1
        if l[i] <= mn and cl[i] > mn + 0.1*atr[i]: return 1
    elif st == "RETEST48":
        mx = h[i-48:i].max(); mn = l[i-48:i].min()
        if h[i] >= mx and cl[i] < mx - 0.1*atr[i]: return -1
        if l[i] <= mn and cl[i] > mn + 0.1*atr[i]: return 1
    elif st == "VWAP":
        vw = c["vwap"]
        if np.isnan(vw[i]) or np.isnan(vw[i-1]): return 0
        if cl[i] > vw[i] and cl[i-1] <= vw[i-1]: return 1
        if cl[i] < vw[i] and cl[i-1] >= vw[i-1]: return -1
    elif st == "RSI2":
        if c["rsi2"][i] < 10 and cl[i] < l[i-24:i].min(): return 1
        if c["rsi2"][i] > 90 and cl[i] > h[i-24:i].max(): return -1
    return 0

def simulate(c, slots, tp_mult, ttl, sl_mult=0.8):
    d = c["d"]; n = c["n"]; atr = c["atr"]
    trades = []
    pos = None
    for i in range(80, n):
        hour = (d["time"][i] % 86400) // 3600
        at = atr[i]
        if pos is not None:
            dd_, e, sl, tp_l, ttl_i = pos
            if dd_ == 1:
                if d["low"][i] <= sl: trades.append(-1.0); pos = None; continue
                if d["high"][i] >= tp_l: trades.append(tp_mult); pos = None; continue
            else:
                if d["high"][i] >= sl: trades.append(-1.0); pos = None; continue
                if d["low"][i] <= tp_l: trades.append(tp_mult); pos = None; continue
            if i >= ttl_i: trades.append(0.0); pos = None
            continue
        sts = None
        for h1_, h2_, ss in slots:
            if h1_ <= hour < h2_:
                sts = ss; break
        if sts is None or at <= 0: continue
        sig = 0
        for st in sts:
            s = sig_at(c, i, st)
            if s != 0:
                if sig != 0 and s != sig: sig = 0; break
                sig = s
        if sig != 0:
            sl_d = sl_mult*at; tp_d = tp_mult*sl_d
            pos = (sig, d["close"][i], d["close"][i]-sig*sl_d, d["close"][i]+sig*tp_d, i+ttl)
    return trades

def stats(tr):
    if len(tr) < 10: return None
    a = np.array(tr)
    eq = np.cumsum(a); peak = np.maximum.accumulate(eq)
    dd = (eq - peak).min()
    w = (a > 0).sum()/len(a)*100
    wins = a[a > 0].sum(); losses = -a[a < 0].sum()
    pf = wins/losses if losses > 0 else 99.0
    return (len(a), round(a.sum(),1), round(w,1), round(pf,2), round(dd,1))

PERIODS = [
    ("P1", dtm.datetime(2024,7,1), dtm.datetime(2025,6,30)),
    ("P2", dtm.datetime(2025,7,1), dtm.datetime(2026,1,31)),
    ("P3", dtm.datetime(2026,2,1), dtm.datetime(2026,8,11)),
]
STRATS = ["BREAK24","BREAK48","MOMEMA","EMACROSS","RETEST24","RETEST48","VWAP","RSI2"]
FRANJAS = [(h, h+2) for h in range(0, 24, 2)]
print("Cargando caches corregidos...", flush=True)
CACHE = {sym: {pn: build_cache(sym, f1, f2) for pn, f1, f2 in PERIODS} for sym in ["XAUUSDm","BTCUSDm"]}
out = r"C:\Users\H2R\Documents\Default Project\grid3_corregido.csv"
with open(out, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["activo","franja","estrat","tp","ttl","P1_n","P1_pnl","P1_win","P1_PF","P1_DD","P2_n","P2_pnl","P2_win","P2_PF","P2_DD","P3_n","P3_pnl","P3_win","P3_PF","P3_DD"])
    f.flush()
    for sym in ["XAUUSDm","BTCUSDm"]:
        for (h1_, h2_) in FRANJAS:
            for st in STRATS:
                for tp in [2.0, 2.5, 3.0]:
                    for ttl in [24, 48]:
                        row = [sym, f"{h1_:02d}-{h2_:02d}", st, tp, ttl]
                        for pn, _, _ in PERIODS:
                            tr = simulate(CACHE[sym][pn], [(h1_, h2_, [st])], tp, ttl)
                            s = stats(tr)
                            row += list(s) if s else [0,0,0,0,0]
                        w.writerow(row); f.flush()
        print(f"{sym} listo", flush=True)
mt5.shutdown()
print("GRID3 CORREGIDO TERMINADO")
