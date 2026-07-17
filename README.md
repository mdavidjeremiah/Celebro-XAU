# celebro_microtick_xau

`celebro_microtick_xau` is an original MetaTrader 5 Expert Advisor for XAUUSD scalping. It derives short-horizon signals from broker tick activity and includes automatic risk-based lot sizing, broker-side stops, execution filters, and account protection controls.

> **Risk warning:** This software can place live trades and can lose money rapidly. It does not guarantee profitability. Backtest with real ticks, perform out-of-sample validation, and run on a demo account before considering live use.

## Files

- `XAU_MicroTick_EA.mq5` — Expert Advisor source.
- `XAU_MicroTick_Tester.set` — Strategy Tester optimization preset.
- `XAU_MicroTick_Live_Conservative.set` — conservative preset; live execution remains disarmed.

You may rename the source to `celebro_microtick_xau.mq5` before compiling so the MT5 Navigator displays the chosen EA name.

## Microtick engine

The EA maintains a fixed-size rolling tick buffer and evaluates:

- normalized short-horizon velocity and acceleration;
- uptick/down-tick imbalance;
- directional run pressure;
- path efficiency;
- tick intensity and spread;
- stale-feed, feed-gap, noise, and price-shock conditions.

Weighted long and short scores must pass the entry threshold, directional-edge requirement, and confirmation-tick count. These features are retail broker tick proxies—not exchange order-book data or true institutional HFT infrastructure.

## Automatic lot sizing

Automatic sizing is enabled by default with `UseFixedLot=false`. Before each entry, the EA:

1. Calculates the configured risk budget from current account equity and `RiskPerTradePct`.
2. Uses the planned stop-loss price and `OrderCalcProfit` to estimate the loss for one lot.
3. Derives and rounds volume downward to the broker lot step.
4. Applies the broker minimum/maximum and `MaxLot` hard cap.
5. Uses `OrderCalcMargin` and enforces `MinFreeMarginReservePct`.
6. Skips the trade if the broker minimum lot would exceed the risk budget.

The chart panel displays calculated volume, monetary risk, effective equity-risk percentage, and estimated margin. `UseFixedLot` is provided only for controlled testing and is disabled by default; the EA contains no martingale or loss-recovery multiplier.

## Installation

1. Open **File → Open Data Folder** in MetaTrader 5.
2. Copy or rename `XAU_MicroTick_EA.mq5` to `MQL5/Experts/celebro_microtick_xau.mq5`.
3. Open the file in MetaEditor and compile it.
4. Copy the `.set` files to `MQL5/Profiles/Tester` or load them directly from the EA inputs dialog.
5. Refresh the MT5 Navigator and attach `celebro_microtick_xau` only to your broker's XAU/GOLD chart.

Broker symbols with suffixes, such as `XAUUSD.a`, are accepted because the EA checks for `XAU` or `GOLD` in the chart symbol.

## Validation workflow

1. In Strategy Tester, select **Every tick based on real ticks**.
2. Load `XAU_MicroTick_Tester.set`.
3. Verify the broker's point size, spread behavior, stop level, commission, swap, and trading sessions.
4. Test across multiple market regimes and reserve unseen dates for out-of-sample evaluation.
5. Reject configurations with inadequate trade counts, unstable results, excessive drawdown, or dependence on a narrow date range.
6. Forward-test the selected configuration on a demo account under realistic latency and spread conditions.

The custom tester score rejects runs with fewer than 50 trades, non-positive profit, profit factor at or below 1, or relative equity drawdown above 15%. Passing that filter is not evidence that a configuration will remain profitable.

## Live arming

The EA defaults to:

```text
AllowLiveTrading=false
```

For a conservative baseline, load `XAU_MicroTick_Live_Conservative.set`; it also remains disarmed. Review every input first, enable MT5 Algo Trading, and set `AllowLiveTrading=true` manually only after testing. The account holder is solely responsible for broker compatibility and all resulting trades.

## Safety controls

- One EA position per symbol and magic number.
- Broker-side stop loss and take profit on entry.
- Break-even, trailing-stop, signal-exit, and maximum-hold management.
- Spread, tick-age, intensity, efficiency, and shock gates.
- Minimum order interval and per-minute/per-day trade caps.
- Daily equity-loss, peak-equity drawdown, and floating-loss locks.
- Consecutive-loss cooldown and execution-rejection pause.
- Server-time trading session, weekend block, and Friday cutoff.
- Free-margin reserve and maximum-lot cap.

## Important configuration notes

- All point-based inputs use the broker's `_Point`; they are not automatically dollar distances.
- Session inputs use broker server time.
- `MagicNumber` should be unique when running other EAs or multiple configurations.
- Daily counters are maintained while the EA instance is running and reset at the broker's server-day boundary.
- Removing or restarting the EA resets its in-memory tick buffer and runtime counters.
- `TradeComment` can be changed to identify this strategy in account history.

## Disclaimer

This project is provided for research and educational use. It is not financial advice, a solicitation, or a promise of returns. High-frequency-style execution on retail MT5 is constrained by broker latency, spreads, slippage, liquidity, execution rules, and hardware/network conditions.
