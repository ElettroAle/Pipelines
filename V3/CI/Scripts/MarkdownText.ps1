# Lettura di una sezione Markdown della documentazione architetturale e misure di
# leggibilita' del suo testo, per Test-ArchitectureDocs.ps1.

$ViewMarkerPattern = '^\s*<!--\s*vista:\s*([\w-]+)\s*-->\s*$'
$CommentPattern = '^\s*<!--.*-->\s*$'
$HeadingPattern = '^(#{1,6})\s+(.+?)\s*#*\s*$'
$FencePattern = '^\s*```\s*([\w-]*)'
$QuotePattern = '^\s*>\s?(.*)$'
$TableSeparatorPattern = '^\s*\|[\s:|-]+\|\s*$'
$TablePattern = '^\s*\|(.*)$'
$ListItemPattern = '^\s*(?:[-*+]|\d+\.)\s+(.*)$'
$WordPattern = '[\p{L}\p{N}]+'

function ConvertTo-PlainText([string]$Markdown) {
    $text = $Markdown -replace '!\[[^\]]*\]\([^)]*\)', ''
    $text = $text -replace '\[([^\]]*)\]\([^)]*\)', '$1'
    $text = $text -replace '`([^`]*)`', '$1'
    $text = $text -replace '\*\*|__', ''
    $text = $text -replace '(?<![\p{L}\p{N}])[*_](?=\S)|(?<=\S)[*_](?![\p{L}\p{N}])', ''
    return ($text -replace '\s+', ' ').Trim()
}

function ConvertTo-HeadingAnchor([string]$Heading) {
    $text = (ConvertTo-PlainText $Heading).ToLowerInvariant() -replace '[^\p{L}\p{N}\s-]', ''
    return ($text.Trim() -replace '\s+', '-')
}

function Get-Sentences([string]$Text, [string[]]$Abbreviations) {
    $protected = $Text
    foreach ($abbreviation in $Abbreviations) {
        $pattern = '(?i)(?<![\p{L}\p{N}])' + [regex]::Escape($abbreviation)
        $protected = [regex]::Replace($protected, $pattern, { param($m) $m.Value.Replace('.', [char]0) })
    }
    return @($protected -split '(?<=[.!?])\s+' | ForEach-Object { $_.Replace([string][char]0, '.').Trim() } | Where-Object { $_ })
}

function Get-WordCount([string]$Text) {
    return [regex]::Matches($Text, $WordPattern).Count
}

function Get-GulpeaseIndex([string[]]$Blocks, [string[]]$Abbreviations) {
    $sentences = @($Blocks | ForEach-Object { Get-Sentences $_ $Abbreviations })
    $text = $Blocks -join ' '
    $words = Get-WordCount $text
    if ($words -eq 0) { return $null }
    $letters = [regex]::Matches($text, '\p{L}').Count
    return [int][math]::Round(89 + (300 * $sentences.Count - 10 * $letters) / $words)
}

function New-Block([string]$Kind, [int]$Line, [string]$Raw) {
    $plain = if ($Kind -eq 'table') { ConvertTo-PlainText ($Raw -replace '\|', ' ') } else { ConvertTo-PlainText $Raw }
    return [pscustomobject]@{ Kind = $Kind; Line = $Line; Raw = $Raw; Text = $plain }
}

# Una sezione: titolo (H1), parti (H2), blocchi di testo con la riga iniziale, marcatori
# di vista, diagrammi Mermaid con la riga del recinto di apertura, ancore dei titoli.
function ConvertFrom-MarkdownSection([string]$Content) {
    $section = [pscustomobject]@{ Title = $null; Parts = @(); Blocks = @(); Views = @(); Diagrams = @(); Anchors = @() }
    $current = $null
    $fence = $null
    $lineNumber = 0

    $flush = {
        if ($current) { $section.Blocks += New-Block $current.Kind $current.Line ($current.Lines -join ' ') }
        $current = $null
    }

    foreach ($line in ($Content -split "`r?`n")) {
        $lineNumber++
        if ($fence) {
            if ($line -match '^\s*```\s*$') {
                if ($fence.Language -eq 'mermaid') { $section.Diagrams += [pscustomobject]@{ Line = $fence.Line; Text = ($fence.Lines -join "`n") } }
                $fence = $null
            }
            else { $fence.Lines += $line }
            continue
        }

        if ($line -match $FencePattern) {
            . $flush
            $fence = @{ Language = $Matches[1].ToLowerInvariant(); Line = $lineNumber; Lines = @() }
        }
        elseif ($line -match $ViewMarkerPattern) {
            . $flush
            $section.Views += $Matches[1]
        }
        elseif ($line -match $CommentPattern -or $line -match $TableSeparatorPattern) {
            . $flush
        }
        elseif ($line -match $HeadingPattern) {
            . $flush
            $level = $Matches[1].Length
            $heading = $Matches[2]
            if ($level -eq 1 -and -not $section.Title) { $section.Title = ConvertTo-PlainText $heading }
            if ($level -eq 2) { $section.Parts += ConvertTo-PlainText $heading }
            $section.Anchors += ConvertTo-HeadingAnchor $heading
        }
        elseif ($line -match $QuotePattern) {
            $kind = if ($section.Parts.Count -eq 0) { 'opening' } else { 'quote' }
            if (-not $current -or $current.Kind -ne $kind) { . $flush; $current = @{ Kind = $kind; Line = $lineNumber; Lines = @() } }
            $current.Lines += $Matches[1]
        }
        elseif ($line -match $TablePattern) {
            . $flush
            $section.Blocks += New-Block 'table' $lineNumber $line
        }
        elseif ($line -match $ListItemPattern) {
            . $flush
            $current = @{ Kind = 'list'; Line = $lineNumber; Lines = @($Matches[1]) }
        }
        elseif (-not $line.Trim()) {
            . $flush
        }
        else {
            if (-not $current -or $current.Kind -notin @('paragraph', 'list')) { . $flush; $current = @{ Kind = 'paragraph'; Line = $lineNumber; Lines = @() } }
            $current.Lines += $line.Trim()
        }
    }
    . $flush
    return $section
}
