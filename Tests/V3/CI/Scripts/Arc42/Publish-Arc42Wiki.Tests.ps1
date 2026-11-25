#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Arc42/Publish-Arc42Wiki.ps1

.DESCRIPTION
    Il documento e' quello valido della fixture condivisa. La wiki e' un repository git locale con
    un origin bare sul ramo wikiMaster, gia' popolato con le release note e una pagina che la
    pubblicazione non possiede. Lo script gira come in pipeline: richiede Java 17 o successivo per
    esportare e disegnare le viste C4 (STRUCTURIZR_JAVA, JAVA_HOME_17_X64 o JAVA_HOME). PLANTUML_JAR
    evita lo scaricamento di PlantUML. Il documento in PDF e Word richiede Node.js per Chrome headless;
    PANDOC_PATH evita lo scaricamento di pandoc.
#>

BeforeAll {
    . "$PSScriptRoot/../Common/Fixtures/Documentation/DocumentationFixture.ps1"
    . "$PSScriptRoot/Fixtures/DocumentReaders.ps1"
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../../../../V3/CI/Scripts/Arc42/Publish-Arc42Wiki.ps1"
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

    function Invoke-WikiPublish([System.Collections.IDictionary]$Docs, $Wiki, [string]$Language = '', [string]$Formats = '') {
        return Invoke-DocsScript $ScriptPath $Docs @{
            DOCUMENT_FORMATS      = $Formats
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
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
        try { $content = git -C $Wiki.Origin show "wikiMaster:$Path" 2>$null }
        finally { [Console]::OutputEncoding = $previousEncoding }
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

    # Il titolo e la riga dei vicini che Export-C4CodeModel.ps1 scrive in una vista generata.
    function Add-ViewCaption([System.Collections.IDictionary]$Docs) {
        Edit-Docs $Docs 'docs/architecture/c4/workspace.dsl' 'deployment sistema produzione "deployment-produzione" {' "deployment sistema produzione `"deployment-produzione`" `"Comunica con:\nAzure (inoltra)`" {`n            title `"Produzione, nodo Azure`""
    }

    # Una vista di allocazione come la scrive Export-C4CodeModel.ps1: la frase dello scopo, la proprieta' con
    # gli ambienti di cui elencare i gruppi di risorse e gli elementi con il gruppo, il modulo che li dichiara e il
    # nome Azure. Il private endpoint si chiama nella vista con la parte che raggiunge.
    function Add-ResourceGroupView([System.Collections.IDictionary]$Docs) {
        $placement = {
            param($Group, $Module, $AzureName)
            $lines = @('properties {', "`"resourceGroup`" `"$Group`"", "`"module`" `"$Module`"") + @(if ($AzureName) { "`"azureName`" `"$AzureName`"" })
            ($lines + '}') -join "`n"
        }
        Edit-Docs $Docs 'docs/architecture/c4/workspace.dsl' 'containerInstance client' (@(
                'deploymentNode "Piano del client" {', (& $placement 'rg-web' 'Client' 'asp-web-prod'), "containerInstance client {`n$(& $placement 'rg-web' 'Client' 'app-client-prod')`n}", '}'
                "infrastructureNode `"Client`" {`n$(& $placement 'rg-hub' 'Hub' 'pe-client-prod')`n}"
                "infrastructureNode `"kv-a|b`" {`n$(& $placement 'rg-dati' 'Platform' 'kv-a|b')`n}"
                "infrastructureNode `"Senza nome Azure`" {`n$(& $placement 'rg-vuoto' 'Platform' '')`n}"
            ) -join "`n")
        Edit-Docs $Docs 'docs/architecture/c4/workspace.dsl' 'deployment sistema produzione "deployment-produzione" {' "deployment sistema produzione `"deployment-produzione`" `"Dove gira ogni applicazione dell'ambiente.`" {`n            title `"Allocazione · Produzione`"`n            properties {`n                `"resourceGroups`" `"Produzione`"`n            }"
    }
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

    Context "Scenario: viste dei componenti disegnate da un solo marcatore" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            Edit-Docs $docs 'docs/architecture/05_building_block_view.md' "<!-- vista: componenti-client -->`n<!-- vista: componenti-bff -->`n<!-- vista: componenti-motore -->`n<!-- vista: componenti-worker -->" '<!-- vista: component* -->'
            $res = Invoke-WikiPublish $docs $wiki
            $page = Get-WikiPage $wiki 'Architettura/5.-Building-Block-View.md'
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora la pagina mostra l'immagine di ogni vista dei componenti, in ordine di chiave" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $images = [regex]::Matches($page, '!\[(componenti-[\w-]+)\]') | ForEach-Object { $_.Groups[1].Value }
            $images | Should -Be @('componenti-bff', 'componenti-client', 'componenti-motore', 'componenti-worker')
        }

        It "E la pagina non mostra il marcatore" {
            $page | Should -Not -Match '<!-- vista:'
        }
    }

    Context "Scenario: ogni vista ha un titolo suo, fatto dai nomi delle parti che mostra, e una riga che nomina le parti con cui comunica; nel documento titolo e riga accompagnano l'immagine" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            Add-ViewCaption $docs
            $res = Invoke-WikiPublish $docs $wiki
            $page = Get-WikiPage $wiki 'Architettura/7.-Deployment-View.md'
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora nella pagina il titolo della vista, in grassetto, e la riga dei vicini precedono l'immagine (ADR-2113)" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $page | Should -Match ([regex]::Escape("**Produzione, nodo Azure**`n`nComunica con: Azure (inoltra)`n`n![Produzione, nodo Azure](/.attachments/Architettura/deployment-produzione.png)"))
        }

        It "E una vista senza titolo resta l'immagine con la chiave come testo alternativo (ADR-2113)" {
            $building = Get-WikiPage $wiki 'Architettura/5.-Building-Block-View.md'
            $building | Should -Match ([regex]::Escape('![contenitori](/.attachments/Architettura/contenitori.png)'))
            $building | Should -Not -Match '\*\*\n\n!\[contenitori\]'
        }
    }

    Context "Scenario: i gruppi di risorse stanno in una tabella generata nel testo, con il contenuto e il modulo che li dichiara; la frase dello scopo accompagna l'immagine" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            Add-ResourceGroupView $docs
            $res = Invoke-WikiPublish $docs $wiki
            $page = Get-WikiPage $wiki 'Architettura/7.-Deployment-View.md'
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora sotto l'immagine della vista una tabella elenca per gruppo di risorse il contenuto e il modulo, in ordine di nome" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $page | Should -Match ([regex]::Escape((@(
                            '![Allocazione · Produzione](/.attachments/Architettura/deployment-produzione.png)', ''
                            '| Gruppo di risorse | Contenuto | Modulo |', '| --- | --- | --- |'
                            '| rg-dati | kv-a\|b | Platform |', '| rg-hub | pe-client-prod | Hub |', '| rg-web | app-client-prod, asp-web-prod | Client |'
                        ) -join "`n")))
        }

        It "E la frase dello scopo della vista precede l'immagine" {
            $page | Should -Match ([regex]::Escape("**Allocazione · Produzione**`n`nDove gira ogni applicazione dell'ambiente.`n`n![Allocazione"))
        }

        It "E una vista senza la proprieta' dei gruppi di risorse non ha la tabella" {
            Get-WikiPage $wiki 'Architettura/5.-Building-Block-View.md' | Should -Not -Match 'Gruppo di risorse'
        }
    }

    Context "Scenario: la tabella elenca le risorse con il loro nome Azure, per gruppo di risorse e modulo" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            Add-ResourceGroupView $docs
            $res = Invoke-WikiPublish $docs $wiki
            $rows = @((Get-WikiPage $wiki 'Architettura/7.-Deployment-View.md') -split "`n" | Where-Object { $_ -match '^\| rg-' })
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora il gruppo dell'Hub elenca il private endpoint con il suo nome Azure, non con la parte che raggiunge" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $rows | Should -Contain '| rg-hub | pe-client-prod | Hub |'
        }

        It "E un'istanza compare con il nome Azure della risorsa che la ospita, non con il nome dell'applicazione" {
            $rows | Should -Contain '| rg-web | app-client-prod, asp-web-prod | Client |'
        }

        It "E un nodo senza nome Azure non entra nella tabella" {
            @($rows | Where-Object { $_ -match 'rg-vuoto' }) | Should -BeNullOrEmpty
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

    Context "Scenario: la prima menzione di una voce della reference porta alla sua pagina" {
        BeforeAll {
            $wiki = New-Wiki
            Set-WikiFile $wiki.Seed '.attachments/Reference/reference-index.json' '{"entries":[{"kind":"api","name":"BFF","url":"https://wiki/Reference/API/BFF"}]}'
            Add-WikiCommit $wiki.Seed 'Reference'
            Invoke-Git $wiki.Checkout pull -q origin wikiMaster | Out-Null
            $docs = New-ValidDocs
            $docs['docs/architecture/c4/workspace.dsl'] = $null
            foreach ($path in @($docs.Keys)) {
                if ($docs[$path] -is [string]) { $docs[$path] = $docs[$path] -replace '(?m)^<!-- vista: [\w-]+\*? -->\r?\n', '' }
            }
            $previousReferenceRoot = $env:REFERENCE_ROOT
            $env:REFERENCE_ROOT = 'Reference'
            try { $res = Invoke-WikiPublish $docs $wiki }
            finally { $env:REFERENCE_ROOT = $previousReferenceRoot }
            $page = Get-WikiPage $wiki 'Architettura/1.-Introduzione-e-obiettivi.md'
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora la prima menzione diventa un link alla pagina della reference" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            $page | Should -Match ([regex]::Escape('([BFF](https://wiki/Reference/API/BFF))'))
        }

        It "E le menzioni successive restano testo" {
            ([regex]::Matches($page, [regex]::Escape('](https://wiki/Reference/API/BFF)'))).Count | Should -Be 1
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
            Edit-Docs $docs 'docs/decisions/0001-esempio.md' "status: accepted`n" "status: accepted`nversion: 2`ndate: 2026-10-25`n"
            Edit-Docs $docs 'docs/decisions/0001-esempio.md' "# Esempio`n" "# Esempio`n`nIl BFF e' l'unico ingresso.`n"
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
            $decision | Should -Be "Il BFF e' l'unico ingresso."
        }
    }

    Context "Scenario: decisione sostituita" {
        BeforeAll {
            $wiki = New-Wiki
            $docs = New-ValidDocs
            Add-DecisionIndex $docs
            Edit-Docs $docs 'docs/decisions/0001-esempio.md' 'status: accepted' "status: superseded`nsuperseded-by: 0002-sostituta"
            $docs['docs/decisions/0002-sostituta.md'] = "---`nstatus: accepted`nsupersedes: 0001-esempio`n---`n`n# Sostituta`n`nIl BFF resta l'unico ingresso.`n"
            $res = Invoke-WikiPublish $docs $wiki
            $index = Get-WikiPage $wiki 'Architettura/9.-Decisioni-di-progettazione.md'
            $replaced = Get-WikiPage $wiki 'Architettura/9.-Decisioni-di-progettazione/0001-Esempio.md'
            $successor = Get-WikiPage $wiki 'Architettura/9.-Decisioni-di-progettazione/0002-Sostituta.md'
        }
        AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

        It "Allora la pagina della decisione sostituita comincia con l'avviso in rosso" {
            $res.ExitCode | Should -Be 0 -Because $res.Output
            ($replaced -split "`n")[0] | Should -BeLike '> <span style="color:red;font-weight:bold">DECISIONE SOSTITUITA.*</span>*'
        }

        It "E l'avviso porta alla decisione che vale al suo posto" {
            ($replaced -split "`n")[0] | Should -BeLike '*[[]0002 Sostituta](/Architettura/9.-Decisioni-di-progettazione/0002-Sostituta).'
        }

        It "E l'indice mostra in rosso lo stato della decisione sostituita" {
            $index | Should -Match ([regex]::Escape('| <span style="color:red;font-weight:bold">sostituita</span> |'))
        }

        It "E la decisione che vale non ha avvisi" {
            $successor | Should -Not -BeNullOrEmpty
            $successor | Should -Not -Match 'color:red'
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


# Gli scenari del documento del requisito 1539 «La documentazione architetturale si legge nella wiki e come
# documento PDF e Word», con il testo dei criteri di accettazione: un It per ogni Allora e ogni E. Il repository
# non ha un runner Gherkin per PowerShell, quindi gli schemi e i loro esempi sono Context di Pester.
Describe "Funzionalità: Documentazione architetturale nella wiki e come documento" {

    BeforeAll {
        $DocumentVersion = 'Versione 01234567'
        $SectionTitles = @('Introduzione e obiettivi', 'Vincoli di architettura', 'Ambito e contesto del sistema', 'Strategia della soluzione',
            'Building Block View', 'Runtime View', 'Deployment View', 'Concetti trasversali', 'Decisioni di progettazione',
            'Requisiti di Qualità', 'Rischi e debiti tecnici', 'Glossario')
        $AzureDevOpsLink = '^https?://([\w-]+\.)*(dev\.azure\.com|visualstudio\.com)([:/?#]|$)'

        function Read-PublishedDocument([string]$Format, [byte[]]$Bytes) {
            if ($Format -eq 'Word') {
                $word = Read-WordDocument $Bytes
                return [pscustomobject]@{
                    Text     = $word.Text
                    Headings = $word.Headings
                    Index    = $word.Index -and $word.Text.Contains('Indice')
                    Links    = @($word.Links | Where-Object { -not $_.Target.StartsWith('#') } | ForEach-Object Target)
                    Linked   = (@($word.Links | ForEach-Object Text) -join "`n")
                    Images   = $word.Images.Count
                }
            }
            $pdf = Read-PdfDocument $Bytes
            $headings = foreach ($title in $pdf.Outline) {
                if ($title -notmatch '^(\d+(?:\.\d+)*) (.+)$') { continue }
                [pscustomobject]@{ Level = $Matches[1].Split('.').Count; Number = $Matches[1]; Title = $Matches[2] }
            }
            return [pscustomobject]@{
                Text     = $pdf.Text
                Headings = @($headings)
                Index    = $pdf.Outline -contains 'Indice'
                Links    = $pdf.Links
                Linked   = ''
                Images   = $pdf.Images.Count
            }
        }

        function Get-PublishedState($Wiki) {
            return @{
                Home = Get-WikiPage $Wiki 'Architettura.md'
                Page = Get-WikiPage $Wiki 'Architettura/5.-Building-Block-View.md'
                Png  = Get-WikiFileBytes $Wiki '.attachments/Architettura/contenitori.png'
                PDF  = Get-WikiFileBytes $Wiki '.attachments/Architettura/Architettura.pdf'
                Word = Get-WikiFileBytes $Wiki '.attachments/Architettura/Architettura.docx'
            }
        }

        $wiki = New-Wiki
        $docs = New-ValidDocs
        Add-DecisionIndex $docs
        Add-ViewCaption $docs
        $docs['docs/decisions/0012-canale-eventi-di-sessione.md'] = (@(
                '---', 'status: accepted', '---', '',
                "# Canale eventi di sessione posseduto dall'hub", '',
                '## Contesto e problema', '',
                'La scelta nasce dal [Task 1600](https://dev.azure.com/Org/Progetto/_workitems/edit/1600) e dalla [PR 1300](https://dev.azure.com/Org/Progetto/_git/Architettura.Repo/pullrequest/1300).', '',
                '## Opzioni considerate', '',
                "- Il canale nell'hub, descritto nella [pagina della wiki](https://dev.azure.com/Org/Progetto/_wiki/wikis/Progetto.wiki/1/Canale) e nella build <https://org.visualstudio.com/Progetto/_build>.",
                '- Il canale nel BFF, come propone [MADR](https://adr.github.io/madr/).', '',
                '## Esito della decisione', '',
                "Il canale vive nell'hub, come in [0001-esempio](0001-esempio.md) e secondo la [guida](../STYLE.md).") -join "`n") + "`n"
        $first = Invoke-WikiPublish $docs $wiki '' 'pdf, docx'
        $before = Get-PublishedState $wiki
        $commitsBeforeChange = Get-WikiCommitCount $wiki
        Edit-Docs $docs 'docs/architecture/c4/workspace.dsl' 'bff -> motore "inoltra"' "bff -> motore `"inoltra`"`n        bff -> motore `"consegna gli eventi di sessione al client`""
        $second = Invoke-WikiPublish $docs $wiki '' 'pdf, docx'
        $after = Get-PublishedState $wiki
        $commitsAfterChange = Get-WikiCommitCount $wiki
        $third = Invoke-WikiPublish $docs $wiki '' 'pdf, docx'
    }
    AfterAll { Remove-Item -Recurse -Force $wiki.Root -ErrorAction SilentlyContinue }

    Context "Schema dello scenario: documento scaricabile" {

        Context "Esempio: <formato>" -ForEach @(
            @{ formato = 'PDF'; File = 'Architettura.pdf' }
            @{ formato = 'Word'; File = 'Architettura.docx' }
        ) {
            BeforeAll { $document = Read-PublishedDocument $formato $before[$formato] }

            It 'Allora la home rimanda al documento in <formato> della versione in "main"' {
                $first.ExitCode | Should -Be 0 -Because $first.Output
                $before.Home | Should -Match ([regex]::Escape("- [$File](/.attachments/Architettura/$File)"))
                ($document.Text -replace '\s+', '') | Should -Match ([regex]::Escape(($DocumentVersion -replace '\s+', '')))
            }

            It "E il documento contiene le dodici sezioni arc42 numerate, l'indice, i diagrammi disegnati e le decisioni" {
                $sections = @($document.Headings | Where-Object Level -EQ 1)
                @($sections | ForEach-Object Number) | Should -Be @(1..12 | ForEach-Object { "$_" })
                @($sections | ForEach-Object { $_.Title.Trim() }) | Should -Be $SectionTitles
                $document.Index | Should -BeTrue
                $document.Images | Should -Be 8 -Because 'sette viste C4 e un diagramma Mermaid'
                $decisions = @($document.Headings | Where-Object { $_.Level -eq 2 -and $_.Number -like '9.*' -and $_.Title.Trim() -match '^\d{4} ' } | ForEach-Object { $_.Title.Trim() })
                $decisions | Should -Be @('0001 Esempio', '0012 Canale eventi di sessione')
            }

            It "E nel documento il titolo e la riga dei vicini accompagnano l'immagine della vista (ADR-2113)" {
                $text = $document.Text -replace '\s+', ''
                $text | Should -Match ([regex]::Escape('Produzione,nodoAzureComunicacon:Azure(inoltra)'))
            }
        }
    }

    Context "Schema dello scenario: documento leggibile da chi non accede ad Azure DevOps" {

        Context "Esempio: <formato>" -ForEach @(
            @{ formato = 'PDF' }
            @{ formato = 'Word' }
        ) {
            BeforeAll { $document = Read-PublishedDocument $formato $before[$formato] }

            It 'Allora la decisione nomina "PR 1300" e "Task 1600" come testo, senza link' {
                $text = $document.Text -replace '\s+', ''
                $text | Should -Match 'PR1300'
                $text | Should -Match 'Task1600'
                $document.Linked | Should -Not -Match 'PR 1300|Task 1600'
                @($document.Links | Where-Object { $_ -match 'pullrequest/1300|edit/1600' }) | Should -BeNullOrEmpty
            }

            It "E il documento non contiene link a pagine della wiki, a PR, a work item o ad altre risorse interne di Azure DevOps" {
                @($document.Links | Where-Object { $_ -match $AzureDevOpsLink }) | Should -BeNullOrEmpty
                $document.Links | Should -Contain 'https://adr.github.io/madr/'
            }
        }
    }

    Context "Schema dello scenario: modifica visibile ovunque" {

        Context "Esempio: <dove>" -ForEach @(
            @{ dove = 'la pagina "Vista dei building block"'; Kind = 'Page' }
            @{ dove = 'il documento PDF'; Kind = 'PDF' }
            @{ dove = 'il documento Word'; Kind = 'Word' }
        ) {
            It "Allora il diagramma dei container mostra la relazione nuova" {
                $second.ExitCode | Should -Be 0 -Because $second.Output
                $commitsAfterChange | Should -Be ($commitsBeforeChange + 1)
                [Convert]::ToHexString($after.Png) | Should -Not -Be ([Convert]::ToHexString($before.Png)) -Because 'la vista dei container cambia con la relazione nuova'
                switch ($Kind) {
                    'Page' { $after.Page | Should -Match ([regex]::Escape('![contenitori](/.attachments/Architettura/contenitori.png)')) }
                    'Word' {
                        $pngs = @((Read-WordDocument $after.Word).Images | ForEach-Object { [Convert]::ToHexString($_) })
                        $pngs | Should -Contain ([Convert]::ToHexString($after.Png))
                        $pngs | Should -Not -Contain ([Convert]::ToHexString($before.Png))
                    }
                    'PDF' {
                        $size = Get-PngDimensions $after.Png
                        $previousSize = Get-PngDimensions $before.Png
                        $image = @((Read-PdfDocument $after.PDF).Images | Where-Object { $_.Width -eq $size.Width -and $_.Height -eq $size.Height })
                        $previous = @((Read-PdfDocument $before.PDF).Images | Where-Object { $_.Width -eq $previousSize.Width -and $_.Height -eq $previousSize.Height })
                        $image.Count | Should -Be 1
                        $previous.Count | Should -Be 1
                        $image[0].Hash | Should -Not -Be $previous[0].Hash
                    }
                }
            }
        }
    }

    Context "Scenario: il documento della stessa versione non cambia" {

        It "Allora una nuova pubblicazione senza modifiche non crea commit" {
            $third.ExitCode | Should -Be 0 -Because $third.Output
            Get-WikiCommitCount $wiki | Should -Be $commitsAfterChange
            $third.Output | Should -Match "La wiki mostra gia' il documento"
        }
    }

    Context "Scenario: formato del documento non supportato" {
        BeforeAll {
            $unsupportedWiki = New-Wiki
            $commits = Get-WikiCommitCount $unsupportedWiki
            $res = Invoke-WikiPublish (New-ValidDocs) $unsupportedWiki '' 'pdf, odt'
        }
        AfterAll { Remove-Item -Recurse -Force $unsupportedWiki.Root -ErrorAction SilentlyContinue }

        It "Allora la pubblicazione fallisce e nomina il formato" {
            $res.ExitCode | Should -Be 1
            Get-Issues $res.Output | Should -Match 'formato del documento non supportato: odt'
        }

        It "E la wiki non cambia" {
            Get-WikiCommitCount $unsupportedWiki | Should -Be $commits
        }
    }
}
