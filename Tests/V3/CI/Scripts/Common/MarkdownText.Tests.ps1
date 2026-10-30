#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Common/MarkdownText.ps1

.DESCRIPTION
    Lettura delle sezioni Markdown di un documento e misure di leggibilita', comuni a tutti
    gli script di verifica della documentazione.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/MarkdownText.ps1"
}


Describe "MarkdownText — analisi del testo" {

    It "Divide le frasi su punto, punto esclamativo e punto interrogativo" {
        Get-Sentences 'Il BFF riceve. Chi chiama? Il Client!' @() | Should -Be @('Il BFF riceve.', 'Chi chiama?', 'Il Client!')
    }

    It "Non divide la frase dopo un'abbreviazione dichiarata" {
        Get-Sentences 'Un servizio, es. il BFF, riceve. Poi basta.' @('es.') | Should -Be @('Un servizio, es. il BFF, riceve.', 'Poi basta.')
    }

    It "Non divide la frase su un numero decimale" {
        @(Get-Sentences 'La versione 1.5 gira ovunque.' @()).Count | Should -Be 1
    }

    It "Conta le parole separando l'apostrofo" {
        Get-WordCount "L'API del Motore." | Should -Be 4
    }

    It "Calcola l'indice Gulpease con la formula 89 + (300 frasi - 10 lettere) / parole" {
        Get-GulpeaseIndex 'Il gatto dorme. Il cane abbaia.' @() | Should -Be 149
    }

    It "Toglie dal testo semplice link, enfasi e codice in linea" {
        ConvertTo-PlainText 'Il **BFF** usa [la API](x.md) e `SessionStore` in *modo* sicuro.' | Should -Be 'Il BFF usa la API e SessionStore in modo sicuro.'
    }

    It "Ricava l'ancora di un titolo come la wiki" {
        ConvertTo-HeadingAnchor 'Qualità e Rischi: sintesi' | Should -Be 'qualità-e-rischi-sintesi'
    }
}

Describe "MarkdownText — blocchi di una sezione" {

    BeforeAll {
        $content = @(
            '# Titolo {#section-titolo}'
            ''
            '> **A chi serve**: a tutti.'
            ''
            '## In breve {#_in_breve}'
            ''
            'Prima riga'
            'seconda riga.'
            ''
            '- voce uno'
            '- voce due'
            ''
            '| Nome | Ruolo |'
            ''
            '<!-- vista: contesto -->'
            '```mermaid'
            'sequenceDiagram'
            '```'
        ) -join "`n"
        $section = ConvertFrom-MarkdownSection $content
    }

    It "Riconosce il titolo senza l'attributo del titolo" { $section.Title | Should -Be 'Titolo' }
    It "Riconosce le parti senza l'attributo del titolo" { $section.Parts | Should -Be @('In breve') }
    It "Riconosce l'apertura prima della prima parte" { ($section.Blocks | Where-Object Kind -EQ 'opening').Text | Should -Be 'A chi serve: a tutti.' }
    It "Unisce le righe di un paragrafo con la riga iniziale" {
        $paragraph = $section.Blocks | Where-Object Kind -EQ 'paragraph' | Select-Object -First 1
        $paragraph.Text | Should -Be 'Prima riga seconda riga.'
        $paragraph.Line | Should -Be 7
    }
    It "Tiene ogni voce di elenco come blocco" { @($section.Blocks | Where-Object Kind -EQ 'list').Count | Should -Be 2 }
    It "Distingue le tabelle" { @($section.Blocks | Where-Object Kind -EQ 'table').Count | Should -Be 1 }
    It "Raccoglie i marcatori di vista" { $section.Views | Should -Be @('contesto') }
    It "Raccoglie i diagrammi Mermaid con la riga del recinto" {
        $section.Diagrams[0].Line | Should -Be 16
        $section.Diagrams[0].Text | Should -Be 'sequenceDiagram'
    }
    It "Ricorda la parte che contiene il diagramma" { $section.Diagrams[0].Part | Should -Be 'In breve' }
    It "Un diagramma prima della prima parte non ha parte" {
        (ConvertFrom-MarkdownSection "# Titolo`n`n``````mermaid`nsequenceDiagram`n```````n").Diagrams[0].Part | Should -BeNullOrEmpty
    }
}

Describe "MarkdownText — sezioni di un documento" {

    BeforeAll {
        $directory = Join-Path ([IO.Path]::GetTempPath()) "pester-sections-$(New-Guid)"
        New-Item -ItemType Directory -Path "$directory/model" | Out-Null
        [IO.File]::WriteAllText("$directory/02-uso.md", "# Uso`n")
        [IO.File]::WriteAllText("$directory/01-introduzione.md", "# Introduzione`n")
        [IO.File]::WriteAllText("$directory/note.md", "Testo senza titolo.`n")
        [IO.File]::WriteAllText("$directory/model/workspace.dsl", "workspace {}`n")
        [IO.File]::WriteAllText("$directory/model/legenda.md", "# Legenda`n")
        $sections = Get-DocumentSections $directory
    }

    AfterAll {
        Remove-Item -Recurse -Force $directory -ErrorAction SilentlyContinue
    }

    It "Sono i file Markdown della cartella, senza sottocartelle, in ordine di nome" {
        $sections.File.Name | Should -Be @('01-introduzione.md', '02-uso.md', 'note.md')
    }

    It "Si nominano con il titolo" { $sections[0].Title | Should -Be 'Introduzione' }

    It "Senza titolo si nominano con il file" { $sections[2].Title | Should -Be 'note.md' }

    It "Una cartella che non esiste non ha sezioni" {
        @(Get-DocumentSections (Join-Path $directory 'assente')).Count | Should -Be 0
    }
}
