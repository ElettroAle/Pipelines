# SPDX-License-Identifier: Apache-2.0

# Fonti di una PR (Test-PullRequestSources.ps1): la PR e' collegata ad almeno un Task, ogni Task porta
# l'ADR con le sezioni obbligatorie della lingua del documento e il suo padre e' un requisito con i criteri
# di accettazione o un Bug con i passi di riproduzione. Del contenuto dell'ADR si verifica solo la presenza
# delle sezioni.

. "$PSScriptRoot/../Common/DocumentLanguage.ps1"

$ApiVersion = '7.1'
$ParentRelation = 'System.LinkTypes.Hierarchy-Reverse'
$RequirementTypes = @('Requirement', 'User Story', 'Product Backlog Item')

function Get-SourcesSettings {
    $pullRequest = 0
    if (-not [int]::TryParse("$env:PULL_REQUEST_ID".Trim(), [ref]$pullRequest) -or $pullRequest -le 0) {
        throw "la verifica delle fonti gira solo nella build di una PR: PULL_REQUEST_ID non e' un numero di PR ('$env:PULL_REQUEST_ID')"
    }
    return @{
        PullRequest   = $pullRequest
        CollectionUri = "$env:SYSTEM_COLLECTIONURI".TrimEnd('/')
        Project       = "$env:SYSTEM_TEAMPROJECT"
        AccessToken   = "$env:SYSTEM_ACCESSTOKEN"
        Sections      = @($DocumentLanguage.AdrSections)
    }
}

function Invoke-BoardsApi($Settings, [string]$Path) {
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $project = [uri]::EscapeDataString($Settings.Project)
    $uri = "$($Settings.CollectionUri)/$project/_apis/$Path${separator}api-version=$ApiVersion"
    return Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($Settings.AccessToken)" }
}

function Get-PullRequestWorkItemIds($Settings) {
    $repository = (Invoke-BoardsApi $Settings "git/pullrequests/$($Settings.PullRequest)").repository.id
    $linked = Invoke-BoardsApi $Settings "git/repositories/$([uri]::EscapeDataString($repository))/pullRequests/$($Settings.PullRequest)/workitems"
    return @($linked.value | ForEach-Object { [int]$_.id } | Sort-Object -Unique)
}

function Get-WorkItem($Settings, [int]$Id) {
    $item = Invoke-BoardsApi $Settings "wit/workitems/${Id}?`$expand=relations"
    $parent = @($item.relations | Where-Object rel -EQ $ParentRelation) | Select-Object -First 1
    return [pscustomobject]@{
        Id                 = $Id
        Type               = "$($item.fields.'System.WorkItemType')"
        Description        = "$($item.fields.'System.Description')"
        AcceptanceCriteria = "$($item.fields.'Microsoft.VSTS.Common.AcceptanceCriteria')"
        ReproSteps         = "$($item.fields.'Microsoft.VSTS.TCM.ReproSteps')"
        ParentId           = if ($parent) { [int]($parent.url -replace '^.*/', '') } else { 0 }
    }
}

function ConvertTo-PlainText([string]$Html) {
    $text = [Net.WebUtility]::HtmlDecode(($Html -replace '<[^>]*>', ' '))
    return ($text -replace '\s+', ' ').Trim()
}

function Test-HasText([string]$Value) {
    return [bool](ConvertTo-PlainText $Value)
}

# L'ADR del Task e' in Markdown o, scritto prima del Markdown, in HTML: in entrambi la sezione e'
# un'intestazione di secondo livello, non il suo nome citato nel testo.
function Get-AdrHeadings([string]$Description) {
    $markdown = @($Description -split "`r?`n" | Where-Object { $_ -match '^##\s+(.+?)\s*#*\s*$' } | ForEach-Object { $Matches[1] })
    $html = @([regex]::Matches($Description, '(?is)<h2\b[^>]*>(.*?)</h2>') | ForEach-Object { $_.Groups[1].Value })
    return @(($markdown + $html) | ForEach-Object { ConvertTo-PlainText $_ })
}

function Get-MissingAdrSections([string]$Description, [string[]]$Sections = @($DocumentLanguage.AdrSections)) {
    $headings = Get-AdrHeadings $Description
    return @($Sections | Where-Object { $headings -notcontains $_ })
}

function New-SourceIssue([string]$Element, [string]$Part) {
    return "${Element}: manca `"$Part`""
}

function Get-ParentIssue($Parent, [int]$TaskId) {
    if ($Parent.Type -eq 'Bug') {
        if (Test-HasText $Parent.ReproSteps) { return $null }
        return New-SourceIssue "Bug $($Parent.Id)" 'passi di riproduzione'
    }
    if ($RequirementTypes -notcontains $Parent.Type) { return New-SourceIssue "Task $TaskId" 'Requirement o Bug padre' }
    if (Test-HasText $Parent.AcceptanceCriteria) { return $null }
    return New-SourceIssue "$($Parent.Type) $($Parent.Id)" 'criteri di accettazione'
}

function Get-TaskIssues($Settings, $Task, [hashtable]$Read) {
    $issues = @(Get-MissingAdrSections $Task.Description $Settings.Sections | ForEach-Object { New-SourceIssue "Task $($Task.Id)" $_ })
    if (-not $Task.ParentId) { return $issues + (New-SourceIssue "Task $($Task.Id)" 'Requirement o Bug padre') }
    if (-not $Read.ContainsKey($Task.ParentId)) { $Read[$Task.ParentId] = Get-WorkItem $Settings $Task.ParentId }
    return @($issues + (Get-ParentIssue $Read[$Task.ParentId] $Task.Id) | Where-Object { $_ })
}

function Get-SourceIssues($Settings) {
    $read = @{}
    Get-PullRequestWorkItemIds $Settings | ForEach-Object { $read[$_] = Get-WorkItem $Settings $_ }
    $tasks = @($read.Values | Where-Object Type -EQ 'Task' | Sort-Object Id)
    if (-not $tasks) { return @(New-SourceIssue "PR $($Settings.PullRequest)" 'Task collegato') }
    return @($tasks | ForEach-Object { Get-TaskIssues $Settings $_ $read })
}
