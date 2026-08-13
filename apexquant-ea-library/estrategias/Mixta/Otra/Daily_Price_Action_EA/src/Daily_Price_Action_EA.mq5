//+------------------------------------------------------------------+
//|                                    PriceActionDayTrader.mq5      |
//|                                  Price Action Day Trading EA      |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Price Action Day Trader"
#property version   "1.00"
#property strict

// Input Parameters
input group "=== Risk Management ==="
input double RiskPercent = 1.5;              // Risk per trade (% of balance)
input double StopLossPips = 40;              // Stop Loss in pips
input double TakeProfitRatio = 2.0;          // Risk:Reward Ratio (TP/SL)
input double MaxDailyLoss = 3.0;             // Max daily loss (% of balance)

input group "=== Price Action Settings ==="
input int PinBarPipSize = 10;                // Minimum pin bar wick size (pips)
input double PinBarRatio = 2.0;              // Pin bar wick to body ratio
input int EngulfingMinPips = 15;             // Minimum engulfing candle size (pips)
input int SRLookback = 20;                   // Support/Resistance lookback periods
input double SRTolerance = 10;               // S/R level tolerance (pips)

input group "=== Moving Averages ==="
input int FastMA = 20;                       // Fast MA period
input int SlowMA = 50;                       // Slow MA period
input ENUM_MA_METHOD MAMethod = MODE_EMA;    // MA method

input group "=== Trading Hours ==="
input int StartHour = 2;                     // Trading start hour (broker time)
input int EndHour = 20;                      // Trading end hour (broker time)
input bool CloseAtEndOfDay = true;           // Close all positions at end of day

input group "=== Trade Management ==="
input int MagicNumber = 123456;              // Magic number
input bool UseBreakEven = true;              // Move SL to breakeven
input double BreakEvenPips = 20;             // Breakeven trigger (pips)
input bool UseTrailingStop = true;           // Use trailing stop
input double TrailingStopPips = 30;          // Trailing stop distance (pips)
input double TrailingStepPips = 10;          // Trailing stop step (pips)

input group "=== Order Filling ==="
input ENUM_ORDER_TYPE_FILLING FillingMode = ORDER_FILLING_FOK;  // Preferred filling mode
input bool AutoDetectFilling = true;         // Auto-detect broker filling mode

// Global variables
double pipValue;
double dailyStartBalance;
datetime lastBarTime;
int fastMAHandle, slowMAHandle;
double fastMA[], slowMA[];
ENUM_ORDER_TYPE_FILLING orderFillingMode;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Calculate pip value
   string symbol = _Symbol;
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   pipValue = (digits == 3 || digits == 5) ? 10 * _Point : _Point;
   
   // Initialize MA handles
   fastMAHandle = iMA(symbol, PERIOD_CURRENT, FastMA, 0, MAMethod, PRICE_CLOSE);
   slowMAHandle = iMA(symbol, PERIOD_CURRENT, SlowMA, 0, MAMethod, PRICE_CLOSE);
   
   if(fastMAHandle == INVALID_HANDLE || slowMAHandle == INVALID_HANDLE)
   {
      Print("Error creating MA handles");
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);
   
   // Detect and set order filling mode
   orderFillingMode = DetectFillingMode();
   Print("Using order filling mode: ", EnumToString(orderFillingMode));
   
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastBarTime = 0;
   
   Print("Price Action Day Trader EA initialized successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(fastMAHandle != INVALID_HANDLE)
      IndicatorRelease(fastMAHandle);
   if(slowMAHandle != INVALID_HANDLE)
      IndicatorRelease(slowMAHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool isNewBar = (currentBarTime != lastBarTime);
   
   if(isNewBar)
   {
      lastBarTime = currentBarTime;
      
      // Update daily start balance at beginning of day
      MqlDateTime time;
      TimeToStruct(TimeCurrent(), time);
      if(time.hour == 0 && time.min == 0)
      {
         dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      }
   }
   
   // Check trading hours
   if(!IsTradingTime())
   {
      if(CloseAtEndOfDay && PositionsTotal() > 0)
      {
         CloseAllPositions();
      }
      return;
   }
   
   // Check daily loss limit
   if(CheckDailyLossLimit())
   {
      Print("Daily loss limit reached. No new trades today.");
      return;
   }
   
   // Manage existing positions
   ManagePositions();
   
   // Look for new trade setups only on new bar
   if(isNewBar && PositionsTotal() == 0)
   {
      AnalyzeAndTrade();
   }
}

//+------------------------------------------------------------------+
//| Detect broker's supported filling mode                           |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   // If auto-detect is disabled, use user preference
   if(!AutoDetectFilling)
   {
      Print("Auto-detect disabled. Using manual filling mode: ", EnumToString(FillingMode));
      return FillingMode;
   }
   
   // Get broker's filling mode
   int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   // Check supported filling modes (bit flags)
   bool supportsFOK = (filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK;
   bool supportsIOC = (filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC;
   
   Print("Broker filling modes - FOK: ", supportsFOK, " | IOC: ", supportsIOC);
   
   // Priority: FOK > IOC > RETURN
   if(supportsFOK)
   {
      Print("Broker supports FOK - using Fill or Kill mode");
      return ORDER_FILLING_FOK;
   }
   else if(supportsIOC)
   {
      Print("Broker supports IOC - using Immediate or Cancel mode");
      return ORDER_FILLING_IOC;
   }
   
   // Fallback
   Print("Warning: Could not detect filling mode. Using FOK as default.");
   return ORDER_FILLING_FOK;
}

//+------------------------------------------------------------------+
//| Check trading hours                                              |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   
   if(time.hour >= StartHour && time.hour < EndHour)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check daily loss limit                                           |
//+------------------------------------------------------------------+
bool CheckDailyLossLimit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyLoss = dailyStartBalance - currentBalance;
   double lossPercent = (dailyLoss / dailyStartBalance) * 100;
   
   if(lossPercent >= MaxDailyLoss)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Analyze market and execute trades                                |
//+------------------------------------------------------------------+
void AnalyzeAndTrade()
{
   // Check if we have sufficient bars
   int bars = Bars(_Symbol, PERIOD_CURRENT);
   int requiredBars = MathMax(SlowMA, SRLookback) + 5;
   
   if(bars < requiredBars)
   {
      Print("Insufficient bars for calculation. Required: ", requiredBars, " Available: ", bars);
      return;
   }
   
   // Copy MA data with error checking
   if(CopyBuffer(fastMAHandle, 0, 0, 3, fastMA) < 3)
   {
      Print("Error copying Fast MA buffer: ", GetLastError());
      return;
   }
   
   if(CopyBuffer(slowMAHandle, 0, 0, 3, slowMA) < 3)
   {
      Print("Error copying Slow MA buffer: ", GetLastError());
      return;
   }
   
   // Determine trend
   int trend = GetTrend();
   
   // Check for price action setups
   int signal = 0;
   
   // Check for pin bar setup
   if(IsPinBar(1))
   {
      signal = GetPinBarSignal(1, trend);
   }
   
   // Check for engulfing pattern
   if(signal == 0 && IsEngulfing(1))
   {
      signal = GetEngulfingSignal(1, trend);
   }
   
   // Check for inside bar breakout
   if(signal == 0 && IsInsideBar(1))
   {
      signal = GetInsideBarSignal(1, trend);
   }
   
   // Execute trade if signal found
   if(signal != 0)
   {
      double sl = StopLossPips * pipValue;
      double tp = sl * TakeProfitRatio;
      
      if(signal > 0) // Buy signal
      {
         ExecuteBuy(sl, tp);
      }
      else if(signal < 0) // Sell signal
      {
         ExecuteSell(sl, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Get market trend                                                 |
//+------------------------------------------------------------------+
int GetTrend()
{
   if(fastMA[0] > slowMA[0] && fastMA[1] > slowMA[1])
      return 1;  // Uptrend
   
   if(fastMA[0] < slowMA[0] && fastMA[1] < slowMA[1])
      return -1; // Downtrend
   
   return 0; // No clear trend
}

//+------------------------------------------------------------------+
//| Check if candle is a pin bar                                    |
//+------------------------------------------------------------------+
bool IsPinBar(int index)
{
   double open = iOpen(_Symbol, PERIOD_CURRENT, index);
   double high = iHigh(_Symbol, PERIOD_CURRENT, index);
   double low = iLow(_Symbol, PERIOD_CURRENT, index);
   double close = iClose(_Symbol, PERIOD_CURRENT, index);
   
   double bodySize = MathAbs(close - open);
   double upperWick = high - MathMax(open, close);
   double lowerWick = MathMin(open, close) - low;
   
   // Bullish pin bar - long lower wick
   if(lowerWick > PinBarPipSize * pipValue && 
      lowerWick > bodySize * PinBarRatio &&
      upperWick < bodySize)
   {
      return true;
   }
   
   // Bearish pin bar - long upper wick
   if(upperWick > PinBarPipSize * pipValue && 
      upperWick > bodySize * PinBarRatio &&
      lowerWick < bodySize)
   {
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Get pin bar signal                                               |
//+------------------------------------------------------------------+
int GetPinBarSignal(int index, int trend)
{
   double open = iOpen(_Symbol, PERIOD_CURRENT, index);
   double high = iHigh(_Symbol, PERIOD_CURRENT, index);
   double low = iLow(_Symbol, PERIOD_CURRENT, index);
   double close = iClose(_Symbol, PERIOD_CURRENT, index);
   
   double upperWick = high - MathMax(open, close);
   double lowerWick = MathMin(open, close) - low;
   
   // Bullish pin bar in uptrend or at support
   if(lowerWick > upperWick * 2 && (trend >= 0 || IsAtSupport(low)))
   {
      return 1; // Buy signal
   }
   
   // Bearish pin bar in downtrend or at resistance
   if(upperWick > lowerWick * 2 && (trend <= 0 || IsAtResistance(high)))
   {
      return -1; // Sell signal
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Check if candle is engulfing                                     |
//+------------------------------------------------------------------+
bool IsEngulfing(int index)
{
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, index);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, index);
   double open2 = iOpen(_Symbol, PERIOD_CURRENT, index + 1);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, index + 1);
   
   double candleSize = MathAbs(close1 - open1);
   
   if(candleSize < EngulfingMinPips * pipValue)
      return false;
   
   // Bullish engulfing
   if(close2 < open2 && close1 > open1 && 
      open1 <= close2 && close1 > open2)
   {
      return true;
   }
   
   // Bearish engulfing
   if(close2 > open2 && close1 < open1 && 
      open1 >= close2 && close1 < open2)
   {
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Get engulfing signal                                             |
//+------------------------------------------------------------------+
int GetEngulfingSignal(int index, int trend)
{
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, index);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, index);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, index + 1);
   
   // Bullish engulfing
   if(close1 > open1 && close2 < iOpen(_Symbol, PERIOD_CURRENT, index + 1))
   {
      if(trend >= 0) // In uptrend or neutral
         return 1;
   }
   
   // Bearish engulfing
   if(close1 < open1 && close2 > iOpen(_Symbol, PERIOD_CURRENT, index + 1))
   {
      if(trend <= 0) // In downtrend or neutral
         return -1;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Check if candle is inside bar                                    |
//+------------------------------------------------------------------+
bool IsInsideBar(int index)
{
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, index);
   double low1 = iLow(_Symbol, PERIOD_CURRENT, index);
   double high2 = iHigh(_Symbol, PERIOD_CURRENT, index + 1);
   double low2 = iLow(_Symbol, PERIOD_CURRENT, index + 1);
   
   if(high1 < high2 && low1 > low2)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Get inside bar breakout signal                                   |
//+------------------------------------------------------------------+
int GetInsideBarSignal(int index, int trend)
{
   double close0 = iClose(_Symbol, PERIOD_CURRENT, 0);
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, index + 1);
   double low1 = iLow(_Symbol, PERIOD_CURRENT, index + 1);
   
   // Bullish breakout
   if(close0 > high1 && trend >= 0)
   {
      return 1;
   }
   
   // Bearish breakout
   if(close0 < low1 && trend <= 0)
   {
      return -1;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Check if price is at support                                     |
//+------------------------------------------------------------------+
bool IsAtSupport(double price)
{
   double tolerance = SRTolerance * pipValue;
   
   for(int i = 2; i < SRLookback; i++)
   {
      double low = iLow(_Symbol, PERIOD_CURRENT, i);
      if(MathAbs(price - low) < tolerance)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if price is at resistance                                  |
//+------------------------------------------------------------------+
bool IsAtResistance(double price)
{
   double tolerance = SRTolerance * pipValue;
   
   for(int i = 2; i < SRLookback; i++)
   {
      double high = iHigh(_Symbol, PERIOD_CURRENT, i);
      if(MathAbs(price - high) < tolerance)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if sufficient funds for trade                              |
//+------------------------------------------------------------------+
bool CheckMoneyForTrade(string symb, double lots, ENUM_ORDER_TYPE type)
{
   // Getting the opening price
   MqlTick mqltick;
   if(!SymbolInfoTick(symb, mqltick))
   {
      Print("Error getting tick data: ", GetLastError());
      return false;
   }
   
   double price = mqltick.ask;
   if(type == ORDER_TYPE_SELL)
      price = mqltick.bid;
   
   // Values of the required and free margin
   double margin, free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   // Call of the checking function
   if(!OrderCalcMargin(type, symb, lots, price, margin))
   {
      Print("Error in ", __FUNCTION__, " code=", GetLastError());
      return false;
   }
   
   // If there are insufficient funds to perform the operation
   if(margin > free_margin)
   {
      Print("Not enough money for ", EnumToString(type), " ", lots, " ", symb, 
            " Required margin: ", margin, " Free margin: ", free_margin);
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check the correctness of the order volume                        |
//+------------------------------------------------------------------+
bool CheckVolumeValue(double volume, string &description)
{
   // Minimal allowed volume for trade operations
   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(volume < min_volume)
   {
      description = StringFormat("Volume %.2f is less than the minimal allowed SYMBOL_VOLUME_MIN=%.2f",
                                  volume, min_volume);
      return false;
   }
   
   // Maximal allowed volume of trade operations
   double max_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(volume > max_volume)
   {
      description = StringFormat("Volume %.2f is greater than the maximal allowed SYMBOL_VOLUME_MAX=%.2f",
                                  volume, max_volume);
      return false;
   }
   
   // Get minimal step of volume changing
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int ratio = (int)MathRound(volume / volume_step);
   if(MathAbs(ratio * volume_step - volume) > 0.0000001)
   {
      description = StringFormat("Volume %.2f is not a multiple of the minimal step SYMBOL_VOLUME_STEP=%.2f, closest valid volume=%.2f",
                                  volume, volume_step, ratio * volume_step);
      return false;
   }
   
   description = "Correct volume value";
   return true;
}

//+------------------------------------------------------------------+
//| Check if new order is allowed                                    |
//+------------------------------------------------------------------+
bool IsNewOrderAllowed()
{
   // Get the number of pending orders allowed on the account
   int max_allowed_orders = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
   
   // If there is no limitation, return true
   if(max_allowed_orders == 0) 
      return true;
   
   // Count current orders
   int orders = OrdersTotal();
   
   // Return the result of comparing
   return (orders < max_allowed_orders);
}

//+------------------------------------------------------------------+
//| Check StopLoss and TakeProfit levels                             |
//+------------------------------------------------------------------+
bool CheckStopLoss_TakeProfit(ENUM_ORDER_TYPE type, double SL, double TP)
{
   // Get the SYMBOL_TRADE_STOPS_LEVEL level
   int stops_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   
   if(stops_level == 0)
      return true; // No restrictions
   
   // Get current prices
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Print("Error getting tick data: ", GetLastError());
      return false;
   }
   
   bool SL_check = false, TP_check = false;
   
   // Check only two order types
   switch(type)
   {
      case ORDER_TYPE_BUY:
      {
         // Check the StopLoss
         if(SL > 0)
         {
            SL_check = ((tick.bid - SL) > stops_level * _Point);
            if(!SL_check)
               Print("For Buy order StopLoss=", SL, " must be less than ", 
                     tick.bid - stops_level * _Point, " (Bid-SYMBOL_TRADE_STOPS_LEVEL)");
         }
         else
            SL_check = true;
         
         // Check the TakeProfit
         if(TP > 0)
         {
            TP_check = ((TP - tick.bid) > stops_level * _Point);
            if(!TP_check)
               Print("For Buy order TakeProfit=", TP, " must be greater than ", 
                     tick.bid + stops_level * _Point, " (Bid+SYMBOL_TRADE_STOPS_LEVEL)");
         }
         else
            TP_check = true;
         
         return (SL_check && TP_check);
      }
      
      case ORDER_TYPE_SELL:
      {
         // Check the StopLoss
         if(SL > 0)
         {
            SL_check = ((SL - tick.ask) > stops_level * _Point);
            if(!SL_check)
               Print("For Sell order StopLoss=", SL, " must be greater than ", 
                     tick.ask + stops_level * _Point, " (Ask+SYMBOL_TRADE_STOPS_LEVEL)");
         }
         else
            SL_check = true;
         
         // Check the TakeProfit
         if(TP > 0)
         {
            TP_check = ((tick.ask - TP) > stops_level * _Point);
            if(!TP_check)
               Print("For Sell order TakeProfit=", TP, " must be less than ", 
                     tick.ask - stops_level * _Point, " (Ask-SYMBOL_TRADE_STOPS_LEVEL)");
         }
         else
            TP_check = true;
         
         return (TP_check && SL_check);
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Execute buy order                                                |
//+------------------------------------------------------------------+
void ExecuteBuy(double slDistance, double tpDistance)
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(price - slDistance, _Digits);
   double tp = NormalizeDouble(price + tpDistance, _Digits);
   
   // Calculate lot size based on risk
   double lotSize = CalculateLotSize(slDistance);
   
   // Validate lot size
   string volumeDesc;
   if(!CheckVolumeValue(lotSize, volumeDesc))
   {
      Print("Invalid lot size: ", volumeDesc);
      return;
   }
   
   // Check if sufficient funds
   if(!CheckMoneyForTrade(_Symbol, lotSize, ORDER_TYPE_BUY))
   {
      Print("Insufficient funds for Buy trade");
      return;
   }
   
   // Check if new order is allowed
   if(!IsNewOrderAllowed())
   {
      Print("Maximum number of orders reached");
      return;
   }
   
   // Check SL/TP levels
   if(!CheckStopLoss_TakeProfit(ORDER_TYPE_BUY, sl, tp))
   {
      Print("Invalid StopLoss or TakeProfit levels");
      return;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = price;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = "PA Buy";
   request.type_filling = orderFillingMode;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
      {
         Print("Buy order placed successfully. Ticket: ", result.order, " Deal: ", result.deal);
      }
      else
      {
         Print("Buy order placed with retcode: ", result.retcode, " - ", result.comment);
      }
   }
   else
   {
      Print("Buy order failed. Error: ", GetLastError(), " Retcode: ", result.retcode);
      // Try alternative filling mode if first attempt fails
      if(!RetryWithAlternativeFilling(request, result, "Buy"))
      {
         Print("All filling modes failed for Buy order");
      }
   }
}

//+------------------------------------------------------------------+
//| Execute sell order                                               |
//+------------------------------------------------------------------+
void ExecuteSell(double slDistance, double tpDistance)
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(price + slDistance, _Digits);
   double tp = NormalizeDouble(price - tpDistance, _Digits);
   
   // Calculate lot size based on risk
   double lotSize = CalculateLotSize(slDistance);
   
   // Validate lot size
   string volumeDesc;
   if(!CheckVolumeValue(lotSize, volumeDesc))
   {
      Print("Invalid lot size: ", volumeDesc);
      return;
   }
   
   // Check if sufficient funds
   if(!CheckMoneyForTrade(_Symbol, lotSize, ORDER_TYPE_SELL))
   {
      Print("Insufficient funds for Sell trade");
      return;
   }
   
   // Check if new order is allowed
   if(!IsNewOrderAllowed())
   {
      Print("Maximum number of orders reached");
      return;
   }
   
   // Check SL/TP levels
   if(!CheckStopLoss_TakeProfit(ORDER_TYPE_SELL, sl, tp))
   {
      Print("Invalid StopLoss or TakeProfit levels");
      return;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = price;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = "PA Sell";
   request.type_filling = orderFillingMode;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
      {
         Print("Sell order placed successfully. Ticket: ", result.order, " Deal: ", result.deal);
      }
      else
      {
         Print("Sell order placed with retcode: ", result.retcode, " - ", result.comment);
      }
   }
   else
   {
      Print("Sell order failed. Error: ", GetLastError(), " Retcode: ", result.retcode);
      // Try alternative filling mode if first attempt fails
      if(!RetryWithAlternativeFilling(request, result, "Sell"))
      {
         Print("All filling modes failed for Sell order");
      }
   }
}

//+------------------------------------------------------------------+
//| Retry order with alternative filling modes                       |
//+------------------------------------------------------------------+
bool RetryWithAlternativeFilling(MqlTradeRequest &request, MqlTradeResult &result, string orderType)
{
   ENUM_ORDER_TYPE_FILLING alternativeModes[];
   int modeCount = 0;
   
   // Build list of alternative modes based on current mode
   if(orderFillingMode == ORDER_FILLING_FOK)
   {
      ArrayResize(alternativeModes, 2);
      alternativeModes[0] = ORDER_FILLING_IOC;
      alternativeModes[1] = ORDER_FILLING_RETURN;
      modeCount = 2;
   }
   else if(orderFillingMode == ORDER_FILLING_IOC)
   {
      ArrayResize(alternativeModes, 2);
      alternativeModes[0] = ORDER_FILLING_FOK;
      alternativeModes[1] = ORDER_FILLING_RETURN;
      modeCount = 2;
   }
   else // ORDER_FILLING_RETURN
   {
      ArrayResize(alternativeModes, 2);
      alternativeModes[0] = ORDER_FILLING_FOK;
      alternativeModes[1] = ORDER_FILLING_IOC;
      modeCount = 2;
   }
   
   // Try each alternative mode
   for(int i = 0; i < modeCount; i++)
   {
      request.type_filling = alternativeModes[i];
      Print("Retrying ", orderType, " order with filling mode: ", EnumToString(alternativeModes[i]));
      
      if(OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
         {
            Print(orderType, " order successful with ", EnumToString(alternativeModes[i]), ". Ticket: ", result.order);
            // Update global filling mode if successful
            orderFillingMode = alternativeModes[i];
            return true;
         }
      }
      else
      {
         Print("Failed with ", EnumToString(alternativeModes[i]), ". Error: ", GetLastError());
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   // Prevent division by zero
   if(tickValue == 0 || tickSize == 0 || slDistance == 0)
   {
      Print("Error: Invalid values for lot calculation. TickValue=", tickValue, 
            " TickSize=", tickSize, " SLDistance=", slDistance);
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   }
   
   double lotSize = (riskAmount * tickSize) / (slDistance * tickValue);
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(lotStep == 0)
      lotStep = minLot;
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Manage existing positions                                        |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || 
         PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      
      // Move to breakeven
      if(UseBreakEven)
      {
         MoveToBreakeven(ticket);
      }
      
      // Re-verify position still exists before trailing stop
      if(!PositionSelectByTicket(ticket))
         continue;
      
      // Trailing stop
      if(UseTrailingStop)
      {
         TrailStop(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Move stop loss to breakeven                                      |
//+------------------------------------------------------------------+
void MoveToBreakeven(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;
   
   // Verify position still belongs to this EA
   if(PositionGetString(POSITION_SYMBOL) != _Symbol || 
      PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return;
   
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   long posType = PositionGetInteger(POSITION_TYPE);
   
   double currentPrice = (posType == POSITION_TYPE_BUY) ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double beTrigger = BreakEvenPips * pipValue;
   bool shouldModify = false;
   double newSL = currentSL;
   
   if(posType == POSITION_TYPE_BUY)
   {
      if(currentPrice >= openPrice + beTrigger && currentSL < openPrice)
      {
         newSL = openPrice;
         shouldModify = true;
      }
   }
   else // SELL
   {
      if(currentPrice <= openPrice - beTrigger && (currentSL > openPrice || currentSL == 0))
      {
         newSL = openPrice;
         shouldModify = true;
      }
   }
   
   if(shouldModify)
   {
      // Final check before modification
      if(PositionSelectByTicket(ticket))
      {
         ModifyPosition(ticket, NormalizeDouble(newSL, _Digits), currentTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing stop                                                    |
//+------------------------------------------------------------------+
void TrailStop(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return;
   
   // Verify position still belongs to this EA
   if(PositionGetString(POSITION_SYMBOL) != _Symbol || 
      PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return;
   
   long posType = PositionGetInteger(POSITION_TYPE);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   double currentPrice = (posType == POSITION_TYPE_BUY) ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double trailDistance = TrailingStopPips * pipValue;
   double trailStep = TrailingStepPips * pipValue;
   bool shouldModify = false;
   double newSL = currentSL;
   
   if(posType == POSITION_TYPE_BUY)
   {
      newSL = currentPrice - trailDistance;
      if(newSL > currentSL + trailStep)
      {
         shouldModify = true;
      }
   }
   else // SELL
   {
      newSL = currentPrice + trailDistance;
      if(newSL < currentSL - trailStep || currentSL == 0)
      {
         shouldModify = true;
      }
   }
   
   if(shouldModify)
   {
      // Final check before modification
      if(PositionSelectByTicket(ticket))
      {
         ModifyPosition(ticket, NormalizeDouble(newSL, _Digits), currentTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Check if modification is within freeze level                     |
//+------------------------------------------------------------------+
bool CheckFreezeLevel(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;
   
   int freeze_level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(freeze_level == 0)
      return true; // No freeze level
   
   long posType = PositionGetInteger(POSITION_TYPE);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return false;
   
   bool check = true;
   
   if(posType == POSITION_TYPE_BUY)
   {
      // Check StopLoss
      if(currentSL > 0)
      {
         check = check && ((tick.bid - currentSL) > freeze_level * _Point);
         if(!check)
            Print("Position #", ticket, " cannot be modified: Bid-SL distance=", 
                  (int)((tick.bid - currentSL) / _Point), " points < SYMBOL_TRADE_FREEZE_LEVEL=", freeze_level);
      }
      
      // Check TakeProfit
      if(currentTP > 0)
      {
         check = check && ((currentTP - tick.bid) > freeze_level * _Point);
         if(!check)
            Print("Position #", ticket, " cannot be modified: TP-Bid distance=", 
                  (int)((currentTP - tick.bid) / _Point), " points < SYMBOL_TRADE_FREEZE_LEVEL=", freeze_level);
      }
   }
   else // SELL
   {
      // Check StopLoss
      if(currentSL > 0)
      {
         check = check && ((currentSL - tick.ask) > freeze_level * _Point);
         if(!check)
            Print("Position #", ticket, " cannot be modified: SL-Ask distance=", 
                  (int)((currentSL - tick.ask) / _Point), " points < SYMBOL_TRADE_FREEZE_LEVEL=", freeze_level);
      }
      
      // Check TakeProfit
      if(currentTP > 0)
      {
         check = check && ((tick.ask - currentTP) > freeze_level * _Point);
         if(!check)
            Print("Position #", ticket, " cannot be modified: Ask-TP distance=", 
                  (int)((tick.ask - currentTP) / _Point), " points < SYMBOL_TRADE_FREEZE_LEVEL=", freeze_level);
      }
   }
   
   return check;
}

//+------------------------------------------------------------------+
//| Modify position                                                  |
//+------------------------------------------------------------------+
void ModifyPosition(ulong ticket, double sl, double tp)
{
   // Final verification that position exists
   if(!PositionSelectByTicket(ticket))
   {
      Print("ModifyPosition: Position #", ticket, " doesn't exist");
      return;
   }
   
   // Verify it's the correct symbol and magic number
   if(PositionGetString(POSITION_SYMBOL) != _Symbol || 
      PositionGetInteger(POSITION_MAGIC) != MagicNumber)
   {
      Print("ModifyPosition: Position #", ticket, " doesn't match EA symbol/magic");
      return;
   }
   
   // Check if modification is actually needed
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   
   if(NormalizeDouble(currentSL, _Digits) == NormalizeDouble(sl, _Digits) && 
      NormalizeDouble(currentTP, _Digits) == NormalizeDouble(tp, _Digits))
   {
      return; // No change needed - avoid TRADE_RETCODE_NO_CHANGES error
   }
   
   // Check freeze level
   if(!CheckFreezeLevel(ticket))
   {
      return; // Cannot modify within freeze level
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = _Symbol;
   request.sl = NormalizeDouble(sl, _Digits);
   request.tp = NormalizeDouble(tp, _Digits);
   request.magic = MagicNumber;
   request.type_filling = orderFillingMode;
   
   if(!OrderSend(request, result))
   {
      int error = GetLastError();
      // Only log significant errors
      if(error != 10013) // 10013 = Invalid request
      {
         Print("ModifyPosition failed for #", ticket, " Error: ", error, 
               " Retcode: ", result.retcode, " - ", result.comment);
      }
   }
   else
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         Print("Position #", ticket, " modified successfully. SL=", sl, " TP=", tp);
      }
      else if(result.retcode != TRADE_RETCODE_NO_CHANGES)
      {
         Print("Position modification returned: ", result.retcode, " - ", result.comment);
      }
   }
}

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;
      
      // Verify position belongs to this EA before closing
      if(!PositionSelectByTicket(ticket))
         continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || 
         PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol = _Symbol;
      request.volume = PositionGetDouble(POSITION_VOLUME);
      request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                     ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price = (request.type == ORDER_TYPE_SELL) ? 
                      SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                      SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.deviation = 10;
      request.type_filling = orderFillingMode;
      request.magic = MagicNumber;
      
      if(!OrderSend(request, result))
      {
         Print("Failed to close position #", ticket, " Error: ", GetLastError(), 
               " Retcode: ", result.retcode);
         // Try alternative filling modes
         RetryWithAlternativeFilling(request, result, "Close");
      }
      else
      {
         if(result.retcode == TRADE_RETCODE_DONE)
            Print("Position #", ticket, " closed successfully");
      }
   }
}
//+------------------------------------------------------------------+