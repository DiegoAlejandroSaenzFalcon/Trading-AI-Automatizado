//+------------------------------------------------------------------+
//|                          Pure_Fractal_Pure_v7.mq5                |
//|              Micro-Inertia Velocity Bias Engine                  |
//|              Refactored from v6 — Experimental Prototype         |
//+------------------------------------------------------------------+
#property copyright "Quantitative Systems Architecture"
#property version   "7.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//===========================================
// INPUT PARAMETERS
//===========================================

//--- Core Risk Parameters (Unchanged from v6)
input double InpLotSize          = 0.01;  // Lot Size
input int    InpATRPeriod        = 14;    // ATR Period (Momentum Gauge)
input double InpTPMultiplier     = 0.8;   // TP Multiplier (Short & Fast)
input double InpSLMultiplier     = 3.0;   // Emergency Parachute (ATR x Multiplier)
input int    InpTrailingPoints   = 10;    // Active Trailing Stop Points
input int    InpMinPointsProfit  = 2;     // Min Points Above Entry for Breakeven

//--- Micro-Inertia Bias Engine Parameters
input int    InpFastEMATicks     = 5;     // Fast EMA span (tick-velocity anchor, N_fast)
input int    InpSlowEMATicks     = 50;    // Slow EMA span (macro-displacement anchor, N_slow)
input double InpVelocitySens     = 50.0; // k1: Micro-velocity sigmoid sensitivity
input double InpTrendWeight      = 3.0;   // k2: Macro-displacement sigmoid weight
input double InpBiasThreshold    = 0.55;  // Minimum P(Long/Short) to commit direction
                                          // Below threshold -> neutral random (0.5)

//===========================================
// GLOBAL VARIABLES
//===========================================

//--- ATR Handle & Buffer
int    g_hATR;
double g_bufATR[];
ulong  g_magic = 787;

//--- Micro-Inertia EMA State (in-memory, O(1) per tick)
double g_fastEMA    = 0.0;   // Fast EMA of mid-price (velocity anchor)
double g_slowEMA    = 0.0;   // Slow EMA of mid-price (trend anchor)
double g_alphaFast  = 0.0;   // EMA smoothing factor alpha_fast
double g_alphaSlow  = 0.0;   // EMA smoothing factor alpha_slow
bool   g_emaInit    = false;  // Warm-up flag: true after first valid mid-price

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(g_magic);

    //--- Initialize ATR indicator
    g_hATR = iATR(_Symbol, _Period, InpATRPeriod);
    if(g_hATR == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create ATR handle.");
        return INIT_FAILED;
    }
    ArraySetAsSeries(g_bufATR, true);

    //--- Pre-compute EMA alpha constants: alpha = 2 / (N + 1)
    g_alphaFast = 2.0 / (InpFastEMATicks + 1.0);
    g_alphaSlow = 2.0 / (InpSlowEMATicks + 1.0);

    //--- Reset EMA warm-up state
    g_fastEMA = 0.0;
    g_slowEMA = 0.0;
    g_emaInit = false;

    Print("Pure_Fractal v7 initialized. FastAlpha=", g_alphaFast,
          " SlowAlpha=", g_alphaSlow,
          " VelSens=", InpVelocitySens,
          " TrendWeight=", InpTrendWeight);

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
}

//+------------------------------------------------------------------+
//| OnTick — Main Loop                                               |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Fetch ATR (single buffer, already configured as series)
    if(CopyBuffer(g_hATR, 0, 0, 1, g_bufATR) < 1) return;

    //--- Update Micro-Inertia EMA states on every tick (zero cost)
    double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                + SymbolInfoDouble(_Symbol, SYMBOL_BID)) * 0.5;
    UpdateMicroInertiaEMAs(mid);

    int totalPositions = CountPositions();

    if(totalPositions == 0)
    {
        ExecuteBiasedEntry();
    }
    else
    {
        ManageExitsAndProtection();
    }
}

//+------------------------------------------------------------------+
//| UpdateMicroInertiaEMAs                                           |
//| Updates fast & slow EMA scalars in O(1). No indicator handles.   |
//+------------------------------------------------------------------+
void UpdateMicroInertiaEMAs(double mid)
{
    if(!g_emaInit)
    {
        //--- Cold-start: seed both EMAs with current mid-price
        g_fastEMA = mid;
        g_slowEMA = mid;
        g_emaInit = true;
        return;
    }

    //--- Standard EMA recurrence: EMA_t = alpha * price_t + (1-alpha) * EMA_{t-1}
    g_fastEMA = g_alphaFast * mid + (1.0 - g_alphaFast) * g_fastEMA;
    g_slowEMA = g_alphaSlow * mid + (1.0 - g_alphaSlow) * g_slowEMA;
}

//+------------------------------------------------------------------+
//| ComputeBiasProbability                                           |
//|                                                                   |
//| Returns P(Long) in [0,1] via sigmoid fusion of:                  |
//|   - v_hat : ATR-normalized tick velocity (fast EMA delta)        |
//|   - D     : ATR-normalized macro displacement (slow EMA delta)   |
//|                                                                   |
//| P(Long) = sigmoid(k1 * v_hat + k2 * D)                          |
//+------------------------------------------------------------------+
double ComputeBiasProbability(double mid, double atr)
{
    //--- Guard against degenerate ATR (e.g., at market open)
    if(atr <= 0.0) return 0.5;

    //--- Layer 1: Tick-velocity vector (signed, ATR-normalized)
    //    v_mu = mid - fastEMA_prev ≈ instantaneous momentum impulse
    //    v_hat = v_mu / ATR  (dimensionless, instrument-agnostic)
    double v_mu  = mid - g_fastEMA;
    double v_hat = v_mu / atr;

    //--- Layer 2: Macro-displacement ratio
    //    D = (mid - slowEMA) / ATR  (trend strength in ATR units)
    double D = (mid - g_slowEMA) / atr;

    //--- Layer 3: Logistic sigmoid fusion
    //    argument = k1 * v_hat + k2 * D
    //    sigmoid(x) = 1 / (1 + exp(-x))
    double argument = InpVelocitySens * v_hat + InpTrendWeight * D;

    //--- Clamp argument to prevent floating-point overflow in exp()
    argument = MathMax(-20.0, MathMin(20.0, argument));

    double pLong = 1.0 / (1.0 + MathExp(-argument));

    return pLong;
}

//+------------------------------------------------------------------+
//| ExecuteBiasedEntry                                               |
//|                                                                   |
//| Replaces the old % 2 parity gate with the Micro-Inertia sigmoid. |
//| Execution is ALWAYS immediate — only direction is biased.        |
//+------------------------------------------------------------------+
void ExecuteBiasedEntry()
{
    double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double mid    = (ask + bid) * 0.5;
    double atr    = g_bufATR[0];
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    //--- Compute directional bias probability
    double pLong = ComputeBiasProbability(mid, atr);

    //--- Direction decision logic:
    //    Strong bias  (pLong > threshold)           → deterministic Long
    //    Strong bias  (pLong < 1 - threshold)       → deterministic Short
    //    Neutral zone (near 0.5, below threshold)   → stochastic fallback
    bool goLong;
    double pShort = 1.0 - pLong;

    if(pLong >= InpBiasThreshold)
    {
        goLong = true;   // Momentum clearly upward — go Long
    }
    else if(pShort >= InpBiasThreshold)
    {
        goLong = false;  // Momentum clearly downward — go Short
    }
    else
    {
        //--- Neutral regime: stochastic draw weighted by computed probability.
        //    Even here the bias is non-uniform — it is P(Long) vs P(Short),
        //    not the flat 50/50 of v6. In true chop, they are nearly equal.
        double r = (double)MathRand() / 32767.0;
        goLong = (r < pLong);
    }

    //--- Execute market order immediately (continuous execution preserved)
    if(goLong)
    {
        double sl = NormalizeDouble(ask - (atr * InpSLMultiplier), digits);
        double tp = NormalizeDouble(ask + (atr * InpTPMultiplier), digits);
        trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "MIV7 Buy");
    }
    else
    {
        double sl = NormalizeDouble(bid + (atr * InpSLMultiplier), digits);
        double tp = NormalizeDouble(bid - (atr * InpTPMultiplier), digits);
        trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "MIV7 Sell");
    }
}

//+------------------------------------------------------------------+
//| CountPositions                                                   |
//+------------------------------------------------------------------+
int CountPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == g_magic)
        {
            count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| ManageExitsAndProtection — UNCHANGED from v6                     |
//| Real-time ATR-adaptive TP, Breakeven, Aggressive Trailing Stop   |
//+------------------------------------------------------------------+
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
            if(bid >= open + (atr * 0.5))
            {
                double targetBE = open + (InpMinPointsProfit * point);
                if(sl < targetBE)
                    trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
            }

            //--- 2. Aggressive Trailing Stop (only once BE is secured)
            if(sl >= open)
            {
                double newSL = NormalizeDouble(bid - (InpTrailingPoints * point), digits);
                if(newSL > sl)
                    trade.PositionModify(ticket, newSL, tp);
            }
        }
        else // POSITION_TYPE_SELL
        {
            //--- 1. Smart Breakeven
            if(ask <= open - (atr * 0.5))
            {
                double targetBE = open - (InpMinPointsProfit * point);
                if(sl == 0.0 || sl > targetBE)
                    trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
            }

            //--- 2. Aggressive Trailing Stop (only once BE is secured)
            if(sl > 0.0 && sl <= open)
            {
                double newSL = NormalizeDouble(ask + (InpTrailingPoints * point), digits);
                if(newSL < sl)
                    trade.PositionModify(ticket, newSL, tp);
            }
        }
    }
}