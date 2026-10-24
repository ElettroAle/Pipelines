# Accesso alla Structurizr CLI per Test-ArchitectureDocs.ps1: valida il modello C4
# scritto in Structurizr DSL e lo esporta in JSON.

$StructurizrVersion = '2025.11.09'
# L'archivio e' unico per tutte le piattaforme: gira sulla JVM.
$StructurizrArchive = @{ Name = 'structurizr-cli.zip'; Sha256 = 'F5365A463FC44D539ED19BEC00C48BA1E1ECDA0CCFD1BA40D2E7472D264EB79A' }
# La CLI e' compilata per Java 17 (class file 61).
$StructurizrMinimumJava = 17

function Get-JavaMajorVersion([string]$Java) {
    if (-not (Test-Path $Java -PathType Leaf)) { return 0 }
    $versionLine = (& $Java -version 2>&1 | Select-Object -First 1) -as [string]
    $global:LASTEXITCODE = 0
    if ($versionLine -match 'version "(1\.)?(\d+)') { return [int]$Matches[2] }
    return 0
}

function Get-JavaCandidates {
    if ($env:STRUCTURIZR_JAVA) { return @($env:STRUCTURIZR_JAVA) }

    $executable = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'java.exe' } else { 'java' }
    $homes = @($env:JAVA_HOME_21_X64, $env:JAVA_HOME_17_X64, $env:JAVA_HOME) | Where-Object { $_ }
    $fromHomes = $homes | ForEach-Object { Join-Path $_ "bin/$executable" } | Where-Object { Test-Path $_ }
    $fromPath = Get-Command java -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    return @($fromHomes) + @($fromPath | Where-Object { $_ })
}

function Get-StructurizrJava {
    $java = Get-JavaCandidates | Where-Object { (Get-JavaMajorVersion $_) -ge $StructurizrMinimumJava } | Select-Object -First 1
    if (-not $java) { throw "Structurizr CLI $StructurizrVersion richiede Java $StructurizrMinimumJava o successivo: nessuno trovato in STRUCTURIZR_JAVA, JAVA_HOME_21_X64, JAVA_HOME_17_X64, JAVA_HOME o PATH" }
    return $java
}

function Get-StructurizrLibraries {
    if ($env:STRUCTURIZR_CLI_PATH) { return Join-Path $env:STRUCTURIZR_CLI_PATH 'lib' }

    $toolsRoot = if ($env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY } else { [IO.Path]::GetTempPath() }
    $installDir = Join-Path $toolsRoot "structurizr-cli/$StructurizrVersion"
    $libraries = Join-Path $installDir 'lib'
    if (Test-Path $libraries) { return $libraries }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    $archivePath = Join-Path $installDir $StructurizrArchive.Name
    $url = "https://github.com/structurizr/cli/releases/download/v$StructurizrVersion/$($StructurizrArchive.Name)"
    Write-Host "Download Structurizr CLI $StructurizrVersion da $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing

    $actualHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ne $StructurizrArchive.Sha256) {
        Remove-Item -Force $archivePath
        throw "Checksum di $($StructurizrArchive.Name) non valido: atteso $($StructurizrArchive.Sha256), ottenuto $actualHash"
    }

    Expand-Archive -Path $archivePath -DestinationPath $installDir -Force
    Remove-Item -Force $archivePath
    return $libraries
}

# Esporta il workspace in JSON; se il DSL non e' valido restituisce l'errore della CLI.
function Export-StructurizrWorkspace([string]$WorkspaceDsl) {
    $java = Get-StructurizrJava
    $classPath = Join-Path (Get-StructurizrLibraries) '*'
    $outputDir = Join-Path ([IO.Path]::GetTempPath()) "structurizr-$(New-Guid)"
    try {
        $output = & $java -cp $classPath com.structurizr.cli.StructurizrCliApplication export -workspace $WorkspaceDsl -format json -output $outputDir 2>&1
        $exitCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        $exported = Get-ChildItem -Path $outputDir -Filter '*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exitCode -ne 0 -or -not $exported) {
            $reason = @($output | ForEach-Object { "$_" } | Where-Object { $_ -match 'does not exist|error|Error|unexpected|expected' }) | Select-Object -Last 1
            if (-not $reason) { $reason = @($output | ForEach-Object { "$_" }) | Select-Object -Last 1 }
            return [pscustomobject]@{ Workspace = $null; Error = ($reason -replace '^[\w.]+Exception:\s*', '' -replace ' of .+?\.dsl', '') }
        }
        return [pscustomobject]@{ Workspace = (Get-Content -Raw $exported.FullName | ConvertFrom-Json); Error = $null }
    }
    finally {
        Remove-Item -Recurse -Force $outputDir -ErrorAction SilentlyContinue
    }
}
