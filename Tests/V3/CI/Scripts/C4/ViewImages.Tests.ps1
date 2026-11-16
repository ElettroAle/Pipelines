#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/ViewImages.ps1

.DESCRIPTION
    Il disegno di PlantUML e' sostituito da PNG finti: ogni diagramma di prova dichiara in un commento
    le misure del suo disegno in ciascuna direzione, con gli spazi di default e stretti, e il PNG finto
    porta quelle misure nell'intestazione IHDR. Il disegno vero e' provato da Arc42/PlantUml.Tests.ps1.
#>

BeforeAll {
    $previous = @{ Width = $env:C4_PAGE_WIDTH; Height = $env:C4_PAGE_HEIGHT; MinScale = $env:C4_MIN_SCALE }
    $env:C4_PAGE_WIDTH = ''; $env:C4_PAGE_HEIGHT = ''; $env:C4_MIN_SCALE = ''
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/ViewImages.ps1"

    function New-FakePng([int]$Width, [int]$Height) {
        $bytes = [byte[]]::new(33)
        [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52) | ForEach-Object -Begin { $i = 0 } -Process { $bytes[$i++] = $_ }
        foreach ($pair in @(@(16, $Width), @(20, $Height))) {
            $bytes[$pair[0]] = ($pair[1] -shr 24) -band 0xFF
            $bytes[$pair[0] + 1] = ($pair[1] -shr 16) -band 0xFF
            $bytes[$pair[0] + 2] = ($pair[1] -shr 8) -band 0xFF
            $bytes[$pair[0] + 3] = $pair[1] -band 0xFF
        }
        return $bytes
    }

    function New-FanOutDiagram([int]$Targets, [string]$Measures) {
        $relations = 1..$Targets | ForEach-Object { "Rel(sistema.api, sistema.risorsa$_, `"Usa`", `$techn=`"`", `$tags=`"`", `$link=`"`")" }
        return (@('@startuml', 'top to bottom direction', "' misure $Measures", 'Container(sistema.api, "Api")') + $relations + 'SHOW_LEGEND(true)', '@enduml') -join "`n"
    }

    function New-Diagram([string]$TopBottom, [string]$LeftRight, [string]$Direction = 'top to bottom direction', [string]$Compact = '') {
        $tight = if ($Compact) { $Compact } else { "tbs=$TopBottom lrs=$LeftRight" }
        return "@startuml`n$Direction`n' misure tb=$TopBottom lr=$LeftRight $tight`nPerson(utente, `"Utente`")`n@enduml`n"
    }

    function Invoke-FakePlantUml([hashtable]$Diagrams) {
        $script:Rendered += , @($Diagrams.Keys)
        $script:Sources = $Diagrams
        $images = @{}
        foreach ($key in $Diagrams.Keys) {
            $text = $Diagrams[$key]
            $direction = if ($text -match '(?m)^left to right direction') { 'lr' } else { 'tb' }
            if ($text -match '(?m)^skinparam nodesep') { $direction += 's' }
            $hidden = ([regex]::Matches($text, '(?m)^\S+ -\[hidden\]-> \S+$')).Count
            if ($hidden -and $text -match " $direction$hidden=(\d+)x(\d+)") { }
            else { $null = $text -match " $direction=(\d+)x(\d+)" }
            $images[$key] = New-FakePng ([int]$Matches[1]) ([int]$Matches[2])
        }
        return $images
    }
}

AfterAll {
    $env:C4_PAGE_WIDTH = $previous.Width; $env:C4_PAGE_HEIGHT = $previous.Height; $env:C4_MIN_SCALE = $previous.MinScale
}

Describe "Funzionalità: Viste C4 disegnate nella direzione che si legge" {

    BeforeEach {
        $script:Rendered = @()
        $script:Sources = @{}
        Mock ConvertTo-PlantUmlPng { param($Diagrams, $Java) Invoke-FakePlantUml $Diagrams }
    }

    Context "Scenario: una vista lunga dall'alto in basso si legge da sinistra a destra" {
        BeforeEach {
            $images = ConvertTo-ViewImages @{ container = (New-Diagram '800x3000' '1900x900') } 'java'
        }

        It "Allora resta il disegno da sinistra a destra" {
            $images['container'].Layout | Should -Be 'lr'
        }

        It "E la scala e' quella con cui il disegno entra nella pagina" {
            $images['container'].Scale | Should -Be (1200 / 1900)
        }

        It "E la vista si legge" {
            Test-ViewReadable $images['container'] | Should -BeTrue
        }

        It "E l'immagine e' il PNG della direzione scelta" {
            (Get-PngSize $images['container'].Png).Width | Should -Be 1900
        }
    }

    Context "Scenario: una vista larga da sinistra a destra si legge dall'alto in basso" {
        It "Allora resta il disegno dall'alto in basso anche se il modello dice da sinistra a destra" {
            $images = ConvertTo-ViewImages @{ componenti = (New-Diagram '1000x1200' '2600x700' 'left to right direction') } 'java'
            $images['componenti'].Layout | Should -Be 'tb'
        }
    }

    Context "Scenario: entrambe le direzioni entrano intere nella pagina" {
        It "Allora resta il disegno piu' piccolo" {
            $images = ConvertTo-ViewImages @{ contesto = (New-Diagram '900x700' '1100x500') } 'java'
            $images['contesto'].Layout | Should -Be 'lr'
            $images['contesto'].Scale | Should -Be 1
        }
    }

    Context "Scenario: gli spazi stretti fanno entrare la vista nella pagina" {
        It "Allora resta il disegno con gli spazi stretti" {
            $images = ConvertTo-ViewImages @{ componenti = (New-Diagram '2400x900' '900x3200' 'top to bottom direction' 'tbs=1500x800 lrs=900x2600') } 'java'
            $images['componenti'].Layout | Should -Be 'tb-stretto'
            $images['componenti'].Scale | Should -Be 0.8
        }
    }

    Context "Scenario: gli spazi stretti non cambiano il disegno" {
        It "Allora resta il disegno con gli spazi di default" {
            $images = ConvertTo-ViewImages @{ contesto = (New-Diagram '900x700' '1100x900') } 'java'
            $images['contesto'].Layout | Should -Be 'tb'
        }
    }

    Context "Scenario: nessuna direzione si legge" {
        BeforeEach {
            $images = ConvertTo-ViewImages @{ container = (New-Diagram '1500x6000' '5000x1400') } 'java'
        }

        It "Allora la vista non si legge" {
            Test-ViewReadable $images['container'] | Should -BeFalse
        }

        It "E la misura nomina dimensioni, direzione, scala e scala minima" {
            Format-ViewMeasure $images['container'] | Should -Be '1500x6000 px in tb, scala 0.27 (minima 0.60)'
        }
    }

    Context "Scenario: piu' viste" {
        BeforeEach {
            $images = ConvertTo-ViewImages @{ contesto = (New-Diagram '900x700' '1100x500'); container = (New-Diagram '800x3000' '1900x900') } 'java'
        }

        It "Allora tutte le varianti si disegnano in una sola volta" {
            $script:Rendered.Count | Should -Be 1
            $script:Rendered[0] | Sort-Object | Should -Be @('container.lr', 'container.lr-stretto', 'container.tb', 'container.tb-stretto', 'contesto.lr', 'contesto.lr-stretto', 'contesto.tb', 'contesto.tb-stretto')
        }

        It "E ogni vista ha il suo disegno" {
            $images.Keys | Sort-Object | Should -Be @('container', 'contesto')
        }
    }
}

Describe "Funzionalità: ranghi troppo larghi a capo" {

    BeforeEach {
        $script:Rendered = @()
        $script:Sources = @{}
        Mock ConvertTo-PlantUmlPng { param($Diagrams, $Java) Invoke-FakePlantUml $Diagrams }
    }

    Context "Scenario: le risorse chiamate da un'applicazione non entrano in una riga" {
        BeforeEach {
            $measures = 'tb=3000x900 lr=900x3400 tbs=2700x800 lrs=800x3000 tb6=900x1500 lr6=1500x2000 tb4=1800x1200'
            $images = ConvertTo-ViewImages @{ container = (New-FanOutDiagram 9 $measures) } 'java'
        }

        It "Allora resta il disegno con i ranghi a capo" {
            $images['container'].Layout | Should -Be 'tb'
            $images['container'].RankWidth | Should -Be 3
        }

        It "E la vista si legge" {
            Test-ViewReadable $images['container'] | Should -BeTrue
        }

        It "E la misura nomina la larghezza dei ranghi" {
            Format-ViewMeasure $images['container'] | Should -Be '900x1500 px in tb, ranghi di 3, scala 1.00 (minima 0.60)'
        }

        It "E ogni larghezza dei ranghi si disegna in ogni direzione e con ogni spazio" {
            @($script:Rendered[0] | Where-Object { $_ -like 'container.tb.3' -or $_ -like 'container.lr-stretto.8' }).Count | Should -Be 2
        }
    }

    Context "Scenario: i ranghi a capo non rendono il disegno piu' leggibile" {
        It "Allora resta il disegno senza frecce nascoste" {
            $images = ConvertTo-ViewImages @{ container = (New-FanOutDiagram 9 'tb=1000x900 lr=900x1000 tbs=1000x900 lrs=900x1000 tb6=900x1500 lr6=1500x900') } 'java'
            $images['container'].RankWidth | Should -Be 0
            Format-ViewMeasure $images['container'] | Should -Be '1000x900 px in tb, scala 1.00 (minima 0.60)'
        }
    }

    Context "Scenario: il rango piu' largo non supera tutte le larghezze provate" {
        It "Allora si disegnano solo le larghezze che il rango supera" {
            $null = ConvertTo-ViewImages @{ contesto = (New-FanOutDiagram 4 'tb=900x700 lr=700x900 tbs=900x700 lrs=700x900') } 'java'
            $script:Rendered[0] | Sort-Object | Should -Be @('contesto.lr', 'contesto.lr-stretto', 'contesto.lr-stretto.3', 'contesto.lr.3', 'contesto.tb', 'contesto.tb-stretto', 'contesto.tb-stretto.3', 'contesto.tb.3')
        }
    }
}

Describe "Funzionalità: ranghi di un diagramma C4-PlantUML" {

    It "Un rango piu' largo va a capo con frecce nascoste fra un elemento e quello tante posizioni dopo" {
        $diagram = "@startuml`nRel(a, b, `"x`")`nRel(a, c, `"x`")`nRel(a, d, `"x`")`nRel(a, e, `"x`")`nRel(a, f, `"x`")`nSHOW_LEGEND(true)`n@enduml`n"
        Add-RankWraps $diagram 2 | Should -Be "@startuml`nRel(a, b, `"x`")`nRel(a, c, `"x`")`nRel(a, d, `"x`")`nRel(a, e, `"x`")`nRel(a, f, `"x`")`nSHOW_LEGEND(true)`nb -[hidden]-> d`nc -[hidden]-> e`nd -[hidden]-> f`n@enduml`n"
    }

    It "Un rango che entra nella larghezza lascia il diagramma com'e'" {
        $diagram = "@startuml`nRel(a, b, `"x`")`nRel(a, c, `"x`")`n@enduml"
        Add-RankWraps $diagram 2 | Should -Be $diagram
    }

    It "Il rango di un elemento e' il cammino piu' lungo che lo raggiunge" {
        $ranks = Get-DiagramRanks "Rel(q, t, `"x`")`nRel(a, b, `"x`")`nRel(b, p, `"x`")`nRel(p, t, `"x`")"
        $ranks['q'], $ranks['a'], $ranks['p'], $ranks['t'] | Should -Be @(0, 0, 2, 3)
    }

    It "Una relazione all'indietro non fa girare il calcolo in tondo" {
        $ranks = Get-DiagramRanks "Rel(a, b, `"x`")`nRel(b, a, `"x`")`nRel(a, c, `"x`")"
        $ranks['a'], $ranks['b'], $ranks['c'] | Should -Be @(0, 1, 1)
    }

    It "Gli identificativi con il punto e le relazioni rientrate si leggono come li scrive Structurizr" {
        $ranks = Get-DiagramRanks "  Rel_D(dxp.api, dxp.store, `"x`", `$techn=`"y`")"
        $ranks['dxp.api'], $ranks['dxp.store'] | Should -Be @(0, 1)
    }

    It "Un elemento senza relazioni non ha rango" {
        (Get-DiagramRanks "Person(utente, `"Utente`")").Count | Should -Be 0
    }
}

Describe "Funzionalità: disposizione di un diagramma C4-PlantUML" {

    It "La riga della direzione si sostituisce e il resto del diagramma resta com'e'" {
        $diagram = New-Diagram '1x1' '1x1'
        Set-DiagramLayout $diagram 'lr' | Should -Be ($diagram -replace 'top to bottom direction', 'left to right direction')
    }

    It "Gli spazi stretti seguono la riga della direzione" {
        $diagram = New-Diagram '1x1' '1x1'
        Set-DiagramLayout $diagram 'tb-stretto' | Should -Be ($diagram -replace 'top to bottom direction', "top to bottom direction`nskinparam nodesep 20`nskinparam ranksep 30")
    }

    It "Un diagramma senza direzione la riceve dopo @startuml" {
        Set-DiagramLayout "@startuml`nPerson(utente, `"Utente`")`n@enduml" 'lr' | Should -Be "@startuml`nleft to right direction`nPerson(utente, `"Utente`")`n@enduml"
    }
}

Describe "Funzionalità: pagina e scala minima dichiarate dalla pipeline" {

    It "Pagina e scala minima vengono da C4_PAGE_WIDTH, C4_PAGE_HEIGHT e C4_MIN_SCALE" {
        $env:C4_PAGE_WIDTH = '1000'; $env:C4_PAGE_HEIGHT = '800'; $env:C4_MIN_SCALE = '0.9'
        try {
            . "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/ViewImages.ps1"
            Get-PageScale ([pscustomobject]@{ Width = 2000; Height = 400 }) | Should -Be 0.5
            Test-ViewReadable ([pscustomobject]@{ Scale = 0.85 }) | Should -BeFalse
        }
        finally {
            $env:C4_PAGE_WIDTH = ''; $env:C4_PAGE_HEIGHT = ''; $env:C4_MIN_SCALE = ''
            . "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/ViewImages.ps1"
        }
    }
}

Describe "Funzionalità: ranghi a capo disegnati da PlantUML" {

    BeforeAll {
        . "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/Structurizr.ps1"
        $previousPath = $env:PATH
        $env:PATH = ($env:PATH -split [IO.Path]::PathSeparator | Where-Object { -not (Test-Path (Join-Path $_ 'dot*')) }) -join [IO.Path]::PathSeparator
        $resources = 1..30 | ForEach-Object { "    ContainerDb(Negozio.Risorsa$_, `"Risorsa $_`", `$techn=`"Azure`", `$descr=`"Conserva i dati della parte $_.`", `$tags=`"`", `$link=`"`")" }
        $relations = 1..30 | ForEach-Object { "Rel(Negozio.Api, Negozio.Risorsa$_, `"Legge e scrive i dati`", `$techn=`"HTTPS`", `$tags=`"`", `$link=`"`")" }
        # Come la esporta la Structurizr CLI: identificativi con il punto, separatore spento, confine del sistema.
        $view = (@('@startuml', 'set separator none', 'title Negozio - Containers', '', 'top to bottom direction', '', '!include <C4/C4>', '!include <C4/C4_Context>', '!include <C4/C4_Container>', '',
                'System_Boundary("Negozio_boundary", "Negozio", $tags="") {', '    Container(Negozio.Api, "Api", $techn="ASP.NET Core", $descr="Espone le API del negozio.", $tags="", $link="")') +
            $resources + '}' + '' + $relations + '' + 'SHOW_LEGEND(true)' + '@enduml') -join "`n"
        $images = ConvertTo-ViewImages @{ container = $view } (Get-StructurizrJava)
    }

    AfterAll { $env:PATH = $previousPath }

    It "Una vista con trenta risorse chiamate da un'applicazione si legge con i ranghi a capo" {
        Format-ViewMeasure $images['container'] | Write-Host
        $images['container'].RankWidth | Should -BeGreaterThan 0
        Test-ViewReadable $images['container'] | Should -BeTrue
    }
}
