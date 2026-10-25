# Giudica lo stile delle sezioni di un documento con un modello linguistico: la guida di stile del
# repository e' l'istruzione del modello, e la pipeline non conosce nessuna regola. Un solo giudizio
# copre tutte le regole: la sezione arriva in unita' numerate e la risposta ha una voce per regola.
# In una PR si giudicano le righe cambiate dall'ultimo giudizio superato; con STYLE_FIX le correzioni
# del modello, validate e rigiudicate in giri limitati, tornano sul ramo della PR.

. "$PSScriptRoot/VerificationGate.ps1"
. "$PSScriptRoot/MarkdownText.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$guidePath = if ($env:STYLE_GUIDE) { $env:STYLE_GUIDE } else { 'docs/STYLE.md' }
$glossaryFileName = $env:DOCS_GLOSSARY
$targetBranch = $env:TARGET_BRANCH -replace '^refs/heads/', '' -replace '^\$\(.*\)$', ''
$sourceBranch = $env:SOURCE_BRANCH -replace '^refs/heads/', '' -replace '^\$\(.*\)$', ''
$endpoint = "$env:STYLE_JUDGE_ENDPOINT".TrimEnd('/')
$model = $env:STYLE_JUDGE_MODEL
$seed = if ($env:STYLE_JUDGE_SEED) { [int]$env:STYLE_JUDGE_SEED } else { 1919 }
$fixRequested = $env:STYLE_FIX -eq 'true'
$maxRounds = if ($env:STYLE_MAX_ROUNDS) { [math]::Max(1, [int]$env:STYLE_MAX_ROUNDS) } else { 4 }
$maximumWords = [int]$env:READABILITY_MAX_WORDS
$abbreviations = @("$env:READABILITY_ABBREVIATIONS" -split ';' | ForEach-Object Trim | Where-Object { $_ })

$SectionFilePattern = '^\d+[_-].+\.md$'
$JudgeScope = 'giudizio dello stile'
$CleanTrailer = 'Style-Judge: clean'
$MaxAttempts = 3
$RequestTimeoutSeconds = 600
$WrapWidth = 110
$LockedKinds = @('heading', 'code', 'marker', 'separator')
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

La sezione arriva divisa in unità numerate. Giudichi solo le unità segnate con l'asterisco, per
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
Una correzione non tocca titoli, diagrammi, blocchi di codice e commenti, non va a capo, rispetta
tutte le regole della guida. Una violazione in un titolo o in un diagramma si corregge nel testo che
li spiega, oppure è none. Se il messaggio riporta correzioni scartate nel giro precedente, la nuova
correzione di quell'unità evita il motivo dello scarto.

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

# Le regole sono i titoli di terzo livello della parte «Regole» della guida, o di tutta la guida
# se quella parte non c'e'; i titoli dentro gli esempi non contano.
function Get-GuideRules([string]$Guide) {
    $headings = [Collections.Generic.List[object]]::new()
    $part = $null
    $fence = $null
    foreach ($line in ($Guide -split "`r?`n")) {
        if ($fence) {
            if ($line -match $fence) { $fence = $null }
            continue
        }
        if ($line -match $OpeningFencePattern) { $fence = '^\s*' + [regex]::Escape($Matches[1]) + '\s*$' }
        elseif ($line -match '^##\s+(.+?)\s*$') { $part = $Matches[1] }
        elseif ($line -match '^###\s+(.+?)\s*$') { $headings.Add([pscustomobject]@{ Part = $part; Title = $Matches[1] }) }
    }
    $inRules = @($headings | Where-Object Part -EQ 'Regole')
    $selected = if ($inRules) { $inRules } else { $headings }
    return @($selected | ForEach-Object Title)
}

function Get-SectionFiles {
    return @(Get-ChildItem -Path $docsDirectory -File -ErrorAction SilentlyContinue | Where-Object Name -Match $SectionFilePattern | Sort-Object Name)
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
    git -c core.quotePath=false diff -U0 --no-color --no-ext-diff --relative @Range -- $docsDirectory $guidePath | ForEach-Object {
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

# In una PR si giudica cio' che la PR cambia e che nessun giudizio superato ha gia' visto: il
# segno e' il trailer dell'ultimo commit della PR che ha superato il giudizio. Fuori da una PR, o
# se cambia la guida, si giudica tutto.
function Get-ReviewScope {
    $everything = @{ All = $true; PullRequest = $false }
    if (-not $targetBranch) { return $everything }
    git rev-parse --verify --quiet "origin/$targetBranch^{commit}" > $null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $everything }

    $source = Get-SourceCommit
    $changed = Get-ChangedLines @("origin/$targetBranch...HEAD")
    $marker = git log -n 1 --format=%H --grep "^$CleanTrailer`$" "origin/$targetBranch..$source"
    if ($marker) {
        Write-Host "Ultimo giudizio superato: $marker"
        $changed = Select-CommonLines $changed (Get-ChangedLines @($marker, 'HEAD'))
    }
    $guide = ConvertTo-RepositoryPath (Resolve-Path $guidePath).Path
    return @{ All = $changed.ContainsKey($guide); PullRequest = $true; Lines = $changed; Source = $source }
}

#endregion

#region Documento in unita'

function New-Segment([string]$Kind, [string[]]$Lines) {
    return [pscustomobject]@{ Kind = $Kind; Lines = $Lines; Locked = $Kind -in $LockedKinds; IsUnit = $Kind -ne 'blank'; Start = 0; Number = 0; Marked = $false }
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
        if ($line -match $OpeningFencePattern) {
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

function Read-Document([string]$Path) {
    $raw = [IO.File]::ReadAllText($Path)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $trailing = $raw.EndsWith($newline)
    $body = if ($trailing) { $raw.Substring(0, $raw.Length - $newline.Length) } else { $raw }
    $lines = if ($body.Length) { $body -split [regex]::Escape($newline) } else { @() }
    return [pscustomobject]@{ Path = $Path; Newline = $newline; Trailing = $trailing; Segments = (ConvertTo-Segments $lines); Changed = $false }
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
    $pattern = @{ list = '^\s*(?:[-*+]|\d+\.)\s+'; quote = '^\s*>\s?' }[$Kind]
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
    if ($Segment.Kind -eq 'row') {
        $Segment.Lines = @($Text)
        return
    }
    $prefix = Get-UnitPrefix $Segment.Kind $Text
    $continuation = if ($Segment.Kind -eq 'quote') { $prefix } else { ' ' * $prefix.Length }
    $Segment.Lines = Format-Wrapped $Text.Substring($prefix.Length) $prefix $continuation
}

function Set-InitialMarks($Document, $Scope, [string]$RelativePath) {
    [void](Update-Numbering $Document 1)
    $lines = $null
    if (-not $Scope.All) { $lines = $Scope.Lines[$RelativePath] }
    foreach ($unit in (Get-Units $Document)) {
        $range = $unit.Start..($unit.Start + $unit.Lines.Count - 1)
        $unit.Marked = $Scope.All -or ($lines -and @($range | Where-Object { $lines.Contains($_) }).Count -gt 0)
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
    $parts.Add("SEZIONE DA GIUDICARE ($FileName)")
    $parts.Add((@(Get-Units $Document | ForEach-Object { $mark = if ($_.Marked) { '*' } else { '' }; "[$($_.Number)$mark] $(Get-UnitText $_)" }) -join "`n"))
    if ($Rejections.Count) {
        $parts.Add('CORREZIONI SCARTATE NEL GIRO PRECEDENTE')
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
    if (-not $After.Trim()) { return 'la correzione svuota l''unità' }
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
    $Document.Segments.Insert($index + 1, (New-Segment 'blank' @('')))
    $Document.Segments.Insert($index + 2, $paragraph)
    $Document.Changed = $true
}

function Invoke-Replacement($Target, $Finding, [hashtable]$Original) {
    $segment = $Target.Segment
    if ($Target.Glossary) { return 'la correzione cambia una voce del glossario' }
    if ($segment.Locked) { return 'la correzione tocca un titolo, un diagramma, un blocco di codice o un commento' }
    $find = "$($Finding.Fix.find)"
    $before = Get-UnitText $segment
    if (-not $Original.ContainsKey($segment)) { $Original[$segment] = $before }
    $occurrences = if ($find) { [regex]::Matches($before, [regex]::Escape($find)).Count } else { 0 }
    if ($occurrences -ne 1) {
        # Un'altra correzione ha gia' cambiato il tratto: l'unita' torna al giudizio nel giro dopo.
        if ($find -and [regex]::Matches($Original[$segment], [regex]::Escape($find)).Count -eq 1) { $segment.Marked = $true; return $null }
        return 'il tratto da correggere non compare una volta sola nell''unità'
    }
    $after = $before.Replace($find, "$($Finding.Fix.text)")
    $reason = Test-Correction $segment.Kind $before $after
    if ($reason) { return $reason }
    Set-UnitText $segment $after
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

    foreach ($finding in $Findings) {
        $target = if ("$($finding.Fix.kind)" -eq 'insert') { $targets[[int]$finding.Fix.unit] } else { $targets[$finding.Unit] }
        $kind = if ($target) { "$($finding.Fix.kind)" } else { 'missing' }
        $reason = switch ($kind) {
            'replace' { Invoke-Replacement $target $finding $original }
            'insert' {
                $text = "$($finding.Fix.text)".Trim()
                $term = Get-GlossaryTerm $text
                if ($target.Glossary -and $term -and -not $glossaryTerms.Add($term)) { $null }
                elseif (-not ($rejected = Test-Correction 'paragraph' '' $text)) { $insertions.Add(@{ Target = $target; Text = $text }); $null }
                else { $rejected }
            }
            'missing' { 'la correzione indica un''unità che la sezione non ha' }
            default { 'il modello non propone una correzione' }
        }
        if ($reason) { [pscustomobject]@{ Finding = $finding; Reason = $reason } }
    }
    foreach ($insertion in $insertions) { Add-Paragraph $insertion.Target.Document $insertion.Target.Segment $insertion.Text (-not $insertion.Target.Glossary) }
}

#endregion

function New-FindingIssue([string]$Title, $Finding, [string]$Rejection) {
    $detail = "«$($Finding.Excerpt)»: $($Finding.Explanation)"
    if ($Rejection) { $detail += "; correzione scartata: $Rejection" }
    return New-Issue $Title $Finding.Rule $detail
}

# Ogni giro giudica le unita' segnate e, se la correzione e' attiva e non e' l'ultimo giro,
# applica le correzioni e segna per il giro dopo le unita' corrette e quelle con una correzione
# scartata, che torna al modello con il motivo. L'ultimo giro verifica.
function Invoke-SectionReview($File, $Context) {
    $document = Read-Document $File.FullName
    $title = (ConvertFrom-MarkdownSection ([IO.File]::ReadAllText($File.FullName))).Title
    if (-not $title) { $title = $File.Name }
    Set-InitialMarks $document $Context.Scope (ConvertTo-RepositoryPath $File.FullName)
    $rejections = @{}

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
        if (-not $findings) { return }

        if (-not $Context.Fix -or $round -eq $Context.Rounds) {
            $findings | ForEach-Object { New-FindingIssue $title $_ ($rejections[$units[$_.Unit]] -join '; ') }
            return
        }
        $rejections = @{}
        foreach ($rejection in @(Invoke-Corrections $document $Context.Glossary $findings)) {
            $unit = $units[$rejection.Finding.Unit]
            $unit.Marked = $true
            $rejections[$unit] = @($rejections[$unit]) + "$($rejection.Finding.Rule): $($rejection.Reason)" | Where-Object { $_ }
        }
        Save-Document $document
        if ($Context.Glossary) { Save-Document $Context.Glossary }
    }
}

function Test-ObjectiveChecks {
    $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File "$PSScriptRoot/Test-Documentation.ps1" 2>&1
    $output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -eq 0) { return }
    $global:LASTEXITCODE = 0
    return New-Issue $JudgeScope 'correzioni non pubblicate' 'i controlli oggettivi falliscono sul testo corretto'
}

function Show-Corrections {
    git diff --quiet -- $docsDirectory
    if ($LASTEXITCODE -eq 0) { return $false }
    $global:LASTEXITCODE = 0
    Write-Host '##[group]Correzioni del giudizio dello stile'
    git -c core.quotePath=false --no-pager diff --stat -- $docsDirectory | ForEach-Object { Write-Host $_ }
    git -c core.quotePath=false --no-pager diff -- $docsDirectory | ForEach-Object { Write-Host $_ }
    Write-Host '##[endgroup]'
    return $true
}

# Le correzioni si applicano al commit di origine della PR, non al commit di merge della build, e
# il commit porta il trailer che segna il giudizio superato.
function Publish-Corrections([string]$Source) {
    $patchFile = [IO.Path]::GetTempFileName()
    $messageFile = [IO.Path]::GetTempFileName()
    $worktree = Join-Path ([IO.Path]::GetTempPath()) "style-judge-$(New-Guid)"
    try {
        git diff --full-index --binary --output=$patchFile -- $docsDirectory
        $out = git worktree add -q --detach $worktree $Source 2>&1
        if ($LASTEXITCODE -ne 0) { return New-Issue $JudgeScope 'correzioni non pubblicate' "copia del ramo non creata: $out" }
        $corrected = (Get-Item $patchFile).Length -gt 0
        if ($corrected) {
            $out = git -C $worktree apply --3way --whitespace=nowarn $patchFile 2>&1
            if ($LASTEXITCODE -ne 0) { return New-Issue $JudgeScope 'correzioni non pubblicate' "correzioni non applicabili al ramo: $out" }
        }
        $subject = if ($corrected) { 'docs: apply the style judge corrections' } else { 'docs: record the passed style judgement' }
        [IO.File]::WriteAllText($messageFile, "$subject`n`n$CleanTrailer`n")
        $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Quality Gate' }
        $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'quality-gate@noreply.local' }
        git -C $worktree add -A
        $out = git -C $worktree -c "user.name=$name" -c "user.email=$email" commit -q --allow-empty -F $messageFile 2>&1
        if ($LASTEXITCODE -ne 0) { return New-Issue $JudgeScope 'correzioni non pubblicate' "commit non riuscito: $out" }
        $authorization = if ($env:SYSTEM_ACCESSTOKEN) { @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") } else { @() }
        $out = git -C $worktree @authorization push -q origin "HEAD:refs/heads/$sourceBranch" 2>&1
        if ($LASTEXITCODE -ne 0) { return New-Issue $JudgeScope 'correzioni non pubblicate' "push sul ramo $sourceBranch non riuscito: $out" }
        Write-Host "Ramo $sourceBranch aggiornato con «$CleanTrailer»: la PR riparte da questo commit"
    }
    finally {
        git worktree remove --force $worktree 2>&1 | Out-Null
        Remove-Item $patchFile, $messageFile -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
    }
}

function Get-StyleIssues {
    $setup = Read-JudgeSetup
    if ($setup.Issue) { return $setup.Issue }

    $sections = Get-SectionFiles
    $glossaryFile = $sections | Where-Object { $glossaryFileName -and $_.Name -eq $glossaryFileName } | Select-Object -First 1
    $scope = Get-ReviewScope
    $fix = $fixRequested -and $scope.PullRequest -and [bool]$sourceBranch
    if ($fixRequested -and -not $fix) { Write-Host 'Correzione automatica non attiva fuori da una PR: il giudizio verifica soltanto' }
    $context = @{
        Scope    = $scope
        Fix      = $fix
        Rounds   = if ($fix) { $maxRounds } else { 1 }
        Rules    = $setup.Rules
        System   = $Instructions + $setup.Guide
        Schema   = New-FindingsSchema $setup.Rules
        Glossary = if ($glossaryFile) { Read-Document $glossaryFile.FullName } else { $null }
    }

    $issues = @()
    foreach ($file in ($sections | Where-Object { -not $glossaryFile -or $_.FullName -ne $glossaryFile.FullName })) {
        try { $issues += @(Invoke-SectionReview $file $context) }
        catch { return New-Issue $JudgeScope 'verifica non eseguita' "$($file.Name): $($_.Exception.Message)" }
    }
    Write-Host "Giudizio dello stile: $($script:Usage.Requests) richieste, $($script:Usage.Input) token in ingresso, $($script:Usage.Output) in uscita"
    if (-not $fix) { return $issues }

    $corrected = Show-Corrections
    if ($issues -or -not $script:Usage.Requests) { return $issues }
    if ($corrected) {
        $objective = Test-ObjectiveChecks
        if ($objective) { return $objective }
    }
    return Publish-Corrections $scope.Source
}

Invoke-Verification { Get-StyleIssues } "Stile del documento in $docsDirectory conforme alla guida" 'Giudizio dello stile disattivato'
