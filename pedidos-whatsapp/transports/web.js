const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { config, esc, csvCell, hoyInicio } = require('../config');
const { leerPedidos, resumenDe, cambiarEstado } = require('../core/orders');
const { notificar } = require('../core/notify');
const { hilos, leerHilo } = require('../core/conversacion');
const { askLLM } = require('../core/ai');
const { loadAgentesUtiles } = require('../agents-loader');

const AGENTES = loadAgentesUtiles();
const DASHBOARD = path.join(__dirname, '..', 'dashboard.html');
const SESIONES = new Set();

function estadoHtml(p) {
  const est = p.estado || 'recibido';
  const colores = { recibido: '#ff9800', en_cocina: '#2196f3', listo: '#4caf50', entregado: '#607d8b', cancelado: '#f44336' };
  const label = { recibido: 'Recibido', en_cocina: 'En cocina', listo: 'Listo', entregado: 'Entregado', cancelado: 'Cancelado' };
  const color = colores[est] || '#888';
  const badge = `<span style="background:${color};color:#fff;padding:2px 8px;border-radius:10px;font-size:.75rem;font-weight:700">${label[est] || est}</span>`;
  const btn = (estado, texto, bg) => `<button onclick="cambiarEstado(${p.id},'${estado}')" style="background:${bg};color:#fff;border:none;padding:2px 6px;border-radius:4px;cursor:pointer;font-size:.72rem;margin:2px">${texto}</button>`;
  let bots = '<span style="color:#999">—</span>';
  if (est === 'recibido') bots = btn('en_cocina', '👨‍🍳 Cocina', '#075e54') + btn('listo', '✅ Listo', '#25D366') + btn('cancelado', '❌', '#f44336');
  else if (est === 'en_cocina') bots = btn('listo', '✅ Listo', '#25D366') + btn('cancelado', '❌', '#f44336');
  else if (est === 'listo') bots = btn('entregado', '🚚 Entregado', '#607d8b');
  return `<td>${badge}<br><span style="display:inline-block;margin-top:4px">${bots}</span></td>`;
}

function tokenValido(req) {
  const c = req.headers.cookie || '';
  const m = c.match(/(?:^|;\s*)panel_token=([^;]+)/);
  return m && SESIONES.has(m[1]);
}

function paginaLogin(error) {
  return `<!doctype html><html lang="es"><head><meta charset="utf-8"><title>Acceso ${esc(config.negocio)}</title>
<style>body{font-family:Arial,Segoe UI,sans-serif;background:#075e54;color:#fff;display:flex;height:100vh;align-items:center;justify-content:center}
form{background:#fff;color:#333;padding:2rem 2.5rem;border-radius:10px;text-align:center;box-shadow:0 4px 16px rgba(0,0,0,.3)}
h2{margin-top:0;color:#075e54}input{padding:.6rem;width:220px;margin:.6rem 0;border:1px solid #ccc;border-radius:6px;font-size:1rem}
button{background:#25D366;color:#fff;border:none;padding:.6rem 1.4rem;border-radius:6px;cursor:pointer;font-weight:700;font-size:1rem}
.msg{color:#c00;margin-top:.4rem;font-size:.9rem}</style></head>
<body><form method="post" action="/login"><h2>Acceso al panel</h2>
<input name="password" type="password" placeholder="Contraseña del panel" autofocus><br>
<button type="submit">Entrar</button>${error ? `<div class="msg">${esc(error)}</div>` : ''}</form></body></html>`;
}

function iniciarWeb() {
  const server = http.createServer(async (req, res) => {
    const url = req.url.split('?')[0];

    const pw = config.panel_password || '';
    if (pw) {
      if (url === '/login' && req.method === 'POST') {
        let body = '';
        req.on('data', c => { body += c; });
        req.on('end', () => {
          try {
            const params = new URLSearchParams(body);
            if (params.get('password') === pw) {
              const t = crypto.randomBytes(16).toString('hex');
              SESIONES.add(t);
              res.writeHead(302, { 'Set-Cookie': `panel_token=${t}; HttpOnly; Path=/; SameSite=Lax`, 'Location': '/' });
              res.end();
            } else {
              res.writeHead(401, { 'Content-Type': 'text/html; charset=utf-8' });
              res.end(paginaLogin('Contraseña incorrecta'));
            }
          } catch {
            res.writeHead(400, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(paginaLogin('Solicitud inválida'));
          }
        });
        return;
      }
      if (!tokenValido(req)) {
        res.writeHead(401, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(paginaLogin());
        return;
      }
    }

    if (url === '/api/agents') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(AGENTES.map(a => ({ id: a.id, name: a.name, category: a.category, description: a.description, emoji: a.emoji, vibe: a.vibe }))));
      return;
    }

    if (url === '/api/agent-chat' && req.method === 'POST') {
      let body = '';
      req.on('data', chunk => { body += chunk; });
      req.on('end', async () => {
        try {
          const data = JSON.parse(body);
          const agent = AGENTES.find(a => a.id === data.agentId);
          if (!agent) {
            res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(JSON.stringify({ error: 'Agente no encontrado' }));
            return;
          }
          const reply = await askLLM(agent, data.message || 'Hola');
          res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ reply }));
        } catch (e) {
          res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ error: e.message }));
        }
      });
      return;
    }

    if (url === '/api/pedidos') {
      const pedidos = leerPedidos().reverse();
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(pedidos));
      return;
    }

    if (url === '/api/conversaciones') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(hilos()));
      return;
    }

    if (url.startsWith('/api/conversacion')) {
      const u = new URL(req.url, 'http://localhost');
      const tel = u.searchParams.get('tel') || '';
      const msgs = leerHilo(tel).map(m => ({
        fecha: new Date(m.fecha).toLocaleString('es-CO'),
        rol: m.rol,
        texto: m.texto
      }));
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(msgs));
      return;
    }

    if (url.startsWith('/api/pedido/') && req.method === 'POST') {
      const m = url.match(/^\/api\/pedido\/(\d+)\/estado$/);
      if (m) {
        let body = '';
        req.on('data', c => { body += c; });
        req.on('end', async () => {
          try {
            const data = JSON.parse(body || '{}');
            const id = parseInt(m[1], 10);
            const pedido = cambiarEstado(id, data.estado);
            if (pedido && data.estado === 'listo' && pedido.telefono) {
              const ok = await notificar(pedido.telefono + '@s.whatsapp.net', `✅ ¡Tu pedido #${pedido.id} está LISTO! ${config.negocio} te avisa.`);
              console.log('[KDS] Aviso a cliente:', ok ? 'enviado' : 'no enviado (bot puede estar apagado)');
            }
            res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(JSON.stringify({ ok: true, estado: pedido ? pedido.estado : null }));
          } catch (e) {
            res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(JSON.stringify({ error: e.message }));
          }
        });
        return;
      }
    }

    if (url === '/export.csv') {
      const pedidos = leerPedidos();
      const filas = ['id;fecha;remitente;telefono;detalle;total;direccion;lat;lng;mensaje_original'];
      for (const p of pedidos) {
        filas.push([
          p.id, p.fecha, csvCell(p.remitente), p.telefono,
          p.items.map(i => `${i.cantidad} ${i.producto}`).join(' | '),
          p.total, csvCell((p.direccion || '').replace(/;/g, ',')), p.lat || '', p.lng || '',
          `"${(p.crudo || '').replace(/"/g, '""')}"`
        ].join(';'));
      }
      res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8' });
      res.end(filas.join('\n'));
      return;
    }

    const pedidos = leerPedidos();
    const r = resumenDe(pedidos, hoyInicio());
    const totalHistorico = resumenDe(pedidos).total;
    const filasHtml = pedidos.slice().reverse().slice(0, 100).map(p => {
      const dirCelda = p.lat
        ? `<a href="https://maps.google.com/?q=${p.lat},${p.lng}" target="_blank" style="color:#25D366;font-weight:bold">📌 Ver mapa</a>`
        : esc(p.direccion || '-');
      return `<tr><td>#${p.id}</td><td>${new Date(p.fecha).toLocaleString('es-CO')}</td><td>${esc(p.remitente)}</td><td>${p.items.map(i => `${i.cantidad} ${i.producto}`).join(', ')}</td><td>${dirCelda}</td><td>${config.moneda}${p.total.toLocaleString('es-CO')}</td><td>${p.telefono || '-'}</td>${estadoHtml(p)}</tr>`;
    }).join('');

    let html = fs.readFileSync(DASHBOARD, 'utf8');
    html = html
      .replaceAll('{{negocio}}', config.negocio)
      .replaceAll('{{pedidosHoy}}', r.pedidos)
      .replaceAll('{{moneda}}', config.moneda)
      .replaceAll('{{ventasHoy}}', r.total.toLocaleString('es-CO'))
      .replaceAll('{{ventasTotal}}', totalHistorico.toLocaleString('es-CO'))
      .replaceAll('{{filasHtml}}', filasHtml);
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
  });

  server.listen(config.puerto, () => {
    console.log(`[OK] Tablero web: http://localhost:${config.puerto}`);
  }).on('error', (e) => {
    if (e.code === 'EADDRINUSE') {
      console.log('[!] Ya hay OTRO bot de pedidos corriendo en esta laptop. Cierra TODAS las ventanas negras y abre SOLO UNA vez iniciar.bat.');
      console.log('[!] Este bot se apaga solo en 5 segundos.');
      setTimeout(() => process.exit(1), 5000);
    } else {
      console.log('[!] Error del servidor web:', e.message);
    }
  });
}

module.exports = { iniciarWeb };
