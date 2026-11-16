# SPDX-License-Identifier: Apache-2.0

# pandoc per Arc42Document.ps1: si scarica alla prima esecuzione, alla versione e con l'SHA-256 fissati qui,
# in Agent.ToolsDirectory, che sopravvive alla pulizia del workspace. PANDOC_PATH indica un pandoc gia'
# presente ed evita lo scaricamento.

$PandocVersion = '3.14'
$PandocArchives = @{
    Linux   = @{ Name = "pandoc-$PandocVersion-linux-amd64.tar.gz"; Sha256 = 'C5F4720CDEFB3F7BDC5D07202EF579FEEF0D1370773C873804DD8FDAA8C4F1B8'; Executable = "pandoc-$PandocVersion/bin/pandoc" }
    Windows = @{ Name = "pandoc-$PandocVersion-windows-x86_64.zip"; Sha256 = '0144B96E8C7B023FD382EC5EF5BDC475E873F1019D6FA72502492DF2C9A94A3B'; Executable = "pandoc-$PandocVersion/pandoc.exe" }
}

function Get-PandocArchive {
    if ($IsWindows) { return $PandocArchives.Windows }
    if ($IsLinux) { return $PandocArchives.Linux }
    throw "pandoc ${PandocVersion}: sistema operativo non supportato, serve PANDOC_PATH"
}

function Get-Pandoc {
    if ($env:PANDOC_PATH) { return $env:PANDOC_PATH }

    $archive = Get-PandocArchive
    $toolsRoot = if ($env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY } else { [IO.Path]::GetTempPath() }
    $installDir = Join-Path $toolsRoot "pandoc/$PandocVersion"
    $executable = Join-Path $installDir $archive.Executable
    if (Test-Path $executable) { return $executable }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    $download = Join-Path $installDir $archive.Name
    $url = "https://github.com/jgm/pandoc/releases/download/$PandocVersion/$($archive.Name)"
    Write-Host "Download pandoc $PandocVersion da $url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing

    $actualHash = (Get-FileHash -Path $download -Algorithm SHA256).Hash
    if ($actualHash -ne $archive.Sha256) {
        Remove-Item -Force $download
        throw "Checksum di $($archive.Name) non valido: atteso $($archive.Sha256), ottenuto $actualHash"
    }
    if ($archive.Name.EndsWith('.zip')) { Expand-Archive -Path $download -DestinationPath $installDir -Force }
    else {
        tar -xzf $download -C $installDir
        if ($LASTEXITCODE -ne 0) { throw "estrazione di $($archive.Name) non riuscita" }
    }
    Remove-Item -Force $download
    return $executable
}

# Converte un file Markdown nel formato di uscita; gli argomenti in piu' (indice, numerazione, metadati)
# li sceglie il chiamante. SOURCE_DATE_EPOCH fissa le date che pandoc scrive nel file.
function Invoke-Pandoc([string]$InputPath, [string]$OutputPath, [string[]]$Arguments, [long]$SourceDateEpoch) {
    $pandoc = Get-Pandoc
    $previousEpoch = $env:SOURCE_DATE_EPOCH
    $env:SOURCE_DATE_EPOCH = "$SourceDateEpoch"
    try { $output = & $pandoc $InputPath -o $OutputPath @Arguments 2>&1 }
    finally { $env:SOURCE_DATE_EPOCH = $previousEpoch }
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0) { throw "pandoc non converte $([IO.Path]::GetFileName($InputPath)): $(@($output | ForEach-Object { "$_" }) -join ' ')" }
}
