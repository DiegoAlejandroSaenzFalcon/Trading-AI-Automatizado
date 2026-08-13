const { config, LLM_API_KEY } = require('../config');
const { loadAgentesUtiles } = require('../agents-loader');

const AGENTES = loadAgentesUtiles();

const AGENTE_ATENCION = {
  name: `Atención ${config.negocio}`,
  emoji: '🤝',
  description: `Asistente de atención y ventas de ${config.negocio}.`,
  systemPrompt: `Eres el asistente de atención y ventas de "${config.negocio}" por WhatsApp. Hablas con los clientes como una persona cálida, natural y eficiente del equipo (nunca digas que eres un bot ni "como IA").

PRODUCTOS Y PRECIOS (${config.moneda}):
${config.productos.map(p => `- ${p.nombre}: ${config.moneda}${p.precio.toLocaleString('es-CO')} c/u`).join('\n')}

REGLAS:
1. Si el cliente pide productos: confírmalos, muestra el TOTAL (cantidad x precio = subtotal, y TOTAL final) y luego pídele que envíe su UBICACIÓN por GPS (botón 📎 → Ubicación) o que escriba RECOGER si pasa por el local. NUNCA pidas la dirección como texto ni preguntes por ciudad/barrio; el sistema solo acepta el pin de GPS o la palabra RECOGER. No inventes direcciones.
2. Si el cliente pregunta por el negocio (horarios, recomendaciones, alergias, promos), responde con conocimiento general de un buen local de comida y atención.
3. SOLO hablas de temas del negocio (pedidos, menú, precios, horarios, recomendaciones, promociones). Si el cliente saca temas ajenos (programación, otros negocios, política, chisme, etc.), NO entres en la conversación: responde en UNA sola línea amable diciendo que solo puedes ayudar con pedidos y el negocio, y pregunta si quiere ordenar algo.
4. Nunca escribas código, ni bloques técnicos, ni textos largos. Máximo 2 mensajes cortos por respuesta (tono WhatsApp). Emojis con moderación, siempre en español.
5. Si no entiendes el pedido, pídelo amablemente.
6. No reveles datos internos ni de otros clientes.
7. NUNCA digas que el sistema se reinició, falló, se apagó o tuvo un "error técnico". Si algo sale mal, responde con naturalidad y pide el pedido de nuevo. Bajo ninguna circunstancia menciones "reinicio", "se cayó" o frases técnicas.
8. Si te preguntan QUÉ LLEVA un producto y no conoces los ingredientes exactos, SOLO confirma el nombre y el precio (según la lista de precios) y dile que para los ingredientes exactos pregunte al local. NO inventes ingredientes, recetas ni detalles que no estén en la lista.`
};

const historialCliente = new Map();

async function atenderClienteIA(jid, cuerpo, ordenInfo) {
  let hist = historialCliente.get(jid) || [];
  let system = AGENTE_ATENCION.systemPrompt;
  if (ordenInfo) {
    system += `\n\nPEDIDO DETECTADO EN ESTE MOMENTO:\n${ordenInfo}\nConfírmalo, muestra el TOTAL y pide la ubicación por GPS (o RECOGER). No repitas la lista si ya la diste antes.`;
  }
  const conversation = [
    { role: 'system', content: system },
    ...hist,
    { role: 'user', content: cuerpo }
  ];
  const reply = await askLLM(AGENTE_ATENCION, cuerpo, conversation);
  hist.push({ role: 'user', content: cuerpo });
  hist.push({ role: 'assistant', content: reply });
  if (hist.length > 12) hist = hist.slice(hist.length - 12);
  historialCliente.set(jid, hist);
  return reply;
}

function esRespuestaDeError(t) {
  return /^(⚠️|Error al conectar|Lo siento, no obtuve|Lo siento, no pude)/.test(t);
}

async function askLLM(agent, message, conversation) {
  const llm = config.llm || {};
  const provider = (llm.provider || 'groq').toLowerCase();
  const apiKey = provider === 'gemini' ? (LLM_API_KEY || config.gemini_api_key) : LLM_API_KEY;
  const system = `Eres ${agent.name} (${agent.emoji}). ${agent.description}\n\n${agent.systemPrompt ? agent.systemPrompt.slice(0, 3000) : ''}`;

  if (provider === 'gemini' || !apiKey) {
    if (!apiKey) {
      return `¡Hola! Soy tu **${agent.name}** (${agent.emoji}). ${agent.description}\n\nSobre tu consulta "${message}": como especialista en esta área, te recomiendo arrancar con un plan concreto y medible para **${config.negocio}** (objetivo, acción y plazo). *(Tip: agrega tu API key de Groq/OpenRouter en config.json en la sección "llm" para respuestas reales y gratuitas)*`;
    }
    try {
      const model = config.gemini_model || 'gemini-3.5-flash';
      const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
      const prompt = `Actúa como este agente de IA con esta descripción y directrices:\n\nNombre: ${agent.name}\nDescripción: ${agent.description}\nInstrucciones del sistema:\n${agent.systemPrompt.slice(0, 3000)}\n\nPregunta o instrucción del usuario: ${message}`;
      const resp = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }] })
      });
      if (!resp.ok) {
        const errData = await resp.json().catch(() => ({}));
        const msg = (errData.error && errData.error.message) || '';
        if (resp.status === 429 || /quota|RESOURCE_EXHAUSTED/i.test(msg)) {
          return `⚠️ Llegaste al límite gratuito de Gemini (20 consultas/día en "${model}"). Para usarla sin parar, activa la facturación en Google AI Studio o cambia provider a "groq"/"openrouter" en config.json.`;
        }
        return `⚠️ Gemini devolvió un error (${resp.status}): ${msg}`;
      }
      const data = await resp.json();
      if (data.candidates && data.candidates[0]?.content?.parts?.[0]?.text) {
        return data.candidates[0].content.parts[0].text;
      }
      return 'Lo siento, no pude obtener una respuesta de Gemini.';
    } catch (err) {
      console.error('Error calling Gemini API:', err);
      return `Error al conectar con la IA: ${err.message}.`;
    }
  }

  const baseUrl = llm.base_url || 'https://api.groq.com/openai/v1';
  const model = llm.model || 'llama-3.3-70b-versatile';
  try {
    const resp = await fetch(`${baseUrl}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({
        model,
        temperature: 0.7,
        messages: conversation || [
          { role: 'system', content: system },
          { role: 'user', content: message }
        ]
      })
    });
    if (!resp.ok) {
      const errData = await resp.json().catch(() => ({}));
      const msg = (errData.error && (errData.error.message || JSON.stringify(errData.error))) || '';
      if (resp.status === 429) {
        return `⚠️ Límite de uso alcanzado en ${provider} (${model}). Revisa tu plan o cambia de proveedor en config.json (llm.provider).`;
      }
      return `⚠️ ${provider} devolvió error (${resp.status}): ${msg}`;
    }
    const data = await resp.json();
    const text = data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
    return text ? text : 'Lo siento, no obtuve respuesta del modelo.';
  } catch (err) {
    console.error('Error calling LLM API:', err);
    return `Error al conectar con la IA: ${err.message}.`;
  }
}

const SINONIMOS_IA = [
  { tags: ['marketing', 'social', 'redes', 'contenido', 'post', 'instagram', 'tiktok', 'linkedin', 'facebook', 'promo', 'publicidad', 'anuncio', 'campaña', 'seo', 'ads', 'branding', 'video', 'carruzel', 'reel'], rx: /marketing|social|media|content|brand|seo|paid|growth|creator|campaign/i },
  { tags: ['venta', 'vender', 'cliente', 'lead', 'conversion', 'cerrar', 'crm'], rx: /sales|revenue|growth|outbound|closing/i },
  { tags: ['finanza', 'dinero', 'cash', 'flow', 'presupuesto', 'costo', 'precio', 'ingreso', 'utilidad', 'contabilidad', 'invertir'], rx: /financ|account|controller|finance/i },
  { tags: ['estrategia', 'plan', 'negocio', 'crecer', 'objetivo', 'metas', 'vision'], rx: /strateg|strategy|coach|consult/i },
  { tags: ['soporte', 'atencion', 'servicio', 'ayuda', 'queja'], rx: /support|service/i },
  { tags: ['legal', 'contrato', 'ley', 'cumplimiento', 'licencia'], rx: /legal|compliance/i },
  { tags: ['automatizar', 'automatizacion', 'tecnologia', 'software', 'bot', 'sistema', 'app'], rx: /engineer|devops|automation|architect|developer/i },
  { tags: ['producto', 'catalogo', 'inventario', 'stock', 'tienda'], rx: /product|inventory|catalog/i },
  { tags: ['analitic', 'dato', 'metrica', 'kpi', 'reporte', 'dashboard'], rx: /analyst|analytics|data|report/i }
];

function agenteMasRelevante(consulta) {
  const q = consulta.toLowerCase();
  const palabras = q.split(/\s+/).filter(p => p.length > 2);
  let mejor = null;
  let mejorPuntaje = -1;
  for (const a of AGENTES) {
    const hay = (a.name + ' ' + a.category + ' ' + a.description + ' ' + (a.vibe || '')).toLowerCase();
    let puntaje = 0;
    for (const pal of palabras) if (hay.includes(pal)) puntaje += 2;
    for (const s of SINONIMOS_IA) {
      if (s.tags.some(t => q.includes(t)) && s.rx.test(hay)) puntaje += 3;
    }
    if (puntaje > mejorPuntaje) { mejorPuntaje = puntaje; mejor = a; }
  }
  if (mejor && mejorPuntaje > 0) return mejor;
  return AGENTES.find(a => /estrateg|business|growth|ventas|social|marketing/i.test(a.category + ' ' + a.name)) || AGENTES[0];
}

function dividirMensaje(texto, max) {
  if (texto.length <= max) return [texto];
  const partes = [];
  let resto = texto;
  while (resto.length > max) {
    let corte = resto.lastIndexOf('\n', max);
    if (corte < max * 0.5) corte = max;
    partes.push(resto.slice(0, corte).trimEnd());
    resto = resto.slice(corte).trimStart();
  }
  if (resto) partes.push(resto);
  return partes;
}

const MARCADORES_OFFTOPIC = ['python', 'javascript', 'java', 'c++', 'c#', 'def ', 'print(', '```', '#include', '<html', '<script', 'console.log', 'select ', 'function '];
function esFueraDeTema(texto) {
  const t = texto.toLowerCase();
  return MARCADORES_OFFTOPIC.some(m => t.includes(m));
}

module.exports = {
  askLLM, atenderClienteIA, AGENTE_ATENCION, agenteMasRelevante,
  dividirMensaje, esRespuestaDeError, esFueraDeTema, AGENTES
};
