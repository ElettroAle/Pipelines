# CLAUDE.md — Istruzioni per l'AI

Questo file descrive la struttura, le convenzioni e le regole di questa libreria di pipeline ADO.
Leggilo integralmente prima di modificare qualsiasi file.

---

## Struttura e Principi Architetturali

La libreria è organizzata in tre livelli gerarchici:

```
Entry point  →  Orchestratore  →  Step template
```

- **Entry point** (`Agnostic/`, `GitFlow/`, `TrunkFlow/`): definisce variabili, variable groups e branch-conditional logic. Non contiene mai step inline — inietta step template tramite stepList.
- **Orchestratore** (`Common/publish.yaml`, `GitFlow/Modules/publish.yaml`, `CD/TrunkFlow/Modules/promote.yaml`, ecc.): definisce gli stage e i job. Non conosce la tecnologia (dotNet, Angular, App Service). Riceve le stepList dai caller.
- **Step template** (`CI/Common/Steps/`, `CD/Common/Steps/`): contiene i task effettivi. È l'unico punto in cui risiedono operazioni tecnologia-specifiche.

### Regola fondamentale: nessun inline

**Non inserire mai task inline negli entry point.** Ogni operazione tecnologia-specifica deve risiedere in un file `Common/Steps/`. Gli entry point iniettano step template, non task diretti.

Sbagliato (CI e CD):
```yaml
buildSteps:
  - task: UseDotNet@2      # ← task inline: VIETATO
    inputs:
      version: 10.0.x
```
```yaml
stagingDeploySteps:
  - task: AzureWebApp@1    # ← task inline: VIETATO
    inputs:
      ...
```

Corretto:
```yaml
buildSteps:
  - template: ../Common/Steps/dotnet-build.yaml

stagingDeploySteps:
  - template: ../Common/Steps/appService-deploy.yaml
    parameters:
      azureServiceConnection: ${{ parameters.azureServiceConnection }}
      webAppName: ${{ parameters.stagingWebAppName }}
      packagePath: '$(Build.ArtifactStagingDirectory)/publish/**/*.zip'
```

---

## Convenzioni di Naming

| Livello | Pattern | Esempio CI | Esempio CD |
|---|---|---|---|
| Entry point | `{flusso}/{azione}-{tech1}-{tech2}.yaml` | `GitFlow/publish-dotNet.yaml` | `TrunkFlow/promote-dotNet-appService.yaml` |
| Orchestratore | `{flusso}/Modules/{azione}.yaml` | `GitFlow/Modules/publish.yaml` | `TrunkFlow/Modules/promote.yaml` |
| Step template CI | `CI/Common/Steps/{tech}-{azione}.yaml` | `Common/Steps/dotnet-build.yaml` | — |
| Step template CD | `CD/Common/Steps/{tech}-{azione}.yaml` | — | `Common/Steps/appService-deploy.yaml` |

**Nota sul naming degli entry point CD**: il nome riflette *tutte* le tecnologie coinvolte.
`promote-dotNet-appService.yaml` significa: promuove un progetto .NET su Azure App Service.

### Flussi riconosciuti
- `Agnostic` — nessuna governance Git
- `GitFlow` — branch dev/staging/main con SemVer e tagging
- `TrunkFlow` — solo main; CI produce pre-release, CD taglia il tag

---

## Regole sui Parametri degli Step Template

I parametri degli step template hanno **sempre un default che punta a una variabile ADO** (`$(nomevariabile)`). Questo permette al caller di non passare esplicitamente il parametro se la variabile è già definita nell'entry point.

```yaml
parameters:
  - name: dotnetVersion
    type: string
    default: '$(dotnetVersion)'   # ← default = variabile runtime ADO
```

### `versionArgs` — il parametro discriminante

`CI/Common/Steps/dotnet-publish.yaml` accetta il parametro `versionArgs` (default: `''`).

- **Agnostico** → non passare `versionArgs` (o passare `''`): nessuna versione embedded nel binario.
- **GitFlow / TrunkFlow / CD Promote** → passare:
  ```
  versionArgs: '/p:Version=$(currentTag) /p:AssemblyVersion=$(currentTag) /p:FileVersion=$(currentTag) /p:InformationalVersion="$(currentTag)-$(gitHash)"'
  ```

Non aggiungere mai i `/p:Version` direttamente nell'entry point: passali sempre tramite `versionArgs`.

---

## Riferimenti ai Path

I path dei template sono **sempre relativi al file che li referenzia**.

### CI

| Da | A `CI/Common/Steps/` | Esempio |
|---|---|---|
| `CI/Agnostic/` | `../Common/Steps/` | `../Common/Steps/dotnet-build.yaml` |
| `CI/GitFlow/` | `../Common/Steps/` | `../Common/Steps/dotnet-build.yaml` |
| `CI/TrunkFlow/` | `../Common/Steps/` | `../Common/Steps/dotnet-build.yaml` |

### CD

| Da | A `CI/Common/Steps/` | A `CD/Common/Steps/` |
|---|---|---|
| `CD/Agnostic/` | — | `../Common/Steps/appService-deploy.yaml` |
| `CD/TrunkFlow/` (entry point) | `../../CI/Common/Steps/dotnet-build.yaml` | `../Common/Steps/appService-deploy.yaml` |

Gli orchestratori (`*/Modules/`) **non referenziano mai step template** — ricevono stepList dai caller.

---

## Test prima di ogni PR

Prima di aprire una PR esegui sempre i due livelli di test dalla root del repo.

### Livello 1 — Static Analysis (Python)

```bash
pip install -r Tests/static/requirements.txt
yamllint -c Tests/static/.yamllint.yaml V3/
python Tests/static/check-references.py
python Tests/static/check-parameters.py
```

Cosa intercetta:
- YAML malformato, tab, trailing spaces
- `template: path/che/non/esiste.yaml`
- Parametri passati a un template che non li dichiara (typo, rename)

### Livello 2 — Script Unit Tests (Pester)

Eseguire solo se hai modificato `CI/Scripts/`:

```powershell
Invoke-Pester Tests/scripts/ -Output Detailed
```

I test usano un **bare repo locale** come fake remote, quindi non richiedono accesso di rete.

### Quando eseguire cosa

| Hai modificato | Esegui |
|---|---|
| Qualsiasi file in `V3/` | Livello 1 |
| `CI/Scripts/Set-Versioning.ps1` | Livello 1 + Livello 2 (`Set-Versioning.Tests.ps1`) |
| `CI/Scripts/Verify-SemVer.ps1` | Livello 1 + Livello 2 (`Verify-SemVer.Tests.ps1`) |

I workflow GitHub Actions replicano questi stessi check automaticamente su ogni push.

---

## Aggiungere uno Step Template

**CI** — operazioni di build, publish, quality:
1. Creare il file in `CI/Common/Steps/{tech}-{azione}.yaml`.

**CD** — operazioni di deploy:
1. Creare il file in `CD/Common/Steps/{tech}-{azione}.yaml`.

Per entrambi:
2. Usare variabili ADO come default per tutti i parametri opzionali.
3. Documentare nel header con la sezione `# Riusato da:`.
4. Aggiornare tutti gli entry point che ne hanno bisogno per referenziarlo.
5. Aggiornare il `README.md`.
6. Verificare che `check-references.py` e `check-parameters.py` passino.

---

## Aggiungere un Nuovo Stack Tecnologico

1. Creare in `CI/Common/Steps/`:
   - `{tech}-build.yaml`
   - `{tech}-publish.yaml`
   - `{tech}-quality.yaml`
2. Creare in `CD/Common/Steps/`:
   - `{tech}-deploy.yaml` (o `{hostingTarget}-deploy.yaml` se è più descrittivo)
3. Creare entry point in `CI/Agnostic/`, e se necessario in `CI/GitFlow/` e `CI/TrunkFlow/`.
4. Creare entry point in `CD/Agnostic/` e, se necessario, in `CD/TrunkFlow/` (`promote-{tech}-{hostingTarget}.yaml`).
5. **Non toccare** gli orchestratori esistenti se non cambia la struttura di stage/job.

---

## Aggiungere un Nuovo Flusso Git

1. Creare la cartella `CI/{NuovoFlusso}/` con:
   - `Modules/publish.yaml` — orchestratore con la logica specifica del flusso
   - Entry point per ogni tech stack (`publish-dotNet.yaml`, ecc.)
2. Gli entry point referenziano `../Common/Steps/` per gli step CI.
3. Se il flusso ha una fase CD dedicata (come TrunkFlow), creare `CD/{NuovoFlusso}/Modules/` con l'orchestratore agnostico, e gli entry point specifici in `CD/{NuovoFlusso}/`.
4. Aggiornare il `README.md`.

---

## Cosa NON Fare

- **Non inserire task inline negli entry point** (né CI né CD): ogni task va in `Common/Steps/`.
- **Non duplicare step** tra entry point diversi. Se ti trovi a copiare task, crea uno step template.
- **Non modificare** gli orchestratori agnostici per aggiungere logica tech-specific.
- **Non aggiungere** branch-conditional logic negli orchestratori (`Modules/`): quella logica appartiene agli entry point.
- **Non referenziare** `Common/Steps/` dagli orchestratori (`*/Modules/`): i moduli ricevono stepList, non le definiscono.
- **Non cambiare** il path dell'artifact staging (`$(Build.ArtifactStagingDirectory)/publish`): è il contratto tra step template e orchestratore.
- **Non creare** entry point CD con nome solo della piattaforma di hosting (`promote-appService.yaml`): il nome deve includere anche la tecnologia di build (`promote-dotNet-appService.yaml`).

---

## Variabili ADO Attese dagli Step Template

Queste variabili devono essere definite nell'entry point (come `variables:` o tramite variable group) affinché i default degli step template funzionino:

| Variabile | Tipo | Usata da |
|---|---|---|
| `dotnetVersion` | stringa | `dotnet-build.yaml`, `dotnet-publish.yaml`, `dotnet-quality.yaml` |
| `publishProject` | stringa | `dotnet-build.yaml`, `dotnet-publish.yaml` |
| `buildConfiguration` | stringa | tutti |
| `targetRuntime` | stringa | `dotnet-publish.yaml` |
| `selfContained` | stringa | `dotnet-publish.yaml` |
| `outputDirectory` | stringa | `dotnet-publish.yaml`, `angular-publish.yaml` |
| `targetEnvironment` | stringa | `dotnet-publish.yaml` |
| `nodeVersion` | stringa | `angular-*.yaml` |
| `buildProjects` | stringa | `dotnet-quality.yaml` |
| `testProjects` | stringa | `dotnet-quality.yaml` |
| `appLocation` | stringa | `staticWebApp-deploy.yaml` |
| `currentTag` | stringa | `versionArgs` (esposto da Set-Versioning) |
| `gitHash` | stringa | `versionArgs` (esposto da Set-Versioning) |
