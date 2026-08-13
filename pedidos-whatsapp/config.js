const fs = require('fs');
const path = require('path');

function resolverRutaConfig() {
  const args = process.argv.slice(2);
  const i = args.indexOf('--cliente');
  let p = i !== -1 ? args[i + 1] : process.env.CLIENTE_CONFIG;
  if (!p) p = 'config.json';
  return path.isAbsolute(p) ? p : path.join(__dirname, p);
}

const CONFIG_PATH = resolverRutaConfig();
const esConfigPorDefecto = CONFIG_PATH.replace(/\\/g, '/').endsWith('config.json');

const config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));

const clienteId = config.id || (esConfigPorDefecto ? 'default' : path.basename(CONFIG_PATH, '.json'));
config.clienteId = clienteId;

const DATA_DIR = esConfigPorDefecto
  ? path.join(__dirname, 'data')
  : path.join(__dirname, 'data', clienteId);
config.dataDir = DATA_DIR;

config.authDir = config.auth_dir
  ? path.resolve(__dirname, config.auth_dir)
  : path.join(__dirname, esConfigPorDefecto ? 'auth_info' : 'auth_info_' + clienteId);

if (config.puerto && process.env.PORT_OVERRIDE) {
  config.puerto = parseInt(process.env.PORT_OVERRIDE, 10) || config.puerto;
}

function leerApiKey() {
  if (config.llm && config.llm.api_key) return config.llm.api_key;
  if (process.env.LLM_API_KEY) return process.env.LLM_API_KEY;
  const f = path.join(__dirname, '.llm_key');
  if (fs.existsSync(f)) return fs.readFileSync(f, 'utf8').trim();
  return '';
}
const LLM_API_KEY = leerApiKey();

function normalizar(t) {
  return t.toLowerCase().normalize('NFD').replace(/[^\x00-\x7F]/g, '');
}
function escaparRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function csvCell(v) {
  const s = String(v == null ? '' : v).replace(/"/g, '""');
  return /^[=+\-@]/.test(s) ? '"' + s + '"' : s;
}
function fechaDia() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
function hoyInicio() {
  return `${fechaDia()}T00:00`;
}
function numDeCelular(id) {
  const solo = String(id).split('@')[0].split(':')[0];
  return solo.replace(/\D/g, '');
}

module.exports = { config, LLM_API_KEY, normalizar, escaparRegex, esc, csvCell, fechaDia, hoyInicio, numDeCelular };
