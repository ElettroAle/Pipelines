#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/LanguageModel/Foundry.ps1

.DESCRIPTION
    Il modulo Foundry del contratto del modello linguistico. Le chat completions di Azure OpenAI sono
    sostituite da un endpoint locale (Fixtures/ModelEndpointStub.ps1) che conserva le richieste e
    risponde con le risposte registrate dal test; la Azure CLI e l'attesa fra i tentativi sono mock.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/LanguageModel/LanguageModel.ps1"
    . "$PSScriptRoot/Fixtures/ModelEndpointStub.ps1"
    $script:Stub = Start-ModelEndpoint

    $script:Schema = @{ type = 'object'; additionalProperties = $false; required = @('ok'); properties = @{ ok = @{ type = 'boolean' } } }

    function New-CompletionResponse([string]$Content = '{"ok":true}') {
        return New-ModelResponse 200 @{ choices = @(@{ message = @{ role = 'assistant'; content = $Content } }); usage = @{ prompt_tokens = 100; completion_tokens = 10 } }
    }

    function New-Client([hashtable]$Options = @{}) {
        $parameters = @{ Provider = 'foundry'; Endpoint = $Stub.Endpoint; Model = 'giudice'; AccessToken = 'token-di-prova' }
        foreach ($name in $Options.Keys) { $parameters[$name] = $Options[$name] }
        return New-LanguageModel @parameters
    }

    function Invoke-Model($Client = (New-Client)) {
        return Invoke-LanguageModel $Client 'istruzioni' 'domanda' $Schema 'style_findings'
    }
}

AfterAll { Stop-ModelEndpoint $Stub }

Describe "Foundry — richiesta" {

    BeforeAll {
        Reset-ModelEndpoint $Stub @(New-CompletionResponse)
        Invoke-Model (New-Client @{ ReasoningEffort = 'high' }) | Out-Null
        $request = (Get-ModelEndpointRequests $Stub)[0]
    }

    It "Chiama le chat completions dell'endpoint Foundry" {
        $request.Path | Should -Be '/openai/v1/chat/completions'
    }

    It "Si autentica con il token Entra ID" {
        $request.Headers.authorization | Should -Be 'Bearer token-di-prova'
    }

    It "Chiede il deployment dichiarato con le istruzioni e la domanda" {
        $request.Body.model | Should -Be 'giudice'
        $request.Body.messages[0].role | Should -Be 'system'
        $request.Body.messages[0].content | Should -Be 'istruzioni'
        $request.Body.messages[1].role | Should -Be 'user'
        $request.Body.messages[1].content | Should -Be 'domanda'
    }

    It "Chiede la risposta nello schema dato, in modalità stretta e con il suo nome" {
        $request.Body.response_format.type | Should -Be 'json_schema'
        $request.Body.response_format.json_schema.name | Should -Be 'style_findings'
        $request.Body.response_format.json_schema.strict | Should -BeTrue
        $request.Body.response_format.json_schema.schema.required | Should -Be @('ok')
    }

    It "Manda il livello di ragionamento" {
        $request.Body.reasoning_effort | Should -Be 'high'
    }
}

Describe "Foundry — risposta e opzioni" {

    BeforeEach { Reset-ModelEndpoint $Stub @(New-CompletionResponse) }

    It "Restituisce la risposta letta e i token usati" {
        $result = Invoke-Model
        $result.Response.ok | Should -BeTrue
        $result.Usage.Input | Should -Be 100
        $result.Usage.Output | Should -Be 10
    }

    It "Senza livello di ragionamento né seme non li manda" {
        Invoke-Model | Out-Null
        $names = (Get-ModelEndpointRequests $Stub)[0].Body.PSObject.Properties.Name
        $names | Should -Not -Contain 'reasoning_effort'
        $names | Should -Not -Contain 'seed'
    }

    It "Manda il seme dichiarato" {
        Invoke-Model (New-Client @{ Seed = 7 }) | Out-Null
        (Get-ModelEndpointRequests $Stub)[0].Body.seed | Should -Be 7
    }

    It "Senza token dichiarato lo chiede alla Azure CLI una volta sola" {
        Mock az { $global:LASTEXITCODE = 0; 'token-da-az' }
        $client = New-Client @{ AccessToken = '' }
        Invoke-Model $client | Out-Null
        Invoke-Model $client | Out-Null
        Get-ModelEndpointRequests $Stub | ForEach-Object { $_.Headers.authorization | Should -Be 'Bearer token-da-az' }
        Should -Invoke az -Times 1 -Exactly
    }

    It "Un token non ottenuto dalla Azure CLI è un errore" {
        Mock az { $global:LASTEXITCODE = 1; 'accesso negato' }
        { Invoke-Model (New-Client @{ AccessToken = '' }) } | Should -Throw '*token Entra ID non ottenuto*accesso negato*'
    }
}

Describe "Foundry — seme non supportato" {

    It "Riprova senza seme se il modello lo rifiuta, e non lo manda più" {
        $rejected = New-ModelResponse 400 @{ error = @{ message = "Unsupported parameter: 'seed'" } }
        Reset-ModelEndpoint $Stub @($rejected, (New-CompletionResponse))
        $client = New-Client @{ Seed = 1 }
        Invoke-Model $client | Out-Null
        Invoke-Model $client | Out-Null
        $requests = Get-ModelEndpointRequests $Stub
        $requests.Count | Should -Be 3
        $requests[0].Body.seed | Should -Be 1
        $requests | Select-Object -Skip 1 | ForEach-Object { $_.Body.PSObject.Properties.Name | Should -Not -Contain 'seed' }
    }

    It "Un 400 senza seme non si ripete" {
        Reset-ModelEndpoint $Stub @(New-ModelResponse 400 @{ error = @{ message = 'schema non valido' } })
        { Invoke-Model } | Should -Throw
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be 1
    }
}

Describe "Foundry — errori transitori" {

    BeforeEach { Mock Start-Sleep {} }

    It "Ripete una richiesta rifiutata dal limite di token al minuto dopo l'attesa di Retry-After" {
        Reset-ModelEndpoint $Stub @((New-ModelResponse 429 @{ error = @{ message = 'lento' } } @{ 'Retry-After' = '5' }), (New-CompletionResponse))
        (Invoke-Model).Response.ok | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It "Si ferma dopo il numero massimo di tentativi" {
        Reset-ModelEndpoint $Stub @(New-ModelResponse 503 @{ error = @{ message = 'giu' } })
        { Invoke-Model } | Should -Throw
        @(Get-ModelEndpointRequests $Stub).Count | Should -Be $ModelMaxAttempts
    }
}

Describe "Foundry — configurazione" {

    It "Senza endpoint il client non nasce" {
        { New-Client @{ Endpoint = '' } } | Should -Throw 'endpoint o modello non configurati'
    }

    It "Senza modello il client non nasce" {
        { New-Client @{ Model = '' } } | Should -Throw 'endpoint o modello non configurati'
    }
}
