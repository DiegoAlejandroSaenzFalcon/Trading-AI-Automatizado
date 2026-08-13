const { config, fechaDia, hoyInicio, normalizar, escaparRegex } = require('../config');
const { enviarPedido } = require('./integracion');
const db = require('./db');

function leerPedidos() {
  return db.leerPedidos();
}

function guardarPedido(datos) {
  db.guardarPedido(datos);
  enviarPedido(datos).catch(e => console.error('[!] Error en integración POS:', e && e.message ? e.message : e));
}

function patchPedido(id, campos) {
  return db.patchPedido(id, campos);
}

function cambiarEstado(id, estado) {
  return db.cambiarEstado(id, estado);
}

function siguienteId() {
  return db.siguienteId();
}

function parsearPedido(mensaje) {
  const texto = normalizar(mensaje);
  const items = [];
  for (const p of config.productos) {
    let cantidad = 0;
    const aliasUnico = [...new Set(p.alias)].sort((a, b) => b.length - a.length);
    const alt = aliasUnico.map(escaparRegex).join('|');
    const altP = aliasUnico.map(a => escaparRegex(a).split(' ').map(w => w + 's?').join(' ')).join('|');
    let m;
    const re = new RegExp(`(\\d+)\\s*(?:${altP})\\b`, 'g');
    while ((m = re.exec(texto)) !== null) {
      const c = parseInt(m[1], 10);
      if (c > 0 && c <= 1000) cantidad += c;
    }
    const reSuf = new RegExp(`(?:${altP})\\b\\s*(?:[x×*]\\s*)?\\s*(\\d{1,3})\\b`, 'g');
    while ((m = reSuf.exec(texto)) !== null) {
      const c = parseInt(m[1], 10);
      if (c > 0 && c <= 1000) cantidad += c;
    }
    const reDoc = new RegExp(`\\b(?:docena|docenas)\\s+(?:de\\s+)?(?:${altP})\\b`, 'g');
    while ((m = reDoc.exec(texto)) !== null) cantidad += 12;
    if (cantidad === 0 && !/\d/.test(texto)) {
      const esPregunta = /[?¿]|\b(que|qué|cual|cuál|como|cómo|cuanto|cuánto|cuesta|trae|lleva|tiene|sabes|informacion|info|dime|me dices|me dice|por que|por qué|porque)\b/i.test(texto);
      if (!esPregunta && new RegExp(`\\b(?:${altP})\\b`).test(texto)) cantidad = 1;
    }
    if (cantidad > 0) items.push({ producto: p.nombre, cantidad, precioUnitario: p.precio, subtotal: cantidad * p.precio });
  }
  return items;
}

function resumenDe(orders, desde) {
  const hoy = desde ? orders.filter(o => o.dia === desde.slice(0, 10)) : orders;
  let total = 0;
  const porProducto = {};
  for (const o of hoy) {
    total += o.total;
    for (const i of o.items) {
      if (!porProducto[i.producto]) porProducto[i.producto] = { cantidad: 0, valor: 0 };
      porProducto[i.producto].cantidad += i.cantidad;
      porProducto[i.producto].valor += i.subtotal;
    }
  }
  const articulos = Object.entries(porProducto)
    .sort((a, b) => b[1].cantidad - a[1].cantidad)
    .map(([k, v]) => `${k}: ${v.cantidad} und (${config.moneda}${v.valor.toLocaleString('es-CO')})`)
    .join('\n');
  return {
    texto:
      `📊 REPORTE PEDIDOS\n${hoy.length} pedidos | ${config.moneda}${total.toLocaleString('es-CO')}\n\nDetalle vendido:\n${articulos || 'Ninguno'}`,
    total, pedidos: hoy.length
  };
}

function formatearConfirmacion(pedido, remitente) {
  const lineas = pedido.items.map(i => `• ${i.cantidad} x ${i.producto} = ${config.moneda}${i.subtotal.toLocaleString('es-CO')}`);
  return `✅ Pedido #${pedido.id} recibido de ${remitente}\n\n${lineas.join('\n')}\n\n💰 TOTAL: ${config.moneda}${pedido.total.toLocaleString('es-CO')}`;
}

function reporteHoyTexto() {
  return resumenDe(leerPedidos(), hoyInicio()).texto;
}

module.exports = {
  leerPedidos, guardarPedido, patchPedido, cambiarEstado, siguienteId,
  parsearPedido, resumenDe, formatearConfirmacion, reporteHoyTexto
};
