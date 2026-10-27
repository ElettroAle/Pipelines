# Test Suite — Azure DevOps Pipeline Templates

Suite di test a 2 livelli per verificare la correttezza dei template V3 prima di ogni PR.
I livelli 1 e 2 girano interamente su GitHub Actions senza bisogno di Azure DevOps.

---

## Struttura

```
Tests/
├── static/                     # Livello 1: analisi statica YAML
│   ├── .yamllint.yaml          # Config yamllint
│   ├── requirements.txt        # Dipendenze Python
│   ├── check-references.py     # Verifica che ogni template: esista su disco
│   └── check-parameters.py     # Verifica contratti parametri (unknown + required)
├── scripts/                    # Livello 2: unit test PowerShell (Pester)
│   ├── Set-Versioning.Tests.ps1
│   ├── Verify-SemVer.Tests.ps1
│   ├── New-ReleaseNotes.Tests.ps1
│   ├── Test-PublishedArtifact.Tests.ps1
│   ├── Test-AdrCorpus.Tests.ps1
│   ├── Test-Arc42Document.Tests.ps1
│   ├── Test-C4Model.Tests.ps1
│   ├── Test-MermaidDiagrams.Tests.ps1
│   ├── Test-Documentation.Tests.ps1
│   ├── Test-DocumentationStyle.Tests.ps1
│   ├── MarkdownText.Tests.ps1
│   ├── GitCliff.Tests.ps1
│   └── ScenarioCoverage.Tests.ps1
├── fixtures/
│   ├── valid-commits.txt       # Messaggi commit validi — usati da Verify-SemVer.Tests
│   ├── invalid-commits.txt     # Messaggi commit non validi — usati da Verify-SemVer.Tests
│   ├── documentation/          # Documento valido condiviso e template arc42 italiano ufficiale — usati dai test della documentazione
│   └── scenario-coverage/      # .feature + Cucumber Messages reali (Reqnroll 3.3.4) — usati da ScenarioCoverage.Tests
└── preview/                    # Livello 3: pipeline ADO per az pipelines run --preview
    ├── quality-dotNet.yaml
    └── publish-dotNet.yaml
```

---

## Livello 1 — Static Analysis

### Prerequisiti
- Python 3.12+
- `pip install -r Tests/static/requirements.txt`

### Esecuzione locale

```bash
# Da root del repo

# 1. YAML Lint su tutta V3/
yamllint -c Tests/static/.yamllint.yaml V3/ V4/

# 2. Verifica che ogni 'template: path/file.yaml' esista su disco
python Tests/static/check-references.py

# 3. Verifica contratti parametri (nomi passati ⊆ nomi definiti)
python Tests/static/check-parameters.py
```

### Cosa controlla

| Check | Cosa trova |
|---|---|
| `yamllint` | Sintassi YAML invalida, tab, trailing spaces, linee troppo lunghe |
| `check-references.py` | `template: path/che/non/esiste.yaml` |
| `check-parameters.py` | Parametri passati a un template che non li accetta (typo, rename) |

---

## Livello 2 — Script Unit Tests (Pester)

### Prerequisiti
- PowerShell 7+
- Pester 5+: `Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser`
- `git` installato e disponibile nel PATH
- .NET SDK 10+ (solo per `ScenarioCoverage.Tests.ps1`: lo script è una file-based app, `dotnet run` scarica il pacchetto `Gherkin` da nuget.org)

### Esecuzione locale

```powershell
# Da root del repo
Invoke-Pester Tests/scripts/ -Output Detailed
```

Per eseguire solo un file:
```powershell
Invoke-Pester Tests/scripts/Verify-SemVer.Tests.ps1 -Output Detailed
```

### Cosa controlla

#### `Set-Versioning.Tests.ps1` (4 suite, ~15 test)

| Suite | Scenario testato |
|---|---|
| `REQUIRE_TAG=false` | Prerelease `{prossima versione}-dev.{BuildId}` senza tag, `PRERELEASE_LABEL`, patch successiva se HEAD è sul tag, `assemblyVersion` numerico |
| `REQUIRE_TAG=true, incremento` | `fix:`→patch, `feat:`→minor, `feat!:`→major; nessun tag→prima release `0.1.0` (`initial_tag`) |
| `REQUIRE_TAG=true, HEAD=tag` | Nessun incremento se il tree è identico all'ultimo tag |
| Scope e breaking | `fix(scope):`→patch, `feat(scope):`→minor, `feat(scope)!:`/`fix!:`/`BREAKING CHANGE:`→major, `chore(scope):` e messaggi liberi→patch |
| Incremento più alto | Tra i commit dall'ultimo tag vince il più alto: `feat:` poi `fix:` → minor, `feat!:` poi `fix:` → major |
| Versione nel run di publish | Build number uguale alla versione calcolata (rilascio, rilascio senza modifiche, prerelease); tag `release` solo sulle publish di rilascio |
| Prefisso ADO | `Merged PR <id>: <titolo convenzionale>` (messaggio di default di Azure DevOps, anche in squash) riconosciuto come il titolo senza prefisso |
| Sanitizzazione PROJECT_NAME | Punti→trattini, lowercase |

Ogni test crea un repository git reale con un **bare repo locale come fake remote** (`git init --bare`), così `git push origin <tag>` funziona senza rete.

#### `Verify-SemVer.Tests.ps1`

| Suite | Scenario testato |
|---|---|
| Branch protetti (main, staging) | Tipi ammessi da `cliff.toml` accettati, tipi ignoti e messaggi liberi rifiutati; merge commit (usa `--no-merges`) |
| Branch non protetti | Check skippato su `dev`, `feature/x`, ecc. |
| `ADDITIONAL_TAG_BRANCHES` | Branch extra protetti via env var |
| Titolo della PR | `PR_TITLE` validato come `Merged PR <id>: <titolo>` al posto dell'ultimo commit, HEAD invariato, `GATED_BRANCHES` |
| `GATE_MODE` | `warn` (warning + SucceededWithIssues), `off`, `enforce` di default |
| Avviso sui Conventional Commits di una PR | Sul merge ref della PR: nessun avviso se il titolo o almeno un commit è convenzionale (squash, promozione, back-merge), avviso con l'elenco dei messaggi valutati se nessuno lo è |
| Gate bloccante per default | Con i default letti dai tre template di quality GitFlow la PR senza messaggi convenzionali fallisce verso `dev`, `staging` e `main`, passa verso un ramo non gated; `warn` scelto dal consumer avvisa senza fallire; lo script senza `GATED_BRANCHES` protegge gli stessi rami |

#### `GitCliff.Tests.ps1`

Il binario scaricato risponde con la versione fissata e non dipende da runtime assenti sugli agent: su Windows nessun
`VCRUNTIME*.dll`/`MSVCP*.dll` importato (i runner GitHub hanno il Visual C++ Redistributable, un agent qualunque puo' non averlo), su Linux
nessun loader dinamico `ld-linux`. La cache è separata per archivio.

#### `New-ReleaseNotes.Tests.ps1`

| Suite | Scenario testato |
|---|---|
| Contenuto | Gruppi per tipo con scope e PR, messaggi liberi in "Altre modifiche", range dal tag del primo parent con salto dei merge |
| Pubblicazione | Upload nel summary, wiki non toccato fuori da main, errore di generazione che non ferma il publish |
| Collegamenti nelle note di rilascio | Ogni voce con link al commit e alla PR che lo ha integrato (merge o squash, mai la PR di promozione), work item della PR letti da un'API locale finta, note pubblicate anche se l'API non risponde, link GitHub |
| Note di rilascio del repository AI | Su un wiki locale finto: la prima publish crea la sezione della versione, la seconda publish della stessa versione (Engine e Worker) non la duplica |

#### `Test-PublishedArtifact.Tests.ps1`

L'API Build è un HttpListener locale con gli artifact della run in memoria.

| Suite | Scenario testato |
|---|---|
| Rerun dello stage di publish con artifact già pubblicato | Rerun dopo un caricamento riuscito: upload saltato e dichiarato nel log; prima esecuzione: upload; API in errore: upload con warning |
| Interrogazione dell'API | Artifact della run corrente con il token della pipeline, nome esatto, step mai fallito |

#### `Test-AdrCorpus.Tests.ps1`

Ogni test costruisce un repository con un bare repo come origin: il corpus di partenza su `main`, la PR su un ramo.

| Suite | Scenario testato |
|---|---|
| Verifica del corpus delle decisioni architetturali | Decisione ben formata; stato non ammesso, numero duplicato, sezione mancante, sostituzione non reciproca; ADR accepted riscritto e sostituito; diagramma cambiato con una versione nuova, modifica non versionata, esito cambiato; modalità `warn` |
| Regole del corpus | ADR accepted eliminato, ADR senza versione alla versione 1, versione senza la sua voce, versione non intera, versione più bassa, ADR proposed riscrivibile, superseded-by verso una decisione inesistente, file senza frontmatter, file non numerati ignorati, run fuori da una PR, modalità `off`, una segnalazione per difetto |

I test degli script di verifica della documentazione partono dal documento valido di
`Tests/fixtures/documentation/DocumentationFixture.ps1` (le dodici sezioni del template arc42 italiano,
modello C4, diagramma Mermaid, testo entro le soglie) e vi introducono un solo difetto per scenario.
Lo script gira come in pipeline, in un processo separato.

#### `Test-Arc42Document.Tests.ps1`

Il template è l'archivio ufficiale `arc42-template-IT-plain-markdownMP.zip` della release fissata nello
script (CC BY-SA 4.0, in `Tests/fixtures/documentation/`), servito da un HttpListener locale al posto di
GitHub: lo SHA-256 verificato è quello vero e nessuna prova scarica dalla rete.

| Suite | Scenario testato |
|---|---|
| Struttura del documento sul template arc42 | Documento con le sezioni del template e URL della release nella lingua; sezione mancante, sezione fuori template, titolo diverso; attributo di titolo conservato; file non numerato ignorato |
| Template della release fissata | Lingua non supportata senza download, SHA-256 diverso, download non riuscito |
| Modalità del controllo | `warn`, `off` senza download |

#### `Test-C4Model.Tests.ps1`

Richiede Java 17 o successivo (`STRUCTURIZR_JAVA`, `JAVA_HOME_17_X64` o `JAVA_HOME`); la Structurizr CLI si scarica alla prima esecuzione.

| Suite | Scenario testato |
|---|---|
| Verifica del modello C4 | Modello completo e mostrato; relazione verso un elemento non dichiarato, container senza vista dei componenti, livello mancante, vista non mostrata, marcatore di vista inesistente, modello mancante |
| Strumenti e modalità | Senza Java 17 la verifica fallisce nominando il controllo non eseguito; `off` |

#### `Test-MermaidDiagrams.Tests.ps1`

Richiede Node.js; il parser Mermaid si installa alla prima esecuzione.

| Suite | Scenario testato |
|---|---|
| Verifica dei diagrammi Mermaid | Diagrammi validi; diagramma non valido con sezione, file e riga; diagramma non valido in una decisione; cartella delle decisioni dichiarata; documento senza decisioni |
| Strumenti e modalità | Senza Node.js la verifica fallisce nominando il controllo non eseguito; `off` |

#### `Test-Documentation.Tests.ps1`

| Suite | Scenario testato |
|---|---|
| Controlli comuni sulla documentazione | Rimandi esistenti e testo entro le soglie; rimando a decisione, ancora o file inesistente; testo oltre le soglie (leggibilità, frase troppo lunga); documento di un altro formato senza modello C4 e con file non numerati |
| Modalità del controllo | `warn`, `off` |

#### `MarkdownText.Tests.ps1`

| Suite | Scenario testato |
|---|---|
| Analisi del testo | Frasi, abbreviazioni, decimali, parole, indice Gulpease, testo semplice, ancore |
| Blocchi di una sezione | Titolo e parti senza attributi di titolo, apertura, paragrafi, elenchi, tabelle, marcatori di vista, diagrammi |
| Sezioni di un documento | File Markdown della cartella in ordine di nome, nome dal titolo o dal file, cartella assente |

#### `Test-DocumentationStyle.Tests.ps1`

Il modello è sostituito da un endpoint locale che risponde come Azure OpenAI: restituisce un rilievo quando la sezione inviata contiene la frase registrata e conserva le richieste. Le prove verificano cosa si manda al modello e come si riporta la risposta; il giudizio vero del modello si prova con gli esempi della guida di stile del repository della documentazione.

| Suite | Scenario testato |
|---|---|
| Giudizio dello stile | Documento conforme; sezione che viola una regola della guida (sezione e regola nominate); regola nuova nella guida senza cambiare la pipeline; modello non disponibile (tre tentativi, poi rilievo) |
| Cosa si manda al modello | Una richiesta per sezione, glossario escluso e mandato come contesto; formato di risposta e deployment; in una PR solo le sezioni cambiate, nessuna chiamata senza sezioni cambiate, tutte se cambia la guida; decisione nuova, righe cambiate di una decisione esistente, decisioni esistenti non rigiudicate quando cambia la guida, cartella delle decisioni dichiarata, nessuna decisione fuori da una PR |
| Correzioni in una decisione nuova | La decisione corretta torna sul ramo della PR con il segno del giudizio superato |
| Correzioni con rilievi rimasti | Dopo il numero massimo di giri, e con una correzione scartata, le correzioni fatte tornano sul ramo con le unità in sospeso e la verifica fallisce; il giudizio dopo rilegge solo quelle unità e passa quando non hanno più rilievi |
| Configurazione e modalità | Guida indicata dal parametro, guida mancante, endpoint assente, `warn`, `off` |

#### `ScenarioCoverage.Tests.ps1` (14 suite, 25 test)

Lo script gira come processo (`dotnet run`), come in pipeline. Le fixture `green` e `red` sono l'output
reale di una run Reqnroll + xUnit con `BUILD_BUILDID=4242`; i casi con corpus diversi copiano una
fixture in `TestDrive` e la alterano. Il workflow esegue la suite su `ubuntu-latest` e `windows-latest`.

| Suite | Scenario testato |
|---|---|
| Corpus verificato | Righe di `Esempi` e scenari dentro una `Regola` contati uno per uno; `@ignore` su scenario e su Funzionalità in attesa |
| Scenari non superati | Riga di esempio fallita nominata per riga; frase senza binding distinta dal fallimento |
| Feature non eseguita | `.feature` che nessun progetto di test compila |
| Run diversa | Messages di un altro BuildId ignorati |
| Sorgenti disallineati | Righe spostate dopo la build: scenario non eseguito + esecuzione senza scenario |
| Esecuzione orfana | Messages di un `.feature` rimosso |
| Gherkin non valido | Problema del corpus (exit 1), non errore di invocazione |
| Nessun `.feature` | Exit 0 senza verificare nulla |
| Riepilogo markdown | Tabelle problemi / in attesa |
| CRLF | `.feature` con fine riga Windows: stesse righe di un checkout LF |
| Modalità `warn` | Exit 0 con problemi; `##vso` solo con `TF_BUILD`; SucceededWithIssues anche su messages illeggibili |
| Modalità `enforce` su agent | Exit 1 con `logissue type=error`, `task.uploadsummary` del riepilogo |
| Invocazione non valida | Exit 2: opzioni mancanti o sconosciute, modalità sconosciuta (anche in pipeline), root assente, messages illeggibili |

Per rigenerare le fixture: un progetto xUnit con `Reqnroll.xUnit` 3.3.4, i `.feature` della fixture e
`BUILD_BUILDID=4242`, `REQNROLL_FORMATTERS={"formatters":{"message":{"outputFilePath":"scenario-coverage/{env:BUILD_BUILDID}.ndjson"}}}`
durante `dotnet test -c Release`.

---

## GitHub Actions

I workflow si attivano automaticamente su ogni PR verso `main` e su ogni push.

| Workflow | File | Trigger |
|---|---|---|
| Static Analysis | `.github/workflows/test-static.yml` | modifiche in `V3/**`, `V4/**` o `Tests/static/**` |
| Script Unit Tests | `.github/workflows/test-scripts.yml` | modifiche in `V3/CI/Scripts/**` o `Tests/scripts/**` |
| Template Expansion Preview | `.github/workflows/test-preview.yml` | `workflow_dispatch` (da abilitare, vedi Livello 3) |

I risultati Pester vengono pubblicati come report JUnit nella tab "Checks" di GitHub.

---

## Livello 3 — Template Expansion Preview (richiede Azure DevOps)

Usa `az pipelines run --preview` per espandere i template fully-resolved senza eseguirli.
Cattura errori che la static analysis non può vedere:
- Variabili ADO non risolte a runtime
- Condizioni `${{ if }}` con parametri mancanti
- Step template con parametri obbligatori non soddisfatti dalla pipeline host

I file di test pipeline ADO sono in `Tests/preview/`.

### Setup (una tantum)

**1. Registrare le pipeline in Azure DevOps**

Creare due pipeline in ADO puntando ai file di questo repo:

| Nome pipeline ADO | File |
|---|---|
| `Pipelines - Preview quality-dotNet` | `Tests/preview/quality-dotNet.yaml` |
| `Pipelines - Preview publish-dotNet` | `Tests/preview/publish-dotNet.yaml` |

**2. Aggiungere secret e variabili in GitHub**

In `Settings → Secrets and variables → Actions`:

| Tipo | Nome | Valore |
|---|---|---|
| Secret | `AZURE_DEVOPS_PAT` | PAT con scope *Build (Read & Execute)* |
| Variable | `AZURE_DEVOPS_ORG` | `https://dev.azure.com/NomeOrg` |
| Variable | `AZURE_DEVOPS_PROJECT` | Nome progetto ADO |

**3. Abilitare il workflow**

Aprire `.github/workflows/test-preview.yml` e decommentare il blocco `push` / `pull_request`.

### Esecuzione manuale

```bash
# Prerequisito: az CLI + estensione devops installati localmente
export AZURE_DEVOPS_EXT_PAT=<il_tuo_pat>
az devops configure --defaults organization=https://dev.azure.com/NomeOrg project=NomeProgetto

az pipelines run --name "Pipelines - Preview quality-dotNet" --preview
az pipelines run --name "Pipelines - Preview publish-dotNet" --preview
```
