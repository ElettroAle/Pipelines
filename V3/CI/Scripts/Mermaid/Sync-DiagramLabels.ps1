# SPDX-License-Identifier: Apache-2.0

# Allinea al modello C4 i diagrammi di sequenza delle sezioni del documento (DiagramModel.ps1): ogni
# partecipante prende come alias il suo identificativo e come etichetta il nome che il modello gli da',
# e ogni riquadro il nome del container dei suoi componenti. Un partecipante scritto con un nome che il
# modello non ha piu' si riconosce con il modello del ramo base, dove quel nome c'era. In una PR le
# righe cambiate tornano sul suo ramo in un commit, e la build che parte da quel commit verifica i
# flussi; fuori da una PR non cambia nulla e la verifica dei flussi segnala cio' che non torna.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/MarkdownText.ps1"
. "$PSScriptRoot/../C4/Structurizr.ps1"
. "$PSScriptRoot/Mermaid.ps1"
. "$PSScriptRoot/DiagramModel.ps1"

$docsDirectory = if ($env:DOCS_DIRECTORY) { $env:DOCS_DIRECTORY } else { 'docs/architecture' }
$WorkspaceDsl = Join-Path $docsDirectory 'c4/workspace.dsl'
$sourceBranch = $env:SOURCE_BRANCH -replace '^refs/heads/', '' -replace '^\$\(.*\)$', ''

$SyncScope = 'allineamento dei diagrammi'
# Il commit non avvia le pipeline con trigger sui rami; la build della PR parte comunque.
$SkipCi = '[skip ci]'
$CommitSubject = 'docs: align diagram participants with the C4 model'

function Get-SequenceDiagrams {
    $diagrams = @(foreach ($section in (Get-DocumentSections $docsDirectory)) {
            foreach ($diagram in $section.Content.Diagrams) {
                [pscustomobject]@{ Id = "$($section.File.Name):$($diagram.Line)"; File = $section.File.FullName; Line = $diagram.Line; Text = $diagram.Text; Parsed = $null }
            }
        })
    if (-not $diagrams) { return @() }
    $results = @{}
    Invoke-MermaidParser $diagrams | ForEach-Object { $results[$_.id] = $_ }
    foreach ($diagram in $diagrams) { $diagram.Parsed = $results[$diagram.Id] }
    return @($diagrams | Where-Object { $_.Parsed.type -eq 'sequence' })
}

function Get-Model([string]$Dsl) {
    if (-not (Test-Path $Dsl -PathType Leaf)) { return }
    $export = Export-StructurizrWorkspace (Resolve-Path $Dsl).Path
    if ($export.Error) { return }
    return New-ModelIndex $export.Workspace
}

# La build di una PR gira sul commit di merge: il primo genitore e' il ramo base, il secondo il ramo della PR.
function Get-MergeParents {
    $commits = @("$(git rev-list --parents -n 1 HEAD)" -split ' ')
    if ($commits.Count -ge 3) { return @{ Base = $commits[1]; Source = $commits[2] } }
    return @{ Base = $null; Source = $commits[0] }
}

function Invoke-InWorktree([string]$Commit, [scriptblock]$Action) {
    $worktree = Join-Path ([IO.Path]::GetTempPath()) "diagram-labels-$(New-Guid)"
    $out = git worktree add -q --detach $worktree $Commit 2>&1
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; throw "copia del commit $Commit non creata: $out" }
    try { return & $Action $worktree }
    finally {
        git worktree remove --force $worktree 2>&1 | Out-Null
        $global:LASTEXITCODE = 0
    }
}

function Get-BaseModel([string]$Commit) {
    if (-not $Commit) { return }
    return Invoke-InWorktree $Commit { param($Worktree) Get-Model (Join-Path $Worktree $WorkspaceDsl) }
}

function Test-NeedsBaseModel([object[]]$Diagrams, $Head) {
    return [bool]@($Diagrams | ForEach-Object { @($_.Parsed.placements) } | Where-Object { $_ -and -not (Resolve-ElementId $_.id $Head) })
}

# Le righe del diagramma, dopo il recinto di apertura, si sostituiscono con quelle allineate: i diagrammi
# di un file si scrivono dall'ultimo, cosi' le righe di quelli prima non si spostano.
function Set-DiagramText($Diagram, [string]$Text) {
    $content = [IO.File]::ReadAllText($Diagram.File)
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new([string[]]($content -split "`r?`n"))
    $lines.RemoveRange($Diagram.Line, @($Diagram.Text -split "`n").Count)
    $lines.InsertRange($Diagram.Line, [string[]]($Text -split "`n"))
    [IO.File]::WriteAllText($Diagram.File, ($lines -join $newline))
}

function Get-GitAuthorization {
    if ($env:SYSTEM_ACCESSTOKEN) { return @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") }
    return @()
}

# Le righe allineate si applicano al commit del ramo della PR, non al commit di merge della build.
function Publish-Alignment([string]$Source) {
    $patchFile = [IO.Path]::GetTempFileName()
    $messageFile = [IO.Path]::GetTempFileName()
    try {
        git diff --full-index --binary --output=$patchFile -- $docsDirectory
        [IO.File]::WriteAllText($messageFile, "$CommitSubject`n`n$SkipCi`n")
        $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Quality Gate' }
        $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'quality-gate@noreply.local' }
        return Invoke-InWorktree $Source {
            param($Worktree)
            $out = git -C $Worktree apply --3way --whitespace=nowarn $patchFile 2>&1
            if ($LASTEXITCODE -ne 0) { return New-Issue $SyncScope 'diagrammi non pubblicati' "righe non applicabili al ramo ${sourceBranch}: $out" }
            git -C $Worktree add -A
            $out = git -C $Worktree -c "user.name=$name" -c "user.email=$email" commit -q -F $messageFile 2>&1
            if ($LASTEXITCODE -ne 0) { return New-Issue $SyncScope 'diagrammi non pubblicati' "commit non riuscito: $out" }
            $authorization = Get-GitAuthorization
            $out = git -C $Worktree @authorization push -q origin "HEAD:refs/heads/$sourceBranch" 2>&1
            if ($LASTEXITCODE -ne 0) { return New-Issue $SyncScope 'diagrammi non pubblicati' "push sul ramo $sourceBranch non riuscito: $out" }
            return New-Issue $SyncScope 'diagrammi allineati al modello C4' "commit sul ramo ${sourceBranch}: la verifica dei flussi riparte da quel commit"
        }
    }
    finally {
        Remove-Item $patchFile, $messageFile -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
    }
}

function Sync-DiagramLabels {
    if (-not $sourceBranch) { return Write-Host 'Fuori da una PR i diagrammi non si allineano: la verifica dei flussi segnala cio'' che non torna' }
    $diagrams = Get-SequenceDiagrams
    $head = if ($diagrams) { Get-Model $WorkspaceDsl }
    if (-not $head) { return }

    $commits = Get-MergeParents
    $base = if (Test-NeedsBaseModel $diagrams $head) { Get-BaseModel $commits.Base }
    $changed = @(foreach ($diagram in ($diagrams | Sort-Object File, @{ Expression = 'Line'; Descending = $true })) {
            $aligned = Get-AlignedDiagram $diagram.Text $diagram.Parsed $head $base
            if ($aligned -cne $diagram.Text) { Set-DiagramText $diagram $aligned; $diagram.Id }
        })
    if (-not $changed) { return }
    Write-Host "Diagrammi allineati al modello C4: $($changed -join ', ')"
    Publish-Alignment $commits.Source
}

Invoke-Verification { Sync-DiagramLabels } "Diagrammi di $docsDirectory allineati al modello C4" 'Allineamento dei diagrammi disattivato'
