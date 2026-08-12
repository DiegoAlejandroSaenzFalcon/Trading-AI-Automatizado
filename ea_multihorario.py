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

def signal(d, i, strat, atr, ema20, ema30, ema60, vw):
    closes = d["close"]; highs = d["high"]; lows = d["low"]
    if strat == "BREAK24":
        if closes[i] > highs[i-24:i].max(): return 1
        if closes[i] < lows[i-24:i].min(): return -1
    elif strat == "BREAK48":
        if closes[i] > highs[i-48:i].max(): return 1
        if closes[i] < lows[i-48:i].min(): return -1
    elif strat == "MOMEMA":
        if closes[i] > ema30[i] and closes[i] > highs[i-3:i].max(): return 1
        if closes[i] < ema30[i] and closes[i] < lows[i-3:i].min(): return -1
    elif strat == "EMACROSS":
        if i < 1: return 0
        if ema20[i] > ema60[i] and ema20[i-1] <= ema60[i-1]: return 1
        if ema20[i] < ema60[i] and ema20[i-1] >= ema60[i-1]: return -1
    elif strat == "RETEST48":
        mx = highs[i-48:i].max(); mn = lows[i-48:i].min()
        if highs[i] >= mx and closes[i] < mx - 0.1*atr[i]: return -1
        if lows[i] <= mn and closes[i] > mn + 0.1*atr[i]: return 1
    elif strat == "VWAP":
        if np.isnan(vw[i]) or np.isnan(vw[i-1]): return 0
        if closes[i] > vw[i] and closes[i-1] <= vw[i-1]: return 1
        if closes[i] < vw[i] and closes[i-1] >= vw[i-1]: return -1
    return 0

SCHEDULE_XAU = [(4, 6, "BREAK48"), (16, 18, "EMACROSS"), (22, 24, "BREAK48")]
SCHEDULE_BTC = [(16, 18, "RETEST48"), (18, 20, "VWAP")]

def run_multi(sym, frm, to, schedule):
    d = load(sym, frm, to)
    n = len(d)
    atr = wilder_atr(d)
    ema20 = ema_arr(d["close"], 20); ema30 = ema_arr(d["close"], 30); ema60 = ema_arr(d["close"], 60)
    vw = vwap_day(d["time"], (d["high"]+d["low"]+d["close"])/3.0)
    trades = []
    pos = None
    for i in range(80, n):
        hour = (d["time"][i] % 86400) // 3600
        strat_now = None
        for h1_, h2_, st in schedule:
            if h1_ <= hour < h2_:
                strat_now = st; break
        at = atr[i]
        if pos is not None:
            dd_, e, sl, tp_l, ttl = pos
            if dd_ == 1:
                if d["low"][i] <= sl: trades.append(-1.0); pos = None; continue
                if d["high"][i] >= tp_l: trades.append(2.0); pos = None; continue
            else:
                if d["high"][i] >= sl: trades.append(-1.0); pos = None; continue
                if d["low"][i] <= tp_l: trades.append(2.0); pos = None; continue
            if i >= ttl: trades.append(0.0); pos = None
            continue
        if strat_now is None or at <= 0: continue
        sig = signal(d, i, strat_now, atr, ema20, ema30, ema60, vw)
        if sig != 0:
            sl_d = 0.8*at; tp_d = 2.0*sl_d
            pos = (sig, d["close"][i], d["close"][i]-sig*sl_d, d["close"][i]+sig*tp_d, i+24)
    return trades

PERIODS = [
    ("P1_24h2-25h1", dtm.datetime(2024,7,1), dtm.datetime(2025,6,30)),
    ("P2_25h2-26e", dtm.datetime(2025,7,1), dtm.datetime(2026,1,31)),
    ("P3_26f-26a", dtm.datetime(2026,2,1), dtm.datetime(2026,8,11)),
]
def report(label, sym, schedule, risk, periods):
    print(f"=== {label} ===")
    all_t = []
    for pname, pfrm, pto in PERIODS:
        tr = run_multi(sym, pfrm, pto, schedule)
        all_t += tr
        a = np.array(tr)*risk
        eq = np.cumsum(a); peak = np.maximum.accumulate(eq); dd = (eq-peak).min()
        w = (a>0).sum()/len(a)*100 if len(a) else 0
        wins = a[a>0].sum(); losses = -a[a<0].sum()
        pf = wins/losses if losses else 99
        months = (pto - pfrm).days/30.4
        print(f"{pname}: n={len(a)} pnl=${a.sum():.0f} win={w:.1f}% PF={pf:.2f} maxDD=${dd:.0f} ({len(a)/months:.1f} tr/mes)")
    a = np.array(all_t)*risk
    eq = np.cumsum(a); peak = np.maximum.accumulate(eq); dd = (eq-peak).min()
    w = (a>0).sum()/len(a)*100 if len(a) else 0
    wins = a[a>0].sum(); losses = -a[a<0].sum()
    pf = wins/losses if losses else 99
    print(f"TOTAL 25M: n={len(a)} pnl=${a.sum():.0f} win={w:.1f}% PF={pf:.2f} maxDD=${dd:.0f} ({len(a)/25:.1f} tr/mes)\n")

report("EA MULTIHORARIO XAU: 04-06 BREAK48 | 16-18 EMACROSS | 22-24 BREAK48 (riesgo $20)", "XAUUSDm", SCHEDULE_XAU, 20, PERIODS)
report("EA MULTIHORARIO BTC: 16-18 RETEST48 | 18-20 VWAP (riesgo $300)", "BTCUSDm", SCHEDULE_BTC, 300, PERIODS)
mt5.shutdown()
