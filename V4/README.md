# Pipeline Templates — V4

Generazione nuova, accanto a V3. Qui nascono i template che V3 non ha e che non si costruiscono
modificando un template V3 senza cambiarne il contratto per chi lo usa già.

## Template di alto livello

| Template | Descrizione |
|---|---|
| `CD/Agnostic/deploy-azure-terraform.yaml` | Terraform su Azure: piano su ogni run (anche build validation di PR), apply del piano salvato solo sul ramo di rilascio e dopo l'approvazione sull'ambiente ADO; accesso OIDC senza segreti, CLI scaricata da releases.hashicorp.com senza estensioni del marketplace |

Rispetto a `V3/IAC/`: quelle sono pipeline fisse (percorsi `azure/env/<env>` cablati, solo `int`),
non si estendono da un altro repository, usano i task dell'estensione
`ms-devlabs.custom-terraform-tasks` e, in `terraform-deploy.yaml`, un segreto del service principal.

### Utilizzo

```yaml
resources:
  repositories:
    - repository: infrastructure
      type: github
      name: ElettroAle/Pipelines
      endpoint: <GITHUB_SERVICE_CONNECTION>
      ref: refs/heads/main

extends:
  template: V4/CD/Agnostic/deploy-azure-terraform.yaml@infrastructure
  parameters:
    azureServiceConnection: '<AZURE_SERVICE_CONNECTION>'
    workingDirectory: 'infra'
    varFile: 'environments/dev.tfvars.json'
    targetEnvironment: '<ADO_ENVIRONMENT_WITH_APPROVAL>'
```

## Step template

### `CD/Common/Steps/terraform-install.yaml`
| Parametro | Default | Descrizione |
|---|---|---|
| `terraformVersion` | `$(terraformVersion)` | Versione esatta della CLI, scaricata da releases.hashicorp.com (agent Linux x64) |

### `CD/Common/Steps/terraform-plan.yaml`
| Parametro | Default | Descrizione |
|---|---|---|
| `azureServiceConnection` | *(obbligatorio)* | Service connection ARM in workload identity federation |
| `workingDirectory` | *(obbligatorio)* | Cartella della configurazione Terraform |
| `varFile` | *(obbligatorio)* | File di variabili, relativo a `workingDirectory` |
| `planDirectory` | `$(Build.ArtifactStagingDirectory)/terraform` | Dove scrivere `tfplan`, `plan.txt` e il riepilogo `plan.md` |

### `CD/Common/Steps/terraform-apply.yaml`
| Parametro | Default | Descrizione |
|---|---|---|
| `azureServiceConnection` | *(obbligatorio)* | Service connection ARM in workload identity federation |
| `workingDirectory` | *(obbligatorio)* | Cartella della configurazione Terraform |
| `planFile` | *(obbligatorio)* | Piano salvato dallo stage Plan: si applica senza ricalcolarlo |
