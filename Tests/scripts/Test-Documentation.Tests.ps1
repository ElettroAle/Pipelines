#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Test-Documentation.ps1

.DESCRIPTION
    Ogni scenario parte da una documentazione valida (le dodici sezioni di un template arc42,
    modello C4, diagrammi Mermaid, soglie di leggibilita') e vi introduce un solo difetto. Il
    template e' un archivio zip costruito qui, con i nomi dei file e i titoli del template
    ufficiale italiano e gli attributi di titolo che quel template porta. Lo script gira
    come in pipeline: richiede Java 17 o successivo e Node.js; la Structurizr CLI e il
    parser Mermaid si installano in una cache condivisa da tutti gli scenari.
#>

BeforeAll {
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Test-Documentation.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-architecture-docs-$(New-Guid)"

    $TemplateFiles = [ordered]@{
        '01_introduction_and_goals.md' = "# Introduzione e obiettivi {#section-introduction-and-goals}`n`n## Parte`n"
        '02_architecture_constraints.md' = "# Vincoli di architettura {#section-architecture-constraints}`n`n## Parte`n"
        '03_context_and_scope.md' = "# Ambito e contesto del sistema {#section-context-and-scope}`n`n## Parte`n"
        '04_solution_strategy.md' = "# Strategia della soluzione {#section-solution-strategy}`n`n## Parte`n"
        '05_building_block_view.md' = "# Building Block View {#section-building-block-view}`n`n## Parte`n"
        '06_runtime_view.md' = "# Runtime View {#section-runtime-view}`n`n## Parte`n"
        '07_deployment_view.md' = "# Deployment View {#section-deployment-view}`n`n## Parte`n"
        '08_concepts.md' = "# Concetti trasversali {#section-concepts}`n`n## Parte`n"
        '09_architecture_decisions.md' = "# Decisioni di progettazione {#section-architecture-decisions}`n`n## Parte`n"
        '10_quality_requirements.md' = "# Requisiti di Qualità {#section-quality-requirements}`n`n## Parte`n"
        '11_technical_risks.md' = "# Rischi e debiti tecnici {#section-technical-risks}`n`n## Parte`n"
        '12_glossary.md' = "# Glossario {#section-glossary}`n`n## Parte`n"
        'about-arc42.md' = "# Informazioni su arc42`n"
    }
    $TemplateDirectory = Join-Path ([IO.Path]::GetTempPath()) "pester-docs-template-$(New-Guid)"
    New-Item -ItemType Directory -Path "$TemplateDirectory/files" | Out-Null
    foreach ($name in $TemplateFiles.Keys) { [IO.File]::WriteAllText("$TemplateDirectory/files/$name", $TemplateFiles[$name]) }
    $TemplateArchive = Join-Path $TemplateDirectory 'template.zip'
    Compress-Archive -Path "$TemplateDirectory/files/*" -DestinationPath $TemplateArchive
    $TemplateSha256 = (Get-FileHash $TemplateArchive -Algorithm SHA256).Hash.ToLowerInvariant()

    function New-Section([string]$Title, [string]$Question, [string]$Body) {
        return @"
# $Title

> **A chi serve**: a chi entra nel progetto e a chi lo guida.
> **Cosa risponde**: $Question

## In breve

$Body
"@
    }

    function New-ValidDocs {
        $docs = [ordered]@{}
        $docs['docs/decisions/0001-esempio.md'] = "---`nstatus: accepted`n---`n`n# Esempio`n"
        $docs['docs/architecture/model/workspace.dsl'] = @'
workspace "Piattaforma" {
    model {
        cittadino = person "Cittadino"
        dxp = softwareSystem "Piattaforma" {
            client = container "Client" "Interfaccia web" "Angular" "Applicazione" {
                pagine = component "Pagine"
            }
            bff = container "BFF" "Ingresso unico" "ASP.NET" "Applicazione" {
                proxy = component "Proxy"
            }
            motore = container "API del Motore" "Logica" "ASP.NET" "Applicazione" {
                sessioni = component "Sessioni"
            }
            worker = container "Worker" "Lavori lunghi" "Functions" "Applicazione" {
                coda = component "Coda"
            }
        }
        cittadino -> client "usa"
        client -> bff "chiama"
        bff -> motore "inoltra"
        motore -> worker "accoda"

        produzione = deploymentEnvironment "Produzione" {
            deploymentNode "Azure" {
                containerInstance client
            }
        }
    }
    views {
        systemContext dxp "contesto" {
            include *
        }
        container dxp "contenitori" {
            include *
        }
        component client "componenti-client" {
            include *
        }
        component bff "componenti-bff" {
            include *
        }
        component motore "componenti-motore" {
            include *
        }
        component worker "componenti-worker" {
            include *
        }
        deployment dxp produzione "deployment-produzione" {
            include *
        }
    }
}
'@
        $docs['docs/architecture/01_introduction_and_goals.md'] = New-Section 'Introduzione e obiettivi' 'a cosa serve la piattaforma?' @'
La piattaforma aiuta il cittadino a parlare con un operatore del comune.

Il Backend for Frontend (BFF) riceve le richieste del Client. L'interfaccia di programmazione del Motore (API) esegue il lavoro.
'@
        $docs['docs/architecture/02_architecture_constraints.md'] = New-Section 'Vincoli di architettura' 'quali limiti valgono per tutto il progetto?' @'
La piattaforma gira su Azure. Il codice vive nei repository del progetto.
'@
        $docs['docs/architecture/03_context_and_scope.md'] = New-Section 'Ambito e contesto del sistema' 'chi usa la piattaforma?' @'
<!-- vista: contesto -->

Il Cittadino usa la Piattaforma dal telefono o dal computer.
'@
        $docs['docs/architecture/04_solution_strategy.md'] = New-Section 'Strategia della soluzione' 'come è divisa la piattaforma?' @'
La piattaforma divide il lavoro fra applicazioni piccole. Ogni applicazione fa una cosa sola.
'@
        $docs['docs/architecture/05_building_block_view.md'] = (New-Section 'Building Block View' 'di quali parti è fatta la piattaforma?' @'
<!-- vista: contenitori -->

Il Cittadino usa il Client per aprire una richiesta.

Il Client chiama il BFF per ogni richiesta.

Il BFF inoltra la richiesta all'API del Motore.

L'API del Motore accoda i lavori lunghi al Worker.

## Componenti

<!-- vista: componenti-client -->
<!-- vista: componenti-bff -->
<!-- vista: componenti-motore -->
<!-- vista: componenti-worker -->

Le Pagine del Client mostrano i dati. Il Proxy del BFF passa le chiamate. Le Sessioni dell'API del Motore tengono lo stato.

La Coda del Worker ordina i lavori. `SessionStore` (l'archivio delle sessioni) conserva lo stato fra due richieste.

## Per approfondire

Le scelte sono nella sezione [Decisioni architetturali](09_architecture_decisions.md).
'@)
        $docs['docs/architecture/06_runtime_view.md'] = New-Section 'Runtime View' 'cosa succede quando si apre una sessione?' @'
Il BFF chiede all'API del Motore di aprire una sessione. L'API del Motore risponde con il codice della sessione.

```mermaid
sequenceDiagram
    participant B as BFF
    participant M as API del Motore
    B->>M: apre la sessione
    M-->>B: codice della sessione
```
'@
        $docs['docs/architecture/07_deployment_view.md'] = New-Section 'Deployment View' 'dove girano le applicazioni?' @'
<!-- vista: deployment-produzione -->

Un **Private Endpoint** è un indirizzo privato che porta il traffico a un servizio senza passare da internet.

Il Client gira nel nodo Azure. Ogni servizio riceve il traffico da un Private Endpoint.

La rete segue lo schema *hub-and-spoke*: una rete centrale collega le reti delle applicazioni.
'@
        $docs['docs/architecture/08_concepts.md'] = New-Section 'Concetti trasversali' 'quali regole valgono per tutte le applicazioni?' @'
Ogni servizio riceve il traffico da un Private Endpoint (PE). Il PE ha un indirizzo della rete privata.
'@
        $docs['docs/architecture/09_architecture_decisions.md'] = New-Section 'Decisioni di progettazione' 'quali scelte sono state fatte e perché?' @'
La decisione [0001-esempio](../decisions/0001-esempio.md) sceglie il BFF come unico ingresso.

Il quadro delle applicazioni è nella [vista dei building block](05_building_block_view.md#in-breve).
'@
        $docs['docs/architecture/10_quality_requirements.md'] = New-Section 'Requisiti di Qualità' 'quanto deve essere veloce la piattaforma?' @'
Una risposta arriva al cittadino in meno di due secondi.
'@
        $docs['docs/architecture/11_technical_risks.md'] = New-Section 'Rischi e debiti tecnici' 'cosa può andare storto?' @'
Un guasto dell'API del Motore ferma le richieste nuove.
'@
        $docs['docs/architecture/12_glossary.md'] = New-Section 'Glossario' 'cosa vogliono dire i termini usati?' @'
I termini sono in ordine alfabetico.

- **API**: interfaccia di programmazione, il modo in cui un programma chiede un servizio a un altro.
- **BFF**: Backend for Frontend, l'applicazione che riceve le richieste del Client.
- **hub-and-spoke**: schema di rete con una rete centrale collegata alle reti delle applicazioni.
- **PE**: Private Endpoint, un indirizzo privato verso un servizio.
'@
        # Il checkout su Windows puo' portare i here-string in CRLF: le modifiche delle fixture cercano testo in LF.
        foreach ($path in @($docs.Keys)) { $docs[$path] = $docs[$path] -replace "`r`n", "`n" }
        return $docs
    }

    function Edit-Docs([System.Collections.IDictionary]$Docs, [string]$Path, [string]$Old, [string]$New) {
        if (-not $Docs[$Path].Contains($Old)) { throw "Fixture: '$Old' assente da $Path" }
        $Docs[$Path] = $Docs[$Path].Replace($Old, $New)
    }

    function Invoke-DocsCheck([System.Collections.IDictionary]$Docs, [string]$Mode = '', [hashtable]$Environment = @{}) {
        $variables = @{
            DOCS_TEMPLATE             = $TemplateArchive
            DOCS_TEMPLATE_SHA256      = $TemplateSha256
            READABILITY_GULPEASE      = '40'
            READABILITY_MAX_WORDS     = '25'
            READABILITY_ABBREVIATIONS = 'es.;ecc.'
        }
        foreach ($name in $Environment.Keys) { $variables[$name] = $Environment[$name] }

        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-docs-$(New-Guid)"
        foreach ($path in $Docs.Keys) {
            if ($null -eq $Docs[$path]) { continue }
            $file = Join-Path $root $path
            New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
            [IO.File]::WriteAllText($file, ($Docs[$path] -replace "`r`n", "`n"))
        }

        Push-Location $root
        try {
            $env:GATE_MODE = $Mode
            $previous = @{}
            foreach ($name in $variables.Keys) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, $variables[$name])
            }
            $pwsh = (Get-Process -Id $PID).Path
            $output = & $pwsh -NoProfile -NonInteractive -File $ScriptPath 2>&1
            foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
            return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
        }
        finally {
            Pop-Location
            $env:GATE_MODE = $null
            Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
        }
    }

    function Get-Issues([string]$Output, [string]$Level = 'error') {
        return @([regex]::Matches($Output, "##vso\[task\.logissue type=$Level\]([^\r\n]*)") | ForEach-Object { $_.Groups[1].Value })
    }

    function Get-LineNumber([string]$Content, [string]$Text) {
        $lines = $Content -split "`r?`n"
        return [Array]::IndexOf($lines, ($lines | Where-Object { $_.Contains($Text) } | Select-Object -First 1)) + 1
    }
}

AfterAll {
    Remove-Item -Recurse -Force $TemplateDirectory -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}


Describe "Funzionalità: Verifica della documentazione architetturale" {

    Context "Scenario: documento completo e chiaro" {
        BeforeAll {
            $res = Invoke-DocsCheck (New-ValidDocs)
        }

        It "Allora la verifica passa" {
            Get-Issues $res.Output | Should -BeNullOrEmpty
            $res.ExitCode | Should -Be 0
        }
    }

    Context "Schema dello scenario: documento non ben formato — <difetto>" -ForEach @(
        @{
            difetto  = 'la sezione "Deployment View" mancante'
            elemento = '^documento: sezione mancante \(07_deployment_view\.md: Deployment View\)'
            Mutate   = { param($d) $d['docs/architecture/07_deployment_view.md'] = $null }
        }
        @{
            difetto  = 'una relazione da "BFF" verso "Motore v3", che il modello non dichiara'
            elemento = '^modello C4: .*"Motore v3"'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/model/workspace.dsl' 'motore -> worker "accoda"' "motore -> worker `"accoda`"`n        bff -> `"Motore v3`" `"chiama`"" }
        }
        @{
            difetto  = 'il container "Worker" senza vista dei componenti'
            elemento = '^modello C4: container senza vista dei componenti \(Worker\)'
            Mutate   = {
                param($d)
                Edit-Docs $d 'docs/architecture/model/workspace.dsl' "        component worker `"componenti-worker`" {`n            include *`n        }`n" ''
                Edit-Docs $d 'docs/architecture/05_building_block_view.md' "<!-- vista: componenti-worker -->`n" ''
            }
        }
        @{
            difetto  = 'un diagramma di sequenza Mermaid con sintassi non valida'
            elemento = '^Runtime View: diagramma non valido \(06_runtime_view\.md:{0}\b'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/06_runtime_view.md' 'B->>M: apre la sessione' 'B->>: apre la sessione' }
            Line     = 'B->>: apre la sessione'
        }
        @{
            difetto  = 'un rimando alla decisione "0042-inesistente"'
            elemento = '^Decisioni di progettazione: rimando inesistente \(0042-inesistente\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/09_architecture_decisions.md' 'come unico ingresso.' 'come unico ingresso. La decisione 0042-inesistente vale ancora.' }
        }
    ) {
        BeforeAll {
            $docs = New-ValidDocs
            & $Mutate $docs
            $res = Invoke-DocsCheck $docs
            $expected = if ($Line) { $elemento -f (Get-LineNumber $docs['docs/architecture/06_runtime_view.md'] $Line) } else { $elemento }
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina l'elemento difettoso" {
            Get-Issues $res.Output | Where-Object { $_ -match $expected } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Schema dello scenario: testo oltre le soglie di leggibilità — <sezione>, <motivo>" -ForEach @(
        @{
            sezione = 'Strategia della soluzione'; motivo = 'leggibilità'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/04_solution_strategy.md' 'La piattaforma divide il lavoro fra applicazioni piccole. Ogni applicazione fa una cosa sola.' 'Infrastrutturalmente, l''orchestrazione multiprogettuale garantisce interoperabilità transfrontaliera. Contestualmente, l''automatizzazione documentale razionalizza l''amministrazione organizzativa. Conseguentemente, l''interoperabilità infrastrutturale semplifica l''amministrazione multiprogettuale. Parallelamente, l''internazionalizzazione organizzativa rafforza l''orchestrazione documentale interdipartimentale.' }
        }
        @{
            sezione = 'Runtime View'; motivo = 'frase troppo lunga'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/06_runtime_view.md' 'con il codice della sessione.' 'con il codice della sessione, che il BFF conserva per tutta la durata della conversazione e che rimanda all''API del Motore ogni volta che il cittadino scrive un messaggio nuovo o chiude la finestra.' }
        }
    ) {
        BeforeAll {
            $docs = New-ValidDocs
            & $Mutate $docs
            $res = Invoke-DocsCheck $docs
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina la sezione e il motivo" {
            Get-Issues $res.Output | Where-Object { $_.StartsWith("${sezione}: $motivo") } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }
}

Describe "Test-Documentation — modalità del controllo" {

    BeforeAll {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/09_architecture_decisions.md' 'come unico ingresso.' 'come unico ingresso. La decisione 0042-inesistente vale ancora.'
    }

    It "In modalità warn segnala come warning e non blocca" {
        $res = Invoke-DocsCheck $docs 'warn'
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output 'warning' | Should -Not -BeNullOrEmpty
        $res.Output | Should -Match 'task\.complete result=SucceededWithIssues'
    }

    It "In modalità off non verifica" {
        $res = Invoke-DocsCheck $docs 'off'
        $res.ExitCode | Should -Be 0
        Get-Issues $res.Output | Should -BeNullOrEmpty
    }
}

Describe "Test-Documentation — strumenti assenti" {

    It "Senza un Java 17 fallisce nominando il modello C4 e il motivo" {
        $res = Invoke-DocsCheck (New-ValidDocs) -Environment @{ STRUCTURIZR_JAVA = (Join-Path ([IO.Path]::GetTempPath()) 'java-assente') }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^modello C4: verifica non eseguita \(.*Java 17' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Senza Node.js fallisce nominando i diagrammi Mermaid" {
        $res = Invoke-DocsCheck (New-ValidDocs) -Environment @{ PATH = '' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^diagrammi Mermaid: verifica non eseguita' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }
}

Describe "Test-Documentation — controlli strutturali" {

    It "Un rimando a un'ancora inesistente fallisce nominando il rimando" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/09_architecture_decisions.md' '#in-breve' '#nessuna'
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^Decisioni di progettazione: rimando inesistente \(05_building_block_view\.md#nessuna\)' } | Should -Not -BeNullOrEmpty
    }

    It "Una vista non mostrata in nessuna sezione fallisce nominando la vista" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/03_context_and_scope.md' "<!-- vista: contesto -->`n" ''
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^modello C4: vista non mostrata in nessuna sezione \(contesto\)' } | Should -Not -BeNullOrEmpty
    }

    It "Un marcatore di vista inesistente fallisce nominando la sezione e la vista" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/03_context_and_scope.md' 'vista: contesto' "vista: contesto -->`n<!-- vista: nessuna"
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^Ambito e contesto del sistema: vista inesistente \(nessuna\)' } | Should -Not -BeNullOrEmpty
    }

    It "Un modello senza vista di deployment fallisce nominando il livello" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/model/workspace.dsl' "        deployment dxp produzione `"deployment-produzione`" {`n            include *`n        }`n" ''
        Edit-Docs $docs 'docs/architecture/07_deployment_view.md' "<!-- vista: deployment-produzione -->`n" ''
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^modello C4: livello mancante \(vista di deployment\)' } | Should -Not -BeNullOrEmpty
    }

    It "Un file numerato che non è una sezione del template fallisce nominando il file" {
        $docs = New-ValidDocs
        $docs['docs/architecture/13_extra.md'] = "# Appendice`n"
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^documento: sezione fuori template \(13_extra\.md: Appendice\)' } | Should -Not -BeNullOrEmpty
    }

    It "Un titolo diverso da quello del template fallisce nominando il file e il titolo atteso" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/02_architecture_constraints.md' '# Vincoli di architettura' '# Vincoli'
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^documento: titolo diverso dal template \(02_architecture_constraints\.md: Vincoli, atteso «Vincoli di architettura»\)' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }
}

Describe "MarkdownText — analisi del testo" {

    BeforeAll {
        . "$PSScriptRoot/../../V3/CI/Scripts/MarkdownText.ps1"
    }

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

    Context "Blocchi di una sezione" {
        BeforeAll {
            $content = @(
                '# Titolo'
                ''
                '> **A chi serve**: a tutti.'
                ''
                '## In breve'
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

        It "Riconosce il titolo" { $section.Title | Should -Be 'Titolo' }
        It "Riconosce le parti" { $section.Parts | Should -Be @('In breve') }
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
    }
}

Describe "Test-Documentation — template del documento" {

    BeforeAll {
        function New-ProductDocs {
            $docs = New-ValidDocs
            foreach ($path in @($docs.Keys | Where-Object { $_ -like 'docs/architecture/*' })) { $docs[$path] = $null }
            $docs['docs/template/01-introduzione.md'] = "# Introduzione`n"
            $docs['docs/template/02-glossario.md'] = "# Glossario`n"
            $docs['docs/architecture/01-introduzione.md'] = New-Section 'Introduzione' 'a cosa serve il prodotto?' 'Il prodotto aiuta il cittadino a parlare con un operatore del comune.'
            $docs['docs/architecture/02-glossario.md'] = New-Section 'Glossario' 'cosa vogliono dire i termini usati?' 'I termini sono in ordine alfabetico.'
            return $docs
        }
        $ProductTemplate = @{ DOCS_TEMPLATE = 'docs/template'; DOCS_TEMPLATE_SHA256 = '' }
    }

    It "Un documento con un template proprio nel repository e senza modello C4 passa" {
        $res = Invoke-DocsCheck (New-ProductDocs) -Environment $ProductTemplate
        Get-Issues $res.Output | Should -BeNullOrEmpty -Because ($res.Output)
        $res.ExitCode | Should -Be 0
    }

    It "Senza modello C4 un marcatore di vista fallisce nominando la sezione e la vista" {
        $docs = New-ProductDocs
        Edit-Docs $docs 'docs/architecture/01-introduzione.md' 'Il prodotto aiuta' "<!-- vista: contesto -->`n`nIl prodotto aiuta"
        $res = Invoke-DocsCheck $docs -Environment $ProductTemplate
        Get-Issues $res.Output | Where-Object { $_ -match '^Introduzione: vista inesistente \(contesto\)' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Senza template dichiarato fallisce nominando il parametro" {
        $res = Invoke-DocsCheck (New-ValidDocs) -Environment @{ DOCS_TEMPLATE = '' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^template del documento: non dichiarato \(parametro docsTemplate\)' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Un template con SHA-256 diverso da quello dichiarato fallisce nominando i due valori" {
        $declared = '0' * 64
        $res = Invoke-DocsCheck (New-ValidDocs) -Environment @{ DOCS_TEMPLATE_SHA256 = $declared }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match "^template del documento: SHA-256 diverso \(atteso $declared, ricevuto $TemplateSha256\)" } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Un template scaricato senza SHA-256 fallisce senza scaricarlo" {
        $res = Invoke-DocsCheck (New-ValidDocs) -Environment @{ DOCS_TEMPLATE = 'https://example.invalid/template.zip'; DOCS_TEMPLATE_SHA256 = '' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^template del documento: SHA-256 non dichiarato \(https://example\.invalid/template\.zip\)' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }

    It "Un template che non si scarica fallisce nominando l'indirizzo" {
        $res = Invoke-DocsCheck (New-ValidDocs) -Environment @{ DOCS_TEMPLATE = 'http://127.0.0.1:9/template.zip' }
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^template del documento: download non riuscito \(http://127\.0\.0\.1:9/template\.zip: ' } | Should -Not -BeNullOrEmpty -Because ($res.Output)
    }
}
