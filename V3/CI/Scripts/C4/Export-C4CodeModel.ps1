# SPDX-License-Identifier: Apache-2.0

# Parte del modello C4 che nasce da un repository sorgente, in Structurizr DSL da includere nel
# sistema del documento: un file per repository in GENERATED_DIRECTORY/containers, che si legge e non si
# scrive a mano. Unisce i frammenti che i lettori delle tecnologie hanno scritto in FRAGMENT_DIRECTORY
# (contratto in C4CodeModel.ps1) e non conosce le tecnologie: un file manifest del repository che
# nessun frammento ha letto ferma la generazione. I container del repository stanno in un gruppo con
# il nome del repository senza il prefisso comune ai repository sorgente (SOURCE_REPOSITORIES).
# Il testo che Write-C4ModelText.ps1 ha scritto per tutto il sistema (model.text.json) da' le
# descrizioni degli elementi, cio' che passa sulle relazioni e le relazioni con persone e sistemi
# esterni. Persone e sistemi esterni stanno in context.dsl, da includere nel modello prima del sistema:
# il testo e' uno solo, quindi ogni repository scrive lo stesso contesto.
# La revisione del testo da' a ogni risorsa il suo nome e unisce le copie: una copia non si scrive.
# Un indirizzo che un container del repository chiama in locale si lega con i frammenti di tutto il
# sistema: se non vi si avvia nessun container, o piu' d'uno, la generazione si ferma.
# Gli ambienti di deployment della parte stanno in GENERATED_DIRECTORY/deployment/<repository>.dsl, da
# includere nel modello dopo il sistema software, e le loro viste in
# GENERATED_DIRECTORY/deployment-views/<repository>.dsl: per ambiente quella d'insieme, deployment_<ambiente>,
# e una per ogni gruppo del secondo livello che contiene qualcosa, deployment_<ambiente>_<gruppo>, divisa
# nei nodi che contiene se ospita istanze in piu' rami.
# Le viste della parte stanno in GENERATED_DIRECTORY/views/<repository>.dsl. Ogni applicazione ha la vista
# dei container container-<applicazione>, con gli elementi con cui ha relazioni, nel sistema che nel
# workspace accanto a GENERATED_DIRECTORY include i container generati: una vista con tutte le applicazioni
# di un repository somma i loro vicini e non si legge piu' alla scala minima. Un container
# con componenti ha la vista della logica, con l'identificativo del container come chiave, e quella
# dell'accesso ai dati, <container>-<suffisso della lingua>, ciascuna se ha componenti: un componente e' di
# accesso ai dati se un segmento del suo nome e' fra C4_DATA_ACCESS_SEGMENTS (default DataAccess). Le
# parti e le viste stanno in due cartelle perche' il workspace le include come cartelle, senza elencare i
# repository.
# GENERATION_MODE=check confronta i file del repository con quelli che la generazione produce. Un file
# che il repository non ha ancora non si confronta: lo segnala l'!include del workspace che lo usa, e
# cosi' un file nuovo della generazione non ferma le PR delle parti generate prima di lui.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/DocumentLanguage.ps1"
. "$PSScriptRoot/C4CodeModel.ps1"

$SourceRepositories = @("$env:SOURCE_REPOSITORIES" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$GeneratedDirectory = if ($env:GENERATED_DIRECTORY) { $env:GENERATED_DIRECTORY } else { 'docs/architecture/c4/generated' }
$Mode = if ($env:GENERATION_MODE) { $env:GENERATION_MODE.ToLower() } else { 'write' }
$GeneratedTag = $DocumentLanguage.GeneratedTag
$TechnicalTag = $DocumentLanguage.TechnicalTag
$ExternalTag = $DocumentLanguage.ExternalTag
$ApplicationTag = $DocumentLanguage.ApplicationTag
$DataAccessViewSuffix = $DocumentLanguage.DataAccessViewSuffix
$DataAccessSegments = @("$(if ($env:C4_DATA_ACCESS_SEGMENTS) { $env:C4_DATA_ACCESS_SEGMENTS } else { 'DataAccess' })" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$WorkspaceFile = Join-Path (Split-Path -Parent $GeneratedDirectory) 'workspace.dsl'
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

# Un sistema esterno che la revisione non trova in produzione, e una relazione che la revisione toglie,
# restano nel testo ma non entrano nel modello.
function Get-ExcludedSystems($Review) {
    return @($Review.externalSystems.PSObject.Properties | Where-Object { $_.Value -and $_.Value.inProduction -eq $false } | ForEach-Object Name)
}

function Test-ReviewedLink($Link, $Review, [string[]]$Excluded) {
    if ($Excluded -contains $Link.source -or $Excluded -contains $Link.target) { return $false }
    $decision = $Review.links."$($Link.source) -> $($Link.target)"
    return -not ($decision -and $decision.keep -eq $false)
}

function Get-ReviewedSystems($Systems, [string[]]$Excluded) {
    $kept = [pscustomobject]@{}
    $Systems.PSObject.Properties | Where-Object { $Excluded -notcontains $_.Name } | ForEach-Object { $kept | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value }
    return $kept
}

# Una relazione la descrive il container da cui parte, che puo' stare in un altro repository: il testo
# delle relazioni si cerca in tutto il sistema, le relazioni con persone e sistemi esterni solo nei
# container di questo repository.
function Get-PartText($Text, $Fragments) {
    $ownIds = @($Fragments.Content.containers | Where-Object { $_ } | ForEach-Object id)
    $review = $Text.Content.review
    $excluded = Get-ExcludedSystems $review
    $part = @{ Elements = @{}; Relationships = @{}; Links = @(); People = $Text.Content.people; ExternalSystems = Get-ReviewedSystems $Text.Content.externalSystems $excluded; Names = @{}; SameAs = @{} }
    foreach ($unit in @($Text.Content.units.PSObject.Properties | Where-Object { $_.Value })) {
        $unit.Value.elements.PSObject.Properties | ForEach-Object { $part.Elements[$_.Name] = $_.Value }
        $unit.Value.relationships.PSObject.Properties | ForEach-Object { $part.Relationships[$_.Name] = $_.Value }
        if ($ownIds -contains $unit.Name) { $part.Links += @($unit.Value.links | Where-Object { $_ -and (Test-ReviewedLink $_ $review $excluded) }) }
    }
    foreach ($container in @($Text.Content.review.containers.PSObject.Properties | Where-Object { $_.Value })) {
        if ($container.Value.name) { $part.Names[$container.Name] = $container.Value.name }
        if ($container.Value.sameAs) { $part.SameAs[$container.Name] = $container.Value.sameAs }
    }
    return $part
}

# Un container che la revisione ha unito a un altro non si scrive: le sue relazioni passano a quello,
# senza doppioni.
function Get-KeptId([string]$Id) {
    if ($script:ModelText.SameAs.ContainsKey($Id)) { return $script:ModelText.SameAs[$Id] }
    return $Id
}

function Get-KeptContainers($Containers) {
    return @($Containers | Where-Object { $_ -and -not $script:ModelText.SameAs.ContainsKey($_.id) })
}

function Get-ContainerName($Container) {
    if ($script:ApplicationNames.ContainsKey($Container.id)) { return $script:ApplicationNames[$Container.id] }
    if ($script:ModelText.Names.ContainsKey($Container.id)) { return $script:ModelText.Names[$Container.id] }
    return $Container.name
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
    $lines = @("$Indent$($Container.id) = container $(Format-Text (Get-ContainerName $Container)) $(Format-Text $script:ModelText.Elements[$Container.id]) $(Format-Text $Container.technology) $(Format-Text ($tags -join ',')) {")
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
    if (-not $Containers.Count) { return @() }
    if ($Containers.Count -gt 1) { return Format-Group $Containers }
    return Format-Container $Containers[0] ''
}

function New-PartRelationship($Relationship, [string[]]$Texts) {
    $source = Get-KeptId $Relationship.source
    $target = Get-KeptId $Relationship.target
    return [pscustomobject]@{ Source = $source; Target = $target; Line = (@("$source -> $target") + @($Texts | ForEach-Object { Format-Text $_ })) -join ' ' }
}

# Le relazioni della parte, prima quelle del codice e poi quelle con persone e sistemi esterni, una volta sola.
function Get-PartRelationships($Fragments) {
    $declared = @(@($Fragments.Content.relationships) + $script:CallRelationships | Where-Object { $_ } | ForEach-Object {
            $described = $script:ModelText.Relationships["$($_.source) -> $($_.target)"]
            New-PartRelationship $_ @($described.description, $described.technology, $GeneratedTag)
        })
    $linked = @($script:ModelText.Links | Where-Object { $_ } | ForEach-Object { New-PartRelationship $_ @($_.description, $_.technology) })
    $written = @{}
    foreach ($relationship in $declared + $linked) {
        $key = "$($relationship.Source) -> $($relationship.Target)"
        if ($relationship.Source -eq $relationship.Target -or $written.ContainsKey($key)) { continue }
        $written[$key] = $true
        $relationship
    }
}

function Format-Model($Fragments) {
    $lines = @("// Parte del modello C4 generata da $Repository con Export-C4CodeModel.ps1: non si modifica a mano.")
    $lines += Format-Containers (Get-KeptContainers @($Fragments.Content.containers))
    $lines += @($script:PartRelationships | ForEach-Object Line)
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

function Get-Applications($Fragments) {
    return @(Get-KeptContainers @($Fragments.Content.containers) | Where-Object { @($_.tags) -contains $ApplicationTag })
}

# Il sistema del blocco piu' interno che include la cartella containers delle parti generate.
function Get-DocumentSystem {
    if (-not (Test-Path $WorkspaceFile -PathType Leaf)) { return $null }
    $include = '^\s*!include\s+"?' + [regex]::Escape((Split-Path -Leaf $GeneratedDirectory)) + '/containers/?"?\s*$'
    $blocks = [Collections.Generic.List[string]]::new()
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $WorkspaceFile).Path)) {
        if ($line -match $include) { return @($blocks | Where-Object { $_ }) | Select-Object -Last 1 }
        $code = $line -replace '"[^"]*"', '""' -replace '(^|\s)(#|//).*$', ''
        $system = if ($code -match '^\s*(?<id>\w+)\s*=\s*softwareSystem\b') { $Matches.id } else { '' }
        foreach ($character in $code.ToCharArray()) {
            if ($character -eq '{') { $blocks.Add($system); $system = '' }
            elseif ($character -eq '}' -and $blocks.Count) { $blocks.RemoveAt($blocks.Count - 1) }
        }
    }
    return $null
}

function Test-DataAccess($Component) {
    return [bool](@("$($Component.name)" -split '\.') | Where-Object { $DataAccessSegments -contains $_ })
}

# Gli elementi mostrati, poi quelli fuori dal container in relazione con loro e, con WithUsed, anche quelli
# del container che usano.
function Get-ViewElements([string[]]$Shown, [string[]]$Container, [bool]$WithUsed) {
    $related = foreach ($relationship in $script:PartRelationships) {
        if ($Shown -contains $relationship.Source -and ($WithUsed -or $Container -notcontains $relationship.Target)) { $relationship.Target }
        elseif ($Shown -contains $relationship.Target -and $Container -notcontains $relationship.Source) { $relationship.Source }
    }
    return @($Shown) + @($related | Where-Object { $Shown -notcontains $_ } | Sort-Object -Unique)
}

function Format-View([string]$Kind, [string]$Scope, [string]$Key, [string[]]$Elements, [string]$Layout) {
    return "$Kind $Scope $(Format-Text $Key) {", "    include $($Elements -join ' ')", "    autoLayout $Layout", '}'
}

function Format-ComponentViews($Container) {
    $components = @($Container.components | Where-Object { $_ })
    $ids = @($components | ForEach-Object id)
    $dataAccess = @($components | Where-Object { Test-DataAccess $_ } | ForEach-Object id)
    $logic = @($ids | Where-Object { $dataAccess -notcontains $_ })
    if ($logic.Count) { Format-View 'component' $Container.id $Container.id (Get-ViewElements $logic $ids $false) 'tb' }
    if ($dataAccess.Count) { Format-View 'component' $Container.id "$($Container.id)-$DataAccessViewSuffix" (Get-ViewElements $dataAccess $ids $true) 'tb' }
}

function Format-Views($Fragments, [string]$System) {
    $lines = @("// Viste generate da $Repository con Export-C4CodeModel.ps1: non si modificano a mano.")
    foreach ($application in Get-Applications $Fragments) {
        $lines += Format-View 'container' $System "container-$($application.id)" @("->$($application.id)->") 'lr'
    }
    foreach ($container in @($Fragments.Content.containers | Where-Object { @($_.components | Where-Object { $_ }).Count })) {
        $lines += Format-ComponentViews $container
    }
    return ($lines -join "`n") + "`n"
}

# Gli ambienti di deployment della parte: il modello li accetta solo fuori dal sistema software e dopo i
# container a cui le istanze rimandano, quindi stanno in un file proprio. Il testo di un nodo e' uno per
# tutti gli ambienti.
function Get-DeploymentEnvironments($Fragments) {
    return @($Fragments | ForEach-Object { @($_.Content.deployment) } | Where-Object { $_ })
}

function Format-DeploymentNode($Node, [string]$Indent) {
    $description = Format-Text $script:ModelText.Elements[$Node.text]
    if ($Node.kind -eq 'infrastructureNode') {
        return "$Indent$($Node.id) = infrastructureNode $(Format-Text $Node.name) $description $(Format-Text $Node.technology) $(Format-Text $GeneratedTag)"
    }
    $lines = @("$Indent$($Node.id) = deploymentNode $(Format-Text $Node.name) $description $(Format-Text $Node.technology) $(Format-Text $GeneratedTag) {")
    $lines += @($Node.children | Where-Object { $_ } | ForEach-Object { Format-DeploymentNode $_ "$Indent    " })
    $lines += @($Node.instances | Where-Object { $_ } | ForEach-Object { Get-KeptId $_ } | Select-Object -Unique | ForEach-Object { "$Indent    containerInstance $_" })
    return $lines + "$Indent}"
}

function Format-Deployment($Environments) {
    $lines = @("// Ambienti di deployment generati da $Repository con Export-C4CodeModel.ps1: non si modificano a mano.")
    foreach ($environment in $Environments) {
        $lines += "deploymentEnvironment $(Format-Text $environment.name) {"
        $lines += @($environment.nodes | Where-Object { $_ } | ForEach-Object { Format-DeploymentNode $_ '    ' })
        $lines += '}'
    }
    return ($lines -join "`n") + "`n"
}

# Structurizr non disegna un nodo senza istanze ne' nodi dell'infrastruttura, quindi un gruppo cosi' non ha vista.
function Test-DeploymentContent($Node) {
    return $Node.kind -eq 'infrastructureNode' -or @($Node.instances | Where-Object { $_ }).Count -or
        @($Node.children | Where-Object { $_ -and (Test-DeploymentContent $_) }).Count
}

# I gruppi di un ambiente sono i nodi del secondo livello; la chiave della vista porta il nome del gruppo e,
# se un altro gruppo dell'ambiente ha lo stesso nome, quello del nodo che lo contiene.
function Get-DeploymentGroups($Environment) {
    $groups = @(foreach ($root in @($Environment.nodes | Where-Object { $_ })) {
            @($root.children | Where-Object { $_ -and $_.kind -ne 'infrastructureNode' }) | ForEach-Object { [pscustomobject]@{ Node = $_; Root = $root } }
        })
    $repeated = @($groups | Group-Object { $_.Node.name } | Where-Object Count -GT 1 | ForEach-Object Name)
    foreach ($group in $groups) {
        $name = if ($repeated -contains $group.Node.name) { "$($group.Root.name)_$($group.Node.name)" } else { $group.Node.name }
        $group | Add-Member -NotePropertyName Slug -NotePropertyValue (ConvertTo-Identifier $name) -PassThru
    }
}

function Get-DeploymentChildren($Node) {
    return @($Node.children | Where-Object { $_ -and $_.kind -ne 'infrastructureNode' })
}

function Get-DeploymentSubtree($Node) {
    $Node
    Get-DeploymentChildren $Node | ForEach-Object { Get-DeploymentSubtree $_ }
}

function Test-DeploymentInstances($Node) {
    return @($Node.instances | Where-Object { $_ }).Count -or @(Get-DeploymentChildren $Node | Where-Object { Test-DeploymentInstances $_ }).Count
}

# Le relazioni partono dalle istanze: istanze in rami diversi di un nodo condividono i vicini e le loro frecce
# attraversano i riquadri annidati dei rami, e la vista non si legge alla scala minima. Con un ramo solo la
# vista racconta un'applicazione, come la vista dei container di ogni applicazione.
function Test-DeploymentBranches($Node) {
    return [bool]@(Get-DeploymentSubtree $Node | Where-Object { @(Get-DeploymentChildren $_ | Where-Object { Test-DeploymentInstances $_ }).Count -gt 1 }).Count
}

# Sotto il gruppo la vista di un nodo porta anche gli elementi in relazione con le sue istanze: la vista del
# gruppo li mostrava, e senza di loro le istanze resterebbero senza relazioni.
function Format-DeploymentNodeViews([string]$Environment, $Node, [string]$Key, [bool]$WithNeighbours) {
    $lines = @("deployment * $(Format-Text $Environment) $(Format-Text $Key) {", "    include $($Node.id)")
    if (Test-DeploymentBranches $Node) {
        $children = @(Get-DeploymentChildren $Node)
        $lines += @($children | ForEach-Object { "    exclude $(Format-Text "element.parent==$($_.id)")" })
        $lines += '    autoLayout lr', '}'
        foreach ($child in @($children | Where-Object { Test-DeploymentContent $_ })) {
            $lines += Format-DeploymentNodeViews $Environment $child "${Key}_$(ConvertTo-Identifier $child.name)" $true
        }
        return $lines
    }
    if ($WithNeighbours) {
        $lines += @(Get-DeploymentSubtree $Node | Where-Object { @($_.instances | Where-Object { $_ }).Count } | ForEach-Object { "    include $(Format-Text "->element.parent==$($_.id)->")" })
    }
    return $lines + @('    autoLayout lr', '}')
}

# Un ambiente intero non si legge alla scala minima: la vista d'insieme mostra i gruppi senza il loro
# contenuto e ogni gruppo ha la sua vista con tutto cio' che contiene; un nodo con istanze in piu' rami si
# divide allo stesso modo, nella vista d'insieme del nodo e in una vista per figlio, <chiave del padre>_<figlio>.
function Format-DeploymentViews($Environments) {
    $lines = @("// Viste di deployment generate da $Repository con Export-C4CodeModel.ps1: non si modificano a mano.")
    foreach ($environment in $Environments) {
        $key = "deployment_$(ConvertTo-Identifier $environment.name)"
        $groups = @(Get-DeploymentGroups $environment)
        $lines += "deployment * $(Format-Text $environment.name) $(Format-Text $key) {", '    include *'
        $lines += @($groups | ForEach-Object { "    exclude $(Format-Text "element.parent==$($_.Node.id)")" })
        $lines += '    autoLayout lr', '}'
        foreach ($group in @($groups | Where-Object { Test-DeploymentContent $_.Node })) {
            $lines += Format-DeploymentNodeViews $environment.name $group.Node "${key}_$($group.Slug)" $false
        }
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
    if (-not @($fragments.Content.containers).Count -and -not @(Get-DeploymentEnvironments $fragments).Count) { return New-Issue $Repository 'nessuna applicazione riconosciuta' $SourceDirectory }

    $script:ModelText = Get-PartText $text $fragments
    $script:ApplicationNames = Get-C4ApplicationNames @(Read-FragmentContents | ForEach-Object { @($_.containers) })
    $system = Get-DocumentSystem
    if ((Get-Applications $fragments).Count -and -not $system) { return New-Issue $Repository 'sistema che include le parti generate non trovato' ($WorkspaceFile -replace '\\', '/') }
    $script:PartRelationships = @(Get-PartRelationships $fragments)
    $name = $Repository.ToLowerInvariant()
    $outputs = [ordered]@{ "containers/$name.dsl" = Format-Model $fragments; "views/$name.dsl" = Format-Views $fragments $system; 'context.dsl' = Format-Context }
    $environments = Get-DeploymentEnvironments $fragments
    if ($environments) {
        $outputs["deployment/$name.dsl"] = Format-Deployment $environments
        $outputs["deployment-views/$name.dsl"] = Format-DeploymentViews $environments
    }
    & $ModeActions[$Mode] $outputs
}

Invoke-Verification { Get-GenerationIssues } "Parte del modello C4 di $Repository allineata al codice" 'Generazione del modello C4 disattivata'
