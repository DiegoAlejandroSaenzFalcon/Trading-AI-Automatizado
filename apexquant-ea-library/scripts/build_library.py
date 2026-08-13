#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_library.py — Generador de la biblioteca publica de EAs (default proyect).
Escanea la carpeta MQL5\\Experts, extrae metadatos del header de cada .mq5 y
genera:
  1) Carpetas por ESTRATEGIA (fisicas, un solo "hogar" por EA)
  2) registry.csv        -> FUENTE DE VERDAD (efectividad, activo, magic, estado)
  3) INDEX.md            -> ordenado por efectividad (mira rapido)
  4) POR_ACTIVO.md       -> vista virtual por activo (auto-generada)
  5) POR_ESTRATEGIA.md   -> vista por tipo de estrategia

USO:  python build_library.py   (desde la carpeta del repo)
"""
import io, os, re, csv, glob, datetime

REPO    = os.path.dirname(os.path.abspath(__file__))          # <repo>/scripts
ROOT    = os.path.dirname(REPO)                                # <repo>
EXPERTS = r"C:\Users\H2R\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts"

SKIP_DIRS = {"Examples", "Free Robots", "Advisors"}
ASSETS = {
    "BTC": "BTCUSD", "btc": "BTCUSD", "BTCUSD": "BTCUSD",
    "XAU": "XAUUSD", "xau": "XAUUSD", "XAUUSD": "XAUUSD",
    "GOLD": "XAUUSD", "SP500": "SP500", "NAS100": "NAS100",
    "US30": "US30", "EURUSD": "EURUSD", "GBPUSD": "GBPUSD",
    "USDJPY": "USDJPY",
}
# Palabras clave -> tipo de estrategia (nombre de archivo)
STRAT_RULES = [
    (re.compile(r"(fvg)", re.I),                    "FVG"),
    (re.compile(r"(breakout|ruptura)", re.I),       "Breakout"),
    (re.compile(r"(engulfing)", re.I),              "Engulfing"),
    (re.compile(r"(engulfbull|bull)", re.I),        "Engulfing"),
    (re.compile(r"(macross|macd)", re.I),           "Cruce_MA"),
    (re.compile(r"(dca)", re.I),                    "DCA_Martingala"),
    (re.compile(r"(regimen|regime)", re.I),         "Regimen_Tendencia"),
    (re.compile(r"(trend|tendencia)", re.I),        "Tendencia"),
    (re.compile(r"(scalper|scalp|m1)", re.I),       "Scalping"),
    (re.compile(r"(retest)", re.I),                 "Retest"),
    (re.compile(r"(vwap)", re.I),                   "VWAP"),
    (re.compile(r"(kalman)", re.I),                 "Kalman"),
    (re.compile(r"(liquidity|induce)", re.I),       "Liquidez"),
    (re.compile(r"(adaptive)", re.I),               "Adaptativo"),
    (re.compile(r"(multi.?timeframe|mf)", re.I),    "MultiTimeframe"),
    (re.compile(r"(breakout)", re.I),               "Breakout"),
]
DEFAULT_STRAT = "Mixta/Otra"

def slugify(name):
    s = re.sub(r"[^\w\.\-]+", "_", name.strip())
    return s

def detect_asset(name):
    for k, v in ASSETS.items():
        if k in name:
            return v
    return "VARIOS/ND"

def detect_strategy(name):
    for rx, label in STRAT_RULES:
        if rx.search(name):
            return label
    return DEFAULT_STRAT

def read_header(path, n=30):
    try:
        with io.open(path, "r", encoding="utf-8-sig") as f:
            return f.read(n * 2500)
    except Exception:
        return ""

def find_magic(text):
    m = re.search(r"(?:InpMagicBase|InpMagicNumber|InpMagic)\s*=\s*(\d+)", text)
    return int(m.group(1)) if m else None

def header_summary(text):
    lines = []
    for line in text.splitlines()[:22]:
        line = line.strip()
        if line.startswith("//|") or line.startswith("// "):
            lines.append(line.lstrip("//| ").strip())
        elif line.startswith("#property version"):
            lines.append("version: " + line.split('"')[1])
    return "; ".join([l for l in lines if l][:8])

def main():
    today = datetime.date.today().isoformat()
    rows = []
    files = glob.glob(os.path.join(EXPERTS, "**", "*.mq5"), recursive=True)
    files = [f for f in files if not any(s in f for s in SKIP_DIRS)]
    for path in sorted(files):
        fname = os.path.basename(path)
        head  = read_header(path)
        asset = detect_asset(fname)
        strat = detect_strategy(fname)
        magic = find_magic(head)
        slug  = slugify(fname[:-4])
        rows.append({
            "slug": slug,
            "archivo": fname,
            "ruta_origen": os.path.relpath(path, EXPERTS),
            "activo": asset,
            "estrategia": strat,
            "magic": magic if magic is not None else "",
            "estado": "POR_REVISAR",   # backtest|demo|live|archive|por_revisar
            "score": 0,                 # 0-3 (ver README principal)
            "r_mult": "",
            "max_dd_pct": "",
            "winrate": "",
            "notas": header_summary(head) or "",
        })
    # ---- escritura ----
    reg_dir = os.path.join(ROOT, "registro")
    os.makedirs(reg_dir, exist_ok=True)
    csv_path = os.path.join(reg_dir, "registry.csv")
    with io.open(csv_path, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["slug","archivo","ruta_origen","activo","estrategia","magic",
                    "estado","score","r_mult","max_dd_pct","winrate","notas"])
        for r in rows:
            w.writerow([r["slug"],r["archivo"],r["ruta_origen"],r["activo"],
                        r["estrategia"],r["magic"],r["estado"],r["score"],
                        r["r_mult"],r["max_dd_pct"],r["winrate"],r["notas"]])
    # carpetas fisicas por estrategia + README minimo
    index_rows = []
    for r in rows:
        d = os.path.join(ROOT, "estrategias", r["estrategia"], r["slug"])
        os.makedirs(os.path.join(d, "src"), exist_ok=True)
        readme = (
            "# %s\n\n- **Activo:** %s\n- **Estrategia:** %s\n- **Magic:** %s\n"
            "- **Estado:** %s (score %d/3)\n- **Archivo:** %s\n\n## Descripcion\n%s\n\n"
            "## Resultados\n\n| Metricas | Valor |\n|---|---|\n| R xTrade | %s |\n"
            "| Max DD %% | %s |\n| Winrate | %s |\n\n## Config\nVer `src/%s` y el `.set` del EA."
            "\n\n*Configuracion inicial auto-generada el %s (editar con datos reales de validacion).*\n"
            % (r["slug"], r["activo"], r["estrategia"], r["magic"], r["estado"],
               r["score"], r["archivo"], r["notas"], r["r_mult"], r["max_dd_pct"],
               r["winrate"], r["archivo"], today)
        )
        io.open(os.path.join(d, "README.md"), "w", encoding="utf-8").write(readme)
        index_rows.append(r)
    # INDICES
    def fmt(r):
        return "| [%s](estrategias/%s/%s/) | %s | %s | %s | %d | %s | %s |" % (
            r["archivo"], r["estrategia"], r["slug"], r["activo"], r["estrategia"],
            r["magic"] if r["magic"] else "-", r["score"], r["estado"], r["notas"][:60])
    header = "# INDICE POR EFECTIVIDAD\n\nScore: 3=WF validado | 2=demo positivo 1sem+ | 1=backtest marginal | 0=sin probar/falta.\n\n"
    io.open(os.path.join(ROOT, "INDEX.md"), "w", encoding="utf-8").write(
        header + "| EA | Activo | Estrategia | Magic | Score | Estado | Notas |\n|---|---|---|---|---|---|---|\n" +
        "\n".join(fmt(r) for r in sorted(index_rows, key=lambda r: (-r["score"], r["activo"], r["archivo"]))))
    # por activo
    lines = ["# BIBLIOTECA POR ACTIVO\n"]
    active_assets = sorted({r["activo"] for r in index_rows})
    for a in active_assets:
        lines.append("\n## %s\n" % a)
        lines.append("| EA | Estrategia | Magic | Score | Estado |\n|---|---|---|---|---|")
        for r in sorted([x for x in index_rows if x["activo"] == a],
                        key=lambda x: (-x["score"], x["archivo"])):
            lines.append("| [%s](estrategias/%s/%s/) | %s | %s | %d | %s |" %
                         (r["archivo"], r["estrategia"], r["slug"], r["estrategia"],
                          r["magic"] if r["magic"] else "-", r["score"], r["estado"]))
    io.open(os.path.join(ROOT, "POR_ACTIVO.md"), "w", encoding="utf-8").write("\n".join(lines))
    # por estrategia
    lines = ["# BIBLIOTECA POR ESTRATEGIA\n"]
    for s in sorted({r["estrategia"] for r in index_rows}):
        lines.append("\n## %s\n" % s)
        lines.append("| EA | Activo | Magic | Score | Estado |\n|---|---|---|---|---|")
        for r in sorted([x for x in index_rows if x["estrategia"] == s],
                        key=lambda x: (-x["score"], x["archivo"])):
            lines.append("| [%s](estrategias/%s/%s/) | %s | %s | %d | %s |" %
                         (r["archivo"], r["estrategia"], r["slug"], r["activo"],
                          r["magic"] if r["magic"] else "-", r["score"], r["estado"]))
    io.open(os.path.join(ROOT, "POR_ESTRATEGIA.md"), "w", encoding="utf-8").write("\n".join(lines))
    print("BIBLIOTECA GENERADA")
    print("  -", len(rows), "EAs escaneados")
    print("  - registry.csv:", os.path.join(reg_dir, "registry.csv"))
    print("  - INDEX.md / POR_ACTIVO.md / POR_ESTRATEGIA.md")
    print("  - carpetas en ./estrategias/<TIPO>/<EA>/src")

if __name__ == "__main__":
    main()