#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Pandoc/Pandoc.ps1

.DESCRIPTION
    Lo scaricamento e' un Invoke-WebRequest finto che scrive un archivio costruito dal test, nel formato
    del sistema operativo che esegue la prova; pandoc e' uno script finto che registra argomenti e
    SOURCE_DATE_EPOCH. Nessuna prova scarica dalla rete.
#>

BeforeAll {
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/Pandoc/Pandoc.ps1"

    function New-PandocArchive([string]$Directory) {
        $archive = Get-PandocArchive
        $content = Join-Path $Directory 'content'
        $executable = Join-Path $content $archive.Executable
        New-Item -ItemType Directory -Force -Path (Split-Path $executable) | Out-Null
        [IO.File]::WriteAllText($executable, 'pandoc finto')
        $path = Join-Path $Directory $archive.Name
        if ($archive.Name.EndsWith('.zip')) { Compress-Archive -Path (Join-Path $content '*') -DestinationPath $path }
        else { tar -czf $path -C $content . }
        return $path
    }

    function New-FakePandoc([string]$Directory, [int]$ExitCode) {
        $script = Join-Path $Directory 'pandoc.ps1'
        $record = Join-Path $Directory 'record.txt'
        [IO.File]::WriteAllText($script, "[IO.File]::WriteAllText('$record', `"`$env:SOURCE_DATE_EPOCH|`$(`$args -join ' ')`"); Write-Output 'avviso di pandoc'; exit $ExitCode")
        return [pscustomobject]@{ Path = $script; Record = $record }
    }
}

Describe 'pandoc fissato alla versione e allo SHA-256 dello script' {

    BeforeEach {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-pandoc-$(New-Guid)"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $previousTools = $env:AGENT_TOOLSDIRECTORY
        $previousPath = $env:PANDOC_PATH
        $env:AGENT_TOOLSDIRECTORY = Join-Path $root 'tools'
        $env:PANDOC_PATH = $null
        $originalHash = (Get-PandocArchive).Sha256
    }

    AfterEach {
        (Get-PandocArchive).Sha256 = $originalHash
        $env:AGENT_TOOLSDIRECTORY = $previousTools
        $env:PANDOC_PATH = $previousPath
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }

    It 'usa il pandoc indicato da PANDOC_PATH senza scaricare' {
        Mock Invoke-WebRequest { throw 'nessuno scaricamento atteso' }
        $env:PANDOC_PATH = '/opt/pandoc/bin/pandoc'
        Get-Pandoc | Should -Be '/opt/pandoc/bin/pandoc'
        Should -Invoke Invoke-WebRequest -Times 0
    }

    It "scarica l'archivio della release, ne verifica lo SHA-256 e lo estrae una volta sola" {
        $fakeArchive = New-PandocArchive $root
        (Get-PandocArchive).Sha256 = (Get-FileHash $fakeArchive -Algorithm SHA256).Hash
        Mock Invoke-WebRequest { Copy-Item $fakeArchive $OutFile } -ParameterFilter { $Uri -eq "https://github.com/jgm/pandoc/releases/download/$PandocVersion/$((Get-PandocArchive).Name)" }
        $pandoc = Get-Pandoc
        [IO.File]::ReadAllText($pandoc) | Should -Be 'pandoc finto'
        Get-Pandoc | Should -Be $pandoc
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Get-ChildItem (Split-Path $pandoc) -Filter (Get-PandocArchive).Name -Recurse | Should -BeNullOrEmpty
    }

    It 'rifiuta un archivio con uno SHA-256 diverso e non lo tiene' {
        $fakeArchive = New-PandocArchive $root
        Mock Invoke-WebRequest { Copy-Item $fakeArchive $OutFile }
        { Get-Pandoc } | Should -Throw "Checksum di $((Get-PandocArchive).Name) non valido*"
        Get-ChildItem $env:AGENT_TOOLSDIRECTORY -Recurse -File | Should -BeNullOrEmpty
    }
}

Describe 'Conversione con pandoc' {

    BeforeEach {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-pandoc-$(New-Guid)"
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $previousPath = $env:PANDOC_PATH
        $previousEpoch = $env:SOURCE_DATE_EPOCH
        $env:SOURCE_DATE_EPOCH = '42'
    }

    AfterEach {
        $env:PANDOC_PATH = $previousPath
        $env:SOURCE_DATE_EPOCH = $previousEpoch
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }

    It 'passa ingresso, uscita e argomenti, con la data della fonte, e poi ripristina SOURCE_DATE_EPOCH' {
        $fake = New-FakePandoc $root 0
        $env:PANDOC_PATH = $fake.Path
        Invoke-Pandoc 'documento.md' 'documento.docx' @('--toc', '--number-sections') 1700000000
        [IO.File]::ReadAllText($fake.Record) | Should -Be '1700000000|documento.md -o documento.docx --toc --number-sections'
        $env:SOURCE_DATE_EPOCH | Should -Be '42'
        $LASTEXITCODE | Should -Be 0
    }

    It "fallisce con l'uscita di pandoc quando la conversione non riesce" {
        $env:PANDOC_PATH = (New-FakePandoc $root 3).Path
        { Invoke-Pandoc 'documento.md' 'documento.docx' @() 0 } | Should -Throw 'pandoc non converte documento.md: avviso di pandoc'
        $env:SOURCE_DATE_EPOCH | Should -Be '42'
    }
}
