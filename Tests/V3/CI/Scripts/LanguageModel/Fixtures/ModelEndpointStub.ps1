# SPDX-License-Identifier: Apache-2.0

# Endpoint locale di un fornitore del modello linguistico per i test dei moduli. Ogni richiesta resta in
# request-<n>.json con percorso, intestazioni e corpo; la risposta e' la voce n di responses.json
# (l'ultima si ripete), con status, headers e body. La cartella di stato si azzera fra un test e l'altro
# con Reset-ModelEndpoint.

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
            $count = @(Get-ChildItem $State -Filter 'request-*.json').Count + 1
            $request = [ordered]@{ path = $context.Request.Url.AbsolutePath; headers = $headers; body = $body }
            [IO.File]::WriteAllText((Join-Path $State "request-$count.json"), ($request | ConvertTo-Json -Depth 5))
            $responses = @(Get-Content -Raw (Join-Path $State 'responses.json') | ConvertFrom-Json)
            $response = $responses[[math]::Min($count, $responses.Count) - 1]
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
    return @{ Endpoint = $endpoint; State = $state; Job = $job }
}

function Stop-ModelEndpoint($Stub) {
    New-Item -ItemType File -Path (Join-Path $Stub.State 'stop') -Force | Out-Null
    $Stub.Job | Wait-Job -Timeout 10 | Out-Null
    $Stub.Job | Remove-Job -Force
    Remove-Item -Recurse -Force $Stub.State -ErrorAction SilentlyContinue
}

function Reset-ModelEndpoint($Stub, [object[]]$Responses) {
    Get-ChildItem $Stub.State -Filter 'request-*.json' | Remove-Item -Force
    [IO.File]::WriteAllText((Join-Path $Stub.State 'responses.json'), (ConvertTo-Json -InputObject @($Responses) -Depth 20))
}

function Get-ModelEndpointRequests($Stub) {
    return @(Get-ChildItem $Stub.State -Filter 'request-*.json' | Sort-Object { [int]($_.BaseName -replace '\D', '') } | ForEach-Object {
            $request = Get-Content -Raw $_.FullName | ConvertFrom-Json
            [pscustomobject]@{ Path = $request.path; Headers = $request.headers; Body = $request.body | ConvertFrom-Json; Raw = $request.body }
        })
}

function New-ModelResponse([int]$Status = 200, $Body = @{}, [hashtable]$Headers = @{}) {
    return @{ status = $Status; headers = $Headers; body = $Body }
}
