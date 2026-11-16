# SPDX-License-Identifier: Apache-2.0

# Lettura delle sorgenti della reference: i moduli Terraform con terraform-docs, gli endpoint dalle
# specifiche OpenAPI, i task di un Taskfile di go-task con i suoi include.

$TerraformDocsVersion = '0.24.0'
# SHA-256 del file terraform-docs-v<versione>.sha256sum della release.
$TerraformDocsArchives = @{
    'Windows' = @{ Name = "terraform-docs-v$TerraformDocsVersion-windows-amd64.zip"; Sha256 = 'AFC02CBDF63726D3E5FB26A077CA1F24ACD4820D7E44C21B03A3E030F9266490'; Exe = 'terraform-docs.exe' }
    'Linux'   = @{ Name = "terraform-docs-v$TerraformDocsVersion-linux-amd64.tar.gz"; Sha256 = '9005DAF969DE0B50134493A2C00078B49F5F5B39D021CDA7C89BF4D4F3D776D3'; Exe = 'terraform-docs' }
}
$OpenApiMethods = @('get', 'put', 'post', 'patch', 'delete', 'head', 'options', 'trace')
# Variabili che go-task definisce da se': un task che le legge non le riceve da chi lo lancia.
$TaskBuiltInVariables = @('CLI_ARGS', 'CLI_ARGS_LIST', 'CLI_FORCE', 'CLI_SILENT', 'CLI_VERBOSE', 'CLI_OFFLINE', 'CLI_ASSUME_YES',
    'TASK', 'TASK_EXE', 'TASK_NAME', 'TASK_DIR', 'TASK_VERSION', 'ROOT_TASKFILE', 'ROOT_DIR', 'TASKFILE', 'TASKFILE_DIR',
    'USER_WORKING_DIR', 'CHECKSUM', 'TIMESTAMP', 'ITEM', 'EXIT_CODE', 'MATCH', 'ALIAS', 'KEY')

#region terraform-docs

function Get-TerraformDocsPath {
    if ($env:TERRAFORM_DOCS_PATH) { return $env:TERRAFORM_DOCS_PATH }
    $platform = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Windows' } else { 'Linux' }
    $archive = $TerraformDocsArchives[$platform]
    $toolsRoot = if ($env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY } else { [IO.Path]::GetTempPath() }
    $installDir = Join-Path $toolsRoot "terraform-docs/$TerraformDocsVersion"
    $exePath = Join-Path $installDir $archive.Exe
    if (Test-Path $exePath) { return $exePath }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    $archivePath = Join-Path $installDir $archive.Name
    $url = "https://github.com/terraform-docs/terraform-docs/releases/download/v$TerraformDocsVersion/$($archive.Name)"
    Write-Host "Download terraform-docs $TerraformDocsVersion da $url"
    Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing
    $actualHash = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ne $archive.Sha256) {
        Remove-Item -Force $archivePath
        throw "checksum di $($archive.Name) non valido: atteso $($archive.Sha256), ottenuto $actualHash"
    }
    if ($archive.Name.EndsWith('.zip')) { Expand-Archive -Path $archivePath -DestinationPath $installDir -Force }
    else {
        tar -xzf $archivePath -C $installDir
        chmod +x $exePath
    }
    Remove-Item -Force $archivePath
    return $exePath
}

function Read-TerraformModule([string]$Directory) {
    $exe = Get-TerraformDocsPath
    $output = & $exe json --sort-by name $Directory 2>&1
    if ($LASTEXITCODE -ne 0) { throw "terraform-docs su ${Directory}: $output" }
    $module = ($output -join "`n") | ConvertFrom-Json
    return [pscustomobject]@{
        Name      = Split-Path $Directory -Leaf
        Variables = @($module.inputs | Where-Object { $_ } | ForEach-Object {
                [pscustomobject]@{ Name = $_.name; Type = "$($_.type)"; Default = $_.default; Required = [bool]$_.required; Description = "$($_.description)".Trim() }
            })
        Outputs   = @($module.outputs | Where-Object { $_ } | ForEach-Object {
                [pscustomobject]@{ Name = $_.name; Description = "$($_.description)".Trim() }
            })
        Resources = @($module.resources | Where-Object { $_ -and $_.mode -eq 'managed' } | ForEach-Object { "$($_.provider)_$($_.type).$($_.name)" })
    }
}

function Read-TerraformModules([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw "cartella dei moduli Terraform inesistente: $Directory" }
    return @(Get-ChildItem -LiteralPath $Directory -Directory | Sort-Object Name |
        Where-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.tf' -File } |
        ForEach-Object { Read-TerraformModule $_.FullName })
}

#endregion

#region OpenAPI

function Resolve-OpenApiReference($Document, $Item) {
    if ($Item -isnot [System.Collections.IDictionary] -or -not $Item.Contains('$ref')) { return $Item }
    $target = $Document
    foreach ($segment in ($Item['$ref'] -replace '^#/', '' -split '/')) {
        if ($target -isnot [System.Collections.IDictionary] -or -not $target.Contains($segment)) { return $Item }
        $target = $target[$segment]
    }
    return $target
}

function Get-OpenApiDescription($Operation) {
    $summary = "$($Operation['summary'])".Trim()
    $description = "$($Operation['description'])".Trim()
    if (-not $description -or $description -eq $summary) { return $summary }
    return (@($summary, $description) | Where-Object { $_ }) -join ' '
}

function Get-OpenApiParameters($Document, $PathItem, $Operation) {
    $parameters = [ordered]@{}
    foreach ($item in @($PathItem['parameters']) + @($Operation['parameters'])) {
        $parameter = Resolve-OpenApiReference $Document $item
        if ($parameter -isnot [System.Collections.IDictionary] -or -not $parameter['name']) { continue }
        $parameters["$($parameter['in'])/$($parameter['name'])"] = [pscustomobject]@{
            Name = "$($parameter['name'])"; In = "$($parameter['in'])"; Required = [bool]$parameter['required']; Description = "$($parameter['description'])".Trim()
        }
    }
    $body = Resolve-OpenApiReference $Document $Operation['requestBody']
    if ($body -is [System.Collections.IDictionary]) {
        $types = if ($body['content'] -is [System.Collections.IDictionary]) { @($body['content'].Keys) -join ', ' } else { '' }
        $parameters['body'] = [pscustomobject]@{ Name = $types; In = 'body'; Required = [bool]$body['required']; Description = "$($body['description'])".Trim() }
    }
    return @($parameters.Values)
}

function Get-OpenApiResponses($Document, $Operation) {
    if ($Operation['responses'] -isnot [System.Collections.IDictionary]) { return @() }
    return @($Operation['responses'].Keys | Sort-Object | ForEach-Object {
            $response = Resolve-OpenApiReference $Document $Operation['responses'][$_]
            [pscustomobject]@{ Code = "$_"; Description = "$($response['description'])".Trim() }
        })
}

function Read-OpenApiEndpoints([string[]]$Paths) {
    $endpoints = [ordered]@{}
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "specifica OpenAPI inesistente: $path" }
        $document = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        if ($document['paths'] -isnot [System.Collections.IDictionary]) { continue }
        foreach ($route in $document['paths'].Keys) {
            $pathItem = $document['paths'][$route]
            foreach ($method in $OpenApiMethods) {
                if (-not $pathItem.Contains($method)) { continue }
                $operation = $pathItem[$method]
                $endpoints["$($method.ToUpperInvariant()) $route"] = [pscustomobject]@{
                    Method      = $method.ToUpperInvariant()
                    Path        = $route
                    Description = Get-OpenApiDescription $operation
                    Parameters  = @(Get-OpenApiParameters $document $pathItem $operation)
                    Responses   = @(Get-OpenApiResponses $document $operation)
                }
            }
        }
    }
    return @($endpoints.Values | Sort-Object Path, @{ Expression = { [array]::IndexOf($OpenApiMethods, $_.Method.ToLowerInvariant()) } })
}

#endregion

#region Taskfile

# Un Taskfile si legge per indentazione: bastano le chiavi dei blocchi, desc, internal, vars e
# include, senza un parser YAML da scaricare.
function Get-YamlIndent([string]$Line) { return $Line.Length - $Line.TrimStart(' ').Length }

function Test-YamlContentLine([string]$Line) { return $Line.Trim() -and -not $Line.TrimStart().StartsWith('#') }

function ConvertFrom-YamlScalar([string]$Value) {
    $text = $Value.Trim()
    if ($text -match '^"(.*)"\s*(#.*)?$') { return ($Matches[1] -replace '\\"', '"' -replace '\\\\', '\') }
    if ($text -match "^'(.*)'\s*(#.*)?$") { return ($Matches[1] -replace "''", "'") }
    return ($text -replace '\s+#.*$', '')
}

# I figli diretti di un blocco: per ogni chiave, il valore sulla sua riga e le righe che contiene.
function Get-YamlEntries([string[]]$Lines) {
    $entries = [System.Collections.Generic.List[object]]::new()
    $content = @($Lines | Where-Object { Test-YamlContentLine $_ })
    if (-not $content) { return @() }
    $indent = Get-YamlIndent $content[0]
    $current = $null
    foreach ($line in $Lines) {
        if ((Test-YamlContentLine $line) -and (Get-YamlIndent $line) -eq $indent -and $line -match '^\s*(\S.*?):(?:\s+(.*))?\s*$') {
            $current = [pscustomobject]@{ Key = (ConvertFrom-YamlScalar $Matches[1]); Value = "$($Matches[2])"; Lines = [System.Collections.Generic.List[string]]::new() }
            $entries.Add($current)
            continue
        }
        if ($current) { $current.Lines.Add($line) }
    }
    return $entries.ToArray()
}

function Get-YamlEntry([object[]]$Entries, [string]$Key) { return $Entries | Where-Object Key -eq $Key | Select-Object -First 1 }

function Get-YamlText($Entry) {
    if (-not $Entry) { return '' }
    if ($Entry.Value -match '^[|>][+-]?\s*$') {
        $joiner = if ($Entry.Value.StartsWith('|')) { "`n" } else { ' ' }
        return (@($Entry.Lines | ForEach-Object Trim | Where-Object { $_ }) -join $joiner)
    }
    return ConvertFrom-YamlScalar $Entry.Value
}

function Get-YamlKeys($Entry) {
    if (-not $Entry) { return @() }
    if ($Entry.Value -match '^\{(.*)\}') { return @($Matches[1] -split ',' | ForEach-Object { ($_ -split ':', 2)[0].Trim() } | Where-Object { $_ }) }
    return @(Get-YamlEntries $Entry.Lines | ForEach-Object Key)
}

function Read-Taskfile([string]$Path, [string]$Namespace, [string[]]$InheritedVariables) {
    if ((Test-Path -LiteralPath $Path -PathType Container)) { $Path = Join-Path $Path 'Taskfile.yml' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Taskfile inesistente: $Path" }
    $root = Get-YamlEntries ([IO.File]::ReadAllLines($Path))
    $globalVariables = @($InheritedVariables) + @(Get-YamlKeys (Get-YamlEntry $root 'vars'))
    $tasks = @()
    $tasksEntry = Get-YamlEntry $root 'tasks'
    foreach ($task in @(if ($tasksEntry) { Get-YamlEntries $tasksEntry.Lines })) {
        $properties = Get-YamlEntries $task.Lines
        if ((Get-YamlText (Get-YamlEntry $properties 'internal')) -eq 'true') { continue }
        $defined = @($globalVariables) + @(Get-YamlKeys (Get-YamlEntry $properties 'vars')) + $TaskBuiltInVariables
        $text = (@($task.Value) + $task.Lines) -join "`n"
        $parameters = @([regex]::Matches($text, '\{\{[^}]*?\.([A-Z_][A-Z0-9_]*)') | ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $defined -notcontains $_ } | Select-Object -Unique)
        $tasks += [pscustomobject]@{ Name = "$Namespace$($task.Key)"; Description = Get-YamlText (Get-YamlEntry $properties 'desc'); Parameters = $parameters }
    }
    $includesEntry = Get-YamlEntry $root 'includes'
    foreach ($include in @(if ($includesEntry) { Get-YamlEntries $includesEntry.Lines })) {
        $properties = Get-YamlEntries $include.Lines
        $file = if ($include.Value) { ConvertFrom-YamlScalar $include.Value } else { Get-YamlText (Get-YamlEntry $properties 'taskfile') }
        $includePath = Join-Path (Split-Path $Path) $file
        if ((Get-YamlText (Get-YamlEntry $properties 'optional')) -eq 'true' -and -not (Test-Path -LiteralPath $includePath)) { continue }
        $flatten = (Get-YamlText (Get-YamlEntry $properties 'flatten')) -eq 'true'
        $prefix = if ($flatten) { $Namespace } else { "$Namespace$($include.Key):" }
        $tasks += Read-Taskfile $includePath $prefix (@($globalVariables) + @(Get-YamlKeys (Get-YamlEntry $properties 'vars')))
    }
    return $tasks
}

function Read-TaskfileTasks([string]$Path) {
    return @(Read-Taskfile $Path '' @() | Sort-Object Name)
}

#endregion
