import time
import csv
from datetime import datetime, timedelta
from pathlib import Path

import MetaTrader5 as mt5

CONFIG = {
    "symbol": "BTCUSDm",
    "timeframe": mt5.TIMEFRAME_H2,
    "fixed_lot": 1.0,  # Lote fijo de 1.0 para BTCUSDm
    "sl_atr_mult": 2.0,
    "tp_atr_mult": 4.0,
    "atr_period": 14,
    "max_positions": 1,
    "max_daily_trades": 10,
    "max_daily_drawdown_pct": 10.0,
    "trades_csv": "trades_btc_h2.csv",
    "signals_csv": "signals_btc_h2.csv",
    "magic": 20260811,
}

TRADES_COLUMNS = ["ticket", "symbol", "type", "volume", "open_time", "open_price",
                  "sl", "tp", "close_time", "close_price", "profit", "status"]
SIGNALS_COLUMNS = ["time", "price", "vwap", "adx", "signal"]


def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(msg):
    print(f"[{now()}] {msg}", flush=True)


def load_csv(path):
    if not Path(path).exists():
        return []
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def save_csv(path, rows, columns):
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def adx(high, low, close, period=14):
    h = high.values if hasattr(high, "values") else high
    l = low.values if hasattr(low, "values") else low
    c = close.values if hasattr(close, "values") else close
    n = len(c)
    plus_dm = [0.0] * n
    minus_dm = [0.0] * n
    tr = [0.0] * n
    for i in range(1, n):
        up = h[i] - h[i-1]
        down = l[i-1] - l[i]
        plus_dm[i] = up if up > down and up > 0 else 0.0
        minus_dm[i] = down if down > up and down > 0 else 0.0
        tr[i] = max(h[i] - l[i], abs(h[i] - c[i-1]), abs(l[i] - c[i-1]))

    def smooth(vals):
        out = [0.0] * len(vals)
        if len(vals) < period:
            return out
        out[period-1] = sum(vals[:period])
        for i in range(period, len(vals)):
            out[i] = out[i-1] - (out[i-1] / period) + vals[i]
        return out

    s_tr = smooth(tr)
    s_plus = smooth(plus_dm)
    s_minus = smooth(minus_dm)
    dx = [0.0] * n
    atr = [0.0] * n
    for i in range(n):
        if s_tr[i] > 0:
            atr[i] = s_tr[i] / period
            p_di = 100 * s_plus[i] / s_tr[i]
            m_di = 100 * s_minus[i] / s_tr[i]
            if (p_di + m_di) > 0:
                dx[i] = 100 * abs(p_di - m_di) / (p_di + m_di)
    s_dx = smooth(dx)
    adx_out = [0.0] * n
    for i in range(n):
        adx_out[i] = s_dx[i] / period if i >= period else 0.0
    return adx_out, atr


def close_hist(symbol, magic):
    start = datetime.now() - timedelta(days=2)
    deals = mt5.history_deals_get(start, datetime.now()) or []
    closed = {}
    for d in deals:
        if (d.symbol == symbol and d.magic == magic
                and d.entry == mt5.DEAL_ENTRY_OUT):
            closed[d.position_id] = d
    return closed


def main():
    if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
        log(f"ERROR: no se pudo iniciar MT5: {mt5.last_error()}")
        return

    account = mt5.account_info()
    if account is None:
        log("ERROR: cuenta no conectada.")
        return
    log(f"Bot BTC H2 Live LOT 1.0 | Cuenta: {account.login} | Balance: {account.balance:.2f} USD")

    sym = mt5.symbol_info(CONFIG["symbol"])
    if sym is None:
        log(f"ERROR: símbolo {CONFIG['symbol']} no encontrado")
        return
    mt5.symbol_select(CONFIG["symbol"], True)

    digits = sym.digits
    trades = load_csv(CONFIG["trades_csv"])
    signals = load_csv(CONFIG["signals_csv"])
    last_candle_time = 0

    log(f"Operando {CONFIG['symbol']} en H2 | Lote fijo: {CONFIG['fixed_lot']} lotes")

    try:
        while True:
            account = mt5.account_info()
            if account is None:
                time.sleep(15)
                continue

            closed = close_hist(CONFIG["symbol"], CONFIG["magic"])
            open_pos = mt5.positions_get(symbol=CONFIG["symbol"]) or []
            open_tickets = {p.ticket for p in open_pos}
            changed = False
            for t in trades:
                if t["status"] == "OPEN":
                    ticket = int(t["ticket"])
                    if ticket in closed:
                        d = closed[ticket]
                        t["close_time"] = now()
                        t["close_price"] = f"{d.price}"
                        t["profit"] = f"{d.profit + d.commission + d.swap:.2f}"
                        t["status"] = "CLOSED"
                        changed = True
                        log(f"Trade cerrado BTC H2 #{ticket} | P&L: {t['profit']} USD")
            if changed:
                save_csv(CONFIG["trades_csv"], trades, TRADES_COLUMNS)

            rates = mt5.copy_rates_from_pos(CONFIG["symbol"], CONFIG["timeframe"], 0, 100)
            if rates is None or len(rates) < 30:
                time.sleep(10)
                continue

            candle_time = int(rates[-1]["time"])
            if candle_time == last_candle_time:
                time.sleep(15)
                continue
            last_candle_time = candle_time

            import pandas as pd
            import numpy as np
            df = pd.DataFrame(rates)
            df["time"] = pd.to_datetime(df["time"], unit="s")
            df = df.set_index("time")
            df["tp"] = (df["high"] + df["low"] + df["close"]) / 3
            df["tv"] = 1.0
            df["vwap"] = (df["tp"] * df["tv"]).groupby(df.index.date).cumsum() / df["tv"].groupby(df.index.date).cumsum()
            dx, atr_arr = adx(df["high"], df["low"], df["close"], CONFIG["atr_period"])
            df["adx"] = dx
            df["atr"] = atr_arr

            row = df.iloc[-1]
            prev = df.iloc[-2]
            price_now = row["close"]
            vwap = row["vwap"]
            adx_val = row["adx"]
            atr_val = row["atr"]

            good_adx = not np.isnan(adx_val) and adx_val >= 22
            signal = None
            if good_adx:
                if price_now > vwap and prev["close"] <= prev["vwap"]:
                    signal = "BUY"
                elif price_now < vwap and prev["close"] >= prev["vwap"]:
                    signal = "SELL"

            candle_iso = datetime.fromtimestamp(candle_time).strftime("%Y-%m-%d %H:%M")
            signals.append({"time": candle_iso, "price": f"{price_now:.2f}",
                            "vwap": f"{vwap:.2f}", "adx": f"{adx_val:.1f}",
                            "signal": signal or "NONE"})
            save_csv(CONFIG["signals_csv"], signals, SIGNALS_COLUMNS)

            if signal is None:
                log(f"{candle_iso} | BTC H2 | Precio: {price_now:.2f} | VWAP: {vwap:.1f} | ADX: {adx_val:.1f} | Buscando entrada 1.0 lote")
                continue

            if open_tickets:
                log(f"{candle_iso} | Señal BTC {signal} pero ya hay posición abierta.")
                continue

            sl_dist = CONFIG["sl_atr_mult"] * atr_val
            if sl_dist <= 0:
                continue
            lot = CONFIG["fixed_lot"]

            tick = mt5.symbol_info_tick(CONFIG["symbol"])
            price = tick.ask if signal == "BUY" else tick.bid
            sl = price - sl_dist if signal == "BUY" else price + sl_dist
            tp = price + CONFIG["tp_atr_mult"] * atr_val if signal == "BUY" else price - CONFIG["tp_atr_mult"] * atr_val

            request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": CONFIG["symbol"],
                "volume": lot,
                "type": mt5.ORDER_TYPE_BUY if signal == "BUY" else mt5.ORDER_TYPE_SELL,
                "price": price,
                "sl": round(sl, digits),
                "tp": round(tp, digits),
                "deviation": 30,
                "magic": CONFIG["magic"],
                "comment": "btc_h2_lot_1.0",
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": mt5.ORDER_FILLING_IOC,
            }

            result = mt5.order_send(request)
            if result is None or result.retcode != mt5.TRADE_RETCODE_DONE:
                log(f"ERROR orden BTC: {result.retcode if result else mt5.last_error()}")
                continue

            trades.append({"ticket": str(result.order), "symbol": CONFIG["symbol"],
                           "type": signal, "volume": str(lot),
                           "open_time": now(), "open_price": f"{price}",
                           "sl": str(request["sl"]), "tp": str(request["tp"]),
                           "close_time": "", "close_price": "", "profit": "", "status": "OPEN"})
            save_csv(CONFIG["trades_csv"], trades, TRADES_COLUMNS)
            log(f"¡ORDEN BTC H2 1.0 LOTE EJECUTADA! {signal} | Precio: {price} | SL: {request['sl']} | TP: {request['tp']}")

    except KeyboardInterrupt:
        log("Bot BTC detenido.")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
