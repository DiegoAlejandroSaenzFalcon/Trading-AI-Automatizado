import MetaTrader5 as mt5
if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("init failed", mt5.last_error())
    raise SystemExit
acc = mt5.account_info()
print(f"Cuenta: {acc.login} {acc.server} balance={acc.balance}")
pos = mt5.positions_get()
print(f"Posiciones: {len(pos) if pos else 0}")
for p in (pos or []):
    side = "BUY" if p.type == 0 else "SELL"
    print(f"  {p.symbol} {side} lot={p.volume} magic={p.magic} profit={p.profit:+.2f}")
mt5.shutdown()
