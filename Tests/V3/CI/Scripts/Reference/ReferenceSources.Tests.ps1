#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Reference/ReferenceSources.ps1

.DESCRIPTION
    I Taskfile e le specifiche OpenAPI sono scritti in TestDrive; i moduli Terraform si leggono con
    terraform-docs, scaricato alla prima esecuzione (TERRAFORM_DOCS_PATH lo evita).
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Reference/ReferenceSources.ps1"

    function Write-TestFile([string]$Path, [string]$Content) {
        $file = Join-Path $TestDrive $Path
        New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
        [IO.File]::WriteAllText($file, ($Content -replace "`r`n", "`n"))
        return $file
    }
}

Describe 'Read-TaskfileTasks' {
    BeforeAll {
        $taskfile = Write-TestFile 'tf/Taskfile.yml' @'
version: '3'

vars:
  GLOBAL: x

includes:
  flat:
    taskfile: ./Flat.yml
    flatten: true
  ns: ./Nested
  missing:
    taskfile: ./Missing.yml
    optional: true

tasks:
  # un commento
  deploy:
    desc: "Rilascia (richiede ENV)"
    vars:
      LOCAL: '{{.ENV}}-x'
    cmds:
      - echo {{.ENV}} {{.LOCAL}} {{.GLOBAL}} {{.CLI_ARGS}} {{.OUT | default "o"}}
  folded:
    desc: >
      Prima riga
      seconda riga
  literal:
    desc: |
      Riga uno
      Riga due
  quoted:
    desc: 'L''apostrofo # non e'' un commento'
    vars: {A: 1, B: 2}
    cmds:
      - echo {{.A}} {{.B}} {{.C}}
  hidden:
    internal: true
    desc: interno
  nodesc:
    cmds:
      - echo
'@
        Write-TestFile 'tf/Flat.yml' "version: '3'`ntasks:`n  flat:task:`n    desc: Piatto`n    cmds:`n      - echo {{.GLOBAL}} {{.P}}`n" | Out-Null
        Write-TestFile 'tf/Nested/Taskfile.yml' "version: '3'`ntasks:`n  inner:`n    desc: Annidato # commento`n" | Out-Null
        $tasks = @{}
        foreach ($task in (Read-TaskfileTasks $taskfile)) { $tasks[$task.Name] = $task }
    }

    It 'elenca i task non interni, degli include piatti con il loro nome e degli altri con lo spazio dei nomi' {
        @($tasks.Keys | Sort-Object) | Should -Be @('deploy', 'flat:task', 'folded', 'literal', 'nodesc', 'ns:inner', 'quoted')
    }

    It 'legge le descrizioni scritte fra virgolette, piegate, letterali e senza virgolette' {
        @($tasks['quoted'].Description, $tasks['folded'].Description, $tasks['literal'].Description, $tasks['ns:inner'].Description, $tasks['nodesc'].Description) |
            Should -Be @("L'apostrofo # non e' un commento", 'Prima riga seconda riga', "Riga uno`nRiga due", 'Annidato', '')
    }

    It 'i parametri sono le variabili lette e non definite da un blocco vars o da go-task' {
        "$($tasks['deploy'].Parameters -join ',')|$($tasks['quoted'].Parameters -join ',')|$($tasks['flat:task'].Parameters -join ',')" | Should -Be 'ENV,OUT|C|P'
    }

    It 'un Taskfile inesistente fa fallire la lettura' {
        { Read-TaskfileTasks (Join-Path $TestDrive 'assente.yml') } | Should -Throw '*Taskfile inesistente*'
    }

    It 'una cartella si legge dal suo Taskfile.yml' {
        @(Read-TaskfileTasks (Join-Path $TestDrive 'tf/Nested') | ForEach-Object Name) | Should -Be @('inner')
    }
}

Describe 'Read-OpenApiEndpoints' {
    BeforeAll {
        $document = Write-TestFile 'api.json' (ConvertTo-Json -Depth 20 -InputObject @{
                openapi    = '3.0.1'
                paths      = @{
                    '/b' = @{ delete = @{ summary = 'Cancella'; description = 'Cancella'; responses = @{ '204' = @{ description = 'Fatto' } } }; get = @{ description = 'Solo descrizione'; responses = @{ '200' = @{ '$ref' = '#/components/responses/Ok' } } } }
                    '/a' = @{ post = @{ summary = 'Crea'; description = 'Con dettagli'; parameters = @(@{ '$ref' = '#/components/parameters/Tenant' }, @{ '$ref' = '#/components/parameters/Assente' }); requestBody = @{ '$ref' = '#/components/requestBodies/Item' } } }
                }
                components = @{
                    parameters    = @{ Tenant = @{ name = 'tenant'; in = 'header'; required = $true; description = 'Il tenant' } }
                    responses     = @{ Ok = @{ description = 'Bene' } }
                    requestBodies = @{ Item = @{ description = 'La voce'; content = @{ 'application/json' = @{} } } }
                }
            })
        $other = Write-TestFile 'other.json' '{"openapi":"3.0.1"}'
        $endpoints = Read-OpenApiEndpoints @($document, $other)
    }

    It 'ordina gli endpoint per percorso e metodo' {
        @($endpoints | ForEach-Object { "$($_.Method) $($_.Path)" }) | Should -Be @('POST /a', 'GET /b', 'DELETE /b')
    }

    It 'unisce riassunto e descrizione senza ripeterli' {
        @($endpoints | ForEach-Object Description) | Should -Be @('Crea Con dettagli', 'Solo descrizione', 'Cancella')
    }

    It 'risolve i riferimenti di parametri, corpo e risposte e ignora quelli che non trova' {
        "$(@($endpoints[0].Parameters | ForEach-Object { "$($_.Name)/$($_.In)/$($_.Required)/$($_.Description)" }) -join ';')|$($endpoints[1].Responses[0].Description)|$($endpoints[0].Responses.Count)" |
            Should -Be 'tenant/header/True/Il tenant;application/json/body/False/La voce|Bene|0'
    }

    It 'una specifica inesistente fa fallire la lettura' {
        { Read-OpenApiEndpoints @((Join-Path $TestDrive 'assente.json')) } | Should -Throw '*specifica OpenAPI inesistente*'
    }
}

Describe 'Read-TerraformModules' {
    BeforeAll {
        $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
        if (-not $env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) 'pester-reference-tools' }
        Write-TestFile 'modules/Store/main.tf' @'
variable "size" {
  type    = number
  default = 3
}

output "id" {
  value       = azurerm_storage_account.this.id
  description = "L'account."
}

resource "azurerm_storage_account" "this" {
  name = "x"
}

data "azurerm_client_config" "current" {}
'@ | Out-Null
        Write-TestFile 'modules/Empty/README.md' 'nessun file Terraform' | Out-Null
        $modules = Read-TerraformModules (Join-Path $TestDrive 'modules')
    }

    AfterAll { $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory }

    It 'legge solo le cartelle con file Terraform' {
        @($modules | ForEach-Object Name) | Should -Be @('Store')
    }

    It 'legge variabili, output e risorse gestite, senza le fonti dati' {
        $module = $modules[0]
        "$($module.Variables[0].Name)/$($module.Variables[0].Type)/$($module.Variables[0].Default)/$($module.Variables[0].Required)/[$($module.Variables[0].Description)]|$($module.Outputs[0].Description)|$($module.Resources -join ',')" |
            Should -Be 'size/number/3/False/[]|L''account.|azurerm_storage_account.this'
    }

    It 'una cartella dei moduli inesistente fa fallire la lettura' {
        { Read-TerraformModules (Join-Path $TestDrive 'assente') } | Should -Throw '*cartella dei moduli Terraform inesistente*'
    }

    It 'un modulo che terraform-docs non legge fa fallire la lettura' {
        Write-TestFile 'broken/Bad/main.tf' 'variable "x" {' | Out-Null
        { Read-TerraformModules (Join-Path $TestDrive 'broken') } | Should -Throw '*terraform-docs su*'
    }
}
