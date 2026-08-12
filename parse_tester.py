import re
import sys


def parse_segments(path):
    with open(path, "r", encoding="utf-16-le", errors="replace") as f:
        lines = f.readlines()
    segments = []
    cur = None
    pending = None
    for ln in lines:
        m = re.search(r"testing of Experts\\([\w.]+)\.ex5 from (.+?) to (.+?) ", ln)
        if m:
            cur = {"ea": m.group(1), "frm": m.group(2), "to": m.group(3), "trades": []}
            segments.append(cur)
            pending = None
            continue
        if cur is None:
            continue
        m = re.search(r"final balance ([\d.]+) USD", ln)
        if m:
            cur["final_balance"] = float(m.group(1))
            cur = None
            pending = None
            continue

        m = re.search(r"(\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2})\s+market (buy|sell) ([\d.]+) (\S+) sl: ([\d.]+) tp: ([\d.]+)", ln)
        if m and "CTrade" not in ln:
            pending = {"open_time": m.group(1), "side": m.group(2), "vol": float(m.group(3)), "entry_price": None, "exit_type": None, "exit_price": None}
            continue
        if pending is None:
            continue

        m = re.search(r"deal #\d+ \w+ ([\d.]+) (\S+) at ([\d.]+) done", ln)
        if m:
            if pending["entry_price"] is None:
                pending["entry_price"] = float(m.group(3))
            elif pending["exit_type"] is not None:
                pending["exit_price"] = float(m.group(3))
                cur["trades"].append(pending)
                pending = None
            continue

        m = re.search(r"(\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2})\s+(stop loss|take profit) triggered", ln)
        if m:
            pending["exit_type"] = m.group(2)
            pending["close_time"] = m.group(1)
    return segments


def pnl(t):
    if t["entry_price"] is None or t["exit_price"] is None:
        return None
    if t["side"] == "buy":
        return (t["exit_price"] - t["entry_price"]) * t["vol"]
    return (t["entry_price"] - t["exit_price"]) * t["vol"]


if __name__ == "__main__":
    segs = parse_segments(sys.argv[1])
    for s in segs:
        ok = [t for t in s["trades"] if pnl(t) is not None]
        total = sum(pnl(t) for t in ok)
        print(
            f"--- {s['ea']} {s['frm']}->{s['to']} | trades={len(s['trades'])} | pnl_est={total:+.2f} | FB={s.get('final_balance')}"
        )
