#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/Write-C4ModelText.ps1 e per il testo composto da Export-C4CodeModel.ps1

.DESCRIPTION
    Ogni scenario costruisce i repository sorgente finti di un sistema ed esegue, come in pipeline, i
    lettori di ogni repository, il generatore del testo di tutto il sistema e lo scrittore di ogni parte.
    Il modello e' sostituito da un endpoint locale (Tests/V3/CI/Scripts/C4/Fixtures/ModelTextStub.ps1)
    che descrive ogni elemento e ogni relazione della parte e lascia distinte le voci del catalogo, salvo
    le risposte cambiate dallo scenario; le prove verificano cosa il generatore manda al modello, quali
    stesure accetta, cosa corregge, cosa salva e cosa lo scrittore compone. Il testo vero del modello si
    giudica sul repository della documentazione. Lo scenario che controlla la validita' del DSL richiede
    Java 17 o successivo (STRUCTURIZR_JAVA, JAVA_HOME_17_X64 o JAVA_HOME).
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/C4CodeFixture.ps1"
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/Structurizr.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-text-tools-$(New-Guid)"

    $script:StubState = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-text-$(New-Guid)"
    New-Item -ItemType Directory -Path $StubState | Out-Null
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $script:StubEndpoint = "http://127.0.0.1:$port"
    $stubScript = Resolve-Path "$PSScriptRoot/Fixtures/ModelTextStub.ps1"
    $script:Stub = Start-ThreadJob -ArgumentList $StubEndpoint, $StubState, "$stubScript" -ScriptBlock {
        param($Endpoint, $State, $Script)
        & $Script $Endpoint $State
    }

    $Api = 'contoso_shop_ai_api'
    $Worker = 'contoso_shop_ai_worker'
    $Language = 'contoso_shop_ai_language'
    $Speech = 'contoso_shop_ai_speech'
    $Web = 'contoso_shop_bff_web'
    $Utils = 'contoso_shop_ai_api__contoso_shop_ai_utils'
    $UseCase = 'contoso_shop_ai_api__contoso_shop_ai_usecase_writtenconversations'
    $ServiceBus = 'contoso_shop_ai_api__contoso_shop_ai_dataaccess_azureservicebus'
    $Engine = 'Contoso.Shop.AI'
    $Bff = 'Contoso.Shop.Bff.Web'
    $Guide = "# Guida di stile`n`n## Regole`n`n### Niente riempitivi`n`nUn'espressione che non aggiunge informazione si toglie.`n"
    $Production = "sms_sender = `"+390000000`"`npayments_endpoint = `"https://pagamenti.example.com`"`n"
    $Decision = "# Canale eventi di sessione`n`n## Esito della decisione`n`nGli eventi viaggiano su Service Bus.`n"

    function Reset-Stub([hashtable]$Answers = @{}) {
        Get-ChildItem $StubState -File | Remove-Item -Force
        if ($Answers.Count) { [IO.File]::WriteAllText((Join-Path $StubState 'answers.json'), ($Answers | ConvertTo-Json -Depth 10)) }
    }

    function Set-StubStatus([int]$Status) {
        [IO.File]::WriteAllText((Join-Path $StubState 'status'), "$Status")
    }

    function Get-StubRequests {
        return @(Get-ChildItem $StubState -Filter 'request-*.json' | Sort-Object { [int]($_.BaseName -replace '\D', '') } | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    }

    function Get-UserMessage($Request) {
        return ($Request.messages | Where-Object role -EQ 'user').content
    }

    function Get-RequestedUnits {
        return @(Get-StubRequests | ForEach-Object { [regex]::Match((Get-UserMessage $_), 'PARTE DA DESCRIVERE: (\S+)').Groups[1].Value } | Where-Object { $_ })
    }

    function Get-UnitRequests([string]$Unit) {
        return @(Get-StubRequests | Where-Object { (Get-UserMessage $_) -match "PARTE DA DESCRIVERE: $Unit\b" })
    }

    function Get-ReviewRequests {
        return @(Get-StubRequests | Where-Object { (Get-UserMessage $_).Contains("CONFIGURAZIONE DI PRODUZIONE:`n") })
    }

    $Sms = @{ id = 'sms'; name = 'Gateway SMS'; description = 'Recapita gli SMS.'; technical = $false }
    $Payments = @{ id = 'pagamenti'; name = 'Servizio pagamenti'; description = 'Incassa i pagamenti.'; technical = $false }
    $SmsLink = @{ source = $Api; target = 'sms'; description = 'Invia gli SMS'; technology = 'HTTPS' }
    $PaymentsLink = @{ source = $Api; target = 'pagamenti'; description = 'Chiede i pagamenti'; technology = 'HTTPS' }
    $ApiExternals = @{ externalSystems = @($Sms, $Payments); links = @($SmsLink, $PaymentsLink) }

    function Get-FirstReviewMessage {
        return Get-UserMessage (Get-ReviewRequests | Select-Object -First 1)
    }

    function Get-CatalogueRequests {
        return @(Get-StubRequests | Where-Object { (Get-UserMessage $_).Contains("CATALOGO DA CONTROLLARE:`n") })
    }

    function Add-Sources([System.Collections.IDictionary]$Files, [string]$Repository, [System.Collections.IDictionary]$Repo) {
        $Repo.Keys | ForEach-Object { $Files["sources/$Repository/$($_ -replace '^source/', '')"] = $Repo[$_] }
        return $Files
    }

    function New-DescribedEngine {
        $engineFiles = New-EngineRepository
        $engineFiles['source/Contoso.Shop.AI.Api/Program.cs'] = "app.MapPost(`"/conversations`", SendMessage);`n"
        $files = Add-Sources ([ordered]@{}) $Engine $engineFiles
        $files["sources/$Engine/deploy/production.tfvars"] = $Production
        $files['docs/STYLE.md'] = $Guide
        $files['docs/decisions/0012-canale-eventi-di-sessione.md'] = $Decision
        return $files
    }

    function New-ResourcesFragment([string[]]$Ids) {
        return [ordered]@{
            manifests     = @()
            containers    = @($Ids | ForEach-Object { [ordered]@{ id = $_; name = 'lang-shop-prod'; codeName = 'lang-shop-prod'; sources = @(); technology = 'Language'; properties = [ordered]@{}; components = @() } })
            relationships = @($Ids | ForEach-Object { [ordered]@{ source = $Api; target = $_ } })
            addresses     = @()
            calls         = @()
        } | ConvertTo-Json -Depth 10
    }

    function New-DescribedSystem {
        return Add-Sources (New-DescribedEngine) $Bff (New-BffRepository)
    }

    function New-Workspace([System.Collections.IDictionary]$Files) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-text-ws-$(New-Guid)"
        Write-SourceFiles $root $Files
        return $root
    }

    function New-Step([string]$Script, [hashtable]$Variables, [string]$Repository) {
        $own = $Variables.Clone()
        $own['SOURCE_REPOSITORY'] = $Repository
        $own['SOURCE_DIRECTORY'] = "sources/$Repository"
        return @{ Script = $Script; Variables = $own }
    }

    # Readers dice i lettori di un repository: senza voce il repository si legge con il lettore .NET.
    function Invoke-Text([string]$Root, [string[]]$Repositories = @('Contoso.Shop.AI'), [hashtable]$Readers = @{}, [hashtable]$Environment = @{}) {
        $variables = @{
            SOURCE_DIRECTORY = ''; SOURCE_REPOSITORY = ''; SOURCE_REPOSITORIES = $C4SourceRepositories; SOURCES_DIRECTORY = 'sources'
            FRAGMENT_DIRECTORY = 'fragments'; GENERATED_DIRECTORY = 'docs/architecture/c4/generated'; GENERATION_MODE = 'write'; DOCUMENT_LANGUAGE = ''
            C4_TEXT_ENDPOINT = $StubEndpoint; C4_TEXT_MODEL = 'gpt-6-luna'; C4_TEXT_TOKEN = 'token-di-prova'; C4_TEXT_REASONING_EFFORT = ''
            C4_TEXT_MAX_DRAFTS = ''; C4_TEXT_CONTEXT = 'docs/decisions'; STYLE_GUIDE = 'docs/STYLE.md'; PROGRESS_BRANCH = ''
            READABILITY_MAX_WORDS = ''; READABILITY_ABBREVIATIONS = ''; GATE_MODE = ''; SYSTEM_ACCESSTOKEN = ''; C4_CORRECTIONS_FILE = 'corrections.md'
            C4_REVIEW_EVIDENCE = "$Engine/deploy"
        }
        $Environment.Keys | ForEach-Object { $variables[$_] = $Environment[$_] }
        $steps = @(foreach ($repository in $Repositories) {
                $own = if ($Readers.ContainsKey($repository)) { @($Readers[$repository]) } else { @('dotnet10') }
                $own | Where-Object { $_ } | ForEach-Object { New-Step $C4Readers[$_] $variables $repository }
            })
        $steps += @{ Script = 'C4/Write-C4ModelText.ps1'; Variables = $variables }
        $steps += @($Repositories | ForEach-Object { New-Step 'C4/Export-C4CodeModel.ps1' $variables $_ })
        Push-Location $Root
        try {
            $outputs = @()
            $exitCode = 0
            foreach ($step in $steps) {
                $result = Invoke-C4Script $step.Script $step.Variables
                $outputs += $result.Output
                $exitCode = $result.ExitCode
                if ($exitCode) { break }
            }
            $generated = Join-Path $Root 'docs/architecture/c4/generated'
            $textFile = Join-Path $generated 'model.text.json'
            $correctionsFile = Join-Path $Root 'corrections.md'
            return @{
                ExitCode    = $exitCode
                Output      = $outputs -join "`n"
                Generated   = Read-Directory $generated '*.dsl'
                Text        = if (Test-Path $textFile) { Get-Content -Raw $textFile | ConvertFrom-Json } else { $null }
                Corrections = if (Test-Path $correctionsFile) { Get-Content -Raw $correctionsFile } else { '' }
            }
        }
        finally { Pop-Location }
    }

    function Remove-Workspace([string]$Root) {
        Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue
    }

    function Invoke-Git([string]$Directory) {
        $out = git -C $Directory @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' '): $out" }
        return $out
    }

    function New-OriginWorkspace([System.Collections.IDictionary]$Files) {
        $origin = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-text-origin-$(New-Guid)"
        Invoke-Git ([IO.Path]::GetTempPath()) init -q --bare -b main $origin | Out-Null
        $seed = New-Workspace ([ordered]@{ 'docs/STYLE.md' = $Guide })
        Invoke-Git $seed init -q -b main | Out-Null
        Invoke-Git $seed -c user.name=Prova -c user.email=prova@example.com commit -q --allow-empty -m 'seed' | Out-Null
        Invoke-Git $seed add -A | Out-Null
        Invoke-Git $seed -c user.name=Prova -c user.email=prova@example.com commit -q -m 'docs' | Out-Null
        Invoke-Git $seed push -q $origin main | Out-Null
        Remove-Workspace $seed
        return $origin
    }

    function New-Clone([string]$Origin, [System.Collections.IDictionary]$Files) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-text-clone-$(New-Guid)"
        Invoke-Git ([IO.Path]::GetTempPath()) clone -q $Origin $root | Out-Null
        Write-SourceFiles $root $Files
        return $root
    }

    function Get-OriginText([string]$Origin, [string]$Branch) {
        return (git -C $Origin show "${Branch}:docs/architecture/c4/generated/model.text.json" 2>$null) -join "`n" | ConvertFrom-Json
    }
}

AfterAll {
    New-Item -ItemType File -Path (Join-Path $StubState 'stop') -Force | Out-Null
    $Stub | Wait-Job -Timeout 10 | Out-Null
    $Stub | Remove-Job -Force
    Remove-Item -Recurse -Force $StubState -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}


Describe "Funzionalità: Testo del modello C4 scritto dal generatore" {

    Context "Scenario: modello generato e descritto" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            $dsl = $res.Generated['containers/contoso.shop.ai.dsl']
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il container ""Api"" ha una descrizione" {
            Get-ElementLine $dsl 'container' 'Api' | Should -Match "container `"Api`" `"Descrizione di $Api\.`"" -Because $dsl
        }

        It "E il componente ""UseCase.WrittenConversations"" ha una descrizione" {
            Get-ContainerBlock $dsl 'Api' | Should -Match "component `"UseCase.WrittenConversations`" `"Descrizione di $UseCase\.`"" -Because $dsl
        }

        It "E la relazione fra ""DataAccess.AzureServiceBus"" e ""UseCase.WrittenConversations"" dice cio' che passa" {
            $dsl | Should -Match "$ServiceBus -> $UseCase `"Passa da $ServiceBus a $UseCase`" `"chiamata`"" -Because $dsl
        }

        It "E il testo accettato resta nel testo del sistema" {
            $res.Text.units.$Api.elements.$Api | Should -Be "Descrizione di $Api."
        }

        It "E non ci sono correzioni da elencare" {
            $res.Corrections | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: cosa il generatore manda al modello" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedSystem)
            $res = Invoke-Text $root @($Engine, $Bff)
            Remove-Workspace $root
            $apiRequest = Get-UnitRequests $Api | Select-Object -First 1
        }

        It "Allora chiede un container per richiesta" {
            Get-RequestedUnits | Sort-Object | Should -Be @($Api, $Worker, $Web)
        }

        It "E usa il modello configurato" {
            $apiRequest.model | Should -Be 'gpt-6-luna'
        }

        It "E chiede il ragionamento alto" {
            $apiRequest.reasoning_effort | Should -Be 'high'
        }

        It "E da' la guida di stile come istruzione" {
            ($apiRequest.messages | Where-Object role -EQ 'system').content | Should -Match 'Niente riempitivi'
        }

        It "E manda il codice della parte" {
            Get-UserMessage $apiRequest | Should -Match '=== Contoso\.Shop\.AI\.Api/Program\.cs ===\s+app\.MapPost'
        }

        It "E manda i documenti di contesto" {
            Get-UserMessage $apiRequest | Should -Match 'Gli eventi viaggiano su Service Bus'
        }

        It "E manda i container degli altri repository del sistema" {
            Get-UserMessage $apiRequest | Should -Match "ALTRI CONTAINER DEL SISTEMA:\n(- .+\n)*- $Web = Bff\.Web \(Contoso\.Shop\.Bff\.Web\)"
        }

        It "E chiede una risposta con lo schema del testo" {
            $apiRequest.response_format.json_schema.schema.required | Should -Be @('elements', 'relationships', 'people', 'externalSystems', 'links')
        }
    }

    Context "Scenario: testo di una struttura che non cambia" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedEngine)
            $first = Invoke-Text $root
            Reset-Stub
            $res = Invoke-Text $root
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello non riceve richieste" {
            Get-StubRequests | Should -BeNullOrEmpty
        }

        It "E la parte generata resta la stessa" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Be $first.Generated['containers/contoso.shop.ai.dsl']
        }
    }

    Context "Scenario: la struttura di un container cambia" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedEngine)
            Invoke-Text $root | Out-Null
            Reset-Stub
            Write-SourceFiles $root ([ordered]@{ 'sources/Contoso.Shop.AI/Contoso.Shop.AI.Worker/Contoso.Shop.AI.Worker.csproj' = (New-Project 'Microsoft.NET.Sdk' @('Contoso.Shop.AI.UseCase.WrittenConversations', 'Contoso.Shop.AI.Utils') "    <OutputType>Exe</OutputType>`n    <AzureFunctionsVersion>v4</AzureFunctionsVersion>") })
            $res = Invoke-Text $root
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello riscrive solo il testo di ""Worker""" {
            Get-RequestedUnits | Should -Be @($Worker)
        }

        It "E il componente nuovo di ""Worker"" ha una descrizione" {
            $res.Text.units.$Worker.elements.contoso_shop_ai_worker__contoso_shop_ai_utils | Should -Not -BeNullOrEmpty
        }
    }

    Context "Schema dello scenario: stesura respinta, il modello riscrive solo le voci da riscrivere — <difetto>" -ForEach @(
        @{ difetto = 'un elemento senza descrizione'; first = @{ omitElement = 'contoso_shop_ai_api__contoso_shop_ai_utils' }; motivo = 'elemento senza descrizione: contoso_shop_ai_api__contoso_shop_ai_utils' }
        @{ difetto = 'una frase troppo lunga'; first = @{ longDescription = 'contoso_shop_ai_api__contoso_shop_ai_utils' }; motivo = 'frase di contoso_shop_ai_api__contoso_shop_ai_utils oltre 25 parole' }
    ) {
        BeforeAll {
            Reset-Stub @{ $Api = @($first, @{ longDescription = $Api }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root -Environment @{ READABILITY_MAX_WORDS = '25' }
            Remove-Workspace $root
            $apiRequests = Get-UnitRequests $Api
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello riceve una seconda stesura da correggere" {
            $apiRequests.Count | Should -Be 2
        }

        It "E la seconda richiesta nomina il motivo" {
            Get-UserMessage $apiRequests[1] | Should -Match ([regex]::Escape($motivo))
        }

        It "E la voce riscritta prende il testo della seconda stesura" {
            $res.Text.units.$Api.elements.$Utils | Should -Be "Descrizione di $Utils."
        }

        It "E la voce accettata alla prima stesura resta" {
            $res.Text.units.$Api.elements.$Api | Should -Be "Descrizione di $Api."
        }
    }

    Context "Schema dello scenario: cio' che la struttura non contiene si toglie senza un'altra stesura — <difetto>" -ForEach @(
        @{ difetto = 'una relazione che il codice non dichiara'; spec = @{ extraRelationship = @{ source = 'contoso_shop_ai_api__contoso_shop_ai_utils'; target = 'contoso_shop_ai_api' } }; motivo = "relazione che il codice non dichiara: contoso_shop_ai_api__contoso_shop_ai_utils -> contoso_shop_ai_api"; voce = 'contoso_shop_ai_api__contoso_shop_ai_utils -> contoso_shop_ai_api' }
        @{ difetto = 'una persona senza relazioni'; spec = @{ people = @(@{ id = 'cliente'; name = 'Cliente'; description = 'Scrive al negozio.'; technical = $false }) }; motivo = 'persona o sistema esterno senza relazioni: cliente'; voce = 'cliente' }
        @{ difetto = 'una relazione che non lega un elemento della parte'; spec = @{ externalSystems = @(@{ id = 'entra'; name = 'Entra'; description = 'Identita''.'; technical = $false }); links = @(@{ source = 'entra'; target = 'contoso_shop_ai_worker'; description = 'Autentica'; technology = '' }) }; motivo = 'relazione che non lega una persona o un sistema esterno a un elemento della parte: entra -> contoso_shop_ai_worker'; voce = 'entra' }
    ) {
        BeforeAll {
            Reset-Stub @{ $Api = @($spec) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            Remove-Workspace $root
            $apiRequests = Get-UnitRequests $Api
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello riceve una sola stesura" {
            $apiRequests.Count | Should -Be 1
        }

        It "E le correzioni nominano cio' che si e' tolto" {
            $res.Corrections | Should -Match ([regex]::Escape("${Api}: $motivo"))
        }

        It "E il testo non contiene cio' che si e' tolto" {
            $res.Text | ConvertTo-Json -Depth 20 | Should -Not -Match ([regex]::Escape("""$voce"""))
        }
    }

    Context "Scenario: testo ancora da scrivere dopo l'ultima stesura" {
        BeforeAll {
            Reset-Stub @{ $Worker = @(@{ omitElement = $Worker }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello riceve tre stesure" {
            @(Get-RequestedUnits | Where-Object { $_ -eq $Worker }).Count | Should -Be 3
        }

        It "E le correzioni nominano il container e la voce" {
            $res.Corrections | Should -Match ([regex]::Escape("${Worker}: testo ancora da scrivere dopo 3 stesure: elemento senza descrizione: $Worker"))
        }

        It "E la pipeline lo segnala come avviso" {
            Get-Issues $res.Output 'warning' | Where-Object { $_ -match "testo ancora da scrivere dopo 3 stesure" } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il testo dell'altro container resta accettato" {
            $res.Text.units.$Api.elements.$Api | Should -Not -BeNullOrEmpty
        }

        It "E il testo di ""Worker"" si riscrive alla run successiva" {
            $res.Text.units.$Worker.basis | Should -BeNullOrEmpty
        }

        It "E la parte generata si scrive" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Not -BeNullOrEmpty
        }
    }

    Context "Scenario: modello linguistico non disponibile" {
        BeforeAll {
            Reset-Stub
            Set-StubStatus 503
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            Remove-Workspace $root
            $requested = @(Get-RequestedUnits)
            Reset-Stub
        }

        It "Allora la pipeline fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il container non descritto" {
            Get-Issues $res.Output | Where-Object { $_ -match "testo di contoso_shop_ai_(api|worker) non scritto" } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E non chiama il modello per gli altri container" {
            @($requested | Select-Object -Unique).Count | Should -Be 1
        }
    }

    Context "Scenario: il limite di token al minuto rifiuta le prime richieste" {
        BeforeAll {
            Reset-Stub
            [IO.File]::WriteAllText((Join-Path $StubState 'throttle'), '4')
            $root = New-Workspace (New-DescribedEngine)
            $started = Get-Date
            $res = Invoke-Text $root
            $elapsed = (Get-Date) - $started
            Remove-Workspace $root
            Reset-Stub
        }

        It "Allora il testo si scrive" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E aspetta quanto chiede Retry-After, non il raddoppio" {
            $elapsed.TotalSeconds | Should -BeLessThan 25
        }
    }

    Context "Scenario: generazione rilanciata" {
        BeforeAll {
            $branch = 'c4/model'
            $origin = New-OriginWorkspace
            $files = New-DescribedEngine
            $files.Remove('docs/STYLE.md')

            Reset-Stub
            [IO.File]::WriteAllText((Join-Path $StubState 'fail-after'), '1')
            $first = New-Clone $origin $files
            $failed = Invoke-Text $first -Environment @{ PROGRESS_BRANCH = $branch }
            Remove-Workspace $first
            $saved = Get-OriginText $origin $branch

            Reset-Stub
            $second = New-Clone $origin $files
            $res = Invoke-Text $second -Environment @{ PROGRESS_BRANCH = $branch }
            Remove-Workspace $second
            $resumed = Get-OriginText $origin $branch
            Remove-Workspace $origin
        }

        It "Allora la prima pipeline fallisce" {
            $failed.ExitCode | Should -Be 1
        }

        It "E il testo accettato di ""Api"" resta sul ramo" {
            $saved.units.$Api.elements.$Api | Should -Not -BeNullOrEmpty
        }

        It "E la pipeline rilanciata riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il testo di ""Api"" non si riscrive" {
            Get-RequestedUnits | Should -Be @($Worker)
        }

        It "E il ramo porta il testo di entrambi i container" {
            @($resumed.units.PSObject.Properties.Name | Sort-Object) | Should -Be @($Api, $Worker)
        }
    }

    Context "Scenario: persone e sistemi esterni di piu' repository" {
        BeforeAll {
            $person = @{ id = 'cliente'; name = 'Cliente'; description = 'Scrive al negozio dal sito.'; technical = $false }
            $link = @{ source = 'cliente'; target = $Api; description = 'Invia i messaggi'; technology = 'HTTPS' }
            $webLink = @{ source = 'cliente'; target = $Web; description = 'Apre la chat'; technology = 'HTTPS' }
            Reset-Stub @{ $Api = @(@{ people = @($person); links = @($link) }); $Web = @(@{ people = @($person); links = @($webLink) }) }
            $root = New-Workspace (New-DescribedSystem)
            $res = Invoke-Text $root @($Engine, $Bff)
            $webRequests = Get-UnitRequests $Web
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il testo dei due repository e' uno solo" {
            @($res.Text.units.PSObject.Properties.Name | Sort-Object) | Should -Be @($Api, $Worker, $Web)
        }

        It "E il contesto dichiara la persona una volta sola" {
            @($res.Generated['context.dsl'] -split "`n" | Where-Object { $_ -match '^cliente = person "Cliente"' }).Count | Should -Be 1
        }

        It "E la parte del Motore contiene la relazione dalla persona all'applicazione" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Match "cliente -> $Api `"Invia i messaggi`" `"HTTPS`""
        }

        It "E il container del BFF trova la persona nel catalogo" {
            Get-UserMessage $webRequests[0] | Should -Match '- cliente = Cliente'
        }

        It "E una stesura che la dichiara di nuovo si accetta senza un'altra richiesta" {
            $webRequests.Count | Should -Be 1
        }

        It "E la parte del BFF la collega con lo stesso identificativo" {
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Match "cliente -> $Web `"Apre la chat`" `"HTTPS`""
        }
    }

    Context "Scenario: una stesura dichiara con un altro identificativo una persona del catalogo" {
        BeforeAll {
            $person = @{ id = 'cliente'; name = 'Cliente'; description = 'Scrive al negozio dal sito.'; technical = $false }
            $renamed = @{ id = 'customer'; name = ' cliente '; description = 'Apre la chat.'; technical = $false }
            Reset-Stub @{
                $Api = @(@{ people = @($person); links = @(@{ source = 'cliente'; target = $Api; description = 'Invia i messaggi'; technology = 'HTTPS' }) })
                $Web = @(@{ people = @($renamed); links = @(@{ source = 'customer'; target = $Web; description = 'Apre la chat'; technology = 'HTTPS' }) })
            }
            $root = New-Workspace (New-DescribedSystem)
            $res = Invoke-Text $root @($Engine, $Bff)
            $webRequests = Get-UnitRequests $Web
            Remove-Workspace $root
        }

        It "Allora la stesura si accetta senza un'altra richiesta" {
            $webRequests.Count | Should -Be 1
        }

        It "E il testo non dichiara l'altro identificativo" {
            @($res.Text.people.PSObject.Properties.Name) | Should -Be @('cliente')
        }

        It "E la parte collega l'identificativo del catalogo" {
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Match "cliente -> $Web `"Apre la chat`" `"HTTPS`""
        }
    }

    Context "Scenario: il catalogo unisce due voci che indicano la stessa persona" {
        BeforeAll {
            $person = @{ id = 'cliente'; name = 'Cliente'; description = 'Scrive al negozio dal sito.'; technical = $false }
            $other = @{ id = 'acquirente'; name = 'Acquirente del negozio'; description = 'Apre la chat dal sito.'; technical = $false }
            Reset-Stub @{
                $Api       = @(@{ people = @($person); links = @(@{ source = 'cliente'; target = $Api; description = 'Invia i messaggi'; technology = 'HTTPS' }) })
                $Web       = @(@{ people = @($other); links = @(@{ source = 'acquirente'; target = $Web; description = 'Apre la chat'; technology = 'HTTPS' }) })
                catalogue  = @(@{ acquirente = 'cliente' })
            }
            $root = New-Workspace (New-DescribedSystem)
            $res = Invoke-Text $root @($Engine, $Bff)
            $catalogueRequests = Get-CatalogueRequests
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il controllo vede insieme le voci e i container di tutti i repository" {
            $message = Get-UserMessage $catalogueRequests[0]
            $message | Should -Match '- acquirente \[persona\] = Acquirente del negozio'
            $message | Should -Match '- cliente \[persona\] = Cliente'
            $message | Should -Match "- $Web = Bff\.Web \(Contoso\.Shop\.Bff\.Web\)"
        }

        It "E il controllo chiede la risposta con lo schema del catalogo" {
            $catalogueRequests[0].response_format.json_schema.name | Should -Be 'c4_model_catalogue'
        }

        It "E il testo dichiara solo la voce che resta" {
            @($res.Text.people.PSObject.Properties.Name) | Should -Be @('cliente')
        }

        It "E la parte del BFF collega la voce che resta" {
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Match "cliente -> $Web `"Apre la chat`" `"HTTPS`""
        }

        It "E il contesto non dichiara la voce unita" {
            $res.Generated['context.dsl'] | Should -Not -Match 'acquirente'
        }

        It "E le correzioni elencano l'unione" {
            $res.Corrections | Should -Match 'catalogo: acquirente unito a cliente'
        }
    }

    Context "Scenario: il catalogo toglie un sistema esterno che e' un container del sistema" {
        BeforeAll {
            $portal = @{ id = 'portale'; name = 'Portale del negozio'; description = 'Riceve le richieste del sito.'; technical = $false }
            Reset-Stub @{
                $Api      = @(@{ externalSystems = @($portal); links = @(@{ source = 'portale'; target = $Api; description = 'Chiama le API'; technology = 'HTTPS' }) })
                catalogue = @(@{ portale = $Web })
            }
            $root = New-Workspace (New-DescribedSystem)
            $res = Invoke-Text $root @($Engine, $Bff)
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il testo non dichiara il sistema esterno" {
            @($res.Text.externalSystems.PSObject.Properties.Name) | Should -BeNullOrEmpty
        }

        It "E la parte non ha la relazione con il sistema esterno" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Not -Match '\bportale ->'
        }

        It "E le correzioni elencano il sistema esterno tolto" {
            $res.Corrections | Should -Match "catalogo: sistema esterno portale tolto, e' il container $Web"
        }
    }

    Context "Scenario: risposta del catalogo respinta" {
        BeforeAll {
            $person = @{ id = 'cliente'; name = 'Cliente'; description = 'Scrive al negozio dal sito.'; technical = $false }
            $other = @{ id = 'acquirente'; name = 'Acquirente del negozio'; description = 'Apre la chat dal sito.'; technical = $false }
            Reset-Stub @{
                $Api      = @(@{ people = @($person); links = @(@{ source = 'cliente'; target = $Api; description = 'Invia i messaggi'; technology = 'HTTPS' }) })
                $Web      = @(@{ people = @($other); links = @(@{ source = 'acquirente'; target = $Web; description = 'Apre la chat'; technology = 'HTTPS' }) })
                catalogue = @(@{ acquirente = 'sconosciuto'; omit = @('cliente') }, @{ acquirente = 'cliente' })
            }
            $root = New-Workspace (New-DescribedSystem)
            $res = Invoke-Text $root @($Engine, $Bff)
            $catalogueRequests = Get-CatalogueRequests
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello riceve un secondo controllo da correggere" {
            $catalogueRequests.Count | Should -Be 2
        }

        It "E il secondo controllo nomina i motivi" {
            $message = Get-UserMessage $catalogueRequests[1]
            $message | Should -Match 'voce unita a un identificativo sconosciuto: acquirente -> sconosciuto'
            $message | Should -Match 'voce del catalogo senza risposta: cliente'
        }

        It "E la risposta corretta si applica" {
            @($res.Text.people.PSObject.Properties.Name) | Should -Be @('cliente')
        }
    }

    Context "Scenario: una relazione parte da un'applicazione di un altro repository" {
        BeforeAll {
            Reset-Stub
            $archive = 'contoso_shop_infrastructure_archivio'
            $fragment = [ordered]@{
                manifests     = @('main.tf')
                containers    = @([ordered]@{ id = $archive; name = 'archivio'; codeName = 'main.tf'; sources = @(); technology = 'Terraform'; tags = @('Servizio'); properties = @{}; components = @() })
                relationships = @([ordered]@{ source = $Api; target = $archive })
            }
            $files = New-DescribedEngine
            $files['sources/Contoso.Shop.Infrastructure/main.tf'] = "resource `"azurerm_storage_account`" `"archivio`" {}`n"
            $files['fragments/contoso.shop.infrastructure.consumer.json'] = $fragment | ConvertTo-Json -Depth 10
            $root = New-Workspace $files
            $res = Invoke-Text $root @($Engine, 'Contoso.Shop.Infrastructure') -Readers @{ 'Contoso.Shop.Infrastructure' = @() } -Environment @{ SOURCE_REPOSITORIES = "$C4SourceRepositories,Contoso.Shop.Infrastructure" }
            $apiRequests = Get-UnitRequests $Api
            $archiveRequests = Get-UnitRequests $archive
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la relazione la descrive il container da cui parte" {
            Get-UserMessage $apiRequests[0] | Should -Match """target"":\s*""$archive"""
            Get-UserMessage $archiveRequests[0] | Should -Not -Match """source"":\s*""$Api"""
        }

        It "E la parte dell'infrastruttura dice cio' che passa sulla relazione" {
            $res.Generated['containers/contoso.shop.infrastructure.dsl'] | Should -Match "$Api -> $archive ""Passa da $Api a $archive"""
        }
    }

    Context "Scenario: una relazione parte da un elemento che nessun container letto contiene" {
        BeforeAll {
            Reset-Stub
            $archive = 'contoso_shop_infrastructure_archivio'
            $fragment = [ordered]@{
                manifests     = @('main.tf')
                containers    = @([ordered]@{ id = $archive; name = 'archivio'; codeName = 'main.tf'; sources = @(); technology = 'Terraform'; tags = @('Servizio'); properties = @{}; components = @() })
                relationships = @([ordered]@{ source = $Api; target = $archive })
            }
            $root = New-Workspace ([ordered]@{
                    'sources/Contoso.Shop.Infrastructure/main.tf'          = "resource `"azurerm_storage_account`" `"archivio`" {}`n"
                    'docs/STYLE.md'                                       = $Guide
                    'fragments/contoso.shop.infrastructure.consumer.json' = ($fragment | ConvertTo-Json -Depth 10)
                })
            $res = Invoke-Text $root @('Contoso.Shop.Infrastructure') -Readers @{ 'Contoso.Shop.Infrastructure' = @() } -Environment @{ SOURCE_REPOSITORIES = 'Contoso.Shop.Infrastructure' }
            $requests = @(Get-StubRequests)
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la struttura mandata al modello per il container di arrivo contiene la relazione" {
            Get-UserMessage $requests[0] | Should -Match """source"":\s*""$Api"""
        }

        It "E la parte dice cio' che passa sulla relazione" {
            $res.Generated['containers/contoso.shop.infrastructure.dsl'] | Should -Match "$Api -> $archive ""Passa da $Api a $archive"""
        }
    }

    Context "Scenario: una stesura dichiara come sistema esterno l'applicazione di un repository sorgente" {
        BeforeAll {
            $bffSystem = @{ id = 'bff'; name = 'Contoso.Shop.Bff.Web'; description = 'Riceve le richieste del sito.'; technical = $false }
            Reset-Stub @{ $Api = @(@{ externalSystems = @($bffSystem); links = @(@{ source = 'bff'; target = $Api; description = 'Chiama le API'; technology = 'HTTPS' }) }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            $apiRequests = Get-UnitRequests $Api
            Remove-Workspace $root
        }

        It "Allora la stesura si accetta senza un'altra richiesta" {
            $apiRequests.Count | Should -Be 1
        }

        It "E il testo non dichiara il sistema esterno" {
            @($res.Text.externalSystems.PSObject.Properties.Name) | Should -BeNullOrEmpty
        }

        It "E la parte non ha la relazione con il sistema esterno" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Not -Match '\bbff ->'
        }

        It "E le correzioni elencano il sistema esterno tolto" {
            $res.Corrections | Should -Match "${Api}: sistema esterno con il nome di un repository sorgente: bff"
        }

        It "E il modello riceve i repository sorgente del sistema" {
            Get-UserMessage $apiRequests[0] | Should -Match 'REPOSITORY SORGENTE DEL SISTEMA:\n- Contoso\.Shop\.AI\n- Contoso\.Shop\.Bff\.Web\n- Contoso\.Shop\.Client\.Web'
        }
    }

    Context "Scenario: il testo salvato dichiara come sistema esterno l'applicazione di un repository sorgente" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedEngine)
            Invoke-Text $root | Out-Null
            $path = Join-Path $root 'docs/architecture/c4/generated/model.text.json'
            $saved = Get-Content -Raw $path | ConvertFrom-Json
            $saved.externalSystems | Add-Member -NotePropertyName 'bff' -NotePropertyValue ([pscustomobject]@{ name = 'Contoso.Shop.Bff.Web'; description = 'Riceve le richieste del sito.'; technical = $false })
            $saved.units.$Api.links = @([pscustomobject]@{ source = 'bff'; target = $Api; description = 'Chiama le API'; technology = 'HTTPS' })
            [IO.File]::WriteAllText($path, ($saved | ConvertTo-Json -Depth 20))

            Reset-Stub
            $res = Invoke-Text $root
            $requests = @(Get-StubRequests)
            Remove-Workspace $root
        }

        It "Allora la run non chiede nulla al modello" {
            $requests | Should -BeNullOrEmpty
        }

        It "E il testo non dichiara il sistema esterno" {
            @($res.Text.externalSystems.PSObject.Properties.Name) | Should -BeNullOrEmpty
        }

        It "E la parte non ha la relazione con il sistema esterno" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Not -Match '\bbff ->'
        }
    }

    Context "Scenario: il modello descritto e' un modello Structurizr valido" {
        BeforeAll {
            $person = @{ id = 'cliente'; name = 'Cliente'; description = 'Scrive al negozio dal sito.'; technical = $false }
            $system = @{ id = 'entra'; name = 'Entra External ID'; description = 'Autentica i clienti.'; technical = $true }
            $links = @(@{ source = 'cliente'; target = $Api; description = 'Invia i messaggi'; technology = 'HTTPS' }, @{ source = $Api; target = 'entra'; description = 'Valida i token'; technology = 'OpenID Connect' })
            Reset-Stub @{ $Api = @(@{ people = @($person); externalSystems = @($system); links = $links }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            Remove-Workspace $root
            $dir = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-text-dsl-$(New-Guid)"
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'generated/containers'), (Join-Path $dir 'generated/views') | Out-Null
            $res.Generated.Keys | ForEach-Object { [IO.File]::WriteAllText((Join-Path $dir "generated/$_"), $res.Generated[$_]) }
            [IO.File]::WriteAllText((Join-Path $dir 'workspace.dsl'), "workspace {`n    model {`n        !include generated/context.dsl`n        sistema = softwareSystem `"Contoso.Shop`" {`n            !include generated/containers`n        }`n    }`n    views {`n        !include generated/views`n    }`n}`n")
            $export = Export-StructurizrWorkspace (Join-Path $dir 'workspace.dsl')
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
            $model = $export.Workspace.model
        }

        It "Allora il contesto si scrive con la parte" {
            $res.Generated['context.dsl'] | Should -Match 'cliente = person "Cliente"'
        }

        It "E il workspace che lo include si esporta senza errori" {
            $export.Error | Should -BeNullOrEmpty
        }

        It "E ogni elemento generato ha una descrizione" {
            $elements = @($model.softwareSystems[0].containers) + @($model.softwareSystems[0].containers | ForEach-Object { @($_.components) })
            $elements | Where-Object { $_ -and -not $_.description } | ForEach-Object name | Should -BeNullOrEmpty
        }

        It "E la vista dei componenti di ""Api"" generata con la parte si esporta" {
            @($export.Workspace.views.componentViews | ForEach-Object key) | Should -Contain $Api
        }

        It "E il sistema esterno porta il tag degli elementi tecnici" {
            ($model.softwareSystems | Where-Object name -EQ 'Entra External ID').tags | Should -Match 'Esterno,Tecnico'
        }

        It "E la relazione dalla persona all'applicazione dice cio' che passa" {
            ($model.people | Where-Object name -EQ 'Cliente').relationships.description | Should -Contain 'Invia i messaggi'
        }
    }

    Context "Scenario: un container sparisce dal codice" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedEngine)
            Invoke-Text $root | Out-Null
            Remove-Item -Recurse -Force (Join-Path $root 'sources/Contoso.Shop.AI/Contoso.Shop.AI.Worker')
            Remove-Item -Recurse -Force (Join-Path $root 'fragments')
            Reset-Stub
            $res = Invoke-Text $root
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il testo di ""Worker"" non resta" {
            $res.Text.units.PSObject.Properties.Name | Should -Not -Contain $Worker
        }
    }

    Context "Scenario: modello non configurato" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root -Environment @{ C4_TEXT_ENDPOINT = '' }
            Remove-Workspace $root
        }

        It "Allora la pipeline fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la configurazione mancante" {
            Get-Issues $res.Output | Where-Object { $_ -match 'endpoint o modello non configurati' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E non chiama il modello" {
            Get-StubRequests | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: una relazione nasce dal proxy di sviluppo di un'altra applicazione" {
        BeforeAll {
            Reset-Stub
            $client = 'contoso_shop_client_web'
            $files = Add-Sources ([ordered]@{ 'docs/STYLE.md' = $Guide }) $Bff (Add-LaunchSettings (New-BffRepository) 'Contoso.Shop.Bff.Web' @('https://localhost:5001'))
            $files = Add-Sources $files 'Contoso.Shop.Client.Web' (Add-DevProxy (New-ClientRepository) @{ '/api' = 'https://localhost:5001' })
            $root = New-Workspace $files
            $res = Invoke-Text $root @($Bff, 'Contoso.Shop.Client.Web') -Readers @{ 'Contoso.Shop.Client.Web' = @('angular18') }
            $clientRequests = Get-UnitRequests $client
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la relazione la descrive l'applicazione che chiama" {
            Get-UserMessage $clientRequests[0] | Should -Match """target"":\s*""${Web}__$Web"""
        }

        It "E la parte dell'applicazione che chiama dice cio' che passa sulla relazione" {
            $res.Generated['containers/contoso.shop.client.web.dsl'] | Should -Match "$client -> ${Web}__$Web ""Passa da $client a ${Web}__$Web"""
        }
    }

    Context "Scenario: un sistema esterno che la configurazione di produzione non usa esce dal modello" {
        BeforeAll {
            Reset-Stub @{ $Api = @($ApiExternals); review = @(@{ notInProduction = @('pagamenti') }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            $message = Get-FirstReviewMessage
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la revisione riceve la configurazione di produzione" {
            $message | Should -Match "=== $([regex]::Escape($Engine))/deploy/production\.tfvars ===\r?\nsms_sender"
        }

        It "E la revisione riceve il codice dell'elemento legato ai sistemi esterni" {
            $message | Should -Match 'CODICE DEGLI ELEMENTI LEGATI A SISTEMI ESTERNI:\s+=== Contoso\.Shop\.AI/Contoso\.Shop\.AI\.Api/'
        }

        It "E il contesto non dichiara il sistema esterno" {
            $res.Generated['context.dsl'] | Should -Not -Match 'pagamenti ='
        }

        It "E la parte non ha la relazione con il sistema esterno" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Not -Match "$Api -> pagamenti"
        }

        It "E il sistema esterno usato in produzione resta" {
            $res.Generated['context.dsl'] | Should -Match 'sms = softwareSystem "Gateway SMS"'
        }

        It "E il testo salva la prova del sistema esterno che resta" {
            $res.Text.review.externalSystems.sms.evidence[0].path | Should -Be "$Engine/deploy/production.tfvars"
        }

        It "E le correzioni dicono perche' il sistema esterno e' uscito" {
            $res.Corrections | Should -Match "sistema esterno pagamenti tolto, non e' in produzione: Motivo per pagamenti\."
        }

        It "E il testo conserva il sistema esterno con la decisione della revisione" {
            $res.Text.externalSystems.pagamenti.name | Should -Be 'Servizio pagamenti'
            $res.Text.review.externalSystems.pagamenti.inProduction | Should -Be $false
        }

        It "E il testo conserva la relazione con il sistema esterno" {
            @($res.Text.units.$Api.links | Where-Object target -EQ 'pagamenti') | Should -Not -BeNullOrEmpty
        }
    }

    Context "Scenario: un sistema esterno escluso torna quando la configurazione di produzione lo prova" {
        BeforeAll {
            Reset-Stub @{ $Api = @($ApiExternals); review = @(@{ notInProduction = @('pagamenti') }) }
            $root = New-Workspace (New-DescribedEngine)
            $first = Invoke-Text $root
            [IO.File]::AppendAllText((Join-Path $root "sources/$Engine/deploy/production.tfvars"), "payments_retries = 3`n")
            Reset-Stub
            $res = Invoke-Text $root
            $requests = @(Get-ReviewRequests)
            Remove-Workspace $root
        }

        It "Allora la prima generazione esclude il sistema esterno" {
            $first.Generated['context.dsl'] | Should -Not -Match 'pagamenti ='
        }

        It "E la revisione successiva giudica di nuovo il sistema esterno escluso" {
            Get-UserMessage $requests[0] | Should -Match '(?m)^- pagamenti \[sistema esterno\]'
        }

        It "E il contesto dichiara di nuovo il sistema esterno" {
            $res.Generated['context.dsl'] | Should -Match 'pagamenti = softwareSystem "Servizio pagamenti"'
        }

        It "E la parte ha di nuovo la relazione con il sistema esterno" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Match "$Api -> pagamenti ""Chiede i pagamenti"""
        }
    }

    Context "Scenario: un sistema esterno senza una prova nella configurazione esce dopo l'ultimo giro" {
        BeforeAll {
            Reset-Stub @{ $Api = @($ApiExternals); review = @(@{ noEvidence = @('pagamenti') }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            $requests = @(Get-ReviewRequests)
            Remove-Workspace $root
        }

        It "Allora la revisione si ripete fino all'ultimo giro" {
            $requests.Count | Should -Be 3
        }

        It "E il giro successivo nomina la prova mancante" {
            Get-UserMessage $requests[1] | Should -Match 'sistema esterno in produzione senza una prova che compaia nella configurazione di produzione: pagamenti'
        }

        It "E il sistema esterno esce dal modello" {
            $res.Generated['context.dsl'] | Should -Not -Match 'pagamenti ='
        }
    }

    Context "Scenario: una citazione che non compare nel file si respinge" {
        BeforeAll {
            Reset-Stub @{ $Api = @($ApiExternals); review = @(@{ wrongQuote = @('pagamenti') }, @{}) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            $requests = @(Get-ReviewRequests)
            Remove-Workspace $root
        }

        It "Allora la revisione chiede un secondo giro" {
            $requests.Count | Should -Be 2
        }

        It "E il sistema esterno con la prova giusta resta" {
            $res.Generated['context.dsl'] | Should -Match 'pagamenti = softwareSystem "Servizio pagamenti"'
        }
    }

    Context "Scenario: la revisione toglie la relazione di una persona con un'applicazione che non usa" {
        BeforeAll {
            $person = @{ id = 'cliente'; name = 'Cliente'; description = 'Scrive al negozio dal sito.'; technical = $false }
            $apiLink = @{ source = 'cliente'; target = $Api; description = 'Invia i messaggi'; technology = 'HTTPS' }
            $webLink = @{ source = 'cliente'; target = $Web; description = 'Apre la chat'; technology = 'HTTPS' }
            Reset-Stub @{
                $Api   = @(@{ people = @($person); links = @($apiLink) })
                $Web   = @(@{ people = @($person); links = @($webLink) })
                review = @(@{ drop = @("cliente -> $Api") })
            }
            $root = New-Workspace (New-DescribedSystem)
            $res = Invoke-Text $root @($Engine, $Bff)
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la parte del Motore non ha la relazione della persona" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Not -Match "cliente -> $Api"
        }

        It "E il testo conserva la relazione con la decisione della revisione" {
            @($res.Text.units.$Api.links | Where-Object source -EQ 'cliente') | Should -Not -BeNullOrEmpty
            $res.Text.review.links."cliente -> $Api".keep | Should -Be $false
        }

        It "E la relazione con l'applicazione che la persona usa resta" {
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Match "cliente -> $Web `"Apre la chat`""
        }
    }

    Context "Scenario: un'applicazione si chiama dal codice, non dalla revisione" {
        BeforeAll {
            Reset-Stub @{ review = @(@{ names = @{ $Api = 'Motore AI' } }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            $requests = @(Get-ReviewRequests)
            Remove-Workspace $root
        }

        It "Allora la parte scrive l'applicazione con il nome nel codice senza il prefisso comune alle applicazioni" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Match "$Api = container `"Api`""
        }

        It "E il nome nel codice resta nella proprieta' del container" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Match '"Contoso\.Shop\.AI\.Api"'
        }

        It "E la revisione non torna sul nome" {
            $requests.Count | Should -Be 1
        }
    }

    Context "Scenario: l'unica applicazione del sistema tiene il nome del codice" {
        BeforeAll {
            Reset-Stub @{ review = @(@{ names = @{ $Web = 'Motore' } }) }
            $root = New-Workspace (New-DescribedSystem)
            $res = Invoke-Text $root @($Bff)
            Remove-Workspace $root
        }

        It "Allora la parte non usa il nome dato dalla revisione" {
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Match "$Web = container `"Web`""
        }
    }

    Context "Scenario: le applicazioni di repository diversi si chiamano senza il prefisso comune a tutte" {
        BeforeAll {
            Reset-Stub @{ review = @(@{ names = @{ $Web = 'Web' } }) }
            $root = New-Workspace (New-DescribedSystem)
            $res = Invoke-Text $root @($Engine, $Bff)
            $requests = @(Get-ReviewRequests)
            Remove-Workspace $root
        }

        It "Allora l'applicazione del BFF si chiama con la parte che la distingue nel sistema" {
            $res.Generated['containers/contoso.shop.bff.web.dsl'] | Should -Match "$Web = container `"Bff\.Web`""
        }

        It "E cosi' le applicazioni degli altri repository" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Match "$Api = container `"AI\.Api`""
        }

        It "E la revisione vede le applicazioni con quei nomi" {
            Get-UserMessage $requests[0] | Should -Match "$Web = Bff\.Web \[[^\]]+\] \(applicazione di "
        }
    }

    Context "Scenario: due nomi uguali si respingono" {
        BeforeAll {
            Reset-Stub @{ review = @(@{ names = @{ $Language = 'Lingua'; $Speech = 'Lingua' } }, @{ names = @{ $Language = 'Lingua'; $Speech = 'Voce' } }) }
            $files = New-DescribedEngine
            $files['fragments/contoso.shop.ai.resources.json'] = New-ResourcesFragment @($Language, $Speech)
            $root = New-Workspace $files
            $res = Invoke-Text $root
            $requests = @(Get-ReviewRequests)
            Remove-Workspace $root
        }

        It "Allora il secondo giro nomina il nome non unico" {
            Get-UserMessage $requests[1] | Should -Match 'nome di container non unico'
        }

        It "E la parte usa i nomi del secondo giro" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Match "$Speech = container `"Voce`""
        }
    }

    Context "Scenario: una risorsa chiamata con il suo nome tecnico" {
        BeforeAll {
            Reset-Stub @{ review = @(@{ names = @{ $Language = 'lang-shop-prod' } }, @{ names = @{ $Language = 'Riconoscimento della lingua' } }) }
            $files = New-DescribedEngine
            $files['fragments/contoso.shop.ai.resources.json'] = New-ResourcesFragment @($Language)
            $root = New-Workspace $files
            $res = Invoke-Text $root
            $requests = @(Get-ReviewRequests)
            Remove-Workspace $root
        }

        It "Allora il giro successivo chiede il nome di cio' che fa" {
            Get-UserMessage $requests[1] | Should -Match "risorsa chiamata con il suo nome tecnico invece che con cio' che fa: $Language = lang-shop-prod"
        }

        It "E la parte usa il nome di cio' che fa" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Match "$Language = container `"Riconoscimento della lingua`""
        }
    }

    Context "Scenario: la revisione unisce due container che sono copie della stessa risorsa" {
        BeforeAll {
            $language = 'contoso_shop_ai_language'
            $copy = 'contoso_shop_ai_language_2'
            $resources = [ordered]@{
                manifests     = @()
                containers    = @(
                    [ordered]@{ id = $language; name = 'language'; codeName = 'language'; sources = @(); technology = 'Language'; properties = [ordered]@{}; components = @() }
                    [ordered]@{ id = $copy; name = 'language-2'; codeName = 'language-2'; sources = @(); technology = 'Language'; properties = [ordered]@{}; components = @() }
                )
                relationships = @(
                    [ordered]@{ source = $Api; target = $language }
                    [ordered]@{ source = $Api; target = $copy }
                    [ordered]@{ source = $Worker; target = $copy }
                )
                addresses     = @()
                calls         = @()
            }
            Reset-Stub @{ review = @(@{ sameAs = @{ $copy = $language } }) }
            $files = New-DescribedEngine
            $files['fragments/contoso.shop.ai.resources.json'] = $resources | ConvertTo-Json -Depth 10
            $root = New-Workspace $files
            $res = Invoke-Text $root
            Remove-Workspace $root
            $dsl = $res.Generated['containers/contoso.shop.ai.dsl']
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E la copia non si scrive" {
            $dsl | Should -Not -Match "$copy = container"
        }

        It "E le relazioni della copia passano al container che resta, senza doppioni" {
            @($dsl -split "`n" | Where-Object { $_ -match "^$Api -> $language " }).Count | Should -Be 1
        }

        It "E la relazione dell'altra applicazione con la copia arriva al container che resta" {
            $dsl | Should -Match "$Worker -> $language "
        }

        It "E nessuna relazione parte dalla copia o vi arriva" {
            $dsl | Should -Not -Match "(^|
)$copy -> |-> $copy "
        }
    }

    Context "Scenario: un container con componenti non si unisce a un altro" {
        BeforeAll {
            Reset-Stub @{ review = @(@{ sameAs = @{ $Worker = $Api } }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root
            $requests = @(Get-ReviewRequests)
            Remove-Workspace $root
        }

        It "Allora il giro successivo nomina l'unione respinta" {
            Get-UserMessage $requests[1] | Should -Match "container con componenti unito a un altro: $Worker -> $Api"
        }

        It "E i due container restano" {
            $res.Generated['containers/contoso.shop.ai.dsl'] | Should -Match "$Worker = container"
        }
    }

    Context "Scenario: la revisione non si ripete se struttura e configurazione non cambiano" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedEngine)
            Invoke-Text $root | Out-Null
            Reset-Stub
            Invoke-Text $root | Out-Null
            $unchanged = @(Get-ReviewRequests).Count
            [IO.File]::AppendAllText((Join-Path $root "sources/$Engine/deploy/production.tfvars"), "sms_retries = 3`n")
            Reset-Stub
            Invoke-Text $root | Out-Null
            $changed = @(Get-ReviewRequests).Count
            Remove-Workspace $root
        }

        It "Allora la seconda generazione non chiede la revisione" {
            $unchanged | Should -Be 0
        }

        It "E una configurazione di produzione cambiata la chiede di nuovo" {
            $changed | Should -Be 1
        }
    }
}
