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

    function Invoke-Generation([System.Collections.IDictionary]$Files, [string]$Repository, [string]$Mode = 'write') {
        $readers = @{ 'Contoso.Shop.AI' = 'dotnet10'; 'Contoso.Shop.Bff.Web' = 'dotnet10'; 'Contoso.Shop.Client.Web' = 'angular18' }
        return Invoke-C4Generation $Files $Repository @($readers[$Repository]) $Mode
    }

    # Il frammento che il lettore .NET lascia per il BFF che si avvia agli indirizzi dati.
    function Get-BffFragment([string[]]$Urls) {
        $bff = Invoke-C4Reader (Add-LaunchSettings (New-BffRepository) 'Contoso.Shop.Bff.Web' $Urls) 'Contoso.Shop.Bff.Web' 'dotnet10'
        return @($bff.Fragments.Values)[0]
    }

    function New-ProxiedClient {
        return Add-DevProxy (New-ClientRepository) @{ '/api' = 'https://localhost:5001/'; '/hubs' = 'https://LOCALHOST:5001' }
    }

    function Get-ComponentViewOpening([string]$Scope, [string]$Key, [string]$Kind = 'component') {
        return "(?m)^$Kind $Scope `"$Key`" \{"
    }

    # La descrizione di una vista: la proprieta' description del suo blocco, che il disegno non mostra.
    function Get-ViewDescription([string]$Views, [string]$Declaration, [string]$Key) {
        $block = Get-Block $Views "^$([regex]::Escape($Declaration)) `"$([regex]::Escape($Key))`" \{"
        $match = [regex]::Match($block, '(?m)^\s*"description" "([^"]*)"\s*$')
        if (-not $match.Success) { return $null }
        return $match.Groups[1].Value
    }
}


Describe "Funzionalità: Modello C4 generato dal codice" {

    Context "Schema dello scenario: elementi e relazioni nati dal codice .NET" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI'
            $dsl = $res.Generated['containers/contoso.shop.ai.dsl']
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

        It "E le viste della parte hanno la vista dei componenti di ""Api""" {
            $res.Generated['views/contoso.shop.ai.dsl'] | Should -Match (Get-ComponentViewOpening 'contoso_shop_ai_api' 'contoso_shop_ai_api')
        }

        It "E le viste della parte hanno la vista dei componenti di ""Worker""" {
            $res.Generated['views/contoso.shop.ai.dsl'] | Should -Match (Get-ComponentViewOpening 'contoso_shop_ai_worker' 'contoso_shop_ai_worker')
        }
    }

    Context "Schema dello scenario: viste dei componenti per livello" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI'
            $views = $res.Generated['views/contoso.shop.ai.dsl']
            $logic = Get-Block $views (Get-ComponentViewOpening 'contoso_shop_ai_api' 'contoso_shop_ai_api')
            $dataAccess = Get-Block $views (Get-ComponentViewOpening 'contoso_shop_ai_api' 'contoso_shop_ai_api-accesso-dati')
        }

        It "Allora la vista della logica di ""Api"" mostra ""UseCase.WrittenConversations""" {
            $logic | Should -Match 'contoso_shop_ai_api__contoso_shop_ai_usecase_writtenconversations\b' -Because $views
        }

        It "E la vista della logica di ""Api"" non mostra i componenti di accesso ai dati" {
            (@($logic -split "`n" | Where-Object { $_ -match '^\s*include ' }) -join "`n") | Should -Not -Match 'dataaccess' -Because $views
        }

        It "E la vista dell'accesso ai dati di ""Api"" mostra ""DataAccess.AzureServiceBus"" e ""DataAccess.AzureStorageAccount""" {
            $dataAccess | Should -Match 'contoso_shop_ai_api__contoso_shop_ai_dataaccess_azureservicebus\b' -Because $views
            $dataAccess | Should -Match 'contoso_shop_ai_api__contoso_shop_ai_dataaccess_azurestorageaccount\b' -Because $views
        }

        It "E la vista dell'accesso ai dati di ""Api"" mostra ""UseCase.WrittenConversations"", che ""DataAccess.AzureServiceBus"" usa" {
            $dataAccess | Should -Match 'contoso_shop_ai_api__contoso_shop_ai_usecase_writtenconversations\b' -Because $views
        }

        It "E la vista dell'accesso ai dati di ""Api"" non mostra ""Api"", che li chiama dallo stesso container" {
            $dataAccess | Should -Not -Match 'contoso_shop_ai_api__contoso_shop_ai_api\b' -Because $views
        }

        It "E ""Worker"", senza componenti di accesso ai dati, ha solo la vista della logica" {
            $views | Should -Match (Get-ComponentViewOpening 'contoso_shop_ai_worker' 'contoso_shop_ai_worker')
            $views | Should -Not -Match 'contoso_shop_ai_worker-accesso-dati'
        }
    }

    Context "Scenario: la descrizione di ogni vista dei container e dei componenti nasce dal suo contenuto con le frasi della lingua (ADR-2140)" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI'
            $views = $res.Generated['views/contoso.shop.ai.dsl']
        }

        It "Allora la vista dei container di un'applicazione nomina l'applicazione" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
            Get-ViewDescription $views 'container sistema' 'container-contoso_shop_ai_api' | Should -Be 'Le relazioni di Api con il resto del sistema.'
        }

        It "E la vista della logica nomina i suoi componenti e, con il loro testo, le relazioni che ne escono e vi entrano" {
            Get-ViewDescription $views 'component contoso_shop_ai_api' 'contoso_shop_ai_api' |
                Should -Be 'Componenti della logica di Api: Api, UseCase.WrittenConversations, Utils. Si rivolgono a DataAccess.AzureServiceBus, DataAccess.AzureStorageAccount. Ricevono le richieste di DataAccess.AzureServiceBus.'
        }

        It "E la vista dell'accesso ai dati nomina i suoi componenti e chi li usa" {
            Get-ViewDescription $views 'component contoso_shop_ai_api' 'contoso_shop_ai_api-accesso-dati' |
                Should -Be "Componenti dell'accesso ai dati di Api: DataAccess.AzureServiceBus, DataAccess.AzureStorageAccount. Si rivolgono a UseCase.WrittenConversations. Usati da Api."
        }

        It "E una frase con un elenco vuoto non si scrive" {
            Get-ViewDescription $views 'component contoso_shop_ai_worker' 'contoso_shop_ai_worker' | Should -Be 'Componenti della logica di Worker: UseCase.WrittenConversations, Worker.'
        }

        It "E la descrizione sta nella proprieta' della vista e non nella vista, che il disegno mostra sotto il titolo" {
            $views | Should -Not -Match '(?m)^(container|component) \S+ "[^"]+" "'
            $views | Should -Not -Match '\\n'
        }

        It "E viste diverse hanno descrizioni diverse" {
            $descriptions = @([regex]::Matches($views, '"description" "([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
            $descriptions.Count | Should -Be 5
            @($descriptions | Sort-Object -Unique).Count | Should -Be $descriptions.Count
        }
    }

    Context "Scenario: ogni vista ha un titolo suo, fatto dai nomi delle parti che mostra" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI'
            $views = $res.Generated['views/contoso.shop.ai.dsl']
        }

        It "Allora la vista dei container di un'applicazione ha il titolo della lingua con il nome dell'applicazione" {
            Get-Block $views (Get-ComponentViewOpening 'sistema' 'container-contoso_shop_ai_api' 'container') | Should -Match '\n    title "Container di Api"\n'
        }

        It "E la vista della logica ha il nome del container e il livello della lingua" {
            Get-Block $views (Get-ComponentViewOpening 'contoso_shop_ai_api' 'contoso_shop_ai_api') | Should -Match '\n    title "Api · logica"\n'
        }

        It "E la vista dell'accesso ai dati ha il nome del container e il livello della lingua" {
            Get-Block $views (Get-ComponentViewOpening 'contoso_shop_ai_api' 'contoso_shop_ai_api-accesso-dati') | Should -Match '\n    title "Api · accesso ai dati"\n'
        }

        It "E in inglese titoli e frasi delle descrizioni vengono dalla lingua del documento" {
            $english = (Invoke-C4Generation (New-EngineRepository) 'Contoso.Shop.AI' @('dotnet10') -Environment @{ DOCUMENT_LANGUAGE = 'EN' }).Generated['views/contoso.shop.ai.dsl']
            Get-ViewDescription $english 'component contoso_shop_ai_api' 'contoso_shop_ai_api' |
                Should -Be 'Logic components of Api: Api, UseCase.WrittenConversations, Utils. They turn to DataAccess.AzureServiceBus, DataAccess.AzureStorageAccount. They receive the requests of DataAccess.AzureServiceBus.'
            Get-ViewDescription $english 'container sistema' 'container-contoso_shop_ai_api' | Should -Be 'The relationships of Api with the rest of the system.'
            $english | Should -Match ([regex]::Escape('title "Containers of Api"'))
            $english | Should -Match ([regex]::Escape('title "Api · logic"'))
        }
    }

    Context "Scenario: i segmenti dei componenti di accesso ai dati scelti dal consumer" {
        BeforeAll {
            $res = Invoke-C4Generation (New-EngineRepository) 'Contoso.Shop.AI' @('dotnet10') -Environment @{ C4_DATA_ACCESS_SEGMENTS = 'Utils, UseCase' }
            $views = $res.Generated['views/contoso.shop.ai.dsl']
        }

        It "Allora la vista dell'accesso ai dati di ""Api"" mostra ""Utils"" e ""UseCase.WrittenConversations""" {
            $block = Get-Block $views (Get-ComponentViewOpening 'contoso_shop_ai_api' 'contoso_shop_ai_api-accesso-dati')
            $block | Should -Match 'contoso_shop_ai_api__contoso_shop_ai_utils\b' -Because $views
            $block | Should -Match 'contoso_shop_ai_api__contoso_shop_ai_usecase_writtenconversations\b' -Because $views
        }

        It "E la vista della logica di ""Api"" mostra ""DataAccess.AzureServiceBus""" {
            Get-Block $views (Get-ComponentViewOpening 'contoso_shop_ai_api' 'contoso_shop_ai_api') | Should -Match 'contoso_shop_ai_api__contoso_shop_ai_dataaccess_azureservicebus\b' -Because $views
        }
    }

    Context "Scenario: una vista dei container per ogni applicazione del repository" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI'
            $views = $res.Generated['views/contoso.shop.ai.dsl']
            $api = Get-Block $views (Get-ComponentViewOpening 'sistema' 'container-contoso_shop_ai_api' 'container')
            $worker = Get-Block $views (Get-ComponentViewOpening 'sistema' 'container-contoso_shop_ai_worker' 'container')
        }

        It "Allora ogni vista appartiene al sistema che nel workspace include i container generati, con la chiave dell'applicazione" {
            $api | Should -Not -BeNullOrEmpty -Because $views
            $worker | Should -Not -BeNullOrEmpty -Because $views
        }

        It "E ogni vista mostra la sua applicazione con gli elementi con cui ha relazioni" {
            $api | Should -Match '(?m)^\s*include ->contoso_shop_ai_api->\s*$' -Because $api
            $worker | Should -Match '(?m)^\s*include ->contoso_shop_ai_worker->\s*$' -Because $worker
        }

        It "E nessuna vista raccoglie tutte le applicazioni del repository" {
            $views | Should -Not -Match '"container-ai"' -Because $views
        }
    }

    Context "Scenario: workspace senza il sistema che include i container generati" {
        BeforeAll {
            $files = New-EngineRepository
            $files['docs/architecture/c4/workspace.dsl'] = "workspace {`n    model {`n        sistema = softwareSystem `"Contoso.Shop`"`n    }`n}`n"
            $res = Invoke-Generation $files 'Contoso.Shop.AI'
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il workspace" {
            Get-Issues $res.Output | Where-Object { $_ -match 'sistema che include le parti generate non trovato' -and $_ -match 'workspace\.dsl' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: un repository senza applicazioni non ha la vista dei container" {
        BeforeAll {
            $container = [ordered]@{ id = 'contoso_shop_infrastructure_db'; name = 'db'; codeName = 'db'; technology = 'SQL'; tags = @(); components = @() }
            $fragment = [ordered]@{ manifests = @(); containers = @($container); relationships = @(); addresses = @(); calls = @() } | ConvertTo-Json -Depth 5
            $files = [ordered]@{ 'source/README.md' = "x`n"; 'docs/architecture/c4/workspace.dsl' = $null }
            $res = Invoke-C4Generation $files 'Contoso.Shop.Infrastructure' @() -Fragments @{ 'contoso.shop.infrastructure.azure.json' = $fragment }
        }

        It "Allora la generazione riesce anche senza workspace" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E le viste della parte non hanno viste dei container" {
            $res.Generated['views/contoso.shop.infrastructure.dsl'] | Should -Not -Match '(?m)^container ' -Because ($res.Generated['views/contoso.shop.infrastructure.dsl'])
        }
    }

    Context "Scenario: test e strumenti non entrano nel modello" {
        BeforeAll {
            $res = Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI'
            $dsl = $res.Generated['containers/contoso.shop.ai.dsl']
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
            $dsl = $res.Generated["containers/$($repository.ToLowerInvariant()).dsl"]
        }

        It "Allora l'elemento del progetto si chiama <nome>" {
            Get-ElementLine $dsl $kind $nome | Should -Not -BeNullOrEmpty -Because $dsl
        }

        It "E l'elemento porta <progetto> come nome completo" {
            $dsl | Should -Match ([regex]::Escape("`"codice`" `"$progetto`""))
        }
    }

    Context "Scenario: un'applicazione si chiama senza il prefisso comune a tutte le applicazioni del sistema" {
        BeforeAll {
            $client = Invoke-C4Reader (New-ClientRepository) 'Contoso.Shop.Client.Web' 'angular18'
            $fragments = @{ 'contoso.shop.client.web.angular18.json' = @($client.Fragments.Values)[0] }
            $res = Invoke-C4Generation (New-BffRepository) 'Contoso.Shop.Bff.Web' @('dotnet10') -Fragments $fragments
            $dsl = $res.Generated['containers/contoso.shop.bff.web.dsl']
        }

        It "Allora l'applicazione del BFF si chiama Bff.Web" {
            Get-ElementLine $dsl 'container' 'Bff.Web' | Should -Not -BeNullOrEmpty -Because $dsl
        }

        It "E i suoi componenti tengono il nome senza il prefisso comune del repository" {
            Get-ElementLine $dsl 'component' 'Web.BusinessLogic' | Should -Not -BeNullOrEmpty -Because $dsl
        }
    }

    Context "Schema dello scenario: elementi nati dall'applicazione Angular" {
        BeforeAll {
            $res = Invoke-Generation (New-ClientRepository) 'Contoso.Shop.Client.Web'
            $dsl = $res.Generated['containers/contoso.shop.client.web.dsl']
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
            $files['docs/architecture/c4/generated/containers/contoso.shop.ai.dsl'] = 'container "DataAccess.Twilio"'
            $res = Invoke-Generation $files 'Contoso.Shop.AI'
        }

        It "Allora il modello non contiene ""Contoso.Shop.AI.DataAccess.Twilio""" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Not -Match 'Twilio'
        }
    }

    Context "Scenario: la generazione cambia solo la parte del repository integrato" {
        BeforeAll {
            $files = New-BffRepository
            $files['docs/architecture/c4/generated/containers/contoso.shop.ai.dsl'] = "# parte del Motore`n"
            $res = Invoke-Generation $files 'Contoso.Shop.Bff.Web'
        }

        It "Allora cambia la parte generata di ""Contoso.Shop.Bff.Web""" {
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Match 'container\s+"Web"'
        }

        It "E la parte generata di ""Contoso.Shop.AI"" resta com'era" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Be "# parte del Motore`n"
        }

        It "E scrive il contesto dal testo di tutto il sistema" {
            $res.Generated['context.dsl'] | Should -Match '^// Persone e sistemi esterni del modello C4'
        }
    }

    Context "Scenario: persone e sistemi esterni dal testo di tutto il sistema" {
        BeforeAll {
            $text = [ordered]@{
                units           = [ordered]@{
                    contoso_shop_bff_web = [ordered]@{ basis = ''; elements = @{}; relationships = @{}; links = @(@{ source = 'cliente'; target = 'contoso_shop_bff_web'; description = 'Apre la chat'; technology = 'HTTPS' }) }
                    contoso_shop_ai_api  = [ordered]@{ basis = ''; elements = @{}; relationships = @{}; links = @(@{ source = 'contoso_shop_ai_api'; target = 'entra'; description = 'Valida i token'; technology = '' }) }
                }
                people          = [ordered]@{ cliente = @{ name = 'Cliente'; description = 'Scrive al negozio.'; technical = $false } }
                externalSystems = [ordered]@{ entra = @{ name = 'Entra External ID'; description = 'Autentica i clienti.'; technical = $true } }
            }
            $files = New-BffRepository
            $files['docs/architecture/c4/generated/model.text.json'] = $text | ConvertTo-Json -Depth 10
            $res = Invoke-Generation $files 'Contoso.Shop.Bff.Web'
        }

        It "Allora il contesto dichiara la persona" {
            $res.Generated['context.dsl'] | Should -Match 'cliente = person "Cliente" "Scrive al negozio\." ""'
        }

        It "E il contesto dichiara il sistema esterno con i suoi tag" {
            $res.Generated['context.dsl'] | Should -Match 'entra = softwareSystem "Entra External ID" "Autentica i clienti\." "Esterno,Tecnico"'
        }

        It "E la parte contiene solo le relazioni con persone e sistemi esterni dei suoi container" {
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Match 'cliente -> contoso_shop_bff_web "Apre la chat" "HTTPS"'
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Not -Match 'contoso_shop_ai_api -> entra'
        }

        It "E la descrizione della vista dei container nomina chi chiama l'applicazione, con il testo della relazione (ADR-2140)" {
            Get-ViewDescription $res.Generated['views/contoso.shop.bff.web.dsl'] 'container sistema' 'container-contoso_shop_bff_web' |
                Should -Be 'Le relazioni di Web con il resto del sistema. Riceve le richieste di Cliente (Apre la chat).'
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
            $files['docs/architecture/c4/generated/containers/x.dsl'] = $null
            $previousFile = "# parte precedente`n"
            $files["docs/architecture/c4/generated/containers/$($repository.ToLower()).dsl"] = $previousFile
            $res = Invoke-Generation $files $repository
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il repository e l'elemento" {
            Get-Issues $res.Output | Where-Object { $_ -match ([regex]::Escape($repository)) -and $_ -match ([regex]::Escape($elemento)) } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il modello non cambia" {
            $res.Generated["containers/$($repository.ToLower()).dsl"] | Should -Be $previousFile
        }
    }

    Context "Scenario: parte generata modificata a mano" {
        BeforeAll {
            $files = New-BffRepository
            $first = Invoke-Generation $files 'Contoso.Shop.Bff.Web'
            $files['docs/architecture/c4/generated/containers/contoso.shop.bff.web.dsl'] = $first.Generated['containers/contoso.shop.bff.web.dsl'] -replace '"Web.BusinessLogic"', '"Logica"'
            $res = Invoke-Generation $files 'Contoso.Shop.Bff.Web' 'check'
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la parte generata di ""Contoso.Shop.Bff.Web""" {
            Get-Issues $res.Output | Where-Object { $_ -match 'contoso\.shop\.bff\.web\.dsl' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: parte generata prima del file delle sue viste" {
        BeforeAll {
            $files = New-BffRepository
            $first = Invoke-Generation $files 'Contoso.Shop.Bff.Web'
            $files['docs/architecture/c4/generated/containers/contoso.shop.bff.web.dsl'] = $first.Generated['containers/contoso.shop.bff.web.dsl']
            $res = Invoke-Generation $files 'Contoso.Shop.Bff.Web' 'check'
        }

        It "Allora la verifica passa" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }

    Context "Scenario: parte generata allineata al codice" {
        BeforeAll {
            $files = New-BffRepository
            $first = Invoke-Generation $files 'Contoso.Shop.Bff.Web'
            $first.Generated.Keys | ForEach-Object { $files["docs/architecture/c4/generated/$_"] = $first.Generated[$_] }
            $res = Invoke-Generation $files 'Contoso.Shop.Bff.Web' 'check'
        }

        It "Allora la verifica passa" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }

    Context "Scenario: la parte generata e' un modello Structurizr valido" {
        BeforeAll {
            $engine = (Invoke-Generation (New-EngineRepository) 'Contoso.Shop.AI').Generated
            $client = (Invoke-Generation (New-ClientRepository) 'Contoso.Shop.Client.Web').Generated
            $dir = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-code-dsl-$(New-Guid)"
            foreach ($part in 'containers/contoso.shop.ai.dsl', 'views/contoso.shop.ai.dsl') { Write-SourceFiles $dir @{ "generated/$part" = $engine[$part] } }
            foreach ($part in 'containers/contoso.shop.client.web.dsl', 'views/contoso.shop.client.web.dsl') { Write-SourceFiles $dir @{ "generated/$part" = $client[$part] } }
            [IO.File]::WriteAllText((Join-Path $dir 'workspace.dsl'), $C4Workspace)
            $export = Export-StructurizrWorkspace (Join-Path $dir 'workspace.dsl')
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
        }

        It "Allora il workspace che la include si esporta senza errori" {
            $export.Error | Should -BeNullOrEmpty
        }

        It "E le viste generate dei container e dei componenti si esportano" {
            @($export.Workspace.views.containerViews | ForEach-Object key) | Should -Contain 'container-contoso_shop_ai_api'
            @($export.Workspace.views.componentViews | ForEach-Object key) | Should -Contain 'contoso_shop_ai_api-accesso-dati'
        }

        It "E le viste generate portano il loro titolo e, nella proprieta' che il disegno non mostra, la descrizione (ADR-2140)" {
            $view = $export.Workspace.views.componentViews | Where-Object key -EQ 'contoso_shop_ai_api-accesso-dati'
            $view.title | Should -Be 'Api · accesso ai dati'
            $view.description | Should -BeNullOrEmpty
            $view.properties.description | Should -BeLike "Componenti dell'accesso ai dati di Api: *"
            ($export.Workspace.views.containerViews | Where-Object key -EQ 'container-contoso_shop_ai_api').title | Should -Be 'Container di Api'
        }

        It "E i componenti generati portano il tag dei generati" {
            $components = @($export.Workspace.model.softwareSystems[0].containers | ForEach-Object { @($_.components) })
            $components | Where-Object { ($_.tags -split ',') -notcontains 'Generato' } | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: un file di progetto che nessun lettore della composizione legge" {
        BeforeAll {
            $files = New-EngineRepository
            $files['docs/architecture/c4/generated/containers/contoso.shop.ai.dsl'] = "# parte precedente`n"
            $res = Invoke-C4Generation $files 'Contoso.Shop.AI' @('angular18')
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il file di progetto non letto" {
            Get-Issues $res.Output | Where-Object { $_ -match 'Contoso\.Shop\.AI\.Api/Contoso\.Shop\.AI\.Api\.csproj' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il modello non cambia" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Be "# parte precedente`n"
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
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Not -Match 'Tools\.X'
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
            $dsl = $res.Generated['containers/contoso.shop.bff.web.dsl']
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

        It "E il container del lettore del consumer, senza componenti, non ha una vista dei componenti" {
            $res.Generated['views/contoso.shop.bff.web.dsl'] | Should -Not -Match 'component contoso_shop_bff_web_storage\b'
        }
    }

    Context "Schema dello scenario: elementi e relazioni nati dal codice — il proxy di sviluppo verso l'indirizzo di avvio di un'altra applicazione" {
        BeforeAll {
            $fragments = @{ 'contoso.shop.bff.web.dotnet10.json' = (Get-BffFragment @('https://localhost:5001;http://localhost:5000')) }
            $res = Invoke-C4Generation (New-ProxiedClient) 'Contoso.Shop.Client.Web' @('angular18') -Fragments $fragments
            $dsl = $res.Generated['containers/contoso.shop.client.web.dsl']
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello contiene la relazione dal container ""Client.Web"" al container ""Web"" di ""Contoso.Shop.Bff.Web""" {
            $dsl | Should -Match '(?m)^contoso_shop_client_web -> contoso_shop_bff_web ' -Because $dsl
        }

        It "E la relazione compare una volta sola" {
            @($dsl -split "`n" | Where-Object { $_ -match '^contoso_shop_client_web -> contoso_shop_bff_web ' }).Count | Should -Be 1
        }
    }

    Context "Scenario: la relazione del proxy di sviluppo sta nella parte dell'applicazione che chiama" {
        BeforeAll {
            $client = Invoke-C4Reader (New-ProxiedClient) 'Contoso.Shop.Client.Web' 'angular18'
            $fragments = @{ 'contoso.shop.client.web.angular18.json' = @($client.Fragments.Values)[0] }
            $res = Invoke-C4Generation (Add-LaunchSettings (New-BffRepository) 'Contoso.Shop.Bff.Web' @('https://localhost:5001')) 'Contoso.Shop.Bff.Web' @('dotnet10') -Fragments $fragments
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la parte dell'applicazione chiamata non contiene la relazione" {
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Not -Match 'contoso_shop_client_web ->'
        }
    }

    Context "Schema dello scenario: indirizzo del proxy di sviluppo che non porta a una sola applicazione — <caso>" -ForEach @(
        @{ caso = 'nessuna applicazione vi si avvia'; Fragments = { @{ 'contoso.shop.bff.web.dotnet10.json' = (Get-BffFragment @('https://localhost:7001')) } }; problema = 'indirizzo chiamato a cui nessuna applicazione si avvia' }
        @{ caso = 'due applicazioni vi si avviano'; Fragments = { @{ 'contoso.shop.bff.web.dotnet10.json' = (Get-BffFragment @('https://localhost:5001')); 'contoso.shop.ai.dotnet10.json' = ((Get-BffFragment @('https://localhost:5001')) -replace 'contoso_shop_bff_web', 'contoso_shop_ai_api') } }; problema = "indirizzo chiamato a cui si avvia piu' di un'applicazione" }
    ) {
        BeforeAll {
            $res = Invoke-C4Generation (New-ProxiedClient) 'Contoso.Shop.Client.Web' @('angular18') -Fragments (& $Fragments)
        }

        It "Allora la generazione fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il repository, l'indirizzo e il file del proxy" {
            Get-Issues $res.Output | Where-Object { $_ -match 'Contoso\.Shop\.Client\.Web' -and $_.Contains($problema) -and $_.Contains('https://localhost:5001') -and $_.Contains('proxy.conf.json') } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E non scrive la parte generata" {
            $res.Generated.Keys | Should -BeNullOrEmpty
        }
    }
}
