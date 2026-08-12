import importlib.util
spec = importlib.util.spec_from_file_location("br", r"C:\Users\H2R\Documents\Default Project\backtest_r30.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)
import MetaTrader5 as mt5
import datetime as dtm
mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe")

def run_period_equity(frm, to, risk_usd, max_lot, max_daily_loss):
    br.INP["SessionFilterEnable"] = True
    br.INP["StartHour"] = 10; br.INP["EndHour"] = 15
    br.INP["RiskPerTradeUSD"] = risk_usd
    br.INP["MaxLotSize"] = max_lot
    br.INP["MaxDailyLossUSD"] = max_daily_loss
    br.reset()
    m1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M1, frm, to)
    m15 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M15, frm, to)
    h1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_H1, frm, to)
    h4 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_H4, frm, to)
    atr_h1 = br.wilder_atr(h1, 14)
    atr_m15 = br.wilder_atr(m15, 14)
    ema_h4 = br.ema_series([r["close"] for r in h4], 200)
    t_m15 = {r["time"]: i for i, r in enumerate(m15)}
    t_h1 = {r["time"]: i for i, r in enumerate(h1)}
    t_h4 = {r["time"]: i for i, r in enumerate(h4)}
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
                trades.append(dict(entry_time=pos["time"], exit_time=now, pnl=pnl, vol=pos["vol"], type=pos["type"]))
                br.s.dayRealizedPL += pnl
                if not br.s.dailyLimitHit and br.s.dayRealizedPL <= -br.INP["MaxDailyLossUSD"]:
                    br.s.dailyLimitHit = True
                if pnl < 0 and br.INP["CooldownMinutes"] > 0:
                    br.s.cooldownUntil = now + br.INP["CooldownMinutes"]*60
        br.s.lastTickP = pLongAdj
    return trades

def stats(trades, label):
    if not trades:
        print(f"{label}: sin trades")
        return
    eq = 0.0; peak = 0.0; maxdd = 0.0; eq_curve = []
    for t in trades:
        eq += t["pnl"]
        peak = max(peak, eq)
        maxdd = min(maxdd, eq - peak)
    tot = eq
    n = len(trades)
    w = sum(1 for t in trades if t["pnl"]>0)/n*100
    wins = sum(t["pnl"] for t in trades if t["pnl"]>0)
    losses = sum(t["pnl"] for t in trades if t["pnl"]<0)
    pf = wins/abs(losses) if losses else 999
    avg = tot/n
    # peor racha
    worst = 0; cur = 0
    for t in trades:
        if t["pnl"] < 0: cur += t["pnl"]
        else: cur = 0
        worst = min(worst, cur)
    print(f"{label}: tr={n:>3}  pnl={tot:>9.1f}  win={w:>5.1f}%  PF={pf:>5.2f}  maxDD={maxdd:>9.1f}  avg={avg:>6.2f}  peorRacha={worst:>9.1f}")

print("=== 10-15h | FEB-MAY (in sample) ===")
frm1 = dtm.datetime(2026, 2, 1); to1 = dtm.datetime(2026, 5, 13)
for r in (30, 150, 300, 600):
    t = run_period_equity(frm1, to1, r, 2.0, r*4)
    stats(t, f"riesgo ${r}")
print()
print("=== 10-15h | MAY-AGO (out of sample) ===")
frm2 = dtm.datetime(2026, 5, 14); to2 = dtm.datetime(2026, 8, 11)
for r in (30, 150, 300, 600):
    t = run_period_equity(frm2, to2, r, 2.0, r*4)
    stats(t, f"riesgo ${r}")
mt5.shutdown()
