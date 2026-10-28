// SPDX-License-Identifier: Apache-2.0

// Legge i diagrammi da un file JSON [{ id, text }] e scrive, per ognuno, l'esito
// del parse: il tipo del diagramma, oppure l'errore con la riga.
import { readFileSync, writeFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body></body></html>');
globalThis.window = dom.window;
globalThis.document = dom.window.document;
const { default: mermaid } = await import('mermaid');
mermaid.initialize({ startOnLoad: false });

async function check({ id, text }) {
  try {
    const diagram = await mermaid.mermaidAPI.getDiagramFromText(text);
    return { id, type: diagram.type };
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
