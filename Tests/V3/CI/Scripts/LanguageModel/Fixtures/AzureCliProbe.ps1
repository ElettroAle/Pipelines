# SPDX-License-Identifier: Apache-2.0

# Una Azure CLI finta, messa prima di quella vera nel PATH di uno script: se lo script la chiama, per
# esempio per un token Entra ID verso Foundry, lascia il file Called. Un passo che usa Anthropic non la
# chiama mai.

function New-AzureCliProbe {
    $directory = Join-Path ([IO.Path]::GetTempPath()) "pester-az-probe-$(New-Guid)"
    New-Item -ItemType Directory -Path $directory | Out-Null
    $called = Join-Path $directory 'called'
    [IO.File]::WriteAllText((Join-Path $directory 'az.cmd'), "@echo off`r`necho called> `"%~dp0called`"`r`nexit /b 1`r`n")
    [IO.File]::WriteAllText((Join-Path $directory 'az'), "#!/bin/sh`ntouch `"`$(dirname `"`$0`")/called`"`nexit 1`n")
    if (-not $IsWindows) { chmod +x (Join-Path $directory 'az') }
    return @{
        Directory = $directory
        Called    = $called
        Path      = "$directory$([IO.Path]::PathSeparator)$env:PATH"
    }
}

function Remove-AzureCliProbe($Probe) {
    Remove-Item -Recurse -Force $Probe.Directory -ErrorAction SilentlyContinue
}
