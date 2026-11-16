// SPDX-License-Identifier: Apache-2.0

// Disegna con Chrome headless, aperto una volta sola, i diagrammi Mermaid di un file JSON
// [{ id, text }] in PNG nella cartella di uscita (comando diagrams), oppure stampa una pagina HTML
// in PDF A4 con il segnalibro di ogni titolo (comando pdf).
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import puppeteer from 'puppeteer';
import { renderMermaid } from '@mermaid-js/mermaid-cli';

// Il sandbox di Chrome richiede namespace utente che Ubuntu 24.04 nega ai processi senza privilegi;
// le pagine disegnate vengono dal repository, non dalla rete.
const browser = await puppeteer.launch({ headless: 'shell', args: ['--no-sandbox'] });

async function drawDiagrams(input, outputDirectory) {
  const diagrams = JSON.parse(readFileSync(input, 'utf8'));
  for (const { id, text } of diagrams) {
    try {
      const { data } = await renderMermaid(browser, text, 'png', { viewport: { width: 1200, height: 800, deviceScaleFactor: 2 } });
      writeFileSync(join(outputDirectory, `${id}.png`), data);
    } catch (error) {
      throw new Error(`diagramma ${id}: ${String(error?.message ?? error).split('\n')[0]}`);
    }
  }
}

async function printPdf(input, output) {
  const page = await browser.newPage();
  await page.goto(pathToFileURL(input).href, { waitUntil: 'load' });
  await page.pdf({ path: output, format: 'A4', printBackground: true, outline: true, tagged: true });
}

try {
  const [command, input, output] = process.argv.slice(2);
  if (command === 'diagrams') await drawDiagrams(input, output);
  else if (command === 'pdf') await printPdf(input, output);
  else throw new Error(`comando sconosciuto: ${command}`);
} catch (error) {
  console.error(String(error?.message ?? error));
  process.exitCode = 1;
} finally {
  await browser.close();
}
