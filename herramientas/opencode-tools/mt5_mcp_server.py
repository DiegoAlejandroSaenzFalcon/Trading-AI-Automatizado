"""MCP local server (stdio) que expone herramientas de MetaTrader 5.
Usa el paquete `MetaTrader5` ya instalado. Corre con: python mt5_mcp_server.py
"""
import sys, json, datetime

try:
    import MetaTrader5 as mt5
except ImportError:
    mt5 = None


def init_mt5():
    if mt5 is None:
        return "ERROR: paquete MetaTrader5 no instalado (pip install MetaTrader5)"
    paths = [r"C:\Program Files\MetaTrader 5\terminal64.exe"]
    for p in paths:
        if mt5.initialize(p):
            break
    else:
        return "ERROR: no se pudo conectar al terminal MT5"
    return None


def dump(obj):
    return json.dumps(obj, indent=1, default=str, ensure_ascii=False)


TOOLS = [
    {"name": "account_info", "description": "Datos de la cuenta (balance, equity, margen, apalancamiento).",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "positions", "description": "Posiciones abiertas del terminal (todas, con simbolo/magic/lote/PnL).",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "symbol_info", "description": "Specs de un simbolo (spread, margen, volumen min/max/step, digits).",
     "inputSchema": {"type": "object", "properties": {"symbol": {"type": "string"}}, "required": ["symbol"]}},
    {"name": "history_deals", "description": "Ultimos N deals cerrados (profit, comision, swap, magic, simbolo).",
     "inputSchema": {"type": "object", "properties": {"days": {"type": "number", "default": 7}}, "required": []}},
    {"name": "terminal_info", "description": "Estado del terminal (server, build, conectado).",
     "inputSchema": {"type": "object", "properties": {}}},
]


def handle_tools_call(name, args):
    err = init_mt5()
    if err:
        return {"content": [{"type": "text", "text": err}]}
    try:
        if name == "account_info":
            a = mt5.account_info()
            out = dump(vars(a)) if a else "sin cuenta"
        elif name == "positions":
            pos = mt5.positions_get()
            rows = []
            for p in (pos or []):
                rows.append(dict(ticket=p.ticket, symbol=p.symbol, type="BUY" if p.type == 0 else "SELL",
                                 volume=p.volume, price_open=p.price_open, sl=p.sl, tp=p.tp,
                                 profit=p.profit, swap=p.swap, magic=p.magic, comment=p.comment))
            out = dump(rows) if rows else "sin posiciones"
        elif name == "symbol_info":
            s = mt5.symbol_info(args.get("symbol", "BTCUSDm"))
            if s:
                out = dump(dict(name=s.name, digits=s.digits, spread=s.spread, spread_float=s.spread_float,
                                margin_initial=s.margin_initial, margin_maintenance=s.margin_maintenance,
                                volume_min=s.volume_min, volume_max=s.volume_max, volume_step=s.volume_step,
                                trade_stops_level=s.trade_stops_level, trade_freeze_level=s.trade_freeze_level,
                                trade_contract_size=s.trade_contract_size, trade_tick_value=s.trade_tick_value,
                                trade_tick_size=s.trade_tick_size, session_open=s.session_open, session_close=s.session_close))
            else:
                out = "simbolo no disponible"
        elif name == "history_deals":
            days = int(args.get("days", 7))
            from_ = datetime.datetime.now() - datetime.timedelta(days=days)
            deals = mt5.history_deals_get(from_, datetime.datetime.now() + datetime.timedelta(days=1))
            rows = [dict(ticket=d.ticket, time=str(datetime.datetime.fromtimestamp(d.time)), symbol=d.symbol,
                         type=d.type, volume=d.volume, price=d.price, profit=d.profit, commission=d.commission,
                         swap=d.swap, magic=d.magic, comment=d.comment) for d in (deals or [])]
            out = dump(rows) if rows else f"sin deals en {days} dias"
        elif name == "terminal_info":
            t = mt5.terminal_info()
            out = dump(vars(t)) if t else "sin terminal"
        else:
            out = "tool desconocido"
        return {"content": [{"type": "text", "text": out}]}
    except Exception as e:
        return {"content": [{"type": "text", "text": "ERROR: " + repr(e)}]}
    finally:
        try:
            mt5.shutdown()
        except Exception:
            pass


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        method = msg.get("method", "")
        mid = msg.get("id")
        if method == "initialize":
            resp = {"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": "2025-03-26",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "mt5-mcp", "version": "1.0.0"}}}
        elif method == "notifications/initialized":
            resp = None
        elif method == "tools/list":
            resp = {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}}
        elif method == "tools/call":
            params = msg.get("params", {})
            result = handle_tools_call(params.get("name", ""), params.get("arguments", {}))
            resp = {"jsonrpc": "2.0", "id": mid, "result": result}
        elif method == "ping":
            resp = {"jsonrpc": "2.0", "id": mid, "result": {}}
        else:
            resp = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method no soportado"}}
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()