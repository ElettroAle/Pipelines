# SPDX-License-Identifier: Apache-2.0

# Endpoint locale che risponde come Azure OpenAI al generatore del testo del modello C4. Per ogni
# richiesta legge la parte da descrivere e la sua struttura dal messaggio, e scrive una stesura che
# descrive ogni elemento e ogni relazione. answers.json nella cartella di stato cambia la stesura di
# una parte, una voce per stesura: omitElement toglie un elemento, extraRelationship aggiunge una
# relazione, longDescription allunga la descrizione di un elemento, people, externalSystems e links si
# aggiungono. La voce catalogue cambia la risposta al controllo del catalogo: identificativo e sameAs,
# omit toglie le voci elencate; senza voce ogni identificativo resta distinto. status forza un codice
# HTTP; throttle rifiuta con 429 e Retry-After di un secondo quel numero di richieste; fail-after rifiuta
# con 503 ogni richiesta oltre quel numero, contato dall'ultimo azzeramento dello stato. Un rifiuto porta
# sempre Retry-After. Le richieste ricevute restano in request-<n>.json.

param([string]$Endpoint, [string]$State)

function Get-Structure([string]$User) {
    $start = $User.IndexOf("STRUTTURA DELLA PARTE (JSON):`n")
    $end = $User.IndexOf("`n`nALTRI CONTAINER DEL SISTEMA:")
    return $User.Substring($start + 30, $end - $start - 30) | ConvertFrom-Json
}

function New-Draft($Structure, $Spec) {
    $container = $Structure.container
    $ids = @($container.id) + @($container.components | Where-Object { $_ } | ForEach-Object id)
    $elements = @($ids | Where-Object { $_ -ne $Spec.omitElement } | ForEach-Object {
            $description = if ($_ -eq $Spec.longDescription) { (@('parola') * 40) -join ' ' } else { "Descrizione di $_." }
            @{ id = $_; description = $description }
        })
    $relationships = @($Structure.relationships | Where-Object { $_ } | ForEach-Object {
            @{ source = $_.source; target = $_.target; description = "Passa da $($_.source) a $($_.target)"; technology = 'chiamata' }
        })
    if ($Spec.extraRelationship) { $relationships += @{ source = $Spec.extraRelationship.source; target = $Spec.extraRelationship.target; description = 'Inventata'; technology = '' } }
    return [ordered]@{
        elements        = $elements
        relationships   = $relationships
        people          = @($Spec.people | Where-Object { $_ })
        externalSystems = @($Spec.externalSystems | Where-Object { $_ })
        links           = @($Spec.links | Where-Object { $_ })
    }
}

function New-CatalogueAnswer([string]$User, $Spec) {
    $start = $User.IndexOf("CATALOGO DA CONTROLLARE:`n")
    $section = $User.Substring($start) -split "`n`n" | Select-Object -First 1
    $ids = @([regex]::Matches($section, '(?m)^- (\S+) \[') | ForEach-Object { $_.Groups[1].Value })
    $actors = @($ids | Where-Object { @($Spec.omit) -notcontains $_ } | ForEach-Object {
            $sameAs = if ($Spec -and $Spec.PSObject.Properties[$_]) { $Spec.$_ } else { '' }
            @{ id = $_; sameAs = $sameAs }
        })
    return [ordered]@{ actors = $actors }
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("$Endpoint/")
$listener.Start()
$count = 0
$stopFile = Join-Path $State 'stop'
while (-not (Test-Path $stopFile)) {
    $pending = $listener.GetContextAsync()
    while (-not $pending.Wait(200)) { if (Test-Path $stopFile) { break } }
    if (-not $pending.IsCompleted) { break }
    $context = $pending.Result
    $reader = [IO.StreamReader]::new($context.Request.InputStream, [Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $count++
    [IO.File]::WriteAllText((Join-Path $State "request-$count.json"), $body)

    $statusFile = Join-Path $State 'status'
    $status = if (Test-Path $statusFile) { [int](Get-Content -Raw $statusFile) } else { 200 }
    $retryAfter = '0'
    $throttleFile = Join-Path $State 'throttle'
    $throttled = if (Test-Path $throttleFile) { [int](Get-Content -Raw $throttleFile) } else { 0 }
    if ($throttled -gt 0) {
        [IO.File]::WriteAllText($throttleFile, "$($throttled - 1)")
        $status = 429
        $retryAfter = '1'
    }
    $failAfterFile = Join-Path $State 'fail-after'
    $received = @(Get-ChildItem $State -Filter 'request-*.json').Count
    if ((Test-Path $failAfterFile) -and $received -gt [int](Get-Content -Raw $failAfterFile)) { $status = 503 }
    $payload = '{}'
    if ($status -eq 200) {
        $request = $body | ConvertFrom-Json
        $user = ($request.messages | Where-Object role -EQ 'user').content
        $catalogue = $user.Contains("CATALOGO DA CONTROLLARE:`n")
        $unit = if ($catalogue) { 'catalogue' } else { [regex]::Match($user, 'PARTE DA DESCRIVERE: (\S+)').Groups[1].Value }
        $draftsFile = Join-Path $State "drafts-$unit"
        $draft = if (Test-Path $draftsFile) { [int](Get-Content -Raw $draftsFile) } else { 0 }
        [IO.File]::WriteAllText($draftsFile, "$($draft + 1)")
        $answersFile = Join-Path $State 'answers.json'
        $answers = if (Test-Path $answersFile) { Get-Content -Raw $answersFile | ConvertFrom-Json } else { $null }
        $specs = @($answers.$unit)
        $spec = if ($specs.Count) { $specs[[math]::Min($draft, $specs.Count - 1)] } else { $null }
        $answer = if ($catalogue) { New-CatalogueAnswer $user $spec } else { New-Draft (Get-Structure $user) $spec }
        $content = $answer | ConvertTo-Json -Depth 10 -Compress
        $payload = @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }); usage = @{ prompt_tokens = 100; completion_tokens = 10 } } | ConvertTo-Json -Depth 6 -Compress
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $context.Response.StatusCode = $status
    if ($status -ne 200) { $context.Response.AddHeader('Retry-After', $retryAfter) }
    $context.Response.ContentType = 'application/json'
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
}
$listener.Stop()
