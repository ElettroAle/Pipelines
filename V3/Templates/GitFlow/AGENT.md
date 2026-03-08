# Istruzioni per Coding Agent — Integrazione Pipeline V3 GitFlow

Questo documento guida un coding agent nell'integrare le pipeline
CI/CD V3 GitFlow in un repository applicativo .NET.

Il coding agent **scrive i file nel repo applicativo** usando `extends:`
per referenziare i template di questo repo. Non copia file da qui.

---

## Quando usare GitFlow

GitFlow è il flusso corretto quando:
- Il team lavora su branch multipli (`dev` → `staging` → `main`)
- Ogni branch corrisponde a un ambiente di deployment distinto
- Il versioning SemVer è governato dai tag Git e dai Conventional Commits
- Si vuole che la PR validation (quality gate) blocchi merge non conformi
- Il deploy avviene automaticamente dopo la CI sul branch di riferimento

---

## Struttura da creare nel repo applicativo

```
.azure/
└── pipelines/
    ├── ci.yaml          ← CI publish (trigger: dev, staging, main)
    ├── quality.yaml     ← Quality gate (trigger: PR verso dev/staging/main)
    ├── cd-dev.yaml      ← Deploy su Development (trigger: CI su dev)
    ├── cd-staging.yaml  ← Deploy su Staging (trigger: CI su staging)
    └── cd-prod.yaml     ← Deploy su Production (trigger: CI su main)
```

> I file CD sono separati per ambiente perché i parametri (webAppName,
> targetEnvironment) sono fissi a compile-time in ADO e non possono
> variare branch-conditionally in un unico file `extends:`.

---

## File 1: ci.yaml — CI Publish

```yaml
trigger:
  branches:
    include:
      - dev
      - staging
      - main
pr: none

resources:
  repositories:
    - repository: infrastructure
      type: git
      name: <OrgName>/<PipelinesRepoName>   # es. MyOrg/Pipelines
      ref: refs/heads/main

extends:
  template: V3/CI/GitFlow/publish-dotNet.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'             # es. MyApp.BackEnd
```

**Comportamento per branch:**

| Branch | Variable group | requireTag | Effetto |
|--------|----------------|------------|---------|
| `dev` | `development` | false | Build + artifact senza tag SemVer obbligatorio |
| `staging` | `staging` | true | Richiede tag SemVer sul commit |
| `main` | `production` | true | Richiede tag SemVer sul commit |
| feature/* | `development` | true | Usare solo per quality, non per publish |

---

## File 2: quality.yaml — Quality Gate

Obbligatorio per bloccare PR non conformi ai Conventional Commits
e con test falliti o coverage insufficiente.

```yaml
trigger: none
pr:
  branches:
    include:
      - dev
      - staging
      - main

resources:
  repositories:
    - repository: infrastructure
      type: git
      name: <OrgName>/<PipelinesRepoName>
      ref: refs/heads/main

extends:
  template: V3/CI/GitFlow/quality-dotNet.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'
```

---

## File 3: cd-dev.yaml — Deploy su Development

```yaml
trigger: none
pr: none

resources:
  repositories:
    - repository: infrastructure
      type: git
      name: <OrgName>/<PipelinesRepoName>
      ref: refs/heads/main
  pipelines:
    - pipeline: ci_be                     # alias referenziato dal template CD
      source: '<NomePipelineCI>'          # nome della pipeline CI in ADO
      branch: dev
      trigger:
        branches:
          include:
            - dev

extends:
  template: V3/CD/Agnostic/deploy-azure-appService.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'
    azureServiceConnection: '<ServiceConnectionName>'
    targetEnvironment: 'Development'
    webAppName: '<app-name-dev>'
```

---

## File 4: cd-staging.yaml — Deploy su Staging

```yaml
trigger: none
pr: none

resources:
  repositories:
    - repository: infrastructure
      type: git
      name: <OrgName>/<PipelinesRepoName>
      ref: refs/heads/main
  pipelines:
    - pipeline: ci_be
      source: '<NomePipelineCI>'
      branch: staging
      trigger:
        branches:
          include:
            - staging

extends:
  template: V3/CD/Agnostic/deploy-azure-appService.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'
    azureServiceConnection: '<ServiceConnectionName>'
    targetEnvironment: 'Staging'
    webAppName: '<app-name-staging>'
```

---

## File 5: cd-prod.yaml — Deploy su Production

```yaml
trigger: none
pr: none

resources:
  repositories:
    - repository: infrastructure
      type: git
      name: <OrgName>/<PipelinesRepoName>
      ref: refs/heads/main
  pipelines:
    - pipeline: ci_be
      source: '<NomePipelineCI>'
      branch: main
      trigger:
        branches:
          include:
            - main

extends:
  template: V3/CD/Agnostic/deploy-azure-appService.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'
    azureServiceConnection: '<ServiceConnectionName>'
    targetEnvironment: 'Production'
    webAppName: '<app-name-prod>'
```

---

## Parametri da sostituire

| Placeholder | Dove | Valore di esempio |
|---|---|---|
| `<OrgName>` | `resources.repositories` | `MyOrg` |
| `<PipelinesRepoName>` | `resources.repositories` | `Pipelines` |
| `<ProjectName>` | `extends.parameters` | `MyApp.BackEnd` |
| `<NomePipelineCI>` | `resources.pipelines.source` | `MyApp.BackEnd - CI` |
| `<ServiceConnectionName>` | `extends.parameters` | `sc-arm-myapp` |
| `<app-name-dev>` | `extends.parameters` | `app-myapp-be-dev` |
| `<app-name-staging>` | `extends.parameters` | `app-myapp-be-staging` |
| `<app-name-prod>` | `extends.parameters` | `app-myapp-be-prod` |

**Regola `<ProjectName>`**: deve corrispondere al nome della cartella
che contiene il `.csproj` e al nome del `.csproj` stesso.
Esempio: `MyApp.BackEnd` → `MyApp.BackEnd/MyApp.BackEnd.csproj`

**Regola `<NomePipelineCI>`**: è il nome visualizzato della pipeline CI
in Azure DevOps (Settings → Pipelines), non il path del file yaml.

---

## Prerequisiti Azure DevOps

- [ ] Repository resource `infrastructure` punta al repo Pipelines
- [ ] ADO Environment `Development` (usato dalla CI publish e dal cd-dev)
- [ ] ADO Environment `Staging` con approval obbligatoria (cd-staging)
- [ ] ADO Environment `Production` con approval obbligatoria (cd-prod)
- [ ] Service connection ARM con permessi Contributor su tutti gli App Service
- [ ] Variable group `development` con `targetEnvironment=Development`
- [ ] Variable group `staging` con `targetEnvironment=Staging`
- [ ] Variable group `production` con `targetEnvironment=Production`
- [ ] Branch policy su `dev`, `staging`, `main`: richiede la quality pipeline come PR check

---

## Conventional Commits — regola sulle PR

Il quality gate valida il titolo della PR. Solo i seguenti prefissi sono accettati:

| Prefisso | Version bump |
|---|---|
| `fix:` | patch (1.2.3 → 1.2.4) |
| `feat:` | minor (1.2.3 → 1.3.0) |
| `feat!:` | major (1.2.3 → 2.0.0) |

La CI fallisce su `staging` e `main` se il commit non ha un tag SemVer corrispondente.

---

## Architettura di riferimento

```
Repo Applicativo                   Repo Pipelines (infrastructure)
────────────────                   ────────────────────────────────
.azure/pipelines/
  ci.yaml (dev/staging/main)       V3/CI/GitFlow/
    extends: ──────────────────►     publish-dotNet.yaml
                                       └─ Modules/publish.yaml
                                             ├─ Set-Versioning.ps1
                                             └─ CI/Common/Steps/dotnet-*.yaml

  quality.yaml (PR trigger)        V3/CI/GitFlow/
    extends: ──────────────────►     quality-dotNet.yaml
                                       └─ Modules/quality.yaml

  cd-dev.yaml   ┐
  cd-staging.yaml ├──────────────► V3/CD/Agnostic/
  cd-prod.yaml  ┘                    deploy-azure-appService.yaml
                                       └─ CD/Common/Steps/
                                             appService-deploy.yaml
```

**Flusso per branch `staging` (esempio):**
```
Push su staging
  → CI (ci.yaml): Set-Versioning (requireTag=true) → Build → Publish artifact
  → CD (cd-staging.yaml): Download artifact latestFromBranch → Deploy su Staging
```

---

## Cosa NON fare

- **Non copiare** file da questo repo: usare sempre `extends:`
- **Non aggiungere task inline** nel file di raccordo: tutto passa dai parametri
- **Non usare un unico cd.yaml** con branch-conditional logic sugli `extends:` parameters: i parametri template sono YAML-time, non runtime
- **Non omettere** la quality pipeline: senza il PR check i Conventional Commits non vengono applicati
- **Non modificare** il path dell'artifact: `$(Build.ArtifactStagingDirectory)/publish` è il contratto della CI
- **Non aggiungere** `trigger:` ai file cd-*.yaml: il trigger viene gestito tramite `resources.pipelines`
