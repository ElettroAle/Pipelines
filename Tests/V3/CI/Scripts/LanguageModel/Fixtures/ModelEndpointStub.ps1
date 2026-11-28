# SPDX-License-Identifier: Apache-2.0

# Endpoint locale di un fornitore del modello linguistico per i test dei moduli. Ogni richiesta resta in
# request-<n>.json con metodo, percorso, intestazioni e corpo; la risposta e' la voce n di responses.json
# (l'ultima si ripete), con status, headers, body e delay in secondi prima della risposta. Un percorso di
# routes.json risponde sempre con la sua voce e la richiesta resta in routed-<n>.json, fuori dal conteggio.
# La cartella di stato si azzera fra un test e l'altro con Reset-ModelEndpoint. Il listener parte in un
# thread: Start-ModelEndpoint torna solo quando ascolta, altrimenti la prima richiesta di un test puo'
# arrivare prima e trovare la porta chiusa.

function Start-ModelEndpoint {
    $state = Join-Path ([IO.Path]::GetTempPath()) "pester-language-model-$(New-Guid)"
    New-Item -ItemType Directory -Path $state | Out-Null
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $endpoint = "http://127.0.0.1:$port"
    $job = Start-ThreadJob -ArgumentList $endpoint, $state -ScriptBlock {
        param($Endpoint, $State)
        $listener = [Net.HttpListener]::new()
        $listener.Prefixes.Add("$Endpoint/")
        $listener.Start()
        New-Item -ItemType File -Path (Join-Path $State 'ready') | Out-Null
        $stopFile = Join-Path $State 'stop'
        while (-not (Test-Path $stopFile)) {
            $pending = $listener.GetContextAsync()
            while (-not $pending.Wait(200)) { if (Test-Path $stopFile) { break } }
            if (-not $pending.IsCompleted) { break }
            $context = $pending.Result
            $reader = [IO.StreamReader]::new($context.Request.InputStream, [Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $headers = [ordered]@{}
            foreach ($name in $context.Request.Headers.AllKeys) { $headers[$name.ToLowerInvariant()] = $context.Request.Headers[$name] }
            $request = [ordered]@{ path = $context.Request.Url.AbsolutePath; method = $context.Request.HttpMethod; headers = $headers; body = $body }
            $routesFile = Join-Path $State 'routes.json'
            $routes = if (Test-Path $routesFile) { Get-Content -Raw $routesFile | ConvertFrom-Json } else { $null }
            $route = if ($routes) { $routes.PSObject.Properties[$request.path] } else { $null }
            if ($route) {
                $routed = @(Get-ChildItem $State -Filter 'routed-*.json').Count + 1
                [IO.File]::WriteAllText((Join-Path $State "routed-$routed.json"), ($request | ConvertTo-Json -Depth 5))
                $response = $route.Value
            }
            else {
                $count = @(Get-ChildItem $State -Filter 'request-*.json').Count + 1
                [IO.File]::WriteAllText((Join-Path $State "request-$count.json"), ($request | ConvertTo-Json -Depth 5))
                $responses = @(Get-Content -Raw (Join-Path $State 'responses.json') | ConvertFrom-Json)
                $response = $responses[[math]::Min($count, $responses.Count) - 1]
            }
            if ($response.delay) { Start-Sleep -Seconds $response.delay }
            $payload = if ($response.body -is [string]) { $response.body } else { $response.body | ConvertTo-Json -Depth 20 -Compress }
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
            $context.Response.StatusCode = [int]$response.status
            foreach ($header in @($response.headers.PSObject.Properties)) { $context.Response.AddHeader($header.Name, "$($header.Value)") }
            $context.Response.ContentType = 'application/json'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.Close()
        }
        $listener.Stop()
    }
    $ready = Join-Path $state 'ready'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path $ready)) {
        if ($job.State -eq 'Failed' -or [DateTime]::UtcNow -gt $deadline) { throw "endpoint del modello non avviato: $($job | Receive-Job -ErrorAction SilentlyContinue)" }
        Start-Sleep -Milliseconds 50
    }
    return @{ Endpoint = $endpoint; State = $state; Job = $job }
}

function Stop-ModelEndpoint($Stub) {
    New-Item -ItemType File -Path (Join-Path $Stub.State 'stop') -Force | Out-Null
    $Stub.Job | Wait-Job -Timeout 10 | Out-Null
    $Stub.Job | Remove-Job -Force
    Remove-Item -Recurse -Force $Stub.State -ErrorAction SilentlyContinue
}

function Reset-ModelEndpoint($Stub, [object[]]$Responses, [hashtable]$Routes = @{}) {
    Get-ChildItem $Stub.State -Filter 'request-*.json' | Remove-Item -Force
    Get-ChildItem $Stub.State -Filter 'routed-*.json' | Remove-Item -Force
    [IO.File]::WriteAllText((Join-Path $Stub.State 'responses.json'), (ConvertTo-Json -InputObject @($Responses) -Depth 20))
    [IO.File]::WriteAllText((Join-Path $Stub.State 'routes.json'), (ConvertTo-Json -InputObject $Routes -Depth 20))
}

function Get-ModelEndpointRequests($Stub, [switch]$Routed) {
    $filter = if ($Routed) { 'routed-*.json' } else { 'request-*.json' }
    return @(Get-ChildItem $Stub.State -Filter $filter | Sort-Object { [int]($_.BaseName -replace '\D', '') } | ForEach-Object {
            $request = Get-Content -Raw $_.FullName | ConvertFrom-Json
            $body = if ($request.body) { $request.body | ConvertFrom-Json } else { $null }
            [pscustomobject]@{ Path = $request.path; Method = $request.method; Headers = $request.headers; Body = $body; Raw = $request.body }
        })
}

function New-ModelResponse([int]$Status = 200, $Body = @{}, [hashtable]$Headers = @{}, [int]$Delay = 0) {
    return @{ status = $Status; headers = $Headers; body = $Body; delay = $Delay }
}
