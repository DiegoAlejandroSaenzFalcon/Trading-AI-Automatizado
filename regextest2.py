import re

s = "testing of Experts\\Pure_Fractal_FVG_Fusion_BTCUSD_r30.ex5 from 2026.02.01 00:00 to 2026.05.13 00:00"
print("test A:", re.search(r"Experts\\([\w.]+)\.ex5", s))
print("test B:", re.search(r"testing of Experts", s))
print("test C:", re.search(r"\\Pure_Fractal", s))
print("test D:", re.search(r"from (\S+) to (\S+)", s))
m = re.search(r"Experts\\([\w.]+)\.ex5 from (\S+) to (\S+)", s)
print("test E:", m is not None, m.groups() if m else "")
