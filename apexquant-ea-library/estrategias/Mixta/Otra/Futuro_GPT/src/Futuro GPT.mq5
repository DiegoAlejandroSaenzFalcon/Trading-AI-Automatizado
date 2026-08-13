//+------------------------------------------------------------------+
//|                                                MarketStructureEA |
//|                       Professional Market Structure Analyzer      |
//|                     XAUUSD M5 - Visual Analytical Tool            |
//|                                                                  |
//|  Version : 1.00                                                  |
//|  Platform: MetaTrader 5                                          |
//|  Author  : ChatGPT                                               |
//|                                                                  |
//|  Este EA NO abre operaciones.                                    |
//|  Su única finalidad es analizar estructura del mercado,          |
//|  detectar zonas institucionales y asistir visualmente al trader. |
//+------------------------------------------------------------------+

#property strict
#property version   "1.00"
#property description "Professional Market Structure Analyzer"
#property description "Visual Tool"
#property description "NO Auto Trading"
#property description "XAUUSD M5"

#include <Trade\SymbolInfo.mqh>

//========================================================
// ENUMS
//========================================================

enum ENUM_ZONE_TYPE
{
   ZONE_DEMAND=0,
   ZONE_SUPPLY=1
};

enum ENUM_ZONE_STATE
{
   ZONE_ACTIVE=0,
   ZONE_BROKEN=1,
   ZONE_DISABLED=2
};

//========================================================
// INPUTS
//========================================================

input int      InpSwingLength=5;

input int      InpATRPeriod=14;

input double   InpATRMultiplier=0.80;

input double   InpZoneThicknessATR=0.60;

input int      InpMaximumZones=250;

input int      InpMaximumHistoryBars=2500;

input bool     InpEnablePinbar=true;

input bool     InpEnableEngulfing=true;

input bool     InpEnableAlerts=true;

input bool     InpEnablePush=false;

input bool     InpEnablePanel=true;

input bool     InpEnableLogs=true;

input color    InpDemandColor=clrLime;

input color    InpSupplyColor=clrTomato;

input color    InpDemandBorder=clrGreen;

input color    InpSupplyBorder=clrRed;

input int      InpRectangleTransparency=70;

input int      InpArrowSize=2;

input double   InpPinbarRatio=0.60;

input double   InpBodyMaximum=0.25;

input double   InpMergeATRDistance=0.30;

input int      InpFutureProjectionBars=300;

//========================================================
// GLOBALS
//========================================================

string PREFIX_RECT="MS_RECT_";
string PREFIX_ARROW="MS_ARROW_";
string PREFIX_TEXT="MS_TEXT_";
string PREFIX_PANEL="MS_PANEL_";

int ATRHandle=INVALID_HANDLE;

double ATRBuffer[];

datetime LastBarTime=0;

CSymbolInfo SymbolData;

//========================================================
// ZONE CLASS
//========================================================

class CZone
{

public:

   int         ID;

   ENUM_ZONE_TYPE Type;

   ENUM_ZONE_STATE State;

   datetime    Time1;

   datetime    Time2;

   double      High;

   double      Low;

   double      Strength;

   int         Touches;

   bool        Alerted;

   bool        Visible;

   string      ObjectName;

   CZone()
   {
      ID=0;
      Type=ZONE_DEMAND;
      State=ZONE_ACTIVE;
      Time1=0;
      Time2=0;
      High=0;
      Low=0;
      Strength=0;
      Touches=0;
      Alerted=false;
      Visible=true;
      ObjectName="";
   }

};

//========================================================
// ARRAYS
//========================================================

CZone Zones[];

int ZoneCount=0;

//========================================================
// LOG
//========================================================

void Log(string txt)
{
   if(!InpEnableLogs)
      return;

   Print("[MarketStructureEA] ",txt);
}

//========================================================
// BAR DETECTION
//========================================================

bool IsNewBar()
{

   datetime t=iTime(_Symbol,_Period,0);

   if(t!=LastBarTime)
   {
      LastBarTime=t;
      return true;
   }

   return false;

}

//========================================================
// ATR
//========================================================

bool UpdateATR()
{

   if(CopyBuffer(ATRHandle,0,0,10,ATRBuffer)<=0)
      return false;

   return true;

}

double CurrentATR()
{

   if(ArraySize(ATRBuffer)==0)
      return 0;

   return ATRBuffer[0];

}

//========================================================
// OBJECT DELETE
//========================================================

void DeleteObjectsByPrefix(string prefix)
{

   int total=ObjectsTotal(0);

   for(int i=total-1;i>=0;i--)
   {

      string name=ObjectName(0,i);

      if(StringFind(name,prefix)==0)
         ObjectDelete(0,name);

   }

}

//========================================================
// CLEANUP
//========================================================

void DeleteAllEAObjects()
{

   DeleteObjectsByPrefix(PREFIX_RECT);

   DeleteObjectsByPrefix(PREFIX_ARROW);

   DeleteObjectsByPrefix(PREFIX_TEXT);

   DeleteObjectsByPrefix(PREFIX_PANEL);

}

//========================================================
// INIT
//========================================================

int OnInit()
{

   Log("Initialization...");

   SymbolData.Name(_Symbol);

   ATRHandle=iATR(_Symbol,_Period,InpATRPeriod);

   if(ATRHandle==INVALID_HANDLE)
   {
      Print("Cannot create ATR.");
      return(INIT_FAILED);
   }

   ArraySetAsSeries(ATRBuffer,true);

   ArrayResize(Zones,InpMaximumZones);

   LastBarTime=iTime(_Symbol,_Period,0);

   DeleteAllEAObjects();

   Log("Initialization Complete.");

   return(INIT_SUCCEEDED);

}
//========================================================
// DEINIT
//========================================================

void OnDeinit(const int reason)
{
   Log("Deinitializing EA...");

   DeleteAllEAObjects();

   if(ATRHandle!=INVALID_HANDLE)
      IndicatorRelease(ATRHandle);

   Log("Resources released.");
}

//========================================================
// SWING DETECTOR
//========================================================

bool IsSwingHigh(const int index)
{
   if(index<=InpSwingLength)
      return(false);

   if(index>=Bars(_Symbol,_Period)-InpSwingLength)
      return(false);

   double center=High[index];

   for(int i=1;i<=InpSwingLength;i++)
   {
      if(High[index-i]>=center)
         return(false);

      if(High[index+i]>center)
         return(false);
   }

   return(true);
}

bool IsSwingLow(const int index)
{
   if(index<=InpSwingLength)
      return(false);

   if(index>=Bars(_Symbol,_Period)-InpSwingLength)
      return(false);

   double center=Low[index];

   for(int i=1;i<=InpSwingLength;i++)
   {
      if(Low[index-i]<=center)
         return(false);

      if(Low[index+i]<center)
         return(false);
   }

   return(true);
}

//========================================================
// ATR FILTER
//========================================================

bool SwingPassATR(const int index)
{
   double atr=CurrentATR();

   if(atr<=0.0)
      return(false);

   double range=High[index]-Low[index];

   if(range<(atr*InpATRMultiplier))
      return(false);

   return(true);
}

//========================================================
// ZONE SEARCH
//========================================================

int FindZoneByPrice(double high,double low,ENUM_ZONE_TYPE type)
{
   for(int i=0;i<ZoneCount;i++)
   {
      if(Zones[i].State!=ZONE_ACTIVE)
         continue;

      if(Zones[i].Type!=type)
         continue;

      if(MathAbs(Zones[i].High-high)<(_Point*10))
      {
         if(MathAbs(Zones[i].Low-low)<(_Point*10))
            return(i);
      }
   }

   return(-1);
}

//========================================================
// CREATE ZONE
//========================================================

void CreateZone(const int index,
                ENUM_ZONE_TYPE type)
{

   if(ZoneCount>=InpMaximumZones)
      return;

   double atr=CurrentATR();

   if(atr<=0)
      return;

   double thickness=atr*InpZoneThicknessATR;

   CZone zone;

   zone.ID=ZoneCount+1;

   zone.Type=type;

   zone.State=ZONE_ACTIVE;

   zone.Time1=Time[index];

   zone.Time2=TimeCurrent()+(PeriodSeconds(_Period)*InpFutureProjectionBars);

   zone.Strength=1.0;

   zone.Touches=0;

   zone.Alerted=false;

   zone.Visible=true;

   if(type==ZONE_SUPPLY)
   {
      zone.High=High[index];
      zone.Low=High[index]-thickness;
   }
   else
   {
      zone.Low=Low[index];
      zone.High=Low[index]+thickness;
   }

   if(FindZoneByPrice(zone.High,zone.Low,type)>=0)
      return;

   zone.ObjectName=PREFIX_RECT+IntegerToString(zone.ID);

   Zones[ZoneCount]=zone;

   ZoneCount++;

}

//========================================================
// DRAW SINGLE ZONE
//========================================================

void DrawZone(CZone &zone)
{

   if(!zone.Visible)
      return;

   if(ObjectFind(0,zone.ObjectName)>=0)
      ObjectDelete(0,zone.ObjectName);

   ObjectCreate(0,
                zone.ObjectName,
                OBJ_RECTANGLE,
                0,
                zone.Time1,
                zone.High,
                zone.Time2,
                zone.Low);

   color clr=(zone.Type==ZONE_SUPPLY)?
              InpSupplyColor:
              InpDemandColor;

   ObjectSetInteger(0,
                    zone.ObjectName,
                    OBJPROP_COLOR,
                    clr);

   ObjectSetInteger(0,
                    zone.ObjectName,
                    OBJPROP_FILL,
                    true);

   ObjectSetInteger(0,
                    zone.ObjectName,
                    OBJPROP_BACK,
                    true);

   ObjectSetInteger(0,
                    zone.ObjectName,
                    OBJPROP_WIDTH,
                    1);

}

//========================================================
// DRAW ALL
//========================================================

void DrawAllZones()
{

   for(int i=0;i<ZoneCount;i++)
   {

      if(Zones[i].State!=ZONE_ACTIVE)
         continue;

      DrawZone(Zones[i]);

   }

}

//========================================================
// SCAN HISTORY
//========================================================

void ScanHistory()
{

   static bool scanned=false;

   if(scanned)
      return;

   Log("Scanning history...");

   int bars=MathMin(Bars(_Symbol,_Period)-InpSwingLength-5,
                    InpMaximumHistoryBars);

   for(int i=bars;i>=InpSwingLength;i--)
   {

      if(!SwingPassATR(i))
         continue;

      if(IsSwingHigh(i))
         CreateZone(i,ZONE_SUPPLY);

      if(IsSwingLow(i))
         CreateZone(i,ZONE_DEMAND);

   }

   DrawAllZones();

   scanned=true;

   Log("History scan finished.");

}

//========================================================
// NEW BAR UPDATE
//========================================================

void UpdateNewBar()
{

   int index=InpSwingLength+1;

   if(!SwingPassATR(index))
      return;

   if(IsSwingHigh(index))
      CreateZone(index,ZONE_SUPPLY);

   if(IsSwingLow(index))
      CreateZone(index,ZONE_DEMAND);

   DrawAllZones();

}

//========================================================
// ON TICK
//========================================================

void OnTick()
{

   if(!UpdateATR())
      return;

   ScanHistory();

   if(IsNewBar())
   {
      UpdateNewBar();
   }

   // Price Action Engine
   // (Continuará en la Parte 3)

}