import re, collections, datetime, csv

LOG = r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075\Agent-127.0.0.1-3001\logs\20260812.log"
OUT = r"C:\Users\H2R\Documents\Default Project\backtests\v11_btc_lote10"
DEPOSIT = 100000.0
LOT = 10.0
CONTRACT = 1.0

def pnl_fn(en, cl, side): return (cl-en)*LOT*CONTRACT if side=="buy" else (en-cl)*LOT*CONTRACT
def T(s): return datetime.datetime(int(s[0:4]), int(s[5:7]), int(s[8:10]), int(s[11:13]), int(s[14:16]), int(s[17:19]))

re_dt = re.compile(r"(\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2})")
re_deal = re.compile(r"deal #(\d+) (buy|sell) ([\d.]+) (\S+) at ([\d.]+) done")
re_trig = re.compile(r"(stop loss|take profit) triggered #(\d+) (buy|sell) ([\d.]+) (\S+) ([\d.]+) sl: ([\d.]+) tp: ([\d.]+) \[#(\d+) (buy|sell) ([\d.]+) (\S+) at ([\d.]+)\]")
re_mclose = re.compile(r"market (buy|sell) ([\d.]+) (\S+), close #(\d+) \(([\d.]+) / ([\d.]+)")

deal_n = {}; closing_ids = set(); closes = {}


def parse():
    global deal_n, closes
    sl_lin = re.compile(r"stop loss triggered #(\d+)")
    for line in open(LOG, encoding="utf-16", errors="replace"):
        m = re_dt.search(line)
        if not m:
            continue
        t = T(m.group(1))
        d = re_deal.search(line)
        if d:
            did, dside, dl, dsym, dp = d.groups()
            deal_n[int(did)] = (dside, float(dp), t)
            continue
        tg = re_trig.search(line)
        if tg:
            reason, oid, side, lot, sym, entry, sl, tp, cd, cs, cl_, csym, cp = tg.groups()
            oid = int(oid); cd = int(cd)
            closing_ids.add(cd)
            closes[oid] = ("TP" if reason == "take profit" else "SL", float(cp), t)
            continue
        mc = re_mclose.search(line)
        if mc:
            cs_, lot, sym, oid, bid, ask = mc.groups()
            closes[int(oid)] = ("MARKET", float(ask if cs_ == "buy" else bid), t)

parse()
opens = {oid: info for oid, info in deal_n.items() if oid not in closing_ids}

trades = []
for oid, (side, entry, t_open) in opens.items():
    if oid in closes:
        reason, close, t_close = closes[oid]
        trades.append(dict(id=oid, side=side, entry=entry, t_open=t_open, t_close=t_close,
                           close=close, reason=reason,
                           pnl=pnl_fn(entry, close, side),
                           hold_min=(t_close - t_open).total_seconds() / 60))

trades.sort(key=lambda x: x["id"])

bal = DEPOSIT; eq = [(trades[0]["t_open"], DEPOSIT)] if trades else []
ws = 0; ls = 0; maxws = 0; maxls = 0; monthly = collections.OrderedDict()
for tr in trades:
    bal += tr["pnl"]; eq.append((tr["t_close"], bal))
    tr["balance"] = bal
    ws = ws + 1 if tr["pnl"] > 0 else 0
    ls = ls + 1 if tr["pnl"] <= 0 else 0
    maxws = max(maxws, ws); maxls = max(maxls, ls)
    k = (tr["t_close"].year, tr["t_close"].month)
    monthly[k] = monthly.get(k, 0.0) + tr["pnl"]

wins = [t for t in trades if t["pnl"] > 0]; losses = [t for t in trades if t["pnl"] < 0]
gp = sum(t["pnl"] for t in wins); gl = -sum(t["pnl"] for t in losses)
peak = DEPOSIT; maxdd = 0.0; maxdd_t = 0.0
for _, b in eq:
    peak = max(peak, b)
    maxdd = max(maxdd, peak - b); maxdd_t = max(maxdd_t, (peak - b) / peak * 100)

print("== RESULTADO PORTFOLIO v11.0 | BTCUSDm H1 | lote fijo 10.0 | 2025-01-01 a 2026-08-10 | Modelo 1 ==")
print(f"Balance final: {bal:,.2f} USD (inicio {DEPOSIT:,.0f})  ->  +{bal-DEPOSIT:,.2f}  ({100*(bal/DEPOSIT-1):+.1f}%)")
print(f"Trades: {len(trades)}  |  Wins:{len(wins)}  Losses:{len(losses)}  BE:{len(trades)-len(wins)-len(losses)}")
if trades:
    print(f"Winrate: {100*len(wins)/len(trades):.1f}%  |  Profit factor: {gp/gl if gl else float('inf'):.2f}")
    print(f"Gross profit: {gp:,.2f}  |  Gross loss: {-gl:,.2f}  |  Neto: {gp-gl:,.2f}")
    print(f"Avg win: {gp/len(wins):,.2f}  |  Avg loss: {gl/len(losses):,.2f}  |  Avg/trade: {sum(t['pnl'] for t in trades)/len(trades):,.2f}")
    print(f"Max win streak: {maxws}  |  Max loss streak: {maxls}")
    print(f"Max drawdown (balance/cierre): {maxdd:,.2f} USD ({maxdd_t:.1f}%)")
    print(f"Hold medio: {sum(t['hold_min'] for t in trades)/len(trades):.0f} min  |  Hold max: {max(t['hold_min'] for t in trades):.0f} min")
    print("Cierres por: SL=%d  TP=%d  MARKET=%d" % (sum(1 for t in trades if t['reason']=='SL'), sum(1 for t in trades if t['reason']=='TP'), sum(1 for t in trades if t['reason']=='MARKET')))
    print(f"1a trade: {trades[0]['t_open']}  |  ultima: {trades[-1]['t_close']}")
    print("== Mensual (USD) ==")
    for k, v in monthly.items():
        print(f"  {k[0]}-{k[1]:02d}: {v:+,.0f}")

with open(OUT + r"\trades_v11_btc_lote10.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["id", "side", "entry", "close", "t_open", "t_close", "reason", "pnl_usd", "hold_min", "balance"])
    for tr in trades:
        w.writerow([tr["id"], tr["side"], f"{tr['entry']:.2f}", f"{tr['close']:.2f}",
                    tr["t_open"].strftime("%Y-%m-%d %H:%M"), tr["t_close"].strftime("%Y-%m-%d %H:%M"),
                    tr["reason"], f"{tr['pnl']:.2f}", f"{tr['hold_min']:.0f}", f"{tr['balance']:.2f}"])
print("CSV:", OUT + r"\trades_v11_btc_lote10.csv")