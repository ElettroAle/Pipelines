#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Publish-Arc42Wiki.ps1

.DESCRIPTION
    Il documento e' quello valido della fixture condivisa. La wiki e' un repository git locale con
    un origin bare sul ramo wikiMaster, gia' popolato con le release note e una pagina che la
    pubblicazione non possiede. Lo script gira come in pipeline: richiede Java 17 o successivo per
    esportare e disegnare le viste C4 (STRUCTURIZR_JAVA, JAVA_HOME_17_X64 o JAVA_HOME). PLANTUML_JAR
    evita lo scaricamento di PlantUML.
#>

BeforeAll {
    . "$PSScriptRoot/../fixtures/documentation/DocumentationFixture.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Publish-Arc42Wiki.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-arc42-wiki-$(New-Guid)"
    $ReleaseNotes = "# AI`n`n## 1.2.0`n`n- Nuova funzione`n"
    $ReleaseNotesImage = 'immagine delle release note'
    $PngSignature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    function Invoke-Git([string]$Directory) {
        $output = git -C $Directory @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
        return $output
    }

    function Set-WikiFile([string]$Directory, [string]$Path, [string]$Content) {
        $file = Join-Path $Directory $Path
        New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
        [IO.File]::WriteAllText($file, $Content)
    }

    function Add-WikiCommit([string]$Directory, [string]$Message) {
        Invoke-Git $Directory add -A | Out-Null
        Invoke-Git $Directory -c user.name=Wiki -c user.email=wiki@example.org commit -q -m $Message | Out-Null
        Invoke-Git $Directory push -q origin HEAD:refs/heads/wikiMaster | Out-Null
    }

    # Una wiki di progetto come quella reale: le release note con il loro ordine e una pagina
    # che la pubblicazione non possiede.
    function New-Wiki {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-wiki-$(New-Guid)"
        $origin = Join-Path $root 'origin.git'
        $seed = Join-Path $root 'seed'
        git init -q --bare -b wikiMaster $origin
        git clone -q $origin $seed 2>&1 | Out-Null
        Invoke-Git $seed checkout -q -b wikiMaster | Out-Null
        Set-WikiFile $seed '.order' "Release-notes`n"
        Set-WikiFile $seed 'Release-notes.md' "[[_TOSP_]]`n"
        Set-WikiFile $seed 'Release-notes/.order' "AI`n"
        Set-WikiFile $seed 'Release-notes/AI.md' $ReleaseNotes
        Set-WikiFile $seed 'Indice.md' "# Indice`n"
        Set-WikiFile $seed '.attachments/release-notes.png' $ReleaseNotesImage
        Add-WikiCommit $seed 'Release notes'
        $checkout = Join-Path $root 'checkout'
        git clone -q -b wikiMaster $origin $checkout 2>&1 | Out-Null
        return [pscustomobject]@{ Root = $root; Origin = $origin; Seed = $seed; Checkout = $checkout }
    }

    function Invoke-WikiPublish([System.Collections.IDictionary]$Docs, $Wiki, [string]$Language = '') {
        return Invoke-DocsScript $ScriptPath $Docs @{
            DOCUMENT_LANGUAGE     = $Language
            WIKI_DIRECTORY        = $Wiki.Checkout
            SYSTEM_COLLECTIONURI  = 'https://dev.azure.com/Org/'
            SYSTEM_TEAMPROJECT    = 'Progetto'
            BUILD_REPOSITORY_NAME = 'Architettura.Repo'
            BUILD_SOURCEVERSION   = '0123456789abcdef'
            SYSTEM_ACCESSTOKEN    = ''
        }
    }

    # Lo stato della wiki come lo vede chi la apre: l'ultimo commit di wikiMaster nell'origin.
    function Get-WikiPage($Wiki, [string]$Path) {
        $content = git -C $Wiki.Origin show "wikiMaster:$Path" 2>$null
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $null }
        return ($content -join "`n")
    }

    # I byte si leggono da un clone: su Linux PowerShell ridirige l'uscita di un processo come
    # testo e rompe un file binario.
    function Get-WikiFileBytes($Wiki, [string]$Path) {
        $clone = Join-Path $Wiki.Root "read-$(New-Guid)"
        git clone -q -b wikiMaster $Wiki.Origin $clone 2>&1 | Out-Null
        $file = Join-Path $clone $Path
        if (-not (Test-Path -LiteralPath $file)) { return $null }
        return [IO.File]::ReadAllBytes($file)
    }

    function Test-Png([byte[]]$Bytes) {
        return $Bytes.Count -gt $PngSignature.Count -and -not (Compare-Object ($Bytes | Select-Object -First $PngSignature.Count) $PngSignature)
    }

    function Get-WikiCommitCount($Wiki) {
        return [int](git -C $Wiki.Origin rev-list --count wikiMaster)
    }

    function Add-DecisionIndex([System.Collections.IDictionary]$Docs) {
        Edit-Docs $Docs 'docs/architecture/09_architecture_decisions.md' 'La decisione [0001-esempio]' "| Decisione | Scelta |`n|---|---|`n| [0001](../decisions/0001-esempio.md) | Il BFF come unico ingresso |`n`nLa decisione [0001-esempio]"
    }
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}


Describe "Funzionalità: Documentazione architetturale nella wiki" {

    Context "Scenario: wiki allineata a main" {
        BeforeAll {
            $wiki = New-Wiki
            $res = Invoke-WikiPublish (New-ValidDocs) $wiki
            $order = Get-WikiPage $wiki 'Architettura/.order'
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora la pubblicazione riesce" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
        }

        It "E ogni sezione e' una pagina sotto Architettura, nell'ordine dei numeri" {
            ($order -split "`n") | Should -Be @(
                '1.-Introduzione-e-obiettivi', '2.-Vincoli-di-architettura', '3.-Ambito-e-contesto-del-sistema',
                '4.-Strategia-della-soluzione', '5.-Building-Block-View', '6.-Runtime-View', '7.-Deployment-View',
                '8.-Concetti-trasversali', '9.-Decisioni-di-progettazione', '10.-Requisiti-di-Qualità',
                '11.-Rischi-e-debiti-tecnici', '12.-Glossario')
        }

        It "E la pagina Architettura elenca le sue sottopagine" {
            Get-WikiPage $wiki 'Architettura.md' | Should -Be '[[_TOSP_]]'
        }

        It "E la pagina mostra il testo della sezione senza ripeterne il titolo" {
            $page = Get-WikiPage $wiki 'Architettura/2.-Vincoli-di-architettura.md'
            $page | Should -Match 'La piattaforma gira su Azure'
            $page | Should -Not -Match '(?m)^# Vincoli di architettura'
        }
    }

    Context "Scenario: una sezione tolta dal documento sparisce dalla wiki" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            $null = Invoke-WikiPublish $docs $wiki
            $docs['docs/architecture/11_technical_risks.md'] = $null
            $res = Invoke-WikiPublish $docs $wiki
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora la pagina della sezione non c'e' piu'" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-WikiPage $wiki 'Architettura/11.-Rischi-e-debiti-tecnici.md' | Should -BeNullOrEmpty
        }

        It "E l'ordine non la elenca" {
            Get-WikiPage $wiki 'Architettura/.order' | Should -Not -Match 'Rischi'
        }
    }

    Context "Schema dello scenario: diagrammi C4 disegnati nella wiki — <vista>" -ForEach @(
        @{ vista = 'contesto (C4 livello 1)'; pagina = 'Architettura/3.-Ambito-e-contesto-del-sistema.md'; chiave = 'contesto' }
        @{ vista = 'container (C4 livello 2)'; pagina = 'Architettura/5.-Building-Block-View.md'; chiave = 'contenitori' }
        @{ vista = 'componenti del Worker (livello 3)'; pagina = 'Architettura/5.-Building-Block-View.md'; chiave = 'componenti-worker' }
        @{ vista = 'deployment di produzione'; pagina = 'Architettura/7.-Deployment-View.md'; chiave = 'deployment-produzione' }
    ) {
        BeforeAll {
            $wiki = New-Wiki
            $res = Invoke-WikiPublish (New-ValidDocs) $wiki
            $page = Get-WikiPage $wiki $pagina
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora la pagina mostra l'immagine della vista" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $page | Should -Match ([regex]::Escape("![$chiave](/.attachments/Architettura/$chiave.png)"))
        }

        It "E l'immagine e' il diagramma disegnato in PNG" {
            Test-Png (Get-WikiFileBytes $wiki ".attachments/Architettura/$chiave.png") | Should -BeTrue
        }

        It "E la pagina non mostra il marcatore" {
            $page | Should -Not -Match '<!-- vista:'
        }
    }

    Context "Scenario: diagramma Mermaid disegnato nella wiki" {
        BeforeAll {
            $wiki = New-Wiki
            $res = Invoke-WikiPublish (New-ValidDocs) $wiki
            $page = Get-WikiPage $wiki 'Architettura/6.-Runtime-View.md'
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora la pagina mostra il diagramma nella sintassi della wiki" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $page | Should -Match '(?m)^::: mermaid\n\s*sequenceDiagram'
        }

        It "E non il blocco Markdown" {
            $page | Should -Not -Match '```mermaid'
        }
    }

    Context "Scenario: un documento senza viste C4" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            foreach ($path in @($docs.Keys)) {
                if ($docs[$path] -is [string]) { $docs[$path] = $docs[$path] -replace '(?m)^<!-- vista: [\w-]+ -->\r?\n', '' }
            }
            $res = Invoke-WikiPublish $docs $wiki
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora la pubblicazione riesce" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-WikiPage $wiki 'Architettura.md' | Should -Be '[[_TOSP_]]'
        }

        It "E nessuna immagine nasce sotto Architettura" {
            git -C $wiki.Origin ls-tree -r --name-only wikiMaster -- .attachments/Architettura | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: una vista tolta dal documento perde la sua immagine" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            $null = Invoke-WikiPublish $docs $wiki
            Edit-Docs $docs 'docs/architecture/07_deployment_view.md' '<!-- vista: deployment-produzione -->' ''
            $res = Invoke-WikiPublish $docs $wiki
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora l'immagine della vista non c'e' piu'" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-WikiFileBytes $wiki '.attachments/Architettura/deployment-produzione.png' | Should -BeNullOrEmpty
        }

        It "E le immagini delle viste ancora mostrate restano" {
            Test-Png (Get-WikiFileBytes $wiki '.attachments/Architettura/contesto.png') | Should -BeTrue
        }
    }

    Context "Scenario: decisione nell'indice" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            Add-DecisionIndex $docs
            $res = Invoke-WikiPublish $docs $wiki
            $index = Get-WikiPage $wiki 'Architettura/9.-Decisioni-di-progettazione.md'
            $decision = Get-WikiPage $wiki 'Architettura/9.-Decisioni-di-progettazione/0001-Esempio.md'
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora l'indice elenca la decisione con il suo stato" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $index | Should -Match '\| Decisione \| Scelta \| Stato \|'
            $index | Should -Match '\| \[0001\]\(/Architettura/9\.-Decisioni-di-progettazione/0001-Esempio\)\s*\| Il BFF come unico ingresso \| accettata \|'
        }

        It "E la decisione e' una sottopagina della sezione 9" {
            $decision | Should -Not -BeNullOrEmpty
            Get-WikiPage $wiki 'Architettura/9.-Decisioni-di-progettazione/.order' | Should -Be '0001-Esempio'
        }

        It "E la pagina della decisione non mostra i suoi metadati" {
            $decision | Should -Not -Match 'status:'
        }
    }

    Context "Scenario: nomi delle pagine leggibili" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            Edit-Docs $docs 'docs/architecture/05_building_block_view.md' '# Building Block View' '# *Building Block View*'
            Edit-Docs $docs 'docs/decisions/0001-esempio.md' '# Esempio' "# Il BFF e' l'unico ingresso del Client per ogni richiesta che arriva dal browser"
            $res = Invoke-WikiPublish $docs $wiki
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora il nome della pagina di una sezione e' il suo titolo in testo semplice" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-WikiPage $wiki 'Architettura/5.-Building-Block-View.md' | Should -Not -BeNullOrEmpty
            Get-WikiPage $wiki 'Architettura/.order' | Should -Not -Match '%2A'
        }

        It "E il nome della pagina di una decisione viene dal nome del suo file, non dal titolo" {
            Get-WikiPage $wiki 'Architettura/9.-Decisioni-di-progettazione/.order' | Should -Be '0001-Esempio'
        }
    }

    Context "Scenario: i link portano alle pagine della wiki" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            Edit-Docs $docs 'docs/architecture/02_architecture_constraints.md' 'La piattaforma gira su Azure.' 'La piattaforma gira su Azure, come dice la [guida](../STYLE.md).'
            $res = Invoke-WikiPublish $docs $wiki
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora un link a un'altra sezione porta alla sua pagina, con l'ancora" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-WikiPage $wiki 'Architettura/9.-Decisioni-di-progettazione.md' | Should -Match ([regex]::Escape('[vista dei building block](/Architettura/5.-Building-Block-View#in-breve)'))
        }

        It "E un link a una decisione porta alla sua pagina" {
            Get-WikiPage $wiki 'Architettura/9.-Decisioni-di-progettazione.md' | Should -Match ([regex]::Escape('[0001-esempio](/Architettura/9.-Decisioni-di-progettazione/0001-Esempio)'))
        }

        It "E un link a un file non pubblicato porta al file nel repository" {
            Get-WikiPage $wiki 'Architettura/2.-Vincoli-di-architettura.md' | Should -Match ([regex]::Escape('[guida](https://dev.azure.com/Org/Progetto/_git/Architettura.Repo?path=/docs/STYLE.md)'))
        }
    }

    Context "Scenario: il resto della wiki resta com'e'" {
        BeforeAll {
            $wiki = New-Wiki
            $res = Invoke-WikiPublish (New-ValidDocs) $wiki
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora le release note non cambiano" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-WikiPage $wiki 'Release-notes/AI.md' | Should -Be $ReleaseNotes.TrimEnd("`n")
            Get-WikiPage $wiki 'Release-notes/.order' | Should -Be 'AI'
        }

        It "E una pagina che la pubblicazione non possiede resta" {
            Get-WikiPage $wiki 'Indice.md' | Should -Be '# Indice'
        }

        It "E un allegato che la pubblicazione non possiede resta" {
            Get-WikiPage $wiki '.attachments/release-notes.png' | Should -Be $ReleaseNotesImage
        }

        It "E l'ordine della radice aggiunge Architettura in testa, senza togliere le altre voci" {
            Get-WikiPage $wiki '.order' | Should -Be "Architettura`nRelease-notes"
        }
    }

    Context "Scenario: la wiki e' cambiata dopo il checkout" {
        BeforeAll {
            $wiki = New-Wiki
            Set-WikiFile $wiki.Seed 'Release-notes/AI.md' "# AI`n`n## 1.3.0`n"
            Add-WikiCommit $wiki.Seed 'Release notes 1.3.0'
            $res = Invoke-WikiPublish (New-ValidDocs) $wiki
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora il documento si pubblica sopra il commit nuovo" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-WikiPage $wiki 'Architettura.md' | Should -Be '[[_TOSP_]]'
        }

        It "E le release note nuove restano" {
            Get-WikiPage $wiki 'Release-notes/AI.md' | Should -Match '1\.3\.0'
        }
    }

    Context "Scenario: la wiki mostra gia' il documento" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            $null = Invoke-WikiPublish $docs $wiki
            $commits = Get-WikiCommitCount $wiki
            $res = Invoke-WikiPublish $docs $wiki
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora nessun commit nuovo" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-WikiCommitCount $wiki | Should -Be $commits
        }

        It "E il registro lo dice" {
            $res.Output | Should -Match "La wiki mostra gia' il documento"
        }
    }

    Context "Scenario: un marcatore rivolto a una vista che il modello non ha" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            Edit-Docs $docs 'docs/architecture/03_context_and_scope.md' '<!-- vista: contesto -->' '<!-- vista: inesistente -->'
            $commits = Get-WikiCommitCount $wiki
            $res = Invoke-WikiPublish $docs $wiki
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora la pubblicazione fallisce e nomina la vista" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Should -Match 'la vista inesistente non esiste nel modello C4'
        }

        It "E la wiki non cambia" {
            Get-WikiCommitCount $wiki | Should -Be $commits
        }
    }

    Context "Scenario: documento in inglese" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = ConvertTo-EnglishConventions (New-ValidDocs)
            Add-DecisionIndex $docs
            $res = Invoke-WikiPublish $docs $wiki 'EN'
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora il documento nasce sotto Architecture" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            Get-WikiPage $wiki 'Architecture.md' | Should -Be '[[_TOSP_]]'
            Get-WikiPage $wiki '.order' | Should -Be "Architecture`nRelease-notes"
        }

        It "E l'indice delle decisioni ha la colonna Status" {
            Get-WikiPage $wiki 'Architecture/9.-Decisioni-di-progettazione.md' | Should -Match '\| Decisione \| Scelta \| Status \|[\s\S]*\| accepted \|'
        }

        It "E il marcatore view diventa l'immagine del diagramma" {
            $page = Get-WikiPage $wiki 'Architecture/3.-Ambito-e-contesto-del-sistema.md'
            $page | Should -Match ([regex]::Escape('![contesto](/.attachments/Architecture/contesto.png)'))
            $page | Should -Not -Match '<!-- view:'
            Test-Png (Get-WikiFileBytes $wiki '.attachments/Architecture/contesto.png') | Should -BeTrue
        }
    }
}
