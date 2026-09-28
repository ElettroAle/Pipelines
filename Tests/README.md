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
│   └── ScenarioCoverage.Tests.ps1
├── fixtures/
│   ├── valid-commits.txt       # Messaggi commit validi — usati da Verify-SemVer.Tests
│   ├── invalid-commits.txt     # Messaggi commit non validi — usati da Verify-SemVer.Tests
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
yamllint -c Tests/static/.yamllint.yaml V3/

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
| `REQUIRE_TAG=false` | Versione `{lastTag}.{BuildId}`, fallback a `0.0.0.{BuildId}` |
| `REQUIRE_TAG=true, incremento` | `fix:`→patch, `feat:`→minor, `feat!:`→major; nessun tag→parte da 0.0.0 |
| `REQUIRE_TAG=true, HEAD=tag` | Nessun incremento se il tree è identico all'ultimo tag |
| Scope e breaking | `fix(scope):`→patch, `feat(scope):`→minor, `feat(scope)!:`/`fix!:`/`BREAKING CHANGE:`→major, `chore(scope):` ignorato |
| Incremento più alto | Tra i commit dall'ultimo tag vince il più alto: `feat:` poi `fix:` → minor, `feat!:` poi `fix:` → major |
| Prefisso ADO | `Merged PR <id>: <titolo convenzionale>` (messaggio di default di Azure DevOps, anche in squash) riconosciuto come il titolo senza prefisso |
| Sanitizzazione PROJECT_NAME | Punti→trattini, lowercase |

Ogni test crea un repository git reale con un **bare repo locale come fake remote** (`git init --bare`), così `git push origin <tag>` funziona senza rete.

#### `Verify-SemVer.Tests.ps1` (3 suite, ~15 test)

| Suite | Scenario testato |
|---|---|
| Branch protetti (main, staging) | Commit validi/invalidi; merge commit (usa `--no-merges`) |
| Branch non protetti | Check skippato su `dev`, `feature/x`, ecc. |
| `ADDITIONAL_TAG_BRANCHES` | Branch extra protetti via env var |

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
| Static Analysis | `.github/workflows/test-static.yml` | modifiche in `V3/**` o `Tests/static/**` |
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
