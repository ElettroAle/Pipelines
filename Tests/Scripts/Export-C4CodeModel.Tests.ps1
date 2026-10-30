#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Export-C4CodeModel.ps1 e per la composizione dei lettori

.DESCRIPTION
    Ogni scenario costruisce un repository sorgente finto (progetti .NET o un'applicazione Angular),
    esegue i lettori delle sue tecnologie e poi lo scrittore, come in pipeline. Lo scenario che
    controlla la validita' del DSL richiede Java 17 o successivo (STRUCTURIZR_JAVA, JAVA_HOME_17_X64 o
    JAVA_HOME).
#>

BeforeAll {
    . "$PSScriptRoot/../Fixtures/C4/C4CodeFixture.ps1"
    . "$PSScriptRoot/../../V3/CI/Scripts/Common/Diagrams/Structurizr.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-code-$(New-Guid)"

    function Invoke-Generation([System.Collections.IDictionary]$Files, [string]$Repository, [string]$Mode = 'write') {
        $readers = @{ 'Aidea.Dxp.AI' = 'dotnet10'; 'Aidea.Dxp.Bff.Web' = 'dotnet10'; 'Aidea.Dxp.Client.Web' = 'angular18' }
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
            $res = Invoke-Generation (New-EngineRepository) 'Aidea.Dxp.AI'
            $dsl = $res.Generated['aidea.dxp.ai.dsl']
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello contiene il container ""Api"" nel gruppo di ""Aidea.Dxp.AI""" {
            Get-Block $dsl 'group\s+"AI"' | Should -Match 'container\s+"Api"'
        }

        It "E il modello contiene il container ""Worker"" nel gruppo di ""Aidea.Dxp.AI""" {
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
            $dsl | Should -Match 'aidea_dxp_ai_api__aidea_dxp_ai_dataaccess_azureservicebus\s+->\s+aidea_dxp_ai_api__aidea_dxp_ai_usecase_writtenconversations'
        }

        It "E un'applicazione e' componente di se stessa" {
            Get-ContainerBlock $dsl 'Api' | Should -Match 'component\s+"Api"'
        }
    }

    Context "Scenario: test e strumenti non entrano nel modello" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Aidea.Dxp.AI'
            $dsl = $res.Generated['aidea.dxp.ai.dsl']
        }

        It "Allora il modello non contiene ""Aidea.Dxp.AI.UnitTest.Engine""" {
            $dsl | Should -Not -Match 'UnitTest\.Engine'
        }

        It "E il modello non contiene ""Aidea.Dxp.AI.Utils.Reflection""" {
            $dsl | Should -Not -Match 'Utils\.Reflection'
        }

        It "E il modello non contiene ""Aidea.Dxp.AI.Evals""" {
            $dsl | Should -Not -Match 'Evals'
        }
    }

    Context "Schema dello scenario: nome senza il prefisso comune del repository — <progetto>" -ForEach @(
        @{ repository = 'Aidea.Dxp.AI'; progetto = 'Aidea.Dxp.AI.UseCase.WrittenConversations'; nome = 'UseCase.WrittenConversations'; kind = 'component' }
        @{ repository = 'Aidea.Dxp.AI'; progetto = 'Aidea.Dxp.AI.Api'; nome = 'Api'; kind = 'container' }
        @{ repository = 'Aidea.Dxp.Bff.Web'; progetto = 'Aidea.Dxp.Bff.Web'; nome = 'Web'; kind = 'container' }
        @{ repository = 'Aidea.Dxp.Bff.Web'; progetto = 'Aidea.Dxp.Bff.Web.BusinessLogic'; nome = 'Web.BusinessLogic'; kind = 'component' }
    ) {
        BeforeAll {
            $files = if ($repository -eq 'Aidea.Dxp.AI') { New-EngineRepository } else { New-BffRepository }
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
            $res = Invoke-Generation (New-ClientRepository) 'Aidea.Dxp.Client.Web'
            $dsl = $res.Generated['aidea.dxp.client.web.dsl']
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
            $files['docs/architecture/model/generated/aidea.dxp.ai.dsl'] = 'container "DataAccess.Twilio"'
            $res = Invoke-Generation $files 'Aidea.Dxp.AI'
        }

        It "Allora il modello non contiene ""Aidea.Dxp.AI.DataAccess.Twilio""" {
            $res.Generated['aidea.dxp.ai.dsl'] | Should -Not -Match 'Twilio'
        }
    }

    Context "Scenario: la generazione cambia solo la parte del repository integrato" {
        BeforeAll {
            $files = New-BffRepository
            $files['docs/architecture/model/generated/aidea.dxp.ai.dsl'] = "# parte del Motore`n"
            $res = Invoke-Generation $files 'Aidea.Dxp.Bff.Web'
        }

        It "Allora cambia la parte generata di ""Aidea.Dxp.Bff.Web""" {
            $res.Generated['aidea.dxp.bff.web.dsl'] | Should -Match 'container\s+"Web"'
        }

        It "E la parte generata di ""Aidea.Dxp.AI"" resta com'era" {
            $res.Generated['aidea.dxp.ai.dsl'] | Should -Be "# parte del Motore`n"
        }
    }

    Context "Schema dello scenario: caso non riconosciuto — <elemento>" -ForEach @(
        @{
            repository = 'Aidea.Dxp.Client.Web'; elemento = 'portal'
            Build      = { $f = [ordered]@{}; $f['source/portal/package.json'] = '{ "name": "portal", "dependencies": { "react": "^18.0.0" } }'; $f }
        }
        @{
            repository = 'Aidea.Dxp.AI'; elemento = 'Aidea.Dxp.AI.Console'
            Build      = { $f = New-EngineRepository; Add-Project $f 'Aidea.Dxp.AI.Console' (New-Project 'Microsoft.NET.Sdk.BlazorWebAssembly'); $f }
        }
        @{
            repository = 'Aidea.Dxp.AI'; elemento = 'Aidea.Dxp.AI.Utils (net8.0)'
            Build      = { $f = New-EngineRepository; Add-Project $f 'Aidea.Dxp.AI.Utils' ((New-Project) -replace 'net10\.0', 'net8.0'); $f }
        }
        @{
            repository = 'Aidea.Dxp.Client.Web'; elemento = 'ui-kit'
            Build      = { $f = New-ClientRepository; $f['source/angular.json'] = '{ "projects": { "aidea-dxp-client-web": { "projectType": "application", "sourceRoot": "src" }, "ui-kit": { "projectType": "library", "sourceRoot": "projects/ui-kit/src" } } }'; $f }
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
            $first = Invoke-Generation $files 'Aidea.Dxp.Bff.Web'
            $files['docs/architecture/model/generated/aidea.dxp.bff.web.dsl'] = $first.Generated['aidea.dxp.bff.web.dsl'] -replace '"Web.BusinessLogic"', '"Logica"'
            $res = Invoke-Generation $files 'Aidea.Dxp.Bff.Web' 'check'
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la parte generata di ""Aidea.Dxp.Bff.Web""" {
            Get-Issues $res.Output | Where-Object { $_ -match 'aidea\.dxp\.bff\.web\.dsl' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: parte generata allineata al codice" {
        BeforeAll {
            $files = New-BffRepository
            $first = Invoke-Generation $files 'Aidea.Dxp.Bff.Web'
            $files['docs/architecture/model/generated/aidea.dxp.bff.web.dsl'] = $first.Generated['aidea.dxp.bff.web.dsl']
            $res = Invoke-Generation $files 'Aidea.Dxp.Bff.Web' 'check'
        }

        It "Allora la verifica passa" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }

    Context "Scenario: la parte generata e' un modello Structurizr valido" {
        BeforeAll {
            $engine = (Invoke-Generation (New-EngineRepository) 'Aidea.Dxp.AI').Generated['aidea.dxp.ai.dsl']
            $client = (Invoke-Generation (New-ClientRepository) 'Aidea.Dxp.Client.Web').Generated['aidea.dxp.client.web.dsl']
            $dir = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-code-dsl-$(New-Guid)"
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'generated') | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'generated/aidea.dxp.ai.dsl'), $engine)
            [IO.File]::WriteAllText((Join-Path $dir 'generated/aidea.dxp.client.web.dsl'), $client)
            [IO.File]::WriteAllText((Join-Path $dir 'workspace.dsl'), "workspace {`n    model {`n        sistema = softwareSystem `"Aidea.Dxp`" {`n            !include generated/aidea.dxp.ai.dsl`n            !include generated/aidea.dxp.client.web.dsl`n        }`n    }`n}`n")
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
            $files['docs/architecture/model/generated/aidea.dxp.ai.dsl'] = "# parte precedente`n"
            $res = Invoke-C4Generation $files 'Aidea.Dxp.AI' @('angular18')
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il file di progetto non letto" {
            Get-Issues $res.Output | Where-Object { $_ -match 'Aidea\.Dxp\.AI\.Api/Aidea\.Dxp\.AI\.Api\.csproj' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il modello non cambia" {
            $res.Generated['aidea.dxp.ai.dsl'] | Should -Be "# parte precedente`n"
        }
    }

    Context "Scenario: un frammento che non si legge" {
        BeforeAll {
            $res = Invoke-C4Generation (New-BffRepository) 'Aidea.Dxp.Bff.Web' @('dotnet10') -Fragments @{ 'aidea.dxp.bff.web.terraform.json' = '{ non e'' json' }
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il frammento" {
            Get-Issues $res.Output | Where-Object { $_ -match 'aidea\.dxp\.bff\.web\.terraform\.json' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: i frammenti di un altro repository non entrano nella parte generata" {
        BeforeAll {
            $other = '{ "manifests": [], "containers": [ { "id": "aidea_dxp_ai_tools_x", "name": "X", "codeName": "Aidea.Dxp.AI.Tools.X", "technology": ".NET", "tags": [], "properties": {}, "components": [] } ], "relationships": [] }'
            $res = Invoke-C4Generation (New-EngineRepository) 'Aidea.Dxp.AI' @('dotnet10') -Fragments @{ 'aidea.dxp.ai.tools.dotnet10.json' = $other }
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la parte generata non contiene il container dell'altro repository" {
            $res.Generated['aidea.dxp.ai.dsl'] | Should -Not -Match 'Tools\.X'
        }
    }

    Context "Scenario: un repository senza applicazioni" {
        BeforeAll {
            $res = Invoke-C4Generation ([ordered]@{ 'source/README.md' = "# Strumenti`n" }) 'Aidea.Dxp.Client.Web' @('angular18')
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
            $res = Invoke-C4Generation $files 'Aidea.Dxp.Bff.Web' @('dotnet10', 'consumer')
            $dsl = $res.Generated['aidea.dxp.bff.web.dsl']
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

        It "E il container del lettore del consumer sta nel gruppo di ""Aidea.Dxp.Bff.Web""" {
            Get-Block $dsl 'group\s+"Bff.Web"' | Should -Match 'container\s+"storage"' -Because $dsl
        }

        It "E il container .NET sta nel gruppo di ""Aidea.Dxp.Bff.Web""" {
            Get-Block $dsl 'group\s+"Bff.Web"' | Should -Match 'container\s+"Web"' -Because $dsl
        }
    }
}
