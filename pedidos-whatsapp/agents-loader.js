const fs = require('fs');
const path = require('path');
const { config } = require('./config');

const AGENCY_DIR = path.join(__dirname, '..', 'agency-agents');

function loadAllAgents() {
  const agents = [];
  if (!fs.existsSync(AGENCY_DIR)) return agents;

  const categories = fs.readdirSync(AGENCY_DIR, { withFileTypes: true })
    .filter(dirent => dirent.isDirectory() && !dirent.name.startsWith('.'))
    .map(dirent => dirent.name);

  for (const cat of categories) {
    const catPath = path.join(AGENCY_DIR, cat);
    const files = fs.readdirSync(catPath).filter(f => f.endsWith('.md'));
    for (const file of files) {
      try {
        const filePath = path.join(catPath, file);
        const content = fs.readFileSync(filePath, 'utf8');
        
        // Parse frontmatter
        const fmMatch = content.match(/^---\s*([\s\S]*?)\s*---/);
        let meta = { name: file.replace('.md', ''), description: '', emoji: '🤖', vibe: '', category: cat };
        
        if (fmMatch) {
          const fmLines = fmMatch[1].split('\n');
          for (const line of fmLines) {
            const parts = line.split(':');
            if (parts.length >= 2) {
              const key = parts[0].trim();
              const val = parts.slice(1).join(':').trim();
              meta[key] = val;
            }
          }
        }

        const body = content.replace(/^---\s*([\s\S]*?)\s*---/, '').trim();
        
        agents.push({
          id: `${cat}/${file.replace('.md', '')}`,
          category: cat,
          filename: file,
          name: meta.name,
          description: meta.description || 'Agente especialista en IA',
          emoji: meta.emoji || '🤖',
          vibe: meta.vibe || '',
          systemPrompt: body.slice(0, 4000) // limit prompt size for API
        });
      } catch (err) {
        console.error(`Error loading agent ${file}:`, err.message);
      }
    }
  }

  return agents;
}

function loadAgentesUtiles() {
  const all = loadAllAgents();
  const cats = (config.agencias_categorias || []).map(c => String(c).toLowerCase());
  if (!cats.length) return all;
  return all.filter(a => cats.includes(String(a.category).toLowerCase()));
}

module.exports = { loadAllAgents, loadAgentesUtiles };
