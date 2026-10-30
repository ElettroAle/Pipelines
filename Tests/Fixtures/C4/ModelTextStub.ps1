# SPDX-License-Identifier: Apache-2.0

# Endpoint locale che risponde come Azure OpenAI al generatore del testo del modello C4. Per ogni
# richiesta legge la parte da descrivere e la sua struttura dal messaggio, e scrive una stesura che
# descrive ogni elemento e ogni relazione. answers.json nella cartella di stato cambia la stesura di
# una parte, una voce per stesura: omitElement toglie un elemento, extraRelationship aggiunge una
# relazione, longDescription allunga la descrizione di un elemento, people, externalSystems e links si
# aggiungono. status forza un codice HTTP. Le richieste ricevute restano in request-<n>.json.

param([string]$Endpoint, [string]$State)

function Get-Structure([string]$User) {
    $start = $User.IndexOf("STRUTTURA DELLA PARTE (JSON):`n")
    $end = $User.IndexOf("`n`nALTRI CONTAINER DEL REPOSITORY:")
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
    $payload = '{}'
    if ($status -eq 200) {
        $request = $body | ConvertFrom-Json
        $user = ($request.messages | Where-Object role -EQ 'user').content
        $unit = [regex]::Match($user, 'PARTE DA DESCRIVERE: (\S+)').Groups[1].Value
        $draftsFile = Join-Path $State "drafts-$unit"
        $draft = if (Test-Path $draftsFile) { [int](Get-Content -Raw $draftsFile) } else { 0 }
        [IO.File]::WriteAllText($draftsFile, "$($draft + 1)")
        $answersFile = Join-Path $State 'answers.json'
        $answers = if (Test-Path $answersFile) { Get-Content -Raw $answersFile | ConvertFrom-Json } else { $null }
        $specs = @($answers.$unit)
        $spec = if ($specs.Count) { $specs[[math]::Min($draft, $specs.Count - 1)] } else { $null }
        $content = New-Draft (Get-Structure $user) $spec | ConvertTo-Json -Depth 10 -Compress
        $payload = @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }); usage = @{ prompt_tokens = 100; completion_tokens = 10 } } | ConvertTo-Json -Depth 6 -Compress
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $context.Response.StatusCode = $status
    $context.Response.ContentType = 'application/json'
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
}
$listener.Stop()
