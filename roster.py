import csv
rows = []
with open(r"C:\Users\H2R\Documents\Default Project\grid_multiestrategia.csv") as f:
    r = csv.DictReader(f)
    for row in r:
        is_ok = float(row["IS_PF"]) > 1.15 and int(row["IS_n"]) >= 10
        os_ok = float(row["OOS_PF"]) > 1.15 and int(row["OOS_n"]) >= 10
        rows.append((row["activo"], row["franja"], row["estrategia"], float(row["IS_PF"]), float(row["OOS_PF"]), int(row["IS_n"]), int(row["OOS_n"]), is_ok, os_ok))
print("=== ROBUSTAS (IS y OOS > 1.15, n>=10 ambas) ===")
for a, fr, st, p1, p2, n1, n2, i1, i2 in rows:
    if i1 and i2:
        print(f"{a} {fr} {st:8s} IS {p1:>5.2f} ({n1:>4})  OOS {p2:>5.2f} ({n2:>4})")
print()
print("=== MAPA POR FRANJA (mejor robusta OOS) ===")
best = {}
for a, fr, st, p1, p2, n1, n2, i1, i2 in rows:
    if i1 and i2:
        key = (a, fr)
        if key not in best or p2 > best[key][3]:
            best[key] = (st, p1, n1, p2, n2)
for (a, fr), (st, p1, n1, p2, n2) in sorted(best.items()):
    print(f"{a} {fr}: {st:8s} IS {p1:.2f} / OOS {p2:.2f} (n IS {n1}, OOS {n2})")
