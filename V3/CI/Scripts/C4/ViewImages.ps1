# SPDX-License-Identifier: Apache-2.0

# Disegna le viste C4 esportate in C4-PlantUML nel modo che si legge meglio. Ogni vista si disegna
# dall'alto in basso e da sinistra a destra, ciascuna con gli spazi di default e con spazi stretti, e
# resta il disegno che, adattato alla pagina, si rimpicciolisce meno: la direzione scritta nel modello
# e' solo il punto di partenza. La pagina misura C4_PAGE_WIDTH per C4_PAGE_HEIGHT pixel; sotto
# C4_MIN_SCALE il disegno scelto e' il meno peggio, e lo si segnala senza fermare nulla.

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

function Set-DiagramLayout([string]$Diagram, [string]$Layout) {
    $lines = (@($ViewLayouts[$Layout].Direction, $ViewLayouts[$Layout].Spacing) | Where-Object { $_ }) -join "`n"
    if ($Diagram -match $DirectionLinePattern) { return [regex]::new($DirectionLinePattern).Replace($Diagram, $lines.Replace('$', '$$'), 1) }
    return [regex]::new('(?m)^@startuml.*$').Replace($Diagram, "`$0`n$lines", 1)
}

# Larghezza e altezza stanno nell'intestazione IHDR del PNG, in big-endian dal sedicesimo byte.
function Get-PngSize([byte[]]$Png) {
    $read = { param($Offset) ([int]$Png[$Offset] -shl 24) -bor ([int]$Png[$Offset + 1] -shl 16) -bor ([int]$Png[$Offset + 2] -shl 8) -bor [int]$Png[$Offset + 3] }
    return [pscustomobject]@{ Width = & $read 16; Height = & $read 20 }
}

function Get-PageScale($Size) {
    return [math]::Min(1.0, [math]::Min($ViewPage.Width / $Size.Width, $ViewPage.Height / $Size.Height))
}

function New-ViewImage([byte[]]$Png, [string]$Layout) {
    $size = Get-PngSize $Png
    return [pscustomobject]@{ Png = $Png; Layout = $Layout; Order = @($ViewLayouts.Keys).IndexOf($Layout); Width = $size.Width; Height = $size.Height; Scale = (Get-PageScale $size) }
}

function Select-ReadableImage($Images) {
    return $Images | Sort-Object @{ Expression = 'Scale'; Descending = $true }, @{ Expression = { $_.Width * $_.Height } }, Order | Select-Object -First 1
}

# Tutte le varianti si disegnano con una sola JVM: chiave della vista -> disegno scelto.
function ConvertTo-ViewImages([hashtable]$Diagrams, [string]$Java) {
    $variants = @{}
    foreach ($key in $Diagrams.Keys) {
        foreach ($layout in $ViewLayouts.Keys) { $variants["$key.$layout"] = Set-DiagramLayout $Diagrams[$key] $layout }
    }
    $drawn = ConvertTo-PlantUmlPng $variants $Java
    $images = @{}
    foreach ($key in $Diagrams.Keys) {
        $images[$key] = Select-ReadableImage @($ViewLayouts.Keys | ForEach-Object { New-ViewImage $drawn["$key.$_"] $_ })
    }
    return $images
}

function Test-ViewReadable($Image) {
    return $Image.Scale -ge $ViewPage.MinScale
}

function Format-ViewMeasure($Image) {
    return "$($Image.Width)x$($Image.Height) px in $($Image.Layout), scala $($Image.Scale.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) (minima $($ViewPage.MinScale.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)))"
}
