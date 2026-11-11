# SPDX-License-Identifier: Apache-2.0

# Un partecipante di un diagramma di sequenza e' un elemento del modello C4 identificato dal suo
# identificativo nel DSL, l'alias del partecipante; l'etichetta e' il nome che il modello gli da' e
# cambia con il modello senza cambiare l'identita'. Una seconda istanza dello stesso elemento
# nello stesso diagramma ha l'alias <identificativo>~<numero>: la tilde non compare negli
# identificativi del DSL. Usato da Test-DiagramFlows.ps1 e Sync-DiagramLabels.ps1.

$DslIdentifierProperty = 'structurizr.dsl.identifier'
$InstanceSeparator = '~'

function Get-DslIdentifier($Element) {
    $identifier = $Element.properties.$DslIdentifierProperty
    if ($identifier) { return "$identifier" }
    return "$($Element.id)"
}

function New-ModelIndex($Workspace) {
    $elements = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $byNumber = @{}
    $add = {
        param($Element, [string]$Kind, [string]$Container)
        $id = Get-DslIdentifier $Element
        $elements[$id] = [pscustomobject]@{ Id = $id; Name = "$($Element.name)"; Kind = $Kind; Container = $Container }
        $byNumber["$($Element.id)"] = $id
    }
    $sources = [System.Collections.Generic.List[object]]::new()
    foreach ($person in @($Workspace.model.people | Where-Object { $_ })) { & $add $person 'person' $null; $sources.Add($person) }
    foreach ($system in @($Workspace.model.softwareSystems | Where-Object { $_ })) {
        & $add $system 'softwareSystem' $null; $sources.Add($system)
        foreach ($container in @($system.containers | Where-Object { $_ })) {
            & $add $container 'container' $null; $sources.Add($container)
            $containerId = Get-DslIdentifier $container
            foreach ($component in @($container.components | Where-Object { $_ })) { & $add $component 'component' $containerId; $sources.Add($component) }
        }
    }
    $relations = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($relation in @($sources | ForEach-Object { @($_.relationships) } | Where-Object { $_ })) {
        [void]$relations.Add("$($byNumber["$($relation.sourceId)"])>$($byNumber["$($relation.destinationId)"])")
    }
    return [pscustomobject]@{ Elements = $elements; Relations = $relations }
}

function Resolve-ElementId([string]$Alias, $Model) {
    if ($Model.Elements.ContainsKey($Alias)) { return $Alias }
    $separator = $Alias.LastIndexOf($InstanceSeparator)
    if ($separator -gt 0 -and $Alias.Substring($separator + 1) -match '^\d+$') {
        $element = $Alias.Substring(0, $separator)
        if ($Model.Elements.ContainsKey($element)) { return $element }
    }
}

function Get-ContainerNamed([string]$Name, $Model) {
    $found = @($Model.Elements.Values | Where-Object { $_.Kind -eq 'container' -and $_.Name -ceq $Name })
    if ($found.Count -eq 1) { return $found[0].Id }
}

# Un partecipante scritto per nome si riconosce dal nome: un componente nel riquadro del suo container,
# gli altri elementi fuori dai riquadri, solo se il nome e' di un elemento soltanto.
function Find-ElementByName([string]$Name, [string]$Box, $Model) {
    if (-not $Model) { return }
    if ($Box) {
        $container = Get-ContainerNamed $Box $Model
        $found = @($Model.Elements.Values | Where-Object { $_.Kind -eq 'component' -and $_.Container -ceq $container -and $_.Name -ceq $Name })
    }
    else { $found = @($Model.Elements.Values | Where-Object { $_.Kind -ne 'component' -and $_.Name -ceq $Name }) }
    if ($found.Count -eq 1) { return $found[0].Id }
}

# Il riquadro di un diagramma e' il container dei componenti che contiene, se sono tutti dello stesso.
function Get-BoxContainer($Box, [System.Collections.IDictionary]$Aliases, $Model) {
    $containers = @($Box.actors | ForEach-Object { if ($Aliases.Contains($_)) { Resolve-ElementId $Aliases[$_] $Model } } | Where-Object { $_ } |
            ForEach-Object { $Model.Elements[$_].Container } | Select-Object -Unique)
    if ($containers.Count -eq 1 -and $containers[0]) { return $containers[0] }
}

# Alias nuovo di ogni partecipante: il suo identificativo nel modello, con il numero dell'istanza
# se l'elemento compare piu' volte; un partecipante che nessun modello riconosce resta com'e'.
function Get-ParticipantAliases($Parsed, $Head, $Base) {
    $aliases = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $taken = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($placement in @($Parsed.placements | Where-Object { $_ })) {
        $id = Resolve-ElementId $placement.id $Head
        if (-not $id) { $id = Find-ElementByName $placement.name $placement.box $Head }
        if (-not $id) {
            $old = Find-ElementByName $placement.name $placement.box $Base
            if ($old -and $Head.Elements.ContainsKey($old)) { $id = $old }
        }
        if (-not $id) { continue }
        $taken[$id] = 1 + $(if ($taken.ContainsKey($id)) { $taken[$id] } else { 0 })
        $aliases[$placement.id] = if ($taken[$id] -eq 1) { $id } else { "$id$InstanceSeparator$($taken[$id])" }
    }
    return $aliases
}


$DeclarationPattern = '^(?<lead>\s*(?:create\s+)?)(?<kind>participant|actor)\s+(?<alias>\S+?)(?:\s+as\s+(?<label>.+?))?\s*$'
$BoxPattern = '^\s*box\b'
# Le righe che aprono o separano un blocco portano testo libero, non partecipanti.
$FreeTextPattern = '^\s*(loop|alt|else|opt|par|and|critical|option|break|rect|end|title|autonumber|accTitle|accDescr)\b'

function Get-AlignedDeclaration([string]$Line, [System.Collections.IDictionary]$Aliases, $Head) {
    $match = [regex]::Match($Line, $DeclarationPattern)
    $alias = $match.Groups['alias'].Value
    if (-not $Aliases.Contains($alias)) { return $Line }
    $newAlias = $Aliases[$alias]
    $name = $Head.Elements[(Resolve-ElementId $newAlias $Head)].Name
    return "$($match.Groups['lead'].Value)$($match.Groups['kind'].Value) $newAlias as $name"
}

function Get-AlignedBox([string]$Line, $Box, [System.Collections.IDictionary]$Aliases, $Head) {
    $container = Get-BoxContainer $Box $Aliases $Head
    if (-not $container) { return $Line }
    $name = $Head.Elements[$container].Name
    if ($Box.name -and $Line.TrimEnd().EndsWith($Box.name)) { return $Line.TrimEnd().Substring(0, $Line.TrimEnd().Length - $Box.name.Length) + $name }
    return "$($Line.TrimEnd()) $name"
}

# Gli alias cambiati in una sola sostituzione, i piu' lunghi prima: un alias nuovo non si riscrive.
# Dopo un alias puo' venire il trattino di una freccia (->>, -->>, -x, -)).
function Get-RenamePattern([System.Collections.IDictionary]$Aliases) {
    $changed = @($Aliases.Keys | Where-Object { $Aliases[$_] -cne $_ } | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) })
    if ($changed) { return "(?<![\w.~-])(?:$($changed -join '|'))(?![\w.~]|-(?![->x)]))" }
}

function Get-AlignedReferences([string]$Line, [System.Collections.IDictionary]$Aliases, [string]$RenamePattern) {
    if (-not $RenamePattern) { return $Line }
    $colon = $Line.IndexOf(':')
    $head = if ($colon -ge 0) { $Line.Substring(0, $colon) } else { $Line }
    $tail = if ($colon -ge 0) { $Line.Substring($colon) } else { '' }
    return [regex]::Replace($head, $RenamePattern, { param($match) $Aliases[$match.Value] }) + $tail
}

# Un partecipante che compare solo nei messaggi non ha una riga che ne porti l'etichetta: la riceve
# subito dopo l'intestazione del diagramma.
function Add-ImplicitDeclarations([string[]]$Lines, [System.Collections.IDictionary]$Aliases, [string[]]$Declared, $Head) {
    $implicit = @($Aliases.Keys | Where-Object { $Declared -cnotcontains $_ })
    $header = [array]::FindIndex($Lines, [Predicate[string]] { param($line) $line -match '^\s*sequenceDiagram\b' })
    if (-not $implicit -or $header -lt 0) { return $Lines }
    $indent = if ($Lines.Count -gt $header + 1 -and $Lines[$header + 1] -match '^(\s+)') { $Matches[1] } else { '    ' }
    $declarations = @($implicit | ForEach-Object { "${indent}participant $($Aliases[$_]) as $($Head.Elements[(Resolve-ElementId $Aliases[$_] $Head)].Name)" })
    return @($Lines[0..$header]) + $declarations + @($Lines | Select-Object -Skip ($header + 1))
}

# Il testo del diagramma con gli alias e le etichette del modello Head; il modello Base riconosce i
# partecipanti scritti con un nome che Head non ha piu'.
function Get-AlignedDiagram([string]$Text, $Parsed, $Head, $Base) {
    $aliases = Get-ParticipantAliases $Parsed $Head $Base
    $renamePattern = Get-RenamePattern $aliases
    $boxes = @($Parsed.boxes | Where-Object { $_ })
    $boxIndex = 0
    $declared = [System.Collections.Generic.List[string]]::new()
    $lines = foreach ($line in ($Text -split "`n")) {
        if ($line -match $DeclarationPattern) { $declared.Add($Matches['alias']); Get-AlignedDeclaration $line $aliases $Head }
        elseif ($line -match $BoxPattern) { Get-AlignedBox $line $boxes[$boxIndex] $aliases $Head; $boxIndex++ }
        elseif ($line -match $FreeTextPattern) { $line }
        else { Get-AlignedReferences $line $aliases $renamePattern }
    }
    return ((Add-ImplicitDeclarations @($lines) $aliases @($declared) $Head) -join "`n")
}
