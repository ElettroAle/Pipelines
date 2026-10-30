# SPDX-License-Identifier: Apache-2.0

# Accesso al parser Mermaid per Test-MermaidDiagrams.ps1 e Test-DiagramFlows.ps1: le dipendenze sono fissate
# da Parser/package-lock.json e installate con npm ci in una cache per lockfile.

$MermaidCheckerSource = Join-Path $PSScriptRoot 'Parser'

function Get-MermaidCheckerDirectory {
    $lockFile = Join-Path $MermaidCheckerSource 'package-lock.json'
    $lockHash = (Get-FileHash -Path $lockFile -Algorithm SHA256).Hash.Substring(0, 12)
    $toolsRoot = if ($env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY } else { [IO.Path]::GetTempPath() }
    $installDir = Join-Path $toolsRoot "architecture-docs-mermaid/$lockHash"

    if (-not (Test-Path (Join-Path $installDir 'node_modules/mermaid'))) {
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        Copy-Item -Path (Join-Path $MermaidCheckerSource 'package.json'), $lockFile -Destination $installDir -Force
        Push-Location $installDir
        try {
            $output = & npm ci --omit=dev --no-audit --no-fund 2>&1
            if ($LASTEXITCODE -ne 0) { throw "npm ci del parser Mermaid terminato con exit code ${LASTEXITCODE}: $($output -join "`n")" }
        }
        finally {
            Pop-Location
        }
    }
    Copy-Item -Path (Join-Path $MermaidCheckerSource 'check-diagrams.mjs') -Destination $installDir -Force
    return $installDir
}

# Ogni diagramma { Id, Text } torna con error/line se non valido, altrimenti con il tipo e,
# secondo il tipo, partecipanti e chiamate o classi.
function Invoke-MermaidParser([object[]]$Diagrams) {
    if (-not $Diagrams) { return @() }

    $checkerDir = Get-MermaidCheckerDirectory
    $workDir = Join-Path ([IO.Path]::GetTempPath()) "mermaid-$(New-Guid)"
    New-Item -ItemType Directory -Path $workDir | Out-Null
    try {
        $inputPath = Join-Path $workDir 'diagrams.json'
        $outputPath = Join-Path $workDir 'results.json'
        $payload = @($Diagrams | ForEach-Object { @{ id = $_.Id; text = $_.Text } })
        [IO.File]::WriteAllText($inputPath, (ConvertTo-Json -InputObject $payload -Depth 4))
        $output = & node (Join-Path $checkerDir 'check-diagrams.mjs') $inputPath $outputPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Parser Mermaid terminato con exit code ${LASTEXITCODE}: $($output -join "`n")" }
        $global:LASTEXITCODE = 0
        return @(Get-Content -Raw $outputPath | ConvertFrom-Json)
    }
    finally {
        Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    }
}
