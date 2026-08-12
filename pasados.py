import csv
rows = []
with open(r"C:\Users\H2R\Documents\Default Project\grid3_corregido.csv") as f:
    for r in csv.DictReader(f):
        p = [float(r["P1_PF"]), float(r["P2_PF"]), float(r["P3_PF"])]
        n = [int(r["P1_n"]), int(r["P2_n"]), int(r["P3_n"])]
        pnl = [float(r["P1_pnl"]), float(r["P2_pnl"]), float(r["P3_pnl"])]
        rows.append((r["activo"], r["franja"], r["estrat"], r["tp"], r["ttl"], p, n, pnl))
pas = [r for r in rows if all(p > 1.15 for p in r[5]) and all(n >= 20 for n in r[6])]
for a, fr, st, tp, ttl, p, n, pnl in sorted(pas, key=lambda x: (x[0], x[1])):
    print(f"{a} {fr} {st:9s} tp{tp:<4} ttl{ttl:<3} " + " ".join(f"{p[i]:.2f}/{n[i]}" for i in range(3)) + f"  pnlR={sum(pnl):.0f}")
