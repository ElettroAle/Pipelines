# SPDX-License-Identifier: Apache-2.0

# Testo della parte del modello C4 che nasce da un repository sorgente: la descrizione di ogni elemento,
# cio' che passa su ogni relazione, le persone e i sistemi esterni con le loro relazioni. Lo scrive un
# modello Azure OpenAI leggendo i frammenti dei lettori (FRAGMENT_DIRECTORY), il codice degli elementi
# (sources), la guida di stile e i documenti di contesto; Export-C4CodeModel.ps1 lo compone con la
# struttura. Il modello non cambia la struttura: ogni stesura passa controlli deterministici e, se li
# fallisce, torna al modello con i motivi. Si scrive un container alla volta; il testo accettato si
# salva in <repository in minuscolo>.text.json (GENERATED_DIRECTORY) e, con PROGRESS_BRANCH, sul ramo,
# cosi' una pipeline fallita e rilanciata riparte dai container senza testo accettato. Il testo di un
# container la cui struttura non cambia resta quello accettato.

. "$PSScriptRoot/Common/VerificationGate.ps1"
. "$PSScriptRoot/Common/DocumentLanguage.ps1"
. "$PSScriptRoot/Common/MarkdownText.ps1"
. "$PSScriptRoot/Common/C4CodeModel.ps1"

$GeneratedDirectory = if ($env:GENERATED_DIRECTORY) { $env:GENERATED_DIRECTORY } else { 'docs/architecture/model/generated' }
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

$TextScope = "testo del modello C4 di $Repository"
$IdentifierPattern = '^[a-z][a-z0-9_]*$'
$SourceExtensions = @('.cs', '.ts', '.html', '.json', '.csproj', '.tf', '.md', '.yaml', '.yml', '.sql')
$TestFilePattern = '\.(spec|test)\.ts$|Tests?\.cs$'
$MaxAttempts = 3
$RequestTimeoutSeconds = 900

$Instructions = @'
Scrivi il testo di una parte del modello C4 di un'architettura software. La struttura (elementi e
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

Non aggiungere elementi o relazioni fra elementi del codice. Scrivi solo cio' che il codice, le
decisioni e i requisiti mostrano. Il testo segue la guida di stile.
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

function Get-TextPath([string]$Name) {
    return Join-Path $GeneratedDirectory $Name
}

function Get-TextFileName {
    return "$($Repository.ToLowerInvariant()).text.json"
}

function New-EmptyText {
    return [pscustomobject]@{ units = [pscustomobject]@{}; people = [pscustomobject]@{}; externalSystems = [pscustomobject]@{} }
}

function ConvertFrom-TextJson([string]$Json) {
    $text = $Json | ConvertFrom-Json -ErrorAction Stop
    foreach ($part in 'units', 'people', 'externalSystems') {
        if (-not $text.$part) { $text | Add-Member -Force -NotePropertyName $part -NotePropertyValue ([pscustomobject]@{}) }
    }
    return $text
}

function Read-SavedText {
    $path = Get-TextPath (Get-TextFileName)
    if (-not (Test-Path $path -PathType Leaf)) { return New-EmptyText }
    return ConvertFrom-TextJson (Get-Content -Raw $path)
}

function Save-Text($Text) {
    New-Item -ItemType Directory -Force -Path $GeneratedDirectory | Out-Null
    $path = Join-Path (Resolve-Path $GeneratedDirectory).Path (Get-TextFileName)
    [IO.File]::WriteAllText($path, ($Text | ConvertTo-Json -Depth 20) + "`n")
}

# Le persone e i sistemi esterni li dichiara il testo del repository che li ha incontrati per primo;
# gli altri repository li trovano nel catalogo e li collegano senza dichiararli di nuovo.
function Read-Catalogue {
    $catalogue = @{}
    $own = Get-TextFileName
    foreach ($file in (Get-ChildItem -Path $GeneratedDirectory -Filter '*.text.json' -File -ErrorAction SilentlyContinue | Where-Object Name -NE $own)) {
        $text = ConvertFrom-TextJson (Get-Content -Raw $file.FullName)
        foreach ($part in 'people', 'externalSystems') {
            $text.$part.PSObject.Properties | ForEach-Object { $catalogue[$_.Name] = $_.Value }
        }
    }
    return $catalogue
}

function Get-GitAuthorization {
    if ($env:SYSTEM_ACCESSTOKEN) { return @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") }
    return @()
}

# GENERATED_DIRECTORY e' relativa alla cartella di lavoro, dentro il checkout della documentazione.
function Get-RepositoryTextPath {
    $prefix = "$(git rev-parse --show-prefix 2>$null)".Trim()
    return ($prefix + ((Get-TextPath (Get-TextFileName)) -replace '\\', '/' -replace '^\./', ''))
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

function Publish-Progress($Progress, [string]$UnitId) {
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
    Copy-Item (Get-TextPath (Get-TextFileName)) $target -Force
    $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Documentation' }
    $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'documentation@noreply.local' }
    git -C $Progress.Worktree add -- $relative
    $out = git -C $Progress.Worktree -c "user.name=$name" -c "user.email=$email" commit -q --allow-empty -m "docs: text of $UnitId in the C4 model of $Repository" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "commit del testo non riuscito: $out" }
    $out = git -C $Progress.Worktree @authorization push -q origin "HEAD:refs/heads/$ProgressBranch" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "push sul ramo $ProgressBranch non riuscito: $out" }
    Write-Host "Ramo $ProgressBranch aggiornato con il testo di $UnitId"
}

function Read-Fragments {
    $pattern = '^' + [regex]::Escape($Repository.ToLowerInvariant()) + '\.[^.]+\.json$'
    return @(Get-ChildItem -Path $FragmentDirectory -File -ErrorAction SilentlyContinue | Where-Object Name -Match $pattern | Sort-Object Name |
            ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
}

function Get-RelationshipKey($Relationship) {
    return "$($Relationship.source) -> $($Relationship.target)"
}

function Get-Units($Fragments) {
    $relationships = @($Fragments | ForEach-Object { @($_.relationships) } | Where-Object { $_ })
    foreach ($container in @($Fragments | ForEach-Object { @($_.containers) } | Where-Object { $_ })) {
        $ids = @($container.id) + @($container.components | Where-Object { $_ } | ForEach-Object id)
        $own = @($relationships | Where-Object { $ids -contains $_.source })
        [pscustomobject]@{
            Id            = $container.id
            Container     = $container
            ElementIds    = $ids
            Relationships = $own
            Basis         = Get-Basis $container $own
        }
    }
}

function Get-Basis($Container, $Relationships) {
    $json = [ordered]@{ container = $Container; relationships = @($Relationships) } | ConvertTo-Json -Depth 20 -Compress
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-SourceFilesOf($Unit) {
    $root = (Resolve-Path $SourceDirectory).Path
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

function Get-UnitStructure($Unit) {
    $structure = [ordered]@{ container = $Unit.Container; relationships = @($Unit.Relationships | ForEach-Object { [ordered]@{ source = $_.source; target = $_.target } }) }
    return $structure | ConvertTo-Json -Depth 20
}

function Get-UserMessage($Unit, $Units, [hashtable]$Catalogue, $Previous, [string[]]$Rejections) {
    $others = @($Units | Where-Object Id -NE $Unit.Id | ForEach-Object { "- $($_.Id) = $($_.Container.name)" })
    $previousText = if ($Previous) { $Previous | ConvertTo-Json -Depth 20 } else { '(nessuno)' }
    $root = (Resolve-Path $SourceDirectory).Path
    $code = Format-Files @(Get-SourceFilesOf $Unit) $MaxSourceCharacters { param($f) [IO.Path]::GetRelativePath($root, $f.FullName) -replace '\\', '/' }
    $context = Format-Files @(Get-ContextFiles) $MaxContextCharacters { param($f) (Resolve-Path -Relative $f.FullName) -replace '\\', '/' }
    $message = @(
        "LINGUA DEL DOCUMENTO: $($DocumentLanguage.TextLanguage)"
        "REPOSITORY: $Repository"
        "PARTE DA DESCRIVERE: $($Unit.Id)"
        "STRUTTURA DELLA PARTE (JSON):`n$(Get-UnitStructure $Unit)"
        "ALTRI CONTAINER DEL REPOSITORY:`n$(if ($others) { $others -join "`n" } else { '(nessuno)' })"
        "CATALOGO DI PERSONE E SISTEMI ESTERNI:`n$(Format-Catalogue $Catalogue)"
        "TESTO ACCETTATO PRIMA CHE LA STRUTTURA CAMBIASSE:`n$previousText"
    )
    if ($Rejections) { $message += "STESURA PRECEDENTE RESPINTA, DA CORREGGERE:`n$(($Rejections | ForEach-Object { "- $_" }) -join "`n")" }
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

function Invoke-Writer([string]$System, [string]$User) {
    if (-not $script:Token) { $script:Token = Get-AccessToken }
    $body = [ordered]@{
        model            = $Model
        reasoning_effort = $ReasoningEffort
        messages         = @(@{ role = 'system'; content = $System }, @{ role = 'user'; content = $User })
        response_format  = @{ type = 'json_schema'; json_schema = @{ name = 'c4_model_text'; strict = $true; schema = (New-TextSchema) } }
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
            if (-not $transient -or $attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
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

function Test-Described($Items, [string]$Field, [string]$Where) {
    $Items | Where-Object { -not "$($_.$Field)".Trim() } | ForEach-Object { "$Where senza $Field" }
}

function Get-ElementRejections($Unit, $Draft) {
    $written = @($Draft.elements | ForEach-Object id)
    $Unit.ElementIds | Where-Object { $written -notcontains $_ } | ForEach-Object { "elemento senza descrizione: $_" }
    $written | Where-Object { $Unit.ElementIds -notcontains $_ } | ForEach-Object { "elemento che la struttura non contiene: $_" }
    $written | Group-Object | Where-Object Count -GT 1 | ForEach-Object { "elemento descritto piu' volte: $($_.Name)" }
    foreach ($element in $Draft.elements) {
        if (-not "$($element.description)".Trim()) { "elemento senza descrizione: $($element.id)" }
        Test-Readable $element.description $element.id
    }
}

function Get-RelationshipRejections($Unit, $Draft) {
    $expected = @($Unit.Relationships | ForEach-Object { Get-RelationshipKey $_ })
    $written = @($Draft.relationships | ForEach-Object { Get-RelationshipKey $_ })
    $expected | Where-Object { $written -notcontains $_ } | ForEach-Object { "relazione senza cio' che passa: $_" }
    $written | Where-Object { $expected -notcontains $_ } | ForEach-Object { "relazione che il codice non dichiara: $_" }
    $written | Group-Object | Where-Object Count -GT 1 | ForEach-Object { "relazione descritta piu' volte: $($_.Name)" }
    foreach ($relationship in $Draft.relationships) {
        if (-not "$($relationship.description)".Trim()) { "relazione senza cio' che passa: $(Get-RelationshipKey $relationship)" }
        Test-Readable $relationship.description (Get-RelationshipKey $relationship)
    }
}

function Get-ActorRejections($Draft, [hashtable]$Catalogue, [string[]]$GeneratedIds) {
    $actors = @($Draft.people) + @($Draft.externalSystems) | Where-Object { $_ }
    foreach ($actor in $actors) {
        if ($actor.id -notmatch $IdentifierPattern) { "identificativo non valido: $($actor.id)" }
        if ($Catalogue.ContainsKey($actor.id)) { "persona o sistema esterno gia' nel catalogo: $($actor.id)" }
        if ($GeneratedIds -contains $actor.id) { "persona o sistema esterno con l'identificativo di un elemento del codice: $($actor.id)" }
        if (-not "$($actor.name)".Trim()) { "persona o sistema esterno senza nome: $($actor.id)" }
        if (-not "$($actor.description)".Trim()) { "persona o sistema esterno senza descrizione: $($actor.id)" }
        Test-Readable $actor.description $actor.id
    }
    $actors | Group-Object id | Where-Object Count -GT 1 | ForEach-Object { "persona o sistema esterno dichiarato piu' volte: $($_.Name)" }
    $linked = @($Draft.links | ForEach-Object { $_.source; $_.target })
    $actors | Where-Object { $linked -notcontains $_.id } | ForEach-Object { "persona o sistema esterno senza relazioni: $($_.id)" }
}

function Get-LinkRejections($Unit, $Draft, [hashtable]$Catalogue) {
    $actors = @($Catalogue.Keys) + @(@($Draft.people) + @($Draft.externalSystems) | Where-Object { $_ } | ForEach-Object id)
    foreach ($link in $Draft.links) {
        $key = Get-RelationshipKey $link
        $bindsUnit = ($Unit.ElementIds -contains $link.source -and $actors -contains $link.target) -or ($actors -contains $link.source -and $Unit.ElementIds -contains $link.target)
        if (-not $bindsUnit) { "relazione che non lega una persona o un sistema esterno a un elemento della parte: $key" }
        if (-not "$($link.description)".Trim()) { "relazione senza cio' che passa: $key" }
        Test-Readable $link.description $key
    }
    @($Draft.links | ForEach-Object { Get-RelationshipKey $_ }) | Group-Object | Where-Object Count -GT 1 | ForEach-Object { "relazione descritta piu' volte: $($_.Name)" }
}

function Get-DraftRejections($Unit, $Draft, [hashtable]$Catalogue, [string[]]$GeneratedIds) {
    @(Get-ElementRejections $Unit $Draft) + @(Get-RelationshipRejections $Unit $Draft) +
    @(Get-ActorRejections $Draft $Catalogue $GeneratedIds) + @(Get-LinkRejections $Unit $Draft $Catalogue) | Where-Object { $_ }
}

function ConvertTo-UnitText($Unit, $Draft) {
    $elements = [ordered]@{}
    $Draft.elements | Sort-Object id | ForEach-Object { $elements[$_.id] = $_.description.Trim() }
    $relationships = [ordered]@{}
    $Draft.relationships | Sort-Object { Get-RelationshipKey $_ } | ForEach-Object {
        $relationships[(Get-RelationshipKey $_)] = [ordered]@{ description = $_.description.Trim(); technology = "$($_.technology)".Trim() }
    }
    $links = @($Draft.links | Sort-Object { Get-RelationshipKey $_ } | ForEach-Object {
            [ordered]@{ source = $_.source; target = $_.target; description = $_.description.Trim(); technology = "$($_.technology)".Trim() }
        })
    return [pscustomobject][ordered]@{ basis = $Unit.Basis; elements = $elements; relationships = $relationships; links = $links }
}

function Add-Actors($Text, $Draft) {
    foreach ($part in 'people', 'externalSystems') {
        foreach ($actor in @($Draft.$part | Where-Object { $_ })) {
            $Text.$part | Add-Member -Force -NotePropertyName $actor.id -NotePropertyValue ([pscustomobject][ordered]@{
                    name = $actor.name.Trim(); description = $actor.description.Trim(); technical = [bool]$actor.technical
                })
        }
    }
}

# Un container che non c'e' piu' perde il testo; una persona o un sistema esterno dichiarato qui resta
# finche' una relazione di un repository lo usa.
function Remove-StaleText($Text, $Units) {
    $ids = @($Units | ForEach-Object Id)
    $Text.units.PSObject.Properties.Name | Where-Object { $ids -notcontains $_ } | ForEach-Object { $Text.units.PSObject.Properties.Remove($_) }
    $linked = @($Text.units.PSObject.Properties.Value | ForEach-Object { @($_.links) } | ForEach-Object { $_.source; $_.target })
    $linked += @(Get-ChildItem -Path $GeneratedDirectory -Filter '*.text.json' -File -ErrorAction SilentlyContinue | Where-Object Name -NE (Get-TextFileName) |
            ForEach-Object { (ConvertFrom-TextJson (Get-Content -Raw $_.FullName)).units.PSObject.Properties.Value } | ForEach-Object { @($_.links) } | ForEach-Object { $_.source; $_.target })
    foreach ($part in 'people', 'externalSystems') {
        $Text.$part.PSObject.Properties.Name | Where-Object { $linked -notcontains $_ } | ForEach-Object { $Text.$part.PSObject.Properties.Remove($_) }
    }
}

function Write-UnitText($Unit, $Units, $Text, [string[]]$GeneratedIds, $Progress) {
    $catalogue = Read-Catalogue
    @($Text.people.PSObject.Properties) + @($Text.externalSystems.PSObject.Properties) | Where-Object { $_ } | ForEach-Object { $catalogue[$_.Name] = $_.Value }
    $previous = $Text.units.($Unit.Id)
    $rejections = @()
    for ($draft = 1; $draft -le $MaxDrafts; $draft++) {
        $answer = Invoke-Writer (Get-SystemMessage) (Get-UserMessage $Unit $Units $catalogue $previous $rejections)
        $rejections = @(Get-DraftRejections $Unit $answer $catalogue $GeneratedIds)
        if (-not $rejections) {
            $Text.units | Add-Member -Force -NotePropertyName $Unit.Id -NotePropertyValue (ConvertTo-UnitText $Unit $answer)
            Add-Actors $Text $answer
            Save-Text $Text
            Publish-Progress $Progress $Unit.Id
            Write-Host "Testo di $($Unit.Id) accettato alla stesura $draft"
            return
        }
        Write-Host "Stesura $draft di $($Unit.Id) respinta: $($rejections -join '; ')"
    }
    $rejections | ForEach-Object { New-Issue $TextScope "testo di $($Unit.Id) respinto a ogni stesura" $_ }
}

function Get-PendingUnits($Units, $Text) {
    return @($Units | Where-Object { $Text.units.($_.Id).basis -ne $_.Basis })
}

function Get-TextIssues {
    $sourceIssues = @(Get-SourceIssues)
    if ($sourceIssues) { return $sourceIssues }
    if (-not $Endpoint -or -not $Model) { return New-Issue $TextScope 'testo non scritto' 'endpoint o modello non configurati' }

    $units = @(Get-Units (Read-Fragments))
    if (-not $units) { return New-Issue $TextScope 'nessun container da descrivere' $FragmentDirectory }
    $generatedIds = @($units | ForEach-Object { $_.ElementIds })
    $text = Read-ProgressText
    if (-not $text) { $text = Read-SavedText }
    Remove-StaleText $text $units
    Save-Text $text

    $script:Usage = @{ Requests = 0; Input = 0; Output = 0 }
    $progress = New-Progress
    try {
        foreach ($unit in (Get-PendingUnits $units $text)) {
            try { Write-UnitText $unit $units $text $generatedIds $progress }
            catch {
                New-Issue $TextScope "testo di $($unit.Id) non scritto" $_.Exception.Message
                break
            }
        }
    }
    finally {
        Remove-Progress $progress
        Write-Host "Modello $Model (ragionamento $ReasoningEffort): $($script:Usage.Requests) richieste, $($script:Usage.Input) token in ingresso, $($script:Usage.Output) in uscita"
    }
}

Invoke-Verification { Get-TextIssues } "Testo del modello C4 di $Repository scritto e verificato" 'Testo del modello C4 disattivato'
