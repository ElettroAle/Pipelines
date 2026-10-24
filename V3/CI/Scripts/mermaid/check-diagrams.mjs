// Legge i diagrammi da un file JSON [{ id, text }] e scrive, per ognuno, l'esito
// del parse con elementi e relazioni: la verifica della documentazione li confronta
// con il testo della sezione che mostra il diagramma.
import { readFileSync, writeFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body></body></html>');
globalThis.window = dom.window;
globalThis.document = dom.window.document;
const { default: mermaid } = await import('mermaid');
mermaid.initialize({ startOnLoad: false });

const NOTE = 2;
const PSEUDO_STATE = /^root_(start|end)$|_start$|_end$/;

function describeSequence(db) {
  const actors = db.getActors();
  const name = id => actors.get(id)?.description || id;
  return {
    elements: [...actors.values()].map(actor => actor.description || actor.name),
    relationships: db.getMessages()
      .filter(message => message.from && message.to && message.from !== message.to && message.type !== NOTE)
      .map(message => [name(message.from), name(message.to)])
  };
}

function describeState(db) {
  const isState = id => !PSEUDO_STATE.test(id);
  return {
    elements: [...db.getStates().keys()].filter(isState),
    relationships: db.getRelations()
      .filter(relation => isState(relation.id1) && isState(relation.id2))
      .map(relation => [relation.id1, relation.id2])
  };
}

function describeFlowchart(db) {
  const vertices = db.getVertices();
  const name = id => vertices.get(id)?.text || id;
  return {
    elements: [...vertices.values()].map(vertex => vertex.text || vertex.id),
    relationships: db.getEdges().map(edge => [name(edge.start), name(edge.end)])
  };
}

const describers = [
  [/^sequence/, describeSequence],
  [/^state/, describeState],
  [/^flowchart/, describeFlowchart]
];

async function check({ id, text }) {
  try {
    const diagram = await mermaid.mermaidAPI.getDiagramFromText(text);
    const describe = describers.find(([type]) => type.test(diagram.type))?.[1];
    return { id, type: diagram.type, ...(describe ? describe(diagram.db) : { elements: [], relationships: [] }) };
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
