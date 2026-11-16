# SPDX-License-Identifier: Apache-2.0

# Chrome headless per Arc42Document.ps1: disegna i diagrammi Mermaid in PNG con mermaid-cli e stampa
# l'HTML del documento in PDF. mermaid-cli, puppeteer e la versione di Chrome sono fissati da
# Renderer/package-lock.json, installati con npm ci in una cache per lockfile; Chrome si scarica una
# volta nella stessa cache, solo nella variante headless.

$BrowserRendererSource = Join-Path $PSScriptRoot 'Renderer'

function Get-BrowserRendererDirectory {
    $lockFile = Join-Path $BrowserRendererSource 'package-lock.json'
    $lockHash = (Get-FileHash -Path $lockFile -Algorithm SHA256).Hash.Substring(0, 12)
    $toolsRoot = if ($env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY } else { [IO.Path]::GetTempPath() }
    $installDir = Join-Path $toolsRoot "architecture-docs-browser/$lockHash"
    $env:PUPPETEER_CACHE_DIR = Join-Path $installDir 'browsers'
    $installed = Join-Path $installDir 'installed'

    # Chrome si scarica con il comando di puppeteer e non con il suo script di installazione, che npm
    # recenti non eseguono senza un'approvazione; il segno di fine dice che anche Chrome e' completo.
    if (-not (Test-Path $installed)) {
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        Copy-Item -Path (Join-Path $BrowserRendererSource 'package.json'), $lockFile -Destination $installDir -Force
        Push-Location $installDir
        try {
            $output = & npm ci --omit=dev --ignore-scripts --no-audit --no-fund 2>&1
            if ($LASTEXITCODE -ne 0) { throw "npm ci di Chrome headless terminato con exit code ${LASTEXITCODE}: $($output -join "`n")" }
            $output = & npx --no-install puppeteer browsers install chrome-headless-shell 2>&1
            if ($LASTEXITCODE -ne 0) { throw "download di Chrome headless terminato con exit code ${LASTEXITCODE}: $($output -join "`n")" }
            [IO.File]::WriteAllText($installed, '')
        }
        finally {
            Pop-Location
        }
    }
    Copy-Item -Path (Join-Path $BrowserRendererSource 'render.mjs') -Destination $installDir -Force
    return $installDir
}

function Invoke-BrowserRenderer([string]$Command, [string]$InputPath, [string]$OutputPath) {
    $rendererDir = Get-BrowserRendererDirectory
    $output = & node (Join-Path $rendererDir 'render.mjs') $Command $InputPath $OutputPath 2>&1
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0) { throw "Chrome headless non completa ${Command}: $(@($output | ForEach-Object { "$_" }) -join ' ')" }
}

# Ogni diagramma { Id, Text } diventa un PNG: id -> byte del PNG.
function ConvertTo-MermaidPng([object[]]$Diagrams) {
    if (-not $Diagrams) { return @{} }
    $workDir = Join-Path ([IO.Path]::GetTempPath()) "mermaid-png-$(New-Guid)"
    New-Item -ItemType Directory -Path $workDir | Out-Null
    try {
        $inputPath = Join-Path $workDir 'diagrams.json'
        $payload = @($Diagrams | ForEach-Object { @{ id = $_.Id; text = $_.Text } })
        [IO.File]::WriteAllText($inputPath, (ConvertTo-Json -InputObject $payload -Depth 4))
        Invoke-BrowserRenderer 'diagrams' $inputPath $workDir
        $images = @{}
        foreach ($diagram in $Diagrams) { $images[$diagram.Id] = [IO.File]::ReadAllBytes((Join-Path $workDir "$($diagram.Id).png")) }
        return $images
    }
    finally {
        Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    }
}

# Chrome scrive nel PDF l'ora della stampa: la data della fonte la sostituisce con una stringa della stessa
# lunghezza, cosi' i riferimenti incrociati restano validi e la stessa fonte da' lo stesso file.
function ConvertTo-PdfFromHtml([string]$HtmlPath, [DateTimeOffset]$Date) {
    $pdfPath = [IO.Path]::ChangeExtension($HtmlPath, '.pdf')
    Invoke-BrowserRenderer 'pdf' $HtmlPath $pdfPath
    $latin1 = [Text.Encoding]::Latin1
    $text = $latin1.GetString([IO.File]::ReadAllBytes($pdfPath))
    $stamp = "D:$($Date.UtcDateTime.ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture))+00'00'"
    $text = [regex]::Replace($text, "/(CreationDate|ModDate) \(D:\d{14}[+\-Z]\d{2}'\d{2}'\)", { param($match) "/$($match.Groups[1].Value) ($stamp)" })
    return $latin1.GetBytes($text)
}
