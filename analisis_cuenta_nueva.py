import MetaTrader5 as mt5
from datetime import datetime, timedelta

if not mt5.initialize(r"C:\Program Files\MetaTrader 5\terminal64.exe"):
    print("MT5 init failed:", mt5.last_error())
    raise SystemExit

acc = mt5.account_info()
print("=== CUENTA ===")
print(f"login={acc.login} server={acc.server} balance={acc.balance:.2f} equity={acc.equity:.2f}")
print(f"flotante={acc.profit:+.2f} margin_free={acc.margin_free:.2f} leverage={acc.leverage}")

pos = mt5.positions_get()
print(f"\n=== POSICIONES ABIERTAS: {len(pos) if pos else 0} ===")
if pos:
    for p in pos:
        side = "BUY" if p.type == 0 else "SELL"
        print(f"  {p.symbol} {side} lot={p.volume} entry={p.price_open:.2f} profit={p.profit:+.2f} magic={p.magic}")

# Historial: deals desde el inicio de la cuenta
print("\n=== HISTORIAL DE OPERACIONES ===")
from_d = datetime.now() - timedelta(days=120)
deals = mt5.history_deals_get(from_d, datetime.now())
if not deals:
    print("Sin deals en los ultimos 120 dias:", mt5.last_error())
    mt5.shutdown()
    raise SystemExit

# agrupar deals por posicion para reconstruir trades completos
from collections import defaultdict
by_pos = defaultdict(list)
for d in deals:
    if d.position_id:
        by_pos[d.position_id].append(d)

trades = []
for pid, ds in by_pos.items():
    ins = [d for d in ds if d.type in (0, 1)]
    outs = [d for d in ds if d.type in (2, 3)]
    if not ins:
        continue
    entry = ins[0]
    total = sum(d.profit for d in ds)
    closed = any(d.profit != 0 for d in ds)
    trades.append({
        "ticket": pid,
        "symbol": entry.symbol,
        "side": "BUY" if entry.type == 0 else "SELL",
        "volume": entry.volume,
        "magic": entry.magic,
        "open_time": datetime.fromtimestamp(entry.time),
        "close_time": datetime.fromtimestamp(max(d.time for d in ds)),
        "profit": total,
        "closed": closed,
        "reason": next((d.comment for d in outs), next((d.comment for d in ds), "")),
    })

trades.sort(key=lambda t: t["open_time"])
closed = [t for t in trades if t["closed"]]
wins = [t for t in closed if t["profit"] > 0]
losses = [t for t in closed if t["profit"] < 0]
be = [t for t in closed if t["profit"] == 0]

print(f"\nTrades totales (posiciones): {len(trades)} | Cerrados: {len(closed)}")
print(f"Periodo: {trades[0]['open_time']:%Y-%m-%d %H:%M} -> {trades[-1]['close_time']:%Y-%m-%d %H:%M}" if trades else "")
print(f"\n--- RESUMEN GENERAL ---")
print(f"Ganadores: {len(wins)} | Perdedores: {len(losses)} | Breakeven: {len(be)}")
print(f"Win rate: {len(wins)/len(closed)*100:.1f}%" if closed else "n/a")
gross_win = sum(t["profit"] for t in wins)
gross_loss = sum(t["profit"] for t in losses)
print(f"Ganancia bruta: +{gross_win:.2f} | Perdida bruta: {gross_loss:.2f}")
print(f"Neto: {gross_win+gross_loss:+.2f}")
print(f"Profit Factor: {gross_win/abs(gross_loss):.2f}" if gross_loss != 0 else "n/a")
print(f"Trade promedio: {(gross_win+gross_loss)/len(closed):+.2f}" if closed else "n/a")
print(f"Mejor trade: {max(t['profit'] for t in closed):+.2f} | Peor: {min(t['profit'] for t in closed):+.2f}")

print(f"\n--- POR SIMBOLO ---")
for sym in sorted(set(t["symbol"] for t in closed)):
    st = [t for t in closed if t["symbol"] == sym]
    w = [t for t in st if t["profit"] > 0]
    l = [t for t in st if t["profit"] < 0]
    gw = sum(t["profit"] for t in w)
    gl = sum(t["profit"] for t in l)
    print(f"{sym}: {len(st)} trades | WR {len(w)/len(st)*100:.1f}% | neto {gw+gl:+.2f} | PF {gw/abs(gl):.2f}" if gl else f"{sym}: {len(st)} trades | WR {len(w)/len(st)*100:.1f}% | neto {gw+gl:+.2f}")

print(f"\n--- POR MAGIC (estrategia) ---")
for mg in sorted(set(t["magic"] for t in closed)):
    st = [t for t in closed if t["magic"] == mg]
    w = [t for t in st if t["profit"] > 0]
    l = [t for t in st if t["profit"] < 0]
    gw = sum(t["profit"] for t in w)
    gl = sum(t["profit"] for t in l)
    syms = ",".join(sorted(set(t["symbol"] for t in st)))
    pf = f"{gw/abs(gl):.2f}" if gl else "inf"
    print(f"magic {mg} ({syms}): {len(st)} trades | WR {len(w)/len(st)*100:.1f}% | neto {gw+gl:+.2f} | PF {pf}")

print(f"\n--- ULTIMOS 10 TRADES ---")
for t in closed[-10:]:
    print(f"{t['close_time']:%m-%d %H:%M} {t['symbol']} {t['side']} vol={t['volume']} magic={t['magic']} pnl={t['profit']:+.2f} ({t['reason']})")

print(f"\n--- PNL POR DIA ---")
from collections import OrderedDict
by_day = OrderedDict()
for t in closed:
    d = t["close_time"].date()
    by_day.setdefault(d, 0.0)
    by_day[d] += t["profit"]
for d, pnl in by_day.items():
    print(f"{d}: {pnl:+.2f}")

# drawdown de la curva acumulada
print(f"\n--- DRAWDOWN (curva PnL acumulado) ---")
cum = 0.0
peak = 0.0
maxdd = 0.0
for t in closed:
    cum += t["profit"]
    if cum > peak:
        peak = cum
    dd = peak - cum
    if dd > maxdd:
        maxdd = dd
print(f"PnL acumulado max: {peak:+.2f} | Max drawdown: -{maxdd:.2f}")

mt5.shutdown()