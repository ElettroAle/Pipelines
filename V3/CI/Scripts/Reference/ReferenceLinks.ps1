# SPDX-License-Identifier: Apache-2.0

# Collegamento dal testo di una pagina della wiki alla reference: la prima menzione di ogni voce
# dell'indice (modulo, API, task) diventa un link alla sua pagina. Titoli, blocchi di codice, link,
# immagini e tag restano come sono; un codice in linea diventa link solo se contiene esattamente il nome.
# Una voce gia' collegata nella pagina non riceve un secondo link, quindi applicare il collegamento due
# volte non cambia la pagina.

$ReferenceFencePattern = '^\s*(```|~~~|:::)'
$ReferenceHeadingPattern = '^\s{0,3}#{1,6}\s'
$ReferenceProtectedSpanPattern = '(!?\[[^\]]*\]\([^)]*\)|`[^`]+`|<[^>\r\n]+>|https?://[^\s)>\]]+)'
$ReferenceNameStart = '(?<![\p{L}\p{N}_:/.\-])'
$ReferenceNameEnd = '(?![\p{L}\p{N}_:/\-]|\.[\p{L}\p{N}])'

function Read-ReferenceIndex([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $index = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    return @($index.entries | Where-Object { $_.name -and $_.url })
}

function Get-ReferenceNamePattern([object[]]$Entries) {
    $names = @($Entries | ForEach-Object { [regex]::Escape($_.name) } | Sort-Object Length -Descending)
    return [regex]::new($ReferenceNameStart + '(?:' + ($names -join '|') + ')' + $ReferenceNameEnd)
}

function Add-ReferenceLinksToText([string]$Text, [regex]$Pattern, [hashtable]$UrlByName, [hashtable]$Linked) {
    return $Pattern.Replace($Text, [Text.RegularExpressions.MatchEvaluator] {
            param($match)
            if ($Linked.ContainsKey($match.Value)) { return $match.Value }
            $Linked[$match.Value] = $true
            return "[$($match.Value)]($($UrlByName[$match.Value]))"
        })
}

function Add-ReferenceLinksToLine([string]$Line, [regex]$Pattern, [hashtable]$UrlByName, [hashtable]$Linked) {
    $parts = [regex]::Split($Line, $ReferenceProtectedSpanPattern)
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i % 2 -eq 0) {
            $parts[$i] = Add-ReferenceLinksToText $parts[$i] $Pattern $UrlByName $Linked
            continue
        }
        $code = [regex]::Match($parts[$i], '^`([^`]+)`$')
        if ($code.Success -and $UrlByName.ContainsKey($code.Groups[1].Value) -and -not $Linked.ContainsKey($code.Groups[1].Value)) {
            $Linked[$code.Groups[1].Value] = $true
            $parts[$i] = "[$($parts[$i])]($($UrlByName[$code.Groups[1].Value]))"
        }
    }
    return $parts -join ''
}

function Add-ReferenceLinks([string]$Markdown, [object[]]$Entries) {
    if (-not $Entries -or -not $Markdown) { return $Markdown }
    $urlByName = @{}
    foreach ($entry in $Entries) { if (-not $urlByName.ContainsKey($entry.name)) { $urlByName[$entry.name] = $entry.url } }
    $linked = @{}
    foreach ($name in $urlByName.Keys) {
        if ($Markdown.Contains("]($($urlByName[$name]))")) { $linked[$name] = $true }
    }
    $pattern = Get-ReferenceNamePattern $Entries
    $inFence = $false
    $lines = $Markdown -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $ReferenceFencePattern) { $inFence = -not $inFence; continue }
        if ($inFence -or $lines[$i] -match $ReferenceHeadingPattern) { continue }
        $lines[$i] = Add-ReferenceLinksToLine $lines[$i] $pattern $urlByName $linked
    }
    return $lines -join "`n"
}
