import csv
from collections import defaultdict
d = defaultdict(dict)
with open(r"C:\Users\H2R\Documents\Default Project\grid2_final.csv") as f:
    for row in csv.DictReader(f):
        key = (row["activo"], row["franja"], row["estrat"])
        d[key][row["periodo"]] = (int(row["n"]), float(row["pnlR"]), float(row["win"]), float(row["PF"]), float(row["DD"]))
print("=== PASA 3 PERIODOS (PF>1.15, n>=20 en los 3) ===")
pas = []
for key, res in sorted(d.items()):
    if len(res) != 3: continue
    vals = [res[p] for p in ["P1_24h2-25h1","P2_25h2-26e","P3_26f-26a"]]
    if all(v and v[3] > 1.15 and v[0] >= 20 for v in vals):
        pas.append((key, vals))
        print(f"{key[0]} {key[1]} {key[2]:9s}  " + "  ".join(f"PF {v[3]:.2f} (n={v[0]}, win={v[2]:.0f}%, DD={v[4]})" for v in vals))
print()
print("=== CERCA (min >= 1.05, media >= 1.20, n>=30) ===")
for key, res in sorted(d.items()):
    if len(res) != 3: continue
    vals = [res[p] for p in ["P1_24h2-25h1","P2_25h2-26e","P3_26f-26a"]]
    if key in [k for k,_ in pas]: continue
    if all(v and v[0] >= 30 for v in vals):
        pfs = [v[3] for v in vals]
        if min(pfs) >= 1.05 and sum(pfs)/3 >= 1.20:
            print(f"{key[0]} {key[1]} {key[2]:9s}  " + "  ".join(f"{v[3]:.2f}(n={v[0]})" for v in vals))
print()
print(f"TOTAL PASA: {len(pas)}")
