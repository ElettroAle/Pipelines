# Pipeline V3

Libreria di template Azure DevOps YAML per CI e CD, progettata per essere **riusabile**, **manutenibile** e **scalabile** su più workflow Git e stack tecnologici.

---

## Struttura

```
V3/
├── CI/
│   ├── Common/                 # Orchestratori e step template condivisi tra tutti i flussi
│   │   ├── Steps/              # Step atomici (un solo punto di manutenzione per ogni operazione)
│   │   │   ├── dotnet-build.yaml
│   │   │   ├── dotnet-publish.yaml
│   │   │   ├── dotnet-quality.yaml
│   │   │   ├── angular-build.yaml
│   │   │   ├── angular-publish.yaml
│   │   │   └── angular-quality.yaml
│   │   ├── publish.yaml        # Orchestratore Build+Publish (agnostico)
│   │   └── quality.yaml        # Orchestratore Quality gate (agnostico)
│   │
│   ├── Agnostic/               # Entry point senza governance Git (no SemVer, no tagging)
│   │   ├── publish-dotNet.yaml
│   │   ├── publish-angular.yaml
│   │   ├── quality-dotNet.yaml
│   │   └── quality-angular.yaml
│   │
│   ├── GitFlow/                # Entry point con governance GitFlow
│   │   ├── Modules/            # Orchestratori specifici GitFlow
│   │   │   ├── publish.yaml    # Aggiunge Set-Versioning con requireTag da branch e release notes
│   │   │   └── quality.yaml    # Aggiunge validazione PR title (Conventional Commits, git-cliff)
│   │   ├── publish-dotNet.yaml
│   │   ├── publish-angular.yaml
│   │   ├── quality-dotNet.yaml
│   │   └── quality-angular.yaml
│   │
│   ├── TrunkFlow/              # Entry point con governance TrunkFlow
│   │   ├── Modules/
│   │   │   └── publish.yaml    # Aggiunge Set-Versioning con REQUIRE_TAG=false fisso
│   │   └── publish-dotNet.yaml
│   │
│   └── Scripts/
│       ├── cliff.toml          # Regole Conventional Commits condivise
│       ├── GitCliff.ps1
│       ├── New-ReleaseNotes.ps1
│       ├── Set-Versioning.ps1
│       └── Verify-SemVer.ps1
│
└── CD/
    ├── Common/
    │   └── Steps/              # Step atomici CD (tecnologia di deploy centralizzata)
    │       ├── appService-deploy.yaml       # AzureWebApp@1 (Windows, Zip Deploy)
    │       └── staticWebApp-deploy.yaml     # AzureStaticWebApp@0 (SPA pre-buildata)
    │
    ├── Agnostic/               # Entry point deploy senza governance Git
    │   ├── deploy-azure-appService.yaml     # .NET → App Service
    │   └── deploy-angular-staticWebApp.yaml # Angular → Static Web Apps
    │
    └── TrunkFlow/              # Entry point promote con governance TrunkFlow
        ├── Modules/
        │   └── promote.yaml    # Orchestratore agnostico: versioning → build → deploy (inject)
        └── promote-dotNet-appService.yaml   # .NET → App Service (inietta tutti gli step)
```

---

## Principio di Riuso

Ogni operazione tecnica è definita **una sola volta** e referenziata da tutti i livelli superiori.

```
Entry point (Agnostic / GitFlow / TrunkFlow)
    └── Orchestratore (Common / GitFlow/Modules / TrunkFlow/Modules)
            └── Step template (CI/Common/Steps/ o CD/Common/Steps/)   ← definito una sola volta
```

- Modificare il comportamento di **build** .NET → toccare un solo file: `CI/Common/Steps/dotnet-build.yaml`.
- Modificare il comportamento di **deploy** su App Service → toccare un solo file: `CD/Common/Steps/appService-deploy.yaml`.

---

## Flussi Supportati

### Agnostic
Nessuna governance Git. Usato per ambienti senza SemVer o tagging.

| Template | Descrizione |
|---|---|
| `CI/Agnostic/publish-dotNet.yaml` | Build + Publish .NET, artifact nominato `{progetto}-{env}` |
| `CI/Agnostic/publish-angular.yaml` | Build + Publish Angular, artifact nominato `{progetto}-{env}` |
| `CI/Agnostic/quality-dotNet.yaml` | Quality gate .NET (Gitleaks + Test + Coverage) |
| `CI/Agnostic/quality-angular.yaml` | Quality gate Angular (Gitleaks + Build check) |
| `CD/Agnostic/deploy-azure-appService.yaml` | Download artifact CI + deploy su Azure App Service |
| `CD/Agnostic/deploy-angular-staticWebApp.yaml` | Download artifact CI + deploy su Azure Static Web Apps |

### GitFlow
Branch-conditional: `dev` → `staging` → `main`. Set-Versioning con tagging Git.

| Template | Descrizione |
|---|---|
| `CI/GitFlow/publish-dotNet.yaml` | CI .NET con SemVer embedded e tagging Git |
| `CI/GitFlow/publish-angular.yaml` | CI Angular con SemVer e tagging Git |
| `CI/GitFlow/quality-dotNet.yaml` | Quality .NET + validazione PR title |
| `CI/GitFlow/quality-angular.yaml` | Quality Angular + validazione PR title |

### TrunkFlow
Tutto su `main`. La CI produce artifact pre-release, la CD promote taglia il tag SemVer.

| Template | Descrizione |
|---|---|
| `CI/TrunkFlow/publish-dotNet.yaml` | CI .NET con versione pre-release (no tag Git) |
| `CD/TrunkFlow/promote-dotNet-appService.yaml` | Promote .NET → App Service: Verify-SemVer → versioning → rebuild → deploy staging → deploy prod |

---

## Step Template — Parametri Chiave

### `CI/Common/Steps/dotnet-build.yaml`
| Parametro | Default | Descrizione |
|---|---|---|
| `dotnetVersion` | `$(dotnetVersion)` | Versione SDK .NET |
| `publishProject` | `$(publishProject)` | Path del .csproj |
| `buildConfiguration` | `$(buildConfiguration)` | Configurazione build |

### `CI/Common/Steps/dotnet-publish.yaml`
| Parametro | Default | Descrizione |
|---|---|---|
| `projectName` | *(obbligatorio)* | Nome repo (per FileTransform) |
| `targetEnvironment` | `$(targetEnvironment)` | Ambiente target |
| `versionArgs` | `''` | Argomenti `/p:Version=…` (vuoto = nessun versionamento embedded) |
| `outputDirectory` | `$(outputDirectory)` | Path output artifact |

> **Nota:** `versionArgs` è il parametro che distingue la pipeline agnostica (vuoto) da GitFlow/TrunkFlow (contiene `/p:Version=$(currentTag) ...`).

### `CI/Common/Steps/angular-build.yaml`
| Parametro | Default | Descrizione |
|---|---|---|
| `nodeVersion` | `$(nodeVersion)` | Versione Node.js |
| `workingDirectory` | `$(Build.SourcesDirectory)` | Directory di lavoro |
| `buildConfiguration` | `$(buildConfiguration)` | Configurazione Angular |

### `CI/Common/Steps/angular-publish.yaml`
| Parametro | Default | Descrizione |
|---|---|---|
| `projectName` | *(obbligatorio)* | Nome repo (per workingDirectory e copy dist) |
| `nodeVersion` | `$(nodeVersion)` | Versione Node.js |
| `buildConfiguration` | `$(buildConfiguration)` | Configurazione Angular |
| `outputDirectory` | `$(outputDirectory)` | Path output artifact |

### `CD/Common/Steps/appService-deploy.yaml`
| Parametro | Default | Descrizione |
|---|---|---|
| `azureServiceConnection` | *(obbligatorio)* | Service connection ARM in Azure DevOps |
| `webAppName` | *(obbligatorio)* | Nome completo App Service |
| `packagePath` | `$(packagePath)` | Glob path del .zip da deployare |

### `CD/Common/Steps/staticWebApp-deploy.yaml`
| Parametro | Default | Descrizione |
|---|---|---|
| `swaDeploymentToken` | *(obbligatorio)* | Token di deployment Azure Static Web Apps |
| `appLocation` | `$(appLocation)` | Path locale della directory da deployare |

---

## Utilizzo nei Repo Applicativi

Il repo applicativo definisce un file di raccordo che estende il template desiderato con `extends:` o `template:` e configura trigger e parametri.

### Esempio — CI GitFlow .NET

```yaml
# nel repo applicativo: pipelines/ci.yaml
trigger:
  branches:
    include: [main, dev, staging]

resources:
  repositories:
    - repository: infrastructure
      type: git
      name: MyOrg/Infrastructure

extends:
  template: V3/CI/GitFlow/publish-dotNet.yaml@infrastructure
  parameters:
    projectName: 'MyApp.BackEnd'
```

### Esempio — CD TrunkFlow Promote

```yaml
# nel repo applicativo: pipelines/promote.yaml
trigger: none
pr: none

resources:
  repositories:
    - repository: infrastructure
      type: git
      name: MyOrg/Infrastructure

extends:
  template: V3/CD/TrunkFlow/promote-dotNet-appService.yaml@infrastructure
  parameters:
    projectName: 'MyApp.BackEnd'
    azureServiceConnection: 'sc-arm-myapp'
    stagingWebAppName: 'app-myapp-be-staging'
    prodWebAppName: 'app-myapp-be-prod'
```

### Esempio — CD TrunkFlow con tecnologia di deploy custom

Per iniettare una tecnologia di deploy diversa da App Service, estendere direttamente l'orchestratore agnostico:

```yaml
extends:
  template: V3/CD/TrunkFlow/Modules/promote.yaml@infrastructure
  parameters:
    projectName: 'MyApp.BackEnd'
    buildSteps:
      - template: V3/CI/Common/Steps/dotnet-build.yaml@infrastructure
    publishSteps:
      - template: V3/CI/Common/Steps/dotnet-publish.yaml@infrastructure
        parameters:
          projectName: 'MyApp.BackEnd'
          targetEnvironment: 'Staging'
          versionArgs: '/p:Version=$(currentTag) /p:AssemblyVersion=$(assemblyVersion) /p:FileVersion=$(assemblyVersion) /p:InformationalVersion="$(currentTag)+$(gitHash)"'
    stagingDeploySteps:
      - template: V3/CD/Common/Steps/appService-deploy.yaml@infrastructure
        parameters:
          azureServiceConnection: 'sc-arm-myapp'
          webAppName: 'app-myapp-be-staging'
          packagePath: '$(Build.ArtifactStagingDirectory)/publish/**/*.zip'
    prodDeploySteps:
      - template: V3/CD/Common/Steps/appService-deploy.yaml@infrastructure
        parameters:
          azureServiceConnection: 'sc-arm-myapp'
          webAppName: 'app-myapp-be-prod'
          packagePath: '$(Pipeline.Workspace)/staging/**/*.zip'
```

---

## Variable Groups ADO Richiesti

| Group | Variabili attese | Usato da |
|---|---|---|
| `development` | `targetEnvironment=Development`, conn. strings, ecc. | GitFlow (dev branch), TrunkFlow CI |
| `staging` | `targetEnvironment=Staging`, conn. strings, ecc. | GitFlow (staging branch), TrunkFlow CD promote |
| `production` | `targetEnvironment=Production`, conn. strings, ecc. | GitFlow (main branch) |
| `common-quality` | Soglie di copertura, ecc. | Tutti i quality template |

---

## Aggiungere un Nuovo Stack Tecnologico

1. Creare i file step CI in `CI/Common/Steps/`:
   - `{tech}-build.yaml`
   - `{tech}-publish.yaml`
   - `{tech}-quality.yaml`
2. Creare il file step CD in `CD/Common/Steps/`:
   - `{hostingTarget}-deploy.yaml`
3. Creare gli entry point CI in `CI/Agnostic/`, `CI/GitFlow/`, `CI/TrunkFlow/` referenziando i nuovi step.
4. Creare gli entry point CD in `CD/Agnostic/` e, se necessario, in `CD/TrunkFlow/` (`promote-{tech}-{hostingTarget}.yaml`).

Non è mai necessario modificare gli orchestratori (`Common/publish.yaml`, `GitFlow/Modules/publish.yaml`, `CD/TrunkFlow/Modules/promote.yaml`).
