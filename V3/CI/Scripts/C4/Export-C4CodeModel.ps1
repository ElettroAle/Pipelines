# SPDX-License-Identifier: Apache-2.0

# Parte del modello C4 che nasce da un repository sorgente, in Structurizr DSL da includere nel
# sistema del documento: un file per repository in GENERATED_DIRECTORY/model, che si legge e non si
# scrive a mano. Unisce i frammenti che i lettori delle tecnologie hanno scritto in FRAGMENT_DIRECTORY
# (contratto in C4CodeModel.ps1) e non conosce le tecnologie: un file manifest del repository che
# nessun frammento ha letto ferma la generazione. I container del repository stanno in un gruppo con
# il nome del repository senza il prefisso comune ai repository sorgente (SOURCE_REPOSITORIES).
# Il testo che Write-C4ModelText.ps1 ha scritto per tutto il sistema (model.text.json) da' le
# descrizioni degli elementi, cio' che passa sulle relazioni e le relazioni con persone e sistemi
# esterni. Persone e sistemi esterni stanno in context.dsl, da includere nel modello prima del sistema:
# il testo e' uno solo, quindi ogni repository scrive lo stesso contesto.
# Un indirizzo che un container del repository chiama in locale si lega con i frammenti di tutto il
# sistema: se non vi si avvia nessun container, o piu' d'uno, la generazione si ferma.
# Le viste dei componenti dei container della parte stanno in GENERATED_DIRECTORY/views/<repository>.dsl:
# una per container con componenti, con l'identificativo del container come chiave. Le parti e le viste
# stanno in due cartelle perche' il workspace le include come cartelle, senza elencare i repository.
# GENERATION_MODE=check confronta i file del repository con quelli che la generazione produce. Un file
# che il repository non ha ancora non si confronta: lo segnala l'!include del workspace che lo usa, e
# cosi' un file nuovo della generazione non ferma le PR delle parti generate prima di lui.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/DocumentLanguage.ps1"
. "$PSScriptRoot/C4CodeModel.ps1"

$SourceRepositories = @("$env:SOURCE_REPOSITORIES" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$GeneratedDirectory = if ($env:GENERATED_DIRECTORY) { $env:GENERATED_DIRECTORY } else { 'docs/architecture/model/generated' }
$Mode = if ($env:GENERATION_MODE) { $env:GENERATION_MODE.ToLower() } else { 'write' }
$GeneratedTag = $DocumentLanguage.GeneratedTag
$TechnicalTag = $DocumentLanguage.TechnicalTag
$ExternalTag = $DocumentLanguage.ExternalTag
$TextFileName = 'model.text.json'
$CodeNameProperty = $DocumentLanguage.CodeNameProperty
$Manifests = @('*.csproj', '*.fsproj', '*.vbproj', '*.sqlproj', '*.esproj', '*.njsproj', '*.shproj', 'package.json', 'angular.json',
    'pom.xml', 'build.gradle', 'go.mod', 'pyproject.toml', 'Cargo.toml', '*.tf')

function Read-Fragments {
    $pattern = '^' + [regex]::Escape($Repository.ToLowerInvariant()) + '\.[^.]+\.json$'
    foreach ($file in (Get-ChildItem -Path $FragmentDirectory -File -ErrorAction SilentlyContinue | Where-Object Name -Match $pattern | Sort-Object Name)) {
        try { [pscustomobject]@{ File = $file.Name; Content = Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop } }
        catch { [pscustomobject]@{ File = $file.Name; Content = $null } }
    }
}

function Get-FragmentIssues($Fragments) {
    $Fragments | Where-Object { -not $_.Content } | ForEach-Object { New-Issue $Repository 'frammento del modello non leggibile' $_.File }
}

function Get-UnreadManifestIssues($Fragments) {
    $read = @($Fragments | ForEach-Object { $_.Content.manifests })
    $Manifests | ForEach-Object { Get-SourceFiles $_ } | ForEach-Object { Get-RelativePath $_.FullName } |
        Where-Object { $read -notcontains $_ } |
        ForEach-Object { New-Issue $Repository 'file di progetto che nessun lettore riconosce' $_ }
}

function Get-OwnCalls($Fragments) {
    $ownIds = @($Fragments.Content.containers | Where-Object { $_ } | ForEach-Object id)
    return @(Resolve-C4Calls @(Read-FragmentContents) | Where-Object { $ownIds -contains $_.Call.container })
}

function Get-CallIssues($Calls) {
    foreach ($resolved in $Calls) {
        $detail = "$($resolved.Call.source): $($resolved.Call.address)"
        if (-not $resolved.Targets) { New-Issue $Repository 'indirizzo chiamato a cui nessuna applicazione si avvia' $detail }
        elseif ($resolved.Targets.Count -gt 1) { New-Issue $Repository "indirizzo chiamato a cui si avvia piu' di un'applicazione" "$detail; $($resolved.Targets -join ', ')" }
    }
}

function Read-ModelText {
    $path = Join-Path $GeneratedDirectory $TextFileName
    if (-not (Test-Path $path -PathType Leaf)) { return [pscustomobject]@{ Readable = $true; Content = $null } }
    try { return [pscustomobject]@{ Readable = $true; Content = Get-Content -Raw $path | ConvertFrom-Json -ErrorAction Stop } }
    catch { return [pscustomobject]@{ Readable = $false; Content = $null } }
}

function Get-TextIssues($Text) {
    if (-not $Text.Readable) { New-Issue $Repository 'testo del modello non leggibile' $TextFileName }
}

# Una relazione la descrive il container da cui parte, che puo' stare in un altro repository: il testo
# delle relazioni si cerca in tutto il sistema, le relazioni con persone e sistemi esterni solo nei
# container di questo repository.
function Get-PartText($Text, $Fragments) {
    $ownIds = @($Fragments.Content.containers | Where-Object { $_ } | ForEach-Object id)
    $part = @{ Elements = @{}; Relationships = @{}; Links = @(); People = $Text.Content.people; ExternalSystems = $Text.Content.externalSystems }
    foreach ($unit in @($Text.Content.units.PSObject.Properties | Where-Object { $_.Value })) {
        $unit.Value.elements.PSObject.Properties | ForEach-Object { $part.Elements[$_.Name] = $_.Value }
        $unit.Value.relationships.PSObject.Properties | ForEach-Object { $part.Relationships[$_.Name] = $_.Value }
        if ($ownIds -contains $unit.Name) { $part.Links += @($unit.Value.links | Where-Object { $_ }) }
    }
    return $part
}

function Format-Text([string]$Text) {
    return '"' + (($Text -replace '\s+', ' ').Trim() -replace '"', '\"') + '"'
}

function Format-Properties($Element, [string]$Indent) {
    $values = @([pscustomobject]@{ Name = $CodeNameProperty; Value = $Element.codeName }) + @($Element.properties.PSObject.Properties | Where-Object Value)
    return @("${Indent}properties {") + @($values | ForEach-Object { "$Indent    $(Format-Text $_.Name) $(Format-Text $_.Value)" }) + "${Indent}}"
}

function Format-Container($Container, [string]$Indent) {
    $tags = @($Container.tags) + $GeneratedTag
    $lines = @("$Indent$($Container.id) = container $(Format-Text $Container.name) $(Format-Text $script:ModelText.Elements[$Container.id]) $(Format-Text $Container.technology) $(Format-Text ($tags -join ',')) {")
    $lines += Format-Properties $Container "$Indent    "
    foreach ($component in $Container.components) {
        $lines += "$Indent    $($component.id) = component $(Format-Text $component.name) $(Format-Text $script:ModelText.Elements[$component.id]) $(Format-Text $component.technology) $(Format-Text $GeneratedTag) {"
        $lines += Format-Properties $component "$Indent        "
        $lines += "$Indent    }"
    }
    return $lines + "$Indent}"
}

function Format-Group($Containers) {
    $group = Remove-CommonPrefix $Repository @($SourceRepositories + $Repository | Select-Object -Unique)
    return @("group $(Format-Text $group) {") + @($Containers | ForEach-Object { Format-Container $_ '    ' }) + '}'
}

function Format-Containers($Containers) {
    if ($Containers.Count -gt 1) { return Format-Group $Containers }
    return Format-Container $Containers[0] ''
}

function Format-Model($Fragments) {
    $lines = @("// Parte del modello C4 generata da $Repository con Export-C4CodeModel.ps1: non si modifica a mano.")
    $lines += Format-Containers @($Fragments.Content.containers)
    @($Fragments.Content.relationships) + $script:CallRelationships | Where-Object { $_ } | ForEach-Object {
        $described = $script:ModelText.Relationships["$($_.source) -> $($_.target)"]
        $lines += "$($_.source) -> $($_.target) $(Format-Text $described.description) $(Format-Text $described.technology) $(Format-Text $GeneratedTag)"
    }
    $script:ModelText.Links | ForEach-Object { $lines += "$($_.source) -> $($_.target) $(Format-Text $_.description) $(Format-Text $_.technology)" }
    return ($lines -join "`n") + "`n"
}

function Format-Actor([string]$Id, $Actor, [string]$Kind, [string[]]$Tags) {
    $allTags = @($Tags) + @(if ($Actor.technical) { $TechnicalTag })
    return "$Id = $Kind $(Format-Text $Actor.name) $(Format-Text $Actor.description) $(Format-Text ($allTags -join ','))"
}

function Format-Context {
    $lines = @("// Persone e sistemi esterni del modello C4, dal testo di tutto il sistema: non si modifica a mano.")
    $lines += @($script:ModelText.People.PSObject.Properties | Sort-Object Name | ForEach-Object { Format-Actor $_.Name $_.Value 'person' @() })
    $lines += @($script:ModelText.ExternalSystems.PSObject.Properties | Sort-Object Name | ForEach-Object { Format-Actor $_.Name $_.Value 'softwareSystem' @($ExternalTag) })
    return ($lines -join "`n") + "`n"
}

function Format-Views($Fragments) {
    $lines = @("// Viste dei componenti generate da $Repository con Export-C4CodeModel.ps1: non si modificano a mano.")
    foreach ($container in @($Fragments.Content.containers | Where-Object { @($_.components | Where-Object { $_ }).Count })) {
        $lines += "component $($container.id) $(Format-Text $container.id) {", '    include *', '    autoLayout tb', '}'
    }
    return ($lines -join "`n") + "`n"
}

function Get-CheckIssues([System.Collections.IDictionary]$Outputs) {
    foreach ($name in $Outputs.Keys) {
        $target = Join-Path $GeneratedDirectory $name
        $current = Get-Item $target -ErrorAction SilentlyContinue | ForEach-Object { (Get-Content -Raw $_.FullName) -replace "`r`n", "`n" }
        if ($null -eq $current) { continue }
        if ($Outputs[$name] -ne $current) { New-Issue $Repository 'parte generata diversa da quella che il codice produce' ($target -replace '\\', '/') }
    }
}

function Write-Model([System.Collections.IDictionary]$Outputs) {
    New-Item -ItemType Directory -Force -Path $GeneratedDirectory | Out-Null
    $directory = (Resolve-Path $GeneratedDirectory).Path
    foreach ($name in $Outputs.Keys) {
        $path = Join-Path $directory $name
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [IO.File]::WriteAllText($path, $Outputs[$name])
    }
}

$ModeActions = @{
    check = { param($Outputs) Get-CheckIssues $Outputs }
    write = { param($Outputs) Write-Model $Outputs }
}

function Get-GenerationIssues {
    $sourceIssues = @(Get-SourceIssues)
    if ($sourceIssues) { return $sourceIssues }

    $fragments = @(Read-Fragments)
    $text = Read-ModelText
    $issues = @(Get-FragmentIssues $fragments) + @(Get-UnreadManifestIssues $fragments) + @(Get-TextIssues $text)
    if ($issues) { return $issues }
    $calls = Get-OwnCalls $fragments
    $callIssues = @(Get-CallIssues $calls)
    if ($callIssues) { return $callIssues }
    $script:CallRelationships = Get-C4CallRelationships $calls
    if (-not @($fragments.Content.containers).Count) { return New-Issue $Repository 'nessuna applicazione riconosciuta' $SourceDirectory }

    $script:ModelText = Get-PartText $text $fragments
    $name = $Repository.ToLowerInvariant()
    $outputs = [ordered]@{ "model/$name.dsl" = Format-Model $fragments; "views/$name.dsl" = Format-Views $fragments; 'context.dsl' = Format-Context }
    & $ModeActions[$Mode] $outputs
}

Invoke-Verification { Get-GenerationIssues } "Parte del modello C4 di $Repository allineata al codice" 'Generazione del modello C4 disattivata'
