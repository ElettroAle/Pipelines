# SPDX-License-Identifier: Apache-2.0

#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/AzureRepos/Publish-PullRequest.ps1

.DESCRIPTION
    Ogni scenario usa un repository bare locale come origin e un clone come checkout della pipeline,
    con la cartella generata scritta nel clone. L'API delle PR e' un endpoint locale
    (Fixtures/AzureReposStub.ps1) che registra le richieste; le prove verificano cosa arriva sul ramo
    di origin e cosa si chiede all'API.
#>

BeforeAll {
    $script:Script = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/AzureRepos/Publish-PullRequest.ps1"
    $script:StubState = Join-Path ([IO.Path]::GetTempPath()) "pester-pr-$(New-Guid)"
    New-Item -ItemType Directory -Path $StubState | Out-Null
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $script:StubEndpoint = "http://127.0.0.1:$port"
    $stubScript = Resolve-Path "$PSScriptRoot/Fixtures/AzureReposStub.ps1"
    $script:Stub = Start-ThreadJob -ArgumentList $StubEndpoint, $StubState, "$stubScript" -ScriptBlock {
        param($Endpoint, $State, $Script)
        & $Script $Endpoint $State
    }
    $script:Branch = 'c4/aidea.dxp.ai'
    $script:Generated = 'docs/architecture/model/generated'
    $script:Workspaces = [System.Collections.Generic.List[string]]::new()

    function Reset-Stub([object[]]$Active = @(), [int]$Status = 200) {
        Get-ChildItem $StubState -File | Remove-Item -Force
        if ($Active.Count) { [IO.File]::WriteAllText((Join-Path $StubState 'active.json'), (ConvertTo-Json @($Active) -Depth 6)) }
        if ($Status -ne 200) { [IO.File]::WriteAllText((Join-Path $StubState 'status'), "$Status") }
    }

    function Get-StubRequests {
        return @(Get-ChildItem $StubState -Filter 'request-*.json' | Sort-Object { [int]($_.BaseName -replace '\D', '') } | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    }

    function Invoke-Git([string]$Directory) {
        $out = git -C $Directory @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' '): $out" }
        return $out
    }

    function New-Directory([string]$Name) {
        $path = Join-Path ([IO.Path]::GetTempPath()) "pester-pr-$Name-$(New-Guid)"
        New-Item -ItemType Directory -Path $path | Out-Null
        $Workspaces.Add($path)
        return $path
    }

    function Write-Files([string]$Root, [System.Collections.IDictionary]$Files) {
        foreach ($name in $Files.Keys) {
            $path = Join-Path $Root $name
            New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
            [IO.File]::WriteAllText($path, $Files[$name])
        }
    }

    function Save-Commit([string]$Root, [string]$Message) {
        Invoke-Git $Root add -A | Out-Null
        Invoke-Git $Root -c user.name=Prova -c user.email=prova@example.com commit -q --allow-empty -m $Message | Out-Null
    }

    # Origin con main che porta i file dati, e un clone come checkout della pipeline.
    function New-Checkout([System.Collections.IDictionary]$MainFiles) {
        $origin = Join-Path (New-Directory 'origin') 'Docs.Repo.git'
        Invoke-Git ([IO.Path]::GetTempPath()) init -q --bare -b main $origin | Out-Null
        $clone = Join-Path (New-Directory 'clone') 'docs'
        Invoke-Git ([IO.Path]::GetTempPath()) clone -q $origin $clone 2>$null | Out-Null
        Write-Files $clone $MainFiles
        Save-Commit $clone 'main'
        Invoke-Git $clone push -q origin HEAD:main | Out-Null
        return [pscustomobject]@{ Origin = $origin; Clone = $clone }
    }

    function Push-Branch($Checkout, [System.Collections.IDictionary]$Files, [string]$Message) {
        $other = Join-Path (New-Directory 'other') 'docs'
        Invoke-Git ([IO.Path]::GetTempPath()) clone -q $Checkout.Origin $other 2>$null | Out-Null
        Write-Files $other $Files
        Save-Commit $other $Message
        Invoke-Git $other push -q origin "HEAD:refs/heads/$Branch" | Out-Null
    }

    function New-OriginRepository([string]$Repository) {
        $source = Join-Path (New-Directory 'source') $Repository
        Invoke-Git ([IO.Path]::GetTempPath()) init -q -b main $source | Out-Null
        Invoke-Git $source remote add origin "https://dev.azure.com/org/project/_git/$Repository" | Out-Null
        Save-Commit $source 'Merged PR 42: nuovo endpoint delle conversazioni'
        return $source
    }

    function Invoke-PullRequest($Checkout, [hashtable]$Environment = @{}) {
        $variables = @{
            PULL_REQUEST_PATHS = $Generated; PULL_REQUEST_BRANCH = $Branch; PULL_REQUEST_TARGET = 'main'
            PULL_REQUEST_TITLE = 'docs: C4 model of Aidea.Dxp.AI'; PULL_REQUEST_DESCRIPTION = 'Parte rigenerata.'
            PULL_REQUEST_ORIGIN_DIRECTORY = ''; PULL_REQUEST_MERGE_STRATEGY = ''
            SYSTEM_COLLECTIONURI = "$StubEndpoint/org/"; SYSTEM_TEAMPROJECT = 'Aidea Dxp'; SYSTEM_ACCESSTOKEN = ''
            BUILD_REQUESTEDFOR = ''; BUILD_REQUESTEDFOREMAIL = ''
        }
        $Environment.Keys | ForEach-Object { $variables[$_] = $Environment[$_] }
        $previous = @{}
        foreach ($name in $variables.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $variables[$name]) }
        try {
            Push-Location $Checkout.Clone
            $output = & pwsh -NoProfile -File $Script 2>&1 | Out-String
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
        finally {
            Pop-Location
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
    }

    function Get-OriginFile($Checkout, [string]$Ref, [string]$Path) {
        $content = git -C $Checkout.Origin show "${Ref}:$Path" 2>$null
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $null }
        return $content -join "`n"
    }

    function Test-OriginBranch($Checkout) {
        return [bool]"$(git -C $Checkout.Origin branch --list $Branch)".Trim()
    }

    function Get-BranchMessages($Checkout) {
        return @(git -C $Checkout.Origin log --format=%s "refs/heads/$Branch")
    }
}

AfterAll {
    New-Item -ItemType File -Path (Join-Path $StubState 'stop') -Force | Out-Null
    $Stub | Wait-Job -Timeout 10 | Out-Null
    $Stub | Remove-Job -Force
    Remove-Item -Recurse -Force $StubState -ErrorAction SilentlyContinue
    $Workspaces | ForEach-Object { Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue }
}

Describe 'Publish-PullRequest' {
    Context 'con una parte cambiata e nessun ramo' {
        BeforeAll {
            Reset-Stub
            $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'vecchia'; 'README.md' = 'leggimi' }
            Write-Files $checkout.Clone @{ "$Generated/aidea.dxp.ai.dsl" = 'nuova'; 'README.md' = 'modificato a parte' }
            $origin = New-OriginRepository 'Aidea.Dxp.AI'
            $result = Invoke-PullRequest $checkout @{ PULL_REQUEST_ORIGIN_DIRECTORY = $origin }
            $requests = Get-StubRequests
            $created = $requests | Where-Object method -EQ 'POST'
            $completion = $requests | Where-Object method -EQ 'PATCH'
        }

        It 'termina senza errori' { $result.ExitCode | Should -Be 0 -Because $result.Output }

        It 'porta la parte nuova sul ramo' {
            Get-OriginFile $checkout "refs/heads/$Branch" "$Generated/aidea.dxp.ai.dsl" | Should -Be 'nuova'
        }

        It 'non porta sul ramo i file fuori dalle cartelle indicate' {
            Get-OriginFile $checkout "refs/heads/$Branch" 'README.md' | Should -Be 'leggimi'
        }

        It 'usa il titolo come messaggio del commit' {
            (Get-BranchMessages $checkout)[0] | Should -Be 'docs: C4 model of Aidea.Dxp.AI'
        }

        It 'chiama l''API del repository di origin nel progetto della pipeline' {
            $created.url | Should -Match '^/org/Aidea%20Dxp/_apis/git/repositories/Docs\.Repo/pullrequests\?api-version='
        }

        It 'apre la PR dal ramo verso la destinazione' {
            $created.body.sourceRefName | Should -Be "refs/heads/$Branch"
            $created.body.targetRefName | Should -Be 'refs/heads/main'
        }

        It 'da'' alla PR il titolo indicato' { $created.body.title | Should -Be 'docs: C4 model of Aidea.Dxp.AI' }

        It 'cita nella descrizione l''ultimo commit del repository d''origine' {
            $created.body.description | Should -Match '^Parte rigenerata\.\n\nOrigine: Merged PR 42: nuovo endpoint delle conversazioni \(Aidea\.Dxp\.AI@[0-9a-f]{8}\)$'
        }

        It 'attiva il completamento automatico a nome dell''identita'' che ha creato la PR' {
            $completion.url | Should -Match '/pullrequests/101\?'
            $completion.body.autoCompleteSetBy.id | Should -Be 'build-identity'
        }

        It 'completa con la strategia di default e cancella il ramo' {
            $completion.body.completionOptions.mergeStrategy | Should -Be 'noFastForward'
            $completion.body.completionOptions.deleteSourceBranch | Should -BeTrue
        }
    }

    Context 'con la parte uguale a quella della destinazione' {
        BeforeAll {
            Reset-Stub
            $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'uguale' }
            $result = Invoke-PullRequest $checkout
        }

        It 'termina senza errori' { $result.ExitCode | Should -Be 0 -Because $result.Output }

        It 'non crea il ramo' { Test-OriginBranch $checkout | Should -BeFalse }

        It 'non apre la PR' { @(Get-StubRequests | Where-Object method -EQ 'POST').Count | Should -Be 0 }
    }

    Context 'con un ramo rimasto senza differenze e senza PR' {
        BeforeAll {
            Reset-Stub
            $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'uguale' }
            Push-Branch $checkout @{ 'altro.md' = 'avanzo' } 'avanzo di una pipeline precedente'
            $result = Invoke-PullRequest $checkout
        }

        It 'termina senza errori' { $result.ExitCode | Should -Be 0 -Because $result.Output }

        It 'cancella il ramo' { Test-OriginBranch $checkout | Should -BeFalse }
    }

    Context 'con il ramo che porta gia'' il testo salvato da un passo precedente' {
        BeforeAll {
            Reset-Stub
            $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'vecchia' }
            Push-Branch $checkout @{ "$Generated/aidea.dxp.ai.text.json" = '{"testo":1}' } 'docs: text of api in the C4 model of Aidea.Dxp.AI'
            Write-Files $checkout.Clone @{ "$Generated/aidea.dxp.ai.dsl" = 'nuova'; "$Generated/aidea.dxp.ai.text.json" = '{"testo":1}' }
            $result = Invoke-PullRequest $checkout
        }

        It 'termina senza errori' { $result.ExitCode | Should -Be 0 -Because $result.Output }

        It 'aggiunge il commit sopra quelli del ramo' {
            Get-BranchMessages $checkout | Select-Object -First 2 | Should -Be @('docs: C4 model of Aidea.Dxp.AI', 'docs: text of api in the C4 model of Aidea.Dxp.AI')
        }

        It 'porta sul ramo sia il testo sia la parte' {
            Get-OriginFile $checkout "refs/heads/$Branch" "$Generated/aidea.dxp.ai.text.json" | Should -Be '{"testo":1}'
            Get-OriginFile $checkout "refs/heads/$Branch" "$Generated/aidea.dxp.ai.dsl" | Should -Be 'nuova'
        }
    }

    Context 'con un file che la pipeline non scrive piu''' {
        BeforeAll {
            Reset-Stub
            $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'parte'; "$Generated/vecchio.dsl" = 'da togliere' }
            Remove-Item (Join-Path $checkout.Clone "$Generated/vecchio.dsl")
            $result = Invoke-PullRequest $checkout
        }

        It 'termina senza errori' { $result.ExitCode | Should -Be 0 -Because $result.Output }

        It 'toglie il file dal ramo' { Get-OriginFile $checkout "refs/heads/$Branch" "$Generated/vecchio.dsl" | Should -BeNullOrEmpty }

        It 'apre la PR' { @(Get-StubRequests | Where-Object method -EQ 'POST').Count | Should -Be 1 }
    }

    Context 'con una PR gia'' attiva sul ramo' {
        BeforeAll {
            Reset-Stub -Active @(@{ pullRequestId = 77; createdBy = @{ id = 'build-identity' } })
            $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'vecchia' }
            Write-Files $checkout.Clone @{ "$Generated/aidea.dxp.ai.dsl" = 'nuova' }
            $result = Invoke-PullRequest $checkout
            $requests = Get-StubRequests
        }

        It 'termina senza errori' { $result.ExitCode | Should -Be 0 -Because $result.Output }

        It 'cerca la PR attiva dal ramo verso la destinazione' {
            ($requests | Where-Object method -EQ 'GET' | Select-Object -First 1).url | Should -Match ([regex]::Escape("searchCriteria.sourceRefName=refs/heads/$Branch&searchCriteria.targetRefName=refs/heads/main&searchCriteria.status=active"))
        }

        It 'non apre una seconda PR' { @($requests | Where-Object method -EQ 'POST').Count | Should -Be 0 }

        It 'aggiorna la descrizione della PR attiva' {
            $update = $requests | Where-Object method -EQ 'PATCH'
            $update.url | Should -Match '/pullrequests/77\?'
            $update.body.description | Should -Be 'Parte rigenerata.'
        }
    }

    It 'tronca la descrizione al limite di Azure Repos' {
        Reset-Stub
        $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'vecchia' }
        Write-Files $checkout.Clone @{ "$Generated/aidea.dxp.ai.dsl" = 'nuova' }
        Invoke-PullRequest $checkout @{ PULL_REQUEST_DESCRIPTION = 'x' * 5000 } | Out-Null
        (Get-StubRequests | Where-Object method -EQ 'POST').body.description.Length | Should -Be 4000
    }

    It 'usa la strategia di completamento indicata' {
        Reset-Stub
        $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'vecchia' }
        Write-Files $checkout.Clone @{ "$Generated/aidea.dxp.ai.dsl" = 'nuova' }
        Invoke-PullRequest $checkout @{ PULL_REQUEST_MERGE_STRATEGY = 'squash' } | Out-Null
        (Get-StubRequests | Where-Object method -EQ 'PATCH').body.completionOptions.mergeStrategy | Should -Be 'squash'
    }

    Context 'con l''API che risponde con un errore' {
        BeforeAll {
            Reset-Stub -Status 500
            $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'vecchia' }
            Write-Files $checkout.Clone @{ "$Generated/aidea.dxp.ai.dsl" = 'nuova' }
            $result = Invoke-PullRequest $checkout
        }

        It 'fallisce' { $result.ExitCode | Should -Be 1 }

        It 'segnala l''errore della PR' { $result.Output | Should -Match '##vso\[task\.logissue type=error\]pull request: ' }
    }

    It 'fallisce senza il ramo' {
        Reset-Stub
        $checkout = New-Checkout @{ "$Generated/aidea.dxp.ai.dsl" = 'vecchia' }
        $result = Invoke-PullRequest $checkout @{ PULL_REQUEST_BRANCH = '' }
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'PULL_REQUEST_PATHS, PULL_REQUEST_BRANCH e PULL_REQUEST_TITLE sono obbligatori'
    }
}
