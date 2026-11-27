# SPDX-License-Identifier: Apache-2.0

# Propone con un modello linguistico le decisioni che la verifica delle classi (DecisionClasses.ps1)
# respinge, che hanno classi candidate (le classi dei namespace delle classi governate che nessun pattern
# della decisione copre e che il registro delle candidate, CANDIDATES_FILE, non ha gia' visto) o che il
# registro delle decisioni valutate (READABILITY_FILE) non ha nel testo corrente: la leggibilita' dei
# diagrammi la giudica il modello, una volta per testo. Il modello riceve la decisione, i rilievi, le
# candidate e il codice delle classi, e risponde con le voci da aggiungere a governs, le parti della
# struttura e del flusso nel codice e la riga della versione; la versione la alza lo script. La verifica
# delle classi, il flusso della decisione e il parser Mermaid accettano la stesura o la rimandano, fino a
# CLASSES_REPAIR_MAX_DRAFTS stesure; poi la decisione resta com'era e la verifica la segnala. Il modello
# propone e non respinge: una decisione non accettata non ferma il passo.
# Ogni decisione accettata va in un commit sul ramo di avanzamento (PROGRESS_BRANCH) con i registri: una
# run rilanciata riprende da li', applicando il lavoro salvato sopra il testo corrente di main, senza
# richiamare il modello per le decisioni gia' accettate.

. "$PSScriptRoot/../LanguageModel/LanguageModel.ps1"
. "$PSScriptRoot/DecisionClasses.ps1"
. "$PSScriptRoot/../Mermaid/DiagramFlows.ps1"

$Provider = $env:CLASSES_REPAIR_PROVIDER
$Endpoint = $env:CLASSES_REPAIR_ENDPOINT
$ModelName = $env:CLASSES_REPAIR_MODEL
$MaxTokens = [int]"0$env:CLASSES_REPAIR_MAX_TOKENS"
$ReasoningEffort = if ($env:CLASSES_REPAIR_REASONING_EFFORT) { $env:CLASSES_REPAIR_REASONING_EFFORT } else { 'high' }
$MaxDrafts = if ($env:CLASSES_REPAIR_MAX_DRAFTS) { [math]::Max(1, [int]$env:CLASSES_REPAIR_MAX_DRAFTS) } else { 3 }
$CandidatesFile = $env:CANDIDATES_FILE
$ReadabilityFile = $env:READABILITY_FILE
$ProgressBranch = "$env:PROGRESS_BRANCH" -replace '^refs/heads/', ''
$GuidePath = $env:STYLE_GUIDE

$RepairScope = 'proposta delle classi delle decisioni'
$VersionsSection = $DocumentLanguage.AdrVersionsSection
$RequestTimeoutSeconds = 900

$script:LanguageModel = $null
$script:Usage = @{ Requests = 0; Input = 0; Output = 0 }

$Instructions = @'
Aggiorni una decisione architetturale (ADR in Markdown) perche' i suoi diagrammi delle classi tornino a
corrispondere al codice che la decisione governa e restino leggibili. La decisione dichiara nel
frontmatter governs i pattern sui nomi completi delle classi governate: prefissi che finiscono con * e
contengono per intero il namespace di ogni classe che coprono. Ogni classe del codice che un pattern
copre deve comparire, con il suo nome senza namespace, in un diagramma delle classi Mermaid della parte
della struttura nel codice; ogni voce di governs copre almeno una classe.
Il diagramma disegna solo le classi governate e le relazioni fra loro: una classe che nessun pattern
copre, del framework, vicina alle classi governate o assente dal codice, non sta nel diagramma.

Il messaggio riporta la decisione con il numero di ogni riga, i rilievi della verifica, le classi
candidate e il codice delle classi.

- Una classe candidata e' una classe del codice nei namespace delle classi governate che nessun pattern
  copre. Proponi di governarla solo se appartiene alla decisione: realizza un contratto governato, ne e'
  una variante o partecipa al meccanismo che la decisione descrive. Per governarla aggiungi a governs un
  pattern: il suo nome completo seguito da *, oppure un prefisso piu' corto con * se copre solo classi
  che appartengono alla decisione. Il prefisso contiene sempre per intero il namespace della classe: una
  voce non e' mai il nome di una sola classe ne' un namespace intero. Non togliere voci di governs.
  Una classe candidata entra nel diagramma solo con la voce di governs che la copre.
- Ogni diagramma delle classi resta leggibile alla larghezza della pagina della wiki. Giudica sempre la
  leggibilita', anche senza rilievi ne' candidate: quando le classi governate sono troppe per un solo
  diagramma leggibile, dividile in piu' diagrammi, uno per aspetto della decisione, ciascuno
  preceduto da una frase che dice quale aspetto mostra. Ogni classe governata compare in almeno un
  diagramma; una classe compare in due diagrammi solo come estremita' di una relazione che li collega.
- La parte della struttura nel codice e' il testo che sta sotto il suo titolo, fino al titolo successivo,
  senza il titolo: i diagrammi delle classi e la spiegazione di ogni classe e di ogni relazione. Riscrivila
  solo dove serve: aggiungi le classi governate che mancano con le loro relazioni e la loro spiegazione,
  togli le classi che nessun pattern copre, dividi i diagrammi che non si leggono, lascia com'e' il resto.
- Il flusso nel codice usa come partecipanti solo classi dei diagrammi delle classi. La sua parte e' il
  testo sotto il suo titolo, fino al titolo successivo, senza il titolo: riscrivila solo se un partecipante
  non sta piu' nei diagrammi, togliendolo con i suoi messaggi o sostituendolo con la classe governata che
  fa quel passo.
- version e' una riga breve che dice cosa cambia in questa versione, per esempio: classi del biglietto
  aggiunte al diagramma.

Rispondi con:
- governs: le voci da aggiungere, anche nessuna;
- structure: la parte della struttura nel codice riscritta, oppure una stringa vuota se non cambia;
- flow: la parte del flusso nel codice riscritta, oppure una stringa vuota se non cambia;
- version: la riga della versione.
Senza rilievi ne' candidate e con ogni diagramma leggibile, governs, structure e flow restano vuoti.
Se il messaggio riporta una stesura scartata, la nuova stesura evita i motivi dello scarto.
'@

function New-RepairSchema {
    return @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('governs', 'structure', 'flow', 'version')
        properties           = @{
            governs   = @{ type = 'array'; items = @{ type = 'string' } }
            structure = @{ type = 'string' }
            flow      = @{ type = 'string' }
            version   = @{ type = 'string' }
        }
    }
}

function Get-SystemMessage {
    $guide = if ($GuidePath -and (Test-Path $GuidePath -PathType Leaf)) { Get-Content -Raw $GuidePath } else { '' }
    return "$Instructions`nGUIDA DI STILE:`n$guide"
}

function Invoke-Writer([string]$System, [string]$User) {
    $answer = Invoke-LanguageModel $script:LanguageModel $System $User (New-RepairSchema) 'decision_classes_repair'
    $script:Usage.Requests++
    $script:Usage.Input += $answer.Usage.Input
    $script:Usage.Output += $answer.Usage.Output
    return $answer.Response
}

# Il registro delle candidate: per ogni decisione i nomi completi delle classi che il modello ha gia' visto.
function Read-Candidates([string]$Json) {
    $ledger = @{}
    if (-not "$Json".Trim()) { return $ledger }
    $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @($parsed.PSObject.Properties)) { $ledger[$property.Name] = @($property.Value | Where-Object { $_ }) }
    return $ledger
}

function Read-CandidatesFile {
    if (-not $CandidatesFile -or -not (Test-Path $CandidatesFile -PathType Leaf)) { return @{} }
    return Read-Candidates ([IO.File]::ReadAllText($CandidatesFile))
}

function Write-LedgerFile([string]$Path, [hashtable]$Ledger, [scriptblock]$Value) {
    $ordered = [ordered]@{}
    $Ledger.Keys | Sort-Object | ForEach-Object { $ordered[$_] = & $Value $Ledger[$_] }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $ordered -Depth 4) + "`n")
}

function Save-Candidates([hashtable]$Ledger) {
    if (-not $CandidatesFile) { return }
    Write-LedgerFile $CandidatesFile $Ledger { param($names) , @($names | Sort-Object -Unique) }
}

# Il registro delle decisioni valutate: per ogni decisione l'impronta del testo che il modello ha giudicato.
function Get-TextHash([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Text -replace "`r`n", "`n"))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Read-Readability([string]$Json) {
    $ledger = @{}
    if (-not "$Json".Trim()) { return $ledger }
    $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    foreach ($property in @($parsed.PSObject.Properties)) { $ledger[$property.Name] = "$($property.Value)" }
    return $ledger
}

function Read-ReadabilityFile {
    if (-not $ReadabilityFile -or -not (Test-Path $ReadabilityFile -PathType Leaf)) { return @{} }
    return Read-Readability ([IO.File]::ReadAllText($ReadabilityFile))
}

function Save-Readability([hashtable]$Ledger) {
    if (-not $ReadabilityFile) { return }
    Write-LedgerFile $ReadabilityFile $Ledger { param($hash) $hash }
}

# Senza registro una decisione in pari non va al modello: la valuterebbe di nuovo a ogni run.
function Test-Evaluated($Decision, [hashtable]$Readability) {
    if (-not $ReadabilityFile) { return $true }
    return $Readability[$Decision.Id] -ceq (Get-TextHash ([IO.File]::ReadAllText($Decision.Section.File.FullName)))
}

function Get-Candidates($Decision, $Types, [hashtable]$Ledger) {
    $governed = @(Get-GovernedTypes $Types $Decision.Governs)
    $namespaces = @($governed | ForEach-Object { Get-Namespace $_.FullName } | Sort-Object -Unique)
    $seen = @($Ledger[$Decision.Id])
    return @($Types | Where-Object { $namespaces -ccontains (Get-Namespace $_.FullName) -and @($governed.FullName) -cnotcontains $_.FullName -and $seen -cnotcontains $_.FullName } |
            Sort-Object FullName -Unique)
}

function Format-NumberedLines([string]$Text) {
    $number = 0
    return (($Text -split "`r?`n") | ForEach-Object { $number++; "$number| $_" }) -join "`n"
}

function Format-ClassSources($Types) {
    $files = @($Types | ForEach-Object File | Sort-Object -Unique)
    return @($files | ForEach-Object { "FILE $(Get-RelativePath $_)`n$([IO.File]::ReadAllText($_))" }) -join "`n`n"
}

function Get-RepairMessage($Decision, [string]$Text, [string[]]$Findings, $Candidates, $Types, $Previous, [string[]]$Rejections) {
    $governed = @(Get-GovernedTypes $Types $Decision.Governs)
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add("RILIEVI DELLA VERIFICA`n$(if ($Findings) { ($Findings | ForEach-Object { "- $_" }) -join "`n" } else { '- nessuno' })")
    $parts.Add("CLASSI CANDIDATE`n$(if ($Candidates) { ($Candidates | ForEach-Object { "- $($_.FullName)" }) -join "`n" } else { '- nessuna' })")
    if ($Rejections) {
        $parts.Add("STESURA SCARTATA`n$($Previous | ConvertTo-Json -Depth 6)`nMotivi dello scarto:`n$(($Rejections | ForEach-Object { "- $_" }) -join "`n")")
    }
    $parts.Add("DECISIONE $($Decision.Id)`n$(Format-NumberedLines $Text)")
    $parts.Add("CODICE DELLE CLASSI`n$(Format-ClassSources (@($governed) + @($Candidates)))")
    return $parts -join "`n`n"
}

function Get-FrontMatterEnd([string[]]$Lines) {
    if ($Lines[0] -ne '---') { return -1 }
    return [Array]::IndexOf($Lines, '---', 1)
}

# Le voci nuove vanno in fondo alla lista governs, la versione nel campo version.
function Set-FrontMatter([Collections.Generic.List[string]]$Lines, [string[]]$Additions, [int]$Version) {
    $end = Get-FrontMatterEnd $Lines.ToArray()
    $governsLine = [Array]::FindIndex($Lines.ToArray(), [Predicate[string]] { param($line) $line -match "^${GovernsField}:\s*$" })
    if ($Additions -and $governsLine -ge 0 -and $governsLine -lt $end) {
        $last = $governsLine
        while ($last + 1 -lt $end -and $Lines[$last + 1] -match '^\s+-\s+') { $last++ }
        $Lines.InsertRange($last + 1, [string[]]@($Additions | ForEach-Object { "  - $_" }))
        $end += $Additions.Count
    }
    $versionLine = [Array]::FindIndex($Lines.ToArray(), [Predicate[string]] { param($line) $line -match '^version:' })
    if ($versionLine -ge 0 -and $versionLine -lt $end) { $Lines[$versionLine] = "version: $Version" }
    else { $Lines.Insert($end, "version: $Version") }
}

function Get-PartRange([string[]]$Lines, [string]$Name) {
    $start = [Array]::FindIndex($Lines, [Predicate[string]] { param($line) $line -match "^##\s+$([regex]::Escape($Name))\s*$" })
    if ($start -lt 0) { return $null }
    $next = $start + 1
    $fence = $false
    while ($next -lt $Lines.Count) {
        if ($Lines[$next] -match '^\s*```') { $fence = -not $fence }
        elseif (-not $fence -and $Lines[$next] -match '^##\s') { break }
        $next++
    }
    return @{ Start = $start; End = $next }
}

function Set-PartText([Collections.Generic.List[string]]$Lines, [string]$Name, [string]$Text) {
    $range = Get-PartRange $Lines.ToArray() $Name
    if (-not $range) { return }
    $body = @('') + @("$Text".Trim() -split "`r?`n") + @('')
    $Lines.RemoveRange($range.Start + 1, $range.End - $range.Start - 1)
    $Lines.InsertRange($range.Start + 1, [string[]]$body)
}

# Il modello a volte scrive la nota gia' come voce, con il segno dell'elenco e il numero: il numero
# della voce e' quello della versione nuova, una volta sola.
function Add-VersionEntry([Collections.Generic.List[string]]$Lines, [int]$Version, [string]$Note) {
    $entry = "- ${Version}: $("$Note".Trim() -replace '^(?:-\s+)?(?:\d+\s*:\s*)+', '')"
    $range = Get-PartRange $Lines.ToArray() $VersionsSection
    if (-not $range) {
        while ($Lines.Count -and -not $Lines[$Lines.Count - 1].Trim()) { $Lines.RemoveAt($Lines.Count - 1) }
        $Lines.AddRange([string[]]@('', "## $VersionsSection", '', $entry, ''))
        return
    }
    $last = $range.End - 1
    while ($last -gt $range.Start -and -not $Lines[$last].Trim()) { $last-- }
    $Lines.Insert($last + 1, $entry)
}

function Get-DecisionVersion([string]$Text) {
    $declared = "$((Get-FrontMatter $Text)['version'])"
    if ($declared -match '^\d+$') { return [int]$declared }
    return 1
}

# Una voce senza * e' il nome di una classe: diventa il prefisso del suo nome.
function ConvertTo-GovernsPattern([string]$Entry) {
    $entry = $Entry.Trim()
    if (-not $entry -or $entry.EndsWith('*')) { return $entry }
    return "$entry*"
}

# La stesura applicata al testo della decisione: voci di governs in piu', struttura e flusso riscritti,
# versione nuova con la sua voce. Torna $null se la stesura non cambia la decisione.
function Get-DraftText([string]$Original, $Draft, [string[]]$Governs) {
    $additions = @($Draft.governs | ForEach-Object { ConvertTo-GovernsPattern $_ } | Where-Object { $_ -and $Governs -cnotcontains $_ } | Select-Object -Unique)
    $structure = "$($Draft.structure)"
    $flow = "$($Draft.flow)"
    if (-not $additions -and -not $structure.Trim() -and -not $flow.Trim()) { return $null }
    $newline = if ($Original.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]::new([string[]]($Original -split "`r?`n"))
    $version = (Get-DecisionVersion $Original) + 1
    Set-FrontMatter $lines $additions $version
    if ($structure.Trim()) { Set-PartText $lines $StructureSection $structure }
    if ($flow.Trim()) { Set-PartText $lines $FlowSection $flow }
    Add-VersionEntry $lines $version $Draft.version
    return $lines -join $newline
}

function Get-DecisionFindings([string]$Id, $Types) {
    $decision = @(Get-Decisions | Where-Object Id -EQ $Id)
    if (-not $decision) { return @("decisione $Id non letta") }
    $diagrams = @(Get-Diagrams @($decision[0].Section))
    Add-ParsedDiagrams $diagrams
    @($diagrams | Where-Object { $_.Parsed.error }) | ForEach-Object { "diagramma non valido ($($_.Id) $($_.Parsed.error))" }
    Add-DiagramClasses $decision
    Get-DecisionClassIssues $decision[0] $Types
    @(Get-DecisionFlowFindings $decision[0].Section $diagrams) | ForEach-Object Text
}

# Una stesura si scrive nel file solo se le verifiche la accettano; altrimenti il file torna com'era e i
# motivi vanno al modello con la stesura successiva. Una stesura che non cambia nulla e' accettata quando
# la decisione non ha rilievi: il modello ha solo visto le candidate.
function Repair-Decision($Decision, [string[]]$Findings, $Candidates, $Types) {
    $path = $Decision.Section.File.FullName
    $original = [IO.File]::ReadAllText($path)
    $system = Get-SystemMessage
    $previous = $null
    $rejections = @()
    for ($draft = 1; $draft -le $MaxDrafts; $draft++) {
        $answer = Invoke-Writer $system (Get-RepairMessage $Decision $original $Findings $Candidates $Types $previous $rejections)
        $text = Get-DraftText $original $answer $Decision.Governs
        if ($null -eq $text) {
            if (-not $Findings) { return $true }
            $rejections = @('la stesura non cambia la decisione, che la verifica respinge')
        }
        else {
            [IO.File]::WriteAllText($path, $text)
            $rejections = @(Get-DecisionFindings $Decision.Id $Types)
            if (-not $rejections) { return $true }
            [IO.File]::WriteAllText($path, $original)
        }
        Write-Host "Stesura $draft di $($Decision.Id) scartata: $($rejections -join '; ')"
        $previous = $answer
    }
    return $false
}

function Get-GitAuthorization {
    if ($env:SYSTEM_ACCESSTOKEN) { return @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") }
    return @()
}

function Get-RepositoryPath([string]$Path) {
    $root = "$(git rev-parse --show-toplevel 2>$null)".Trim()
    return [IO.Path]::GetRelativePath($root, [IO.Path]::GetFullPath($Path)) -replace '\\', '/'
}

function Test-ProgressBranch {
    if (-not $ProgressBranch) { return $false }
    $authorization = Get-GitAuthorization
    $found = git @authorization ls-remote origin "refs/heads/$ProgressBranch" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not "$found".Trim()) { $global:LASTEXITCODE = 0; return $false }
    $out = git @authorization fetch -q origin "+refs/heads/${ProgressBranch}:refs/remotes/origin/$ProgressBranch" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ramo $ProgressBranch non letto: $out" }
    return $true
}

function Get-ProgressFile([string]$Path) {
    if (-not $Path) { return $null }
    $content = git show "refs/remotes/origin/${ProgressBranch}:$(Get-RepositoryPath $Path)" 2>$null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $null }
    return ($content -join "`n") + "`n"
}

function Get-PartText([string]$Text, [string]$Name) {
    $lines = $Text -split "`r?`n"
    $range = Get-PartRange $lines $Name
    if (-not $range -or $range.End - $range.Start -le 1) { return '' }
    return ($lines[($range.Start + 1)..($range.End - 1)] -join "`n").Trim()
}

function Get-VersionEntries([string]$Text) {
    $lines = $Text -split "`r?`n"
    $range = Get-PartRange $lines $VersionsSection
    if (-not $range -or $range.End - $range.Start -le 1) { return @() }
    return @($lines[($range.Start + 1)..($range.End - 1)] | Where-Object { $_ -match '^-\s+\d+:' } | ForEach-Object { $_.TrimEnd() })
}

function Get-CommonCount([string[]]$Left, [string[]]$Right) {
    $count = 0
    while ($count -lt $Left.Count -and $count -lt $Right.Count -and $Left[$count] -ceq $Right[$count]) { $count++ }
    return $count
}

function Get-Governs([string]$Text) {
    return @((Get-FrontMatter $Text)[$GovernsField] | Where-Object { $_ })
}

# Una decisione accepted cambia solo con una versione nuova: il testo da cui il modello e' partito e' quello
# della storia di main con le sole voci di versione comuni al ramo di avanzamento.
function Find-MainText([string]$Path, [string[]]$Entries) {
    $relative = Get-RepositoryPath $Path
    foreach ($commit in @(git log --format=%H HEAD -- $relative 2>$null)) {
        $content = git show "${commit}:$relative" 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $text = ($content -join "`n") + "`n"
        $found = @(Get-VersionEntries $text)
        if ($found.Count -eq $Entries.Count -and (Get-CommonCount $found $Entries) -eq $Entries.Count) { return $text }
    }
    $global:LASTEXITCODE = 0
    return $null
}

function Get-ResumedPart([string]$Base, [string]$Progress, [string]$Current, [string]$Name) {
    $basePart = Get-PartText $Base $Name
    $part = Get-PartText $Progress $Name
    if ($part -ceq $basePart -or (Get-PartText $Current $Name) -cne $basePart) { return '' }
    return $part
}

# Il lavoro del modello sul ramo, rispetto al testo da cui e' partito, applicato sopra il testo corrente di
# main: le voci di governs per classi che main non governa, la struttura e il flusso se main non li ha
# cambiati, e una versione nuova con le righe delle versioni del ramo.
function Get-ResumedText([string]$Base, [string]$Progress, [string]$Current, [string[]]$Notes, $Types) {
    $baseGoverns = Get-Governs $Base
    $currentGoverns = Get-Governs $Current
    $governed = @((Get-GovernedTypes $Types $currentGoverns).FullName)
    $additions = @(Get-Governs $Progress | Where-Object { $baseGoverns -cnotcontains $_ } |
            Where-Object { @((Get-GovernedTypes $Types @($_)).FullName | Where-Object { $governed -cnotcontains $_ }).Count })
    $draft = [pscustomobject]@{
        governs   = $additions
        structure = Get-ResumedPart $Base $Progress $Current $StructureSection
        flow      = Get-ResumedPart $Base $Progress $Current $FlowSection
        version   = ($Notes -join '; ')
    }
    return Get-DraftText $Current $draft $currentGoverns
}

# Le voci di versione del ramo oltre quelle comuni con main sono il lavoro del modello; se main non ha voci
# oltre quelle comuni, il modello e' partito dal testo corrente.
function Get-ResumedDecision([string]$Path, [string]$Progress, [string]$Current, $Types) {
    $saved = @(Get-VersionEntries $Progress)
    $own = @(Get-VersionEntries $Current)
    $common = Get-CommonCount $saved $own
    $notes = @($saved | Select-Object -Skip $common | ForEach-Object { $_ -replace '^-\s+(\d+:\s*)+', '' })
    if (-not $notes) { return $null }
    $base = if ($own.Count -eq $common) { $Current } else { Find-MainText $Path @($saved | Select-Object -First $common) }
    if ($null -eq $base) { return $null }
    return Get-ResumedText $base $Progress $Current $notes $Types
}

# Torna vero se la decisione del ramo, applicata sopra main, entra nella copia di lavoro.
function Restore-Decision($Decision, [string]$Progress, $Types) {
    $path = $Decision.Section.File.FullName
    $current = [IO.File]::ReadAllText($path)
    if (($Progress -replace "`r`n", "`n") -eq ($current -replace "`r`n", "`n")) { return $false }
    $resumed = Get-ResumedDecision $path $Progress $current $Types
    if (-not $resumed) { return $false }
    [IO.File]::WriteAllText($path, $resumed)
    if (@(Get-DecisionFindings $Decision.Id $Types)) { [IO.File]::WriteAllText($path, $current); return $false }
    Write-Host "Decisione $($Decision.Id) ripresa dal ramo $ProgressBranch"
    return $true
}

# Le decisioni del ramo di avanzamento, gia' accettate da una run interrotta, tornano nella copia di lavoro
# applicate sopra main, se la verifica le accetta ancora. Il registro del ramo si unisce a quello di main,
# tranne le classi che il modello aveva aggiunto a governs e che la decisione ripresa non governa: tornano
# candidate. Una decisione valutata sul ramo resta valutata nel testo ripreso.
function Resume-Progress($Decisions, $Types, [hashtable]$Ledger, [hashtable]$Readability) {
    if (-not (Test-ProgressBranch)) { return }
    $saved = Read-Candidates (Get-ProgressFile $CandidatesFile)
    $judged = Read-Readability (Get-ProgressFile $ReadabilityFile)
    $lost = @{}
    foreach ($decision in $Decisions) {
        $path = $decision.Section.File.FullName
        $progress = Get-ProgressFile $path
        if ($null -eq $progress) { continue }
        $resumed = Restore-Decision $decision $progress $Types
        $final = [IO.File]::ReadAllText($path)
        $hash = $judged[$decision.Id]
        if ($hash -and ($hash -ceq (Get-TextHash $final) -or ($resumed -and $hash -ceq (Get-TextHash $progress)))) { $Readability[$decision.Id] = Get-TextHash $final }
        $kept = @((Get-GovernedTypes $Types (Get-Governs $final)).FullName)
        $lost[$decision.Id] = @((Get-GovernedTypes $Types (Get-Governs $progress)).FullName | Where-Object { $kept -cnotcontains $_ })
    }
    foreach ($id in $saved.Keys) {
        $Ledger[$id] = @(@($Ledger[$id]) + @($saved[$id]) | Where-Object { $_ -and @($lost[$id]) -cnotcontains $_ } | Sort-Object -Unique)
    }
}

function New-Progress {
    return @{ Worktree = $null }
}

function Remove-Progress($Progress) {
    if (-not $Progress.Worktree) { return }
    git worktree remove --force $Progress.Worktree 2>&1 | Out-Null
    $global:LASTEXITCODE = 0
}

function Publish-Progress($Progress, [string[]]$Paths, [string]$Label) {
    if (-not $ProgressBranch) { return }
    $authorization = Get-GitAuthorization
    if (-not $Progress.Worktree) {
        $worktree = Join-Path ([IO.Path]::GetTempPath()) "decision-classes-$(New-Guid)"
        $start = if (git rev-parse -q --verify "refs/remotes/origin/$ProgressBranch" 2>$null) { "refs/remotes/origin/$ProgressBranch" } else { 'HEAD' }
        $out = git worktree add -q --detach $worktree $start 2>&1
        if ($LASTEXITCODE -ne 0) { throw "copia del ramo $ProgressBranch non creata: $out" }
        $Progress.Worktree = $worktree
    }
    foreach ($path in @($Paths | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) })) {
        $relative = Get-RepositoryPath $path
        $target = Join-Path $Progress.Worktree $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        Copy-Item $path $target -Force
        git -C $Progress.Worktree add -- $relative
    }
    $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Documentation' }
    $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'documentation@noreply.local' }
    $out = git -C $Progress.Worktree -c "user.name=$name" -c "user.email=$email" commit -q --allow-empty -m "docs: classes of $Label" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "commit della decisione non riuscito: $out" }
    $out = git -C $Progress.Worktree @authorization push -q origin "HEAD:refs/heads/$ProgressBranch" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "push sul ramo $ProgressBranch non riuscito: $out" }
    Write-Host "Ramo $ProgressBranch aggiornato con le classi di $Label"
}

# Il modello non toglie voci di governs: una decisione con voci che non sono pattern validi non gli va.
function Get-PendingDecisions($Decisions, $Types, [hashtable]$Ledger, [hashtable]$Readability) {
    foreach ($decision in $Decisions) {
        $entryIssues = @(Get-GovernsEntryIssues $decision $Types)
        if ($entryIssues) {
            Write-Host "##vso[task.logissue type=warning]Decisione $($decision.Id) non proposta: voci di $GovernsField da riscrivere come pattern ($($entryIssues -join '; '))"
            continue
        }
        $findings = @(Get-DecisionClassIssues $decision $Types)
        $candidates = @(Get-Candidates $decision $Types $Ledger)
        if ($findings -or $candidates -or -not (Test-Evaluated $decision $Readability)) { [pscustomobject]@{ Decision = $decision; Findings = $findings; Candidates = $candidates } }
    }
}

function Repair-DecisionClasses {
    $decisions = @(Get-Decisions | Where-Object { $_.Governs })
    if (-not $decisions) { return }
    if (-not (Test-Path $SourceDirectory -PathType Container)) { return New-Issue $RepairScope 'codice sorgente assente' $SourceDirectory }

    $types = @(Get-ProductionTypes (Read-DotNetProjects))
    $ledger = Read-CandidatesFile
    $readability = Read-ReadabilityFile
    try { Resume-Progress $decisions $types $ledger $readability }
    catch { return New-Issue $RepairScope 'proposta interrotta non ripresa' $_.Exception.Message }

    $decisions = @(Get-Decisions | Where-Object { $_.Governs })
    Add-DiagramClasses $decisions
    $pending = @(Get-PendingDecisions $decisions $types $ledger $readability)
    Save-Candidates $ledger
    Save-Readability $readability
    if (-not $pending) { return }
    try { $script:LanguageModel = New-LanguageModel $Provider $Endpoint $ModelName $ReasoningEffort -AccessToken $env:CLASSES_REPAIR_TOKEN -MaxTokens $MaxTokens -TimeoutSeconds $RequestTimeoutSeconds }
    catch { return New-Issue $RepairScope 'proposta non eseguita' $_.Exception.Message }

    $progress = New-Progress
    try {
        foreach ($item in $pending) {
            try { $accepted = Repair-Decision $item.Decision $item.Findings $item.Candidates $types }
            catch { return New-Issue $RepairScope 'proposta interrotta' "$($item.Decision.Id): $($_.Exception.Message)" }
            if (-not $accepted) { Write-Host "##vso[task.logissue type=warning]Decisione $($item.Decision.Id) non aggiornata: la verifica delle classi la segnala"; continue }
            $ledger[$item.Decision.Id] = @(@($ledger[$item.Decision.Id]) + @($item.Candidates.FullName) | Where-Object { $_ } | Sort-Object -Unique)
            Save-Candidates $ledger
            $readability[$item.Decision.Id] = Get-TextHash ([IO.File]::ReadAllText($item.Decision.Section.File.FullName))
            Save-Readability $readability
            Publish-Progress $progress @($item.Decision.Section.File.FullName, $CandidatesFile, $ReadabilityFile) $item.Decision.Id
        }
    }
    catch { return New-Issue $RepairScope 'proposta non salvata' $_.Exception.Message }
    finally {
        Remove-Progress $progress
        Write-Host "Proposta delle classi delle decisioni: $($script:Usage.Requests) richieste, $($script:Usage.Input) token in ingresso, $($script:Usage.Output) in uscita"
    }
}

Invoke-Verification { Repair-DecisionClasses } "Classi delle decisioni in $decisionsDirectory proposte" 'Proposta delle classi delle decisioni disattivata'
