# language: it
Funzionalità: Carrello
  Contesto:
    Dato un carrello vuoto

  Scenario: Aggiunta di un articolo
    Quando aggiungo 1 articoli
    Allora il carrello contiene 1 articoli

  Schema dello scenario: Aggiunte multiple
    Quando aggiungo <n> articoli
    Allora il carrello contiene <n> articoli

    Esempi:
      | n |
      | 2 |
      | 3 |

  @ignore
  Scenario: Svuotamento in attesa di traduzione
    Quando svuoto il carrello

  Regola: Il carrello conta gli articoli
    Scenario: Due aggiunte si sommano
      Quando aggiungo 1 articoli
      E aggiungo 1 articoli
      Allora il carrello contiene 2 articoli
