const db = require('./db');

function registrar(hilo, remitente, rol, texto) {
  db.registrarConversacion(hilo, remitente, rol, texto);
}

function hilos() {
  return db.hilosConversacion();
}

function leerHilo(hilo) {
  return db.leerHiloConversacion(hilo);
}

module.exports = { registrar, hilos, leerHilo };
