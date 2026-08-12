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
    return {"d": d, "n": len(d), "atr": wilder_atr(d),
            "ema20": ema_arr(d["close"],20), "ema30": ema_arr(d["close"],30), "ema60": ema_arr(d["close"],60),
            "vwap": vwap_day(d["time"], (d["high"]+d["low"]+d["close"])/3.0)}

def sig_at(c, i, st):
    d = c["d"]; h = d["high"]; l = d["low"]; cl = d["close"]
    if st == "BREAK48":
        if cl[i] > h[i-48:i].max(): return 1
        if cl[i] < l[i-48:i].min(): return -1
    elif st == "MOMEMA":
        if cl[i] > c["ema30"][i] and cl[i] > h[i-3:i].max(): return 1
        if cl[i] < c["ema30"][i] and cl[i] < l[i-3:i].min(): return -1
    elif st == "EMACROSS":
        if i < 1: return 0
        if c["ema20"][i] > c["ema60"][i] and c["ema20"][i-1] <= c["ema60"][i-1]: return 1
        if c["ema20"][i] < c["ema60"][i] and c["ema20"][i-1] >= c["ema60"][i-1]: return -1
    elif st == "RETEST48":
        mx = h[i-48:i].max(); mn = l[i-48:i].min()
        if h[i] >= mx and cl[i] < mx - 0.1*c["atr"][i]: return -1
        if l[i] <= mn and cl[i] > mn + 0.1*c["atr"][i]: return 1
    elif st == "VWAP":
        vw = c["vwap"]
        if np.isnan(vw[i]) or np.isnan(vw[i-1]): return 0
        if cl[i] > vw[i] and cl[i-1] <= vw[i-1]: return 1
        if cl[i] < vw[i] and cl[i-1] >= vw[i-1]: return -1
    return 0

def run_ea(c, slots):
    d = c["d"]; n = c["n"]; atr = c["atr"]
    trades = []
    poss = [None]*len(slots)
    for i in range(80, n):
        hour = (d["time"][i] % 86400) // 3600
        for si, slot in enumerate(slots):
            h1_, h2_, st_list, tp_m, ttl = slot
            p = poss[si]
            if p is not None:
                dd_, e, sl, tp_l, ttl_i = p
                if dd_ == 1:
                    if d["low"][i] <= sl: trades.append(-1.0); poss[si] = None; continue
                    if d["high"][i] >= tp_l: trades.append(tp_m); poss[si] = None; continue
                else:
                    if d["high"][i] >= sl: trades.append(-1.0); poss[si] = None; continue
                    if d["low"][i] <= tp_l: trades.append(tp_m); poss[si] = None; continue
                if i >= ttl_i: trades.append(0.0); poss[si] = None
                continue
            if not (h1_ <= hour < h2_): continue
            at = atr[i]
            if at <= 0: continue
            sig = 0
            for st in st_list:
                s = sig_at(c, i, st)
                if s != 0:
                    if sig != 0 and s != sig: sig = 0; break
                    sig = s
            if sig != 0:
                sl_d = 0.8*at; tp_d = tp_m*sl_d
                poss[si] = (sig, d["close"][i], d["close"][i]-sig*sl_d, d["close"][i]+sig*tp_d, i+ttl)
    return trades

def report(label, caches, slots, risk, period_months=25):
    all_t = []
    print(f"=== {label} ===")
    for pn, _, _ in PERIODS:
        tr = run_ea(caches[pn], slots)
        all_t += tr
        a = np.array(tr)
        eq = np.cumsum(a); peak = np.maximum.accumulate(eq); dd = (eq-peak).min()
        w = (a>0).sum()/len(a)*100
        wins = a[a>0].sum(); losses = -a[a<0].sum()
        pf = wins/losses if losses else 99
        months = (pto2[pn] - pfrm2[pn]).days/30.4
        print(f"{pn}: n={len(a)} pnlR={a.sum():.0f} win={w:.1f}% PF={pf:.2f} maxDD={dd:.0f}R ({len(a)/months:.1f} tr/mes)")
    a = np.array(all_t)
    eq = np.cumsum(a); peak = np.maximum.accumulate(eq); dd = (eq-peak).min()
    w = (a>0).sum()/len(a)*100
    wins = a[a>0].sum(); losses = -a[a<0].sum()
    pf = wins/losses if losses else 99
    print(f"TOTAL: n={len(a)} pnlR={a.sum():.0f} win={w:.1f}% PF={pf:.2f} maxDD={dd:.0f}R ({len(a)/period_months:.1f} tr/mes)")
    print(f"  => USD riesgo ${risk}: pnl=${a.sum()*risk:.0f}, maxDD=${dd*risk:.0f}, {a.sum()/period_months*risk:.0f}$/mes")
    print()

PERIODS = [("P1", dtm.datetime(2024,7,1), dtm.datetime(2025,6,30)),
           ("P2", dtm.datetime(2025,7,1), dtm.datetime(2026,1,31)),
           ("P3", dtm.datetime(2026,2,1), dtm.datetime(2026,8,11))]
pfrm2 = {p[0]: p[1] for p in PERIODS}; pto2 = {p[0]: p[2] for p in PERIODS}
print("Cargando caches...", flush=True)
CACHE = {sym: {pn: build_cache(sym, f1, f2) for pn, f1, f2 in PERIODS} for sym in ["XAUUSDm","BTCUSDm"]}

XAU_SLOTS = [
    (0, 2, ["MOMEMA"], 3.0, 48),
    (2, 4, ["MOMEMA"], 2.0, 48),
    (4, 6, ["BREAK48","MOMEMA"], 3.0, 24),
    (6, 8, ["BREAK48"], 3.0, 48),
    (10, 12, ["RETEST48"], 3.0, 48),
    (14, 16, ["EMACROSS"], 2.0, 48),
    (16, 18, ["RETEST48"], 2.0, 48),
    (22, 24, ["BREAK48"], 3.0, 48),
]
BTC_SLOTS = [
    (4, 6, ["VWAP"], 2.5, 48),
    (16, 18, ["RETEST48"], 2.0, 48),
    (18, 20, ["VWAP"], 2.0, 24),
    (20, 22, ["RETEST48"], 2.5, 48),
]
report("EA MULTIHORARIO XAU FINAL (8 slots)", CACHE["XAUUSDm"], XAU_SLOTS, 20)
report("EA MULTIHORARIO BTC FINAL (4 slots)", CACHE["BTCUSDm"], BTC_SLOTS, 300)
mt5.shutdown()
