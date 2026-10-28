# SPDX-License-Identifier: Apache-2.0

# Disegna diagrammi PlantUML in PNG per Publish-Arc42Wiki.ps1. Le librerie C4 sono quelle interne di
# PlantUML, e il layout smetana e' compreso nel jar: non servono Graphviz ne' la rete.

$PlantUmlVersion = '1.2026.8'
$PlantUmlJar = @{ Name = "plantuml-$PlantUmlVersion.jar"; Sha256 = '5E1ECFA8ECD32C90B03BBF3B1EB6F020943F98AB0FCF4032BE31A0002EE2C462' }

function Get-PlantUmlJar {
    if ($env:PLANTUML_JAR) { return $env:PLANTUML_JAR }

    $toolsRoot = if ($env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY } else { [IO.Path]::GetTempPath() }
    $installDir = Join-Path $toolsRoot "plantuml/$PlantUmlVersion"
    $jar = Join-Path $installDir $PlantUmlJar.Name
    if (Test-Path $jar) { return $jar }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    $download = "$jar.download"
    $url = "https://github.com/plantuml/plantuml/releases/download/v$PlantUmlVersion/$($PlantUmlJar.Name)"
    Write-Host "Download PlantUML $PlantUmlVersion da $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing

    $actualHash = (Get-FileHash -Path $download -Algorithm SHA256).Hash
    if ($actualHash -ne $PlantUmlJar.Sha256) {
        Remove-Item -Force $download
        throw "Checksum di $($PlantUmlJar.Name) non valido: atteso $($PlantUmlJar.Sha256), ottenuto $actualHash"
    }
    Move-Item -Path $download -Destination $jar
    return $jar
}

# Disegna ogni diagramma (chiave -> sorgente PlantUML) con una sola JVM: chiave -> byte del PNG.
function ConvertTo-PlantUmlPng([hashtable]$Diagrams, [string]$Java) {
    $jar = Get-PlantUmlJar
    $workDir = Join-Path ([IO.Path]::GetTempPath()) "plantuml-$(New-Guid)"
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    try {
        foreach ($key in $Diagrams.Keys) { [IO.File]::WriteAllText((Join-Path $workDir "$key.puml"), $Diagrams[$key]) }
        # Smetana anche dove Graphviz c'e': lo stesso modello da' lo stesso disegno su ogni agent.
        $output = & $Java '-Djava.awt.headless=true' -jar $jar -tpng '-Playout=smetana' -charset UTF-8 (Join-Path $workDir '*.puml') 2>&1
        $exitCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($exitCode -ne 0) { throw "PlantUML non disegna i diagrammi: $(@($output | ForEach-Object { "$_" }) -join ' ')" }
        $images = @{}
        foreach ($key in $Diagrams.Keys) {
            $png = Join-Path $workDir "$key.png"
            if (-not (Test-Path $png)) { throw "PlantUML non ha disegnato $key" }
            $images[$key] = [IO.File]::ReadAllBytes($png)
        }
        return $images
    }
    finally {
        Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
    }
}
