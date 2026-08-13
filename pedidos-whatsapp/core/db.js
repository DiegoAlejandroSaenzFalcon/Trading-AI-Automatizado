const fs = require('fs');
const path = require('path');
const { DatabaseSync } = require('node:sqlite');
const { config } = require('../config');

const DB_PATH = path.join(config.dataDir, 'neurallgo.db');
if (!fs.existsSync(config.dataDir)) fs.mkdirSync(config.dataDir, { recursive: true });

const db = new DatabaseSync(DB_PATH);
db.exec('PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;');

db.exec(`
CREATE TABLE IF NOT EXISTS tenants (
  id TEXT PRIMARY KEY,
  nombre TEXT,
  creado TEXT
);
CREATE TABLE IF NOT EXISTS pedidos (
  id INTEGER,
  tenant_id TEXT,
  fecha TEXT,
  dia TEXT,
  remitente TEXT,
  telefono TEXT,
  items TEXT,
  total INTEGER,
  crudo TEXT,
  direccion TEXT,
  lat TEXT,
  lng TEXT,
  estado TEXT DEFAULT 'recibido',
  tipo TEXT DEFAULT 'domicilio',
  estado_pago TEXT DEFAULT 'pendiente',
  PRIMARY KEY (tenant_id, id)
);
CREATE TABLE IF NOT EXISTS clientes (
  tenant_id TEXT,
  telefono TEXT,
  nombre TEXT,
  total_pedidos INTEGER DEFAULT 0,
  ultima_compra TEXT,
  creado TEXT,
  PRIMARY KEY (tenant_id, telefono)
);
CREATE TABLE IF NOT EXISTS conversaciones (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tenant_id TEXT,
  hilo TEXT,
  remitente TEXT,
  rol TEXT,
  texto TEXT,
  fecha TEXT
);
CREATE INDEX IF NOT EXISTS idx_pedidos_tenant ON pedidos(tenant_id);
CREATE INDEX IF NOT EXISTS idx_conv_tenant ON conversaciones(tenant_id, hilo);
CREATE INDEX IF NOT EXISTS idx_clientes_tenant ON clientes(tenant_id);
`);

const tenantId = config.clienteId;
db.prepare('INSERT OR IGNORE INTO tenants (id, nombre, creado) VALUES (?, ?, ?)')
  .run(tenantId, config.negocio || tenantId, new Date().toISOString());

function siguienteId() {
  const row = db.prepare('SELECT COALESCE(MAX(id),0)+1 AS n FROM pedidos WHERE tenant_id=?').get(tenantId);
  return row.n;
}

function guardarPedido(datos) {
  db.prepare(`INSERT INTO pedidos
    (id, tenant_id, fecha, dia, remitente, telefono, items, total, crudo, direccion, lat, lng, estado, tipo, estado_pago)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(
    datos.id, tenantId,
    datos.fecha || new Date().toISOString(),
    datos.dia || (datos.fecha ? datos.fecha.slice(0, 10) : ''),
    datos.remitente || '',
    datos.telefono || '',
    JSON.stringify(datos.items || []),
    datos.total || 0,
    datos.crudo || '',
    datos.direccion || '',
    datos.lat || '',
    datos.lng || '',
    datos.estado || 'recibido',
    datos.tipo || 'domicilio',
    datos.estado_pago || 'pendiente'
  );
  if (datos.telefono) actualizarPerfil(datos);
}

function leerPedidos() {
  const rows = db.prepare('SELECT * FROM pedidos WHERE tenant_id=? ORDER BY id ASC').all(tenantId);
  return rows.map(r => ({
    id: r.id,
    fecha: r.fecha,
    dia: r.dia,
    remitente: r.remitente,
    telefono: r.telefono,
    items: JSON.parse(r.items || '[]'),
    total: r.total,
    crudo: r.crudo,
    direccion: r.direccion,
    lat: r.lat,
    lng: r.lng,
    estado: r.estado,
    tipo: r.tipo,
    estado_pago: r.estado_pago
  }));
}

function patchPedido(id, campos) {
  const cols = Object.keys(campos).filter(k => ['fecha','dia','remitente','telefono','items','total','crudo','direccion','lat','lng','estado','tipo','estado_pago'].includes(k));
  if (!cols.length) return;
  const set = cols.map(c => `${c}=?`).join(', ');
  const vals = cols.map(c => c === 'items' ? JSON.stringify(campos[c]) : campos[c]);
  db.prepare(`UPDATE pedidos SET ${set} WHERE tenant_id=? AND id=?`).run(...vals, tenantId, id);
}

function cambiarEstado(id, estado) {
  patchPedido(id, { estado });
  return leerPedidos().find(p => p.id === id) || null;
}

// ---- Clientes / perfilación ----
function actualizarPerfil(datos) {
  const existente = db.prepare('SELECT * FROM clientes WHERE tenant_id=? AND telefono=?').get(tenantId, datos.telefono);
  if (existente) {
    db.prepare('UPDATE clientes SET total_pedidos=total_pedidos+1, ultima_compra=?, nombre=COALESCE(NULLIF(?, ""), nombre) WHERE tenant_id=? AND telefono=?')
      .run(datos.fecha || new Date().toISOString(), datos.remitente || '', tenantId, datos.telefono);
  } else {
    db.prepare('INSERT INTO clientes (tenant_id, telefono, nombre, total_pedidos, ultima_compra, creado) VALUES (?,?,?,?,?,?)')
      .run(tenantId, datos.telefono, datos.remitente || '', 1, datos.fecha || new Date().toISOString(), new Date().toISOString());
  }
}

function obtenerCliente(telefono) {
  return db.prepare('SELECT * FROM clientes WHERE tenant_id=? AND telefono=?').get(tenantId, telefono) || null;
}

function listarClientes() {
  return db.prepare('SELECT telefono, nombre, total_pedidos, ultima_compra FROM clientes WHERE tenant_id=? ORDER BY ultima_compra DESC').all(tenantId);
}

// ---- Conversaciones ----
function registrarConversacion(hilo, remitente, rol, texto) {
  if (!texto || !String(texto).trim()) return;
  if (!hilo) hilo = 'desconocido';
  db.prepare('INSERT INTO conversaciones (tenant_id, hilo, remitente, rol, texto, fecha) VALUES (?,?,?,?,?,?)')
    .run(tenantId, hilo, remitente || '', rol, String(texto), new Date().toISOString());
}

function hilosConversacion() {
  const rows = db.prepare(`SELECT hilo, MAX(remitente) AS remitente, COUNT(*) AS total, MAX(fecha) AS ultima
    FROM conversaciones WHERE tenant_id=? GROUP BY hilo ORDER BY ultima DESC`).all(tenantId);
  return rows.map(r => ({ telefono: r.hilo, remitente: r.remitente, total: r.total, ultima: r.ultima }));
}

function leerHiloConversacion(hilo) {
  if (!hilo) return [];
  return db.prepare('SELECT fecha, rol, texto FROM conversaciones WHERE tenant_id=? AND hilo=? ORDER BY id ASC')
    .all(tenantId, hilo)
    .map(m => ({ fecha: new Date(m.fecha).toLocaleString('es-CO'), rol: m.rol, texto: m.texto }));
}

// ---- Migración de datos legacy (JSONL) a SQLite ----
function migrarLegacy() {
  const pedFile = path.join(config.dataDir, 'pedidos.jsonl');
  if (fs.existsSync(pedFile)) {
    const existentes = db.prepare('SELECT COUNT(*) AS n FROM pedidos WHERE tenant_id=?').get(tenantId).n;
    if (existentes === 0) {
      const lineas = fs.readFileSync(pedFile, 'utf8').split('\n').filter(l => l.trim());
      let migrados = 0;
      for (const l of lineas) {
        try {
          const p = JSON.parse(l);
          guardarPedido({
            id: p.id, fecha: p.fecha, dia: p.dia, remitente: p.remitente, telefono: p.telefono,
            items: p.items, total: p.total, crudo: p.crudo, direccion: p.direccion, lat: p.lat, lng: p.lng,
            estado: p.estado || 'recibido', tipo: p.tipo || 'domicilio', estado_pago: p.estado_pago || 'pendiente'
          });
          migrados++;
        } catch {}
      }
      console.log(`[DB] Migrados ${migrados} pedidos legacy a SQLite.`);
    }
    fs.renameSync(pedFile, pedFile + '.migrado');
  }
  const convFile = path.join(config.dataDir, 'conversaciones.jsonl');
  if (fs.existsSync(convFile)) {
    const existentes = db.prepare('SELECT COUNT(*) AS n FROM conversaciones WHERE tenant_id=?').get(tenantId).n;
    if (existentes === 0) {
      const lineas = fs.readFileSync(convFile, 'utf8').split('\n').filter(l => l.trim());
      for (const l of lineas) {
        try {
          const m = JSON.parse(l);
          registrarConversacion(m.telefono || m.hilo || 'desconocido', m.remitente, m.rol, m.texto);
        } catch {}
      }
      console.log(`[DB] Migradas conversaciones legacy a SQLite.`);
    }
    fs.renameSync(convFile, convFile + '.migrado');
  }
}

migrarLegacy();

module.exports = {
  db, tenantId,
  siguienteId, guardarPedido, leerPedidos, patchPedido, cambiarEstado,
  actualizarPerfil, obtenerCliente, listarClientes,
  registrarConversacion, hilosConversacion, leerHiloConversacion,
  migrarLegacy
};
