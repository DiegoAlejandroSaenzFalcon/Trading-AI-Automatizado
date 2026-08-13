let sockActivo = null;

function setSock(s) {
  sockActivo = s;
}

function haySock() {
  return !!sockActivo;
}

async function notificar(jid, texto) {
  if (!sockActivo) return false;
  try {
    await sockActivo.sendMessage(jid, { text: texto });
    return true;
  } catch (e) {
    console.error('[NOTIFY] No pude avisar al cliente:', e && e.message ? e.message : e);
    return false;
  }
}

module.exports = { setSock, haySock, notificar };
