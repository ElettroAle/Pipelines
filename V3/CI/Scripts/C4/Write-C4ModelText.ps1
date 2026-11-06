# SPDX-License-Identifier: Apache-2.0

# Testo del modello C4 di tutto il sistema: la descrizione di ogni elemento, cio' che passa su ogni
# relazione, le persone e i sistemi esterni con le loro relazioni. Un solo testo per tutti i repository
# sorgente (SOURCE_REPOSITORIES, ognuno in SOURCES_DIRECTORY/<repository>): parti scritte separatamente
# dichiarerebbero due volte la stessa persona o la stessa applicazione con nomi diversi. Lo scrive un
# modello Azure OpenAI leggendo i frammenti dei lettori (FRAGMENT_DIRECTORY), il codice degli elementi
# (sources), la guida di stile e i documenti di contesto; Export-C4CodeModel.ps1 lo compone con la
# struttura. Si scrive un container alla volta, poi il modello rilegge il catalogo di persone e sistemi
# esterni vedendo insieme tutti i container e unisce le voci che indicano la stessa cosa.
# Una stesura respinta non ferma la run: cio' che la struttura non contiene si toglie e si elenca in
# C4_CORRECTIONS_FILE, i testi mancanti e le frasi troppo lunghe tornano al modello, che riscrive solo
# quelli. Il testo accettato si salva in model.text.json (GENERATED_DIRECTORY) e, con PROGRESS_BRANCH,
# sul ramo, cosi' una pipeline fallita e rilanciata riparte dai container senza testo accettato. Il testo
# di un container la cui struttura non cambia resta quello accettato.
# Infine il modello rivede tutto il sistema insieme: tiene un sistema esterno solo se la configurazione
# di produzione (C4_REVIEW_EVIDENCE, file sotto SOURCES_DIRECTORY) lo prova con un tratto citato alla
# lettera, che si verifica nel file; toglie le relazioni con persone e sistemi esterni che non sono vere;
# da' a ogni container il nome con cui lo si riconosce e unisce i container che sono copie di uno stesso.
# La revisione si ripete solo quando cambiano la struttura o la configurazione di produzione.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/DocumentLanguage.ps1"
. "$PSScriptRoot/../Common/MarkdownText.ps1"
. "$PSScriptRoot/../Common/ModelRetry.ps1"
. "$PSScriptRoot/C4CodeModel.ps1"

$SourceRepositories = @("$env:SOURCE_REPOSITORIES" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$SourcesDirectory = if ($env:SOURCES_DIRECTORY) { $env:SOURCES_DIRECTORY } else { 'sources' }
$GeneratedDirectory = if ($env:GENERATED_DIRECTORY) { $env:GENERATED_DIRECTORY } else { 'docs/architecture/c4/generated' }
$CorrectionsFile = $env:C4_CORRECTIONS_FILE
$GuidePath = $env:STYLE_GUIDE
$ContextPaths = @("$env:C4_TEXT_CONTEXT" -split ';' | ForEach-Object Trim | Where-Object { $_ })
$Endpoint = "$env:C4_TEXT_ENDPOINT".TrimEnd('/')
$Model = $env:C4_TEXT_MODEL
$ReasoningEffort = if ($env:C4_TEXT_REASONING_EFFORT) { $env:C4_TEXT_REASONING_EFFORT } else { 'high' }
$MaxDrafts = if ($env:C4_TEXT_MAX_DRAFTS) { [math]::Max(1, [int]$env:C4_TEXT_MAX_DRAFTS) } else { 3 }
$MaxSourceCharacters = if ($env:C4_TEXT_MAX_SOURCE_CHARACTERS) { [int]$env:C4_TEXT_MAX_SOURCE_CHARACTERS } else { 300000 }
$MaxContextCharacters = if ($env:C4_TEXT_MAX_CONTEXT_CHARACTERS) { [int]$env:C4_TEXT_MAX_CONTEXT_CHARACTERS } else { 100000 }
$ProgressBranch = "$env:PROGRESS_BRANCH" -replace '^refs/heads/', ''
$MaximumWords = [int]$env:READABILITY_MAX_WORDS
$Abbreviations = @("$env:READABILITY_ABBREVIATIONS" -split ';' | ForEach-Object Trim | Where-Object { $_ })
$EvidencePaths = @("$env:C4_REVIEW_EVIDENCE" -split ';' | ForEach-Object Trim | Where-Object { $_ })

$TextScope = 'testo del modello C4'
$TextFileName = 'model.text.json'
$ActorParts = @('people', 'externalSystems')
$IdentifierPattern = '^[a-z][a-z0-9_]*$'
$SourceExtensions = @('.cs', '.ts', '.html', '.json', '.csproj', '.tf', '.md', '.yaml', '.yml', '.sql')
$TestFilePattern = '\.(spec|test)\.ts$|Tests?\.cs$'
$RequestTimeoutSeconds = 900

$Instructions = @'
Scrivi il testo di un container del modello C4 di un'architettura software. La struttura (elementi e
relazioni) nasce dal codice e non si cambia: scrivi solo il testo, nella lingua del documento, per chi
lavora sulla piattaforma.

- elements: una voce per ogni elemento della parte, con il suo identificativo. La descrizione dice cosa
  fa l'elemento e a cosa serve, in una o due frasi, senza ripetere il nome o la tecnologia.
- relationships: una voce per ogni relazione della parte, con sorgente e destinazione date. description
  dice cio' che passa, al presente (ad esempio: "Invia i messaggi della conversazione"); technology dice
  il protocollo o il mezzo, vuoto se il codice non lo mostra.
- people ed externalSystems: solo le persone e i sistemi esterni che usano gli elementi della parte, o
  che gli elementi usano, e che il catalogo non contiene ancora. Identificativo in minuscolo con
  underscore; technical vale true se interessa solo chi gestisce la piattaforma.
- links: le relazioni fra una persona o un sistema esterno (del catalogo o nuovo) e un elemento della
  parte, in una delle due direzioni, con cio' che passa.

I container del sistema e le applicazioni dei repository sorgente del sistema fanno parte del sistema:
non sono mai persone ne' sistemi esterni.

Non aggiungere elementi o relazioni fra elementi del codice. Scrivi solo cio' che il codice, le
decisioni e i requisiti mostrano. Il testo segue la guida di stile. Se il messaggio elenca voci da
riscrivere, riscrivi quelle: le altre voci restano quelle gia' accettate.
'@

$CatalogueInstructions = @'
Controlli il catalogo delle persone e dei sistemi esterni di un modello C4, scritto un container alla
volta. Rispondi con una voce per ogni identificativo del catalogo, con sameAs:
- vuoto se la voce e' distinta da tutte le altre;
- l'identificativo di un'altra voce del catalogo dello stesso tipo se le due voci indicano la stessa
  persona o lo stesso sistema; la voce che resta ha sameAs vuoto;
- l'identificativo di un container del sistema se la voce e' un sistema esterno che in realta' e' quel
  container.
Una persona e un sistema esterno non sono mai la stessa cosa. Decidi da nomi, descrizioni e relazioni.
'@

$ReviewInstructions = @'
Rivedi il modello C4 di tutto il sistema, scritto un container alla volta, perche' descriva il sistema
come gira in produzione e sia coerente in ogni sua parte. Rispondi con una voce per ogni sistema
esterno, per ogni relazione con persone e sistemi esterni e per ogni container, con il motivo in una
frase:
- externalSystems: inProduction vale true solo se la configurazione di produzione mostra che il sistema
  si usa. evidence cita il file con il percorso dato nel messaggio e un tratto del file copiato alla
  lettera che lo prova. Un sistema che compare solo nel codice, o con valori segnaposto o di esempio
  nella configurazione, non e' in produzione.
- links: keep vale false se la relazione non e' vera. Una persona usa solo le applicazioni con cui
  interagisce direttamente, non quelle che un'altra applicazione del sistema chiama per lei.
- containers: name e' il nome con cui chi lavora sulla piattaforma riconosce il container, unico nel
  sistema; un nome gia' scelto nella revisione precedente resta, salvo che sia sbagliato. Un'applicazione
  si chiama con la parte del suo nome nel codice che la distingue nel sistema, cioe' senza il prefisso
  comune a tutte le applicazioni, anche se ha piu' di un progetto; una risorsa si chiama con cio' che fa
  per il sistema, nella lingua del documento, mai con il nome tecnico della risorsa. sameAs e'
  l'identificativo di un altro container della stessa tecnologia quando i due sono copie della stessa
  cosa (per esempio una risorsa per tenant), vuoto altrimenti; il container che resta ha sameAs vuoto.
'@

function New-TextSchema {
    $text = @{ type = 'string' }
    $relation = @{
        type = 'object'; additionalProperties = $false; required = @('source', 'target', 'description', 'technology')
        properties = @{ source = $text; target = $text; description = $text; technology = $text }
    }
    $actor = @{
        type = 'object'; additionalProperties = $false; required = @('id', 'name', 'description', 'technical')
        properties = @{ id = $text; name = $text; description = $text; technical = @{ type = 'boolean' } }
    }
    $element = @{
        type = 'object'; additionalProperties = $false; required = @('id', 'description')
        properties = @{ id = $text; description = $text }
    }
    return @{
        type = 'object'; additionalProperties = $false
        required = @('elements', 'relationships', 'people', 'externalSystems', 'links')
        properties = @{
            elements        = @{ type = 'array'; items = $element }
            relationships   = @{ type = 'array'; items = $relation }
            people          = @{ type = 'array'; items = $actor }
            externalSystems = @{ type = 'array'; items = $actor }
            links           = @{ type = 'array'; items = $relation }
        }
    }
}

function New-CatalogueSchema {
    $entry = @{
        type = 'object'; additionalProperties = $false; required = @('id', 'sameAs')
        properties = @{ id = @{ type = 'string' }; sameAs = @{ type = 'string' } }
    }
    return @{ type = 'object'; additionalProperties = $false; required = @('actors'); properties = @{ actors = @{ type = 'array'; items = $entry } } }
}

function New-ReviewSchema {
    $text = @{ type = 'string' }
    $quote = @{
        type = 'object'; additionalProperties = $false; required = @('path', 'quote')
        properties = @{ path = $text; quote = $text }
    }
    $system = @{
        type = 'object'; additionalProperties = $false; required = @('id', 'inProduction', 'evidence', 'reason')
        properties = @{ id = $text; inProduction = @{ type = 'boolean' }; evidence = @{ type = 'array'; items = $quote }; reason = $text }
    }
    $link = @{
        type = 'object'; additionalProperties = $false; required = @('source', 'target', 'keep', 'reason')
        properties = @{ source = $text; target = $text; keep = @{ type = 'boolean' }; reason = $text }
    }
    $container = @{
        type = 'object'; additionalProperties = $false; required = @('id', 'name', 'sameAs', 'reason')
        properties = @{ id = $text; name = $text; sameAs = $text; reason = $text }
    }
    return @{
        type = 'object'; additionalProperties = $false; required = @('externalSystems', 'links', 'containers')
        properties = @{
            externalSystems = @{ type = 'array'; items = $system }
            links           = @{ type = 'array'; items = $link }
            containers      = @{ type = 'array'; items = $container }
        }
    }
}

function Get-TextPath {
    return Join-Path $GeneratedDirectory $TextFileName
}

function New-EmptyReview {
    return [pscustomobject][ordered]@{ basis = ''; externalSystems = [pscustomobject]@{}; containers = [pscustomobject]@{} }
}

function New-EmptyText {
    return [pscustomobject]@{ units = [pscustomobject]@{}; people = [pscustomobject]@{}; externalSystems = [pscustomobject]@{}; catalogueReviewed = $false; review = New-EmptyReview }
}

function ConvertFrom-TextJson([string]$Json) {
    $text = $Json | ConvertFrom-Json -ErrorAction Stop
    foreach ($part in @('units') + $ActorParts) {
        if (-not $text.$part) { $text | Add-Member -Force -NotePropertyName $part -NotePropertyValue ([pscustomobject]@{}) }
    }
    if ($null -eq $text.catalogueReviewed) { $text | Add-Member -Force -NotePropertyName catalogueReviewed -NotePropertyValue $false }
    if (-not $text.review) { $text | Add-Member -Force -NotePropertyName review -NotePropertyValue (New-EmptyReview) }
    foreach ($part in 'externalSystems', 'containers') {
        if (-not $text.review.$part) { $text.review | Add-Member -Force -NotePropertyName $part -NotePropertyValue ([pscustomobject]@{}) }
    }
    return $text
}

function Read-SavedText {
    $path = Get-TextPath
    if (-not (Test-Path $path -PathType Leaf)) { return New-EmptyText }
    return ConvertFrom-TextJson (Get-Content -Raw $path)
}

function Save-Text($Text) {
    New-Item -ItemType Directory -Force -Path $GeneratedDirectory | Out-Null
    $path = Join-Path (Resolve-Path $GeneratedDirectory).Path $TextFileName
    [IO.File]::WriteAllText($path, ($Text | ConvertTo-Json -Depth 20) + "`n")
}

function Get-Catalogue($Text) {
    $catalogue = @{}
    foreach ($part in $ActorParts) { $Text.$part.PSObject.Properties | ForEach-Object { $catalogue[$_.Name] = $_.Value } }
    return $catalogue
}

function Get-ActorPart($Text, [string]$Id) {
    return $ActorParts | Where-Object { $Text.$_.PSObject.Properties[$Id] } | Select-Object -First 1
}

function Add-Correction([string]$Line) {
    if (-not $script:Corrections.Contains($Line)) { $script:Corrections.Add($Line) }
}

function Get-GitAuthorization {
    if ($env:SYSTEM_ACCESSTOKEN) { return @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") }
    return @()
}

# GENERATED_DIRECTORY e' relativa alla cartella di lavoro, dentro il checkout della documentazione.
function Get-RepositoryTextPath {
    $prefix = "$(git rev-parse --show-prefix 2>$null)".Trim()
    return ($prefix + ((Get-TextPath) -replace '\\', '/' -replace '^\./', ''))
}

# Il ramo di avanzamento porta il testo gia' accettato da una pipeline fallita: si riparte da li'.
function Read-ProgressText {
    if (-not $ProgressBranch) { return $null }
    $authorization = Get-GitAuthorization
    $found = git @authorization ls-remote origin "refs/heads/$ProgressBranch" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not "$found".Trim()) { $global:LASTEXITCODE = 0; return $null }
    $out = git @authorization fetch -q origin "+refs/heads/${ProgressBranch}:refs/remotes/origin/$ProgressBranch" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ramo $ProgressBranch non letto: $out" }
    $json = git show "refs/remotes/origin/${ProgressBranch}:$(Get-RepositoryTextPath)" 2>$null
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $null }
    return ConvertFrom-TextJson ($json -join "`n")
}

function New-Progress {
    return @{ Worktree = $null }
}

function Remove-Progress($Progress) {
    if (-not $Progress.Worktree) { return }
    git worktree remove --force $Progress.Worktree 2>&1 | Out-Null
    $global:LASTEXITCODE = 0
}

function Publish-Progress($Progress, [string]$Label) {
    if (-not $ProgressBranch) { return }
    $authorization = Get-GitAuthorization
    if (-not $Progress.Worktree) {
        $worktree = Join-Path ([IO.Path]::GetTempPath()) "c4-text-$(New-Guid)"
        $start = if (git rev-parse -q --verify "refs/remotes/origin/$ProgressBranch" 2>$null) { "refs/remotes/origin/$ProgressBranch" } else { 'HEAD' }
        $out = git worktree add -q --detach $worktree $start 2>&1
        if ($LASTEXITCODE -ne 0) { throw "copia del ramo $ProgressBranch non creata: $out" }
        $Progress.Worktree = $worktree
    }
    $relative = Get-RepositoryTextPath
    $target = Join-Path $Progress.Worktree $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item (Get-TextPath) $target -Force
    $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Documentation' }
    $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'documentation@noreply.local' }
    git -C $Progress.Worktree add -- $relative
    $out = git -C $Progress.Worktree -c "user.name=$name" -c "user.email=$email" commit -q --allow-empty -m "docs: text of $Label in the C4 model" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "commit del testo non riuscito: $out" }
    $out = git -C $Progress.Worktree @authorization push -q origin "HEAD:refs/heads/$ProgressBranch" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "push sul ramo $ProgressBranch non riuscito: $out" }
    Write-Host "Ramo $ProgressBranch aggiornato con il testo di $Label"
}

function Read-Fragments {
    foreach ($repository in $SourceRepositories) {
        $pattern = '^' + [regex]::Escape($repository.ToLowerInvariant()) + '\.[^.]+\.json$'
        Get-ChildItem -Path $FragmentDirectory -File -ErrorAction SilentlyContinue | Where-Object Name -Match $pattern | Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ Repository = $repository; Content = Get-Content -Raw $_.FullName | ConvertFrom-Json } }
    }
}

function Get-RelationshipKey($Relationship) {
    return "$($Relationship.source) -> $($Relationship.target)"
}

function Get-ElementIds($Container) {
    return @($Container.id) + @($Container.components | Where-Object { $_ } | ForEach-Object id)
}

# Una relazione appartiene al container da cui parte. Una relazione che parte da un elemento che nessun
# container letto contiene la descrive il container a cui arriva: altrimenti resterebbe senza cio' che passa.
function Get-Units($Fragments) {
    $relationships = @($Fragments | ForEach-Object { @($_.Content.relationships) } | Where-Object { $_ }) +
        @(Get-C4CallRelationships @(Resolve-C4Calls @($Fragments.Content)))
    $containers = @(foreach ($fragment in $Fragments) {
            @($fragment.Content.containers) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Repository = $fragment.Repository; Container = $_ } }
        })
    $systemIds = @($containers | ForEach-Object { Get-ElementIds $_.Container })
    foreach ($entry in $containers) {
        $ids = Get-ElementIds $entry.Container
        $own = @($relationships | Where-Object { $ids -contains $_.source -or ($ids -contains $_.target -and $systemIds -notcontains $_.source) })
        [pscustomobject]@{
            Id            = $entry.Container.id
            Repository    = $entry.Repository
            Container     = $entry.Container
            ElementIds    = $ids
            Relationships = $own
            Basis         = Get-Basis $entry.Container $own
        }
    }
}

function Get-Basis($Container, $Relationships) {
    $json = [ordered]@{ container = $Container; relationships = @($Relationships) } | ConvertTo-Json -Depth 20 -Compress
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-SourceRoot($Unit) {
    $directory = Join-Path $SourcesDirectory $Unit.Repository
    if (-not (Test-Path $directory -PathType Container)) { return $null }
    return (Resolve-Path $directory).Path
}

function Get-SourceFilesOf($Unit) {
    $root = Get-SourceRoot $Unit
    if (-not $root) { return }
    $elements = @($Unit.Container.components | Where-Object { $_ }) + @($Unit.Container)
    $seen = @{}
    foreach ($directory in @($elements | ForEach-Object { @($_.sources) } | Where-Object { $_ })) {
        $path = Join-Path $root $directory
        if (-not (Test-Path $path -PathType Container)) { continue }
        Get-ChildItem -Path $path -Recurse -File |
            Where-Object { $SourceExtensions -contains $_.Extension -and $_.Name -notmatch $TestFilePattern } |
            Where-Object { -not ($_.FullName.Substring($root.Length) -split '[\\/]' | Where-Object { $IgnoredDirectories -contains $_ }) } |
            Sort-Object FullName |
            Where-Object { -not $seen.ContainsKey($_.FullName) } |
            ForEach-Object { $seen[$_.FullName] = $true; $_ }
    }
}

function Format-Files($Files, [int]$Budget, [scriptblock]$GetName) {
    $parts = [Collections.Generic.List[string]]::new()
    $left = @()
    foreach ($file in $Files) {
        $content = "$(Get-Content -Raw $file.FullName)"
        if ($Budget -lt $content.Length) { $left += & $GetName $file; continue }
        $Budget -= $content.Length
        $parts.Add("=== $(& $GetName $file) ===`n$content")
    }
    if ($left) { $parts.Add("File non riportati per lunghezza: $($left -join ', ')") }
    return $parts -join "`n"
}

function Get-ContextFiles {
    foreach ($path in $ContextPaths) {
        if (Test-Path $path -PathType Container) { Get-ChildItem -Path $path -Recurse -File -Filter '*.md' | Sort-Object FullName }
        elseif (Test-Path $path -PathType Leaf) { Get-Item $path }
    }
}

function Format-Catalogue([hashtable]$Catalogue) {
    if (-not $Catalogue.Count) { return '(vuoto)' }
    return ($Catalogue.Keys | Sort-Object | ForEach-Object { "- $_ = $($Catalogue[$_].name): $($Catalogue[$_].description)" }) -join "`n"
}

function Format-List([string[]]$Lines) {
    if (-not $Lines) { return '(nessuno)' }
    return ($Lines | ForEach-Object { "- $_" }) -join "`n"
}

function Format-Containers($Units) {
    return Format-List @($Units | ForEach-Object { "$($_.Id) = $($_.Container.name) ($($_.Repository))" })
}

function Get-UnitStructure($Unit) {
    $structure = [ordered]@{ container = $Unit.Container; relationships = @($Unit.Relationships | ForEach-Object { [ordered]@{ source = $_.source; target = $_.target } }) }
    return $structure | ConvertTo-Json -Depth 20
}

function Get-UserMessage($Unit, $Units, [hashtable]$Catalogue, $Previous, [string[]]$Rejections) {
    $previousText = if ($Previous) { $Previous | ConvertTo-Json -Depth 20 } else { '(nessuno)' }
    $root = Get-SourceRoot $Unit
    $code = if ($root) { Format-Files @(Get-SourceFilesOf $Unit) $MaxSourceCharacters { param($f) [IO.Path]::GetRelativePath($root, $f.FullName) -replace '\\', '/' } } else { '' }
    $context = Format-Files @(Get-ContextFiles) $MaxContextCharacters { param($f) (Resolve-Path -Relative $f.FullName) -replace '\\', '/' }
    $message = @(
        "LINGUA DEL DOCUMENTO: $($DocumentLanguage.TextLanguage)"
        "REPOSITORY: $($Unit.Repository)"
        "PARTE DA DESCRIVERE: $($Unit.Id)"
        "STRUTTURA DELLA PARTE (JSON):`n$(Get-UnitStructure $Unit)"
        "ALTRI CONTAINER DEL SISTEMA:`n$(Format-Containers @($Units | Where-Object Id -NE $Unit.Id))"
        "REPOSITORY SORGENTE DEL SISTEMA:`n$(Format-List $SourceRepositories)"
        "CATALOGO DI PERSONE E SISTEMI ESTERNI:`n$(Format-Catalogue $Catalogue)"
        "TESTO ACCETTATO PRIMA CHE LA STRUTTURA CAMBIASSE:`n$previousText"
    )
    if ($Rejections) { $message += "STESURA PRECEDENTE RESPINTA, VOCI DA RISCRIVERE:`n$(Format-List $Rejections)" }
    $message += "CODICE DELLA PARTE:`n$code"
    $message += "DOCUMENTI DI CONTESTO:`n$context"
    return $message -join "`n`n"
}

function Get-SystemMessage {
    $guide = if ($GuidePath -and (Test-Path $GuidePath -PathType Leaf)) { Get-Content -Raw $GuidePath } else { '' }
    return "$Instructions`nGUIDA DI STILE:`n$guide"
}

function Get-AccessToken {
    if ($env:C4_TEXT_TOKEN) { return $env:C4_TEXT_TOKEN }
    $token = az account get-access-token --resource 'https://cognitiveservices.azure.com' --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "token Entra ID non ottenuto: $token" }
    return $token
}

function Invoke-Writer([string]$System, [string]$User, [hashtable]$Schema = (New-TextSchema), [string]$SchemaName = 'c4_model_text') {
    if (-not $script:Token) { $script:Token = Get-AccessToken }
    $body = [ordered]@{
        model            = $Model
        reasoning_effort = $ReasoningEffort
        messages         = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $User })
        response_format  = @{ type = 'json_schema'; json_schema = @{ name = $SchemaName; strict = $true; schema = $Schema } }
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

function Test-Readable([string]$Text, [string]$Where) {
    if ($MaximumWords -le 0) { return }
    Get-Sentences $Text $Abbreviations | Where-Object { (Get-WordCount $_) -gt $MaximumWords } |
        ForEach-Object { "frase di $Where oltre $MaximumWords parole: $_" }
}

function Get-TextRejections([string]$Text, [string]$Where, [string]$Missing) {
    if (-not "$Text".Trim()) { return $Missing }
    Test-Readable $Text $Where
}

function Get-ItemRejections([string]$Collection, [string]$Key, $Value) {
    switch ($Collection) {
        'Elements' { Get-TextRejections $Value $Key "elemento senza descrizione: $Key" }
        { $_ -in 'Relationships', 'Links' } { Get-TextRejections $Value.description $Key "relazione senza cio' che passa: $Key" }
        default {
            if (-not "$($Value.name)".Trim()) { "persona o sistema esterno senza nome: $Key" }
            Get-TextRejections $Value.description $Key "persona o sistema esterno senza descrizione: $Key"
        }
    }
}

# La stesura si tiene per chiave: le voci gia' accettate restano quando il modello riscrive le altre.
function ConvertTo-Draft($Answer) {
    $draft = [ordered]@{ Elements = [ordered]@{}; Relationships = [ordered]@{}; People = [ordered]@{}; ExternalSystems = [ordered]@{}; Links = [ordered]@{} }
    foreach ($element in @($Answer.elements | Where-Object { $_ })) { if (-not $draft.Elements.Contains("$($element.id)")) { $draft.Elements["$($element.id)"] = "$($element.description)" } }
    foreach ($pair in @(@('relationships', 'Relationships'), @('links', 'Links'))) {
        foreach ($relation in @($Answer.($pair[0]) | Where-Object { $_ })) {
            $key = Get-RelationshipKey $relation
            if (-not $draft[$pair[1]].Contains($key)) { $draft[$pair[1]][$key] = $relation }
        }
    }
    foreach ($pair in @(@('people', 'People'), @('externalSystems', 'ExternalSystems'))) {
        foreach ($actor in @($Answer.($pair[0]) | Where-Object { $_ })) { if (-not $draft[$pair[1]].Contains("$($actor.id)")) { $draft[$pair[1]]["$($actor.id)"] = $actor } }
    }
    return $draft
}

function Merge-Drafts($Kept, $New) {
    $merged = [ordered]@{}
    foreach ($collection in @($Kept.Keys)) {
        $items = [ordered]@{}
        foreach ($key in $Kept[$collection].Keys) {
            $keep = -not @(Get-ItemRejections $collection $key $Kept[$collection][$key]) -or -not $New[$collection].Contains($key)
            $items[$key] = if ($keep) { $Kept[$collection][$key] } else { $New[$collection][$key] }
        }
        foreach ($key in $New[$collection].Keys) { if (-not $items.Contains($key)) { $items[$key] = $New[$collection][$key] } }
        $merged[$collection] = $items
    }
    return $merged
}

function Get-DraftActorIds($Draft) {
    return @($Draft.People.Keys) + @($Draft.ExternalSystems.Keys)
}

function Rename-DraftActor($Draft, [string]$From, [string]$To) {
    $links = [ordered]@{}
    foreach ($link in $Draft.Links.Values) {
        if ($link.source -eq $From) { $link.source = $To }
        if ($link.target -eq $From) { $link.target = $To }
        $key = Get-RelationshipKey $link
        if (-not $links.Contains($key)) { $links[$key] = $link }
    }
    $Draft.Links = $links
}

function Remove-DraftItems($Items, [string[]]$Keys) {
    @($Keys) | Where-Object { $_ } | ForEach-Object { $Items.Remove($_) }
}

# Cio' che la struttura non contiene si toglie senza chiedere al modello: la run non si ferma.
function Repair-Draft($Unit, $Draft, [hashtable]$Catalogue, [string[]]$GeneratedIds) {
    $extraElements = @($Draft.Elements.Keys | Where-Object { $Unit.ElementIds -notcontains $_ })
    Remove-DraftItems $Draft.Elements $extraElements
    $extraElements | ForEach-Object { "elemento che la struttura non contiene: $_" }

    $expected = @($Unit.Relationships | ForEach-Object { Get-RelationshipKey $_ })
    $extraRelationships = @($Draft.Relationships.Keys | Where-Object { $expected -notcontains $_ })
    Remove-DraftItems $Draft.Relationships $extraRelationships
    $extraRelationships | ForEach-Object { "relazione che il codice non dichiara: $_" }

    foreach ($part in 'People', 'ExternalSystems') {
        foreach ($id in @($Draft[$part].Keys)) {
            $actor = $Draft[$part][$id]
            $normal = if ($id -match $IdentifierPattern) { $id } else { ConvertTo-Identifier $id }
            if ($GeneratedIds -contains $normal -or $normal -notmatch $IdentifierPattern) {
                $Draft[$part].Remove($id)
                "persona o sistema esterno con l'identificativo di un elemento del codice o non valido: $id"
                continue
            }
            if ($normal -ne $id) { $Draft[$part].Remove($id); $actor.id = $normal; $Draft[$part][$normal] = $actor; Rename-DraftActor $Draft $id $normal }
        }
    }

    $actors = @($Catalogue.Keys) + @(Get-DraftActorIds $Draft)
    $unbound = @($Draft.Links.Keys | Where-Object {
            $link = $Draft.Links[$_]
            -not (($Unit.ElementIds -contains $link.source -and $actors -contains $link.target) -or ($actors -contains $link.source -and $Unit.ElementIds -contains $link.target))
        })
    Remove-DraftItems $Draft.Links $unbound
    $unbound | ForEach-Object { "relazione che non lega una persona o un sistema esterno a un elemento della parte: $_" }

    $linked = @($Draft.Links.Values | ForEach-Object { $_.source; $_.target })
    foreach ($part in 'People', 'ExternalSystems') {
        $unlinked = @($Draft[$part].Keys | Where-Object { $linked -notcontains $_ })
        Remove-DraftItems $Draft[$part] $unlinked
        $unlinked | ForEach-Object { "persona o sistema esterno senza relazioni: $_" }
    }
}

function Get-PendingRejections($Unit, $Draft) {
    foreach ($id in $Unit.ElementIds) {
        if ($Draft.Elements.Contains($id)) { Get-ItemRejections 'Elements' $id $Draft.Elements[$id] } else { "elemento senza descrizione: $id" }
    }
    foreach ($key in @($Unit.Relationships | ForEach-Object { Get-RelationshipKey $_ })) {
        if ($Draft.Relationships.Contains($key)) { Get-ItemRejections 'Relationships' $key $Draft.Relationships[$key] } else { "relazione senza cio' che passa: $key" }
    }
    foreach ($collection in 'People', 'ExternalSystems', 'Links') {
        foreach ($key in $Draft[$collection].Keys) { Get-ItemRejections $collection $key $Draft[$collection][$key] }
    }
}

function Get-ActorKey([string]$Name) {
    return ($Name -replace '\s+', ' ').Trim().ToLowerInvariant()
}

# Una persona o un sistema esterno che il catalogo ha gia', per identificativo o per nome, non si
# dichiara di nuovo: la stesura lo collega con l'identificativo del catalogo.
function Merge-CatalogueActors($Answer, [hashtable]$Catalogue) {
    $catalogueIds = @{}
    $Catalogue.GetEnumerator() | ForEach-Object { $catalogueIds[$_.Key] = $_.Key; $catalogueIds[(Get-ActorKey $_.Value.name)] = $_.Key }
    foreach ($part in $ActorParts) {
        $kept = foreach ($actor in @($Answer.$part | Where-Object { $_ })) {
            $known = if ($Catalogue.ContainsKey($actor.id)) { $actor.id } else { $catalogueIds[(Get-ActorKey $actor.name)] }
            if (-not $known) { $actor; continue }
            foreach ($link in @($Answer.links | Where-Object { $_ })) {
                if ($link.source -eq $actor.id) { $link.source = $known }
                if ($link.target -eq $actor.id) { $link.target = $known }
            }
        }
        $Answer.$part = @($kept)
    }
}

function Test-SourceRepositoryName([string]$Name) {
    $key = Get-ActorKey $Name
    return [bool]($SourceRepositories | Where-Object { (Get-ActorKey $_) -eq $key })
}

function Test-KeptLink($Link, [string[]]$Dropped) {
    return $Link -and $Dropped -notcontains $Link.source -and $Dropped -notcontains $Link.target
}

# Un'applicazione di un repository sorgente dichiarata come sistema esterno comparirebbe due volte nel
# modello: la dichiarazione e le sue relazioni si tolgono senza chiedere al modello.
function Remove-SourceRepositoryDraftSystems($Answer) {
    $dropped = @($Answer.externalSystems | Where-Object { $_ -and (Test-SourceRepositoryName $_.name) } | ForEach-Object id)
    if (-not $dropped) { return }
    $Answer.externalSystems = @($Answer.externalSystems | Where-Object { $_ -and $dropped -notcontains $_.id })
    $Answer.links = @($Answer.links | Where-Object { Test-KeptLink $_ $dropped })
    $dropped | ForEach-Object { "sistema esterno con il nome di un repository sorgente: $_" }
}

function Remove-SourceRepositorySystems($Text) {
    $dropped = @($Text.externalSystems.PSObject.Properties | Where-Object { Test-SourceRepositoryName $_.Value.name } | ForEach-Object Name)
    Remove-TextActors $Text $dropped
}

function Remove-TextActors($Text, [string[]]$Ids) {
    if (-not $Ids) { return }
    foreach ($part in $ActorParts) { $Ids | ForEach-Object { $Text.$part.PSObject.Properties.Remove($_) } }
    foreach ($unit in @($Text.units.PSObject.Properties.Value | Where-Object { $_ })) {
        $unit.links = @($unit.links | Where-Object { Test-KeptLink $_ $Ids })
    }
}

function ConvertTo-UnitText($Unit, $Draft, [string]$Basis) {
    $elements = [ordered]@{}
    $Draft.Elements.Keys | Sort-Object | ForEach-Object { $elements[$_] = "$($Draft.Elements[$_])".Trim() }
    $relationships = [ordered]@{}
    $Draft.Relationships.Keys | Sort-Object | ForEach-Object {
        $relationships[$_] = [ordered]@{ description = "$($Draft.Relationships[$_].description)".Trim(); technology = "$($Draft.Relationships[$_].technology)".Trim() }
    }
    $links = @($Draft.Links.Keys | Sort-Object | ForEach-Object {
            $link = $Draft.Links[$_]
            [ordered]@{ source = $link.source; target = $link.target; description = "$($link.description)".Trim(); technology = "$($link.technology)".Trim() }
        })
    return [pscustomobject][ordered]@{ basis = $Basis; elements = $elements; relationships = $relationships; links = $links }
}

function Add-Actors($Text, $Draft) {
    foreach ($pair in @(@('People', 'people'), @('ExternalSystems', 'externalSystems'))) {
        foreach ($actor in $Draft[$pair[0]].Values) {
            $Text.($pair[1]) | Add-Member -Force -NotePropertyName $actor.id -NotePropertyValue ([pscustomobject][ordered]@{
                    name = "$($actor.name)".Trim(); description = "$($actor.description)".Trim(); technical = [bool]$actor.technical
                })
        }
    }
}

function Rename-LinkedActor($Text, [string]$From, [string]$To) {
    foreach ($unit in @($Text.units.PSObject.Properties.Value | Where-Object { $_ })) {
        foreach ($link in @($unit.links | Where-Object { $_ })) {
            if ($link.source -eq $From) { $link.source = $To }
            if ($link.target -eq $From) { $link.target = $To }
        }
        $seen = @{}
        $unit.links = @($unit.links | Where-Object { $_ } | Where-Object { $key = Get-RelationshipKey $_; $new = -not $seen.ContainsKey($key); $seen[$key] = $true; $new })
    }
}

# Un container che non c'e' piu' perde il testo; una persona o un sistema esterno resta finche' una
# relazione lo usa.
function Remove-StaleText($Text, $Units) {
    $ids = @($Units | ForEach-Object Id)
    @($Text.units.PSObject.Properties | ForEach-Object Name) | Where-Object { $ids -notcontains $_ } | ForEach-Object { $Text.units.PSObject.Properties.Remove($_) }
    $linked = @($Text.units.PSObject.Properties.Value | ForEach-Object { @($_.links) } | ForEach-Object { $_.source; $_.target })
    foreach ($part in $ActorParts) {
        @($Text.$part.PSObject.Properties | ForEach-Object Name) | Where-Object { $linked -notcontains $_ } | ForEach-Object { $Text.$part.PSObject.Properties.Remove($_) }
    }
}

function Write-UnitText($Unit, $Units, $Text, [string[]]$GeneratedIds, $Progress) {
    $catalogue = Get-Catalogue $Text
    $previous = $Text.units.($Unit.Id)
    $kept = $null
    $rejections = @()
    for ($round = 1; $round -le $MaxDrafts; $round++) {
        $answer = Invoke-Writer (Get-SystemMessage) (Get-UserMessage $Unit $Units $catalogue $previous $rejections)
        Remove-SourceRepositoryDraftSystems $answer | ForEach-Object { Add-Correction "$($Unit.Id): $_" }
        Merge-CatalogueActors $answer $catalogue
        $draft = ConvertTo-Draft $answer
        if ($kept) { $draft = Merge-Drafts $kept $draft }
        Repair-Draft $Unit $draft $catalogue $GeneratedIds | ForEach-Object { Add-Correction "$($Unit.Id): $_" }
        $rejections = @(Get-PendingRejections $Unit $draft)
        $kept = $draft
        if (-not $rejections) { break }
        Write-Host "Stesura $round di $($Unit.Id), voci da riscrivere: $($rejections -join '; ')"
    }
    $rejections | ForEach-Object { Add-Correction "$($Unit.Id): testo ancora da scrivere dopo $MaxDrafts stesure: $_" }
    $basis = if ($rejections) { '' } else { $Unit.Basis }
    $Text.units | Add-Member -Force -NotePropertyName $Unit.Id -NotePropertyValue (ConvertTo-UnitText $Unit $kept $basis)
    Add-Actors $Text $kept
    $Text.catalogueReviewed = $false
    Save-Text $Text
    Publish-Progress $Progress $Unit.Id
    Write-Host "Testo di $($Unit.Id) scritto in $round stesure"
}

function Get-PendingUnits($Units, $Text) {
    return @($Units | Where-Object { $Text.units.($_.Id).basis -ne $_.Basis })
}

function Get-CatalogueMessage($Units, $Text, [string[]]$Rejections) {
    $catalogue = foreach ($part in $ActorParts) {
        $kind = if ($part -eq 'people') { 'persona' } else { 'sistema esterno' }
        $Text.$part.PSObject.Properties | ForEach-Object { "$($_.Name) [$kind] = $($_.Value.name): $($_.Value.description)" }
    }
    $links = @($Text.units.PSObject.Properties.Value | ForEach-Object { @($_.links) } | Where-Object { $_ } | ForEach-Object { "$(Get-RelationshipKey $_): $($_.description)" })
    $message = @(
        "LINGUA DEL DOCUMENTO: $($DocumentLanguage.TextLanguage)"
        "CONTAINER DEL SISTEMA:`n$(Format-Containers $Units)"
        "CATALOGO DA CONTROLLARE:`n$(Format-List @($catalogue))"
        "RELAZIONI DEL CATALOGO CON IL SISTEMA:`n$(Format-List $links)"
    )
    if ($Rejections) { $message += "RISPOSTA PRECEDENTE RESPINTA, VOCI DA RISCRIVERE:`n$(Format-List $Rejections)" }
    return $message -join "`n`n"
}

function Get-CatalogueRejections([hashtable]$Answers, $Text, $Units) {
    $containerIds = @($Units | ForEach-Object Id)
    foreach ($id in @((Get-Catalogue $Text).Keys)) {
        $sameAs = $Answers[$id]
        $reason = if ($null -eq $sameAs) { "voce del catalogo senza risposta: $id" }
        elseif (-not $sameAs) { $null }
        elseif ($sameAs -eq $id) { "voce unita a se stessa: $id" }
        elseif ($containerIds -contains $sameAs) { if ((Get-ActorPart $Text $id) -ne 'externalSystems') { "persona indicata come container: $id -> $sameAs" } }
        elseif (-not (Get-ActorPart $Text $sameAs)) { "voce unita a un identificativo sconosciuto: $id -> $sameAs" }
        elseif ((Get-ActorPart $Text $sameAs) -ne (Get-ActorPart $Text $id)) { "persona e sistema esterno uniti: $id -> $sameAs" }
        elseif ($Answers[$sameAs]) { "voce unita a una voce che non resta: $id -> $sameAs" }
        if ($reason) { [pscustomobject]@{ Id = $id; Reason = $reason } }
    }
}

function Merge-CatalogueAnswers([hashtable]$Answers, $Answer, [string[]]$Ids, [string[]]$Pending) {
    $new = @{}
    foreach ($entry in @($Answer.actors | Where-Object { $_ })) {
        if ($Ids -contains $entry.id -and -not $new.ContainsKey($entry.id)) { $new[$entry.id] = "$($entry.sameAs)".Trim() }
    }
    foreach ($id in $Ids) {
        if ((-not $Answers.ContainsKey($id) -or $Pending -contains $id) -and $new.ContainsKey($id)) { $Answers[$id] = $new[$id] }
    }
}

function Set-CatalogueAnswers([hashtable]$Answers, $Text, $Units) {
    $containerIds = @($Units | ForEach-Object Id)
    foreach ($id in @($Answers.Keys | Where-Object { $Answers[$_] })) {
        $sameAs = $Answers[$id]
        if ($containerIds -contains $sameAs) {
            Remove-TextActors $Text @($id)
            Add-Correction "catalogo: sistema esterno $id tolto, e' il container $sameAs"
            continue
        }
        Rename-LinkedActor $Text $id $sameAs
        Remove-TextActors $Text @($id)
        Add-Correction "catalogo: $id unito a $sameAs"
    }
}

# Il catalogo si scrive un container alla volta: solo vedendo insieme tutti i container il modello
# riconosce due voci che indicano la stessa persona o un sistema esterno che e' un container del sistema.
function Invoke-CatalogueReview($Units, $Text, $Progress) {
    $ids = @((Get-Catalogue $Text).Keys | Sort-Object)
    if ($ids) {
        $answers = @{}
        $pending = @()
        $rejected = @()
        for ($round = 1; $round -le $MaxDrafts; $round++) {
            $answer = Invoke-Writer $CatalogueInstructions (Get-CatalogueMessage $Units $Text @($rejected | ForEach-Object Reason)) (New-CatalogueSchema) 'c4_model_catalogue'
            Merge-CatalogueAnswers $answers $answer $ids $pending
            $rejected = @(Get-CatalogueRejections $answers $Text $Units)
            if (-not $rejected) { break }
            $pending = @($rejected | ForEach-Object Id)
            Write-Host "Controllo $round del catalogo, voci da riscrivere: $(($rejected | ForEach-Object Reason) -join '; ')"
        }
        $rejected | ForEach-Object { $answers[$_.Id] = ''; Add-Correction "catalogo: voce tenuta distinta dopo $MaxDrafts controlli: $($_.Reason)" }
        Set-CatalogueAnswers $answers $Text $Units
    }
    $Text.catalogueReviewed = $true
    Save-Text $Text
    if ($ids) { Publish-Progress $Progress 'catalogue' }
}

#region Revisione del modello

function Get-SourcesRoot {
    if (-not (Test-Path $SourcesDirectory -PathType Container)) { return $null }
    return (Resolve-Path $SourcesDirectory).Path
}

function Get-EvidenceName([string]$Root, [string]$Path) {
    return [IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/'
}

function Get-EvidenceFiles {
    $root = Get-SourcesRoot
    if (-not $root) { return }
    $seen = @{}
    foreach ($path in $EvidencePaths) {
        $items = @(Get-ChildItem -Path (Join-Path $root $path) -ErrorAction SilentlyContinue)
        $files = @($items | Where-Object { -not $_.PSIsContainer }) + @($items | Where-Object PSIsContainer | ForEach-Object { Get-ChildItem -Path $_.FullName -Recurse -File })
        $files | Sort-Object FullName | Where-Object { -not $seen.ContainsKey($_.FullName) } | ForEach-Object { $seen[$_.FullName] = $true; $_ }
    }
}

# La revisione si ripete quando cambia la struttura di un container o la configurazione di produzione:
# le sue decisioni tolgono voci dal testo, quindi la base non conta il testo.
function Get-ReviewBasis($Units, $EvidenceFiles) {
    $root = Get-SourcesRoot
    $parts = @($ReviewInstructions) + @($Units | Sort-Object Id | ForEach-Object { "$($_.Id) $($_.Basis)" }) +
        @($EvidenceFiles | ForEach-Object { "$(Get-EvidenceName $root $_.FullName)`n$(Get-Content -Raw $_.FullName)" })
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($parts -join "`n`n"))
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-ContainerOf($Units, [string]$ElementId) {
    return $Units | Where-Object { $_.ElementIds -contains $ElementId } | Select-Object -First 1
}

function Get-TextLinks($Text) {
    return @($Text.units.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { @($_.Value.links) } | Where-Object { $_ })
}

function Get-ExternalLinkElements($Text) {
    $systems = @($Text.externalSystems.PSObject.Properties | ForEach-Object Name)
    return @(Get-TextLinks $Text | ForEach-Object {
            if ($systems -contains $_.target) { $_.source }
            if ($systems -contains $_.source) { $_.target }
        } | Sort-Object -Unique)
}

function Get-ElementSourceFiles($Unit, [string]$ElementId) {
    $root = Get-SourceRoot $Unit
    if (-not $root) { return }
    $element = @($Unit.Container) + @($Unit.Container.components | Where-Object { $_ }) | Where-Object id -EQ $ElementId | Select-Object -First 1
    foreach ($directory in @($element.sources | Where-Object { $_ })) {
        $path = Join-Path $root $directory
        if (-not (Test-Path $path -PathType Container)) { continue }
        Get-ChildItem -Path $path -Recurse -File |
            Where-Object { $SourceExtensions -contains $_.Extension -and $_.Name -notmatch $TestFilePattern } |
            Where-Object { -not ($_.FullName.Substring($root.Length) -split '[\\/]' | Where-Object { $IgnoredDirectories -contains $_ }) } |
            Sort-Object FullName
    }
}

function Format-ReviewContainers($Units, $Text) {
    return Format-List @($Units | ForEach-Object {
            $name = if ($Text.review.containers.($_.Id).name) { $Text.review.containers.($_.Id).name } else { $_.Container.name }
            $components = @($_.Container.components | Where-Object { $_ }).Count
            $kind = if (Test-Application $_) { 'applicazione' } else { 'risorsa' }
            "$($_.Id) = $name [$($_.Container.technology)] ($kind di $($_.Repository), nome nel codice $(Get-CodeName $_), $components componenti): $($Text.units.($_.Id).elements.($_.Id))"
        })
}

function Format-ContainerRelations($Units, $Text) {
    $seen = @{}
    return Format-List @(foreach ($unit in $Units) {
            foreach ($relationship in $unit.Relationships) {
                $source = Get-ContainerOf $Units $relationship.source
                $target = Get-ContainerOf $Units $relationship.target
                if (-not $source -or -not $target -or $source.Id -eq $target.Id) { continue }
                $key = "$($source.Id) -> $($target.Id)"
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                "${key}: $($Text.units.($unit.Id).relationships.(Get-RelationshipKey $relationship).description)"
            }
        })
}

function Get-ReviewMessage($Units, $Text, $EvidenceFiles, [string[]]$Rejections) {
    $root = Get-SourcesRoot
    $catalogue = foreach ($part in $ActorParts) {
        $kind = if ($part -eq 'people') { 'persona' } else { 'sistema esterno' }
        $Text.$part.PSObject.Properties | ForEach-Object { "$($_.Name) [$kind] = $($_.Value.name): $($_.Value.description)" }
    }
    $links = @(Get-TextLinks $Text | ForEach-Object { "$(Get-RelationshipKey $_): $($_.description)" })
    $evidence = if ($root) { Format-Files @($EvidenceFiles) $MaxContextCharacters { param($f) Get-EvidenceName $root $f.FullName } } else { '' }
    $code = Format-Files @(foreach ($id in (Get-ExternalLinkElements $Text)) {
            $unit = Get-ContainerOf $Units $id
            if ($unit) { Get-ElementSourceFiles $unit $id }
        }) $MaxSourceCharacters { param($f) Get-EvidenceName $root $f.FullName }
    $message = @(
        "LINGUA DEL DOCUMENTO: $($DocumentLanguage.TextLanguage)"
        "CONTAINER DEL SISTEMA:`n$(Format-ReviewContainers $Units $Text)"
        "RELAZIONI FRA I CONTAINER:`n$(Format-ContainerRelations $Units $Text)"
        "PERSONE E SISTEMI ESTERNI:`n$(Format-List @($catalogue))"
        "RELAZIONI CON PERSONE E SISTEMI ESTERNI:`n$(Format-List $links)"
    )
    if ($Rejections) { $message += "RISPOSTA PRECEDENTE RESPINTA, VOCI DA RISCRIVERE:`n$(Format-List $Rejections)" }
    $message += "CONFIGURAZIONE DI PRODUZIONE:`n$(if ($evidence) { $evidence } else { '(nessuna)' })"
    $message += "CODICE DEGLI ELEMENTI LEGATI A SISTEMI ESTERNI:`n$code"
    return $message -join "`n`n"
}

function Get-NormalText([string]$Text) {
    return ($Text -replace '\s+', ' ').Trim()
}

# Una prova vale se cita un file della configurazione di produzione e un tratto che vi compare.
function Test-Evidence($Evidence, [hashtable]$EvidenceTexts) {
    $quote = Get-NormalText $Evidence.quote
    $path = "$($Evidence.path)".Trim() -replace '\\', '/'
    return $quote -and $EvidenceTexts.ContainsKey($path) -and $EvidenceTexts[$path].Contains($quote)
}

function Get-SystemRejection($Entry, [hashtable]$EvidenceTexts) {
    if (-not $Entry.inProduction) { return $null }
    $proven = @($Entry.evidence | Where-Object { $_ -and (Test-Evidence $_ $EvidenceTexts) })
    if (-not $proven) { return "sistema esterno in produzione senza una prova che compaia nella configurazione di produzione: $($Entry.id)" }
    return $null
}

function Get-ContainerRejection($Entry, $Units, [hashtable]$Decided) {
    $unit = $Units | Where-Object Id -EQ $Entry.id | Select-Object -First 1
    $sameAs = "$($Entry.sameAs)".Trim()
    if (-not $sameAs) { return $null }
    $target = $Units | Where-Object Id -EQ $sameAs | Select-Object -First 1
    if ($sameAs -eq $Entry.id) { return "container unito a se stesso: $($Entry.id)" }
    if (-not $target) { return "container unito a un identificativo sconosciuto: $($Entry.id) -> $sameAs" }
    if (@($unit.Container.components | Where-Object { $_ }).Count -or @($target.Container.components | Where-Object { $_ }).Count) { return "container con componenti unito a un altro: $($Entry.id) -> $sameAs" }
    if ($target.Container.technology -ne $unit.Container.technology) { return "container unito a uno di un'altra tecnologia: $($Entry.id) -> $sameAs" }
    if ($Decided.ContainsKey($sameAs) -and $Decided[$sameAs].sameAs) { return "container unito a uno che non resta: $($Entry.id) -> $sameAs" }
    return $null
}

function Test-Application($Unit) {
    return @($Unit.Container.tags) -contains $DocumentLanguage.ApplicationTag
}

function Get-CodeName($Unit) {
    if ($Unit.Container.codeName) { return "$($Unit.Container.codeName)" }
    return "$($Unit.Container.name)"
}

function Get-NameKey([string]$Name) {
    return ($Name.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]', '')
}

# Il nome di un'applicazione la distingue nel sistema solo se contiene la parte del nome nel codice che
# resta togliendo il prefisso comune a tutte le applicazioni: il lettore di un repository toglie solo il
# prefisso comune ai suoi progetti, e due repository possono avere un'applicazione Web ciascuno.
function Get-NameRejection($Entry, $Units) {
    $unit = $Units | Where-Object Id -EQ $Entry.id | Select-Object -First 1
    $name = "$($Entry.name)"
    if (-not $unit -or -not $name) { return $null }
    if (-not (Test-Application $unit)) {
        if ((Get-NameKey $name) -eq (Get-NameKey (Get-CodeName $unit))) { return "risorsa chiamata con il suo nome tecnico invece che con cio' che fa: $($Entry.id) = $name" }
        return $null
    }
    $applications = @($Units | Where-Object { Test-Application $_ } | ForEach-Object { Get-CodeName $_ })
    if ($applications.Count -lt 2) { return $null }
    $distinctive = Remove-CommonPrefix (Get-CodeName $unit) $applications
    if (-not $distinctive -or (Get-NameKey $name).Contains((Get-NameKey $distinctive))) { return $null }
    return "nome di applicazione che non la distingue nel sistema: $($Entry.id) = $name, dal codice $(Get-CodeName $unit) deve contenere $distinctive"
}

# Senza una risposta valida un'applicazione si chiama con la parte del nome nel codice che la distingue
# nel sistema, una risorsa con il nome del lettore.
function Get-DefaultName($Unit, $Units) {
    $applications = @($Units | Where-Object { Test-Application $_ } | ForEach-Object { Get-CodeName $_ })
    if (-not (Test-Application $Unit) -or $applications.Count -lt 2) { return $Unit.Container.name }
    return Remove-CommonPrefix (Get-CodeName $Unit) $applications
}

function Get-FinalName($Units, [hashtable]$Decided, [string]$Id) {
    if ($Decided.ContainsKey($Id) -and $Decided[$Id].name) { return $Decided[$Id].name }
    return ($Units | Where-Object Id -EQ $Id | Select-Object -First 1).Container.name
}

function Get-DuplicateNameRejections($Units, [hashtable]$Decided) {
    $kept = @($Units | Where-Object { -not ($Decided.ContainsKey($_.Id) -and $Decided[$_.Id].sameAs) })
    $kept | Group-Object { (Get-FinalName $Units $Decided $_.Id).ToLowerInvariant() } | Where-Object Count -GT 1 | ForEach-Object {
        foreach ($unit in $_.Group) { [pscustomobject]@{ Key = "container:$($unit.Id)"; Reason = "nome di container non unico: $($unit.Id) = $(Get-FinalName $Units $Decided $unit.Id)" } }
    }
}

function Merge-ReviewAnswer($Answer, $State, $Units, [hashtable]$EvidenceTexts) {
    $rejections = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Answer.externalSystems | Where-Object { $_ })) {
        $key = "system:$($entry.id)"
        if (-not $State.Expected.Contains($key) -or ($State.Decided.ContainsKey($key) -and -not $State.Pending.Contains($key))) { continue }
        $reason = Get-SystemRejection $entry $EvidenceTexts
        if ($reason) { $rejections.Add([pscustomobject]@{ Key = $key; Reason = $reason }) } else { $State.Decided[$key] = $entry }
    }
    foreach ($entry in @($Answer.links | Where-Object { $_ })) {
        $key = "link:$(Get-RelationshipKey $entry)"
        if (-not $State.Expected.Contains($key) -or ($State.Decided.ContainsKey($key) -and -not $State.Pending.Contains($key))) { continue }
        $State.Decided[$key] = $entry
    }
    foreach ($entry in @($Answer.containers | Where-Object { $_ })) {
        $key = "container:$($entry.id)"
        if (-not $State.Expected.Contains($key) -or ($State.Decided.ContainsKey($key) -and -not $State.Pending.Contains($key))) { continue }
        $entry.name = "$($entry.name)".Trim()
        $State.Decided[$key] = $entry
    }
    $containers = @{}
    $State.Decided.Keys | Where-Object { $_ -like 'container:*' } | ForEach-Object { $containers[$_.Substring(10)] = $State.Decided[$_] }
    foreach ($id in @($containers.Keys)) {
        $reason = Get-ContainerRejection $containers[$id] $Units $containers
        if (-not $reason) { $reason = Get-NameRejection $containers[$id] $Units }
        if ($reason) { $rejections.Add([pscustomobject]@{ Key = "container:$id"; Reason = $reason }) }
    }
    Get-DuplicateNameRejections $Units $containers | ForEach-Object { $rejections.Add($_) }
    foreach ($key in $State.Expected) {
        if (-not $State.Decided.ContainsKey($key) -and -not ($rejections | Where-Object Key -EQ $key)) {
            $rejections.Add([pscustomobject]@{ Key = $key; Reason = "voce senza risposta: $($key -replace '^[a-z]+:', '')" })
        }
    }
    $rejections | ForEach-Object { [void]$State.Decided.Remove($_.Key) }
    return @($rejections)
}

function New-ReviewState($Units, $Text) {
    $expected = [Collections.Generic.HashSet[string]]::new()
    $Text.externalSystems.PSObject.Properties | ForEach-Object { [void]$expected.Add("system:$($_.Name)") }
    Get-TextLinks $Text | ForEach-Object { [void]$expected.Add("link:$(Get-RelationshipKey $_)") }
    $Units | ForEach-Object { [void]$expected.Add("container:$($_.Id)") }
    return @{ Expected = $expected; Decided = @{}; Pending = [Collections.Generic.HashSet[string]]::new() }
}

# Una voce che resta senza risposta valida dopo l'ultimo giro: un sistema esterno senza prova esce dal
# modello, una relazione resta, un container prende il nome di default e non si unisce.
function Set-ReviewDecisions($State, $Units, $Text) {
    foreach ($key in $State.Expected) {
        if ($State.Decided.ContainsKey($key)) { continue }
        Add-Correction "revisione: voce lasciata com'era dopo $MaxDrafts giri: $($key -replace '^[a-z]+:', '')"
    }
    $systems = [ordered]@{}
    $dropped = @(foreach ($property in @($Text.externalSystems.PSObject.Properties)) {
            $decision = $State.Decided["system:$($property.Name)"]
            if ($decision -and $decision.inProduction) {
                $systems[$property.Name] = [ordered]@{ inProduction = $true; evidence = @($decision.evidence | Where-Object { $_ }); reason = "$($decision.reason)" }
                continue
            }
            $reason = if ($decision) { $decision.reason } else { 'nessuna prova nella configurazione di produzione' }
            Add-Correction "revisione: sistema esterno $($property.Name) tolto, non e' in produzione: $reason"
            $property.Name
        })
    Remove-TextActors $Text $dropped
    foreach ($unit in @($Text.units.PSObject.Properties.Value | Where-Object { $_ })) {
        $unit.links = @($unit.links | Where-Object { $_ } | Where-Object {
                $decision = $State.Decided["link:$(Get-RelationshipKey $_)"]
                $keep = -not $decision -or $decision.keep
                if (-not $keep) { Add-Correction "revisione: relazione $(Get-RelationshipKey $_) tolta: $($decision.reason)" }
                $keep
            })
    }
    $containers = [ordered]@{}
    foreach ($unit in ($Units | Sort-Object Id)) {
        $decision = $State.Decided["container:$($unit.Id)"]
        $name = if ($decision -and $decision.name) { $decision.name } else { Get-DefaultName $unit $Units }
        $sameAs = if ($decision) { "$($decision.sameAs)".Trim() } else { '' }
        if ($sameAs) { Add-Correction "revisione: container $($unit.Id) unito a ${sameAs}: $($decision.reason)" }
        $containers[$unit.Id] = [ordered]@{ name = $name; sameAs = $sameAs }
    }
    return [ordered]@{ externalSystems = $systems; containers = $containers }
}

function Invoke-ModelReview($Units, $Text, $Progress) {
    $evidenceFiles = @(Get-EvidenceFiles)
    $basis = Get-ReviewBasis $Units $evidenceFiles
    if ($Text.review.basis -eq $basis) { return }
    $root = Get-SourcesRoot
    $evidenceTexts = @{}
    $evidenceFiles | ForEach-Object { $evidenceTexts[(Get-EvidenceName $root $_.FullName)] = Get-NormalText (Get-Content -Raw $_.FullName) }
    $state = New-ReviewState $Units $Text
    $rejections = @()
    for ($round = 1; $round -le $MaxDrafts; $round++) {
        $answer = Invoke-Writer $ReviewInstructions (Get-ReviewMessage $Units $Text $evidenceFiles @($rejections | ForEach-Object Reason)) (New-ReviewSchema) 'c4_model_review'
        $rejections = @(Merge-ReviewAnswer $answer $state $Units $evidenceTexts)
        if (-not $rejections) { break }
        $state.Pending = [Collections.Generic.HashSet[string]]::new([string[]]@($rejections | ForEach-Object Key))
        Write-Host "Revisione $round del modello, voci da riscrivere: $(($rejections | ForEach-Object Reason) -join '; ')"
    }
    $decisions = Set-ReviewDecisions $state $Units $Text
    Remove-StaleText $Text $Units
    $Text.review = [pscustomobject][ordered]@{ basis = $basis; externalSystems = [pscustomobject]$decisions.externalSystems; containers = [pscustomobject]$decisions.containers }
    Save-Text $Text
    Publish-Progress $Progress 'review'
}

#endregion

function Write-Corrections {
    if (-not $script:Corrections.Count) { return }
    $script:Corrections | ForEach-Object { Write-Host "##vso[task.logissue type=warning]Modello C4: $_" }
    if (-not $CorrectionsFile) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent ([IO.Path]::GetFullPath($CorrectionsFile, (Get-Location).Path))) | Out-Null
    $lines = @('Correzioni della generazione del modello C4:') + @($script:Corrections | ForEach-Object { "- $_" })
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($CorrectionsFile, (Get-Location).Path), ($lines -join "`n") + "`n")
}

function Get-TextIssues {
    if (-not $SourceRepositories) { return New-Issue $TextScope 'repository sorgente non dichiarati' 'SOURCE_REPOSITORIES' }
    if (-not $Endpoint -or -not $Model) { return New-Issue $TextScope 'testo non scritto' 'endpoint o modello non configurati' }

    $units = @(Get-Units @(Read-Fragments))
    if (-not $units) { return New-Issue $TextScope 'nessun container da descrivere' $FragmentDirectory }
    $generatedIds = @($units | ForEach-Object { $_.ElementIds })
    $text = Read-ProgressText
    if (-not $text) { $text = Read-SavedText }
    Remove-SourceRepositorySystems $text
    Remove-StaleText $text $units
    Save-Text $text

    $script:Usage = @{ Requests = 0; Input = 0; Output = 0 }
    $script:Corrections = [Collections.Generic.List[string]]::new()
    $progress = New-Progress
    try {
        foreach ($unit in (Get-PendingUnits $units $text)) {
            try { Write-UnitText $unit $units $text $generatedIds $progress }
            catch { return New-Issue $TextScope "testo di $($unit.Id) non scritto" $_.Exception.Message }
        }
        if (-not $text.catalogueReviewed) {
            try { Invoke-CatalogueReview $units $text $progress }
            catch { return New-Issue $TextScope 'catalogo di persone e sistemi esterni non controllato' $_.Exception.Message }
        }
        try { Invoke-ModelReview $units $text $progress }
        catch { return New-Issue $TextScope 'modello non rivisto' $_.Exception.Message }
    }
    finally {
        Remove-Progress $progress
        Write-Corrections
        Write-Host "Modello $Model (ragionamento $ReasoningEffort): $($script:Usage.Requests) richieste, $($script:Usage.Input) token in ingresso, $($script:Usage.Output) in uscita"
    }
}

Invoke-Verification { Get-TextIssues } 'Testo del modello C4 scritto e verificato' 'Testo del modello C4 disattivato'
