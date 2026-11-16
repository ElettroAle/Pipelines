# SPDX-License-Identifier: Apache-2.0

# Lettore Terraform del modello C4 (contratto in C4CodeModel.ps1): gli ambienti di deployment dalla
# dichiarazione Terraform del repository sorgente, valutata ambiente per ambiente (TerraformValues.ps1)
# senza eseguire Terraform e senza leggere lo stato. C4_DEPLOYMENT_ENVIRONMENTS associa a ogni ambiente
# del modello la directory d'ambiente dei moduli radice (es. dev=dev-aidea;prod=prod-aidea); una
# directory che non vi compare entra negli ambienti con cui scambia remote state. C4_TERRAFORM_INSTANCES
# istanzia un modulo radice una volta per ogni directory che un glob trova, con il nome della directory in
# una variabile (es. Tenant-Customers:customer_tenant_id=environments/{environment}/data/*).
# I nodi si annidano per identificativo Azure: sottoscrizione, gruppo di risorse, rete virtuale, subnet,
# piano di hosting; un'applicazione sta nel suo piano, il piano nella subnet a cui le sue applicazioni si
# integrano (ADR del lettore), un private endpoint nella sua subnet, un servizio dati nel suo gruppo di
# risorse. Un container del modello (FRAGMENT_DIRECTORY) sta sulla risorsa che ha il suo nome nel codice o
# su quella che un frammento dichiara in hosts. Una risorsa che ospita un container o che gira su un piano,
# di un tipo che le regole non riconoscono, ferma la lettura nominandola.

. "$PSScriptRoot/../Common/VerificationGate.ps1"
. "$PSScriptRoot/../Common/DocumentLanguage.ps1"
. "$PSScriptRoot/C4CodeModel.ps1"
. "$PSScriptRoot/TerraformCode.ps1"
. "$PSScriptRoot/TerraformValues.ps1"

$EnvironmentMap = [ordered]@{}
"$env:C4_DEPLOYMENT_ENVIRONMENTS" -split ';' | ForEach-Object Trim | Where-Object { $_ -match '^([^=]+)=(.+)$' } | ForEach-Object { $EnvironmentMap[$Matches[1].Trim()] = $Matches[2].Trim() }
$InstanceRules = @("$env:C4_TERRAFORM_INSTANCES" -split ';' | ForEach-Object Trim | Where-Object { $_ -match '^([^:]+):([^=]+)=(.+)$' } |
        ForEach-Object { [pscustomobject]@{ Root = $Matches[1]; Variable = $Matches[2]; Glob = $Matches[3] } })

$Applications = @('azurerm_linux_web_app', 'azurerm_windows_web_app', 'azurerm_linux_function_app', 'azurerm_windows_function_app', 'azurerm_function_app_flex_consumption')
$Rules = @{
    azurerm_resource_group                     = @{ Level = 'resourceGroup'; Arm = 'Microsoft.Resources/resourceGroups' }
    azurerm_virtual_network                    = @{ Level = 'virtualNetwork'; Arm = 'Microsoft.Network/virtualNetworks' }
    azurerm_subnet                             = @{ Level = 'subnet'; Arm = 'Microsoft.Network/virtualNetworks/subnets' }
    azurerm_service_plan                       = @{ Level = 'hostingPlan'; Arm = 'Microsoft.Web/serverfarms' }
    azurerm_static_web_app                     = @{ Level = 'application'; Arm = 'Microsoft.Web/staticSites' }
    azurerm_private_endpoint                   = @{ Level = 'privateEndpoint'; Arm = 'Microsoft.Network/privateEndpoints' }
    azurerm_storage_account                    = @{ Level = 'service'; Arm = 'Microsoft.Storage/storageAccounts' }
    azurerm_key_vault                          = @{ Level = 'service'; Arm = 'Microsoft.KeyVault/vaults' }
    azurerm_cognitive_account                  = @{ Level = 'service'; Arm = 'Microsoft.CognitiveServices/accounts' }
    azurerm_ai_services                        = @{ Level = 'service'; Arm = 'Microsoft.CognitiveServices/accounts' }
    azurerm_search_service                     = @{ Level = 'service'; Arm = 'Microsoft.Search/searchServices' }
    azurerm_signalr_service                    = @{ Level = 'service'; Arm = 'Microsoft.SignalRService/signalR' }
    azurerm_servicebus_namespace               = @{ Level = 'service'; Arm = 'Microsoft.ServiceBus/namespaces' }
    azurerm_eventhub_namespace                 = @{ Level = 'service'; Arm = 'Microsoft.EventHub/namespaces' }
    azurerm_communication_service              = @{ Level = 'service'; Arm = 'Microsoft.Communication/communicationServices' }
    azurerm_email_communication_service        = @{ Level = 'service'; Arm = 'Microsoft.Communication/emailServices' }
    azurerm_monitor_data_collection_rule       = @{ Level = 'service'; Arm = 'Microsoft.Insights/dataCollectionRules' }
    azurerm_cosmosdb_account                   = @{ Level = 'service'; Arm = 'Microsoft.DocumentDB/databaseAccounts' }
    azurerm_mssql_server                       = @{ Level = 'service'; Arm = 'Microsoft.Sql/servers' }
    azurerm_postgresql_flexible_server         = @{ Level = 'service'; Arm = 'Microsoft.DBforPostgreSQL/flexibleServers' }
    azurerm_redis_cache                        = @{ Level = 'service'; Arm = 'Microsoft.Cache/redis' }
    azurerm_container_registry                 = @{ Level = 'service'; Arm = 'Microsoft.ContainerRegistry/registries' }
    azurerm_app_configuration                  = @{ Level = 'service'; Arm = 'Microsoft.AppConfiguration/configurationStores' }
    azurerm_app_service_virtual_network_swift_connection = @{ Level = 'integration' }
}
$Applications | ForEach-Object { $Rules[$_] = @{ Level = 'application'; Arm = 'Microsoft.Web/sites' } }
$ArmLevels = @{}
$Rules.Values | Where-Object Arm | ForEach-Object { $ArmLevels[$_.Arm.ToLowerInvariant()] = $_.Level }
$LevelTechnology = @{ subscription = 'Microsoft.Resources/subscriptions'; resourceGroup = 'Microsoft.Resources/resourceGroups' }

# ── Identificativi Azure ─────────────────────────────────────────────────────

function Get-ArmType($Resource) {
    $type = $Resource.Block.Labels[0]
    if ($type -eq 'azapi_resource') {
        $declared = Invoke-TfAttribute $Resource.Module $Resource.Block 'type' $Resource.Entry.Each $Resource.Entry.Count
        if ($declared -is [string]) { return ($declared -split '@')[0] }
        return $null
    }
    if ($Rules.ContainsKey($type)) { return $Rules[$type].Arm }
}

function Get-ProviderBlock($Module, [string]$Reference) {
    $parts = $Reference -split '\.'
    $alias = if ($parts.Count -gt 1) { $parts[1] } else { $null }
    if ($Module.Call) {
        $mapping = $Module.Call.Attributes['providers']
        $mapped = if ($mapping -and $mapping.Text -match "(?m)\b$([regex]::Escape($Reference))\s*=\s*([\w.]+)") { $Matches[1] } elseif ($alias) { $null } else { $parts[0] }
        if (-not $mapped) { return $null }
        return Get-ProviderBlock $Module.Parent $mapped
    }
    return $Module.Blocks | Where-Object { $_.Type -eq 'provider' -and $_.Labels[0] -eq $parts[0] -and (Get-StringLiteral $_.Attributes['alias']) -eq $alias } | Select-Object -First 1
}

function Get-RootModule($Module) {
    while ($Module.Parent) { $Module = $Module.Parent }
    return $Module
}

# La sottoscrizione del provider della risorsa: il suo valore, o la variabile che la porta.
function Get-SubscriptionId($Resource) {
    $declared = $Resource.Block.Attributes['provider']
    $reference = if ($declared) { $declared.Text.Trim() } else { ($Resource.Block.Labels[0] -split '_')[0] }
    $provider = Get-ProviderBlock $Resource.Module $reference
    if (-not $provider -or -not $provider.Attributes['subscription_id']) { return '{subscription}' }
    $value = Invoke-TfAttribute (Get-RootModule $Resource.Module) $provider 'subscription_id'
    return Format-TfValue $value
}

function Get-ResourceAttribute($Resource, [string]$Name) {
    return Invoke-TfAttribute $Resource.Module $Resource.Block $Name $Resource.Entry.Each $Resource.Entry.Count
}

function Get-ResourceGroupId($Resource) {
    return "/subscriptions/$(Get-SubscriptionId $Resource)/resourceGroups/$(Format-TfValue (Get-ResourceAttribute $Resource 'resource_group_name'))"
}

function Get-AzureId($Resource) {
    $type = $Resource.Block.Labels[0]
    $name = Format-TfValue (Get-ResourceAttribute $Resource 'name')
    if ($type -eq 'azapi_resource') {
        $armType = Get-ArmType $Resource
        $parent = Format-TfValue (Get-ResourceAttribute $Resource 'parent_id')
        if (-not $armType) { return [TfUnknown]::new("$($Resource.Address).id") }
        if ($parent -match '/providers/') { return "$parent/$(($armType -split '/')[-1])/$name" }
        return "$parent/providers/$armType/$name"
    }
    if (-not $Rules.ContainsKey($type) -or -not $Rules[$type].Arm) { return [TfUnknown]::new("$($Resource.Address).id") }
    if ($type -eq 'azurerm_resource_group') { return "/subscriptions/$(Get-SubscriptionId $Resource)/resourceGroups/$name" }
    if ($type -eq 'azurerm_subnet') {
        return "$(Get-ResourceGroupId $Resource)/providers/Microsoft.Network/virtualNetworks/$(Format-TfValue (Get-ResourceAttribute $Resource 'virtual_network_name'))/subnets/$name"
    }
    return "$(Get-ResourceGroupId $Resource)/providers/$($Rules[$type].Arm)/$name"
}

$script:TfResourceId = { param($Resource) Get-AzureId $Resource }

# I tratti di un identificativo: sottoscrizione, gruppo di risorse e, dopo providers, tipo e nome.
function Split-AzureId([string]$Id) {
    $segments = @($Id.Trim('/') -split '/')
    if ($segments.Count -lt 2 -or $segments[0] -ne 'subscriptions') { return $null }
    $result = [ordered]@{ Subscription = $segments[1]; ResourceGroup = $null; Type = $null; Names = @() }
    if ($segments.Count -ge 4 -and $segments[2] -eq 'resourceGroups') { $result.ResourceGroup = $segments[3] }
    if ($segments.Count -ge 8 -and $segments[4] -eq 'providers') {
        $types = @($segments[5] + '/' + $segments[6])
        $names = @($segments[7])
        for ($index = 8; $index + 1 -lt $segments.Count; $index += 2) { $types += $segments[$index]; $names += $segments[$index + 1] }
        $result.Type = $types -join '/'
        $result.Names = $names
    }
    return [pscustomobject]$result
}

function Get-AncestorIds([string]$Id) {
    $parts = Split-AzureId $Id
    if (-not $parts) { return @() }
    $ids = @("/subscriptions/$($parts.Subscription)")
    if ($parts.ResourceGroup) { $ids += "$($ids[-1])/resourceGroups/$($parts.ResourceGroup)" }
    if ($parts.Type -match '^Microsoft\.Network/virtualNetworks(/subnets)?$') {
        $ids += "$($ids[-1])/providers/Microsoft.Network/virtualNetworks/$($parts.Names[0])"
        if ($parts.Names.Count -gt 1) { $ids += "$($ids[-1])/subnets/$($parts.Names[1])" }
    }
    return $ids
}

function Get-IdLevel([string]$Id) {
    $parts = Split-AzureId $Id
    if (-not $parts.ResourceGroup) { return 'subscription' }
    if (-not $parts.Type) { return 'resourceGroup' }
    return $ArmLevels[$parts.Type.ToLowerInvariant()]
}

function Get-IdName([string]$Id) {
    return (($Id.TrimEnd('/') -split '/')[-1]).Trim('{', '}')
}

# ── Ambienti ─────────────────────────────────────────────────────────────────

function Get-RemoteWorkspaces($Environment) {
    $root = Get-TfRootInstance $Environment
    foreach ($block in @($root.Blocks | Where-Object { $_.Type -eq 'data' -and $_.Labels[0] -eq 'terraform_remote_state' })) {
        foreach ($entry in (Get-TfInstances $root $block)) {
            if ($entry.Unknown) { continue }
            $resource = [pscustomobject]@{ Module = $root; Block = $block; Entry = $entry; Address = "data.terraform_remote_state.$($block.Labels[1])" }
            $workspace = Get-TfRemoteWorkspace $resource
            if ($workspace -is [string]) { $workspace }
        }
    }
}

# Le directory d'ambiente di ogni ambiente del modello: quelle con il suo nome e quelle condivise che
# scambiano remote state con una di loro.
function Get-ModelEnvironments($Code) {
    $all = @(Get-TfEnvironments $Code)
    $reads = @{}
    $all | ForEach-Object { $reads[$_.Directory] = @(Get-RemoteWorkspaces $_) }
    $mapped = @($EnvironmentMap.Values)
    foreach ($name in $EnvironmentMap.Keys) {
        $own = @($all | Where-Object Name -EQ $EnvironmentMap[$name])
        $ownWorkspaces = @($own | ForEach-Object Workspace | Where-Object { $_ })
        $shared = @($all | Where-Object { $mapped -notcontains $_.Name } | Where-Object {
                $candidate = $_
                @($own | Where-Object { $reads[$_.Directory] -contains $candidate.Workspace }).Count -or @($reads[$candidate.Directory] | Where-Object { $ownWorkspaces -contains $_ }).Count
            })
        [pscustomobject]@{ Name = $name; Directories = @($own) + @($shared) }
    }
}

# Un modulo radice che C4_TERRAFORM_INSTANCES istanzia per directory: un ambiente per istanza, con la
# variabile fissata al nome della directory.
function Expand-Instances($Environment) {
    $rule = $InstanceRules | Where-Object Root -EQ $Environment.Root | Select-Object -First 1
    if (-not $rule) { return , @($Environment) }
    $pattern = $rule.Glob.Replace('{environment}', $Environment.Name)
    $base = Join-Path $script:TfCode.Root $Environment.Root
    $parent = Split-Path (Join-Path $base $pattern) -Parent
    $leaf = Split-Path $pattern -Leaf
    $names = @(Get-ChildItem -Path $parent -Directory -Filter $leaf -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object)
    return , @($names | ForEach-Object {
            $values = [ordered]@{}
            foreach ($key in $Environment.Values.Keys) { $values[$key] = $Environment.Values[$key] }
            $values[$rule.Variable] = [pscustomobject]@{ Text = "`"$_`""; File = "$($Environment.Directory)/values.tfvars"; Line = 0 }
            [pscustomobject]@{ Root = $Environment.Root; Directory = $Environment.Directory; Name = $Environment.Name; Workspace = $Environment.Workspace; Values = $values; RootInstance = $null; Instance = $_ }
        })
}

# ── Risorse ──────────────────────────────────────────────────────────────────

function Get-ResourceLevel($Resource) {
    $type = $Resource.Block.Labels[0]
    if ($type -eq 'azapi_resource') {
        $armType = Get-ArmType $Resource
        if ($armType) { return $ArmLevels[$armType.ToLowerInvariant()] }
        return $null
    }
    if ($Rules.ContainsKey($type)) { return $Rules[$type].Level }
}

function Get-Resources($Environment, [string[]]$HostPatterns) {
    foreach ($module in @(Get-TfModuleInstances $Environment)) {
        foreach ($block in @($module.Blocks | Where-Object Type -EQ 'resource')) {
            $type = $block.Labels[0]
            $pattern = "$($Environment.Root)/$("$($module.Path -replace '\[[^\]]*\]', '')/$type.$($block.Labels[1])".TrimStart('/'))"
            $candidate = $Rules.ContainsKey($type) -or $type -eq 'azapi_resource' -or $block.Attributes['service_plan_id'] -or $HostPatterns -contains $pattern
            if (-not $candidate) { continue }
            foreach ($entry in (Get-TfInstances $module $block)) {
                $address = "$($module.Path)/$type.$($block.Labels[1])$(Format-TfKey $entry.Key)".TrimStart('/')
                if ($entry.Unknown) {
                    if ($type -eq 'azapi_resource') { continue }
                    throw [TfError]::new("$($block.File):$($block.Line): istanze di $address sconosciute ($($entry.Unknown))")
                }
                $resource = [pscustomobject]@{ Module = $module; Block = $block; Entry = $entry; Address = $address; Mode = 'resource' }
                $level = Get-ResourceLevel $resource
                [pscustomobject]@{
                    Resource = $resource; Type = $type; Level = $level; Root = $Environment.Root
                    Key = "$($Environment.Root)/$address"; Pattern = "$($Environment.Root)/$($address -replace '\[[^\]]*\]', '')"
                    Code = $module.CodeDirectory; Environment = $Environment
                }
            }
        }
    }
}

function Get-Value($Resource, [string]$Attribute) {
    $value = Get-ResourceAttribute $Resource $Attribute
    if ($null -eq $value) { return $null }
    return Format-TfValue $value
}

function Get-Name($Item) {
    $name = Get-ResourceAttribute $Item.Resource 'name'
    if ($name -is [string]) { return $name }
    return $null
}

# ── Container ospitati ───────────────────────────────────────────────────────

function Get-ModelContainers {
    $contents = @(Read-FragmentContents)
    $containers = @($contents | ForEach-Object { @($_.containers) } | Where-Object { $_ })
    $hosts = @($contents | ForEach-Object { @($_.hosts) } | Where-Object { $_ })
    return [pscustomobject]@{ Containers = $containers; Hosts = $hosts }
}

# Per ogni chiave di risorsa, i container che ospita: per nome nel codice in qualunque ambiente, o per
# l'indirizzo che un frammento dichiara in hosts.
function Get-ContainerHosts($Model, $Items) {
    $byName = @{}
    foreach ($item in $Items) {
        $name = Get-Name $item
        if (-not $name) { continue }
        $key = $name.ToLowerInvariant()
        if (-not $byName.ContainsKey($key)) { $byName[$key] = [System.Collections.Generic.List[string]]::new() }
        $byName[$key].Add($item.Key)
    }
    $hosted = @{}
    $issues = [System.Collections.Generic.List[string]]::new()
    $add = { param($key, $container) if (-not $hosted.ContainsKey($key)) { $hosted[$key] = [System.Collections.Generic.List[string]]::new() }; if (-not $hosted[$key].Contains($container)) { $hosted[$key].Add($container) } }
    foreach ($container in $Model.Containers) {
        $codeName = "$($container.codeName)".ToLowerInvariant()
        if ($codeName -and $byName.ContainsKey($codeName)) { $byName[$codeName] | ForEach-Object { & $add $_ $container.id } }
    }
    foreach ($entry in $Model.Hosts) {
        $matched = @($Items | Where-Object { $_.Pattern -eq $entry.resource -or $_.Key -eq $entry.resource } | ForEach-Object Key | Sort-Object -Unique)
        if (-not $matched) { $issues.Add((New-Issue $Repository 'risorsa che ospita un container assente dalla dichiarazione' "$($entry.container): $($entry.resource)")); continue }
        $matched | ForEach-Object { & $add $_ $entry.container }
    }
    return [pscustomobject]@{ Hosted = $hosted; Issues = $issues.ToArray() }
}

# ── Nodi ─────────────────────────────────────────────────────────────────────

function New-Node([string]$Environment, [string]$Path, [string]$Name, [string]$Technology, [string]$Kind, [string]$TextKey, [string]$Module, [string[]]$Sources) {
    return [ordered]@{
        id = ConvertTo-Identifier "$Repository.$Environment.$Path"; name = $Name; technology = $Technology; kind = $Kind
        text = ConvertTo-Identifier "$Repository.$TextKey"; module = $Module; sources = @($Sources | Where-Object { $_ } | Sort-Object -Unique)
        children = [System.Collections.Generic.List[object]]::new(); instances = [System.Collections.Generic.List[string]]::new()
    }
}

function Get-TechnologyOf($Item) {
    $armType = Get-ArmType $Item.Resource
    if ($armType) { return $armType }
    return $Item.Type
}

function Add-Child($Parent, $Child) {
    $existing = $Parent.children | Where-Object { $_.id -eq $Child.id } | Select-Object -First 1
    if ($existing) { return $existing }
    $Parent.children.Add($Child)
    return $Child
}

# Il nodo di un identificativo, con i nodi dei suoi antenati: dalla risorsa che lo dichiara, se c'e'.
function Get-IdNode($State, [string]$Id) {
    $key = $Id.ToLowerInvariant()
    if ($State.Nodes.ContainsKey($key)) { return $State.Nodes[$key] }
    $declared = $State.ById[$key]
    $ancestors = @(Get-AncestorIds $Id)
    $parentId = if ($ancestors.Count -gt 1 -and $ancestors[-1].ToLowerInvariant() -eq $key) { $ancestors[-2] } elseif ($ancestors.Count -and $ancestors[-1].ToLowerInvariant() -ne $key) { $ancestors[-1] } else { $null }
    $level = Get-IdLevel $Id
    $technology = if ($declared) { Get-TechnologyOf $declared } elseif ($LevelTechnology.ContainsKey($level)) { $LevelTechnology[$level] } else { (Split-AzureId $Id).Type }
    $textKey = if ($declared) { $declared.Pattern } else { "$level.$(Get-IdName $Id)" }
    $module = if ($declared) { $declared.Root } else { 'azure' }
    $sources = if ($declared) { @($declared.Code) } else { @() }
    $node = New-Node $State.Environment $key (Get-IdName $Id) $technology 'deploymentNode' $textKey $module $sources
    if ($parentId) { $node = Add-Child (Get-IdNode $State $parentId) $node } else { $State.Roots.Add($node) }
    $State.Nodes[$key] = $node
    return $node
}

function Add-Hosted($State, $Item, $Parent, [string]$Path) {
    $containers = @($State.Hosted[$Item.Key])
    if ($containers) { $containers | ForEach-Object { if (-not $Parent.instances.Contains($_)) { $Parent.instances.Add($_) } }; return }
    $node = New-Node $State.Environment $Path (Get-Name $Item) (Get-TechnologyOf $Item) 'infrastructureNode' $Item.Pattern $Item.Root @($Item.Code)
    [void](Add-Child $Parent $node)
}

# Il piano nella subnet a cui la sua applicazione si integra, altrimenti nel suo gruppo di risorse.
function Get-PlanNode($State, [string]$PlanId, [string]$SubnetId) {
    if (-not $SubnetId) { return Get-IdNode $State $PlanId }
    $declared = $State.ById[$PlanId.ToLowerInvariant()]
    $technology = if ($declared) { Get-TechnologyOf $declared } else { (Split-AzureId $PlanId).Type }
    $textKey = if ($declared) { $declared.Pattern } else { "hostingPlan.$(Get-IdName $PlanId)" }
    $module = if ($declared) { $declared.Root } else { 'azure' }
    $sources = if ($declared) { @($declared.Code) } else { @() }
    $plan = New-Node $State.Environment "$($SubnetId.ToLowerInvariant())/$($PlanId.ToLowerInvariant())" (Get-IdName $PlanId) $technology 'deploymentNode' $textKey $module $sources
    return Add-Child (Get-IdNode $State $SubnetId) $plan
}

# Piano e subnet di integrazione di un'applicazione: gli attributi di azurerm, o le proprieta' del body
# di un azapi_resource.
function Get-ApplicationPlacement($Item, [hashtable]$Integrations) {
    $planId = Get-Value $Item.Resource 'service_plan_id'
    $subnetId = Get-Value $Item.Resource 'virtual_network_subnet_id'
    if ($Item.Type -eq 'azapi_resource') {
        $body = Get-ResourceAttribute $Item.Resource 'body'
        $properties = if ($body -is [System.Collections.IDictionary] -and $body.Contains('properties')) { $body['properties'] }
        if ($properties -is [System.Collections.IDictionary]) {
            if ($properties.Contains('serverFarmId')) { $planId = Format-TfValue $properties['serverFarmId'] }
            if ($properties.Contains('virtualNetworkSubnetId')) { $subnetId = Format-TfValue $properties['virtualNetworkSubnetId'] }
        }
    }
    if (-not $subnetId) { $subnetId = $Integrations[$Item.Id.ToLowerInvariant()] }
    return [pscustomobject]@{ PlanId = $planId; SubnetId = $subnetId }
}

function Get-EnvironmentNodes([string]$Name, $Items, $Hosted) {
    $state = @{ Environment = $Name; Nodes = @{}; ById = @{}; Roots = [System.Collections.Generic.List[object]]::new(); Hosted = $Hosted }
    $identified = foreach ($item in $Items) {
        if (-not $item.Level -or $item.Level -eq 'integration') { $item; continue }
        $id = Get-AzureId $item.Resource
        if ($id -isnot [string]) { $id = Format-TfValue $id }
        $item | Add-Member -Force -NotePropertyName Id -NotePropertyValue $id
        $state.ById[$id.ToLowerInvariant()] = $item
        $item
    }
    $integrations = @{}
    foreach ($item in @($identified | Where-Object Level -EQ 'integration')) {
        $integrations[(Get-Value $item.Resource 'app_service_id').ToLowerInvariant()] = Get-Value $item.Resource 'subnet_id'
    }
    foreach ($item in @($identified | Where-Object { $_.Level -in @('resourceGroup', 'virtualNetwork', 'subnet') })) { [void](Get-IdNode $state $item.Id) }
    $plansWithApps = @{}
    foreach ($item in @($identified | Where-Object Level -EQ 'application')) {
        $placement = Get-ApplicationPlacement $item $integrations
        if ($placement.PlanId) {
            $plansWithApps[$placement.PlanId.ToLowerInvariant()] = $true
            Add-Hosted $state $item (Get-PlanNode $state $placement.PlanId $placement.SubnetId) $item.Id.ToLowerInvariant()
        }
        else { Add-Hosted $state $item (Get-IdNode $state ((Get-AncestorIds $item.Id) | Select-Object -Last 1)) $item.Id.ToLowerInvariant() }
    }
    foreach ($item in @($identified | Where-Object Level -EQ 'hostingPlan')) {
        if (-not $plansWithApps.ContainsKey($item.Id.ToLowerInvariant())) { [void](Get-IdNode $state $item.Id) }
    }
    foreach ($item in @($identified | Where-Object Level -EQ 'privateEndpoint')) {
        $subnetId = Get-Value $item.Resource 'subnet_id'
        $parent = if ($subnetId) { Get-IdNode $state $subnetId } else { Get-IdNode $state ((Get-AncestorIds $item.Id) | Select-Object -Last 1) }
        Add-Hosted $state $item $parent $item.Id.ToLowerInvariant()
    }
    foreach ($item in @($identified | Where-Object Level -EQ 'service')) {
        Add-Hosted $state $item (Get-IdNode $state ((Get-AncestorIds $item.Id) | Select-Object -Last 1)) $item.Id.ToLowerInvariant()
    }
    return $state.Roots
}

function Get-UnknownHostingIssues($Items, $Hosted) {
    $Items | Where-Object { -not $_.Level -and ($Hosted.ContainsKey($_.Key) -or $_.Resource.Block.Attributes['service_plan_id']) } |
        ForEach-Object { New-Issue $Repository 'risorsa di hosting di un tipo che le regole non riconoscono' "$($_.Key) ($($_.Type), $($_.Resource.Block.File):$($_.Resource.Block.Line))" }
}

function Get-UnhostedIssues($Model, $Hosted) {
    $hostedIds = @($Hosted.Values | ForEach-Object { $_ } | Sort-Object -Unique)
    $own = @(Read-FragmentContents | Where-Object { $_ } | ForEach-Object { @($_.containers) } | Where-Object { $_ -and "$($_.id)".StartsWith((ConvertTo-Identifier $Repository) + '_') })
    $own | Where-Object { $hostedIds -notcontains $_.id -and @($_.tags) -notcontains $DocumentLanguage.ApplicationTag } |
        ForEach-Object { New-Issue $Repository 'servizio del modello che la dichiarazione non ospita' "$($_.id) ($($_.codeName))" }
}

function Get-ReadIssues {
    $sourceIssues = @(Get-SourceIssues)
    if ($sourceIssues) { return $sourceIssues }
    if (-not $EnvironmentMap.Count) { return New-Issue $Repository 'ambienti del modello non dichiarati' 'C4_DEPLOYMENT_ENVIRONMENTS' }
    Reset-TfEvaluation
    $code = Read-TerraformRepository (Resolve-Path $SourceDirectory).Path
    try {
        $environments = @(Get-ModelEnvironments $code)
        $missing = @($environments | Where-Object { -not @($_.Directories | Where-Object { $EnvironmentMap.Values -contains $_.Name }).Count })
        if ($missing) { return $missing | ForEach-Object { New-Issue $Repository 'ambiente senza directory nella dichiarazione' "$($_.Name)=$($EnvironmentMap[$_.Name])" } }
        $model = Get-ModelContainers
        $hostPatterns = @($model.Hosts | ForEach-Object resource)
        $itemsByEnvironment = [ordered]@{}
        foreach ($environment in $environments) {
            $itemsByEnvironment[$environment.Name] = @($environment.Directories | ForEach-Object { Expand-Instances $_ } | ForEach-Object { $_ } | ForEach-Object { Get-Resources $_ $hostPatterns })
        }
        $all = @($itemsByEnvironment.Values | ForEach-Object { $_ })
        $hosts = Get-ContainerHosts $model $all
        if ($hosts.Issues) { return $hosts.Issues }
        $hosted = $hosts.Hosted
        $issues = @(Get-UnknownHostingIssues $all $hosted) + @(Get-UnhostedIssues $model $hosted)
        if ($issues) { return $issues }
        $deployment = @(foreach ($name in $itemsByEnvironment.Keys) { [ordered]@{ name = $name; nodes = @(Get-EnvironmentNodes $name $itemsByEnvironment[$name] $hosted) } })
    }
    catch [TfError] { return New-Issue $Repository 'dichiarazione Terraform non valutata' $_.Exception.Message }
    $manifests = @(Get-SourceFiles '*.tf' | ForEach-Object { Get-RelativePath $_.FullName })
    Write-C4Fragment 'terraform' $manifests @() @() -Deployment $deployment
}

Invoke-Verification { Get-ReadIssues } "Dichiarazione Terraform di $Repository letta" 'Lettura della dichiarazione Terraform disattivata'
