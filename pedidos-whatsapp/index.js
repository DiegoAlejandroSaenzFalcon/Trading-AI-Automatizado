const { config } = require('./config');
const { iniciarWhatsApp } = require('./transports/whatsapp');
const { iniciarWeb } = require('./transports/web');
const { loadAllAgents, loadAgentesUtiles } = require('./agents-loader');

console.log(`[IA] Agencia cargada: ${loadAgentesUtiles().length} expertos útiles de ${loadAllAgents().length} totales.`);

iniciarWhatsApp().catch(e => console.error('[!] Error de sesión:', e));
iniciarWeb();
