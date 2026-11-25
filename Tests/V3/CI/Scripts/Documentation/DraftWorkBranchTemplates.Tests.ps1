# SPDX-License-Identifier: Apache-2.0

#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester dei rami di lavoro della bozza nei template che aprono una PR sul ramo del documento.

.DESCRIPTION
    Il nome del ramo di lavoro si legge dal testo dei template e si valuta come farebbe l'espansione, con il ramo
    di default del template e il ramo del documento. Il push si prova su un origin bare locale dove esiste gia' il
    ramo di lavoro di main, come mentre la sua PR e' aperta.
#>

BeforeDiscovery {
    $Templates = @(
        @{ Template = 'V3/CI/Common/Steps/adr-register.yaml'; Occurrences = 2 }
        @{ Template = 'V3/CI/Common/Steps/documentation-update.yaml'; Occurrences = 1 }
    )
}

BeforeAll {
    $script:Root = Resolve-Path "$PSScriptRoot/../../../../.."
    $script:WorkBranchPattern = "\`$\{\{ iif\(eq\(parameters\.targetBranch, 'main'\), parameters\.branch, format\('(?<format>[^']*)', parameters\.branch, parameters\.targetBranch\)\) \}\}"

    function Get-TemplateText([string]$Path) {
        return [IO.File]::ReadAllText((Join-Path $Root $Path)) -replace "`r`n", "`n"
    }

    function Get-DefaultBranch([string]$Text) {
        return [regex]::Match($Text, "(?s)\n  - name: branch\n    type: string\n    default: '([^']*)'").Groups[1].Value
    }

    function Get-WorkBranchFormats([string]$Text) {
        return , @([regex]::Matches($Text, "(?m)^\s+(?:branch|ADR_REGISTER_BRANCH): $WorkBranchPattern$") | ForEach-Object { $_.Groups['format'].Value })
    }

    function Resolve-WorkBranch([string]$Format, [string]$Branch, [string]$TargetBranch) {
        if ($TargetBranch -eq 'main') { return $Branch }
        return $Format.Replace('{0}', $Branch).Replace('{1}', $TargetBranch)
    }

    function Test-FolderPrefix([string]$Folder, [string]$Branch) {
        return $Branch.StartsWith("$Folder/")
    }

    function Invoke-Git([string]$Directory) {
        $output = & git -C $Directory @args 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }

    function New-OriginWithMainWorkBranch([string]$MainWorkBranch, [string]$DocumentBranch) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "draft-work-branch-$([guid]::NewGuid().ToString('N'))"
        $origin = Join-Path $root 'origin.git'
        $work = Join-Path $root 'work'
        git init -q --bare -b main $origin
        git init -q -b main $work
        Invoke-Git $work config user.email 'pipeline@example.com' | Out-Null
        Invoke-Git $work config user.name 'Pipeline' | Out-Null
        Invoke-Git $work commit -q --allow-empty -m 'docs: documento' | Out-Null
        Invoke-Git $work remote add origin $origin | Out-Null
        foreach ($branch in 'main', $DocumentBranch, $MainWorkBranch) {
            Invoke-Git $work push -q origin "HEAD:refs/heads/$branch" | Out-Null
        }
        return [pscustomobject]@{ Root = $root; Origin = $origin; Work = $work }
    }

}

Describe 'Funzionalità: rami di lavoro della bozza accanto a quelli di main' {

    Context 'Scenario: i rami di lavoro della bozza si pubblicano anche quando esistono quelli di main (<Template>)' -ForEach $Templates {
        BeforeAll {
            $text = Get-TemplateText $Template
            $script:MainWorkBranch = Get-DefaultBranch $text
            $script:DraftWorkBranch = Resolve-WorkBranch (Get-WorkBranchFormats $text)[0] $MainWorkBranch 'staging'
            $script:Repository = New-OriginWithMainWorkBranch $MainWorkBranch 'staging'
            $script:Push = Invoke-Git $Repository.Work push origin "HEAD:refs/heads/$DraftWorkBranch"
        }

        AfterAll {
            Remove-Item -Recurse -Force $Repository.Root -ErrorAction SilentlyContinue
        }

        It 'Allora il push del ramo di lavoro della bozza riesce' {
            $Push.ExitCode | Should -Be 0 -Because $Push.Output
        }

        It "E l'origin ha il ramo di lavoro della bozza accanto a quello di main" {
            $heads = (Invoke-Git $Repository.Origin for-each-ref --format='%(refname:short)' refs/heads).Output -split '\r?\n' | Where-Object { $_ }
            $heads | Should -Contain $DraftWorkBranch
            $heads | Should -Contain $MainWorkBranch
        }
    }

    Context 'Nome del ramo di lavoro (ADR-2147) in <Template>' -ForEach $Templates {
        BeforeAll {
            $script:Text = Get-TemplateText $Template
            $script:MainWorkBranch = Get-DefaultBranch $Text
            $script:Formats = Get-WorkBranchFormats $Text
        }

        It 'ogni punto che compone il ramo di lavoro usa la stessa espressione' {
            $Formats.Count | Should -Be $Occurrences
            @($Formats | Select-Object -Unique).Count | Should -Be 1
            ([regex]::Matches($Text, 'format\(''\{0\}/\{1\}''')).Count | Should -Be 0
        }

        It 'su main il ramo di lavoro resta il ramo di default del template' {
            $MainWorkBranch | Should -Not -BeNullOrEmpty
            Resolve-WorkBranch $Formats[0] $MainWorkBranch 'main' | Should -Be $MainWorkBranch
        }

        It 'sulla bozza il ramo di lavoro ha il ramo del documento come suffisso con il trattino' {
            Resolve-WorkBranch $Formats[0] $MainWorkBranch 'staging' | Should -Be "$MainWorkBranch-staging"
        }

        It 'nessun ramo di lavoro della bozza e'' cartella o dentro la cartella del ramo di lavoro di main o del ramo del documento' -ForEach @(
            @{ DocumentBranch = 'staging' }, @{ DocumentBranch = 'bozza' }
        ) {
            $draft = Resolve-WorkBranch $Formats[0] $MainWorkBranch $DocumentBranch
            foreach ($other in $MainWorkBranch, $DocumentBranch) {
                Test-FolderPrefix $draft $other | Should -BeFalse -Because "$other non puo' stare nella cartella $draft"
                Test-FolderPrefix $other $draft | Should -BeFalse -Because "$draft non puo' stare nella cartella $other"
            }
        }
    }
}
