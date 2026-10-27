# Documento valido condiviso dalle prove dei moduli di verifica della documentazione: le dodici
# sezioni del template arc42 italiano, un modello C4, un diagramma Mermaid, testo entro le soglie
# di leggibilita'. Ogni scenario vi introduce un solo difetto e lancia lo script come in pipeline.

$Arc42TemplateArchive = Join-Path $PSScriptRoot 'arc42-template-IT-plain-markdownMP.zip'

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
        utente = person "Utente"
        sistema = softwareSystem "Piattaforma" {
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
        utente -> client "usa"
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
        systemContext sistema "contesto" {
            include *
        }
        container sistema "contenitori" {
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
        deployment sistema produzione "deployment-produzione" {
            include *
        }
    }
}
'@
    $docs['docs/architecture/01_introduction_and_goals.md'] = New-Section 'Introduzione e obiettivi' 'a cosa serve la piattaforma?' @'
La piattaforma aiuta il utente a parlare con un operatore dell'assistenza.

Il Backend for Frontend (BFF) riceve le richieste del Client. L'interfaccia di programmazione del Motore (API) esegue il lavoro.
'@
    $docs['docs/architecture/02_architecture_constraints.md'] = New-Section 'Vincoli di architettura' 'quali limiti valgono per tutto il progetto?' @'
La piattaforma gira su Azure. Il codice vive nei repository del progetto.
'@
    $docs['docs/architecture/03_context_and_scope.md'] = New-Section 'Ambito e contesto del sistema' 'chi usa la piattaforma?' @'
<!-- vista: contesto -->

Il Utente usa la Piattaforma dal telefono o dal computer.
'@
    $docs['docs/architecture/04_solution_strategy.md'] = New-Section 'Strategia della soluzione' 'come è divisa la piattaforma?' @'
La piattaforma divide il lavoro fra applicazioni piccole. Ogni applicazione fa una cosa sola.
'@
    $docs['docs/architecture/05_building_block_view.md'] = (New-Section 'Building Block View' 'di quali parti è fatta la piattaforma?' @'
<!-- vista: contenitori -->

Il Utente usa il Client per aprire una richiesta.

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
Una risposta arriva al utente in meno di due secondi.
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

# Lo stesso documento con le convenzioni inglesi (Languages/EN.psd1): marcatori di vista e tag
# dei container. Il testo resta quello italiano, perche' le convenzioni non lo riguardano.
function ConvertTo-EnglishConventions([System.Collections.IDictionary]$Docs) {
    foreach ($path in @($Docs.Keys)) {
        if ($null -eq $Docs[$path]) { continue }
        $Docs[$path] = $Docs[$path].Replace('<!-- vista:', '<!-- view:').Replace('"Applicazione"', '"Application"')
    }
    return $Docs
}

function Edit-Docs([System.Collections.IDictionary]$Docs, [string]$Path, [string]$Old, [string]$New) {
    if (-not $Docs[$Path].Contains($Old)) { throw "Fixture: '$Old' assente da $Path" }
    $Docs[$Path] = $Docs[$Path].Replace($Old, $New)
}

# Scrive il documento in una cartella nuova e vi lancia lo script in un processo separato, con le
# variabili d'ambiente indicate (GATE_MODE compresa) ripristinate al termine.
function Invoke-DocsScript([string]$ScriptPath, [System.Collections.IDictionary]$Docs, [hashtable]$Environment = @{}) {
    $root = Join-Path ([IO.Path]::GetTempPath()) "pester-docs-$(New-Guid)"
    foreach ($path in $Docs.Keys) {
        if ($null -eq $Docs[$path]) { continue }
        $file = Join-Path $root $path
        New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
        [IO.File]::WriteAllText($file, ($Docs[$path] -replace "`r`n", "`n"))
    }

    $previous = @{}
    foreach ($name in $Environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $Environment[$name])
    }
    Push-Location $root
    try {
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoProfile -NonInteractive -File $ScriptPath 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
    finally {
        Pop-Location
        foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
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
