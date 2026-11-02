#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/Export-C4CodeModel.ps1 e per la composizione dei lettori

.DESCRIPTION
    Ogni scenario costruisce un repository sorgente finto (progetti .NET o un'applicazione Angular),
    esegue i lettori delle sue tecnologie e poi lo scrittore, come in pipeline. Lo scenario che
    controlla la validita' del DSL richiede Java 17 o successivo (STRUCTURIZR_JAVA, JAVA_HOME_17_X64 o
    JAVA_HOME).
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/C4CodeFixture.ps1"
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/Structurizr.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-code-$(New-Guid)"

    function Invoke-Generation([System.Collections.IDictionary]$Files, [string]$Repository, [string]$Mode = 'write') {
        $readers = @{ 'Contoso.Shop.AI' = 'dotnet10'; 'Contoso.Shop.Bff.Web' = 'dotnet10'; 'Contoso.Shop.Client.Web' = 'angular18' }
        return Invoke-C4Generation $Files $Repository @($readers[$Repository]) $Mode
    }
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}


Describe "Funzionalità: Modello C4 generato dal codice" {

    Context "Schema dello scenario: elementi e relazioni nati dal codice .NET" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI'
            $dsl = $res.Generated['contoso.shop.ai.dsl']
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello contiene il container ""Api"" nel gruppo di ""Contoso.Shop.AI""" {
            Get-Block $dsl 'group\s+"AI"' | Should -Match 'container\s+"Api"'
        }

        It "E il modello contiene il container ""Worker"" nel gruppo di ""Contoso.Shop.AI""" {
            Get-Block $dsl 'group\s+"AI"' | Should -Match 'container\s+"Worker"'
        }

        It "E il modello contiene il componente ""UseCase.WrittenConversations"" in entrambi i container" {
            Get-ContainerBlock $dsl 'Api' | Should -Match 'component\s+"UseCase\.WrittenConversations"'
            Get-ContainerBlock $dsl 'Worker' | Should -Match 'component\s+"UseCase\.WrittenConversations"'
        }

        It "E il modello contiene il componente ""Utils"" nel container ""Api""" {
            Get-ContainerBlock $dsl 'Api' | Should -Match 'component\s+"Utils"'
        }

        It "E il modello contiene la relazione fra i componenti di ""DataAccess.AzureServiceBus"" e ""UseCase.WrittenConversations""" {
            $dsl | Should -Match 'contoso_shop_ai_api__contoso_shop_ai_dataaccess_azureservicebus\s+->\s+contoso_shop_ai_api__contoso_shop_ai_usecase_writtenconversations'
        }

        It "E un'applicazione e' componente di se stessa" {
            Get-ContainerBlock $dsl 'Api' | Should -Match 'component\s+"Api"'
        }
    }

    Context "Scenario: test e strumenti non entrano nel modello" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI'
            $dsl = $res.Generated['contoso.shop.ai.dsl']
        }

        It "Allora il modello non contiene ""Contoso.Shop.AI.UnitTest.Engine""" {
            $dsl | Should -Not -Match 'UnitTest\.Engine'
        }

        It "E il modello non contiene ""Contoso.Shop.AI.Utils.Reflection""" {
            $dsl | Should -Not -Match 'Utils\.Reflection'
        }

        It "E il modello non contiene ""Contoso.Shop.AI.Evals""" {
            $dsl | Should -Not -Match 'Evals'
        }
    }

    Context "Schema dello scenario: nome senza il prefisso comune del repository — <progetto>" -ForEach @(
        @{ repository = 'Contoso.Shop.AI'; progetto = 'Contoso.Shop.AI.UseCase.WrittenConversations'; nome = 'UseCase.WrittenConversations'; kind = 'component' }
        @{ repository = 'Contoso.Shop.AI'; progetto = 'Contoso.Shop.AI.Api'; nome = 'Api'; kind = 'container' }
        @{ repository = 'Contoso.Shop.Bff.Web'; progetto = 'Contoso.Shop.Bff.Web'; nome = 'Web'; kind = 'container' }
        @{ repository = 'Contoso.Shop.Bff.Web'; progetto = 'Contoso.Shop.Bff.Web.BusinessLogic'; nome = 'Web.BusinessLogic'; kind = 'component' }
    ) {
        BeforeAll {
            $files = if ($repository -eq 'Contoso.Shop.AI') { New-EngineRepository } else { New-BffRepository }
            $res = Invoke-Generation $files $repository
            $dsl = @($res.Generated.Values)[0]
        }

        It "Allora l'elemento del progetto si chiama <nome>" {
            Get-ElementLine $dsl $kind $nome | Should -Not -BeNullOrEmpty -Because $dsl
        }

        It "E l'elemento porta <progetto> come nome completo" {
            $dsl | Should -Match ([regex]::Escape("`"codice`" `"$progetto`""))
        }
    }

    Context "Schema dello scenario: elementi nati dall'applicazione Angular" {
        BeforeAll {
            $res = Invoke-Generation (New-ClientRepository) 'Contoso.Shop.Client.Web'
            $dsl = $res.Generated['contoso.shop.client.web.dsl']
            $client = Get-ContainerBlock $dsl 'Client.Web'
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello contiene il container ""Client.Web""" {
            Get-ElementLine $dsl 'container' 'Client.Web' | Should -Not -BeNullOrEmpty -Because $dsl
        }

        It "E il container unico del repository non sta in un gruppo" {
            $dsl | Should -Not -Match '(?m)^\s*group\s' -Because $dsl
        }

        It "E il modello contiene il componente ""settings"" nel container ""Client.Web""" {
            $client | Should -Match 'component\s+"settings"'
        }

        It "E il modello contiene il componente ""realtime"" nel container ""Client.Web""" {
            $client | Should -Match 'component\s+"realtime"'
        }

        It "E un modulo di base senza registrazione dei servizi non e' un componente" {
            $client | Should -Not -Match 'component\s+"guards"'
        }

        It "E il modello contiene la relazione da ""chat"" a ""ai-suggestions""" {
            $dsl | Should -Match '__features_chat\s+->\s+\S+__features_ai_suggestions'
        }

        It "E il modello contiene la relazione da ""chat"" a ""realtime""" {
            $dsl | Should -Match '__features_chat\s+->\s+\S+__core_realtime'
        }
    }

    Context "Scenario: un elemento sparisce dal codice" {
        BeforeAll {
            $files = New-EngineRepository
            $files['docs/architecture/model/generated/contoso.shop.ai.dsl'] = 'container "DataAccess.Twilio"'
            $res = Invoke-Generation $files 'Contoso.Shop.AI'
        }

        It "Allora il modello non contiene ""Contoso.Shop.AI.DataAccess.Twilio""" {
            $res.Generated['contoso.shop.ai.dsl'] | Should -Not -Match 'Twilio'
        }
    }

    Context "Scenario: la generazione cambia solo la parte del repository integrato" {
        BeforeAll {
            $files = New-BffRepository
            $files['docs/architecture/model/generated/contoso.shop.ai.dsl'] = "# parte del Motore`n"
            $res = Invoke-Generation $files 'Contoso.Shop.Bff.Web'
        }

        It "Allora cambia la parte generata di ""Contoso.Shop.Bff.Web""" {
            $res.Generated['contoso.shop.bff.web.dsl'] | Should -Match 'container\s+"Web"'
        }

        It "E la parte generata di ""Contoso.Shop.AI"" resta com'era" {
            $res.Generated['contoso.shop.ai.dsl'] | Should -Be "# parte del Motore`n"
        }

        It "E non scrive il contesto, che e' di tutti i repository" {
            @($res.Generated.Keys) | Should -Not -Contain 'context.dsl'
        }
    }

    Context "Schema dello scenario: caso non riconosciuto — <elemento>" -ForEach @(
        @{
            repository = 'Contoso.Shop.Client.Web'; elemento = 'portal'
            Build      = { $f = [ordered]@{}; $f['source/portal/package.json'] = '{ "name": "portal", "dependencies": { "react": "^18.0.0" } }'; $f }
        }
        @{
            repository = 'Contoso.Shop.AI'; elemento = 'Contoso.Shop.AI.Console'
            Build      = { $f = New-EngineRepository; Add-Project $f 'Contoso.Shop.AI.Console' (New-Project 'Microsoft.NET.Sdk.BlazorWebAssembly'); $f }
        }
        @{
            repository = 'Contoso.Shop.AI'; elemento = 'Contoso.Shop.AI.Utils (net8.0)'
            Build      = { $f = New-EngineRepository; Add-Project $f 'Contoso.Shop.AI.Utils' ((New-Project) -replace 'net10\.0', 'net8.0'); $f }
        }
        @{
            repository = 'Contoso.Shop.Client.Web'; elemento = 'ui-kit'
            Build      = { $f = New-ClientRepository; $f['source/angular.json'] = '{ "projects": { "contoso-shop-client-web": { "projectType": "application", "sourceRoot": "src" }, "ui-kit": { "projectType": "library", "sourceRoot": "projects/ui-kit/src" } } }'; $f }
        }
    ) {
        BeforeAll {
            $files = & $Build
            $files['docs/architecture/model/generated/x.dsl'] = $null
            $previousFile = "# parte precedente`n"
            $files["docs/architecture/model/generated/$($repository.ToLower()).dsl"] = $previousFile
            $res = Invoke-Generation $files $repository
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il repository e l'elemento" {
            Get-Issues $res.Output | Where-Object { $_ -match ([regex]::Escape($repository)) -and $_ -match ([regex]::Escape($elemento)) } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il modello non cambia" {
            $res.Generated["$($repository.ToLower()).dsl"] | Should -Be $previousFile
        }
    }

    Context "Scenario: parte generata modificata a mano" {
        BeforeAll {
            $files = New-BffRepository
            $first = Invoke-Generation $files 'Contoso.Shop.Bff.Web'
            $files['docs/architecture/model/generated/contoso.shop.bff.web.dsl'] = $first.Generated['contoso.shop.bff.web.dsl'] -replace '"Web.BusinessLogic"', '"Logica"'
            $res = Invoke-Generation $files 'Contoso.Shop.Bff.Web' 'check'
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la parte generata di ""Contoso.Shop.Bff.Web""" {
            Get-Issues $res.Output | Where-Object { $_ -match 'contoso\.shop\.bff\.web\.dsl' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: parte generata allineata al codice" {
        BeforeAll {
            $files = New-BffRepository
            $first = Invoke-Generation $files 'Contoso.Shop.Bff.Web'
            $first.Generated.Keys | ForEach-Object { $files["docs/architecture/model/generated/$_"] = $first.Generated[$_] }
            $res = Invoke-Generation $files 'Contoso.Shop.Bff.Web' 'check'
        }

        It "Allora la verifica passa" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }

    Context "Scenario: la parte generata e' un modello Structurizr valido" {
        BeforeAll {
            $engine = (Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI').Generated['contoso.shop.ai.dsl']
            $client = (Invoke-Generation (New-ClientRepository) 'Contoso.Shop.Client.Web').Generated['contoso.shop.client.web.dsl']
            $dir = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-code-dsl-$(New-Guid)"
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'generated') | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'generated/contoso.shop.ai.dsl'), $engine)
            [IO.File]::WriteAllText((Join-Path $dir 'generated/contoso.shop.client.web.dsl'), $client)
            [IO.File]::WriteAllText((Join-Path $dir 'workspace.dsl'), "workspace {`n    model {`n        sistema = softwareSystem `"Contoso.Shop`" {`n            !include generated/contoso.shop.ai.dsl`n            !include generated/contoso.shop.client.web.dsl`n        }`n    }`n}`n")
            $export = Export-StructurizrWorkspace (Join-Path $dir 'workspace.dsl')
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }

        It "Allora il workspace che la include si esporta senza errori" {
            $export.Error | Should -BeNullOrEmpty
        }

        It "E i componenti generati portano il tag dei generati" {
            $components = @($export.Workspace.model.softwareSystems[0].containers | ForEach-Object { @($_.components) })
            $components | Where-Object { ($_.tags -split ',') -notcontains 'Generato' } | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: un file di progetto che nessun lettore della composizione legge" {
        BeforeAll {
            $files = New-EngineRepository
            $files['docs/architecture/model/generated/contoso.shop.ai.dsl'] = "# parte precedente`n"
            $res = Invoke-C4Generation $files 'Contoso.Shop.AI' @('angular18')
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il file di progetto non letto" {
            Get-Issues $res.Output | Where-Object { $_ -match 'Contoso\.Shop\.AI\.Api/Contoso\.Shop\.AI\.Api\.csproj' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il modello non cambia" {
            $res.Generated['contoso.shop.ai.dsl'] | Should -Be "# parte precedente`n"
        }
    }

    Context "Scenario: un frammento che non si legge" {
        BeforeAll {
            $res = Invoke-C4Generation (New-BffRepository) 'Contoso.Shop.Bff.Web' @('dotnet10') -Fragments @{ 'contoso.shop.bff.web.terraform.json' = '{ non e'' json' }
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il frammento" {
            Get-Issues $res.Output | Where-Object { $_ -match 'contoso\.shop\.bff\.web\.terraform\.json' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: i frammenti di un altro repository non entrano nella parte generata" {
        BeforeAll {
            $other = '{ "manifests": [], "containers": [ { "id": "contoso_shop_ai_tools_x", "name": "X", "codeName": "Contoso.Shop.AI.Tools.X", "technology": ".NET", "tags": [], "properties": {}, "components": [] } ], "relationships": [] }'
            $res = Invoke-C4Generation (New-EngineRepository) 'Contoso.Shop.AI' @('dotnet10') -Fragments @{ 'contoso.shop.ai.tools.dotnet10.json' = $other }
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la parte generata non contiene il container dell'altro repository" {
            $res.Generated['contoso.shop.ai.dsl'] | Should -Not -Match 'Tools\.X'
        }
    }

    Context "Scenario: un repository senza applicazioni" {
        BeforeAll {
            $res = Invoke-C4Generation ([ordered]@{ 'source/README.md' = "# Strumenti`n" }) 'Contoso.Shop.Client.Web' @('angular18')
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E dice che nessuna applicazione e' riconosciuta" {
            Get-Issues $res.Output | Where-Object { $_ -match 'nessuna applicazione riconosciuta' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E non scrive la parte generata" {
            $res.Generated.Keys | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: un lettore scritto nel repository del consumer si compone con gli altri" {
        BeforeAll {
            $files = New-BffRepository
            $files['source/infra/storage.tf'] = "resource `"azurerm_storage_account`" `"x`" {}`n"
            $res = Invoke-C4Generation $files 'Contoso.Shop.Bff.Web' @('dotnet10', 'consumer')
            $dsl = $res.Generated['contoso.shop.bff.web.dsl']
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la parte generata contiene il container del lettore del consumer" {
            Get-ElementLine $dsl 'container' 'storage' | Should -Not -BeNullOrEmpty -Because $dsl
        }

        It "E la parte generata contiene ancora il container .NET" {
            Get-ElementLine $dsl 'container' 'Web' | Should -Not -BeNullOrEmpty -Because $dsl
        }

        It "E il container del lettore del consumer sta nel gruppo di ""Contoso.Shop.Bff.Web""" {
            Get-Block $dsl 'group\s+"Bff.Web"' | Should -Match 'container\s+"storage"' -Because $dsl
        }

        It "E il container .NET sta nel gruppo di ""Contoso.Shop.Bff.Web""" {
            Get-Block $dsl 'group\s+"Bff.Web"' | Should -Match 'container\s+"Web"' -Because $dsl
        }
    }
}
