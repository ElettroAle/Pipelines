# SPDX-License-Identifier: Apache-2.0

# Ripara con un modello linguistico i diagrammi di sequenza che la verifica dei flussi (DiagramFlows.ps1)
# respinge dopo l'allineamento delle etichette (Sync-DiagramLabels.ps1): un elemento che il modello C4 non
# ha piu', una chiamata che il modello fa passare per altri elementi. Per ogni sezione con rilievi il
# modello linguistico riceve il modello C4, i rilievi e la sezione, e risponde con i diagrammi riscritti e
# le frasi che li descrivono. La stessa verifica dei flussi accetta la stesura o la rimanda con i rilievi
# rimasti, fino a FLOWS_REPAIR_MAX_DRAFTS stesure; poi la sezione resta com'era e la verifica la segnala.
# Nessuna regola del documento sta qui: decidono i rilievi della verifica e il modello C4.
# Una sezione accettata va subito in un commit sul ramo di appoggio, e tutti i commit tornano sul ramo
# della PR a fine giro: un push sul ramo della PR avvierebbe una nuova build. Se il job si interrompe, la
# build dopo porta sul ramo della PR i commit del ramo di appoggio senza chiamare il modello.

. "$PSScriptRoot/../Common/ModelRetry.ps1"
. "$PSScriptRoot/DiagramFlows.ps1"

$sourceBranch = $env:SOURCE_BRANCH -replace '^refs/heads/', '' -replace '^\$\(.*\)$', ''
$Endpoint = "$env:FLOWS_REPAIR_ENDPOINT".TrimEnd('/')
$Deployment = $env:FLOWS_REPAIR_MODEL
$ReasoningEffort = if ($env:FLOWS_REPAIR_REASONING_EFFORT) { $env:FLOWS_REPAIR_REASONING_EFFORT } else { 'high' }
$MaxDrafts = if ($env:FLOWS_REPAIR_MAX_DRAFTS) { [math]::Max(1, [int]$env:FLOWS_REPAIR_MAX_DRAFTS) } else { 3 }
$GuidePath = $env:STYLE_GUIDE

$RepairScope = 'riparazione dei flussi'
$SideBranchPrefix = 'flows-repair'
# I commit della riparazione non avviano le pipeline con trigger sui rami; la build della PR parte comunque.
$SkipCi = '[skip ci]'
$RequestTimeoutSeconds = 900

$script:Token = $null
$script:Usage = @{ Requests = 0; Input = 0; Output = 0 }

$Instructions = @'
Ripari i diagrammi di sequenza Mermaid di una sezione di un documento di architettura perche' tornino
coerenti con il modello C4, che descrive il sistema com'e': il modello non si cambia, il documento si'.
Il messaggio riporta il modello C4 (gli elementi con identificativo, nome, tipo e container; le relazioni
fra identificativi), i rilievi della verifica dei flussi e la sezione con il numero di ogni riga.

La verifica dei flussi chiede che:
- ogni partecipante sia un elemento del modello, con l'identificativo come alias e il nome come
  etichetta (participant <identificativo> as <nome>, actor per una persona); una seconda istanza dello
  stesso elemento ha l'alias <identificativo>~2;
- un componente stia in un box con il nome del suo container; gli altri elementi stanno fuori dai box;
- un diagramma non mostri insieme un container e i suoi componenti;
- ogni chiamata fra due elementi diversi segua una relazione del modello nella stessa direzione;
- ogni flusso abbia anche un diagramma a livello dei container, senza box.

Correggi solo cio' che i rilievi indicano e cambia il meno possibile: un elemento che il modello non ha
piu' esce dal diagramma, o lo sostituisce l'elemento del modello che ne fa le veci; una chiamata senza
relazione passa per gli elementi che il modello mette in mezzo. Il testo di ogni messaggio dice cio' che
passa.

Rispondi con:
- diagrams: un elemento per ogni diagramma che cambi. line e' il numero della riga del recinto di
  apertura del diagramma, quello citato dai rilievi; text e' il nuovo contenuto del diagramma, senza i
  recinti.
- replacements: le frasi del testo fuori dai diagrammi che descrivono i passaggi cambiati. find e' un
  tratto copiato alla lettera, che nella sezione compare una volta sola; text e' il tratto riscritto con
  i nomi del modello e secondo la guida di stile.
Se il messaggio riporta una stesura scartata, la nuova stesura evita i motivi dello scarto.
'@

function New-RepairSchema {
    $diagram = @{ type = 'object'; additionalProperties = $false; required = @('line', 'text'); properties = @{ line = @{ type = 'integer' }; text = @{ type = 'string' } } }
    $replacement = @{ type = 'object'; additionalProperties = $false; required = @('find', 'text'); properties = @{ find = @{ type = 'string' }; text = @{ type = 'string' } } }
    return @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('diagrams', 'replacements')
        properties           = @{ diagrams = @{ type = 'array'; items = $diagram }; replacements = @{ type = 'array'; items = $replacement } }
    }
}

function Get-SystemMessage {
    $guide = if ($GuidePath -and (Test-Path $GuidePath -PathType Leaf)) { Get-Content -Raw $GuidePath } else { '' }
    return "$Instructions`nGUIDA DI STILE:`n$guide"
}

function Get-AccessToken {
    if ($env:FLOWS_REPAIR_TOKEN) { return $env:FLOWS_REPAIR_TOKEN }
    $token = az account get-access-token --resource 'https://cognitiveservices.azure.com' --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "token Entra ID non ottenuto: $token" }
    return $token
}

function Invoke-Writer([string]$System, [string]$User) {
    if (-not $script:Token) { $script:Token = Get-AccessToken }
    $body = [ordered]@{
        model            = $Deployment
        reasoning_effort = $ReasoningEffort
        messages         = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $User })
        response_format  = @{ type = 'json_schema'; json_schema = @{ name = 'diagram_flows_repair'; strict = $true; schema = New-RepairSchema } }
    } | ConvertTo-Json -Depth 30
    for ($attempt = 1; ; $attempt++) {
        try {
            $response = Invoke-RestMethod -Method Post -Uri "$Endpoint/openai/v1/chat/completions" -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
                -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = "Bearer $script:Token" } -TimeoutSec $RequestTimeoutSeconds
            break
        }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            $transient = $status -eq 429 -or $status -ge 500
            if (-not $transient -or $attempt -ge $ModelMaxAttempts) { throw }
            Start-Sleep -Seconds (Get-ModelRetryDelay $_.Exception.Response $attempt)
        }
    }
    $script:Usage.Requests++
    $script:Usage.Input += [int]$response.usage.prompt_tokens
    $script:Usage.Output += [int]$response.usage.completion_tokens
    return $response.choices[0].message.content | ConvertFrom-Json
}

function Format-FlowModel($Model) {
    $elements = @($Model.Elements.Values | Sort-Object Id | ForEach-Object { "- $($_.Id) | $($_.Name) | $($_.Kind)$(if ($_.Container) { " | $($_.Container)" })" })
    $relations = @($Model.Relations | Sort-Object | ForEach-Object { "- $($_ -replace '>', ' -> ')" })
    return "MODELLO C4`nElementi (identificativo | nome | tipo | container):`n$($elements -join "`n")`nRelazioni (sorgente -> destinazione):`n$($relations -join "`n")"
}

function Format-NumberedLines([string]$Text) {
    $number = 0
    return (($Text -split "`r?`n") | ForEach-Object { $number++; "$number| $_" }) -join "`n"
}

function Get-RepairMessage([string]$Name, [string]$Text, [string[]]$Findings, $Model, $Previous, [string[]]$Rejections) {
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add((Format-FlowModel $Model))
    $parts.Add("RILIEVI DELLA VERIFICA DEI FLUSSI`n$(($Findings | ForEach-Object { "- $_" }) -join "`n")")
    if ($Rejections) {
        $parts.Add("STESURA SCARTATA`n$($Previous | ConvertTo-Json -Depth 10)`nMotivi dello scarto:`n$(($Rejections | ForEach-Object { "- $_" }) -join "`n")")
    }
    $parts.Add("SEZIONE $Name`n$(Format-NumberedLines $Text)")
    return $parts -join "`n`n"
}

function Get-OccurrenceCount([string]$Text, [string]$Find) {
    if (-not $Find) { return 0 }
    return ([regex]::Matches($Text, [regex]::Escape($Find))).Count
}

# I diagrammi si sostituiscono dall'ultimo, cosi' le righe di quelli prima non si spostano; le frasi
# dopo, sul testo che ne risulta.
function Get-DraftText([string]$Original, $Draft) {
    $newline = if ($Original.Contains("`r`n")) { "`r`n" } else { "`n" }
    $section = ConvertFrom-MarkdownSection $Original
    $lines = [Collections.Generic.List[string]]::new([string[]]($Original -split "`r?`n"))
    $rejections = [Collections.Generic.List[string]]::new()
    foreach ($change in @($Draft.diagrams | Where-Object { $_ } | Sort-Object { [int]$_.line } -Descending)) {
        $diagram = @($section.Diagrams | Where-Object Line -EQ ([int]$change.line)) | Select-Object -First 1
        if (-not $diagram) { $rejections.Add("nessun diagramma alla riga $($change.line)"); continue }
        $lines.RemoveRange($diagram.Line, @($diagram.Text -split "`n").Count)
        $lines.InsertRange($diagram.Line, [string[]]("$($change.text)".TrimEnd() -split "`r?`n"))
    }
    $text = $lines -join $newline
    foreach ($replacement in @($Draft.replacements | Where-Object { $_ })) {
        $count = Get-OccurrenceCount $text $replacement.find
        if ($count -ne 1) { $rejections.Add("il tratto da sostituire compare $count volte invece di una: $($replacement.find)"); continue }
        $text = $text.Replace($replacement.find, $replacement.text)
    }
    return @{ Text = $text; Rejections = @($rejections) }
}

function Get-SectionFlowFindings([string]$Path, $Model) {
    $section = @(Get-DocumentSections $docsDirectory | Where-Object { $_.File.FullName -eq $Path })
    $diagrams = Get-Diagrams $section
    Add-ParsedDiagrams $diagrams
    @($diagrams | Where-Object { $_.Parsed.error }) | ForEach-Object { "diagramma non valido ($($_.Id) $($_.Parsed.error))" }
    @(Get-SequenceFlowFindings (Get-SequenceDiagrams $diagrams) $Model) | ForEach-Object Text
}

# Una stesura si scrive nel file solo se la verifica dei flussi la accetta; altrimenti il file torna
# com'era e i motivi vanno al modello con la stesura successiva.
function Repair-Section([string]$Path, [string[]]$Findings, $Model) {
    $original = [IO.File]::ReadAllText($Path)
    $name = Split-Path $Path -Leaf
    $system = Get-SystemMessage
    $previous = $null
    $rejections = @()
    for ($draft = 1; $draft -le $MaxDrafts; $draft++) {
        $answer = Invoke-Writer $system (Get-RepairMessage $name $original $Findings $Model $previous $rejections)
        $applied = Get-DraftText $original $answer
        $rejections = $applied.Rejections
        if (-not $rejections) {
            [IO.File]::WriteAllText($Path, $applied.Text)
            $rejections = @(Get-SectionFlowFindings $Path $Model)
            if (-not $rejections) { return $true }
            [IO.File]::WriteAllText($Path, $original)
        }
        Write-Host "Stesura $draft di $name scartata: $($rejections -join '; ')"
        $previous = $answer
    }
    return $false
}

function Get-GitAuthorization {
    if ($env:SYSTEM_ACCESSTOKEN) { return @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") }
    return @()
}

# La build di una PR gira sul commit di merge: il secondo genitore e' il commit del ramo della PR.
function Get-SourceCommit {
    $commits = @("$(git rev-list --parents -n 1 HEAD)" -split ' ')
    if ($commits.Count -ge 3) { return $commits[2] }
    return $commits[0]
}

function Remove-SideBranch([string]$Side) {
    $authorization = Get-GitAuthorization
    $out = git @authorization push -q origin --delete $Side 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "##vso[task.logissue type=warning]Ramo di appoggio $Side non cancellato: $out" }
    $global:LASTEXITCODE = 0
}

function Resume-InterruptedRepair([string]$Source) {
    $side = "$SideBranchPrefix/$Source"
    $authorization = Get-GitAuthorization
    $found = git @authorization ls-remote origin "refs/heads/$side" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not "$found".Trim()) { $global:LASTEXITCODE = 0; return $null }
    $out = git @authorization fetch -q origin "+refs/heads/${side}:refs/remotes/origin/$side" 2>&1
    if ($LASTEXITCODE -eq 0) { $out = git @authorization push -q origin "refs/remotes/origin/${side}:refs/heads/$sourceBranch" 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        return New-Issue $RepairScope 'riparazione interrotta non ripresa' "push del ramo $side su $sourceBranch non riuscito: $out"
    }
    Remove-SideBranch $side
    return New-Issue $RepairScope 'riparazione ripresa' "i commit della riparazione interrotta sono sul ramo ${sourceBranch}: la verifica dei flussi riparte da quel commit"
}

function New-Publisher([string]$Source) {
    return @{ Source = $Source; Worktree = $null; Side = "$SideBranchPrefix/$Source"; Commits = 0 }
}

function Remove-Publisher($Publisher) {
    if (-not $Publisher.Worktree) { return }
    git worktree remove --force $Publisher.Worktree 2>&1 | Out-Null
    $global:LASTEXITCODE = 0
}

# La sezione riparata si applica a una copia del commit del ramo della PR, non al commit di merge della
# build, e il commit va sul ramo di appoggio.
function Publish-Section($Publisher, [string]$Path) {
    $relativePath = "$($docsDirectory.TrimEnd('/', '\'))/$(Split-Path $Path -Leaf)" -replace '\\', '/'
    $patchFile = [IO.Path]::GetTempFileName()
    $messageFile = [IO.Path]::GetTempFileName()
    try {
        if (-not $Publisher.Worktree) {
            $worktree = Join-Path ([IO.Path]::GetTempPath()) "flows-repair-$(New-Guid)"
            $out = git worktree add -q --detach $worktree $Publisher.Source 2>&1
            if ($LASTEXITCODE -ne 0) { return New-Issue $RepairScope 'diagrammi non pubblicati' "copia del ramo non creata: $out" }
            $Publisher.Worktree = $worktree
        }
        git diff --full-index --binary --output=$patchFile -- $relativePath
        $out = git -C $Publisher.Worktree apply --3way --whitespace=nowarn $patchFile 2>&1
        if ($LASTEXITCODE -ne 0) { return New-Issue $RepairScope 'diagrammi non pubblicati' "righe di $relativePath non applicabili al ramo: $out" }
        [IO.File]::WriteAllText($messageFile, "docs: repair the diagram flows of $relativePath`n`n$SkipCi`n")
        $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Quality Gate' }
        $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'quality-gate@noreply.local' }
        git -C $Publisher.Worktree add -A
        $out = git -C $Publisher.Worktree -c "user.name=$name" -c "user.email=$email" commit -q -F $messageFile 2>&1
        if ($LASTEXITCODE -ne 0) { return New-Issue $RepairScope 'diagrammi non pubblicati' "commit non riuscito: $out" }
        $authorization = Get-GitAuthorization
        $out = git -C $Publisher.Worktree @authorization push -q origin "HEAD:refs/heads/$($Publisher.Side)" 2>&1
        if ($LASTEXITCODE -ne 0) { return New-Issue $RepairScope 'diagrammi non pubblicati' "push sul ramo di appoggio $($Publisher.Side) non riuscito: $out" }
        $Publisher.Commits++
        git add -- $relativePath
        Write-Host "Ramo di appoggio $($Publisher.Side) aggiornato con i diagrammi di $relativePath"
    }
    finally {
        Remove-Item $patchFile, $messageFile -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
    }
}

# Porta sul ramo della PR i commit del ramo di appoggio. Il push avvia la build successiva.
function Complete-Publisher($Publisher) {
    if (-not $Publisher.Commits) { return }
    $authorization = Get-GitAuthorization
    $out = git -C $Publisher.Worktree @authorization push -q origin "HEAD:refs/heads/$sourceBranch" 2>&1
    if ($LASTEXITCODE -ne 0) {
        $global:LASTEXITCODE = 0
        return New-Issue $RepairScope 'diagrammi non pubblicati' "push sul ramo $sourceBranch non riuscito, il lavoro resta sul ramo $($Publisher.Side): $out"
    }
    Remove-SideBranch $Publisher.Side
    return New-Issue $RepairScope 'diagrammi riparati con il modello C4' "$($Publisher.Commits) commit sul ramo ${sourceBranch}: la verifica dei flussi riparte dall'ultimo"
}

# Si riparano le sezioni del documento; le decisioni restano alla verifica dei flussi.
function Get-SectionsToRepair {
    $sections = @(Get-DocumentSections $docsDirectory | ForEach-Object { $_.File.FullName })
    return @(Get-FlowFindings | Where-Object { $_.File -and $sections -contains $_.File } | Group-Object File)
}

function Repair-DiagramFlows {
    if (-not $sourceBranch) { return Write-Host 'Fuori da una PR i diagrammi non si riparano: la verifica dei flussi segnala cio'' che non torna' }
    $source = Get-SourceCommit
    $resumed = Resume-InterruptedRepair $source
    if ($resumed) { return $resumed }

    $sections = Get-SectionsToRepair
    if (-not $sections) { return }
    $flowModel = Get-FlowModel
    if ($flowModel.Finding) { return }

    $publisher = New-Publisher $source
    $issues = @()
    try {
        foreach ($section in $sections) {
            try { $repaired = Repair-Section $section.Name @($section.Group | ForEach-Object Text) $flowModel.Model }
            catch {
                $issues += New-Issue $RepairScope 'riparazione interrotta' "$(Split-Path $section.Name -Leaf): $($_.Exception.Message)"
                break
            }
            if (-not $repaired) { continue }
            $issue = Publish-Section $publisher $section.Name
            if ($issue) { return @($issues) + $issue }
        }
        Write-Host "Riparazione dei flussi: $($script:Usage.Requests) richieste, $($script:Usage.Input) token in ingresso, $($script:Usage.Output) in uscita"
        return @($issues) + @(Complete-Publisher $publisher)
    }
    finally { Remove-Publisher $publisher }
}

Invoke-Verification { Repair-DiagramFlows } "Diagrammi di $docsDirectory coerenti con il modello C4" 'Riparazione dei flussi disattivata'
