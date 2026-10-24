#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/Test-ArchitectureDocs.ps1

.DESCRIPTION
    Ogni scenario parte da una documentazione valida (dodici sezioni arc42, modello C4,
    diagrammi Mermaid, guida di stile) e vi introduce un solo difetto. Lo script gira
    come in pipeline: richiede Java 17 o successivo e Node.js; la Structurizr CLI e il
    parser Mermaid si installano in una cache condivisa da tutti gli scenari.
#>

BeforeAll {
    $ScriptPath = Resolve-Path "$PSScriptRoot/../../V3/CI/Scripts/Test-ArchitectureDocs.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-architecture-docs-$(New-Guid)"

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
        $docs['docs/style.json'] = @'
{
  "gulpease": { "opening": 40, "body": 40 },
  "sentences": { "maxWords": 25, "abbreviations": ["es.", "ecc."] },
  "fillers": ["è importante sottolineare che", "vale la pena notare che"],
  "selfReferences": ["in questa sezione", "questo documento", "vedremo"],
  "jargon": { "leverage": "sfruttare", "deployare": "rilasciare" },
  "opening": ["A chi serve", "Cosa risponde"],
  "parts": { "first": "In breve", "last": "Per approfondire" }
}
'@
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
        $docs['docs/architecture/01-introduzione-e-obiettivi.md'] = New-Section 'Introduzione e obiettivi' 'a cosa serve la piattaforma?' @'
La piattaforma aiuta il cittadino a parlare con un operatore del comune.

Il Backend for Frontend (BFF) riceve le richieste del Client. L'interfaccia di programmazione del Motore (API) esegue il lavoro.
'@
        $docs['docs/architecture/02-vincoli.md'] = New-Section 'Vincoli' 'quali limiti valgono per tutto il progetto?' @'
La piattaforma gira su Azure. Il codice vive nei repository del progetto.
'@
        $docs['docs/architecture/03-contesto-e-ambito.md'] = New-Section 'Contesto e ambito' 'chi usa la piattaforma?' @'
<!-- vista: contesto -->

Il Cittadino usa la Piattaforma dal telefono o dal computer.
'@
        $docs['docs/architecture/04-strategia-di-soluzione.md'] = New-Section 'Strategia di soluzione' 'come è divisa la piattaforma?' @'
La piattaforma divide il lavoro fra applicazioni piccole. Ogni applicazione fa una cosa sola.
'@
        $docs['docs/architecture/05-vista-dei-building-block.md'] = (New-Section 'Vista dei building block' 'di quali parti è fatta la piattaforma?' @'
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

Le scelte sono nella sezione [Decisioni architetturali](09-decisioni-architetturali.md).
'@)
        $docs['docs/architecture/06-vista-di-runtime.md'] = New-Section 'Vista di runtime' 'cosa succede quando si apre una sessione?' @'
Il BFF chiede all'API del Motore di aprire una sessione. L'API del Motore risponde con il codice della sessione.

```mermaid
sequenceDiagram
    participant B as BFF
    participant M as API del Motore
    B->>M: apre la sessione
    M-->>B: codice della sessione
```
'@
        $docs['docs/architecture/07-vista-di-deployment.md'] = New-Section 'Vista di deployment' 'dove girano le applicazioni?' @'
<!-- vista: deployment-produzione -->

Un **Private Endpoint** è un indirizzo privato che porta il traffico a un servizio senza passare da internet.

Il Client gira nel nodo Azure. Ogni servizio riceve il traffico da un Private Endpoint.

La rete segue lo schema *hub-and-spoke*: una rete centrale collega le reti delle applicazioni.
'@
        $docs['docs/architecture/08-concetti-trasversali.md'] = New-Section 'Concetti trasversali' 'quali regole valgono per tutte le applicazioni?' @'
Ogni servizio riceve il traffico da un Private Endpoint (PE). Il PE ha un indirizzo della rete privata.
'@
        $docs['docs/architecture/09-decisioni-architetturali.md'] = New-Section 'Decisioni architetturali' 'quali scelte sono state fatte e perché?' @'
La decisione [0001-esempio](../decisions/0001-esempio.md) sceglie il BFF come unico ingresso.

Il quadro delle applicazioni è nella [vista dei building block](05-vista-dei-building-block.md#in-breve).
'@
        $docs['docs/architecture/10-requisiti-di-qualita.md'] = New-Section 'Requisiti di qualità' 'quanto deve essere veloce la piattaforma?' @'
Una risposta arriva al cittadino in meno di due secondi.
'@
        $docs['docs/architecture/11-rischi-e-debito-tecnico.md'] = New-Section 'Rischi e debito tecnico' 'cosa può andare storto?' @'
Un guasto dell'API del Motore ferma le richieste nuove.
'@
        $docs['docs/architecture/12-glossario.md'] = New-Section 'Glossario' 'cosa vogliono dire i termini usati?' @'
I termini sono in ordine alfabetico.

- **API**: interfaccia di programmazione, il modo in cui un programma chiede un servizio a un altro.
- **BFF**: Backend for Frontend, l'applicazione che riceve le richieste del Client.
- **hub-and-spoke**: schema di rete con una rete centrale collegata alle reti delle applicazioni.
- **PE**: Private Endpoint, un indirizzo privato verso un servizio.
'@
        return $docs
    }

    function Edit-Docs([System.Collections.IDictionary]$Docs, [string]$Path, [string]$Old, [string]$New) {
        if (-not $Docs[$Path].Contains($Old)) { throw "Fixture: '$Old' assente da $Path" }
        $Docs[$Path] = $Docs[$Path].Replace($Old, $New)
    }

    function Invoke-DocsCheck([System.Collections.IDictionary]$Docs, [string]$Mode = '', [hashtable]$Environment = @{}) {
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
            foreach ($name in $Environment.Keys) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, $Environment[$name])
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
            difetto  = 'la sezione "Vista di deployment" mancante'
            elemento = '^documento: sezione mancante \(Vista di deployment\)'
            Mutate   = { param($d) $d['docs/architecture/07-vista-di-deployment.md'] = $null }
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
                Edit-Docs $d 'docs/architecture/05-vista-dei-building-block.md' "<!-- vista: componenti-worker -->`n" ''
            }
        }
        @{
            difetto  = 'un diagramma di sequenza Mermaid con sintassi non valida'
            elemento = '^Vista di runtime: diagramma non valido \(06-vista-di-runtime\.md:{0}\b'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/06-vista-di-runtime.md' 'B->>M: apre la sessione' 'B->>: apre la sessione' }
            Line     = 'B->>: apre la sessione'
        }
        @{
            difetto  = 'un rimando alla decisione "0042-inesistente"'
            elemento = '^Decisioni architetturali: rimando inesistente \(0042-inesistente\)'
            Mutate   = { param($d) Edit-Docs $d 'docs/architecture/09-decisioni-architetturali.md' 'come unico ingresso.' 'come unico ingresso. La decisione 0042-inesistente vale ancora.' }
        }
    ) {
        BeforeAll {
            $docs = New-ValidDocs
            & $Mutate $docs
            $res = Invoke-DocsCheck $docs
            $expected = if ($Line) { $elemento -f (Get-LineNumber $docs['docs/architecture/06-vista-di-runtime.md'] $Line) } else { $elemento }
        }

        It "Allora la verifica fallisce" {
            $res.ExitCode | Should -Be 1
        }

        It "E nomina l'elemento difettoso" {
            Get-Issues $res.Output | Where-Object { $_ -match $expected } | Should -Not -BeNullOrEmpty -Because ($res.Output)
        }
    }

    Context "Schema dello scenario: testo non chiaro — <sezione>, <motivo>" -ForEach @(
        @{
            sezione = 'Strategia di soluzione'; motivo = 'leggibilità'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/04-strategia-di-soluzione.md' 'La piattaforma divide il lavoro fra applicazioni piccole. Ogni applicazione fa una cosa sola.' 'Infrastrutturalmente, l''orchestrazione multiprogettuale garantisce interoperabilità transfrontaliera. Contestualmente, l''automatizzazione documentale razionalizza l''amministrazione organizzativa.' }
        }
        @{
            sezione = 'Vista di runtime'; motivo = 'frase troppo lunga'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/06-vista-di-runtime.md' 'con il codice della sessione.' 'con il codice della sessione, che il BFF conserva per tutta la durata della conversazione e che rimanda all''API del Motore ogni volta che il cittadino scrive un messaggio nuovo o chiude la finestra.' }
        }
        @{
            sezione = 'Introduzione e obiettivi'; motivo = 'riempitivo'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/01-introduzione-e-obiettivi.md' 'La piattaforma aiuta' 'È importante sottolineare che la piattaforma aiuta' }
        }
        @{
            sezione = 'Strategia di soluzione'; motivo = 'autoreferenziale'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/04-strategia-di-soluzione.md' 'La piattaforma divide' 'In questa sezione vedremo come la piattaforma divide' }
        }
        @{
            sezione = 'Concetti trasversali'; motivo = 'sigla non spiegata'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/08-concetti-trasversali.md' 'Ogni servizio riceve' 'Il PE è privato. Ogni servizio riceve' }
        }
        @{
            sezione = 'Vista di deployment'; motivo = 'termine senza glossario'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/12-glossario.md' "- **hub-and-spoke**: schema di rete con una rete centrale collegata alle reti delle applicazioni.`n" '' }
        }
        @{
            sezione = 'Vista dei building block'; motivo = 'nome interno non spiegato'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/05-vista-dei-building-block.md' 'conserva lo stato fra due richieste.' 'conserva lo stato fra due richieste. Il SessionBackup parte ogni notte.' }
        }
        @{
            sezione = 'Concetti trasversali'; motivo = 'gergo evitabile'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/08-concetti-trasversali.md' 'della rete privata.' 'della rete privata. Il PE permette di fare leverage sulla rete.' }
        }
        @{
            sezione = 'Vista di deployment'; motivo = 'ordine dei concetti'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/07-vista-di-deployment.md' 'Un **Private Endpoint**' "Il traffico entra da un Private Endpoint.`n`nUn **Private Endpoint**" }
        }
        @{
            sezione = 'Vincoli'; motivo = 'ordine della sezione'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' '## In breve' "## Dettagli`n`nIl progetto usa un solo cloud.`n`n## In breve" }
        }
        @{
            sezione = 'Vincoli'; motivo = 'apertura mancante'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/02-vincoli.md' "> **A chi serve**: a chi entra nel progetto e a chi lo guida.`n> **Cosa risponde**: quali limiti valgono per tutto il progetto?`n" '' }
        }
        @{
            sezione = 'Vista dei building block'; motivo = 'elemento non spiegato'
            Mutate  = {
                param($d)
                Edit-Docs $d 'docs/architecture/05-vista-dei-building-block.md' 'L''API del Motore accoda i lavori lunghi al Worker.' 'L''API del Motore accoda i lavori lunghi.'
                Edit-Docs $d 'docs/architecture/05-vista-dei-building-block.md' 'La Coda del Worker ordina' 'La Coda ordina'
            }
        }
        @{
            sezione = 'Vista di runtime'; motivo = 'relazione non spiegata'
            Mutate  = { param($d) Edit-Docs $d 'docs/architecture/06-vista-di-runtime.md' 'Il BFF chiede all''API del Motore di aprire una sessione. L''API del Motore risponde' "Il BFF apre una sessione.`n`nL'API del Motore risponde" }
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

Describe "Test-ArchitectureDocs — modalità del controllo" {

    BeforeAll {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/04-strategia-di-soluzione.md' 'La piattaforma divide' 'In questa sezione vedremo come la piattaforma divide'
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

    It "Senza guida di stile fallisce nominando il file" {
        $docs['docs/style.json'] = $null
        $res = Invoke-DocsCheck $docs
        $res.ExitCode | Should -Be 1
        Get-Issues $res.Output | Where-Object { $_ -match '^guida di stile: file mancante \(docs/style\.json\)' } | Should -Not -BeNullOrEmpty
    }
}

Describe "Test-ArchitectureDocs — strumenti assenti" {

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

Describe "Test-ArchitectureDocs — controlli strutturali" {

    It "Un rimando a un'ancora inesistente fallisce nominando il rimando" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/09-decisioni-architetturali.md' '#in-breve' '#nessuna'
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^Decisioni architetturali: rimando inesistente \(05-vista-dei-building-block\.md#nessuna\)' } | Should -Not -BeNullOrEmpty
    }

    It "Una vista non mostrata in nessuna sezione fallisce nominando la vista" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/03-contesto-e-ambito.md' "<!-- vista: contesto -->`n" ''
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^modello C4: vista non mostrata in nessuna sezione \(contesto\)' } | Should -Not -BeNullOrEmpty
    }

    It "Un marcatore di vista inesistente fallisce nominando la sezione e la vista" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/03-contesto-e-ambito.md' 'vista: contesto' "vista: contesto -->`n<!-- vista: nessuna"
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^Contesto e ambito: vista inesistente \(nessuna\)' } | Should -Not -BeNullOrEmpty
    }

    It "Un modello senza vista di deployment fallisce nominando il livello" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/model/workspace.dsl' "        deployment dxp produzione `"deployment-produzione`" {`n            include *`n        }`n" ''
        Edit-Docs $docs 'docs/architecture/07-vista-di-deployment.md' "<!-- vista: deployment-produzione -->`n" ''
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^modello C4: livello mancante \(vista di deployment\)' } | Should -Not -BeNullOrEmpty
    }

    It "Un titolo che non è una sezione arc42 fallisce nominando il file" {
        $docs = New-ValidDocs
        $docs['docs/architecture/13-extra.md'] = "# Appendice`n"
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^documento: titolo non arc42 \(13-extra\.md: Appendice\)' } | Should -Not -BeNullOrEmpty
    }

    It "Sezioni fuori dall'ordine arc42 falliscono nominando la sezione" {
        $docs = New-ValidDocs
        $docs['docs/architecture/00-vincoli.md'] = $docs['docs/architecture/02-vincoli.md']
        $docs['docs/architecture/02-vincoli.md'] = $null
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^documento: sezione fuori ordine \(Vincoli\)' } | Should -Not -BeNullOrEmpty
    }

    It "Una sigla assente dal glossario fallisce anche se spiegata nel testo" {
        $docs = New-ValidDocs
        Edit-Docs $docs 'docs/architecture/12-glossario.md' '- **PE**: Private Endpoint, un indirizzo privato verso un servizio.' ''
        $res = Invoke-DocsCheck $docs
        Get-Issues $res.Output | Where-Object { $_ -match '^Concetti trasversali: termine senza glossario \(PE\)' } | Should -Not -BeNullOrEmpty
    }
}

Describe "MarkdownText — analisi del testo" {

    BeforeAll {
        . "$PSScriptRoot/../../V3/CI/Scripts/MarkdownText.ps1"
    }

    It "Divide le frasi su punto, punto esclamativo e punto interrogativo" {
        Get-Sentences 'Il BFF riceve. Chi chiama? Il Client!' @() | Should -Be @('Il BFF riceve.', 'Chi chiama?', 'Il Client!')
    }

    It "Non divide la frase dopo un'abbreviazione della guida di stile" {
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
