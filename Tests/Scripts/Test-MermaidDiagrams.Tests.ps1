#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Test-MermaidDiagrams.ps1

.DESCRIPTION
    Ogni scenario parte dal documento valido della fixture condivisa. Lo script gira come in
    pipeline: richiede Node.js; il parser Mermaid si installa in una cache condivisa da tutti
    gli scenari.
#>

BeforeAll {
    . "$PSScriptRoot/../Fixtures/Documentation/DocumentationFixture.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Test-MermaidDiagrams.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-mermaid-$(New-Guid)"

    function Invoke-DiagramCheck([System.Collections.IDictionary]$Docs, [hashtable]$Environment = @{}) {
        $variables = @{ GATE_MODE = '' }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        return Invoke-DocsScript $ScriptPath $Docs $variables
    }
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}


Describe "Funzionalità: Verifica dei diagrammi Mermaid" {

    Context "Scenario: diagrammi validi" {
        BeforeAll {
            $res = Invoke-DiagramCheck (New-ValidDocs)
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Scenario: un diagramma di sequenza con sintassi non valida" {
        BeforeAll {
            $docs = New-ValidDocs
            Edit-Docs $docs 'docs/architecture/06_runtime_view.md' 'B->>M: apre la sessione' 'B->>: apre la sessione'
            $res = Invoke-DiagramCheck $docs
            $line = Get-LineNumber $docs['docs/architecture/06_runtime_view.md'] 'B->>: apre la sessione'
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la sezione, il file e la riga del diagramma" {
            Get-Issues $res.Output | Where-Object { $_ -match "^Runtime View: diagramma non valido \(06_runtime_view\.md:$line\b" } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: un diagramma non valido in una decisione" {
        BeforeAll {
            $docs = New-ValidDocs
            $docs['docs/decisions/0001-esempio.md'] += "`n``````mermaid`nclassDiagram`n    Porta <|..>> Adattatore`n```````n"
            $res = Invoke-DiagramCheck $docs
            $line = Get-LineNumber $docs['docs/decisions/0001-esempio.md'] 'Porta <|..>> Adattatore'
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la decisione, il file e la riga del diagramma" {
            Get-Issues $res.Output | Where-Object { $_ -match "^Esempio: diagramma non valido \(0001-esempio\.md:$line\b" } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: la cartella delle decisioni dichiarata dal consumer" {
        BeforeAll {
            $docs = New-ValidDocs
            $docs.Remove('docs/decisions/0001-esempio.md')
            $docs['adr/0001-esempio.md'] = "---`nstatus: accepted`n---`n`n# Esempio`n`n``````mermaid`nclassDiagram`n    Porta <|..>> Adattatore`n```````n"
            $res = Invoke-DiagramCheck $docs @{ DECISIONS_DIRECTORY = 'adr' }
        }

        It "Allora la verifica legge le decisioni da quella cartella e fallisce" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Where-Object { $_ -match '^Esempio: diagramma non valido \(0001-esempio\.md:' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: un documento senza decisioni" {
        BeforeAll {
            $docs = New-ValidDocs
            $docs.Remove('docs/decisions/0001-esempio.md')
            $res = Invoke-DiagramCheck $docs
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }
}

Describe "Test-MermaidDiagrams — strumenti e modalità" {

    It "Senza Node.js fallisce nominando i diagrammi Mermaid" {
        $res = Invoke-DiagramCheck (New-ValidDocs) @{ PATH = '' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^diagrammi Mermaid: verifica non eseguita' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "In modalità off non verifica" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/06_runtime_view.md' 'B->>M: apre la sessione' 'B->>: apre la sessione'
        $res = Invoke-DiagramCheck $docs @{ GATE_MODE = 'off' }
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output | Should -BeNullOrEmpty
    }
}
