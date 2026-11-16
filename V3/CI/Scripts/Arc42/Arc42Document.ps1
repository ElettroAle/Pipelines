# SPDX-License-Identifier: Apache-2.0

# Il documento unico che Publish-Arc42Wiki.ps1 allega alla wiki: le pagine della wiki, convertite da
# Convert-PageBody per il documento, una dopo l'altra, con le decisioni sotto la sezione che le raccoglie.
# pandoc ne fa il Word e l'HTML che Chrome headless stampa in PDF, con indice e sezioni numerate. Il
# documento si legge anche senza accedere ad Azure DevOps: i link fra le pagine diventano rimandi nel
# documento, quelli al repository e alle altre risorse di Azure DevOps testo.

. "$PSScriptRoot/../Pandoc/Pandoc.ps1"
. "$PSScriptRoot/../Browser/Browser.ps1"

$DocumentFormats = @('pdf', 'docx')
$AzureDevOpsLinkPattern = '^https?://(?:[\w-]+\.)*(?:dev\.azure\.com|visualstudio\.com)(?:[:/?#]|$)'
$AutolinkPattern = '<(https?://[^>\s]+)>'
# Il Markdown del documento e' quello della wiki: niente formule fra dollari, LaTeX, citazioni con la
# chiocciola o blocchi YAML, e un'immagine da sola resta un'immagine, senza didascalia.
$PandocReader = 'markdown-tex_math_dollars-raw_tex-citations-yaml_metadata_block-implicit_figures'
# Chrome non conosce la densita' dei PNG: le immagini restano entro la pagina, e i diagrammi Mermaid,
# disegnati al doppio dei pixel, hanno in Word la loro misura con --dpi=192.
$DocumentStyle = @'
@page { size: A4; margin: 2cm 1.8cm; }
body { font-family: "DejaVu Sans", "Segoe UI", Arial, sans-serif; font-size: 10.5pt; line-height: 1.45; max-width: none; margin: 0; padding: 0; }
img { max-width: 100%; max-height: 24cm; }
table { border-collapse: collapse; }
th, td { border: 1px solid #999; padding: 3px 6px; vertical-align: top; }
pre { white-space: pre-wrap; }
h1 { break-before: page; }
#TOC { break-after: page; }
'@

function Get-DocumentFormats([string]$Value) {
    $formats = @($Value -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    $unknown = @($formats | Where-Object { $_ -notin $DocumentFormats })
    if ($unknown) { throw "formato del documento non supportato: $($unknown -join ', ') (ammessi: $($DocumentFormats -join ', '))" }
    return $formats
}

function Get-DocumentAnchor($Page) {
    return 'doc-' + ([IO.Path]::GetFileNameWithoutExtension($Page.Source).ToLowerInvariant() -replace '[^a-z0-9_-]', '-')
}

function Get-DocumentViewFile([string]$View) {
    return "view-$View.png"
}

function Add-DocumentDiagram($Document, [Collections.Generic.List[string]]$Lines) {
    $id = "mermaid-$($Document.Diagrams.Count + 1)"
    $Document.Diagrams.Add([pscustomobject]@{ Id = $id; Text = ($Lines -join "`n") })
    return "![]($id.png)"
}

function Convert-DocumentLink($Page, [string]$Label, [string]$Target, [hashtable]$PagesBySource) {
    if ($Target.StartsWith('#')) { return "[$Label]($Target)" }
    if ($Target -match $ExternalLinkPattern) {
        if ($Target -match $AzureDevOpsLinkPattern) { return $Label }
        return "[$Label]($Target)"
    }
    $source = Resolve-LinkSource $Page $Target
    if ($source -and $PagesBySource.ContainsKey($source)) { return "[$Label](#$(Get-DocumentAnchor $PagesBySource[$source]))" }
    return $Label
}

function Convert-DocumentLinks([string]$Line, $Page, [hashtable]$PagesBySource) {
    $line = [regex]::Replace($Line, $AutolinkPattern, { param($match) if ($match.Groups[1].Value -match $AzureDevOpsLinkPattern) { $match.Groups[1].Value } else { $match.Value } })
    return [regex]::Replace($line, '(?<!!)\[([^\]]*)\]\(([^)\s]+)\)', { param($match) Convert-DocumentLink $Page $match.Groups[1].Value $match.Groups[2].Value $PagesBySource })
}

function Move-Headings([string]$Body, [int]$Shift) {
    if ($Shift -le 0) { return $Body }
    $fence = $false
    $lines = foreach ($line in ($Body -split "`n")) {
        if ($line -match $FencePattern) { $fence = -not $fence }
        if (-not $fence -and $line -match '^(#{1,6})(\s.*)$') { ('#' * [math]::Min(6, $Matches[1].Length + $Shift)) + $Matches[2] }
        else { $line }
    }
    return $lines -join "`n"
}

# Ogni pagina e' un titolo del livello della sua profondita', con il suo corpo spostato sotto il titolo.
function ConvertTo-DocumentMarkdown($Pages, [hashtable]$Contents, [int]$Level = 1) {
    $parts = foreach ($page in $Pages) {
        "$('#' * $Level) $($page.Title) {#$(Get-DocumentAnchor $page)}`n`n$(Move-Headings $Contents[$page.Source] ($Level - 1))"
        if ($page.Children.Count) { ConvertTo-DocumentMarkdown $page.Children $Contents ($Level + 1) }
    }
    return ($parts -join "`n`n")
}

function Get-SourceDateEpoch {
    $epoch = git log -1 --format=%ct 2>$null
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -eq 0 -and "$epoch" -match '^\d+$') { return [long]"$epoch" }
    return 0
}

function New-Arc42Document($Pages, [hashtable]$PagesBySource, $Views, [hashtable]$ViewImages, [string[]]$Formats) {
    $document = [pscustomobject]@{ Diagrams = [Collections.Generic.List[object]]::new() }
    $contents = @{}
    foreach ($page in (Get-AllPages $Pages)) { $contents[$page.Source] = Convert-PageBody $page $PagesBySource $Views @{} $document }

    $workDir = Join-Path ([IO.Path]::GetTempPath()) "arc42-document-$(New-Guid)"
    New-Item -ItemType Directory -Path $workDir | Out-Null
    try {
        foreach ($view in $ViewImages.Keys) { [IO.File]::WriteAllBytes((Join-Path $workDir (Get-DocumentViewFile $view)), $ViewImages[$view]) }
        $diagrams = ConvertTo-MermaidPng $document.Diagrams.ToArray()
        foreach ($id in $diagrams.Keys) { [IO.File]::WriteAllBytes((Join-Path $workDir "$id.png"), $diagrams[$id]) }
        $markdownPath = Join-Path $workDir 'document.md'
        [IO.File]::WriteAllText($markdownPath, (ConvertTo-DocumentMarkdown $Pages $contents) + "`n")
        [IO.File]::WriteAllText((Join-Path $workDir 'document.css'), $DocumentStyle)

        $epoch = Get-SourceDateEpoch
        $common = @(
            "--from=$PandocReader", '--toc', '--toc-depth=2', '--number-sections', "--resource-path=$workDir",
            "--metadata=title:$wikiRoot", "--metadata=subtitle:$($DocumentLanguage.DocumentVersion -f $sourceVersion)",
            "--metadata=lang:$($DocumentLanguage.DocumentLang)", "--metadata=toc-title:$($DocumentLanguage.TableOfContents)")
        $name = ConvertTo-WikiName $wikiRoot
        $files = [ordered]@{}
        foreach ($format in $Formats) {
            if ($format -eq 'docx') {
                $docx = Join-Path $workDir 'document.docx'
                Invoke-Pandoc $markdownPath $docx ($common + '--dpi=192') $epoch
                $files["$name.docx"] = [IO.File]::ReadAllBytes($docx)
            }
            else {
                $html = Join-Path $workDir 'document.html'
                Invoke-Pandoc $markdownPath $html ($common + @('--to=html5', '--standalone', '--embed-resources', "--css=$(Join-Path $workDir 'document.css')")) $epoch
                $files["$name.pdf"] = ConvertTo-PdfFromHtml $html ([DateTimeOffset]::FromUnixTimeSeconds($epoch))
            }
        }
        Write-Host "Documento: $(@($files.Keys) -join ', ') con $($ViewImages.Count) viste C4 e $($document.Diagrams.Count) diagrammi Mermaid"
        return $files
    }
    finally {
        Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    }
}
