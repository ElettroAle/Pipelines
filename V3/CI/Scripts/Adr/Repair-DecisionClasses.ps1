# SPDX-License-Identifier: Apache-2.0

# Propone con un modello linguistico le decisioni che la verifica delle classi (DecisionClasses.ps1)
# respinge o che hanno classi candidate: le classi dei namespace delle classi governate che nessun pattern
# della decisione copre e che il registro delle candidate (CANDIDATES_FILE) non ha gia' visto. Il modello
# riceve la decisione, i rilievi, le candidate e il codice delle classi, e risponde con le voci da
# aggiungere a governs, la parte della struttura nel codice e la riga della versione; la versione la alza
# lo script. La verifica delle classi, il flusso della decisione e il parser Mermaid accettano la stesura o
# la rimandano, fino a CLASSES_REPAIR_MAX_DRAFTS stesure; poi la decisione resta com'era e la verifica la
# segnala. Il modello propone e non respinge: una decisione non accettata non ferma il passo.
# Ogni decisione accettata va in un commit sul ramo di avanzamento (PROGRESS_BRANCH) con il registro: una
# run rilanciata riprende da li' senza richiamare il modello per le decisioni gia' accettate.

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
$ProgressBranch = "$env:PROGRESS_BRANCH" -replace '^refs/heads/', ''
$GuidePath = $env:STYLE_GUIDE

$RepairScope = 'proposta delle classi delle decisioni'
$VersionsSection = $DocumentLanguage.AdrVersionsSection
$RequestTimeoutSeconds = 900

$script:LanguageModel = $null
$script:Usage = @{ Requests = 0; Input = 0; Output = 0 }

$Instructions = @'
Aggiorni una decisione architetturale (ADR in Markdown) perche' il suo diagramma delle classi torni a
corrispondere al codice che la decisione governa. La decisione dichiara nel frontmatter governs i pattern
sui nomi completi delle classi governate: un nome completo, o un prefisso che finisce con *. Ogni classe
del codice che un pattern copre deve comparire, con il suo nome senza namespace, nel diagramma delle
classi Mermaid della parte della struttura nel codice; ogni voce di governs copre almeno una classe.

Il messaggio riporta la decisione con il numero di ogni riga, i rilievi della verifica, le classi
candidate e il codice delle classi.

- Una classe candidata e' una classe del codice nei namespace delle classi governate che nessun pattern
  copre. Proponi di governarla solo se appartiene alla decisione: realizza un contratto governato, ne e'
  una variante o partecipa al meccanismo che la decisione descrive. Per governarla aggiungi a governs il
  suo nome completo, oppure un prefisso con * se copre solo classi che appartengono alla decisione. Non
  togliere voci di governs.
- La parte della struttura nel codice e' il testo che sta sotto il suo titolo, fino al titolo successivo,
  senza il titolo: il diagramma delle classi e la spiegazione di ogni classe e di ogni relazione. Riscrivila
  solo dove serve: aggiungi le classi governate che mancano con le loro relazioni e la loro spiegazione,
  togli le classi che il codice non ha piu', lascia com'e' il resto. Le classi del framework da cui una
  classe governata dipende possono restare nel diagramma.
- Il flusso nel codice usa come partecipanti le classi del diagramma: non togliere una classe che il flusso
  usa.
- version e' una riga breve che dice cosa cambia in questa versione, per esempio: classi del biglietto
  aggiunte al diagramma.

Rispondi con:
- governs: le voci da aggiungere, anche nessuna;
- structure: la parte della struttura nel codice riscritta, oppure una stringa vuota se non cambia;
- version: la riga della versione.
Se il messaggio riporta una stesura scartata, la nuova stesura evita i motivi dello scarto.
'@

function New-RepairSchema {
    return @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('governs', 'structure', 'version')
        properties           = @{
            governs   = @{ type = 'array'; items = @{ type = 'string' } }
            structure = @{ type = 'string' }
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

function Save-Candidates([hashtable]$Ledger) {
    if (-not $CandidatesFile) { return }
    $ordered = [ordered]@{}
    $Ledger.Keys | Sort-Object | ForEach-Object { $ordered[$_] = @($Ledger[$_] | Sort-Object -Unique) }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([IO.Path]::GetFullPath($CandidatesFile))) | Out-Null
    [IO.File]::WriteAllText($CandidatesFile, (ConvertTo-Json -InputObject $ordered -Depth 4) + "`n")
}

function Get-Namespace([string]$FullName) {
    $dot = $FullName.LastIndexOf('.')
    if ($dot -lt 0) { return '' }
    return $FullName.Substring(0, $dot)
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

function Set-StructurePart([Collections.Generic.List[string]]$Lines, [string]$Structure) {
    $range = Get-PartRange $Lines.ToArray() $StructureSection
    $body = @('') + @("$Structure".Trim() -split "`r?`n") + @('')
    $Lines.RemoveRange($range.Start + 1, $range.End - $range.Start - 1)
    $Lines.InsertRange($range.Start + 1, [string[]]$body)
}

function Add-VersionEntry([Collections.Generic.List[string]]$Lines, [int]$Version, [string]$Note) {
    $entry = "- ${Version}: $("$Note".Trim())"
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

# La stesura applicata al testo della decisione: voci di governs in piu', struttura riscritta, versione
# nuova con la sua voce. Torna $null se la stesura non cambia la decisione.
function Get-DraftText([string]$Original, $Draft, [string[]]$Governs) {
    $additions = @($Draft.governs | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $Governs -cnotcontains $_ } | Select-Object -Unique)
    $structure = "$($Draft.structure)"
    if (-not $additions -and -not $structure.Trim()) { return $null }
    $newline = if ($Original.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]::new([string[]]($Original -split "`r?`n"))
    $version = (Get-DecisionVersion $Original) + 1
    Set-FrontMatter $lines $additions $version
    if ($structure.Trim()) { Set-StructurePart $lines $structure }
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
    $content = git show "refs/remotes/origin/${ProgressBranch}:$(Get-RepositoryPath $Path)" 2>$null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $null }
    return ($content -join "`n") + "`n"
}

# Le decisioni e il registro del ramo di avanzamento, gia' accettati da una run interrotta, tornano nella
# copia di lavoro se la verifica li accetta ancora.
function Resume-Progress($Decisions, $Types, [hashtable]$Ledger) {
    if (-not (Test-ProgressBranch)) { return }
    $saved = Read-Candidates (Get-ProgressFile $CandidatesFile)
    foreach ($id in $saved.Keys) { $Ledger[$id] = @(@($Ledger[$id]) + @($saved[$id]) | Where-Object { $_ } | Sort-Object -Unique) }
    foreach ($decision in $Decisions) {
        $path = $decision.Section.File.FullName
        $progress = Get-ProgressFile $path
        $current = [IO.File]::ReadAllText($path)
        if ($null -eq $progress -or ($progress -replace "`r`n", "`n") -eq ($current -replace "`r`n", "`n")) { continue }
        [IO.File]::WriteAllText($path, $progress)
        if (@(Get-DecisionFindings $decision.Id $Types)) { [IO.File]::WriteAllText($path, $current); continue }
        Write-Host "Decisione $($decision.Id) ripresa dal ramo $ProgressBranch"
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

function Get-PendingDecisions($Decisions, $Types, [hashtable]$Ledger) {
    foreach ($decision in $Decisions) {
        $findings = @(Get-DecisionClassIssues $decision $Types)
        $candidates = @(Get-Candidates $decision $Types $Ledger)
        if ($findings -or $candidates) { [pscustomobject]@{ Decision = $decision; Findings = $findings; Candidates = $candidates } }
    }
}

function Repair-DecisionClasses {
    $decisions = @(Get-Decisions | Where-Object { $_.Governs })
    if (-not $decisions) { return }
    if (-not (Test-Path $SourceDirectory -PathType Container)) { return New-Issue $RepairScope 'codice sorgente assente' $SourceDirectory }

    $types = @(Get-ProductionTypes (Read-DotNetProjects))
    $ledger = Read-CandidatesFile
    try { Resume-Progress $decisions $types $ledger }
    catch { return New-Issue $RepairScope 'proposta interrotta non ripresa' $_.Exception.Message }

    $decisions = @(Get-Decisions | Where-Object { $_.Governs })
    Add-DiagramClasses $decisions
    $pending = @(Get-PendingDecisions $decisions $types $ledger)
    Save-Candidates $ledger
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
            Publish-Progress $progress @($item.Decision.Section.File.FullName, $CandidatesFile) $item.Decision.Id
        }
    }
    catch { return New-Issue $RepairScope 'proposta non salvata' $_.Exception.Message }
    finally {
        Remove-Progress $progress
        Write-Host "Proposta delle classi delle decisioni: $($script:Usage.Requests) richieste, $($script:Usage.Input) token in ingresso, $($script:Usage.Output) in uscita"
    }
}

Invoke-Verification { Repair-DecisionClasses } "Classi delle decisioni in $decisionsDirectory proposte" 'Proposta delle classi delle decisioni disattivata'
