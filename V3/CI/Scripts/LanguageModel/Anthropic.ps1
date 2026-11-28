# SPDX-License-Identifier: Apache-2.0

# Modulo Anthropic del contratto del modello linguistico (LanguageModel.ps1): API Messages a consumo,
# autenticata con la chiave in ANTHROPIC_API_KEY, con la risposta in output_config.format json_schema e
# il livello di ragionamento in output_config.effort. Niente campionamento, seme o configurazione del
# ragionamento: con la versione dell'API dichiarata i modelli li rifiutano. Un rifiuto o una risposta
# troncata sono errori: nessun altro modello risponde al posto di quello scelto.

$AnthropicDefaultEndpoint = 'https://api.anthropic.com'
$AnthropicApiVersion = '2026-10-21'
$AnthropicFailedStops = @('refusal', 'max_tokens')

function Initialize-AnthropicLanguageModel($Client) {
    if (-not $Client.Model) { throw 'modello non configurato' }
    # Una variabile della pipeline non definita arriva come la sua macro, $(nome), non come stringa vuota.
    if (-not $env:ANTHROPIC_API_KEY -or $env:ANTHROPIC_API_KEY -match '^\$\(.+\)$') { throw 'chiave Anthropic non configurata (ANTHROPIC_API_KEY)' }
    $Client.ApiKey = $env:ANTHROPIC_API_KEY
    if (-not $Client.Endpoint) { $Client.Endpoint = $AnthropicDefaultEndpoint }
    if ($Client.MaxTokens -le 0) { $Client.MaxTokens = Get-AnthropicModelMaxTokens $Client }
}

function Get-AnthropicHeaders($Client) {
    return @{ 'x-api-key' = $Client.ApiKey; 'anthropic-version' = $AnthropicApiVersion }
}

# Il ragionamento conta nel tetto: un numero fisso scarta risposte gia' pagate quando il modello ragiona piu'
# a lungo, mentre il massimo del modello costa solo i token usati.
function Get-AnthropicModelMaxTokens($Client) {
    $uri = "$($Client.Endpoint)/v1/models/$([uri]::EscapeDataString($Client.Model))"
    try { $model = Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-AnthropicHeaders $Client) -TimeoutSec $Client.TimeoutSeconds }
    catch {
        $status = [int]$_.Exception.Response.StatusCode
        $reason = if ($status) { "($status): $($_.ErrorDetails.Message)" } else { "($($_.Exception.Message))" }
        throw "massimo di uscita di $($Client.Model) non letto dall'API dei modelli $reason"
    }
    if ([int]$model.max_tokens -le 0) { throw "massimo di uscita di $($Client.Model) non dichiarato dall'API dei modelli" }
    return [int]$model.max_tokens
}

function New-AnthropicRequest($Client, [string]$System, [string]$User, $Schema) {
    $outputConfig = [ordered]@{ format = @{ type = 'json_schema'; schema = $Schema } }
    if ($Client.ReasoningEffort) { $outputConfig.effort = $Client.ReasoningEffort }
    return [ordered]@{
        model         = $Client.Model
        max_tokens    = $Client.MaxTokens
        system        = $System
        messages      = @(@{ role = 'user'; content = $User })
        output_config = $outputConfig
    }
}

function Read-AnthropicResponse($Client, $Response) {
    if ($Response.stop_reason -in $AnthropicFailedStops) {
        $category = if ($Response.stop_details.category) { " ($($Response.stop_details.category))" } else { '' }
        throw "risposta di $($Client.Model) interrotta: stop_reason $($Response.stop_reason)$category"
    }
    $text = @($Response.content | Where-Object type -EQ 'text') | Select-Object -First 1
    if (-not $text) { throw "risposta di $($Client.Model) senza testo" }
    return @{
        Response = $text.text | ConvertFrom-Json
        Usage    = @{ Input = [int]$Response.usage.input_tokens; Output = [int]$Response.usage.output_tokens }
    }
}

# Il tempo scaduto, del client o dell'API (timeout_error), e' quello di una risposta lunga senza streaming.
function Test-AnthropicTimeout($ErrorRecord) {
    $exception = $ErrorRecord.Exception
    if ($exception -is [TimeoutException] -or $exception.InnerException -is [TimeoutException]) { return $true }
    try { return (ConvertFrom-Json "$($ErrorRecord.ErrorDetails.Message)").error.type -eq 'timeout_error' }
    catch { return $false }
}

function New-AnthropicFailure($ErrorRecord, $Response, [string]$Detail) {
    return @{ Status = [int]$Response.StatusCode; HttpResponse = $Response; Detail = $Detail; Error = $ErrorRecord; TimedOut = $false }
}

function Invoke-AnthropicMessage($Client, [byte[]]$Body) {
    try {
        $response = Invoke-RestMethod -Method Post -Uri "$($Client.Endpoint)/v1/messages" -Body $Body `
            -ContentType 'application/json' -Headers (Get-AnthropicHeaders $Client) -TimeoutSec $Client.TimeoutSeconds
        return @{ Response = $response }
    }
    catch {
        $failure = New-AnthropicFailure $_ $_.Exception.Response "$($_.ErrorDetails.Message)"
        $failure.TimedOut = Test-AnthropicTimeout $_
        return $failure
    }
}

function Wait-AnthropicTask($Task, [int]$TimeoutSeconds) {
    if (-not $Task.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) { throw [TimeoutException]::new("nessuna risposta di Anthropic in $TimeoutSeconds secondi") }
    return $Task.Result
}

# Il tempo massimo vale fra un evento e il successivo: uno stream lungo resta aperto finche' il modello scrive.
function Invoke-AnthropicStream($Client, [byte[]]$Body) {
    $http = [Net.Http.HttpClient]::new()
    $http.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$($Client.Endpoint)/v1/messages")
        $request.Content = [Net.Http.ByteArrayContent]::new($Body)
        $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
        foreach ($header in (Get-AnthropicHeaders $Client).GetEnumerator()) { $request.Headers.Add($header.Key, $header.Value) }
        try { $response = Wait-AnthropicTask $http.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead) $Client.TimeoutSeconds }
        catch { return New-AnthropicFailure $_ $null '' }
        if (-not $response.IsSuccessStatusCode) {
            return New-AnthropicFailure $null $response (Wait-AnthropicTask $response.Content.ReadAsStringAsync() $Client.TimeoutSeconds)
        }
        $reader = [IO.StreamReader]::new((Wait-AnthropicTask $response.Content.ReadAsStreamAsync() $Client.TimeoutSeconds), [Text.Encoding]::UTF8)
        return @{ Response = Read-AnthropicStream $reader $Client.TimeoutSeconds }
    }
    finally { $http.Dispose() }
}

function Set-AnthropicField($Object, [string]$Name, $Value) {
    $Object | Add-Member -Force -NotePropertyName $Name -NotePropertyValue $Value
}

# Ricompone dagli eventi del server la stessa risposta dell'API senza streaming: i blocchi di contenuto in ordine
# di indice, il testo dai text_delta, stop_reason e token in uscita dall'ultimo message_delta.
function Read-AnthropicStream([IO.StreamReader]$Reader, [int]$TimeoutSeconds) {
    $message = $null
    $blocks = [ordered]@{}
    $texts = @{}
    $finished = $false
    while ($null -ne ($line = Wait-AnthropicTask $Reader.ReadLineAsync() $TimeoutSeconds)) {
        if (-not $line.StartsWith('data:')) { continue }
        $event = $line.Substring(5).Trim() | ConvertFrom-Json
        switch ($event.type) {
            'message_start' { $message = $event.message }
            'content_block_start' {
                $blocks["$($event.index)"] = $event.content_block
                $texts["$($event.index)"] = [Text.StringBuilder]::new()
            }
            'content_block_delta' { if ($event.delta.type -eq 'text_delta') { [void]$texts["$($event.index)"].Append($event.delta.text) } }
            'message_delta' {
                Set-AnthropicField $message 'stop_reason' $event.delta.stop_reason
                if ($event.delta.stop_details) { Set-AnthropicField $message 'stop_details' $event.delta.stop_details }
                if ($null -ne $event.usage.output_tokens) { Set-AnthropicField $message.usage 'output_tokens' $event.usage.output_tokens }
            }
            'message_stop' { $finished = $true }
            'error' { throw "risposta di Anthropic interrotta nello streaming: $($event.error.type) $($event.error.message)" }
        }
    }
    if (-not $finished) { throw 'streaming di Anthropic chiuso prima della fine della risposta' }
    foreach ($index in $blocks.Keys) { if ($blocks[$index].type -eq 'text') { Set-AnthropicField $blocks[$index] 'text' $texts[$index].ToString() } }
    Set-AnthropicField $message 'content' @($blocks.Values)
    return $message
}

function Send-AnthropicRequest($Client, $Request) {
    $body = [Text.Encoding]::UTF8.GetBytes(($Request | ConvertTo-Json -Depth 30))
    for ($attempt = 1; ; $attempt++) {
        $reply = if ($Request.stream) { Invoke-AnthropicStream $Client $body } else { Invoke-AnthropicMessage $Client $body }
        if ($reply.Contains('Response') -or $reply.TimedOut) { return $reply }
        $transient = $reply.Status -eq 429 -or $reply.Status -ge 500
        if ($transient -and $attempt -lt $ModelMaxAttempts) {
            Start-Sleep -Seconds (Get-ModelRetryDelay $reply.HttpResponse $attempt)
            continue
        }
        if (-not $reply.Status) { throw $reply.Error }
        throw "richiesta ad Anthropic non riuscita ($($reply.Status)): $($reply.Detail)"
    }
}

# Una risposta lunga senza streaming puo' superare il tempo massimo della richiesta: la stessa richiesta si
# ripete in streaming, che tiene viva la connessione mentre il modello scrive.
function Invoke-AnthropicLanguageModel($Client, [string]$System, [string]$User, $Schema, [string]$SchemaName) {
    $request = New-AnthropicRequest $Client $System $User $Schema
    $reply = Send-AnthropicRequest $Client $request
    if ($reply.TimedOut) {
        $request.stream = $true
        $reply = Send-AnthropicRequest $Client $request
    }
    return Read-AnthropicResponse $Client $reply.Response
}
