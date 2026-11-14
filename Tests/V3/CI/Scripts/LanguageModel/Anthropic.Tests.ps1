#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/LanguageModel/Anthropic.ps1

.DESCRIPTION
    Il modulo Anthropic del contratto del modello linguistico. L'API Messages e' sostituita da un
    endpoint locale (Fixtures/ModelEndpointStub.ps1) che conserva le richieste e risponde con le
    risposte registrate dal test; l'attesa fra i tentativi e' sostituita da un mock.
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
        Reset-ModelEndpoint $Stub @(New-MessageResponse)
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

    It "Chiede il modello dichiarato con il limite di token predefinito" {
        $request.Body.model | Should -Be 'claude-sonnet-5-5'
        $request.Body.max_tokens | Should -Be 32000
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
        Reset-ModelEndpoint $Stub @(New-MessageResponse)
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
        (New-Client @{ Endpoint = '' }).Endpoint | Should -Be 'https://api.anthropic.com'
    }

    It "Toglie la barra finale dall'endpoint" {
        Invoke-Model (New-Client @{ Endpoint = "$($Stub.Endpoint)/" }) | Out-Null
        (Get-ModelEndpointRequests $Stub)[0].Path | Should -Be '/v1/messages'
    }
}

Describe "Anthropic — risposta" {

    BeforeEach { $env:ANTHROPIC_API_KEY = 'chiave-di-prova' }

    It "Legge il primo blocco di testo dopo i blocchi di ragionamento" {
        $thinking = @{ type = 'thinking'; thinking = ''; signature = 'firma' }
        Reset-ModelEndpoint $Stub @(New-MessageResponse '{"diagrams":[{"line":4}]}' 'end_turn' @($thinking, $thinking))
        $result = Invoke-Model
        $result.Response.diagrams[0].line | Should -Be 4
    }

    It "Restituisce i token in ingresso e in uscita" {
        Reset-ModelEndpoint $Stub @(New-MessageResponse)
        $result = Invoke-Model
        $result.Usage.Input | Should -Be 120
        $result.Usage.Output | Should -Be 30
    }

    It "Un rifiuto del modello è un errore che lo nomina" {
        $refusal = New-MessageResponse '' 'refusal'
        $refusal.body.stop_details = @{ type = 'refusal'; category = 'cyber' }
        Reset-ModelEndpoint $Stub @($refusal)
        { Invoke-Model } | Should -Throw '*refusal*cyber*'
    }

    It "Una risposta troncata dal limite di token è un errore che lo nomina" {
        Reset-ModelEndpoint $Stub @(New-MessageResponse '{"diagr' 'max_tokens')
        { Invoke-Model } | Should -Throw '*max_tokens*'
    }

    It "Una risposta senza testo è un errore" {
        Reset-ModelEndpoint $Stub @(New-ModelResponse 200 @{ content = @(@{ type = 'thinking'; thinking = '' }); stop_reason = 'end_turn'; usage = @{ input_tokens = 1; output_tokens = 1 } })
        { Invoke-Model } | Should -Throw '*senza testo*'
    }
}

Describe "Anthropic — errori transitori" {

    BeforeEach {
        $env:ANTHROPIC_API_KEY = 'chiave-di-prova'
        Mock Start-Sleep {}
    }

    It "Ripete una richiesta rifiutata dal limite di frequenza dopo l'attesa di retry-after" {
        Reset-ModelEndpoint $Stub @((New-ModelResponse 429 @{ type = 'error'; error = @{ type = 'rate_limit_error'; message = 'lento' } } @{ 'retry-after' = '7' }), (New-MessageResponse))
        $result = Invoke-Model
        $result.Response.diagrams | Should -BeNullOrEmpty
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be 2
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
    }

    It "Ripete una richiesta rifiutata perché l'API è sovraccarica (529)" {
        Reset-ModelEndpoint $Stub @((New-ModelResponse 529 @{ type = 'error'; error = @{ type = 'overloaded_error'; message = 'piena' } }), (New-MessageResponse))
        Invoke-Model | Out-Null
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be 2
    }

    It "Ripete una richiesta fallita per un errore del server" {
        Reset-ModelEndpoint $Stub @((New-ModelResponse 500 @{ type = 'error'; error = @{ type = 'api_error'; message = 'guasto' } }), (New-MessageResponse))
        Invoke-Model | Out-Null
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be 2
    }

    It "Si ferma dopo il numero massimo di tentativi" {
        Reset-ModelEndpoint $Stub @(New-ModelResponse 503 @{ type = 'error'; error = @{ type = 'api_error'; message = 'giu' } })
        { Invoke-Model } | Should -Throw '*503*'
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be $ModelMaxAttempts
    }

    It "Non ripete una richiesta respinta e riporta il messaggio dell'API" {
        Reset-ModelEndpoint $Stub @(New-ModelResponse 400 @{ type = 'error'; error = @{ type = 'invalid_request_error'; message = 'schema non valido' } })
        { Invoke-Model } | Should -Throw '*400*schema non valido*'
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be 1
        Should -Invoke Start-Sleep -Times 0 -Exactly
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
