# CLAUDE.md — Istruzioni per l'AI

Questo file descrive la struttura, le convenzioni e le regole di questa libreria di pipeline ADO.
Leggilo integralmente prima di modificare qualsiasi file.

---

## Struttura e Principi Architetturali

La libreria è organizzata in tre livelli gerarchici:

```
Entry point  →  Orchestratore  →  Step template
```

- **Entry point** (`Agnostic/`, `GitFlow/`, `TrunkFlow/`): definisce variabili, variable groups e branch-conditional logic. Non contiene mai step inline.
- **Orchestratore** (`Common/publish.yaml`, `GitFlow/Modules/publish.yaml`, ecc.): definisce gli stage e i job. Non conosce la tecnologia (dotNet, Angular).
- **Step template** (`Common/Steps/`): contiene i task effettivi. È l'unico punto in cui si modificano le operazioni tecniche.

### Regola fondamentale: nessun inline

**Non inserire mai step inline negli entry point.** Ogni step deve risiedere in un file `Common/Steps/`. Gli entry point iniettano step template, non task diretti.

Sbagliato:
```yaml
buildSteps:
  - task: UseDotNet@2      # ← step inline: VIETATO
    inputs:
      version: 10.0.x
```

Corretto:
```yaml
buildSteps:
  - template: ../Common/Steps/dotnet-build.yaml   # ← riferimento a step template
```

---

## Convenzioni di Naming

| Livello | Pattern | Esempio |
|---|---|---|
| Entry point | `{flusso}/{azione}-{tech}.yaml` | `GitFlow/publish-dotNet.yaml` |
| Orchestratore | `{flusso}/Modules/publish.yaml` | `GitFlow/Modules/publish.yaml` |
| Step template | `Common/Steps/{tech}-{azione}.yaml` | `Common/Steps/dotnet-build.yaml` |

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

| Da | A `Common/Steps/` | Esempio |
|---|---|---|
| `CI/Agnostic/` | `../Common/Steps/` | `../Common/Steps/dotnet-build.yaml` |
| `CI/GitFlow/` | `../Common/Steps/` | `../Common/Steps/dotnet-build.yaml` |
| `CI/TrunkFlow/` | `../Common/Steps/` | `../Common/Steps/dotnet-build.yaml` |
| `CD/TrunkFlow/` | `../../CI/Common/Steps/` | `../../CI/Common/Steps/dotnet-build.yaml` |

Gli orchestratori (`GitFlow/Modules/`, `TrunkFlow/Modules/`) **non referenziano step template** — ricevono stepList dai caller.

---

## Aggiungere uno Step Template

1. Creare il file in `CI/Common/Steps/{tech}-{azione}.yaml`.
2. Usare variabili ADO come default per tutti i parametri opzionali.
3. Documentare il parametro nel header del file con la sezione `# Riusato da:`.
4. Aggiornare tutti gli entry point che ne hanno bisogno per referenziarlo.
5. Aggiornare il `README.md` con la tabella parametri.

---

## Aggiungere un Nuovo Stack Tecnologico

1. Creare in `CI/Common/Steps/`:
   - `{tech}-build.yaml`
   - `{tech}-publish.yaml`
   - `{tech}-quality.yaml`
2. Creare entry point in `CI/Agnostic/`, e se necessario in `CI/GitFlow/` e `CI/TrunkFlow/`.
3. Se il deploy ha caratteristiche specifiche, aggiungere in `CD/Agnostic/`.
4. **Non toccare** gli orchestratori esistenti (`Common/publish.yaml`, `GitFlow/Modules/publish.yaml`, ecc.) se non cambia la struttura di stage/job.

---

## Aggiungere un Nuovo Flusso Git

1. Creare la cartella `CI/{NuovoFlusso}/` con:
   - `Modules/publish.yaml` — orchestratore con la logica specifica del flusso
   - Entry point per ogni tech stack (`publish-dotNet.yaml`, ecc.)
2. Gli entry point referenziano `../Common/Steps/` per gli step.
3. Aggiornare il `README.md`.

---

## Cosa NON Fare

- **Non duplicare step** tra entry point diversi. Se ti trovi a copiare task, crea uno step template.
- **Non modificare** `Common/publish.yaml` o `Common/quality.yaml` per aggiungere logica tech-specific: questi orchestratori devono rimanere agnostici.
- **Non aggiungere** branch-conditional logic negli orchestratori (`Modules/`): quella logica appartiene agli entry point.
- **Non referenziare** `CI/Common/Steps/` da file in `CI/GitFlow/Modules/` o `CI/TrunkFlow/Modules/`: i moduli ricevono stepList, non le definiscono.
- **Non cambiare** il path dell'artifact staging (`$(Build.ArtifactStagingDirectory)/publish`): è il contratto tra step template e orchestratore.

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
| `currentTag` | stringa | `versionArgs` (esposto da Set-Versioning) |
| `gitHash` | stringa | `versionArgs` (esposto da Set-Versioning) |
