# language: it
Funzionalità: Carrello
  Contesto:
    Dato un carrello vuoto

  Scenario: Aggiunta di un articolo
    Quando aggiungo 1 articoli
    Allora il carrello contiene 1 articoli

  Schema dello scenario: Aggiunte multiple
    Quando aggiungo <n> articoli
    Allora il carrello contiene <attesi> articoli

    Esempi:
      | n | attesi |
      | 2 | 2      |
      | 3 | 4      |

  Scenario: Frase senza binding
    Quando premo un bottone inesistente
