#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Documentation/DocumentationUpdate.ps1 e Update-Documentation.ps1

.DESCRIPTION
    Ogni prova costruisce un repository git temporaneo con il documento valido delle prove della
    documentazione, un punto di partenza e il cambiamento da documentare, con un bare repo come origin.
    Il modello linguistico e il servizio dei work item sono endpoint locali che rispondono con le stesure
    e i work item registrati e conservano le richieste. Le funzioni girano nel processo delle prove;
    Update-Documentation.ps1 gira come in pipeline, in un processo a parte. Le verifiche che giudicano le
    stesure sono quelle della documentazione e del corpus degli ADR.
#>

BeforeAll {
    . "$PSScriptRoot/../Common/Fixtures/Documentation/DocumentationFixture.ps1"
    . "$PSScriptRoot/../LanguageModel/Fixtures/ModelEndpointStub.ps1"
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Documentation/DocumentationUpdate.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Documentation/Update-Documentation.ps1"

    $script:Model = Start-ModelEndpoint
    $script:Boards = Start-ModelEndpoint
    $script:Verifications = @('Documentation/Test-Documentation.ps1', 'Adr/Test-AdrCorpus.ps1')
    $script:Section = 'docs/architecture/04_solution_strategy.md'
    $script:DecisionPath = 'docs/decisions/0002-coda-dei-lavori.md'
    $script:ClosedEndpoint = & {
        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
        "http://127.0.0.1:$port"
    }

    function Invoke-Git {
        $output = git -c user.name=t -c user.email=t@t -c core.autocrlf=false @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
        return $output
    }

    function New-DecisionText([string]$Outcome = 'Si usa una coda.', [string]$Structure = 'La classe `Coda` riceve i lavori.', [string]$Extra = '') {
        return "---`nstatus: accepted`ndate: 2026-10-02`ngoverns: Esempio.Coda.*`n---`n`n# Coda dei lavori`n`n## Contesto e problema`n`nI lavori lunghi bloccano le richieste.`n`n## Opzioni considerate`n`n- Coda`n- Chiamata diretta`n`n## Esito della decisione`n`n$Outcome`n`n## Struttura nel codice`n`n$Structure`n$Extra"
    }

    function Write-Files([System.Collections.IDictionary]$Files, [string]$Root) {
        foreach ($path in $Files.Keys) {
            $file = Join-Path $Root $path
            New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
            [IO.File]::WriteAllText($file, ($Files[$path] -replace "`r`n", "`n"))
        }
    }

    function Push-Main([string]$Root) {
        Invoke-Git -C $Root push -q origin main | Out-Null
        Invoke-Git -C $Root fetch -q origin | Out-Null
    }

    # Documento valido, punto di partenza in un commit a parte e, se indicato, il cambiamento in un commit
    # con l'oggetto di una PR integrata.
    function New-UpdateRepository([System.Collections.IDictionary]$Change, [switch]$WithoutBaseline, [string]$Subject = 'Merged PR 77: coda dei lavori') {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-docs-update-$(New-Guid)"
        $bare = "$root-origin.git"
        Invoke-Git init -q --bare -b main $bare | Out-Null
        $docs = New-ValidDocs
        $docs[$DecisionPath] = New-DecisionText
        Write-Files $docs $root
        Invoke-Git -C $root init -q -b main | Out-Null
        Invoke-Git -C $root config core.autocrlf false | Out-Null
        Invoke-Git -C $root add -A | Out-Null
        Invoke-Git -C $root commit -q -m base | Out-Null
        Invoke-Git -C $root remote add origin $bare | Out-Null
        $base = "$(Invoke-Git -C $root rev-parse HEAD)".Trim()
        if (-not $WithoutBaseline) {
            [IO.File]::WriteAllText((Join-Path $root '.documentation-baseline'), "$base`n")
            Invoke-Git -C $root add -A | Out-Null
            Invoke-Git -C $root commit -q -m 'docs: documentation updated after the integration' | Out-Null
        }
        if ($Change) {
            Write-Files $Change $root
            Invoke-Git -C $root add -A | Out-Null
            Invoke-Git -C $root commit -q -m $Subject | Out-Null
        }
        Push-Main $root
        return @{ Root = $root; Bare = $bare; Base = $base; Head = "$(Invoke-Git -C $root rev-parse HEAD)".Trim() }
    }

    function Remove-UpdateRepository($Repository) {
        Remove-Item -Recurse -Force $Repository.Root, $Repository.Bare -ErrorAction SilentlyContinue
    }

    function Get-RepositoryFile($Repository, [string]$Path) {
        return [IO.File]::ReadAllText((Join-Path $Repository.Root $Path))
    }

    function Get-UncommittedChanges($Repository, [string]$Path) {
        return (Invoke-Git -C $Repository.Root status --porcelain -- $Path) -join "`n"
    }

    function New-Draft([object[]]$Documents, [string]$Summary = 'Spiegata la coda dei lavori.') {
        $content = @{ summary = $Summary; documents = @($Documents) } | ConvertTo-Json -Depth 10 -Compress
        return New-ModelResponse 200 @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }); usage = @{ prompt_tokens = 10; completion_tokens = 5 } }
    }

    function New-SectionDraft([string]$Path = $Section, [string]$Text) {
        return @{ path = $Path; text = $Text; note = '' }
    }

    function Get-SectionText([string]$Body) {
        return New-Section 'Strategia della soluzione' 'come è divisa la piattaforma?' $Body
    }

    function New-TestSettings([hashtable]$Overrides = @{}) {
        $settings = Get-UpdateSettings
        $settings.Endpoint = $Model.Endpoint
        $settings.Model = 'scrittore'
        $settings.AccessToken = 'token-di-prova'
        $settings.Verifications = $Verifications
        $settings.DescriptionFile = Join-Path ([IO.Path]::GetTempPath()) "pester-docs-update-description-$(New-Guid).md"
        foreach ($name in $Overrides.Keys) { $settings[$name] = $Overrides[$name] }
        return $settings
    }

    function Invoke-InRepository($Repository, [scriptblock]$Action) {
        $previous = @{ SYSTEM_COLLECTIONURI = $env:SYSTEM_COLLECTIONURI; SYSTEM_TEAMPROJECT = $env:SYSTEM_TEAMPROJECT; SYSTEM_ACCESSTOKEN = $env:SYSTEM_ACCESSTOKEN; TARGET_BRANCH = $env:TARGET_BRANCH }
        $env:SYSTEM_COLLECTIONURI = "$($Boards.Endpoint)/organizzazione/"
        $env:SYSTEM_TEAMPROJECT = 'Progetto di prova'
        $env:SYSTEM_ACCESSTOKEN = 'token-della-build'
        $env:TARGET_BRANCH = 'main'
        Push-Location $Repository.Root
        try { return & $Action }
        finally {
            Pop-Location
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
    }

    function Invoke-Update($Repository, [hashtable]$Overrides = @{}) {
        $settings = New-TestSettings $Overrides
        $outcome = Invoke-InRepository $Repository { Invoke-DocumentationUpdate $settings }
        $description = if (Test-Path $settings.DescriptionFile) { [IO.File]::ReadAllText($settings.DescriptionFile) } else { $null }
        Remove-Item $settings.DescriptionFile -ErrorAction SilentlyContinue
        return @{ Outcome = $outcome; Description = $description }
    }

    function Get-UserMessage($Request) {
        return ($Request.Body.messages | Where-Object role -EQ 'user').content
    }

    $script:NewStrategy = Get-SectionText "La piattaforma divide il lavoro fra applicazioni piccole. Ogni applicazione fa una cosa sola.`n`nI lavori lunghi passano da una coda, come dice la decisione [0002-coda-dei-lavori](../decisions/0002-coda-dei-lavori.md)."
    $script:QueueChange = [ordered]@{ $DecisionPath = New-DecisionText -Structure "La classe ``Coda`` riceve i lavori. La classe ``Turno`` li ordina." }
}

AfterAll {
    Stop-ModelEndpoint $Model
    Stop-ModelEndpoint $Boards
}

Describe 'Impostazioni dalle variabili della pipeline' {
    It 'Senza variabili valgono le cartelle e le verifiche di default' {
        $settings = Get-UpdateSettings
        $settings.DocsDirectory | Should -Be 'docs/architecture'
        $settings.DecisionsDirectory | Should -Be 'docs/decisions'
        $settings.ChangePaths | Should -Be @('docs/decisions', 'docs/architecture/c4/generated')
        $settings.BaselineFile | Should -Be '.documentation-baseline'
        $settings.Verifications | Should -Be $DefaultVerifications
        $settings.MaxDrafts | Should -Be 3
        $settings.WorkItemType | Should -Be 'Bug'
        $settings.ReasoningEffort | Should -Be 'high'
    }

    It 'Una variabile non definita arriva come macro e vale il default' {
        $previous = $env:DOCS_UPDATE_ORIGIN_DIRECTORY
        $env:DOCS_UPDATE_ORIGIN_DIRECTORY = '$(originDirectory)'
        try { (Get-UpdateSettings).OriginDirectory | Should -Be '' }
        finally { $env:DOCS_UPDATE_ORIGIN_DIRECTORY = $previous }
    }

    It 'Le liste arrivano separate da punto e virgola' {
        $previous = $env:DOCS_UPDATE_CHANGE_PATHS
        $env:DOCS_UPDATE_CHANGE_PATHS = ' adr ; modello ;'
        try { (Get-UpdateSettings).ChangePaths | Should -Be @('adr', 'modello') }
        finally { $env:DOCS_UPDATE_CHANGE_PATHS = $previous }
    }
}

Describe 'Versione nuova di una decisione' {
    It 'Una decisione senza versione passa alla 2 con la voce che nomina la PR' {
        $origin = @{ PullRequest = '77'; Repository = 'Sorgente'; Commit = 'abcd1234' }
        $result = Get-VersionedDecision (New-DecisionText) (New-DecisionText -Structure 'Le classi cambiano.') 'struttura nel codice' $origin
        $result | Should -Match '(?m)^version: 2$'
        $result | Should -Match '(?m)^## Versioni\n\n- 2: struttura nel codice \(PR 77 di Sorgente\)$'
    }

    It "Senza PR nell'origine la voce nomina il commit" {
        $origin = @{ PullRequest = $null; Repository = 'Sorgente'; Commit = 'abcd1234' }
        $result = Get-VersionedDecision (New-DecisionText) (New-DecisionText -Structure 'Le classi cambiano.') 'struttura' $origin
        $result | Should -Match '- 2: struttura \(commit abcd1234 di Sorgente\)'
    }

    It 'Una sezione delle versioni esistente riceve la voce dopo le altre' {
        $original = (New-DecisionText -Extra "`n## Versioni`n`n- 2: prima modifica`n") -replace 'date: 2026-10-02', "date: 2026-10-02`nversion: 2"
        $drafted = $original.Replace('riceve i lavori', 'riceve e conta i lavori')
        $result = Get-VersionedDecision $original $drafted 'conteggio' @{ PullRequest = '9'; Repository = 'R' }
        $result | Should -Match '(?m)^version: 3$'
        $result | Should -Match '- 2: prima modifica\n- 3: conteggio \(PR 9 di R\)'
    }

    It 'Una sezione delle versioni vuota riceve la voce dopo una riga vuota' {
        $original = New-DecisionText -Extra "`n## Versioni`n"
        $result = Get-VersionedDecision $original $original.Replace('riceve i lavori', 'ordina i lavori') 'ordine' @{ PullRequest = '9'; Repository = 'R' }
        $result | Should -Match '## Versioni\n\n- 2: ordine'
    }

    It 'Una sezione dopo le versioni resta dopo la voce nuova' {
        $original = New-DecisionText -Extra "`n## Versioni`n`n- 2: prima`n`n## Pattern di riferimento`n`nCoda.`n"
        $result = Get-VersionedDecision ($original -replace 'date: 2026-10-02', "date: 2026-10-02`nversion: 2") $original.Replace('riceve i lavori', 'ordina i lavori') 'ordine' @{ PullRequest = '9'; Repository = 'R' }
        $result | Should -Match '- 2: prima\n- 3: ordine \(PR 9 di R\)\n\n## Pattern di riferimento'
    }

    It "L'intestazione dei metadati resta quella del corpus anche se la stesura la cambia" {
        $drafted = (New-DecisionText -Structure 'Altro.') -replace 'status: accepted', 'status: proposed'
        $result = Get-VersionedDecision (New-DecisionText) $drafted 'nota' @{ PullRequest = '1'; Repository = 'R' }
        $result | Should -Match '(?m)^status: accepted$'
    }

    It 'Una decisione con il corpo invariato resta identica' {
        $original = New-DecisionText
        Get-VersionedDecision $original ($original -replace 'status: accepted', 'status: proposed') 'nota' @{} | Should -BeExactly $original
    }

    It 'Un testo senza metadati e una versione non numerica valgono la versione 1' {
        (Split-Decision '# Titolo').Body | Should -Be '# Titolo'
        Get-DecisionVersion @{ version = 'due' } | Should -Be 1
    }
}

Describe 'Rilievi delle verifiche' {
    It 'Solo le righe di errore sono rilievi' {
        Get-ErrorIssues @('##vso[task.logissue type=error]rimando rotto', '##vso[task.logissue type=warning]avviso', 'testo') | Should -Be @('rimando rotto')
    }

    It 'Una verifica che fallisce senza rilievi dice il suo codice di uscita' {
        $repository = New-UpdateRepository
        try {
            $issues = Invoke-InRepository $repository { Get-VerificationIssues (New-TestSettings @{ Verifications = @('Assente/Test-Assente.ps1') }) }
            $issues | Should -Match '^Assente/Test-Assente\.ps1 terminata con codice '
        }
        finally { Remove-UpdateRepository $repository }
    }
}

Describe 'Punto di partenza e cambiamento' {
    It 'Senza punto di partenza lo registra senza chiamare il modello' {
        $repository = New-UpdateRepository -WithoutBaseline
        Reset-ModelEndpoint $Model @()
        try {
            $result = Invoke-Update $repository
            $result.Outcome.Status | Should -Be 'baseline'
            $result.Outcome.Publish | Should -BeTrue
            (Get-RepositoryFile $repository '.documentation-baseline').Trim() | Should -Be $repository.Head
            Get-ModelEndpointRequests $Model | Should -BeNullOrEmpty
        }
        finally { Remove-UpdateRepository $repository }
    }

    It 'Senza commit nelle cartelle osservate nulla cambia e non si pubblica' {
        $repository = New-UpdateRepository -Change ([ordered]@{ 'README.md' = 'Altro.' })
        Reset-ModelEndpoint $Model @()
        try {
            $result = Invoke-Update $repository
            $result.Outcome.Status | Should -Be 'unchanged'
            $result.Outcome.Publish | Should -BeFalse
            Get-ModelEndpointRequests $Model | Should -BeNullOrEmpty
            Invoke-Git -C $repository.Root status --porcelain | Should -BeNullOrEmpty
        }
        finally { Remove-UpdateRepository $repository }
    }

    It "I commit di un aggiornamento precedente non sono un cambiamento" {
        $repository = New-UpdateRepository
        Reset-ModelEndpoint $Model @()
        try {
            [IO.File]::WriteAllText((Join-Path $repository.Root $DecisionPath), (New-DecisionText -Structure 'Versione nuova.'))
            [IO.File]::WriteAllText((Join-Path $repository.Root '.documentation-baseline'), "$($repository.Head)`n")
            Invoke-Git -C $repository.Root add -A | Out-Null
            Invoke-Git -C $repository.Root commit -q -m 'docs: documentation updated after the integration' | Out-Null
            (Invoke-Update $repository).Outcome.Status | Should -Be 'unchanged'
        }
        finally { Remove-UpdateRepository $repository }
    }

    It 'Un punto di partenza fuori dalla storia ferma il passo nominando il checkout' {
        $repository = New-UpdateRepository
        try {
            [IO.File]::WriteAllText((Join-Path $repository.Root '.documentation-baseline'), "$('0' * 40)`n")
            { Invoke-Update $repository } | Should -Throw '*fetchDepth: 0*'
        }
        finally { Remove-UpdateRepository $repository }
    }
}

Describe 'Guide che l aggiornamento puo riscrivere' {
    It 'Una cartella di guide porta ogni suo file Markdown, un file porta se stesso, un percorso inesistente nulla' {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-docs-update-guides-$(New-Guid)"
        Write-Files ([ordered]@{
                'docs/guides/home.md'                 = "# Home`n"
                'docs/guides/procedures/tenant.md'    = "# Tenant`n"
                'docs/guides/tutorials/primo.md'      = "# Primo`n"
                'docs/guides/tutorials/immagine.png'  = 'png'
                'README.md'                           = "# Leggimi`n"
            }) $root
        Push-Location $root
        try {
            $documents = Get-Documents @{ DocsDirectory = 'docs/architecture'; Guides = @('docs/guides', 'README.md', 'docs/nessuna') } @{ Files = @() } @()
        }
        finally {
            Pop-Location
            Remove-Item -Recurse -Force $root
        }

        @($documents.Keys) | Should -Be @('docs/guides/home.md', 'docs/guides/procedures/tenant.md', 'docs/guides/tutorials/primo.md', 'README.md')
        @($documents.Values | ForEach-Object IsDecision) | Should -Not -Contain $true
    }
}

Describe 'Stesura accettata' {
    BeforeAll {
        $repository = New-UpdateRepository -Change $QueueChange
        Reset-ModelEndpoint $Model @(New-Draft @((New-SectionDraft -Text $NewStrategy), @{ path = $DecisionPath; text = New-DecisionText -Structure "La classe ``Coda`` riceve i lavori. La classe ``Turno`` li ordina. La classe ``Conteggio`` li conta."; note = 'diagramma del codice con la classe Conteggio' }))
        $result = Invoke-Update $repository @{ StyleGuide = 'docs/architecture/01_introduction_and_goals.md' }
        $requests = Get-ModelEndpointRequests $Model
        $message = Get-UserMessage $requests[0]
    }

    AfterAll { Remove-UpdateRepository $repository }

    It 'La sezione riscritta entra nel documento' {
        $result.Outcome.Status | Should -Be 'updated'
        Get-RepositoryFile $repository $Section | Should -Match 'decisione \[0002-coda-dei-lavori\]'
    }

    It 'La decisione cambiata riceve la versione nuova con la voce che nomina la PR' {
        $decision = Get-RepositoryFile $repository $DecisionPath
        $decision | Should -Match '(?m)^version: 2$'
        $decision | Should -Match '- 2: diagramma del codice con la classe Conteggio \(PR 77 di '
    }

    It "Il punto di partenza avanza al commit della run e il passo chiede la PR" {
        (Get-RepositoryFile $repository '.documentation-baseline').Trim() | Should -Be $repository.Head
        $result.Outcome.Publish | Should -BeTrue
    }

    It 'La descrizione della PR riporta il riassunto e il cambiamento' {
        $result.Description | Should -Match 'Spiegata la coda dei lavori\.'
        $result.Description | Should -Match 'Cambiamento: Merged PR 77: coda dei lavori'
    }

    It 'Il modello riceve il cambiamento, l indice delle decisioni, i documenti e la guida di stile' {
        $message | Should -Match 'CAMBIAMENTO\nOrigine: Merged PR 77: coda dei lavori'
        $message | Should -Match '\+La classe `Coda` riceve i lavori\. La classe `Turno` li ordina\.'
        $message | Should -Match '- 0002-coda-dei-lavori \| accepted \| Coda dei lavori'
        $message | Should -Match "=== $([regex]::Escape($Section))"
        $message | Should -Match "=== $([regex]::Escape($DecisionPath))"
        ($requests[0].Body.messages | Where-Object role -EQ 'system').content | Should -Match 'GUIDA DI STILE:\n# Introduzione e obiettivi'
    }

    It 'Una sola stesura, nessun work item' {
        $requests.Count | Should -Be 1
        Get-ModelEndpointRequests $Boards | Should -BeNullOrEmpty
    }
}

Describe 'Stesure scartate' {
    It 'Una stesura che rompe un rimando torna al modello con il motivo e la seconda entra' {
        $repository = New-UpdateRepository -Change $QueueChange
        $broken = Get-SectionText 'La piattaforma usa una coda, come dice la [decisione](../decisions/0099-assente.md).'
        Reset-ModelEndpoint $Model @((New-Draft @(New-SectionDraft -Text $broken)), (New-Draft @(New-SectionDraft -Text $NewStrategy)))
        try {
            $result = Invoke-Update $repository
            $result.Outcome.Status | Should -Be 'updated'
            $requests = Get-ModelEndpointRequests $Model
            $requests.Count | Should -Be 2
            Get-UserMessage $requests[1] | Should -Match 'STESURA SCARTATA[\s\S]*Motivi dello scarto:\n- .*0099-assente'
            Get-RepositoryFile $repository $Section | Should -Be ($NewStrategy -replace "`r`n", "`n")
        }
        finally { Remove-UpdateRepository $repository }
    }

    It 'Un documento fuori dall aggiornamento e una decisione senza nota scartano la stesura' {
        $repository = New-UpdateRepository -Change $QueueChange
        $draft = New-Draft @(@{ path = 'docs/altro.md'; text = 'x'; note = '' }, @{ path = $DecisionPath; text = New-DecisionText -Structure 'Altro.'; note = ' ' })
        Reset-ModelEndpoint $Model @($draft)
        try {
            $result = Invoke-Update $repository @{ MaxDrafts = 1 }
            $result.Outcome.Status | Should -Be 'rejected'
            $result.Outcome.Message | Should -Match "documento fuori dall'aggiornamento: docs/altro\.md"
            $result.Outcome.Message | Should -Match "decisione $([regex]::Escape($DecisionPath)) cambiata senza la nota della versione"
        }
        finally { Remove-UpdateRepository $repository }
    }

    It "Una decisione accettata con l'esito cambiato si scarta per la verifica del corpus" {
        $repository = New-UpdateRepository -Change $QueueChange
        Reset-ModelEndpoint $Model @(New-Draft @(@{ path = $DecisionPath; text = New-DecisionText -Outcome 'Si chiama direttamente.'; note = 'esito' }))
        try {
            $result = Invoke-Update $repository @{ MaxDrafts = 1 }
            $result.Outcome.Status | Should -Be 'rejected'
            $result.Outcome.Message | Should -Match 'Esito della decisione'
            Get-UncommittedChanges $repository $DecisionPath | Should -BeNullOrEmpty
        }
        finally { Remove-UpdateRepository $repository }
    }

    Context 'Tutte le stesure scartate' {
        BeforeAll {
            $repository = New-UpdateRepository -Change $QueueChange
            $broken = Get-SectionText 'La piattaforma usa una coda, come dice la [decisione](../decisions/0099-assente.md).'
            Reset-ModelEndpoint $Model @(New-Draft @(New-SectionDraft -Text $broken))
            Reset-ModelEndpoint $Boards @(New-ModelResponse 200 @{ id = 4242 })
            $result = Invoke-Update $repository
            $workItems = Get-ModelEndpointRequests $Boards
        }

        AfterAll { Remove-UpdateRepository $repository }

        It 'Il modello scrive tre stesure, la prima e due correzioni' {
            (Get-ModelEndpointRequests $Model).Count | Should -Be 3
        }

        It 'I documenti restano quelli del ramo principale' {
            Get-UncommittedChanges $repository 'docs' | Should -BeNullOrEmpty
        }

        It 'Si apre un Bug che nomina il cambiamento e il motivo del rifiuto' {
            $workItems.Count | Should -Be 1
            $workItems[0].Path | Should -Be '/organizzazione/Progetto%20di%20prova/_apis/wit/workitems/$Bug'
            $workItems[0].Headers.authorization | Should -Be 'Bearer token-della-build'
            $fields = @($workItems[0].Body)
            ($fields | Where-Object path -EQ '/fields/System.Title').value | Should -Match '^Documentazione non aggiornata: Merged PR 77: coda dei lavori'
            ($fields | Where-Object path -EQ '/fields/Microsoft.VSTS.TCM.ReproSteps').value | Should -Match 'Merged PR 77[\s\S]*Motivi del rifiuto[\s\S]*0099-assente'
        }

        It 'Il punto di partenza avanza e il passo chiede la PR con il solo punto di partenza' {
            $result.Outcome.Status | Should -Be 'rejected'
            $result.Outcome.Publish | Should -BeTrue
            (Get-RepositoryFile $repository '.documentation-baseline').Trim() | Should -Be $repository.Head
            $result.Description | Should -Match 'work item 4242'
        }
    }

    It "Un rilievo che c'era gia' prima della stesura non la scarta" {
        $repository = New-UpdateRepository -Change ([ordered]@{ $DecisionPath = New-DecisionText -Structure 'Rimando alla [decisione](0099-assente.md).' })
        Reset-ModelEndpoint $Model @(New-Draft @(New-SectionDraft -Text $NewStrategy))
        try { (Invoke-Update $repository).Outcome.Status | Should -Be 'updated' }
        finally { Remove-UpdateRepository $repository }
    }
}

Describe 'Modello senza documenti da cambiare o non disponibile' {
    It 'Una risposta senza documenti lascia la documentazione com era e avanza il punto di partenza' {
        $repository = New-UpdateRepository -Change $QueueChange
        Reset-ModelEndpoint $Model @(New-Draft @() 'Nulla da cambiare.')
        try {
            $result = Invoke-Update $repository
            $result.Outcome.Status | Should -Be 'unchanged'
            $result.Outcome.Publish | Should -BeTrue
            Invoke-Git -C $repository.Root status --porcelain -- docs | Should -BeNullOrEmpty
            (Get-RepositoryFile $repository '.documentation-baseline').Trim() | Should -Be $repository.Head
            $result.Description | Should -Match 'Nessun documento da cambiare\. Nulla da cambiare\.'
        }
        finally { Remove-UpdateRepository $repository }
    }

    It 'Un modello non raggiungibile non cambia nulla e non apre work item' {
        $repository = New-UpdateRepository -Change $QueueChange
        Reset-ModelEndpoint $Boards @()
        try {
            $result = Invoke-Update $repository @{ Endpoint = $ClosedEndpoint }
            $result.Outcome.Status | Should -Be 'unavailable'
            $result.Outcome.Publish | Should -BeFalse
            Invoke-Git -C $repository.Root status --porcelain | Should -BeNullOrEmpty
            Get-ModelEndpointRequests $Boards | Should -BeNullOrEmpty
        }
        finally { Remove-UpdateRepository $repository }
    }
}

Describe "Origine dal repository che ha avviato la run" {
    It "La voce della versione nomina la PR del repository sorgente" {
        $source = Join-Path ([IO.Path]::GetTempPath()) "pester-docs-update-source-$(New-Guid)"
        Invoke-Git init -q -b main $source | Out-Null
        Invoke-Git -C $source remote add origin 'https://dev.example/organizzazione/_git/Sorgente.Applicazione' | Out-Null
        Invoke-Git -C $source commit -q --allow-empty -m 'Merged PR 512: classe nuova' | Out-Null
        $repository = New-UpdateRepository -Change $QueueChange
        Reset-ModelEndpoint $Model @(New-Draft @(@{ path = $DecisionPath; text = New-DecisionText -Structure 'Classi nuove.'; note = 'classi' }))
        try {
            (Invoke-Update $repository @{ OriginDirectory = $source }).Outcome.Status | Should -Be 'updated'
            Get-RepositoryFile $repository $DecisionPath | Should -Match '- 2: classi \(PR 512 di Sorgente\.Applicazione\)'
        }
        finally {
            Remove-UpdateRepository $repository
            Remove-Item -Recurse -Force $source -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Update-Documentation.ps1 come in pipeline' {
    BeforeAll {
        function Invoke-Script($Repository, [hashtable]$Environment) {
            $variables = @{
                DOCS_UPDATE_ENDPOINT = $Model.Endpoint; DOCS_UPDATE_MODEL = 'scrittore'; DOCS_UPDATE_TOKEN = 'token-di-prova'; DOCS_UPDATE_PROVIDER = ''
                DOCS_UPDATE_VERIFICATIONS = $Verifications -join ';'; DOCS_UPDATE_DESCRIPTION_FILE = ''; DOCS_UPDATE_ORIGIN_DIRECTORY = ''
                SYSTEM_COLLECTIONURI = "$($Boards.Endpoint)/organizzazione/"; SYSTEM_TEAMPROJECT = 'Progetto'; SYSTEM_ACCESSTOKEN = 'token'; TARGET_BRANCH = 'main'
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
    }

    It 'Un aggiornamento accettato chiede la PR e chiude il passo con successo' {
        $repository = New-UpdateRepository -Change $QueueChange
        Reset-ModelEndpoint $Model @(New-Draft @(New-SectionDraft -Text $NewStrategy))
        try {
            $run = Invoke-Script $repository @{}
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match '##vso\[task\.setvariable variable=documentationUpdateChanged\]True'
            $run.Output | Should -Match '##\[section\]Documentazione aggiornata'
        }
        finally { Remove-UpdateRepository $repository }
    }

    It 'Un modello non disponibile chiude il passo con un avviso e senza PR' {
        $repository = New-UpdateRepository -Change $QueueChange
        try {
            $run = Invoke-Script $repository @{ DOCS_UPDATE_ENDPOINT = $ClosedEndpoint }
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match '##vso\[task\.setvariable variable=documentationUpdateChanged\]False'
            $run.Output | Should -Match '##vso\[task\.logissue type=warning\]Modello non disponibile'
            $run.Output | Should -Match 'result=SucceededWithIssues'
        }
        finally { Remove-UpdateRepository $repository }
    }

    It 'Un modello non configurato ferma il passo con un errore' {
        $repository = New-UpdateRepository -Change $QueueChange
        try {
            $run = Invoke-Script $repository @{ DOCS_UPDATE_MODEL = '' }
            $run.ExitCode | Should -Be 1
            $run.Output | Should -Match '##vso\[task\.logissue type=error\]aggiornamento della documentazione: endpoint o modello non configurati'
        }
        finally { Remove-UpdateRepository $repository }
    }
}
