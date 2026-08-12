import datetime
import numpy as np
import pandas as pd
import MetaTrader5 as mt5


def run_fvg_backtest():
    if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
        print("MT5 init failed")
        return

    end = datetime.datetime.now()
    start = end - datetime.timedelta(days=120)
    rates = mt5.copy_rates_range("BTCUSDm", mt5.TIMEFRAME_M15, start, end)
    mt5.shutdown()

    if rates is None or len(rates) == 0:
        print("No rates found for BTCUSDm M15")
        return

    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df = df.set_index("time")

    # Indicadores
    df["tr"] = np.maximum(
        df["high"] - df["low"],
        np.maximum(
            abs(df["high"] - df["close"].shift(1)),
            abs(df["low"] - df["close"].shift(1))
        )
    )
    df["atr"] = df["tr"].rolling(14).mean()
    df["macro_ema"] = df["close"].ewm(span=50).mean()

    trades = []
    pos = None

    for i in range(50, len(df)):
        row = df.iloc[i]
        prev = df.iloc[i-1]
        p2 = df.iloc[i-2]

        if pos is not None:
            # Gestionar salida SL / TP
            ep = None
            if pos["side"] == 1:
                if row["low"] <= pos["sl"]:
                    ep = pos["sl"]
                elif row["high"] >= pos["tp"]:
                    ep = pos["tp"]
            else:
                if row["high"] >= pos["sl"]:
                    ep = pos["sl"]
                elif row["low"] <= pos["tp"]:
                    ep = pos["tp"]

            if ep is not None:
                pnl = (ep - pos["entry"]) * pos["lot"] if pos["side"] == 1 else (pos["entry"] - ep) * pos["lot"]
                pnl -= 1.5 * pos["lot"]  # Coste de spread simulado ($15 por 1 lote)
                trades.append({"pnl": pnl, "win": pnl > 0})
                pos = None
            continue

        # Detección de FVG (Fair Value Gap alcista / bajista)
        # Alcista: low[0] > high[2]
        # Bajista: high[0] < low[2]
        fvg_buy = row["low"] > p2["high"]
        fvg_sell = row["high"] < p2["low"]

        macro_bull = row["close"] > row["macro_ema"]

        side = None
        if fvg_buy and macro_bull:
            side = 1
        elif fvg_sell and not macro_bull:
            side = -1

        if side is None:
            continue

        entry = row["close"]
        atr = row["atr"]
        if np.isnan(atr) or atr <= 0:
            continue

        sl_dist = 1.5 * atr
        tp_dist = 3.0 * atr
        lot = 1.0  # Lote fijo de 1.0 solicitado

        pos = {
            "side": side,
            "entry": entry,
            "sl": entry - sl_dist if side == 1 else entry + sl_dist,
            "tp": entry + tp_dist if side == 1 else entry - tp_dist,
            "lot": lot
        }

    if not trades:
        print("Sin trades generados.")
        return

    tdf = pd.DataFrame(trades)
    wins = tdf[tdf["win"]]
    losses = tdf[~tdf["win"]]
    total_pnl = tdf["pnl"].sum()
    win_rate = len(wins) / len(tdf) * 100
    pf = wins["pnl"].sum() / abs(losses["pnl"].sum()) if len(losses) > 0 else np.inf
    cum = tdf["pnl"].cumsum()
    max_dd = (cum - cum.cummax()).min()

    print(f"=== BACKTEST FVG (Pure Fractal Style) BTCUSDm M15 (Lote 1.0, 120 días) ===")
    print(f"Total Trades: {len(tdf)}")
    print(f"Win Rate: {win_rate:.1f}%")
    print(f"P&L Neto: ${total_pnl:,.2f} USD")
    print(f"Profit Factor: {pf:.2f}")
    print(f"Max Drawdown: ${max_dd:,.2f} USD")


if __name__ == "__main__":
    run_fvg_backtest()
