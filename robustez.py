import importlib.util
spec = importlib.util.spec_from_file_location("br", r"C:\Users\H2R\Documents\Default Project\backtest_r30.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)
import MetaTrader5 as mt5
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

# parchear run() para periodo configurable
import datetime as dtm
orig = br.run
def run_period(session_on, frm, to):
    br.INP["SessionFilterEnable"] = session_on
    br.reset()
    m1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M1, frm, to)
    m15 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M15, frm, to)
    h1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_H1, frm, to)
    h4 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_H4, frm, to)
    if m1 is None or m15 is None or h1 is None or h4 is None:
        print("Faltan datos", mt5.last_error())
        return None, None
    atr_h1 = br.wilder_atr(h1, 14)
    atr_m15 = br.wilder_atr(m15, 14)
    ema_h4 = br.ema_series([r["close"] for r in h4], 200)
    t_m15 = {r["time"]: i for i, r in enumerate(m15)}
    t_h1 = {r["time"]: i for i, r in enumerate(h1)}
    t_h4 = {r["time"]: i for i, r in enumerate(h4)}
    trades = []
    dbg = dict(can=0, entered=0)
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
        h4_bar_time = now - (now % 14400)
        idxH4 = t_h4.get(h4_bar_time)
        atr = atr_h1[idxH1] if idxH1 > 0 else 0.0
        atrFvg = atr_m15[idx15] if idx15 > 0 else 0.0
        br.check_day_rollover(now)
        br.kalman_update(mid, 60)
        br.update_adaptive_noise(15.0)
        if br.s.lastMacroBarTime is None or h4_bar_time != br.s.lastMacroBarTime:
            br.s.lastMacroBarTime = h4_bar_time
            if idxH4 is not None and 0 < idxH4 < len(ema_h4):
                ema1 = ema_h4[idxH4]
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
                dbg["entered"] += 1
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
                trades.append(dict(entry_time=pos["time"], pnl=pnl))
                br.s.dayRealizedPL += pnl
                if br.s.dailyLimitHit == False and br.s.dayRealizedPL <= -120.0:
                    br.s.dailyLimitHit = True
                if pnl < 0 and br.INP["CooldownMinutes"] > 0:
                    br.s.cooldownUntil = now + br.INP["CooldownMinutes"]*60
        br.s.lastTickP = pLongAdj
    return trades, dbg

print("=== ROBUSTEZ: 13 May - 11 Ago 2026 (3 meses nuevos) ===")
frm = dtm.datetime(2026, 5, 14)
to = dtm.datetime(2026, 8, 11)
for h0, h1, label in [(16,19,"16-19h actual"),(10,15,"10-15h propuesta"),(12,16,"12-16h propuesta"),(12,15,"12-15h")]:
    br.INP["SessionFilterEnable"] = True
    br.INP["StartHour"] = h0; br.INP["EndHour"] = h1
    trades, dbg = run_period(True, frm, to)
    tot = sum(t["pnl"] for t in trades) if trades else 0.0
    n = len(trades) if trades else 0
    w = sum(1 for t in trades if t["pnl"]>0)/n*100 if n else 0
    print(f"{label:<18}{tot:>10.1f}{n:>8}{w:>7.1f}%")
mt5.shutdown()
