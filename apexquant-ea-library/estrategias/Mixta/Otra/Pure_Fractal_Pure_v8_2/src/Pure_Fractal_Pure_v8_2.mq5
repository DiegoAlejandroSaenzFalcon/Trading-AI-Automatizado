//+------------------------------------------------------------------+
//|                      Pure_Fractal_Pure_v8_2.mq5                  |
//|       2D Discrete Cinematic Kalman Filter + Acceleration Gauge   |
//|       Full architectural refactor of v7 — Production Build       |
//|                                                                   |
//|  DEFECT ELIMINATED: Dual-EMA Micro-Inertia engine replaced.      |
//|  The g_slowEMA macro-displacement anchor (high inertia, lagging) |
//|  and g_fastEMA velocity proxy are entirely removed. In their     |
//|  place: a constant-velocity Kalman Filter that estimates the     |
//|  TRUE instantaneous price (p_k) and TRUE tick-velocity (v_k)     |
//|  in one O(1) scalar step per tick, with zero lag by construction.|
//|                                                                   |
//|  STATE-SPACE MODEL                                                |
//|    x_k = [p_k, v_k]^T                                            |
//|    Transition:   A = [[1, dt], [0, 1]]                           |
//|    Observation:  H = [1, 0]   (price observed, velocity hidden)  |
//|    Process noise Q: diagonal, user-tunable                       |
//|    Measurement noise R: scalar, user-tunable (now ADAPTIVE)      |
//|                                                                   |
//|  SIGMOID ENGINE                                                   |
//|    P(Long) = sigma(k1*v_hat + k2*D + k3*a_hat)                   |
//|    v_hat = v_k / ATR          (ATR-normalized Kalman velocity)    |
//|    D     = (mid - p_k) / ATR  (structural displacement)          |
//|    a_hat = a_k / ATR          (acceleration reversal gauge)       |
//|    a_k   = (v_k - v_{k-1}) / dt                                  |
//|                                                                   |
//|  NOTE: KalmanUpdate uses explicit 2x2 scalar arithmetic.         |
//|  This avoids the matrix*vector operator type-resolution bug       |
//|  present in certain MetaEditor builds where matrix*vector        |
//|  returns matrix instead of vector. The scalar path is also       |
//|  marginally faster (no dispatch overhead for a fixed 2x2 system).|
//|  This 2x2 scalar core is UNTOUCHED by this revision — every      |
//|  addition below is additive/surgical, never structural to it.    |
//+------------------------------------------------------------------+
//|  ============  INSTITUTIONAL HARDENING — CHANGELOG  ============ |
//|  Every line touched or added carries a // [NEURALGO_UPDATE] tag  |
//|  for audit purposes. Five subsystems were layered on top of the  |
//|  original v8 core without altering its proven entry/exit logic:  |
//|                                                                   |
//|   1. Full input parametrization, organized by group().           |
//|   2. Risk & Damage Control:                                      |
//|        - Hard Limit (USD): ATR-based SL is truncated so realized |
//|          monetary risk never exceeds InpMaxRiskUSD (tick-value   |
//|          based, not point-based — avoids the tick-size/point     |
//|          mismatch bug common on 3/5-digit or metal symbols).     |
//|        - Damage Control: at a configurable fraction of the Hard  |
//|          Limit, a contrary hedge is opened (Hedging-account      |
//|          aware) to defend equity ahead of full liquidation.      |
//|        - Anti-Revenge Cooldown: N minutes of signal-scanning     |
//|          pause after ANY losing close (detected via              |
//|          OnTradeTransaction, not polling).                       |
//|   3. Soft Macro Bias: EMA200 gate (TEMA-selectable) that          |
//|      multiplies — never hard-blocks — counter-trend entries by   |
//|      a parametric gamma.                                         |
//|   4. Adaptive Kalman Filter (AKF): R_k = R_base*(1+alpha*sigma^2)|
//|      where sigma^2 blends rolling tick-return variance with a    |
//|      spread-widening amplifier, so institutional noise/whipsaws  |
//|      inflate R_k and collapse the Kalman gain automatically.     |
//|   5. Session isolation strictly on TimeTradeServer() — gates new |
//|      entries only, never touches open-position protection.       |
//|                                                                   |
//|  Cannot be verified against a live MetaEditor compiler from this |
//|  environment — written to Strict-Mode discipline (explicit casts |
//|  on every long/int narrowing, ArraySetAsSeries on every buffer,  |
//|  input variables never reassigned, sanitized runtime copies used |
//|  wherever an input feeds an array size or a modulo). Compile in  |
//|  MetaEditor before demo/live use.                                |
//+------------------------------------------------------------------+
#property copyright "Quantitative Systems Architecture"
#property version   "8.20"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;                                          // primary entries / exits (magic = g_magic)
CTrade tradeHedge;               // [NEURALGO_UPDATE] dedicated instance for Damage Control hedges

//===================================================================
//  [NEURALGO_UPDATE] ENUMS — declared ahead of INPUTS because
//  ENUM_MACRO_MODE is consumed by an input declaration below.
//===================================================================
enum ENUM_MACRO_MODE
{
    MACRO_MODE_EMA  = 0,   // EMA200 (active, zero cold-start bias)
    MACRO_MODE_TEMA = 1    // TEMA200 (lag-reduced, cascade-seeded from EMA200)
};

enum ENUM_DC_STATE
{
    DC_STATE_NORMAL = 0,   // single primary position (or flat) — standard flow
    DC_STATE_HEDGED = 1    // Damage Control hedge deployed — combined-P/L unwind flow
};

//===================================================================
//  INPUT PARAMETERS
//===================================================================

//--- Core Risk Parameters (preserved from v7)
input group "Core Risk Parameters";
input double InpLotSize          = 0.01;   // Lot Size
input int    InpATRPeriod        = 14;     // ATR Period
input double InpTPMultiplier     = 0.8;    // TP Multiplier (ATR x)
input double InpSLMultiplier     = 3.0;    // SL Multiplier (ATR x)
input int    InpTrailingPoints   = 10;     // Trailing Stop (points)
input int    InpMinPointsProfit  = 2;      // Min Points for Breakeven

//--- 2D Cinematic Kalman Filter
//    Q tunes the filter's agility (high Q = trust new ticks more).
//    R tunes noise rejection (high R = smoother, more lag).
//    Q11 governs position uncertainty; Q22 governs velocity uncertainty.
//    Typical XAUUSD starting range: Q11 1e-5..1e-3, Q22 1e-3..1e-1, R 1e-4..1e-2
input group "2D Cinematic Kalman Filter";
input double InpKalmanQ11        = 1e-4;   // Q[0][0]: position process noise
input double InpKalmanQ22        = 1e-2;   // Q[1][1]: velocity process noise
input double InpKalmanR          = 1e-3;   // R_base: measurement noise floor (AKF scales this up)
input double InpKalmanDtFallback = 0.1;    // Fallback delta-t (seconds) for tick 0

//--- Kalman-Fused Sigmoid Parameters
input group "Kalman-Fused Sigmoid Engine";
input double InpVelocitySens     = 50.0;   // k1: Kalman velocity sensitivity
input double InpDisplacementW    = 3.0;    // k2: Filtered displacement weight
input double InpAccelerationW    = 10.0;   // k3: Acceleration reversal amplifier
input double InpBiasThreshold    = 0.55;   // Min P(direction) to commit market entry

//--- [NEURALGO_UPDATE] Adaptive Kalman Filter (AKF)
input group "Adaptive Kalman Filter (AKF)";
input bool   InpAKF_Enable       = true;   // Enable dynamic R_k (disable = static InpKalmanR)
input int    InpAKF_Window       = 30;     // Rolling sample window (ticks) for variance engine
input double InpAKF_Alpha        = 50.0;   // alpha: sigma^2_tick -> R_k amplification gain

//--- [NEURALGO_UPDATE] Soft Macro Bias (EMA/TEMA gate)
input group "Soft Macro Bias (EMA/TEMA Gate)";
input bool             InpMacroBiasEnable  = true;             // Enable macro-trend penalty
input int               InpMacroPeriod     = 200;              // MA period (EMA200 baseline)
input ENUM_MACRO_MODE   InpMacroMode       = MACRO_MODE_EMA;    // EMA (now) or TEMA (lag-reduced)
input double             InpMacroPenaltyGamma = 0.70;            // gamma in (0,1]: counter-trend penalty

//--- [NEURALGO_UPDATE] Risk — Hard Limit (USD)
input group "Risk - Hard Limit (USD)";
input double InpMaxRiskUSD       = 8.0;    // Absolute max risk per cycle, account-currency units

//--- [NEURALGO_UPDATE] Risk — Damage Control (Hedge)
input group "Risk - Damage Control (Hedge)";
input bool   InpDamageControlEnable          = true;  // Enable contrary-hedge defense
input double InpDamageControlTriggerPct      = 0.50;  // Fraction of InpMaxRiskUSD that arms the hedge
input double InpDamageControlBalanceUsagePct = 0.50;  // Fraction of min(Balance,FreeMargin) used for hedge size

//--- [NEURALGO_UPDATE] Risk — Anti-Revenge Cooldown
input group "Risk - Anti-Revenge Cooldown";
input int    InpCooldownMinutes  = 15;     // Minutes to pause new signal-scanning after a losing close

//--- [NEURALGO_UPDATE] Session Filter — strictly TimeTradeServer()
input group "Session Filter (Server Time)";
input bool   InpSessionFilterEnable = true;  // Gate NEW entries to this server-time window
input int    InpStartHour        = 7;        // Session start hour   [0-23]
input int    InpStartMinute      = 0;        // Session start minute [0-59]
input int    InpEndHour          = 19;       // Session end hour     [0-23]
input int    InpEndMinute        = 0;        // Session end minute   [0-59]

//===================================================================
//  GLOBAL STATE — KALMAN ENGINE
//  All stored as plain scalars to avoid matrix/vector operator
//  ambiguity in the MQL5 compiler. Element access on matrix/vector
//  types works fine; it is the arithmetic *operators* between them
//  that have version-dependent return-type resolution.
//===================================================================

//--- Kalman state estimate: x = [p_k, v_k]
double g_kxP = 0.0;    // p_k : Kalman-filtered true price
double g_kxV = 0.0;    // v_k : Kalman-estimated instantaneous velocity

//--- Error covariance matrix P (2x2, symmetric)
double g_kP00 = 1.0,  g_kP01 = 0.0;
double g_kP10 = 0.0,  g_kP11 = 1.0;

//--- Process noise Q (diagonal elements only; Q01 = Q10 = 0)
double g_kQpos = 1e-4;  // Q[0][0]: position process noise
double g_kQvel = 1e-2;  // Q[1][1]: velocity process noise

//--- Measurement noise R (now driven per-tick by UpdateAdaptiveNoise when AKF is enabled)
double g_kR    = 1e-3;

//--- Runtime state
bool   g_kInit        = false;  // true after first valid mid-price observed
ulong  g_lastTickUs   = 0;      // microsecond timestamp of the previous tick
double g_lastTickDt   = 0.1;    // actual delta-t of the most recent Kalman step
double g_prevVelocity = 0.0;    // v_{k-1}: archived velocity for acceleration gauge

//--- ATR
int    g_hATR;
double g_bufATR[];
ulong  g_magic = 888;

//===================================================================
//  [NEURALGO_UPDATE] GLOBAL STATE — RISK / DAMAGE CONTROL
//===================================================================
ulong         g_magicHedge    = 889;      // distinct magic for the hedge leg
ENUM_DC_STATE g_dcState       = DC_STATE_NORMAL;
double        g_dcTriggerPct  = 0.50;     // sanitized runtime copy of InpDamageControlTriggerPct
datetime      g_cooldownUntil = 0;        // TimeTradeServer() timestamp; 0 = no active cooldown

//===================================================================
//  [NEURALGO_UPDATE] GLOBAL STATE — SOFT MACRO BIAS (EMA/TEMA)
//===================================================================
int      g_hMacroEMA;                     // native EMA(InpMacroPeriod) handle — always computed
bool     g_macroInit        = false;
datetime g_lastMacroBarTime = 0;
double   g_macroEMA         = 0.0;        // stage 1: native EMA
double   g_macroTEMA        = 0.0;        // 3*EMA1 - 3*EMA2 + EMA3
double   g_tema_ema2        = 0.0;        // stage 2: hand-rolled EMA-of-EMA1
double   g_tema_ema3        = 0.0;        // stage 3: hand-rolled EMA-of-EMA2

//===================================================================
//  [NEURALGO_UPDATE] GLOBAL STATE — ADAPTIVE KALMAN FILTER (AKF)
//===================================================================
double g_tickBuf[];       // circular buffer of mid-price tick deltas
double g_spreadBuf[];     // circular buffer of instantaneous spreads
int    g_akfWindow   = 30;   // sanitized runtime copy of InpAKF_Window (>=2, drives array size + modulo)
int    g_akfBufIdx   = 0;
int    g_akfBufCount = 0;
bool   g_akfInit      = false;
double g_lastMid      = 0.0;

//===================================================================
//  OnInit
//===================================================================
int OnInit()
{
    //--- [NEURALGO_UPDATE] Critical parameter validation — fail fast on nonsensical risk config
    if(InpMaxRiskUSD <= 0.0)
    {
        Print("ERROR: InpMaxRiskUSD debe ser mayor a 0. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpDamageControlBalanceUsagePct < 0.0)
    {
        Print("ERROR: InpDamageControlBalanceUsagePct no puede ser negativo. EA no iniciado.");
        return INIT_PARAMETERS_INCORRECT;
    }

    //--- [NEURALGO_UPDATE] Sanitized runtime copy of the Damage Control trigger fraction.
    //    InpDamageControlTriggerPct is an 'input' (read-only); we cannot reassign it, so an
    //    out-of-range value is clamped into g_dcTriggerPct instead and used everywhere else.
    g_dcTriggerPct = InpDamageControlTriggerPct;
    if(g_dcTriggerPct <= 0.0 || g_dcTriggerPct > 1.0)
    {
        Print("[NEURALGO_UPDATE] AVISO: InpDamageControlTriggerPct fuera de (0,1]. Se usa 0.50 internamente.");
        g_dcTriggerPct = 0.50;
    }

    if(InpMacroPenaltyGamma <= 0.0 || InpMacroPenaltyGamma > 1.0)
        Print("[NEURALGO_UPDATE] AVISO: InpMacroPenaltyGamma fuera de (0,1]. Revise el valor configurado.");

    if(InpMacroPeriod < 1)
        Print("[NEURALGO_UPDATE] AVISO: InpMacroPeriod < 1. El handle de EMA podria fallar.");

    //--- Trade objects: magic numbers + broker-compatible filling mode
    trade.SetExpertMagicNumber(g_magic);
    trade.SetTypeFilling(GetBestFillingMode(_Symbol));                    // [NEURALGO_UPDATE]

    tradeHedge.SetExpertMagicNumber(g_magicHedge);                        // [NEURALGO_UPDATE]
    tradeHedge.SetTypeFilling(GetBestFillingMode(_Symbol));               // [NEURALGO_UPDATE]

    //--- ATR indicator handle
    g_hATR = iATR(_Symbol, _Period, InpATRPeriod);
    if(g_hATR == INVALID_HANDLE)
    {
        Print("ERROR: ATR handle creation failed. EA will not start.");
        return INIT_FAILED;
    }
    ArraySetAsSeries(g_bufATR, true);

    //--- [NEURALGO_UPDATE] Soft Macro Bias: native EMA handle (stage 1 of the TEMA cascade too)
    g_hMacroEMA = iMA(_Symbol, _Period, InpMacroPeriod, 0, MODE_EMA, PRICE_CLOSE);
    if(g_hMacroEMA == INVALID_HANDLE)
    {
        Print("ERROR: Macro EMA handle creation failed. EA will not start.");
        return INIT_FAILED;
    }
    g_macroInit        = false;
    g_lastMacroBarTime = 0;
    g_macroEMA         = 0.0;
    g_macroTEMA        = 0.0;
    g_tema_ema2        = 0.0;
    g_tema_ema3         = 0.0;

    //--- [NEURALGO_UPDATE] AKF: circular buffers sized ONCE from a sanitized window (never resized per tick)
    g_akfWindow = InpAKF_Window;
    if(g_akfWindow < 2)
    {
        Print("[NEURALGO_UPDATE] AVISO: InpAKF_Window < 2. Se usa 2 internamente.");
        g_akfWindow = 2;
    }
    ArrayResize(g_tickBuf, g_akfWindow);
    ArrayResize(g_spreadBuf, g_akfWindow);
    ArrayInitialize(g_tickBuf, 0.0);
    ArrayInitialize(g_spreadBuf, 0.0);
    g_akfInit     = false;
    g_akfBufIdx   = 0;
    g_akfBufCount = 0;
    g_lastMid     = 0.0;

    //--- Kalman state: zero-seeded; overwritten on cold-start
    g_kxP = 0.0;
    g_kxV = 0.0;

    //--- Error covariance P: identity (large initial uncertainty, converges fast)
    g_kP00 = 1.0;  g_kP01 = 0.0;
    g_kP10 = 0.0;  g_kP11 = 1.0;

    //--- Process noise Q: must be strictly positive
    g_kQpos = MathMax(1e-12, InpKalmanQ11);
    g_kQvel = MathMax(1e-12, InpKalmanQ22);

    //--- Measurement noise R: must be strictly positive (AKF overwrites this every tick if enabled)
    g_kR = MathMax(1e-12, InpKalmanR);

    //--- Reset runtime state
    g_kInit        = false;
    g_lastTickUs   = 0;
    g_lastTickDt   = InpKalmanDtFallback;
    g_prevVelocity = 0.0;

    //--- [NEURALGO_UPDATE] Risk / Damage Control state reset
    g_dcState       = DC_STATE_NORMAL;
    g_cooldownUntil = 0;

    //--- [NEURALGO_UPDATE] Damage Control needs a Hedging-mode account to hold two opposite
    //    positions simultaneously. On a Netting account the hedge order would net against the
    //    primary instead of opening a true parallel position, so we warn (not fail) up front.
    if(InpDamageControlEnable &&
       (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
    {
        Print("[NEURALGO_UPDATE] AVISO: la cuenta no esta en modo Hedging. ",
              "Damage Control no podra abrir una cobertura paralela y se omitira en tiempo de ejecucion.");
    }

    Print("Pure_Fractal v8.2 [Institutional Hardened] initialised | ",
          "Qpos=", DoubleToString(InpKalmanQ11, 5),
          " Qvel=", DoubleToString(InpKalmanQ22, 5),
          " Rbase=", DoubleToString(InpKalmanR, 5),
          " | k1=", InpVelocitySens, " k2=", InpDisplacementW, " k3=", InpAccelerationW,
          " | Thr=", InpBiasThreshold,
          " | MaxRiskUSD=", DoubleToString(InpMaxRiskUSD, 2),
          " | DCTrigger=", DoubleToString(g_dcTriggerPct, 2),
          " | Session=", (InpSessionFilterEnable ? "ON" : "OFF"));

    return INIT_SUCCEEDED;
}

//===================================================================
//  OnDeinit
//===================================================================
void OnDeinit(const int reason)
{
    if(g_hATR != INVALID_HANDLE)
        IndicatorRelease(g_hATR);

    if(g_hMacroEMA != INVALID_HANDLE)                       // [NEURALGO_UPDATE]
        IndicatorRelease(g_hMacroEMA);
}

//===================================================================
//  OnTick  —  Continuous execution loop, zero tick-skipping
//===================================================================
void OnTick()
{
    if(CopyBuffer(g_hATR, 0, 0, 1, g_bufATR) < 1) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double mid = (ask + bid) * 0.5;

    UpdateAdaptiveNoise(mid, ask, bid);      // [NEURALGO_UPDATE] must run BEFORE KalmanUpdate
    KalmanUpdate(mid);
    UpdateMacroFilter();                     // [NEURALGO_UPDATE] EMA/TEMA refresh (new-bar gated)

    if(CheckHardRiskLimit())                 // [NEURALGO_UPDATE] highest-priority equity backstop
        return;

    if(g_dcState == DC_STATE_HEDGED)         // [NEURALGO_UPDATE]
    {
        ManageDamageControlState();
        return;
    }

    if(CountPositions() == 0)
    {
        if(InCooldown()) return;                                   // [NEURALGO_UPDATE]
        if(InpSessionFilterEnable && !IsWithinSession()) return;    // [NEURALGO_UPDATE]
        ExecuteBiasedEntry();
    }
    else
    {
        ManageExitsAndProtection();
        CheckDamageControl();                // [NEURALGO_UPDATE]
    }
}

//===================================================================
//  [NEURALGO_UPDATE] OnTradeTransaction
//  Event-driven (not polled) Anti-Revenge Cooldown trigger: any deal
//  that CLOSES exposure for our magic numbers with a negative net
//  result (profit + swap + commission) arms the cooldown.
//===================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    ulong dealTicket = trans.deal;
    if(!HistoryDealSelect(dealTicket)) return;

    long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
    if(dealMagic != g_magic && dealMagic != g_magicHedge) return;

    long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY) return; // only closing deals

    double dealResult = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                       + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                       + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

    if(dealResult < 0.0 && InpCooldownMinutes > 0)
    {
        g_cooldownUntil = TimeTradeServer() + InpCooldownMinutes * 60;
        PrintFormat("[NEURALGO_UPDATE] Anti-Revenge Cooldown activo hasta %s (perdida detectada: %.2f)",
                    TimeToString(g_cooldownUntil, TIME_DATE | TIME_MINUTES), dealResult);
    }
}

//===================================================================
//  [NEURALGO_UPDATE] UpdateAdaptiveNoise  (Adaptive Kalman Filter)
//
//  Required formula:  R_k = R_base * (1 + alpha * sigma^2_tick)
//
//  sigma^2_tick is built from TWO signals as specified narratively:
//    (a) rolling population variance of mid-price tick deltas
//        (raw price^2 units — dimensionally consistent with R,
//         which is added directly to a price^2 covariance term
//         inside KalmanUpdate; no ATR-normalization here).
//    (b) a spread-widening amplifier: if the instantaneous spread
//        is elevated versus its own rolling average (institutional
//        noise / news manipulation widening the book), the tick
//        variance is scaled up further. The amplifier only ever
//        pushes R_k UP (MathMax with 1.0), never below the pure
//        tick-variance estimate.
//
//  As R_k grows, S = pp00 + R_k grows, so K0/K1 = pp.. / S collapse
//  towards zero inside KalmanUpdate — the filter coasts on its
//  predicted trajectory and effectively ignores the noisy print,
//  exactly the "ignore the noise, hold directional inertia" goal.
//===================================================================
void UpdateAdaptiveNoise(double mid, double ask, double bid)
{
    double Rbase = MathMax(1e-12, InpKalmanR);

    if(!InpAKF_Enable)
    {
        g_kR = Rbase;
        return;
    }

    double spread = ask - bid;

    if(!g_akfInit)
    {
        g_lastMid  = mid;
        g_akfInit  = true;
        g_kR       = Rbase;
        return;
    }

    double tickDelta = mid - g_lastMid;
    g_lastMid = mid;

    g_tickBuf[g_akfBufIdx]   = tickDelta;
    g_spreadBuf[g_akfBufIdx] = spread;
    g_akfBufIdx = (g_akfBufIdx + 1) % g_akfWindow;           // g_akfWindow is the sanitized copy
    if(g_akfBufCount < g_akfWindow) g_akfBufCount++;

    if(g_akfBufCount < 2)
    {
        g_kR = Rbase;
        return;
    }

    //--- (a) rolling variance of tick deltas
    double meanTick = 0.0;
    for(int i = 0; i < g_akfBufCount; i++)
        meanTick += g_tickBuf[i];
    meanTick /= g_akfBufCount;

    double varTick = 0.0;
    for(int i = 0; i < g_akfBufCount; i++)
    {
        double d = g_tickBuf[i] - meanTick;
        varTick += d * d;
    }
    varTick /= g_akfBufCount;

    //--- (b) spread-widening amplifier
    double meanSpread = 0.0;
    for(int i = 0; i < g_akfBufCount; i++)
        meanSpread += g_spreadBuf[i];
    meanSpread /= g_akfBufCount;

    double spreadRatio     = (meanSpread > 0.0) ? (spread / meanSpread) : 1.0;
    double spreadAmplifier = MathMax(1.0, spreadRatio);

    double sigmaTickSqEff = varTick * spreadAmplifier;

    g_kR = MathMax(1e-12, Rbase * (1.0 + InpAKF_Alpha * sigmaTickSqEff));
}

//===================================================================
//  KalmanUpdate
//
//  One complete Predict -> Update cycle of the 2D Discrete Kalman
//  Filter. All arithmetic is explicit 2x2 scalar — O(1), zero
//  matrix/vector operator calls (avoids MQL5 type-resolution bugs).
//
//  Motion model (constant-velocity):
//    x_k = A * x_{k-1}   A = [[1, dt], [0, 1]]
//    z_k = H * x_k + v   H = [1, 0]
//
//  ---------------------------------------------------------------
//  PREDICT
//    xp0 = p + dt*v                   (predicted price)
//    xp1 = v                          (predicted velocity)
//
//    tmp = A * P  (intermediate):
//      t00 = P00 + dt*P10
//      t01 = P01 + dt*P11
//      t10 = P10
//      t11 = P11
//
//    P_pred = tmp * A^T + Q  (A^T = [[1,0],[dt,1]]):
//      pp00 = t00 + t01*dt + Qpos
//      pp01 = t01
//      pp10 = t10 + t11*dt
//      pp11 = t11 + Qvel
//
//  UPDATE
//    y  = mid - xp0                   (innovation)
//    S  = pp00 + R                    (innovation covariance, scalar)
//    K0 = pp00 / S  ,  K1 = pp10 / S  (Kalman gain, H selects col 0)
//
//    State:
//      p_k = xp0 + K0 * y
//      v_k = xp1 + K1 * y
//
//    Covariance  (I - K*H) * P_pred,  (I-KH)=[[1-K0,0],[-K1,1]]):
//      P00 = (1-K0)*pp00
//      P01 = (1-K0)*pp01
//      P10 = pp10 - K1*pp00
//      P11 = pp11 - K1*pp01
//
//  NOTE [NEURALGO_UPDATE]: g_kR is now written by UpdateAdaptiveNoise()
//  once per tick BEFORE this function runs. This function itself is
//  otherwise byte-for-byte identical to the original v8 core.
//===================================================================
void KalmanUpdate(double mid)
{
    //--- Dynamic delta-t: real wall-clock elapsed since previous tick
    ulong  nowUs = GetMicrosecondCount();
    double dt;
    if(!g_kInit || g_lastTickUs == 0)
    {
        dt = InpKalmanDtFallback;
    }
    else
    {
        double rawDt = (double)(nowUs - g_lastTickUs) * 1e-6;  // us -> seconds
        dt = MathMax(1e-6, MathMin(60.0, rawDt));              // clamp [1µs, 60s]
    }
    g_lastTickUs = nowUs;
    g_lastTickDt = dt;  // expose to ComputeBiasProbability acceleration gauge

    //--- Cold-start: seed filter from first observed price
    if(!g_kInit)
    {
        g_kxP          = mid;
        g_kxV          = 0.0;
        g_prevVelocity = 0.0;
        g_kInit        = true;
        return;  // no prediction on first tick — no prior history
    }

    //--- Archive previous velocity before overwrite (acceleration gauge)
    g_prevVelocity = g_kxV;

    //---------------------------------------------------------------
    //  PREDICT STEP
    //---------------------------------------------------------------
    // x_pred = A * [p, v]^T
    double xp0 = g_kxP + dt * g_kxV;   // p_pred
    double xp1 = g_kxV;                  // v_pred

    // tmp = A * P   (A = [[1,dt],[0,1]])
    double t00 = g_kP00 + dt * g_kP10;
    double t01 = g_kP01 + dt * g_kP11;
    double t10 = g_kP10;
    double t11 = g_kP11;

    // P_pred = tmp * A^T + Q   (A^T = [[1,0],[dt,1]])
    double pp00 = t00 + t01 * dt + g_kQpos;
    double pp01 = t01;
    double pp10 = t10 + t11 * dt;
    double pp11 = t11 + g_kQvel;

    //---------------------------------------------------------------
    //  UPDATE STEP
    //---------------------------------------------------------------
    // Innovation: y = z - H*x_pred  (H=[1,0] => selects price only)
    double y = mid - xp0;

    // Innovation covariance: S = H*P_pred*H^T + R = pp00 + R
    double S = pp00 + g_kR;

    // Guard: degenerate S — fallback to prediction, inflate P
    if(S < 1e-12)
    {
        g_kxP  = xp0;   g_kxV  = xp1;
        g_kP00 = pp00 + g_kQpos;  g_kP01 = pp01;
        g_kP10 = pp10;             g_kP11 = pp11 + g_kQvel;
        return;
    }

    // Kalman gain: K = P_pred * H^T / S
    // H^T = [1;0] => K = first column of P_pred / S
    double K0 = pp00 / S;
    double K1 = pp10 / S;

    // State update: x_k = x_pred + K * y
    g_kxP = xp0 + K0 * y;
    g_kxV = xp1 + K1 * y;

    // Covariance update: P_k = (I - K*H) * P_pred
    // (I - K*H) = [[1-K0, 0], [-K1, 1]]
    g_kP00 = MathMax((1.0 - K0) * pp00,          1e-12);  // positivity guard
    g_kP01 =         (1.0 - K0) * pp01;
    g_kP10 = pp10 - K1 * pp00;
    g_kP11 = MathMax(pp11 - K1 * pp01,            1e-12);  // positivity guard
}

//===================================================================
//  [NEURALGO_UPDATE] UpdateMacroFilter / GetMacroFilterValue
//
//  Soft Macro Bias data source. Stage 1 (EMA200) is the platform's
//  own native EMA — reliable, pre-warmed, no seeding bias of ours.
//  Stages 2-3 are a hand-rolled recursive EMA-of-EMA cascade (the
//  textbook TEMA construction: TEMA = 3*E1 - 3*E2 + E3, E2=EMA(E1),
//  E3=EMA(E2)) seeded from the first available EMA1 reading, which
//  converges quickly since it only needs to be numerically stable
//  after the EA has already accumulated live bar history. Refreshed
//  once per NEW BAR (macro filters have no business reacting to
//  intra-bar noise), never per tick.
//===================================================================
void UpdateMacroFilter()
{
    if(!InpMacroBiasEnable) return;

    datetime curBarTime = iTime(_Symbol, _Period, 0);
    if(curBarTime == g_lastMacroBarTime) return;   // same bar — nothing to refresh yet
    g_lastMacroBarTime = curBarTime;

    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(g_hMacroEMA, 0, 0, 1, buf) < 1) return;
    double ema1 = buf[0];

    if(!g_macroInit)
    {
        g_tema_ema2 = ema1;
        g_tema_ema3 = ema1;
        g_macroInit = true;
    }
    else
    {
        double alpha = 2.0 / (InpMacroPeriod + 1.0);
        g_tema_ema2 += alpha * (ema1 - g_tema_ema2);
        g_tema_ema3 += alpha * (g_tema_ema2 - g_tema_ema3);
    }

    g_macroEMA  = ema1;
    g_macroTEMA = 3.0 * ema1 - 3.0 * g_tema_ema2 + g_tema_ema3;
}

double GetMacroFilterValue()
{
    return (InpMacroMode == MACRO_MODE_TEMA) ? g_macroTEMA : g_macroEMA;
}

//===================================================================
//  ComputeBiasProbability
//
//  Maps Kalman state -> P(Long) in [0,1] via 3-layer fused sigmoid:
//
//    P(Long) = sigma(k1*v_hat + k2*D + k3*a_hat)
//
//  v_hat = v_k / ATR            (ATR-normalized Kalman velocity)
//  D     = (mid - p_k) / ATR   (raw price vs Kalman filtered price)
//  a_hat = a_k / ATR           (normalized instantaneous acceleration)
//  a_k   = (v_k - v_{k-1}) / dt
//
//  Reversal logic embedded in a_k:
//    sign(v_k) == sign(a_k): impulse strengthening => amplifies sigmoid
//    sign(v_k) != sign(a_k): micro-exhaustion/pivot => crushes sigmoid
//
//  [NEURALGO_UPDATE] Soft Macro Bias penalty is applied AFTER the raw
//  sigmoid, as a multiplicative — never a hard — gate:
//    signal=LONG  & p_k < MacroRef  => pLong  *= gamma
//    signal=SHORT & p_k > MacroRef  => pShort *= gamma  (renormalized)
//  gamma in (0,1] always keeps the result inside [0,1].
//===================================================================
double ComputeBiasProbability(double mid, double atr)
{
    if(atr <= 0.0 || !g_kInit) return 0.5;

    //--- Layer 1: ATR-normalized Kalman velocity
    double v_hat = g_kxV / atr;

    //--- Layer 2: Structural displacement of raw price vs filtered state
    double D = (mid - g_kxP) / atr;

    //--- Layer 3: Instantaneous acceleration (pivot / continuation detector)
    double a_hat = 0.0;
    if(g_lastTickDt > 1e-6)
    {
        double a_k = (g_kxV - g_prevVelocity) / g_lastTickDt;
        a_hat = a_k / atr;
    }

    //--- Logistic sigmoid fusion
    double arg = InpVelocitySens  * v_hat
               + InpDisplacementW * D
               + InpAccelerationW * a_hat;

    arg = MathMax(-20.0, MathMin(20.0, arg));  // overflow guard for exp()

    double pLong = 1.0 / (1.0 + MathExp(-arg));

    //--- [NEURALGO_UPDATE] Soft Macro Bias: parametric counter-trend penalty
    if(InpMacroBiasEnable && g_macroInit)
    {
        double macroRef = GetMacroFilterValue();

        if(pLong >= 0.5 && g_kxP < macroRef)
        {
            pLong = pLong * InpMacroPenaltyGamma;
        }
        else if(pLong < 0.5 && g_kxP > macroRef)
        {
            double pShort = 1.0 - pLong;
            pShort = pShort * InpMacroPenaltyGamma;
            pLong  = 1.0 - pShort;
        }
    }

    return pLong;
}

//===================================================================
//  ExecuteBiasedEntry
//  Kalman-derived P(Long) determines trade direction.
//  Market order is always immediate — continuous execution preserved.
//
//  [NEURALGO_UPDATE] Hard Limit (USD): the ATR-based SL distance is
//  truncated (never widened) so realized monetary risk for InpLotSize
//  never exceeds InpMaxRiskUSD. TP is untouched by the cap.
//===================================================================
void ExecuteBiasedEntry()
{
    double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double mid    = (ask + bid) * 0.5;
    double atr    = g_bufATR[0];
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    if(atr <= 0.0) return;

    double pLong  = ComputeBiasProbability(mid, atr);
    double pShort = 1.0 - pLong;

    bool goLong;
    if(pLong >= InpBiasThreshold)
        goLong = true;
    else if(pShort >= InpBiasThreshold)
        goLong = false;
    else
    {
        double r = (double)MathRand() / 32767.0;
        goLong = (r < pLong);
    }

    double slDistance = atr * InpSLMultiplier;
    double tpDistance = atr * InpTPMultiplier;
    slDistance = ApplyHardRiskLimit(slDistance, InpLotSize);          // [NEURALGO_UPDATE]

    if(goLong)
    {
        double sl = NormalizeDouble(ask - slDistance, digits);
        double tp = NormalizeDouble(ask + tpDistance, digits);
        trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "KF8 Buy");
    }
    else
    {
        double sl = NormalizeDouble(bid + slDistance, digits);
        double tp = NormalizeDouble(bid - tpDistance, digits);
        trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "KF8 Sell");
    }
}

//===================================================================
//  CountPositions
//===================================================================
int CountPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == g_magic)
            count++;
    }
    return count;
}

//===================================================================
//  ManageExitsAndProtection  (preserved verbatim from v7)
//  Real-time ATR-adaptive breakeven + aggressive trailing stop.
//  [NEURALGO_UPDATE]: none — intentionally untouched. While a Damage
//  Control hedge is active, OnTick routes to ManageDamageControlState()
//  instead of here, so this never competes with the hedge unwind.
//===================================================================
void ManageExitsAndProtection()
{
    double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double atr    = g_bufATR[0];

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol ||
           PositionGetInteger(POSITION_MAGIC) != g_magic) continue;

        ulong  ticket = PositionGetTicket(i);
        double open   = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl     = PositionGetDouble(POSITION_SL);
        double tp     = PositionGetDouble(POSITION_TP);
        double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
            //--- 1. Smart Breakeven: activate after 0.5 * ATR in favour
            if(bid >= open + atr * 0.5)
            {
                double targetBE = open + InpMinPointsProfit * point;
                if(sl < targetBE)
                    trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
            }
            //--- 2. Aggressive Trailing Stop (only after BE is locked)
            if(sl >= open)
            {
                double newSL = NormalizeDouble(bid - InpTrailingPoints * point, digits);
                if(newSL > sl)
                    trade.PositionModify(ticket, newSL, tp);
            }
        }
        else // POSITION_TYPE_SELL
        {
            //--- 1. Smart Breakeven
            if(ask <= open - atr * 0.5)
            {
                double targetBE = open - InpMinPointsProfit * point;
                if(sl == 0.0 || sl > targetBE)
                    trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
            }
            //--- 2. Aggressive Trailing Stop (only after BE is locked)
            if(sl > 0.0 && sl <= open)
            {
                double newSL = NormalizeDouble(ask + InpTrailingPoints * point, digits);
                if(newSL < sl)
                    trade.PositionModify(ticket, newSL, tp);
            }
        }
    }
}

//===================================================================
//  [NEURALGO_UPDATE] RISK & DAMAGE CONTROL SUBSYSTEM
//===================================================================

//--- Monetary risk for a given SL distance, using tick VALUE and tick
//    SIZE (not SYMBOL_POINT) so metals/5-digit symbols where tick size
//    != point size are still computed correctly.
double CalcMoneyRisk(double lots, double slDistance)
{
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickSize <= 0.0) return 0.0;
    return (slDistance / tickSize) * tickValue * lots;
}

//--- Truncates (never widens) an SL distance so its monetary risk for
//    the given lot size does not exceed InpMaxRiskUSD.
double ApplyHardRiskLimit(double slDistance, double lots)
{
    double risk = CalcMoneyRisk(lots, slDistance);
    if(risk > InpMaxRiskUSD && risk > 0.0)
    {
        double scale = InpMaxRiskUSD / risk;
        slDistance *= scale;
    }
    return slDistance;
}

//--- Absolute equity backstop: combined floating P/L (primary + hedge)
//    breaching -InpMaxRiskUSD force-flattens everything immediately.
//    Returns true if it acted (caller should skip the rest of that tick).
bool CheckHardRiskLimit()
{
    double totalFloating = 0.0;
    bool   anyPosition    = false;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol) continue;
        long magic = PositionGetInteger(POSITION_MAGIC);
        if(magic != g_magic && magic != g_magicHedge) continue;

        totalFloating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        anyPosition = true;
    }

    if(anyPosition && totalFloating <= -MathAbs(InpMaxRiskUSD))
    {
        PrintFormat("[NEURALGO_UPDATE] HARD LIMIT alcanzado (%.2f <= -%.2f). Cierre forzado de todas las posiciones.",
                    totalFloating, MathAbs(InpMaxRiskUSD));
        FlattenAll();
        g_dcState = DC_STATE_NORMAL;
        if(InpCooldownMinutes > 0)
            g_cooldownUntil = TimeTradeServer() + InpCooldownMinutes * 60;
        return true;
    }
    return false;
}

//--- Closes every position (primary + hedge) belonging to this EA.
void FlattenAll()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol) continue;
        long magic = PositionGetInteger(POSITION_MAGIC);
        if(magic != g_magic && magic != g_magicHedge) continue;

        ulong ticket = PositionGetTicket(i);
        if(magic == g_magicHedge)
            tradeHedge.PositionClose(ticket);
        else
            trade.PositionClose(ticket);
    }
}

//--- Arms the hedge once the single primary position's floating loss
//    reaches g_dcTriggerPct * InpMaxRiskUSD.
void CheckDamageControl()
{
    if(!InpDamageControlEnable) return;
    if(g_dcState != DC_STATE_NORMAL) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != g_magic) continue;

        double floatingLoss = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        double triggerLevel = -MathAbs(InpMaxRiskUSD) * g_dcTriggerPct;

        if(floatingLoss <= triggerLevel)
        {
            ulong ticket = PositionGetTicket(i);
            DeployHedge(ticket);
        }
        return;   // only one primary position is ever open by design
    }
}

//--- Opens the contrary hedge sized off available capital, with its
//    own emergency SL (broker-side safety net independent of this
//    EA's own logic staying alive) capped by the same Hard Limit math.
void DeployHedge(ulong primaryTicket)
{
    if(!PositionSelectByTicket(primaryTicket)) return;
    ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
    {
        Print("[NEURALGO_UPDATE] Damage Control requiere una cuenta en modo Hedging. Cobertura abortada.");
        return;
    }

    double balance       = AccountInfoDouble(ACCOUNT_BALANCE);
    double freeMargin     = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    double usableCapital = MathMin(balance, freeMargin) * InpDamageControlBalanceUsagePct;

    double hedgeLots = CalcMaxLotsForCapital(usableCapital);
    if(hedgeLots <= 0.0)
    {
        Print("[NEURALGO_UPDATE] Damage Control: capital insuficiente para abrir la cobertura.");
        return;
    }

    double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double atr     = g_bufATR[0];
    int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    double safetyDist = atr * InpSLMultiplier;
    safetyDist = ApplyHardRiskLimit(safetyDist, hedgeLots);

    bool sent = false;
    if(ptype == POSITION_TYPE_BUY)
    {
        double sl = NormalizeDouble(bid + safetyDist, digits);
        sent = tradeHedge.Sell(hedgeLots, _Symbol, bid, sl, 0.0, "DC Hedge Sell");
    }
    else
    {
        double sl = NormalizeDouble(ask - safetyDist, digits);
        sent = tradeHedge.Buy(hedgeLots, _Symbol, ask, sl, 0.0, "DC Hedge Buy");
    }

    if(sent)
    {
        g_dcState = DC_STATE_HEDGED;
        PrintFormat("[NEURALGO_UPDATE] Damage Control activo. Hedge abierto: %.2f lotes.", hedgeLots);
    }
    else
    {
        PrintFormat("[NEURALGO_UPDATE] Damage Control: fallo al enviar la cobertura (error %d).", GetLastError());
    }
}

//--- While hedged, monitors COMBINED floating P/L (primary + hedge).
//    Unwinds (closes both) once combined result is back to >= 0.
void ManageDamageControlState()
{
    if(g_dcState != DC_STATE_HEDGED) return;

    double primaryPL = 0.0, hedgePL = 0.0;
    bool   hasPrimary = false, hasHedge = false;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol) continue;
        long   magic = PositionGetInteger(POSITION_MAGIC);
        double pl    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

        if(magic == g_magic)
        {
            primaryPL = pl;
            hasPrimary = true;
        }
        else if(magic == g_magicHedge)
        {
            hedgePL = pl;
            hasHedge = true;
        }
    }

    if(!hasPrimary && !hasHedge)
    {
        g_dcState = DC_STATE_NORMAL;   // both legs already closed externally
        return;
    }

    double combined = primaryPL + hedgePL;

    if(combined >= 0.0)
    {
        FlattenAll();
        g_dcState = DC_STATE_NORMAL;
        PrintFormat("[NEURALGO_UPDATE] Damage Control resuelto. P/L combinado en cierre: %.2f", combined);
    }
}

//--- Converts a capital budget into a broker-valid lot size using
//    OrderCalcMargin (pre-trade margin query — no guessed leverage math).
double CalcMaxLotsForCapital(double capital)
{
    if(capital <= 0.0) return 0.0;

    double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double marginPerLot = 0.0;
    if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, price, marginPerLot) || marginPerLot <= 0.0)
        return 0.0;

    double rawLots = capital / marginPerLot;
    return NormalizeVolume(rawLots);
}

//--- Rounds down to the symbol's volume step and clamps to [min,max].
//    Returns 0.0 if the rounded volume falls below the broker minimum.
double NormalizeVolume(double vol)
{
    double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if(stepVol <= 0.0) stepVol = minVol;
    if(stepVol <= 0.0) stepVol = 0.01;

    double steps      = MathFloor(vol / stepVol + 1e-8);
    double normalized = steps * stepVol;

    if(normalized < minVol) return 0.0;
    if(normalized > maxVol) normalized = maxVol;

    int stepDigits = 2;
    if(stepVol >= 0.09999) stepDigits = 1;
    if(stepVol >= 0.9999)  stepDigits = 0;

    return NormalizeDouble(normalized, stepDigits);
}

//===================================================================
//  [NEURALGO_UPDATE] SESSION FILTER & ANTI-REVENGE COOLDOWN HELPERS
//===================================================================

//--- Strictly TimeTradeServer()-based window. Only gates NEW entries;
//    open-position protection (breakeven/trailing/hard-limit/damage
//    control) always runs regardless of this filter.
bool IsWithinSession()
{
    MqlDateTime tstruct;
    TimeToStruct(TimeTradeServer(), tstruct);

    int nowMinutes   = tstruct.hour * 60 + tstruct.min;
    int startMinutes = InpStartHour * 60 + InpStartMinute;
    int endMinutes   = InpEndHour   * 60 + InpEndMinute;

    if(startMinutes == endMinutes)
        return true;   // degenerate zero-width window => treated as "always on"

    if(startMinutes < endMinutes)
        return (nowMinutes >= startMinutes && nowMinutes < endMinutes);
    else
        return (nowMinutes >= startMinutes || nowMinutes < endMinutes);  // wraps past midnight
}

bool InCooldown()
{
    return (g_cooldownUntil > 0 && TimeTradeServer() < g_cooldownUntil);
}

//===================================================================
//  [NEURALGO_UPDATE] UTILITY — broker-compatible order filling mode
//===================================================================
ENUM_ORDER_TYPE_FILLING GetBestFillingMode(string symbol)
{
    int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
    if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}
//+------------------------------------------------------------------+
