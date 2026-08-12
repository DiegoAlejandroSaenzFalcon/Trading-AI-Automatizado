import csv
rows = []
with open(r"C:\Users\H2R\Documents\Default Project\refinamiento_xau.csv") as f:
    for r in csv.DictReader(f):
        p1pf, p2pf, p3pf = float(r["P1_PF"]), float(r["P2_PF"]), float(r["P3_PF"])
        p1pnl, p2pnl, p3pnl = float(r["P1_pnl"]), float(r["P2_pnl"]), float(r["P3_pnl"])
        n1, n2, n3 = int(r["P1_n"]), int(r["P2_n"]), int(r["P3_n"])
        rows.append((r["slot"], r["tp"], r["ttl"], p1pf, p2pf, p3pf, p1pnl+p2pnl, p3pnl, n1+n2, n3))
print("=== MEJORES POR SLOT (ordenado por pnlR P1+P2, con P3 PF>1.1 y n>=30) ===")
slots = sorted(set(r[0] for r in rows))
for sl in slots:
    cands = [r for r in rows if r[0] == sl and r[3] > 1.05 and r[4] > 1.05 and r[5] > 1.1 and r[8]+r[9] >= 60]
    if not cands:
        cands = [r for r in rows if r[0] == sl]
    cands.sort(key=lambda r: -r[6])
    for r in cands[:3]:
        print(f"{r[0]:14s} tp{r[1]:<4} ttl{r[2]:<3} P1 {r[3]:.2f} P2 {r[4]:.2f} P3 {r[5]:.2f} | pnlR P1+P2={r[6]:.0f} P3={r[7]:.0f} | n={r[8]}+{r[9]}")
    print()
