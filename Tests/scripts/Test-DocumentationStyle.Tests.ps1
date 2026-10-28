#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Test-DocumentationStyle.ps1

.DESCRIPTION
    Il modello e' sostituito da un endpoint locale che risponde come Azure OpenAI: per ogni
    regola registrata restituisce una violazione, nella voce della regola, per ogni unita'
    segnata della sezione che contiene la frase indicata, con la correzione registrata; conserva
    le richieste ricevute. Le prove verificano cosa lo script manda al modello, come riporta la
    risposta e come applica le correzioni; il giudizio vero del modello si prova con gli esempi
    della guida di stile del repository della documentazione.
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

        function Read-Units([string]$Text) {
            $units = [Collections.Generic.List[object]]::new()
            foreach ($line in ($Text -split "`n")) {
                if ($line -match '^\[(\d+)(\*?)\] (.*)$') { $units.Add([pscustomobject]@{ Number = [int]$Matches[1]; Marked = $Matches[2] -eq '*'; Text = $Matches[3] }) }
                elseif ($units.Count) { $units[$units.Count - 1].Text += "`n$line" }
            }
            return , $units
        }

        function New-Verdict($Request, [object[]]$Rules) {
            $user = ($Request.messages | Where-Object role -EQ 'user').content
            $glossaryPart, $sectionPart = $user -split '(?:SEZIONE|DECISIONE) DA GIUDICARE \([^)]*\)', 2
            $section = Read-Units $sectionPart
            $glossary = Read-Units $glossaryPart
            $verdict = [ordered]@{}
            $Request.response_format.json_schema.schema.properties.PSObject.Properties | ForEach-Object { $verdict[$_.Name] = [Collections.Generic.List[object]]::new() }
            foreach ($rule in $Rules) {
                $property = $Request.response_format.json_schema.schema.properties.PSObject.Properties | Where-Object { $_.Value.description -eq $rule.rule } | Select-Object -First 1
                if (-not $property) { continue }
                if ($rule.until -and $user.Contains($rule.until)) { continue }
                foreach ($unit in ($section | Where-Object { ($_.Marked -or $rule.everywhere) -and $_.Text.Contains($rule.match) })) {
                    $find = if ($rule.find) { $rule.find } else { $rule.match }
                    $target = $unit.Number
                    $fix = @{ kind = 'none'; unit = $target; find = ''; text = '' }
                    $replacement = if ($null -ne $rule.retryReplacement -and $user.Contains('CORREZIONI SCARTATE')) { $rule.retryReplacement } else { $rule.replacement }
                    if ($null -ne $replacement) { $fix = @{ kind = 'replace'; unit = $target; find = $find; text = $replacement } }
                    elseif ($rule.insert) { $fix = @{ kind = 'insert'; unit = $target; find = ''; text = $rule.insert } }
                    elseif ($rule.glossaryInsert) { $fix = @{ kind = 'insert'; unit = $glossary[0].Number; find = ''; text = $rule.glossaryInsert } }
                    $verdict[$property.Name].Add(@{ unit = $unit.Number; excerpt = $rule.match; explanation = 'viola la regola'; fix = $fix })
                }
            }
            return $verdict
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
            $failOnFile = Join-Path $State 'fail-on'
            if ((Test-Path $failOnFile) -and $body.Contains((Get-Content -Raw $failOnFile))) { $status = 503 }
            $hangOnFile = Join-Path $State 'hang-on'
            if ((Test-Path $hangOnFile) -and $body.Contains((Get-Content -Raw $hangOnFile))) { continue }
            $request = $body | ConvertFrom-Json
            $payload = '{}'
            if ((Test-Path (Join-Path $State 'reject-seed')) -and $null -ne $request.seed) {
                $status = 400
                $payload = '{"error":{"message":"Unsupported parameter: ''seed''"}}'
            }
            elseif ($status -eq 200) {
                $rulesFile = Join-Path $State 'rules.json'
                $rules = if (Test-Path $rulesFile) { @(Get-Content -Raw $rulesFile | ConvertFrom-Json) } else { @() }
                $content = New-Verdict $request $rules | ConvertTo-Json -Depth 8 -Compress
                $payload = @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }); usage = @{ prompt_tokens = 100; completion_tokens = 10 } } | ConvertTo-Json -Depth 6 -Compress
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

## Per chi si scrive

La documentazione serve a chi lavora sulla piattaforma.

## Regole

### Niente riempitivi

Un'espressione che non aggiunge informazione si toglie.

~~~markdown
### Un titolo dentro un esempio non e' una regola
~~~

### Il testo parla della piattaforma, non di se stesso

Niente frasi che annunciano cosa dira' il testo.
'@

    $PartedGuide = @'
# Guida di stile

## Regole

### Niente riempitivi

Un'espressione che non aggiunge informazione si toglie.

## Regole delle sezioni

### Ogni sezione dice a chi serve

La sezione si apre con una citazione che nomina i lettori.

~~~markdown
### Un titolo dentro un esempio delle sezioni
~~~

## Regole delle decisioni

### Il titolo dice la decisione presa

Il titolo di una decisione nomina la scelta, senza sigle.
'@

    $SectionRule = 'Ogni sezione dice a chi serve'
    $DecisionRule = 'Il titolo dice la decisione presa'
    $Filler = 'Niente riempitivi'
    $SelfReference = 'Il testo parla della piattaforma, non di se stesso'
    $FixEnvironment = @{ TARGET_BRANCH = 'refs/heads/main'; SOURCE_BRANCH = 'refs/heads/feature'; STYLE_FIX = 'true'; READABILITY_MAX_WORDS = '25' }
    $ExistingDecision = "---`nstatus: accepted`n---`n`n# Copie dei dati`n`n## Contesto e problema`n`nServono copie dei dati.`n`n## Opzioni considerate`n`n- Copie in Italia.`n`n## Esito della decisione`n`nLe copie restano in Italia.`n"
    $NewDecision = "---`nstatus: accepted`n---`n`n# Copie cifrate`n`n## Contesto e problema`n`nServono copie dei dati.`n`n## Opzioni considerate`n`n- Copie in Italia.`n`n## Esito della decisione`n`nLe copie restano in Italia.`n"

    function Get-FixEnvironment([hashtable]$Overrides) {
        $environment = $FixEnvironment.Clone()
        foreach ($name in $Overrides.Keys) { $environment[$name] = $Overrides[$name] }
        return $environment
    }

    function New-Docs {
        $docs = [ordered]@{}
        $docs['docs/STYLE.md'] = $Guide
        $docs['docs/architecture/01-introduzione-e-obiettivi.md'] = "# Introduzione e obiettivi`n`nLa piattaforma aiuta il utente a parlare con l'assistenza.`n"
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

    function Get-UserMessage($Request) {
        return ($Request.messages | Where-Object role -EQ 'user').content
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
        $variables = @{ GATE_MODE = $Mode; STYLE_JUDGE_ENDPOINT = $StubEndpoint; STYLE_JUDGE_MODEL = 'giudice'; STYLE_JUDGE_TOKEN = 'token-di-prova'; TARGET_BRANCH = ''; SOURCE_BRANCH = ''; STYLE_GUIDE = ''; DOCS_GLOSSARY = '03-glossario.md'; STYLE_FIX = ''; STYLE_MAX_ROUNDS = ''; STYLE_MAX_FINDINGS = ''; STYLE_JUDGE_SEED = ''; READABILITY_MAX_WORDS = ''; READABILITY_GULPEASE = ''; SYSTEM_ACCESSTOKEN = '' }
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
        return @(Get-StubRequests | ForEach-Object { [regex]::Match((Get-UserMessage $_), '(?:SEZIONE|DECISIONE) DA GIUDICARE \(([^)]+)\)').Groups[1].Value })
    }

    function Invoke-Git {
        $output = git -c user.name=t -c user.email=t@t -c core.autocrlf=false @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
        return $output
    }

    function New-PullRequestRepository([scriptblock]$Change, [scriptblock]$Base = {}) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-style-pr-$(New-Guid)"
        $docs = New-Docs
        & $Base $docs
        Write-Docs $docs $root
        Push-Location $root
        try {
            Invoke-Git init -q -b main | Out-Null
            Invoke-Git config core.autocrlf false | Out-Null
            Invoke-Git commit -q --allow-empty -m init | Out-Null
            Invoke-Git add -A | Out-Null
            Invoke-Git commit -q -m base | Out-Null
            Invoke-Git update-ref refs/remotes/origin/main HEAD | Out-Null
            Invoke-Git checkout -q -b feature | Out-Null
            & $Change $docs
            Write-Docs $docs $root
            Invoke-Git add -A | Out-Null
            Invoke-Git commit -q -m change | Out-Null
        }
        finally { Pop-Location }
        return $root
    }

    # Come la build di una PR su Azure DevOps: il ramo della PR e' su un origin, e la copia di
    # lavoro e' il commit di merge del ramo nella destinazione.
    function New-OriginRepository([scriptblock]$Change, [scriptblock]$Base = {}) {
        $bare = Join-Path ([IO.Path]::GetTempPath()) "pester-style-origin-$(New-Guid)"
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-style-build-$(New-Guid)"
        Invoke-Git init -q --bare -b main $bare | Out-Null
        $docs = New-Docs
        & $Base $docs
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
            Invoke-Git commit -q -m change | Out-Null
            Invoke-Git push -q origin feature | Out-Null
            Invoke-Git fetch -q origin | Out-Null
            Invoke-Git checkout -q --detach origin/main | Out-Null
            Invoke-Git merge -q --no-ff --no-edit origin/feature | Out-Null
            $feature = Invoke-Git rev-parse origin/feature
        }
        finally { Pop-Location }
        return @{ Root = $root; Bare = $bare; Feature = $feature }
    }

    # Come un job che va in timeout: lo script si ferma a meta' giudizio e il processo si chiude da fuori.
    function Invoke-InterruptedStyleCheck($Repository, [hashtable]$Environment, [string]$Side) {
        $variables = @{ GATE_MODE = 'enforce'; STYLE_JUDGE_ENDPOINT = $StubEndpoint; STYLE_JUDGE_MODEL = 'giudice'; STYLE_JUDGE_TOKEN = 'token-di-prova'; STYLE_GUIDE = ''; DOCS_GLOSSARY = '03-glossario.md'; STYLE_MAX_ROUNDS = ''; STYLE_MAX_FINDINGS = ''; STYLE_JUDGE_SEED = ''; READABILITY_GULPEASE = ''; SYSTEM_ACCESSTOKEN = '' }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        $previous = @{}
        foreach ($name in $variables.Keys) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $variables[$name])
        }
        try { $process = Start-Process (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $ScriptPath) -WorkingDirectory $Repository.Root -PassThru -WindowStyle Hidden }
        finally { foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) } }
        $deadline = (Get-Date).AddMinutes(2)
        while ((Get-Date) -lt $deadline -and -not (git -C $Repository.Bare branch --list $Side)) { Start-Sleep -Milliseconds 200 }
        Start-Sleep -Seconds 1
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()
    }

    function Update-BuildToFeature($Repository) {
        Push-Location $Repository.Root
        try {
            Invoke-Git reset -q --hard | Out-Null
            Invoke-Git fetch -q origin | Out-Null
            Invoke-Git checkout -q --detach origin/main | Out-Null
            Invoke-Git merge -q --no-ff --no-edit origin/feature | Out-Null
        }
        finally { Pop-Location }
    }

    function Get-FeatureTip($Repository) {
        return Invoke-Git -C $Repository.Bare rev-parse feature
    }

    function Get-FeatureFile($Repository, [string]$Path) {
        return (Invoke-Git -C $Repository.Bare show "feature:$Path") -join "`n"
    }

    function Remove-Repository($Repository) {
        Remove-Item -Recurse -Force $Repository.Root, $Repository.Bare -ErrorAction SilentlyContinue
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

    Context "Scenario: il giudizio copre tutte le regole in un solo passaggio" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(
                @{ match = 'È importante sottolineare che'; rule = $Filler }
                @{ match = 'Va detto che'; rule = $Filler }
                @{ match = 'In questa sezione vedremo che'; rule = $SelfReference })
            $docs = New-Docs
            $docs['docs/architecture/02-vincoli.md'] = "# Vincoli`n`nIn questa sezione vedremo che la piattaforma gira su Azure.`n`nÈ importante sottolineare che i dati restano in Italia.`n`n- Va detto che le reti sono separate.`n"
            $res = Invoke-StyleCheck $docs
            $request = Get-StubRequests | Where-Object { (Get-UserMessage $_) -like '*SEZIONE DA GIUDICARE (02-vincoli.md)*' }
        }

        It "Dato una sezione modificata che viola tre regole diverse della guida di stile" {
            @($request).Count | Should -Be 1
        }

        It "Allora il modello riceve in una sola richiesta tutte le unità modificate della sezione" {
            $user = Get-UserMessage $request
            $user | Should -BeLike '*`[2`*`] In questa sezione vedremo*'
            $user | Should -BeLike '*`[3`*`] È importante sottolineare*'
            $user | Should -BeLike '*`[4`*`] - Va detto che*'
        }

        It "E la risposta ha una voce per ogni regola della guida" {
            $schema = $request.response_format.json_schema.schema
            @($schema.properties.PSObject.Properties | ForEach-Object { $_.Value.description }) | Should -Be @($Filler, $SelfReference)
            $schema.required | Should -Be @('regola_1', 'regola_2')
        }

        It "E la verifica nomina le tre violazioni" {
            $issues = Get-Issues $res.Output
            $issues | Where-Object { $_.StartsWith("Vincoli: $Filler («È importante sottolineare che»") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
            $issues | Where-Object { $_.StartsWith("Vincoli: $Filler («Va detto che»") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
            $issues | Where-Object { $_.StartsWith("Vincoli: $SelfReference («In questa sezione vedremo che»") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: si giudicano solo le righe cambiate" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(
                @{ match = 'gira su Azure'; rule = $Filler; everywhere = $true }
                @{ match = 'Inoltre'; rule = $Filler; everywhere = $true })
            $root = New-PullRequestRepository -Base { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`nI dati restano in Italia." } `
                -Change { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'I dati restano' 'Inoltre i dati restano' }
            $res = Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' }
            Remove-Item -Recurse -Force $root
        }

        It "Dato una sezione già giudicata in cui cambia un solo paragrafo" {
            $user = Get-UserMessage (Get-StubRequests)[0]
            $user | Should -BeLike '*`[2`] La piattaforma gira su Azure.*'
            $user | Should -BeLike '*`[3`*`] Inoltre i dati restano in Italia.*'
        }

        It "Allora la verifica nomina solo violazioni del paragrafo cambiato" {
            $issues = Get-Issues $res.Output
            $issues | Where-Object { $_ -like '*«Inoltre»*' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
            $issues | Where-Object { $_ -like '*«gira su Azure»*' } | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: la pipeline corregge e verifica il risultato" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = 'È importante sottolineare che i dati'; rule = $Filler; replacement = 'I dati' })
            $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`nÈ importante sottolineare che i dati restano in Italia." }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
            $requests = Get-StubRequests
        }

        AfterAll { Remove-Repository $repository }

        It "Allora la pipeline applica la correzione proposta dal modello" {
            $vincoli = Get-FeatureFile $repository 'docs/architecture/02-vincoli.md'
            $vincoli | Should -BeLike '*I dati restano in Italia.*' -Because ($res.Output)
            $vincoli | Should -Not -BeLike '*È importante*'
        }

        It "E il modello giudica di nuovo le righe corrette" {
            $requests.Count | Should -Be 2
            Get-UserMessage $requests[1] | Should -BeLike '*`[3`*`] I dati restano in Italia.*'
        }

        It "E i controlli oggettivi passano sul testo corretto" {
            $res.Output | Should -Match 'Documento in docs/architecture valido'
        }

        It "E il ramo della PR riceve un commit con le correzioni e il segno del file giudicato" {
            Invoke-Git -C $repository.Bare log -1 --format=%B feature | Should -Contain 'Style-Judge-Done: docs/architecture/02-vincoli.md'
            Invoke-Git -C $repository.Bare rev-parse 'feature^' | Should -Be $repository.Feature
        }

        It "E il registro della pipeline mostra il diff delle correzioni" {
            $res.Output | Should -Match '##\[group\]Correzioni del giudizio dello stile'
            $res.Output | Should -Match '(?m)^-È importante sottolineare che i dati restano in Italia\.'
            $res.Output | Should -Match '(?m)^\+I dati restano in Italia\.'
        }

        It "E la verifica passa" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        Context "Scenario: lo stesso testo non si giudica due volte" {
            BeforeAll {
                $tip = Get-FeatureTip $repository
                Update-BuildToFeature $repository
                Reset-Stub
                $again = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
            }

            It "Allora il modello non riceve richieste" {
                @(Get-StubRequests).Count | Should -Be 0
            }

            It "E la verifica passa" {
                $again.ExitCode | Should -Be 0 -Because ($again.Output)
                Get-FeatureTip $repository | Should -Be $tip
            }
        }
    }

    Context "Schema dello scenario: una correzione non accettabile si scarta — <difetto>" -ForEach @(
        @{ difetto = 'rende una frase più lunga del massimo della configurazione'; sezione = 'Vincoli'; vecchio = 'gira su Azure.'; nuovo = 'gira su Azure in Italia.'; regola = @{ match = 'gira su Azure in Italia'; replacement = 'gira su Azure in Italia, con una rete per ogni ambiente e una regola per ogni passaggio fra due parti che si parlano solo quando serve davvero e mai altrimenti' } }
        @{ difetto = 'modifica un diagramma'; sezione = 'Vincoli'; vecchio = 'gira su Azure.'; nuovo = "gira su Azure.`n`n``````mermaid`nflowchart LR`n  A --> B`n```````n"; regola = @{ match = 'A --> B'; replacement = 'A --> C' } }
        @{ difetto = 'modifica un titolo imposto dal modello del documento'; sezione = 'Vincoli della piattaforma'; vecchio = '# Vincoli'; nuovo = '# Vincoli della piattaforma'; regola = @{ match = 'Vincoli della piattaforma'; replacement = 'Vincoli' } }
        @{ difetto = 'cerca un testo che la sezione non contiene'; sezione = 'Vincoli'; vecchio = 'gira su Azure.'; nuovo = 'gira su Azure in Italia.'; regola = @{ match = 'gira su Azure in Italia'; find = 'testo assente'; replacement = 'gira in Italia' } }
    ) {
        BeforeAll {
            Reset-Stub
            $regola.rule = $Filler
            Set-StubRules @($regola)
            $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' $vecchio $nuovo }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
        }

        AfterAll { Remove-Repository $repository }

        It "Allora la correzione è scartata" {
            Get-Issues $res.Output | Where-Object { $_ -like '*correzione scartata*' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E la verifica fallisce nominando la sezione e la regola" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_.StartsWith("${sezione}: $Filler («$($regola.match)»") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il ramo della PR riceve il segno del giudizio con l'unità in sospeso" {
            $message = Invoke-Git -C $repository.Bare log -1 --format=%B feature
            $message | Should -Contain 'Style-Judge-Done: docs/architecture/02-vincoli.md'
            $message | Where-Object { $_ -like "Style-Judge-Pending: docs/architecture/02-vincoli.md`t*" } | Should -Not -BeNullOrEmpty -Because ($res.Output)
            Invoke-Git -C $repository.Bare rev-parse 'feature^' | Should -Be $repository.Feature
        }
    }

    Context "Scenario: una correzione scartata torna al modello con il motivo" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{
                    match            = 'È importante sottolineare che i dati'
                    rule             = $Filler
                    replacement      = 'I dati, che sono quelli dei cittadini, degli enti, degli operatori e dei servizi collegati alla piattaforma in ogni ambiente di sviluppo, di collaudo e di produzione'
                    retryReplacement = 'I dati' })
            $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`nÈ importante sottolineare che i dati restano in Italia." }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
            $requests = Get-StubRequests
        }

        AfterAll { Remove-Repository $repository }

        It "Dato una correzione scartata perché porta una frase oltre il massimo" {
            $requests.Count | Should -Be 3
        }

        It "Quando il modello giudica di nuovo l'unità, riceve il motivo dello scarto" {
            $user = Get-UserMessage $requests[1]
            $user | Should -BeLike '*`[3`*`] È importante sottolineare*'
            $user | Should -BeLike "*CORREZIONI SCARTATE NEL GIRO PRECEDENTE*``[3``] ${Filler}: la correzione porta una frase a * parole, massimo 25*"
        }

        It "Allora la seconda correzione si applica e la verifica passa" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
            Get-FeatureFile $repository 'docs/architecture/02-vincoli.md' | Should -BeLike '*I dati restano in Italia.*'
        }
    }

    Context "Scenario: la correzione non gira all'infinito" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = 'gira su Azure'; rule = $Filler; replacement = 'gira su Azure davvero' })
            $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' 'gira su Azure in Italia.' }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment (Get-FixEnvironment @{ STYLE_MAX_ROUNDS = '3' })
        }

        AfterAll { Remove-Repository $repository }

        It "Allora la pipeline si ferma dopo il numero massimo di giri della configurazione" {
            @(Get-StubRequests).Count | Should -Be 3
        }

        It "E la verifica fallisce nominando le violazioni rimaste" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_.StartsWith("Vincoli: $Filler («gira su Azure»") -and $_ -like '*la correzione non toglie la violazione*' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il ramo della PR riceve le correzioni valide con le unità rimaste in sospeso" {
            Get-FeatureFile $repository 'docs/architecture/02-vincoli.md' | Should -BeLike '*La piattaforma gira su Azure in Italia.*'
            $message = Invoke-Git -C $repository.Bare log -1 --format=%B feature
            $message | Should -Contain 'Style-Judge-Done: docs/architecture/02-vincoli.md'
            $message | Where-Object { $_ -like "Style-Judge-Pending: docs/architecture/02-vincoli.md`t*gira su Azure in Italia*" } | Should -Not -BeNullOrEmpty
        }
    }

    Context "Scenario: violazioni rimaste oltre la soglia" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = 'gira su Azure in Italia'; rule = $Filler; find = 'testo assente'; replacement = 'gira in Italia' })
            $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' 'gira su Azure in Italia.' }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
        }

        AfterAll { Remove-Repository $repository }

        It "Dato la soglia di default, zero violazioni tollerate" {
            @(Get-StubRequests).Count | Should -Be 4
        }

        It "Allora la verifica fallisce nominando la violazione rimasta" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_.StartsWith("Vincoli: $Filler («gira su Azure in Italia»") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E il ramo della PR riceve il segno del giudizio con l'unità in sospeso" {
            $message = Invoke-Git -C $repository.Bare log -1 --format=%B feature
            $message | Should -Contain 'Style-Judge-Done: docs/architecture/02-vincoli.md'
            @($message | Where-Object { $_ -like "Style-Judge-Pending: docs/architecture/02-vincoli.md`t*gira su Azure in Italia*" }).Count | Should -Be 1
            Invoke-Git -C $repository.Bare rev-parse 'feature^' | Should -Be $repository.Feature
        }

        Context "Scenario: il giudizio dopo rilegge solo le unità in sospeso" {
            BeforeAll {
                Update-BuildToFeature $repository
                Reset-Stub
                $again = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
                $requests = @(Get-StubRequests)
            }

            It "Allora il modello giudica solo la sezione con l'unità in sospeso" {
                Get-JudgedFiles | Select-Object -Unique | Should -Be @('02-vincoli.md')
            }

            It "E nella sezione è segnata solo quell'unità" {
                $marked = [regex]::Matches((Get-UserMessage $requests[0]), '\[\d+\*\] .*')
                @($marked).Count | Should -Be 1
                $marked[0].Value | Should -BeLike '*gira su Azure in Italia*'
            }

            It "E la verifica passa quando l'unità in sospeso non ha più violazioni" {
                $again.ExitCode | Should -Be 0 -Because ($again.Output -join "`n")
                $message = Invoke-Git -C $repository.Bare log -1 --format=%B feature
                $message | Should -Contain 'Style-Judge-Done: docs/architecture/02-vincoli.md'
                $message | Where-Object { $_ -like 'Style-Judge-Pending:*' } | Should -BeNullOrEmpty
            }
        }
    }

    Context "Scenario: l'unità in sospeso viola ancora la regola" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = 'gira su Azure in Italia'; rule = $Filler; find = 'testo assente'; replacement = 'gira in Italia' })
            $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' 'gira su Azure in Italia.' }
            Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment | Out-Null
            Update-BuildToFeature $repository
            $judged = Get-FeatureTip $repository
            Reset-Stub
            Set-StubRules @(@{ match = 'gira su Azure in Italia'; rule = $Filler; replacement = 'gira in Italia' })
            $again = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
        }

        AfterAll { Remove-Repository $repository }

        It "Allora il modello la verifica con un solo giro" {
            @(Get-StubRequests).Count | Should -Be 1
        }

        It "E la correzione proposta non si applica" {
            Get-FeatureFile $repository 'docs/architecture/02-vincoli.md' | Should -BeLike '*gira su Azure in Italia.*'
        }

        It "E il ramo della PR non cambia, perché un push avvierebbe un'altra build sullo stesso rilievo" {
            Get-FeatureTip $repository | Should -Be $judged
        }

        It "E la verifica fallisce nominando la violazione rimasta" {
            $again.ExitCode | Should -Be 1
            Get-Issues $again.Output | Where-Object { $_.StartsWith("Vincoli: $Filler («gira su Azure in Italia»") } | Should -Not -BeNullOrEmpty -Because ($again.Output)
        }
    }

    Context "Scenario: violazioni rimaste entro la soglia" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = 'gira su Azure in Italia'; rule = $Filler; find = 'testo assente'; replacement = 'gira in Italia' })
            $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' 'gira su Azure in Italia.' }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment (Get-FixEnvironment @{ STYLE_MAX_FINDINGS = '1' })
        }

        AfterAll { Remove-Repository $repository }

        It "Allora la violazione resta come avviso che nomina la sezione e la regola" {
            Get-Issues $res.Output 'warning' | Where-Object { $_.StartsWith("Vincoli: $Filler («gira su Azure in Italia»") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "E la verifica passa con esito parziale" {
            Get-Issues $res.Output | Should -BeNullOrEmpty
            $res.Output | Should -Match 'task\.complete result=SucceededWithIssues'
            $res.ExitCode | Should -Be 0
        }

        It "E il ramo della PR riceve il segno del giudizio senza unità in sospeso" {
            $message = Invoke-Git -C $repository.Bare log -1 --format=%B feature
            $message | Should -Contain 'Style-Judge: clean'
            $message | Where-Object { $_ -like 'Style-Judge-Pending:*' } | Should -BeNullOrEmpty
        }

        Context "Scenario: il giudizio dopo non rifà il lavoro" {
            BeforeAll {
                Update-BuildToFeature $repository
                Reset-Stub
                $again = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment (Get-FixEnvironment @{ STYLE_MAX_FINDINGS = '1' })
            }

            It "Allora il modello non riceve richieste e la verifica passa" {
                @(Get-StubRequests).Count | Should -Be 0
                $again.ExitCode | Should -Be 0 -Because ($again.Output)
            }
        }
    }

    Context "Schema dello scenario: la soglia delle violazioni tollerate — <soglia>" -ForEach @(
        @{ soglia = '2'; uscita = 1; livello = 'error' }
        @{ soglia = '3'; uscita = 0; livello = 'warning' }
        @{ soglia = '-1'; uscita = 0; livello = 'warning' }
    ) {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(
                @{ match = 'È importante sottolineare che'; rule = $Filler }
                @{ match = 'Va detto che'; rule = $Filler }
                @{ match = 'In questa sezione vedremo che'; rule = $SelfReference })
            $docs = New-Docs
            $docs['docs/architecture/02-vincoli.md'] = "# Vincoli`n`nIn questa sezione vedremo che la piattaforma gira su Azure.`n`nÈ importante sottolineare che i dati restano in Italia.`n`n- Va detto che le reti sono separate.`n"
            $res = Invoke-StyleCheck $docs -Environment @{ STYLE_MAX_FINDINGS = $soglia }
        }

        It "Dato tre violazioni, la verifica le nomina tutte e tre al livello della soglia" {
            @(Get-Issues $res.Output $livello).Count | Should -Be 3 -Because ($res.Output)
        }

        It "E l'esito dipende dalla soglia" {
            $res.ExitCode | Should -Be $uscita
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
        Get-StubRequests | ForEach-Object { Get-UserMessage $_ | Should -BeLike '*il cloud di Microsoft*' }
    }

    It "Chiede una risposta nel formato fissato, con il deployment configurato" {
        Invoke-StyleCheck (New-Docs) | Out-Null
        $request = (Get-StubRequests)[0]
        $request.model | Should -Be 'giudice'
        $request.response_format.type | Should -Be 'json_schema'
        $request.response_format.json_schema.strict | Should -BeTrue
        $request.response_format.json_schema.schema.properties.regola_1.items.required | Should -Be @('unit', 'excerpt', 'explanation', 'fix')
    }

    It "Le regole sono i titoli della parte Regole, non quelli degli esempi" {
        Invoke-StyleCheck (New-Docs) | Out-Null
        @((Get-StubRequests)[0].response_format.json_schema.schema.properties.PSObject.Properties).Count | Should -Be 2
    }

    It "Chiede il seme configurato" {
        Invoke-StyleCheck (New-Docs) -Environment @{ STYLE_JUDGE_SEED = '7' } | Out-Null
        Get-StubRequests | ForEach-Object { $_.seed | Should -Be 7 }
    }

    It "Riprova senza seme se il modello lo rifiuta" {
        Set-Content (Join-Path $StubState 'reject-seed') ''
        $res = Invoke-StyleCheck (New-Docs)
        $requests = Get-StubRequests
        $requests[0].seed | Should -Not -BeNullOrEmpty
        $requests | Select-Object -Skip 1 | ForEach-Object { $_.seed | Should -BeNullOrEmpty }
        $res.ExitCode | Should -Be 0 -Because ($res.Output)
    }

    It "Riporta le richieste e i token consumati" {
        $res = Invoke-StyleCheck (New-Docs)
        $res.Output | Should -Match 'Giudizio dello stile: 2 richieste, 200 token in ingresso, 20 in uscita'
    }

    Context "In una PR" {

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

        It "Giudica una decisione nuova" {
            $root = New-PullRequestRepository { param($d) $d['docs/decisions/0002-nuova.md'] = $NewDecision }
            Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' } | Out-Null
            Remove-Item -Recurse -Force $root
            Get-JudgedFiles | Should -Be @('0002-nuova.md')
        }

        It "Giudica le righe cambiate di una decisione esistente" {
            Set-StubRules @(
                @{ match = 'Le copie restano'; rule = $Filler; everywhere = $true }
                @{ match = 'Inoltre'; rule = $Filler; everywhere = $true })
            $root = New-PullRequestRepository -Base { param($d) $d['docs/decisions/0001-esistente.md'] = $ExistingDecision } `
                -Change { param($d) Edit-Docs $d 'docs/decisions/0001-esistente.md' 'Le copie restano in Italia.' "Le copie restano in Italia.`n`nInoltre si cifrano." }
            $res = Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' }
            Remove-Item -Recurse -Force $root
            $issues = Get-Issues $res.Output
            $issues | Where-Object { $_ -like '*«Inoltre»*' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
            $issues | Where-Object { $_ -like '*«Le copie restano»*' } | Should -BeNullOrEmpty
        }

        It "Non giudica le decisioni esistenti se cambia la guida" {
            $root = New-PullRequestRepository -Base { param($d) $d['docs/decisions/0001-esistente.md'] = $ExistingDecision } `
                -Change { param($d) Edit-Docs $d 'docs/STYLE.md' 'si toglie.' 'si toglie sempre.' }
            Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' } | Out-Null
            Remove-Item -Recurse -Force $root
            Get-JudgedFiles | Should -Be @('01-introduzione-e-obiettivi.md', '02-vincoli.md')
        }

        It "Manda a una decisione le regole comuni e quelle delle decisioni, a una sezione le comuni e quelle delle sezioni" {
            $root = New-PullRequestRepository -Base { param($d) $d['docs/STYLE.md'] = $PartedGuide } -Change { param($d) $d['docs/decisions/0002-nuova.md'] = $NewDecision; Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' 'gira su Azure in Italia.' }
            Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' } | Out-Null
            Remove-Item -Recurse -Force $root
            $requests = @(Get-StubRequests)
            $decision = $requests | Where-Object { (Get-UserMessage $_) -like '*DECISIONE DA GIUDICARE (0002-nuova.md)*' }
            $section = $requests | Where-Object { (Get-UserMessage $_) -like '*SEZIONE DA GIUDICARE (02-vincoli.md)*' }
            @($decision.response_format.json_schema.schema.properties.PSObject.Properties | ForEach-Object { $_.Value.description }) | Should -Be @($Filler, $DecisionRule)
            @($section.response_format.json_schema.schema.properties.PSObject.Properties | ForEach-Object { $_.Value.description }) | Should -Be @($Filler, $SectionRule)
            $decisionGuide = ($decision.messages | Where-Object role -EQ 'system').content
            $sectionGuide = ($section.messages | Where-Object role -EQ 'system').content
            $decisionGuide | Should -Not -BeLike "*$SectionRule*"
            $decisionGuide | Should -Not -BeLike '*Un titolo dentro un esempio delle sezioni*'
            $sectionGuide | Should -Not -BeLike "*$DecisionRule*"
        }

        It "Non rigiudica le sezioni se la guida cambia solo nelle regole delle decisioni o nell'ordine delle regole" {
            $root = New-PullRequestRepository -Base { param($d) $d['docs/STYLE.md'] = $PartedGuide } -Change {
                param($d)
                $d['docs/STYLE.md'] = $PartedGuide.Replace('senza sigle.', 'senza sigle né abbreviazioni.').Replace("## Regole delle sezioni`n", "## Regole delle sezioni`n`nLe regole che valgono solo per le sezioni.`n")
            }
            Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' } | Out-Null
            Remove-Item -Recurse -Force $root
            @(Get-StubRequests).Count | Should -Be 0
        }

        It "Rigiudica tutte le sezioni se cambia una regola delle sezioni" {
            $root = New-PullRequestRepository -Base { param($d) $d['docs/STYLE.md'] = $PartedGuide } -Change { param($d) $d['docs/STYLE.md'] = $PartedGuide.Replace('nomina i lettori.', 'nomina i lettori e la domanda.') }
            Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' } | Out-Null
            Remove-Item -Recurse -Force $root
            Get-JudgedFiles | Should -Be @('01-introduzione-e-obiettivi.md', '02-vincoli.md')
        }

        It "Non manda al modello l'intestazione di una decisione" {
            $root = New-PullRequestRepository { param($d) $d['docs/decisions/0002-nuova.md'] = $NewDecision }
            Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' } | Out-Null
            Remove-Item -Recurse -Force $root
            Get-UserMessage (Get-StubRequests)[0] | Should -Not -BeLike '*status: accepted*'
        }

        It "Legge le decisioni dalla cartella dichiarata" {
            $root = New-PullRequestRepository { param($d) $d['adr/0002-nuova.md'] = $NewDecision }
            Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main'; DECISIONS_DIRECTORY = 'adr' } | Out-Null
            Remove-Item -Recurse -Force $root
            Get-JudgedFiles | Should -Be @('0002-nuova.md')
        }
    }

    It "Fuori da una PR non giudica le decisioni" {
        $docs = New-Docs
        $docs['docs/decisions/0001-esistente.md'] = $ExistingDecision
        Invoke-StyleCheck $docs | Out-Null
        Get-JudgedFiles | Should -Be @('01-introduzione-e-obiettivi.md', '02-vincoli.md')
    }
}

Describe "Funzionalità: il giudizio dello stile pubblica un file alla volta" {

    Context "Scenario: il job si interrompe a metà documento" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(
                @{ match = 'È importante sottolineare che la piattaforma'; rule = $Filler; replacement = 'La piattaforma' }
                @{ match = 'È importante sottolineare che i dati'; rule = $Filler; replacement = 'I dati' })
            [IO.File]::WriteAllText((Join-Path $StubState 'hang-on'), 'SEZIONE DA GIUDICARE (02-vincoli.md)')
            $repository = New-OriginRepository {
                param($d)
                Edit-Docs $d 'docs/architecture/01-introduzione-e-obiettivi.md' 'La piattaforma aiuta' 'È importante sottolineare che la piattaforma aiuta'
                Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`nÈ importante sottolineare che i dati restano in Italia."
            }
            $side = "style-judge/$($repository.Feature)"
            Invoke-InterruptedStyleCheck $repository $FixEnvironment $side
        }

        AfterAll { Remove-Repository $repository }

        It "Allora il ramo della PR non cambia, perché un push avvierebbe una nuova build" {
            Get-FeatureTip $repository | Should -Be $repository.Feature
        }

        It "E il ramo di appoggio ha il commit della prima sezione con le sue correzioni" {
            Invoke-Git -C $repository.Bare log -1 --format=%B $side | Should -Contain 'Style-Judge-Done: docs/architecture/01-introduzione-e-obiettivi.md'
            Invoke-Git -C $repository.Bare rev-parse "$side^" | Should -Be $repository.Feature
            (Invoke-Git -C $repository.Bare show "${side}:docs/architecture/01-introduzione-e-obiettivi.md") -join "`n" | Should -Not -BeLike '*sottolineare*'
        }

        Context "Scenario: la build dopo riprende il lavoro interrotto" {
            BeforeAll {
                Update-BuildToFeature $repository
                Reset-Stub
                $resumed = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
            }

            It "Allora il modello non riceve richieste" {
                @(Get-StubRequests).Count | Should -Be 0
            }

            It "E il ramo della PR riceve i commit del ramo di appoggio, che si cancella" {
                Invoke-Git -C $repository.Bare log -1 --format=%B feature | Should -Contain 'Style-Judge-Done: docs/architecture/01-introduzione-e-obiettivi.md'
                Invoke-Git -C $repository.Bare rev-parse 'feature^' | Should -Be $repository.Feature
                git -C $repository.Bare branch --list $side | Should -BeNullOrEmpty
            }

            It "E la verifica fallisce dicendo che riparte dal commit ripreso" {
                $resumed.ExitCode | Should -Be 1
                Get-Issues $resumed.Output | Where-Object { $_ -like 'giudizio dello stile: giudizio ripreso*' } | Should -Not -BeNullOrEmpty -Because ($resumed.Output)
            }

            Context "Scenario: la build avviata dal commit ripreso giudica il resto" {
                BeforeAll {
                    Update-BuildToFeature $repository
                    Reset-Stub
                    Set-StubRules @(@{ match = 'È importante sottolineare che i dati'; rule = $Filler; replacement = 'I dati' })
                    $rest = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
                }

                It "Allora il modello giudica solo la seconda sezione" {
                    Get-JudgedFiles | Select-Object -Unique | Should -Be @('02-vincoli.md')
                }

                It "E la verifica passa con le correzioni di entrambe le sezioni sul ramo della PR" {
                    $rest.ExitCode | Should -Be 0 -Because ($rest.Output)
                    Get-FeatureFile $repository 'docs/architecture/02-vincoli.md' | Should -BeLike '*I dati restano in Italia.*'
                    Invoke-Git -C $repository.Bare rev-parse 'feature~2' | Should -Be $repository.Feature
                }
            }
        }
    }

    Context "Scenario: il giudizio si interrompe a metà documento" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(
                @{ match = 'È importante sottolineare che la piattaforma'; rule = $Filler; replacement = 'La piattaforma' }
                @{ match = 'È importante sottolineare che i dati'; rule = $Filler; replacement = 'I dati' })
            [IO.File]::WriteAllText((Join-Path $StubState 'fail-on'), 'SEZIONE DA GIUDICARE (02-vincoli.md)')
            $repository = New-OriginRepository {
                param($d)
                Edit-Docs $d 'docs/architecture/01-introduzione-e-obiettivi.md' 'La piattaforma aiuta' 'È importante sottolineare che la piattaforma aiuta'
                Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`nÈ importante sottolineare che i dati restano in Italia."
            }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
        }

        AfterAll { Remove-Repository $repository }

        It "Dato il modello che non risponde sulla seconda sezione" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_ -match '^giudizio dello stile: verifica non eseguita \(02-vincoli\.md: ' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }

        It "Allora il ramo della PR ha già le correzioni della prima sezione, nel suo commit" {
            Get-FeatureFile $repository 'docs/architecture/01-introduzione-e-obiettivi.md' | Should -Not -BeLike '*sottolineare*' -Because ($res.Output)
            Invoke-Git -C $repository.Bare log -1 --format=%B feature | Should -Contain 'Style-Judge-Done: docs/architecture/01-introduzione-e-obiettivi.md'
            Invoke-Git -C $repository.Bare rev-parse 'feature^' | Should -Be $repository.Feature
        }

        It "E la seconda sezione resta come nella PR" {
            Get-FeatureFile $repository 'docs/architecture/02-vincoli.md' | Should -BeLike '*sottolineare che i dati*'
        }

        Context "Scenario: il giudizio dopo riparte dalle sezioni non pubblicate" {
            BeforeAll {
                Update-BuildToFeature $repository
                Reset-Stub
                Set-StubRules @(@{ match = 'È importante sottolineare che i dati'; rule = $Filler; replacement = 'I dati' })
                $again = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
            }

            It "Allora il modello giudica solo la seconda sezione" {
                Get-JudgedFiles | Select-Object -Unique | Should -Be @('02-vincoli.md')
            }

            It "E il ramo della PR riceve un commit per la seconda sezione" {
                Get-FeatureFile $repository 'docs/architecture/02-vincoli.md' | Should -BeLike '*I dati restano in Italia.*' -Because ($again.Output)
                Invoke-Git -C $repository.Bare log -1 --format=%B feature | Should -Contain 'Style-Judge-Done: docs/architecture/02-vincoli.md'
                Invoke-Git -C $repository.Bare rev-parse 'feature~2' | Should -Be $repository.Feature
            }

            It "E la verifica passa" {
                $again.ExitCode | Should -Be 0 -Because ($again.Output)
            }
        }
    }

    Context "Scenario: violazioni entro la soglia in più sezioni" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(
                @{ match = 'gira su Azure in Italia'; rule = $Filler; find = 'testo assente'; replacement = 'gira in Italia' }
                @{ match = 'aiuta il utente'; rule = $Filler; find = 'testo assente'; replacement = "aiuta l'utente" })
            $repository = New-OriginRepository {
                param($d)
                Edit-Docs $d 'docs/architecture/01-introduzione-e-obiettivi.md' 'La piattaforma aiuta' 'Oggi la piattaforma aiuta'
                Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' 'gira su Azure in Italia.'
            }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment (Get-FixEnvironment @{ STYLE_MAX_FINDINGS = '2' })
        }

        AfterAll { Remove-Repository $repository }

        It "Allora ogni sezione ha il suo commit con l'unità in sospeso, e un commit finale chiude il giudizio" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
            Invoke-Git -C $repository.Bare log -1 --format=%B feature | Should -Contain 'Style-Judge: clean'
            Invoke-Git -C $repository.Bare log -1 --format=%B 'feature~1' | Should -Contain 'Style-Judge-Done: docs/architecture/02-vincoli.md'
            Invoke-Git -C $repository.Bare log -1 --format=%B 'feature~2' | Should -Contain 'Style-Judge-Done: docs/architecture/01-introduzione-e-obiettivi.md'
            Invoke-Git -C $repository.Bare rev-parse 'feature~3' | Should -Be $repository.Feature
        }
    }
}

Describe "Test-DocumentationStyle — correzioni in una decisione nuova" {

    BeforeAll {
        Reset-Stub
        Set-StubRules @(@{ match = 'È importante sottolineare che le copie'; rule = $Filler; replacement = 'Le copie' })
        $repository = New-OriginRepository { param($d) $d['docs/decisions/0002-nuova.md'] = $NewDecision.Replace('Le copie restano', 'È importante sottolineare che le copie restano') }
        $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
    }

    AfterAll { Remove-Repository $repository }

    It "Allora il ramo della PR riceve la decisione corretta con il segno del file giudicato" {
        Get-FeatureFile $repository 'docs/decisions/0002-nuova.md' | Should -BeLike '*Le copie restano in Italia.*' -Because ($res.Output)
        Get-FeatureFile $repository 'docs/decisions/0002-nuova.md' | Should -Not -BeLike '*È importante*'
        Invoke-Git -C $repository.Bare log -1 --format=%B feature | Should -Contain 'Style-Judge-Done: docs/decisions/0002-nuova.md'
    }

    It "E la verifica passa" {
        $res.ExitCode | Should -Be 0 -Because ($res.Output)
    }
}

Describe "Test-DocumentationStyle — correzioni" {

    BeforeEach { Reset-Stub }

    It "Aggiunge al glossario la voce proposta, una volta sola" {
        $entry = '**Italia**: il paese in cui restano i dati.'
        Set-StubRules @(
            @{ match = 'restano in Italia'; rule = $Filler; glossaryInsert = $entry; until = '**Italia**' }
            @{ match = 'I dati'; rule = $SelfReference; glossaryInsert = $entry; until = '**Italia**' })
        $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`nI dati restano in Italia." }
        $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
        $glossary = Get-FeatureFile $repository 'docs/architecture/03-glossario.md'
        Remove-Repository $repository
        $res.ExitCode | Should -Be 0 -Because ($res.Output)
        $glossary | Should -Be "# Glossario`n`n$entry`n`n**Azure**: il cloud di Microsoft."
    }

    It "Non pubblica se i controlli oggettivi falliscono sul testo corretto" {
        Set-StubRules @(@{ match = 'È importante sottolineare che i dati'; rule = $Filler; replacement = 'I dati' })
        $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`nÈ importante sottolineare che i dati restano in Italia." }
        $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment (Get-FixEnvironment @{ READABILITY_GULPEASE = '100' })
        $tip = Get-FeatureTip $repository
        Remove-Repository $repository
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -like 'giudizio dello stile: correzioni non pubblicate (i controlli oggettivi*' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        $tip | Should -Be $repository.Feature
    }

    It "Fuori da una PR non corregge e verifica soltanto" {
        Set-StubRules @(@{ match = 'gira su Azure'; rule = $Filler; replacement = 'gira' })
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-style-$(New-Guid)"
        Write-Docs (New-Docs) $root
        $res = Invoke-StyleCheck -Root $root -Mode 'enforce' -Environment @{ STYLE_FIX = 'true' }
        $vincoli = [IO.File]::ReadAllText((Join-Path $root 'docs/architecture/02-vincoli.md'))
        Remove-Item -Recurse -Force $root
        $res.ExitCode | Should -Be 1
        $vincoli | Should -BeLike '*gira su Azure.*'
        @(Get-StubRequests).Count | Should -Be 2
    }

    It "Riavvolge al margine il paragrafo corretto, senza aprire un elenco a inizio riga" {
        $long = ('parola ' * 15).Trim()
        Set-StubRules @(@{ match = 'Breve.'; rule = $Filler; replacement = "Lungo $long 1. $long." })
        $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'La piattaforma gira su Azure.' 'Breve.' }
        $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment (Get-FixEnvironment @{ READABILITY_MAX_WORDS = '' })
        $lines = @((Get-FeatureFile $repository 'docs/architecture/02-vincoli.md') -split "`n")
        Remove-Repository $repository
        $res.ExitCode | Should -Be 0 -Because ($res.Output)
        $lines.Count | Should -Be 4
        $lines[2] | Should -Be "Lungo $long 1."
        $lines[3] | Should -Be "$long."
    }
}

Describe "Test-DocumentationStyle — configurazione e modalità" {

    BeforeEach { Reset-Stub }

    It "Manda al modello la guida indicata dal parametro" {
        $docs = New-Docs
        $docs['docs/guide/scrittura.md'] = "# Altra guida`n`n### Niente sigle`n"
        Invoke-StyleCheck $docs -Environment @{ STYLE_GUIDE = 'docs/guide/scrittura.md' } | Out-Null
        (Get-StubRequests)[0].messages[0].content | Should -BeLike '*### Niente sigle*'
    }

    It "Senza la guida fallisce nominando il file" {
        $docs = New-Docs
        $docs['docs/STYLE.md'] = $null
        $res = Invoke-StyleCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^giudizio dello stile: guida mancante \(.*STYLE\.md\)' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Con una guida senza regole fallisce nominando il file" {
        $docs = New-Docs
        $docs['docs/STYLE.md'] = "# Guida`n`nScrivi bene.`n"
        $res = Invoke-StyleCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^giudizio dello stile: guida senza regole \(.*STYLE\.md\)' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        @(Get-StubRequests).Count | Should -Be 0
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

Describe "Funzionalità: Giudizio delle decisioni architetturali" {

    BeforeEach { Reset-Stub }

    It "Scenario: decisione nuova che viola una regola delle decisioni: la verifica nomina la decisione e la regola" {
        Set-StubRules @(@{ match = 'Copie cifrate'; rule = $DecisionRule })
        $root = New-PullRequestRepository -Base { param($d) $d['docs/STYLE.md'] = $PartedGuide } -Change { param($d) $d['docs/decisions/0002-nuova.md'] = $NewDecision }
        $res = Invoke-StyleCheck -Root $root -Mode 'enforce' -Environment @{ TARGET_BRANCH = 'refs/heads/main' }
        Remove-Item -Recurse -Force $root
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_.StartsWith("0002-nuova: $DecisionRule («Copie cifrate»") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Scenario: una regola delle sezioni non vale per le decisioni" {
        Set-StubRules @(@{ match = 'Servono copie'; rule = $SectionRule; everywhere = $true })
        $root = New-PullRequestRepository -Base { param($d) $d['docs/STYLE.md'] = $PartedGuide } -Change { param($d) $d['docs/decisions/0002-nuova.md'] = $NewDecision }
        $res = Invoke-StyleCheck -Root $root -Mode 'enforce' -Environment @{ TARGET_BRANCH = 'refs/heads/main' }
        Remove-Item -Recurse -Force $root
        $res.ExitCode | Should -Be 0 -Because ($res.Output)
    }

    It "Scenario: le decisioni chiuse non si giudicano" {
        $root = New-PullRequestRepository { param($d) $d['docs/decisions/0002-nuova.md'] = $NewDecision.Replace('status: accepted', 'status: rejected') }
        Invoke-StyleCheck -Root $root -Environment @{ TARGET_BRANCH = 'refs/heads/main' } | Out-Null
        Remove-Item -Recurse -Force $root
        @(Get-StubRequests).Count | Should -Be 0
    }

    Context "Scenario: la correzione non crea versioni" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = 'È importante sottolineare che servono'; rule = $Filler; replacement = 'Servono' })
            $versioned = $ExistingDecision.Replace('status: accepted', "status: accepted`nversion: 2").Replace('Le copie restano in Italia.', "Le copie restano in Italia.`n`n## Versioni`n`n- 2: il contesto comprende i backup.")
            $versioned = $versioned.Replace('Servono copie dei dati.', 'È importante sottolineare che servono copie dei dati e dei backup.')
            $repository = New-OriginRepository -Base { param($d) $d['docs/decisions/0001-esistente.md'] = $ExistingDecision } -Change { param($d) $d['docs/decisions/0001-esistente.md'] = $versioned }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
            $decision = Get-FeatureFile $repository 'docs/decisions/0001-esistente.md'
            $judged = Get-JudgedFiles | Select-Object -Unique
        }

        AfterAll { Remove-Repository $repository }

        It "Dato la decisione accettata portata dalla PR alla versione 2 con un riempitivo nel paragrafo cambiato" {
            $judged | Should -Be @('0001-esistente.md')
        }

        It "Allora il paragrafo si corregge" {
            $decision | Should -BeLike '*Servono copie dei dati e dei backup.*' -Because ($res.Output)
            $decision | Should -Not -BeLike '*È importante*'
        }

        It "E la decisione resta alla versione 2" {
            $decision | Should -BeLike "*version: 2`n*"
        }

        It "E la verifica del corpus passa" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }

    Context "Scenario: il titolo di una decisione nuova si corregge con il suo indice" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = 'Copie cifrate C4'; rule = $DecisionRule; replacement = 'Copie cifrate in Italia' })
            $repository = New-OriginRepository -Base { param($d) $d['docs/STYLE.md'] = $PartedGuide } -Change {
                param($d)
                $d['docs/decisions/0002-nuova.md'] = $NewDecision.Replace('# Copie cifrate', '# Copie cifrate C4')
                Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`n| Decisione | Titolo |`n|---|---|`n| [0002](../decisions/0002-nuova.md) | Copie cifrate C4 |"
            }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
        }

        AfterAll { Remove-Repository $repository }

        It "Allora il titolo si corregge" {
            Get-FeatureFile $repository 'docs/decisions/0002-nuova.md' | Should -BeLike "*# Copie cifrate in Italia`n*" -Because ($res.Output)
        }

        It "E la riga dell'indice riporta il titolo corretto" {
            Get-FeatureFile $repository 'docs/architecture/02-vincoli.md' | Should -BeLike '*| `[0002`](../decisions/0002-nuova.md) | Copie cifrate in Italia |*'
        }

        It "E i controlli oggettivi passano" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }

        It "E il commit della decisione conta come giudicato anche l'indice" {
            $message = Invoke-Git -C $repository.Bare log -1 --format=%B feature
            $message | Should -Contain 'Style-Judge-Done: docs/decisions/0002-nuova.md'
            $message | Should -Contain 'Style-Judge-Done: docs/architecture/02-vincoli.md'
        }
    }
}

Describe "Funzionalità: Verifica della documentazione architetturale — titoli e correzioni verificate" {

    BeforeEach { Reset-Stub }

    Context "Scenario: un titolo libero si corregge con i suoi rimandi" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = 'Regione C4'; rule = $Filler; replacement = 'Regione' })
            $repository = New-OriginRepository {
                param($d)
                Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`n## Regione C4`n`nI dati restano in Italia."
                Edit-Docs $d 'docs/architecture/01-introduzione-e-obiettivi.md' 'La piattaforma aiuta' 'La piattaforma, ospitata nella [regione scelta](02-vincoli.md#regione-c4), aiuta'
            }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
        }

        AfterAll { Remove-Repository $repository }

        It "Allora il titolo e il rimando si correggono insieme" {
            Get-FeatureFile $repository 'docs/architecture/02-vincoli.md' | Should -BeLike "*## Regione`n*" -Because ($res.Output)
            Get-FeatureFile $repository 'docs/architecture/01-introduzione-e-obiettivi.md' | Should -BeLike '*(02-vincoli.md#regione)*'
        }

        It "E i controlli oggettivi passano" {
            $res.ExitCode | Should -Be 0 -Because ($res.Output)
        }
    }

    Context "Scenario: una correzione che non toglie la violazione si annulla" {
        BeforeAll {
            Reset-Stub
            Set-StubRules @(@{ match = 'Regione C4'; rule = $Filler; insert = 'La regione è quella di Milano.' })
            $repository = New-OriginRepository { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' 'gira su Azure.' "gira su Azure.`n`n## Regione C4`n`nI dati restano in Italia." }
            $res = Invoke-StyleCheck -Root $repository.Root -Mode 'enforce' -Environment $FixEnvironment
        }

        AfterAll { Remove-Repository $repository }

        It "Allora il paragrafo aggiunto si toglie" {
            Get-FeatureFile $repository 'docs/architecture/02-vincoli.md' | Should -Not -BeLike '*Milano*'
        }

        It "E la correzione è scartata con il motivo «non toglie la violazione»" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_.StartsWith("Vincoli: $Filler («Regione C4»") -and $_ -like '*la correzione non toglie la violazione*' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }
}
