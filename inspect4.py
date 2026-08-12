import re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-16-le", errors="replace") as f:
    lines = f.readlines()
print("total lineas:", len(lines))
hits = [i for i, ln in enumerate(lines) if "testing of" in ln]
print("lineas con 'testing of':", len(hits))
for i in hits[:3]:
    print(i, repr(lines[i][:120]))
