//+------------------------------------------------------------------+
//|                      Pure_Fractal_Pure_v11.mq5                   |
//|   v10 Capital-Protected Engine + Production Hardening Layer       |
//|                                                                   |
//|  WHY THIS VERSION EXISTS                                          |
//|  v9 fixed the SIGNAL problem (reversal whipsaw). v10 fixed the    |
//|  CAPITAL problem (no risk-based sizing, no cross-symbol guard).   |
//|  v11 fixes the BROKER/EXECUTION problem: the class of errors and  |
//|  silent failure modes that show up once you actually run this on  |
//|  4 different real symbols (BTCUSD / XAUUSD / EURUSD / GBPUSD)     |
//|  with 4 different point sizes, stop-level rules and filling       |
//|  modes, instead of one symbol you hand-tuned everything around.   |
//|                                                                   |
//|  NEW IN v11:                                                      |
//|                                                                   |
//|   1) BROKER STOP-LEVEL / FREEZE-LEVEL SAFE CLAMPING                |
//|      ATR-based SL/TP distances are now clamped to never be        |
//|      smaller than SYMBOL_TRADE_STOPS_LEVEL / SYMBOL_TRADE_FREEZE_  |
//|      LEVEL (+ a small buffer). This is the documented fix for the |
//|      "invalid stops" errors this project has hit before when a    |
//|      distance calibrated for one symbol's point size is sent to a |
//|      different symbol. Applied on BOTH new entries and on every   |
//|      trailing/breakeven modification.                             |
//|                                                                   |
//|   2) ORDER EXECUTION HARDENING                                    |
//|      - Explicit slippage/deviation control (InpSlippagePoints).   |
//|      - Auto-detects and sets the symbol's supported order filling |
//|        mode (FOK / IOC / RETURN) instead of assuming one — avoids |
//|        "Unsupported filling mode" rejections that vary by broker. |
//|      - Every Buy()/Sell() return value is checked; failures are   |
//|        logged with the broker's retcode + description instead of  |
//|        failing silently.                                          |
//|                                                                   |
//|   3) PRE-TRADE ENVIRONMENT CHECKS                                  |
//|      Verifies AutoTrading is actually enabled (terminal + MQL +    |
//|      account + symbol trade mode) before attempting an entry,      |
//|      instead of repeatedly trying and failing.                     |
//|                                                                   |
//|   4) TRADING HOURS FILTER (optional)                               |
//|      Restrict new entries to a server-time window. Useful for      |
//|      avoiding the thinnest-liquidity hours on a given symbol.      |
//|                                                                   |
//|   5) EMERGENCY PER-TRADE EQUITY STOP                               |
//|      A hard backstop independent of the static SL: if a single     |
//|      position's OWN floating loss reaches InpEmergencyLossPercent  |
//|      PerTrade of account equity, it is force-closed immediately.   |
//|      This exists specifically for gap/slippage scenarios (e.g.     |
//|      BTCUSD weekend gaps) where price can jump straight past a     |
//|      resting SL and fill far worse than intended.                  |
//|                                                                   |
//|   6) ABSOLUTE SPREAD CAP                                           |
//|      The v10 ATR-relative spread filter is preserved, plus a flat  |
//|      points-based ceiling as a sanity backstop for broker glitches |
//|      or feed issues that an ATR-relative filter alone might miss.  |
//|                                                                   |
//|   7) RISK-SIZING SAFETY: SKIP INSTEAD OF OVER-RISK                 |
//|      If the risk-based lot calculation comes out BELOW the         |
//|      broker's minimum volume, v10 silently forced the lot up to    |
//|      the minimum (over-risking). v11 skips the trade instead       |
//|      (configurable) so the risk budget is never silently violated. |
//|                                                                   |
//|  EVERYTHING FROM v9/v10 IS PRESERVED UNCHANGED: fast Kalman filter,|
//|  macro Kalman filter, entry-confirmation streak, reversal-         |
//|  protective exit, post-exit cooldown, risk-based position sizing,  |
//|  the cross-symbol daily capital guard, and ATR-adaptive trailing.  |
//|                                                                   |
//|  WHAT v11 DELIBERATELY DOES NOT DO:                                |
//|  It does not change the Kalman math, the sigmoid weights, or the   |
//|  TP/SL multipliers. Those remain yours to calibrate per symbol in  |
//|  the Strategy Tester — this release is about making sure the EA    |
//|  behaves predictably and safely once your signal IS good, on       |
//|  whatever broker/symbol combination you point it at.               |
//+------------------------------------------------------------------+
#property copyright "Quantitative Systems Architecture"
#property version   "11.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//===================================================================
//  INPUT PARAMETERS
//===================================================================

input group "=== Core Risk Parameters ==="
input double InpLotSize          = 0.01;   // Fixed Lot Size (used only when InpUseRiskBasedSizing=false)
input int    InpATRPeriod        = 14;     // ATR Period
input double InpTPMultiplier     = 0.8;    // TP Multiplier (ATR x)
input double InpSLMultiplier     = 3.0;    // SL Multiplier (ATR x)

input group "=== Position Sizing — Risk-Based ==="
input bool   InpUseRiskBasedSizing  = true;  // Compute lot size from % equity risk instead of fixed InpLotSize
input double InpRiskPercentPerTrade = 0.5;   // % of account EQUITY risked per trade. Lower this if running several symbols at once.
input double InpMinLotSize          = 0.01;  // Hard floor on computed lot size
input double InpMaxLotSize          = 1.0;   // Hard ceiling on computed lot size, regardless of risk math
input bool   InpSkipIfRiskTooSmall  = true;  // If the risk-based lot is below broker minimum, SKIP the trade instead of over-risking

input group "=== Order Execution & Broker Safety (NEW v11) ==="
input int    InpSlippagePoints     = 30;    // Max acceptable slippage/deviation, in points (raise this for fast-moving symbols like BTCUSD)

input group "=== Trading Hours Filter (NEW v11) ==="
input bool   InpUseTradingHours    = false; // Restrict new entries to a server-time trading window
input int    InpTradingHourStart   = 0;     // Server hour (0-23) the trading window opens
input int    InpTradingHourEnd     = 23;    // Server hour (0-23) the trading window closes (inclusive). Start>End wraps past midnight.

input group "=== Emergency Equity Stop (NEW v11) ==="
input bool   InpUseEmergencyEquityStop       = true; // Hard backstop beyond the static SL — protects against gap/slippage fills
input double InpEmergencyLossPercentPerTrade = 2.0;  // Force-close a position if its OWN floating loss reaches this % of equity. Keep this ABOVE your normal expected per-trade loss.

input group "=== Fast (Micro) Kalman Filter — Entry/Exit Timing ==="
//    Q tunes the filter's agility (high Q = trust new ticks more).
//    R tunes noise rejection (high R = smoother, more lag).
//    These are PER-SYMBOL. Do not reuse one set across BTCUSD/XAUUSD/EURUSD/GBPUSD blindly.
input double InpKalmanQ11        = 1e-4;   // Q[0][0]: position process noise
input double InpKalmanQ22        = 1e-2;   // Q[1][1]: velocity process noise
input double InpKalmanR          = 1e-3;   // Measurement noise variance (R)
input double InpKalmanDtFallback = 0.1;    // Fallback delta-t (seconds) for tick 0

input group "=== Kalman-Fused Sigmoid (Direction Probability) ==="
input double InpVelocitySens     = 50.0;   // k1: Kalman velocity sensitivity
input double InpDisplacementW    = 3.0;    // k2: Filtered displacement weight
input double InpAccelerationW    = 10.0;   // k3: Acceleration reversal amplifier
input double InpBiasThreshold    = 0.55;   // Min P(direction) to commit a market entry
input bool   InpAllowAmbiguousEntry = false; // Legacy coin-flip entry when neither side reaches threshold (NOT recommended)

input group "=== Entry Confirmation — Anti-Whipsaw Filter ==="
input bool   InpUseEntryConfirm    = true; // Require N consecutive agreeing ticks before opening a trade
input int    InpEntryConfirmTicks  = 5;    // Consecutive ticks required (tick-space, not bar-space)

input group "=== Macro (Slow) Kalman Filter — Regime Confirmation ==="
input bool   InpUseMacroFilter     = true; // Require the slow filter to agree with the fast filter's direction
input double InpMacroQ11           = 1e-6; // Position process noise — keep much smaller than InpKalmanQ11
input double InpMacroQ22           = 1e-4; // Velocity process noise — keep much smaller than InpKalmanQ22
input double InpMacroR             = 1e-3; // Measurement noise variance

input group "=== Reversal-Protective Exit — Core Fix ==="
input bool   InpUseReversalExit       = true; // Close the position early when the regime confirms a reversal
input double InpReversalBiasThreshold = 0.60; // P(opposite direction) required to flag a reversal tick (>= InpBiasThreshold recommended)
input int    InpReversalConfirmTicks  = 8;    // Consecutive reversal-flagged ticks required before forcing the exit
input bool   InpReversalRequireMacro  = true; // Macro (slow) filter must also agree with the reversal direction

input group "=== Post-Exit Cooldown — Anti-Whipsaw Re-Entry Filter ==="
input bool   InpUseCooldown        = true; // Block new entries for a period after ANY exit (SL/TP/trailing/reversal/emergency)
input int    InpCooldownSeconds    = 30;   // Cooldown duration in seconds

input group "=== Spread Filter ==="
input bool   InpUseSpreadFilter     = true;  // Skip entries when live spread is wide relative to current volatility (ATR)
input double InpMaxSpreadATRFactor  = 0.15;  // Max acceptable spread = ATR * this factor
input bool   InpUseAbsoluteSpreadCap = true; // Flat backstop ceiling regardless of ATR (catches broker/feed glitches)
input double InpMaxSpreadPoints      = 500;  // Max acceptable spread, in points — needs per-symbol calibration

input group "=== Cross-Symbol Capital Guard ==="
//    Shared across EVERY chart/symbol running this EA in the SAME terminal via Global Variables.
//    All instances MUST use the identical InpGlobalVarPrefix to coordinate correctly.
input bool   InpUseGlobalCapitalGuard = true;    // Halt NEW entries on every symbol once the shared daily loss limit is hit
input double InpMaxDailyLossPercent   = 5.0;     // Daily loss limit, as % of day-start account equity
input string InpGlobalVarPrefix       = "PF11_"; // Must be IDENTICAL across all chart instances sharing this guard

input group "=== Position Management: Breakeven & Trailing ==="
input int    InpTrailingPoints     = 10;   // Legacy: trailing distance in raw points (used when InpUseATRTrailing=false)
input int    InpMinPointsProfit    = 2;    // Points locked in once breakeven triggers
input bool   InpUseATRTrailing     = false; // true = trailing/breakeven distances scale with ATR (recommended for multi-asset use)
input double InpTrailingATRFactor  = 0.10; // Trailing distance = ATR * this factor (used when InpUseATRTrailing=true)
input double InpBreakevenATRFactor = 0.50; // Breakeven trigger = ATR * this factor

//===================================================================
//  GLOBAL STATE — FAST (MICRO) KALMAN ENGINE
//===================================================================
double g_kxP = 0.0;
double g_kxV = 0.0;
double g_kP00 = 1.0,  g_kP01 = 0.0;
double g_kP10 = 0.0,  g_kP11 = 1.0;
double g_kQpos = 1e-4;
double g_kQvel = 1e-2;
double g_kR    = 1e-3;
bool   g_kInit        = false;
ulong  g_lastTickUs   = 0;
double g_lastTickDt   = 0.1;
double g_prevVelocity = 0.0;

//===================================================================
//  GLOBAL STATE — MACRO (SLOW) KALMAN ENGINE
//===================================================================
double g_mxP = 0.0;
double g_mxV = 0.0;
double g_mP00 = 1.0,  g_mP01 = 0.0;
double g_mP10 = 0.0,  g_mP11 = 1.0;
double g_mQpos = 1e-6;
double g_mQvel = 1e-4;
double g_mR    = 1e-3;
bool   g_mInit = false;

//===================================================================
//  GLOBAL STATE — ENTRY CONFIRMATION / REVERSAL / COOLDOWN
//===================================================================
int      g_entryStreakDir      = 0;
int      g_entryStreakLen      = 0;
int      g_reversalStreakLen   = 0;
datetime g_lastCloseTime       = 0;
bool     g_hadPositionLastTick = false;

//===================================================================
//  ATR / MAGIC
//===================================================================
int    g_hATR;
double g_bufATR[];
ulong  g_magic = 891;   // bumped again for v11 so it never adopts a stray v8/v9/v10 position

//===================================================================
//  OnInit
//===================================================================
int OnInit()
{
    trade.SetExpertMagicNumber(g_magic);
    trade.SetDeviationInPoints((ulong)MathMax(0, InpSlippagePoints));
    ConfigureTradeFillingMode();

    g_hATR = iATR(_Symbol, _Period, InpATRPeriod);
    if(g_hATR == INVALID_HANDLE)
    {
        Print("ERROR: ATR handle creation failed. EA will not start.");
        return INIT_FAILED;
    }
    ArraySetAsSeries(g_bufATR, true);

    //--- Fast Kalman: zero-seeded; overwritten on cold-start
    g_kxP = 0.0;  g_kxV = 0.0;
    g_kP00 = 1.0; g_kP01 = 0.0;
    g_kP10 = 0.0; g_kP11 = 1.0;
    g_kQpos = MathMax(1e-12, InpKalmanQ11);
    g_kQvel = MathMax(1e-12, InpKalmanQ22);
    g_kR    = MathMax(1e-12, InpKalmanR);
    g_kInit = false;
    g_lastTickUs   = 0;
    g_lastTickDt   = InpKalmanDtFallback;
    g_prevVelocity = 0.0;

    //--- Macro Kalman: zero-seeded; overwritten on cold-start
    g_mxP = 0.0;  g_mxV = 0.0;
    g_mP00 = 1.0; g_mP01 = 0.0;
    g_mP10 = 0.0; g_mP11 = 1.0;
    g_mQpos = MathMax(1e-12, InpMacroQ11);
    g_mQvel = MathMax(1e-12, InpMacroQ22);
    g_mR    = MathMax(1e-12, InpMacroR);
    g_mInit = false;

    //--- Confirmation / reversal / cooldown state
    g_entryStreakDir      = 0;
    g_entryStreakLen      = 0;
    g_reversalStreakLen   = 0;
    g_lastCloseTime       = 0;
    g_hadPositionLastTick = false;

    //--- Initialise / sync the shared daily capital guard immediately on attach
    if(InpUseGlobalCapitalGuard)
        UpdateDailyEquityAnchor();

    Print("Pure_Fractal v11 [Kalman + Regime Confirmation + Capital Guard + Execution Hardening] initialised on ", _Symbol);
    Print("  Sizing | ", (InpUseRiskBasedSizing ? "RISK-BASED" : "FIXED LOT"),
          " Risk%=", DoubleToString(InpRiskPercentPerTrade, 2),
          " Min=", DoubleToString(InpMinLotSize, 2), " Max=", DoubleToString(InpMaxLotSize, 2),
          " SkipIfTooSmall=", (InpSkipIfRiskTooSmall ? "YES" : "NO"));
    Print("  Execution | Slippage=", InpSlippagePoints, "pts | MinStopDist=", DoubleToString(GetMinStopDistance(), 6));
    Print("  Trading Hours | ", (InpUseTradingHours ? "RESTRICTED " + (string)InpTradingHourStart + "-" + (string)InpTradingHourEnd : "24h"));
    Print("  Emergency Equity Stop | ", (InpUseEmergencyEquityStop ? "ENABLED" : "DISABLED"),
          " Limit%=", DoubleToString(InpEmergencyLossPercentPerTrade, 2));
    Print("  Fast Kalman  | Qpos=", DoubleToString(InpKalmanQ11, 6),
          " Qvel=", DoubleToString(InpKalmanQ22, 6), " R=", DoubleToString(InpKalmanR, 6));
    Print("  Macro Kalman | ", (InpUseMacroFilter ? "ENABLED" : "DISABLED"));
    Print("  Entry Confirm | ", (InpUseEntryConfirm ? "ENABLED" : "DISABLED"), " Ticks=", InpEntryConfirmTicks);
    Print("  Reversal Exit | ", (InpUseReversalExit ? "ENABLED" : "DISABLED"),
          " Threshold=", DoubleToString(InpReversalBiasThreshold, 2), " Ticks=", InpReversalConfirmTicks);
    Print("  Cooldown | ", (InpUseCooldown ? "ENABLED" : "DISABLED"), " Seconds=", InpCooldownSeconds);
    Print("  Spread Filter | ATR-relative=", (InpUseSpreadFilter ? "ON" : "OFF"),
          " AbsoluteCap=", (InpUseAbsoluteSpreadCap ? ((string)InpMaxSpreadPoints + "pts") : "OFF"));
    Print("  Capital Guard | ", (InpUseGlobalCapitalGuard ? "ENABLED" : "DISABLED"),
          " DailyLossLimit=", DoubleToString(InpMaxDailyLossPercent, 2), "% | Prefix=", InpGlobalVarPrefix,
          " <-- MUST MATCH on every symbol sharing this guard");

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
    double atr = g_bufATR[0];

    double dt = ComputeDeltaT();

    KalmanUpdate(mid, dt);

    if(InpUseMacroFilter)
        MacroKalmanUpdate(mid, dt);

    double pLong = (atr > 0.0 && g_kInit) ? ComputeBiasProbability(mid, atr) : 0.5;
    UpdateEntryConfirmationStreak(CurrentDirectionalSign(pLong));

    int posCountBefore = CountPositions();

    if(posCountBefore > 0)
    {
        //--- Protective layers run in order of urgency: catastrophic -> regime -> routine management
        CheckEmergencyEquityStop();
        if(CountPositions() > 0)
            CheckReversalProtectiveExit(pLong);
        if(CountPositions() > 0)
            ManageExitsAndProtection();
    }
    else
    {
        g_reversalStreakLen = 0;
        if(IsCooldownElapsed() && IsEntryConfirmed())
            ExecuteBiasedEntry();
    }

    int posCountAfter = CountPositions();
    if(g_hadPositionLastTick && posCountAfter == 0)
        g_lastCloseTime = TimeCurrent();
    g_hadPositionLastTick = (posCountAfter > 0);
}

//===================================================================
//  ComputeDeltaT
//===================================================================
double ComputeDeltaT()
{
    ulong  nowUs = GetMicrosecondCount();
    double dt;
    if(!g_kInit || g_lastTickUs == 0)
    {
        dt = InpKalmanDtFallback;
    }
    else
    {
        double rawDt = (double)(nowUs - g_lastTickUs) * 1e-6;
        dt = MathMax(1e-6, MathMin(60.0, rawDt));
    }
    g_lastTickUs = nowUs;
    g_lastTickDt = dt;
    return dt;
}

//===================================================================
//  KalmanUpdate  —  Fast (micro) filter
//===================================================================
void KalmanUpdate(double mid, double dt)
{
    if(!g_kInit)
    {
        g_kxP          = mid;
        g_kxV          = 0.0;
        g_prevVelocity = 0.0;
        g_kInit        = true;
        return;
    }

    g_prevVelocity = g_kxV;

    double xp0 = g_kxP + dt * g_kxV;
    double xp1 = g_kxV;

    double t00 = g_kP00 + dt * g_kP10;
    double t01 = g_kP01 + dt * g_kP11;
    double t10 = g_kP10;
    double t11 = g_kP11;

    double pp00 = t00 + t01 * dt + g_kQpos;
    double pp01 = t01;
    double pp10 = t10 + t11 * dt;
    double pp11 = t11 + g_kQvel;

    double y = mid - xp0;
    double S = pp00 + g_kR;

    if(S < 1e-12)
    {
        g_kxP  = xp0;   g_kxV  = xp1;
        g_kP00 = pp00 + g_kQpos;  g_kP01 = pp01;
        g_kP10 = pp10;             g_kP11 = pp11 + g_kQvel;
        return;
    }

    double K0 = pp00 / S;
    double K1 = pp10 / S;

    g_kxP = xp0 + K0 * y;
    g_kxV = xp1 + K1 * y;

    g_kP00 = MathMax((1.0 - K0) * pp00, 1e-12);
    g_kP01 =         (1.0 - K0) * pp01;
    g_kP10 = pp10 - K1 * pp00;
    g_kP11 = MathMax(pp11 - K1 * pp01, 1e-12);
}

//===================================================================
//  MacroKalmanUpdate  —  Slow (macro) filter
//===================================================================
void MacroKalmanUpdate(double mid, double dt)
{
    if(!g_mInit)
    {
        g_mxP   = mid;
        g_mxV   = 0.0;
        g_mInit = true;
        return;
    }

    double xp0 = g_mxP + dt * g_mxV;
    double xp1 = g_mxV;

    double t00 = g_mP00 + dt * g_mP10;
    double t01 = g_mP01 + dt * g_mP11;
    double t10 = g_mP10;
    double t11 = g_mP11;

    double pp00 = t00 + t01 * dt + g_mQpos;
    double pp01 = t01;
    double pp10 = t10 + t11 * dt;
    double pp11 = t11 + g_mQvel;

    double y = mid - xp0;
    double S = pp00 + g_mR;

    if(S < 1e-12)
    {
        g_mxP  = xp0;   g_mxV  = xp1;
        g_mP00 = pp00 + g_mQpos;  g_mP01 = pp01;
        g_mP10 = pp10;             g_mP11 = pp11 + g_mQvel;
        return;
    }

    double K0 = pp00 / S;
    double K1 = pp10 / S;

    g_mxP = xp0 + K0 * y;
    g_mxV = xp1 + K1 * y;

    g_mP00 = MathMax((1.0 - K0) * pp00, 1e-12);
    g_mP01 =         (1.0 - K0) * pp01;
    g_mP10 = pp10 - K1 * pp00;
    g_mP11 = MathMax(pp11 - K1 * pp01, 1e-12);
}

//===================================================================
//  ComputeBiasProbability
//===================================================================
double ComputeBiasProbability(double mid, double atr)
{
    if(atr <= 0.0 || !g_kInit) return 0.5;

    double v_hat = g_kxV / atr;
    double D     = (mid - g_kxP) / atr;

    double a_hat = 0.0;
    if(g_lastTickDt > 1e-6)
    {
        double a_k = (g_kxV - g_prevVelocity) / g_lastTickDt;
        a_hat = a_k / atr;
    }

    double arg = InpVelocitySens  * v_hat
               + InpDisplacementW * D
               + InpAccelerationW * a_hat;

    arg = MathMax(-20.0, MathMin(20.0, arg));

    return 1.0 / (1.0 + MathExp(-arg));
}

//===================================================================
//  CurrentDirectionalSign
//===================================================================
int CurrentDirectionalSign(double pLong)
{
    if(pLong >= InpBiasThreshold)         return  1;
    if(pLong <= (1.0 - InpBiasThreshold)) return -1;
    return 0;
}

//===================================================================
//  UpdateEntryConfirmationStreak
//===================================================================
void UpdateEntryConfirmationStreak(int dirSign)
{
    if(dirSign == 0)
    {
        g_entryStreakDir = 0;
        g_entryStreakLen = 0;
        return;
    }

    if(dirSign == g_entryStreakDir)
        g_entryStreakLen++;
    else
    {
        g_entryStreakDir = dirSign;
        g_entryStreakLen = 1;
    }
}

//===================================================================
//  IsEntryConfirmed
//===================================================================
bool IsEntryConfirmed()
{
    if(!InpUseEntryConfirm) return true;
    return (g_entryStreakLen >= InpEntryConfirmTicks);
}

//===================================================================
//  MacroAgrees
//===================================================================
bool MacroAgrees(int dirSign)
{
    if(!InpUseMacroFilter) return true;
    if(dirSign > 0) return (g_mxV >= 0.0);
    if(dirSign < 0) return (g_mxV <= 0.0);
    return false;
}

//===================================================================
//  IsCooldownElapsed
//===================================================================
bool IsCooldownElapsed()
{
    if(!InpUseCooldown) return true;
    if(g_lastCloseTime == 0) return true;
    return ((TimeCurrent() - g_lastCloseTime) >= InpCooldownSeconds);
}

//===================================================================
//  IsWithinTradingHours  [NEW v11]
//===================================================================
bool IsWithinTradingHours()
{
    if(!InpUseTradingHours) return true;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;

    if(InpTradingHourStart <= InpTradingHourEnd)
        return (hour >= InpTradingHourStart && hour <= InpTradingHourEnd);

    return (hour >= InpTradingHourStart || hour <= InpTradingHourEnd); // window wraps past midnight
}

//===================================================================
//  IsTradingEnvironmentReady  [NEW v11]
//  Verifies AutoTrading is actually enabled end-to-end before the EA
//  attempts to send an order, instead of failing repeatedly.
//===================================================================
bool IsTradingEnvironmentReady()
{
    if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED))            return false;
    if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))    return false;
    if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))     return false;

    long tradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
    if(tradeMode == SYMBOL_TRADE_MODE_DISABLED) return false;

    return true;
}

//===================================================================
//  ConfigureTradeFillingMode  [NEW v11]
//  Auto-detects which order filling mode this symbol/broker actually
//  supports and configures CTrade accordingly, instead of assuming
//  one mode works everywhere.
//===================================================================
void ConfigureTradeFillingMode()
{
    long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

    if((filling & SYMBOL_FILLING_FOK) != 0)
        trade.SetTypeFilling(ORDER_FILLING_FOK);
    else if((filling & SYMBOL_FILLING_IOC) != 0)
        trade.SetTypeFilling(ORDER_FILLING_IOC);
    else
        trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//===================================================================
//  GetMinStopDistance  [NEW v11]
//  Minimum allowed distance (in price units) between the current
//  price and SL/TP, per broker/symbol rules, plus a small safety
//  buffer. Fixes "invalid stops" errors when an ATR-based distance
//  comes out smaller than the broker allows on a given symbol.
//===================================================================
double GetMinStopDistance()
{
    long stopsLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
    long maxLevel    = MathMax(stopsLevel, freezeLevel);

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    return ((double)maxLevel * point) + (5.0 * point);
}

//===================================================================
//  IsSpreadAcceptable
//  ATR-relative filter (v10) + flat points-based backstop (NEW v11).
//===================================================================
bool IsSpreadAcceptable(double atr)
{
    double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double spread = ask - bid;
    double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    if(InpUseAbsoluteSpreadCap && point > 0.0)
    {
        if((spread / point) > InpMaxSpreadPoints) return false;
    }

    if(!InpUseSpreadFilter) return true;
    if(atr <= 0.0)          return true;

    return (spread <= atr * InpMaxSpreadATRFactor);
}

//===================================================================
//  Global Variable names for the shared cross-symbol capital guard
//===================================================================
string GVDayEquity()  { return InpGlobalVarPrefix + "DayStartEquity"; }
string GVDayStamp()   { return InpGlobalVarPrefix + "DayStamp"; }
string GVHaltedFlag() { return InpGlobalVarPrefix + "Halted"; }

//===================================================================
//  UpdateDailyEquityAnchor
//===================================================================
void UpdateDailyEquityAnchor()
{
    double today = MathFloor((double)TimeCurrent() / 86400.0);

    if(!GlobalVariableCheck(GVDayStamp()) || GlobalVariableGet(GVDayStamp()) != today)
    {
        GlobalVariableSet(GVDayStamp(), today);
        GlobalVariableSet(GVDayEquity(), AccountInfoDouble(ACCOUNT_EQUITY));
        GlobalVariableSet(GVHaltedFlag(), 0.0);
    }
}

//===================================================================
//  IsCapitalGuardTripped
//===================================================================
bool IsCapitalGuardTripped()
{
    if(!InpUseGlobalCapitalGuard) return false;

    UpdateDailyEquityAnchor();

    if(GlobalVariableCheck(GVHaltedFlag()) && GlobalVariableGet(GVHaltedFlag()) > 0.5)
        return true;

    double dayStartEquity = GlobalVariableGet(GVDayEquity());
    if(dayStartEquity <= 0.0) return false;

    double equityNow    = AccountInfoDouble(ACCOUNT_EQUITY);
    double lossPercent  = (dayStartEquity - equityNow) / dayStartEquity * 100.0;

    if(lossPercent >= InpMaxDailyLossPercent)
    {
        GlobalVariableSet(GVHaltedFlag(), 1.0);
        Print("Pure_Fractal v11: DAILY CAPITAL GUARD TRIPPED on ", _Symbol,
              " | Loss=", DoubleToString(lossPercent, 2), "% >= Limit=",
              DoubleToString(InpMaxDailyLossPercent, 2), "% | ALL symbols halted until next trading day.");
        return true;
    }

    return false;
}

//===================================================================
//  ComputeRiskBasedLotSize
//  Returns a positive lot size, InpLotSize (fixed mode), or -1.0 as a
//  sentinel meaning "cannot achieve the requested risk% — skip" when
//  InpSkipIfRiskTooSmall is enabled.
//===================================================================
double ComputeRiskBasedLotSize(double slDistancePrice)
{
    if(!InpUseRiskBasedSizing) return InpLotSize;
    if(slDistancePrice <= 0.0) return InpLotSize;

    double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = equity * (InpRiskPercentPerTrade / 100.0);

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(tickSize <= 0.0 || tickValue <= 0.0) return InpLotSize;

    double lossPerLot = (slDistancePrice / tickSize) * tickValue;
    if(lossPerLot <= 0.0) return InpLotSize;

    double rawLots = riskAmount / lossPerLot;

    double brokerMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    if(brokerMin <= 0.0) brokerMin = InpMinLotSize;

    if(InpSkipIfRiskTooSmall && rawLots < brokerMin * 0.999)
        return -1.0; // cannot hit the requested risk% on this account/instrument right now

    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if(lotStep > 0.0)
        rawLots = MathFloor(rawLots / lotStep) * lotStep;

    rawLots = MathMax(InpMinLotSize, MathMin(InpMaxLotSize, rawLots));

    double brokerMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(brokerMin > 0.0) rawLots = MathMax(brokerMin, rawLots);
    if(brokerMax > 0.0) rawLots = MathMin(brokerMax, rawLots);

    return rawLots;
}

//===================================================================
//  CheckEmergencyEquityStop  [NEW v11]
//  Independent of the static SL: force-closes a position if its own
//  floating loss reaches InpEmergencyLossPercentPerTrade of equity.
//  Catches gap/slippage fills that jump past a resting SL.
//===================================================================
void CheckEmergencyEquityStop()
{
    if(!InpUseEmergencyEquityStop) return;

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity <= 0.0) return;

    double maxLossMoney = equity * (InpEmergencyLossPercentPerTrade / 100.0);

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol ||
           PositionGetInteger(POSITION_MAGIC) != g_magic) continue;

        ulong  ticket = PositionGetTicket(i);
        double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

        if(profit < 0.0 && MathAbs(profit) >= maxLossMoney)
        {
            if(trade.PositionClose(ticket))
            {
                Print("Pure_Fractal v11: EMERGENCY EQUITY STOP | Ticket=", ticket,
                      " | FloatingLoss=", DoubleToString(profit, 2),
                      " | Limit=-", DoubleToString(maxLossMoney, 2),
                      " | Catches slippage/gap fills that jumped past the static SL.");
                g_lastCloseTime = TimeCurrent();
            }
            else
            {
                Print("Pure_Fractal v11: Emergency close FAILED | Ticket=", ticket,
                      " | RetCode=", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
            }
        }
    }
}

//===================================================================
//  CheckReversalProtectiveExit
//===================================================================
void CheckReversalProtectiveExit(double pLong)
{
    if(!InpUseReversalExit) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol ||
           PositionGetInteger(POSITION_MAGIC) != g_magic) continue;

        ulong ticket  = PositionGetTicket(i);
        long  posType = PositionGetInteger(POSITION_TYPE);

        bool reversalTickFlag = false;

        if(posType == POSITION_TYPE_BUY)
        {
            double pShort = 1.0 - pLong;
            reversalTickFlag = (pShort >= InpReversalBiasThreshold);
            if(reversalTickFlag && InpReversalRequireMacro)
                reversalTickFlag = MacroAgrees(-1);
        }
        else if(posType == POSITION_TYPE_SELL)
        {
            reversalTickFlag = (pLong >= InpReversalBiasThreshold);
            if(reversalTickFlag && InpReversalRequireMacro)
                reversalTickFlag = MacroAgrees(1);
        }

        if(reversalTickFlag)
            g_reversalStreakLen++;
        else
            g_reversalStreakLen = 0;

        if(g_reversalStreakLen >= InpReversalConfirmTicks)
        {
            if(trade.PositionClose(ticket))
            {
                Print("Pure_Fractal v11: REVERSAL PROTECTIVE EXIT | Ticket=", ticket,
                      " | Type=", EnumToString((ENUM_POSITION_TYPE)posType),
                      " | pLong=", DoubleToString(pLong, 4),
                      " | MacroV=", DoubleToString(g_mxV, 6),
                      " | StreakTicks=", g_reversalStreakLen);
                g_lastCloseTime = TimeCurrent();
            }
            else
            {
                Print("Pure_Fractal v11: Reversal exit FAILED | Ticket=", ticket,
                      " | RetCode=", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
            }
            g_reversalStreakLen = 0;
        }
    }
}

//===================================================================
//  ExecuteBiasedEntry
//  Full gate cascade: environment -> capital guard -> cooldown ->
//  entry confirmation -> trading hours -> spread -> signal -> macro
//  agreement -> broker-safe SL/TP -> risk-based sizing -> send + verify.
//===================================================================
void ExecuteBiasedEntry()
{
    if(!IsTradingEnvironmentReady()) return;
    if(IsCapitalGuardTripped())      return;
    if(!IsCooldownElapsed())         return;
    if(!IsEntryConfirmed())          return;
    if(!IsWithinTradingHours())      return;

    double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double mid    = (ask + bid) * 0.5;
    double atr    = g_bufATR[0];
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    if(atr <= 0.0) return;
    if(!IsSpreadAcceptable(atr)) return;

    double pLong  = ComputeBiasProbability(mid, atr);
    double pShort = 1.0 - pLong;

    bool goLong;
    if(pLong >= InpBiasThreshold)
        goLong = true;
    else if(pShort >= InpBiasThreshold)
        goLong = false;
    else
    {
        if(!InpAllowAmbiguousEntry) return;
        double r = (double)MathRand() / 32767.0;
        goLong = (r < pLong);
    }

    if(!MacroAgrees(goLong ? 1 : -1))
        return;

    //--- Broker-safe SL/TP distances (never closer than the symbol's stop/freeze level)
    double minStopDist = GetMinStopDistance();
    double slDist = MathMax(atr * InpSLMultiplier, minStopDist);
    double tpDist = MathMax(atr * InpTPMultiplier, minStopDist);

    if(slDist > atr * InpSLMultiplier || tpDist > atr * InpTPMultiplier)
        Print("Pure_Fractal v11: SL/TP widened to respect broker minimum stop distance on ", _Symbol,
              " (MinDist=", DoubleToString(minStopDist, digits), ")");

    //--- Risk-based lot size, computed from the ACTUAL (possibly widened) SL distance
    double lots = ComputeRiskBasedLotSize(slDist);
    if(lots <= 0.0)
    {
        Print("Pure_Fractal v11: Entry skipped on ", _Symbol, " — risk-based size below broker minimum at ",
              DoubleToString(InpRiskPercentPerTrade, 2), "% risk. Raise risk%, raise equity, or disable InpSkipIfRiskTooSmall.");
        return;
    }

    bool sent;
    if(goLong)
    {
        double sl = NormalizeDouble(ask - slDist, digits);
        double tp = NormalizeDouble(ask + tpDist, digits);
        sent = trade.Buy(lots, _Symbol, ask, sl, tp, "KF11 Buy");
    }
    else
    {
        double sl = NormalizeDouble(bid + slDist, digits);
        double tp = NormalizeDouble(bid - tpDist, digits);
        sent = trade.Sell(lots, _Symbol, bid, sl, tp, "KF11 Sell");
    }

    if(!sent)
    {
        Print("Pure_Fractal v11: ORDER FAILED on ", _Symbol, " | RetCode=", trade.ResultRetcode(),
              " | ", trade.ResultRetcodeDescription());
        return;
    }

    g_reversalStreakLen = 0;
    g_entryStreakLen    = 0;
    g_entryStreakDir    = 0;
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
//  ManageExitsAndProtection
//  Every PositionModify is now also clamped to respect the broker's
//  minimum stop distance, so a trailing step never sends a request
//  that the broker would reject as "invalid stops".
//===================================================================
void ManageExitsAndProtection()
{
    double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double atr    = g_bufATR[0];
    double minStopDist = GetMinStopDistance();

    double trailDist = InpUseATRTrailing ? (atr * InpTrailingATRFactor) : (InpTrailingPoints * point);
    double beTrigger  = atr * InpBreakevenATRFactor;
    double beLock     = InpMinPointsProfit * point;

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
            //--- 1. Smart Breakeven
            if(bid >= open + beTrigger)
            {
                double targetBE = open + beLock;
                if(sl < targetBE && (bid - targetBE) >= minStopDist)
                    trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
            }
            //--- 2. Aggressive Trailing Stop (only after BE is locked)
            if(sl >= open)
            {
                double newSL = NormalizeDouble(bid - trailDist, digits);
                if(newSL > sl && (bid - newSL) >= minStopDist)
                    trade.PositionModify(ticket, newSL, tp);
            }
        }
        else // POSITION_TYPE_SELL
        {
            //--- 1. Smart Breakeven
            if(ask <= open - beTrigger)
            {
                double targetBE = open - beLock;
                if((sl == 0.0 || sl > targetBE) && (targetBE - ask) >= minStopDist)
                    trade.PositionModify(ticket, NormalizeDouble(targetBE, digits), tp);
            }
            //--- 2. Aggressive Trailing Stop (only after BE is locked)
            if(sl > 0.0 && sl <= open)
            {
                double newSL = NormalizeDouble(ask + trailDist, digits);
                if(newSL < sl && (newSL - ask) >= minStopDist)
                    trade.PositionModify(ticket, newSL, tp);
            }
        }
    }
}
//+------------------------------------------------------------------+