# SPDX-License-Identifier: Apache-2.0

# Genera la reference dal codice e la scrive nella wiki di progetto di Azure DevOps sotto WIKI_ROOT, che
# riscrive per intero: una pagina per modulo Terraform (variabili e output con la descrizione, l'elenco
# delle risorse), una per API (ogni endpoint con parametri, risposte e descrizione), quella dei comandi del
# task runner e la pagina radice con le release notes. Accanto alle pagine scrive l'indice delle voci, che
# il collegamento dal testo legge, e collega alla reference le pagine sotto REFERENCE_LINK_ROOTS. Un commit
# solo, ripetuto sopra l'ultimo commit della wiki se un'altra pipeline l'ha cambiata. Le voci senza
# descrizione aprono o aggiornano un work item per repository (ReferenceBugs.ps1); le risorse dei moduli
# non hanno descrizione e non ne aprono.

. "$PSScriptRoot/../Common/DocumentLanguage.ps1"
. "$PSScriptRoot/../Common/WikiNames.ps1"
. "$PSScriptRoot/ReferenceSources.ps1"
. "$PSScriptRoot/ReferenceLinks.ps1"
. "$PSScriptRoot/ReferenceBugs.ps1"

$ErrorActionPreference = 'Stop'
$MaxPushAttempts = 3
$AttachmentsFolder = '.attachments'
$IndexFile = 'reference-index.json'
$Labels = $DocumentLanguage.Reference

# Una variabile della pipeline non definita arriva come la sua macro, $(nome), non come stringa vuota.
function Get-ReferenceSetting([string]$Value, [string]$Default = '') {
    $text = "$Value".Trim() -replace '^\$\(.*\)$', ''
    if ($text) { return $text }
    return $Default
}

function ConvertFrom-ReferenceList([string]$Json) {
    $text = Get-ReferenceSetting $Json
    if (-not $text) { return @() }
    return @($text | ConvertFrom-Json | Where-Object { $_ })
}

function Get-ReferenceSettings {
    $collectionUri = "$env:SYSTEM_COLLECTIONURI".TrimEnd('/')
    $project = "$env:SYSTEM_TEAMPROJECT"
    $defaultWikiUrl = "$collectionUri/$([uri]::EscapeDataString($project))/_wiki/wikis/$([uri]::EscapeDataString("$project.wiki"))"
    return @{
        ModulesDirectory    = Get-ReferenceSetting $env:REFERENCE_MODULES_DIRECTORY
        ModulesRepository   = Get-ReferenceSetting $env:REFERENCE_MODULES_REPOSITORY
        Taskfile            = Get-ReferenceSetting $env:REFERENCE_TASKFILE
        TaskfileRepository  = Get-ReferenceSetting $env:REFERENCE_TASKFILE_REPOSITORY
        Apis                = @(ConvertFrom-ReferenceList $env:REFERENCE_APIS)
        ReleaseNotes        = @(ConvertFrom-ReferenceList $env:REFERENCE_RELEASE_NOTES)
        LinkRoots           = @((Get-ReferenceSetting $env:REFERENCE_LINK_ROOTS) -split ';' | ForEach-Object Trim | Where-Object { $_ })
        WikiDirectory       = Get-ReferenceSetting $env:WIKI_DIRECTORY
        WikiBranch          = Get-ReferenceSetting $env:WIKI_BRANCH 'wikiMaster'
        WikiRoot            = Get-ReferenceSetting $env:WIKI_ROOT $Labels.WikiRoot
        WikiUrl             = (Get-ReferenceSetting $env:WIKI_URL $defaultWikiUrl).TrimEnd('/')
        WorkItemType        = Get-ReferenceSetting $env:REFERENCE_WORK_ITEM_TYPE 'Bug'
        CollectionUri       = $collectionUri
        Project             = $project
        AccessToken         = "$env:SYSTEM_ACCESSTOKEN"
    }
}

#region Pagine

function Get-PageUrl($Settings, [string[]]$Titles) {
    $path = '/' + (@($Titles | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    return "$($Settings.WikiUrl)?pagePath=$path"
}

function ConvertTo-Cell([string]$Text) {
    return ("$Text" -replace '\|', '\|' -replace "\r?\n", '<br>').Trim()
}

function New-Table([string[]]$Header, [object[]]$Rows) {
    $lines = @("| $($Header -join ' | ') |", "|$(@($Header | ForEach-Object { '---' }) -join '|')|")
    foreach ($row in $Rows) { $lines += "| $(@($row | ForEach-Object { ConvertTo-Cell $_ }) -join ' | ') |" }
    return $lines
}

function Format-Default($Variable) {
    if ($Variable.Required) { return $Labels.Required }
    return "``$(ConvertTo-Json -InputObject $Variable.Default -Compress -Depth 10)``"
}

function New-ModulePage($Module) {
    $lines = @("_$($Labels.Generated)_", '', "## $($Labels.Variables)", '')
    $lines += New-Table @($Labels.Name, $Labels.Type, $Labels.Default, $Labels.Description) @($Module.Variables | ForEach-Object {
            , @("``$($_.Name)``", "``$($_.Type)``", (Format-Default $_), $_.Description)
        })
    $lines += @('', "## $($Labels.Outputs)", '')
    $lines += New-Table @($Labels.Name, $Labels.Description) @($Module.Outputs | ForEach-Object { , @("``$($_.Name)``", $_.Description) })
    $lines += @('', "## $($Labels.Resources)", '')
    $lines += @($Module.Resources | ForEach-Object { "- ``$_``" })
    return ($lines -join "`n") + "`n"
}

function New-ApiPage([object[]]$Endpoints) {
    $lines = @("_$($Labels.Generated)_")
    foreach ($endpoint in $Endpoints) {
        $lines += @('', "## $($endpoint.Method) $($endpoint.Path)", '')
        if ($endpoint.Description) { $lines += @($endpoint.Description, '') }
        if ($endpoint.Parameters.Count) {
            $lines += @("### $($Labels.Parameters)", '')
            $lines += New-Table @($Labels.Name, $Labels.Location, $Labels.Description) @($endpoint.Parameters | ForEach-Object {
                    $location = if ($_.Required) { "$($_.In), $($Labels.Required)" } else { $_.In }
                    , @("``$($_.Name)``", $location, $_.Description)
                })
            $lines += ''
        }
        $lines += @("### $($Labels.Responses)", '')
        $lines += New-Table @($Labels.Code, $Labels.Description) @($endpoint.Responses | ForEach-Object { , @("``$($_.Code)``", $_.Description) })
    }
    return ($lines -join "`n") + "`n"
}

function New-TasksPage([object[]]$Tasks) {
    $lines = @("_$($Labels.Generated)_", '')
    $lines += New-Table @($Labels.Task, $Labels.Description, $Labels.Parameters) @($Tasks | ForEach-Object {
            , @("``$($_.Name)``", $_.Description, (@($_.Parameters | ForEach-Object { "``$_``" }) -join ', '))
        })
    return ($lines -join "`n") + "`n"
}

function New-RootPage($Settings) {
    $lines = @("_$($Labels.Generated)_", '', '[[_TOSP_]]')
    if ($Settings.ReleaseNotes.Count) {
        $lines += @('', "## $($Labels.ReleaseNotes)", '')
        foreach ($notes in $Settings.ReleaseNotes) {
            $titles = @("$($notes.page)".Trim('/') -split '/' | Where-Object { $_ })
            $lines += "- [$($notes.name)]($(Get-PageUrl $Settings $titles))"
        }
    }
    return ($lines -join "`n") + "`n"
}

function Add-Missing([System.Collections.IDictionary]$Missing, [string]$Repository, [string]$Entry) {
    $key = if ($Repository) { $Repository } else { '?' }
    if (-not $Missing.Contains($key)) { $Missing[$key] = [System.Collections.Generic.List[string]]::new() }
    $Missing[$key].Add($Entry)
}

# Le pagine come percorsi della wiki (titoli) con il loro testo, l'indice delle voci e le voci senza descrizione.
function New-Reference($Settings) {
    $root = $Settings.WikiRoot
    $pages = [System.Collections.Generic.List[object]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()
    $missing = [ordered]@{}
    $pages.Add([pscustomobject]@{ Titles = @($root); Content = (New-RootPage $Settings) })

    if ($Settings.ModulesDirectory) {
        $pages.Add([pscustomobject]@{ Titles = @($root, $Labels.ModulesPage); Content = "_$($Labels.Generated)_`n`n[[_TOSP_]]`n" })
        foreach ($module in (Read-TerraformModules $Settings.ModulesDirectory)) {
            $titles = @($root, $Labels.ModulesPage, $module.Name)
            $pages.Add([pscustomobject]@{ Titles = $titles; Content = (New-ModulePage $module) })
            $entries.Add([pscustomobject]@{ kind = 'module'; name = $module.Name; url = (Get-PageUrl $Settings $titles) })
            foreach ($variable in @($module.Variables | Where-Object { -not $_.Description })) { Add-Missing $missing $Settings.ModulesRepository ($Labels.MissingVariable -f $variable.Name, $module.Name) }
            foreach ($output in @($module.Outputs | Where-Object { -not $_.Description })) { Add-Missing $missing $Settings.ModulesRepository ($Labels.MissingOutput -f $output.Name, $module.Name) }
        }
    }

    if ($Settings.Apis.Count) {
        $pages.Add([pscustomobject]@{ Titles = @($root, $Labels.ApisPage); Content = "_$($Labels.Generated)_`n`n[[_TOSP_]]`n" })
        foreach ($api in $Settings.Apis) {
            $endpoints = @(Read-OpenApiEndpoints @($api.documents))
            $titles = @($root, $Labels.ApisPage, $api.name)
            $pages.Add([pscustomobject]@{ Titles = $titles; Content = (New-ApiPage $endpoints) })
            $entries.Add([pscustomobject]@{ kind = 'api'; name = $api.name; url = (Get-PageUrl $Settings $titles) })
            foreach ($endpoint in @($endpoints | Where-Object { -not $_.Description })) { Add-Missing $missing $api.repository ($Labels.MissingEndpoint -f "$($endpoint.Method) $($endpoint.Path)", $api.name) }
        }
    }

    if ($Settings.Taskfile) {
        $tasks = @(Read-TaskfileTasks $Settings.Taskfile)
        $titles = @($root, $Labels.TasksPage)
        $pages.Add([pscustomobject]@{ Titles = $titles; Content = (New-TasksPage $tasks) })
        foreach ($task in $tasks) {
            $entries.Add([pscustomobject]@{ kind = 'task'; name = $task.Name; url = (Get-PageUrl $Settings $titles) })
            if (-not $task.Description) { Add-Missing $missing $Settings.TaskfileRepository ($Labels.MissingTask -f $task.Name) }
        }
    }
    return [pscustomobject]@{ Pages = $pages.ToArray(); Entries = $entries.ToArray(); Missing = $missing }
}

#endregion

#region Scrittura nella wiki

function Write-WikiFile($Settings, [string]$RelativePath, [string]$Content) {
    $path = Join-Path $Settings.WikiDirectory $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, $Content)
}

function Get-PageFile($Page) { return ((@($Page.Titles | ForEach-Object { ConvertTo-WikiName $_ }) -join '/') + '.md') }

function Write-Reference($Settings, $Reference) {
    $rootName = ConvertTo-WikiName $Settings.WikiRoot
    $attachments = "$AttachmentsFolder/$rootName"
    Remove-Item -Recurse -Force (Join-Path $Settings.WikiDirectory $rootName), (Join-Path $Settings.WikiDirectory "$rootName.md"), (Join-Path $Settings.WikiDirectory $attachments) -ErrorAction SilentlyContinue
    $orders = [ordered]@{}
    foreach ($page in $Reference.Pages) {
        Write-WikiFile $Settings (Get-PageFile $page) $page.Content
        if ($page.Titles.Count -lt 2) { continue }
        $folder = (@($page.Titles | Select-Object -SkipLast 1 | ForEach-Object { ConvertTo-WikiName $_ }) -join '/')
        if (-not $orders.Contains($folder)) { $orders[$folder] = [System.Collections.Generic.List[string]]::new() }
        $orders[$folder].Add((ConvertTo-WikiName $page.Titles[-1]))
    }
    foreach ($folder in $orders.Keys) { Write-WikiFile $Settings "$folder/.order" (($orders[$folder] -join "`n") + "`n") }
    Write-WikiFile $Settings "$attachments/$IndexFile" (ConvertTo-Json -InputObject @{ entries = @($Reference.Entries) } -Depth 5)
    $orderFile = Join-Path $Settings.WikiDirectory '.order'
    $rootEntries = if (Test-Path $orderFile) { @([IO.File]::ReadAllLines($orderFile) | Where-Object { $_.Trim() }) } else { @() }
    if ($rootEntries -notcontains $rootName) { [IO.File]::WriteAllText($orderFile, ((@($rootEntries) + $rootName) -join "`n") + "`n") }
    return @("$rootName.md", $rootName, $attachments, '.order')
}

# Le pagine scritte da altre pubblicazioni sotto le radici indicate ricevono i link alla reference.
function Add-ReferenceLinksToWiki($Settings, [object[]]$Entries) {
    $changed = @()
    foreach ($root in $Settings.LinkRoots) {
        $rootName = ConvertTo-WikiName $root
        $files = @(Get-Item -LiteralPath (Join-Path $Settings.WikiDirectory "$rootName.md") -ErrorAction SilentlyContinue)
        $folder = Join-Path $Settings.WikiDirectory $rootName
        if (Test-Path -LiteralPath $folder -PathType Container) { $files += @(Get-ChildItem -LiteralPath $folder -Recurse -Filter '*.md' -File) }
        foreach ($file in $files) {
            $content = [IO.File]::ReadAllText($file.FullName)
            $linked = Add-ReferenceLinks $content $Entries
            if ($linked -ceq $content) { continue }
            [IO.File]::WriteAllText($file.FullName, $linked)
            $changed += [IO.Path]::GetRelativePath($Settings.WikiDirectory, $file.FullName) -replace '\\', '/'
        }
    }
    return $changed
}

function Invoke-WikiGit($Settings) {
    $output = git -C $Settings.WikiDirectory @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
    return $output
}

function Publish-ToWiki($Settings, $Reference) {
    $authorization = if ($Settings.AccessToken) { @('-c', "http.extraheader=AUTHORIZATION: bearer $($Settings.AccessToken)") } else { @() }
    $name = if ($env:BUILD_REQUESTEDFOR) { $env:BUILD_REQUESTEDFOR } else { 'Reference' }
    $email = if ($env:BUILD_REQUESTEDFOREMAIL) { $env:BUILD_REQUESTEDFOREMAIL } else { 'reference@noreply.local' }
    $version = if ($env:BUILD_BUILDNUMBER) { $env:BUILD_BUILDNUMBER } else { 'locale' }
    for ($attempt = 1; $attempt -le $MaxPushAttempts; $attempt++) {
        Invoke-WikiGit $Settings @authorization fetch -q origin $Settings.WikiBranch | Out-Null
        Invoke-WikiGit $Settings reset -q --hard FETCH_HEAD | Out-Null
        $paths = @(Write-Reference $Settings $Reference) + @(Add-ReferenceLinksToWiki $Settings $Reference.Entries)
        Invoke-WikiGit $Settings add -A -- @($paths | Where-Object { (Test-Path (Join-Path $Settings.WikiDirectory $_)) -or (git -C $Settings.WikiDirectory ls-files -- $_) }) | Out-Null
        git -C $Settings.WikiDirectory diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "La wiki mostra gia' la reference"
            return
        }
        $global:LASTEXITCODE = 0
        Invoke-WikiGit $Settings -c "user.name=$name" -c "user.email=$email" commit -q -m "$($Settings.WikiRoot) @ $version" | Out-Null
        git -C $Settings.WikiDirectory @authorization push -q origin "HEAD:refs/heads/$($Settings.WikiBranch)" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Wiki aggiornata: $($Reference.Pages.Count) pagine sotto /$($Settings.WikiRoot)"
            return
        }
        $global:LASTEXITCODE = 0
        Write-Host "Push rifiutato al tentativo ${attempt}: la wiki e' cambiata, si riscrive sopra il commit nuovo"
    }
    throw "la wiki non accetta il push dopo $MaxPushAttempts tentativi"
}

#endregion

function Publish-Reference {
    $settings = Get-ReferenceSettings
    if (-not $settings.WikiDirectory -or -not (Test-Path (Join-Path $settings.WikiDirectory '.git'))) { throw "WIKI_DIRECTORY non indica un checkout della wiki: '$($settings.WikiDirectory)'" }
    $reference = New-Reference $settings
    Publish-ToWiki $settings $reference
    Update-ReferenceBugs $settings $reference.Missing $Labels
}

try { Publish-Reference }
catch {
    Write-Host "##vso[task.logissue type=error]reference: $($_.Exception.Message)"
    exit 1
}
