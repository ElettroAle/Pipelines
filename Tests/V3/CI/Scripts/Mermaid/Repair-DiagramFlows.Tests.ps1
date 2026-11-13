#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Mermaid/Repair-DiagramFlows.ps1

.DESCRIPTION
    Come la build di una PR su Azure DevOps: il ramo della PR e' su un origin locale e la copia di
    lavoro e' il commit di merge del ramo nella destinazione. Il modello linguistico e' sostituito da un
    endpoint locale che risponde come Azure OpenAI con le stesure registrate, una per richiesta (l'ultima
    si ripete), e conserva le richieste ricevute. Le prove verificano cosa lo script manda al modello e
    come accetta, scarta e pubblica le stesure; la riparazione vera del modello si vede nella PR della
    documentazione. Lo script gira come in pipeline: richiede Java 17 o successivo per la Structurizr CLI
    e Node.js per il parser Mermaid.
#>

BeforeAll {
    . "$PSScriptRoot/../Common/Fixtures/Documentation/DocumentationFixture.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Mermaid/Repair-DiagramFlows.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-flows-repair-$(New-Guid)"

    $script:StubState = Join-Path ([IO.Path]::GetTempPath()) "pester-flows-repair-stub-$(New-Guid)"
    New-Item -ItemType Directory -Path $StubState | Out-Null
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $script:StubEndpoint = "http://127.0.0.1:$port"

    $script:Stub = Start-ThreadJob -ArgumentList $StubEndpoint, $StubState -ScriptBlock {
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
            $count = @(Get-ChildItem $State -Filter 'request-*.json').Count + 1
            [IO.File]::WriteAllText((Join-Path $State "request-$count.json"), $body)
            $answers = @(Get-Content -Raw (Join-Path $State 'answers.json') | ConvertFrom-Json)
            $answer = $answers[[math]::Min($count, $answers.Count) - 1]
            $content = $answer | ConvertTo-Json -Depth 8 -Compress
            $payload = @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }); usage = @{ prompt_tokens = 100; completion_tokens = 10 } } | ConvertTo-Json -Depth 6 -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
            $context.Response.StatusCode = 200
            $context.Response.ContentType = 'application/json'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.Close()
        }
        $listener.Stop()
    }

    $RuntimeView = 'docs/architecture/06_runtime_view.md'
    $WorkspaceDsl = 'docs/architecture/c4/workspace.dsl'
    $ValidDiagram = "    participant bff as BFF`n    participant motore as API del Motore`n    bff->>motore: apre la sessione`n    motore-->>bff: codice della sessione"
    $ValidProse = "Il BFF chiede all'API del Motore di aprire una sessione."
    $ShortcutDiagram = "    participant client as Client`n    participant motore as API del Motore`n    client->>motore: apre la sessione`n    motore-->>client: codice della sessione"
    $ShortcutProse = "Il Client chiede all'API del Motore di aprire una sessione."
    $RoutedDiagram = "    participant client as Client`n    participant bff as BFF`n    participant motore as API del Motore`n    client->>bff: apre la sessione`n    bff->>motore: apre la sessione`n    motore-->>client: codice della sessione"
    $RoutedProse = "Il Client chiede al BFF di aprire una sessione, e il BFF la chiede all'API del Motore."

    function Set-Answers([object[]]$Answers) {
        Get-ChildItem $StubState -Filter 'request-*.json' | Remove-Item
        [IO.File]::WriteAllText((Join-Path $StubState 'answers.json'), (ConvertTo-Json -InputObject @($Answers) -Depth 8))
    }

    function Get-Requests {
        return @(Get-ChildItem $StubState -Filter 'request-*.json' | Sort-Object { [int]($_.BaseName -replace '\D', '') } | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    }

    function Get-UserMessage($Request) {
        return ($Request.messages | Where-Object role -EQ 'user').content
    }

    function New-Answer([int]$Line, [string]$Diagram, [string]$Find = '', [string]$Text = '') {
        $replacements = if ($Find) { @(@{ find = $Find; text = $Text }) } else { @() }
        return @{ diagrams = @(@{ line = $Line; text = "sequenceDiagram`n$Diagram" }); replacements = $replacements }
    }

    function Get-DiagramLine([System.Collections.IDictionary]$Docs) {
        return Get-LineNumber $Docs[$RuntimeView] '```mermaid'
    }

    function Invoke-Git {
        $output = git -c user.name=t -c user.email=t@t -c core.autocrlf=false @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
        return $output
    }

    function Write-Docs([System.Collections.IDictionary]$Docs, [string]$Root) {
        foreach ($path in $Docs.Keys) {
            $file = Join-Path $Root $path
            New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
            [IO.File]::WriteAllText($file, ($Docs[$path] -replace "`r`n", "`n"))
        }
    }

    function New-OriginRepository([scriptblock]$Change) {
        $bare = Join-Path ([IO.Path]::GetTempPath()) "pester-repair-origin-$(New-Guid)"
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-repair-build-$(New-Guid)"
        Invoke-Git init -q --bare -b main $bare | Out-Null
        $docs = New-ValidDocs
        Write-Docs $docs $root
        Push-Location $root
        try {
            Invoke-Git init -q -b main | Out-Null
            Invoke-Git config core.autocrlf false | Out-Null
            Invoke-Git add -A | Out-Null
            Invoke-Git commit -q -m base | Out-Null
            Invoke-Git remote add origin $bare | Out-Null
            Invoke-Git push -q origin main | Out-Null
            Invoke-Git checkout -q -b feature | Out-Null
            & $Change $docs
            Write-Docs $docs $root
            Invoke-Git add -A | Out-Null
            Invoke-Git commit -q --allow-empty -m change | Out-Null
            Invoke-Git push -q origin feature | Out-Null
            Invoke-Git fetch -q origin | Out-Null
            Invoke-Git checkout -q --detach origin/main | Out-Null
            Invoke-Git merge -q --no-ff --no-edit origin/feature | Out-Null
            $feature = Invoke-Git rev-parse origin/feature
        }
        finally { Pop-Location }
        return @{ Root = $root; Bare = $bare; Feature = "$feature".Trim(); Docs = $docs }
    }

    function Invoke-Repair($Repository, [hashtable]$Environment = @{}) {
        $variables = @{
            GATE_MODE = 'enforce'; SOURCE_BRANCH = 'refs/heads/feature'; SYSTEM_ACCESSTOKEN = ''; DOCUMENT_LANGUAGE = ''; STYLE_GUIDE = ''
            FLOWS_REPAIR_ENDPOINT = $StubEndpoint; FLOWS_REPAIR_MODEL = 'riparatore'; FLOWS_REPAIR_TOKEN = 'token-di-prova'; FLOWS_REPAIR_MAX_DRAFTS = ''; FLOWS_REPAIR_REASONING_EFFORT = ''
        }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        $previous = @{}
        foreach ($name in $variables.Keys) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $variables[$name])
        }
        Push-Location $Repository.Root
        try {
            $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $ScriptPath 2>&1
            return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
        }
        finally {
            Pop-Location
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
    }

    function Get-FeatureFile($Repository, [string]$Path) {
        return (git -C $Repository.Bare show "refs/heads/feature:$Path" 2>&1) -join "`n"
    }

    function Get-FeatureTip($Repository) {
        return "$(git -C $Repository.Bare rev-parse refs/heads/feature)".Trim()
    }

    function Get-SideBranches($Repository) {
        return @(git -C $Repository.Bare for-each-ref --format='%(refname:short)' 'refs/heads/flows-repair/')
    }

    function Remove-Repository($Repository) {
        Remove-Item -Recurse -Force $Repository.Root, $Repository.Bare -ErrorAction SilentlyContinue
    }

    $Shortcut = { param($docs) Edit-Docs $docs $RuntimeView $ValidDiagram $ShortcutDiagram; Edit-Docs $docs $RuntimeView $ValidProse $ShortcutProse }
}

AfterAll {
    New-Item -ItemType File -Path (Join-Path $StubState 'stop') -Force | Out-Null
    $Stub | Wait-Job -Timeout 10 | Out-Null
    $Stub | Remove-Job -Force
    Remove-Item -Recurse -Force $StubState -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}

Describe "Funzionalità: Diagrammi riallineati dall'AI quando il modello C4 cambia" {

    Context "Scenario: una chiamata senza relazione si ripara passando per gli elementi del modello" {
        BeforeAll {
            $repository = New-OriginRepository $Shortcut
            Set-Answers @(New-Answer (Get-DiagramLine $repository.Docs) $RoutedDiagram $ShortcutProse $RoutedProse)
            $res = Invoke-Repair $repository
            $requests = Get-Requests
            $runtime = Get-FeatureFile $repository $RuntimeView
            $message = git -C $repository.Bare log -1 --format=%B refs/heads/feature
        }
        AfterAll { Remove-Repository $repository }

        It "Allora il diagramma della sezione sul ramo della PR passa per gli elementi del modello" {
            $runtime | Should -MatchExactly '(?m)^    client->>bff: apre la sessione\n    bff->>motore: apre la sessione$' -Because $res.Output
        }

        It "E il testo della sezione nomina gli stessi passaggi del diagramma" {
            $runtime.Contains($RoutedProse) | Should -BeTrue
            $runtime.Contains($ShortcutProse) | Should -BeFalse
        }

        It "E la correzione torna sul ramo della PR con un commit che non avvia le pipeline sui rami" {
            ($message -join "`n") | Should -MatchExactly '^docs: repair the diagram flows of docs/architecture/06_runtime_view\.md'
            ($message -join "`n") | Should -MatchExactly '\[skip ci\]'
        }

        It "E il modello linguistico riceve il modello C4 e i rilievi della verifica dei flussi" {
            $requests.Count | Should -Be 1
            $user = Get-UserMessage $requests[0]
            $user | Should -MatchExactly '(?m)^- client -> bff$'
            $user | Should -MatchExactly '(?m)^- bff \| BFF \| container$'
            $user | Should -MatchExactly 'chiamata senza relazione nel modello C4 \(06_runtime_view\.md:\d+ Client -> API del Motore\)'
        }

        It "E la verifica si ferma per ripartire dal commit della riparazione, senza ramo di appoggio" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_ -match '^riparazione dei flussi: diagrammi riparati con il modello C4 \(1 commit sul ramo feature' } | Should -Not -BeNullOrEmpty -Because $res.Output
            Get-SideBranches $repository | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: un elemento tolto dal modello esce dal diagramma" {
        BeforeAll {
            $withWorker = "$ValidDiagram`n    participant worker as Worker`n    motore->>worker: accoda il riepilogo"
            $repository = New-OriginRepository {
                param($docs)
                Edit-Docs $docs $RuntimeView $ValidDiagram $withWorker
                Edit-Docs $docs $RuntimeView $ValidProse "$ValidProse Il Worker riceve il riepilogo."
                Edit-Docs $docs $WorkspaceDsl "            worker = container `"Worker`" `"Lavori lunghi`" `"Functions`" `"Applicazione`" {`n                coda = component `"Coda`"`n            }`n" ''
                Edit-Docs $docs $WorkspaceDsl "        motore -> worker `"accoda`"`n" ''
                Edit-Docs $docs $WorkspaceDsl "        component worker `"componenti-worker`" {`n            include *`n        }`n" ''
            }
            Set-Answers @(New-Answer (Get-DiagramLine $repository.Docs) $ValidDiagram ' Il Worker riceve il riepilogo.' '')
            $res = Invoke-Repair $repository
            $runtime = Get-FeatureFile $repository $RuntimeView
        }
        AfterAll { Remove-Repository $repository }

        It "Allora il diagramma passa la verifica dei flussi senza quell'elemento" {
            $runtime | Should -Not -Match 'worker' -Because $res.Output
            $runtime | Should -MatchExactly '(?m)^    bff->>motore: apre la sessione$'
        }

        It "E il testo della sezione non lo nomina piu'" {
            $runtime | Should -Not -Match 'Worker'
        }
    }

    Context "Scenario: una stesura scartata torna al modello con i motivi dello scarto" {
        BeforeAll {
            $repository = New-OriginRepository $Shortcut
            $line = Get-DiagramLine $repository.Docs
            Set-Answers @((New-Answer $line $ShortcutDiagram), (New-Answer $line $RoutedDiagram $ShortcutProse $RoutedProse))
            $res = Invoke-Repair $repository
            $requests = Get-Requests
            $runtime = Get-FeatureFile $repository $RuntimeView
        }
        AfterAll { Remove-Repository $repository }

        It "Allora il modello riceve la stesura scartata con i rilievi rimasti" {
            $requests.Count | Should -Be 2 -Because $res.Output
            $rejected = (Get-UserMessage $requests[1]) -split 'Motivi dello scarto:', 2
            $rejected[0] | Should -MatchExactly 'STESURA SCARTATA'
            $rejected[1] | Should -MatchExactly '(?m)^- Runtime View: chiamata senza relazione nel modello C4 \(06_runtime_view\.md:\d+ Client -> API del Motore\)$'
        }

        It "E la stesura accettata arriva sul ramo della PR" {
            $runtime | Should -MatchExactly '(?m)^    client->>bff: apre la sessione$'
        }
    }

    Context "Scenario: una correzione che non passa la verifica non si pubblica" {
        BeforeAll {
            $repository = New-OriginRepository $Shortcut
            Set-Answers @(New-Answer (Get-DiagramLine $repository.Docs) $ShortcutDiagram)
            $res = Invoke-Repair $repository @{ FLOWS_REPAIR_MAX_DRAFTS = '2' }
            $requests = Get-Requests
        }
        AfterAll { Remove-Repository $repository }

        It "Allora il modello riceve al massimo le stesure previste" {
            $requests.Count | Should -Be 2 -Because $res.Output
        }

        It "E la sezione resta com'era, sul ramo della PR e nella copia della build" {
            Get-FeatureTip $repository | Should -Be $repository.Feature
            [IO.File]::ReadAllText((Join-Path $repository.Root $RuntimeView)).Contains($ShortcutDiagram) | Should -BeTrue
        }

        It "E la riparazione lascia alla verifica dei flussi gli errori rimasti" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-SideBranches $repository | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: un rilancio riparte dal lavoro gia' pagato" {
        BeforeAll {
            $repository = New-OriginRepository $Shortcut
            $side = "flows-repair/$($repository.Feature)"
            Push-Location $repository.Root
            try {
                Invoke-Git checkout -q --detach $repository.Feature | Out-Null
                Edit-Docs $repository.Docs $RuntimeView $ShortcutDiagram $RoutedDiagram
                Write-Docs $repository.Docs $repository.Root
                Invoke-Git commit -q -am 'docs: repair the diagram flows of docs/architecture/06_runtime_view.md' | Out-Null
                Invoke-Git push -q origin "HEAD:refs/heads/$side" | Out-Null
                $saved = "$(Invoke-Git rev-parse HEAD)".Trim()
                Invoke-Git checkout -q --detach origin/main | Out-Null
                Invoke-Git merge -q --no-ff --no-edit $repository.Feature | Out-Null
            }
            finally { Pop-Location }
            Set-Answers @(New-Answer (Get-DiagramLine $repository.Docs) $RoutedDiagram)
            $res = Invoke-Repair $repository
            $requests = Get-Requests
        }
        AfterAll { Remove-Repository $repository }

        It "Allora la sezione gia' riparata non va di nuovo al modello" {
            $requests.Count | Should -Be 0 -Because $res.Output
        }

        It "E il ramo della PR riceve i commit del ramo di appoggio, che si cancella" {
            Get-FeatureTip $repository | Should -Be $saved
            Get-SideBranches $repository | Should -BeNullOrEmpty
        }

        It "E la verifica si ferma per ripartire da quel commit" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_ -match '^riparazione dei flussi: riparazione ripresa' } | Should -Not -BeNullOrEmpty -Because $res.Output
        }
    }

    Context "Scenario: un diagramma gia' in regola non costa nulla" {
        BeforeAll {
            $repository = New-OriginRepository { param($docs) }
            Set-Answers @(New-Answer 1 $RoutedDiagram)
            $res = Invoke-Repair $repository
            $requests = Get-Requests
        }
        AfterAll { Remove-Repository $repository }

        It "Allora il modello linguistico non viene chiamato" {
            $requests.Count | Should -Be 0 -Because $res.Output
        }

        It "E il ramo della PR non cambia" {
            $res.ExitCode | Should -Be 0
            Get-FeatureTip $repository | Should -Be $repository.Feature
        }
    }

    Context "Scenario: fuori da una PR nessuno riscrive" {
        BeforeAll {
            $repository = New-OriginRepository $Shortcut
            Set-Answers @(New-Answer (Get-DiagramLine $repository.Docs) $RoutedDiagram)
            $res = Invoke-Repair $repository @{ SOURCE_BRANCH = '' }
            $requests = Get-Requests
        }
        AfterAll { Remove-Repository $repository }

        It "Allora il modello linguistico non viene chiamato e la verifica dei flussi segnala come oggi" {
            $requests.Count | Should -Be 0 -Because $res.Output
            $res.ExitCode | Should -Be 0
            Get-FeatureTip $repository | Should -Be $repository.Feature
        }
    }
}

Describe "Repair-DiagramFlows — stesure che non si applicano" {

    It "Una frase da sostituire che non compare una volta sola scarta la stesura" {
        $repository = New-OriginRepository $Shortcut
        try {
            $line = Get-DiagramLine $repository.Docs
            Set-Answers @((New-Answer $line $RoutedDiagram 'frase che non esiste' 'altro'), (New-Answer $line $RoutedDiagram))
            $res = Invoke-Repair $repository
            $requests = Get-Requests
            $requests.Count | Should -Be 2 -Because $res.Output
            Get-UserMessage $requests[1] | Should -MatchExactly 'il tratto da sostituire compare 0 volte invece di una: frase che non esiste'
        }
        finally { Remove-Repository $repository }
    }

    It "Un diagramma indicato con una riga senza diagramma scarta la stesura" {
        $repository = New-OriginRepository $Shortcut
        try {
            Set-Answers @((New-Answer 2 $RoutedDiagram), (New-Answer (Get-DiagramLine $repository.Docs) $RoutedDiagram))
            $res = Invoke-Repair $repository
            $requests = Get-Requests
            $requests.Count | Should -Be 2 -Because $res.Output
            Get-UserMessage $requests[1] | Should -MatchExactly 'nessun diagramma alla riga 2'
        }
        finally { Remove-Repository $repository }
    }
}
