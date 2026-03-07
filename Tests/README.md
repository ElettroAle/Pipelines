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
│   └── check-parameters.py     # Verifica contratti parametri tra template
├── scripts/                    # Livello 2: unit test PowerShell (Pester)
│   ├── Set-Versioning.Tests.ps1
│   └── Verify-SemVer.Tests.ps1
└── fixtures/
    ├── valid-commits.txt       # Messaggi commit validi (Conventional Commits)
    └── invalid-commits.txt     # Messaggi commit non validi
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
| Sanitizzazione PROJECT_NAME | Punti→trattini, lowercase |

Ogni test crea un repository git reale con un **bare repo locale come fake remote** (`git init --bare`), così `git push origin <tag>` funziona senza rete.

#### `Verify-SemVer.Tests.ps1` (3 suite, ~15 test)

| Suite | Scenario testato |
|---|---|
| Branch protetti (main, staging) | Commit validi/invalidi; merge commit (usa `--no-merges`) |
| Branch non protetti | Check skippato su `dev`, `feature/x`, ecc. |
| `ADDITIONAL_TAG_BRANCHES` | Branch extra protetti via env var |

---

## GitHub Actions

I workflow si attivano automaticamente su ogni PR verso `main` e su ogni push.

| Workflow | File | Trigger |
|---|---|---|
| Static Analysis | `.github/workflows/test-static.yml` | modifiche in `V3/**` o `Tests/static/**` |
| Script Unit Tests | `.github/workflows/test-scripts.yml` | modifiche in `V3/CI/Scripts/**` o `Tests/scripts/**` |

I risultati Pester vengono pubblicati come report JUnit nella tab "Checks" di GitHub.

---

## Livello 3 — Template Expansion Preview (richiede Azure DevOps)

> Da configurare separatamente in Azure DevOps.

Usa `az pipelines run --preview` per espandere i template fully-resolved senza eseguirli.
I file di test pipeline ADO sono in `Tests/preview/` (da creare quando si configura ADO).

Questo livello cattura errori che la static analysis non può vedere:
- Variabili ADO non risolte a runtime
- Condizioni `${{ if }}` con parametri mancanti
- Step template con parametri obbligatori non soddisfatti dalla pipeline host
