# SPDX-License-Identifier: Apache-2.0

# Giudica lo stile delle sezioni e delle decisioni di un documento con un modello linguistico: la guida
# di stile del repository e' l'istruzione del modello, e la pipeline non conosce nessuna regola. Ogni
# tipo di documento ha il suo profilo: le regole che valgono per lui e i titoli che il suo modello impone.
# In una PR si giudicano le righe cambiate dall'ultimo giudizio di ogni file; con STYLE_FIX le correzioni
# del modello, validate e rigiudicate in giri limitati, tornano sul ramo della PR un file alla volta.

. "$PSScriptRoot/Common/VerificationGate.ps1"
. "$PSScriptRoot/Common/MarkdownText.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$decisionsDirectory = if ($env:DECISIONS_DIRECTORY) { $env:DECISIONS_DIRECTORY } else { 'docs/decisions' }
$guidePath = if ($env:STYLE_GUIDE) { $env:STYLE_GUIDE } else { 'docs/STYLE.md' }
$glossaryFileName = $env:DOCS_GLOSSARY
$targetBranch = $env:TARGET_BRANCH -replace '^refs/heads/', '' -replace '^\$\(.*\)$', ''
$sourceBranch = $env:SOURCE_BRANCH -replace '^refs/heads/', '' -replace '^\$\(.*\)$', ''
$endpoint = "$env:STYLE_JUDGE_ENDPOINT".TrimEnd('/')
$model = $env:STYLE_JUDGE_MODEL
$seed = if ($env:STYLE_JUDGE_SEED) { [int]$env:STYLE_JUDGE_SEED } else { 1 }
$fixRequested = $env:STYLE_FIX -eq 'true'
$maxRounds = if ($env:STYLE_MAX_ROUNDS) { [math]::Max(1, [int]$env:STYLE_MAX_ROUNDS) } else { 4 }
$maxFindings = if ("$env:STYLE_MAX_FINDINGS" -match '^-?\d+$') { [int]$env:STYLE_MAX_FINDINGS } else { 0 }
$maximumWords = [int]$env:READABILITY_MAX_WORDS
$abbreviations = @("$env:READABILITY_ABBREVIATIONS" -split ';' | ForEach-Object Trim | Where-Object { $_ })

$SectionFilePattern = '^\d+[_-].+\.md$'
$JudgeScope = 'giudizio dello stile'
$CleanTrailer = 'Style-Judge: clean'
$DoneTrailer = 'Style-Judge-Done'
$SideBranchPrefix = 'style-judge'
# I commit del giudice non avviano le pipeline con trigger sui rami; la build della PR parte comunque.
$SkipCi = '[skip ci]'
$PendingTrailer = 'Style-Judge-Pending'
$PendingTextLength = 80
$MaxAttempts = 3
$RequestTimeoutSeconds = 600
$WrapWidth = 110
$LockedKinds = @('code', 'marker', 'separator', 'frontmatter')
# Una decisione sostituita, deprecata o respinta e' storia: non si giudica.
$ClosedStatuses = @('superseded', 'deprecated', 'rejected')
$ReferencePattern = '(?<!!)(\[[^\]]*\]\()([^)\s]+)(\))'
$ExternalReferencePattern = '^[a-z][a-z0-9+.-]*:'
$OpeningFencePattern = '^\s*(```|~~~)'
$BlockStartPattern = '^\s*(```|~~~|<!--|#{1,6}\s|>|\||(?:[-*+]|\d+\.)\s)'
# Una parola che, a inizio riga, trasformerebbe la riga in un titolo, un elenco, una citazione o una tabella.
$BlockWordPattern = '^(```|~~~|<!--|>|\||#{1,6}$|[-*+]$|\d+\.$)'

$script:SeedSupported = $true
$script:Token = $null
$script:Usage = @{ Requests = 0; Input = 0; Output = 0 }

$Instructions = @'
Sei il revisore della documentazione di una piattaforma software. Applichi soltanto le regole della
guida di stile che segue: nessun'altra regola, nessuna preferenza personale.

Il documento arriva diviso in unità numerate. Giudichi solo le unità segnate con l'asterisco, per
esempio [4*]; le altre unità e il glossario sono contesto. Il compito è uno spoglio completo, in
questa sola risposta: per ogni regola, nell'ordine della guida, esamini ogni unità segnata e riporti
ogni violazione nella voce di quella regola. Una voce vuota dice che nessuna unità segnata viola la
regola. Lo stesso testo non avrà un secondo giudizio: ciò che non riporti ora resta nel documento.

Per ogni violazione indichi il numero dell'unità, il tratto che viola la regola copiato alla
lettera, il motivo in una frase e la correzione:
- replace: find è un tratto dell'unità copiato alla lettera, che vi compare una volta sola; text lo
  sostituisce. Se l'unità viola la stessa regola in più punti, find li comprende tutti.
- insert: text è un paragrafo nuovo da aggiungere dopo l'unità indicata da fix.unit; find resta
  vuoto. Una voce nuova del glossario si aggiunge dopo la voce del glossario che la precede in ordine
  alfabetico, nella stessa forma delle altre voci.
- none: la violazione non si corregge cambiando il testo; find e text restano vuoti.
Una correzione non tocca diagrammi, blocchi di codice e commenti, non va a capo, rispetta tutte le
regole della guida. Una violazione in un titolo si corregge con replace sul titolo stesso: i rimandi a
quel titolo si aggiornano da soli. {TITOLI} Una violazione in un diagramma si corregge nel
testo che lo spiega, oppure è none. Una correzione deve togliere la violazione dall'unità che la
contiene: un paragrafo aggiunto altrove non la toglie. Se il messaggio riporta correzioni scartate nel
giro precedente, la nuova correzione di quell'unità evita il motivo dello scarto.

GUIDA DI STILE

'@

function Read-JudgeSetup {
    if (-not (Test-Path $guidePath -PathType Leaf)) { return @{ Issue = New-Issue $JudgeScope 'guida mancante' $guidePath } }
    if (-not $endpoint -or -not $model) { return @{ Issue = New-Issue $JudgeScope 'verifica non eseguita' 'endpoint o modello non configurati' } }
    $guide = [IO.File]::ReadAllText($guidePath)
    $rules = Get-GuideRules $guide
    if (-not $rules) { return @{ Issue = New-Issue $JudgeScope 'guida senza regole' $guidePath } }
    return @{ Guide = $guide; Rules = $rules }
}

# Le regole sono i titoli di terzo livello delle parti delle regole della guida: comuni, delle sezioni,
# delle decisioni. Una guida senza quelle parti ha solo regole comuni, tutti i suoi titoli di terzo
# livello; i titoli dentro gli esempi non contano. Il testo di una regola arriva fino al titolo dopo.
function Get-GuideRules([string]$Guide) {
    $headings = [Collections.Generic.List[object]]::new()
    $part = $null
    $current = $null
    $fence = $null
    foreach ($line in ($Guide -split "`r?`n")) {
        if ($fence) {
            if ($line -match $fence) { $fence = $null }
        }
        elseif ($line -match $OpeningFencePattern) { $fence = '^\s*' + [regex]::Escape($Matches[1]) + '\s*$' }
        elseif ($line -match '^##\s+(.+?)\s*$') { $part = $Matches[1]; $current = $null; continue }
        elseif ($line -match '^###\s+(.+?)\s*$') {
            $current = [pscustomobject]@{ Part = $part; Title = $Matches[1]; Lines = [Collections.Generic.List[string]]::new() }
            $headings.Add($current)
            continue
        }
        if ($current) { $current.Lines.Add($line) }
    }
    $parts = $DocumentLanguage.StyleRuleParts
    $inRules = @($headings | Where-Object { $_.Part -in $parts.Values })
    $selected = if ($inRules) { $inRules } else { @($headings | ForEach-Object { $_.Part = $parts.Common; $_ }) }
    return @($selected | ForEach-Object { [pscustomobject]@{ Part = $_.Part; Title = $_.Title; Text = ($_.Lines -join "`n").Trim() } })
}

function Select-ProfileRules($Rules, [string]$Kind) {
    $parts = $DocumentLanguage.StyleRuleParts
    $own = if ($Kind -eq 'decision') { $parts.Decisions } else { $parts.Sections }
    return @($Rules | Where-Object { $_.Part -in @($parts.Common, $own) })
}

# Le regole di un tipo di documento, indipendenti dalla parte in cui stanno e dal loro ordine: spostare
# una regola nella guida non la cambia.
function Get-RulesKey($Rules) {
    return (@($Rules | Sort-Object Title | ForEach-Object { "$($_.Title)`n$($_.Text)" }) -join "`n`n")
}

# Il modello non riceve le regole dell'altro tipo di documento, nemmeno con i loro esempi: altrimenti le
# applicherebbe lo stesso.
function Remove-GuidePart([string]$Guide, [string]$Part) {
    $kept = [Collections.Generic.List[string]]::new()
    $skipping = $false
    $fence = $null
    foreach ($line in ($Guide -split "`n")) {
        if ($fence) {
            if ($line -match $fence) { $fence = $null }
        }
        elseif ($line -match $OpeningFencePattern) { $fence = '^\s*' + [regex]::Escape($Matches[1]) + '\s*$' }
        elseif ($line -match '^##\s+(.+?)\s*$') { $skipping = $Matches[1] -eq $Part }
        if (-not $skipping) { $kept.Add($line) }
    }
    return $kept -join "`n"
}

# Il titolo di primo livello di una sezione e' quello del template arc42, e i titoli di secondo livello
# di una decisione sono le parti del modello MADR: li verificano i controlli oggettivi, non si correggono.
function New-DocumentProfile([string]$Kind, $Setup) {
    $parts = $DocumentLanguage.StyleRuleParts
    $decision = $Kind -eq 'decision'
    $other = if ($decision) { $parts.Sections } else { $parts.Decisions }
    $applicable = Select-ProfileRules $Setup.Rules $Kind
    $rules = @($applicable | ForEach-Object Title)
    $titles = if ($decision) { 'I titoli di secondo livello sono le parti del modello della decisione: non si correggono.' } else { 'Il titolo di primo livello è quello del modello del documento: non si corregge.' }
    return @{
        Kind               = $Kind
        RulesKey           = Get-RulesKey $applicable
        Label              = if ($decision) { 'DECISIONE DA GIUDICARE' } else { 'SEZIONE DA GIUDICARE' }
        LockedHeadingLevel = if ($decision) { 2 } else { 1 }
        WholeOnGuide       = -not $decision
        NamedByFile        = $decision
        Rules              = $rules
        System             = $Instructions.Replace('{TITOLI}', $titles) + (Remove-GuidePart $Setup.Guide $other)
        Schema             = New-FindingsSchema $rules
    }
}

function Get-DecisionStatus([string]$Path) {
    $raw = [IO.File]::ReadAllText($Path)
    if ($raw -notmatch '^---\r?\n([\s\S]*?)\r?\n---') { return $null }
    if ($Matches[1] -match '(?m)^status:\s*([\w-]+)') { return $Matches[1] }
    return $null
}

function Get-SectionFiles([string]$Directory) {
    return @(Get-ChildItem -Path $Directory -File -ErrorAction SilentlyContinue | Where-Object Name -Match $SectionFilePattern | Sort-Object Name)
}

function ConvertTo-RepositoryPath([string]$Path) {
    return ([IO.Path]::GetRelativePath((Get-Location).Path, $Path) -replace '\\', '/')
}

#region Ambito: le righe da giudicare

function Get-SourceCommit {
    $commits = @("$(git rev-list --parents -n 1 HEAD)" -split ' ')
    if ($commits.Count -ge 3) { return $commits[2] }
    return $commits[0]
}

function Get-ChangedLines([string[]]$Range) {
    $changed = @{}
    $file = $null
    $previous = ''
    git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --relative @Range -- $docsDirectory $decisionsDirectory $guidePath | ForEach-Object {
        if ($previous.StartsWith('--- ') -and $_ -match '^\+\+\+ (?:b/)?(.+?)\t?$') {
            $file = if ($Matches[1] -eq '/dev/null') { $null } else { $Matches[1] }
            if ($file -and -not $changed.ContainsKey($file)) { $changed[$file] = [Collections.Generic.HashSet[int]]::new() }
        }
        elseif ($file -and $_ -match '^@@ -\S+ \+(\d+)(?:,(\d+))? @@') {
            $start = [int]$Matches[1]
            $count = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
            $lines = if ($count -eq 0) { @($start, ($start + 1)) } else { $start..($start + $count - 1) }
            foreach ($line in $lines) { [void]$changed[$file].Add($line) }
        }
        $previous = $_
    }
    return $changed
}

function Select-CommonLines([hashtable]$First, [hashtable]$Second) {
    $common = @{}
    foreach ($file in $First.Keys) {
        if (-not $Second.ContainsKey($file)) { continue }
        $lines = [Collections.Generic.HashSet[int]]::new($First[$file])
        $lines.IntersectWith($Second[$file])
        if ($lines.Count) { $common[$file] = $lines }
    }
    return $common
}

# In una PR si giudica cio' che la PR cambia e che nessun giudizio ha gia' visto. Il segno e' per
# file: il commit del giudice nomina i file giudicati, e un commit con il trailer del giudizio
# superato vale per tutti. Fuori da una PR si giudica tutto il documento.
function Get-ReviewScope {
    $everything = @{ PullRequest = $false }
    if (-not $targetBranch) { return $everything }
    git rev-parse --verify --quiet "origin/$targetBranch^{commit}" > $null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $everything }

    $source = Get-SourceCommit
    return @{
        PullRequest = $true
        Source      = $source
        Base        = Get-ChangedLines @("origin/$targetBranch...HEAD")
        MergeBase   = "$(git merge-base "origin/$targetBranch" HEAD)".Trim()
        RulesAt     = @{}
        Judgements  = @(Get-Judgements "origin/$targetBranch..$source")
        Since       = @{}
        Guide       = ConvertTo-RepositoryPath (Resolve-Path $guidePath).Path
    }
}

# I commit del giudice, dal piu' recente: i file giudicati e, per file, l'inizio del testo delle
# unita' con violazioni rimaste, cercate per testo perche' i commit dopo possono spostare le righe.
function Get-Judgements([string]$Range) {
    $separator = [char]0x1e
    $log = (git log "--format=%H%n%B$separator" $Range) -join "`n"
    foreach ($record in ($log -split $separator)) {
        $lines = @($record.Trim() -split "`n")
        if (-not $lines[0]) { continue }
        $judgement = @{ Commit = $lines[0]; Clean = $lines -contains $CleanTrailer; Done = [Collections.Generic.HashSet[string]]::new(); Pending = @{} }
        foreach ($line in $lines) {
            if ($line -match "^${DoneTrailer}: (.+)$") { [void]$judgement.Done.Add($Matches[1]) }
            if ($line -notmatch "^${PendingTrailer}: ([^\t]+)\t([^\t]+)(?:\t(.+))?$") { continue }
            if (-not $judgement.Pending.ContainsKey($Matches[1])) { $judgement.Pending[$Matches[1]] = [Collections.Generic.List[object]]::new() }
            $judgement.Pending[$Matches[1]].Add(@{ Text = $Matches[2]; Finding = $Matches[3] })
        }
        if ($judgement.Clean -or $judgement.Done.Count) { $judgement }
    }
}

# Un documento si rigiudica tutto solo se cambiano le regole del suo tipo dal suo ultimo giudizio, o
# dall'inizio della PR. Le decisioni non si rigiudicano mai tutte: il loro profilo ha WholeOnGuide falso.
function Get-FileScope($Scope, [string]$RelativePath, $Profile) {
    if (-not $Scope.PullRequest) { return @{ All = $true; Lines = $null; Pending = @(); Findings = @{} } }
    $judgement = $Scope.Judgements | Where-Object { $_.Clean -or $_.Done.Contains($RelativePath) } | Select-Object -First 1
    $lines = $Scope.Base
    $pending = @()
    $findings = @{}
    if ($judgement) {
        if (-not $Scope.Since.ContainsKey($judgement.Commit)) {
            Write-Host "Ultimo giudizio di ${RelativePath}: $($judgement.Commit)"
            $Scope.Since[$judgement.Commit] = Select-CommonLines $Scope.Base (Get-ChangedLines @($judgement.Commit, 'HEAD'))
        }
        $lines = $Scope.Since[$judgement.Commit]
        if ($judgement.Pending.ContainsKey($RelativePath)) {
            $pending = @($judgement.Pending[$RelativePath] | ForEach-Object { $_.Text })
            $judgement.Pending[$RelativePath] | Where-Object { $_.Finding } | ForEach-Object { $findings[$_.Text] = $_.Finding }
        }
    }
    $since = if ($judgement) { $judgement.Commit } else { $Scope.MergeBase }
    $all = $Profile.WholeOnGuide -and $lines.ContainsKey($Scope.Guide) -and (Get-RulesKeyAt $Scope $since $Profile.Kind) -cne $Profile.RulesKey
    return @{ All = $all; Lines = $lines[$RelativePath]; Pending = $pending; Findings = $findings }
}

function Get-RulesKeyAt($Scope, [string]$Commit, [string]$Kind) {
    $key = "$Commit $Kind"
    if (-not $Scope.RulesAt.ContainsKey($key)) {
        $guide = (git show "${Commit}:./$($Scope.Guide)" 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { $guide = ''; $global:LASTEXITCODE = 0 }
        $Scope.RulesAt[$key] = Get-RulesKey (Select-ProfileRules (Get-GuideRules $guide) $Kind)
    }
    return $Scope.RulesAt[$key]
}

#endregion

#region Documento in unita'

function New-Segment([string]$Kind, [string[]]$Lines) {
    return [pscustomobject]@{ Kind = $Kind; Lines = $Lines; Locked = $Kind -in $LockedKinds; IsUnit = $Kind -notin 'blank', 'frontmatter'; Start = 0; Number = 0; Marked = $false }
}

function Test-BlockStart([string]$Line) {
    return $Line -match $BlockStartPattern
}

# Un'unita' e' un titolo, un paragrafo, una voce di elenco, una riga di tabella, una citazione, un
# commento o un blocco di codice o di diagramma intero; le righe vuote le separano.
function ConvertTo-Segments([string[]]$Lines) {
    $segments = [Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        $start = $i
        $i++
        if ($start -eq 0 -and $line -eq '---') {
            while ($i -lt $Lines.Count -and $Lines[$i] -ne '---') { $i++ }
            $i = [math]::Min($i + 1, $Lines.Count)
            $kind = 'frontmatter'
        }
        elseif ($line -match $OpeningFencePattern) {
            $close = '^\s*' + [regex]::Escape($Matches[1]) + '\s*$'
            while ($i -lt $Lines.Count -and $Lines[$i] -notmatch $close) { $i++ }
            $i = [math]::Min($i + 1, $Lines.Count)
            $kind = 'code'
        }
        elseif (-not $line.Trim()) { $kind = 'blank' }
        elseif ($line -match '^#{1,6}\s') { $kind = 'heading' }
        elseif ($line -match '^\s*<!--') {
            $i--
            while ($i -lt $Lines.Count -and -not $Lines[$i].Contains('-->')) { $i++ }
            $i = [math]::Min($i + 1, $Lines.Count)
            $kind = 'marker'
        }
        elseif ($line -match $TableSeparatorPattern) { $kind = 'separator' }
        elseif ($line -match '^\s*\|') { $kind = 'row' }
        elseif ($line -match '^\s*>') {
            while ($i -lt $Lines.Count -and $Lines[$i] -match '^\s*>') { $i++ }
            $kind = 'quote'
        }
        else {
            $kind = if ($line -match $ListItemPattern) { 'list' } else { 'paragraph' }
            while ($i -lt $Lines.Count -and $Lines[$i].Trim() -and -not (Test-BlockStart $Lines[$i])) { $i++ }
        }
        $segments.Add((New-Segment $kind @($Lines[$start..($i - 1)])))
    }
    return , $segments
}

function Read-Document([string]$Path, [int]$LockedHeadingLevel = 0) {
    $raw = [IO.File]::ReadAllText($Path)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $trailing = $raw.EndsWith($newline)
    $body = if ($trailing) { $raw.Substring(0, $raw.Length - $newline.Length) } else { $raw }
    $lines = if ($body.Length) { $body -split [regex]::Escape($newline) } else { @() }
    $segments = ConvertTo-Segments $lines
    foreach ($heading in ($segments | Where-Object Kind -EQ 'heading')) { $heading.Locked = ($heading.Lines[0] -replace '^(#+).*', '$1').Length -eq $LockedHeadingLevel }
    return [pscustomobject]@{ Path = $Path; Newline = $newline; Trailing = $trailing; Segments = $segments; Changed = $false }
}

function Save-Document($Document) {
    if (-not $Document.Changed) { return }
    $text = @($Document.Segments | ForEach-Object { $_.Lines }) -join $Document.Newline
    if ($Document.Trailing) { $text += $Document.Newline }
    [IO.File]::WriteAllText($Document.Path, $text)
    $Document.Changed = $false
}

function Update-Numbering($Document, [int]$First) {
    $line = 1
    $number = $First
    foreach ($segment in $Document.Segments) {
        $segment.Start = $line
        $line += $segment.Lines.Count
        if ($segment.IsUnit) { $segment.Number = $number++ }
    }
    return $number
}

function Get-Units($Document) {
    return @($Document.Segments | Where-Object IsUnit)
}

function Get-UnitPrefix([string]$Kind, [string]$Text) {
    $pattern = @{ list = '^\s*(?:[-*+]|\d+\.)\s+'; quote = '^\s*>\s?'; heading = '^#{1,6}\s+' }[$Kind]
    if (-not $pattern) { return '' }
    return [regex]::Match($Text, $pattern).Value
}

function Get-UnitText($Segment) {
    $continuation = @($Segment.Lines | Select-Object -Skip 1)
    if ($Segment.Kind -eq 'paragraph') { return ($Segment.Lines | ForEach-Object Trim) -join ' ' }
    if ($Segment.Kind -eq 'list') { return (@($Segment.Lines[0].TrimEnd()) + @($continuation | ForEach-Object Trim)) -join ' ' }
    if ($Segment.Kind -eq 'quote') { return (@($Segment.Lines[0].TrimEnd()) + @($continuation | ForEach-Object { ($_ -replace '^\s*>\s?', '').Trim() })) -join ' ' }
    return $Segment.Lines -join "`n"
}

function Format-Wrapped([string]$Body, [string]$FirstPrefix, [string]$Continuation) {
    $lines = [Collections.Generic.List[string]]::new()
    $current = $FirstPrefix
    $empty = $true
    foreach ($word in @($Body -split ' ' | Where-Object { $_ })) {
        if (-not $empty -and ($current.Length + 1 + $word.Length) -gt $WrapWidth -and $word -notmatch $BlockWordPattern) {
            $lines.Add($current)
            $current = $Continuation + $word
        }
        elseif ($empty) { $current += $word }
        else { $current += " $word" }
        $empty = $false
    }
    $lines.Add($current)
    return , $lines.ToArray()
}

function Set-UnitText($Segment, [string]$Text) {
    if ($Segment.Kind -in 'row', 'heading') {
        $Segment.Lines = @($Text)
        return
    }
    $prefix = Get-UnitPrefix $Segment.Kind $Text
    $continuation = if ($Segment.Kind -eq 'quote') { $prefix } else { ' ' * $prefix.Length }
    $Segment.Lines = Format-Wrapped $Text.Substring($prefix.Length) $prefix $continuation
}

function Set-InitialMarks($Document, $FileScope) {
    [void](Update-Numbering $Document 1)
    $lines = $FileScope.Lines
    foreach ($unit in (Get-Units $Document)) {
        $range = $unit.Start..($unit.Start + $unit.Lines.Count - 1)
        $changed = $lines -and @($range | Where-Object { $lines.Contains($_) }).Count -gt 0
        $text = Get-PendingText $unit
        $unit.Marked = $FileScope.All -or $changed -or @($FileScope.Pending | Where-Object { $text.StartsWith($_) }).Count -gt 0
    }
}

#endregion

#region Giudizio

function New-FindingsSchema([string[]]$Rules) {
    $fix = @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('kind', 'unit', 'find', 'text')
        properties           = @{
            kind = @{ type = 'string'; enum = @('replace', 'insert', 'none') }
            unit = @{ type = 'integer'; description = 'L''unita'' a cui si applica la correzione: per insert quella dopo cui aggiungere il paragrafo' }
            find = @{ type = 'string'; description = 'Il tratto dell''unita'' da sostituire, copiato alla lettera; vuoto per insert e none' }
            text = @{ type = 'string'; description = 'Il testo corretto, o il paragrafo da aggiungere; vuoto per none' }
        }
    }
    $violation = @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('unit', 'excerpt', 'explanation', 'fix')
        properties           = @{
            unit        = @{ type = 'integer'; description = 'Numero dell''unita'' segnata che viola la regola' }
            excerpt     = @{ type = 'string'; description = 'Il tratto che viola la regola, copiato alla lettera' }
            explanation = @{ type = 'string'; description = 'Perche'' il tratto viola la regola, in una frase' }
            fix         = $fix
        }
    }
    $properties = [ordered]@{}
    for ($k = 0; $k -lt $Rules.Count; $k++) { $properties["regola_$($k + 1)"] = @{ type = 'array'; description = $Rules[$k]; items = $violation } }
    return @{ type = 'object'; additionalProperties = $false; required = @($properties.Keys); properties = $properties }
}

function Get-AccessToken {
    if ($env:STYLE_JUDGE_TOKEN) { return $env:STYLE_JUDGE_TOKEN }
    $token = az account get-access-token --resource 'https://cognitiveservices.azure.com' --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "token Entra ID non ottenuto: $token" }
    return $token
}

function New-JudgeBody([string]$System, [string]$User, $Schema) {
    $body = [ordered]@{
        model           = $model
        messages        = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $User })
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'style_findings'; strict = $true; schema = $Schema } }
    }
    if ($script:SeedSupported) { $body.seed = $seed }
    return $body | ConvertTo-Json -Depth 30
}

function Invoke-Judge($Context, [string]$User) {
    if (-not $script:Token) { $script:Token = Get-AccessToken }
    for ($attempt = 1; ; $attempt++) {
        $body = New-JudgeBody $Context.System $User $Context.Schema
        try {
            $response = Invoke-RestMethod -Method Post -Uri "$endpoint/openai/v1/chat/completions" -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
                -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Bearer $script:Token" } -TimeoutSec $RequestTimeoutSeconds
            break
        }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            if ($status -eq 400 -and $script:SeedSupported -and "$($_.ErrorDetails.Message)" -match 'seed') {
                $script:SeedSupported = $false
                continue
            }
            $transient = $status -eq 429 -or $status -ge 500
            if (-not $transient -or $attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }

    $script:Usage.Requests++
    $script:Usage.Input += [int]$response.usage.prompt_tokens
    $script:Usage.Output += [int]$response.usage.completion_tokens
    $verdict = $response.choices[0].message.content | ConvertFrom-Json
    for ($k = 0; $k -lt $Context.Rules.Count; $k++) {
        foreach ($item in @($verdict."regola_$($k + 1)")) {
            if ($null -eq $item) { continue }
            [pscustomobject]@{ Rule = $Context.Rules[$k]; Unit = [int]$item.unit; Excerpt = $item.excerpt; Explanation = $item.explanation; Fix = $item.fix }
        }
    }
}

function Get-JudgeMessage($Document, $Context, [string]$FileName, [hashtable]$Rejections) {
    $parts = [Collections.Generic.List[string]]::new()
    if ($Context.Glossary) {
        $parts.Add("GLOSSARIO DEL DOCUMENTO ($glossaryFileName)")
        $parts.Add((@(Get-Units $Context.Glossary | ForEach-Object { "[$($_.Number)] $(Get-UnitText $_)" }) -join "`n"))
    }
    $parts.Add("$($Context.Label) ($FileName)")
    $parts.Add((@(Get-Units $Document | ForEach-Object { $mark = if ($_.Marked) { '*' } else { '' }; "[$($_.Number)$mark] $(Get-UnitText $_)" }) -join "`n"))
    if ($Rejections.Count) {
        $parts.Add('RILIEVI E CORREZIONI SCARTATE NEI GIRI PRECEDENTI')
        $parts.Add((@($Rejections.Keys | Sort-Object Number | ForEach-Object { "[$($_.Number)] $($Rejections[$_] -join '; ')" }) -join "`n"))
    }
    return $parts -join "`n`n"
}

#endregion

#region Correzioni

function Get-LongestSentence([string]$Kind, [string]$Text) {
    $prose = if ($Kind -eq 'row') { $Text -replace '\|', ' ' } else { $Text -replace '^\s*(?:[-*+]|\d+\.|>)\s*', '' }
    $counts = @(Get-Sentences (ConvertTo-PlainText $prose) $abbreviations | ForEach-Object { Get-WordCount $_ })
    if (-not $counts) { return 0 }
    return ($counts | Measure-Object -Maximum).Maximum
}

# Il motivo per cui il testo corretto non si accetta, o niente se si accetta.
function Test-Correction([string]$Kind, [string]$Before, [string]$After) {
    if ($After -match "`n|``````|~~~|<!--") { return 'la correzione cambia la struttura del testo' }
    if ($Kind -eq 'row' -and ($After -notmatch '^\s*\|' -or $After.Split('|').Count -ne $Before.Split('|').Count)) { return 'la correzione cambia le colonne della tabella' }
    if ($Kind -eq 'paragraph' -and (Test-BlockStart $After)) { return 'la correzione trasforma il paragrafo in un altro elemento' }
    if ($Kind -in 'list', 'quote' -and (Get-UnitPrefix $Kind $After) -ne (Get-UnitPrefix $Kind $Before)) { return 'la correzione cambia il segno dell''elenco o della citazione' }
    if ($Kind -eq 'heading' -and (Get-UnitPrefix $Kind $After) -ne (Get-UnitPrefix $Kind $Before)) { return 'la correzione cambia il livello del titolo' }
    if (-not $After.Substring((Get-UnitPrefix $Kind $After).Length).Trim()) { return 'la correzione svuota l''unità' }
    $longest = Get-LongestSentence $Kind $After
    if ($maximumWords -and $longest -gt $maximumWords) { return "la correzione porta una frase a $longest parole, massimo $maximumWords" }
    return $null
}

function Get-GlossaryTerm([string]$Text) {
    return [regex]::Match($Text, '^\*\*([^*]+)\*\*').Groups[1].Value.ToLowerInvariant()
}

# L'unita' dopo cui si aggiunge un paragrafo: dopo l'ultima riga di una tabella o l'ultima voce di
# un elenco, per non spezzarli.
function Get-InsertionIndex($Document, $Segment) {
    $index = $Document.Segments.IndexOf($Segment)
    $grouped = @{ row = @('row', 'separator'); separator = @('row', 'separator'); list = @('list') }[$Segment.Kind]
    while ($grouped -and $index + 1 -lt $Document.Segments.Count -and $Document.Segments[$index + 1].Kind -in $grouped) { $index++ }
    return $index
}

function Add-Paragraph($Document, $After, [string]$Text, [bool]$Marked) {
    $index = Get-InsertionIndex $Document $After
    $paragraph = New-Segment 'paragraph' (Format-Wrapped $Text '' '')
    $paragraph.Marked = $Marked
    $blank = New-Segment 'blank' @('')
    $Document.Segments.Insert($index + 1, $blank)
    $Document.Segments.Insert($index + 2, $paragraph)
    $Document.Changed = $true
    return @($blank, $paragraph)
}

# Un titolo corretto cambia la sua ancora: i rimandi a quel titolo, e le righe che lo riportano accanto a
# un rimando al suo file (come l'indice delle decisioni), cambiano con lui. Restituisce come annullarlo.
function Update-TitleReferences($Document, $Glossary, [string]$Before, [string]$After) {
    $oldText = $Before -replace '^#{1,6}\s+', ''
    $newText = $After -replace '^#{1,6}\s+', ''
    $change = @{ File = [IO.Path]::GetFullPath($Document.Path); OldText = $oldText; NewText = $newText; OldAnchor = ConvertTo-HeadingAnchor $oldText; NewAnchor = ConvertTo-HeadingAnchor $newText }
    $undo = [Collections.Generic.List[object]]::new()
    $inMemory = @($Document, $Glossary | Where-Object { $_ })
    foreach ($memory in $inMemory) {
        foreach ($segment in ($memory.Segments | Where-Object { -not $_.Locked -and $_.Kind -ne 'heading' })) {
            $lines = @($segment.Lines | ForEach-Object { Update-ReferenceLine $_ $memory.Path $change })
            if (($lines -join "`n") -eq ($segment.Lines -join "`n")) { continue }
            $undo.Add(@{ Segment = $segment; Lines = $segment.Lines; Document = $memory })
            $segment.Lines = $lines
            $memory.Changed = $true
            if ($memory -ne $Document) { [void]$script:Propagated.Add((ConvertTo-RepositoryPath $memory.Path)) }
        }
    }
    $memoryPaths = @($inMemory | ForEach-Object { [IO.Path]::GetFullPath($_.Path) })
    foreach ($file in (Get-ChildItem -Path $docsDirectory, $decisionsDirectory -Filter '*.md' -File -Recurse -ErrorAction SilentlyContinue)) {
        if ($file.FullName -in $memoryPaths) { continue }
        $raw = [IO.File]::ReadAllText($file.FullName)
        $updated = Update-ReferenceText $raw $file.FullName $change
        if ($updated -ceq $raw) { continue }
        $undo.Add(@{ Path = $file.FullName; Content = $raw })
        [IO.File]::WriteAllText($file.FullName, $updated)
        [void]$script:Propagated.Add((ConvertTo-RepositoryPath $file.FullName))
    }
    return , $undo
}

function Update-ReferenceText([string]$Raw, [string]$Path, $Change) {
    $fence = $null
    $lines = foreach ($line in ($Raw -split "`n")) {
        if ($fence) { if ($line -match $fence) { $fence = $null }; $line; continue }
        if ($line -match $OpeningFencePattern) { $fence = '^\s*' + [regex]::Escape($Matches[1]) + '\s*$'; $line; continue }
        Update-ReferenceLine $line $Path $Change
    }
    return @($lines) -join "`n"
}

function Update-ReferenceLine([string]$Line, [string]$Path, $Change) {
    $text = [Text.StringBuilder]::new()
    $last = 0
    $quotesTitle = $false
    foreach ($link in [regex]::Matches($Line, $ReferencePattern)) {
        $target, $anchor = $link.Groups[2].Value -split '#', 2
        $replacement = $link.Value
        if ($link.Groups[2].Value -notmatch $ExternalReferencePattern -and (Resolve-ReferenceTarget $Path $target) -eq $Change.File) {
            if ($anchor -and [uri]::UnescapeDataString($anchor).ToLowerInvariant() -eq $Change.OldAnchor) {
                $replacement = $link.Groups[1].Value + "$target#$($Change.NewAnchor)" + $link.Groups[3].Value
                $quotesTitle = $true
            }
            elseif (-not $anchor -and $target) { $quotesTitle = $true }
        }
        [void]$text.Append($Line.Substring($last, $link.Index - $last)).Append($replacement)
        $last = $link.Index + $link.Length
    }
    [void]$text.Append($Line.Substring($last))
    $updated = $text.ToString()
    if ($quotesTitle) { $updated = $updated.Replace($Change.OldText, $Change.NewText) }
    return $updated
}

function Resolve-ReferenceTarget([string]$From, [string]$Target) {
    if (-not $Target) { return [IO.Path]::GetFullPath($From) }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path $From) ([uri]::UnescapeDataString($Target))))
}

function Undo-Correction($Correction) {
    foreach ($segment in @($Correction.Inserted)) { if ($segment) { [void]$Correction.Document.Segments.Remove($segment) } }
    if ($Correction.Lines) { $Correction.Unit.Lines = $Correction.Lines }
    $Correction.Document.Changed = $true
    $references = @($Correction.References)
    [array]::Reverse($references)
    foreach ($reference in $references) {
        if ($reference.Path) { [IO.File]::WriteAllText($reference.Path, $reference.Content); continue }
        $reference.Segment.Lines = $reference.Lines
        $reference.Document.Changed = $true
    }
}

# Un nome contenuto in un nome piu' lungo (Handler in IHandler) compare piu' volte come testo ma una
# volta sola come parola intera: in quel caso vale l'occorrenza della parola intera.
function Find-UniqueOccurrence([string]$Text, [string]$Find) {
    if (-not $Find) { return $null }
    $matches = [regex]::Matches($Text, [regex]::Escape($Find))
    if ($matches.Count -eq 1) { return $matches[0] }
    if ($matches.Count -lt 2) { return $null }
    $whole = [regex]::Matches($Text, '(?<![\p{L}\p{N}_])' + [regex]::Escape($Find) + '(?![\p{L}\p{N}_])')
    if ($whole.Count -eq 1) { return $whole[0] }
    return $null
}

function Invoke-Replacement($Target, $Finding, [hashtable]$Original, $Glossary, $Applied) {
    $segment = $Target.Segment
    if ($Target.Glossary) { return 'la correzione cambia una voce del glossario' }
    if ($segment.Locked) { return 'la correzione tocca un titolo imposto dal modello del documento, un diagramma, un blocco di codice o un commento' }
    $find = "$($Finding.Fix.find)"
    $before = Get-UnitText $segment
    if (-not $Original.ContainsKey($segment)) { $Original[$segment] = $before }
    $occurrence = Find-UniqueOccurrence $before $find
    if (-not $occurrence) {
        # Un'altra correzione ha gia' cambiato il tratto: l'unita' torna al giudizio nel giro dopo.
        if (Find-UniqueOccurrence $Original[$segment] $find) { $segment.Marked = $true; return $null }
        return 'il tratto da correggere non compare una volta sola nell''unità'
    }
    $after = $before.Substring(0, $occurrence.Index) + "$($Finding.Fix.text)" + $before.Substring($occurrence.Index + $occurrence.Length)
    $reason = Test-Correction $segment.Kind $before $after
    if ($reason) { return $reason }
    $correction = @{ Rule = $Finding.Rule; Unit = $segment; Document = $Target.Document; Lines = $segment.Lines; References = @() }
    Set-UnitText $segment $after
    if ($segment.Kind -eq 'heading') { $correction.References = Update-TitleReferences $Target.Document $Glossary $before $after }
    $Applied.Add($correction)
    $segment.Marked = $true
    $Target.Document.Changed = $true
    return $null
}

function Invoke-Corrections($Document, $Glossary, $Findings) {
    $targets = @{}
    foreach ($unit in (Get-Units $Document)) { $targets[$unit.Number] = @{ Document = $Document; Segment = $unit; Glossary = $false } }
    if ($Glossary) { foreach ($unit in (Get-Units $Glossary)) { $targets[$unit.Number] = @{ Document = $Glossary; Segment = $unit; Glossary = $true } } }
    $glossaryTerms = [Collections.Generic.HashSet[string]]::new([string[]]@(if ($Glossary) { Get-Units $Glossary | ForEach-Object { Get-GlossaryTerm (Get-UnitText $_) } | Where-Object { $_ } }))
    $original = @{}
    $insertions = [Collections.Generic.List[object]]::new()
    $applied = [Collections.Generic.List[object]]::new()
    $rejected = [Collections.Generic.List[object]]::new()

    foreach ($finding in $Findings) {
        $target = if ("$($finding.Fix.kind)" -eq 'insert') { $targets[[int]$finding.Fix.unit] } else { $targets[$finding.Unit] }
        $kind = if ($target) { "$($finding.Fix.kind)" } else { 'missing' }
        $reason = switch ($kind) {
            'replace' { Invoke-Replacement $target $finding $original $Glossary $applied }
            'insert' {
                $text = "$($finding.Fix.text)".Trim()
                $term = Get-GlossaryTerm $text
                if ($target.Glossary -and $term -and -not $glossaryTerms.Add($term)) { $null }
                elseif (-not ($invalid = Test-Correction 'paragraph' '' $text)) { $insertions.Add(@{ Target = $target; Text = $text; Finding = $finding; Unit = $targets[$finding.Unit].Segment }); $null }
                else { $invalid }
            }
            'missing' { 'la correzione indica un''unità che il documento non ha' }
            default { 'il modello non propone una correzione' }
        }
        if ($reason) { $rejected.Add([pscustomobject]@{ Finding = $finding; Reason = $reason }) }
    }
    foreach ($insertion in $insertions) {
        $inserted = Add-Paragraph $insertion.Target.Document $insertion.Target.Segment $insertion.Text (-not $insertion.Target.Glossary)
        if (-not $insertion.Unit) { continue }
        $insertion.Unit.Marked = $true
        $applied.Add(@{ Rule = $insertion.Finding.Rule; Unit = $insertion.Unit; Document = $insertion.Target.Document; Inserted = $inserted; References = @() })
    }
    return @{ Applied = $applied; Rejected = $rejected }
}

#endregion

function New-FindingIssue([string]$Title, $Finding, [string]$Rejection) {
    $detail = "«$($Finding.Excerpt)»: $($Finding.Explanation)"
    if ($Rejection) { $detail += "; correzione scartata: $Rejection" }
    return New-Issue $Title $Finding.Rule $detail
}

# Il rilievo rimasto viaggia nel commit del file con l'unita' in sospeso: il giudizio dopo lo
# ritrova e il modello riparte da li', con le correzioni gia' scartate, invece di ricominciare.
function Format-RememberedFinding($Finding, [string]$Reasons) {
    $text = "$($Finding.Rule) («$($Finding.Excerpt)»): $($Finding.Explanation)"
    if ($Reasons) { $text += "; correzioni scartate: $Reasons" }
    return ($text -replace '\s+', ' ').Trim()
}

function Get-RememberedFindings($Document, $FileScope) {
    $remembered = @{}
    if (-not $FileScope.Findings -or -not $FileScope.Findings.Count) { return $remembered }
    foreach ($unit in (Get-Units $Document)) {
        $text = Get-PendingText $unit
        $finding = $FileScope.Findings.Keys | Where-Object { $text.StartsWith($_) } | Select-Object -First 1
        if ($finding) { $remembered[$unit] = @("rilievo rimasto: $($FileScope.Findings[$finding])") }
    }
    return $remembered
}

function Get-PendingText($Segment) {
    $text = (Get-UnitText $Segment) -replace '\s+', ' '
    return $text.Substring(0, [math]::Min($PendingTextLength, $text.Length)).Trim()
}

# Ogni giro giudica le unita' segnate e, con la correzione attiva, applica le correzioni e segna
# per il giro dopo le unita' corrette e quelle con una correzione scartata, che torna al modello
# con il motivo. Una correzione che il giro dopo trova ancora in violazione della stessa regola si
# annulla. L'ultimo giro verifica soltanto: restano le violazioni che i giri non hanno tolto.
function Invoke-SectionReview($File, $FileScope, $Context) {
    $document = Read-Document $File.FullName $Context.LockedHeadingLevel
    $title = if ($Context.NamedByFile) { $File.BaseName } else { (ConvertFrom-MarkdownSection ([IO.File]::ReadAllText($File.FullName))).Title }
    if (-not $title) { $title = $File.Name }
    $relativePath = ConvertTo-RepositoryPath $File.FullName
    Set-InitialMarks $document $FileScope
    $rejections = Get-RememberedFindings $document $FileScope
    $applied = @()

    for ($round = 1; $round -le $Context.Rounds; $round++) {
        $next = Update-Numbering $document 1
        if ($Context.Glossary) { [void](Update-Numbering $Context.Glossary $next) }
        $marked = [Collections.Generic.HashSet[int]]::new([int[]]@(Get-Units $document | Where-Object Marked | ForEach-Object Number))
        if (-not $marked.Count) { return }

        $units = @{}
        foreach ($unit in (Get-Units $document)) { $units[$unit.Number] = $unit }
        $findings = @(Invoke-Judge $Context (Get-JudgeMessage $document $Context $File.Name $rejections) | Where-Object { $marked.Contains($_.Unit) })
        Write-Host "$($File.Name), giro ${round}: $($marked.Count) unità giudicate, $($findings.Count) rilievi"
        foreach ($unit in (Get-Units $document)) { $unit.Marked = $false }
        $previous = $rejections
        $rejections = @{}
        Undo-IneffectiveCorrections $applied $findings $rejections
        Save-Document $document
        if ($Context.Glossary) { Save-Document $Context.Glossary }
        if (-not $findings) { return }

        if (-not $Context.Fix -or $round -eq $Context.Rounds) {
            foreach ($finding in $findings) {
                $unit = $units[$finding.Unit]
                $reasons = @(@($previous[$unit]) + @($rejections[$unit]) | Where-Object { $_ }) -join '; '
                $pending = if ($Context.Fix -and $unit) { "$relativePath`t$(Get-PendingText $unit)`t$(Format-RememberedFinding $finding $reasons)" } else { $null }
                $Context.Remaining.Add(@{ Issue = (New-FindingIssue $title $finding $reasons); Pending = $pending })
            }
            return
        }
        $corrections = Invoke-Corrections $document $Context.Glossary $findings
        $applied = @($corrections.Applied)
        Save-Document $document
        if ($Context.Glossary) { Save-Document $Context.Glossary }
        foreach ($rejection in $corrections.Rejected) {
            $unit = $units[$rejection.Finding.Unit]
            if (-not $unit) { continue }
            $unit.Marked = $true
            $rejections[$unit] = @(@($rejections[$unit]) + "$($rejection.Finding.Rule): $($rejection.Reason)" | Where-Object { $_ })
        }
    }
}

# Una correzione resta solo se il giro dopo non trova piu' la stessa regola violata nella stessa unita'.
function Undo-IneffectiveCorrections($Applied, $Findings, [hashtable]$Rejections) {
    $ineffective = @($Applied | Where-Object { $correction = $_; @($Findings | Where-Object { $_.Rule -eq $correction.Rule -and $_.Unit -eq $correction.Unit.Number }).Count })
    [array]::Reverse($ineffective)
    foreach ($correction in $ineffective) {
        Undo-Correction $correction
        $Rejections[$correction.Unit] = @(@($Rejections[$correction.Unit]) + "$($correction.Rule): la correzione non toglie la violazione" | Where-Object { $_ })
    }
}

function Test-ObjectiveChecks([string]$RelativePath) {
    foreach ($check in 'Test-Documentation.ps1', 'Test-AdrCorpus.ps1') {
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File "$PSScriptRoot/$check" 2>&1
        $output | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -eq 0) { continue }
        $global:LASTEXITCODE = 0
        return New-Issue $JudgeScope 'correzioni non pubblicate' "i controlli oggettivi falliscono sul testo corretto di $RelativePath"
    }
}

function Show-Corrections {
    git diff --quiet -- $docsDirectory $decisionsDirectory
    if ($LASTEXITCODE -eq 0) { return $false }
    $global:LASTEXITCODE = 0
    Write-Host '##[group]Correzioni del giudizio dello stile'
    git -c core.quotePath=false --no-pager diff --stat -- $docsDirectory $decisionsDirectory | ForEach-Object { Write-Host $_ }
    git -c core.quotePath=false --no-pager diff -- $docsDirectory $decisionsDirectory | ForEach-Object { Write-Host $_ }
    Write-Host '##[endgroup]'
    return $true
}

function Test-Corrected {
    git diff --quiet -- $docsDirectory $decisionsDirectory
    $corrected = $LASTEXITCODE -ne 0
    $global:LASTEXITCODE = 0
    return $corrected
}

function Undo-Corrections {
    git checkout -q -- $docsDirectory $decisionsDirectory 2>&1 | Out-Null
    $global:LASTEXITCODE = 0
}

# Le correzioni si applicano su una copia del commit di origine della PR, non sul commit di merge
# della build. Ogni file giudicato ha il suo commit, che parte dal precedente e va sul ramo di
# appoggio: un push sul ramo della PR avvierebbe una nuova build e annullerebbe questa. Il ramo della
# PR riceve tutti i commit insieme a fine giudizio; se il job si interrompe, il giudizio dopo li ritrova.
function New-Publisher([string]$Source) {
    return @{ Source = $Source; Worktree = $null; Side = "$SideBranchPrefix/$Source"; Commits = 0 }
}

function Get-GitAuthorization {
    if ($env:SYSTEM_ACCESSTOKEN) { return @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") }
    return @()
}

function Remove-Publisher($Publisher) {
    if (-not $Publisher -or -not $Publisher.Worktree) { return }
    git worktree remove --force $Publisher.Worktree 2>&1 | Out-Null
    $global:LASTEXITCODE = 0
}

function Remove-SideBranch([string]$Side) {
    $authorization = Get-GitAuthorization
    $out = git @authorization push -q origin --delete $Side 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=warning]Ramo di appoggio $Side non cancellato: $out" }
    $global:LASTEXITCODE = 0
}

# Porta sul ramo della PR i commit del ramo di appoggio. Il push avvia la build successiva.
function Complete-Publisher($Publisher) {
    if (-not $Publisher -or -not $Publisher.Commits) { return }
    $authorization = Get-GitAuthorization
    $out = git -C $Publisher.Worktree @authorization push -q origin "HEAD:refs/heads/$sourceBranch" 2>&1
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        return New-Issue $JudgeScope 'correzioni non pubblicate' "push sul ramo $sourceBranch non riuscito, il lavoro resta sul ramo $($Publisher.Side): $out"
    }
    Write-Host "Ramo $sourceBranch aggiornato con $($Publisher.Commits) commit del giudizio: la PR riparte dall'ultimo"
    Remove-SideBranch $Publisher.Side
}

# Un giudizio interrotto ha lasciato i suoi commit sul ramo di appoggio dello stesso commit della PR:
# si portano sul ramo della PR senza chiamare il modello, e la build che parte giudica il resto.
function Resume-InterruptedJudgement([string]$Source) {
    $side = "$SideBranchPrefix/$Source"
    $authorization = Get-GitAuthorization
    $found = git @authorization ls-remote origin "refs/heads/$side" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not "$found".Trim()) { $global:LASTEXITCODE = 0; return $null }
    $out = git @authorization fetch -q origin "+refs/heads/${side}:refs/remotes/origin/$side" 2>&1
    if ($LASTEXITCODE -eq 0) { $out = git @authorization push -q origin "refs/remotes/origin/${side}:refs/heads/$sourceBranch" 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        return New-Issue $JudgeScope 'giudizio interrotto non ripreso' "push del ramo $side su $sourceBranch non riuscito: $out"
    }
    Remove-SideBranch $side
    return New-Issue $JudgeScope 'giudizio ripreso' "i commit del giudizio interrotto sono sul ramo ${sourceBranch}: la verifica riparte da quel commit"
}

function Publish-Judgement($Publisher, [string]$Subject, [string[]]$Trailers) {
    $patchFile = [IO.Path]::GetTempFileName()
    $messageFile = [IO.Path]::GetTempFileName()
    try {
        if (-not $Publisher.Worktree) {
            $worktree = Join-Path ([IO.Path]::GetTempPath()) "style-judge-$(New-Guid)"
            $out = git worktree add -q --detach $worktree $Publisher.Source 2>&1
            if ($LASTEXITCODE -ne 0) { return New-Issue $JudgeScope 'correzioni non pubblicate' "copia del ramo non creata: $out" }
            $Publisher.Worktree = $worktree
        }
        git diff --full-index --binary --output=$patchFile -- $docsDirectory $decisionsDirectory
        if ((Get-Item $patchFile).Length -gt 0) {
            $out = git -C $Publisher.Worktree apply --3way --whitespace=nowarn $patchFile 2>&1
            if ($LASTEXITCODE -ne 0) { return New-Issue $JudgeScope 'correzioni non pubblicate' "correzioni non applicabili al ramo: $out" }
        }
        [IO.File]::WriteAllText($messageFile, "$Subject`n`n$SkipCi`n`n" + ($Trailers -join "`n") + "`n")
        $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Quality Gate' }
        $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'quality-gate@noreply.local' }
        git -C $Publisher.Worktree add -A
        $out = git -C $Publisher.Worktree -c "user.name=$name" -c "user.email=$email" commit -q --allow-empty -F $messageFile 2>&1
        if ($LASTEXITCODE -ne 0) { return New-Issue $JudgeScope 'correzioni non pubblicate' "commit non riuscito: $out" }
        $authorization = Get-GitAuthorization
        $out = git -C $Publisher.Worktree @authorization push -q origin "HEAD:refs/heads/$($Publisher.Side)" 2>&1
        if ($LASTEXITCODE -ne 0) { return New-Issue $JudgeScope 'correzioni non pubblicate' "push sul ramo di appoggio $($Publisher.Side) non riuscito: $out" }
        $Publisher.Commits++
        git add -- $docsDirectory $decisionsDirectory
        Write-Host "Ramo di appoggio $($Publisher.Side) aggiornato: $Subject"
    }
    finally {
        Remove-Item $patchFile, $messageFile -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
    }
}

# Un file giudicato si pubblica subito, con le sue correzioni se superano i controlli oggettivi.
# Se non li superano, le sue correzioni si scartano e il file resta da giudicare.
# I file cambiati solo perche' riportano un titolo corretto contano come giudicati con il file del
# titolo, tranne quelli ancora da giudicare in questa verifica.
function Publish-FileJudgement($Publisher, [string]$RelativePath, [string[]]$Pending, [string[]]$Propagated) {
    $corrected = Show-Corrections
    if ($corrected) {
        $objective = Test-ObjectiveChecks $RelativePath
        if ($objective) {
            Undo-Corrections
            $script:Propagated.Clear()
            return @{ Issue = $objective; Stop = $false }
        }
    }
    $pendingLines = @($Pending | Where-Object { $_ } | ForEach-Object { "${PendingTrailer}: $_" })
    $doneLines = @(@($RelativePath) + @($Propagated) | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { "${DoneTrailer}: $_" })
    $subject = if ($corrected) { "docs: apply the style judge corrections to $RelativePath" } else { "docs: record the style judgement of $RelativePath" }
    $issue = Publish-Judgement $Publisher $subject ($doneLines + $pendingLines)
    return @{ Issue = $issue; Stop = [bool]$issue }
}

function Get-StyleIssues {
    $setup = Read-JudgeSetup
    if ($setup.Issue) { return $setup.Issue }

    $sections = Get-SectionFiles $docsDirectory
    $glossaryFile = $sections | Where-Object { $glossaryFileName -and $_.Name -eq $glossaryFileName } | Select-Object -First 1
    $scope = Get-ReviewScope
    $fix = $fixRequested -and $scope.PullRequest -and [bool]$sourceBranch
    if ($fixRequested -and -not $fix) { Write-Host 'Correzione automatica non attiva fuori da una PR: il giudizio verifica soltanto' }
    $context = @{
        Fix       = $fix
        Rounds    = if ($fix) { $maxRounds } else { 1 }
        Glossary  = if ($glossaryFile) { Read-Document $glossaryFile.FullName } else { $null }
        Remaining = [Collections.Generic.List[object]]::new()
    }
    $sectionProfile = New-DocumentProfile 'section' $setup
    $decisionProfile = New-DocumentProfile 'decision' $setup

    $reviews = @($sections | Where-Object { -not $glossaryFile -or $_.FullName -ne $glossaryFile.FullName } | ForEach-Object { @{ File = $_; Profile = $sectionProfile } })
    if ($scope.PullRequest) {
        $openDecisions = Get-SectionFiles $decisionsDirectory | Where-Object { (Get-DecisionStatus $_.FullName) -notin $ClosedStatuses }
        $reviews += @($openDecisions | ForEach-Object { @{ File = $_; Profile = $decisionProfile } })
    }
    $queued = [Collections.Generic.HashSet[string]]::new([string[]]@($reviews | ForEach-Object { ConvertTo-RepositoryPath $_.File.FullName }))

    if ($fix) {
        $resumed = Resume-InterruptedJudgement $scope.Source
        if ($resumed) { return $resumed }
    }

    $issues = @()
    $publisher = if ($fix) { New-Publisher $scope.Source } else { $null }
    $completed = $true
    $publishable = $fix
    try {
        foreach ($review in $reviews) {
            $relativePath = ConvertTo-RepositoryPath $review.File.FullName
            [void]$queued.Remove($relativePath)
            $touched = $script:Propagated.Remove($relativePath)
            if (-not $review.Profile.Rules) { continue }
            $requests = $script:Usage.Requests
            $remaining = $context.Remaining.Count
            $fileScope = Get-FileScope $scope $relativePath $review.Profile
            $fileContext = $context.Clone()
            foreach ($name in $review.Profile.Keys) { $fileContext[$name] = $review.Profile[$name] }
            # Le unita' in sospeso riprendono le correzioni con tutti i giri: rilanciare la build continua
            # il lavoro. Se nessuna correzione resta e le violazioni restano, non si pubblica nulla: il push
            # avvierebbe un'altra build sullo stesso rilievo.
            $pendingOnly = $fix -and -not $fileScope.All -and -not $fileScope.Lines -and $fileScope.Pending
            try { Invoke-SectionReview $review.File $fileScope $fileContext }
            catch {
                Undo-Corrections
                $issues += New-Issue $JudgeScope 'verifica non eseguita' "$($review.File.Name): $($_.Exception.Message)"
                $completed = $false
                break
            }
            if (-not $fix -or ($script:Usage.Requests -eq $requests -and -not $touched)) { continue }
            if ($pendingOnly -and $context.Remaining.Count -gt $remaining -and -not (Test-Corrected)) { continue }
            $pending = @($context.Remaining | Select-Object -Skip $remaining | ForEach-Object { $_.Pending })
            $propagated = @($script:Propagated | Where-Object { $_ -ne $relativePath -and -not $queued.Contains($_) })
            $published = Publish-FileJudgement $publisher $relativePath $pending $propagated
            $propagated | ForEach-Object { [void]$script:Propagated.Remove($_) }
            if ($published.Issue) { $issues += $published.Issue }
            if ($published.Stop) { $completed = $false; $publishable = $false; break }
        }
        Write-Host "Giudizio dello stile: $($script:Usage.Requests) richieste, $($script:Usage.Input) token in ingresso, $($script:Usage.Output) in uscita"
        $findings = @($context.Remaining | ForEach-Object { $_.Issue } | Select-Object -Unique)
        $tolerated = $maxFindings -lt 0 -or $findings.Count -le $maxFindings
        if (-not $tolerated) { return @($issues) + $findings + @($(if ($publishable) { Complete-Publisher $publisher })) }
        $script:Tolerated = $findings
        # Le unita' rimaste in sospeso nei commit dei file valgono come giudicate quando tutte
        # insieme restano entro la soglia: il giudizio superato le chiude.
        $pendingRecorded = @($context.Remaining | Where-Object { $_.Pending }).Count -gt 0
        if ($fix -and $completed -and $pendingRecorded) {
            $issue = Publish-Judgement $publisher 'docs: record the style judgement within the tolerated findings' @($CleanTrailer)
            if ($issue) { $issues += $issue; $publishable = $false }
        }
        if ($publishable) { $issues += @(Complete-Publisher $publisher) }
        return $issues
    }
    finally { Remove-Publisher $publisher }
}

# Le violazioni entro la soglia restano visibili come avvisi; la verifica passa con esito parziale.
function Write-ToleratedFindings([string[]]$Findings) {
    $Findings | ForEach-Object { Write-Host "##vso[task.logissue type=warning]$_" }
    Write-Host "##vso[task.complete result=SucceededWithIssues;]"
}

$script:Tolerated = @()
$script:Propagated = [Collections.Generic.HashSet[string]]::new()
Invoke-Verification {
    $issues = @(Get-StyleIssues)
    if (-not $issues -and $script:Tolerated) { Write-ToleratedFindings $script:Tolerated }
    $issues
} "Stile del documento in $docsDirectory conforme alla guida" 'Giudizio dello stile disattivato'
