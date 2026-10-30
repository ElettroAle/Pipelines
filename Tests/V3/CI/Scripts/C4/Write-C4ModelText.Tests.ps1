#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/Write-C4ModelText.ps1 e per il testo composto da Export-C4CodeModel.ps1

.DESCRIPTION
    Ogni scenario costruisce un repository sorgente finto ed esegue, come in pipeline, il lettore .NET,
    il generatore del testo e lo scrittore. Il modello e' sostituito da un endpoint locale
    (Tests/V3/CI/Scripts/C4/Fixtures/ModelTextStub.ps1) che descrive ogni elemento e ogni relazione della parte, salvo
    le stesure cambiate dallo scenario; le prove verificano cosa il generatore manda al modello, quali
    stesure accetta, cosa salva e cosa lo scrittore compone. Il testo vero del modello si giudica sul
    repository della documentazione. Lo scenario che controlla la validita' del DSL richiede Java 17 o
    successivo (STRUCTURIZR_JAVA, JAVA_HOME_17_X64 o JAVA_HOME).
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

    $Api = 'aidea_dxp_ai_api'
    $Worker = 'aidea_dxp_ai_worker'
    $UseCase = 'aidea_dxp_ai_api__aidea_dxp_ai_usecase_writtenconversations'
    $ServiceBus = 'aidea_dxp_ai_api__aidea_dxp_ai_dataaccess_azureservicebus'
    $Guide = "# Guida di stile`n`n## Regole`n`n### Niente riempitivi`n`nUn'espressione che non aggiunge informazione si toglie.`n"
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
        return @(Get-StubRequests | ForEach-Object { [regex]::Match((Get-UserMessage $_), 'PARTE DA DESCRIVERE: (\S+)').Groups[1].Value })
    }

    function New-DescribedEngine {
        $files = New-EngineRepository
        $files['source/Aidea.Dxp.AI.Api/Program.cs'] = "app.MapPost(`"/conversations`", SendMessage);`n"
        $files['docs/STYLE.md'] = $Guide
        $files['docs/decisions/0012-canale-eventi-di-sessione.md'] = $Decision
        return $files
    }

    function New-Workspace([System.Collections.IDictionary]$Files) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-text-ws-$(New-Guid)"
        Write-SourceFiles $root $Files
        return $root
    }

    function Invoke-Text([string]$Root, [string]$Repository, [string[]]$Readers = @('dotnet10'), [hashtable]$Environment = @{}) {
        $variables = @{
            SOURCE_DIRECTORY = 'source'; SOURCE_REPOSITORY = $Repository; SOURCE_REPOSITORIES = $C4SourceRepositories
            FRAGMENT_DIRECTORY = 'fragments'; GENERATED_DIRECTORY = 'docs/architecture/model/generated'; GENERATION_MODE = 'write'; DOCUMENT_LANGUAGE = ''
            C4_TEXT_ENDPOINT = $StubEndpoint; C4_TEXT_MODEL = 'gpt-6-luna'; C4_TEXT_TOKEN = 'token-di-prova'; C4_TEXT_REASONING_EFFORT = ''
            C4_TEXT_MAX_DRAFTS = ''; C4_TEXT_CONTEXT = 'docs/decisions'; STYLE_GUIDE = 'docs/STYLE.md'; PROGRESS_BRANCH = ''
            READABILITY_MAX_WORDS = ''; READABILITY_ABBREVIATIONS = ''; GATE_MODE = ''; SYSTEM_ACCESSTOKEN = ''
        }
        $Environment.Keys | ForEach-Object { $variables[$_] = $Environment[$_] }
        $steps = @($Readers | ForEach-Object { $C4Readers[$_] }) + 'C4/Write-C4ModelText.ps1' + 'C4/Export-C4CodeModel.ps1'
        Push-Location $Root
        try {
            $outputs = @()
            $exitCode = 0
            foreach ($step in $steps) {
                $result = Invoke-C4Script $step $variables
                $outputs += $result.Output
                $exitCode = $result.ExitCode
                if ($exitCode) { break }
            }
            $generated = Join-Path $Root 'docs/architecture/model/generated'
            $textFile = Join-Path $generated "$($Repository.ToLowerInvariant()).text.json"
            return @{
                ExitCode  = $exitCode
                Output    = $outputs -join "`n"
                Generated = Read-Directory $generated '*.dsl'
                Text      = if (Test-Path $textFile) { Get-Content -Raw $textFile | ConvertFrom-Json } else { $null }
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
        return (git -C $Origin show "${Branch}:docs/architecture/model/generated/aidea.dxp.ai.text.json" 2>$null) -join "`n" | ConvertFrom-Json
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
            $res = Invoke-Text $root 'Aidea.Dxp.AI'
            $dsl = $res.Generated['aidea.dxp.ai.dsl']
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

        It "E il testo accettato resta nel file del testo del repository" {
            $res.Text.units.$Api.elements.$Api | Should -Be "Descrizione di $Api."
        }
    }

    Context "Scenario: cosa il generatore manda al modello" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root 'Aidea.Dxp.AI'
            Remove-Workspace $root
            $requests = Get-StubRequests
            $apiRequest = $requests | Where-Object { (Get-UserMessage $_) -match "PARTE DA DESCRIVERE: $Api\b" } | Select-Object -First 1
        }

        It "Allora chiede un container per richiesta" {
            Get-RequestedUnits | Sort-Object | Should -Be @($Api, $Worker)
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
            Get-UserMessage $apiRequest | Should -Match '=== Aidea\.Dxp\.AI\.Api/Program\.cs ===\s+app\.MapPost'
        }

        It "E manda i documenti di contesto" {
            Get-UserMessage $apiRequest | Should -Match 'Gli eventi viaggiano su Service Bus'
        }

        It "E chiede una risposta con lo schema del testo" {
            $apiRequest.response_format.json_schema.schema.required | Should -Be @('elements', 'relationships', 'people', 'externalSystems', 'links')
        }
    }

    Context "Scenario: testo di una struttura che non cambia" {
        BeforeAll {
            Reset-Stub
            $root = New-Workspace (New-DescribedEngine)
            $first = Invoke-Text $root 'Aidea.Dxp.AI'
            Reset-Stub
            $res = Invoke-Text $root 'Aidea.Dxp.AI'
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello non riceve richieste" {
            Get-StubRequests | Should -BeNullOrEmpty
        }

        It "E la parte generata resta la stessa" {
            $res.Generated['aidea.dxp.ai.dsl'] | Should -Be $first.Generated['aidea.dxp.ai.dsl']
        }
    }

    Context "Scenario: la struttura di un container cambia" {
        BeforeAll {
            Reset-Stub
            $files = New-DescribedEngine
            $root = New-Workspace $files
            Invoke-Text $root 'Aidea.Dxp.AI' | Out-Null
            Reset-Stub
            Write-SourceFiles $root ([ordered]@{ 'source/Aidea.Dxp.AI.Worker/Aidea.Dxp.AI.Worker.csproj' = (New-Project 'Microsoft.NET.Sdk' @('Aidea.Dxp.AI.UseCase.WrittenConversations', 'Aidea.Dxp.AI.Utils') "    <OutputType>Exe</OutputType>`n    <AzureFunctionsVersion>v4</AzureFunctionsVersion>") })
            $res = Invoke-Text $root 'Aidea.Dxp.AI'
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il modello riscrive solo il testo di ""Worker""" {
            Get-RequestedUnits | Should -Be @($Worker)
        }

        It "E il componente nuovo di ""Worker"" ha una descrizione" {
            $res.Text.units.$Worker.elements.aidea_dxp_ai_worker__aidea_dxp_ai_utils | Should -Not -BeNullOrEmpty
        }
    }

    Context "Schema dello scenario: stesura respinta e corretta — <difetto>" -ForEach @(
        @{ difetto = 'un elemento senza descrizione'; spec = @{ omitElement = 'aidea_dxp_ai_api__aidea_dxp_ai_utils' }; motivo = 'elemento senza descrizione: aidea_dxp_ai_api__aidea_dxp_ai_utils' }
        @{ difetto = 'una relazione che il codice non dichiara'; spec = @{ extraRelationship = @{ source = 'aidea_dxp_ai_api__aidea_dxp_ai_utils'; target = 'aidea_dxp_ai_api' } }; motivo = "relazione che il codice non dichiara: aidea_dxp_ai_api__aidea_dxp_ai_utils -> aidea_dxp_ai_api" }
        @{ difetto = 'una persona senza relazioni'; spec = @{ people = @(@{ id = 'cittadino'; name = 'Cittadino'; description = 'Scrive all''ente.'; technical = $false }) }; motivo = 'persona o sistema esterno senza relazioni: cittadino' }
        @{ difetto = 'una relazione che non lega un elemento della parte'; spec = @{ externalSystems = @(@{ id = 'entra'; name = 'Entra'; description = 'Identita''.'; technical = $false }); links = @(@{ source = 'entra'; target = 'aidea_dxp_ai_worker'; description = 'Autentica'; technology = '' }) }; motivo = 'relazione che non lega una persona o un sistema esterno a un elemento della parte: entra -> aidea_dxp_ai_worker' }
        @{ difetto = 'una frase troppo lunga'; spec = @{ longDescription = 'aidea_dxp_ai_api' }; motivo = 'frase di aidea_dxp_ai_api oltre 25 parole' }
    ) {
        BeforeAll {
            Reset-Stub @{ $Api = @($spec, @{}) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root 'Aidea.Dxp.AI' -Environment @{ READABILITY_MAX_WORDS = '25' }
            Remove-Workspace $root
            $apiRequests = @(Get-StubRequests | Where-Object { (Get-UserMessage $_) -match "PARTE DA DESCRIVERE: $Api\b" })
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
    }

    Context "Scenario: testo respinto a ogni stesura" {
        BeforeAll {
            Reset-Stub @{ $Worker = @(@{ omitElement = $Worker }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root 'Aidea.Dxp.AI'
            Remove-Workspace $root
        }

        It "Allora la pipeline fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il container e il motivo" {
            Get-Issues $res.Output | Where-Object { $_ -match "testo di $Worker respinto a ogni stesura \(elemento senza descrizione: $Worker\)" } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il modello riceve tre stesure" {
            @(Get-RequestedUnits | Where-Object { $_ -eq $Worker }).Count | Should -Be 3
        }

        It "E il testo dell'altro container resta accettato" {
            $res.Text.units.$Api.elements.$Api | Should -Not -BeNullOrEmpty
        }

        It "E la parte generata non si scrive" {
            $res.Generated['aidea.dxp.ai.dsl'] | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: modello linguistico non disponibile" {
        BeforeAll {
            Reset-Stub
            Set-StubStatus 503
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root 'Aidea.Dxp.AI'
            Remove-Workspace $root
            $requested = @(Get-RequestedUnits)
            Reset-Stub
        }

        It "Allora la pipeline fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il container non descritto" {
            Get-Issues $res.Output | Where-Object { $_ -match "testo di aidea_dxp_ai_(api|worker) non scritto" } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E non chiama il modello per gli altri container" {
            @($requested | Select-Object -Unique).Count | Should -Be 1
        }
    }

    Context "Scenario: generazione rilanciata" {
        BeforeAll {
            $branch = 'c4/aidea.dxp.ai'
            $origin = New-OriginWorkspace
            $files = New-DescribedEngine
            $files.Remove('docs/STYLE.md')

            Reset-Stub @{ $Worker = @(@{ omitElement = $Worker }) }
            $first = New-Clone $origin $files
            $failed = Invoke-Text $first 'Aidea.Dxp.AI' -Environment @{ PROGRESS_BRANCH = $branch }
            Remove-Workspace $first
            $saved = Get-OriginText $origin $branch

            Reset-Stub
            $second = New-Clone $origin $files
            $res = Invoke-Text $second 'Aidea.Dxp.AI' -Environment @{ PROGRESS_BRANCH = $branch }
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

    Context "Scenario: persone e sistemi esterni" {
        BeforeAll {
            $person = @{ id = 'cittadino'; name = 'Cittadino'; description = 'Scrive all''ente dal sito.'; technical = $false }
            $link = @{ source = 'cittadino'; target = $Api; description = 'Invia i messaggi'; technology = 'HTTPS' }
            Reset-Stub @{ $Api = @(@{ people = @($person); links = @($link) }) }
            $files = New-DescribedEngine
            $bff = New-BffRepository
            $bff.Keys | ForEach-Object { $files["bff/$($_ -replace '^source/', '')"] = $bff[$_] }
            $root = New-Workspace $files
            $res = Invoke-Text $root 'Aidea.Dxp.AI'

            $bffLink = @{ source = 'cittadino'; target = 'aidea_dxp_bff_web'; description = 'Apre la chat'; technology = 'HTTPS' }
            Reset-Stub @{ aidea_dxp_bff_web = @(@{ people = @($person); links = @($bffLink) }, @{ links = @($bffLink) }) }
            $bffResult = Invoke-Text $root 'Aidea.Dxp.Bff.Web' -Environment @{ SOURCE_DIRECTORY = 'bff' }
            $bffRequests = @(Get-StubRequests)
            Remove-Workspace $root
        }

        It "Allora la generazione riesce" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il contesto dichiara la persona" {
            $bffResult.Generated['context.dsl'] | Should -Match 'cittadino = person "Cittadino" "Scrive all''ente dal sito\." ""'
        }

        It "E la parte generata contiene la relazione dalla persona all'applicazione" {
            $res.Generated['aidea.dxp.ai.dsl'] | Should -Match "cittadino -> $Api `"Invia i messaggi`" `"HTTPS`""
        }

        It "E un altro repository trova la persona nel catalogo" {
            Get-UserMessage $bffRequests[0] | Should -Match '- cittadino = Cittadino'
        }

        It "E una stesura che la dichiara di nuovo e' respinta" {
            Get-UserMessage $bffRequests[1] | Should -Match "persona o sistema esterno gia' nel catalogo: cittadino"
        }

        It "E l'altro repository la collega senza dichiararla" {
            $bffResult.Generated['aidea.dxp.bff.web.dsl'] | Should -Match 'cittadino -> aidea_dxp_bff_web "Apre la chat" "HTTPS"'
        }
    }

    Context "Scenario: il modello descritto e' un modello Structurizr valido" {
        BeforeAll {
            $person = @{ id = 'cittadino'; name = 'Cittadino'; description = 'Scrive all''ente dal sito.'; technical = $false }
            $system = @{ id = 'entra'; name = 'Entra External ID'; description = 'Autentica i cittadini.'; technical = $true }
            $links = @(@{ source = 'cittadino'; target = $Api; description = 'Invia i messaggi'; technology = 'HTTPS' }, @{ source = $Api; target = 'entra'; description = 'Valida i token'; technology = 'OpenID Connect' })
            Reset-Stub @{ $Api = @(@{ people = @($person); externalSystems = @($system); links = $links }) }
            $root = New-Workspace (New-DescribedEngine)
            $res = Invoke-Text $root 'Aidea.Dxp.AI'
            Remove-Workspace $root
            $dir = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-text-dsl-$(New-Guid)"
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'generated') | Out-Null
            $res.Generated.Keys | ForEach-Object { [IO.File]::WriteAllText((Join-Path $dir "generated/$_"), $res.Generated[$_]) }
            [IO.File]::WriteAllText((Join-Path $dir 'workspace.dsl'), "workspace {`n    model {`n        !include generated/context.dsl`n        sistema = softwareSystem `"Aidea.Dxp`" {`n            !include generated/aidea.dxp.ai.dsl`n        }`n    }`n}`n")
            $export = Export-StructurizrWorkspace (Join-Path $dir 'workspace.dsl')
            Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
            $model = $export.Workspace.model
        }

        It "Allora il workspace che lo include si esporta senza errori" {
            $export.Error | Should -BeNullOrEmpty
        }

        It "E ogni elemento generato ha una descrizione" {
            $elements = @($model.softwareSystems[0].containers) + @($model.softwareSystems[0].containers | ForEach-Object { @($_.components) })
            $elements | Where-Object { $_ -and -not $_.description } | ForEach-Object name | Should -BeNullOrEmpty
        }

        It "E il sistema esterno porta il tag degli elementi tecnici" {
            ($model.softwareSystems | Where-Object name -EQ 'Entra External ID').tags | Should -Match 'Esterno,Tecnico'
        }

        It "E la relazione dalla persona all'applicazione dice cio' che passa" {
            ($model.people | Where-Object name -EQ 'Cittadino').relationships.description | Should -Contain 'Invia i messaggi'
        }
    }

    Context "Scenario: un container sparisce dal codice" {
        BeforeAll {
            Reset-Stub
            $files = New-DescribedEngine
            $root = New-Workspace $files
            Invoke-Text $root 'Aidea.Dxp.AI' | Out-Null
            Remove-Item -Recurse -Force (Join-Path $root 'source/Aidea.Dxp.AI.Worker')
            Remove-Item -Recurse -Force (Join-Path $root 'fragments')
            Reset-Stub
            $res = Invoke-Text $root 'Aidea.Dxp.AI'
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
            $res = Invoke-Text $root 'Aidea.Dxp.AI' -Environment @{ C4_TEXT_ENDPOINT = '' }
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
}
