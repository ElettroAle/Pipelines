#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Mermaid/Test-DiagramFlows.ps1

.DESCRIPTION
    Ogni scenario parte dal documento valido della fixture condivisa, con il diagramma di sequenza
    fatto di componenti e una decisione con la struttura e il flusso nel codice, e vi introduce un
    solo difetto. Lo script gira come in pipeline: richiede Java 17 o successivo per la Structurizr
    CLI e Node.js per il parser Mermaid, installati in cache condivise da tutti gli scenari.
#>

BeforeAll {
    . "$PSScriptRoot/../Common/Fixtures/Documentation/DocumentationFixture.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Mermaid/Test-DiagramFlows.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-flows-$(New-Guid)"

    $RuntimeView = 'docs/architecture/06_runtime_view.md'
    $Decision = 'docs/decisions/0002-sessioni.md'

    function New-FlowDocs {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/model/workspace.dsl' '        bff -> motore "inoltra"' "        bff -> motore `"inoltra`"`n        proxy -> sessioni `"apre la sessione`""
        Edit-Docs $docs $RuntimeView "    participant B as BFF`n    participant M as API del Motore`n    B->>M: apre la sessione`n    M-->>B: codice della sessione" "    participant P as Proxy`n    participant S as Sessioni`n    P->>S: apre la sessione`n    S-->>P: codice della sessione"
        $docs[$Decision] = @'
---
status: accepted
---

# Sessioni in un archivio

## Contesto e problema

Le sessioni vanno conservate fra due richieste.

## Opzioni considerate

- Un archivio delle sessioni.

## Esito della decisione

Si sceglie l'archivio delle sessioni.

## Struttura nel codice

```mermaid
classDiagram
    SessionController --> SessionStore
```

## Flusso nel codice

```mermaid
sequenceDiagram
    participant C as SessionController
    participant S as SessionStore
    C->>S: salva la sessione
    S-->>C: sessione salvata
```
'@ -replace "`r`n", "`n"
        return $docs
    }

    function Invoke-FlowCheck([System.Collections.IDictionary]$Docs, [hashtable]$Environment = @{}) {
        $variables = @{ GATE_MODE = ''; DOCUMENT_LANGUAGE = '' }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }
        return Invoke-DocsScript $ScriptPath $Docs $variables
    }

    function Get-Issue($Result, [string]$Pattern) {
        return Get-Issues $Result.Output | Where-Object { $_ -match $Pattern }
    }
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}


Describe "Funzionalità: Flussi coerenti con la struttura" {

    Context "Scenario: flussi coerenti" {
        BeforeAll {
            $res = Invoke-FlowCheck (New-FlowDocs)
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: flusso del documento che la struttura non dichiara (<Difetto>)" -ForEach @(
        @{ Difetto = 'un partecipante che il modello C4 non dichiara'; Old = 'participant S as Sessioni'; New = 'participant S as Modello'; Issue = '^Runtime View: partecipante fuori dal modello C4 \(06_runtime_view\.md:\d+ Modello\)$' }
        @{ Difetto = 'un container applicativo con i suoi componenti'; Old = 'participant P as Proxy'; New = 'participant P as BFF'; Issue = '^Runtime View: container applicativo al posto dei suoi componenti \(06_runtime_view\.md:\d+ BFF\)$' }
        @{ Difetto = 'una chiamata senza relazione nel modello C4'; Old = 'participant S as Sessioni'; New = 'participant S as Coda'; Issue = '^Runtime View: chiamata senza relazione nel modello C4 \(06_runtime_view\.md:\d+ Proxy -> Coda\)$' }
    ) {
        BeforeAll {
            $docs = New-FlowDocs
            Edit-Docs $docs $RuntimeView $Old $New
            $res = Invoke-FlowCheck $docs
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina il file del diagramma e l'elemento" {
            Get-Issue $res $Issue | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: risposte e chiamate a sé non si controllano" {
        BeforeAll {
            $docs = New-FlowDocs
            Edit-Docs $docs $RuntimeView '    S-->>P: codice della sessione' "    S->>S: crea il codice`n    S-->>P: codice della sessione"
            $res = Invoke-FlowCheck $docs
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: flusso di una decisione che la struttura non dichiara (<Difetto>)" -ForEach @(
        @{ Difetto = 'senza la parte Flusso nel codice'; Old = "## Flusso nel codice"; New = '## Ulteriori informazioni'; Issue = '^0002-sessioni: parte mancante \(Flusso nel codice\)$' }
        @{ Difetto = 'con il flusso senza diagramma di sequenza'; Old = "sequenceDiagram`n    participant C as SessionController`n    participant S as SessionStore`n    C->>S: salva la sessione`n    S-->>C: sessione salvata"; New = "stateDiagram-v2`n    [*] --> Aperta"; Issue = '^0002-sessioni: flusso senza diagramma di sequenza \(Flusso nel codice\)$' }
        @{ Difetto = 'con un partecipante assente dal diagramma delle classi'; Old = 'participant S as SessionStore'; New = 'participant S as TurnRunner'; Issue = '^0002-sessioni: partecipante fuori dal diagramma delle classi \(0002-sessioni\.md:\d+ TurnRunner\)$' }
    ) {
        BeforeAll {
            $docs = New-FlowDocs
            Edit-Docs $docs $Decision $Old $New
            $res = Invoke-FlowCheck $docs
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la decisione e il motivo" {
            Get-Issue $res $Issue | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Scenario: un diagramma degli stati accompagna il flusso" {
        BeforeAll {
            $docs = New-FlowDocs
            $docs[$Decision] += "`n``````mermaid`nstateDiagram-v2`n    [*] --> Aperta`n    Aperta --> Chiusa`n```````n"
            $res = Invoke-FlowCheck $docs
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Scenario: una decisione senza struttura nel codice non ha flusso" {
        BeforeAll {
            $docs = New-FlowDocs
            $docs[$Decision] = $docs[$Decision] -replace '(?s)## Struttura nel codice.*$', ''
            $res = Invoke-FlowCheck $docs
        }

        It "Allora la verifica non nomina la decisione" {
            Get-Issue $res '^0002-sessioni' | Should -BeNullOrEmpty -Because ($res.Output)
        }
    }
}

Describe "Test-DiagramFlows — partecipanti, decisioni e strumenti" {

    It "Ammette come partecipanti le persone e i container senza componenti" {
        $docs = New-FlowDocs
        Edit-Docs $docs 'docs/architecture/model/workspace.dsl' "                coda = component `"Coda`"`n            }" "                coda = component `"Coda`"`n            }`n            archivio = container `"Archivio`" `"Dati`" `"Cosmos DB`" `"Archivio`""
        Edit-Docs $docs 'docs/architecture/model/workspace.dsl' '        utente -> client "usa"' "        utente -> client `"usa`"`n        utente -> pagine `"apre`"`n        sessioni -> archivio `"salva`""
        Edit-Docs $docs $RuntimeView '    participant P as Proxy' "    actor U as Utente`n    participant G as Pagine`n    participant A as Archivio`n    participant P as Proxy"
        Edit-Docs $docs $RuntimeView '    S-->>P: codice della sessione' "    S->>A: salva`n    U->>G: apre`n    S-->>P: codice della sessione"
        $res = Invoke-FlowCheck $docs
        Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
        $res.ExitCode | Should -Be 0
    }

    It "Due istanze dello stesso componente si riconoscono per nome" {
        $docs = New-FlowDocs
        Edit-Docs $docs $RuntimeView '    participant S as Sessioni' "    participant S as Sessioni`n    participant P2 as Proxy"
        Edit-Docs $docs $RuntimeView '    S-->>P: codice della sessione' "    S-->>P: codice della sessione`n    P2->>S: apre un'altra sessione"
        $res = Invoke-FlowCheck $docs
        Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
    }

    It "Un nome che il modello C4 dà a due elementi fallisce come ambiguo" {
        $docs = New-FlowDocs
        Edit-Docs $docs 'docs/architecture/model/workspace.dsl' '                coda = component "Coda"' "                coda = component `"Coda`"`n                sessioniWorker = component `"Sessioni`""
        $res = Invoke-FlowCheck $docs
        $res.ExitCode | Should -Be 1
        Get-Issue $res '^Runtime View: partecipante ambiguo nel modello C4 \(06_runtime_view\.md:\d+ Sessioni\)$' | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Senza modello C4 un diagramma di sequenza del documento fallisce nominando il modello" {
        $docs = New-FlowDocs
        $docs.Remove('docs/architecture/model/workspace.dsl')
        $res = Invoke-FlowCheck $docs
        $res.ExitCode | Should -Be 1
        Get-Issue $res '^modello C4: modello mancante' | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Non giudica il flusso di una decisione chiusa" {
        $docs = New-FlowDocs
        Edit-Docs $docs $Decision 'status: accepted' 'status: superseded'
        Edit-Docs $docs $Decision '## Flusso nel codice' '## Ulteriori informazioni'
        $res = Invoke-FlowCheck $docs
        Get-Issue $res '^0002-sessioni' | Should -BeNullOrEmpty -Because ($res.Output)
    }

    It "Non giudica il modello delle decisioni, che non ha numero" {
        $docs = New-FlowDocs
        $docs['docs/decisions/adr-template.md'] = $docs[$Decision].Replace('## Flusso nel codice', '## Ulteriori informazioni')
        $res = Invoke-FlowCheck $docs
        Get-Issue $res '^adr-template' | Should -BeNullOrEmpty -Because ($res.Output)
    }

    It "Legge le parti della decisione nella lingua del documento" {
        $docs = ConvertTo-EnglishConventions (New-FlowDocs)
        Edit-Docs $docs $Decision '## Struttura nel codice' '## Code structure'
        Edit-Docs $docs $Decision '## Flusso nel codice' '## Further information'
        $res = Invoke-FlowCheck $docs @{ DOCUMENT_LANGUAGE = 'EN' }
        $res.ExitCode | Should -Be 1
        Get-Issue $res '^0002-sessioni: parte mancante \(Code flow\)$' | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Lascia alla verifica dei diagrammi Mermaid un diagramma non valido" {
        $docs = New-FlowDocs
        Edit-Docs $docs $RuntimeView 'P->>S: apre la sessione' 'P->>: apre la sessione'
        $res = Invoke-FlowCheck $docs
        Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
    }

    It "Senza Node.js fallisce nominando la verifica dei flussi" {
        $res = Invoke-FlowCheck (New-FlowDocs) @{ PATH = '' }
        $res.ExitCode | Should -Be 1
        Get-Issue $res '^flussi dei diagrammi: verifica non eseguita' | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "In modalità off non verifica" {
        $docs = New-FlowDocs
        Edit-Docs $docs $RuntimeView 'participant S as Sessioni' 'participant S as Modello'
        $res = Invoke-FlowCheck $docs @{ GATE_MODE = 'off' }
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output | Should -BeNullOrEmpty
    }
}
