const fs = require('fs');
const path = require('path');
const { config } = require('../config');

const ARCHIVO = path.join(config.dataDir, 'conversaciones.jsonl');
if (!fs.existsSync(config.dataDir)) fs.mkdirSync(config.dataDir, { recursive: true });

// hilo = identificador estable del cliente (su número). Nunca vacío.
function registrar(hilo, remitente, rol, texto) {
  if (!texto || !String(texto).trim()) return;
  if (!hilo) hilo = 'desconocido';
  const linea = {
    fecha: new Date().toISOString(),
    hilo,
    telefono: hilo,
    remitente: remitente || '',
    rol: rol,
    texto: String(texto)
  };
  try {
    fs.appendFileSync(ARCHIVO, JSON.stringify(linea) + '\n', 'utf8');
  } catch (e) {
    console.error('[CONV] No pude guardar mensaje:', e && e.message ? e.message : e);
  }
}

function leerTodas() {
  if (!fs.existsSync(ARCHIVO)) return [];
  return fs.readFileSync(ARCHIVO, 'utf8')
    .split('\n').filter(l => l.trim())
    .map(l => { try { return JSON.parse(l); } catch { return null; } })
    .filter(Boolean);
}

function hilos() {
  const todas = leerTodas();
  const mapa = new Map();
  for (const m of todas) {
    const key = m.hilo || m.telefono || 'desconocido';
    if (!mapa.has(key)) {
      mapa.set(key, { telefono: key, remitente: m.remitente, mensajes: [] });
    }
    const h = mapa.get(key);
    h.mensajes.push(m);
    if (m.remitente) h.remitente = m.remitente;
  }
  return Array.from(mapa.values()).map(h => ({
    telefono: h.telefono,
    remitente: h.remitente,
    total: h.mensajes.length,
    ultima: h.mensajes[h.mensajes.length - 1].fecha
  })).sort((a, b) => b.ultima.localeCompare(a.ultima));
}

function leerHilo(hilo) {
  if (!hilo) return [];
  return leerTodas().filter(m => (m.hilo || m.telefono) === hilo);
}

module.exports = { registrar, leerTodas, hilos, leerHilo };
