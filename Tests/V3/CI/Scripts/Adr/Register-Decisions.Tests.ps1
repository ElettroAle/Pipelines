#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Adr/Register-Decisions.ps1 e DecisionRegistration.ps1

.DESCRIPTION
    Ogni test costruisce il repository delle decisioni, con un bare repo come origin e il punto di
    partenza registrato su 'main', e una board locale (Fixtures/AzureDevOpsStub.ps1) con le PR dei
    repository sorgente e i loro Task. La registrazione gira nel checkout come in pipeline.
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/AzureDevOpsStub.ps1"
    $script:EntryScript = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Adr/Register-Decisions.ps1"
    . (Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Adr/DecisionRegistration.ps1")
    $script:Stub = Start-AzureDevOpsStub
    $script:Project = 'Progetto'
    $script:Baseline = '2026-01-01T00:00:00Z'

    function Invoke-Git([string]$Directory) {
        $output = git -C $Directory -c user.name=t -c user.email=t@t -c core.autocrlf=false @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
        return $output
    }

    function New-Decision([string]$Title, [string]$Front = '') {
        return "---`nstatus: accepted`ndate: 2025-12-01$Front`n---`n`n# $Title`n`n## Contesto e problema`n`nServe una scelta.`n`n## Opzioni considerate`n`n- Prima`n- Seconda`n`n## Esito della decisione`n`nSi sceglie la prima.`n"
    }

    function New-TaskAdr([string]$Title, [string]$Extra = '') {
        return "# $Title`n`n## Contesto e problema`n`nIl problema del lavoro.`n`n## Opzioni considerate`n`n- Una via`n- Un'altra via`n`n## Esito della decisione`n`nSi sceglie una via.$Extra"
    }

    function New-DecisionsRepository([hashtable]$Files = @{}, [switch]$WithoutBaseline) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-register-$(New-Guid)"
        $origin = "$root/origin.git"
        $work = "$root/work"
        git init -q --bare -b main $origin
        git init -q -b main $work
        New-Item -ItemType Directory -Force "$work/docs/decisions" | Out-Null
        $corpus = @{
            'docs/decisions/0001-esempio.md'          = New-Decision 'Esempio'
            'docs/decisions/0003-regole-di-rete.md'   = New-Decision 'Regole di rete'
            'docs/decisions/README.md'                = "# Decisioni`n"
        }
        foreach ($name in $Files.Keys) { $corpus[$name] = $Files[$name] }
        if (-not $WithoutBaseline) { $corpus['.decisions-baseline'] = "$Baseline`n" }
        foreach ($name in $corpus.Keys) { [IO.File]::WriteAllText("$work/$name", $corpus[$name]) }
        Invoke-Git $work add -A | Out-Null
        Invoke-Git $work commit -q -m 'corpus' | Out-Null
        Invoke-Git $work remote add origin $origin | Out-Null
        Invoke-Git $work push -q origin main | Out-Null
        Invoke-Git $work fetch -q origin | Out-Null
        return @{ Root = $root; Work = $work; Origin = $origin }
    }

    function Set-Board([object[]]$Integrations = @(), [hashtable]$WorkItems = @{}) {
        $routes = New-AzureDevOpsRoutes $Project $Integrations $WorkItems @('Negozio.Api', 'Negozio.Infra')
        Set-AzureDevOpsRoutes $Stub $routes
        return $routes
    }

    function Set-RegistrationEnvironment([string]$Sources = 'Negozio.Api:dev;Negozio.Infra') {
        $env:ADR_REGISTER_SOURCES = $Sources
        $env:SYSTEM_COLLECTIONURI = "$($Stub.Endpoint)/"
        $env:SYSTEM_TEAMPROJECT = $Project
        $env:SYSTEM_ACCESSTOKEN = ''
        $env:ADR_REGISTER_DESCRIPTION_FILE = Join-Path $script:Repository.Root 'description.md'
    }

    function Invoke-Registration {
        Push-Location $script:Repository.Work
        try { return Invoke-DecisionRegistration (Get-RegistrationSettings) }
        finally { Pop-Location }
    }

    function Get-NewDecisions {
        return @(Get-ChildItem "$($script:Repository.Work)/docs/decisions" -Filter '*.md' | Where-Object Name -NotMatch '^(0001|0003)-|README' | Sort-Object Name)
    }

    function Get-Text([string]$Relative) {
        return [IO.File]::ReadAllText((Join-Path $script:Repository.Work $Relative))
    }

    function Get-BugRequests {
        return @(Get-AzureDevOpsRequests $Stub | Where-Object { $_.Method -eq 'POST' })
    }

    function Direct([int]$Id, [int[]]$WorkItems, [string]$Closed = '2026-02-01T10:00:00Z') {
        return @{ Repository = 'Negozio.Infra'; Id = $Id; Closed = $Closed; WorkItems = $WorkItems }
    }

    function Promotion([int]$Id, [object[]]$Merged, [string]$Closed = '2026-02-01T10:00:00Z') {
        return @{ Repository = 'Negozio.Api'; Id = $Id; Closed = $Closed; DevelopmentBranch = 'dev'; Merged = $Merged }
    }
}

AfterAll {
    Stop-AzureDevOpsStub $Stub
    'ADR_REGISTER_SOURCES', 'SYSTEM_COLLECTIONURI', 'SYSTEM_TEAMPROJECT', 'SYSTEM_ACCESSTOKEN', 'ADR_REGISTER_DESCRIPTION_FILE' | ForEach-Object { Remove-Item "env:$_" -ErrorAction SilentlyContinue }
}

Describe 'Register-Decisions' {
    AfterEach {
        if ($script:Repository) { Remove-Item -Recurse -Force $script:Repository.Root -ErrorAction SilentlyContinue }
    }

    It 'senza punto di partenza registra l''istante del server e nessuna decisione' {
        $script:Repository = New-DecisionsRepository -WithoutBaseline
        Set-RegistrationEnvironment
        Set-Board @(Direct 1300 @(1600)) @{ 1600 = @{ Description = New-TaskAdr 'Scelta' } } | Out-Null

        $outcome = Invoke-Registration

        $outcome.Status | Should -Be 'baseline'
        $outcome.Publish | Should -BeTrue
        (Get-Text '.decisions-baseline').Trim() | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        Get-NewDecisions | Should -BeNullOrEmpty
    }

    It 'trascrive l''ADR di un Task della PR integrata nel ramo principale, con Task, PR e data nel frontmatter' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        $adr = New-TaskAdr 'Code durevoli per gli eventi'
        Set-Board @(Direct 1300 @(1600)) @{ 1600 = @{ Description = $adr } } | Out-Null

        $outcome = Invoke-Registration

        $outcome.Status | Should -Be 'registered'
        $decision = Get-NewDecisions
        $decision.Name | Should -Be '0004-code-durevoli-per-gli-eventi.md'
        $content = Get-Text 'docs/decisions/0004-code-durevoli-per-gli-eventi.md'
        $content | Should -Be "---`nstatus: accepted`nversion: 1`ndate: 2026-02-01`ntask: 1600`npull-request: 1300`n---`n`n$adr`n"
        (Get-Text '.decisions-baseline').Trim() | Should -Not -Be $Baseline
        [IO.File]::ReadAllText((Join-Path $script:Repository.Root 'description.md')) | Should -Match '0004-code-durevoli-per-gli-eventi: Task 1600, PR 1300 di Negozio.Infra'
    }

    It 'prende i Task dalle PR verso il ramo di sviluppo contenute nella promozione, non da quelle verso altri rami' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        Set-Board @(Promotion 1400 @(@{ Id = 1300; WorkItems = @(1600) }, @{ Id = 1350; WorkItems = @(1650); Target = 'staging' })) @{
            1600 = @{ Description = New-TaskAdr 'Scelta promossa' }
            1650 = @{ Description = New-TaskAdr 'Promozione intermedia' }
        } | Out-Null

        Invoke-Registration | Out-Null

        @(Get-NewDecisions).Name | Should -Be @('0004-scelta-promossa.md')
        Get-Text 'docs/decisions/0004-scelta-promossa.md' | Should -Match "(?m)^task: 1600`n^pull-request: 1300`n^promotion: 1400$"
    }

    It 'non registra nulla e lascia il punto di partenza senza integrazioni nella finestra' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        Set-Board @(Direct 1300 @(1600) '2025-12-31T23:59:59Z') @{ 1600 = @{ Description = New-TaskAdr 'Vecchia' } } | Out-Null

        $outcome = Invoke-Registration

        $outcome.Status | Should -Be 'unchanged'
        $outcome.Publish | Should -BeFalse
        Get-NewDecisions | Should -BeNullOrEmpty
        (Get-Text '.decisions-baseline').Trim() | Should -Be $Baseline
    }

    It 'registra una decisione per ogni Task di una PR, con numeri diversi, e ignora gli altri tipi di work item' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        Set-Board @(Direct 1302 @(1612, 1602, 1700)) @{
            1602 = @{ Description = New-TaskAdr 'Prima scelta' }
            1612 = @{ Description = New-TaskAdr 'Seconda scelta' }
            1700 = @{ Type = 'Bug'; Description = 'non una decisione' }
        } | Out-Null

        Invoke-Registration | Out-Null

        @(Get-NewDecisions).Name | Should -Be @('0004-prima-scelta.md', '0005-seconda-scelta.md')
    }

    It 'non registra di nuovo il Task che ha gia'' una decisione nel corpus' {
        $script:Repository = New-DecisionsRepository @{ 'docs/decisions/0004-gia-registrata.md' = New-Decision 'Gia registrata' "`ntask: 1600`npull-request: 1300" }
        Set-RegistrationEnvironment
        Set-Board @((Direct 1310 @(1600)), (Direct 1311 @(1600) '2026-02-02T10:00:00Z')) @{ 1600 = @{ Description = New-TaskAdr 'Gia registrata' } } | Out-Null

        $outcome = Invoke-Registration

        $outcome.Status | Should -Be 'unchanged'
        @(Get-NewDecisions).Name | Should -Be @('0004-gia-registrata.md')
    }

    It 'registra una sola volta il Task che arriva con due PR nella stessa finestra' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        Set-Board @((Direct 1300 @(1600)), (Direct 1310 @(1600) '2026-02-02T10:00:00Z')) @{ 1600 = @{ Description = New-TaskAdr 'Una volta' } } | Out-Null

        Invoke-Registration | Out-Null

        @(Get-NewDecisions).Name | Should -Be @('0004-una-volta.md')
        Get-Text 'docs/decisions/0004-una-volta.md' | Should -Match '(?m)^pull-request: 1300$'
    }

    It 'sostituisce in modo reciproco la decisione che l''ADR nomina con l''etichetta della lingua' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        Set-Board @(Direct 1305 @(1605)) @{ 1605 = @{ Description = New-TaskAdr 'Regole per servizio' "`n`n## Ulteriori informazioni`n`nSostituisce [0003-regole-di-rete](0003-regole-di-rete.md)." } } | Out-Null
        $before = Get-Text 'docs/decisions/0003-regole-di-rete.md'

        Invoke-Registration | Out-Null

        Get-Text 'docs/decisions/0004-regole-per-servizio.md' | Should -Match '(?m)^supersedes: 0003-regole-di-rete$'
        $replaced = Get-Text 'docs/decisions/0003-regole-di-rete.md'
        $replaced | Should -Match "(?m)^status: superseded`n^superseded-by: 0004-regole-per-servizio$"
        ($replaced -replace "superseded`nsuperseded-by: 0004-regole-per-servizio", 'accepted') | Should -Be $before
    }

    It 'conserva gli a capo CRLF della decisione sostituita' {
        $content = "---`r`nstatus: accepted`r`nsuperseded-by: vecchio`r`n---`r`n`r`n# Titolo`r`n"
        Set-Superseded $content '0009-nuova' | Should -Be "---`r`nstatus: superseded`r`nsuperseded-by: 0009-nuova`r`n---`r`n`r`n# Titolo`r`n"
        Set-Superseded "---`ndate: 2026-01-01`n---`n" '0009-nuova' | Should -Be "---`ndate: 2026-01-01`nstatus: superseded`nsuperseded-by: 0009-nuova`n---`n"
    }

    It 'apre un work item <motivo> e lascia il corpus com''era' -ForEach @(
        @{ motivo = 'decisione tecnica mancante'; Description = ''; Format = 'markdown' }
        @{ motivo = 'decisione non in Markdown'; Description = '<h2>Contesto e problema</h2>'; Format = 'html' }
        @{ motivo = 'sostituzione non reciproca'; Description = "# Sostituisce nulla`n`n## Contesto e problema`n`nTesto.`n`n## Opzioni considerate`n`n- Una`n`n## Esito della decisione`n`nUna.`n`nSostituisce 0042-inesistente."; Format = 'markdown' }
        @{ motivo = "sezione mancante 'Esito della decisione'"; Description = "# Senza esito`n`n## Contesto e problema`n`nTesto.`n`n## Opzioni considerate`n`n- Una"; Format = 'markdown' }
    ) {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        Set-Board @(Direct 1306 @(1606)) @{ 1606 = @{ Description = $Description; Format = $Format } } | Out-Null

        $outcome = Invoke-Registration

        $outcome.Status | Should -Be 'rejected'
        $outcome.WorkItems | Should -Be @(9001)
        Get-NewDecisions | Should -BeNullOrEmpty
        Invoke-Git $script:Repository.Work status --porcelain -- docs/decisions | Should -BeNullOrEmpty
        $bug = @(Get-BugRequests)
        $bug.Count | Should -Be 1
        $bug[0].Path | Should -Be "/$Project/_apis/wit/workitems/`$Bug"
        $operations = $bug[0].Body | ConvertFrom-Json
        ($operations | Where-Object path -EQ '/fields/System.Title').value | Should -BeLike "Decisione del Task 1606 non registrata: *$motivo*"
        ($operations | Where-Object path -EQ '/fields/Microsoft.VSTS.TCM.ReproSteps').value | Should -Match 'PR 1306 di Negozio.Infra'
        ($operations | Where-Object path -EQ '/relations/-').value.url | Should -Be "$($Stub.Endpoint)/_apis/wit/workItems/1606"
        (Get-Text '.decisions-baseline').Trim() | Should -Not -Be $Baseline
    }

    It 'registra nonostante i rilievi che il corpus aveva gia''' {
        $script:Repository = New-DecisionsRepository @{ 'docs/decisions/0002-senza-esito.md' = "---`nstatus: accepted`n---`n`n# Senza esito`n" }
        Set-RegistrationEnvironment
        Set-Board @(Direct 1300 @(1600)) @{ 1600 = @{ Description = New-TaskAdr 'Nuova' } } | Out-Null

        $outcome = Invoke-Registration

        $outcome.Status | Should -Be 'registered'
        @(Get-NewDecisions | Where-Object Name -Match '^0004').Name | Should -Be @('0004-nuova.md')
    }

    It 'fallisce senza cambiare nulla se la board non risponde, e la run successiva recupera' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        $routes = Set-Board @(Direct 1307 @(1607)) @{ 1607 = @{ Description = New-TaskAdr 'Recuperata' } }
        $routes.Remove("GET /$Project/_apis/wit/workitems/1607")
        Set-AzureDevOpsRoutes $Stub $routes

        { Invoke-Registration } | Should -Throw
        Get-NewDecisions | Should -BeNullOrEmpty
        (Get-Text '.decisions-baseline').Trim() | Should -Be $Baseline

        Set-Board @(Direct 1307 @(1607)) @{ 1607 = @{ Description = New-TaskAdr 'Recuperata' } } | Out-Null
        Invoke-Registration | Out-Null
        @(Get-NewDecisions).Name | Should -Be @('0004-recuperata.md')
    }

    It 'unisce la registrazione ancora aperta: numeri diversi, Task e work item non ripetuti' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        $work = $script:Repository.Work
        Set-Board @((Direct 1303 @(1603)), (Direct 1306 @(1606))) @{ 1603 = @{ Description = New-TaskAdr 'Prima integrazione' }; 1606 = @{ Description = '' } } | Out-Null
        Invoke-Registration | Out-Null
        Invoke-Git $work checkout -q -b decisions/register | Out-Null
        Invoke-Git $work add -A | Out-Null
        Invoke-Git $work commit -q -m 'registrazione aperta' | Out-Null
        Invoke-Git $work push -q origin decisions/register | Out-Null
        Invoke-Git $work checkout -q main | Out-Null

        Start-Sleep -Milliseconds 1100
        $secondClosed = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-Board @((Direct 1303 @(1603)), (Direct 1306 @(1606)), (Direct 1304 @(1604) $secondClosed)) @{
            1603 = @{ Description = New-TaskAdr 'Prima integrazione' }
            1604 = @{ Description = New-TaskAdr 'Seconda integrazione' }
            1606 = @{ Description = '' }
        } | Out-Null
        Get-NewDecisions | Should -BeNullOrEmpty

        Invoke-Registration | Out-Null

        @(Get-NewDecisions).Name | Should -Be @('0004-prima-integrazione.md', '0005-seconda-integrazione.md')
        Get-BugRequests | Should -BeNullOrEmpty
    }

    It 'ricava il nome dal titolo del Task se l''ADR non ha un titolo, senza accenti' {
        ConvertTo-Slug 'Perché l''identità è unica' | Should -Be 'perche-l-identita-e-unica'
        ConvertTo-Slug '!!!' | Should -Be 'decisione'
        (ConvertTo-Slug ('parola ' * 30)).Length | Should -BeLessOrEqual 60
        Get-DecisionTitle ([pscustomobject]@{ Title = 'Titolo del Task'; Description = "## Contesto e problema`n`nTesto." }) | Should -Be 'Titolo del Task'
        Get-DecisionTitle ([pscustomobject]@{ Title = 'Titolo del Task'; Description = "# Il **titolo** dell'ADR`n" }) | Should -Be "Il titolo dell'ADR"
    }

    It 'legge le sorgenti con e senza ramo di sviluppo e rifiuta una configurazione senza sorgenti' {
        $source = ConvertTo-Source ' Negozio.Api : dev '
        $source.Name | Should -Be 'Negozio.Api'
        $source.DevelopmentBranch | Should -Be 'dev'
        (ConvertTo-Source 'Negozio.Infra').DevelopmentBranch | Should -Be ''
        $env:ADR_REGISTER_SOURCES = '$(sources)'
        { Get-RegistrationSettings } | Should -Throw '*ADR_REGISTER_SOURCES*'
    }

    It 'come passo della pipeline pubblica la variabile della PR e chiude con un avviso per un work item' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment
        Set-Board @((Direct 1300 @(1600)), (Direct 1306 @(1606))) @{ 1600 = @{ Description = New-TaskAdr 'Entra' }; 1606 = @{ Description = '' } } | Out-Null

        Push-Location $script:Repository.Work
        try { $output = & pwsh -NoProfile -File $EntryScript 2>&1 | ForEach-Object { "$_" } }
        finally { Pop-Location }

        $LASTEXITCODE | Should -Be 0
        $output | Should -Contain '##vso[task.setvariable variable=decisionRegistrationChanged]True'
        ($output -join "`n") | Should -Match 'type=warning\]Decisioni non registrate, work item 9001'
        @(Get-NewDecisions).Name | Should -Be @('0004-entra.md')
    }

    It 'come passo della pipeline fallisce con una configurazione sbagliata' {
        $script:Repository = New-DecisionsRepository
        Set-RegistrationEnvironment ''

        Push-Location $script:Repository.Work
        try { $output = & pwsh -NoProfile -File $EntryScript 2>&1 | ForEach-Object { "$_" } }
        finally { Pop-Location }

        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'type=error\]registrazione delle decisioni'
    }
}
