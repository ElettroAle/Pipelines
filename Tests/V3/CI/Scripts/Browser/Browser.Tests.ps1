#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Browser/Browser.ps1

.DESCRIPTION
    Richiede Node.js. mermaid-cli, puppeteer e Chrome headless si installano alla prima esecuzione nella
    cache di AGENT_TOOLSDIRECTORY, come in pipeline.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Browser/Browser.ps1"
    . "$PSScriptRoot/../Arc42/Fixtures/DocumentReaders.ps1"
    $PngSignature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    $root = Join-Path ([IO.Path]::GetTempPath()) "pester-browser-$(New-Guid)"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $html = Join-Path $root 'documento.html'
    [IO.File]::WriteAllText($html, "<!doctype html><html><head><meta charset='utf-8'><title>Documento</title></head><body><h1 id='uno'>Uno</h1><p>Testo con il <a href='https://example.org/'>link</a> e il <a href='#uno'>rimando</a>.</p></body></html>")
}

AfterAll {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Describe 'Diagrammi Mermaid disegnati con Chrome headless' {

    It 'disegna ogni diagramma in un PNG, con il suo id' {
        $images = ConvertTo-MermaidPng @(
            [pscustomobject]@{ Id = 'mermaid-1'; Text = "sequenceDiagram`n    participant a as BFF`n    participant b as API del Motore`n    a->>b: apre la sessione" }
            [pscustomobject]@{ Id = 'mermaid-2'; Text = "flowchart LR`n    a --> b" }
        )
        @($images.Keys | Sort-Object) | Should -Be @('mermaid-1', 'mermaid-2')
        foreach ($png in $images.Values) { [byte[]]($png | Select-Object -First 8) | Should -Be $PngSignature }
        (Get-PngDimensions $images['mermaid-1']).Width | Should -BeGreaterThan 0
    }

    It 'nomina il diagramma che non si disegna' {
        { ConvertTo-MermaidPng @([pscustomobject]@{ Id = 'mermaid-7'; Text = "sequenceDiagram`n    a->>: manca il destinatario" }) } | Should -Throw '*diagramma mermaid-7*'
    }

    It 'non apre Chrome senza diagrammi' {
        Mock Invoke-BrowserRenderer { throw 'Chrome non atteso' }
        (ConvertTo-MermaidPng @()).Count | Should -Be 0
    }
}

Describe "Stampa in PDF dell'HTML" {

    It "stampa l'HTML con i link e il segnalibro del titolo" {
        $pdf = Read-PdfDocument (ConvertTo-PdfFromHtml $html ([DateTimeOffset]::FromUnixTimeSeconds(0)))
        $pdf.Links | Should -Be @('https://example.org/')
        $pdf.Outline | Should -Contain 'Uno'
        ($pdf.Text -replace '\s+', '') | Should -Match 'Testoconillinkeilrimando'
    }

    It 'scrive la data della fonte al posto di quella della stampa, e la stessa fonte da la stessa stampa' {
        $date = [DateTimeOffset]::FromUnixTimeSeconds(1700000000)
        $first = ConvertTo-PdfFromHtml $html $date
        $second = ConvertTo-PdfFromHtml $html $date
        $text = [Text.Encoding]::Latin1.GetString($first)
        $text | Should -Match ([regex]::Escape("/CreationDate (D:20231114221320+00'00')"))
        $text | Should -Match ([regex]::Escape("/ModDate (D:20231114221320+00'00')"))
        [Convert]::ToHexString($second) | Should -Be ([Convert]::ToHexString($first))
    }

    It 'fallisce con il messaggio di Chrome quando la stampa non riesce' {
        { ConvertTo-PdfFromHtml (Join-Path $root 'manca.html') ([DateTimeOffset]::FromUnixTimeSeconds(0)) } | Should -Throw 'Chrome headless non completa pdf*'
    }
}

Describe 'Cache di Chrome headless' {

    It 'riscarica Chrome quando un download interrotto ha lasciato la cartella senza eseguibile' {
        $previous = $env:AGENT_TOOLSDIRECTORY
        $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-browser-tools-$(New-Guid)"
        try {
            $installDir = Get-BrowserRendererDirectory
            Get-ChildItem -Path (Join-Path $installDir 'browsers') -Recurse -File -Filter 'chrome-headless-shell*' | Remove-Item -Force
            Remove-Item -Force (Join-Path $installDir 'installed')

            { Get-BrowserRendererDirectory } | Should -Not -Throw

            Get-ChildItem -Path (Join-Path $installDir 'browsers') -Recurse -File -Filter 'chrome-headless-shell*' | Should -Not -BeNullOrEmpty
        }
        finally {
            Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
            $env:AGENT_TOOLSDIRECTORY = $previous
        }
    }
}
