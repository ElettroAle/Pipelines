# SPDX-License-Identifier: Apache-2.0

# Parte del modello C4 che nasce da un repository sorgente, in Structurizr DSL da includere nel
# sistema del documento: un file per repository in GENERATED_DIRECTORY, che si legge e non si scrive
# a mano. Unisce i frammenti che i lettori delle tecnologie hanno scritto in FRAGMENT_DIRECTORY
# (contratto in C4CodeModel.ps1) e non conosce le tecnologie: un file manifest del repository che
# nessun frammento ha letto ferma la generazione. I container del repository stanno in un gruppo con
# il nome del repository senza il prefisso comune ai repository sorgente (SOURCE_REPOSITORIES).
# Il testo che Write-C4ModelText.ps1 ha scritto per il repository (<repository>.text.json) da' le
# descrizioni degli elementi, cio' che passa sulle relazioni e le relazioni con persone e sistemi
# esterni; context.dsl dichiara le persone e i sistemi esterni dei testi di tutti i repository, da
# includere nel modello prima del sistema.
# GENERATION_MODE=check confronta il file del repository con quello che la generazione produce.

. "$PSScriptRoot/Common/VerificationGate.ps1"
. "$PSScriptRoot/Common/DocumentLanguage.ps1"
. "$PSScriptRoot/Common/C4CodeModel.ps1"

$SourceRepositories = @("$env:SOURCE_REPOSITORIES" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$GeneratedDirectory = if ($env:GENERATED_DIRECTORY) { $env:GENERATED_DIRECTORY } else { 'docs/architecture/model/generated' }
$Mode = if ($env:GENERATION_MODE) { $env:GENERATION_MODE.ToLower() } else { 'write' }
$GeneratedTag = $DocumentLanguage.GeneratedTag
$TechnicalTag = $DocumentLanguage.TechnicalTag
$ExternalTag = $DocumentLanguage.ExternalTag
$ContextFileName = 'context.dsl'
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

function Read-TextFile($File) {
    try { return Get-Content -Raw $File.FullName | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
}

function Read-ModelTexts {
    foreach ($file in (Get-ChildItem -Path $GeneratedDirectory -Filter '*.text.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        [pscustomobject]@{ File = $file.Name; Content = Read-TextFile $file }
    }
}

function Get-TextIssues($Texts) {
    $Texts | Where-Object { -not $_.Content } | ForEach-Object { New-Issue $Repository 'testo del modello non leggibile' $_.File }
    $Texts | Where-Object Content | ForEach-Object { @($_.Content.people.PSObject.Properties.Name) + @($_.Content.externalSystems.PSObject.Properties.Name) } |
        Where-Object { $_ } | Group-Object | Where-Object Count -GT 1 |
        ForEach-Object { New-Issue $Repository 'persona o sistema esterno dichiarato da piu'' repository' $_.Name }
}

function Get-OwnText($Texts) {
    $own = $Texts | Where-Object File -EQ "$($Repository.ToLowerInvariant()).text.json" | Select-Object -First 1
    $text = @{ Elements = @{}; Relationships = @{}; Links = @() }
    foreach ($unit in @($own.Content.units.PSObject.Properties.Value | Where-Object { $_ })) {
        $unit.elements.PSObject.Properties | ForEach-Object { $text.Elements[$_.Name] = $_.Value }
        $unit.relationships.PSObject.Properties | ForEach-Object { $text.Relationships[$_.Name] = $_.Value }
        $text.Links += @($unit.links | Where-Object { $_ })
    }
    return $text
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
    $Fragments.Content.relationships | ForEach-Object {
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

function Format-Context($Texts) {
    $lines = @("// Persone e sistemi esterni del modello C4, dai testi scritti con Write-C4ModelText.ps1: non si modifica a mano.")
    $contents = @($Texts | Where-Object Content | ForEach-Object Content)
    $contents | ForEach-Object { $_.people.PSObject.Properties } | Sort-Object Name | ForEach-Object { $lines += Format-Actor $_.Name $_.Value 'person' @() }
    $contents | ForEach-Object { $_.externalSystems.PSObject.Properties } | Sort-Object Name | ForEach-Object { $lines += Format-Actor $_.Name $_.Value 'softwareSystem' @($ExternalTag) }
    return ($lines -join "`n") + "`n"
}

function Get-CheckIssues([System.Collections.IDictionary]$Outputs) {
    foreach ($name in $Outputs.Keys) {
        $target = Join-Path $GeneratedDirectory $name
        $current = Get-Item $target -ErrorAction SilentlyContinue | ForEach-Object { (Get-Content -Raw $_.FullName) -replace "`r`n", "`n" }
        if ($Outputs[$name] -ne $current) { New-Issue $Repository 'parte generata diversa da quella che il codice produce' ($target -replace '\\', '/') }
    }
}

function Write-Model([System.Collections.IDictionary]$Outputs) {
    New-Item -ItemType Directory -Force -Path $GeneratedDirectory | Out-Null
    $directory = (Resolve-Path $GeneratedDirectory).Path
    foreach ($name in $Outputs.Keys) { [IO.File]::WriteAllText((Join-Path $directory $name), $Outputs[$name]) }
}

$ModeActions = @{
    check = { param($Outputs) Get-CheckIssues $Outputs }
    write = { param($Outputs) Write-Model $Outputs }
}

function Get-GenerationIssues {
    $sourceIssues = @(Get-SourceIssues)
    if ($sourceIssues) { return $sourceIssues }

    $fragments = @(Read-Fragments)
    $texts = @(Read-ModelTexts)
    $issues = @(Get-FragmentIssues $fragments) + @(Get-UnreadManifestIssues $fragments) + @(Get-TextIssues $texts)
    if ($issues) { return $issues }
    if (-not @($fragments.Content.containers).Count) { return New-Issue $Repository 'nessuna applicazione riconosciuta' $SourceDirectory }

    $script:ModelText = Get-OwnText $texts
    $outputs = [ordered]@{ "$($Repository.ToLowerInvariant()).dsl" = Format-Model $fragments; $ContextFileName = Format-Context $texts }
    & $ModeActions[$Mode] $outputs
}

Invoke-Verification { Get-GenerationIssues } "Parte del modello C4 di $Repository allineata al codice" 'Generazione del modello C4 disattivata'
