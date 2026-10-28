// Legge i diagrammi da un file JSON [{ id, text }] e scrive, per ognuno, l'esito
// del parse: il tipo del diagramma con partecipanti e chiamate di un diagramma di sequenza
// o le classi di un diagramma delle classi, oppure l'errore con la riga.
import { readFileSync, writeFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body></body></html>');
globalThis.window = dom.window;
globalThis.document = dom.window.document;
const { default: mermaid } = await import('mermaid');
mermaid.initialize({ startOnLoad: false });

// Le frecce tratteggiate sono risposte: una chiamata e' una freccia piena fra due partecipanti.
function describeSequence(db) {
  const actors = db.getActors();
  const name = (alias) => actors.get(alias)?.description ?? alias;
  const replies = new Set(Object.entries(db.LINETYPE).filter(([kind]) => kind.includes('DOTTED')).map(([, value]) => value));
  const calls = db.getMessages()
    .filter((message) => message.from && message.to && message.type !== db.LINETYPE.NOTE && !replies.has(message.type))
    .map((message) => ({ from: name(message.from), to: name(message.to) }));
  return { participants: [...actors.values()].map((actor) => actor.description), calls };
}

function describe(diagram) {
  if (diagram.type === 'sequence') return describeSequence(diagram.db);
  if (diagram.type === 'classDiagram') return { classes: [...diagram.db.getClasses().values()].map((item) => item.label) };
  return {};
}

async function check({ id, text }) {
  try {
    const diagram = await mermaid.mermaidAPI.getDiagramFromText(text);
    return { id, type: diagram.type, ...describe(diagram) };
  } catch (error) {
    const message = String(error?.message ?? error);
    const line = Number(/on line (\d+)/.exec(message)?.[1] ?? 1);
    const lines = message.split('\n').filter(Boolean);
    return { id, error: [...new Set([lines[0], lines.at(-1)])].join(' '), line };
  }
}

const [input, output] = process.argv.slice(2);
const diagrams = JSON.parse(readFileSync(input, 'utf8'));
const results = [];
for (const diagram of diagrams) results.push(await check(diagram));
writeFileSync(output, JSON.stringify(results));
