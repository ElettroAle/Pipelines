#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Reference/Publish-Reference.ps1

.DESCRIPTION
    Gli scenari del requisito "La reference della piattaforma si genera dal codice". Le sorgenti sono i
    moduli Terraform, le specifiche OpenAPI e il Taskfile finti di Fixtures/ReferenceFixture.ps1; la wiki e'
    un repository git locale con un origin bare sul ramo wikiMaster; la board e' l'endpoint locale di
    Azure DevOps dei test della registrazione delle decisioni. Lo script gira come in pipeline, in un
    processo separato; terraform-docs si scarica alla prima esecuzione (TERRAFORM_DOCS_PATH lo evita).
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/ReferenceFixture.ps1"
    . "$PSScriptRoot/../Adr/Fixtures/AzureDevOpsStub.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Reference/Publish-Reference.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    if (-not $env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) 'pester-reference-tools' }
    $Stub = Start-AzureDevOpsStub
    $BoardEnvironment = @{ SYSTEM_COLLECTIONURI = "$($Stub.Endpoint)/"; WIKI_URL = 'https://dev.azure.com/Org/Progetto/_wiki/wikis/Progetto.wiki' }
    $NoOpenBug = @{ "POST /Progetto/_apis/wit/wiql" = @{ status = 200; body = @{ workItems = @() } }; 'POST /Progetto/_apis/wit/workitems/$Bug' = @{ status = 200; body = @{ id = 9001 } } }

    function Get-CreatedBugs {
        return @(Get-AzureDevOpsRequests $Stub | Where-Object { $_.Method -eq 'POST' -and $_.Path -like '*/wit/workitems/$Bug' } | ForEach-Object {
                $operations = $_.Body | ConvertFrom-Json
                [pscustomobject]@{
                    Title = "$(($operations | Where-Object path -eq '/fields/System.Title').value)"
                    Text  = "$(($operations | Where-Object path -eq '/fields/Microsoft.VSTS.TCM.ReproSteps').value)"
                }
            })
    }
}

AfterAll {
    Stop-AzureDevOpsStub $Stub
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}

# Gli scenari che leggono la reference delle sorgenti di partenza condividono una generazione.
Describe 'Reference generata dal codice' {
    BeforeAll {
        $Sources = New-ReferenceSources
        $Wiki = New-Wiki
        Set-AzureDevOpsRoutes $Stub $NoOpenBug
        $Generation = Invoke-ReferenceScript $ScriptPath $Sources $Wiki $BoardEnvironment
    }

    AfterAll {
        Remove-Item -Recurse -Force $Sources, $Wiki.Root -ErrorAction SilentlyContinue
    }

    It 'la generazione riesce' {
        $Generation.ExitCode | Should -Be 0 -Because $Generation.Output
    }

    Context 'reference di un modulo Terraform comune: <Module>' -ForEach @(
        @{ Module = 'ServiceBus'; Resource = 'azurerm_servicebus_topic' }
        @{ Module = 'ServiceBusSubscription'; Resource = 'azurerm_servicebus_subscription' }
        @{ Module = 'PrivateEndpoint'; Resource = 'azurerm_private_endpoint' }
        @{ Module = 'AppService'; Resource = 'azurerm_linux_web_app' }
        @{ Module = 'FunctionApp'; Resource = 'azurerm_linux_function_app' }
    ) {
        BeforeAll {
            $page = Get-WikiPage $Wiki "Reference/Moduli-Terraform/$Module.md"
        }

        It 'la pagina elenca le variabili con la loro descrizione' {
            @("| ``name`` | ``string`` | obbligatorio | Nome della risorsa del modulo $Module. |", "| ``tags`` | ``map(string)`` | ``{}`` | Tag della risorsa del modulo $Module. |") |
                Where-Object { -not $page.Contains($_) } | Should -BeNullOrEmpty
        }

        It 'la pagina elenca gli output con la loro descrizione' {
            $page | Should -Match ([regex]::Escape("| ``id`` | Identificativo della risorsa del modulo $Module. |"))
        }

        It 'la pagina elenca le risorse del modulo' {
            $page | Should -Match ([regex]::Escape("- ``$Resource.this``"))
        }
    }

    Context "reference di un'API: <Api>" -ForEach @(
        @{ Api = 'API del Motore'; Page = 'API-del-Motore'; Expected = @(
                "## POST /api/v1/conversations`n`nApre una conversazione"
                '| `application/json` | body, obbligatorio | Il canale della conversazione |'
                '| `201` | Conversazione aperta |'
                "## GET /api/v1/conversations/{conversationId}`n`nLegge una conversazione"
                '| `conversationId` | path, obbligatorio | La conversazione |'
                '| `404` | Conversazione inesistente |'
                "## GET /api/v2/tenants`n`nElenca i tenant"
                '| `page` | query | La pagina |') }
        @{ Api = 'BFF'; Page = 'BFF'; Expected = @(
                "## GET /sessions/{id}`n`nLegge una sessione"
                '| `id` | path, obbligatorio | La sessione |'
                '| `200` | OK |') }
    ) {
        It 'la pagina elenca ogni endpoint con parametri, risposte e descrizione' {
            $page = Get-WikiPage $Wiki "Reference/API/$Page.md"
            @($Expected | Where-Object { -not $page.Contains($_) }) | Should -BeNullOrEmpty -Because $page
        }
    }

    Context 'comandi del task runner' {
        It 'la pagina elenca ogni task con la sua descrizione e i suoi parametri' {
            $page = Get-WikiPage $Wiki 'Reference/Comandi.md'
            @(
                '| `environment:prepare` | Crea gli hard link di un ambiente (richiede MODULE e ENV) | `MODULE`, `ENV` |'
                '| `terraform:plan` | Esegue terraform plan per un modulo e ambiente (richiede MODULE e ENV) | `MODULE`, `ENV` |'
                '| `terraform:plan-destroy` | Esegue terraform plan -destroy per un modulo e ambiente (richiede MODULE e ENV) | `MODULE`, `ENV` |'
                '| `terraform:quality-servicebus` | Quality Service Bus: fmt-check e validate (richiede MODULE e ENV, opzionale OUT) | `MODULE`, `ENV`, `OUT` |'
            ) | Where-Object { -not $page.Contains($_) } | Should -BeNullOrEmpty -Because $page
        }
    }

    Context 'release notes' {
        It 'la reference rimanda alle release notes di ogni repository sorgente' {
            $page = Get-WikiPage $Wiki 'Reference.md'
            @('AI', 'BFF', 'Frontend') | Where-Object { -not $page.Contains("- [$_]($(Get-WikiUrl @('Release notes', $_)))") } | Should -BeNullOrEmpty -Because $page
        }
    }

    Context 'risorsa di un modulo Terraform senza descrizione' {
        It 'la pagina di "ServiceBus" elenca "azurerm_servicebus_topic"' {
            Get-WikiPage $Wiki 'Reference/Moduli-Terraform/ServiceBus.md' | Should -Match ([regex]::Escape('- `azurerm_servicebus_topic.this`'))
        }

        It 'nessun Bug nomina "azurerm_servicebus_topic"' {
            @(Get-AzureDevOpsRequests $Stub | Where-Object { $_.Body -match 'azurerm_servicebus_topic' }) | Should -BeNullOrEmpty
        }
    }

    Context 'dal testo alla reference: <Element> in <Page>' -ForEach @(
        @{ Page = 'Architettura/Concetti-trasversali.md'; Element = 'il modulo "ServiceBus"'; Text = 'ServiceBus'; Titles = @('Reference', 'Moduli Terraform', 'ServiceBus') }
        @{ Page = 'Architettura/Vista-dei-building-block.md'; Element = 'l''API "BFF"'; Text = 'BFF'; Titles = @('Reference', 'API', 'BFF') }
        @{ Page = 'Guide/procedura%3A-aggiungere-un-tenant.md'; Element = 'il task "terraform:plan"'; Text = '`terraform:plan`'; Titles = @('Reference', 'Comandi') }
    ) {
        It "l'elemento porta alla sua pagina di reference" {
            Get-WikiPage $Wiki $Page | Should -Match ([regex]::Escape("[$Text]($(Get-WikiUrl $Titles))"))
        }
    }
}

Describe 'Reference che cambia con il codice' {
    BeforeEach {
        $Sources = New-ReferenceSources
        $Wiki = New-Wiki
    }

    AfterEach {
        Remove-Item -Recurse -Force $Sources, $Wiki.Root -ErrorAction SilentlyContinue
    }

    Context 'reference che segue il codice: <Change>' -ForEach @(
        @{ Change = 'la variabile "max_delivery_count" aggiunta al modulo "ServiceBus"'; Page = 'Reference/Moduli-Terraform/ServiceBus.md'
            Apply = { param($Sources) Add-Content -LiteralPath (Join-Path $Sources 'infrastructure/Common/Modules/ServiceBus/variables.tf') "`nvariable `"max_delivery_count`" {`n  type        = number`n  default     = 10`n  description = `"Consegne prima della dead letter.`"`n}`n" }
            Check = { param($Page) $Page.Contains('| `max_delivery_count` | `number` | `10` | Consegne prima della dead letter. |') } }
        @{ Change = 'l''endpoint "GET /sessions/{id}/summary" aggiunto al BFF'; Page = 'Reference/API/BFF.md'
            Apply = {
                param($Sources)
                $path = Join-Path $Sources 'openapi/bff.json'
                $document = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
                $document.paths['/sessions/{id}/summary'] = @{ get = @{ summary = 'Riassume una sessione'; responses = @{ '200' = @{ description = 'Il riassunto' } } } }
                [IO.File]::WriteAllText($path, (ConvertTo-Json -Depth 20 -InputObject $document))
            }
            Check = { param($Page) $Page.Contains("## GET /sessions/{id}/summary`n`nRiassume una sessione") } }
        @{ Change = 'il task "terraform:plan-destroy" rimosso dal "Taskfile.yml"'; Page = 'Reference/Comandi.md'
            Apply = {
                param($Sources)
                $path = Join-Path $Sources 'infrastructure/Taskfile.yml'
                $text = [IO.File]::ReadAllText($path)
                [IO.File]::WriteAllText($path, ($text -replace '(?s)  terraform:plan-destroy:.*?(?=  environment:prepare:)', ''))
            }
            Check = { param($Page) $Page.Contains('`terraform:plan`') -and -not $Page.Contains('terraform:plan-destroy') } }
    ) {
        BeforeEach {
            $first = Invoke-ReferenceScript $ScriptPath $Sources $Wiki
            $before = Get-WikiLastCommit $Wiki
            & $Apply $Sources
            $second = Invoke-ReferenceScript $ScriptPath $Sources $Wiki
            $after = Get-WikiLastCommit $Wiki
        }

        It 'la reference mostra il risultato' {
            $first.ExitCode, $second.ExitCode | Should -Be @(0, 0) -Because "$($first.Output)`n$($second.Output)"
            & $Check (Get-WikiPage $Wiki $Page) | Should -BeTrue -Because (Get-WikiPage $Wiki $Page)
        }

        It "la reference e' cambiata senza l'intervento di una persona" {
            "$($after.Count - $before.Count) $($after.Message)" | Should -Be '1 Reference @ 20261116.1'
        }
    }

    Context 'voce senza descrizione: <Entry> in <Repository>' -ForEach @(
        @{ Repository = 'Aidea.Dxp.Infrastructure'; Entry = 'la variabile <code>sku</code> del modulo <code>AppService</code>'
            Apply = { param($Sources) Add-Content -LiteralPath (Join-Path $Sources 'infrastructure/Common/Modules/AppService/variables.tf') "`nvariable `"sku`" {`n  type = string`n}`n" } }
        @{ Repository = 'Aidea.Dxp.AI'; Entry = 'l&#39;endpoint <code>POST /conversations</code>'
            Apply = {
                param($Sources)
                $path = Join-Path $Sources 'openapi/engine-v2.json'
                $document = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
                $document.paths['/conversations'] = @{ post = @{ responses = @{ '201' = @{ description = 'Creata' } } } }
                [IO.File]::WriteAllText($path, (ConvertTo-Json -Depth 20 -InputObject $document))
            } }
        @{ Repository = 'Aidea.Dxp.Infrastructure'; Entry = 'il task <code>environment:prepare</code>'
            Apply = {
                param($Sources)
                $path = Join-Path $Sources 'infrastructure/Taskfile.yml'
                [IO.File]::WriteAllText($path, ([IO.File]::ReadAllText($path) -replace "    desc: 'Crea gli hard link di un ambiente \(richiede MODULE e ENV\)'`n", ''))
            } }
    ) {
        It 'la board riceve un Bug che nomina la voce e il repository' {
            Set-AzureDevOpsRoutes $Stub $NoOpenBug
            & $Apply $Sources
            $result = Invoke-ReferenceScript $ScriptPath $Sources $Wiki $BoardEnvironment
            $result.ExitCode | Should -Be 0 -Because $result.Output
            @(Get-CreatedBugs | Where-Object { $_.Title -eq "Reference di ${Repository}: voci senza descrizione" -and $_.Text.Contains($Entry) }).Count | Should -Be 1 -Because (Get-CreatedBugs | ConvertTo-Json)
        }
    }

}

Describe 'Scrittura della reference nella wiki' {
    BeforeEach {
        $Sources = New-ReferenceSources
        $Wiki = New-Wiki
    }

    AfterEach {
        Remove-Item -Recurse -Force $Sources, $Wiki.Root -ErrorAction SilentlyContinue
    }

    It "una seconda generazione senza cambiamenti non aggiunge commit e lascia la wiki com'e'" {
        Invoke-ReferenceScript $ScriptPath $Sources $Wiki | Out-Null
        $before = Get-WikiLastCommit $Wiki
        $result = Invoke-ReferenceScript $ScriptPath $Sources $Wiki
        "$($result.ExitCode) $((Get-WikiLastCommit $Wiki).Count - $before.Count)" | Should -Be '0 0' -Because $result.Output
    }

    It "il resto della wiki resta com'e' e la radice entra in fondo al suo ordine" {
        Invoke-ReferenceScript $ScriptPath $Sources $Wiki | Out-Null
        "$(Get-WikiPage $Wiki 'Release-notes/AI.md')|$(Get-WikiPage $Wiki '.order')" | Should -Be "# AI|Release-notes`nArchitettura`nGuide`nReference"
    }

    It "l'indice delle voci accompagna le pagine" {
        Invoke-ReferenceScript $ScriptPath $Sources $Wiki | Out-Null
        $index = Get-WikiPage $Wiki '.attachments/Reference/reference-index.json' | ConvertFrom-Json
        @($index.entries | ForEach-Object { "$($_.kind):$($_.name)" }) -join ',' | Should -Be 'module:AppService,module:FunctionApp,module:PrivateEndpoint,module:ServiceBus,module:ServiceBusSubscription,api:API del Motore,api:BFF,task:environment:prepare,task:terraform:plan,task:terraform:plan-destroy,task:terraform:quality-servicebus'
    }

    It 'una pagina tolta dal codice sparisce dalla wiki' {
        Invoke-ReferenceScript $ScriptPath $Sources $Wiki | Out-Null
        Remove-Item -Recurse -Force (Join-Path $Sources 'infrastructure/Common/Modules/FunctionApp')
        Invoke-ReferenceScript $ScriptPath $Sources $Wiki | Out-Null
        Get-WikiPage $Wiki 'Reference/Moduli-Terraform/FunctionApp.md' | Should -BeNullOrEmpty
    }

    It "il push rifiutato si ripete sopra il commit nuovo della wiki" {
        Set-WikiFile $Wiki.Seed 'Indice.md' "# Indice`n"
        Add-WikiCommit $Wiki.Seed 'Altra pipeline'
        $result = Invoke-ReferenceScript $ScriptPath $Sources $Wiki
        "$($result.ExitCode) $([bool](Get-WikiPage $Wiki 'Indice.md')) $([bool](Get-WikiPage $Wiki 'Reference.md'))" | Should -Be '0 True True' -Because $result.Output
    }

    It 'una specifica OpenAPI assente fa fallire la generazione senza toccare la wiki' {
        Remove-Item (Join-Path $Sources 'openapi/bff.json')
        $before = Get-WikiLastCommit $Wiki
        $result = Invoke-ReferenceScript $ScriptPath $Sources $Wiki
        "$($result.ExitCode) $((Get-WikiLastCommit $Wiki).Count - $before.Count)" | Should -Be '1 0'
        $result.Output | Should -Match 'specifica OpenAPI inesistente'
    }

    It 'WIKI_DIRECTORY che non indica un checkout della wiki fa fallire la generazione' {
        $result = Invoke-ReferenceScript $ScriptPath $Sources ([pscustomobject]@{ Checkout = $Sources })
        "$($result.ExitCode) $($result.Output -match 'WIKI_DIRECTORY')" | Should -Be '1 True'
    }
}

Describe 'Bug delle voci senza descrizione' {
    BeforeEach {
        $Sources = New-ReferenceSources
        $Wiki = New-Wiki
        Add-Content -LiteralPath (Join-Path $Sources 'infrastructure/Common/Modules/AppService/variables.tf') "`nvariable `"sku`" {`n  type = string`n}`n"
    }

    AfterEach {
        Remove-Item -Recurse -Force $Sources, $Wiki.Root -ErrorAction SilentlyContinue
    }

    It "il Bug aperto con lo stesso titolo si riscrive invece di aprirne un altro" {
        Set-AzureDevOpsRoutes $Stub @{ "POST /Progetto/_apis/wit/wiql" = @{ status = 200; body = @{ workItems = @(@{ id = 77 }) } }; 'PATCH /Progetto/_apis/wit/workitems/77' = @{ status = 200; body = @{ id = 77 } } }
        $result = Invoke-ReferenceScript $ScriptPath $Sources $Wiki $BoardEnvironment
        $requests = Get-AzureDevOpsRequests $Stub
        "$($result.ExitCode) $(@($requests | ForEach-Object Method) -join ',') $($requests[-1].Body -match 'la variabile <code>sku</code>')" | Should -Be '0 POST,PATCH True' -Because $result.Output
    }

    It 'la ricerca del Bug esclude i work item chiusi e cerca il tipo indicato' {
        Set-AzureDevOpsRoutes $Stub @{ "POST /Progetto/_apis/wit/wiql" = @{ status = 200; body = @{ workItems = @() } }; 'POST /Progetto/_apis/wit/workitems/$Issue' = @{ status = 200; body = @{ id = 9002 } } }
        $environment = $BoardEnvironment.Clone()
        $environment.REFERENCE_WORK_ITEM_TYPE = 'Issue'
        $result = Invoke-ReferenceScript $ScriptPath $Sources $Wiki $environment
        $requests = Get-AzureDevOpsRequests $Stub
        $query = ($requests[0].Body | ConvertFrom-Json).query
        "$($result.ExitCode) $($query -match "WorkItemType\] = 'Issue'") $($query -match "NOT IN \('Closed', 'Done', 'Removed', 'Resolved'\)") $($requests[1].Body -match '/fields/System.Description')" | Should -Be '0 True True True' -Because $result.Output
    }

    It 'un repository senza voci da descrivere non tocca la board' {
        Remove-Item (Join-Path $Sources 'infrastructure/Common/Modules/AppService/variables.tf')
        New-ModuleSource $Sources 'AppService' 'azurerm_linux_web_app'
        Set-AzureDevOpsRoutes $Stub $NoOpenBug
        $result = Invoke-ReferenceScript $ScriptPath $Sources $Wiki $BoardEnvironment
        "$($result.ExitCode) $(@(Get-AzureDevOpsRequests $Stub).Count)" | Should -Be '0 0' -Because $result.Output
    }
}
