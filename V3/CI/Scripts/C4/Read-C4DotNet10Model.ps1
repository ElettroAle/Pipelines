# SPDX-License-Identifier: Apache-2.0

# Lettore .NET 10 del modello C4 generato (contratto in C4CodeModel.ps1). Le applicazioni sono
# container; i progetti di produzione che un'applicazione raggiunge con i riferimenti sono i suoi
# componenti, legati da quei riferimenti nella direzione del flusso del controllo: un progetto che
# implementa un'interfaccia del progetto che referenzia ne e' l'adattatore, e la relazione va dalla
# porta all'adattatore, tranne che per l'applicazione, che compone i progetti. Il tipo di un progetto
# viene dalle regole di .NET 10 di DotNet10Code.ps1, provate solo su .NET 10: un progetto di un'altra versione,
# o di un tipo che le regole non riconoscono, ferma la lettura invece di essere letto con regole non sue.
# Gli indirizzi a cui un'applicazione si avvia in locale vengono dai profili del suo
# Properties/launchSettings.json.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/DocumentLanguage.ps1"
. "$PSScriptRoot/DotNet10Code.ps1"

$SupportedTargetFramework = '^net10\.0(-[a-z0-9.]+)?$'
$ApplicationTechnologies = @{
    web       = 'ASP.NET Core'
    functions = 'Azure Functions'
}
$ApplicationTag = $DocumentLanguage.ApplicationTag

function Get-DeclaredInterfaces([string[]]$Code) {
    return @($Code | ForEach-Object { [regex]::Matches($_, "$TypeDeclarationStart" + 'interface\s+(\w+)') } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

# La lista dei tipi base comincia ai due punti dopo il nome, gli argomenti generici e il costruttore
# primario, e finisce alla graffa, al punto e virgola o ai vincoli generici.
function Get-BaseTypeList([string]$Code, [int]$Start) {
    $depth = 0
    for ($index = $Start; $index -lt $Code.Length; $index++) {
        $character = $Code[$index]
        if ($character -in '<', '(') { $depth++ }
        elseif ($character -in '>', ')') { $depth-- }
        elseif ($depth -eq 0 -and $character -in '{', ';') { return '' }
        elseif ($depth -eq 0 -and $character -eq ':') { break }
    }
    $list = [regex]::Match($Code.Substring([Math]::Min($index + 1, $Code.Length)), '^[^{;]*?(?=\swhere\s|\{|;|$)').Value
    while ($list -match '<[^<>]*>') { $list = $list -replace '<[^<>]*>', '' }
    return $list
}

function Get-ImplementedTypes([string[]]$Code) {
    return @(foreach ($text in $Code) {
            foreach ($declaration in [regex]::Matches($text, "$TypeDeclarationStart" + '(?:record\s+(?:class|struct)|class|record|struct)\s+\w+')) {
                (Get-BaseTypeList $text ($declaration.Index + $declaration.Length)) -split ',' |
                    ForEach-Object { ($_.Trim() -split '\.')[-1] } | Where-Object { $_ }
            }
        }) | Sort-Object -Unique
}

function Add-ProjectTypes($Projects) {
    foreach ($project in $Projects.Values) {
        $code = Get-ProjectCode $project
        $project | Add-Member -NotePropertyName Code -NotePropertyValue ($code -join "`n")
        $project | Add-Member -NotePropertyName Interfaces -NotePropertyValue @(Get-DeclaredInterfaces $code)
        $project | Add-Member -NotePropertyName Implemented -NotePropertyValue @(Get-ImplementedTypes $code)
    }
}

function Get-ImplementedPorts($Project, $Referenced) {
    if ($ApplicationTechnologies.ContainsKey("$($Project.Kind)")) { return @() }
    return @($Project.Implemented | Where-Object { $Referenced.Interfaces -contains $_ -and $Project.Interfaces -notcontains $_ })
}

function Test-UsesInterfaceOf($Project, $Referenced, [string[]]$ImplementedPorts) {
    return [bool]@($Referenced.Interfaces | Where-Object { $ImplementedPorts -notcontains $_ -and $Project.Code -match "\b$_\b" }).Count
}

# Un adattatore e' chiamato dal progetto di cui implementa le porte; se ne usa anche altre interfacce,
# chiama a sua volta quel progetto.
function Get-ControlFlow($Project, $Referenced) {
    $ports = @(Get-ImplementedPorts $Project $Referenced)
    if (-not $ports) { return [pscustomobject]@{ Caller = $Project; Called = $Referenced } }
    [pscustomobject]@{ Caller = $Referenced; Called = $Project }
    if (Test-UsesInterfaceOf $Project $Referenced $ports) { [pscustomobject]@{ Caller = $Project; Called = $Referenced } }
}

function Get-ProductionReferences($Project, $Projects) {
    return @($Project.References | Where-Object { $Projects.Contains($_) -and $Projects[$_].Kind -ne $TestKind } | ForEach-Object { $Projects[$_] })
}

function Get-ProjectClosure($Application, $Projects) {
    $visited = [ordered]@{}
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue($Application)
    while ($pending.Count) {
        $project = $pending.Dequeue()
        if ($visited.Contains($project.Path)) { continue }
        $visited[$project.Path] = $project
        Get-ProductionReferences $project $Projects | ForEach-Object { $pending.Enqueue($_) }
    }
    return @($visited.Values)
}

function Get-ComponentId([string]$ContainerId, $Project) {
    return "${ContainerId}__$(ConvertTo-Identifier $Project.Name)"
}

function Get-Applications($Projects) {
    return @($Projects.Values | Where-Object { $ApplicationTechnologies.ContainsKey("$($_.Kind)") } | Sort-Object Name)
}

function New-ApplicationContainer($Application, $Projects, [string[]]$AllNames) {
    $containerId = ConvertTo-Identifier $Application.Name
    $components = foreach ($project in (Get-ProjectClosure $Application $Projects | Sort-Object Name)) {
        [ordered]@{
            id         = Get-ComponentId $containerId $project
            name       = Remove-CommonPrefix $project.Name $AllNames
            codeName   = $project.Name
            sources    = @(Get-RelativePath (Split-Path $project.Path))
            technology = '.NET'
            properties = [ordered]@{}
        }
    }
    return [ordered]@{
        id         = $containerId
        name       = Remove-CommonPrefix $Application.Name $AllNames
        codeName   = $Application.Name
        sources    = @(Get-RelativePath (Split-Path $Application.Path))
        technology = $ApplicationTechnologies[$Application.Kind]
        tags       = @($ApplicationTag)
        properties = [ordered]@{}
        components = @($components)
    }
}

function Get-ApplicationRelationships($Application, $Projects) {
    $containerId = ConvertTo-Identifier $Application.Name
    foreach ($project in (Get-ProjectClosure $Application $Projects | Sort-Object Name)) {
        foreach ($referenced in (Get-ProductionReferences $project $Projects | Sort-Object Name -Unique)) {
            foreach ($flow in (Get-ControlFlow $project $referenced)) {
                New-C4Relationship (Get-ComponentId $containerId $flow.Caller) (Get-ComponentId $containerId $flow.Called)
            }
        }
    }
}

function Read-LaunchSettings($Application) {
    $path = Join-Path (Split-Path $Application.Path) 'Properties/launchSettings.json'
    if (-not (Test-Path $path -PathType Leaf)) { return $null }
    $source = Get-RelativePath $path
    try { $profiles = @((Get-Content -Raw $path | ConvertFrom-Json -ErrorAction Stop).profiles.PSObject.Properties.Value) }
    catch { return [pscustomobject]@{ Source = $source; Urls = $null } }
    $urls = @($profiles | Where-Object { $_.applicationUrl } | ForEach-Object { "$($_.applicationUrl)" -split ';' } | ForEach-Object Trim | Where-Object { $_ })
    return [pscustomobject]@{ Source = $source; Urls = $urls }
}

function Get-LaunchSettingsIssues($Applications) {
    foreach ($settings in @($Applications | ForEach-Object { Read-LaunchSettings $_ } | Where-Object { $_ })) {
        if ($null -eq $settings.Urls) { New-Issue $Repository 'profili di avvio che il lettore non legge' $settings.Source; continue }
        $settings.Urls | Where-Object { -not (ConvertTo-Address $_) } |
            ForEach-Object { New-Issue $Repository 'indirizzo di avvio che non e'' un indirizzo' "$($settings.Source): $_" }
    }
}

function Get-ApplicationAddresses($Application) {
    $settings = Read-LaunchSettings $Application
    if (-not $settings) { return }
    $containerId = ConvertTo-Identifier $Application.Name
    $settings.Urls | ForEach-Object { ConvertTo-Address $_ } | Sort-Object -Unique | ForEach-Object { New-C4Address $containerId $_ $settings.Source }
}

function Get-UnsupportedVersionIssues($Projects) {
    foreach ($project in $Projects.Values) {
        if (-not $project.TargetFrameworks) { New-Issue $Repository 'progetto .NET senza versione dichiarata' $project.Name; continue }
        $project.TargetFrameworks | Where-Object { $_ -notmatch $SupportedTargetFramework } |
            ForEach-Object { New-Issue $Repository 'progetto .NET di una versione che il lettore .NET 10 non legge' "$($project.Name) ($_)" }
    }
}

function Get-UnrecognizedIssues($Projects) {
    $Projects.Values | Where-Object { -not $_.Kind } | ForEach-Object { New-Issue $Repository 'progetto .NET di un tipo non riconosciuto' $_.Name }
}

function Get-ReadIssues {
    $sourceIssues = @(Get-SourceIssues)
    if ($sourceIssues) { return $sourceIssues }

    $projects = Read-DotNetProjects
    $unsupported = @(Get-UnsupportedVersionIssues $projects) + @(Get-UnrecognizedIssues $projects)
    if ($unsupported) { return $unsupported }

    Add-ProjectTypes $projects
    $applications = @(Get-Applications $projects)
    $launchIssues = @(Get-LaunchSettingsIssues $applications)
    if ($launchIssues) { return $launchIssues }

    $allNames = @($projects.Values | ForEach-Object Name)
    $containers = $applications | ForEach-Object { New-ApplicationContainer $_ $projects $allNames }
    $relationships = $applications | ForEach-Object { Get-ApplicationRelationships $_ $projects }
    $addresses = $applications | ForEach-Object { Get-ApplicationAddresses $_ }
    Write-C4Fragment 'dotnet10' @($projects.Keys | ForEach-Object { Get-RelativePath $_ }) $containers $relationships $addresses
}

Invoke-Verification { Get-ReadIssues } "Progetti .NET 10 di $Repository letti" 'Lettura dei progetti .NET 10 disattivata'
