const fs = require('fs');
const path = require('path');
const { config } = require('../config');

// Contrato estándar de pedido: un formato común que cualquier POS puede consumir.
function pedidoEstandar(pedido) {
  return {
    cliente: config.clienteId,
    negocio: config.negocio,
    recibido: new Date().toISOString(),
    pedido: {
      id: pedido.id,
      fecha: pedido.fecha,
      dia: pedido.dia,
      remitente: pedido.remitente,
      telefono: pedido.telefono,
      items: (pedido.items || []).map(i => ({
        producto: i.producto,
        cantidad: i.cantidad,
        precioUnitario: i.precioUnitario,
        subtotal: i.subtotal
      })),
      total: pedido.total,
      direccion: pedido.direccion || '',
      lat: pedido.lat || '',
      lng: pedido.lng || '',
      estado: pedido.estado || 'recibido'
    }
  };
}

async function enviarWebhook(payload, cfg) {
  const headers = { 'Content-Type': 'application/json' };
  if (cfg.token) headers['Authorization'] = `Bearer ${cfg.token}`;
  if (cfg.header && cfg.valor) headers[cfg.header] = cfg.valor;
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), cfg.timeout || 8000);
  try {
    const resp = await fetch(cfg.url, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload),
      signal: controller.signal
    });
    if (!resp.ok) {
      console.error(`[INTEGRACION] webhook devolvió ${resp.status} para pedido #${payload.pedido.id}`);
    } else {
      console.log(`[INTEGRACION] webhook OK pedido #${payload.pedido.id} -> ${cfg.url}`);
    }
  } finally {
    clearTimeout(t);
  }
}

async function enviarArchivo(payload, cfg) {
  const salida = cfg.salida
    ? (path.isAbsolute(cfg.salida) ? cfg.salida : path.join(config.dataDir, cfg.salida))
    : path.join(config.dataDir, 'integracion.jsonl');
  fs.appendFileSync(salida, JSON.stringify(payload) + '\n', 'utf8');
  console.log(`[INTEGRACION] archivo OK pedido #${payload.pedido.id} -> ${salida}`);
}

async function enviarTelegram(payload, cfg) {
  const p = payload.pedido;
  const lineas = p.items.map(i => `• ${i.cantidad} x ${i.producto} = ${config.moneda}${i.subtotal.toLocaleString('es-CO')}`).join('\n');
  const texto = `📦 Nuevo pedido #${p.id} (${config.negocio})\n${lineas}\n💰 Total: ${config.moneda}${p.total.toLocaleString('es-CO')}\n📍 ${p.direccion || 'Recoge en local'} | 📞 ${p.telefono}`;
  const url = `https://api.telegram.org/bot${cfg.token}/sendMessage`;
  const resp = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: cfg.chat_id, text: texto })
  });
  if (!resp.ok) console.error(`[INTEGRACION] telegram devolvió ${resp.status}`);
  else console.log(`[INTEGRACION] telegram OK pedido #${p.id}`);
}

// Despacha el pedido al destino configurado. Si no hay integración o es 'kds'/'none',
// el pedido ya quedó guardado en pedidos.jsonl (nuestro propio KDS lo lee).
async function enviarPedido(pedido) {
  const cfg = config.integracion;
  if (!cfg || !cfg.tipo || cfg.tipo === 'kds' || cfg.tipo === 'none') return;
  const payload = pedidoEstandar(pedido);
  try {
    if (cfg.tipo === 'webhook') return await enviarWebhook(payload, cfg);
    if (cfg.tipo === 'archivo') return await enviarArchivo(payload, cfg);
    if (cfg.tipo === 'telegram') return await enviarTelegram(payload, cfg);
    console.warn(`[INTEGRACION] tipo desconocido: ${cfg.tipo}`);
  } catch (e) {
    console.error(`[INTEGRACION] falló envío (${cfg.tipo}):`, e && e.message ? e.message : e);
  }
}

module.exports = { enviarPedido, pedidoEstandar };
