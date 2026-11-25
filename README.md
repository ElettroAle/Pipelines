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
- Verifica delle fonti della PR (Task con l'ADR, requisito con i criteri), se il consumer la attiva
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
  di ogni progetto). `gherkin-scenario-coverage.yaml` esegue `CI/Scripts/ScenarioCoverage/ScenarioCoverage.cs`, che
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

### Verifica delle fonti di una PR (quality-sources)

Build validation che lascia integrare una PR solo se porta le fonti del proprio perché: è collegata ad
almeno un Task, ogni Task ha nella descrizione l'ADR con le sezioni MADR della lingua (intestazioni di
secondo livello, in Markdown o in HTML) e il padre di ogni Task è un requisito (Requirement, User Story,
Product Backlog Item) con i criteri di accettazione o un Bug con i passi di riproduzione. Il contenuto
dell'ADR non si giudica. Ogni rilievo nomina il work item e la parte mancante, es.
`Task 1600: manca "Opzioni considerate"`.

```yaml
trigger: none
pr: none

resources:
  repositories:
    - repository: infrastructure
      type: github
      name: <owner>/Pipelines
      endpoint: <service connection GitHub>

extends:
  template: V3/CI/Agnostic/quality-sources.yaml@infrastructure
  parameters:
    mode: 'enforce'                     # 'off' | 'warn' | 'enforce' (default)
    language: 'IT'                      # 'IT' (default) | 'EN'
```

- **Una pipeline, più repository.** La verifica non legge il codice della PR, solo la board: la stessa
  pipeline può essere la build validation di più repository e rami.
- **Dentro la quality GitFlow.** `GitFlow/quality-dotNet.yaml` e `GitFlow/quality-angular.yaml` hanno
  la stessa verifica nel job `ValidatePRSources` (`CI/Common/Jobs/quality-sources.yaml`), accanto a
  `ValidatePRTitle`: gira solo sulle PR verso i rami di `sourcesGateBranches` e BuildAndTest parte solo
  se nessuno dei due gate fallisce.

  ```yaml
  extends:
    template: V3/CI/GitFlow/quality-dotNet.yaml@infrastructure
    parameters:
      checkoutRepository: app_repo
      sourcesGateMode: 'enforce'        # 'off' (default) | 'warn' | 'enforce'
      sourcesGateBranches: 'dev'        # rami di destinazione, separati da virgola (default: dev)
  ```
- **Ripetizione.** La board si legge a ogni run: completati i work item, si rilancia la build.
- **Permessi.** L'identità della build legge i work item e le PR del repository.

### Verifica della documentazione (quality-arc42, quality-docs)

Per un repository che tiene un documento in Markdown, una sezione per file. Ogni formato è un modulo:
uno step template in `CI/Common/Steps/` con il suo script, che conosce solo il suo standard. La pipeline
d'ingresso compone i moduli come le pipeline di build compongono gli step di una tecnologia, senza
parametri di formato e senza condizioni sul formato.

| Step | Script | Cosa controlla | Legato a |
|---|---|---|---|
| `adr-verify.yaml` | `Test-AdrCorpus.ps1` | corpus delle decisioni | MADR |
| `adr-classes-verify.yaml` | `Test-DecisionClasses.ps1` e, in modalità `fix`, `Repair-DecisionClasses.ps1` | classi .NET che le decisioni governano con i pattern di `governs`, presenti nel loro diagramma delle classi; in modalità `fix`, pattern e diagramma proposti da un modello linguistico | MADR, Mermaid, .NET 10 |
| `arc42-verify.yaml` | `Test-Arc42Document.ps1` | un file per sezione con nome e titolo del template ufficiale | arc42 |
| `c4-read.yaml` | lo script passato con `scriptPath` | repository sorgente letto da un lettore nel frammento del modello C4 | C4 |
| `c4-read-dotnet10.yaml` | `Read-C4DotNet10Model.ps1`, con `c4-read.yaml` | progetti .NET 10 di un repository sorgente letti nel frammento del modello C4 | C4, .NET 10 |
| `c4-read-angular18.yaml` | `Read-C4Angular18Model.ps1`, con `c4-read.yaml` | applicazione Angular 18 di un repository sorgente letta nel frammento del modello C4 | C4, Angular 18 |
| `c4-read-terraform.yaml` | `Read-C4TerraformModel.ps1`, con `c4-read.yaml` | ambienti di deployment della dichiarazione Terraform di un repository sorgente letti nel frammento del modello C4 | C4, Terraform |
| `c4-describe.yaml` | `Write-C4ModelText.ps1` | testo del modello C4 di tutto il sistema dai frammenti di tutti i repository sorgente, scritto dal modello linguistico scelto, con un solo catalogo di persone e sistemi esterni e una revisione di tutto il modello sulla configurazione di produzione | C4, Foundry o Anthropic |
| `c4-generate.yaml` | `Export-C4CodeModel.ps1` | parte del modello C4 generata dai frammenti di un repository sorgente e dal testo del sistema, allineata al codice, e contesto con persone e sistemi esterni | C4 |
| `c4-verify.yaml` | `Test-C4Model.ps1` | modello Structurizr valido e completo, testo del modello coerente con la parte generata, viste mostrate nelle sezioni, misura della leggibilità di ogni vista | C4 |
| `mermaid-verify.yaml` | `Test-MermaidDiagrams.ps1` | diagrammi Mermaid validi, nel documento e nelle decisioni | Mermaid |
| `flows-verify.yaml` | `Test-DiagramFlows.ps1`, con `Sync-DiagramLabels.ps1` e, con `endpoint`, `Repair-DiagramFlows.ps1` in modalità `fix` | flussi fatti degli elementi del modello C4, riconosciuti per identificativo, e delle classi delle decisioni; in una PR, diagrammi allineati ai nomi del modello e riparati da un modello linguistico quando il modello C4 toglie o aggiunge elementi | C4, Mermaid |
| `documentation-verify.yaml` | `Test-Documentation.ps1` | rimandi esistenti, soglie numeriche di leggibilità | nessun formato |
| `documentation-style.yaml` | `Test-DocumentationStyle.ps1` | giudizio dello stile con la guida del repository | nessun formato |
| `documentation-update.yaml` | `Update-Documentation.ps1`, poi `Publish-PullRequest.ps1` | dopo un cambiamento nel ramo principale un modello linguistico riscrive i documenti toccati, le verifiche indicate giudicano ogni stesura, e una PR in auto-complete la porta nel ramo principale; respinta a ogni stesura apre un work item, con il modello non disponibile si riprende alla run successiva | nessun formato |
| `adr-register.yaml` | `Register-Decisions.ps1`, poi `Publish-PullRequest.ps1` | dopo un'integrazione nel ramo principale dei repository sorgente l'ADR in Markdown di ogni Task arrivato nel ramo principale entra nel corpus, accettato e senza modifiche al testo, con una PR in auto-complete; un Task senza ADR, un ADR non in Markdown o una decisione respinta dalla verifica del corpus aprono un work item; una run fallita si recupera con la successiva | MADR |
| `documentation-draft-sources.yaml` | `Write-DraftSources.ps1` | sulla run che scrive la bozza del documento (`targetBranch` diverso da `main`), il ramo letto, il commit e l'albero git di ogni repository sorgente nel file `.draft-sources` del documento | nessun formato |
| `documentation-promote.yaml` | `Promote-Documentation.ps1` | all'inizio della documentazione del ramo principale, se ogni repository sorgente arriva con l'albero registrato dalla bozza, una PR in auto-complete porta la bozza nel documento ufficiale e i passi del modello, delle decisioni e del testo non girano | nessun formato |
| `documentation-draft-sync.yaml` | `Sync-DocumentationDraft.ps1` | dopo un aggiornamento del ramo principale del documento, una PR in auto-complete lo porta nel ramo di bozza | nessun formato |

Con `targetBranch` diverso da `main` `documentation-update.yaml` e `adr-register.yaml` scrivono la bozza del
documento su quel ramo: il ramo della PR prende il suo nome come suffisso (es. `documentation/update/staging`),
le integrazioni delle decisioni sono quelle nel ramo `sourceBranch` dei repository sorgente (`main` per un
repository che non lo ha) e il work item di un rifiuto nomina il ramo nel titolo. `documentation-draft-sources.yaml`
registra da quali alberi dei repository sorgente viene la bozza; quando la documentazione del ramo principale trova
gli stessi alberi, `documentation-promote.yaml` porta la bozza, gia' verificata, nel documento ufficiale senza una
nuova stesura (la variabile `documentationPromoted` salta `c4-read*.yaml`, `c4-describe.yaml`, `c4-generate.yaml`,
`adr-register.yaml` e `documentation-update.yaml`), altrimenti la documentazione si riscrive come senza bozza.
`documentation-draft-sync.yaml` riporta poi il ramo principale nella bozza.

Due ingressi:

- `CI/Agnostic/quality-arc42.yaml`: ADR, struttura arc42, controlli comuni, diagrammi, stile.
- `CI/Agnostic/quality-docs.yaml`: ADR, controlli comuni, diagrammi, stile, per un documento senza un
  formato con struttura propria.

**Lingua del documento.** Le convenzioni che dipendono dalla lingua stanno in
`CI/Scripts/Common/Languages/<lingua>.psd1`, una per file: sezioni degli ADR, marcatore di vista, tag dei
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
| Marcatore di vista | `<!-- vista: <chiave> -->`, `<!-- vista: <tipo>* -->`, `<!-- vista: <prefisso>* -->` | `<!-- view: <chiave> -->`, `<!-- view: <tipo>* -->`, `<!-- view: <prefisso>* -->` |
| Tag dei container con vista dei componenti | `Applicazione` | `Application` |
| Titoli delle viste generate | `Allocazione · <ambiente>`, `Allocazione · <ambiente> · <applicazione>`, `Rete · <ambiente>`, `Rete · <ambiente> · <rete>`, `Container di <applicazione>`, `<container> · logica`, `<container> · accesso ai dati` | `Allocation · <ambiente>`, `Allocation · <ambiente> · <applicazione>`, `Network · <ambiente>`, `Network · <ambiente> · <rete>`, `Containers of <applicazione>`, `<container> · logic`, `<container> · data access` |
| Frasi dello scopo delle viste generate | `ViewPurposes` in `IT.psd1` | `ViewPurposes` in `EN.psd1` |
| Ambiente e viste della rete, relazioni di rete e riassunte | `<ambiente> rete`, tag `Rete` e `Riassunto`, `Comunica con:` fra i livelli dei componenti | `<ambiente> network`, tag `Network` and `Summary`, `Communicates with:` between the component levels |
| Colonne della tabella dei gruppi di risorse | `Gruppo di risorse`, `Contenuto`, `Modulo` | `Resource group`, `Content`, `Module` |
| Frasi della descrizione dei nodi di deployment, per livello | `NodeDescriptions` in `IT.psd1` | `NodeDescriptions` in `EN.psd1` |
| Parti della decisione con struttura e flusso nel codice | `Struttura nel codice`, `Flusso nel codice` | `Code structure`, `Code flow` |
| Pagina della wiki (default di `wikiRoot`) | `Architettura` | `Architecture` |
| Colonna dello stato nella wiki | `Stato` | `Status` |
| Avviso di una decisione sostituita, deprecata o respinta | `DECISIONE SOSTITUITA. …` | `SUPERSEDED DECISION. …` |

I diagrammi li sceglie il consumer: il parametro `diagramSteps` (stepList, default vuoto) riceve gli step
dei diagrammi che il documento usa. Chi non usa C4, o usa un'altra notazione, cambia la lista nel suo
`quality.yml` e non la pipeline. Gli step iniettati prendono i parametri che il consumer passa loro
(default `enforce` e `docs/architecture`) e non girano con `docsMode: 'off'`.

La verifica ha due modalità, ognuna di default `off`:

- `docsMode`: controlli oggettivi (struttura del formato e controlli comuni), senza nessuna regola di stile;
- `styleMode`: giudizio dello stile con un modello linguistico, Foundry o Claude (`styleProvider`, vedi
  [Modello linguistico dei passi di documentazione](#modello-linguistico-dei-passi-di-documentazione)), che
  riceve la guida di stile del repository come istruzioni. La pipeline non conosce nessuna regola di scrittura: cambiare guida non
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

Struttura arc42 (`arc42-verify.yaml`, `CI/Scripts/Arc42/Test-Arc42Document.ps1`):

- **Template.** La release del template ufficiale (variante `plain-markdownMP`), l'URL e lo SHA-256 di
  ogni lingua sono fissati nello script, come per ogni strumento scaricato in pipeline: il consumer
  passa solo `arc42Language`. Una lingua senza template, un download non riuscito o uno SHA-256 diverso
  fanno fallire la verifica nominando il motivo.
- **Sezioni.** Le sezioni del template sono i suoi file Markdown numerati (`01_introduction_and_goals.md`,
  …). Il documento ha un file con lo stesso nome per ogni sezione, con lo stesso titolo di primo
  livello; gli attributi di titolo (`{#section-…}`) non contano. Un file numerato che il template non ha
  è una sezione fuori template; i file non numerati non sono sezioni. Le sottosezioni e il testo li
  giudica il modello con la guida di stile.

Modello C4 (`c4-verify.yaml`, `CI/Scripts/C4/Test-C4Model.ps1`):

- Il modello è `c4/workspace.dsl` nella cartella del documento: il DSL è valido e ha vista di contesto
  e vista dei container; ogni container con il tag delle applicazioni (`Applicazione` in italiano) ha la sua
  vista dei componenti.
- Una vista di contesto mostra solo il livello di business: una persona o un sistema con il tag tecnico
  (`Tecnico` in italiano) resta fuori, ad esempio con `exclude "element.tag==Tecnico"`, e compare dalla
  vista dei container in giù.
- Una sezione mostra una vista con il marcatore di vista (`<!-- vista: <chiave> -->` in italiano), oppure
  tutte le viste di un tipo, in ordine di chiave, con il tipo e l'asterisco (`<!-- vista: component* -->`),
  oppure, con un prefisso che non è un tipo, le viste la cui chiave inizia con il prefisso
  (`<!-- vista: deployment_dev* -->`): così una vista nuova del modello generato si mostra senza scrivere
  il suo marcatore. Ogni vista è mostrata
  da almeno una sezione e ogni marcatore nomina almeno una vista esistente. Senza questo step i marcatori
  non si controllano.
- La parte generata dal codice (`c4-generate.yaml`) porta il tag `Generato` in italiano: ogni elemento
  generato ha una descrizione, ogni relazione generata dice cosa passa, e fra due elementi generati
  nessuna relazione viene da fuori del codice, nemmeno per ripeterne una generata. Fanno eccezione le relazioni
  derivate fra due elementi di deployment (tag `Riassunto` in italiano), che la generazione scrive da quelle fra i
  loro elementi. Un riferimento a un elemento che nessuna
  parte contiene rende il modello non valido, e l'errore nomina l'identificativo.
- Ogni vista si disegna come nella wiki (`CI/Scripts/C4/ViewImages.ps1`): dall'alto in basso e da sinistra
  a destra, con gli spazi di default e stretti, con i ranghi come escono e con i ranghi più larghi di 3, 5
  o 8 elementi a capo (frecce nascoste fra un elemento e quello tante posizioni dopo, come `unflatten` di
  Graphviz), e resta il disegno che si rimpicciolisce meno per entrare in una pagina di `pageWidth` per
  `pageHeight` pixel (default 1200 per 1600). PlantUML disegna fino a 16384 pixel per lato, senza il
  ritaglio di default a 4096. Una disposizione che il layout smetana non riesce a disegnare (un arco che non
  instrada) resta fuori e la vista sceglie fra le altre; solo una vista senza nessuna disposizione disegnabile
  ferma la misura. Il log ne dà misure, disposizione, ranghi e scala. Se anche quel disegno scende sotto `minScale` (default 0.6) un avviso segnala la
  vista come troppo piena, senza fermare la verifica: una vista troppo piena si snellisce nel modello. La
  direzione scritta nel modello è solo il punto di partenza.
- **Requisiti.** Java 17 o successivo per la Structurizr CLI (versione fissata, SHA-256 verificato) e per
  PlantUML, con i font di sistema; lo step li prepara con `ensure-java.yaml` e `ensure-fonts.yaml`. Senza
  Java la verifica fallisce nominando il controllo non eseguito.

Parte del modello C4 generata dal codice (`c4-read*.yaml`, `c4-describe.yaml` e `c4-generate.yaml`).
Nessuna parte del modello si scrive a mano: la struttura nasce in modo deterministico dal codice, il
testo lo scrive un modello linguistico, e i controlli deterministici verificano entrambi.

- **Un lettore per tecnologia e versione.** Ogni lettore conosce solo la sua tecnologia, in una sola
  versione: legge il checkout del repository sorgente e lascia in `fragmentDirectory` un frammento,
  `<repository in minuscolo>.<tecnologia><versione>.json`. Un progetto di un'altra versione ferma la
  lettura nominando progetto e versione: una versione nuova si legge con un lettore nuovo, mai con regole
  provate su un'altra. Ogni lettore gira con `c4-read.yaml`, che gli passa repository, checkout,
  cartella dei frammenti e script comuni; `c4-read-<tecnologia><versione>.yaml` sceglie solo lo script. Il consumer compone i lettori delle tecnologie del
  repository, poi `c4-describe.yaml` e `c4-generate.yaml`, come una pipeline di build compone gli step
  di una tecnologia.
- **Il frammento** (`CI/Scripts/C4/C4CodeModel.ps1`, che i lettori includono) ha tre parti: `manifests`,
  i file di progetto letti, relativi al repository; `containers`, ognuno con `id`, `name`, `codeName`,
  `sources` (le cartelle del suo codice), `technology`, `tags`, `properties` e i `components` con gli
  stessi campi tranne `tags`; `relationships`, coppie `source` e `target` di identificativi. Può
  dichiarare anche `addresses`, gli indirizzi a cui un container si avvia in locale, e `calls`, quelli
  che chiama in locale, ognuno con `container`, `address` (schema, host e porta in minuscolo) e `source`
  (il file che lo dichiara).
- **Relazioni fra applicazioni di repository diversi.** Un indirizzo chiamato a cui si avvia un solo
  container, di qualunque repository, diventa la relazione fra i due, nella parte e nel testo
  dell'applicazione che chiama. Il legame viene da file che lo sviluppo in locale tiene già allineati: se
  il proxy di un'applicazione punta a una porta sbagliata, l'applicazione non funziona in locale. Un
  indirizzo chiamato a cui non si avvia nessun container, o se ne avvia più d'uno, ferma la generazione
  del repository che chiama, nominando il file e l'indirizzo. Tutti i lettori girano prima della
  generazione, che legge i frammenti di tutto il sistema.
- **Il testo** (`c4-describe.yaml`, `CI/Scripts/C4/Write-C4ModelText.ps1`). Un modello linguistico
  (`provider` e `model`, con ragionamento `reasoningEffort`, default `high`) scrive il testo di tutto il sistema in una
  sola generazione, un container alla volta: la descrizione di ogni elemento, ciò che passa su ogni
  relazione, le persone e i sistemi esterni che il container usa o che lo usano, con le loro relazioni.
  Legge i frammenti di tutti i repository sorgente (`sourceRepositories`, con il checkout di ognuno in
  `sourcesDirectory/<repository>`), la struttura del container, il codice delle sue `sources`, gli altri
  container del sistema, la guida di stile (`guide`), i documenti di contesto (`context`) e il catalogo
  delle persone e dei sistemi esterni già dichiarati. Una relazione appartiene al container da cui parte;
  se parte da un elemento che nessun container letto contiene, ad esempio da un'applicazione verso la
  risorsa che l'infrastruttura le assegna, appartiene al container a cui arriva. I nodi di deployment non
  vanno al modello: la loro descrizione la compone lo scrittore. Ogni testo vale per ogni ambiente in cui
  il sistema gira e non nomina l'ambiente; al salvataggio gli a capo e le sequenze di spazi diventano uno
  spazio, perche' un a capo spezzerebbe la frase nel disegno.
- **Una stesura non ferma mai la pipeline.** Ciò che la struttura non contiene si toglie in modo
  deterministico: elementi e relazioni che il codice non dichiara, identificativi non validi o uguali a
  quelli di un elemento del codice, relazioni legate a un elemento assente dal container, persone e
  sistemi esterni senza relazioni, sistemi esterni con il nome di un repository sorgente. Una persona o
  un sistema esterno già nel catalogo, per identificativo o per nome, si scarta e le relazioni passano
  all'identificativo del catalogo. Ciò che manca, cioè un testo da scrivere, una frase oltre `maxWords`
  parole, il nome o la descrizione di una persona o di un sistema esterno, torna al modello con i motivi,
  e il modello riscrive solo quelle voci: le voci già accettate restano. Oltre `maxDrafts` stesure il
  testo si salva comunque, con un avviso e senza la struttura di riferimento, così la run successiva lo
  riscrive. La pipeline fallisce solo se il modello non è disponibile.
- **Il catalogo.** Dopo i container, il modello controlla in una sola chiamata il catalogo delle persone
  e dei sistemi esterni con tutti i container del sistema davanti: unisce due voci che sono la stessa
  persona o lo stesso sistema, e toglie un sistema esterno che è un container del sistema, passandone le
  relazioni al container. Una risposta respinta torna al modello fino a `maxDrafts` volte; una voce
  ancora respinta resta distinta.
- **La revisione.** Infine il modello rivede tutto il sistema insieme, perché descriva ciò che gira in
  produzione. Un sistema esterno resta solo se il modello cita un tratto di un file della configurazione
  di produzione (`reviewEvidence`, percorsi `<repository>/<percorso>` sotto `sourcesDirectory`) e il
  tratto compare davvero nel file; una relazione con una persona o un sistema esterno che non è vera si
  toglie; ogni risorsa prende un nome unico nel sistema che dice ciò che fa, mai il suo nome tecnico, e
  due container senza componenti e della stessa tecnologia che sono copie della stessa cosa si uniscono:
  la copia non si scrive e le sue relazioni passano al container che resta. Il nome di un'applicazione
  non lo dà la revisione (vedi **Nomi**). Una risposta respinta torna al modello fino a `maxDrafts`
  volte; un sistema esterno ancora senza prova esce dal modello. La revisione si ripete solo quando
  cambiano la struttura, la configurazione di produzione o le istruzioni della revisione, e le sue decisioni si
  salvano con le prove in `model.text.json`. Un sistema esterno escluso e una relazione tolta restano nel
  testo e non entrano nel modello: la revisione successiva li giudica di nuovo, così un'esclusione
  sbagliata si corregge appena la configurazione di produzione ne porta la prova.
- **Il testo salvato e le correzioni.** Il testo accettato si salva in `model.text.json` nella cartella
  delle parti generate e, con `progressBranch`, sul ramo, un container alla volta: rilanciata, la
  pipeline riparte da ciò che non ha testo accettato. Il testo di un container la cui struttura non
  cambia resta quello accettato; quello di un container sparito si toglie. Ogni voce tolta, unita o
  rimasta da scrivere si elenca in `correctionsFile`, che la PR aggiunge alla propria descrizione.
- **Un lettore del consumer** (`c4-read.yaml`). Per una tecnologia o una convenzione che questo
  repository non conosce, ad esempio come l'infrastruttura di un progetto lega un'applicazione al suo
  progetto, il consumer scrive il lettore nel proprio repository e lo passa con `scriptPath`, con le sue
  variabili in `environment`. Lo script trova gli script comuni (`CI/Scripts/Common/`) in
  `C4_SCRIPTS_DIRECTORY` (`V3/CI/Scripts`), ad esempio `$env:C4_SCRIPTS_DIRECTORY/C4/C4CodeModel.ps1` e
  `$env:C4_SCRIPTS_DIRECTORY/Common/VerificationGate.ps1`, e scrive il frammento con lo stesso
  contratto.
- **Lo scrittore** (`CI/Scripts/C4/Export-C4CodeModel.ps1`) unisce i frammenti del repository e scrive
  `containers/<repository in minuscolo>.dsl` nella cartella delle parti generate: il sistema di
  `c4/workspace.dsl` include la cartella intera (`!include generated/containers`), senza elencare i
  repository. Con più di un container, i container stanno in un gruppo con il nome
  del repository senza il prefisso comune ai repository sorgente; un container unico non ha gruppo; ogni elemento porta il tag `Generato` in italiano e il nome
  completo nella proprietà `codice`, e una proprietà vuota non si scrive. Prende da `model.text.json`
  le descrizioni e ciò che passa sulle relazioni dei propri elementi, comprese quelle che partono da un
  altro repository, e le relazioni con persone e sistemi esterni legate ai propri container. Non
  conosce le tecnologie: un
  file di progetto del repository (`*.csproj`, `package.json`, `angular.json`, `*.tf`, `pom.xml` e gli
  altri della sua lista) che nessun frammento dichiara letto ferma la generazione nominando il file, e
  così un frammento che non si legge. Il file generato non si scrive a mano. Scrive anche
  `views/<repository in minuscolo>.dsl`, che le viste del documento includono come cartella
  (`!include generated/views`). Ogni applicazione ha una vista dei container con chiave
  `container-<applicazione>`: l'applicazione e gli elementi con cui ha relazioni, in entrambe le direzioni.
  Ogni vista generata ha un titolo suo, fatto dai nomi delle parti che mostra (`Container di <applicazione>`
  in italiano), e come descrizione la frase fissa che dice il suo scopo (`ViewPurposes` della lingua).
  Una vista con tutte le applicazioni di un repository sommerebbe i loro vicini e non si leggerebbe alla
  scala minima. La vista appartiene al sistema che in `workspace.dsl`, accanto alla cartella delle parti generate,
  include la cartella `containers`; se il workspace non lo dichiara la generazione si ferma. Un container
  con componenti ha la vista della logica, con l'identificativo del container come chiave, e quella
  dell'accesso ai dati, con chiave `<container>-accesso-dati` in italiano, ciascuna solo se ha componenti.
  La vista della logica mostra i componenti che non sono di accesso ai dati e gli elementi fuori dal
  container in relazione con loro. Quella dell'accesso ai dati mostra i suoi componenti, ciò che ognuno usa
  e gli elementi fuori dal container che li chiamano. Il titolo di ognuna è il nome del container con il
  livello (`<container> · logica`, `<container> · accesso ai dati`); se i suoi componenti hanno relazioni con
  quelli dell'altro livello, la descrizione della vista li nomina, dopo la frase dello scopo, con il titolo
  dell'altra vista (`Comunica con: <titolo> (<componenti>)`). Un componente è di accesso ai dati se un segmento del
  suo nome, separato da punti, è fra `dataAccessSegments` (default `DataAccess`). Scrive
  infine `context.dsl`, da includere nel modello prima del sistema: le persone e i sistemi esterni del
  catalogo, i sistemi con il tag `Esterno` e, se tecnici, `Tecnico`. Si committa con le parti generate.
- **La PR della parte** (`azureRepos-pull-request.yaml`, `CI/Scripts/AzureRepos/Publish-PullRequest.ps1`).
  Dopo lo scrittore, porta la cartella delle parti generate sul ramo di `progressBranch` e apre una PR
  verso `targetBranch` con il completamento automatico, che cancella il ramo a fine integrazione. Se la
  cartella non cambia non si apre nessuna PR, e un ramo rimasto senza PR si cancella; una PR attiva sullo
  stesso ramo si aggiorna. Con `originDirectory` la descrizione cita l'ultimo commit del repository
  sorgente, cioè la PR che lo ha integrato; con `descriptionFile` vi aggiunge il contenuto del file, se
  esiste. L'identità della build deve poter contribuire al repository
  della documentazione, creare rami e contribuire alle PR.
- **.NET 10** (`c4-read-dotnet10.yaml`). Ogni progetto dichiara `net10.0` in `TargetFramework` o
  `TargetFrameworks`, o lo eredita dal `Directory.Build.props` più vicino; un'altra versione, o nessuna,
  ferma la lettura. Il tipo di un progetto viene dalla prima regola di .NET 10 del lettore che gli
  corrisponde (SDK, `OutputType`, `IsTestProject`, `AzureFunctionsVersion`, SDK di test): SDK Web e
  Function App sono applicazioni e diventano container, un progetto da riga di comando è uno strumento
  e resta fuori, un tipo che nessuna regola riconosce ferma la lettura. I componenti di un'applicazione
  sono i progetti di produzione che raggiunge con i riferimenti, senza i progetti di test; un progetto
  usato da più applicazioni è un componente di ognuna. Le relazioni sono i riferimenti fra progetti,
  nella direzione del flusso del controllo: un progetto che implementa un'interfaccia del progetto che
  referenzia (una porta) ne è l'adattatore, e la relazione va dalla porta all'adattatore; se usa anche
  un'altra interfaccia di quel progetto, c'è anche la relazione opposta. Un'interfaccia che il progetto
  dichiara a sua volta con lo stesso nome non conta, e l'applicazione tiene la relazione verso i
  progetti che compone. Le dichiarazioni si leggono dai file `.cs`, all'inizio della riga. I
  servizi Azure con cui un'applicazione parla non vengono dalle librerie: li dice l'infrastruttura. Gli
  indirizzi di avvio sono gli `applicationUrl` dei profili in `Properties/launchSettings.json`
  dell'applicazione; un file che non si legge, o un indirizzo senza schema `http` o `https`, ferma la
  lettura.
- **Angular 18** (`c4-read-angular18.yaml`). Il `package.json` del workspace dipende da `@angular/core`
  18 (`^18.x`, `~18.x` o `18.x`); un'altra versione, un intervallo che va oltre la 18 o nessuna
  dipendenza ferma la lettura. L'applicazione del workspace è un container con il nome del repository
  senza il prefisso comune ai repository sorgente; i componenti sono le cartelle di funzionalità e i
  moduli di base con un file `*.providers.ts`, le relazioni gli import fra cartelle. Un progetto che non
  è l'unica applicazione del workspace, o un secondo workspace, ferma la lettura. Gli indirizzi chiamati
  sono i `target` del proxy del dev server, il file JSON di `proxyConfig` nelle opzioni di `serve`; un
  proxy che non è un file JSON leggibile, o un target che non è un indirizzo, ferma la lettura.
- **Terraform** (`c4-read-terraform.yaml`), dopo i lettori dei container. La dichiarazione Terraform si
  valuta ambiente per ambiente senza eseguire Terraform e senza leggere lo stato: codice del modulo
  radice, `values.tfvars`, file `*_override.tf` e `backend.tf` della directory d'ambiente
  (`<modulo radice>/environments/<ambiente>`), default delle variabili, `locals`, argomenti e output dei
  moduli, output del remote state di un altro workspace del repository. Una variabile senza valore nel
  repository e' un valore sconosciuto, scritto `{var.nome}`; un `count` o un `for_each` sconosciuto di
  una risorsa dei nodi, o un'espressione che il valutatore non conosce, ferma la lettura con file e riga.
  `environments` associa a ogni ambiente del modello la sua directory d'ambiente; una directory che non
  vi compare entra negli ambienti con cui scambia remote state. `instances` istanzia un modulo radice
  per ogni directory di un glob, con il nome della directory in una variabile. Ogni ambiente del modello
  ne scrive due, ciascuno per una domanda. L'allocazione, `<ambiente>`: la regione della risorsa (o del suo
  gruppo di risorse), con i piani di calcolo e le applicazioni che ospitano; un'applicazione senza piano sta
  nella regione, e cosi' un servizio che ospita un container. La rete, `<ambiente> rete` in italiano: le reti
  virtuali con le subnet, le applicazioni che vi si integrano, i private endpoint, con il nome della risorsa
  che espongono e i servizi esposti, e gli Application Gateway; i profili Front Door con i loro endpoint; le
  relazioni di peering fra due reti (una per coppia), di origine dall'endpoint del Front Door alla risorsa
  che l'origine nomina, anche attraverso un record DNS e un IP pubblico, e di backend dall'Application
  Gateway all'applicazione o al private endpoint del suo pool. Un collegamento che la dichiarazione non
  risolve, come un nome fuori dalla dichiarazione, da' un avviso e non ferma la lettura. Ogni elemento porta
  il gruppo di risorse, il modulo radice che lo dichiara, il nome Azure della risorsa (un'istanza quello
  della risorsa che la ospita; una regione nessuno) e il suo livello (`region`, `hostingPlan`,
  `application`, `virtualNetwork`, `subnet`, `privateEndpoint`, `gateway`, `ingress`, `ingressEndpoint`).
  La descrizione di un nodo la compone lo scrittore con le frasi del suo livello in `NodeDescriptions`
  della lingua del documento, riempite con i nomi che il modello gia' contiene (cio' che il nodo ospita,
  la parte che espone, la rete in cui sta, le relazioni che riceve o manda), senza tipo di risorsa e senza
  a capo; una frase senza nomi non si scrive, e un livello senza frasi ferma l'esportazione nominandolo.
  Un container dei frammenti sta sulla risorsa con
  il suo nome nel codice o su quella che un frammento dichiara in `hosts`. Una risorsa che ospita un
  container o che gira su un piano, di un tipo che le regole non riconoscono, ferma la lettura nominandola.
  Lo scrittore mette gli ambienti in `deployment/<repository>.dsl`, da includere nel modello dopo il
  sistema software, e le viste in `deployment-views/<repository>.dsl`, da includere nelle viste. Le viste
  nascono dalle domande e non dalla forma dell'albero dei nodi: per ogni ambiente l'allocazione
  (`deployment_<ambiente>`), con i soli piani di calcolo, le applicazioni che ospitano e le chiamate fra le
  applicazioni; per ogni applicazione ospitata la sua allocazione (`deployment_<ambiente>_app_<container>`),
  con il suo piano, i servizi e le applicazioni con cui ha relazioni e solo le sue relazioni; la rete
  (`deployment_<ambiente>_rete`), con le reti e i profili d'ingresso chiusi e fra loro le relazioni di rete,
  per ogni rete con subnet la sua vista (`deployment_<ambiente>_rete_<rete>`), con chiuse le radici con
  cui ha relazioni. In ogni vista una relazione si disegna fra gli elementi piu' vicini alle sue estremita'
  che la vista mostra: quando un'estremita' sta dentro un nodo chiuso, la generazione scrive una volta
  sola la relazione derivata fra i due elementi visibili, con un identificativo, i testi uniti e il tag
  `Riassunto`, e ogni vista esclude le derivate delle altre viste di cui mostra entrambe le estremita'.
  Un nodo e un'istanza di container, che Structurizr non collega, si collegano attraverso il nodo
  dell'istanza. Le viste di rete mostrano solo le relazioni con il tag `Rete`. Il titolo dice il tipo della vista, l'ambiente e la parte
  (`Allocazione · prod · Bff.Web` in italiano) e la descrizione e' la frase fissa dello scopo del tipo.
  L'allocazione dichiara nella proprieta' `resourceGroups` gli ambienti di cui la pubblicazione elenca i
  gruppi di risorse in una tabella sotto l'immagine, con il nome Azure di ogni risorsa. Due nodi fratelli con lo stesso nome, che Structurizr
  rifiuta, aggiungono al nome i servizi esposti, il gruppo di risorse o il nome della risorsa, e la
  posizione se restano uguali. Il disegno riapre la grandezza del titolo su ogni riga della descrizione,
  che l'esportatore C4-PlantUML chiude solo in fondo.
- **Nomi.** Il nome nel codice senza il prefisso comune ai progetti del repository, a segmenti interi e
  più corto di ogni nome. L'identificativo si ricava dal nome completo, così un repository nomina gli
  elementi degli altri senza leggerli. Nel modello di tutto il sistema un'applicazione si chiama con il
  nome nel codice senza il prefisso comune a tutte le applicazioni (con `Contoso.Shop.AI.Api` e
  `Contoso.Shop.Bff.Web`, `AI.Api` e `Bff.Web`): il lettore vede un solo repository.
- Con `generationMode: check` il file del documento si confronta con quello che la generazione produce:
  una differenza nomina il file.

Diagrammi Mermaid (`mermaid-verify.yaml`, `CI/Scripts/Mermaid/Test-MermaidDiagrams.ps1`):

- Ogni diagramma Mermaid delle sezioni e delle decisioni passa dal parser: l'errore nomina sezione (o
  titolo della decisione), file e riga. Una cartella che non esiste non ha diagrammi da verificare.
- **Requisiti.** Node.js (dipendenze fissate da `CI/Scripts/Mermaid/Parser/package-lock.json`); lo step lo
  prepara con `UseNode@1`. Senza Node.js la verifica fallisce nominando il controllo non eseguito.

Classi delle decisioni (`adr-classes-verify.yaml`, `CI/Scripts/Adr/Test-DecisionClasses.ps1`):

- **Pattern.** Una decisione con la parte della struttura nel codice dichiara nel frontmatter `governs` i
  pattern sui nomi completi delle classi che governa: un nome completo, o un prefisso che finisce con `*`
  (`Contoso.Shop.Core.Queue.*`, `Contoso.Shop.Core.Handlers.V2.QueueTicket*`).
- **Confronto.** Le classi di primo livello (classi, record, struct, interfacce, enum) dei progetti .NET che non
  sono di test, nella cartella `sourceDirectory` con il codice dei repository sorgente, lette con le regole del
  lettore .NET 10 del modello C4 (`CI/Scripts/C4/DotNet10Code.ps1`), che corrispondono a un pattern stanno nel
  diagramma delle classi della decisione. La verifica fallisce nominando la decisione e la classe, o la voce di
  `governs` che non copre nessuna classe, e se la decisione ha la struttura senza `governs`, `governs` senza la
  struttura o la struttura senza diagramma delle classi. Una classe che nessun pattern copre, come la classe
  del framework da cui una classe governata eredita, non si controlla; un tipo annidato neppure. Le decisioni
  `superseded`, `deprecated` e `rejected` non si controllano.
- **Proposta.** In modalità `fix`, `CI/Scripts/Adr/Repair-DecisionClasses.ps1` propone prima con il modello
  linguistico le decisioni che la verifica respinge o che hanno classi candidate: le classi dei namespace delle
  classi governate che nessun pattern copre e che il registro `candidatesFile` non ha già visto. Il modello
  riceve la decisione, i rilievi, le candidate e il codice delle classi, e risponde con le voci da aggiungere a
  `governs` (mai da togliere), la parte della struttura nel codice riscritta e la riga della versione; lo script
  alza la versione della decisione e aggiunge la voce sotto Versioni. La verifica delle classi, quella del flusso
  della decisione e il parser accettano la stesura o la rimandano con i motivi, fino a `maxDrafts` stesure; poi
  la decisione resta com'è e il passo la segnala senza fallire. Ogni decisione accettata e il registro vanno in
  un commit sul ramo `progressBranch`, da cui una run rilanciata riprende senza richiamare il modello; il
  registro evita di chiedere al modello le stesse candidate a ogni run. La verifica che segue segnala senza
  bloccare: il cancello è la quality della PR che il consumer apre con le decisioni proposte.
- **Requisiti.** Node.js per il parser Mermaid, preparato dallo step con `UseNode@1`, e il checkout dei
  repository sorgente prima dello step; in modalità `fix`, il modello linguistico (vedi sotto) e un'identità
  della build che può creare il ramo `progressBranch`.

Flussi (`flows-verify.yaml`, `CI/Scripts/Mermaid/Test-DiagramFlows.ps1`):

- **Partecipanti.** Un partecipante è un elemento del modello C4 per il suo identificativo nel DSL, che è
  l'alias, e ne mostra il nome: `participant motore as API del Motore`. Il nome è un'etichetta: quando il
  modello lo cambia, l'identità resta. Una seconda istanza dello stesso elemento nello stesso diagramma
  ha l'alias `<identificativo>~2`. In modalità `fix`, in una PR, `CI/Scripts/Mermaid/Sync-DiagramLabels.ps1`
  allinea prima i diagrammi delle sezioni al modello: ogni partecipante prende come etichetta il nome del
  modello e ogni riquadro il nome del container dei suoi componenti; un partecipante scritto con un nome
  si riconosce dal nome, nel modello della PR o, se quel nome non c'è più, nel modello del ramo base, e
  prende come alias il suo identificativo. Le righe cambiate tornano sul ramo della PR in un commit, e la
  verifica riparte dalla build di quel commit. Un elemento che nessun modello riconosce resta com'è e lo
  segnala la verifica.
- **Riparazione.** Con `endpoint` (Foundry) o con `provider: 'anthropic'`, in modalità `fix`, in una PR,
  `CI/Scripts/Mermaid/Repair-DiagramFlows.ps1` ripara poi con il modello linguistico le sezioni che la verifica respinge ancora, ad esempio per un
  elemento tolto dal modello C4 o per una chiamata che il modello fa passare per altri elementi. Il modello
  linguistico riceve il modello C4, i rilievi e la sezione, e risponde con i diagrammi riscritti e le frasi
  che li descrivono; la verifica dei flussi accetta la stesura o la rimanda con i rilievi rimasti, fino a
  `maxDrafts` stesure, poi la sezione resta com'è e la verifica la segnala. Ogni sezione accettata va in un
  commit sul ramo di appoggio `flows-repair/<commit della PR>` e tutti i commit tornano sul ramo della PR a
  fine giro; se il job si interrompe, la build dopo li porta sul ramo della PR senza chiamare il modello.
  Le decisioni non si riparano. Nessuna regola del documento vive nella pipeline: decidono i rilievi della
  verifica e il modello C4.
- **Sezioni.** Un flusso è un titolo di secondo livello con diagrammi di sequenza: ha almeno un diagramma a
  livello dei container, cioè senza riquadri, i cui partecipanti sono container, persone o sistemi del
  modello C4. I diagrammi di dettaglio mettono ogni componente nel riquadro
  (`box API del Motore`) del container a cui il modello lo assegna; gli altri container, le persone e i
  sistemi possono comparire interi, fuori dai riquadri, ma un container non compare nello stesso
  diagramma sia intero sia con i suoi componenti. Ogni chiamata fra due partecipanti diversi è una
  relazione del modello nella stessa direzione, comprese quelle che Structurizr ricava dai livelli
  inferiori. Le risposte (frecce tratteggiate) e le chiamate di un partecipante a sé non si controllano.
  L'errore nomina la sezione, il file e la riga del diagramma, e il partecipante, il riquadro o la
  chiamata, oppure il file e il flusso senza diagramma a livello dei container; un'etichetta diversa dal
  nome nel modello è un errore.
- **Decisioni.** Una decisione `NNNN-titolo.md` aperta (non `superseded`, `deprecated` o `rejected`)
  con la parte `Struttura nel codice` ha la parte `Flusso nel codice`, con almeno un diagramma di
  sequenza; i suoi partecipanti sono classi del diagramma delle classi della parte della struttura.
  Altri diagrammi del flusso, come quello degli stati, non si controllano.
- Un diagramma non valido lo segnala `mermaid-verify.yaml`, il modello non valido `c4-verify.yaml`: qui
  si salta il primo e si nomina il secondo.
- **Requisiti.** Java 17 o successivo e Node.js, preparati dallo step come in `c4-verify.yaml` e
  `mermaid-verify.yaml`.

Controlli comuni (`documentation-verify.yaml`, `CI/Scripts/Documentation/Test-Documentation.ps1`), su ogni file
Markdown della cartella del documento:

- **Rimandi.** I link relativi puntano a file e ancore esistenti; un identificativo di decisione
  `NNNN-titolo` nel testo esiste in `decisionsDirectory`.
- **Soglie numeriche** (solo se dichiarate). Indice Gulpease minimo del testo di ogni sezione
  (`docsGulpease`) e parole massime per frase (`docsMaxWords`); `docsAbbreviations` sono le
  abbreviazioni che non chiudono una frase.

Gli script condividono `CI/Scripts/Common/VerificationGate.ps1` (modalità, rilievi, codice di uscita) e
`CI/Scripts/Common/MarkdownText.ps1` (lettura delle sezioni e misure di leggibilità).

Giudizio dello stile (`styleMode`, `CI/Scripts/Documentation/Test-DocumentationStyle.ps1`):

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
  altrimenti si annulla e il modello riceve il motivo. L'ultimo dei `maxRounds` giri verifica soltanto:
  `quality-arc42` e `quality-docs` lo espongono come `styleMaxRounds` (default `4`). Un file si ferma al
  primo giro senza rilievi, quindi i giri in più si pagano solo dove servono.
- Il job di `quality-arc42` e `quality-docs` ha un timeout di 90 minuti (`timeoutInMinutes`), perché il giudizio
  in modalità `fix` di un documento intero supera i 30 minuti di un job di build; se il job si ferma comunque, il
  giudizio riparte dai file già registrati sul ramo `style-judge/<commit>`.
- `styleMaxFindings` è la soglia delle violazioni tollerate: fino alla soglia restano come avvisi e la
  verifica passa con esito parziale (`SucceededWithIssues`); oltre la soglia la verifica fallisce e le nomina
  tutte. `0` (default) blocca ogni violazione, `-1` non pone limiti. In modalità `fix` contano le violazioni
  che l'ultimo giro trova ancora.
- In modalità `fix` ogni file giudicato ha il suo commit, con le correzioni che superano i controlli
  oggettivi, il trailer `Style-Judge-Done: <file>` e, oltre la soglia, una riga `Style-Judge-Pending` per ogni
  unità rimasta, con il suo rilievo (regola, testo, spiegazione) e le correzioni già scartate. Il giudizio
  dopo rilegge di ogni file solo le righe cambiate dal suo commit e le unità in sospeso, non il resto del
  documento. Un file con sole unità in sospeso riprende le correzioni con tutti i giri e riceve al primo giro
  i rilievi salvati: rilanciare la build continua il lavoro dove si era fermato, senza ricominciare. Se una
  correzione resta, il commit del file la pubblica con le unità ancora in sospeso; se nessuna resta e le
  violazioni restano, non si pubblica nulla, così il push non avvia un'altra build sullo stesso rilievo; se le
  violazioni spariscono, un commit del file chiude le unità.
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
- Accesso al modello come in [Modello linguistico dei passi di documentazione](#modello-linguistico-dei-passi-di-documentazione).
  Su 429, 529 o 5xx lo script riprova rispettando `Retry-After`, fino a dieci tentativi; se il modello non
  risponde la verifica fallisce nominando il motivo.

### Modello linguistico dei passi di documentazione

Il giudizio dello stile (`documentation-style.yaml`, e `styleProvider` di `quality-arc42` e `quality-docs`), il
testo del modello C4 (`c4-describe.yaml`), la riparazione dei diagrammi (`flows-verify.yaml`), l'aggiornamento
della documentazione (`documentation-update.yaml`) e la proposta delle classi delle decisioni
(`adr-classes-verify.yaml`) scelgono il fornitore del modello con il parametro `provider`, passato agli script (`CI/Scripts/LanguageModel/`):

- `foundry` (default): `model` è il deployment Azure OpenAI di `endpoint`; il passo è un `AzureCLI@2` sulla
  `serviceConnection`, con un token Entra ID, senza chiavi.
- `anthropic`: Claude a consumo sull'API Anthropic, `model` è il modello (es. `claude-sonnet-5-5`), `endpoint`
  vuoto vuol dire `https://api.anthropic.com`. Il passo è un `PowerShell@2`: niente service connection, niente
  Azure CLI. La chiave è una variabile segreta della pipeline del consumer: Azure Pipelines non passa le
  variabili segrete agli script, quindi il passo la mappa in `ANTHROPIC_API_KEY` da `anthropicApiKey`
  (`styleAnthropicApiKey` negli entry point), che di default vale `$(anthropicApiKey)`. Senza la variabile il
  passo fallisce con `chiave Anthropic non configurata (ANTHROPIC_API_KEY)`.

```yaml
variables:
  - group: documentazione   # contiene anthropicApiKey, segreta

extends:
  template: V3/CI/Agnostic/quality-docs.yaml@infrastructure
  parameters:
    styleMode: 'fix'
    styleProvider: 'anthropic'
    styleModel: 'claude-sonnet-5-5'
```

### Pubblicazione nella wiki (publish-arc42-wiki)

Dopo il merge su `main` il documento arc42 si pubblica nella wiki di progetto di Azure DevOps
(`CI/Agnostic/publish-arc42-wiki.yaml`, lo step `CI/Common/Steps/arc42-wiki-publish.yaml` e lo script
`CI/Scripts/Arc42/Publish-Arc42Wiki.ps1`). Lo step prepara Java e i font di sistema con `ensure-java.yaml` ed
`ensure-fonts.yaml`. Prima della pubblicazione dichiara la lingua del documento (`document-language.yaml`) ed
esegue i `composeSteps` del consumer, gli step che preparano i file del documento prima della
pubblicazione:

- Ogni sezione diventa una pagina sotto `wikiRoot` (default il nome della lingua, `Architettura` o
  `Architecture`), nell'ordine dei numeri; le decisioni diventano sottopagine della sezione 9, quella
  delle decisioni nel template arc42, e la tabella che le elenca riceve la colonna dello stato.
- Una decisione sostituita, deprecata o respinta comincia con un avviso in rosso, e l'indice ne mostra lo
  stato in rosso. L'avviso di una decisione sostituita rimanda alla pagina di `superseded-by`: il testo
  della decisione non cambia, l'avviso viene dallo stato.
- I marcatori di vista diventano le immagini PNG delle viste C4: la Structurizr CLI le esporta in
  C4-PlantUML e PlantUML (versione fissata, SHA-256 verificato) le disegna con le librerie C4 interne e il
  layout smetana, senza Graphviz e senza rete, nella disposizione che si legge meglio, come nella verifica
  del modello. Le immagini stanno in `.attachments/<wikiRoot>/<vista>.png`. Prima dell'immagine di una
  vista con un titolo stanno il titolo, in grassetto, e la descrizione della vista, che ne è anche il testo
  alternativo; una vista senza titolo ha la chiave come testo alternativo. Lo stesso vale nel documento unico.
  Con la proprieta' `c4plantuml.tags` delle viste, colori e forme vengono dagli stili del modello, che
  allora dichiara anche quelli di `Person`, `Software System`, `Container` e `Component`.
- I blocchi ` ```mermaid ` diventano la sintassi della wiki `::: mermaid`. I link alle sezioni e alle
  decisioni portano alle pagine; gli altri link relativi al file nel repository.
- Un commit solo nel repository git della wiki tocca soltanto `wikiRoot`, le sue immagini e la sua voce in
  testa all'ordine della radice: le altre pagine della wiki restano come sono. Se la wiki cambia nel
  frattempo, il push si riprova sopra il commit nuovo; se non cambia nulla, nessun commit.
- Con `documentFormats` (`['pdf', 'docx']`, o uno dei due) le stesse pagine diventano anche un documento unico,
  `.attachments/<wikiRoot>/<wikiRoot>.pdf` e `.docx`, che la pagina `wikiRoot` nomina e che lo stesso commit allega
  alla wiki (`CI/Scripts/Arc42/Arc42Document.ps1`). Il documento ha la versione del commit sotto il titolo,
  l'indice e le sezioni numerate; le decisioni sono sottosezioni della sezione 9 con il loro stato; le viste C4
  sono le stesse immagini della wiki e i diagrammi Mermaid PNG disegnati da Chrome headless. I link alle
  sezioni e alle decisioni diventano rimandi nel documento; quelli al repository e alle altre risorse di Azure
  DevOps testo, perche' il documento si legge anche senza accesso. pandoc (versione fissata, SHA-256
  verificato) scrive il Word e l'HTML che Chrome headless stampa in PDF A4; lo step installa Node.js e, su
  Linux, le librerie di Chrome con `ensure-chrome-libraries.yaml`. La stessa fonte da' gli stessi file: le
  date nel documento sono quelle del commit, e una pubblicazione senza modifiche non crea commit.
- Con `draftRepository`, l'alias di una repository resource sul ramo di bozza del documento (`draftBranch`,
  default `staging`), la stessa pubblicazione legge anche la bozza: ogni pagina il cui Markdown, o il disegno di
  una vista mostrata, differisce da quello ufficiale, e ogni pagina che esiste solo nella bozza, diventa una
  pagina sorella con il suffisso della lingua (`<titolo> (bozza)` o `<title> (draft)`) subito dopo la pagina
  ufficiale, con in testa l'avviso della bozza in un colore suo e le immagini in
  `.attachments/<wikiRoot>/draft/`. La pagina ufficiale che ha una bozza vi rimanda in testa. PDF e Word restano
  quelli del documento ufficiale, e le bozze che non differiscono piu' spariscono alla run successiva.

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
    documentFormats: ['pdf', 'docx']    # documento unico allegato alla wiki (default: nessuno)
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
pip install -r Tests/Static/requirements.txt
yamllint -c Tests/Static/.yamllint.yaml V3/ V4/
python Tests/Static/check-references.py
python Tests/Static/check-parameters.py
```

```powershell
# Livello 2 — da root del repo
Invoke-Pester Tests/V3/CI/Scripts/ -Output Detailed
```

### GitHub Actions

I workflow si attivano automaticamente su ogni push e su ogni PR verso `main`, **solo se i file modificati ricadono nei path monitorati**:

| Workflow | Trigger (path) |
|---|---|
| `test-static.yml` | `V3/**`, `V4/**`, `Tests/Static/**` |
| `test-scripts.yml` | `V3/CI/Scripts/**`, `Tests/V3/CI/Scripts/**` |

Documentazione completa: [`Tests/README.md`](Tests/README.md)

---

## Script condivisi (V3)

Gli script stanno in `CI/Scripts/`, una cartella per strumento o standard, con le librerie e i dati
che usano solo loro: `Adr/`, `Arc42/` (con PlantUML), `C4/` (con Structurizr e il contratto del
frammento), `Mermaid/` (con il parser in `Parser/`), `Documentation/`, `AzureBoards/`, `AzureRepos/`, `Release/` (con git-cliff e
`cliff.toml`), `ScenarioCoverage/`, `LanguageModel/` (il modello linguistico dei passi di documentazione).
`Common/` contiene solo ciò che usano più cartelle: modalità delle verifiche, lingua del documento con
`Languages/`, lettura del Markdown. I test ricalcano lo stesso
albero in `Tests/V3/CI/Scripts/`, con le fixture accanto ai test che le usano.

| Script | Scopo |
|---|---|
| `CI/Scripts/Release/cliff.toml` | Unica sorgente delle regole Conventional Commits: tipi ammessi, gruppi delle release notes, prefisso ADO `Merged PR <id>: `, regole di bump |
| `CI/Scripts/Release/GitCliff.ps1` | Scarica git-cliff (versione fissata, SHA-256 verificato) e lo espone a `Set-Versioning.ps1`, `Verify-SemVer.ps1` e `New-ReleaseNotes.ps1` |
| `CI/Scripts/Release/Verify-SemVer.ps1` | Gate sui Conventional Commits delle PR verso i branch configurati: segnala solo se né il titolo né alcun commit della PR è convenzionale (senza PR, l'ultimo commit non-merge); modalità `off`/`warn`/`enforce`, di default `enforce` su `dev`, `staging` e `main` |
| `CI/Scripts/Release/Set-Versioning.ps1` | Calcola la versione con `git cliff --bumped-version`: tag Git su staging/main, prerelease `x.y.z-dev.<BuildId>` senza tag altrove; setta `currentTag`, `assemblyVersion`, `gitHash`, `computedArtifactName`; usa la versione come build number del run e marca con il tag `release` le publish di rilascio |
| `CI/Scripts/Release/New-ReleaseNotes.ps1` | Release notes dal tag del rilascio precedente sullo stesso ramo, ogni voce con link al commit, alla PR che lo ha integrato e ai work item della PR: summary della run e, su main, pagina wiki |
| `CI/Scripts/Release/Test-PublishedArtifact.ps1` | Prima dell'upload dell'artifact negli orchestratori GitFlow e TrunkFlow: se la run lo ha già pubblicato (rerun dello stage) setta `artifactAlreadyPublished` e l'upload si salta; se la verifica non riesce l'upload procede |
| `CI/Scripts/Adr/Test-AdrCorpus.ps1` | Verifica il corpus degli ADR di un repository di documentazione (`quality-docs.yaml`): nome `NNNN-titolo.md`, stato ammesso, sezioni obbligatorie, versione intera, sostituzioni reciproche, ADR `accepted` con l'esito invariato e cambiati solo con una versione nuova rispetto al ramo di destinazione della PR |
| `CI/Scripts/Adr/Register-Decisions.ps1`, `DecisionRegistration.ps1` | Registrazione delle decisioni (`adr-register.yaml`): PR completate nel ramo principale dei repository sorgente dal punto di partenza registrato nel repository all'istante del server, con le PR di sviluppo che una promozione contiene (`Merged PR <numero>`); ADR in Markdown del Task trascritto con stato, data, Task, PR e promozione nel frontmatter; sostituzione reciproca dalla riga con l'etichetta della lingua del documento; una decisione per Task; verifica del corpus con i soli rilievi nuovi; work item per un Task senza ADR, un ADR non in Markdown o una decisione respinta; registrazione ancora aperta unita prima di registrare |
| `CI/Scripts/Arc42/Test-Arc42Document.ps1` | Struttura di un documento arc42 (`arc42-verify.yaml`): un file per sezione con nome e titolo del template ufficiale; release, URL e SHA-256 per lingua fissati nello script |
| `CI/Scripts/C4/Test-C4Model.ps1` | Modello C4 in Structurizr DSL (`c4-verify.yaml`): modello valido, viste obbligatorie, componenti dei container con il tag delle applicazioni, nessun elemento tecnico nelle viste di contesto, elementi e relazioni generati descritti, nessuna relazione fra elementi generati che il codice non dichiara salvo le relazioni riassunte fra nodi, marcatori di vista nelle sezioni |
| `CI/Scripts/Adr/Test-DecisionClasses.ps1` | Classi governate dalle decisioni (`adr-classes-verify.yaml`): ogni classe .NET che un pattern di `governs` copre sta nel diagramma delle classi della decisione, ogni voce copre almeno una classe |
| `CI/Scripts/Adr/DecisionClasses.ps1` | Frontmatter `governs`, classi dei diagrammi delle classi e confronto con il codice, condivisi dalla verifica e dalla proposta delle classi delle decisioni |
| `CI/Scripts/Adr/Repair-DecisionClasses.ps1` | Classi delle decisioni proposte con il modello linguistico (`CLASSES_REPAIR_PROVIDER`) (`adr-classes-verify.yaml` in modalità `fix`): voci di `governs` e struttura nel codice di ogni decisione respinta o con classi candidate, stesure accettate dalla verifica, registro delle candidate, ramo di avanzamento e ripresa |
| `CI/Scripts/C4/DotNet10Code.ps1` | Lettura del codice .NET 10 condivisa dal lettore del modello C4 e dalla verifica delle classi delle decisioni: progetti con il loro tipo, codice senza commenti, tipi di primo livello con il nome completo |
| `CI/Scripts/C4/C4CodeModel.ps1` | Contratto del frammento del modello C4 generato, incluso dai lettori: file di progetto letti, container, componenti, relazioni, indirizzi di avvio e chiamati e il loro legame |
| `CI/Scripts/C4/Read-C4DotNet10Model.ps1` | Lettore .NET 10 (`c4-read-dotnet10.yaml`): applicazioni come container, progetti di produzione come componenti, regole di .NET 10; un progetto di un'altra versione ferma la lettura |
| `CI/Scripts/C4/Read-C4Angular18Model.ps1` | Lettore Angular 18 (`c4-read-angular18.yaml`): l'applicazione come container, cartelle di funzionalità e moduli di base come componenti; un workspace di un'altra versione ferma la lettura |
| `CI/Scripts/C4/Read-C4TerraformModel.ps1` | Lettore Terraform (`c4-read-terraform.yaml`): per ambiente l'allocazione (regioni, piani di calcolo, istanze dei container dei frammenti) e la rete (reti virtuali, subnet, private endpoint, Application Gateway, Front Door, peering, origini e backend), con gruppo di risorse e modulo di ogni elemento; una risorsa di hosting di un tipo che le regole non riconoscono ferma la lettura |
| `CI/Scripts/C4/TerraformCode.ps1` | Blocchi dei file Terraform e riferimenti delle loro espressioni seguiti per nome fino alle risorse, condivisi dai lettori dell'infrastruttura |
| `CI/Scripts/C4/TerraformValues.ps1` | Valori della dichiarazione Terraform di un ambiente: espressioni, funzioni, variabili, locals, moduli, override e remote state, con i valori sconosciuti |
| `CI/Scripts/C4/Write-C4ModelText.ps1` | Testo del modello C4 di tutto il sistema (`c4-describe.yaml`): stesure del modello linguistico (`C4_TEXT_PROVIDER`) corrette in modo deterministico o rimandate al modello, catalogo unico di persone e sistemi esterni controllato dal modello, revisione di tutto il modello con prove verificate nella configurazione di produzione, testo salvato un container alla volta e ripreso al rilancio, correzioni elencate |
| `CI/Scripts/C4/Export-C4CodeModel.ps1` | Parte del modello C4 generata dai frammenti di un repository sorgente e dal testo del sistema (`c4-generate.yaml`), con il contesto delle persone e dei sistemi esterni: errore sui file di progetto che nessun lettore legge, confronto in modalità `check` |
| `CI/Scripts/AzureBoards/Test-PullRequestSources.ps1`, `PullRequestSources.ps1` | Fonti di una PR (`azureBoards-sources-verify.yaml`): almeno un Task collegato, ADR del Task con le sezioni MADR della lingua in Markdown o HTML, padre requisito con i criteri di accettazione o Bug con i passi di riproduzione; ogni rilievo nomina il work item e la parte mancante |
| `CI/Scripts/AzureRepos/Publish-PullRequest.ps1` | Porta su un ramo le cartelle che la pipeline ha scritto e apre una PR Azure Repos (`azureRepos-pull-request.yaml`), con completamento automatico, cancellazione del ramo e bozza a scelta: riparte dai commit già sul ramo, nessuna PR senza differenze, una PR attiva si aggiorna, descrizione completata da un file |
| `CI/Scripts/Arc42/Publish-Arc42Wiki.ps1` | Pubblica un documento arc42 nella wiki di progetto (`publish-arc42-wiki.yaml`): una pagina per sezione, le decisioni sotto la sezione 9 con lo stato, le viste C4 come immagini C4-PlantUML, un commit solo che non tocca le altre pagine; con la cartella della bozza, le pagine sorelle in bozza di quelle che la bozza cambia |
| `CI/Scripts/Mermaid/Test-MermaidDiagrams.ps1` | Diagrammi Mermaid delle sezioni e delle decisioni (`mermaid-verify.yaml`): errore con sezione, file e riga |
| `CI/Scripts/Mermaid/Test-DiagramFlows.ps1` | Flussi coerenti con la struttura (`flows-verify.yaml`): partecipanti e chiamate dei diagrammi di sequenza contro il modello C4, per identificativo, flusso delle decisioni contro le classi della loro struttura |
| `CI/Scripts/Mermaid/DiagramFlows.ps1` | Controlli dei flussi condivisi da `Test-DiagramFlows.ps1` e `Repair-DiagramFlows.ps1`: ogni rilievo porta il file della sezione che lo contiene |
| `CI/Scripts/Mermaid/Repair-DiagramFlows.ps1` | Diagrammi riparati con il modello linguistico (`FLOWS_REPAIR_PROVIDER`) (`flows-verify.yaml` in modalità `fix` con `endpoint`): sezioni respinte dalla verifica dei flussi riscritte dal modello linguistico e accettate dalla stessa verifica, ramo di appoggio, ripresa di una riparazione interrotta, commit sul ramo della PR |
| `CI/Scripts/Mermaid/Sync-DiagramLabels.ps1` | Diagrammi allineati al modello C4 (`flows-verify.yaml` in modalità `fix`): alias e etichette dei partecipanti e nomi dei riquadri dal modello, migrazione dei partecipanti scritti per nome con il modello del ramo base, commit sul ramo della PR |
| `CI/Scripts/Mermaid/DiagramModel.ps1` | Elementi del modello C4 per identificativo del DSL, partecipanti e riquadri dei diagrammi di sequenza riconosciuti e riscritti con i nomi del modello |
| `CI/Scripts/Documentation/Test-Documentation.ps1` | Controlli comuni a ogni documento (`documentation-verify.yaml`): rimandi esistenti, soglie numeriche di leggibilità |
| `CI/Scripts/Documentation/Update-Documentation.ps1`, `DocumentationUpdate.ps1` | Aggiornamento della documentazione (`documentation-update.yaml`) con il modello linguistico (`DOCS_UPDATE_PROVIDER`): cambiamento dai commit dopo il punto di partenza registrato nel repository, esclusi quelli degli aggiornamenti precedenti; stesure giudicate dalle verifiche indicate, scartate solo per rilievi nuovi e rimandate con i motivi; versione nuova delle decisioni cambiate con la voce che nomina l'origine; work item per un aggiornamento respinto a ogni stesura; con il modello non disponibile nulla cambia e il punto di partenza resta |
| `CI/Scripts/Documentation/Write-DraftSources.ps1`, `Promote-Documentation.ps1`, `Sync-DocumentationDraft.ps1`, `DocumentationDraft.ps1` | Ramo di bozza del documento (`documentation-draft-sources.yaml`, `documentation-promote.yaml`, `documentation-draft-sync.yaml`): ramo letto, commit e albero git dei repository sorgente nel file delle sorgenti della bozza; promozione con una PR dal ramo di bozza quando ogni repository arriva nel ramo principale con lo stesso albero, con la variabile `documentationPromoted`; allineamento della bozza al ramo principale con una PR |
| `CI/Scripts/Documentation/Test-DocumentationStyle.ps1` | Giudizio dello stile di un documento (`documentation-style.yaml`) con il modello linguistico (`STYLE_JUDGE_PROVIDER`) che riceve la guida di stile del repository come istruzioni |
| `CI/Scripts/LanguageModel/LanguageModel.ps1` | Contratto del modello linguistico dei passi di documentazione: `New-LanguageModel` crea il client del fornitore scelto (`foundry`, il default, o `anthropic`), `Invoke-LanguageModel` restituisce la risposta letta secondo lo schema e i token usati. Ogni altro file della cartella è il modulo di un fornitore |
| `CI/Scripts/LanguageModel/Foundry.ps1` | Fornitore Foundry: chat completions Azure OpenAI con token Entra ID della Azure CLI, risposta in JSON schema stretto, livello di ragionamento, seme tolto se il deployment lo rifiuta |
| `CI/Scripts/LanguageModel/Anthropic.ps1` | Fornitore Anthropic: API Messages a consumo con la chiave `ANTHROPIC_API_KEY` (senza chiave il passo fallisce nominandola), risposta in `output_config.format` JSON schema, livello di ragionamento in `output_config.effort`, `max_tokens` (default 32000); un rifiuto o una risposta troncata sono errori |
| `CI/Scripts/Common/ModelRetry.ps1` | Attesa fra i tentativi di una richiesta al modello linguistico rifiutata per un errore transitorio (429, 5xx): `Retry-After` o attesa che raddoppia, fino a dieci tentativi |
| `CI/Scripts/Common/VerificationGate.ps1` | Parte comune degli script di verifica della documentazione: modalità `off`/`warn`/`enforce`, rilievi `##vso[task.logissue]`, codice di uscita |
| `CI/Scripts/Common/MarkdownText.ps1` | Lettura delle sezioni Markdown di un documento (blocchi, parti, marcatori di vista, diagrammi) e misure di leggibilità (frasi, parole, indice Gulpease) |
| `CI/Scripts/C4/Structurizr.ps1` | Scarica la Structurizr CLI (versione fissata, SHA-256 verificato), sceglie un Java 17 o successivo ed esporta il modello C4 in JSON e le viste in C4-PlantUML |
| `CI/Scripts/Arc42/Arc42Document.ps1` | Documento unico in PDF e Word dalle pagine della wiki (`documentFormats` di `publish-arc42-wiki.yaml`): sezioni numerate con indice, decisioni sotto la sezione 9, viste C4 e diagrammi Mermaid come immagini, link interni come rimandi e link ad Azure DevOps come testo |
| `CI/Scripts/Pandoc/Pandoc.ps1` | Scarica pandoc (versione fissata, SHA-256 verificato, `PANDOC_PATH` per uno gia' presente) e converte un Markdown con la data della fonte (`SOURCE_DATE_EPOCH`) |
| `CI/Scripts/Browser/Browser.ps1`, `CI/Scripts/Browser/Renderer/` | Installa con `npm ci` mermaid-cli, puppeteer e Chrome headless fissati dal lockfile; disegna i diagrammi Mermaid in PNG e stampa un HTML in PDF con la data della fonte |
| `CI/Scripts/Arc42/PlantUml.ps1` | Scarica PlantUML (versione fissata, SHA-256 verificato) e disegna i diagrammi in PNG con una sola JVM, layout smetana |
| `CI/Scripts/Common/DocumentLanguage.ps1` | Carica da `CI/Scripts/Common/Languages/<lingua>.psd1` le convenzioni della lingua del documento (`DOCUMENT_LANGUAGE`, default `IT`); una lingua senza file fa fallire lo script nominandola |
| `CI/Scripts/Mermaid/Mermaid.ps1`, `CI/Scripts/Mermaid/Parser/` | Installa con `npm ci` il parser Mermaid fissato dal lockfile e ricava, per ogni diagramma, il tipo (con partecipanti e chiamate di un diagramma di sequenza, classi di un diagramma delle classi) o l'errore con la riga |
| `CI/Scripts/ScenarioCoverage/ScenarioCoverage.cs` | File-based app .NET 10: verifica che ogni scenario dei `.feature` sia stato eseguito e superato, leggendo i Cucumber Messages del runner BDD |

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
