import math
import time
from datetime import datetime

import MetaTrader5 as mt5

# ============ PARAMETROS r30 (defaults del .mq5) ============
INP = dict(
    ATRPeriod=14,
    KalmanQ11=1e-4, KalmanQ22=1e-2, KalmanR=1e-3,
    KalmanDtFallback=0.1, KalmanMinDt=0.001, DtSmoothingAlpha=0.20,
    MaxAccelHatAbs=3.0, VelocitySens=50.0, DisplacementW=3.0, AccelerationW=10.0,
    BiasThreshold=0.60, SignalMode=1,
    BarConfirmEntry=True, MinBarsBetweenEntries=1,
    MacroBiasEnable=True, MacroPeriod=200, MacroMode=0, MacroPenaltyGamma=0.70,
    AKF_Enable=True, AKF_Window=30, AKF_Alpha=50.0, AKFMode=1,
    FVGTimeframe=15, MinGapATR=0.15, MaxZoneAgeBars=60, MaxActiveZones=8,
    ZoneInvalidateATR=0.5, ZoneToleranceATR=0.3, LookbackBars=20, ConfluenceBoost=0.15,
    RequireZoneProximity=True, RegimeFilterEnable=False, RegimeATRMult=0.80, RegimeATRWindow=240,
    SLSpreadBufferMult=1.5, SpreadSpikeThreshold=1.8, MaxSLSpreadExpansion=2.0,
    LotMode=1, FixedLotSize=0.01, RiskPerTradeUSD=30.0, MaxLotSize=0.40,
    SLMultiplier=0.8, TPMultiplier=2.0, MaxOpenPositions=1,
    MaxSpreadATR=0.35,
    PartialTPEnable=False, PartialFactor=0.50, PartialTriggerATR=1.5,
    BreakevenTriggerATR=1.0, BreakevenLockATR=0.25, TrailBaseATR=0.35,
    TrailTightenRate=0.35, TrailMinATR=0.20, TrailSpreadFloorMult=2.0,
    DailyLossLimitEnable=True, MaxDailyLossUSD=120.0,
    VolTimeStopEnable=True, VolCollapseRatio=0.50, VolTimeStopMinBars=6, VolTimeStopBarTF=0,
    CooldownMinutes=5,
    SessionFilterEnable=True, StartHour=16, StartMinute=0, EndHour=19, EndMinute=0,
)

SIGNAL_BALANCED = 1
AKF_INNOV = 1
MACRO_MODE_EMA = 0
LOT_MODE_RISK = 1

AVG_SPREAD_EST = 15.0  # USD, spread tipico BTCUSDm demo
SPREAD_HALF = AVG_SPREAD_EST / 2.0
H1_SEC = 3600
M15_SEC = 900
H4_SEC = 14400
M1_SEC = 60


# ============ ESTADO ============
class S:
    pass


s = S()


def reset():
    s.avgSpread = AVG_SPREAD_EST
    s.kR = INP["KalmanR"]
    s.kInit = False
    s.kxP = 0.0
    s.kxV = 0.0
    s.prevVelocity = 0.0
    s.kP00 = 0.0
    s.kP01 = 0.0
    s.kP10 = 0.0
    s.kP11 = 0.0
    s.smoothedDt = INP["KalmanDtFallback"]
    s.lastPpred00 = 0.0
    s.lastInnovation = 0.0
    s.innovBuf = [0.0] * INP["AKF_Window"]
    s.spreadBuf = [0.0] * INP["AKF_Window"]
    s.akfBufIdx = 0
    s.akfBufCount = 0
    s.sigWarm = False
    s.sigEVel = 0.0
    s.sigEDis = 0.0
    s.sigEAcc = 0.0
    s.macroInit = False
    s.temaEma2 = 0.0
    s.temaEma3 = 0.0
    s.macroEMA = 0.0
    s.macroTEMA = 0.0
    s.lastMacroBarTime = None
    s.zones = []
    s.lastStructBarTime = None
    s.lastFastBarTime = None
    s.prevBarTime = None
    s.entrySignalP = 0.5
    s.lastTickP = 0.5
    s.paFvgBias = 0
    s.paFvgZoneIdx = -1
    s.lastEntryBarTime = 0
    s.cooldownUntil = 0
    s.dayStart = None
    s.dayRealizedPL = 0.0
    s.dailyLimitHit = False
    s.entryATR = 0.0
    s.position = None
    s.atrHist = [0.0] * INP["RegimeATRWindow"]
    s.atrHistIdx = 0
    s.atrHistCnt = 0


# ============ MOTOR ============
def kalman_update(mid, dt):
    if not s.kInit:
        s.kxP = mid
        s.kxV = 0.0
        s.prevVelocity = 0.0
        s.kInit = True
        return
    s.prevVelocity = s.kxV
    xp0 = s.kxP + dt * s.kxV
    xp1 = s.kxV
    t00 = s.kP00 + dt * s.kP10
    t01 = s.kP01 + dt * s.kP11
    t10 = s.kP10
    t11 = s.kP11
    pp00 = t00 + t01 * dt + INP["KalmanQ11"]
    pp01 = t01
    pp10 = t10 + t11 * dt
    pp11 = t11 + INP["KalmanQ22"]
    s.lastPpred00 = pp00
    y = mid - xp0
    s.lastInnovation = y
    S_ = pp00 + s.kR
    if S_ < 1e-12:
        s.kxP = xp0
        s.kxV = xp1
        s.kP00 = pp00 + INP["KalmanQ11"]
        s.kP01 = pp01
        s.kP10 = pp10
        s.kP11 = pp11 + INP["KalmanQ22"]
        return
    K0 = pp00 / S_
    K1 = pp10 / S_
    s.kxP = xp0 + K0 * y
    s.kxV = xp1 + K1 * y
    s.kP00 = max((1.0 - K0) * pp00, 1e-12)
    s.kP01 = (1.0 - K0) * pp01
    s.kP10 = pp10 - K1 * pp00
    s.kP11 = max(pp11 - K1 * pp01, 1e-12)


def update_adaptive_noise(spread):
    Rbase = max(1e-12, INP["KalmanR"])
    if s.akfBufCount < INP["AKF_Window"]:
        s.akfBufCount += 1
    if INP["AKFMode"] == AKF_INNOV:
        s.innovBuf[s.akfBufIdx] = s.lastInnovation
    s.spreadBuf[s.akfBufIdx] = spread
    s.akfBufIdx = (s.akfBufIdx + 1) % INP["AKF_Window"]
    meanSpread = sum(s.spreadBuf[:s.akfBufCount]) / s.akfBufCount
    s.avgSpread = meanSpread
    if not INP["AKF_Enable"] or s.akfBufCount < 2:
        s.kR = Rbase
        return
    if INP["AKFMode"] == AKF_INNOV:
        meanI = sum(s.innovBuf[:s.akfBufCount]) / s.akfBufCount
        varI = sum((v - meanI) ** 2 for v in s.innovBuf[:s.akfBufCount]) / s.akfBufCount
        Rtarget = varI - s.lastPpred00
        Rtarget = max(Rbase, Rtarget)
        Rtarget = min(Rbase * 100.0, Rtarget)
        s.kR = 0.85 * s.kR + 0.15 * Rtarget
        s.kR = max(Rbase, s.kR)


def compute_bias_probability(mid, atr, bar_sec):
    if atr <= 0.0 or not s.kInit:
        return 0.5
    arg = 0.0
    if INP["SignalMode"] == SIGNAL_BALANCED:
        vNorm = s.kxV * bar_sec / atr
        dNorm = (mid - s.kxP) / atr
        aNorm = 0.0
        if s.smoothedDt > 1e-6:
            aNorm = ((s.kxV - s.prevVelocity) / s.smoothedDt) * bar_sec * bar_sec / atr
            aNorm = max(-INP["MaxAccelHatAbs"], min(INP["MaxAccelHatAbs"], aNorm))
        alpha = 0.005
        if not s.sigWarm:
            s.sigEVel = abs(vNorm)
            s.sigEDis = abs(dNorm)
            s.sigEAcc = abs(aNorm)
            s.sigWarm = True
        else:
            s.sigEVel += alpha * (abs(vNorm) - s.sigEVel)
            s.sigEDis += alpha * (abs(dNorm) - s.sigEDis)
            s.sigEAcc += alpha * (abs(aNorm) - s.sigEAcc)
        eps = 1e-6
        vZ = vNorm / s.sigEVel if s.sigEVel > eps else 0.0
        dZ = dNorm / s.sigEDis if s.sigEDis > eps else 0.0
        aZ = aNorm / s.sigEAcc if s.sigEAcc > eps else 0.0
        arg = INP["VelocitySens"] * vZ + INP["DisplacementW"] * dZ + INP["AccelerationW"] * aZ
    else:
        v_hat = s.kxV / atr
        D = (mid - s.kxP) / atr
        a_hat = 0.0
        if s.smoothedDt > 1e-6:
            a_k = (s.kxV - s.prevVelocity) / s.smoothedDt
            a_hat = a_k / atr
            a_hat = max(-INP["MaxAccelHatAbs"], min(INP["MaxAccelHatAbs"], a_hat))
        arg = INP["VelocitySens"] * v_hat + INP["DisplacementW"] * D + INP["AccelerationW"] * a_hat
    arg = max(-20.0, min(20.0, arg))
    pLong = 1.0 / (1.0 + math.exp(-arg))
    if INP["MacroBiasEnable"] and s.macroInit:
        macroRef = s.macroTEMA if INP["MacroMode"] == 1 else s.macroEMA
        if pLong >= 0.5 and s.kxP < macroRef:
            pLong = pLong * INP["MacroPenaltyGamma"]
        elif pLong < 0.5 and s.kxP > macroRef:
            pShort = 1.0 - pLong
            pShort = pShort * INP["MacroPenaltyGamma"]
            pLong = 1.0 - pShort
    return pLong


# ------- patrones (rates: listas de dicts en serie, [0]=mas reciente) -------
def is_bullish_engulfing(r, i):
    prev = r[i + 1]
    cur = r[i]
    return (prev["close"] < prev["open"] and cur["close"] > cur["open"]
            and cur["open"] <= prev["close"] and cur["close"] >= prev["open"])


def is_bearish_engulfing(r, i):
    prev = r[i + 1]
    cur = r[i]
    return (prev["close"] > prev["open"] and cur["close"] < cur["open"]
            and cur["open"] >= prev["close"] and cur["close"] <= prev["open"])


def is_bullish_pinbar(r, i):
    c = r[i]
    rng = c["high"] - c["low"]
    if rng <= 0:
        return False
    body = abs(c["close"] - c["open"])
    lowerWick = min(c["open"], c["close"]) - c["low"]
    upperWick = c["high"] - max(c["open"], c["close"])
    return body <= rng * 0.35 and lowerWick >= rng * 0.55 and upperWick <= rng * 0.20


def is_bearish_pinbar(r, i):
    c = r[i]
    rng = c["high"] - c["low"]
    if rng <= 0:
        return False
    body = abs(c["close"] - c["open"])
    upperWick = c["high"] - max(c["open"], c["close"])
    lowerWick = min(c["open"], c["close"]) - c["low"]
    return body <= rng * 0.35 and upperWick >= rng * 0.55 and lowerWick <= rng * 0.20


# ------- zonas FVG -------
def count_active_zones():
    return sum(1 for z in s.zones if z["active"])


def add_zone(bottom, top, t, typ):
    if count_active_zones() >= INP["MaxActiveZones"]:
        return
    s.zones.append(dict(top=top, bottom=bottom, time=t, type=typ, active=True))


def manage_zone_lifecycle(now, bid, ask, atr):
    if atr <= 0:
        return
    for i in range(len(s.zones) - 1, -1, -1):
        z = s.zones[i]
        if not z["active"]:
            continue
        if now - z["time"] > M15_SEC * INP["MaxZoneAgeBars"]:
            z["active"] = False
            continue
        if z["type"] == 1 and bid < z["bottom"] - atr * INP["ZoneInvalidateATR"]:
            z["active"] = False
        elif z["type"] == -1 and ask > z["top"] + atr * INP["ZoneInvalidateATR"]:
            z["active"] = False


def detect_new_fvg(m15_series, atr_fvg):
    if atr_fvg <= 0:
        return
    minGap = atr_fvg * INP["MinGapATR"]
    r3 = m15_series[3]
    r1 = m15_series[1]
    if r3["high"] < r1["low"] and (r1["low"] - r3["high"]) >= minGap:
        add_zone(r3["high"], r1["low"], r1["time"], 1)
    if r3["low"] > r1["high"] and (r3["low"] - r1["high"]) >= minGap:
        add_zone(r1["high"], r3["low"], r1["time"], -1)


def update_price_action_fvg_bias(m15_series, atr):
    s.paFvgBias = 0
    s.paFvgZoneIdx = -1
    if atr <= 0:
        return
    tol = atr * INP["ZoneToleranceATR"]
    r1 = m15_series[1]
    bullPattern = is_bullish_engulfing(m15_series, 1) or is_bullish_pinbar(m15_series, 1)
    bearPattern = is_bearish_engulfing(m15_series, 1) or is_bearish_pinbar(m15_series, 1)
    if bullPattern:
        for i, z in enumerate(s.zones):
            if not z["active"] or z["type"] != 1:
                continue
            if r1["low"] <= z["top"] + tol and r1["low"] >= z["bottom"] - tol:
                s.paFvgBias = 1
                s.paFvgZoneIdx = i
                break
    elif bearPattern:
        for i, z in enumerate(s.zones):
            if not z["active"] or z["type"] != -1:
                continue
            if r1["high"] >= z["bottom"] - tol and r1["high"] <= z["top"] + tol:
                s.paFvgBias = -1
                s.paFvgZoneIdx = i
                break


# ------- filtros y entrada -------
def is_within_session(now):
    if not INP["SessionFilterEnable"]:
        return True
    dt = datetime.utcfromtimestamp(now)
    nowMin = dt.hour * 60 + dt.minute
    startMin = INP["StartHour"] * 60 + INP["StartMinute"]
    endMin = INP["EndHour"] * 60 + INP["EndMinute"]
    if startMin == endMin:
        return True
    if startMin < endMin:
        return startMin <= nowMin < endMin
    return nowMin >= startMin or nowMin < endMin


def in_cooldown(now):
    return s.cooldownUntil > 0 and now < s.cooldownUntil


def check_day_rollover(now):
    dt = datetime.utcfromtimestamp(now)
    dayStart = now - (dt.hour * 3600 + dt.minute * 60 + dt.second)
    if dayStart == s.dayStart:
        return
    s.dayStart = dayStart
    s.dayRealizedPL = 0.0
    s.dailyLimitHit = False


def spread_ok(atr):
    if INP["MaxSpreadATR"] <= 0.0:
        return True
    return AVG_SPREAD_EST <= atr * INP["MaxSpreadATR"]


def regime_ok(atr):
    if not INP["RegimeFilterEnable"]:
        return True
    if s.atrHistCnt < min(20, INP["RegimeATRWindow"]):
        return True
    meanATR = sum(s.atrHist[:s.atrHistCnt]) / s.atrHistCnt
    if meanATR <= 0:
        return True
    return atr >= meanATR * INP["RegimeATRMult"]


def bars_since_entry_ok(h1_bar_time):
    if s.lastEntryBarTime <= 0:
        return True
    return h1_bar_time - s.lastEntryBarTime >= INP["MinBarsBetweenEntries"] * H1_SEC


def near_active_zone(direction, price, atr):
    if not INP["RequireZoneProximity"]:
        return True
    if atr <= 0:
        return False
    tol = atr * INP["ZoneToleranceATR"]
    for z in s.zones:
        if not z["active"] or z["type"] != direction:
            continue
        if z["bottom"] - tol <= price <= z["top"] + tol:
            return True
    return False


def compute_adaptive_sltp(atr):
    baseSL = atr * INP["SLMultiplier"]
    baseTP = atr * INP["TPMultiplier"]
    spreadFloor = max(0.0, s.avgSpread) * max(0.0, INP["SLSpreadBufferMult"])
    slDist = max(baseSL, spreadFloor)
    tpDist = baseTP
    if s.avgSpread > 1e-12:
        ratio = AVG_SPREAD_EST / s.avgSpread
        if ratio > INP["SpreadSpikeThreshold"]:
            widenFactor = min(INP["MaxSLSpreadExpansion"], ratio / INP["SpreadSpikeThreshold"])
            slDist *= widenFactor
            tpDist *= widenFactor
    return slDist, tpDist


def normalize_volume(vol):
    step = 0.01
    normalized = int(vol / step + 1e-8) * step
    normalized = max(0.01, min(min(100.0, INP["MaxLotSize"]), normalized))
    return round(normalized, 2)


def calc_lot_size(slDistance):
    if INP["LotMode"] == 0:
        return normalize_volume(INP["FixedLotSize"])
    if slDistance <= 0:
        return 0.01
    lots = INP["RiskPerTradeUSD"] / (slDistance * 1.0)
    return normalize_volume(lots)


def execute_biased_entry(pLong, atr, mid, now):
    if atr <= 0.0:
        return False
    if not spread_ok(atr):
        return False
    if not regime_ok(atr):
        return False
    pShort = 1.0 - pLong
    if pLong >= INP["BiasThreshold"]:
        goLong = True
    elif pShort >= INP["BiasThreshold"]:
        goLong = False
    else:
        return False
    if INP["RequireZoneProximity"]:
        if not near_active_zone(1 if goLong else -1, mid, atr):
            return False
    slDist, tpDist = compute_adaptive_sltp(atr)
    lots = calc_lot_size(slDist)
    if lots <= 0.0:
        return False
    if goLong:
        sl = mid - slDist
        tp = mid + tpDist
        typ = "buy"
        entry = mid + SPREAD_HALF
    else:
        sl = mid + slDist
        tp = mid - tpDist
        typ = "sell"
        entry = mid - SPREAD_HALF
    s.position = dict(open=entry, sl=sl, tp=tp, vol=lots, type=typ, time=now)
    s.entryATR = atr
    s.paFvgBias = 0
    return True


def check_vol_time_stop(atr_now, now):
    if not INP["VolTimeStopEnable"]:
        return False
    if s.entryATR <= 0.0:
        return False
    pos = s.position
    if pos["type"] == "buy" and pos["sl"] >= pos["open"]:
        return False
    if pos["type"] == "sell" and 0 < pos["sl"] <= pos["open"]:
        return False
    barsElapsed = (now - pos["time"]) // H1_SEC
    if barsElapsed < INP["VolTimeStopMinBars"]:
        return False
    ratio = atr_now / s.entryATR
    if ratio >= INP["VolCollapseRatio"]:
        return False
    s.position = None
    return True


def manage_exits_and_protection(atr, mid, now):
    pos = s.position
    if pos is None or atr <= 0.0:
        return
    if check_vol_time_stop(atr, now):
        return
    favorable = (mid - pos["open"]) if pos["type"] == "buy" else (pos["open"] - mid)
    beTrigger = atr * INP["BreakevenTriggerATR"]
    if favorable < beTrigger:
        return
    extraATR = (favorable - beTrigger) / atr
    trailATR = max(INP["TrailMinATR"], INP["TrailBaseATR"] - INP["TrailTightenRate"] * extraATR)
    spreadFloor = s.avgSpread * INP["TrailSpreadFloorMult"]
    beLockDist = max(atr * INP["BreakevenLockATR"], spreadFloor)
    trailDist = max(atr * trailATR, spreadFloor)
    if pos["type"] == "buy":
        candidate = max(pos["open"] + beLockDist, mid - trailDist)
        if candidate > pos["sl"]:
            pos["sl"] = candidate
    else:
        candidate = min(pos["open"] - beLockDist, mid + trailDist)
        if pos["sl"] == 0.0 or candidate < pos["sl"]:
            pos["sl"] = candidate


def check_exit_levels(mid):
    pos = s.position
    if pos is None:
        return None
    if pos["type"] == "buy":
        if mid <= pos["sl"] + SPREAD_HALF:
            s.position = None
            return -1
        if mid >= pos["tp"] - SPREAD_HALF:
            s.position = None
            return 1
    else:
        if mid >= pos["sl"] - SPREAD_HALF:
            s.position = None
            return -1
        if mid <= pos["tp"] + SPREAD_HALF:
            s.position = None
            return 1
    return None


# ============ INDICADORES (numpy, cronologico asc) ============
def wilder_atr(rates, period):
    n = len(rates)
    tr = [0.0] * n
    for i in range(1, n):
        h, l, c = rates[i]["high"], rates[i]["low"], rates[i]["close"]
        pc = rates[i - 1]["close"]
        tr[i] = max(h - l, abs(h - pc), abs(l - pc))
    atr = [0.0] * n
    if n <= period:
        return atr
    atr[period] = sum(tr[1:period + 1]) / period
    for i in range(period + 1, n):
        atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period
    return atr


def ema_series(values, period):
    if not values:
        return []
    alpha = 2.0 / (period + 1.0)
    out = [values[0]]
    for v in values[1:]:
        out.append(out[-1] + alpha * (v - out[-1]))
    return out


# ============ SIMULACION ============
def run(session_on):
    INP["SessionFilterEnable"] = session_on
    reset()
    frm = datetime(2026, 2, 1)
    to = datetime(2026, 5, 13)
    m1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M1, frm, to)
    m15 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M15, frm, to)
    h1 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_H1, frm, to)
    h4 = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_H4, frm, to)
    if m1 is None or m15 is None or h1 is None or h4 is None:
        print("Faltan datos", mt5.last_error())
        return None, None

    atr_h1 = wilder_atr(h1, INP["ATRPeriod"])
    atr_m15 = wilder_atr(m15, INP["ATRPeriod"])
    ema_h4 = ema_series([r["close"] for r in h4], INP["MacroPeriod"])

    # mapas de indice por timestamp
    t_m15 = {r["time"]: i for i, r in enumerate(m15)}
    t_h1 = {r["time"]: i for i, r in enumerate(h1)}
    t_h4 = {r["time"]: i for i, r in enumerate(h4)}

    trades = []
    dbg = dict(can=0, entered=0, zones_det=0, zones_created=0, macro_upd=0)

    t0m = m1[0]["time"]
    for k in range(len(m1)):
        r = m1[k]
        now = r["time"]
        mid = (r["high"] + r["low"]) / 2.0

        # barra H1 / M15 / H4 actual (formandose) por timestamp
        h1_bar_time = now - (now % H1_SEC)
        idxH1 = t_h1.get(h1_bar_time)
        if idxH1 is None:
            continue
        m15_bar_time = now - (now % M15_SEC)
        idx15 = t_m15.get(m15_bar_time)
        if idx15 is None:
            continue
        h4_bar_time = now - (now % H4_SEC)
        idxH4 = t_h4.get(h4_bar_time)

        atr = atr_h1[idxH1] if idxH1 > 0 else 0.0
        atrFvg = atr_m15[idx15] if idx15 > 0 else 0.0

        check_day_rollover(now)
        kalman_update(mid, M1_SEC)
        update_adaptive_noise(AVG_SPREAD_EST)

        # macro: al abrir barra H4 nueva (usa EMA de la H4 cerrada)
        if s.lastMacroBarTime is None or h4_bar_time != s.lastMacroBarTime:
            s.lastMacroBarTime = h4_bar_time
            dbg["macro_upd"] += 1
            if idxH4 is not None and 0 < idxH4 < len(ema_h4):
                ema1 = ema_h4[idxH4]
                if not s.macroInit:
                    s.temaEma2 = ema1
                    s.temaEma3 = ema1
                    s.macroInit = True
                else:
                    alpha = 2.0 / (INP["MacroPeriod"] + 1.0)
                    s.temaEma2 += alpha * (ema1 - s.temaEma2)
                    s.temaEma3 += alpha * (s.temaEma2 - s.temaEma3)
                s.macroEMA = ema1
                s.macroTEMA = 3.0 * ema1 - 3.0 * s.temaEma2 + s.temaEma3

        pLongNow = compute_bias_probability(mid, atr, H1_SEC)
        pLongAdj = pLongNow
        if s.paFvgBias == 1:
            pLongAdj = min(0.98, pLongNow + INP["ConfluenceBoost"])
        elif s.paFvgBias == -1:
            pLongAdj = max(0.02, pLongNow - INP["ConfluenceBoost"])

        manage_zone_lifecycle(now, mid, mid, atr)

        # barra H1 nueva: congelar senal
        if s.lastFastBarTime is None or h1_bar_time != s.lastFastBarTime:
            s.lastFastBarTime = h1_bar_time
            if s.prevBarTime is not None and s.prevBarTime != h1_bar_time:
                s.entrySignalP = s.lastTickP
            s.prevBarTime = h1_bar_time
            if INP["RegimeFilterEnable"]:
                s.atrHist[s.atrHistIdx] = atr
                s.atrHistIdx = (s.atrHistIdx + 1) % INP["RegimeATRWindow"]
                if s.atrHistCnt < INP["RegimeATRWindow"]:
                    s.atrHistCnt += 1

        # barra M15 nueva: FVG + PA (usando velas en serie: [0]=actual, [1]=cerrada, [3]=3 atras)
        if s.lastStructBarTime is None or m15_bar_time != s.lastStructBarTime:
            s.lastStructBarTime = m15_bar_time
            if idx15 >= 3:
                dbg["zones_det"] += 1
                series = [m15[idx15], m15[idx15 - 1], m15[idx15 - 2], m15[idx15 - 3]]
                nz = len(s.zones)
                detect_new_fvg(series, atrFvg)
                if len(s.zones) > nz:
                    dbg["zones_created"] += 1
            if idx15 >= 4:
                series = [m15[idx15], m15[idx15 - 1], m15[idx15 - 2], m15[idx15 - 3], m15[idx15 - 4]]
                update_price_action_fvg_bias(series, atr)

        canAttempt = (s.position is None
                      and not in_cooldown(now)
                      and not (INP["DailyLossLimitEnable"] and s.dailyLimitHit)
                      and is_within_session(now)
                      and bars_since_entry_ok(h1_bar_time))

        if canAttempt:
            dbg["can"] += 1
            pEntry = s.entrySignalP if INP["BarConfirmEntry"] else pLongAdj
            if execute_biased_entry(pEntry, atr, mid, now):
                dbg["entered"] += 1
                s.lastEntryBarTime = h1_bar_time

        if s.position is not None:
            pos = s.position
            manage_exits_and_protection(atr, mid, now)
            res = check_exit_levels(mid)
            if res is not None:
                if res == -1:
                    pnl = (pos["sl"] - pos["open"]) * pos["vol"] * (1 if pos["type"] == "buy" else -1)
                else:
                    pnl = (pos["tp"] - pos["open"]) * pos["vol"] * (1 if pos["type"] == "buy" else -1)
                trades.append(dict(entry_time=pos["time"], exit_time=now, type=pos["type"],
                                   entry=pos["open"], sl=pos["sl"], tp=pos["tp"],
                                   vol=pos["vol"], pnl=pnl, result=res))
                s.dayRealizedPL += pnl
                if INP["DailyLossLimitEnable"] and not s.dailyLimitHit and s.dayRealizedPL <= -INP["MaxDailyLossUSD"]:
                    s.dailyLimitHit = True
                if pnl < 0.0 and INP["CooldownMinutes"] > 0:
                    s.cooldownUntil = now + INP["CooldownMinutes"] * 60

        s.lastTickP = pLongAdj

    return trades, dbg


def main():
    if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
        print("init failed", mt5.last_error())
        return
    print("=== VALIDACION: sesion ON 16-19h ===")
    t_on, dbg_on = run(True)
    if t_on:
        tot = sum(t["pnl"] for t in t_on)
        wins = sum(1 for t in t_on if t["pnl"] > 0)
        print(f"Trades: {len(t_on)}  PnL: {tot:.2f}  Winrate: {wins/len(t_on)*100:.1f}%")
    else:
        print("Sin trades")
    if dbg_on:
        print(f"DBG can={dbg_on['can']} entered={dbg_on['entered']} zones_det={dbg_on['zones_det']} zones_created={dbg_on['zones_created']} macro_upd={dbg_on['macro_upd']}")

    print()
    print("=== ESTUDIO: sesion OFF — PnL por hora de entrada (hora servidor) ===")
    t_off, dbg_off = run(False)
    if t_off:
        tot = sum(t["pnl"] for t in t_off)
        wins = sum(1 for t in t_off if t["pnl"] > 0)
        print(f"Trades totales: {len(t_off)}  PnL: {tot:.2f}  Winrate: {wins/len(t_off)*100:.1f}%")
        by_hour = {}
        for t in t_off:
            h = datetime.utcfromtimestamp(t["entry_time"]).hour
            by_hour.setdefault(h, []).append(t)
        print(f"{'Hora':<6}{'Trades':>7}{'Gan%':>7}{'PnL':>12}")
        for h in sorted(by_hour):
            ts = by_hour[h]
            pl = sum(t["pnl"] for t in ts)
            w = sum(1 for t in ts if t["pnl"] > 0)
            print(f"{h:02d}:00  {len(ts):>6}{w/len(ts)*100:>6.1f}%{pl:>11.2f}")
        import csv
        with open(r"C:\Users\H2R\Documents\Default Project\trades_r30_nosesion.csv", "w", newline="") as f:
            wr = csv.DictWriter(f, fieldnames=["entry_time", "exit_time", "type", "entry", "sl", "tp", "vol", "pnl", "result"])
            wr.writeheader()
            for t in t_off:
                wr.writerow(t)
        print("Guardado: trades_r30_nosesion.csv")
    mt5.shutdown()


if __name__ == "__main__":
    main()
