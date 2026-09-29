#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/GitCliff.ps1

.DESCRIPTION
    I runner GitHub hanno runtime che gli agent self-hosted non hanno (Visual C++
    Redistributable su Windows): eseguire il binario non basta a dimostrare che parta
    anche sugli agent, quindi si verificano le sue dipendenze nel file stesso.
#>

BeforeDiscovery {
    $onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

BeforeAll {
    . "$PSScriptRoot/../../V3/CI/Scripts/GitCliff.ps1"
    $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
    $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-gitcliff-$(New-Guid)"
    $GitCliffExe = Get-GitCliffPath
    $GitCliffBytes = [IO.File]::ReadAllBytes($GitCliffExe)
    $GitCliffAscii = [Text.Encoding]::ASCII.GetString($GitCliffBytes)
}

AfterAll {
    Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
    $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
}

Describe "GitCliff — binario scaricato" {

    It "Risponde con la versione fissata" {
        (& $GitCliffExe --version) | Should -Match ([regex]::Escape($GitCliffVersion))
    }

    It "Windows: non dipende dal Visual C++ Redistributable" -Skip:(-not $onWindows) {
        [regex]::Matches($GitCliffAscii, '(?i)(VCRUNTIME|MSVCP)\d+\.dll') | ForEach-Object Value | Should -BeNullOrEmpty
    }

    It "Linux: collegato staticamente, senza loader dinamico" -Skip:$onWindows {
        [regex]::Matches($GitCliffAscii, 'ld-linux[\w.-]*') | ForEach-Object Value | Should -BeNullOrEmpty
    }

    It "La cache e' separata per archivio: un binario di un'altra build non viene riusato" {
        $archive = $GitCliffArchives[(Get-GitCliffPlatform)]
        $GitCliffExe | Should -Match ([regex]::Escape(($archive.Name -replace '(\.zip|\.tar\.gz)$', '')))
    }
}
