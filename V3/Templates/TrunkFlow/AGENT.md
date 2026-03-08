# Istruzioni per Coding Agent — Integrazione Pipeline V3 TrunkFlow

Questo documento guida un coding agent nell'integrare le pipeline
CI/CD V3 TrunkFlow in un repository applicativo .NET.

Il coding agent **scrive i file nel repo applicativo** usando `extends:`
per referenziare i template di questo repo. Non copia file da qui.

---

## Quando usare TrunkFlow

TrunkFlow è il flusso corretto quando:
- Il team lavora su un unico branch (`main`)
- I rilasci sono manuali e richiedono approvazione esplicita
- Il versioning SemVer è governato dai Conventional Commits
- Si vuole separare nettamente il CI (pre-release) dal CD (promozione + tagging)

---

## Struttura da creare nel repo applicativo

```
.azure/
└── pipelines/
    ├── ci.yaml    ← raccordo CI
    └── cd.yaml    ← raccordo CD
```

---

## File 1: ci.yaml (nel repo applicativo)

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
      name: <OrgName>/<PipelinesRepoName>   # es. MyOrg/Pipelines
      ref: refs/heads/main

extends:
  template: V3/CI/TrunkFlow/publish-dotNet.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'             # es. MyApp.BackEnd
```

---

## File 2: cd.yaml (nel repo applicativo)

### Pattern A — Deploy su Azure App Service (caso standard)

Estendere l'entry point specifico: basta passare 4 parametri.

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
  template: V3/CD/TrunkFlow/promote-dotNet-appService.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'
    azureServiceConnection: '<ServiceConnectionName>'
    stagingWebAppName: '<app-name-staging>'
    prodWebAppName: '<app-name-prod>'

    # Opzionali — solo se i nomi ADO environment differiscono dal default:
    # stagingEnvironment: 'Staging'
    # prodEnvironment: 'Production'
```

### Pattern B — Tecnologia di deploy custom (iniettata dall'esterno)

Estendere direttamente l'orchestratore agnostico `Modules/promote.yaml`
e iniettare `stagingDeploySteps` + `prodDeploySteps` con la tecnologia scelta.

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
  template: V3/CD/TrunkFlow/Modules/promote.yaml@infrastructure
  parameters:
    projectName: '<ProjectName>'

    buildSteps:
      - template: V3/CI/Common/Steps/dotnet-build.yaml@infrastructure

    publishSteps:
      - template: V3/CI/Common/Steps/dotnet-publish.yaml@infrastructure
        parameters:
          projectName: '<ProjectName>'
          targetEnvironment: 'Staging'
          versionArgs: >-
            /p:Version=$(currentTag)
            /p:AssemblyVersion=$(currentTag)
            /p:FileVersion=$(currentTag)
            /p:InformationalVersion="$(currentTag)-$(gitHash)"

    # Staging: il binario è appena prodotto — si legge da ArtifactStagingDirectory
    stagingDeploySteps:
      - task: <MyDeployTask>@1
        displayName: 'Deploy su <piattaforma> — Staging'
        inputs:
          # parametri specifici della tecnologia scelta
          package: '$(Build.ArtifactStagingDirectory)/publish/**/*.zip'

    # Production: il binario è scaricato dallo stage precedente — si legge da Pipeline.Workspace/staging
    prodDeploySteps:
      - task: <MyDeployTask>@1
        displayName: 'Deploy su <piattaforma> — Production'
        inputs:
          # parametri specifici della tecnologia scelta
          package: '$(Pipeline.Workspace)/staging/**/*.zip'
```

> Se la tecnologia è App Service, usare il Pattern A che è più conciso.
> Per step template riusabili del deploy (consigliato per uniformità),
> aggiungerli in `V3/CD/Common/Steps/` seguendo il modello di
> `deploy-azure-appService.yaml`.

---

## Parametri obbligatori

| Parametro               | Dove                         | Valore di esempio              |
|-------------------------|------------------------------|--------------------------------|
| `<OrgName>`             | `resources.repositories`     | `MyOrg`                        |
| `<PipelinesRepoName>`   | `resources.repositories`     | `Pipelines`                    |
| `<ProjectName>`         | `extends.parameters`         | `MyApp.BackEnd`                |
| `<ServiceConnectionName>` | `extends.parameters` (A)   | `sc-arm-myapp`                 |
| `<app-name-staging>`    | `extends.parameters` (A)     | `app-myapp-be-staging`         |
| `<app-name-prod>`       | `extends.parameters` (A)     | `app-myapp-be-prod`            |

**Regola `<ProjectName>`**: deve corrispondere al nome della cartella
che contiene il `.csproj` e al nome del `.csproj` stesso.
Esempio: `MyApp.BackEnd` → `MyApp.BackEnd/MyApp.BackEnd.csproj`

---

## Prerequisiti Azure DevOps

- [ ] Repository resource `infrastructure` punta al repo Pipelines
- [ ] ADO Environment `Development` (usato dalla CI publish stage)
- [ ] ADO Environment `Staging` con approval obbligatoria
- [ ] ADO Environment `Production` con approval obbligatoria
- [ ] Service connection ARM con permessi Contributor sull'App Service
- [ ] Variable group `staging` nel progetto ADO (richiesto dall'entry point CD Pattern A)

---

## Conventional Commits — regola su `main`

| Prefisso  | Version bump              |
|-----------|---------------------------|
| `fix:`    | patch (1.2.3 → 1.2.4)    |
| `feat:`   | minor (1.2.3 → 1.3.0)    |
| `feat!:`  | major (1.2.3 → 2.0.0)    |

Il CD fallisce esplicitamente se il commit su `main` non rispetta questo formato.

---

## Architettura di riferimento

```
Repo Applicativo                   Repo Pipelines (infrastructure)
────────────────                   ────────────────────────────────
.azure/pipelines/
  ci.yaml                          V3/CI/TrunkFlow/
    extends: ──────────────────►     publish-dotNet.yaml
                                       └─ Modules/publish.yaml
                                             └─ CI/Common/Steps/dotnet-*.yaml

  cd.yaml (Pattern A)              V3/CD/TrunkFlow/
    extends: ──────────────────►     promote-dotNet-appService.yaml
                                       └─ Modules/promote.yaml        ← agnostico
                                             └─ CD/Common/Steps/
                                                   deploy-azure-appService.yaml

  cd.yaml (Pattern B)
    extends: ──────────────────►   V3/CD/TrunkFlow/Modules/promote.yaml
      stagingDeploySteps:            (orchestratore agnostico)
        - <MyDeployTask>
      prodDeploySteps:
        - <MyDeployTask>
```

---

## Cosa NON fare

- **Non copiare** file da questo repo: usare sempre `extends:`
- **Non aggiungere task inline** nel file di raccordo: tutto passa dai parametri
- **Non modificare** il path dell'artifact: `$(Build.ArtifactStagingDirectory)/publish` (staging) e `$(Pipeline.Workspace)/staging` (prod) sono contratti del modulo
- **Non aggiungere** `trigger:` al `cd.yaml`: il promote è sempre manuale
