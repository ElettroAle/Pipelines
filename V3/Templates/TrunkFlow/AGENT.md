# Istruzioni per Coding Agent — Integrazione Pipeline V3 TrunkFlow

Questo documento guida un coding agent nell'integrare le pipeline
CI/CD V3 TrunkFlow in un repository applicativo .NET con deploy su Azure App Service.

---

## Quando usare TrunkFlow

TrunkFlow è il flusso corretto quando:
- Il team lavora su un unico branch (`main`)
- I rilasci sono manuali e richiedono approvazione esplicita
- Il versioning SemVer è governato dai Conventional Commits
- Si vuole separare nettamente il CI (pre-release) dal CD (promozione con tagging)

---

## Checklist di integrazione

### 1. Struttura nel repo applicativo

Creare due file nella cartella `.azure/pipelines/` (o equivalente):

```
.azure/
└── pipelines/
    ├── ci.yaml    ← raccordo CI  (copia e adatta ci-dotnet.yaml)
    └── cd.yaml    ← raccordo CD  (copia e adatta cd-dotnet-appService.yaml)
```

### 2. Parametri da sostituire

Nei file copiati, sostituire i placeholder:

| Placeholder                 | Valore da impostare                                        |
|-----------------------------|------------------------------------------------------------|
| `<OrgName>`                 | Nome dell'organizzazione ADO (es. `MyOrg`)                 |
| `<PipelinesRepoName>`       | Nome del repo Pipelines (es. `Pipelines`)                  |
| `<ProjectName>`             | Nome del progetto/soluzione .NET (es. `MyApp.BackEnd`)     |
| `<ServiceConnectionName>`   | Nome service connection ARM in ADO (es. `sc-arm-myapp`)    |
| `<app-name-staging>`        | Nome App Service di staging (es. `app-myapp-be-staging`)   |
| `<app-name-prod>`           | Nome App Service di production (es. `app-myapp-be-prod`)   |

**Regola**: `<ProjectName>` deve corrispondere esattamente al nome della cartella
che contiene il file `.csproj` e al nome del file `.csproj` stesso.
Esempio: `projectName: 'MyApp.BackEnd'` → `MyApp.BackEnd/MyApp.BackEnd.csproj`

### 3. Prerequisiti Azure DevOps da verificare

Prima di registrare le pipeline in ADO, verificare che esistano:

- [ ] **Repository resource** `infrastructure` → punta al repo Pipelines
- [ ] **ADO Environment** `Development` (con o senza approval — usato dalla CI)
- [ ] **ADO Environment** `Staging` con approval obbligatoria configurata
- [ ] **ADO Environment** `Production` con approval obbligatoria configurata
- [ ] **Service connection ARM** con nome corrispondente a `azureServiceConnection`
- [ ] **Variable group** `staging` nel progetto ADO (richiesto dall'entry point CD)

### 4. Registrare le pipeline in ADO

1. Creare una nuova pipeline puntando a `ci.yaml` → rinominarla `[ProjectName] CI`
2. Creare una nuova pipeline puntando a `cd.yaml` → rinominarla `[ProjectName] CD`
3. Verificare che la CI si triggeri automaticamente su push a `main`
4. Verificare che la CD sia ad avvio solo manuale

---

## Struttura dei file di raccordo (reference)

### ci.yaml — schema minimo

```yaml
trigger:
  branches:
    include:
      - main
pr: none

resources:
  repositories:
    - repository: infrastructure
      type: git
      name: <OrgName>/<PipelinesRepoName>
      ref: refs/heads/main

extends:
  template: V3/CI/TrunkFlow/publish-dotNet.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'
```

### cd.yaml — schema minimo

```yaml
trigger: none
pr: none

resources:
  repositories:
    - repository: infrastructure
      type: git
      name: <OrgName>/<PipelinesRepoName>
      ref: refs/heads/main

extends:
  template: V3/CD/TrunkFlow/promote-azure-appService.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'
    azureServiceConnection: '<ServiceConnectionName>'
    stagingWebAppName: '<app-name-staging>'
    prodWebAppName: '<app-name-prod>'
```

---

## Conventional Commits — regola da seguire su `main`

Ogni commit su `main` (diretto o via PR) **deve** iniziare con uno di:

| Prefisso   | Effetto sul version bump |
|------------|--------------------------|
| `fix:`     | patch (1.2.3 → 1.2.4)   |
| `feat:`    | minor (1.2.3 → 1.3.0)   |
| `feat!:`   | major (1.2.3 → 2.0.0)   |

Il CD fallisce con errore esplicito se il commit su `main` non rispetta questo formato.

---

## Nota sulla tecnologia di deploy

L'entry point `promote-azure-appService.yaml` gestisce il deploy su App Service.
Se in futuro è necessario un target diverso (IIS su VM, Container Apps, ecc.),
**non modificare** `Modules/promote.yaml`: creare un nuovo entry point che inietti
step template diversi tramite `stagingDeploySteps` / `prodDeploySteps`.

Questo è lo stesso pattern usato per `buildSteps` / `publishSteps` nella CI.

---

## Cosa NON fare

- **Non aggiungere task inline** nei file di raccordo: tutto deve passare
  dall'entry point del repo Pipelines
- **Non modificare** il path dell'artifact staging `$(Build.ArtifactStagingDirectory)/publish`
- **Non aggiungere** `trigger:` al file `cd.yaml`: il promote è sempre manuale
- **Non creare** variable group `staging` nel repo applicativo: deve esistere
  nel progetto ADO come variable group condiviso
