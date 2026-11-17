#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/AzureBoards/Test-PullRequestSources.ps1 e PullRequestSources.ps1

.DESCRIPTION
    Ogni test descrive una board locale (../Adr/Fixtures/AzureDevOpsStub.ps1) con la PR, i work item che
    collega e i loro padri. La verifica gira come in pipeline, con il numero della PR nell'ambiente.
#>

BeforeAll {
    . "$PSScriptRoot/../Adr/Fixtures/AzureDevOpsStub.ps1"
    $script:EntryScript = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/AzureBoards/Test-PullRequestSources.ps1"
    . (Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/AzureBoards/PullRequestSources.ps1")
    $script:Stub = Start-AzureDevOpsStub
    $script:Project = 'Progetto'
    $script:Repository = 'Negozio.Api'

    function New-Adr([string[]]$Sections = @('Contesto e problema', 'Opzioni considerate', 'Esito della decisione')) {
        $body = @('# Una scelta', '') + @($Sections | ForEach-Object { "## $_"; ''; 'Testo.'; '' })
        return $body -join "`n"
    }

    function New-Item-Route([int]$Id, [string]$Type, [hashtable]$Fields = @{}, [int]$Parent = 0) {
        $all = @{ 'System.WorkItemType' = $Type; 'System.Title' = "$Type $Id" }
        foreach ($name in $Fields.Keys) { $all[$name] = $Fields[$name] }
        $body = @{ id = $Id; fields = $all }
        if ($Parent) {
            $body.relations = @(
                @{ rel = 'System.LinkTypes.Related'; url = "http://board/_apis/wit/workItems/9999" }
                @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "http://board/_apis/wit/workItems/$Parent" }
            )
        }
        return @{ status = 200; body = $body }
    }

    # Items: @{ <id> = @{ Type; Fields; Parent } }
    function Set-Board([int[]]$Linked, [hashtable]$Items, [int]$PullRequest = 1300) {
        $routes = @{
            "GET /$Project/_apis/git/pullrequests/$PullRequest" = @{ status = 200; body = @{ pullRequestId = $PullRequest; repository = @{ id = 'repo-guid'; name = $Repository } } }
            "GET /$Project/_apis/git/repositories/repo-guid/pullRequests/$PullRequest/workitems" = @{ status = 200; body = @{ value = @($Linked | ForEach-Object { @{ id = "$_" } }) } }
        }
        foreach ($id in $Items.Keys) {
            $item = $Items[$id]
            $fields = if ($item.Fields) { $item.Fields } else { @{} }
            $routes["GET /$Project/_apis/wit/workitems/$id"] = New-Item-Route $id $item.Type $fields ([int]$item.Parent)
        }
        Set-AzureDevOpsRoutes $Stub $routes
    }

    function Requirement([string]$Criteria = '<pre>Funzionalità: una</pre>') { return @{ Type = 'Requirement'; Fields = @{ 'Microsoft.VSTS.Common.AcceptanceCriteria' = $Criteria } } }
    function Bug([string]$Steps = '<p>Si apre la pagina.</p>') { return @{ Type = 'Bug'; Fields = @{ 'Microsoft.VSTS.TCM.ReproSteps' = $Steps } } }
    function Task([int]$Parent, [string]$Description = (New-Adr)) { return @{ Type = 'Task'; Parent = $Parent; Fields = @{ 'System.Description' = $Description } } }

    function Set-SourcesEnvironment([string]$PullRequest = '1300', [string]$Mode = 'enforce') {
        $env:PULL_REQUEST_ID = $PullRequest
        $env:GATE_MODE = $Mode
        $env:SYSTEM_COLLECTIONURI = "$($Stub.Endpoint)/"
        $env:SYSTEM_TEAMPROJECT = $Project
        $env:SYSTEM_ACCESSTOKEN = 'token'
    }

    function Invoke-Verification {
        $output = & pwsh -NoProfile -NonInteractive -File $EntryScript 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { "$_" }) }
    }

    function Get-Errors($Result) {
        return @($Result.Output | Where-Object { $_ -match '^##vso\[task\.logissue type=error\](.*)$' } | ForEach-Object { $Matches[1] })
    }
}

AfterAll {
    Stop-AzureDevOpsStub $Stub
    'PULL_REQUEST_ID', 'GATE_MODE', 'SYSTEM_COLLECTIONURI', 'SYSTEM_TEAMPROJECT', 'SYSTEM_ACCESSTOKEN', 'DOCUMENT_LANGUAGE' | ForEach-Object { Remove-Item "env:$_" -ErrorAction SilentlyContinue }
}

Describe 'Funzionalità: Fonti di una PR verificate prima dell''integrazione' {
    BeforeEach { Set-SourcesEnvironment }

    Context 'Schema dello scenario: fonti complete' {
        It 'il Task 1600 figlio di <padre> con <fonte>: la verifica passa' -ForEach @(
            @{ padre = 'il Requirement 1500'; fonte = 'i criteri di accettazione'; Parent = 1500; Item = { Requirement } }
            @{ padre = 'il Bug 1504'; fonte = 'i passi di riproduzione'; Parent = 1504; Item = { Bug } }
        ) {
            Set-Board @(1600) @{ 1600 = (Task $Parent); $Parent = (& $Item) }

            $result = Invoke-Verification

            $result.ExitCode | Should -Be 0
            Get-Errors $result | Should -BeNullOrEmpty
        }
    }

    Context 'Schema dello scenario: fonte mancante' {
        It 'collegata a <collegamento> con <difetto>: la verifica fallisce nominando <elemento> e "<parte>"' -ForEach @(
            @{ collegamento = 'il solo Requirement 1500'; difetto = 'nessun Task collegato'; elemento = 'PR 1300'; parte = 'Task collegato'
                Linked = @(1500); Items = { @{ 1500 = (Requirement) } } }
            @{ collegamento = 'il Task 1600'; difetto = 'il Task 1600 senza la sezione richiesta'; elemento = 'Task 1600'; parte = 'Contesto e problema'
                Linked = @(1600); Items = { @{ 1600 = (Task 1500 (New-Adr @('Opzioni considerate', 'Esito della decisione'))); 1500 = (Requirement) } } }
            @{ collegamento = 'il Task 1600'; difetto = 'il Task 1600 senza la sezione richiesta'; elemento = 'Task 1600'; parte = 'Opzioni considerate'
                Linked = @(1600); Items = { @{ 1600 = (Task 1500 (New-Adr @('Contesto e problema', 'Esito della decisione'))); 1500 = (Requirement) } } }
            @{ collegamento = 'il Task 1600'; difetto = 'il Task 1600 senza la sezione richiesta'; elemento = 'Task 1600'; parte = 'Esito della decisione'
                Linked = @(1600); Items = { @{ 1600 = (Task 1500 (New-Adr @('Contesto e problema', 'Opzioni considerate'))); 1500 = (Requirement) } } }
            @{ collegamento = 'il Task 1600 figlio di 1500'; difetto = 'il Requirement 1500 senza criteri'; elemento = 'Requirement 1500'; parte = 'criteri di accettazione'
                Linked = @(1600); Items = { @{ 1600 = (Task 1500); 1500 = (Requirement '') } } }
            @{ collegamento = 'il Task 1600 figlio del Bug 1505'; difetto = 'il Bug 1505 senza passi'; elemento = 'Bug 1505'; parte = 'passi di riproduzione'
                Linked = @(1600); Items = { @{ 1600 = (Task 1505); 1505 = (Bug '<div> </div>') } } }
            @{ collegamento = 'il Task 1600'; difetto = 'il Task 1600 senza padre'; elemento = 'Task 1600'; parte = 'Requirement o Bug padre'
                Linked = @(1600); Items = { @{ 1600 = (Task 0) } } }
        ) {
            Set-Board $Linked (& $Items)

            $result = Invoke-Verification

            $result.ExitCode | Should -Be 1
            Get-Errors $result | Should -Contain "${elemento}: manca `"$parte`""
        }
    }

    Context 'Scenario: fonti completate dopo il fallimento' {
        It 'la verifica ripetuta dopo l''aggiunta della sezione passa' {
            Set-Board @(1600) @{ 1600 = (Task 1500 (New-Adr @('Contesto e problema', 'Esito della decisione'))); 1500 = (Requirement) }
            $failed = Invoke-Verification
            $failed.ExitCode | Should -Be 1
            Get-Errors $failed | Should -Contain 'Task 1600: manca "Opzioni considerate"'

            Set-Board @(1600) @{ 1600 = (Task 1500); 1500 = (Requirement) }
            $result = Invoke-Verification

            $result.ExitCode | Should -Be 0
        }
    }
}

Describe 'Test-PullRequestSources' {
    BeforeEach { Set-SourcesEnvironment }

    It 'nomina ogni parte mancante di ogni Task e legge una sola volta il padre comune' {
        Set-Board @(1600, 1601, 1500) @{
            1600 = (Task 1500 (New-Adr @('Esito della decisione')))
            1601 = (Task 1500 '')
            1500 = (Requirement)
        }

        $result = Invoke-Verification

        $errors = Get-Errors $result
        $errors | Should -Contain 'Task 1600: manca "Contesto e problema"'
        $errors | Should -Contain 'Task 1600: manca "Opzioni considerate"'
        $errors | Should -Contain 'Task 1601: manca "Esito della decisione"'
        @(Get-AzureDevOpsRequests $Stub | Where-Object Path -EQ "/$Project/_apis/wit/workitems/1500").Count | Should -Be 1
    }

    It 'in modalita'' warn segnala senza bloccare' {
        Set-SourcesEnvironment -Mode 'warn'
        Set-Board @(1500) @{ 1500 = (Requirement) }

        $result = Invoke-Verification

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Contain '##vso[task.logissue type=warning]PR 1300: manca "Task collegato"'
    }

    It 'in modalita'' off non legge la board' {
        Set-SourcesEnvironment -Mode 'off'
        Set-Board @() @{}

        $result = Invoke-Verification

        $result.ExitCode | Should -Be 0
        Get-AzureDevOpsRequests $Stub | Should -BeNullOrEmpty
    }

    It 'fuori dalla build di una PR fallisce dicendo che serve la PR' {
        Set-SourcesEnvironment -PullRequest '$(System.PullRequest.PullRequestId)'

        $result = Invoke-Verification

        $result.ExitCode | Should -Be 1
        Get-Errors $result | Should -Match 'build di una PR'
    }

    It 'con la board che non risponde fallisce nominando l''errore' {
        Set-Board @() @{} -PullRequest 1
        $result = Invoke-Verification

        $result.ExitCode | Should -Be 1
        Get-Errors $result | Should -Match 'fonti della PR 1300'
    }
}

Describe 'Get-SourceIssues' {
    BeforeEach { Set-SourcesEnvironment }

    It 'con le fonti complete non ha rilievi' {
        Set-Board @(1600, 1601) @{ 1600 = (Task 1500); 1601 = (Task 1504); 1500 = (Requirement); 1504 = (Bug) }

        Get-SourceIssues (Get-SourcesSettings) | Should -BeNullOrEmpty
    }

    It 'nomina il Bug senza passi, il requisito senza criteri e il Task senza padre' {
        Set-Board @(1600, 1601, 1602) @{ 1600 = (Task 1505); 1601 = (Task 1500); 1602 = (Task 0); 1505 = (Bug ''); 1500 = (Requirement '') }

        Get-SourceIssues (Get-SourcesSettings) | Should -Be @(
            'Bug 1505: manca "passi di riproduzione"'
            'Requirement 1500: manca "criteri di accettazione"'
            'Task 1602: manca "Requirement o Bug padre"'
        )
    }

    It 'senza Task collegati nomina la PR' {
        Set-Board @() @{}

        Get-SourceIssues (Get-SourcesSettings) | Should -Be @('PR 1300: manca "Task collegato"')
    }

    It 'chiede la board con il token della build' {
        Set-Board @(1600) @{ 1600 = (Task 1500); 1500 = (Requirement) }

        Get-SourceIssues (Get-SourcesSettings) | Out-Null

        $requests = Get-AzureDevOpsRequests $Stub
        $requests.Path | Should -Contain "/$Project/_apis/git/repositories/repo-guid/pullRequests/1300/workitems"
        ($requests | Where-Object Path -EQ "/$Project/_apis/wit/workitems/1600").Query | Should -Match 'expand=relations'
    }
}

Describe 'Get-MissingAdrSections' {
    It 'riconosce le sezioni in Markdown al secondo livello' {
        Get-MissingAdrSections (New-Adr) | Should -BeNullOrEmpty
    }

    It 'non accetta una sezione a un livello diverso dal secondo' {
        $adr = "# Scelta`n`n### Contesto e problema`n`n## Opzioni considerate`n`n## Esito della decisione`n"

        Get-MissingAdrSections $adr | Should -Be @('Contesto e problema')
    }

    It 'riconosce le sezioni in HTML, con spazi, tag ed entita'' dentro l''intestazione' {
        $adr = '<h2>Contesto e problema </h2><p>x</p><h2 id="o"><b>Opzioni</b> considerate</h2><h2>Esito&nbsp;della decisione</h2>'

        Get-MissingAdrSections $adr | Should -BeNullOrEmpty
    }

    It 'non scambia per sezione il nome citato nel testo' {
        Get-MissingAdrSections '<p>Contesto e problema, Opzioni considerate, Esito della decisione</p>' | Should -HaveCount 3
    }

    It 'prende le sezioni dalla lingua del documento' {
        $english = "## Context and Problem Statement`n`n## Considered Options`n`n## Decision Outcome`n"

        Get-MissingAdrSections $english @('Context and Problem Statement', 'Considered Options', 'Decision Outcome') | Should -BeNullOrEmpty
    }
}

Describe 'Test-HasText' {
    It 'considera vuoto un campo con soli tag, spazi ed entita''' -ForEach @(
        @{ Value = '' }, @{ Value = $null }, @{ Value = '<div><br></div>' }, @{ Value = '<p>&nbsp;</p>' }
    ) {
        Test-HasText $Value | Should -BeFalse
    }

    It 'considera pieno un campo con del testo' {
        Test-HasText '<pre>Scenario: uno</pre>' | Should -BeTrue
    }
}

Describe 'Get-ParentIssue' {
    It 'accetta come requisito anche User Story e Product Backlog Item' -ForEach @(@{ Type = 'User Story' }, @{ Type = 'Product Backlog Item' }) {
        $parent = [pscustomobject]@{ Id = 1500; Type = $Type; AcceptanceCriteria = 'Scenario: uno'; ReproSteps = '' }

        Get-ParentIssue $parent 1600 | Should -BeNullOrEmpty
    }

    It 'un padre che non e'' ne'' requisito ne'' Bug manca come padre del Task' {
        $parent = [pscustomobject]@{ Id = 200; Type = 'Feature'; AcceptanceCriteria = ''; ReproSteps = '' }

        Get-ParentIssue $parent 1600 | Should -Be 'Task 1600: manca "Requirement o Bug padre"'
    }
}

Describe 'Get-SourcesSettings' {
    It 'toglie la barra finale dall''indirizzo della collezione' {
        Set-SourcesEnvironment

        (Get-SourcesSettings).CollectionUri | Should -Be $Stub.Endpoint
    }

    It 'rifiuta un numero di PR che non e'' un intero' {
        $env:PULL_REQUEST_ID = 'abc'

        { Get-SourcesSettings } | Should -Throw '*build di una PR*'
    }
}
