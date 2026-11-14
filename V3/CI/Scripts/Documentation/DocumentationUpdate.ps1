# SPDX-License-Identifier: Apache-2.0

# Aggiornamento della documentazione dopo un cambiamento arrivato nel ramo principale
# (Update-Documentation.ps1). Il cambiamento sono i commit, dal punto di partenza registrato in un file del
# repository, che toccano le cartelle osservate: i commit degli aggiornamenti precedenti toccano anche il
# punto di partenza e restano fuori. Il modello linguistico riscrive i documenti che il cambiamento tocca;
# le verifiche della documentazione giudicano ogni stesura, e una stesura che porta rilievi nuovi torna al
# modello con i motivi dello scarto. Il punto di partenza avanza con i documenti, nella stessa PR: con il
# modello non disponibile resta dov'e', e la run successiva riprende lo stesso cambiamento.

. "$PSScriptRoot/../LanguageModel/LanguageModel.ps1"
. "$PSScriptRoot/../Common/DocumentLanguage.ps1"

$DefaultVerifications = @('Adr/Test-AdrCorpus.ps1', 'Arc42/Test-Arc42Document.ps1', 'Documentation/Test-Documentation.ps1', 'Mermaid/Test-MermaidDiagrams.ps1', 'Mermaid/Test-DiagramFlows.ps1')
$DecisionFilePattern = '^\d{4}-[a-z0-9-]+\.md$'
$RequestTimeoutSeconds = 900
$WorkItemTitleLength = 255

$UpdateInstructions = @'
Aggiorni la documentazione di architettura dopo un cambiamento arrivato nel ramo principale. Il messaggio
riporta il cambiamento (i commit con le differenze delle decisioni e del modello del sistema), l'indice
delle decisioni, e i documenti che puoi riscrivere, ognuno con il suo percorso: le sezioni del documento,
le guide e le decisioni che il cambiamento tocca o che descrivono il codice.

Porta nel testo cio' che il cambiamento introduce:
- una decisione nuova: la sezione che tratta il suo argomento spiega la scelta e rimanda alla decisione con
  un link relativo al suo file;
- una decisione che ne sostituisce un'altra: il testo spiega la scelta nuova e non presenta piu' la
  decisione sostituita come scelta in vigore;
- un elemento nuovo, cambiato o tolto nel modello del sistema (applicazioni, componenti, comunicazioni,
  risorse di un ambiente): la sezione che lo tratta lo spiega e ne dice il ruolo;
- una classe nuova o cambiata nel codice governato da una decisione: la struttura e il flusso nel codice di
  quella decisione la mostrano. L'esito di una decisione non cambia mai.

Cambia solo cio' che il cambiamento richiede e segui la guida di stile. L'intestazione dei metadati di una
decisione e la sua sezione delle versioni non si toccano: la versione la scrive la pipeline.

Rispondi con:
- documents: un elemento per ogni documento che cambi. path e' il percorso come nel messaggio; text e' il
  testo intero nuovo del documento; note, solo per una decisione, dice in poche parole che cosa cambia, per
  la voce della sua versione nuova; per gli altri documenti note e' vuota.
- summary: che cosa hai aggiornato e perche', in poche frasi.
Se il cambiamento non chiede di cambiare nulla, documents e' vuoto.
Se il messaggio riporta una stesura scartata, la nuova stesura evita i motivi dello scarto.
'@

function Split-List([string]$Value) {
    return @("$Value" -split ';' | ForEach-Object Trim | Where-Object { $_ })
}

# Una variabile della pipeline non definita arriva come la sua macro, $(nome), non come stringa vuota.
function Get-Setting([string]$Value, [string]$Default) {
    $text = "$Value".Trim() -replace '^\$\(.*\)$', ''
    if ($text) { return $text }
    return $Default
}

function Get-UpdateSettings {
    $docs = Get-Setting $env:DOCS_DIRECTORY 'docs/architecture'
    $decisions = Get-Setting $env:DECISIONS_DIRECTORY 'docs/decisions'
    $changePaths = Split-List $env:DOCS_UPDATE_CHANGE_PATHS
    $verifications = Split-List $env:DOCS_UPDATE_VERIFICATIONS
    return @{
        DocsDirectory      = $docs
        DecisionsDirectory = $decisions
        Guides             = Split-List $env:DOCS_UPDATE_GUIDES
        ChangePaths        = if ($changePaths) { $changePaths } else { @($decisions, "$docs/c4/generated") }
        BaselineFile       = Get-Setting $env:DOCS_UPDATE_BASELINE '.documentation-baseline'
        Verifications      = if ($verifications) { $verifications } else { $DefaultVerifications }
        MaxDrafts          = [math]::Max(1, [int](Get-Setting $env:DOCS_UPDATE_MAX_DRAFTS '3'))
        StyleGuide         = Get-Setting $env:STYLE_GUIDE ''
        OriginDirectory    = Get-Setting $env:DOCS_UPDATE_ORIGIN_DIRECTORY ''
        DescriptionFile    = Get-Setting $env:DOCS_UPDATE_DESCRIPTION_FILE ''
        WorkItemType       = Get-Setting $env:DOCS_UPDATE_WORK_ITEM_TYPE 'Bug'
        Provider           = $env:DOCS_UPDATE_PROVIDER
        Endpoint           = Get-Setting $env:DOCS_UPDATE_ENDPOINT ''
        Model              = $env:DOCS_UPDATE_MODEL
        ReasoningEffort    = Get-Setting $env:DOCS_UPDATE_REASONING_EFFORT 'high'
        MaxTokens          = [int]"0$env:DOCS_UPDATE_MAX_TOKENS"
        AccessToken        = $env:DOCS_UPDATE_TOKEN
    }
}

function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path, (Get-Location).Path)
}

function Get-RelativePath([string]$Path) {
    return [IO.Path]::GetRelativePath((Get-Location).Path, $Path) -replace '\\', '/'
}

function Invoke-UpdateGit {
    $output = git @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' '): $output" }
    return @($output | ForEach-Object { "$_" })
}

function Read-Baseline($Settings) {
    $path = Get-FullPath $Settings.BaselineFile
    if (-not (Test-Path $path -PathType Leaf)) { return $null }
    return ([IO.File]::ReadAllText($path)).Trim()
}

function Save-Baseline($Settings, [string]$Commit) {
    $path = Get-FullPath $Settings.BaselineFile
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, "$Commit`n")
}

function Assert-BaselineInHistory([string]$Baseline) {
    git cat-file -e "$Baseline^{commit}" 2>$null
    $found = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    if (-not $found) { throw "punto di partenza $Baseline assente dalla storia: il checkout deve portare tutta la storia (fetchDepth: 0)" }
}

function Get-CommitFiles([string]$Commit) {
    return @(Invoke-UpdateGit diff-tree --no-commit-id --name-only -r $Commit)
}

# I commit di un aggiornamento precedente portano il punto di partenza: le loro modifiche alle cartelle
# osservate, come la versione nuova di una decisione, non sono un cambiamento da documentare.
function Get-Change($Settings, [string]$Baseline) {
    Assert-BaselineInHistory $Baseline
    $baselinePath = $Settings.BaselineFile -replace '\\', '/' -replace '^\./', ''
    $revisions = @('rev-list', '--no-merges', '--reverse', "$Baseline..HEAD", '--') + $Settings.ChangePaths
    $candidates = @(Invoke-UpdateGit @revisions)
    $commits = @($candidates | Where-Object { $_ -and (Get-CommitFiles $_) -notcontains $baselinePath })
    $files = @($commits | ForEach-Object { Get-CommitFiles $_ } | Sort-Object -Unique)
    $subjects = @($commits | ForEach-Object { "$(Invoke-UpdateGit show -s --format='%h %s' $_)" })
    $text = @($commits | ForEach-Object {
            $show = @('show', '--no-color', '--format=commit %h %s', $_, '--') + $Settings.ChangePaths
            (Invoke-UpdateGit @show) -join "`n"
        }) -join "`n`n"
    return @{ Commits = $commits; Files = $files; Subjects = $subjects; Text = $text }
}

function Get-RepositoryName([string]$Directory) {
    $remote = "$(git -C $Directory remote get-url origin 2>$null)".Trim()
    $global:LASTEXITCODE = 0
    if ($remote) { return ($remote.TrimEnd('/') -split '[\\/]')[-1] -replace '\.git$', '' }
    return Split-Path -Leaf (Get-FullPath $Directory)
}

# L'origine e' il commit che ha avviato la run: quello del repository sorgente, se il consumer ne indica
# il checkout, altrimenti l'ultimo del repository della documentazione.
function Get-Origin($Settings) {
    $directory = if ($Settings.OriginDirectory) { $Settings.OriginDirectory } else { (Get-Location).Path }
    $subject = "$(Invoke-UpdateGit -C $directory log -1 --format=%s)".Trim()
    $commit = "$(Invoke-UpdateGit -C $directory rev-parse --short=8 HEAD)".Trim()
    $repository = Get-RepositoryName $directory
    $pullRequest = if ($subject -match '\bPR (\d+)') { $Matches[1] } else { $null }
    return @{ Label = "$subject ($repository@$commit)"; Repository = $repository; Commit = $commit; PullRequest = $pullRequest }
}

function Get-VersionOrigin($Origin) {
    if ($Origin.PullRequest) { return $DocumentLanguage.UpdateOriginPullRequest -f $Origin.PullRequest, $Origin.Repository }
    return $DocumentLanguage.UpdateOriginCommit -f $Origin.Commit, $Origin.Repository
}

function Split-Decision([string]$Text) {
    $match = [regex]::Match($Text, '\A---\r?\n(.*?)\r?\n---\r?\n', 'Singleline')
    if (-not $match.Success) { return @{ Front = @(); Fields = @{}; Body = $Text } }
    $front = @($match.Groups[1].Value -split '\r?\n')
    $fields = @{}
    $front | Where-Object { $_ -match '^([\w-]+):\s*(.*)$' } | ForEach-Object { $fields[$Matches[1]] = $Matches[2].Trim() }
    return @{ Front = $front; Fields = $fields; Body = $Text.Substring($match.Length) }
}

function Get-DecisionVersion($Fields) {
    if ("$($Fields['version'])" -match '^\d+$') { return [int]$Fields['version'] }
    return 1
}

function Set-FrontField([string[]]$Front, [string]$Name, [string]$Value) {
    $line = "${Name}: $Value"
    $index = [Array]::FindIndex($Front, [Predicate[string]] { param($l) $l -match "^$([regex]::Escape($Name)):" })
    if ($index -lt 0) { return @($Front) + $line }
    $copy = @($Front)
    $copy[$index] = $line
    return $copy
}

function Add-VersionEntry([string]$Body, [string]$Entry) {
    $section = $DocumentLanguage.AdrVersionsSection
    $lines = [Collections.Generic.List[string]]::new([string[]]($Body.TrimEnd() -split '\r?\n'))
    $heading = $lines.FindIndex([Predicate[string]] { param($l) $l -match "^##\s+$([regex]::Escape($section))\s*$" })
    if ($heading -lt 0) { return "$($Body.TrimEnd())`n`n## $section`n`n$Entry`n" }
    $end = $heading + 1
    while ($end -lt $lines.Count -and $lines[$end] -notmatch '^#{1,2}\s') { $end++ }
    $insert = $end
    while ($insert -gt $heading + 1 -and -not $lines[$insert - 1].Trim()) { $insert-- }
    if ($insert -eq $heading + 1) { $lines.Insert($insert, ''); $insert++ }
    $lines.Insert($insert, $Entry)
    return ($lines -join "`n") + "`n"
}

# Il modello riscrive il corpo di una decisione; l'intestazione dei metadati resta quella del corpus e la
# versione nuova, con la voce che nomina l'origine del cambiamento, la scrive il passo.
function Get-VersionedDecision([string]$Original, [string]$Drafted, [string]$Note, $Origin) {
    $before = Split-Decision $Original
    $after = Split-Decision $Drafted
    if ($after.Body.Trim() -eq $before.Body.Trim()) { return $Original }
    $version = (Get-DecisionVersion $before.Fields) + 1
    $front = Set-FrontField $before.Front 'version' "$version"
    $body = Add-VersionEntry $after.Body "- ${version}: $($Note.Trim()) ($(Get-VersionOrigin $Origin))"
    return "---`n$($front -join "`n")`n---`n$body"
}

function Get-Decisions($Settings) {
    $directory = Get-FullPath $Settings.DecisionsDirectory
    if (-not (Test-Path $directory)) { return @() }
    return @(Get-ChildItem $directory -File | Where-Object Name -Match $DecisionFilePattern | Sort-Object Name | ForEach-Object {
            $text = [IO.File]::ReadAllText($_.FullName)
            $decision = Split-Decision $text
            $title = if ($decision.Body -match '(?m)^#\s+(.+?)\s*$') { $Matches[1] } else { '' }
            @{ Id = $_.BaseName; Path = $_.FullName; Text = $text; Fields = $decision.Fields; Title = $title }
        })
}

function Format-DecisionIndex($Decisions) {
    $lines = @($Decisions | ForEach-Object {
            $status = "$($_.Fields['status'])"
            if ($_.Fields['superseded-by']) { $status += " da $($_.Fields['superseded-by'])" }
            if ($_.Fields['supersedes']) { $status += ", sostituisce $($_.Fields['supersedes'])" }
            "- $($_.Id) | $status | $($_.Title)"
        })
    return "INDICE DELLE DECISIONI (identificativo | stato | titolo)`n$($lines -join "`n")"
}

function New-Document([string]$Path, [bool]$IsDecision) {
    return @{ Path = $Path; Original = [IO.File]::ReadAllText($Path); IsDecision = $IsDecision }
}

# I documenti che il modello puo' riscrivere: le sezioni del documento, le guide, le decisioni che il
# cambiamento tocca e quelle che governano il codice, perche' una classe nuova cambia la loro struttura.
function Get-Documents($Settings, $Change, $Decisions) {
    $documents = [ordered]@{}
    $docsDirectory = Get-FullPath $Settings.DocsDirectory
    if (Test-Path $docsDirectory) {
        Get-ChildItem $docsDirectory -File -Filter '*.md' | Sort-Object Name | ForEach-Object { $documents[(Get-RelativePath $_.FullName)] = New-Document $_.FullName $false }
    }
    foreach ($guide in $Settings.Guides) {
        $path = Get-FullPath $guide
        if (Test-Path $path -PathType Leaf) { $documents[(Get-RelativePath $path)] = New-Document $path $false }
    }
    foreach ($decision in $Decisions) {
        $relative = Get-RelativePath $decision.Path
        if ($Change.Files -contains $relative -or $decision.Fields['governs']) { $documents[$relative] = New-Document $decision.Path $true }
    }
    return $documents
}

function New-UpdateSchema {
    $document = @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('path', 'text', 'note')
        properties           = @{ path = @{ type = 'string' }; text = @{ type = 'string' }; note = @{ type = 'string' } }
    }
    return @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('summary', 'documents')
        properties           = @{ summary = @{ type = 'string' }; documents = @{ type = 'array'; items = $document } }
    }
}

function Get-UpdateSystemMessage($Settings) {
    $guide = if ($Settings.StyleGuide -and (Test-Path (Get-FullPath $Settings.StyleGuide) -PathType Leaf)) { [IO.File]::ReadAllText((Get-FullPath $Settings.StyleGuide)) } else { '' }
    return "$UpdateInstructions`nGUIDA DI STILE:`n$guide"
}

function Get-UpdateMessage($Change, $Origin, [string]$Index, $Documents, $Previous, [string[]]$Rejections) {
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add("CAMBIAMENTO`nOrigine: $($Origin.Label)`n$($Change.Text)")
    $parts.Add($Index)
    $parts.Add("DOCUMENTI`n$(@($Documents.Keys | ForEach-Object { "=== $_`n$($Documents[$_].Original)" }) -join "`n")")
    if ($Rejections) {
        $parts.Add("STESURA SCARTATA`n$($Previous | ConvertTo-Json -Depth 10)`nMotivi dello scarto:`n$(($Rejections | ForEach-Object { "- $_" }) -join "`n")")
    }
    return $parts -join "`n`n"
}

function Write-Document($Document, [string]$Text) {
    $newline = if ($Document.Original.Contains("`r`n")) { "`r`n" } else { "`n" }
    [IO.File]::WriteAllText($Document.Path, ($Text -replace '\r?\n', $newline))
}

function Restore-Documents($Documents) {
    foreach ($document in $Documents.Values) { [IO.File]::WriteAllText($document.Path, $document.Original) }
}

# Scrive la stesura nei file e restituisce i motivi per cui non si puo' scrivere.
function Set-Draft($Documents, $Draft, $Origin) {
    $rejections = [Collections.Generic.List[string]]::new()
    foreach ($change in @($Draft.documents | Where-Object { $_ })) {
        $document = $Documents["$($change.path)"]
        if (-not $document) { $rejections.Add("documento fuori dall'aggiornamento: $($change.path)"); continue }
        if (-not $document.IsDecision) { Write-Document $document $change.text; continue }
        $versioned = Get-VersionedDecision $document.Original $change.text "$($change.note)" $Origin
        if ($versioned -ne $document.Original -and -not "$($change.note)".Trim()) { $rejections.Add("decisione $($change.path) cambiata senza la nota della versione"); continue }
        Write-Document $document $versioned
    }
    return @($rejections)
}

function Get-ErrorIssues([object[]]$Output) {
    $issues = foreach ($line in $Output) { if ("$line" -match '^##vso\[task\.logissue type=error\](.*)$') { $Matches[1] } }
    return @($issues)
}

# Ogni verifica gira come in pipeline, in un processo a parte che termina con il suo codice di uscita.
function Get-VerificationIssues($Settings) {
    $pwsh = (Get-Process -Id $PID).Path
    $previousMode = $env:GATE_MODE
    $env:GATE_MODE = 'enforce'
    try {
        foreach ($verification in $Settings.Verifications) {
            $script = Join-Path $PSScriptRoot "../$verification"
            $output = @(& $pwsh -NoProfile -NonInteractive -WorkingDirectory (Get-Location).Path -File $script 2>&1)
            $code = $LASTEXITCODE
            $issues = Get-ErrorIssues $output
            if ($code -ne 0 -and -not $issues) { $issues = @("$verification terminata con codice ${code}: $((@($output | Select-Object -Last 3) | ForEach-Object { "$_" }) -join ' ')") }
            $issues
        }
    }
    finally {
        $env:GATE_MODE = $previousMode
        $global:LASTEXITCODE = 0
    }
}

# Le stesure si scrivono nei file e passano dalle verifiche: una stesura che porta rilievi che prima non
# c'erano torna com'era e i motivi vanno al modello con la stesura successiva.
function Write-Update($Settings, $Client, $Change, $Origin, $Documents, [string]$Index) {
    $system = Get-UpdateSystemMessage $Settings
    $before = @(Get-VerificationIssues $Settings)
    $previous = $null
    $rejections = @()
    for ($draft = 1; $draft -le $Settings.MaxDrafts; $draft++) {
        try { $answer = Invoke-LanguageModel $Client $system (Get-UpdateMessage $Change $Origin $Index $Documents $previous $rejections) (New-UpdateSchema) 'documentation_update' }
        catch { return @{ Status = 'unavailable'; Reason = $_.Exception.Message } }
        $response = $answer.Response
        if (-not @($response.documents | Where-Object { $_ }).Count) { return @{ Status = 'empty'; Summary = "$($response.summary)" } }
        $rejections = @(Set-Draft $Documents $response $Origin)
        if (-not $rejections) { $rejections = @(Get-VerificationIssues $Settings | Where-Object { $before -notcontains $_ }) }
        if (-not $rejections) { return @{ Status = 'accepted'; Summary = "$($response.summary)" } }
        Restore-Documents $Documents
        Write-Host "Stesura $draft scartata: $($rejections -join '; ')"
        $previous = $response
    }
    return @{ Status = 'rejected'; Rejections = $rejections }
}

function ConvertTo-HtmlText([string]$Text) {
    return [Net.WebUtility]::HtmlEncode($Text)
}

function Get-RejectionSteps($Origin, $Change, [string[]]$Rejections) {
    $commits = @($Change.Subjects | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join ''
    $reasons = @($Rejections | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join ''
    return "<p>Cambiamento da documentare: $(ConvertTo-HtmlText $Origin.Label)</p><p>Commit del cambiamento:</p><ul>$commits</ul>" +
    "<p>Motivi del rifiuto dell'ultima stesura:</p><ul>$reasons</ul>"
}

function New-RejectionWorkItem($Settings, $Origin, $Change, [string[]]$Rejections) {
    $title = "Documentazione non aggiornata: $($Origin.Label)"
    if ($title.Length -gt $WorkItemTitleLength) { $title = $title.Substring(0, $WorkItemTitleLength) }
    $fields = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = $title }
        @{ op = 'add'; path = '/fields/Microsoft.VSTS.TCM.ReproSteps'; value = Get-RejectionSteps $Origin $Change $Rejections }
    )
    $project = [uri]::EscapeDataString("$env:SYSTEM_TEAMPROJECT")
    $type = [uri]::EscapeDataString($Settings.WorkItemType)
    $uri = "$("$env:SYSTEM_COLLECTIONURI".TrimEnd('/'))/$project/_apis/wit/workitems/`$${type}?api-version=7.1"
    $body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $fields -Depth 5))
    $created = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/json-patch+json; charset=utf-8' -Headers @{ Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN" }
    return $created.id
}

function Save-Description($Settings, [string]$Text) {
    if (-not $Settings.DescriptionFile) { return }
    $path = Get-FullPath $Settings.DescriptionFile
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, $Text)
}

function Format-Description([string]$Text, $Origin, $Change) {
    $commits = @($Change.Subjects | ForEach-Object { "- $_" }) -join "`n"
    return "$Text`n`nCambiamento: $($Origin.Label)`n`n$commits`n"
}

function New-Outcome([string]$Status, [string]$Message, [bool]$Publish = $false) {
    return @{ Status = $Status; Message = $Message; Publish = $Publish }
}

function Complete-Update($Settings, $Result, $Origin, $Change, [string]$Head) {
    switch ($Result.Status) {
        'unavailable' { return New-Outcome 'unavailable' "Modello non disponibile, la documentazione resta com'e' e la run successiva riprende da ${Head}: $($Result.Reason)" }
        'empty' {
            Save-Baseline $Settings $Head
            Save-Description $Settings (Format-Description "Nessun documento da cambiare. $($Result.Summary)".Trim() $Origin $Change)
            return New-Outcome 'unchanged' 'Il cambiamento non chiede di cambiare la documentazione' $true
        }
        'accepted' {
            Save-Baseline $Settings $Head
            Save-Description $Settings (Format-Description $Result.Summary $Origin $Change)
            return New-Outcome 'updated' "Documentazione aggiornata: $($Result.Summary)" $true
        }
        default {
            $id = New-RejectionWorkItem $Settings $Origin $Change $Result.Rejections
            Save-Baseline $Settings $Head
            Save-Description $Settings (Format-Description "Aggiornamento respinto dalle verifiche a ogni stesura: work item $id." $Origin $Change)
            return New-Outcome 'rejected' "Aggiornamento respinto a ogni stesura, la documentazione non cambia: work item $id ($($Result.Rejections -join '; '))" $true
        }
    }
}

function Invoke-DocumentationUpdate($Settings) {
    $head = "$(Invoke-UpdateGit rev-parse HEAD)".Trim()
    $baseline = Read-Baseline $Settings
    if (-not $baseline) {
        Save-Baseline $Settings $head
        return New-Outcome 'baseline' "Punto di partenza registrato: $head" $true
    }
    $change = Get-Change $Settings $baseline
    if (-not $change.Commits) { return New-Outcome 'unchanged' 'Nessun cambiamento da documentare' }

    $origin = Get-Origin $Settings
    $client = New-LanguageModel $Settings.Provider $Settings.Endpoint $Settings.Model $Settings.ReasoningEffort -AccessToken $Settings.AccessToken -MaxTokens $Settings.MaxTokens -TimeoutSeconds $RequestTimeoutSeconds
    $decisions = Get-Decisions $Settings
    $documents = Get-Documents $Settings $change $decisions
    $result = Write-Update $Settings $client $change $origin $documents (Format-DecisionIndex $decisions)
    return Complete-Update $Settings $result $origin $change $head
}
