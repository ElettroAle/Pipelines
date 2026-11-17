---
paths:
  - "V3/**"
  - "V4/**"
  - "Tests/**"
---

# Test prima di ogni PR

Prima di aprire una PR esegui sempre i due livelli di test dalla root del repo.

## Livello 1 — Static Analysis (Python)

```bash
pip install -r Tests/Static/requirements.txt
yamllint -c Tests/Static/.yamllint.yaml V3/ V4/
python Tests/Static/check-references.py
python Tests/Static/check-parameters.py
python Tests/Static/check-spdx.py
```

Cosa intercetta:
- YAML malformato, tab, trailing spaces
- `template: path/che/non/esiste.yaml`
- Parametri passati a un template che non li dichiara (typo, rename)
- File sorgente senza header SPDX

## Livello 2 — Script Unit Tests (Pester)

Eseguire solo se hai modificato `V3/CI/Scripts/` o `Tests/V3/CI/Scripts/`:

```powershell
Invoke-Pester Tests/V3/CI/Scripts/ -Output Detailed
```

I test usano un **bare repo locale** come fake remote. L'unico accesso di rete è il download di git-cliff alla prima esecuzione, evitabile puntando `GIT_CLIFF_PATH` a un binario locale.

## Quando eseguire cosa

| Hai modificato | Esegui |
|---|---|
| Qualsiasi file in `V3/` o `V4/` | Livello 1 |
| `V3/CI/Scripts/Release/Set-Versioning.ps1` | Livello 1 + Livello 2 (`Set-Versioning.Tests.ps1`) |
| `V3/CI/Scripts/Release/Verify-SemVer.ps1` | Livello 1 + Livello 2 (`Verify-SemVer.Tests.ps1`) |
| `V3/CI/Scripts/Release/cliff.toml`, `V3/CI/Scripts/Release/GitCliff.ps1` | Livello 1 + Livello 2 (`GitCliff.Tests.ps1` + `Verify-SemVer.Tests.ps1` + `Set-Versioning.Tests.ps1` + `New-ReleaseNotes.Tests.ps1`) |
| `V3/CI/Scripts/Release/New-ReleaseNotes.ps1` | Livello 1 + Livello 2 (`New-ReleaseNotes.Tests.ps1`) |
| `V3/CI/Scripts/Release/Test-PublishedArtifact.ps1` | Livello 1 + Livello 2 (`Test-PublishedArtifact.Tests.ps1`) |
| `V3/CI/Scripts/Adr/Test-AdrCorpus.ps1` | Livello 1 + Livello 2 (`Test-AdrCorpus.Tests.ps1`) |
| `V3/CI/Scripts/Adr/Register-Decisions.ps1`, `DecisionRegistration.ps1`, `Tests/V3/CI/Scripts/Adr/Fixtures/AzureDevOpsStub.ps1` | Livello 1 + Livello 2 (`Register-Decisions.Tests.ps1`) |
| `V3/CI/Scripts/Arc42/Test-Arc42Document.ps1` | Livello 1 + Livello 2 (`Test-Arc42Document.Tests.ps1`) |
| `V3/CI/Scripts/C4/Test-C4Model.ps1`, `Structurizr.ps1` | Livello 1 + Livello 2 (`Test-C4Model.Tests.ps1`, richiede Java 17) |
| `V3/CI/Scripts/C4/ViewImages.ps1` | Livello 1 + Livello 2 (`ViewImages.Tests.ps1`, il disegno vero con Java 17) |
| `V3/CI/Scripts/Adr/DecisionClasses.ps1`, `Test-DecisionClasses.ps1`, `Repair-DecisionClasses.ps1`, `V3/CI/Scripts/C4/DotNet10Code.ps1` | Livello 1 + Livello 2 (`Test-DecisionClasses.Tests.ps1` + `Repair-DecisionClasses.Tests.ps1` + `DotNet10Code.Tests.ps1` + `Read-C4DotNet10Model.Tests.ps1`, richiede Node.js e Java 17) |
| `V3/CI/Scripts/C4/TerraformCode.ps1`, `TerraformValues.ps1`, `Read-C4TerraformModel.ps1`, `V3/CI/Common/Steps/c4-read-terraform.yaml` | Livello 1 + Livello 2 (`TerraformCode.Tests.ps1` + `TerraformValues.Tests.ps1` + `Read-C4TerraformModel.Tests.ps1`, la validita' del modello con Java 17) |
| `V3/CI/Scripts/C4/C4CodeModel.ps1`, `Read-C4DotNet10Model.ps1`, `Read-C4Angular18Model.ps1`, `Write-C4ModelText.ps1`, `Export-C4CodeModel.ps1`, `Tests/V3/CI/Scripts/C4/Fixtures/` | Livello 1 + Livello 2 (`Read-C4DotNet10Model.Tests.ps1` + `Read-C4Angular18Model.Tests.ps1` + `Write-C4ModelText.Tests.ps1` + `Export-C4CodeModel.Tests.ps1`, richiede Java 17) |
| `V3/CI/Scripts/AzureBoards/Test-PullRequestSources.ps1`, `PullRequestSources.ps1`, `V3/CI/Common/Steps/azureBoards-sources-verify.yaml`, `V3/CI/Agnostic/quality-sources.yaml` | Livello 1 + Livello 2 (`Test-PullRequestSources.Tests.ps1`) |
| `V3/CI/Scripts/AzureRepos/Publish-PullRequest.ps1` | Livello 1 + Livello 2 (`Publish-PullRequest.Tests.ps1`) |
| `V3/CI/Scripts/Arc42/Publish-Arc42Wiki.ps1`, `PlantUml.ps1` | Livello 1 + Livello 2 (`Publish-Arc42Wiki.Tests.ps1` + `PlantUml.Tests.ps1`, richiede Java 17) |
| `V3/CI/Scripts/Arc42/Arc42Document.ps1`, `Tests/V3/CI/Scripts/Arc42/Fixtures/DocumentReaders.ps1` | Livello 1 + Livello 2 (`Publish-Arc42Wiki.Tests.ps1`, richiede Java 17 e Node.js) |
| `V3/CI/Scripts/Pandoc/Pandoc.ps1` | Livello 1 + Livello 2 (`Pandoc.Tests.ps1` + `Publish-Arc42Wiki.Tests.ps1`) |
| `V3/CI/Scripts/Browser/Browser.ps1`, `Renderer/` | Livello 1 + Livello 2 (`Browser.Tests.ps1`, richiede Node.js, + `Publish-Arc42Wiki.Tests.ps1`) |
| `V3/CI/Scripts/Mermaid/Test-MermaidDiagrams.ps1`, `Mermaid.ps1`, `Parser/` | Livello 1 + Livello 2 (`Test-MermaidDiagrams.Tests.ps1`, richiede Node.js) |
| `V3/CI/Scripts/Documentation/Test-Documentation.ps1` | Livello 1 + Livello 2 (`Test-Documentation.Tests.ps1`) |
| `V3/CI/Scripts/Documentation/Test-DocumentationStyle.ps1` | Livello 1 + Livello 2 (`Test-DocumentationStyle.Tests.ps1`) |
| `V3/CI/Scripts/Documentation/Update-Documentation.ps1`, `DocumentationUpdate.ps1` | Livello 1 + Livello 2 (`Update-Documentation.Tests.ps1`) |
| `V3/CI/Scripts/Common/MarkdownText.ps1`, `VerificationGate.ps1`, `Tests/V3/CI/Scripts/Common/Fixtures/Documentation/` | Livello 1 + Livello 2 (`MarkdownText.Tests.ps1` e i test di tutti gli script di verifica della documentazione) |
| `V3/CI/Scripts/LanguageModel/`, `V3/CI/Scripts/Common/ModelRetry.ps1`, `Tests/V3/CI/Scripts/LanguageModel/Fixtures/` | Livello 1 + Livello 2 (`LanguageModel.Tests.ps1` + `Foundry.Tests.ps1` + `Anthropic.Tests.ps1` + `ModelRetry.Tests.ps1`, e i test degli script che chiamano il modello: `Test-DocumentationStyle.Tests.ps1`, `Update-Documentation.Tests.ps1`, `Write-C4ModelText.Tests.ps1`, `Repair-DiagramFlows.Tests.ps1`, questi ultimi due con Java 17, `Repair-DecisionClasses.Tests.ps1`) |
| `V3/CI/Common/Steps/documentation-style.yaml`, `c4-describe.yaml`, `flows-verify.yaml`, `documentation-update.yaml`, `adr-classes-verify.yaml`, `V3/CI/Agnostic/quality-arc42.yaml`, `quality-docs.yaml` | Livello 1 + Livello 2 (`LanguageModelTemplates.Tests.ps1`) |
| `V3/CI/Scripts/Reference/`, `V3/CI/Scripts/Common/WikiNames.ps1`, `Tests/V3/CI/Scripts/Reference/Fixtures/`, `V3/CI/Common/Steps/reference-publish.yaml`, `dotnet-openapi-publish.yaml` | Livello 1 + Livello 2 (`Publish-Reference.Tests.ps1` + `ReferenceLinks.Tests.ps1` + `ReferenceSources.Tests.ps1` + `ReferenceTemplates.Tests.ps1`, e `Publish-Arc42Wiki.Tests.ps1` per i link della reference nelle pagine del documento) |
| `V3/CI/Scripts/ScenarioCoverage/ScenarioCoverage.cs` | Livello 1 + Livello 2 (`ScenarioCoverage.Tests.ps1`, richiede .NET SDK 10) |

I workflow GitHub Actions replicano questi stessi check automaticamente su ogni push.
