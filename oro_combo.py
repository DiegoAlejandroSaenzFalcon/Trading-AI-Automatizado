import importlib.util, copy
spec = importlib.util.spec_from_file_location("br", r"C:\Users\H2R\Documents\Default Project\backtest_r30.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)
import MetaTrader5 as mt5
import datetime as dtm
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
br.AVG_SPREAD_EST = 0.26
br.SPREAD_HALF = 0.13
BASE = copy.deepcopy(br.INP)

def run_gold(frm, to, overrides):
    br.INP = copy.deepcopy(BASE)
    br.INP.update(overrides)
    br.INP.update({"SessionFilterEnable": True, "StartHour": 15, "EndHour": 17,
                   "RiskPerTradeUSD": 20.0, "MaxLotSize": 1.0, "MaxDailyLossUSD": 80.0})
    br.reset()
    m1 = mt5.copy_rates_range("XAUUSDm", mt5.TIMEFRAME_M1, frm, to)
    m15 = mt5.copy_rates_range("XAUUSDm", mt5.TIMEFRAME_M15, frm, to)
    h1 = mt5.copy_rates_range("XAUUSDm", mt5.TIMEFRAME_H1, frm, to)
    atr_h1 = br.wilder_atr(h1, 14)
    atr_m15 = br.wilder_atr(m15, 14)
    ema_macro = br.ema_series([r["close"] for r in h1], 200)
    t_m15 = {r["time"]: i for i, r in enumerate(m15)}
    t_h1 = {r["time"]: i for i, r in enumerate(h1)}
    trades = []
    for k in range(len(m1)):
        r = m1[k]
        now = r["time"]
        mid = (r["high"] + r["low"]) / 2.0
        h1_bar_time = now - (now % 3600)
        idxH1 = t_h1.get(h1_bar_time)
        if idxH1 is None: continue
        m15_bar_time = now - (now % 900)
        idx15 = t_m15.get(m15_bar_time)
        if idx15 is None: continue
        atr = atr_h1[idxH1] if idxH1 > 0 else 0.0
        atrFvg = atr_m15[idx15] if idx15 > 0 else 0.0
        br.check_day_rollover(now)
        br.kalman_update(mid, 60)
        br.update_adaptive_noise(0.26)
        if br.s.lastMacroBarTime is None or h1_bar_time != br.s.lastMacroBarTime:
            br.s.lastMacroBarTime = h1_bar_time
            if idxH1 is not None and 0 < idxH1 < len(ema_macro):
                ema1 = ema_macro[idxH1]
                if not br.s.macroInit:
                    br.s.temaEma2 = ema1; br.s.temaEma3 = ema1; br.s.macroInit = True
                else:
                    alpha = 2.0/201.0
                    br.s.temaEma2 += alpha*(ema1-br.s.temaEma2)
                    br.s.temaEma3 += alpha*(br.s.temaEma2-br.s.temaEma3)
                br.s.macroEMA = ema1
                br.s.macroTEMA = 3.0*ema1 - 3.0*br.s.temaEma2 + br.s.temaEma3
        pLongNow = br.compute_bias_probability(mid, atr, 3600)
        pLongAdj = pLongNow
        if br.s.paFvgBias == 1: pLongAdj = min(0.98, pLongNow + 0.15)
        elif br.s.paFvgBias == -1: pLongAdj = max(0.02, pLongNow - 0.15)
        br.manage_zone_lifecycle(now, mid, mid, atr)
        if br.s.lastFastBarTime is None or h1_bar_time != br.s.lastFastBarTime:
            br.s.lastFastBarTime = h1_bar_time
            if br.s.prevBarTime is not None and br.s.prevBarTime != h1_bar_time:
                br.s.entrySignalP = br.s.lastTickP
            br.s.prevBarTime = h1_bar_time
        if br.s.lastStructBarTime is None or m15_bar_time != br.s.lastStructBarTime:
            br.s.lastStructBarTime = m15_bar_time
            if idx15 >= 3:
                br.detect_new_fvg([m15[idx15], m15[idx15-1], m15[idx15-2], m15[idx15-3]], atrFvg)
            if idx15 >= 4:
                br.update_price_action_fvg_bias([m15[idx15], m15[idx15-1], m15[idx15-2], m15[idx15-3], m15[idx15-4]], atr)
        canAttempt = (br.s.position is None and not br.in_cooldown(now)
                      and not (br.INP["DailyLossLimitEnable"] and br.s.dailyLimitHit)
                      and br.is_within_session(now) and br.bars_since_entry_ok(h1_bar_time))
        if canAttempt:
            pEntry = br.s.entrySignalP if br.INP["BarConfirmEntry"] else pLongAdj
            if br.execute_biased_entry(pEntry, atr, mid, now):
                br.s.lastEntryBarTime = h1_bar_time
        if br.s.position is not None:
            pos = br.s.position
            br.manage_exits_and_protection(atr, mid, now)
            res = br.check_exit_levels(mid)
            if res is not None:
                if res == -1:
                    pnl = (pos["sl"]-pos["open"])*pos["vol"]*(1 if pos["type"]=="buy" else -1)
                else:
                    pnl = (pos["tp"]-pos["open"])*pos["vol"]*(1 if pos["type"]=="buy" else -1)
                trades.append(dict(entry_time=pos["time"], pnl=pnl, vol=pos["vol"]))
                br.s.dayRealizedPL += pnl
                if not br.s.dailyLimitHit and br.s.dayRealizedPL <= -br.INP["MaxDailyLossUSD"]:
                    br.s.dailyLimitHit = True
                if pnl < 0 and br.INP["CooldownMinutes"] > 0:
                    br.s.cooldownUntil = now + br.INP["CooldownMinutes"]*60
        br.s.lastTickP = pLongAdj
    return trades

def stats(trades):
    if not trades: return (0, 0.0, 0.0, 0.0, 0)
    eq = 0.0; peak = 0.0; maxdd = 0.0
    for t in trades:
        eq += t["pnl"]; peak = max(peak, eq); maxdd = min(maxdd, eq - peak)
    tot = eq; n = len(trades)
    w = sum(1 for t in trades if t["pnl"]>0)/n*100
    wins = sum(t["pnl"] for t in trades if t["pnl"]>0)
    losses = sum(t["pnl"] for t in trades if t["pnl"]<0)
    pf = wins/abs(losses) if losses else 999
    return (n, tot, w, pf, maxdd)

frm1 = dtm.datetime(2026, 2, 1); to1 = dtm.datetime(2026, 5, 13)
frm2 = dtm.datetime(2026, 5, 14); to2 = dtm.datetime(2026, 8, 11)
combos = [
    ("cd15+tp2.5", {"CooldownMinutes": 15, "TPMultiplier": 2.5}),
    ("cd15+tp3.0", {"CooldownMinutes": 15, "TPMultiplier": 3.0}),
    ("cd15+tp2.5+boost0", {"CooldownMinutes": 15, "TPMultiplier": 2.5, "ConfluenceBoost": 0.0}),
]
for name, ov in combos:
    st = stats(run_gold(frm1, to1, ov)); print(f"{name} IS: n={st[0]} pnl={st[1]:.1f} win={st[2]:.1f}% PF={st[3]:.2f} DD={st[4]:.1f}", flush=True)
    st2 = stats(run_gold(frm2, to2, ov)); print(f"{name} OOS: n={st2[0]} pnl={st2[1]:.1f} win={st2[2]:.1f}% PF={st2[3]:.2f} DD={st2[4]:.1f}", flush=True)
mt5.shutdown()
