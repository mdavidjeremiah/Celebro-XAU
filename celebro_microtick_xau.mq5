#property copyright "Original implementation"
#property version   "1.00"
#property strict
#property description "Retail MT5 XAUUSD microtick scalper. Validate in tester/demo before use."

#include <Trade/Trade.mqh>

input group "Safety and identity"
input bool   AllowLiveTrading=false;
input ulong  MagicNumber=26071801;
input string TradeComment="XAU-MicroTick";
input int    MaxDeviationPoints=20;

input group "Automatic lot sizing"
input double RiskPerTradePct=0.10;
input double MaxLot=1.00;
input double MinFreeMarginReservePct=50.0;
input bool   UseFixedLot=false;
input double FixedLot=0.01;

input group "Microtick engine"
input int    WarmupTicks=64;
input int    FeatureWindowTicks=32;
input int    FeedGapResetMs=5000;
input int    MaxTickAgeMs=1500;
input double MaxSpreadPoints=50.0;
input double MinTicksPerSecond=2.0;
input double MaxTicksPerSecond=80.0;
input double MinEfficiency=0.30;
input double ShockVelocityTicksPerSec=150.0;

input group "Signal scoring"
input double WeightVelocity=0.32;
input double WeightAcceleration=0.12;
input double WeightImbalance=0.24;
input double WeightRunPressure=0.14;
input double WeightEfficiency=0.18;
input double EntryScore=0.68;
input double ExitScore=0.15;
input double MinDirectionalEdge=0.22;
input int    ConfirmationTicks=3;

input group "Stops and management"
input int    StopLossPoints=180;
input int    TakeProfitPoints=120;
input bool   UseSignalExit=true;
input int    MaxHoldSeconds=120;
input int    BreakEvenTriggerPoints=70;
input int    BreakEvenLockPoints=10;
input int    TrailTriggerPoints=90;
input int    TrailDistancePoints=55;

input group "Frequency and loss controls"
input int    MinOrderIntervalMs=3000;
input int    MaxTradesPerMinute=3;
input int    MaxTradesPerDay=30;
input double DailyLossLimitPct=1.50;
input double PeakDrawdownLimitPct=4.00;
input double MaxFloatingLossPct=0.75;
input int    MaxConsecutiveLosses=3;
input int    LossCooldownMinutes=30;
input int    MaxRejectsBeforePause=3;
input int    RejectPauseMinutes=15;

input group "Trading session (server time)"
input int    SessionStartHour=7;
input int    SessionEndHour=20;
input bool   CloseAtSessionEnd=true;
input bool   FridayCutoff=true;
input int    FridayCutoffHour=18;

#define BUFFER_SIZE 256

struct TickSample
{
   long time_msc;
   double mid;
   double spread_pts;
};

CTrade trade;
TickSample ticks[BUFFER_SIZE];
int tick_head=0, tick_count=0;
long last_tick_msc=0, last_order_msc=0;
int long_confirm=0, short_confirm=0;
int trades_today=0, consecutive_losses=0, reject_count=0;
datetime day_anchor=0, cooldown_until=0, reject_pause_until=0;
double day_start_equity=0.0, peak_equity=0.0, daily_realized=0.0;
double long_score=0.0, short_score=0.0;
double f_velocity=0.0, f_accel=0.0, f_imbalance=0.0, f_run=0.0, f_efficiency=0.0, f_intensity=0.0;
double preview_lot=0.0, preview_risk=0.0, preview_margin=0.0;
string block_reason="Warming up";

int ClampInt(const int value,const int low,const int high) { return MathMax(low,MathMin(high,value)); }
double Clamp(const double value,const double low,const double high) { return MathMax(low,MathMin(high,value)); }
int IndexBack(const int back) { int i=tick_head-1-back; while(i<0) i+=BUFFER_SIZE; return i%BUFFER_SIZE; }

bool GoldLikeSymbol()
{
   string s=_Symbol;
   StringToUpper(s);
   return StringFind(s,"XAU")>=0 || StringFind(s,"GOLD")>=0;
}

void ResetTicks()
{
   tick_head=0; tick_count=0; long_confirm=0; short_confirm=0;
}

void PushTick(const MqlTick &tick)
{
   if(last_tick_msc>0 && tick.time_msc-last_tick_msc>FeedGapResetMs) ResetTicks();
   ticks[tick_head].time_msc=tick.time_msc;
   ticks[tick_head].mid=(tick.bid+tick.ask)*0.5;
   ticks[tick_head].spread_pts=(tick.ask-tick.bid)/_Point;
   tick_head=(tick_head+1)%BUFFER_SIZE;
   if(tick_count<BUFFER_SIZE) tick_count++;
   last_tick_msc=tick.time_msc;
}

bool BuildFeatures()
{
   int n=ClampInt(FeatureWindowTicks,8,BUFFER_SIZE-1);
   if(tick_count<MathMax(ClampInt(WarmupTicks,16,BUFFER_SIZE),n+2)) return false;
   TickSample newest=ticks[IndexBack(0)], oldest=ticks[IndexBack(n-1)];
   double elapsed=MathMax(0.001,(newest.time_msc-oldest.time_msc)/1000.0);
   double net=(newest.mid-oldest.mid)/_Point;
   double path=0.0; int up=0, down=0, run=0, run_sign=0;
   for(int i=0;i<n-1;i++)
   {
      double d=(ticks[IndexBack(i)].mid-ticks[IndexBack(i+1)].mid)/_Point;
      path+=MathAbs(d);
      int sign=(d>0)?1:((d<0)?-1:0);
      if(sign>0) up++; else if(sign<0) down++;
      if(i==0) { run_sign=sign; run=(sign==0?0:1); }
      else if(sign==run_sign && sign!=0) run++; else if(run_sign==0 && sign!=0) { run_sign=sign; run=1; }
   }
   double recent_dt=MathMax(0.001,(ticks[IndexBack(0)].time_msc-ticks[IndexBack(3)].time_msc)/1000.0);
   double recent_velocity=((ticks[IndexBack(0)].mid-ticks[IndexBack(3)].mid)/_Point)/recent_dt;
   double prior_dt=MathMax(0.001,(ticks[IndexBack(3)].time_msc-ticks[IndexBack(6)].time_msc)/1000.0);
   double prior_velocity=((ticks[IndexBack(3)].mid-ticks[IndexBack(6)].mid)/_Point)/prior_dt;
   f_velocity=Clamp(recent_velocity/60.0,-1.0,1.0);
   f_accel=Clamp((recent_velocity-prior_velocity)/100.0,-1.0,1.0);
   f_imbalance=(double)(up-down)/MathMax(1,up+down);
   f_run=Clamp((double)(run*run_sign)/8.0,-1.0,1.0);
   f_efficiency=(path>0.0)?Clamp(MathAbs(net)/path,0.0,1.0):0.0;
   f_intensity=(n-1)/elapsed;
   double directional=WeightVelocity*f_velocity+WeightAcceleration*f_accel+WeightImbalance*f_imbalance+WeightRunPressure*f_run;
   double quality=WeightEfficiency*f_efficiency;
   long_score=Clamp(directional+quality,0.0,1.0);
   short_score=Clamp(-directional+quality,0.0,1.0);
   return true;
}

void ResetDailyIfNeeded()
{
   MqlDateTime now; TimeToStruct(TimeCurrent(),now);
   datetime today=StringToTime(StringFormat("%04d.%02d.%02d 00:00",now.year,now.mon,now.day));
   if(today!=day_anchor)
   {
      day_anchor=today; day_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);
      peak_equity=day_start_equity; daily_realized=0.0; trades_today=0; consecutive_losses=0;
   }
   peak_equity=MathMax(peak_equity,AccountInfoDouble(ACCOUNT_EQUITY));
}

bool SessionAllowed()
{
   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   if(FridayCutoff && t.day_of_week==5 && t.hour>=FridayCutoffHour) return false;
   if(t.day_of_week==0 || t.day_of_week==6) return false;
   if(SessionStartHour==SessionEndHour) return true;
   if(SessionStartHour<SessionEndHour) return t.hour>=SessionStartHour && t.hour<SessionEndHour;
   return t.hour>=SessionStartHour || t.hour<SessionEndHour;
}

bool SelectOurPosition(ulong &ticket)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong id=PositionGetTicket(i);
      if(id>0 && PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber)
      { ticket=id; return true; }
   }
   ticket=0; return false;
}

int CountRecentEntries(const int seconds)
{
   datetime from=TimeCurrent()-seconds;
   if(!HistorySelect(from,TimeCurrent())) return 0;
   int count=0;
   for(int i=HistoryDealsTotal()-1;i>=0;i--)
   {
      ulong d=HistoryDealGetTicket(i);
      if(d>0 && HistoryDealGetString(d,DEAL_SYMBOL)==_Symbol && (ulong)HistoryDealGetInteger(d,DEAL_MAGIC)==MagicNumber && (ENUM_DEAL_ENTRY)HistoryDealGetInteger(d,DEAL_ENTRY)==DEAL_ENTRY_IN) count++;
   }
   return count;
}

bool RiskGate()
{
   ResetDailyIfNeeded();
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double daily_loss=MathMax(0.0,day_start_equity-equity);
   double dd=MathMax(0.0,peak_equity-equity);
   if(day_start_equity>0 && daily_loss/day_start_equity*100.0>=DailyLossLimitPct) { block_reason="Daily loss lock"; return false; }
   if(peak_equity>0 && dd/peak_equity*100.0>=PeakDrawdownLimitPct) { block_reason="Peak drawdown lock"; return false; }
   if(AccountInfoDouble(ACCOUNT_PROFIT)<-equity*MaxFloatingLossPct/100.0) { block_reason="Floating loss lock"; return false; }
   if(TimeCurrent()<cooldown_until) { block_reason="Loss cooldown"; return false; }
   if(TimeCurrent()<reject_pause_until) { block_reason="Execution pause"; return false; }
   if(trades_today>=MaxTradesPerDay) { block_reason="Daily trade cap"; return false; }
   return true;
}

bool CalculateVolume(const ENUM_ORDER_TYPE type,const double entry,const double sl,double &volume,double &risk_money,double &margin)
{
   volume=0; risk_money=0; margin=0;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double budget=equity*RiskPerTradePct/100.0;
   double one_lot_loss=0;
   if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,one_lot_loss)) { block_reason="OrderCalcProfit failed"; return false; }
   one_lot_loss=MathAbs(one_lot_loss);
   if(one_lot_loss<=0 || budget<=0) { block_reason="Invalid risk calculation"; return false; }
   double minlot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxlot=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),MaxLot);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double raw=UseFixedLot?FixedLot:(budget/one_lot_loss);
   volume=MathFloor(raw/step+1e-9)*step;
   volume=MathMin(volume,maxlot);
   int digits=(step>=1.0)?0:(step>=0.1?1:(step>=0.01?2:3));
   volume=NormalizeDouble(volume,digits);
   if(volume<minlot) { block_reason="Risk budget below minimum lot"; return false; }
   risk_money=one_lot_loss*volume;
   if(!UseFixedLot && risk_money>budget*1.001) { block_reason="Normalized lot exceeds risk"; return false; }
   if(!OrderCalcMargin(type,_Symbol,volume,entry,margin)) { block_reason="OrderCalcMargin failed"; return false; }
   double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free_margin-margin<equity*MinFreeMarginReservePct/100.0) { block_reason="Free-margin reserve"; return false; }
   return true;
}

bool PreEntryGate(const MqlTick &tick)
{
   if(!AllowLiveTrading) { block_reason="DISARMED: AllowLiveTrading=false"; return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) { block_reason="Algo trading disabled"; return false; }
   if(!SessionAllowed()) { block_reason="Outside session"; return false; }
   if(!RiskGate()) return false;
   if((TimeCurrent()*1000-last_order_msc)<MinOrderIntervalMs) { block_reason="Order refractory"; return false; }
   if(CountRecentEntries(60)>=MaxTradesPerMinute) { block_reason="Minute trade cap"; return false; }
   if((TimeCurrent()*1000-tick.time_msc)>MaxTickAgeMs) { block_reason="Stale tick"; return false; }
   if((tick.ask-tick.bid)/_Point>MaxSpreadPoints) { block_reason="Spread gate"; return false; }
   if(f_intensity<MinTicksPerSecond || f_intensity>MaxTicksPerSecond) { block_reason="Intensity gate"; return false; }
   if(f_efficiency<MinEfficiency) { block_reason="Noise gate"; return false; }
   double raw_velocity=f_velocity*60.0;
   if(MathAbs(raw_velocity)>ShockVelocityTicksPerSec) { block_reason="Shock gate"; return false; }
   ulong ticket; if(SelectOurPosition(ticket)) { block_reason="Position active"; return false; }
   return true;
}

void RecordReject()
{
   reject_count++;
   if(reject_count>=MaxRejectsBeforePause) { reject_pause_until=TimeCurrent()+RejectPauseMinutes*60; reject_count=0; }
}

void TryEntry(const bool buy,const MqlTick &tick)
{
   ENUM_ORDER_TYPE type=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double entry=buy?tick.ask:tick.bid;
   int stops=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double sl_points=MathMax(StopLossPoints,stops+2);
   double tp_points=MathMax(TakeProfitPoints,stops+2);
   double sl=NormalizeDouble(buy?entry-sl_points*_Point:entry+sl_points*_Point,_Digits);
   double tp=NormalizeDouble(buy?entry+tp_points*_Point:entry-tp_points*_Point,_Digits);
   if(!CalculateVolume(type,entry,sl,preview_lot,preview_risk,preview_margin)) return;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   bool sent=buy?trade.Buy(preview_lot,_Symbol,0,sl,tp,TradeComment):trade.Sell(preview_lot,_Symbol,0,sl,tp,TradeComment);
   last_order_msc=TimeCurrent()*1000;
   if(!sent || (trade.ResultRetcode()!=TRADE_RETCODE_DONE && trade.ResultRetcode()!=TRADE_RETCODE_PLACED && trade.ResultRetcode()!=TRADE_RETCODE_DONE_PARTIAL))
   {
      PrintFormat("ENTRY_REJECT side=%s retcode=%u description=%s",buy?"BUY":"SELL",trade.ResultRetcode(),trade.ResultRetcodeDescription());
      block_reason="Entry rejected"; RecordReject(); return;
   }
   reject_count=0; trades_today++; block_reason="Entry accepted"; long_confirm=0; short_confirm=0;
}

void ManagePosition(const MqlTick &tick)
{
   ulong ticket; if(!SelectOurPosition(ticket)) return;
   ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double open=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
   datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
   double current=(type==POSITION_TYPE_BUY)?tick.bid:tick.ask;
   double profit_pts=(type==POSITION_TYPE_BUY)?(current-open)/_Point:(open-current)/_Point;
   bool exit_signal=UseSignalExit && ((type==POSITION_TYPE_BUY && long_score<ExitScore && short_score>long_score) || (type==POSITION_TYPE_SELL && short_score<ExitScore && long_score>short_score));
   if(exit_signal || (MaxHoldSeconds>0 && TimeCurrent()-opened>=MaxHoldSeconds) || (!SessionAllowed() && CloseAtSessionEnd))
   {
      if(!trade.PositionClose(ticket,MaxDeviationPoints)) PrintFormat("CLOSE_REJECT retcode=%u %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
      else last_order_msc=TimeCurrent()*1000;
      return;
   }
   double candidate=sl;
   if(profit_pts>=BreakEvenTriggerPoints)
      candidate=(type==POSITION_TYPE_BUY)?open+BreakEvenLockPoints*_Point:open-BreakEvenLockPoints*_Point;
   if(profit_pts>=TrailTriggerPoints)
   {
      double trail=(type==POSITION_TYPE_BUY)?current-TrailDistancePoints*_Point:current+TrailDistancePoints*_Point;
      if(type==POSITION_TYPE_BUY) candidate=MathMax(candidate,trail);
      else candidate=(candidate==0)?trail:MathMin(candidate,trail);
   }
   candidate=NormalizeDouble(candidate,_Digits);
   bool improve=(type==POSITION_TYPE_BUY && candidate>sl && candidate<tick.bid) || (type==POSITION_TYPE_SELL && candidate>tick.ask && (sl==0 || candidate<sl));
   if(improve && !trade.PositionModify(ticket,candidate,tp)) PrintFormat("MODIFY_REJECT retcode=%u %s",trade.ResultRetcode(),trade.ResultRetcodeDescription());
}

void UpdatePanel(const MqlTick &tick)
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double effrisk=(equity>0)?preview_risk/equity*100.0:0.0;
   string state=AllowLiveTrading?"ARMED":"DISARMED";
   Comment(StringFormat("XAU MicroTick EA | %s\nBlock: %s\nL %.2f | S %.2f | Edge %.2f\nVel %.2f | Acc %.2f | Imb %.2f | Run %.2f\nEfficiency %.2f | Intensity %.1f/s | Spread %.1f\nAuto lot %.2f | Risk %.2f (%.3f%%) | Margin %.2f\nTrades today %d | Daily P/L %.2f | Consecutive losses %d",
      state,block_reason,long_score,short_score,MathAbs(long_score-short_score),f_velocity,f_accel,f_imbalance,f_run,f_efficiency,f_intensity,(tick.ask-tick.bid)/_Point,preview_lot,preview_risk,effrisk,preview_margin,trades_today,daily_realized,consecutive_losses));
}

int OnInit()
{
   if(!GoldLikeSymbol()) { Print("Attach this EA to an XAU/GOLD symbol."); return INIT_FAILED; }
   if(RiskPerTradePct<=0 || RiskPerTradePct>5 || MaxLot<=0 || StopLossPoints<=0 || ConfirmationTicks<1) return INIT_PARAMETERS_INCORRECT;
   if(WarmupTicks>BUFFER_SIZE || FeatureWindowTicks>=BUFFER_SIZE) return INIT_PARAMETERS_INCORRECT;
   trade.SetExpertMagicNumber(MagicNumber); trade.SetTypeFillingBySymbol(_Symbol); trade.SetAsyncMode(false);
   ResetDailyIfNeeded(); ResetTicks();
   Print("XAU MicroTick EA initialized. Live execution is ",AllowLiveTrading?"ARMED":"DISARMED", ". No profitability is guaranteed.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { Comment(""); }

void OnTick()
{
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   if(tick.bid<=0 || tick.ask<=tick.bid || tick.time_msc<=last_tick_msc) return;
   PushTick(tick); ResetDailyIfNeeded();
   bool ready=BuildFeatures();
   ManagePosition(tick);
   if(!ready) { block_reason="Warming up"; UpdatePanel(tick); return; }
   if(long_score>=EntryScore && long_score-short_score>=MinDirectionalEdge) { long_confirm++; short_confirm=0; }
   else if(short_score>=EntryScore && short_score-long_score>=MinDirectionalEdge) { short_confirm++; long_confirm=0; }
   else { long_confirm=0; short_confirm=0; }
   if(PreEntryGate(tick))
   {
      block_reason="Signal pending";
      if(long_confirm>=ConfirmationTicks) TryEntry(true,tick);
      else if(short_confirm>=ConfirmationTicks) TryEntry(false,tick);
   }
   UpdatePanel(tick);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol || (ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=MagicNumber) return;
   ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
   {
      double pnl=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+HistoryDealGetDouble(trans.deal,DEAL_SWAP)+HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
      daily_realized+=pnl;
      if(pnl<0) { consecutive_losses++; if(consecutive_losses>=MaxConsecutiveLosses) cooldown_until=TimeCurrent()+LossCooldownMinutes*60; }
      else if(pnl>0) consecutive_losses=0;
      PrintFormat("TRADE_CLOSED deal=%I64u pnl=%.2f consecutive_losses=%d",trans.deal,pnl,consecutive_losses);
   }
}

double OnTester()
{
   double trades=TesterStatistics(STAT_TRADES);
   double profit=TesterStatistics(STAT_PROFIT);
   double dd=TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double pf=TesterStatistics(STAT_PROFIT_FACTOR);
   if(trades<50 || dd>15.0 || profit<=0 || pf<=1.0) return -1.0;
   return (profit*pf*MathSqrt(trades))/(1.0+dd*dd);
}
