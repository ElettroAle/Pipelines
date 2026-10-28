# Azure DevOps Pipeline Templates

[![Static Analysis](https://github.com/ElettroAle/Pipelines/actions/workflows/test-static.yml/badge.svg)](https://github.com/ElettroAle/Pipelines/actions/workflows/test-static.yml)
[![Script Unit Tests](https://github.com/ElettroAle/Pipelines/actions/workflows/test-scripts.yml/badge.svg)](https://github.com/ElettroAle/Pipelines/actions/workflows/test-scripts.yml)

Raccolta di template YAML riusabili per Azure DevOps. L'obiettivo è ridurre la
duplicazione nei file di pipeline dei repository applicativi, esponendo moduli
componibili e utility di alto livello pronte all'uso.

---

## Struttura del repository

```
Pipelines/
├── V1/   ← Prima generazione (legacy, non modificare)
├── V2/   ← Seconda generazione (legacy, non modificare)
├── V3/   ← Versione corrente
    ├── CI/
    │   ├── Scripts/                    Script condivisi (SemVer, versioning, copertura scenari)
    │   ├── Modules/                    Moduli atomici agnostici (stages/jobs)
    │   ├── quality-dotNet.yaml         Quality gate agnostica — .NET
    │   ├── quality-angular.yaml        Quality gate agnostica — Angular
    │   ├── publish-dotNet.yaml         Build & Publish agnostico — .NET
    │   ├── publish-angular.yaml        Build & Publish agnostico — Angular
    │   └── GitFlow/
    │       ├── Modules/                Moduli atomici con governance GitFlow
    │       ├── quality-dotNet.yaml     Quality gate GitFlow — .NET
    │       ├── quality-angular.yaml    Quality gate GitFlow — Angular
    │       ├── publish-dotNet.yaml     Build & Publish GitFlow — .NET
    │       └── publish-angular.yaml    Build & Publish GitFlow — Angular
    ├── CD/
    │   ├── deploy-azure-appService.yaml
    │   └── deploy-angular-staticWebApp.yaml
    └── IAC/
        ├── terraform-plan.yaml         Build validation su PR
        ├── terraform-apply.yaml        Apply automatico su merge a main
        └── terraform-deploy.yaml       ⚠ Deprecato — usa plan + apply separati
└── V4/   ← Template nuovi accanto a V3 (vedi V4/README.md)
    └── CD/
        ├── Agnostic/deploy-azure-terraform.yaml   Terraform: plan su ogni run, apply approvato
        └── Common/Steps/terraform-*.yaml          install, plan, apply
```

---

## Versioni

### V1 — Prima generazione (legacy)

Template monolitici per build, test e publish su .NET 6/8, Maven, Node.js, UWP,
Xcode. Include moduli per Docker, Helm e NuGet.

**Non estendere.** Mantenuto solo per retrocompatibilità con pipeline esistenti.

---

### V2 — Seconda generazione (legacy)

Refactoring di V1 con supporto a .NET 8/10 e Angular 18+. Introduce la
separazione tra `buildAndTest` e `buildAndPublish`.

**Non estendere.** Mantenuto solo per retrocompatibilità con pipeline esistenti.

---

### V3 — Versione corrente

Architettura a tre livelli con due famiglie di template CI distinte.

#### Livelli

| Livello | Cartella | Scopo |
|---|---|---|
| 0 — Atomico | `CI/Modules/`, `CI/GitFlow/Modules/` | Singoli stages/jobs, non usati direttamente dai repo |
| 1 — Utility | `CI/*.yaml`, `CI/GitFlow/*.yaml` | Template pronti all'uso, referenziati dai repo applicativi |

#### Famiglie CI

**Agnostica** (`CI/`) — usabile con qualsiasi Git workflow (trunk-based, feature
branch, ecc.). Non include validazione SemVer né tagging Git.

**GitFlow** (`CI/GitFlow/`) — estende la logica agnostica aggiungendo:
- Validazione titolo PR su branch protetti (`main`, `staging`) tramite Conventional Commits
- Calcolo automatico della versione SemVer da commit history e tagging Git
- Branch-conditional variable groups (`dev` → development, `staging` → staging, `main` → production)

I template agnostici sono i **precursori** concettuali di quelli GitFlow: entrambi
sono standalone e indipendenti, entrambi referenziano gli stessi moduli atomici.

---

## Come usare i template

I template V3 vanno referenziati dal repository applicativo tramite `extends:`.

### Esempio — Quality gate GitFlow su .NET

```yaml
# Nel repo applicativo: azure-pipelines-ci.yaml
trigger:
  branches:
    include: [ dev, staging, main, feature/* ]

pr:
  branches:
    include: [ dev, staging, main ]

resources:
  repositories:
    - repository: infra
      type: git
      name: Demetra/DPS.Demetra.Infrastructure

extends:
  template: pipelines/V3/CI/GitFlow/quality-dotNet.yaml@infra
  parameters:
    projectName: 'MyApp'
```

### Esempio — Publish agnostico su Angular

```yaml
# Nel repo applicativo: azure-pipelines-ci.yaml
trigger:
  branches:
    include: [ main ]

resources:
  repositories:
    - repository: infra
      type: git
      name: Demetra/DPS.Demetra.Infrastructure

extends:
  template: pipelines/V3/CI/publish-angular.yaml@infra
  parameters:
    projectName: 'MyAngularApp'
    targetEnvironment: 'Production'
    buildConfiguration: 'production'
```

### Esempio — Deploy su App Service

```yaml
# Nel repo applicativo: azure-pipelines-cd.yaml
resources:
  repositories:
    - repository: infra
      type: git
      name: Demetra/DPS.Demetra.Infrastructure
  pipelines:
    - pipeline: ci_be
      source: 'MyApp - CI'
      trigger:
        branches: [ main ]

extends:
  template: pipelines/V3/CD/deploy-azure-appService.yaml@infra
  parameters:
    projectName: 'MyApp'
    azureServiceConnection: 'my-azure-sc'
    targetEnvironment: 'Production'
    webAppName: 'app-myapp-be-prod'
    ciPipelineResourceAlias: 'ci_be'
```

### Copertura degli scenari Gherkin (quality-dotNet)

Con `scenarioCoverage` diverso da `'off'` la quality verifica, in modo deterministico,
che ogni scenario dei file `.feature` del repo applicativo sia stato eseguito e superato
durante i test. Ogni riga di `Esempi` conta come uno scenario a sé.

```yaml
extends:
  template: V3/CI/GitFlow/quality-dotNet.yaml@infrastructure
  parameters:
    checkoutRepository: app_repo
    testProjects: '**/*.slnx'        # deve includere i progetti BDD
    scenarioCoverage: 'warn'         # 'off' (default) | 'warn' | 'enforce'
```

| Valore | Effetto |
|---|---|
| `off` | Nessun controllo (default) |
| `warn` | Report nella tab *Extensions* della run, esito *Succeeded with issues*, nessun blocco |
| `enforce` | La run fallisce se anche un solo scenario non risulta verificato |

- **Come funziona.** `dotnet-test.yaml` attiva il formatter Cucumber Messages di Reqnroll
  (variabile `REQNROLL_FORMATTERS`, file `scenario-coverage/$(Build.BuildId).ndjson` nell'output
  di ogni progetto). `gherkin-scenario-coverage.yaml` esegue `CI/Scripts/ScenarioCoverage.cs`, che
  legge i `.feature` su disco con il parser Gherkin ufficiale e li confronta con i messages.
  Lo step è una sola riga `dotnet run` senza sintassi di shell: gira su agent Linux e Windows.
- **Cosa fa fallire.** Scenario mai eseguito (feature fuori da ogni progetto di test o esclusa da
  `testProjects`), frase senza binding, step pending o ambiguo, scenario saltato a runtime, fallito,
  eseguito senza step, Gherkin non valido, messages non allineati ai sorgenti.
- **`@ignore`.** Uno scenario (o una Funzionalità) `@ignore` non fa fallire il controllo: è contato
  ed elencato come *in attesa*.
- **Requisiti.** Il repo applicativo dichiara il repository resource con alias `infrastructure`: il
  job BuildAndTest ne fa il checkout in `$(Pipeline.Workspace)/pipeline-templates`, fuori dai sorgenti.
  Senza file `.feature` lo step passa senza verificare nulla.

### Verifica degli Architecture Decision Records (quality-docs)

Per un repository di documentazione con gli ADR in formato MADR, con le intestazioni nella lingua del
documento.

```yaml
extends:
  template: V3/CI/Agnostic/quality-docs.yaml@infrastructure
  parameters:
    checkoutRepository: self
    language: 'EN'                      # 'IT' (default) | 'EN'
    adrMode: 'enforce'                  # 'off' | 'warn' | 'enforce' (default)
    decisionsDirectory: 'docs/decisions'
```

- **Decisione ben formata.** File `NNNN-titolo.md` con numero univoco, frontmatter con `status` fra
  `proposed`, `accepted`, `rejected`, `deprecated`, `superseded`, e le sezioni MADR della lingua:
  `## Contesto e problema`, `## Opzioni considerate`, `## Esito della decisione` in italiano,
  `## Context and Problem Statement`, `## Considered Options`, `## Decision Outcome` in inglese. Gli altri
  file della cartella (README, template) non si verificano.
- **Sostituzione.** La nuova decisione dichiara `supersedes: <id>`; la sostituita passa a
  `status: superseded` con `superseded-by: <id>`. Ognuna deve nominare l'altra.
- **Immutabilità e versioni.** Sulle PR un ADR `accepted` sul ramo di destinazione non si elimina e il
  suo esito (`## Esito della decisione` in italiano, `## Decision Outcome` in inglese) non cambia: una
  scelta diversa è una decisione nuova che lo sostituisce. Il resto cambia solo con una versione nuova:
  `version` nel frontmatter (un intero, 1 se manca) cresce e la sezione `## Versioni` (`## Versions` in
  inglese) ha la voce della versione, un elemento di lista che comincia con il suo numero
  (`- 2: diagramma del codice`). `status` e `superseded-by` cambiano senza versione.
- **Requisiti.** Il repo dichiara il repository resource con alias `infrastructure`; pool Linux
  (Gitleaks gira in docker).

### Verifica della documentazione (quality-arc42, quality-docs)

Per un repository che tiene un documento in Markdown, una sezione per file. Ogni formato è un modulo:
uno step template in `CI/Common/Steps/` con il suo script, che conosce solo il suo standard. La pipeline
d'ingresso compone i moduli come le pipeline di build compongono gli step di una tecnologia, senza
parametri di formato e senza condizioni sul formato.

| Step | Script | Cosa controlla | Legato a |
|---|---|---|---|
| `adr-verify.yaml` | `Test-AdrCorpus.ps1` | corpus delle decisioni | MADR |
| `arc42-verify.yaml` | `Test-Arc42Document.ps1` | un file per sezione con nome e titolo del template ufficiale | arc42 |
| `c4-verify.yaml` | `Test-C4Model.ps1` | modello Structurizr valido e completo, viste mostrate nelle sezioni | C4 |
| `mermaid-verify.yaml` | `Test-MermaidDiagrams.ps1` | diagrammi Mermaid validi, nel documento e nelle decisioni | Mermaid |
| `flows-verify.yaml` | `Test-DiagramFlows.ps1` | flussi fatti degli elementi del modello C4 e delle classi delle decisioni | C4, Mermaid |
| `documentation-verify.yaml` | `Test-Documentation.ps1` | rimandi esistenti, soglie numeriche di leggibilità | nessun formato |
| `documentation-style.yaml` | `Test-DocumentationStyle.ps1` | giudizio dello stile con la guida del repository | nessun formato |

Due ingressi:

- `CI/Agnostic/quality-arc42.yaml`: ADR, struttura arc42, controlli comuni, diagrammi, stile.
- `CI/Agnostic/quality-docs.yaml`: ADR, controlli comuni, diagrammi, stile, per un documento senza un
  formato con struttura propria.

**Lingua del documento.** Le convenzioni che dipendono dalla lingua stanno in
`CI/Scripts/Languages/<lingua>.psd1`, una per file: sezioni degli ADR, marcatore di vista, tag dei
container C4, nome della pagina e colonna dello stato nella wiki. `quality-arc42` la prende da
`arc42Language`, `quality-docs` da `language` (default `IT`); lo step `document-language.yaml` la
dichiara in `DOCUMENT_LANGUAGE` per tutto il job, compresi gli step che il consumer inietta. Una lingua
nuova è un file nuovo in `Languages/`, senza toccare gli script.

**Cartelle del documento.** `docsDirectory` e `decisionsDirectory` si dichiarano una volta sola, nel
template d'ingresso: lo step `document-directories.yaml` le mette in `DOCS_DIRECTORY` e
`DECISIONS_DIRECTORY` per tutto il job, e gli step che il consumer inietta (`c4-verify.yaml`,
`mermaid-verify.yaml`, `flows-verify.yaml`) le usano senza ripeterle. Un parametro passato allo step vince sulla dichiarazione.

| Convenzione | `IT` | `EN` |
|---|---|---|
| Marcatore di vista | `<!-- vista: <chiave> -->` | `<!-- view: <chiave> -->` |
| Tag dei container con vista dei componenti | `Applicazione` | `Application` |
| Parti della decisione con struttura e flusso nel codice | `Struttura nel codice`, `Flusso nel codice` | `Code structure`, `Code flow` |
| Pagina della wiki (default di `wikiRoot`) | `Architettura` | `Architecture` |
| Colonna dello stato nella wiki | `Stato` | `Status` |

I diagrammi li sceglie il consumer: il parametro `diagramSteps` (stepList, default vuoto) riceve gli step
dei diagrammi che il documento usa. Chi non usa C4, o usa un'altra notazione, cambia la lista nel suo
`quality.yml` e non la pipeline. Gli step iniettati prendono i parametri che il consumer passa loro
(default `enforce` e `docs/architecture`) e non girano con `docsMode: 'off'`.

La verifica ha due modalità, ognuna di default `off`:

- `docsMode`: controlli oggettivi (struttura del formato e controlli comuni), senza nessuna regola di stile;
- `styleMode`: giudizio dello stile con un modello Azure OpenAI, che riceve la guida di stile del
  repository come istruzioni. La pipeline non conosce nessuna regola di scrittura: cambiare guida non
  cambia la pipeline.

```yaml
extends:
  template: V3/CI/Agnostic/quality-arc42.yaml@infrastructure
  parameters:
    checkoutRepository: self
    arc42Language: 'IT'
    docsMode: 'enforce'                 # 'off' (default) | 'warn' | 'enforce'
    docsDirectory: 'docs/architecture'
    docsGulpease: 40                    # 0 (default): nessuna soglia
    docsMaxWords: 25                    # 0 (default): nessuna soglia
    docsAbbreviations: ['es.', 'ecc.']
    docsGlossary: '12_glossary.md'
    diagramSteps:
      - template: V3/CI/Common/Steps/c4-verify.yaml@infrastructure
      - template: V3/CI/Common/Steps/mermaid-verify.yaml@infrastructure
      - template: V3/CI/Common/Steps/flows-verify.yaml@infrastructure
    styleMode: 'enforce'                # 'off' (default) | 'warn' | 'enforce'
    styleGuide: 'docs/STYLE.md'         # default
    styleServiceConnection: '<service connection con Cognitive Services OpenAI User>'
    styleEndpoint: 'https://<risorsa>.openai.azure.com'
    styleModel: '<deployment>'
```

Struttura arc42 (`arc42-verify.yaml`, `CI/Scripts/Test-Arc42Document.ps1`):

- **Template.** La release del template ufficiale (variante `plain-markdownMP`), l'URL e lo SHA-256 di
  ogni lingua sono fissati nello script, come per ogni strumento scaricato in pipeline: il consumer
  passa solo `arc42Language`. Una lingua senza template, un download non riuscito o uno SHA-256 diverso
  fanno fallire la verifica nominando il motivo.
- **Sezioni.** Le sezioni del template sono i suoi file Markdown numerati (`01_introduction_and_goals.md`,
  …). Il documento ha un file con lo stesso nome per ogni sezione, con lo stesso titolo di primo
  livello; gli attributi di titolo (`{#section-…}`) non contano. Un file numerato che il template non ha
  è una sezione fuori template; i file non numerati non sono sezioni. Le sottosezioni e il testo li
  giudica il modello con la guida di stile.

Modello C4 (`c4-verify.yaml`, `CI/Scripts/Test-C4Model.ps1`):

- Il modello è `model/workspace.dsl` nella cartella del documento: il DSL è valido e ha vista di contesto,
  vista dei container e vista di deployment; ogni container con il tag delle applicazioni (`Applicazione`
  in italiano) ha la sua vista dei componenti.
- Una vista di contesto mostra solo il livello di business: una persona o un sistema con il tag tecnico
  (`Tecnico` in italiano) resta fuori, ad esempio con `exclude "element.tag==Tecnico"`, e compare dalla
  vista dei container in giù.
- Una sezione mostra una vista con il marcatore di vista (`<!-- vista: <chiave> -->` in italiano); ogni vista è mostrata da
  almeno una sezione e ogni marcatore nomina una vista esistente. Senza questo step i marcatori non si
  controllano.
- **Requisiti.** Java 17 o successivo per la Structurizr CLI (versione fissata, SHA-256 verificato); lo
  step lo prepara con `ensure-java.yaml`. Senza Java la verifica fallisce nominando il controllo non
  eseguito.

Diagrammi Mermaid (`mermaid-verify.yaml`, `CI/Scripts/Test-MermaidDiagrams.ps1`):

- Ogni diagramma Mermaid delle sezioni e delle decisioni passa dal parser: l'errore nomina sezione (o
  titolo della decisione), file e riga. Una cartella che non esiste non ha diagrammi da verificare.
- **Requisiti.** Node.js (dipendenze fissate da `CI/Scripts/mermaid/package-lock.json`); lo step lo
  prepara con `UseNode@1`. Senza Node.js la verifica fallisce nominando il controllo non eseguito.

Flussi (`flows-verify.yaml`, `CI/Scripts/Test-DiagramFlows.ps1`):

- **Sezioni.** Ogni partecipante di un diagramma di sequenza ha come nome mostrato
  (`participant T as Esecuzione del turno`) il nome di un elemento del modello C4: un componente, un
  container, una persona o un sistema. Un container con il tag delle applicazioni che ha componenti
  compare con i suoi componenti, mai intero. Ogni chiamata fra due partecipanti diversi è una relazione
  del modello nella stessa direzione, comprese quelle che Structurizr ricava dai livelli inferiori. Le
  risposte (frecce tratteggiate) e le chiamate di un partecipante a sé non si controllano. L'errore
  nomina la sezione, il file e la riga del diagramma, e il partecipante o la chiamata; un nome che il
  modello dà a due elementi è ambiguo.
- **Decisioni.** Una decisione `NNNN-titolo.md` aperta (non `superseded`, `deprecated` o `rejected`)
  con la parte `Struttura nel codice` ha la parte `Flusso nel codice`, con almeno un diagramma di
  sequenza; i suoi partecipanti sono classi del diagramma delle classi della parte della struttura.
  Altri diagrammi del flusso, come quello degli stati, non si controllano.
- Un diagramma non valido lo segnala `mermaid-verify.yaml`, il modello non valido `c4-verify.yaml`: qui
  si salta il primo e si nomina il secondo.
- **Requisiti.** Java 17 o successivo e Node.js, preparati dallo step come in `c4-verify.yaml` e
  `mermaid-verify.yaml`.

Controlli comuni (`documentation-verify.yaml`, `CI/Scripts/Test-Documentation.ps1`), su ogni file
Markdown della cartella del documento:

- **Rimandi.** I link relativi puntano a file e ancore esistenti; un identificativo di decisione
  `NNNN-titolo` nel testo esiste in `decisionsDirectory`.
- **Soglie numeriche** (solo se dichiarate). Indice Gulpease minimo del testo di ogni sezione
  (`docsGulpease`) e parole massime per frase (`docsMaxWords`); `docsAbbreviations` sono le
  abbreviazioni che non chiudono una frase.

Gli script condividono `CI/Scripts/VerificationGate.ps1` (modalità, rilievi, codice di uscita) e
`CI/Scripts/MarkdownText.ps1` (lettura delle sezioni e misure di leggibilità).

Giudizio dello stile (`styleMode`, `CI/Scripts/Test-DocumentationStyle.ps1`):

- Il modello riceve come istruzioni la guida `styleGuide` e giudica un documento per richiesta, con il
  glossario `docsGlossary` come contesto; il glossario non si giudica. In una PR si giudicano le sezioni
  cambiate, tutte se cambiano le regole che valgono per le sezioni: spostare una regola nella guida, o
  cambiare solo le regole delle decisioni o il testo fuori dalle regole, non le rigiudica. Delle decisioni (`decisionsDirectory`) si giudicano solo le righe
  che la PR aggiunge o cambia, anche quando cambia la guida: il corpus già integrato non si rigiudica, e
  fuori da una PR le decisioni non si giudicano. Le decisioni sostituite, deprecate o respinte non si
  giudicano. Le correzioni di una decisione passano anche dalla verifica del corpus prima di tornare sul
  ramo, e non toccano la sua intestazione: la versione nuova di una decisione accettata la porta la PR.
- Ogni tipo di documento ha le sue regole. Nella guida, le regole sotto `## Regole` valgono per tutti, quelle
  sotto `## Regole delle sezioni` solo per le sezioni e quelle sotto `## Regole delle decisioni` solo per le
  decisioni (i nomi delle parti seguono la lingua del documento). Il modello non riceve le regole dell'altro
  tipo, né nella guida né nella risposta attesa. Una guida senza queste parti ha solo regole comuni.
- Un titolo si corregge come il resto del testo, tranne quelli che il modello del documento impone: il titolo
  di primo livello di una sezione arc42 e i titoli di secondo livello di una decisione MADR. Con il titolo
  cambiano i rimandi alla sua ancora e le righe che lo riportano accanto a un rimando al suo file, come
  l'indice delle decisioni; quei file contano come giudicati nel commit del titolo.
- Una correzione resta solo se il giro dopo non trova più la stessa regola violata nella stessa unità:
  altrimenti si annulla e il modello riceve il motivo. L'ultimo dei `maxRounds` giri verifica soltanto.
- `styleMaxFindings` è la soglia delle violazioni tollerate: fino alla soglia restano come avvisi e la
  verifica passa con esito parziale (`SucceededWithIssues`); oltre la soglia la verifica fallisce e le nomina
  tutte. `0` (default) blocca ogni violazione, `-1` non pone limiti. In modalità `fix` contano le violazioni
  che l'ultimo giro trova ancora.
- In modalità `fix` ogni file giudicato ha il suo commit, con le correzioni che superano i controlli
  oggettivi, il trailer `Style-Judge-Done: <file>` e, oltre la soglia, una riga `Style-Judge-Pending` per ogni
  unità rimasta. Il giudizio dopo rilegge di ogni file solo le righe cambiate dal suo commit e le unità in
  sospeso, non il resto del documento. Un file con sole unità in sospeso si verifica con un giro, senza
  correzioni: se le violazioni restano non si pubblica nulla, così il push non avvia un'altra build sullo
  stesso rilievo; se non restano, un commit del file chiude le unità.
- I commit vanno sul ramo di appoggio `style-judge/<commit della PR>`, con `[skip ci]`: un push sul ramo della
  PR avvierebbe la build di validazione e annullerebbe quella in corso. A fine giudizio il ramo della PR li
  riceve tutti insieme, anche quando la verifica fallisce, e il ramo di appoggio si cancella. Se il job si
  interrompe, per timeout o annullamento, la build dopo trova il ramo di appoggio dello stesso commit, lo porta
  sul ramo della PR senza chiamare il modello e fallisce con `giudizio ripreso`: la build avviata da quel push
  giudica solo il resto.
- L'identità della build deve poter contribuire al repository e creare rami; per cancellare il ramo di
  appoggio serve anche il permesso di cancellare i rami, altrimenti resta e lo step lo segnala con un avviso.
- Risposta in formato fissato (JSON schema): per ogni violazione il titolo della regola, la frase e il
  motivo. Il rilievo è `<sezione>: <regola> («frase»: motivo)`.
- Accesso con token Entra ID della service connection (task `AzureCLI@2`), senza chiavi. Su 429 o 5xx
  lo script riprova fino a tre volte; se il modello non risponde la verifica fallisce nominando il
  motivo.

### Pubblicazione nella wiki (publish-arc42-wiki)

Dopo il merge su `main` il documento arc42 si pubblica nella wiki di progetto di Azure DevOps
(`CI/Agnostic/publish-arc42-wiki.yaml`, lo step `CI/Common/Steps/arc42-wiki-publish.yaml` e lo script
`CI/Scripts/Publish-Arc42Wiki.ps1`). Lo step prepara Java e i font di sistema con `ensure-java.yaml` ed
`ensure-fonts.yaml`:

- Ogni sezione diventa una pagina sotto `wikiRoot` (default il nome della lingua, `Architettura` o
  `Architecture`), nell'ordine dei numeri; le decisioni diventano sottopagine della sezione 9, quella
  delle decisioni nel template arc42, e la tabella che le elenca riceve la colonna dello stato.
- I marcatori di vista diventano le immagini PNG delle viste C4: la Structurizr CLI le esporta in
  C4-PlantUML e PlantUML (versione fissata, SHA-256 verificato) le disegna con le librerie C4 interne e il
  layout smetana, senza Graphviz e senza rete. Le immagini stanno in `.attachments/<wikiRoot>/<vista>.png`.
  Con la proprieta' `c4plantuml.tags` delle viste, colori e forme vengono dagli stili del modello, che
  allora dichiara anche quelli di `Person`, `Software System`, `Container` e `Component`.
- I blocchi ` ```mermaid ` diventano la sintassi della wiki `::: mermaid`. I link alle sezioni e alle
  decisioni portano alle pagine; gli altri link relativi al file nel repository.
- Un commit solo nel repository git della wiki tocca soltanto `wikiRoot`, le sue immagini e la sua voce in
  testa all'ordine della radice: le altre pagine della wiki restano come sono. Se la wiki cambia nel
  frattempo, il push si riprova sopra il commit nuovo; se non cambia nulla, nessun commit.

```yaml
resources:
  repositories:
    - repository: infrastructure
      type: github
      name: ElettroAle/Pipelines
      endpoint: github.com_ElettroAle
    - repository: project_wiki
      type: git
      name: MyProject.wiki
      ref: wikiMaster

trigger:
  branches:
    include: [main]
  paths:
    include: [docs/*]

extends:
  template: V3/CI/Agnostic/publish-arc42-wiki.yaml@infrastructure
  parameters:
    checkoutRepository: self
    wikiRepository: project_wiki
    language: 'EN'                      # lingua del documento, come arc42Language della quality
```

---

## Test Suite

La libreria include una suite di test a 2 livelli che gira su GitHub Actions senza richiedere Azure DevOps.

| Livello | Tool | Cosa verifica |
|---|---|---|
| 1 — Static Analysis | Python (`yamllint`, script custom) | Sintassi YAML, riferimenti a template esistenti, contratti parametri |
| 2 — Script Unit Tests | PowerShell Pester 5 | Logica di `Set-Versioning.ps1`, `Verify-SemVer.ps1`, `New-ReleaseNotes.ps1`, `Test-PublishedArtifact.ps1`, `Test-AdrCorpus.ps1`, degli script di verifica della documentazione e di `ScenarioCoverage.cs` |

### Esecuzione locale

```bash
# Livello 1 — da root del repo
pip install -r Tests/static/requirements.txt
yamllint -c Tests/static/.yamllint.yaml V3/ V4/
python Tests/static/check-references.py
python Tests/static/check-parameters.py
```

```powershell
# Livello 2 — da root del repo
Invoke-Pester Tests/scripts/ -Output Detailed
```

### GitHub Actions

I workflow si attivano automaticamente su ogni push e su ogni PR verso `main`, **solo se i file modificati ricadono nei path monitorati**:

| Workflow | Trigger (path) |
|---|---|
| `test-static.yml` | `V3/**`, `V4/**`, `Tests/static/**` |
| `test-scripts.yml` | `V3/CI/Scripts/**`, `Tests/scripts/**` |

Documentazione completa: [`Tests/README.md`](Tests/README.md)

---

## Script condivisi (V3)

| Script | Scopo |
|---|---|
| `CI/Scripts/cliff.toml` | Unica sorgente delle regole Conventional Commits: tipi ammessi, gruppi delle release notes, prefisso ADO `Merged PR <id>: `, regole di bump |
| `CI/Scripts/GitCliff.ps1` | Scarica git-cliff (versione fissata, SHA-256 verificato) e lo espone a `Set-Versioning.ps1`, `Verify-SemVer.ps1` e `New-ReleaseNotes.ps1` |
| `CI/Scripts/Verify-SemVer.ps1` | Gate sui Conventional Commits delle PR verso i branch configurati: segnala solo se né il titolo né alcun commit della PR è convenzionale (senza PR, l'ultimo commit non-merge); modalità `off`/`warn`/`enforce`, di default `enforce` su `dev`, `staging` e `main` |
| `CI/Scripts/Set-Versioning.ps1` | Calcola la versione con `git cliff --bumped-version`: tag Git su staging/main, prerelease `x.y.z-dev.<BuildId>` senza tag altrove; setta `currentTag`, `assemblyVersion`, `gitHash`, `computedArtifactName`; usa la versione come build number del run e marca con il tag `release` le publish di rilascio |
| `CI/Scripts/New-ReleaseNotes.ps1` | Release notes dal tag del rilascio precedente sullo stesso ramo, ogni voce con link al commit, alla PR che lo ha integrato e ai work item della PR: summary della run e, su main, pagina wiki |
| `CI/Scripts/Test-PublishedArtifact.ps1` | Prima dell'upload dell'artifact negli orchestratori GitFlow e TrunkFlow: se la run lo ha già pubblicato (rerun dello stage) setta `artifactAlreadyPublished` e l'upload si salta; se la verifica non riesce l'upload procede |
| `CI/Scripts/Test-AdrCorpus.ps1` | Verifica il corpus degli ADR di un repository di documentazione (`quality-docs.yaml`): nome `NNNN-titolo.md`, stato ammesso, sezioni obbligatorie, versione intera, sostituzioni reciproche, ADR `accepted` con l'esito invariato e cambiati solo con una versione nuova rispetto al ramo di destinazione della PR |
| `CI/Scripts/Test-Arc42Document.ps1` | Struttura di un documento arc42 (`arc42-verify.yaml`): un file per sezione con nome e titolo del template ufficiale; release, URL e SHA-256 per lingua fissati nello script |
| `CI/Scripts/Test-C4Model.ps1` | Modello C4 in Structurizr DSL (`c4-verify.yaml`): modello valido, viste obbligatorie, componenti dei container con il tag delle applicazioni, nessun elemento tecnico nelle viste di contesto, marcatori di vista nelle sezioni |
| `CI/Scripts/Publish-Arc42Wiki.ps1` | Pubblica un documento arc42 nella wiki di progetto (`publish-arc42-wiki.yaml`): una pagina per sezione, le decisioni sotto la sezione 9 con lo stato, le viste C4 come immagini C4-PlantUML, un commit solo che non tocca le altre pagine |
| `CI/Scripts/Test-MermaidDiagrams.ps1` | Diagrammi Mermaid delle sezioni e delle decisioni (`mermaid-verify.yaml`): errore con sezione, file e riga |
| `CI/Scripts/Test-DiagramFlows.ps1` | Flussi coerenti con la struttura (`flows-verify.yaml`): partecipanti e chiamate dei diagrammi di sequenza contro il modello C4, flusso delle decisioni contro le classi della loro struttura |
| `CI/Scripts/Test-Documentation.ps1` | Controlli comuni a ogni documento (`documentation-verify.yaml`): rimandi esistenti, soglie numeriche di leggibilità |
| `CI/Scripts/Test-DocumentationStyle.ps1` | Giudizio dello stile di un documento (`documentation-style.yaml`) con un modello Azure OpenAI che riceve la guida di stile del repository come istruzioni |
| `CI/Scripts/VerificationGate.ps1` | Parte comune degli script di verifica della documentazione: modalità `off`/`warn`/`enforce`, rilievi `##vso[task.logissue]`, codice di uscita |
| `CI/Scripts/MarkdownText.ps1` | Lettura delle sezioni Markdown di un documento (blocchi, parti, marcatori di vista, diagrammi) e misure di leggibilità (frasi, parole, indice Gulpease) |
| `CI/Scripts/Structurizr.ps1` | Scarica la Structurizr CLI (versione fissata, SHA-256 verificato), sceglie un Java 17 o successivo ed esporta il modello C4 in JSON e le viste in C4-PlantUML |
| `CI/Scripts/PlantUml.ps1` | Scarica PlantUML (versione fissata, SHA-256 verificato) e disegna i diagrammi in PNG con una sola JVM, layout smetana |
| `CI/Scripts/DocumentLanguage.ps1` | Carica da `CI/Scripts/Languages/<lingua>.psd1` le convenzioni della lingua del documento (`DOCUMENT_LANGUAGE`, default `IT`); una lingua senza file fa fallire lo script nominandola |
| `CI/Scripts/Mermaid.ps1`, `CI/Scripts/mermaid/` | Installa con `npm ci` il parser Mermaid fissato dal lockfile e ricava, per ogni diagramma, il tipo (con partecipanti e chiamate di un diagramma di sequenza, classi di un diagramma delle classi) o l'errore con la riga |
| `CI/Scripts/ScenarioCoverage.cs` | File-based app .NET 10: verifica che ogni scenario dei `.feature` sia stato eseguito e superato, leggendo i Cucumber Messages del runner BDD |

---

## Variable Groups richiesti (V3 GitFlow)

| Group | Usato da | Variabili attese |
|---|---|---|
| `common-quality` | quality-* | (libero — configurazione comune quality) |
| `development` | publish-* (branch `dev`) | `targetEnvironment` |
| `staging` | publish-* (branch `staging`) | `targetEnvironment` |
| `production` | publish-* (branch `main`) | `targetEnvironment` |
| `terraform-common` | IAC/terraform-* | `azureServiceConnection` |

---

## Licenza

Distribuito con licenza [Apache License 2.0](LICENSE). Copyright © 2021-2026 Alessandro Fiani.

L'uso, anche commerciale, è consentito alle condizioni della licenza: ogni redistribuzione o
opera derivata deve mantenere la nota di copyright e il file [NOTICE](NOTICE). La licenza non
concede l'uso del nome dell'autore o di marchi (Section 6).

Le pull request con codice esterno non vengono accettate: vedi [CONTRIBUTING.md](CONTRIBUTING.md).
