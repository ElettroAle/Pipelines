#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Mermaid/DiagramModel.ps1

.DESCRIPTION
    Il modello C4 e' l'export JSON di Structurizr costruito in memoria, con l'identificativo del DSL
    nella proprieta' di ogni elemento; i diagrammi passano dal parser Mermaid vero, che richiede Node.js.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Mermaid/Mermaid.ps1"
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Mermaid/DiagramModel.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-diagram-model-$(New-Guid)"

    function New-Element([int]$Number, [string]$Id, [string]$Name, [object[]]$Relations = @()) {
        return [pscustomobject]@{ id = "$Number"; name = $Name; properties = [pscustomobject]@{ 'structurizr.dsl.identifier' = $Id }; relationships = $Relations }
    }

    function New-Workspace([hashtable]$Names = @{}) {
        $name = { param($Id, $Default) if ($Names.ContainsKey($Id)) { $Names[$Id] } else { $Default } }
        $web = New-Element 4 'contoso_bff_web' (& $name 'contoso_bff_web' 'Bff.Web') @([pscustomobject]@{ sourceId = '4'; destinationId = '6' })
        $web | Add-Member components @(
            (New-Element 5 'contoso_bff_web__routes' (& $name 'contoso_bff_web__routes' 'Web') @([pscustomobject]@{ sourceId = '5'; destinationId = '7' }))
        )
        $api = New-Element 6 'contoso_ai_api' (& $name 'contoso_ai_api' 'AI.Api')
        $api | Add-Member components @((New-Element 7 'contoso_ai_api__routes' (& $name 'contoso_ai_api__routes' 'Api')))
        $queue = New-Element 8 'contoso_infra_sb_prod' (& $name 'contoso_infra_sb_prod' 'Code ed eventi delle sessioni')
        $queue | Add-Member components @()
        $system = New-Element 2 'sistema' 'Piattaforma'
        $system | Add-Member containers @($web, $api, $queue)
        $person = New-Element 1 'cittadino' 'Cittadino' @([pscustomobject]@{ sourceId = '1'; destinationId = '4' })
        return [pscustomobject]@{ model = [pscustomobject]@{ people = @($person); softwareSystems = @($system) } }
    }

    function Get-Aligned([string]$Text, $Head, $Base = $null) {
        $parsed = Invoke-MermaidParser @([pscustomobject]@{ Id = 'd'; Text = $Text }) | Select-Object -First 1
        return Get-AlignedDiagram $Text $parsed $Head $Base
    }

    $Head = New-ModelIndex (New-Workspace)
    $Base = New-ModelIndex (New-Workspace @{ contoso_bff_web = 'Web'; contoso_ai_api = 'Api'; contoso_infra_sb_prod = 'sb-contoso-prod' })
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}

Describe "Funzionalità: Diagrammi che riconoscono gli elementi del modello C4 per identificativo" {

    Context "Scenario: una rinomina nel modello non rompe il diagramma" {
        BeforeAll {
            $aligned = Get-Aligned "sequenceDiagram`n    participant contoso_bff_web as Web`n    participant contoso_ai_api as Api`n    contoso_bff_web->>contoso_ai_api: legge l'ente" $Head
        }

        It "Allora ogni partecipante prende il nome che il modello gli da'" {
            $aligned | Should -MatchExactly '(?m)^    participant contoso_bff_web as Bff\.Web$'
            $aligned | Should -MatchExactly '(?m)^    participant contoso_ai_api as AI\.Api$'
        }

        It "E i messaggi restano gli stessi" {
            $aligned | Should -MatchExactly "(?m)^    contoso_bff_web->>contoso_ai_api: legge l'ente$"
        }
    }

    Context "Scenario: un diagramma scritto per nome si migra con il modello del ramo base" {
        BeforeAll {
            $text = @'
sequenceDiagram
    actor Cittadino
    participant Web
    participant Sb as sb-contoso-prod
    Cittadino->>Web: apre il sito di Web
    Web->>Sb: pubblica l'evento
    Note over Web,Sb: Web scrive sul canale
'@ -replace "`r`n", "`n"
            $aligned = Get-Aligned $text $Head $Base
        }

        It "Allora ogni partecipante ha come alias il suo identificativo e come etichetta il nome del modello" {
            $aligned | Should -MatchExactly '(?m)^    actor cittadino as Cittadino$'
            $aligned | Should -MatchExactly '(?m)^    participant contoso_bff_web as Bff\.Web$'
            $aligned | Should -MatchExactly '(?m)^    participant contoso_infra_sb_prod as Code ed eventi delle sessioni$'
        }

        It "E i messaggi e le note usano gli identificativi" {
            $aligned | Should -MatchExactly '(?m)^    cittadino->>contoso_bff_web: apre il sito di Web$'
            $aligned | Should -MatchExactly "(?m)^    contoso_bff_web->>contoso_infra_sb_prod: pubblica l'evento$"
            $aligned | Should -MatchExactly '(?m)^    Note over contoso_bff_web,contoso_infra_sb_prod: Web scrive sul canale$'
        }
    }

    Context "Scenario: il riquadro prende il nome del container dei suoi componenti" {
        BeforeAll {
            $aligned = Get-Aligned "sequenceDiagram`n    box Web`n        participant R as Web`n    end`n    box Api`n        participant A as Api`n    end`n    R->>A: legge" $Head $Base
        }

        It "Allora il riquadro si chiama come il container" {
            $aligned | Should -MatchExactly '(?m)^    box Bff\.Web$'
            $aligned | Should -MatchExactly '(?m)^    box AI\.Api$'
        }

        It "E il componente si riconosce nel suo container" {
            $aligned | Should -MatchExactly '(?m)^        participant contoso_bff_web__routes as Web$'
            $aligned | Should -MatchExactly '(?m)^        participant contoso_ai_api__routes as Api$'
            $aligned | Should -MatchExactly '(?m)^    contoso_bff_web__routes->>contoso_ai_api__routes: legge$'
        }
    }

    Context "Scenario: un elemento che nessun modello conosce resta com'e'" {
        BeforeAll {
            $text = "sequenceDiagram`n    participant Web`n    participant X as Archivio`n    Web->>X: salva"
            $aligned = Get-Aligned $text $Head $Base
        }

        It "Allora il partecipante sconosciuto resta, e lo segnala la verifica dei flussi" {
            $aligned | Should -MatchExactly '(?m)^    participant X as Archivio$'
            $aligned | Should -MatchExactly '(?m)^    contoso_bff_web->>X: salva$'
        }
    }

    Context "Scenario: una chiamata che il modello fa passare per un solo elemento si spezza attraverso quell'elemento" {
        BeforeAll {
            $text = "sequenceDiagram`n    actor cittadino as Cittadino`n    participant contoso_ai_api as AI.Api`n    cittadino->>+contoso_ai_api: apre la sessione`n    contoso_ai_api-->>-cittadino: sessione aperta"
            $aligned = Get-Aligned $text $Head
        }

        It "Allora l'elemento in mezzo entra nel diagramma subito dopo chi chiama" {
            $aligned | Should -MatchExactly '(?m)^    actor cittadino as Cittadino\n    participant contoso_bff_web as Bff\.Web\n    participant contoso_ai_api as AI\.Api$'
        }

        It "E la chiamata passa per l'elemento in mezzo, con lo stesso testo" {
            $aligned | Should -MatchExactly '(?m)^    cittadino->>contoso_bff_web: apre la sessione\n    contoso_bff_web->>\+contoso_ai_api: apre la sessione$'
        }

        It "E la risposta resta com'era" {
            $aligned | Should -MatchExactly '(?m)^    contoso_ai_api-->>-cittadino: sessione aperta$'
        }
    }

    Context "Scenario: una chiamata il cui passaggio comparirebbe intero e scomposto resta com'e'" {
        BeforeAll {
            $text = "sequenceDiagram`n    actor cittadino as Cittadino`n    box Bff.Web`n        participant contoso_bff_web__routes as Web`n    end`n    participant contoso_ai_api as AI.Api`n    cittadino->>contoso_ai_api: apre la sessione"
            $aligned = Get-Aligned $text $Head
        }

        It "Allora la chiamata senza relazione resta, e la segnala la verifica dei flussi" {
            $aligned | Should -MatchExactly '(?m)^    cittadino->>contoso_ai_api: apre la sessione$'
            $aligned | Should -Not -Match 'participant contoso_bff_web as'
        }
    }
}

Describe "DiagramModel — identificativi, istanze e partecipanti impliciti" {

    It "Indicizza gli elementi per identificativo del DSL e le relazioni fra identificativi" {
        $Head.Elements['contoso_bff_web__routes'].Container | Should -Be 'contoso_bff_web'
        $Head.Elements['contoso_infra_sb_prod'].Kind | Should -Be 'container'
        $Head.Relations.Contains('contoso_bff_web__routes>contoso_ai_api__routes') | Should -BeTrue
        $Head.Relations.Contains('cittadino>contoso_bff_web') | Should -BeTrue
    }

    It "Riconosce una seconda istanza dall'identificativo con il numero dopo la tilde" {
        Resolve-ElementId 'contoso_bff_web~2' $Head | Should -Be 'contoso_bff_web'
        Resolve-ElementId 'contoso_bff_web~x' $Head | Should -BeNullOrEmpty
    }

    It "Due partecipanti dello stesso elemento diventano due istanze" {
        $aligned = Get-Aligned "sequenceDiagram`n    participant A as Bff.Web`n    participant B as Bff.Web`n    A->>B: inoltra" $Head
        $aligned | Should -MatchExactly '(?m)^    participant contoso_bff_web as Bff\.Web$'
        $aligned | Should -MatchExactly '(?m)^    participant contoso_bff_web~2 as Bff\.Web$'
        $aligned | Should -MatchExactly '(?m)^    contoso_bff_web->>contoso_bff_web~2: inoltra$'
    }

    It "Un partecipante che compare solo nei messaggi riceve la sua riga dopo l'intestazione" {
        $aligned = Get-Aligned "sequenceDiagram`n    participant contoso_bff_web as Bff.Web`n    contoso_bff_web->>Api: legge" $Head $Base
        $aligned | Should -MatchExactly '(?m)\AsequenceDiagram\n    participant contoso_ai_api as AI\.Api\n    participant contoso_bff_web as Bff\.Web$'
        $aligned | Should -MatchExactly '(?m)^    contoso_bff_web->>contoso_ai_api: legge$'
    }

    It "Un alias che contiene un altro alias non si riscrive a meta'" {
        $aligned = Get-Aligned "sequenceDiagram`n    participant Web`n    participant Web2 as Api`n    Web->>Web2: legge" $Head $Base
        $aligned | Should -MatchExactly '(?m)^    contoso_bff_web->>contoso_ai_api: legge$'
    }

    It "Le righe di testo libero dei blocchi non si riscrivono" {
        $aligned = Get-Aligned "sequenceDiagram`n    participant Web`n    loop Web ripete`n        Web->>Web: verifica`n    end" $Head $Base
        $aligned | Should -MatchExactly '(?m)^    loop Web ripete$'
        $aligned | Should -MatchExactly '(?m)^        contoso_bff_web->>contoso_bff_web: verifica$'
    }

    It "Un diagramma gia' allineato resta identico" {
        $text = "sequenceDiagram`n    box Bff.Web`n        participant contoso_bff_web__routes as Web`n    end`n    participant contoso_ai_api as AI.Api`n    contoso_bff_web__routes->>contoso_ai_api: legge"
        Get-Aligned $text $Head | Should -BeExactly $text
    }
}
