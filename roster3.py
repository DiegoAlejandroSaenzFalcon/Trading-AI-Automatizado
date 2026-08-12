import csv
rows = []
with open(r"C:\Users\H2R\Documents\Default Project\grid3_corregido.csv") as f:
    for r in csv.DictReader(f):
        p = [float(r["P1_PF"]), float(r["P2_PF"]), float(r["P3_PF"])]
        n = [int(r["P1_n"]), int(r["P2_n"]), int(r["P3_n"])]
        pnl = [float(r["P1_pnl"]), float(r["P2_pnl"]), float(r["P3_pnl"])]
        rows.append((r["activo"], r["franja"], r["estrat"], r["tp"], r["ttl"], p, n, pnl))
print("=== PASA (PF>1.15 en los 3 periodos, n>=20 en los 3) ===")
pas = [r for r in rows if all(p > 1.15 for p in r[5]) and all(n >= 20 for n in r[6])]
for a, fr, st, tp, ttl, p, n, pnl in pas:
    print(f"{a} {fr} {st:9s} tp{tp} ttl{ttl}: " + "  ".join(f"{p[i]:.2f}(n={n[i]})" for i in range(3)) + f"  pnlR={sum(pnl):.0f}")
print()
print("=== CERCA (min>=1.0, media>=1.2, n>=25 en los 3) ===")
for a, fr, st, tp, ttl, p, n, pnl in rows:
    if (a, fr, st, tp, ttl) in [(x[0],x[1],x[2],x[3],x[4]) for x in pas]: continue
    if all(n >= 25 for n in n):
        if min(p) >= 1.0 and sum(p)/3 >= 1.2:
            print(f"{a} {fr} {st:9s} tp{tp} ttl{ttl}: " + "  ".join(f"{p[i]:.2f}(n={n[i]})" for i in range(3)) + f"  pnlR={sum(pnl):.0f}")
print(f"\nTOTAL PASA: {len(pas)}")
