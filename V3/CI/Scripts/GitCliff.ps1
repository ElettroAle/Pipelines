# Accesso a git-cliff condiviso da Set-Versioning.ps1, Verify-SemVer.ps1 e
# New-ReleaseNotes.ps1. Compatibile con Windows PowerShell 5.1: PowerShell@2 senza
# pwsh gira su powershell.exe negli agent Windows.

$GitCliffVersion = '2.14.2'
# SHA-256 calcolati sugli archivi della release: la release pubblica checksum solo
# per Linux, e fissarli qui vale per entrambe le piattaforme.
$GitCliffArchives = @{
    'Windows' = @{ Name = "git-cliff-$GitCliffVersion-x86_64-pc-windows-msvc.zip"; Sha256 = '6ECE2112B3F4AF462190ECBEA4AEB1315FFF6AF415629B597F84319073C31131'; Exe = 'git-cliff.exe' }
    'Linux'   = @{ Name = "git-cliff-$GitCliffVersion-x86_64-unknown-linux-gnu.tar.gz"; Sha256 = '24F397C733ADD5390FDCEEE3A2088588AB0D5F944CE00D34CB7029B888CF2DB4'; Exe = 'git-cliff' }
}
$GitCliffConfig = Join-Path $PSScriptRoot 'cliff.toml'
$UnclassifiedCommitGroup = '<!-- 9 -->Altre modifiche'

function Get-GitCliffPlatform {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return 'Windows' }
    return 'Linux'
}

function Get-GitCliffPath {
    if ($env:GIT_CLIFF_PATH) { return $env:GIT_CLIFF_PATH }

    $archive = $GitCliffArchives[(Get-GitCliffPlatform)]
    $toolsRoot = if ($env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY } else { [IO.Path]::GetTempPath() }
    $installDir = Join-Path $toolsRoot "git-cliff/$GitCliffVersion"
    $exePath = Join-Path $installDir "git-cliff-$GitCliffVersion/$($archive.Exe)"
    if (Test-Path $exePath) { return $exePath }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    $archivePath = Join-Path $installDir $archive.Name
    $url = "https://github.com/orhun/git-cliff/releases/download/v$GitCliffVersion/$($archive.Name)"
    Write-Host "Download git-cliff $GitCliffVersion da $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing

    $actualHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ne $archive.Sha256) {
        Remove-Item -Force $archivePath
        throw "Checksum di $($archive.Name) non valido: atteso $($archive.Sha256), ottenuto $actualHash"
    }

    if ($archive.Name.EndsWith('.zip')) {
        Expand-Archive -Path $archivePath -DestinationPath $installDir -Force
    }
    else {
        tar -xzf $archivePath -C $installDir
        chmod +x $exePath
    }
    Remove-Item -Force $archivePath
    return $exePath
}

function Invoke-GitCliff {
    param([string[]]$Arguments)

    $exe = Get-GitCliffPath
    $previousLogLevel = $env:RUST_LOG
    $env:RUST_LOG = 'error'
    try {
        $output = & $exe --config $GitCliffConfig --use-branch-tags @Arguments
        if ($LASTEXITCODE -ne 0) { throw "git-cliff $($Arguments -join ' ') terminato con exit code $LASTEXITCODE" }
        return ($output -join "`n")
    }
    finally {
        $env:RUST_LOG = $previousLogLevel
    }
}

# Prossima versione di rilascio dall'ultimo tag raggiungibile, senza prefisso 'v'.
function Get-NextReleaseVersion {
    return (Invoke-GitCliff @('--bumped-version')).Trim().TrimStart('v')
}

# Commit del range che non rientrano in alcun tipo ammesso da cliff.toml.
function Get-UnclassifiedCommitMessages {
    param([string]$Range)

    $releases = Invoke-GitCliff @($Range, '--context') | ConvertFrom-Json
    return @($releases | ForEach-Object { $_.commits } |
        Where-Object { $_ -and $_.group -eq $UnclassifiedCommitGroup } |
        ForEach-Object { $_.raw_message.Split("`n")[0].Trim() })
}

function Get-ReleaseNotesMarkdown {
    param([string]$Range, [string]$Tag)

    $arguments = @()
    if ($Range) { $arguments += $Range }
    if ($Tag) { $arguments += @('--tag', $Tag) }
    return (Invoke-GitCliff $arguments).Trim()
}
