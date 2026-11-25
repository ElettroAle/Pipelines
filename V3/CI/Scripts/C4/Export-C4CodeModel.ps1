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
# GENERATED_DIRECTORY/deployment-views/<repository>.dsl, una per domanda: per ambiente l'allocazione,
# deployment_<ambiente>, e quella di ogni applicazione ospitata, deployment_<ambiente>_app_<container>; la
# rete, deployment_<ambiente>_<suffisso di rete>, e quella di ogni rete con subnet, con il suo nome in coda.
# Ogni vista generata ha un titolo della lingua e, nella proprieta' description, la descrizione composta dal suo
# contenuto con le frasi della lingua (ViewDescriptions): la descrizione resta fuori dal disegno. Una descrizione
# che non nomina nessun elemento della sua vista, o uguale a quella di un'altra vista, ferma la generazione.
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
$ViewTitles = $DocumentLanguage.ViewTitles
$ViewDescriptions = $DocumentLanguage.ViewDescriptions
$SummaryTag = $DocumentLanguage.SummaryTag
$NetworkTag = $DocumentLanguage.NetworkTag
$NetworkViewSuffix = $DocumentLanguage.NetworkViewSuffix
$NodeDescriptions = $DocumentLanguage.NodeDescriptions
$TitleSeparator = ' · '
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
    return [pscustomobject]@{ Source = $source; Target = $target; Text = "$($Texts[0])"; Line = (@("$source -> $target") + @($Texts | ForEach-Object { Format-Text $_ })) -join ' ' }
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

function Format-ViewProperties([System.Collections.IDictionary]$Values) {
    $written = @($Values.Keys | Where-Object { $Values[$_] })
    if (-not $written) { return @() }
    return @('    properties {') + @($written | ForEach-Object { "        $(Format-Text $_) $(Format-Text $Values[$_])" }) + '    }'
}

# Il contenuto di una vista da cui nasce la sua descrizione: il soggetto, gli elementi che mostra con il loro livello
# e le relazioni con i nomi delle estremita' che mostra. Inside sono il soggetto e cio' che contiene, da cui
# escono e in cui entrano le relazioni del soggetto.
function New-ViewContent([string]$Kind, [string]$Subject, [string]$Environment, $Elements, $Relationships, [string[]]$SubjectIds, [string[]]$Inside) {
    return [pscustomobject]@{
        Kind = $Kind; Subject = $Subject; Environment = $Environment; Elements = @($Elements); Relationships = @($Relationships)
        SubjectIds = @($SubjectIds | Where-Object { $_ }); Inside = @($Inside | Where-Object { $_ })
    }
}

function Format-RelationshipItem([string]$Name, [string]$Text) {
    if ($Text) { return "$Name ($Text)" }
    return $Name
}

# I nomi di un elenco del contenuto della vista, in ordine di nome: Subject, Environment, Host (cio' che ospita il
# soggetto), Shown.<livello> (gli elementi mostrati di quel livello, senza il soggetto), Outgoing e Incoming (le
# relazioni del soggetto con il loro testo), Relationships (tutte le relazioni della vista).
function Get-ViewListNames($Content, [string]$Binding) {
    $names = foreach ($source in ($Binding -split ',' | ForEach-Object Trim)) {
        $list, $kind = $source -split '\.', 2
        switch ($list) {
            'Subject' { $Content.Subject }
            'Environment' { $Content.Environment }
            'Host' { $Content.Elements | Where-Object { $Content.SubjectIds -contains $_.Id } | ForEach-Object Host }
            'Shown' { $Content.Elements | Where-Object { $Content.SubjectIds -notcontains $_.Id -and (-not $kind -or $_.Kind -eq $kind) } | ForEach-Object Name }
            'Outgoing' {
                $Content.Relationships | Where-Object { $Content.Inside -contains $_.Source -and $Content.Inside -notcontains $_.Target } |
                    ForEach-Object { Format-RelationshipItem $_.TargetName $_.Text }
            }
            'Incoming' {
                $Content.Relationships | Where-Object { $Content.Inside -contains $_.Target -and $Content.Inside -notcontains $_.Source } |
                    ForEach-Object { Format-RelationshipItem $_.SourceName $_.Text }
            }
            'Relationships' { $Content.Relationships | ForEach-Object { Format-RelationshipItem "$($_.SourceName) → $($_.TargetName)" $_.Text } }
        }
    }
    return @($names | Where-Object { $_ } | Sort-Object -Unique)
}

# La descrizione si registra con i nomi degli elementi della vista, per le regole che la generazione verifica.
function Register-ViewDescription([string]$Key, $Content) {
    $description = Format-LanguagePhrases $ViewDescriptions[$Content.Kind] { param($Binding) Get-ViewListNames $Content $Binding }
    $script:ViewDescriptionsWritten.Add([pscustomobject]@{ Key = $Key; Description = $description; Names = @($Content.Elements | ForEach-Object Name | Where-Object { $_ }) })
    return $description
}

# Una vista che non mostra nessun elemento non ha nulla da nominare.
function Get-ViewDescriptionIssues {
    $described = @($script:ViewDescriptionsWritten | Where-Object { $_.Names.Count })
    foreach ($view in $described) {
        if (-not @($view.Names | Where-Object { $view.Description.Contains($_) }).Count) { New-Issue $Repository 'descrizione di una vista che non nomina nessun elemento che la vista mostra' $view.Key }
    }
    foreach ($group in @($described | Group-Object Description | Where-Object Count -GT 1)) {
        New-Issue $Repository "descrizione uguale per piu' viste" (@($group.Group | ForEach-Object Key) -join ', ')
    }
}

function Get-RelationshipTexts {
    $texts = @{}
    foreach ($key in $script:ModelText.Relationships.Keys) {
        $source, $target = $key -split ' -> ', 2
        if ($script:ModelText.Relationships[$key].description) { $texts["$(Get-KeptId $source) -> $(Get-KeptId $target)"] = "$($script:ModelText.Relationships[$key].description)" }
    }
    return $texts
}

function Get-ElementName([string]$Id) {
    if ($script:ElementNames.ContainsKey($Id)) { return $script:ElementNames[$Id] }
    return $Id
}

# I nomi e i livelli degli elementi del sistema che le viste dei container e dei componenti mostrano.
function Register-SystemElements {
    $script:ElementNames = @{}
    $script:ElementKinds = @{}
    foreach ($container in $script:SystemContainers.Values) {
        $script:ElementNames["$($container.id)"] = Get-ContainerName $container
        $script:ElementKinds["$($container.id)"] = 'container'
        foreach ($component in @($container.components | Where-Object { $_ })) {
            $script:ElementNames["$($component.id)"] = $component.name
            $script:ElementKinds["$($component.id)"] = if (Test-DataAccess $component) { 'dataAccess' } else { 'logic' }
        }
    }
    $script:ModelText.People.PSObject.Properties | Where-Object { $_ } | ForEach-Object { $script:ElementNames[$_.Name] = $_.Value.name; $script:ElementKinds[$_.Name] = 'person' }
    $script:ModelText.ExternalSystems.PSObject.Properties | Where-Object { $_ } | ForEach-Object { $script:ElementNames[$_.Name] = $_.Value.name; $script:ElementKinds[$_.Name] = 'softwareSystem' }
}

function New-CodeViewContent([string]$Kind, [string]$Subject, [string[]]$SubjectIds, [string[]]$Inside, [string[]]$Elements) {
    $shown = @($Elements | ForEach-Object { [pscustomobject]@{ Id = $_; Name = Get-ElementName $_; Kind = $script:ElementKinds[$_]; Host = $null } })
    $relationships = @($script:PartRelationships | ForEach-Object {
            [pscustomobject]@{ Source = $_.Source; Target = $_.Target; SourceName = Get-ElementName $_.Source; TargetName = Get-ElementName $_.Target; Text = $_.Text }
        })
    return New-ViewContent $Kind $Subject '' $shown $relationships $SubjectIds $Inside
}

function Format-View([string]$Kind, [string]$Scope, [string]$Key, [string]$Title, $Content, [string[]]$Elements, [string]$Layout) {
    $description = Register-ViewDescription $Key $Content
    return @("$Kind $Scope $(Format-Text $Key) {", "    title $(Format-Text $Title)", "    include $($Elements -join ' ')") +
        @(Format-ViewProperties ([ordered]@{ description = $description })) + "    autoLayout $Layout" + '}'
}

function Format-ComponentViews($Container) {
    $components = @($Container.components | Where-Object { $_ })
    $ids = @($components | ForEach-Object id)
    $dataAccessIds = @($components | Where-Object { Test-DataAccess $_ } | ForEach-Object id)
    $logicIds = @($components | Where-Object { -not (Test-DataAccess $_) } | ForEach-Object id)
    $name = Get-ContainerName $Container
    if ($logicIds.Count) {
        $elements = Get-ViewElements $logicIds $ids $false
        Format-View 'component' $Container.id $Container.id "$name$TitleSeparator$($ViewTitles.Logic)" (New-CodeViewContent 'Logic' $name @() $logicIds $elements) $elements 'tb'
    }
    if ($dataAccessIds.Count) {
        $elements = Get-ViewElements $dataAccessIds $ids $true
        Format-View 'component' $Container.id "$($Container.id)-$DataAccessViewSuffix" "$name$TitleSeparator$($ViewTitles.DataAccess)" (New-CodeViewContent 'DataAccess' $name @() $dataAccessIds $elements) $elements 'tb'
    }
}

function Format-Views($Fragments, [string]$System) {
    $lines = @("// Viste generate da $Repository con Export-C4CodeModel.ps1: non si modificano a mano.")
    foreach ($application in Get-Applications $Fragments) {
        $id = $application.id
        $name = Get-ContainerName $application
        $content = New-CodeViewContent 'Containers' $name @($id) @($id) (Get-ViewElements @($id) @($id) $true)
        $lines += Format-View 'container' $System "container-$id" ($ViewTitles.Containers -f $name) $content @("->$id->") 'lr'
    }
    foreach ($container in @($Fragments.Content.containers | Where-Object { @($_.components | Where-Object { $_ }).Count })) {
        $lines += Format-ComponentViews $container
    }
    return ($lines -join "`n") + "`n"
}

# Gli ambienti di deployment della parte: il modello li accetta solo fuori dal sistema software e dopo i
# container a cui le istanze rimandano, quindi stanno in un file proprio.
function Get-DeploymentEnvironments($Fragments) {
    return @($Fragments | ForEach-Object { @($_.Content.deployment) } | Where-Object { $_ })
}

function Get-TreeNodes($Nodes) {
    foreach ($node in @($Nodes | Where-Object { $_ })) {
        $node
        Get-TreeNodes $node.children
    }
}

# Un livello di nodo nuovo si descrive aggiungendo le sue frasi alla lingua, mai con codice.
function Get-NodeKindIssues($Environments) {
    $kinds = @($Environments | ForEach-Object { Get-TreeNodes $_.nodes } | ForEach-Object { "$($_.kind)" } | Sort-Object -Unique)
    $kinds | Where-Object { -not $_ -or -not $NodeDescriptions.ContainsKey($_) } |
        ForEach-Object { New-Issue $Repository 'livello di nodo senza frasi nella lingua' $(if ($_) { $_ } else { '(nessuno)' }) }
}

# Una vista include per identificativo le istanze dei container.
function Get-InstanceId($Node, [string]$Container) {
    return "$($Node.id)__$Container"
}

function Get-NodeInstances($Node) {
    $seen = @{}
    foreach ($instance in @($Node.instances | Where-Object { $_ })) {
        $container = Get-KeptId $(if ($instance -is [string]) { $instance } else { "$($instance.container)" })
        if ($seen.ContainsKey($container)) { continue }
        $seen[$container] = $true
        [pscustomobject]@{ Container = $container; ResourceGroup = $instance.resourceGroup; Module = $instance.module; AzureName = $instance.azureName }
    }
}

function Get-InstanceName([string]$Container) {
    $name = Get-ContainerName ([pscustomobject]@{ id = $Container; name = $script:SystemContainers[$Container].name })
    if ($name) { return $name }
    return $Container
}

# Un private endpoint si chiama con la risorsa che espone, con il nome che il container ha nel modello.
function Get-NodeName($Node) {
    $exposed = if ($Node.exposes) { $script:SystemContainers[(Get-KeptId $Node.exposes)] }
    if ($exposed) { return Get-ContainerName $exposed }
    return $Node.name
}

# Structurizr rifiuta due nodi con lo stesso nome nello stesso padre, come i private endpoint che espongono
# servizi diversi della stessa risorsa: il nome aggiunge i servizi esposti, il gruppo di risorse o il nome
# della risorsa, e la posizione se restano uguali.
function Get-DistinctNames($Nodes) {
    $names = @{}
    foreach ($node in $Nodes) { $names[$node.id] = Get-NodeName $node }
    foreach ($group in @($Nodes | Group-Object { $names[$_.id] } | Where-Object Count -GT 1)) {
        foreach ($node in $group.Group) {
            $detail = @($node.subresources, $node.resourceGroup, $node.name) | Where-Object { $_ -and $_ -ne $group.Name } | Select-Object -First 1
            if ($detail) { $names[$node.id] = "$($group.Name) · $detail" }
        }
    }
    foreach ($group in @($Nodes | Group-Object { $names[$_.id] } | Where-Object Count -GT 1)) {
        $position = 1
        foreach ($node in $group.Group) { $names[$node.id] = "$($group.Name) · $position"; $position++ }
    }
    return $names
}

function Format-DeploymentNodes($Nodes, [string]$Indent) {
    $children = @($Nodes | Where-Object { $_ })
    $names = Get-DistinctNames $children
    foreach ($child in $children) { Format-DeploymentNode $child $Indent $names[$child.id] }
}

function Format-ElementProperties([System.Collections.IDictionary]$Values, [string]$Indent) {
    $written = @($Values.Keys | Where-Object { $Values[$_] })
    if (-not $written) { return @() }
    return @("${Indent}properties {") + @($written | ForEach-Object { "$Indent    $(Format-Text $_) $(Format-Text $Values[$_])" }) + "${Indent}}"
}

function Format-Block([string]$Head, [string[]]$Body, [string]$Indent) {
    if (-not $Body) { return , $Head }
    return @("$Head {") + $Body + "$Indent}"
}

function Format-DeploymentNode($Node, [string]$Indent, [string]$Name) {
    $head = "$Indent$($Node.id) = $($Node.element) $(Format-Text $Name) $(Format-Text $script:NodeTexts[$Node.id]) $(Format-Text $Node.technology) $(Format-Text $GeneratedTag)"
    $body = @(Format-ElementProperties ([ordered]@{ resourceGroup = $Node.resourceGroup; module = $Node.module; azureName = $Node.azureName }) "$Indent    ")
    if ($Node.element -eq 'infrastructureNode') { return Format-Block $head $body $Indent }
    $body += @(Format-DeploymentNodes $Node.children "$Indent    ")
    foreach ($instance in @(Get-NodeInstances $Node)) {
        $properties = [ordered]@{ resourceGroup = $instance.ResourceGroup; module = $instance.Module; azureName = $instance.AzureName }
        $body += Format-Block "$Indent    $(Get-InstanceId $Node $instance.Container) = containerInstance $($instance.Container)" @(Format-ElementProperties $properties "$Indent        ") "$Indent    "
    }
    return Format-Block $head $body $Indent
}

function Get-ElementReference($Node, [string]$Container) {
    if ($Container) { return "${Node}__$(Get-KeptId $Container)" }
    return $Node
}

function Format-EnvironmentRelationship($Relationship) {
    $identifier = if ($Relationship.Id) { "$($Relationship.Id) = " } else { '' }
    return "    $identifier$($Relationship.Source) -> $($Relationship.Target) $(Format-Text $Relationship.Text) `"`" $(Format-Text ($Relationship.Tags -join ','))"
}

function Format-Deployment($Plans) {
    $lines = @("// Ambienti di deployment generati da $Repository con Export-C4CodeModel.ps1: non si modificano a mano.")
    foreach ($environment in @($Plans | ForEach-Object { $_.Environments })) {
        $lines += "deploymentEnvironment $(Format-Text $environment.Environment.name) {"
        $lines += @(Format-DeploymentNodes $environment.Environment.nodes '    ')
        $lines += @($environment.Relationships | ForEach-Object { Format-EnvironmentRelationship $_ })
        $lines += @($environment.Derived.Values | ForEach-Object { Format-EnvironmentRelationship $_ })
        $lines += '}'
    }
    return ($lines -join "`n") + "`n"
}

# Structurizr non disegna un nodo senza istanze ne' nodi dell'infrastruttura.
function Test-DeploymentContent($Node) {
    return $Node.element -eq 'infrastructureNode' -or @($Node.instances | Where-Object { $_ }).Count -or
        @($Node.children | Where-Object { $_ -and (Test-DeploymentContent $_) }).Count
}

function Get-DeploymentRoots($Environment) {
    return @($Environment.nodes | Where-Object { $_ -and $_.element -ne 'infrastructureNode' })
}

# Le istanze di due container in relazione sono in relazione in ogni ambiente, e la relazione puo' dichiararla
# il codice di qualunque repository del sistema.
function Get-SystemRelationships {
    $contents = @(Read-FragmentContents | Where-Object { $_ })
    $declared = @($contents | ForEach-Object { @($_.relationships) }) + @(Get-C4CallRelationships @(Resolve-C4Calls $contents))
    $written = @{}
    foreach ($relationship in @($declared | Where-Object { $_ })) {
        $source = Get-KeptId $relationship.source
        $target = Get-KeptId $relationship.target
        if ($source -eq $target -or $written.ContainsKey("$source -> $target")) { continue }
        $written["$source -> $target"] = $true
        [pscustomobject]@{ Source = $source; Target = $target }
    }
}

# L'albero di un ambiente: il padre di ogni nodo e di ogni istanza, il nome con cui le descrizioni li elencano, il
# livello e le istanze di ogni container.
function New-EnvironmentTree($Environment) {
    $tree = @{ Parents = @{}; Names = @{}; Elements = @{}; Kinds = @{}; Instances = @{} }
    foreach ($node in @($Environment.nodes | Where-Object { $_ })) { Register-TreeNode $node $null $tree }
    return $tree
}

function Register-TreeNode($Node, [string]$Parent, [hashtable]$Tree) {
    $Tree.Parents[$Node.id] = $Parent
    $Tree.Names[$Node.id] = Get-NodeName $Node
    $Tree.Elements[$Node.id] = $Node.element
    $Tree.Kinds[$Node.id] = "$($Node.kind)"
    foreach ($instance in @(Get-NodeInstances $Node)) {
        $id = Get-InstanceId $Node $instance.Container
        $Tree.Parents[$id] = $Node.id
        $Tree.Names[$id] = Get-InstanceName $instance.Container
        $Tree.Elements[$id] = 'containerInstance'
        $Tree.Kinds[$id] = 'containerInstance'
        $Tree.Instances[$instance.Container] = @($Tree.Instances[$instance.Container] | Where-Object { $_ }) + $id
    }
    $Node.children | Where-Object { $_ } | ForEach-Object { Register-TreeNode $_ $Node.id $Tree }
}

function Test-Within([string]$Id, [string]$Ancestor, [hashtable]$Tree) {
    for ($current = $Id; $current; $current = $Tree.Parents[$current]) { if ($current -eq $Ancestor) { return $true } }
    return $false
}

function Get-TreeRoot([string]$Id, [hashtable]$Tree) {
    $current = $Id
    while ($Tree.Parents[$current]) { $current = $Tree.Parents[$current] }
    return $current
}

# Le frasi della lingua per il livello del nodo, ognuna con i nomi di cio' che elenca in ordine di nome:
# i figli, il nodo che lo contiene, la risorsa che espone, le relazioni di un tipo che dal nodo o dal suo
# contenuto escono o vi entrano.
function Get-NodeDescription($Node, [hashtable]$Tree, $Relationships) {
    return Format-LanguagePhrases $NodeDescriptions[$Node.kind] { param($Binding) Get-DescribedNames $Node $Binding $Tree $Relationships }
}

function Get-DescribedNames($Node, [string]$Binding, [hashtable]$Tree, $Relationships) {
    $names = foreach ($source in ($Binding -split ',' | ForEach-Object Trim)) {
        $direction, $kind = $source -split '\.', 2
        switch ($direction) {
            'Children' {
                @($Node.children | Where-Object { $_ } | ForEach-Object { $Tree.Names[$_.id] })
                @(Get-NodeInstances $Node | ForEach-Object { $Tree.Names[(Get-InstanceId $Node $_.Container)] })
            }
            'Exposes' { if ($Node.exposes) { Get-InstanceName (Get-KeptId $Node.exposes) } else { $Node.exposedName } }
            'Parent' { if ($Tree.Parents[$Node.id]) { $Tree.Names[$Tree.Parents[$Node.id]] } }
            'Outgoing' {
                $Relationships | Where-Object { $_.Kind -eq $kind -and (Test-Within $_.Source $Node.id $Tree) -and -not (Test-Within $_.Target $Node.id $Tree) } |
                    ForEach-Object { $Tree.Names[$_.Target] }
            }
            'Incoming' {
                $Relationships | Where-Object { $_.Kind -eq $kind -and (Test-Within $_.Target $Node.id $Tree) -and -not (Test-Within $_.Source $Node.id $Tree) } |
                    ForEach-Object { $Tree.Names[$_.Source] }
            }
        }
    }
    return @($names | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-NetworkRelationships($Network) {
    foreach ($relationship in @($Network.relationships | Where-Object { $_ })) {
        [pscustomobject]@{
            Source = Get-ElementReference $relationship.source $relationship.sourceContainer
            Target = Get-ElementReference $relationship.target $relationship.targetContainer
            Kind = $relationship.kind; Text = $DocumentLanguage.NetworkRelationships[$relationship.kind]; Tags = @($GeneratedTag, $NetworkTag)
        }
    }
}

# Le relazioni fra le istanze di un ambiente, che Structurizr ricava da quelle fra i loro container, con il testo
# della relazione.
function Get-InstanceRelationships([hashtable]$Tree) {
    foreach ($relationship in $script:SystemRelationships) {
        $text = $script:RelationshipTexts["$($relationship.Source) -> $($relationship.Target)"]
        foreach ($source in @($Tree.Instances[$relationship.Source] | Where-Object { $_ })) {
            foreach ($target in @($Tree.Instances[$relationship.Target] | Where-Object { $_ })) {
                [pscustomobject]@{ Source = $source; Target = $target; Text = $text; Tags = @($GeneratedTag) }
            }
        }
    }
}

function New-PlanEnvironment($Environment, $Relationships) {
    $tree = New-EnvironmentTree $Environment
    Get-TreeNodes $Environment.nodes | ForEach-Object { $script:NodeTexts[$_.id] = Get-NodeDescription $_ $tree $Relationships }
    return [pscustomobject]@{
        Environment = $Environment; Tree = $tree; Relationships = @($Relationships); Derived = [ordered]@{}
        Links = @($Relationships) + @(Get-InstanceRelationships $tree)
    }
}

# Una vista dichiara gli elementi che mostra: un nodo incluso con il suo contenuto, un nodo chiuso solo con il
# suo riquadro. Con dei filtri sulle relazioni la vista le esclude tutte e include solo quelle.
function New-DeploymentView([string]$Environment, [string]$Key, [string]$Title, $Subject, [string[]]$Shown, [string[]]$Closed = @(), [string[]]$Filters = @(), [System.Collections.IDictionary]$Properties = @{}) {
    return [pscustomobject]@{
        Environment = $Environment; Key = $Key; Title = $Title; Subject = $Subject; Shown = @($Shown); Closed = @($Closed | Where-Object { $_ })
        Filters = @($Filters); Properties = $Properties; Visible = $null; Own = @(); Excluded = @(); Description = ''
    }
}

# Il soggetto di una vista, per la sua descrizione: il tipo della vista, il nome del soggetto, l'ambiente e gli
# elementi che lo rappresentano nella vista.
function New-ViewSubject([string]$Kind, [string]$Name, [string]$Environment, [string[]]$Ids = @()) {
    return [pscustomobject]@{ Kind = $Kind; Name = $Name; Environment = $Environment; Ids = @($Ids) }
}

function Get-VisibleElements($View, [hashtable]$Tree) {
    $visible = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in $View.Shown) {
        if ($id -eq '*') { $Tree.Parents.Keys | ForEach-Object { [void]$visible.Add($_) }; continue }
        [void]$visible.Add($id)
        if ($View.Closed -notcontains $id) { $Tree.Parents.Keys | Where-Object { Test-Within $_ $id $Tree } | ForEach-Object { [void]$visible.Add($_) } }
    }
    return , $visible
}

function Get-ShownAncestor([string]$Id, [System.Collections.Generic.HashSet[string]]$Visible, [hashtable]$Tree) {
    for ($current = $Id; $current; $current = $Tree.Parents[$current]) { if ($Visible.Contains($current)) { return $current } }
    return $null
}

# Structurizr non accetta una relazione fra un nodo di deployment e un'istanza: l'estremita' dell'istanza sale al
# nodo mostrato che la contiene.
function Get-PermittedEnds([string]$Source, [string]$Target, $View, [hashtable]$Tree) {
    $kinds = @($Tree.Elements[$Source], $Tree.Elements[$Target])
    if ($kinds -notcontains 'deploymentNode' -or $kinds -notcontains 'containerInstance') { return $Source, $Target }
    if ($kinds[0] -eq 'containerInstance') { return (Get-ShownAncestor $Tree.Parents[$Source] $View.Visible $Tree), $Target }
    return $Source, (Get-ShownAncestor $Tree.Parents[$Target] $View.Visible $Tree)
}

# Ogni relazione dell'ambiente si disegna fra gli antenati piu' vicini delle sue estremita' che la vista mostra:
# fra le estremita' stesse e' la relazione del modello, fra due antenati una derivata che fonde quelle che vi
# arrivano, con i testi distinti. Structurizr non crea relazioni implicite fra nodi di deployment.
function Get-DerivedRelationships($View, $Plan) {
    $pairs = [ordered]@{}
    foreach ($relationship in $Plan.Relationships) {
        $source, $target = Get-PermittedEnds (Get-ShownAncestor $relationship.Source $View.Visible $Plan.Tree) (Get-ShownAncestor $relationship.Target $View.Visible $Plan.Tree) $View $Plan.Tree
        if (-not $source -or -not $target -or $source -eq $target -or ($source -eq $relationship.Source -and $target -eq $relationship.Target)) { continue }
        if (-not $pairs.Contains("$source -> $target")) { $pairs["$source -> $target"] = [pscustomobject]@{ Source = $source; Target = $target; Represented = [System.Collections.Generic.List[object]]::new() } }
        $pairs["$source -> $target"].Represented.Add($relationship)
    }
    foreach ($pair in $pairs.Values) {
        $tags = @($pair.Represented | ForEach-Object { $_.Tags } | Select-Object -Unique) + $SummaryTag
        [pscustomobject]@{ Source = $pair.Source; Target = $pair.Target; Text = (@($pair.Represented.Text | Sort-Object -Unique) -join ', '); Tags = $tags }
    }
}

# Una derivata uguale per piu' viste si scrive una volta, con un identificativo con cui le viste la escludono.
function Register-Derived($Derived, $Plan) {
    $key = "$($Derived.Source) -> $($Derived.Target): $($Derived.Text)"
    if ($Plan.Derived.Contains($key)) { return $Plan.Derived[$key] }
    $base = "$($Derived.Source)__to__$($Derived.Target)"
    $taken = @($Plan.Derived.Values | ForEach-Object Id)
    $id = $base
    for ($index = 2; $taken -contains $id; $index++) { $id = "${base}_$index" }
    $Derived | Add-Member -NotePropertyName Id -NotePropertyValue $id
    $Plan.Derived[$key] = $Derived
    return $Derived
}

# Una derivata di un'altra vista con entrambe le estremita' mostrate si escluderebbe solo per caso: si esclude
# per identificativo.
function Set-ViewRelationships($Views, $Plans) {
    foreach ($view in $Views) {
        $plan = $Plans | Where-Object { $_.Environment.name -eq $view.Environment } | Select-Object -First 1
        $view.Visible = Get-VisibleElements $view $plan.Tree
        $view.Own = @(Get-DerivedRelationships $view $plan | ForEach-Object { (Register-Derived $_ $plan).Id })
    }
    foreach ($view in $Views) {
        $plan = $Plans | Where-Object { $_.Environment.name -eq $view.Environment } | Select-Object -First 1
        $view.Excluded = @($plan.Derived.Values | Where-Object { $view.Own -notcontains $_.Id -and $view.Visible.Contains($_.Source) -and $view.Visible.Contains($_.Target) } | ForEach-Object Id)
    }
}

# Le relazioni di un ambiente che una vista disegna, con il tag che i suoi filtri chiedono, fra le estremita' che mostra.
function Get-ViewRelationships($View, $Plan) {
    $tags = @($View.Filters | Where-Object { $_ -match '^relationship\.tag==' } | ForEach-Object { $_ -replace '^relationship\.tag==', '' })
    foreach ($relationship in $Plan.Links) {
        if ($tags -and -not @($relationship.Tags | Where-Object { $tags -contains $_ }).Count) { continue }
        $source = Get-ShownAncestor $relationship.Source $View.Visible $Plan.Tree
        $target = Get-ShownAncestor $relationship.Target $View.Visible $Plan.Tree
        if (-not $source -or -not $target -or $source -eq $target) { continue }
        [pscustomobject]@{ Source = $relationship.Source; Target = $relationship.Target; SourceName = $Plan.Tree.Names[$source]; TargetName = $Plan.Tree.Names[$target]; Text = $relationship.Text }
    }
}

function Get-DeploymentViewContent($View, $Plan) {
    $tree = $Plan.Tree
    $elements = @($View.Visible | ForEach-Object { [pscustomobject]@{ Id = $_; Name = $tree.Names[$_]; Kind = $tree.Kinds[$_]; Host = $tree.Names[$tree.Parents[$_]] } })
    $subject = $View.Subject
    $inside = @($tree.Parents.Keys | Where-Object { $id = $_; @($subject.Ids | Where-Object { Test-Within $id $_ $tree }).Count })
    return New-ViewContent $subject.Kind $subject.Name $subject.Environment $elements @(Get-ViewRelationships $View $Plan) $subject.Ids $inside
}

function Set-ViewDescriptions($Views, $Plans) {
    foreach ($view in $Views) {
        $plan = $Plans | Where-Object { $_.Environment.name -eq $view.Environment } | Select-Object -First 1
        $view.Description = Register-ViewDescription $view.Key (Get-DeploymentViewContent $view $plan)
    }
}

function Format-DeploymentView($View) {
    $lines = @("deployment * $(Format-Text $View.Environment) $(Format-Text $View.Key) {", "    title $(Format-Text $View.Title)")
    $lines += @($View.Shown | ForEach-Object { "    include $_" })
    $lines += @($View.Closed | ForEach-Object { "    exclude $(Format-Text "element.parent==$_")" })
    if ($View.Filters) { $lines += '    exclude relationship==*' }
    $lines += @($View.Filters | ForEach-Object { "    include $(Format-Text $_)" })
    $lines += @($View.Excluded | ForEach-Object { "    exclude $_" })
    $properties = [ordered]@{ description = $View.Description }
    foreach ($name in $View.Properties.Keys) { $properties[$name] = $View.Properties[$name] }
    return $lines + @(Format-ViewProperties $properties) + '    autoLayout lr' + '}'
}

function Get-AllocationInstances($Environment) {
    foreach ($root in (Get-DeploymentRoots $Environment)) {
        foreach ($instance in @(Get-NodeInstances $root)) { [pscustomobject]@{ Container = $instance.Container; Id = Get-InstanceId $root $instance.Container; Placed = $false } }
        foreach ($node in @($root.children | Where-Object { $_ -and $_.element -ne 'infrastructureNode' })) {
            foreach ($instance in @(Get-NodeInstances $node)) { [pscustomobject]@{ Container = $instance.Container; Id = Get-InstanceId $node $instance.Container; Placed = $true } }
        }
    }
}

function Get-RelatedContainers([string]$Container) {
    return @($script:SystemRelationships | ForEach-Object {
            if ($_.Source -eq $Container) { $_.Target } elseif ($_.Target -eq $Container) { $_.Source }
        } | Select-Object -Unique)
}

# Una vista per applicazione ospitata: le sue istanze, quelle in relazione con loro e solo le loro relazioni.
function New-ApplicationAllocationView([string]$Environment, [string]$Key, [string]$Container, $Instances) {
    $own = @($Instances | Where-Object Container -EQ $Container | ForEach-Object Id)
    $related = Get-RelatedContainers $Container
    $neighbours = @($Instances | Where-Object { $_.Container -ne $Container -and $related -contains $_.Container } | ForEach-Object Id | Select-Object -Unique)
    $filters = @($own | ForEach-Object { "relationship.source==$_"; "relationship.destination==$_" })
    return New-DeploymentView $Environment "${Key}_app_$Container" ($ViewTitles.ApplicationAllocation -f $Environment, (Get-InstanceName $Container)) (New-ViewSubject 'ApplicationAllocation' (Get-InstanceName $Container) $Environment $own) (@($own) + $neighbours) @() $filters
}

# La vista d'insieme mostra i piani di calcolo e le applicazioni senza piano, con le loro istanze e le chiamate
# fra le applicazioni; porta gli ambienti di cui la pubblicazione elenca i gruppi di risorse.
function Get-AllocationViews($Environment, $Network) {
    $key = "deployment_$(ConvertTo-Identifier $Environment.name)"
    $placed = @(Get-DeploymentRoots $Environment | ForEach-Object { @($_.children | Where-Object { $_ }) } | ForEach-Object id)
    $shown = if ($placed) { $placed } else { @('*') }
    $groups = [ordered]@{ resourceGroups = (@($Environment.name) + @(if ($Network) { $Network.name })) -join ';' }
    New-DeploymentView $Environment.name $key ($ViewTitles.Allocation -f $Environment.name) (New-ViewSubject 'Allocation' $Environment.name $Environment.name) $shown @() @() $groups
    $instances = @(Get-AllocationInstances $Environment)
    foreach ($container in @($instances | Where-Object Placed | ForEach-Object Container | Sort-Object -Unique)) {
        New-ApplicationAllocationView $Environment.name $key $container $instances
    }
}

function Get-PartSlugs($Parts) {
    $repeated = @($Parts | Group-Object name | Where-Object Count -GT 1 | ForEach-Object Name)
    $slugs = @{}
    foreach ($part in $Parts) { $slugs[$part.id] = ConvertTo-Identifier $(if ($repeated -contains $part.name) { "$($part.resourceGroup)_$($part.name)" } else { $part.name }) }
    return $slugs
}

# La vista d'insieme della rete mostra chiuse le reti e i profili d'ingresso; ogni rete con subnet ha la sua vista,
# con chiuse le radici con cui ha relazioni. Il filtro sul tag della rete tiene fuori le chiamate fra le istanze.
function Get-NetworkViews($Plan, [string]$Environment) {
    $network = $Plan.Environment
    $key = "deployment_$(ConvertTo-Identifier $Environment)_$NetworkViewSuffix"
    $filters = @("relationship.tag==$NetworkTag")
    $rootNodes = @(Get-DeploymentRoots $network)
    $rootIds = @($rootNodes | ForEach-Object id)
    New-DeploymentView $network.name $key ($ViewTitles.Network -f $Environment) (New-ViewSubject 'Network' $Environment $Environment) $(if ($rootIds) { $rootIds } else { @('*') }) $rootIds $filters
    $parts = @($rootNodes | Where-Object { @($_.children | Where-Object { $_ -and $_.element -ne 'infrastructureNode' -and (Test-DeploymentContent $_) }).Count })
    $slugs = Get-PartSlugs $parts
    foreach ($part in $parts) {
        $related = @($Plan.Relationships | ForEach-Object {
                $source = Get-TreeRoot $_.Source $Plan.Tree
                $target = Get-TreeRoot $_.Target $Plan.Tree
                if ($source -eq $part.id) { $target } elseif ($target -eq $part.id) { $source }
            } | Where-Object { $_ -and $_ -ne $part.id } | Select-Object -Unique)
        New-DeploymentView $network.name "${key}_$($slugs[$part.id])" ($ViewTitles.NetworkPart -f $Environment, $part.name) (New-ViewSubject 'NetworkPart' $Plan.Tree.Names[$part.id] $Environment @($part.id)) (@($part.id) + $related) $related $filters
    }
}

function New-DeploymentPlan($Allocation, $Network) {
    $environments = @(New-PlanEnvironment $Allocation @())
    $views = @(Get-AllocationViews $Allocation $Network)
    if ($Network) {
        $environments += New-PlanEnvironment $Network @(Get-NetworkRelationships $Network)
        $views += @(Get-NetworkViews $environments[-1] $Allocation.name)
    }
    Set-ViewRelationships $views $environments
    Set-ViewDescriptions $views $environments
    return [pscustomobject]@{ Environments = $environments; Views = @($views | ForEach-Object { Format-DeploymentView $_ }) }
}

# Ogni ambiente del modello ha l'ambiente dell'allocazione e, se il lettore lo scrive, quello della rete.
function Get-DeploymentPlans($Environments) {
    $networks = @($Environments | Where-Object kind -EQ 'network')
    foreach ($allocation in @($Environments | Where-Object kind -NE 'network')) {
        New-DeploymentPlan $allocation (@($networks | Where-Object environment -EQ $allocation.name) | Select-Object -First 1)
    }
}

function Format-DeploymentViews($Plans) {
    $lines = @("// Viste di deployment generate da $Repository con Export-C4CodeModel.ps1: non si modificano a mano.")
    $lines += @($Plans | ForEach-Object { $_.Views })
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
    $script:SystemRelationships = @(Get-SystemRelationships)
    $script:SystemContainers = @{}
    Read-FragmentContents | Where-Object { $_ } | ForEach-Object { @($_.containers) } | Where-Object { $_ } | ForEach-Object { $script:SystemContainers["$($_.id)"] = $_ }
    Register-SystemElements
    $script:RelationshipTexts = Get-RelationshipTexts
    $script:ViewDescriptionsWritten = [System.Collections.Generic.List[object]]::new()
    $name = $Repository.ToLowerInvariant()
    $outputs = [ordered]@{ "containers/$name.dsl" = Format-Model $fragments; "views/$name.dsl" = Format-Views $fragments $system; 'context.dsl' = Format-Context }
    $environments = Get-DeploymentEnvironments $fragments
    $kindIssues = @(Get-NodeKindIssues $environments)
    if ($kindIssues) { return $kindIssues }
    if ($environments) {
        $script:NodeTexts = @{}
        $plans = @(Get-DeploymentPlans $environments)
        $outputs["deployment/$name.dsl"] = Format-Deployment $plans
        $outputs["deployment-views/$name.dsl"] = Format-DeploymentViews $plans
    }
    $descriptionIssues = @(Get-ViewDescriptionIssues)
    if ($descriptionIssues) { return $descriptionIssues }
    & $ModeActions[$Mode] $outputs
}

Invoke-Verification { Get-GenerationIssues } "Parte del modello C4 di $Repository allineata al codice" 'Generazione del modello C4 disattivata'
