# SPDX-License-Identifier: Apache-2.0

# Le voci della reference senza descrizione nel codice aprono un work item per repository, che elenca
# tutte le voci e si riscrive a ogni generazione finche' resta aperto: le run successive non lo
# duplicano. Un repository senza voci da descrivere non tocca la board.

$ReferenceApiVersion = '7.1'
$ReferenceClosedStates = @('Closed', 'Done', 'Removed', 'Resolved')

function Invoke-ReferenceDevOpsApi($Settings, [string]$Path, [string]$Method = 'GET', $Body, [string]$ContentType = 'application/json') {
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $project = [uri]::EscapeDataString($Settings.Project)
    $parameters = @{
        Method  = $Method
        Uri     = "$($Settings.CollectionUri)/$project/_apis/$Path${separator}api-version=$ReferenceApiVersion"
        Headers = @{ Authorization = "Bearer $($Settings.AccessToken)" }
    }
    if ($null -ne $Body) {
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 10))
        $parameters.ContentType = "$ContentType; charset=utf-8"
    }
    return Invoke-RestMethod @parameters
}

function Get-ReferenceBugField([string]$WorkItemType) {
    if ($WorkItemType -eq 'Bug') { return 'Microsoft.VSTS.TCM.ReproSteps' }
    return 'System.Description'
}

function ConvertTo-ReferenceBugText([string]$Repository, [string[]]$Entries, $Labels) {
    $items = @($Entries | ForEach-Object {
            $html = [Net.WebUtility]::HtmlEncode($_) -replace '`([^`]+)`', '<code>$1</code>'
            "<li>$html</li>"
        }) -join ''
    return "<p>$([Net.WebUtility]::HtmlEncode(($Labels.BugText -f $Repository)))</p><ul>$items</ul>"
}

function Find-ReferenceBug($Settings, [string]$Title) {
    $escape = { param($text) $text.Replace("'", "''") }
    $closed = ($ReferenceClosedStates | ForEach-Object { "'$_'" }) -join ', '
    $query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.WorkItemType] = '$(& $escape $Settings.WorkItemType)' AND [System.Title] = '$(& $escape $Title)' AND [System.State] NOT IN ($closed) ORDER BY [System.Id]"
    $result = Invoke-ReferenceDevOpsApi $Settings 'wit/wiql' 'POST' @{ query = $query }
    return @($result.workItems | ForEach-Object id) | Select-Object -First 1
}

function Update-ReferenceBugs($Settings, [System.Collections.IDictionary]$MissingByRepository, $Labels) {
    $field = Get-ReferenceBugField $Settings.WorkItemType
    $type = [uri]::EscapeDataString($Settings.WorkItemType)
    foreach ($repository in $MissingByRepository.Keys) {
        $entries = @($MissingByRepository[$repository])
        if (-not $entries) { continue }
        $title = $Labels.BugTitle -f $repository
        $text = ConvertTo-ReferenceBugText $repository $entries $Labels
        $existing = Find-ReferenceBug $Settings $title
        if ($existing) {
            Invoke-ReferenceDevOpsApi $Settings "wit/workitems/$existing" 'PATCH' @(@{ op = 'add'; path = "/fields/$field"; value = $text }) 'application/json-patch+json' | Out-Null
            Write-Host "$($Settings.WorkItemType) $existing aggiornato: $($entries.Count) voci senza descrizione in $repository"
            continue
        }
        $operations = @(
            @{ op = 'add'; path = '/fields/System.Title'; value = $title }
            @{ op = 'add'; path = "/fields/$field"; value = $text }
        )
        $created = Invoke-ReferenceDevOpsApi $Settings "wit/workitems/`$$type" 'POST' $operations 'application/json-patch+json'
        Write-Host "$($Settings.WorkItemType) $($created.id) aperto: $($entries.Count) voci senza descrizione in $repository"
    }
}
