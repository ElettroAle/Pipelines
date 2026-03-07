# Azure DevOps Pipeline Templates

Raccolta di template YAML riusabili per Azure DevOps. L'obiettivo è ridurre la
duplicazione nei file di pipeline dei repository applicativi, esponendo moduli
componibili e utility di alto livello pronte all'uso.

---

## Struttura del repository

```
Pipelines/
├── V1/   ← Prima generazione (legacy, non modificare)
├── V2/   ← Seconda generazione (legacy, non modificare)
└── V3/   ← Versione corrente
    ├── CI/
    │   ├── Scripts/                    Powershell condivisi (SemVer, versioning)
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

---

## Test Suite

La libreria include una suite di test a 2 livelli che gira su GitHub Actions senza richiedere Azure DevOps.

| Livello | Tool | Cosa verifica |
|---|---|---|
| 1 — Static Analysis | Python (`yamllint`, script custom) | Sintassi YAML, riferimenti a template esistenti, contratti parametri |
| 2 — Script Unit Tests | PowerShell Pester 5 | Logica di `Set-Versioning.ps1` e `Verify-SemVer.ps1` |

### Esecuzione locale

```bash
# Livello 1 — da root del repo
pip install -r Tests/static/requirements.txt
yamllint -c Tests/static/.yamllint.yaml V3/
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
| `test-static.yml` | `V3/**`, `Tests/static/**` |
| `test-scripts.yml` | `V3/CI/Scripts/**`, `Tests/scripts/**` |

Documentazione completa: [`Tests/README.md`](Tests/README.md)

---

## Script condivisi (V3)

| Script | Scopo |
|---|---|
| `CI/Scripts/Verify-SemVer.ps1` | Verifica che l'ultimo commit rispetti Conventional Commits verso branch protetti |
| `CI/Scripts/Set-Versioning.ps1` | Calcola la versione SemVer da commit history, crea il tag Git e setta le variabili ADO (`currentTag`, `gitHash`, `computedArtifactName`) |

---

## Variable Groups richiesti (V3 GitFlow)

| Group | Usato da | Variabili attese |
|---|---|---|
| `common-quality` | quality-* | (libero — configurazione comune quality) |
| `development` | publish-* (branch `dev`) | `targetEnvironment` |
| `staging` | publish-* (branch `staging`) | `targetEnvironment` |
| `production` | publish-* (branch `main`) | `targetEnvironment` |
| `terraform-common` | IAC/terraform-* | `azureServiceConnection` |
