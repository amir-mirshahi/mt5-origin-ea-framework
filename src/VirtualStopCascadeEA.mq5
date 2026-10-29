//+------------------------------------------------------------------+
//| VirtualStopCascadeEA.mq5                                          |
//| Public portfolio version                                          |
//|                                                                   |
//| Architecture demo for MetaTrader 5 (MQL5):                        |
//|   - Pluggable signal layer (CSignalProvider interface)            |
//|   - Virtual stop state machine (IDLE > VIRTUAL > ARMED > REAL)    |
//|   - Incremental take-profit cascade with alternating reversals    |
//|   - Risk-capped position sizing, daily limits, session filters    |
//|   - Friday protection with broker-session-aware force close       |
//|   - On-chart visual layer and status panel                        |
//|                                                                   |
//| The entry signal in this file is a GENERIC DEMO (SMA crossover).  |
//| It exists only to exercise the execution engine in the Strategy   |
//| Tester. It is NOT a trading edge. Educational use only.           |
//| Not financial advice.                                             |
//+------------------------------------------------------------------+
#property copyright "Amir Mirshahi"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//--- RISK / CORE ---
input double          InpMaxRisk            = 10.0;     // Max risk per trade (account currency)
input double          InpLotSize            = 0.0;      // Fixed lot (0 = auto, risk-capped)
input long            InpMagicNumberA       = 100001;
input long            InpMagicNumberB       = 100002;
input int             InpSlippage           = 10;
input bool            InpTradeBuy           = true;
input bool            InpTradeSell          = true;
input int             InpMaxSpread          = 50;
input double          InpSLBufferPoints     = 1.0;
input ENUM_TIMEFRAMES InpTimeframe          = PERIOD_M5;
input bool            InpDebugMode          = true;

//--- DEMO SIGNAL (replace with your own CSignalProvider) ---
input int             InpDemoFastPeriod     = 10;
input int             InpDemoSlowPeriod     = 30;
input int             InpDemoStopLookback   = 3;        // bars used for the stop reference

//--- REVERSAL CASCADE ---
input bool            InpEnableReverse      = true;
input int             InpMaxReverseCount    = 10;
input double          InpReverseTPRatio     = 2.0;      // used when origin mode is off
input double          InpReverseTPIncrement = 1.0;
input double          InpManualRR           = 2.0;

//--- ORIGIN (VIRTUAL STOP) MODE ---
input bool            InpUseOriginMode      = true;
input int             InpOriginStopsRequired= 3;        // virtual stops before arming
input double          InpRealMainRR         = 2.0;
input double          InpRealRevRR1         = 2.0;
input double          InpRealRevRR2         = 2.0;
input double          InpRealRevRRStep      = 0.5;

//--- DAILY LIMITS ---
input bool            InpUseDailyLimits     = true;
input double          InpDailyProfitTarget  = 50.0;
input double          InpDailyLossLimit     = 30.0;

//--- HOUR WINDOW ---
input bool            InpUseTradingHours    = true;
input string          InpNoNewTradesAfter   = "20:00";  // server time HH:MM

//--- FRIDAY PROTECTION ---
input int             InpFridayCutoffHour   = 12;       // London time: no new trades after
input int             InpFridayCutoffMinute = 0;
input int             InpFridayCloseMinutesBeforeWeekEnd = 30;
input int             InpFridayFallbackCloseHour   = 23;
input int             InpFridayFallbackCloseMinute = 59;

//--- PANEL ---
input bool            InpEnablePanel        = true;
input int             InpPanelUpdateSeconds = 1;

//--- VISUALS ---
input bool            InpShowVisuals        = true;
input bool            InpClearVisualsOnEnd  = false;

//====================================================================
// PHASES
//====================================================================
enum ENUM_PHASE
{
   PHASE_IDLE = 0,     // scanning for a signal
   PHASE_VIRTUAL = 1,  // virtual (paper) cascade running
   PHASE_ARMED = 2,    // enough virtual stops; waiting for price to return to origin
   PHASE_REAL = 3      // real orders live
};

//====================================================================
// SIGNAL LAYER (the only strategy-specific part of the EA)
//====================================================================
// A signal provider returns a direction, the price at which the setup
// is considered triggered, and a reference price for the stop-loss.
// The engine below never knows how the decision was made.
struct SignalResult
{
   int    direction;      // +1 buy, -1 sell, 0 none
   double triggerPrice;   // buy: ask >= trigger | sell: bid <= trigger
   double stopRef;        // buy: low reference  | sell: high reference
};

class CSignalProvider
{
public:
   virtual            ~CSignalProvider() {}
   // Called once per newly closed bar. Return true if a setup exists.
   virtual bool       Evaluate(SignalResult &out) = 0;
};

//====================================================================
// VIRTUAL STATE
//====================================================================
int      g_virtual_stops=0;
int      g_virtual_leg=0;
double   g_virtual_entry=0.0;
double   g_virtual_sl=0.0;
double   g_virtual_tp=0.0;
int      g_virtual_dir=0;
datetime g_virtual_legStartBar=0;
double   g_origin_entry=0.0;
double   g_origin_sl=0.0;
int      g_origin_dir=0;
datetime g_originBarTime=0;

//====================================================================
// REAL STATE
//====================================================================
bool     g_realActive=false;
int      g_consecutiveSL=0;
int      g_reverseCount=0;
ulong    g_currentTicket=0;
long     g_currentMagic=0;
int      g_currentDirection=0;
double   g_currentEntry=0.0,g_currentSL=0.0,g_currentTP=0.0,g_currentLots=0.0;
ulong    g_pendingTicket=0;
long     g_pendingMagic=0;
int      g_pendingDirection=0;
double   g_pendingEntry=0.0,g_pendingSL=0.0,g_pendingTP=0.0,g_pendingLots=0.0;

//====================================================================
// SIGNAL / PHASE STATE
//====================================================================
ENUM_PHASE g_phase=PHASE_IDLE;
datetime   g_lastProcessedBarTime=0;
bool       g_awaitingTrigger=false;
int        g_signalDirection=0;
double     g_signalTrigger=0.0;
double     g_signalStopRef=0.0;
datetime   g_signalBarTime=0,g_triggerBarTime=0;
CSignalProvider *g_signal=NULL;

//====================================================================
// SESSION / DAILY
//====================================================================
bool     g_fridayForceCloseDone=false;
datetime g_dailyResetTime=0;
double   g_dailyRealizedPnL=0.0;
bool     g_dailyLocked=false;
int      g_cutoffHour=-1;
int      g_cutoffMinute=-1;
bool     g_cutoffValid=false;

//====================================================================
// CACHE
//====================================================================
datetime g_cachedMinute=0;
bool     g_cachedIsFridayCutoff=false;
bool     g_cachedIsForceCloseTime=false;
datetime g_cachedWeekCloseDate=0;
datetime g_cachedWeekClose=0;
bool     g_cachedWeekCloseValid=false;
datetime g_lastPanelUpdate=0;
string   g_lastPanelText="";

//====================================================================
// VISUAL PREFIX
//====================================================================
#define VIS_PREFIX "VSC_"

//====================================================================
// HELPERS
//====================================================================
void DebugPrint(string s){if(InpDebugMode) Print("[VSC-EA] ",TimeToString(TimeCurrent())," ",s);}
double Pt(){return SymbolInfoDouble(_Symbol,SYMBOL_POINT);}
int DigitsPrice(){return (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);}
double NP(double p){return NormalizeDouble(p,DigitsPrice());}
bool OurMagic(long m){return m==InpMagicNumberA || m==InpMagicNumberB;}

bool ParseHourMinute(string src,int &h,int &m)
{
   h=-1; m=-1;
   string s=src; StringTrimLeft(s); StringTrimRight(s);
   int colon=StringFind(s,":");
   if(colon<=0) return false;
   h=(int)StringToInteger(StringSubstr(s,0,colon));
   m=(int)StringToInteger(StringSubstr(s,colon+1));
   return (h>=0 && h<=23 && m>=0 && m<=59);
}

//====================================================================
// DEMO SIGNAL: SMA crossover with breakout confirmation
// (generic, for exercising the engine only)
//====================================================================
class CDemoMaCrossSignal : public CSignalProvider
{
private:
   double SMA(int shift,int period)
   {
      double s=0.0;
      for(int i=0;i<period;i++) s+=iClose(_Symbol,InpTimeframe,shift+i);
      return s/period;
   }
   double LowestLow(int bars)
   {
      double v=iLow(_Symbol,InpTimeframe,1);
      for(int i=2;i<=bars;i++) v=MathMin(v,iLow(_Symbol,InpTimeframe,i));
      return v;
   }
   double HighestHigh(int bars)
   {
      double v=iHigh(_Symbol,InpTimeframe,1);
      for(int i=2;i<=bars;i++) v=MathMax(v,iHigh(_Symbol,InpTimeframe,i));
      return v;
   }
public:
   virtual bool Evaluate(SignalResult &out)
   {
      out.direction=0; out.triggerPrice=0.0; out.stopRef=0.0;

      int lookback=MathMax(1,InpDemoStopLookback);
      int need=MathMax(InpDemoSlowPeriod,InpDemoFastPeriod)+lookback+3;
      if(Bars(_Symbol,InpTimeframe)<need) return false;

      double f1=SMA(1,InpDemoFastPeriod), s1=SMA(1,InpDemoSlowPeriod);
      double f2=SMA(2,InpDemoFastPeriod), s2=SMA(2,InpDemoSlowPeriod);
      double point=Pt();

      if(f1>s1 && f2<=s2)          // bullish cross on the last closed bar
      {
         out.direction=1;
         out.triggerPrice=NP(iHigh(_Symbol,InpTimeframe,1)+point);
         out.stopRef=LowestLow(lookback);
      }
      else if(f1<s1 && f2>=s2)     // bearish cross on the last closed bar
      {
         out.direction=-1;
         out.triggerPrice=NP(iLow(_Symbol,InpTimeframe,1)-point);
         out.stopRef=HighestHigh(lookback);
      }
      return out.direction!=0;
   }
};

//====================================================================
// VISUAL DRAWING HELPERS
//====================================================================
void VisDeleteAll()
{
   int total=ObjectsTotal(0,-1,-1);
   for(int i=total-1;i>=0;i--)
   {
      string nm=ObjectName(0,i,-1,-1);
      if(StringFind(nm,VIS_PREFIX)==0) ObjectDelete(0,nm);
   }
   ChartRedraw(0);
}

void VisHLine(string name,double price,color clr,ENUM_LINE_STYLE style,int width)
{
   if(!InpShowVisuals) return;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

void VisText(string name,datetime t,double price,string txt,color clr,int anchor=ANCHOR_LEFT)
{
   if(!InpShowVisuals) return;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_TEXT,0,t,price);
   ObjectSetInteger(0,name,OBJPROP_TIME,0,t);
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,7);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial Narrow");
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
}

//--- right-edge price label (does not overlap candle bodies)
void VisRightLabel(string name,double price,string txt,color clr)
{
   if(!InpShowVisuals) return;
   datetime t=iTime(_Symbol,InpTimeframe,0)+PeriodSeconds(InpTimeframe)*10;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_TEXT,0,t,price);
   ObjectSetInteger(0,name,OBJPROP_TIME,0,t);
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,7);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial Narrow");
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
}

//--- tiny marker (dot)
void VisStopMarker(string name,datetime t,double price,color clr)
{
   if(!InpShowVisuals) return;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_ARROW,0,t,price);
   ObjectSetInteger(0,name,OBJPROP_ARROWCODE,159);
   ObjectSetInteger(0,name,OBJPROP_TIME,0,t);
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
}

//--- screen-corner label
void VisCornerLabel(string name,int x,int y,string txt,color clr,int fontSize=8)
{
   if(!InpShowVisuals) return;
   if(ObjectFind(0,name)<0)
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

//====================================================================
// DRAW CURRENT STATE
//====================================================================
void VisRedrawOrigin()
{
   if(!InpShowVisuals) return;
   VisDeleteAll();
   if(g_origin_entry<=0) return;

   color cDir=(g_origin_dir==1 ? clrDodgerBlue : clrOrangeRed);
   string tag=(g_origin_dir==1 ? "ORIGIN BUY" : "ORIGIN SELL");

   //--- origin entry / SL
   VisHLine(VIS_PREFIX+"originEntry", g_origin_entry, cDir, STYLE_SOLID, 1);
   VisRightLabel(VIS_PREFIX+"originEntryTxt", g_origin_entry,
                 StringFormat("%s %.5f",tag,g_origin_entry), cDir);

   VisHLine(VIS_PREFIX+"originSL", g_origin_sl, clrRed, STYLE_DASH, 1);
   VisRightLabel(VIS_PREFIX+"originSLTxt", g_origin_sl,
                 StringFormat("ORIGIN SL %.5f",g_origin_sl), clrRed);

   //--- current virtual leg
   color cLeg=(g_virtual_dir==1 ? clrLimeGreen : clrCrimson);
   double legDist=MathAbs(g_virtual_entry-g_virtual_sl);
   double legRR=(legDist>0)?(MathAbs(g_virtual_tp-g_virtual_entry)/legDist):0;

   VisHLine(VIS_PREFIX+"legEntry", g_virtual_entry, cLeg, STYLE_SOLID, 1);
   VisRightLabel(VIS_PREFIX+"legEntryTxt", g_virtual_entry,
                 StringFormat("V-LEG %d %s %.5f",
                              g_virtual_leg,
                              g_virtual_dir==1?"BUY":"SELL",
                              g_virtual_entry),
                 cLeg);

   VisHLine(VIS_PREFIX+"legSL", g_virtual_sl, clrRed, STYLE_DOT, 1);
   VisHLine(VIS_PREFIX+"legTP", g_virtual_tp, clrGreen, STYLE_DOT, 1);
   VisRightLabel(VIS_PREFIX+"legTPTxt", g_virtual_tp,
                 StringFormat("V-TP %.1fR %.5f",legRR,g_virtual_tp),
                 clrGreen);

   //--- corner status
   string st1,st2;
   if(g_phase==PHASE_VIRTUAL)
   {
      st1=StringFormat("PHASE: VIRTUAL (%s)",g_virtual_dir==1?"BUY":"SELL");
      st2=StringFormat("Virtual stops: %d / %d",g_virtual_stops,InpOriginStopsRequired);
   }
   else if(g_phase==PHASE_ARMED)
   {
      st1="PHASE: ARMED";
      st2=StringFormat("Waiting return to %.5f  (%d stops)",g_origin_entry,g_virtual_stops);
   }
   else if(g_phase==PHASE_REAL)
   {
      st1=StringFormat("PHASE: REAL (%s)",g_currentDirection==1?"BUY":"SELL");
      st2=StringFormat("Stops %d | Reverses %d/%d",
                       g_consecutiveSL,g_reverseCount,InpMaxReverseCount);
   }
   else
   {
      st1="PHASE: IDLE";
      st2="Scanning for signal...";
   }
   VisCornerLabel(VIS_PREFIX+"status1",10,20,st1,clrYellow,9);
   VisCornerLabel(VIS_PREFIX+"status2",10,38,st2,clrWhite,8);

   ChartRedraw(0);
}

//====================================================================
// VIRTUAL STOP MARKER
//====================================================================
void VisMarkVirtualStop(int stopNumber)
{
   if(!InpShowVisuals) return;
   datetime t=iTime(_Symbol,InpTimeframe,1);
   double offset=10*Pt();
   double y;
   if(g_origin_dir==1) y=iLow (_Symbol,InpTimeframe,1) - offset;
   else                y=iHigh(_Symbol,InpTimeframe,1) + offset;

   VisStopMarker(VIS_PREFIX+"stop_"+IntegerToString(stopNumber), t, y, clrMagenta);
   VisText(VIS_PREFIX+"stopTxt_"+IntegerToString(stopNumber),
           t+PeriodSeconds(InpTimeframe)/3, y,
           IntegerToString(stopNumber), clrMagenta);
   ChartRedraw(0);
}

//====================================================================
// DAILY P/L
//====================================================================
datetime StartOfDay(datetime t)
{
   MqlDateTime dt; TimeToStruct(t,dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   return StructToTime(dt);
}
void RefreshDailyPnL()
{
   datetime today=StartOfDay(TimeCurrent());
   if(today!=g_dailyResetTime)
   {
      g_dailyResetTime=today; g_dailyRealizedPnL=0.0; g_dailyLocked=false;
   }
   double sum=0.0;
   if(HistorySelect(today,TimeCurrent()+60))
   {
      int total=HistoryDealsTotal();
      for(int i=0;i<total;i++)
      {
         ulong d=HistoryDealGetTicket(i); if(d==0) continue;
         if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
         if(!OurMagic(HistoryDealGetInteger(d,DEAL_MAGIC))) continue;
         if(HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
         sum += HistoryDealGetDouble(d,DEAL_PROFIT)
              + HistoryDealGetDouble(d,DEAL_COMMISSION)
              + HistoryDealGetDouble(d,DEAL_SWAP);
      }
   }
   g_dailyRealizedPnL=sum;
   if(InpUseDailyLimits)
   {
      if(!g_dailyLocked && g_dailyRealizedPnL >= InpDailyProfitTarget)
      {
         g_dailyLocked=true;
         DebugPrint(StringFormat("DAILY PROFIT TARGET $%.2f -> locked",g_dailyRealizedPnL));
      }
      if(!g_dailyLocked && g_dailyRealizedPnL <= -InpDailyLossLimit)
      {
         g_dailyLocked=true;
         DebugPrint(StringFormat("DAILY LOSS LIMIT $%.2f -> locked",g_dailyRealizedPnL));
      }
   }
}
bool DailyLimitBlocksNewTrades(){ return InpUseDailyLimits && g_dailyLocked; }

//====================================================================
// HOUR CUTOFF
//====================================================================
bool HourCutoffBlocksNewTrades()
{
   if(!InpUseTradingHours || !g_cutoffValid) return false;
   MqlDateTime st; TimeToStruct(TimeTradeServer(),st);
   return (st.hour*60+st.min) >= (g_cutoffHour*60+g_cutoffMinute);
}

//====================================================================
// FRIDAY PROTECTION
//====================================================================
bool IsLastSundayOfMonth(int y,int mo,int day)
{
   MqlDateTime dt={}; dt.year=y; dt.mon=mo; dt.day=day; dt.hour=12;
   datetime d=StructToTime(dt);
   MqlDateTime x={}; TimeToStruct(d,x);
   return x.day_of_week==SUNDAY && day>=25;
}
bool LondonIsDST(datetime utc)
{
   MqlDateTime u={}; TimeToStruct(utc,u);
   MqlDateTime mar={}; mar.year=u.year; mar.mon=3; mar.day=31; mar.hour=1;
   datetime dm=StructToTime(mar);
   while(!IsLastSundayOfMonth(u.year,3,mar.day)){ mar.day--; dm=StructToTime(mar); }
   MqlDateTime oct={}; oct.year=u.year; oct.mon=10; oct.day=31; oct.hour=1;
   datetime do_=StructToTime(oct);
   while(!IsLastSundayOfMonth(u.year,10,oct.day)){ oct.day--; do_=StructToTime(oct); }
   return utc>=dm && utc<do_;
}
datetime ServerTimeToUTC(datetime t){ return t-(long)(TimeTradeServer()-TimeGMT()); }
datetime LondonTimeFromServer(datetime t)
{
   datetime utc=ServerTimeToUTC(t);
   return utc+(LondonIsDST(utc)?3600:0);
}
bool IsFridayCutoff()
{
   datetime now=TimeTradeServer();
   datetime minNow=(datetime)(now-(now%60));
   if(minNow==g_cachedMinute) return g_cachedIsFridayCutoff;
   g_cachedMinute=minNow;
   datetime london=LondonTimeFromServer(now);
   MqlDateTime lt={}; TimeToStruct(london,lt);
   if(lt.day_of_week!=FRIDAY){ g_cachedIsFridayCutoff=false; return false; }
   int nowMin=lt.hour*60+lt.min;
   int cutMin=InpFridayCutoffHour*60+InpFridayCutoffMinute;
   g_cachedIsFridayCutoff=(nowMin>=cutMin);
   return g_cachedIsFridayCutoff;
}
bool GetFridayWeekClose(datetime &wc)
{
   wc=0;
   datetime now=TimeTradeServer();
   MqlDateTime st={}; TimeToStruct(now,st);
   if(st.day_of_week!=FRIDAY) return false;
   MqlDateTime mid=st; mid.hour=0; mid.min=0; mid.sec=0;
   datetime dayStart=StructToTime(mid);
   if(g_cachedWeekCloseValid && g_cachedWeekCloseDate==dayStart){ wc=g_cachedWeekClose; return true; }
   long best=-1;
   for(uint idx=0; idx<32; idx++)
   {
      datetime f=0,t=0;
      if(!SymbolInfoSessionTrade(_Symbol,FRIDAY,idx,f,t)) break;
      long ts=(long)t; if(ts<0) continue;
      if(ts>best) best=ts;
   }
   if(best>=0)
   {
      wc=dayStart+(datetime)best;
      if(wc<=now && best<86400) wc+=86400;
   }
   else
   {
      MqlDateTime fb=mid; fb.hour=InpFridayFallbackCloseHour; fb.min=InpFridayFallbackCloseMinute; fb.sec=0;
      wc=StructToTime(fb);
   }
   g_cachedWeekCloseDate=dayStart; g_cachedWeekClose=wc; g_cachedWeekCloseValid=true;
   return true;
}
bool FridayForceCloseTime()
{
   datetime now=TimeTradeServer();
   datetime minNow=(datetime)(now-(now%60));
   if(minNow==g_cachedMinute) return g_cachedIsForceCloseTime;
   if(minNow!=g_cachedMinute){ g_cachedMinute=0; IsFridayCutoff(); }
   MqlDateTime st={}; TimeToStruct(now,st);
   if(st.day_of_week!=FRIDAY){ g_cachedIsForceCloseTime=false; return false; }
   datetime wc=0; if(!GetFridayWeekClose(wc)){ g_cachedIsForceCloseTime=false; return false; }
   datetime forceAt=wc-InpFridayCloseMinutesBeforeWeekEnd*60;
   g_cachedIsForceCloseTime=(now>=forceAt);
   return g_cachedIsForceCloseTime;
}
void DeleteAllOurPendingOrders()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i); if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(!OurMagic(OrderGetInteger(ORDER_MAGIC))) continue;
      trade.OrderDelete(t);
   }
}
void CloseAllOurPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(!OurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
      trade.PositionClose(t);
   }
}
bool FridayProtection()
{
   if(FridayForceCloseTime())
   {
      if(!g_fridayForceCloseDone)
      {
         DebugPrint("FRIDAY FORCE CLOSE");
         DeleteAllOurPendingOrders();
         CloseAllOurPositions();
         ResetSignal();
         ResetVirtual();
         ResetRealCascade();
         g_fridayForceCloseDone=true;
      }
      return true;
   }
   g_fridayForceCloseDone=false;   // re-arm for the next week
   return false;
}

//====================================================================
// RISK
//====================================================================
bool SpreadOK(){ return SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=InpMaxSpread; }

double NormalizeVolumeDown(double v)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0||minv<=0||maxv<=0) return 0;
   v=MathMin(v,maxv);
   double out=MathFloor((v+1e-12)/step)*step;
   out=NormalizeDouble(out,8);
   return out<minv?0:out;
}
double RiskForVolume(int direction,double entry,double sl,double volume)
{
   if(volume<=0||entry<=0||sl<=0) return -1;
   if(direction==1 && sl>=entry) return -1;
   if(direction==-1 && sl<=entry) return -1;
   double profit=0;
   ENUM_ORDER_TYPE type=(direction==1?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   if(!OrderCalcProfit(type,_Symbol,volume,entry,sl,profit)) return -1;
   return MathAbs(profit);
}
double CalculateRiskCappedLot(int direction,double entry,double sl,double &riskUsed)
{
   riskUsed=0;
   double minv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(minv<=0||maxv<=0||step<=0) return 0;
   double minRisk=RiskForVolume(direction,entry,sl,minv);
   if(minRisk<0) return 0;
   if(minRisk>InpMaxRisk+0.0001) return 0;
   if(InpLotSize>0)
   {
      double fx=NormalizeVolumeDown(InpLotSize);
      if(fx<=0) return 0;
      double r=RiskForVolume(direction,entry,sl,fx);
      if(r<0||r>InpMaxRisk+0.0001) return 0;
      riskUsed=r; return fx;
   }
   double cand=MathMin(maxv,minv*(InpMaxRisk/minRisk));
   cand=NormalizeVolumeDown(cand);
   while(cand>=minv-1e-12)
   {
      double r=RiskForVolume(direction,entry,sl,cand);
      if(r>=0 && r<=InpMaxRisk+0.0001){ riskUsed=r; return cand; }
      cand=NormalizeVolumeDown(cand-step);
      if(cand<=0) break;
   }
   return 0;
}

//====================================================================
// SIGNAL HANDLING (engine side: consumes SignalResult only)
//====================================================================
void ResetSignal()
{
   g_awaitingTrigger=false;g_signalDirection=0;
   g_signalTrigger=0;g_signalStopRef=0;
   g_signalBarTime=0;g_triggerBarTime=0;
}
void CheckForNewSignal()
{
   if(Bars(_Symbol,InpTimeframe)<5) return;
   datetime t=iTime(_Symbol,InpTimeframe,1);
   if(t<=0||t==g_lastProcessedBarTime) return;
   g_lastProcessedBarTime=t;

   if(g_signal==NULL) return;
   SignalResult sig;
   if(!g_signal.Evaluate(sig)) return;
   if(sig.direction==1  && !InpTradeBuy)  return;
   if(sig.direction==-1 && !InpTradeSell) return;

   g_awaitingTrigger=true;
   g_signalDirection=sig.direction;
   g_signalTrigger=sig.triggerPrice;
   g_signalStopRef=sig.stopRef;
   g_signalBarTime=t;
   g_triggerBarTime=iTime(_Symbol,InpTimeframe,0);
   DebugPrint(StringFormat("%s SETUP trigger %.5f stopRef %.5f",
              sig.direction==1?"BUY":"SELL",sig.triggerPrice,sig.stopRef));
}

//====================================================================
// POSITION FINDERS
//====================================================================
ulong FindPosition(long magic)
{
   ulong found=0; long newest=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=magic) continue;
      long tm=(long)PositionGetInteger(POSITION_TIME_MSC);
      if(tm>=newest){ newest=tm; found=tk; }
   }
   return found;
}
bool AnyCascadePositionOpen()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && OurMagic(PositionGetInteger(POSITION_MAGIC))) return true;
   }
   return false;
}
bool AnyCascadeOrderPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i); if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol && OurMagic(OrderGetInteger(ORDER_MAGIC))) return true;
   }
   return false;
}

//====================================================================
// RESET
//====================================================================
void ResetVirtual()
{
   g_virtual_stops=0;
   g_virtual_leg=0;
   g_virtual_entry=0; g_virtual_sl=0; g_virtual_tp=0;
   g_virtual_dir=0;
   g_virtual_legStartBar=0;
   g_origin_entry=0; g_origin_sl=0; g_origin_dir=0; g_originBarTime=0;
   if(g_phase==PHASE_VIRTUAL || g_phase==PHASE_ARMED) g_phase=PHASE_IDLE;
   if(InpClearVisualsOnEnd) VisDeleteAll();
}
void ResetRealCascade()
{
   g_realActive=false;
   g_consecutiveSL=0;
   g_reverseCount=0;
   g_currentTicket=0;g_currentMagic=0;g_currentDirection=0;
   g_currentEntry=0;g_currentSL=0;g_currentTP=0;g_currentLots=0;
   g_pendingTicket=0;g_pendingMagic=0;g_pendingDirection=0;
   g_pendingEntry=0;g_pendingSL=0;g_pendingTP=0;g_pendingLots=0;
   if(g_phase==PHASE_REAL) g_phase=PHASE_IDLE;
}

//====================================================================
// PHASE 1: START VIRTUAL ORIGIN
//====================================================================
void StartVirtualOrigin(int direction)
{
   double point=Pt();
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double entry=(direction==1?ask:bid);
   double sl=(direction==1 ? NP(g_signalStopRef-InpSLBufferPoints*point)
                           : NP(g_signalStopRef+InpSLBufferPoints*point));
   if((direction==1 && sl>=entry)||(direction==-1 && sl<=entry))
   {
      DebugPrint("Origin: invalid SL; skipping");
      ResetSignal();
      return;
   }

   g_origin_dir=direction;
   g_origin_entry=NP(entry);
   g_origin_sl=NP(sl);
   g_originBarTime=iTime(_Symbol,InpTimeframe,0);

   g_virtual_dir=direction;
   g_virtual_leg=0;
   g_virtual_stops=0;
   g_virtual_entry=g_origin_entry;
   g_virtual_sl=g_origin_sl;
   double dist=MathAbs(g_virtual_entry-g_virtual_sl);
   g_virtual_tp=NP(direction==1?g_virtual_entry+dist:g_virtual_entry-dist);
   g_virtual_legStartBar=g_originBarTime;

   g_phase=PHASE_VIRTUAL;

   DebugPrint(StringFormat("ORIGIN START %s | entry %.5f SL %.5f TP(1R) %.5f",
             direction==1?"BUY":"SELL",g_virtual_entry,g_virtual_sl,g_virtual_tp));

   VisRedrawOrigin();
}

//====================================================================
// PHASE 1: VIRTUAL LEG MANAGEMENT (wick-based)
//====================================================================
void UpdateVirtualCascade()
{
   if(g_phase!=PHASE_VIRTUAL && g_phase!=PHASE_ARMED) return;
   if(g_virtual_dir==0) return;

   datetime curBar=iTime(_Symbol,InpTimeframe,0);
   if(curBar==g_virtual_legStartBar) return;

   double lo=iLow(_Symbol,InpTimeframe,1);
   double hi=iHigh(_Symbol,InpTimeframe,1);

   bool slHit=(g_virtual_dir==1)?(lo<=g_virtual_sl):(hi>=g_virtual_sl);
   bool tpHit=(g_virtual_dir==1)?(hi>=g_virtual_tp):(lo<=g_virtual_tp);

   if(tpHit)
   {
      DebugPrint(StringFormat("VIRTUAL TP (leg %d) | origin dies | stops %d",
                g_virtual_leg,g_virtual_stops));
      VisText(VIS_PREFIX+"deathTxt",iTime(_Symbol,InpTimeframe,1),g_virtual_tp,
              "ORIGIN DIED (virtual TP)",clrRed);
      ResetVirtual();
      ChartRedraw(0);
      return;
   }

   if(slHit)
   {
      g_virtual_stops++;
      VisMarkVirtualStop(g_virtual_stops);
      DebugPrint(StringFormat("VIRTUAL STOP #%d (leg %d)",g_virtual_stops,g_virtual_leg));

      if(g_virtual_stops>=InpOriginStopsRequired)
      {
         g_phase=PHASE_ARMED;
         DebugPrint(StringFormat("ORIGIN ARMED at %d stops | waiting return to %.5f",
                   g_virtual_stops,g_origin_entry));
         VisRedrawOrigin();
         return;
      }

      // next leg: reverse direction, entry = previous SL, SL = previous entry,
      // TP ratio grows by one R per leg
      g_virtual_leg++;
      int newDir=-g_virtual_dir;
      double newEntry=g_virtual_sl;
      double newSL=g_virtual_entry;
      double dist=MathAbs(newEntry-newSL);
      double ratio=(double)(g_virtual_leg+1);
      double newTP=NP(newDir==1?newEntry+dist*ratio:newEntry-dist*ratio);

      g_virtual_dir=newDir;
      g_virtual_entry=newEntry;
      g_virtual_sl=newSL;
      g_virtual_tp=newTP;
      g_virtual_legStartBar=curBar;

      DebugPrint(StringFormat("VIRTUAL LEG %d | %s entry %.5f SL %.5f TP(%.1fR) %.5f",
                g_virtual_leg,newDir==1?"BUY":"SELL",newEntry,newSL,ratio,newTP));

      VisRedrawOrigin();
   }
}

//====================================================================
// PHASE 2: ARMED WAITING
//====================================================================
void UpdateArmedWaiting()
{
   if(g_phase!=PHASE_ARMED) return;
   if(IsFridayCutoff()) return;
   if(HourCutoffBlocksNewTrades()) return;
   if(DailyLimitBlocksNewTrades()) return;
   if(!SpreadOK()) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   bool triggered=false;
   if(g_origin_dir==1 && ask<=g_origin_entry) triggered=true;
   if(g_origin_dir==-1 && bid>=g_origin_entry) triggered=true;

   if(triggered)
   {
      DebugPrint(StringFormat("ORIGIN RETURN | opening REAL %s at %.5f",
                g_origin_dir==1?"BUY":"SELL",g_origin_entry));
      OpenRealFromOrigin();
   }
}

//====================================================================
// PHASE 3: OPEN REAL TRADE
//====================================================================
void OpenRealFromOrigin()
{
   int direction=g_origin_dir;
   double entry=(direction==1?SymbolInfoDouble(_Symbol,SYMBOL_ASK)
                            :SymbolInfoDouble(_Symbol,SYMBOL_BID));
   double sl=g_origin_sl;

   if((direction==1 && sl>=entry)||(direction==-1 && sl<=entry))
   {
      DebugPrint("Real: invalid SL; aborting");
      ResetVirtual();
      return;
   }

   double risk=0;
   double lots=CalculateRiskCappedLot(direction,entry,sl,risk);
   if(lots<=0){ DebugPrint("Real: lot calc failed; aborting"); ResetVirtual(); return; }
   double dist=MathAbs(entry-sl);
   double rr=MathMax(0.1,InpRealMainRR);
   double tp=NP(direction==1?entry+dist*rr:entry-dist*rr);

   trade.SetExpertMagicNumber((int)InpMagicNumberA);
   trade.SetDeviationInPoints(InpSlippage);
   bool ok=(direction==1
            ? trade.Buy(lots,_Symbol,0.0,sl,tp,"Origin-Real-BUY")
            : trade.Sell(lots,_Symbol,0.0,sl,tp,"Origin-Real-SELL"));
   if(!ok){ DebugPrint(StringFormat("REAL OPEN FAILED %d",trade.ResultRetcode())); ResetVirtual(); return; }

   ulong tk=FindPosition(InpMagicNumberA);
   if(tk==0 || !PositionSelectByTicket(tk)){ ResetVirtual(); return; }

   VisDeleteAll();

   color cDir=(direction==1?clrDodgerBlue:clrOrangeRed);
   VisHLine(VIS_PREFIX+"realEntry",entry,cDir,STYLE_SOLID,1);
   VisRightLabel(VIS_PREFIX+"realEntryTxt",entry,
                 StringFormat("REAL %s %.5f (%.1fR)",
                              direction==1?"BUY":"SELL",entry,rr),cDir);
   VisHLine(VIS_PREFIX+"realSL",sl,clrRed,STYLE_SOLID,1);
   VisRightLabel(VIS_PREFIX+"realSLTxt",sl,
                 StringFormat("REAL SL %.5f",sl),clrRed);
   VisHLine(VIS_PREFIX+"realTP",tp,clrGreen,STYLE_SOLID,1);
   VisRightLabel(VIS_PREFIX+"realTPTxt",tp,
                 StringFormat("REAL TP %.1fR %.5f",rr,tp),clrGreen);
   ChartRedraw(0);

   ResetVirtual();
   g_phase=PHASE_REAL;
   g_realActive=true;
   g_consecutiveSL=0; g_reverseCount=0;
   g_currentTicket=tk;
   g_currentMagic=InpMagicNumberA;
   g_currentDirection=direction;
   g_currentEntry=PositionGetDouble(POSITION_PRICE_OPEN);
   g_currentSL=PositionGetDouble(POSITION_SL);
   g_currentTP=PositionGetDouble(POSITION_TP);
   g_currentLots=PositionGetDouble(POSITION_VOLUME);
   g_pendingMagic=InpMagicNumberB;

   if(InpEnableReverse && InpMaxReverseCount>0) PlaceRealReverse();
}

//====================================================================
// PHASE 3: REAL REVERSE (pending stop order at the current SL)
//====================================================================
double RealReverseTPRatio(int revIndex)
{
   if(revIndex==1) return InpRealRevRR1;
   if(revIndex==2) return InpRealRevRR2;
   return InpRealRevRR2 + InpRealRevRRStep*(double)(revIndex-2);
}
void PlaceRealReverse()
{
   if(!InpEnableReverse) return;
   if(InpMaxReverseCount<=0) return;
   if(g_reverseCount>=InpMaxReverseCount) return;
   if(!g_realActive || g_currentTicket==0) return;
   if(IsFridayCutoff()||HourCutoffBlocksNewTrades()||DailyLimitBlocksNewTrades()) return;

   int dir=-g_currentDirection;
   double entry=NP(g_currentSL);
   double sl=NP(g_currentEntry);
   if((dir==1 && sl>=entry)||(dir==-1 && sl<=entry)) return;

   double risk=0;
   double lots=CalculateRiskCappedLot(dir,entry,sl,risk);
   if(lots<=0){ DebugPrint("REAL REVERSE skipped: lot cap"); return; }

   double dist=MathAbs(entry-sl);
   int nextIdx=g_reverseCount+1;
   double rr = InpUseOriginMode ? RealReverseTPRatio(nextIdx)
                                : (InpReverseTPRatio+g_consecutiveSL*InpReverseTPIncrement);
   double tp=NP(dir==1?entry+dist*rr:entry-dist*rr);

   trade.SetExpertMagicNumber((int)g_pendingMagic);
   trade.SetDeviationInPoints(InpSlippage);
   string cmt=StringFormat("Real-Rev%d-%.1fR",nextIdx,rr);
   bool ok=(dir==1 ? trade.BuyStop (lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,cmt)
                   : trade.SellStop(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,cmt));
   if(!ok){ DebugPrint(StringFormat("REAL REVERSE FAILED %d",trade.ResultRetcode())); return; }
   g_pendingTicket=trade.ResultOrder();
   g_pendingDirection=dir;
   g_pendingEntry=entry;
   g_pendingSL=sl;
   g_pendingTP=tp;
   g_pendingLots=lots;

   DebugPrint(StringFormat("REAL REVERSE #%d PLACED | %s entry %.5f SL %.5f TP(%.1fR) %.5f",
             nextIdx,dir==1?"BUY STOP":"SELL STOP",entry,sl,rr,tp));

   color cRev=(dir==1?clrLimeGreen:clrCrimson);
   VisHLine(VIS_PREFIX+"revPend",entry,cRev,STYLE_DASH,1);
   VisRightLabel(VIS_PREFIX+"revPendTxt",entry,
                 StringFormat("REV #%d pend %.5f (%.1fR)",nextIdx,entry,rr),cRev);
   ChartRedraw(0);
}
void CancelPendingRealReverse()
{
   if(g_pendingTicket==0) return;
   if(OrderSelect(g_pendingTicket)) trade.OrderDelete(g_pendingTicket);
   g_pendingTicket=0;
}

//====================================================================
// EXIT REASON
//====================================================================
bool GetExitReason(long magic,ulong pid,bool &tp,bool &sl)
{
   tp=false; sl=false;
   if(!HistorySelect(TimeCurrent()-3*86400,TimeCurrent()+60)) return false;
   for(int i=HistoryDealsTotal()-1;i>=0;i--)
   {
      ulong d=HistoryDealGetTicket(i); if(d==0) continue;
      if(HistoryDealGetString(d,DEAL_SYMBOL)!=_Symbol) continue;
      if(HistoryDealGetInteger(d,DEAL_MAGIC)!=magic) continue;
      if(HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      if((ulong)HistoryDealGetInteger(d,DEAL_POSITION_ID)!=pid) continue;
      ENUM_DEAL_REASON r=(ENUM_DEAL_REASON)HistoryDealGetInteger(d,DEAL_REASON);
      if(r==DEAL_REASON_TP){ tp=true; return true; }
      if(r==DEAL_REASON_SL){ sl=true; return true; }
      double p=HistoryDealGetDouble(d,DEAL_PRICE);
      tp=(MathAbs(p-g_currentTP)<MathAbs(p-g_currentSL));
      sl=!tp;
      return true;
   }
   return false;
}

//====================================================================
// PHASE 3: MONITOR
//====================================================================
void MonitorRealCascade()
{
   if(!g_realActive || g_currentTicket==0) return;
   if(PositionSelectByTicket(g_currentTicket)) return;

   bool tp=false,sl=false;
   if(!GetExitReason(g_currentMagic,g_currentTicket,tp,sl))
   {
      CancelPendingRealReverse(); ResetRealCascade(); return;
   }
   if(tp)
   {
      DebugPrint(StringFormat("REAL TP HIT | stops %d | reverses %d",g_consecutiveSL,g_reverseCount));
      VisText(VIS_PREFIX+"tpLabel",iTime(_Symbol,InpTimeframe,1),g_currentTP,"REAL TP HIT",clrGreen);
      CancelPendingRealReverse(); ResetRealCascade(); return;
   }
   if(sl)
   {
      g_consecutiveSL++;
      if(!InpEnableReverse){ CancelPendingRealReverse(); ResetRealCascade(); return; }
      if(g_reverseCount>=InpMaxReverseCount)
      {
         DebugPrint("REAL: max reverses reached; cascade ends");
         CancelPendingRealReverse(); ResetRealCascade(); return;
      }
      if(IsFridayCutoff()||HourCutoffBlocksNewTrades()||DailyLimitBlocksNewTrades())
      {
         CancelPendingRealReverse(); ResetRealCascade(); return;
      }
      ulong nxt=FindPosition(g_pendingMagic);
      if(nxt==0){ ResetRealCascade(); return; }
      if(!PositionSelectByTicket(nxt)){ ResetRealCascade(); return; }

      // the pending reverse order filled: it becomes the current leg,
      // and the magic numbers alternate between A and B
      g_reverseCount++;
      g_currentTicket=nxt;
      g_currentMagic=g_pendingMagic;
      g_currentDirection=g_pendingDirection;
      g_currentEntry=PositionGetDouble(POSITION_PRICE_OPEN);
      g_currentSL=PositionGetDouble(POSITION_SL);
      g_currentTP=PositionGetDouble(POSITION_TP);
      g_currentLots=PositionGetDouble(POSITION_VOLUME);
      g_pendingMagic=(g_currentMagic==InpMagicNumberA?InpMagicNumberB:InpMagicNumberA);
      g_pendingTicket=0;

      DebugPrint(StringFormat("REAL REVERSE #%d ACTIVE | %s entry %.5f SL %.5f TP %.5f",
                g_reverseCount,g_currentDirection==1?"BUY":"SELL",
                g_currentEntry,g_currentSL,g_currentTP));

      PlaceRealReverse();
   }
}

//====================================================================
// PANEL
//====================================================================
void UpdatePanel()
{
   if(!InpEnablePanel) return;
   datetime now=TimeCurrent();
   if(now-g_lastPanelUpdate<InpPanelUpdateSeconds) return;
   g_lastPanelUpdate=now;

   string ph="";
   switch(g_phase)
   {
      case PHASE_IDLE:    ph="IDLE - scanning"; break;
      case PHASE_VIRTUAL: ph=StringFormat("VIRTUAL %s | stops %d/%d",
                                g_virtual_dir==1?"BUY":"SELL",g_virtual_stops,InpOriginStopsRequired); break;
      case PHASE_ARMED:   ph=StringFormat("ARMED - waiting return to %.5f",g_origin_entry); break;
      case PHASE_REAL:    ph=StringFormat("REAL %s | stops %d | rev %d/%d",
                                g_currentDirection==1?"BUY":"SELL",g_consecutiveSL,g_reverseCount,InpMaxReverseCount); break;
   }
   string s=StringFormat("VirtualStopCascade EA v1.00\n%s\nToday P/L: $%.2f%s",
             ph,g_dailyRealizedPnL,g_dailyLocked?" [LOCKED]":"");
   if(s!=g_lastPanelText){ Comment(s); g_lastPanelText=s; }
}

//====================================================================
// INIT / DEINIT / TICK
//====================================================================
int OnInit()
{
   if(InpMagicNumberA==InpMagicNumberB || InpMaxRisk<=0 || InpSLBufferPoints<0) return INIT_PARAMETERS_INCORRECT;
   if(InpMaxReverseCount<0) return INIT_PARAMETERS_INCORRECT;
   if(InpUseOriginMode && InpOriginStopsRequired<1) return INIT_PARAMETERS_INCORRECT;
   if(InpDemoFastPeriod<1 || InpDemoSlowPeriod<=InpDemoFastPeriod) return INIT_PARAMETERS_INCORRECT;

   int h,m;
   if(ParseHourMinute(InpNoNewTradesAfter,h,m)){ g_cutoffHour=h; g_cutoffMinute=m; g_cutoffValid=true; }
   else { g_cutoffHour=-1; g_cutoffMinute=-1; g_cutoffValid=false; }

   trade.SetExpertMagicNumber((int)InpMagicNumberA);
   trade.SetDeviationInPoints(InpSlippage);

   // plug the signal provider in here; the engine does not care which one
   g_signal=new CDemoMaCrossSignal();
   if(g_signal==NULL) return INIT_FAILED;

   ResetSignal();
   ResetVirtual();
   ResetRealCascade();
   g_phase=PHASE_IDLE;
   g_fridayForceCloseDone=false;
   g_cachedMinute=0; g_cachedIsFridayCutoff=false; g_cachedIsForceCloseTime=false;
   g_cachedWeekCloseDate=0; g_cachedWeekClose=0; g_cachedWeekCloseValid=false;
   g_dailyResetTime=0; g_dailyRealizedPnL=0; g_dailyLocked=false;
   if(InpShowVisuals) VisDeleteAll();
   RefreshDailyPnL();
   UpdatePanel();

   DebugPrint("Init v1.00 | visuals="+string(InpShowVisuals));
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   Comment("");
   if(InpShowVisuals) VisDeleteAll();
   if(CheckPointer(g_signal)==POINTER_DYNAMIC){ delete g_signal; g_signal=NULL; }
}

void OnTick()
{
   RefreshDailyPnL();
   if(FridayProtection()){ UpdatePanel(); return; }

   // state machine dispatch
   if(g_phase==PHASE_REAL)    { MonitorRealCascade();   UpdatePanel(); return; }
   if(g_phase==PHASE_VIRTUAL) { UpdateVirtualCascade(); UpdatePanel(); return; }
   if(g_phase==PHASE_ARMED)   { UpdateArmedWaiting();   UpdatePanel(); return; }

   // PHASE_IDLE: look for a signal, then wait for its trigger price
   bool fridayCutoff=IsFridayCutoff();
   if(fridayCutoff && g_awaitingTrigger){ ResetSignal(); }

   if(!fridayCutoff && !g_awaitingTrigger && !AnyCascadePositionOpen() && !AnyCascadeOrderPending())
      CheckForNewSignal();

   if(g_awaitingTrigger)
   {
      if(iTime(_Symbol,InpTimeframe,0)!=g_triggerBarTime)
      {
         ResetSignal();   // trigger window is one bar
      }
      else if(!fridayCutoff
              && !HourCutoffBlocksNewTrades()
              && !DailyLimitBlocksNewTrades()
              && SpreadOK())
      {
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         if(g_signalDirection==1 && ask>=g_signalTrigger)
         {
            if(InpUseOriginMode) StartVirtualOrigin(1);
            else                 OpenRealDirect(1);
         }
         else if(g_signalDirection==-1 && bid<=g_signalTrigger)
         {
            if(InpUseOriginMode) StartVirtualOrigin(-1);
            else                 OpenRealDirect(-1);
         }
      }
   }
   UpdatePanel();
}

//====================================================================
// DIRECT OPEN (when InpUseOriginMode = false)
//====================================================================
void OpenRealDirect(int direction)
{
   if(!SpreadOK()){ ResetSignal(); return; }
   if(IsFridayCutoff()||HourCutoffBlocksNewTrades()||DailyLimitBlocksNewTrades()){ ResetSignal(); return; }

   double point=Pt();
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double entry=(direction==1?ask:bid);
   double sl=(direction==1 ? NP(g_signalStopRef-InpSLBufferPoints*point)
                           : NP(g_signalStopRef+InpSLBufferPoints*point));
   if((direction==1 && sl>=entry)||(direction==-1 && sl<=entry)){ ResetSignal(); return; }

   double risk=0;
   double lots=CalculateRiskCappedLot(direction,entry,sl,risk);
   if(lots<=0){ ResetSignal(); return; }
   double dist=MathAbs(entry-sl);
   double rr=InpEnableReverse?1.0:MathMax(0.1,InpManualRR);
   double tp=NP(direction==1?entry+dist*rr:entry-dist*rr);

   trade.SetExpertMagicNumber((int)InpMagicNumberA);
   trade.SetDeviationInPoints(InpSlippage);
   bool ok=(direction==1 ? trade.Buy (lots,_Symbol,0.0,sl,tp,"Direct-BUY")
                         : trade.Sell(lots,_Symbol,0.0,sl,tp,"Direct-SELL"));
   ResetSignal();
   if(!ok) return;

   ulong tk=FindPosition(InpMagicNumberA);
   if(tk==0 || !PositionSelectByTicket(tk)) return;

   g_phase=PHASE_REAL;
   g_realActive=true;
   g_consecutiveSL=0; g_reverseCount=0;
   g_currentTicket=tk;
   g_currentMagic=InpMagicNumberA;
   g_currentDirection=direction;
   g_currentEntry=PositionGetDouble(POSITION_PRICE_OPEN);
   g_currentSL=PositionGetDouble(POSITION_SL);
   g_currentTP=PositionGetDouble(POSITION_TP);
   g_currentLots=PositionGetDouble(POSITION_VOLUME);
   g_pendingMagic=InpMagicNumberB;

   if(InpEnableReverse && InpMaxReverseCount>0) PlaceRealReverse();
}
//+------------------------------------------------------------------+
