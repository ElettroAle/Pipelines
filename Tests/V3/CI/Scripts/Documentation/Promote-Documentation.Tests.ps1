#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Documentation/DocumentationDraft.ps1, Write-DraftSources.ps1,
    Promote-Documentation.ps1 e Sync-DocumentationDraft.ps1

.DESCRIPTION
    Ogni prova costruisce il repository del documento, con un bare repo come origin, il ramo principale e il ramo
    di bozza, e un repository sorgente con il suo origin e i checkout delle run. L'API delle PR e' l'endpoint locale
    di Azure Repos (../AzureRepos/Fixtures/AzureReposStub.ps1), che registra le richieste; il completamento di una PR
    si simula con il merge nel suo ramo di destinazione. Gli scenari del requisito girano gli script come in
    pipeline, in un processo a parte; la wiki si pubblica con Publish-Arc42Wiki.ps1, che richiede Java 17, e
    l'aggiornamento della documentazione usa il modello linguistico finto delle prove dei moduli.
#>

BeforeAll {
    . "$PSScriptRoot/../Common/Fixtures/Documentation/DocumentationFixture.ps1"
    . "$PSScriptRoot/../LanguageModel/Fixtures/ModelEndpointStub.ps1"
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Documentation/DocumentationUpdate.ps1"
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Documentation/DocumentationDraft.ps1"
    $Scripts = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts"
    $Templates = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Common/Steps"

    $script:StubState = Join-Path ([IO.Path]::GetTempPath()) "pester-draft-pr-$(New-Guid)"
    New-Item -ItemType Directory -Path $StubState | Out-Null
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
    $script:StubEndpoint = "http://127.0.0.1:$port"
    $stubScript = Resolve-Path "$PSScriptRoot/../AzureRepos/Fixtures/AzureReposStub.ps1"
    $script:Stub = Start-ThreadJob -ArgumentList $StubEndpoint, $StubState, "$stubScript" -ScriptBlock {
        param($Endpoint, $State, $Script)
        & $Script $Endpoint $State
    }
    $script:Model = Start-ModelEndpoint
    $script:Workspaces = [Collections.Generic.List[string]]::new()
    $script:Source = 'Negozio.Notifier'

    function Reset-Stub([object[]]$Active = @()) {
        Get-ChildItem $StubState -File | Remove-Item -Force
        if ($Active.Count) { [IO.File]::WriteAllText((Join-Path $StubState 'active.json'), (ConvertTo-Json @($Active) -Depth 6)) }
    }

    function Get-StubRequests {
        return @(Get-ChildItem $StubState -Filter 'request-*.json' | Sort-Object { [int]($_.BaseName -replace '\D', '') } | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
    }

    function Invoke-Git([string]$Directory) {
        $output = git -C $Directory -c user.name=t -c user.email=t@t -c core.autocrlf=false @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
        return $output
    }

    function New-Workspace([string]$Name) {
        $path = Join-Path ([IO.Path]::GetTempPath()) "pester-draft-$Name-$(New-Guid)"
        New-Item -ItemType Directory -Path $path | Out-Null
        $Workspaces.Add($path)
        return $path
    }

    function Save-Files([string]$Directory, [System.Collections.IDictionary]$Files, [string]$Message) {
        foreach ($path in $Files.Keys) {
            $file = Join-Path $Directory $path
            if ($null -eq $Files[$path]) { Remove-Item -Force $file -ErrorAction SilentlyContinue; continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
            [IO.File]::WriteAllText($file, ($Files[$path] -replace "`r`n", "`n"))
        }
        Invoke-Git $Directory add -A | Out-Null
        Invoke-Git $Directory commit -q --allow-empty -m $Message | Out-Null
    }

    function New-Clone([string]$Origin, [string]$Branch, [string]$Directory) {
        git -c core.autocrlf=false clone -q -b $Branch $Origin $Directory 2>&1 | Out-Null
        Invoke-Git $Directory config core.autocrlf false | Out-Null
        return $Directory
    }

    # Simula il completamento di una PR: il merge del ramo di origine nel ramo di destinazione dell'origin.
    function Complete-PullRequest([string]$Origin, [string]$Source, [string]$Target) {
        $clone = New-Clone $Origin $Target (Join-Path (New-Workspace 'merge') 'repo')
        Invoke-Git $clone fetch -q origin $Source | Out-Null
        Invoke-Git $clone merge -q --no-ff --no-edit FETCH_HEAD | Out-Null
        Invoke-Git $clone push -q origin "HEAD:refs/heads/$Target" | Out-Null
    }

    function Get-OriginFile([string]$Origin, [string]$Branch, [string]$Path) {
        return (git -C $Origin show "${Branch}:$Path" 2>$null) -join "`n"
    }

    function Invoke-Script([string]$Path, [string]$Directory, [hashtable]$Environment) {
        $previous = @{}
        foreach ($name in $Environment.Keys) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $Environment[$name])
        }
        Push-Location $Directory
        try {
            $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $Path 2>&1
            return @{ ExitCode = $LASTEXITCODE; Output = (@($output | ForEach-Object { "$_" }) -join "`n") }
        }
        finally {
            Pop-Location
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        }
    }

    function Get-PipelineEnvironment([hashtable]$Overrides = @{}) {
        $environment = @{
            SYSTEM_COLLECTIONURI      = "$StubEndpoint/"
            SYSTEM_TEAMPROJECT        = 'Progetto'
            SYSTEM_ACCESSTOKEN        = ''
            DRAFT_BRANCH              = 'staging'
            TARGET_BRANCH             = 'main'
            SOURCE_BRANCH             = ''
            DRAFT_SOURCES_FILE        = ''
            DRAFT_SOURCES_DIRECTORY   = ''
            DRAFT_SOURCE_REPOSITORIES = ''
        }
        foreach ($name in $Overrides.Keys) { $environment[$name] = $Overrides[$name] }
        return $environment
    }

    function Add-Notifier([System.Collections.IDictionary]$Docs) {
        Edit-Docs $Docs 'docs/architecture/c4/workspace.dsl' '            worker = container' "            notifier = container `"Notifier`" `"Notifiche push`" `"Functions`" `"Applicazione`"`n            worker = container"
        Edit-Docs $Docs 'docs/architecture/c4/workspace.dsl' 'motore -> worker "accoda"' "motore -> worker `"accoda`"`n        motore -> notifier `"chiede le notifiche push`""
        Edit-Docs $Docs 'docs/architecture/05_building_block_view.md' "L'API del Motore accoda i lavori lunghi al Worker." "L'API del Motore accoda i lavori lunghi al Worker.`n`nIl Notifier invia le notifiche push."
    }

    # Il lavoro arriva in staging nel repository sorgente; la run della bozza ne registra l'albero nel ramo di bozza
    # del documento, insieme alla pagina con il Notifier. Poi staging arriva in main, con o senza una correzione
    # integrata direttamente in main.
    function New-PromotionCase([switch]$WithCorrection) {
        $root = New-Workspace 'case'
        $sourceOrigin = Join-Path $root "origins/$Source.git"
        git init -q --bare -b main $sourceOrigin
        $sourceWork = Join-Path $root 'source-work'
        Invoke-Git $root init -q -b main $sourceWork | Out-Null
        Invoke-Git $sourceWork remote add origin $sourceOrigin | Out-Null
        Save-Files $sourceWork @{ 'README.md' = "# Notifier`n" } 'base'
        Invoke-Git $sourceWork push -q origin main | Out-Null
        Invoke-Git $sourceWork checkout -q -b staging | Out-Null
        Save-Files $sourceWork @{ 'src/Notifier.cs' = "class Notifier {}`n" } 'Merged PR 50: Notifier'
        Invoke-Git $sourceWork push -q origin staging | Out-Null
        $stagingSources = Join-Path $root 'staging-sources'
        New-Clone $sourceOrigin 'staging' (Join-Path $stagingSources $Source) | Out-Null

        $docsOrigin = Join-Path $root 'Architettura.Repo.git'
        git init -q --bare -b main $docsOrigin
        $docs = Join-Path $root 'docs-seed'
        Invoke-Git $root init -q -b main $docs | Out-Null
        Invoke-Git $docs config core.autocrlf false | Out-Null
        Invoke-Git $docs remote add origin $docsOrigin | Out-Null
        Save-Files $docs (New-ValidDocs) 'base'
        Save-Files $docs @{ '.documentation-baseline' = "$("$(Invoke-Git $docs rev-parse HEAD)".Trim())`n" } 'docs: documentation updated after the integration'
        Invoke-Git $docs push -q origin main | Out-Null
        Invoke-Git $docs checkout -q -b staging | Out-Null
        $draft = New-ValidDocs
        Add-Notifier $draft
        Save-Files $docs $draft 'docs: documentation updated after the integration in staging'
        $written = Invoke-Script "$Scripts/Documentation/Write-DraftSources.ps1" $docs (Get-PipelineEnvironment @{
                TARGET_BRANCH = 'staging'; SOURCE_BRANCH = 'staging'; DRAFT_SOURCES_DIRECTORY = $stagingSources; DRAFT_SOURCE_REPOSITORIES = $Source
            })
        if ($written.ExitCode -ne 0) { throw "Write-DraftSources: $($written.Output)" }
        Save-Files $docs @{} 'docs: draft sources'
        Invoke-Git $docs push -q origin staging | Out-Null

        Invoke-Git $sourceWork checkout -q main | Out-Null
        Invoke-Git $sourceWork merge -q --no-ff --no-edit staging -m 'Merged PR 51: staging in main' | Out-Null
        if ($WithCorrection) { Save-Files $sourceWork @{ 'src/Motore.cs' = "class Motore { /* correzione dei lavori doppi */ }`n" } 'Merged PR 52: correzione del Motore' }
        Invoke-Git $sourceWork push -q origin main | Out-Null
        $mainSources = Join-Path $root 'main-sources'
        New-Clone $sourceOrigin 'main' (Join-Path $mainSources $Source) | Out-Null
        $docsMain = New-Clone $docsOrigin 'main' (Join-Path $root 'docs-main')
        return [pscustomobject]@{ Root = $root; DocsOrigin = $docsOrigin; DocsMain = $docsMain; MainSources = $mainSources; StagingSources = $stagingSources; Written = $written }
    }

    function Invoke-Promotion($Case) {
        return Invoke-Script "$Scripts/Documentation/Promote-Documentation.ps1" $Case.DocsMain (Get-PipelineEnvironment @{ DRAFT_SOURCES_DIRECTORY = $Case.MainSources })
    }

    function Invoke-DraftWikiPublish($Case) {
        $wiki = Join-Path $Case.Root 'wiki.git'
        git init -q --bare -b wikiMaster $wiki
        $seed = Join-Path $Case.Root 'wiki-seed'
        Invoke-Git $Case.Root init -q -b wikiMaster $seed | Out-Null
        Invoke-Git $seed remote add origin $wiki | Out-Null
        Save-Files $seed @{ '.order' = "Release-notes`n"; 'Release-notes.md' = "[[_TOSP_]]`n" } 'Release notes'
        Invoke-Git $seed push -q origin HEAD:refs/heads/wikiMaster | Out-Null
        $checkout = New-Clone $wiki 'wikiMaster' (Join-Path $Case.Root 'wiki')
        $official = New-Clone $Case.DocsOrigin 'main' (Join-Path $Case.Root 'wiki-docs-main')
        $draft = New-Clone $Case.DocsOrigin 'staging' (Join-Path $Case.Root 'wiki-docs-staging')
        $result = Invoke-Script "$Scripts/Arc42/Publish-Arc42Wiki.ps1" $official @{
            WIKI_DIRECTORY = $checkout; SYSTEM_COLLECTIONURI = 'https://dev.azure.com/Org/'; SYSTEM_TEAMPROJECT = 'Progetto'
            BUILD_REPOSITORY_NAME = 'Architettura.Repo'; BUILD_SOURCEVERSION = '0123456789abcdef'; SYSTEM_ACCESSTOKEN = ''; DOCUMENT_LANGUAGE = ''
            DRAFT_DOCS_DIRECTORY = "$draft/docs/architecture"; DRAFT_DECISIONS_DIRECTORY = "$draft/docs/decisions"; DRAFT_BRANCH = 'staging'
        }
        $files = @(git -C $wiki -c core.quotepath=false ls-tree -r --name-only wikiMaster)
        return [pscustomobject]@{ Result = $result; Files = $files }
    }

    function New-Draft([object[]]$Documents) {
        $content = @{ summary = 'Documentato il Notifier e la correzione.'; documents = @($Documents) } | ConvertTo-Json -Depth 10 -Compress
        return New-ModelResponse 200 @{ choices = @(@{ message = @{ role = 'assistant'; content = $content } }); usage = @{ prompt_tokens = 10; completion_tokens = 5 } }
    }

    function Get-SectionText([string]$Body) {
        return New-Section 'Strategia della soluzione' 'come è divisa la piattaforma?' $Body
    }

    function Get-SkipCondition([string]$Template) {
        return [IO.File]::ReadAllText((Join-Path $Templates $Template)).Contains("ne(variables['documentationPromoted'], 'True')")
    }
}

AfterAll {
    New-Item -ItemType File -Path (Join-Path $StubState 'stop') -Force | Out-Null
    $Stub | Wait-Job -Timeout 10 | Out-Null
    $Stub | Remove-Job -Force
    Remove-Item -Recurse -Force $StubState -ErrorAction SilentlyContinue
    Stop-ModelEndpoint $Model
    $Workspaces | ForEach-Object { Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue }
}


# Gli scenari del requisito 2124 «Il lavoro arrivato in staging si legge nella wiki come bozza delle pagine che
# cambia» che riguardano la promozione della bozza, con il testo dei criteri di accettazione: un It per ogni Allora
# e ogni E.
Describe "Funzionalità: Bozza della documentazione per il lavoro arrivato in staging" {

    Context "Scenario: il lavoro di staging arriva in main così com'è" {
        BeforeAll {
            Reset-Stub
            $case = New-PromotionCase
            $promotion = Invoke-Promotion $case
            $requests = @(Get-StubRequests)
        }

        It 'Allora "5. Building Block View" ha il testo di "5. Building Block View (bozza)" senza una nuova stesura del modello' {
            $promotion.ExitCode | Should -Be 0 -Because $promotion.Output
            $promotion.Output | Should -Match ([regex]::Escape('##vso[task.setvariable variable=documentationPromoted]True'))
            $create = @($requests | Where-Object method -EQ 'POST')
            $create.Count | Should -Be 1
            $create[0].url | Should -Be '/Progetto/_apis/git/repositories/Architettura.Repo/pullrequests?api-version=7.1'
            $create[0].body.sourceRefName | Should -Be 'refs/heads/staging'
            $create[0].body.targetRefName | Should -Be 'refs/heads/main'
            $completion = @($requests | Where-Object method -EQ 'PATCH')[0].body
            $completion.autoCompleteSetBy.id | Should -Be 'build-identity'
            $completion.completionOptions.deleteSourceBranch | Should -BeFalse
            $completion.completionOptions.mergeStrategy | Should -Be 'noFastForward'
            foreach ($template in 'c4-read.yaml', 'c4-generate.yaml', 'c4-describe.yaml', 'adr-register.yaml', 'documentation-update.yaml') {
                Get-SkipCondition $template | Should -BeTrue -Because "$template non scrive una nuova stesura dopo la promozione"
            }

            Complete-PullRequest $case.DocsOrigin 'staging' 'main'
            $page = 'docs/architecture/05_building_block_view.md'
            Get-OriginFile $case.DocsOrigin 'main' $page | Should -Be (Get-OriginFile $case.DocsOrigin 'staging' $page)
            Get-OriginFile $case.DocsOrigin 'main' $page | Should -Match 'Il Notifier invia le notifiche push'
        }

        It 'E la wiki non ha più la pagina "5. Building Block View (bozza)"' {
            Reset-Stub
            $sync = Invoke-Script "$Scripts/Documentation/Sync-DocumentationDraft.ps1" $case.DocsMain (Get-PipelineEnvironment)
            $sync.ExitCode | Should -Be 0 -Because $sync.Output
            $create = @(Get-StubRequests | Where-Object method -EQ 'POST')
            $create.Count | Should -Be 1
            $create[0].body.sourceRefName | Should -Be 'refs/heads/main'
            $create[0].body.targetRefName | Should -Be 'refs/heads/staging'
            Complete-PullRequest $case.DocsOrigin 'main' 'staging'

            $published = Invoke-DraftWikiPublish $case
            $published.Result.ExitCode | Should -Be 0 -Because $published.Result.Output
            $published.Files | Should -Contain 'Architettura/5.-Building-Block-View.md'
            @($published.Files | Where-Object { $_ -match '\(bozza\)' }) | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: main riceve anche lavoro che staging non conteneva" {
        BeforeAll {
            Reset-Stub
            $case = New-PromotionCase -WithCorrection
            $promotion = Invoke-Promotion $case
            $requests = @(Get-StubRequests)

            Save-Files $case.DocsMain ([ordered]@{
                    'docs/architecture/c4/generated/containers/negozio-notifier.dsl' = "notifier = container `"Notifier`" `"Notifiche push`"`n// correzione dei lavori doppi del Motore`n"
                }) 'Merged PR 92: modello C4 con il Notifier e la correzione del Motore'
            $rewritten = Get-SectionText "La piattaforma divide il lavoro fra applicazioni piccole. Il Notifier invia le notifiche push.`n`nLa correzione del Motore ferma i lavori doppi."
            Reset-ModelEndpoint $Model @(New-Draft @(@{ path = 'docs/architecture/04_solution_strategy.md'; text = $rewritten; note = '' }))
            $settings = Get-UpdateSettings
            $settings.Endpoint = $Model.Endpoint
            $settings.Model = 'scrittore'
            $settings.AccessToken = 'token-di-prova'
            $settings.Verifications = @('Documentation/Test-Documentation.ps1')
            Push-Location $case.DocsMain
            try { $update = Invoke-DocumentationUpdate $settings }
            finally { Pop-Location }
            $modelRequests = @(Get-ModelEndpointRequests $Model)
        }

        It 'Allora il documento ufficiale si aggiorna con una nuova stesura che contiene il container "Notifier" e la correzione' {
            $promotion.ExitCode | Should -Be 0 -Because $promotion.Output
            $promotion.Output | Should -Not -Match 'documentationPromoted'
            $promotion.Output | Should -Match "$Source arriva in main con un albero diverso da quello della bozza"
            @($requests | Where-Object method -EQ 'POST') | Should -BeNullOrEmpty

            $update.Status | Should -Be 'updated'
            $modelRequests.Count | Should -Be 1
            (($modelRequests[0].Body.messages | Where-Object role -EQ 'user').content) | Should -Match 'Notifier[\s\S]*correzione dei lavori doppi'
            $section = [IO.File]::ReadAllText((Join-Path $case.DocsMain 'docs/architecture/04_solution_strategy.md'))
            $section | Should -Match 'Il Notifier invia le notifiche push'
            $section | Should -Match 'La correzione del Motore ferma i lavori doppi'
        }
    }
}


Describe 'Impostazioni della bozza dalle variabili della pipeline' {
    It 'Senza variabili la bozza e'' staging, la destinazione main e il ramo sorgente quello di destinazione' {
        $environment = Get-PipelineEnvironment @{ SYSTEM_COLLECTIONURI = ''; SYSTEM_TEAMPROJECT = ''; DRAFT_BRANCH = ''; TARGET_BRANCH = '' }
        $previous = @{}
        foreach ($name in $environment.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $environment[$name]) }
        try { $settings = Get-DraftSettings }
        finally { foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) } }
        $settings.DraftBranch | Should -Be 'staging'
        $settings.TargetBranch | Should -Be 'main'
        $settings.SourceBranch | Should -Be 'main'
        $settings.SourcesFile | Should -Be '.draft-sources'
        $settings.Repositories | Should -BeNullOrEmpty
    }

    It 'I rami arrivano senza refs/heads, una macro vale il default e i repository sono separati da punto e virgola' {
        $environment = @{ DRAFT_BRANCH = 'refs/heads/bozza'; TARGET_BRANCH = '$(targetBranch)'; SOURCE_BRANCH = 'refs/heads/staging'; DRAFT_SOURCE_REPOSITORIES = ' A ; B ;' }
        $previous = @{}
        foreach ($name in $environment.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $environment[$name]) }
        try { $settings = Get-DraftSettings }
        finally { foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) } }
        $settings.DraftBranch | Should -Be 'bozza'
        $settings.TargetBranch | Should -Be 'main'
        $settings.SourceBranch | Should -Be 'staging'
        $settings.Repositories | Should -Be @('A', 'B')
    }
}

Describe 'Sorgenti della bozza (ADR-2125)' {
    BeforeAll {
        $case = New-PromotionCase
        $record = (Get-OriginFile $case.DocsOrigin 'staging' '.draft-sources' | ConvertFrom-Json).sources
    }

    It 'La run sul ramo di bozza registra il ramo letto, il commit e il suo albero git' {
        $case.Written.ExitCode | Should -Be 0 -Because $case.Written.Output
        $checkout = Join-Path $case.StagingSources $Source
        $record.Count | Should -Be 1
        $record[0].repository | Should -Be $Source
        $record[0].branch | Should -Be 'staging'
        $record[0].commit | Should -Be "$(Invoke-Git $checkout rev-parse HEAD)".Trim()
        $record[0].tree | Should -Be "$(Invoke-Git $checkout rev-parse 'HEAD^{tree}')".Trim()
    }

    It 'Un repository senza il ramo sorgente della bozza si legge su main' {
        $directory = New-Workspace 'docs'
        Push-Location $directory
        try { $sources = @(Write-DraftSources @{ TargetBranch = 'staging'; SourceBranch = 'dev'; SourcesFile = 'out/.draft-sources'; SourcesDirectory = $case.MainSources; Repositories = @($Source) }) }
        finally { Pop-Location }
        $sources[0].branch | Should -Be 'main'
        (Get-Content -Raw (Join-Path $directory 'out/.draft-sources') | ConvertFrom-Json).sources[0].branch | Should -Be 'main'
    }

    It 'Una run sul ramo principale non scrive nulla' {
        $directory = New-Workspace 'docs'
        Push-Location $directory
        try { Write-DraftSources @{ TargetBranch = 'main'; SourcesFile = '.draft-sources'; Repositories = @($Source) } | Should -BeNullOrEmpty }
        finally { Pop-Location }
        Test-Path (Join-Path $directory '.draft-sources') | Should -BeFalse
    }

    It 'Senza repository, senza cartella dei checkout o senza un checkout il passo fallisce nominando cio'' che manca' {
        { Write-DraftSources @{ TargetBranch = 'staging'; Repositories = @() } } | Should -Throw '*DRAFT_SOURCE_REPOSITORIES*'
        { Write-DraftSources @{ TargetBranch = 'staging'; SourcesDirectory = ''; Repositories = @($Source) } } | Should -Throw '*DRAFT_SOURCES_DIRECTORY*'
        { Write-DraftSources @{ TargetBranch = 'staging'; SourcesDirectory = $case.Root; Repositories = @('Assente') } } | Should -Throw '*checkout di Assente assente*'
    }

    It 'Come passo della pipeline fallisce con un errore e, sul ramo principale, chiude senza scrivere' {
        $failed = Invoke-Script "$Scripts/Documentation/Write-DraftSources.ps1" (New-Workspace 'docs') (Get-PipelineEnvironment @{ TARGET_BRANCH = 'staging' })
        $failed.ExitCode | Should -Be 1
        Get-Issues $failed.Output | Should -Match 'sorgenti della bozza: DRAFT_SOURCE_REPOSITORIES'
        $skipped = Invoke-Script "$Scripts/Documentation/Write-DraftSources.ps1" (New-Workspace 'docs') (Get-PipelineEnvironment)
        $skipped.ExitCode | Should -Be 0
        $skipped.Output | Should -Match 'nessuna bozza da registrare'
    }
}

Describe 'Promozione della bozza (ADR-2127)' {
    BeforeAll {
        $case = New-PromotionCase
        function Invoke-PromotionIn([string]$Directory, [hashtable]$Overrides = @{}) {
            $settings = @{ DraftBranch = 'staging'; TargetBranch = 'main'; SourcesFile = '.draft-sources'; SourcesDirectory = $case.MainSources }
            foreach ($name in $Overrides.Keys) { $settings[$name] = $Overrides[$name] }
            $previous = @{ SYSTEM_COLLECTIONURI = $env:SYSTEM_COLLECTIONURI; SYSTEM_TEAMPROJECT = $env:SYSTEM_TEAMPROJECT }
            $env:SYSTEM_COLLECTIONURI = "$StubEndpoint/"
            $env:SYSTEM_TEAMPROJECT = 'Progetto'
            Push-Location $Directory
            try { return Invoke-DocumentationPromotion $settings }
            finally {
                Pop-Location
                foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
            }
        }
    }

    It 'Senza il ramo di bozza o senza il file delle sorgenti la documentazione si riscrive' {
        (Invoke-PromotionIn $case.DocsMain @{ DraftBranch = 'assente' }).Message | Should -Match 'nessun \.draft-sources nel ramo assente'
        (Invoke-PromotionIn $case.DocsMain @{ SourcesFile = 'altro/.draft-sources' }).Promoted | Should -BeFalse
    }

    It 'Un file delle sorgenti vuoto o un checkout assente non promuovono la bozza' {
        Get-PromotionObstacle @{ SourcesFile = '.draft-sources'; DraftBranch = 'staging' } @() | Should -Match 'non elenca repository sorgente'
        Get-PromotionObstacle @{ SourcesDirectory = $case.Root; TargetBranch = 'main' } @([pscustomobject]@{ repository = 'Assente'; tree = 'x' }) | Should -Be 'checkout di Assente assente'
    }

    It 'Una PR attiva dal ramo di bozza non ne apre un''altra' {
        Reset-Stub @(@{ pullRequestId = 77 })
        $outcome = Invoke-PromotionIn $case.DocsMain
        $outcome.Promoted | Should -BeTrue
        $outcome.Message | Should -Match 'PR 77'
        @(Get-StubRequests | Where-Object method -NE 'GET') | Should -BeNullOrEmpty
    }

    It 'Un ramo principale che contiene gia'' la bozza vale come promosso senza PR' {
        Reset-Stub
        $other = New-PromotionCase
        Complete-PullRequest $other.DocsOrigin 'staging' 'main'
        $outcome = Invoke-PromotionIn $other.DocsMain @{ SourcesDirectory = $other.MainSources }
        $outcome.Promoted | Should -BeTrue
        $outcome.Message | Should -Match "contiene gia' la bozza"
        Get-StubRequests | Should -BeNullOrEmpty
    }

    It 'Come passo della pipeline fallisce con un errore se manca la cartella dei checkout' {
        $failed = Invoke-Script "$Scripts/Documentation/Promote-Documentation.ps1" $case.DocsMain (Get-PipelineEnvironment)
        $failed.ExitCode | Should -Be 1
        Get-Issues $failed.Output | Should -Match 'promozione della bozza: DRAFT_SOURCES_DIRECTORY'
    }
}

Describe 'Allineamento della bozza al ramo principale (ADR-2127)' {
    BeforeAll {
        $case = New-PromotionCase
    }

    It 'Senza il ramo di bozza non apre nessuna PR' {
        Reset-Stub
        $result = Invoke-Script "$Scripts/Documentation/Sync-DocumentationDraft.ps1" $case.DocsMain (Get-PipelineEnvironment @{ DRAFT_BRANCH = 'assente' })
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Nessun ramo assente'
        Get-StubRequests | Should -BeNullOrEmpty
    }

    It 'Una bozza che contiene gia'' il ramo principale non riceve una PR' {
        Reset-Stub
        $result = Invoke-Script "$Scripts/Documentation/Sync-DocumentationDraft.ps1" $case.DocsMain (Get-PipelineEnvironment)
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match "contiene gia' main"
        Get-StubRequests | Should -BeNullOrEmpty
    }

    It 'Un origin che non risponde ferma il passo con un errore' {
        $broken = New-Workspace 'broken'
        Invoke-Git $broken init -q -b main | Out-Null
        Invoke-Git $broken remote add origin (Join-Path $broken 'assente.git') | Out-Null
        $result = Invoke-Script "$Scripts/Documentation/Sync-DocumentationDraft.ps1" $broken (Get-PipelineEnvironment)
        $result.ExitCode | Should -Be 1
        Get-Issues $result.Output | Should -Match 'allineamento della bozza'
    }
}
