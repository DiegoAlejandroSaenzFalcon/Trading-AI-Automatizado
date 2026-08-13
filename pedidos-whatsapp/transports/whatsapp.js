const pino = require('pino');
const qrcode = require('qrcode-terminal');
const {
  default: makeWASocket,
  useMultiFileAuthState,
  DisconnectReason,
  fetchLatestBaileysVersion
} = require('@whiskeysockets/baileys');

const {
  config, fechaDia, hoyInicio, numDeCelular
} = require('../config');
const {
  leerPedidos, guardarPedido, patchPedido, resumenDe,
  formatearConfirmacion, reporteHoyTexto, siguienteId, parsearPedido
} = require('../core/orders');
const { setSock } = require('../core/notify');
const { registrar } = require('../core/conversacion');
const {
  askLLM, atenderClienteIA, agenteMasRelevante,
  dividirMensaje, esRespuestaDeError, esFueraDeTema, AGENTES
} = require('../core/ai');

let sock = null;
const idsEnviados = new Set();
const procesadosIn = new Set();
const lidMap = new Map();
const esperandoDireccion = new Map();
const pendientesConfirmar = new Map();

const DUENO_JID = config.numero_dueno.replace(/\D/g, '') + '@s.whatsapp.net';

function celularReal(jid) {
  const base = numDeCelular(jid);
  if (lidMap.has(base)) return lidMap.get(base);
  if (base.startsWith('1382')) return '';
  return base;
}

// Número del cliente SIEMPRE presente: usa el real si se conoce, si no el LID
// (never empty). Es el identificador obligatorio del cliente/pedido.
function numeroCliente(jid) {
  const base = numDeCelular(jid);
  if (lidMap.has(base)) return lidMap.get(base);
  return base;
}

async function cargarContactos(s, reintento) {
  if (typeof s.fetchContacts !== 'function') {
    if (reintento === 0) {
      console.log('[OK] Número de contacto: WhatsApp lo resuelve automáticamente si el cliente está en la agenda del celular del negocio.');
    }
    return;
  }
  try {
    const contactos = await s.fetchContacts();
    for (const c of contactos) {
      if (c.lid && c.jid && !lidMap.has(c.lid)) {
        lidMap.set(c.lid, numDeCelular(c.jid));
      }
    }
    console.log(`[OK] Contactos cargados (${contactos.length}), con número real: ${lidMap.size}`);
  } catch (e) {
    console.log('[!] No pude cargar los contactos:', e.message || e);
  }
  if (reintento < 3) setTimeout(() => cargarContactos(s, reintento + 1), 60000);
}

async function responder(s, jid, texto, m) {
  const res = await s.sendMessage(jid, { text: texto }, m ? { quoted: m } : undefined);
  if (res && res.key && res.key.id) idsEnviados.add(res.key.id);
  registrar(numeroCliente(jid), '', 'bot', texto);
  return res;
}

async function procesar(s, m, jid, cuerpo, ubicacion) {
  const esDueno = numDeCelular(jid) === config.numero_dueno.replace(/\D/g, '');
  const esComando = cuerpo.startsWith('!') || /^(ia|agente|agent)\b/i.test(cuerpo);

  if (esComando && esDueno) {
    if (cuerpo === '!reporte') {
      const r = resumenDe(leerPedidos(), hoyInicio());
      console.log('[OK] Enviando !reporte al dueño');
      await responder(s, jid, r.texto, m);
    } else if (cuerpo === '!vendidos') {
      const pedidos = leerPedidos().filter(p => p.dia === fechaDia());
      const texto = pedidos.length
        ? pedidos.map(p => `#${p.id} ${p.remitente}: ${p.items.map(i => `${i.cantidad} ${i.producto}`).join(', ')} = ${config.moneda}${p.total.toLocaleString('es-CO')} ${p.lat ? `📍 https://maps.google.com/?q=${p.lat},${p.lng}` : p.direccion ? `📍 ${p.direccion}` : ''}`).join('\n')
        : 'Hoy no hay pedidos aún.';
      console.log('[OK] Enviando !vendidos al dueño');
      await responder(s, jid, `📋 PEDIDOS DE HOY\n\n${texto}`, m);
    } else if (cuerpo === '!ayuda') {
      console.log('[OK] Enviando !ayuda al dueño');
      await responder(s, jid, 'Comandos:\n!reporte → resumen de hoy\n!vendidos → lista de pedidos de hoy\n!agentes → áreas de la Agencia IA\n\nIA desde el celular:\n• ia <tu consulta> → elige el experto ideal solo\n• agente <Nombre>: <consulta> → hablas con uno específico', m);
    } else if (/^!agentes?$/i.test(cuerpo)) {
      const cats = {};
      AGENTES.forEach(a => { cats[a.category] = (cats[a.category] || 0) + 1; });
      const lista = Object.entries(cats).map(([c, n]) => `• ${c}: ${n}`).join('\n');
      console.log('[OK] Enviando !agentes al dueño');
      await responder(s, jid, `🤖 AGENCIA IA — ${AGENTES.length} expertos disponibles\n\n${lista}\n\nCómo consultar:\n• ia <tu consulta> → elige el experto ideal solo\n• agente <Nombre>: <consulta> → hablas con uno específico\nEj: ia arma una promo para Instagram este finde`, m);
    } else if (/^(ia|agente|agent)\b/i.test(cuerpo)) {
      await responder(s, jid, '🤖 Buscando al experto indicado y preparando respuesta...', m);
      let consulta = cuerpo.replace(/^(ia|agente|agent)\b\s*/i, '').trim();
      let agente = null;
      let texto = consulta;
      const matchNombre = consulta.match(/^([^:]+):\s*([\s\S]+)$/);
      if (matchNombre) {
        const nombre = matchNombre[1].trim();
        texto = matchNombre[2].trim();
        agente = AGENTES.find(a => a.name.toLowerCase().includes(nombre.toLowerCase()));
        if (!agente) {
          const sugs = AGENTES.filter(a => a.name.toLowerCase().includes(nombre.toLowerCase().slice(0, 5))).slice(0, 6).map(a => a.name);
          await responder(s, jid, `No encontré un experto llamado "${nombre}".\nAlgunos parecidos:\n${sugs.length ? sugs.map(x => '• ' + x).join('\n') : '(escribe "!agentes" para ver áreas)'}\n\nO escribe "ia <consulta>" y elijo el mejor.`, m);
          return;
        }
      } else {
        agente = agenteMasRelevante(texto);
      }
      const reply = await askLLM(agente, texto);
      const encabezado = `🤖 ${agente.emoji || '🤖'} ${agente.name}\n(${agente.category})\n\n`;
      for (const parte of dividirMensaje(encabezado + reply, 3800)) {
        await responder(s, jid, parte, m);
      }
      return;
    }
    return;
  }

  const remitente = m.pushName || 'Cliente';
  registrar(numeroCliente(jid), remitente, 'cliente', cuerpo || (ubicacion ? '[ubicación compartida]' : ''));
  const items = parsearPedido(cuerpo);

  if (items.length === 0 && pendientesConfirmar.has(jid) && !esDueno) {
    if (/confirmar|confirmo/i.test(cuerpo) || /^s[íi]$/i.test(cuerpo)) {
      const pedido = pendientesConfirmar.get(jid);
      pendientesConfirmar.delete(jid);
      guardarPedido(pedido);
      console.log(`[PEDIDO] Aprobado por cliente #${pedido.id} | total ${config.moneda}${pedido.total.toLocaleString('es-CO')}`);
      await responder(s, jid, formatearConfirmacion(pedido, remitente), m);
      esperandoDireccion.set(jid, pedido.id);
      await responder(s, jid, config.pregunta_direccion, m);
    } else if (/cancelar|cancela/i.test(cuerpo)) {
      pendientesConfirmar.delete(jid);
      console.log('[PEDIDO] Pedido descartado por el cliente');
      await responder(s, jid, '✅ Listo, no registramos nada. Cuando quieras reescribe tu pedido.', m);
    } else {
      await responder(s, jid, '⚠️ Para confirmar este pedido responde CONFIRMAR. Si no es correcto, responde CANCELAR y escríbelo de nuevo.', m);
    }
    return;
  }

  if (items.length > 0) {
    const totalUnidades = items.reduce((s, i) => s + i.cantidad, 0);
    const pedido = {
      id: siguienteId(),
      fecha: new Date(Number(m.messageTimestamp) * 1000 || Date.now()).toISOString(),
      dia: fechaDia(),
      remitente,
      telefono: numeroCliente(jid),
      items,
      total: items.reduce((s, i) => s + i.subtotal, 0),
      crudo: cuerpo,
      direccion: '',
      estado: 'recibido'
    };
    if (totalUnidades > config.max_unidades_confirmar) {
      pendientesConfirmar.set(jid, pedido);
      console.log(`[PEDIDO] ⚠️ Sospechoso #${pedido.id} (${totalUnidades} unidades): esperando confirmación del cliente`);
      await responder(s, jid, `⚠️ ¿Son realmente ${totalUnidades} unidades?\n\nSi es correcto responde CONFIRMAR.\nSi no, responde CANCELAR y escríbelo de nuevo.`, m);
      return;
    }
    guardarPedido(pedido);
    console.log(`[PEDIDO] Guardado #${pedido.id} | total ${config.moneda}${pedido.total.toLocaleString('es-CO')}`);
    const ordenInfo = pedido.items.map(i => `• ${i.cantidad} x ${i.producto} = ${config.moneda}${i.subtotal.toLocaleString('es-CO')}`).join('\n') + `\nTOTAL: ${config.moneda}${pedido.total.toLocaleString('es-CO')}`;
    const respIA = await atenderClienteIA(jid, cuerpo, ordenInfo);
    if (esRespuestaDeError(respIA)) {
      await responder(s, jid, formatearConfirmacion(pedido, remitente), m);
      if (!esDueno) await responder(s, jid, config.pregunta_direccion, m);
    } else {
      for (const parte of dividirMensaje(respIA, 3800)) {
        await responder(s, jid, parte, m);
      }
      if (!esDueno) esperandoDireccion.set(jid, pedido.id);
    }
  } else if (esperandoDireccion.has(jid) && !esDueno) {
    const pendId = esperandoDireccion.get(jid);
    esperandoDireccion.delete(jid);
    if (ubicacion) {
      const latN = Number(ubicacion.lat);
      const lngN = Number(ubicacion.lng);
      const valida = Number.isFinite(latN) && Number.isFinite(lngN) &&
        latN >= -90 && latN <= 90 && lngN >= -180 && lngN <= 180 &&
        !(latN === 0 && lngN === 0);
      if (!valida) {
        esperandoDireccion.set(jid, pendId);
        console.log(`[DIRECCION] ⚠️ Pedido #${pendId}: ubicación inválida recibida (${ubicacion.lat},${ubicacion.lng})`);
        await responder(s, jid, '⚠️ No pude leer bien la ubicación. Envíala de nuevo (📎 → Ubicación) o escribe RECOGER si pasas por el local.', m);
        return;
      }
      const lat = latN.toFixed(6);
      const lng = lngN.toFixed(6);
      const etiqueta = [ubicacion.nombre, ubicacion.detalle].filter(Boolean).join(' - ');
      patchPedido(pendId, { direccion: etiqueta || 'Ubicación compartida', lat, lng });
      console.log(`[DIRECCION] Pedido #${pendId}: ubicación ${lat},${lng} ${etiqueta}`);
      await responder(s, jid, '✅ Ubicación recibida 📍\nEl repartidor abrirá el mapa y llevará el pedido exacto a esa dirección.', m);
    } else if (/cancelar|cancela/i.test(cuerpo)) {
      patchPedido(pendId, { direccion: 'Cancelado por cliente' });
      console.log(`[DIRECCION] Pedido #${pendId}: cancelado por el cliente`);
      await responder(s, jid, '✅ Listo, cancelamos la entrega. Tu pedido queda para recoger o escríbenos cuando quieras.', m);
    } else if (/recoge|recogida|pasar|recojo/i.test(cuerpo)) {
      patchPedido(pendId, { direccion: 'Recoge en el local' });
      console.log(`[DIRECCION] Pedido #${pendId}: recoge en el local`);
      await responder(s, jid, '✅ Perfecto, te esperamos para recoger tu pedido.', m);
    } else {
      esperandoDireccion.set(jid, pendId);
      await responder(s, jid, '⚠️ Solo acepto tu UBICACIÓN por GPS (botón 📎 → Ubicación) o la palabra RECOGER si pasas por el local. No se guardan otros textos.', m);
    }
    } else if (!esDueno) {
      if (esFueraDeTema(cuerpo)) {
        await responder(s, jid, `😊 Solo puedo ayudarte con pedidos y consultas de ${config.negocio}. ¿Quieres ordenar algo del menú?`, m);
      } else {
        const respIA = await atenderClienteIA(jid, cuerpo, null);
        if (esRespuestaDeError(respIA)) {
          await responder(s, jid, config.mensaje_fallback || config.mensaje_bienvenida, m);
        } else {
          for (const parte of dividirMensaje(respIA, 3800)) {
            await responder(s, jid, parte, m);
          }
        }
      }
    }
}

async function iniciarSesion() {
  const { state, saveCreds } = await useMultiFileAuthState(config.authDir);
  const { version } = await fetchLatestBaileysVersion();
  const s = makeWASocket({
    version,
    auth: state,
    printQRInTerminal: false,
    logger: pino({ level: 'silent' })
  });
  sock = s;
  s.ev.on('creds.update', saveCreds);

  s.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect } = update;
    if (update.qr) {
      console.log('\n[!] Escanea este QR con el WhatsApp del NEGOCIO: Ajustes > Dispositivos vinculados > Vincular dispositivo\n');
      qrcode.generate(update.qr, { small: true });
    }
    if (connection === 'open') {
      setSock(s);
      console.log(`[OK] ${config.negocio} conectado. Escuchando pedidos...`);
      console.log('[VISTO] Esperando mensajes...');
      cargarContactos(s, 0);
      setTimeout(() => {
        responder(s, DUENO_JID, `✅ El bot de ${config.negocio} está ACTIVO. Escribe un pedido y lo registramos.`)
          .then(() => console.log('[OK] Mensaje de prueba enviado al dueño.'))
          .catch(e => console.log('[!] No pude enviar mensaje de prueba:', e.message || e));
      }, 3000);
    }
    if (connection === 'close') {
      const statusCode = lastDisconnect && lastDisconnect.error && lastDisconnect.error.output
        ? lastDisconnect.error.output.statusCode
        : null;
      if (statusCode === DisconnectReason.loggedOut) {
        console.log('[!] La sesión fue cerrada desde el celular. Borra la carpeta "auth_info" y vuelve a abrir iniciar.bat para escanear de nuevo.');
      } else {
        console.log('[!] Conexión caída, reconectando en 5 segundos...');
        setTimeout(() => iniciarSesion(), 5000);
      }
    }
  });

  s.ev.on('contacts.upsert', (contactos) => {
    for (const c of contactos) {
      if (c.lid && c.jid) lidMap.set(c.lid, numDeCelular(c.jid));
    }
  });

  s.ev.on('messages.upsert', async ({ messages, type }) => {
    if (type !== 'notify' && type !== 'append') return;
    for (const m of messages) {
      if (!m.message) continue;
      const jid = m.key.remoteJid || '';
      if (!jid) continue;
      const idMsg = m.key.id || '';
      if (idsEnviados.has(idMsg) || procesadosIn.has(idMsg)) continue;
      const lmsg = m.message.locationMessage;
      const ubicacion = lmsg ? {
        lat: lmsg.degreesLatitude,
        lng: lmsg.degreesLongitude,
        nombre: lmsg.name || '',
        detalle: lmsg.address || ''
      } : null;
      const cuerpo = (m.message.conversation ||
        (m.message.extendedTextMessage && m.message.extendedTextMessage.text) || '').trim();
      console.log(`[VISTO] de ${jid} | fromMe=${!!m.key.fromMe} | texto="${cuerpo.slice(0, 100)}"${ubicacion ? ' | UBICACION ✓' : ''}`);
      if (jid.endsWith('@g.us')) continue;
      if (jid === 'status@broadcast') continue;
      if (!cuerpo && !ubicacion) continue;
      try {
        await procesar(s, m, jid, cuerpo, ubicacion);
      } catch (e) {
        console.error('[!] Error procesando mensaje:', e && e.message ? e.message : e);
      }
      procesadosIn.add(idMsg);
    }
  });
}

function programarReporteDiario() {
  const [h, mn] = config.hora_reporte.split(':').map(Number);
  const tarea = () => {
    const ahora = new Date();
    const min = ahora.getHours() * 60 + ahora.getMinutes();
    const objetivo = h * 60 + mn;
    if (min === objetivo && sock) {
      sock.sendMessage(DUENO_JID, { text: reporteHoyTexto() }).catch(() => {});
    }
  };
  setInterval(tarea, 60000);
}

async function iniciarWhatsApp() {
  programarReporteDiario();
  await iniciarSesion();
}

module.exports = { iniciarWhatsApp };
