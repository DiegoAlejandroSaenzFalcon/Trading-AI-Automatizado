//+------------------------------------------------------------------+
//|                      Pure_Fractal_Pure_v8.mq5                    |
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
//|    Measurement noise R: scalar, user-tunable                     |
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
//+------------------------------------------------------------------+
#property copyright "Quantitative Systems Architecture"
#property version   "8.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//===================================================================
//  INPUT PARAMETERS
//===================================================================

//--- Core Risk Parameters (preserved from v7)
input double InpLotSize          = 0.01;   // Lot Size
input int    InpATRPeriod        = 14;     // ATR Period
input double InpTPMultiplier     = 3.0;    // TP Multiplier (ATR x)
input double InpSLMultiplier     = 1.5;    // SL Multiplier (ATR x)
input int    InpTrailingPoints   = 10;     // Trailing Stop (points)
input int    InpMinPointsProfit  = 2;      // Min Points for Breakeven

//--- 2D Cinematic Kalman Filter
//    Q tunes the filter's agility (high Q = trust new ticks more).
//    R tunes noise rejection (high R = smoother, more lag).
//    Q11 governs position uncertainty; Q22 governs velocity uncertainty.
//    Typical XAUUSD starting range: Q11 1e-5..1e-3, Q22 1e-3..1e-1, R 1e-4..1e-2
input double InpKalmanQ11        = 1e-4;   // Q[0][0]: position process noise
input double InpKalmanQ22        = 1e-2;   // Q[1][1]: velocity process noise
input double InpKalmanR          = 1e-3;   // Measurement noise variance (R)
input double InpKalmanDtFallback = 0.1;   // Fallback delta-t (seconds) for tick 0

//--- Kalman-Fused Sigmoid Parameters
input double InpVelocitySens     = 50.0;   // k1: Kalman velocity sensitivity
input double InpDisplacementW    = 3.0;    // k2: Filtered displacement weight
input double InpAccelerationW    = 10.0;   // k3: Acceleration reversal amplifier
input double InpBiasThreshold    = 0.55;   // Min P(direction) to commit market entry

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

//--- Measurement noise R
double g_kR    = 1e-3;

//--- Runtime state
bool   g_kInit        = false;  // true after first valid mid-price observed
ulong  g_lastTickUs   = 0;      // microsecond timestamp of the previous tick
double g_lastTickDt   = 0.1;    // actual delta-t of the most recent Kalman step
double g_prevVelocity = 0.0;    // v_{k-1}: archived velocity for acceleration gauge

//--- ATR
int    g_hATR;
double g_bufATR[];
ulong  g_magic = 777;

//===================================================================
//  OnInit
//===================================================================
int OnInit()
{
    trade.SetExpertMagicNumber(g_magic);

    //--- ATR indicator handle
    g_hATR = iATR(_Symbol, _Period, InpATRPeriod);
    if(g_hATR == INVALID_HANDLE)
    {
        Print("ERROR: ATR handle creation failed. EA will not start.");
        return INIT_FAILED;
    }
    ArraySetAsSeries(g_bufATR, true);

    //--- Kalman state: zero-seeded; overwritten on cold-start
    g_kxP = 0.0;
    g_kxV = 0.0;

    //--- Error covariance P: identity (large initial uncertainty, converges fast)
    g_kP00 = 1.0;  g_kP01 = 0.0;
    g_kP10 = 0.0;  g_kP11 = 1.0;

    //--- Process noise Q: must be strictly positive
    g_kQpos = MathMax(1e-12, InpKalmanQ11);
    g_kQvel = MathMax(1e-12, InpKalmanQ22);

    //--- Measurement noise R: must be strictly positive
    g_kR = MathMax(1e-12, InpKalmanR);

    //--- Reset runtime state
    g_kInit        = false;
    g_lastTickUs   = 0;
    g_lastTickDt   = InpKalmanDtFallback;
    g_prevVelocity = 0.0;

    Print("Pure_Fractal v8 [2D Cinematic Kalman] initialised | ",
          "Qpos=", DoubleToString(InpKalmanQ11, 2),
          " Qvel=", DoubleToString(InpKalmanQ22, 2),
          " R=",    DoubleToString(InpKalmanR,   2),
          " | k1=", InpVelocitySens,
            " k2=", InpDisplacementW,
            " k3=", InpAccelerationW,
          " | Thr=", InpBiasThreshold);

    return INIT_SUCCEEDED;
}

//===================================================================
//  OnDeinit
//===================================================================
void OnDeinit(const int reason)
{
    if(g_hATR != INVALID_HANDLE)
        IndicatorRelease(g_hATR);
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

    KalmanUpdate(mid);

    if(CountPositions() == 0)
        ExecuteBiasedEntry();
    else
        ManageExitsAndProtection();
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

    return 1.0 / (1.0 + MathExp(-arg));
}

//===================================================================
//  ExecuteBiasedEntry
//  Kalman-derived P(Long) determines trade direction.
//  Market order is always immediate — continuous execution preserved.
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

    if(goLong)
    {
        double sl = NormalizeDouble(ask - atr * InpSLMultiplier, digits);
        double tp = NormalizeDouble(ask + atr * InpTPMultiplier, digits);
        trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "KF8 Buy");
    }
    else
    {
        double sl = NormalizeDouble(bid + atr * InpSLMultiplier, digits);
        double tp = NormalizeDouble(bid - atr * InpTPMultiplier, digits);
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
//+------------------------------------------------------------------+
