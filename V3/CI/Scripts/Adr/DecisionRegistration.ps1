# SPDX-License-Identifier: Apache-2.0

# Registrazione delle decisioni dei Task arrivati nel ramo principale dei repository sorgente
# (Register-Decisions.ps1). Le integrazioni sono le PR completate nel ramo principale fra il punto di
# partenza registrato nel repository delle decisioni e l'istante del server all'avvio: per un repository
# con un ramo di sviluppo sono promozioni, e i Task vengono dalle PR di sviluppo che contengono. L'ADR del
# Task, scritto in Markdown, entra nel corpus senza modifiche, accettato, con data, Task e PR nel
# frontmatter. Ogni Task da' una sola decisione. Un Task senza ADR, un ADR non in Markdown o una decisione
# che la verifica del corpus respinge aprono un work item e lasciano il corpus com'era.

. "$PSScriptRoot/../Common/DocumentLanguage.ps1"

$DecisionFilePattern = '^\d{4}-[a-z0-9-]+\.md$'
$DecisionIdPattern = '\d{4}-[a-z0-9-]+'
$ApiVersion = '7.1'
$PageSize = 100
$WorkItemTitleLength = 255
$SlugLength = 60

function Split-List([string]$Value) {
    return @("$Value" -split ';' | ForEach-Object Trim | Where-Object { $_ })
}

# Una variabile della pipeline non definita arriva come la sua macro, $(nome), non come stringa vuota.
function Get-Setting([string]$Value, [string]$Default) {
    $text = "$Value".Trim() -replace '^\$\(.*\)$', ''
    if ($text) { return $text }
    return $Default
}

# Una sorgente e' "Repository" se le PR vanno nel ramo principale, "Repository:ramo" se vanno nel ramo
# di sviluppo e arrivano nel principale con una promozione.
function ConvertTo-Source([string]$Text) {
    $name, $development = $Text -split ':', 2
    return [pscustomobject]@{ Name = $name.Trim(); DevelopmentBranch = "$development".Trim() }
}

function Get-RegistrationSettings {
    $sources = @(Split-List (Get-Setting $env:ADR_REGISTER_SOURCES '') | ForEach-Object { ConvertTo-Source $_ })
    if (-not $sources) { throw 'ADR_REGISTER_SOURCES e'' obbligatoria: i repository sorgente, es. "Repo" o "Repo:dev"' }
    return @{
        Sources            = $sources
        DecisionsDirectory = Get-Setting $env:DECISIONS_DIRECTORY 'docs/decisions'
        BaselineFile       = Get-Setting $env:ADR_REGISTER_BASELINE '.decisions-baseline'
        Branch             = (Get-Setting $env:ADR_REGISTER_BRANCH 'decisions/register') -replace '^refs/heads/', ''
        TargetBranch       = (Get-Setting $env:TARGET_BRANCH 'main') -replace '^refs/heads/', ''
        WorkItemType       = Get-Setting $env:ADR_REGISTER_WORK_ITEM_TYPE 'Bug'
        DescriptionFile    = Get-Setting $env:ADR_REGISTER_DESCRIPTION_FILE ''
        CollectionUri      = "$env:SYSTEM_COLLECTIONURI".TrimEnd('/')
        Project            = "$env:SYSTEM_TEAMPROJECT"
        AccessToken        = "$env:SYSTEM_ACCESSTOKEN"
    }
}

function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path, (Get-Location).Path)
}

function Invoke-RegistrationGit {
    $authorization = if ($env:SYSTEM_ACCESSTOKEN) { @('-c', "http.extraheader=AUTHORIZATION: bearer $env:SYSTEM_ACCESSTOKEN") } else { @() }
    $output = git @authorization @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' '): $output" }
    return @($output | ForEach-Object { "$_" })
}

function Invoke-DevOpsApi($Settings, [string]$Path, [string]$Method = 'GET', $Body, [string]$ContentType = 'application/json') {
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $project = [uri]::EscapeDataString($Settings.Project)
    $parameters = @{
        Method                  = $Method
        Uri                     = "$($Settings.CollectionUri)/$project/_apis/$Path${separator}api-version=$ApiVersion"
        Headers                 = @{ Authorization = "Bearer $($Settings.AccessToken)" }
        ResponseHeadersVariable = 'responseHeaders'
    }
    if ($null -ne $Body) {
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 10))
        $parameters.ContentType = "$ContentType; charset=utf-8"
    }
    $response = Invoke-RestMethod @parameters
    return [pscustomobject]@{ Body = $response; Headers = $responseHeaders }
}

function Get-Header($Response, [string]$Name) {
    $key = @($Response.Headers.Keys | Where-Object { $_ -ieq $Name }) | Select-Object -First 1
    if (-not $key) { return '' }
    return "$(@($Response.Headers[$key])[0])"
}

# La finestra si chiude sull'orologio del server, lo stesso che data il completamento delle PR: una PR
# completata dopo resta per la run successiva, che la sua integrazione ha messo in coda.
function Get-ServerNow($Settings) {
    $response = Invoke-DevOpsApi $Settings 'git/repositories'
    $date = Get-Header $response 'Date'
    if ($date) { return [DateTimeOffset]::Parse($date, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() }
    return [DateTimeOffset]::UtcNow
}

function Get-RepositoryPath([string]$Repository) {
    return "git/repositories/$([uri]::EscapeDataString($Repository))"
}

function Get-CompletedPullRequests($Settings, [string]$Repository, [DateTimeOffset]$From, [DateTimeOffset]$To) {
    $criteria = "searchCriteria.status=completed&searchCriteria.targetRefName=refs/heads/$($Settings.TargetBranch)" +
    "&searchCriteria.queryTimeRangeType=closed&searchCriteria.minTime=$($From.ToString('o'))&searchCriteria.maxTime=$($To.ToString('o'))"
    $found = [Collections.Generic.List[object]]::new()
    for ($skip = 0; ; $skip += $PageSize) {
        $page = @((Invoke-DevOpsApi $Settings "$(Get-RepositoryPath $Repository)/pullrequests?$criteria&`$top=$PageSize&`$skip=$skip").Body.value)
        $page | ForEach-Object { $found.Add($_) }
        if ($page.Count -lt $PageSize) { break }
    }
    return @($found | Where-Object {
            $closed = [DateTimeOffset]$_.closedDate
            $closed -gt $From -and $closed -le $To
        })
}

function Get-PullRequestCommitMessages($Settings, [string]$Repository, [int]$PullRequest) {
    $messages = [Collections.Generic.List[string]]::new()
    $token = ''
    do {
        $continuation = if ($token) { "&continuationToken=$([uri]::EscapeDataString($token))" } else { '' }
        $response = Invoke-DevOpsApi $Settings "$(Get-RepositoryPath $Repository)/pullRequests/$PullRequest/commits?`$top=$PageSize$continuation"
        @($response.Body.value) | ForEach-Object { $messages.Add("$($_.comment)") }
        $token = Get-Header $response 'x-ms-continuationtoken'
    } while ($token)
    return $messages
}

# Azure Repos chiude ogni PR con il commit "Merged PR <numero>: <titolo>": i commit di una promozione
# nominano cosi' le PR che porta nel ramo principale, anche quelle passate da un ramo intermedio.
function Get-DevelopmentPullRequests($Settings, $Source, $Integration) {
    if (-not $Source.DevelopmentBranch) { return @([int]$Integration.pullRequestId) }
    $ids = @(Get-PullRequestCommitMessages $Settings $Source.Name $Integration.pullRequestId |
        Where-Object { $_ -match '^Merged PR (\d+):' } | ForEach-Object { [int]$Matches[1] } | Sort-Object -Unique)
    return @($ids | Where-Object {
            $pullRequest = (Invoke-DevOpsApi $Settings "git/pullrequests/$_").Body
            $pullRequest.status -eq 'completed' -and $pullRequest.repository.name -eq $Source.Name -and
            $pullRequest.targetRefName -eq "refs/heads/$($Source.DevelopmentBranch)"
        })
}

function Get-LinkedWorkItems($Settings, [string]$Repository, [int]$PullRequest) {
    return @((Invoke-DevOpsApi $Settings "$(Get-RepositoryPath $Repository)/pullRequests/$PullRequest/workitems").Body.value | ForEach-Object { [int]$_.id } | Sort-Object)
}

function Get-Integrations($Settings, [DateTimeOffset]$From, [DateTimeOffset]$To) {
    $integrations = foreach ($source in $Settings.Sources) {
        foreach ($integration in Get-CompletedPullRequests $Settings $source.Name $From $To) {
            $promotion = if ($source.DevelopmentBranch) { [int]$integration.pullRequestId } else { $null }
            foreach ($pullRequest in Get-DevelopmentPullRequests $Settings $source $integration) {
                [pscustomobject]@{
                    Repository  = $source.Name
                    PullRequest = $pullRequest
                    Promotion   = $promotion
                    Closed      = [DateTimeOffset]$integration.closedDate
                    WorkItems   = Get-LinkedWorkItems $Settings $source.Name $pullRequest
                }
            }
        }
    }
    return @($integrations | Sort-Object Closed, PullRequest)
}

function Get-Task($Settings, [int]$Id) {
    $item = (Invoke-DevOpsApi $Settings "wit/workitems/$Id").Body
    if ($item.fields.'System.WorkItemType' -ne 'Task') { return $null }
    $format = if ($item.multilineFieldsFormat) { "$($item.multilineFieldsFormat.'System.Description')" } else { 'html' }
    return [pscustomobject]@{
        Id          = $Id
        Title       = "$($item.fields.'System.Title')"
        Description = "$($item.fields.'System.Description')"
        IsMarkdown  = $format -eq 'markdown'
    }
}

function Read-Baseline($Settings) {
    $path = Get-FullPath $Settings.BaselineFile
    if (-not (Test-Path $path -PathType Leaf)) { return $null }
    return [DateTimeOffset]::Parse(([IO.File]::ReadAllText($path)).Trim(), [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}

function Save-Baseline($Settings, [DateTimeOffset]$Instant) {
    $path = Get-FullPath $Settings.BaselineFile
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, "$($Instant.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))`n")
}

# La PR di una registrazione precedente puo' essere ancora aperta: senza le sue decisioni questa run ne
# riuserebbe i numeri e registrerebbe di nuovo i suoi Task.
function Merge-PendingRegistration($Settings) {
    $remote = Invoke-RegistrationGit ls-remote origin "refs/heads/$($Settings.Branch)"
    if (-not "$remote".Trim()) { return }
    Invoke-RegistrationGit fetch -q origin "+refs/heads/$($Settings.Branch):refs/remotes/origin/$($Settings.Branch)" | Out-Null
    Invoke-RegistrationGit -c user.name=Pipeline -c user.email=pipeline@noreply.local merge -q --no-edit "refs/remotes/origin/$($Settings.Branch)" | Out-Null
}

function Get-Frontmatter([string]$Content) {
    $fields = @{}
    $lines = $Content -split "`r?`n"
    if ($lines[0] -ne '---') { return $fields }
    $end = [Array]::IndexOf($lines, '---', 1)
    if ($end -lt 1) { return $fields }
    $lines[1..($end - 1)] | Where-Object { $_ -match '^([\w-]+):\s*(.*)$' } | ForEach-Object { $fields[$Matches[1]] = $Matches[2].Trim() }
    return $fields
}

function Get-Corpus($Settings) {
    $directory = Get-FullPath $Settings.DecisionsDirectory
    $files = if (Test-Path $directory) { @(Get-ChildItem $directory -File | Where-Object Name -Match $DecisionFilePattern) } else { @() }
    $tasks = @{}
    $last = 0
    foreach ($file in $files) {
        $last = [math]::Max($last, [int]$file.Name.Substring(0, 4))
        $task = (Get-Frontmatter ([IO.File]::ReadAllText($file.FullName)))['task']
        if ($task) { $tasks[[int]$task] = $file.BaseName }
    }
    return @{ Directory = $directory; Tasks = $tasks; Last = $last }
}

function ConvertTo-Slug([string]$Title) {
    $plain = -join ($Title.Normalize([Text.NormalizationForm]::FormD).ToCharArray() |
        Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
    $words = @($plain.ToLowerInvariant() -split '[^a-z0-9]+' | Where-Object { $_ })
    $slug = ''
    foreach ($word in $words) {
        $next = if ($slug) { "$slug-$word" } else { $word }
        if ($slug -and $next.Length -gt $SlugLength) { break }
        $slug = $next
    }
    if ($slug) { return $slug }
    return 'decisione'
}

function Get-DecisionTitle($Task) {
    $heading = $Task.Description -split "`r?`n" | Where-Object { $_ -match '^#\s+(.+?)\s*$' } | Select-Object -First 1
    if ($heading -match '^#\s+(.+?)\s*$') { return ($Matches[1] -replace '[*_`]', '') }
    return $Task.Title
}

function Get-SupersededDecision([string]$Text) {
    $label = [regex]::Escape($DocumentLanguage.AdrSupersedesLabel)
    if ($Text -match "(?im)^\W*$label\b[^\r\n]*?($DecisionIdPattern)") { return $Matches[1] }
    return $null
}

function New-DecisionContent($Task, $Integration, [string]$Supersedes) {
    $front = @('---', 'status: accepted', 'version: 1', "date: $($Integration.Closed.UtcDateTime.ToString('yyyy-MM-dd'))", "task: $($Task.Id)", "pull-request: $($Integration.PullRequest)")
    if ($Integration.Promotion) { $front += "promotion: $($Integration.Promotion)" }
    if ($Supersedes) { $front += "supersedes: $Supersedes" }
    $text = $Task.Description.TrimEnd() + "`n"
    return (($front + '---' + '') -join "`n") + "`n" + $text
}

# La sostituita cambia solo stato e rimando alla sostituta: il resto del testo resta com'e'.
function Set-Superseded([string]$Content, [string]$By) {
    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]($Content -split [regex]::Escape($newline))
    $lines.RemoveAll([Predicate[string]] { param($line) $line -match '^superseded-by:' }) | Out-Null
    $end = $lines.IndexOf('---', 1)
    $status = $lines.FindIndex(1, $end - 1, [Predicate[string]] { param($line) $line -match '^status:' })
    if ($status -lt 0) { $lines.Insert($end, ''); $status = $end }
    $lines[$status] = 'status: superseded'
    $lines.Insert($status + 1, "superseded-by: $By")
    return $lines -join $newline
}

function Get-CorpusIssues($Settings) {
    $script = Join-Path $PSScriptRoot 'Test-AdrCorpus.ps1'
    $environment = @{ DECISIONS_DIRECTORY = $Settings.DecisionsDirectory; TARGET_BRANCH = $Settings.TargetBranch; GATE_MODE = 'enforce' }
    $saved = @{}
    foreach ($name in $environment.Keys) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $environment[$name]) }
    try { $output = & pwsh -NoProfile -NonInteractive -File $script 2>&1 }
    finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
    $global:LASTEXITCODE = 0
    return @($output | ForEach-Object { "$_" } | Where-Object { $_ -match '^##vso\[task\.logissue type=error\](.*)$' } | ForEach-Object { $Matches[1] })
}

function Restore-Files([hashtable]$Originals) {
    foreach ($path in $Originals.Keys) {
        if ($null -eq $Originals[$path]) { Remove-Item -Force $path -ErrorAction SilentlyContinue }
        else { [IO.File]::WriteAllText($path, $Originals[$path]) }
    }
}

function Add-Decision($Settings, $Corpus, $Task, $Integration, [string[]]$KnownIssues) {
    if (-not $Task.Description.Trim()) { return @{ Registered = $null; Reasons = @('decisione tecnica mancante') } }
    if (-not $Task.IsMarkdown) { return @{ Registered = $null; Reasons = @('decisione non in Markdown') } }

    $number = $Corpus.Last + 1
    $id = '{0:D4}-{1}' -f $number, (ConvertTo-Slug (Get-DecisionTitle $Task))
    $path = Join-Path $Corpus.Directory "$id.md"
    $supersedes = Get-SupersededDecision $Task.Description
    $originals = @{ $path = $null }
    New-Item -ItemType Directory -Force -Path $Corpus.Directory | Out-Null
    [IO.File]::WriteAllText($path, (New-DecisionContent $Task $Integration $supersedes))
    $replaced = if ($supersedes) { Join-Path $Corpus.Directory "$supersedes.md" }
    if ($replaced -and (Test-Path $replaced -PathType Leaf)) {
        $originals[$replaced] = [IO.File]::ReadAllText($replaced)
        [IO.File]::WriteAllText($replaced, (Set-Superseded $originals[$replaced] $id))
    }

    $issues = @(Get-CorpusIssues $Settings | Where-Object { $KnownIssues -notcontains $_ })
    if ($issues) {
        Restore-Files $originals
        return @{ Registered = $null; Reasons = $issues }
    }
    $Corpus.Last = $number
    $Corpus.Tasks[$Task.Id] = $id
    return @{ Registered = $id; Reasons = @() }
}

function ConvertTo-HtmlText([string]$Text) {
    return [Net.WebUtility]::HtmlEncode($Text)
}

function Get-IntegrationLabel($Integration) {
    $label = "PR $($Integration.PullRequest) di $($Integration.Repository)"
    if ($Integration.Promotion) { $label += ", promossa con la PR $($Integration.Promotion)" }
    return $label
}

function New-RejectionWorkItem($Settings, $Task, $Integration, [string[]]$Reasons) {
    $title = "Decisione del Task $($Task.Id) non registrata: $($Reasons -join '; ')"
    if ($title.Length -gt $WorkItemTitleLength) { $title = $title.Substring(0, $WorkItemTitleLength) }
    $reasons = @($Reasons | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join ''
    $steps = "<p>La decisione del Task $($Task.Id), arrivato nel ramo $(ConvertTo-HtmlText $Settings.TargetBranch) con la $(ConvertTo-HtmlText (Get-IntegrationLabel $Integration)), non entra nel corpus delle decisioni.</p><p>Motivi:</p><ul>$reasons</ul>"
    $operations = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = $title }
        @{ op = 'add'; path = '/fields/Microsoft.VSTS.TCM.ReproSteps'; value = $steps }
        @{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Related'; url = "$($Settings.CollectionUri)/_apis/wit/workItems/$($Task.Id)" } }
    )
    $type = [uri]::EscapeDataString($Settings.WorkItemType)
    return (Invoke-DevOpsApi $Settings "wit/workitems/`$$type" 'POST' $operations 'application/json-patch+json').Body.id
}

function Save-Description($Settings, [string[]]$Lines) {
    if (-not $Settings.DescriptionFile) { return }
    $path = Get-FullPath $Settings.DescriptionFile
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, ($Lines -join "`n") + "`n")
}

function New-Outcome([string]$Status, [string[]]$Lines, [bool]$Publish, [string[]]$Registered = @(), [int[]]$WorkItems = @()) {
    return @{ Status = $Status; Lines = $Lines; Publish = $Publish; Registered = $Registered; WorkItems = $WorkItems }
}

function Invoke-DecisionRegistration($Settings) {
    Merge-PendingRegistration $Settings
    $now = Get-ServerNow $Settings
    $baseline = Read-Baseline $Settings
    if (-not $baseline) {
        Save-Baseline $Settings $now
        $lines = @("Punto di partenza della registrazione: $($now.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
        Save-Description $Settings $lines
        return New-Outcome 'baseline' $lines $true
    }

    $corpus = Get-Corpus $Settings
    $knownIssues = @(Get-CorpusIssues $Settings)
    $registered = [Collections.Generic.List[string]]::new()
    $workItems = [Collections.Generic.List[int]]::new()
    $lines = [Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($integration in Get-Integrations $Settings $baseline $now) {
        foreach ($workItem in $integration.WorkItems) {
            if ($seen.ContainsKey($workItem) -or $corpus.Tasks.ContainsKey($workItem)) { continue }
            $seen[$workItem] = $true
            $task = Get-Task $Settings $workItem
            if (-not $task) { continue }
            $result = Add-Decision $Settings $corpus $task $integration $knownIssues
            if ($result.Registered) {
                $registered.Add($result.Registered)
                $lines.Add("- $($result.Registered): Task $($task.Id), $(Get-IntegrationLabel $integration)")
                continue
            }
            $bug = New-RejectionWorkItem $Settings $task $integration $result.Reasons
            $workItems.Add($bug)
            $lines.Add("- Task $($task.Id) non registrato ($(Get-IntegrationLabel $integration)): work item $bug, $($result.Reasons -join '; ')")
        }
    }

    if (-not $registered.Count -and -not $workItems.Count) { return New-Outcome 'unchanged' @('Nessuna decisione da registrare') $false }
    Save-Baseline $Settings $now
    Save-Description $Settings (@('Decisioni dei Task arrivati nel ramo principale:') + $lines)
    $status = if ($workItems.Count) { 'rejected' } else { 'registered' }
    return New-Outcome $status $lines $true $registered $workItems
}
