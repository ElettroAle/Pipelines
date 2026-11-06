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
            $null = $text -match " $direction=(\d+)x(\d+)"
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
