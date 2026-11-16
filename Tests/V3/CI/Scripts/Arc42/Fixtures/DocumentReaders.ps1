# SPDX-License-Identifier: Apache-2.0

# Letture di un documento Word e di un PDF di Chrome come le vede chi li apre: titoli con il loro numero,
# indice, testo, link, immagini. Bastano le strutture che pandoc e Chrome scrivono, senza programmi esterni.

Add-Type -AssemblyName System.IO.Compression

function Get-ZipEntryBytes([IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    try {
        $buffer = [IO.MemoryStream]::new()
        $stream.CopyTo($buffer)
        return , $buffer.ToArray()
    }
    finally { $stream.Dispose() }
}

function Get-WordParagraphText([string]$Xml) {
    return (([regex]::Matches($Xml, '<w:t(?: [^>]*)?>([^<]*)</w:t>') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) }) -join '')
}

function Read-WordDocument([byte[]]$Bytes) {
    $zip = [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($Bytes))
    try {
        $xml = [Text.Encoding]::UTF8.GetString((Get-ZipEntryBytes $zip.GetEntry('word/document.xml')))
        $relations = [Text.Encoding]::UTF8.GetString((Get-ZipEntryBytes $zip.GetEntry('word/_rels/document.xml.rels')))
        $media = @($zip.Entries | Where-Object FullName -Like 'word/media/*' | ForEach-Object { , (Get-ZipEntryBytes $_) })
    }
    finally { $zip.Dispose() }

    $paragraphs = @([regex]::Matches($xml, '(?s)<w:p>.*?</w:p>') | ForEach-Object { $_.Value })
    $headings = foreach ($paragraph in $paragraphs) {
        if ($paragraph -notmatch '<w:pStyle w:val="Heading(\d)"') { continue }
        $level = [int]$Matches[1]
        $number = [regex]::Match($paragraph, '<w:rStyle w:val="SectionNumber" />(?:<w:lang [^>]*/>)?</w:rPr><w:t[^>]*>([^<]*)</w:t>').Groups[1].Value
        $text = Get-WordParagraphText $paragraph
        [pscustomobject]@{ Level = $level; Number = $number; Title = $text.Substring($number.Length) }
    }
    $targets = @{}
    foreach ($relation in [regex]::Matches($relations, '<Relationship [^>]*?/>')) {
        $id = [regex]::Match($relation.Value, 'Id="([^"]+)"').Groups[1].Value
        $targets[$id] = [Net.WebUtility]::HtmlDecode([regex]::Match($relation.Value, 'Target="([^"]+)"').Groups[1].Value)
    }
    $links = foreach ($link in [regex]::Matches($xml, '(?s)<w:hyperlink (r:id|w:anchor)="([^"]+)"[^>]*>(.*?)</w:hyperlink>')) {
        $target = if ($link.Groups[1].Value -eq 'r:id') { $targets[$link.Groups[2].Value] } else { "#$($link.Groups[2].Value)" }
        [pscustomobject]@{ Target = $target; Text = Get-WordParagraphText $link.Groups[3].Value }
    }
    return [pscustomobject]@{
        Text     = (@($paragraphs | ForEach-Object { Get-WordParagraphText $_ }) -join "`n")
        Headings = @($headings)
        Index    = $xml -match '<w:instrText[^>]*>TOC '
        Links    = @($links)
        Images   = $media
    }
}

function Expand-PdfStream([string]$Dictionary, [string]$Data) {
    $bytes = [Text.Encoding]::Latin1.GetBytes($Data)
    if ($Dictionary -notmatch '/FlateDecode') { return , $bytes }
    $inflater = [IO.Compression.ZLibStream]::new([IO.MemoryStream]::new($bytes), [IO.Compression.CompressionMode]::Decompress)
    try {
        $buffer = [IO.MemoryStream]::new()
        $inflater.CopyTo($buffer)
        return , $buffer.ToArray()
    }
    finally { $inflater.Dispose() }
}

function ConvertFrom-PdfString([string]$Literal) {
    if ($Literal -match '^<([0-9A-Fa-f]*)>$') {
        $hex = $Matches[1]
        $bytes = [byte[]]@(for ($i = 0; $i -lt $hex.Length; $i += 2) { [Convert]::ToByte($hex.Substring($i, 2), 16) })
        if ($bytes.Count -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Count - 2) }
        return [Text.Encoding]::Latin1.GetString($bytes)
    }
    $text = $Literal.Substring(1, $Literal.Length - 2) -replace '\\([()\\])', '$1'
    return $text
}

function Read-ToUnicodeMap([string]$CMap) {
    $map = @{}
    foreach ($block in [regex]::Matches($CMap, '(?s)beginbfchar(.*?)endbfchar')) {
        foreach ($pair in [regex]::Matches($block.Groups[1].Value, '<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')) {
            $map[[Convert]::ToInt32($pair.Groups[1].Value, 16)] = ConvertFrom-PdfString "<FEFF$($pair.Groups[2].Value)>"
        }
    }
    foreach ($block in [regex]::Matches($CMap, '(?s)beginbfrange(.*?)endbfrange')) {
        foreach ($range in [regex]::Matches($block.Groups[1].Value, '<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')) {
            $first = [Convert]::ToInt32($range.Groups[1].Value, 16)
            $start = [Convert]::ToInt32($range.Groups[3].Value, 16)
            for ($code = $first; $code -le [Convert]::ToInt32($range.Groups[2].Value, 16); $code++) { $map[$code] = [string][char]($start + $code - $first) }
        }
    }
    return $map
}

# Il testo di ogni pagina: i glifi delle stringhe esadecimali tradotti con la ToUnicode del font in uso.
function Read-PdfDocument([byte[]]$Bytes) {
    $raw = [Text.Encoding]::Latin1.GetString($Bytes)
    $objects = @{}
    foreach ($object in [regex]::Matches($raw, '(?s)(\d+) 0 obj\s*(.*?)\s*endobj')) {
        $body = $object.Groups[2].Value
        $stream = [regex]::Match($body, '(?s)^(.*?)stream\r?\n(.*)\r?\nendstream$')
        $objects[[int]$object.Groups[1].Value] = if ($stream.Success) {
            [pscustomobject]@{ Dictionary = $stream.Groups[1].Value; Stream = (Expand-PdfStream $stream.Groups[1].Value $stream.Groups[2].Value) }
        } else { [pscustomobject]@{ Dictionary = $body; Stream = $null } }
    }
    $maps = @{}
    $pages = foreach ($id in ($objects.Keys | Sort-Object)) {
        $page = $objects[$id].Dictionary
        if ($page -notmatch '/Type /Page\b(?!s)') { continue }
        $fonts = @{}
        foreach ($font in [regex]::Matches([regex]::Match($page, '(?s)/Font <<(.*?)>>').Groups[1].Value, '/(\w+) (\d+) 0 R')) {
            $fontId = [int]$font.Groups[2].Value
            if (-not $maps.ContainsKey($fontId)) {
                $toUnicode = [regex]::Match($objects[$fontId].Dictionary, '/ToUnicode (\d+) 0 R')
                $maps[$fontId] = if ($toUnicode.Success) { Read-ToUnicodeMap ([Text.Encoding]::Latin1.GetString($objects[[int]$toUnicode.Groups[1].Value].Stream)) } else { @{} }
            }
            $fonts[$font.Groups[1].Value] = $maps[$fontId]
        }
        $text = [Text.StringBuilder]::new()
        foreach ($content in [regex]::Matches($page, '/Contents (\d+) 0 R')) {
            $operations = [Text.Encoding]::Latin1.GetString($objects[[int]$content.Groups[1].Value].Stream)
            $current = @{}
            foreach ($token in [regex]::Matches($operations, '/(\w+)\s+[\d.]+\s+Tf|<([0-9A-Fa-f]*)>|\bET\b')) {
                if ($token.Groups[1].Success) { $current = if ($fonts.ContainsKey($token.Groups[1].Value)) { $fonts[$token.Groups[1].Value] } else { @{} } }
                elseif ($token.Groups[2].Success) {
                    $hex = $token.Groups[2].Value
                    for ($i = 0; $i + 4 -le $hex.Length; $i += 4) { [void]$text.Append($current[[Convert]::ToInt32($hex.Substring($i, 4), 16)]) }
                }
                else { [void]$text.Append(' ') }
            }
        }
        $text.ToString()
    }
    $images = foreach ($object in $objects.Values) {
        if ($object.Dictionary -notmatch '/Subtype /Image') { continue }
        [pscustomobject]@{
            Width  = [int][regex]::Match($object.Dictionary, '/Width (\d+)').Groups[1].Value
            Height = [int][regex]::Match($object.Dictionary, '/Height (\d+)').Groups[1].Value
            Hash   = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($object.Stream))
        }
    }
    return [pscustomobject]@{
        Text    = ($pages -join "`n")
        Outline = @([regex]::Matches($raw, '/Title (\((?:\\.|[^\\)])*\)|<[0-9A-Fa-f]*>)\s*/Dest') | ForEach-Object { ConvertFrom-PdfString $_.Groups[1].Value })
        Links   = @([regex]::Matches($raw, '/URI (\((?:\\.|[^\\)])*\))') | ForEach-Object { ConvertFrom-PdfString $_.Groups[1].Value })
        Images  = @($images)
    }
}

# Larghezza e altezza di un PNG stanno nell'intestazione IHDR, in big-endian dal sedicesimo byte.
function Get-PngDimensions([byte[]]$Png) {
    $read = { param($Offset) ([int]$Png[$Offset] -shl 24) -bor ([int]$Png[$Offset + 1] -shl 16) -bor ([int]$Png[$Offset + 2] -shl 8) -bor [int]$Png[$Offset + 3] }
    return [pscustomobject]@{ Width = & $read 16; Height = & $read 20 }
}
