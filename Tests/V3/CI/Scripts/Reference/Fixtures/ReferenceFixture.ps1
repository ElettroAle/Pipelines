# SPDX-License-Identifier: Apache-2.0

# Sorgenti finte della reference e wiki locale per i test di Publish-Reference.ps1: i moduli Terraform comuni
# di un repository di infrastruttura, le specifiche OpenAPI di due API, un Taskfile con un include e una wiki
# con un origin bare sul ramo wikiMaster, gia' popolata con le release notes e con pagine di altre
# pubblicazioni che nominano moduli, API e task.

function Set-SourceFile([string]$Root, [string]$Path, [string]$Content) {
    $file = Join-Path $Root $Path
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    [IO.File]::WriteAllText($file, ($Content -replace "`r`n", "`n"))
}

function New-ModuleSource([string]$Root, [string]$Module, [string]$Resource) {
    Set-SourceFile $Root "infrastructure/Common/Modules/$Module/variables.tf" @"
variable "name" {
  type        = string
  description = "Nome della risorsa del modulo $Module."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tag della risorsa del modulo $Module."
}
"@
    Set-SourceFile $Root "infrastructure/Common/Modules/$Module/outputs.tf" @"
output "id" {
  value       = $Resource.this.id
  description = "Identificativo della risorsa del modulo $Module."
}
"@
    Set-SourceFile $Root "infrastructure/Common/Modules/$Module/main.tf" @"
resource "$Resource" "this" {
  name = var.name
  tags = var.tags
}
"@
}

function New-OpenApiDocument([hashtable]$Paths) {
    return ConvertTo-Json -Depth 20 -InputObject ([ordered]@{ openapi = '3.0.1'; info = @{ title = 'API'; version = 'v1' }; paths = $Paths })
}

function New-Endpoint([string]$Summary, [object[]]$Parameters = @(), [hashtable]$Responses = @{ '200' = @{ description = 'OK' } }) {
    $operation = [ordered]@{ responses = $Responses }
    if ($Summary) { $operation.summary = $Summary }
    if ($Parameters) { $operation.parameters = $Parameters }
    return $operation
}

$EngineConversations = New-Endpoint 'Apre una conversazione' -Responses @{ '201' = @{ description = 'Conversazione aperta' }; '400' = @{ description = 'Richiesta non valida' } }
$EngineConversations.requestBody = @{ required = $true; description = 'Il canale della conversazione'; content = @{ 'application/json' = @{} } }

function New-ReferenceSources {
    $root = Join-Path ([IO.Path]::GetTempPath()) "pester-reference-$(New-Guid)"
    foreach ($module in @(
            @{ Name = 'ServiceBus'; Resource = 'azurerm_servicebus_topic' }
            @{ Name = 'ServiceBusSubscription'; Resource = 'azurerm_servicebus_subscription' }
            @{ Name = 'PrivateEndpoint'; Resource = 'azurerm_private_endpoint' }
            @{ Name = 'AppService'; Resource = 'azurerm_linux_web_app' }
            @{ Name = 'FunctionApp'; Resource = 'azurerm_linux_function_app' })) {
        New-ModuleSource $root $module.Name $module.Resource
    }
    Set-SourceFile $root 'openapi/engine-v1.json' (New-OpenApiDocument @{
            '/api/v1/conversations'                 = @{ post = $EngineConversations }
            '/api/v1/conversations/{conversationId}' = @{
                parameters = @(@{ name = 'conversationId'; in = 'path'; required = $true; description = 'La conversazione' })
                get        = New-Endpoint 'Legge una conversazione' -Responses @{ '200' = @{ description = 'La conversazione' }; '404' = @{ '$ref' = '#/components/responses/NotFound' } }
            }
        })
    $engineV1 = [IO.File]::ReadAllText((Join-Path $root 'openapi/engine-v1.json')) | ConvertFrom-Json -AsHashtable
    $engineV1.components = @{ responses = @{ NotFound = @{ description = 'Conversazione inesistente' } } }
    Set-SourceFile $root 'openapi/engine-v1.json' (ConvertTo-Json -Depth 20 -InputObject $engineV1)
    Set-SourceFile $root 'openapi/engine-v2.json' (New-OpenApiDocument @{
            '/api/v2/tenants' = @{ get = New-Endpoint 'Elenca i tenant' -Parameters @(@{ name = 'page'; in = 'query'; description = 'La pagina' }) }
        })
    Set-SourceFile $root 'openapi/bff.json' (New-OpenApiDocument @{
            '/sessions/{id}' = @{ get = New-Endpoint 'Legge una sessione' -Parameters @(@{ name = 'id'; in = 'path'; required = $true; description = 'La sessione' }) }
        })
    Set-SourceFile $root 'infrastructure/Taskfile.yml' @'
version: '3'

vars:
  SCRIPT_PATH: Common/scripts/create-hardlinks.ps1

includes:
  quality:
    taskfile: ./Common/Taskfiles/quality.yml
    flatten: true
    dir: '.'

tasks:
  terraform:plan:
    desc: "Esegue terraform plan per un modulo e ambiente (richiede MODULE e ENV)"
    cmds:
      - task: _validate
        vars: {MODULE: '{{.MODULE}}', ENV: '{{.ENV}}'}

  terraform:plan-destroy:
    desc: "Esegue terraform plan -destroy per un modulo e ambiente (richiede MODULE e ENV)"
    cmds:
      - pwsh -File {{.SCRIPT_PATH}} -Module {{.MODULE}} -Env {{.ENV}} -Destroy

  environment:prepare:
    desc: 'Crea gli hard link di un ambiente (richiede MODULE e ENV)'
    vars:
      TARGET: '{{.MODULE}}/environments/{{.ENV}}'
    cmds:
      - pwsh -File {{.SCRIPT_PATH}} -Target {{.TARGET}}

  _validate:
    internal: true
    cmds:
      - pwsh -Command "if (-not '{{.MODULE}}') { exit 1 }"
'@
    Set-SourceFile $root 'infrastructure/Common/Taskfiles/quality.yml' @'
version: '3'

tasks:
  terraform:quality-servicebus:
    desc: "Quality Service Bus: fmt-check e validate (richiede MODULE e ENV, opzionale OUT)"
    cmds:
      - pwsh -File quality.ps1 -Module {{.MODULE}} -Env {{.ENV}} -Out {{.OUT | default "plan.json"}}
'@
    return $root
}

function Invoke-Git([string]$Directory) {
    $output = git -C $Directory @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git ${args}: $output" }
    return $output
}

function Set-WikiFile([string]$Directory, [string]$Path, [string]$Content) { Set-SourceFile $Directory $Path $Content }

function Add-WikiCommit([string]$Directory, [string]$Message) {
    Invoke-Git $Directory add -A | Out-Null
    Invoke-Git $Directory -c user.name=Wiki -c user.email=wiki@example.org commit -q -m $Message | Out-Null
    Invoke-Git $Directory push -q origin HEAD:refs/heads/wikiMaster | Out-Null
}

$WikiPages = [ordered]@{
    'Architettura/Concetti-trasversali.md'       = "Il canale degli eventi di sessione vive nel modulo ServiceBus dell'Hub.`n`nOgni ServiceBus ha un topic.`n"
    'Architettura/Vista-dei-building-block.md'   = "## BFF`n`nIl BFF inoltra al Motore le richieste del frontend.`n"
    'Guide/procedura%3A-aggiungere-un-tenant.md' = "Prima dell'apply si lancia ``terraform:plan`` sul modulo.`n"
}

function New-Wiki {
    $root = Join-Path ([IO.Path]::GetTempPath()) "pester-reference-wiki-$(New-Guid)"
    $origin = Join-Path $root 'origin.git'
    $seed = Join-Path $root 'seed'
    git init -q --bare -b wikiMaster $origin
    git clone -q $origin $seed 2>&1 | Out-Null
    Invoke-Git $seed checkout -q -b wikiMaster | Out-Null
    Set-WikiFile $seed '.order' "Release-notes`nArchitettura`nGuide`n"
    Set-WikiFile $seed 'Release-notes.md' "[[_TOSP_]]`n"
    Set-WikiFile $seed 'Release-notes/AI.md' "# AI`n"
    Set-WikiFile $seed 'Architettura.md' "[[_TOSP_]]`n"
    Set-WikiFile $seed 'Guide.md' "[[_TOSP_]]`n"
    foreach ($page in $WikiPages.Keys) { Set-WikiFile $seed $page $WikiPages[$page] }
    Add-WikiCommit $seed 'Wiki'
    $checkout = Join-Path $root 'checkout'
    git clone -q -b wikiMaster $origin $checkout 2>&1 | Out-Null
    return [pscustomobject]@{ Root = $root; Origin = $origin; Seed = $seed; Checkout = $checkout }
}

# Lo stato della wiki come lo vede chi la apre: l'ultimo commit di wikiMaster nell'origin.
function Get-WikiPage($Wiki, [string]$Path) {
    $previousEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
    try { $content = git -C $Wiki.Origin show "wikiMaster:$Path" 2>$null }
    finally { [Console]::OutputEncoding = $previousEncoding }
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return $null }
    return ($content -join "`n")
}

function Get-WikiLastCommit($Wiki) {
    return [pscustomobject]@{
        Count   = [int](git -C $Wiki.Origin rev-list --count wikiMaster)
        Message = "$(git -C $Wiki.Origin log -1 --format=%s wikiMaster)"
    }
}

function Invoke-ReferenceScript([string]$ScriptPath, [string]$Sources, $Wiki, [hashtable]$Environment = @{}) {
    $settings = @{
        DOCUMENT_LANGUAGE             = 'IT'
        WIKI_DIRECTORY                = $Wiki.Checkout
        WIKI_BRANCH                   = ''
        WIKI_ROOT                     = ''
        WIKI_URL                      = ''
        REFERENCE_MODULES_DIRECTORY   = Join-Path $Sources 'infrastructure/Common/Modules'
        REFERENCE_MODULES_REPOSITORY  = 'Aidea.Dxp.Infrastructure'
        REFERENCE_TASKFILE            = Join-Path $Sources 'infrastructure/Taskfile.yml'
        REFERENCE_TASKFILE_REPOSITORY = 'Aidea.Dxp.Infrastructure'
        REFERENCE_APIS                = ConvertTo-Json -Depth 5 -InputObject @(
            @{ name = 'API del Motore'; repository = 'Aidea.Dxp.AI'; documents = @((Join-Path $Sources 'openapi/engine-v1.json'), (Join-Path $Sources 'openapi/engine-v2.json')) }
            @{ name = 'BFF'; repository = 'Aidea.Dxp.Bff.Web'; documents = @((Join-Path $Sources 'openapi/bff.json')) })
        REFERENCE_RELEASE_NOTES       = ConvertTo-Json -InputObject @(@{ name = 'AI'; page = '/Release notes/AI' }, @{ name = 'BFF'; page = '/Release notes/BFF' }, @{ name = 'Frontend'; page = '/Release notes/Frontend' })
        REFERENCE_LINK_ROOTS          = 'Architettura;Guide'
        REFERENCE_WORK_ITEM_TYPE      = ''
        SYSTEM_COLLECTIONURI          = 'https://dev.azure.com/Org/'
        SYSTEM_TEAMPROJECT            = 'Progetto'
        SYSTEM_ACCESSTOKEN            = ''
        BUILD_BUILDNUMBER             = '20261116.1'
    }
    foreach ($name in $Environment.Keys) { $settings[$name] = $Environment[$name] }
    $previous = @{}
    foreach ($name in $settings.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $settings[$name])
    }
    try {
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoProfile -NonInteractive -File $ScriptPath 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
    finally {
        foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    }
}

function Get-WikiUrl([string[]]$Titles) {
    return 'https://dev.azure.com/Org/Progetto/_wiki/wikis/Progetto.wiki?pagePath=/' + (@($Titles | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
}
