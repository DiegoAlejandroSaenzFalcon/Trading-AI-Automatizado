import importlib.util, copy
spec = importlib.util.spec_from_file_location("br", r"C:\Users\H2R\Documents\Default Project\backtest_r30.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)
import MetaTrader5 as mt5
import datetime as dtm
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")
BASE = copy.deepcopy(br.INP)

def run_fvg(sym, frm, to, h1_, h2_, risk, cap, macro_tf, mac_h4=False, spread=0.26, spread_half=0.13):
    br.INP = copy.deepcopy(BASE)
    br.INP.update({"SessionFilterEnable": True, "StartHour": h1_, "EndHour": h2_,
                   "RiskPerTradeUSD": risk, "MaxLotSize": cap, "MaxDailyLossUSD": risk*4})
    br.AVG_SPREAD_EST = spread; br.SPREAD_HALF = spread_half
    br.reset()
    m1 = mt5.copy_rates_range(sym, mt5.TIMEFRAME_M1, frm, to)
    m15 = mt5.copy_rates_range(sym, mt5.TIMEFRAME_M15, frm, to)
    h1 = mt5.copy_rates_range(sym, mt5.TIMEFRAME_H1, frm, to)
    h4 = mt5.copy_rates_range(sym, mt5.TIMEFRAME_H4, frm, to)
    macro = h4 if mac_h4 else h1
    atr_h1 = br.wilder_atr(h1, 14)
    atr_m15 = br.wilder_atr(m15, 14)
    ema_macro = br.ema_series([r["close"] for r in macro], 200)
    t_m15 = {r["time"]: i for i, r in enumerate(m15)}
    t_h1 = {r["time"]: i for i, r in enumerate(h1)}
    t_mac = {r["time"]: i for i, r in enumerate(macro)}
    mtf = 3600 if not mac_h4 else 14400
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
        mac_bar_time = now - (now % mtf)
        idxMac = t_mac.get(mac_bar_time)
        atr = atr_h1[idxH1] if idxH1 > 0 else 0.0
        atrFvg = atr_m15[idx15] if idx15 > 0 else 0.0
        br.check_day_rollover(now)
        br.kalman_update(mid, 60)
        br.update_adaptive_noise(spread)
        if br.s.lastMacroBarTime is None or mac_bar_time != br.s.lastMacroBarTime:
            br.s.lastMacroBarTime = mac_bar_time
            if idxMac is not None and 0 < idxMac < len(ema_macro):
                ema1 = ema_macro[idxMac]
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
    return (n, round(tot,1), round(w,1), round(pf,2), round(maxdd,1))

PERIODS = [
    ("P1_24h2-25h1", dtm.datetime(2024,7,1), dtm.datetime(2025,6,30)),
    ("P2_25h2-26e", dtm.datetime(2025,7,1), dtm.datetime(2026,1,31)),
    ("P3_26f-26a", dtm.datetime(2026,2,1), dtm.datetime(2026,8,11)),
]
CONFIGS = [
    ("XAU FVG 15-17 riesgo20", "XAUUSDm", 15, 17, 20.0, 1.0, False, 0.26, 0.13),
    ("BTC FVG 10-15 riesgo300", "BTCUSDm", 10, 15, 300.0, 4.0, True, 15.0, 7.5),
]
for label, sym, h1_, h2_, risk, cap, mac_h4, spread, sh in CONFIGS:
    res = {}
    for pname, pfrm, pto in PERIODS:
        tr = run_fvg(sym, pfrm, pto, h1_, h2_, risk, cap, None, mac_h4, spread, sh)
        s = stats(tr)
        res[pname] = s
        print(f"{label} {pname}: n={s[0]} pnl={s[1]} win={s[2]}% PF={s[3]} DD={s[4]}", flush=True)
    ok = all(res[p][3] > 1.15 and res[p][0] >= 15 for p in res)
    print(f"{label} -> {'PASA 3 PERIODOS' if ok else 'NO PASA'}\n", flush=True)
mt5.shutdown()
print("VALIDACION FINA TERMINADA")
