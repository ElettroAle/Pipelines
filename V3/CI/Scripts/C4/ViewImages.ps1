# SPDX-License-Identifier: Apache-2.0

# Disegna le viste C4 esportate in C4-PlantUML nel modo che si legge meglio. Ogni vista si disegna
# dall'alto in basso e da sinistra a destra, ciascuna con gli spazi di default e con spazi stretti, con i
# ranghi come escono e con i ranghi troppo larghi a capo, e resta il disegno che, adattato alla pagina, si
# rimpicciolisce meno: la direzione scritta nel modello e' solo il punto di partenza. La pagina misura
# C4_PAGE_WIDTH per C4_PAGE_HEIGHT pixel; sotto C4_MIN_SCALE il disegno scelto e' il meno peggio, e lo si
# segnala senza fermare nulla.

. "$PSScriptRoot/../Arc42/PlantUml.ps1"

$ViewPage = [pscustomobject]@{
    Width    = if ($env:C4_PAGE_WIDTH) { [int]$env:C4_PAGE_WIDTH } else { 1200 }
    Height   = if ($env:C4_PAGE_HEIGHT) { [int]$env:C4_PAGE_HEIGHT } else { 1600 }
    MinScale = if ($env:C4_MIN_SCALE) { [double]::Parse($env:C4_MIN_SCALE, [Globalization.CultureInfo]::InvariantCulture) } else { 0.6 }
}
# L'esportatore di Structurizr scrive la direzione in una sola riga di PlantUML: un diagramma ha una
# direzione sola, e gli spazi fra gli elementi si stringono con nodesep e ranksep.
$ViewLayouts = [ordered]@{
    'tb'         = @{ Direction = 'top to bottom direction'; Spacing = '' }
    'lr'         = @{ Direction = 'left to right direction'; Spacing = '' }
    'tb-stretto' = @{ Direction = 'top to bottom direction'; Spacing = "skinparam nodesep 20`nskinparam ranksep 30" }
    'lr-stretto' = @{ Direction = 'left to right direction'; Spacing = "skinparam nodesep 20`nskinparam ranksep 30" }
}
$DirectionLinePattern = '(?m)^(?:top to bottom|left to right) direction[ \t]*\r?$'
# Gli elementi chiamati da uno stesso elemento finiscono in un rango, una riga dall'alto in basso e una
# colonna da sinistra a destra, che si allunga a ogni risorsa o componente nuovo. Come unflatten di Graphviz,
# un rango piu' largo di una di queste larghezze va a capo: si va da righe strette dall'alto in basso a
# colonne lunghe da sinistra a destra.
$RankWidths = @(3, 5, 8)
$RelationPattern = '(?m)^[ \t]*Rel(?:_\w+)?\((?<source>[^,\s]+)\s*,\s*(?<target>[^,\s]+)\s*,'

function Set-DiagramLayout([string]$Diagram, [string]$Layout) {
    $lines = (@($ViewLayouts[$Layout].Direction, $ViewLayouts[$Layout].Spacing) | Where-Object { $_ }) -join "`n"
    if ($Diagram -match $DirectionLinePattern) { return [regex]::new($DirectionLinePattern).Replace($Diagram, $lines.Replace('$', '$$'), 1) }
    return [regex]::new('(?m)^@startuml.*$').Replace($Diagram, "`$0`n$lines", 1)
}

# Rango di ogni elemento con relazioni: il cammino piu' lungo che lo raggiunge, come nel layout a ranghi.
# Una relazione che chiude un ciclo non allunga il cammino.
function Get-DiagramRanks([string]$Diagram) {
    $targets = [ordered]@{}
    foreach ($relation in [regex]::Matches($Diagram, $RelationPattern)) {
        $source = $relation.Groups['source'].Value
        foreach ($id in $source, $relation.Groups['target'].Value) { if (-not $targets.Contains($id)) { $targets[$id] = [Collections.Generic.List[string]]::new() } }
        $targets[$source].Add($relation.Groups['target'].Value)
    }
    $order = [Collections.Generic.List[string]]::new()
    $visited = @{}
    $visit = {
        param($Id)
        $visited[$Id] = $true
        foreach ($target in $targets[$Id]) { if (-not $visited.ContainsKey($target)) { & $visit $target } }
        $order.Insert(0, $Id)
    }
    foreach ($id in @($targets.Keys)) { if (-not $visited.ContainsKey($id)) { & $visit $id } }
    $position = @{}
    for ($i = 0; $i -lt $order.Count; $i++) { $position[$order[$i]] = $i }
    $ranks = [ordered]@{}
    foreach ($id in $targets.Keys) { $ranks[$id] = 0 }
    foreach ($id in $order) {
        foreach ($target in $targets[$id]) { if ($position[$target] -gt $position[$id]) { $ranks[$target] = [math]::Max($ranks[$target], $ranks[$id] + 1) } }
    }
    return $ranks
}

# Ogni elemento di un rango piu' largo di Width ha una freccia nascosta verso quello Width posti dopo, che
# scende cosi' di un rango: il rango diventa righe di Width elementi.
function Add-RankWraps([string]$Diagram, [int]$Width) {
    $ranks = Get-DiagramRanks $Diagram
    $wraps = @(foreach ($rank in ($ranks.Keys | Group-Object { $ranks[$_] })) {
            $ids = @($rank.Group)
            for ($i = 0; $i + $Width -lt $ids.Count; $i++) { "$($ids[$i]) -[hidden]-> $($ids[$i + $Width])" }
        })
    if (-not $wraps.Count) { return $Diagram }
    $end = $Diagram.LastIndexOf('@enduml')
    return $Diagram.Substring(0, $end) + ($wraps -join "`n") + "`n" + $Diagram.Substring($end)
}

# Larghezza e altezza stanno nell'intestazione IHDR del PNG, in big-endian dal sedicesimo byte.
function Get-PngSize([byte[]]$Png) {
    $read = { param($Offset) ([int]$Png[$Offset] -shl 24) -bor ([int]$Png[$Offset + 1] -shl 16) -bor ([int]$Png[$Offset + 2] -shl 8) -bor [int]$Png[$Offset + 3] }
    return [pscustomobject]@{ Width = & $read 16; Height = & $read 20 }
}

function Get-PageScale($Size) {
    return [math]::Min(1.0, [math]::Min($ViewPage.Width / $Size.Width, $ViewPage.Height / $Size.Height))
}

function New-ViewImage([byte[]]$Png, $Variant) {
    $size = Get-PngSize $Png
    return [pscustomobject]@{ Png = $Png; Layout = $Variant.Layout; RankWidth = $Variant.RankWidth; Order = $Variant.Order; Width = $size.Width; Height = $size.Height; Scale = (Get-PageScale $size) }
}

# Ogni disposizione con i ranghi come escono, poi con ogni larghezza che un rango supera, nell'ordine in cui
# a parita' si preferiscono.
function Get-DiagramVariants([string]$Diagram) {
    $variants = [Collections.Generic.List[object]]::new()
    foreach ($width in @(0) + $RankWidths) {
        $wrapped = if ($width) { Add-RankWraps $Diagram $width } else { $Diagram }
        if ($width -and $wrapped -eq $Diagram) { continue }
        foreach ($layout in $ViewLayouts.Keys) {
            $name = if ($width) { "$layout.$width" } else { $layout }
            $variants.Add([pscustomobject]@{ Name = $name; Layout = $layout; RankWidth = $width; Order = $variants.Count; Diagram = (Set-DiagramLayout $wrapped $layout) })
        }
    }
    return $variants
}

function Select-ReadableImage($Images) {
    return $Images | Sort-Object @{ Expression = 'Scale'; Descending = $true }, @{ Expression = { $_.Width * $_.Height } }, Order | Select-Object -First 1
}

# Tutte le varianti si disegnano con una sola JVM: chiave della vista -> disegno scelto.
function ConvertTo-ViewImages([hashtable]$Diagrams, [string]$Java) {
    $variants = @{}
    $sources = @{}
    foreach ($key in $Diagrams.Keys) {
        $variants[$key] = Get-DiagramVariants $Diagrams[$key]
        foreach ($variant in $variants[$key]) { $sources["$key.$($variant.Name)"] = $variant.Diagram }
    }
    $drawn = ConvertTo-PlantUmlPng $sources $Java
    $images = @{}
    foreach ($key in $Diagrams.Keys) {
        $images[$key] = Select-ReadableImage @($variants[$key] | ForEach-Object { New-ViewImage $drawn["$key.$($_.Name)"] $_ })
    }
    return $images
}

function Test-ViewReadable($Image) {
    return $Image.Scale -ge $ViewPage.MinScale
}

function Format-ViewMeasure($Image) {
    $ranks = if ($Image.RankWidth) { ", ranghi di $($Image.RankWidth)" } else { '' }
    return "$($Image.Width)x$($Image.Height) px in $($Image.Layout)$ranks, scala $($Image.Scale.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) (minima $($ViewPage.MinScale.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)))"
}
