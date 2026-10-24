#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Test-DocumentationStyle.ps1

.DESCRIPTION
    Il modello e' sostituito da un endpoint locale che risponde come Azure OpenAI: per ogni
    regola registrata restituisce un rilievo quando la sezione inviata contiene la frase
    indicata, e conserva le richieste ricevute. Le prove verificano cosa lo script manda al
    modello e come riporta la risposta; il giudizio vero del modello si prova con gli
    esempi della guida di stile del repository della documentazione.
#>

BeforeAll {
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Test-DocumentationStyle.ps1"

    $script:StubState = Join-Path ([IO.Path]::GetTempPath()) "pester-style-judge-$(New-Guid)"
    New-Item -ItemType Directory -Path $StubState | Out-Null
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $script:StubEndpoint = "http://127.0.0.1:$port"

    $script:Stub = Start-ThreadJob -ArgumentList $StubEndpoint, $StubState -ScriptBlock {
        param($Endpoint, $State)
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
                $rulesFile = Join-Path $State 'rules.json'
                $rules = if (Test-Path $rulesFile) { @(Get-Content -Raw $rulesFile | ConvertFrom-Json) } else { @() }
                $findings = @($rules | Where-Object { $user.Contains($_.match) } | ForEach-Object { @{ rule = $_.rule; excerpt = $_.match; explanation = 'viola la regola' } })
                $content = @{ findings = $findings } | ConvertTo-Json -Depth 5 -Compress
                $payload = @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }) } | ConvertTo-Json -Depth 6 -Compress
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
            $context.Response.StatusCode = $status
            $context.Response.ContentType = 'application/json'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.Close()
        }
        $listener.Stop()
    }

    $Guide = @'
# Guida di stile

## Regole

### Niente riempitivi

Un'espressione che non aggiunge informazione si toglie.

### Il testo parla della piattaforma, non di se stesso

Niente frasi che annunciano cosa dira' il testo.
'@

    function New-Docs {
        $docs = [ordered]@{}
        $docs['docs/STYLE.md'] = $Guide
        $docs['docs/architecture/structure.json'] = '{ "sections": ["Introduzione e obiettivi", "Vincoli", "Glossario"], "glossary": "Glossario", "guide": "../STYLE.md" }'
        $docs['docs/architecture/01-introduzione-e-obiettivi.md'] = "# Introduzione e obiettivi`n`nLa piattaforma aiuta il cittadino a parlare con il comune.`n"
        $docs['docs/architecture/02-vincoli.md'] = "# Vincoli`n`nLa piattaforma gira su Azure.`n"
        $docs['docs/architecture/03-glossario.md'] = "# Glossario`n`n**Azure**: il cloud di Microsoft.`n"
        return $docs
    }

    function Edit-Docs([System.Collections.IDictionary]$Docs, [string]$Path, [string]$Old, [string]$New) {
        if (-not $Docs[$Path].Contains($Old)) { throw "Fixture: '$Old' assente da $Path" }
        $Docs[$Path] = $Docs[$Path].Replace($Old, $New)
    }

    function Set-StubRules([object[]]$Rules) {
        ConvertTo-Json -InputObject @($Rules) -Depth 4 | Set-Content (Join-Path $StubState 'rules.json')
    }

    function Reset-Stub {
        Get-ChildItem $StubState -File | Where-Object Name -NE 'stop' | Remove-Item -Force
    }

    function Get-StubRequests {
        return @(Get-ChildItem $StubState -Filter 'request-*.json' | Sort-Object { [int]($_.BaseName -replace '\D') } | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    }

    function Write-Docs([System.Collections.IDictionary]$Docs, [string]$Root) {
        foreach ($path in $Docs.Keys) {
            $file = Join-Path $Root $path
            if ($null -eq $Docs[$path]) { Remove-Item $file -ErrorAction SilentlyContinue; continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
            [IO.File]::WriteAllText($file, $Docs[$path])
        }
    }

    function Invoke-StyleCheck([System.Collections.IDictionary]$Docs, [string]$Mode = '', [hashtable]$Environment = @{}, [string]$Root) {
        $ownRoot = -not $Root
        if ($ownRoot) {
            $Root = Join-Path ([IO.Path]::GetTempPath()) "pester-style-$(New-Guid)"
            Write-Docs $Docs $Root
        }
        $variables = @{ GATE_MODE = $Mode; STYLE_JUDGE_ENDPOINT = $StubEndpoint; STYLE_JUDGE_MODEL = 'giudice'; STYLE_JUDGE_TOKEN = 'token-di-prova'; TARGET_BRANCH = '' }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }

        Push-Location $Root
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
        $previous = @{}
        try {
            foreach ($name in $variables.Keys) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, $variables[$name])
            }
            $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $ScriptPath 2>&1
            return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
        }
        finally {
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
            [Console]::OutputEncoding = $previousEncoding
            Pop-Location
            if ($ownRoot) { Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue }
        }
    }

    function Get-Issues([string]$Output, [string]$Level = 'error') {
        return @([regex]::Matches($Output, "##vso\[task\.logissue type=$Level\]([^\r\n]*)") | ForEach-Object { $_.Groups[1].Value })
    }

    function Get-JudgedFiles {
        return @(Get-StubRequests | ForEach-Object { [regex]::Match(($_.messages | Where-Object role -EQ 'user').content, 'SEZIONE DA GIUDICARE \(([^)]+)\)').Groups[1].Value })
    }
}

AfterAll {
    Set-Content (Join-Path $StubState 'stop') ''
    Wait-Job $Stub -Timeout 10 | Out-Null
    Remove-Job $Stub -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $StubState -ErrorAction SilentlyContinue
}

Describe "Funzionalità: Verifica della documentazione architetturale — giudizio dello stile" {

    Context "Scenario: documento completo e chiaro" {
        It "Allora la verifica passa" {
            Reset-Stub
            $res = Invoke-StyleCheck (New-Docs)
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: testo che viola la guida di stile — <sezione>, <regola>" -ForEach @(
        @{ sezione = 'Introduzione e obiettivi'; file = '01-introduzione-e-obiettivi.md'; originale = 'La piattaforma aiuta'; frase = 'È importante sottolineare che la piattaforma aiuta'; regola = 'Niente riempitivi' }
        @{ sezione = 'Vincoli'; file = '02-vincoli.md'; originale = 'La piattaforma gira'; frase = 'In questa sezione vedremo che la piattaforma gira'; regola = 'Il testo parla della piattaforma, non di se stesso' }
    ) {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = $frase; rule = $regola })
            $docs = New-Docs
            Edit-Docs $docs "docs/architecture/$file" $originale $frase
            $res = Invoke-StyleCheck $docs
        }

        It "Quando il modello giudica la sezione con la guida di stile del repository come istruzioni" {
            $requests = Get-StubRequests
            $requests | Should -Not -BeNullOrEmpty
            $requests | ForEach-Object { ($_.messages | Where-Object role -EQ 'system').content | Should -BeLike "*$Guide*" }
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la sezione e la regola della guida" {
            Get-Issues $res.Output | Where-Object { $_.StartsWith("${sezione}: $regola («$frase»") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: lo stile appartiene al repository della documentazione" {
        BeforeAll {
            Reset-Stub
            $newRule = 'Niente punti esclamativi'
            Set-StubRules @(@{ match = 'gira su Azure!'; rule = $newRule })
            $docs = New-Docs
            Edit-Docs $docs 'docs/STYLE.md' '### Niente riempitivi' "### $newRule`n`nUna frase si chiude con un punto.`n`n### Niente riempitivi"
            Edit-Docs $docs 'docs/architecture/02-vincoli.md' 'gira su Azure.' 'gira su Azure!'
            $pipelineFiles = Get-ChildItem "$PSScriptRoot/../../V3" -Recurse -File | Get-FileHash | ForEach-Object Hash
            $res = Invoke-StyleCheck $docs
        }

        It "Dato una regola nuova aggiunta alla guida di stile del repository" {
            (Get-StubRequests)[0].messages[0].content | Should -BeLike "*### $newRule*"
        }

        It "Allora la verifica fallisce nominando la sezione e la regola nuova" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_.StartsWith("Vincoli: $newRule (") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E la pipeline non è cambiata" {
            Get-ChildItem "$PSScriptRoot/../../V3" -Recurse -File | Get-FileHash | ForEach-Object Hash | Should -Be $pipelineFiles
        }
    }

    Context "Scenario: il giudizio non è disponibile" {
        BeforeAll {
            Reset-Stub
            Set-Content (Join-Path $StubState 'status') '503'
            $res = Invoke-StyleCheck (New-Docs)
        }

        It "Allora la verifica fallisce nominando il giudizio dello stile e il motivo" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_ -match '^giudizio dello stile: verifica non eseguita \(01-introduzione-e-obiettivi\.md: .*503' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E riprova prima di arrendersi" {
            @(Get-StubRequests).Count | Should -Be 3
        }
    }
}

Describe "Test-DocumentationStyle — cosa si manda al modello" {

    BeforeEach { Reset-Stub }

    It "Giudica ogni sezione una volta e non il glossario" {
        Invoke-StyleCheck (New-Docs) | Out-Null
        Get-JudgedFiles | Should -Be @('01-introduzione-e-obiettivi.md', '02-vincoli.md')
    }

    It "Manda il glossario come contesto di ogni sezione" {
        Invoke-StyleCheck (New-Docs) | Out-Null
        Get-StubRequests | ForEach-Object { ($_.messages | Where-Object role -EQ 'user').content | Should -BeLike '*il cloud di Microsoft*' }
    }

    It "Chiede una risposta nel formato fissato, con il deployment configurato" {
        Invoke-StyleCheck (New-Docs) | Out-Null
        $request = (Get-StubRequests)[0]
        $request.model | Should -Be 'giudice'
        $request.response_format.type | Should -Be 'json_schema'
        $request.response_format.json_schema.schema.properties.findings.items.required | Should -Be @('rule', 'excerpt', 'explanation')
    }

    Context "In una PR" {
        BeforeAll {
            function New-PullRequestRepository([scriptblock]$Change) {
                $root = Join-Path ([IO.Path]::GetTempPath()) "pester-style-pr-$(New-Guid)"
                $docs = New-Docs
                Write-Docs $docs $root
                Push-Location $root
                try {
                    git init -q -b main
                    git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
                    git add -A
                    git -c user.name=t -c user.email=t@t commit -q -m base
                    git update-ref refs/remotes/origin/main HEAD
                    git checkout -q -b feature
                    & $Change $docs
                    Write-Docs $docs $root
                    git add -A
                    git -c user.name=t -c user.email=t@t commit -q -m change
                }
                finally { Pop-Location }
                return $root
            }
        }

        It "Giudica solo le sezioni cambiate" {
            $root = New-PullRequestRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' 'gira su Azure in Italia.' }
            Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' } | Out-Null
            Remove-Item -Recurse -Force $root
            Get-JudgedFiles | Should -Be @('02-vincoli.md')
        }

        It "Non chiama il modello se nessuna sezione è cambiata" {
            $root = New-PullRequestRepository { param($d) $d['README.md'] = 'altro' }
            $res = Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' }
            Remove-Item -Recurse -Force $root
            @(Get-StubRequests).Count | Should -Be 0
            $res.ExitCode | Should -Be 0
        }

        It "Giudica tutte le sezioni se cambia la guida" {
            $root = New-PullRequestRepository { param($d) Edit-Docs $d 'docs/STYLE.md' 'si toglie.' 'si toglie sempre.' }
            Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' } | Out-Null
            Remove-Item -Recurse -Force $root
            Get-JudgedFiles | Should -Be @('01-introduzione-e-obiettivi.md', '02-vincoli.md')
        }
    }
}

Describe "Test-DocumentationStyle — configurazione e modalità" {

    BeforeEach { Reset-Stub }

    It "Senza guida dichiarata fallisce nominando la struttura" {
        $docs = New-Docs
        $docs['docs/architecture/structure.json'] = '{ "sections": ["Introduzione e obiettivi", "Vincoli", "Glossario"], "glossary": "Glossario" }'
        $res = Invoke-StyleCheck $docs
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^giudizio dello stile: guida non dichiarata \(docs/architecture/structure\.json\)' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Con la guida dichiarata ma assente fallisce nominando il file" {
        $docs = New-Docs
        $docs['docs/STYLE.md'] = $null
        $res = Invoke-StyleCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^giudizio dello stile: guida mancante \(.*STYLE\.md\)' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Senza endpoint fallisce senza chiamare il modello" {
        $res = Invoke-StyleCheck (New-Docs) -Environment @{ STYLE_JUDGE_ENDPOINT = '' }
        Get-Issues $res.Output | Where-Object { $_ -match '^giudizio dello stile: verifica non eseguita \(endpoint o modello non configurati\)' } | Should -Not -BeNullOrEmpty
        @(Get-StubRequests).Count | Should -Be 0
    }

    It "In modalità warn segnala come warning e non blocca" {
        Set-StubRules @(@{ match = 'gira su Azure'; rule = 'Niente riempitivi' })
        $res = Invoke-StyleCheck (New-Docs) 'warn'
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output 'warning' | Should -Not -BeNullOrEmpty
        $res.Output | Should -Match 'task\.complete result=SucceededWithIssues'
    }

    It "In modalità off non chiama il modello" {
        $res = Invoke-StyleCheck (New-Docs) 'off'
        $res.ExitCode | Should -Be 0
        @(Get-StubRequests).Count | Should -Be 0
    }
}
