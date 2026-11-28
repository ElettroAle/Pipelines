#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/LanguageModel/Anthropic.ps1

.DESCRIPTION
    Il modulo Anthropic del contratto del modello linguistico. L'API Messages e' sostituita da un
    endpoint locale (Fixtures/ModelEndpointStub.ps1) che conserva le richieste e risponde con le
    risposte registrate dal test, e l'API dei modelli con il massimo di uscita del modello; l'attesa fra
    i tentativi e' sostituita da un mock.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/LanguageModel/LanguageModel.ps1"
    . "$PSScriptRoot/Fixtures/ModelEndpointStub.ps1"
    $script:Stub = Start-ModelEndpoint
    $script:PreviousKey = $env:ANTHROPIC_API_KEY

    $script:Schema = @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('diagrams')
        properties           = @{ diagrams = @{ type = 'array'; items = @{ type = 'object'; additionalProperties = $false; required = @('line'); properties = @{ line = @{ type = 'integer' } } } } }
    }

    function New-MessageResponse([string]$Text = '{"diagrams":[]}', [string]$StopReason = 'end_turn', [object[]]$Before = @()) {
        $content = @($Before) + @(@{ type = 'text'; text = $Text })
        return New-ModelResponse 200 @{ id = 'msg_1'; type = 'message'; role = 'assistant'; model = 'claude-sonnet-5-5'; content = $content; stop_reason = $StopReason; usage = @{ input_tokens = 120; output_tokens = 30 } }
    }

    $script:ModelPath = '/v1/models/claude-sonnet-5-5'
    $script:ModelMaxTokens = 64000

    function New-ModelInfo([int]$MaxTokens = $ModelMaxTokens) {
        return New-ModelResponse 200 @{ type = 'model'; id = 'claude-sonnet-5-5'; display_name = 'Claude Sonnet 5.5'; max_input_tokens = 1000000; max_tokens = $MaxTokens }
    }

    function Reset-Messages([object[]]$Responses, $ModelInfo = (New-ModelInfo)) {
        Reset-ModelEndpoint $Stub $Responses @{ $ModelPath = $ModelInfo }
    }

    function ConvertTo-EventStream([object[]]$Events) {
        return ($Events | ForEach-Object { "event: $($_.type)`ndata: $($_ | ConvertTo-Json -Depth 20 -Compress)`n`n" }) -join ''
    }

    function New-TimeoutResponse {
        return New-ModelResponse 504 @{ type = 'error'; error = @{ type = 'timeout_error'; message = 'tempo scaduto' } }
    }

    function New-StreamResponse([string]$Text = '{"diagrams":[]}', [string]$StopReason = 'end_turn', [switch]$Unfinished) {
        $events = @(
            @{ type = 'message_start'; message = @{ id = 'msg_1'; type = 'message'; role = 'assistant'; model = 'claude-sonnet-5-5'; content = @(); stop_reason = $null; usage = @{ input_tokens = 120; output_tokens = 1 } } }
            @{ type = 'content_block_start'; index = 0; content_block = @{ type = 'thinking'; thinking = ''; signature = '' } }
            @{ type = 'content_block_delta'; index = 0; delta = @{ type = 'signature_delta'; signature = 'firma' } }
            @{ type = 'content_block_stop'; index = 0 }
            @{ type = 'ping' }
            @{ type = 'content_block_start'; index = 1; content_block = @{ type = 'text'; text = '' } }
        )
        $half = [math]::Floor($Text.Length / 2)
        foreach ($part in $Text.Substring(0, $half), $Text.Substring($half)) { $events += @{ type = 'content_block_delta'; index = 1; delta = @{ type = 'text_delta'; text = $part } } }
        $events += @{ type = 'content_block_stop'; index = 1 }
        $events += @{ type = 'message_delta'; delta = @{ stop_reason = $StopReason; stop_sequence = $null }; usage = @{ output_tokens = 30 } }
        if (-not $Unfinished) { $events += @{ type = 'message_stop' } }
        return New-ModelResponse 200 (ConvertTo-EventStream $events)
    }

    function New-Client([hashtable]$Options = @{}) {
        $parameters = @{ Provider = 'anthropic'; Endpoint = $Stub.Endpoint; Model = 'claude-sonnet-5-5' }
        foreach ($name in $Options.Keys) { $parameters[$name] = $Options[$name] }
        return New-LanguageModel @parameters
    }

    function Invoke-Model($Client = (New-Client)) {
        return Invoke-LanguageModel $Client 'istruzioni' 'domanda' $Schema 'diagram_flows_repair'
    }
}

AfterAll {
    Stop-ModelEndpoint $Stub
    $env:ANTHROPIC_API_KEY = $PreviousKey
}

Describe "Anthropic — richiesta" {

    BeforeAll {
        $env:ANTHROPIC_API_KEY = 'chiave-di-prova'
        Reset-Messages @(New-MessageResponse)
        Invoke-Model (New-Client @{ ReasoningEffort = 'xhigh'; Seed = 7 }) | Out-Null
        $request = (Get-ModelEndpointRequests $Stub)[0]
    }

    It "Chiama l'API Messages dell'endpoint dichiarato" {
        $request.Path | Should -Be '/v1/messages'
    }

    It "Si autentica con la chiave Anthropic e dichiara la versione dell'API" {
        $request.Headers.'x-api-key' | Should -Be 'chiave-di-prova'
        $request.Headers.'anthropic-version' | Should -Be '2026-10-21'
        $request.Headers.PSObject.Properties.Name | Should -Not -Contain 'authorization'
    }

    It "Chiede il modello dichiarato senza streaming" {
        $request.Body.model | Should -Be 'claude-sonnet-5-5'
        $request.Body.PSObject.Properties.Name | Should -Not -Contain 'stream'
    }

    It "Manda le istruzioni come system e la domanda come unico messaggio dell'utente" {
        $request.Body.system | Should -Be 'istruzioni'
        @($request.Body.messages).Count | Should -Be 1
        $request.Body.messages[0].role | Should -Be 'user'
        $request.Body.messages[0].content | Should -Be 'domanda'
    }

    It "Chiede la risposta nello schema dato, senza cambiarlo" {
        $request.Body.output_config.format.type | Should -Be 'json_schema'
        ($request.Body.output_config.format.schema | ConvertTo-Json -Depth 20 -Compress) | Should -Be ($Schema | ConvertTo-Json -Depth 20 | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress)
    }

    It "Manda il livello di ragionamento come effort" {
        $request.Body.output_config.effort | Should -Be 'xhigh'
    }

    It "Non manda campionamento, seme, configurazione del ragionamento né risposte precompilate" {
        $names = $request.Body.PSObject.Properties.Name
        foreach ($name in 'temperature', 'top_p', 'top_k', 'seed', 'thinking', 'response_format') { $names | Should -Not -Contain $name }
        @($request.Body.messages | Where-Object role -EQ 'assistant').Count | Should -Be 0
    }
}

Describe "Anthropic — opzioni" {

    BeforeEach {
        $env:ANTHROPIC_API_KEY = 'chiave-di-prova'
        Reset-Messages @(New-MessageResponse)
    }

    It "Senza livello di ragionamento non manda effort" {
        Invoke-Model | Out-Null
        (Get-ModelEndpointRequests $Stub)[0].Body.output_config.PSObject.Properties.Name | Should -Not -Contain 'effort'
    }

    It "Usa il limite di token dichiarato" {
        Invoke-Model (New-Client @{ MaxTokens = 8000 }) | Out-Null
        (Get-ModelEndpointRequests $Stub)[0].Body.max_tokens | Should -Be 8000
    }

    It "Senza endpoint usa l'API pubblica di Anthropic" {
        (New-Client @{ Endpoint = ''; MaxTokens = 8000 }).Endpoint | Should -Be 'https://api.anthropic.com'
    }

    It "Toglie la barra finale dall'endpoint" {
        Invoke-Model (New-Client @{ Endpoint = "$($Stub.Endpoint)/" }) | Out-Null
        (Get-ModelEndpointRequests $Stub)[0].Path | Should -Be '/v1/messages'
    }
}

Describe "Anthropic — tetto della risposta" {

    BeforeEach { $env:ANTHROPIC_API_KEY = 'chiave-di-prova' }

    It "Senza un tetto dichiarato la richiesta porta il massimo di uscita letto dall'API dei modelli" {
        Reset-Messages @(New-MessageResponse) (New-ModelInfo 128000)
        Invoke-Model | Out-Null
        (Get-ModelEndpointRequests $Stub)[0].Body.max_tokens | Should -Be 128000
    }

    It "Legge il massimo dall'API dei modelli con la chiave e la versione dell'API delle richieste" {
        Reset-Messages @(New-MessageResponse)
        New-Client | Out-Null
        $read = @(Get-ModelEndpointRequests $Stub -Routed)
        $read.Count | Should -Be 1
        $read[0].Method | Should -Be 'GET'
        $read[0].Path | Should -Be $ModelPath
        $read[0].Headers.'x-api-key' | Should -Be 'chiave-di-prova'
        $read[0].Headers.'anthropic-version' | Should -Be '2026-10-21'
    }

    It "Con un tetto dichiarato la richiesta porta quello e l'API dei modelli non si legge" {
        Reset-Messages @(New-MessageResponse)
        Invoke-Model (New-Client @{ MaxTokens = 8000 }) | Out-Null
        (Get-ModelEndpointRequests $Stub)[0].Body.max_tokens | Should -Be 8000
        Get-ModelEndpointRequests $Stub -Routed | Should -BeNullOrEmpty
    }

    It "Una lettura fallita del massimo è un errore del modulo che nomina il modello e il motivo" {
        Reset-Messages @(New-MessageResponse) (New-ModelResponse 404 @{ type = 'error'; error = @{ type = 'not_found_error'; message = 'modello sconosciuto' } })
        { New-Client } | Should -Throw '*massimo di uscita di claude-sonnet-5-5*404*modello sconosciuto*'
    }

    It "Un modello senza massimo di uscita dichiarato è un errore del modulo" {
        Reset-Messages @(New-MessageResponse) (New-ModelResponse 200 @{ type = 'model'; id = 'claude-sonnet-5-5'; max_tokens = $null })
        { New-Client } | Should -Throw '*massimo di uscita di claude-sonnet-5-5*'
    }
}

Describe "Anthropic — streaming" {

    BeforeEach {
        $env:ANTHROPIC_API_KEY = 'chiave-di-prova'
        Mock Start-Sleep {}
    }

    It "Se l'API chiude la richiesta per il tempo, la ripete in streaming e ricompone la risposta" {
        Reset-Messages @((New-TimeoutResponse), (New-StreamResponse '{"diagrams":[{"line":9}]}'))
        $result = Invoke-Model
        $requests = @(Get-ModelEndpointRequests $Stub)
        $requests.Count | Should -Be 2
        $requests[1].Path | Should -Be '/v1/messages'
        $requests[1].Body.stream | Should -BeTrue
        $requests[1].Body.max_tokens | Should -Be $ModelMaxTokens
        $requests[1].Body.output_config.format.type | Should -Be 'json_schema'
        $requests[1].Headers.'x-api-key' | Should -Be 'chiave-di-prova'
        $requests[1].Headers.'anthropic-version' | Should -Be '2026-10-21'
        $result.Response.diagrams[0].line | Should -Be 9
        $result.Usage.Input | Should -Be 120
        $result.Usage.Output | Should -Be 30
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It "Se la risposta non arriva entro il tempo massimo della richiesta, la ripete in streaming" {
        Reset-Messages @((New-ModelResponse 200 @{} @{} 3), (New-StreamResponse '{"diagrams":[{"line":2}]}'))
        $result = Invoke-Model (New-Client @{ TimeoutSeconds = 2; MaxTokens = 8000 })
        $requests = @(Get-ModelEndpointRequests $Stub)
        $requests.Count | Should -Be 2
        $requests[0].Body.PSObject.Properties.Name | Should -Not -Contain 'stream'
        $requests[1].Body.stream | Should -BeTrue
        $result.Response.diagrams[0].line | Should -Be 2
    }

    It "Una risposta in streaming interrotta per max_tokens resta un errore" {
        Reset-Messages @((New-TimeoutResponse), (New-StreamResponse '{"diagr' 'max_tokens'))
        { Invoke-Model } | Should -Throw '*stop_reason max_tokens*'
    }

    It "Un errore nello stream è un errore che lo nomina" {
        $stream = ConvertTo-EventStream @(@{ type = 'message_start'; message = @{ content = @(); usage = @{ input_tokens = 1; output_tokens = 1 } } }, @{ type = 'error'; error = @{ type = 'overloaded_error'; message = 'Overloaded' } })
        Reset-Messages @((New-TimeoutResponse), (New-ModelResponse 200 $stream))
        { Invoke-Model } | Should -Throw '*overloaded_error*Overloaded*'
    }

    It "Uno stream chiuso prima della fine della risposta è un errore" {
        Reset-Messages @((New-TimeoutResponse), (New-StreamResponse -Unfinished))
        { Invoke-Model } | Should -Throw '*prima della fine*'
    }

    It "Ripete in streaming una richiesta rifiutata dal limite di frequenza dopo l'attesa di retry-after" {
        $limited = New-ModelResponse 429 @{ type = 'error'; error = @{ type = 'rate_limit_error'; message = 'lento' } } @{ 'retry-after' = '5' }
        Reset-Messages @((New-TimeoutResponse), $limited, (New-StreamResponse))
        Invoke-Model | Out-Null
        $requests = @(Get-ModelEndpointRequests $Stub)
        $requests.Count | Should -Be 3
        $requests[2].Body.stream | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It "Una richiesta in streaming respinta riporta il messaggio dell'API" {
        Reset-Messages @((New-TimeoutResponse), (New-ModelResponse 400 @{ type = 'error'; error = @{ type = 'invalid_request_error'; message = 'schema non valido' } }))
        { Invoke-Model } | Should -Throw '*400*schema non valido*'
    }
}

Describe "Anthropic — risposta" {

    BeforeEach { $env:ANTHROPIC_API_KEY = 'chiave-di-prova' }

    It "Legge il primo blocco di testo dopo i blocchi di ragionamento" {
        $thinking = @{ type = 'thinking'; thinking = ''; signature = 'firma' }
        Reset-Messages @(New-MessageResponse '{"diagrams":[{"line":4}]}' 'end_turn' @($thinking, $thinking))
        $result = Invoke-Model
        $result.Response.diagrams[0].line | Should -Be 4
    }

    It "Restituisce i token in ingresso e in uscita" {
        Reset-Messages @(New-MessageResponse)
        $result = Invoke-Model
        $result.Usage.Input | Should -Be 120
        $result.Usage.Output | Should -Be 30
    }

    It "Un rifiuto del modello è un errore che lo nomina" {
        $refusal = New-MessageResponse '' 'refusal'
        $refusal.body.stop_details = @{ type = 'refusal'; category = 'cyber' }
        Reset-Messages @($refusal)
        { Invoke-Model } | Should -Throw '*refusal*cyber*'
    }

    It "Una risposta troncata dal limite di token è un errore che lo nomina" {
        Reset-Messages @(New-MessageResponse '{"diagr' 'max_tokens')
        { Invoke-Model } | Should -Throw '*max_tokens*'
    }

    It "Una risposta senza testo è un errore" {
        Reset-Messages @(New-ModelResponse 200 @{ content = @(@{ type = 'thinking'; thinking = '' }); stop_reason = 'end_turn'; usage = @{ input_tokens = 1; output_tokens = 1 } })
        { Invoke-Model } | Should -Throw '*senza testo*'
    }
}

Describe "Anthropic — errori transitori" {

    BeforeEach {
        $env:ANTHROPIC_API_KEY = 'chiave-di-prova'
        Mock Start-Sleep {}
    }

    It "Ripete una richiesta rifiutata dal limite di frequenza dopo l'attesa di retry-after" {
        Reset-Messages @((New-ModelResponse 429 @{ type = 'error'; error = @{ type = 'rate_limit_error'; message = 'lento' } } @{ 'retry-after' = '7' }), (New-MessageResponse))
        $result = Invoke-Model
        $result.Response.diagrams | Should -BeNullOrEmpty
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be 2
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
    }

    It "Ripete una richiesta rifiutata perché l'API è sovraccarica (529)" {
        Reset-Messages @((New-ModelResponse 529 @{ type = 'error'; error = @{ type = 'overloaded_error'; message = 'piena' } }), (New-MessageResponse))
        Invoke-Model | Out-Null
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be 2
    }

    It "Ripete una richiesta fallita per un errore del server" {
        Reset-Messages @((New-ModelResponse 500 @{ type = 'error'; error = @{ type = 'api_error'; message = 'guasto' } }), (New-MessageResponse))
        Invoke-Model | Out-Null
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be 2
    }

    It "Si ferma dopo il numero massimo di tentativi" {
        Reset-Messages @(New-ModelResponse 503 @{ type = 'error'; error = @{ type = 'api_error'; message = 'giu' } })
        { Invoke-Model } | Should -Throw '*503*'
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be $ModelMaxAttempts
    }

    It "Non ripete una richiesta respinta e riporta il messaggio dell'API" {
        Reset-Messages @(New-ModelResponse 400 @{ type = 'error'; error = @{ type = 'invalid_request_error'; message = 'schema non valido' } })
        { Invoke-Model } | Should -Throw '*400*schema non valido*'
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be 1
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}

# Il comportamento atteso del Bug 2218 «La rigenerazione della documentazione si blocca dopo ogni modifica dei
# passi» per il modulo Anthropic, un It per ogni Allora e ogni E.
Describe "Funzionalità: Il tetto di una risposta Anthropic è il massimo del modello" {

    Context "Scenario: un passo che non dichiara un tetto chiede una risposta lunga" {
        BeforeAll {
            $env:ANTHROPIC_API_KEY = 'chiave-di-prova'
            Reset-Messages @((New-TimeoutResponse), (New-StreamResponse '{"diagrams":[{"line":40000}]}')) (New-ModelInfo 128000)
            $result = Invoke-LanguageModel (New-LanguageModel -Provider 'anthropic' -Endpoint $Stub.Endpoint -Model 'claude-sonnet-5-5') 'istruzioni' 'domanda' $Schema 'diagram_flows_repair'
            $requests = @(Get-ModelEndpointRequests $Stub)
        }

        It "Allora la richiesta porta come tetto il massimo di uscita del modello" {
            $requests | ForEach-Object { $_.Body.max_tokens | Should -Be 128000 }
        }

        It "E una risposta che supera il vecchio tetto fisso arriva intera, anche in streaming" {
            $requests[-1].Body.stream | Should -BeTrue
            $result.Response.diagrams[0].line | Should -Be 40000
        }
    }

    Context "Scenario: il modello esaurisce il tetto" {
        BeforeAll {
            $env:ANTHROPIC_API_KEY = 'chiave-di-prova'
            Reset-Messages @(New-MessageResponse '{"diagr' 'max_tokens')
        }

        It "Allora la risposta interrotta per max_tokens resta un errore" {
            { Invoke-Model } | Should -Throw '*stop_reason max_tokens*'
        }
    }
}

Describe "Anthropic — configurazione" {

    It "Senza chiave Anthropic il client non nasce e l'errore nomina la chiave" {
        $env:ANTHROPIC_API_KEY = ''
        { New-Client } | Should -Throw 'chiave Anthropic non configurata (ANTHROPIC_API_KEY)'
    }

    It "Una variabile della pipeline non definita, rimasta come macro, vale come chiave mancante" {
        $env:ANTHROPIC_API_KEY = '$(anthropicApiKey)'
        { New-Client } | Should -Throw 'chiave Anthropic non configurata (ANTHROPIC_API_KEY)'
    }

    It "Senza modello il client non nasce" {
        $env:ANTHROPIC_API_KEY = 'chiave-di-prova'
        { New-Client @{ Model = '' } } | Should -Throw 'modello non configurato'
    }
}
