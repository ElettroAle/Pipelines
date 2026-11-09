#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Mermaid/Sync-DiagramLabels.ps1

.DESCRIPTION
    Come la build di una PR su Azure DevOps: il ramo della PR e' su un origin locale e la copia di
    lavoro e' il commit di merge del ramo nella destinazione. Il documento e' quello valido della
    fixture condivisa. Lo script gira come in pipeline: richiede Java 17 o successivo per la
    Structurizr CLI e Node.js per il parser Mermaid.
#>

BeforeAll {
    . "$PSScriptRoot/../Common/Fixtures/Documentation/DocumentationFixture.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Mermaid/Sync-DiagramLabels.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-diagram-labels-$(New-Guid)"

    $RuntimeView = 'docs/architecture/06_runtime_view.md'
    $WorkspaceDsl = 'docs/architecture/c4/workspace.dsl'

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

    function New-OriginRepository([scriptblock]$Change, [scriptblock]$Base = {}) {
        $bare = Join-Path ([IO.Path]::GetTempPath()) "pester-labels-origin-$(New-Guid)"
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-labels-build-$(New-Guid)"
        Invoke-Git init -q --bare -b main $bare | Out-Null
        $docs = New-ValidDocs
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

    function Invoke-Sync($Repository, [hashtable]$Environment = @{}) {
        $variables = @{ GATE_MODE = 'enforce'; SOURCE_BRANCH = 'refs/heads/feature'; SYSTEM_ACCESSTOKEN = ''; DOCUMENT_LANGUAGE = '' }
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

    function Remove-Repository($Repository) {
        Remove-Item -Recurse -Force $Repository.Root, $Repository.Bare -ErrorAction SilentlyContinue
    }
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}

Describe "Funzionalità: Diagrammi allineati al modello C4" {

    Context "Scenario: una rinomina nel modello si propaga al diagramma" {
        BeforeAll {
            $repository = New-OriginRepository { param($docs) Edit-Docs $docs $WorkspaceDsl 'bff = container "BFF"' 'bff = container "Ingresso"' }
            $res = Invoke-Sync $repository
            $runtime = Get-FeatureFile $repository $RuntimeView
            $subject = git -C $repository.Bare log -1 --format=%B refs/heads/feature
        }
        AfterAll { Remove-Repository $repository }

        It "Allora il ramo della PR riceve il diagramma con il nome del modello" {
            $runtime | Should -MatchExactly '(?m)^    participant bff as Ingresso$'
            $runtime | Should -MatchExactly '(?m)^    bff->>motore: apre la sessione$'
        }

        It "E il commit non avvia le pipeline sui rami" {
            ($subject -join "`n") | Should -MatchExactly '\[skip ci\]'
        }

        It "E la verifica si ferma per ripartire da quel commit" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_ -match '^allineamento dei diagrammi: diagrammi allineati al modello C4 \(commit sul ramo feature' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: un diagramma scritto per nome si migra con il modello del ramo base" {
        BeforeAll {
            $byName = { param($docs) Edit-Docs $docs $RuntimeView "    participant bff as BFF`n    participant motore as API del Motore`n    bff->>motore: apre la sessione`n    motore-->>bff" "    participant B as BFF`n    participant M as API del Motore`n    B->>M: apre la sessione`n    M-->>B" }
            $repository = New-OriginRepository -Base $byName -Change { param($docs) Edit-Docs $docs $WorkspaceDsl 'bff = container "BFF"' 'bff = container "Ingresso"' }
            $res = Invoke-Sync $repository
            $runtime = Get-FeatureFile $repository $RuntimeView
        }
        AfterAll { Remove-Repository $repository }

        It "Allora ogni partecipante ha come alias il suo identificativo e come etichetta il nome del modello" {
            $runtime | Should -MatchExactly '(?m)^    participant bff as Ingresso$'
            $runtime | Should -MatchExactly '(?m)^    participant motore as API del Motore$'
        }

        It "E i messaggi usano gli identificativi" {
            $runtime | Should -MatchExactly '(?m)^    bff->>motore: apre la sessione$'
            $runtime | Should -MatchExactly '(?m)^    motore-->>bff: codice della sessione$'
        }
    }

    Context "Scenario: un diagramma gia' allineato non cambia" {
        BeforeAll {
            $repository = New-OriginRepository { param($docs) }
            $res = Invoke-Sync $repository
            $head = git -C $repository.Bare rev-parse refs/heads/feature
        }
        AfterAll { Remove-Repository $repository }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }

        It "E il ramo della PR resta com'era" {
            $head | Should -Be $repository.Feature
        }
    }
}

Describe "Sync-DiagramLabels — fuori da una PR e modalita' off" {

    It "Fuori da una PR non cambia nulla" {
        $repository = New-OriginRepository { param($docs) Edit-Docs $docs $WorkspaceDsl 'bff = container "BFF"' 'bff = container "Ingresso"' }
        try {
            $res = Invoke-Sync $repository @{ SOURCE_BRANCH = '' }
            $res.ExitCode | Should -Be 0
            git -C $repository.Bare rev-parse refs/heads/feature | Should -Be $repository.Feature
            git -C $repository.Root status --porcelain | Should -BeNullOrEmpty
        }
        finally { Remove-Repository $repository }
    }

    It "In modalita' off non allinea" {
        $repository = New-OriginRepository { param($docs) Edit-Docs $docs $WorkspaceDsl 'bff = container "BFF"' 'bff = container "Ingresso"' }
        try {
            $res = Invoke-Sync $repository @{ GATE_MODE = 'off' }
            $res.ExitCode | Should -Be 0
            git -C $repository.Bare rev-parse refs/heads/feature | Should -Be $repository.Feature
        }
        finally { Remove-Repository $repository }
    }
}
