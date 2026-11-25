# SPDX-License-Identifier: Apache-2.0

# Lettore Terraform del modello C4 (contratto in C4CodeModel.ps1): gli ambienti di deployment dalla
# dichiarazione Terraform del repository sorgente, valutata ambiente per ambiente (TerraformValues.ps1)
# senza eseguire Terraform e senza leggere lo stato. C4_DEPLOYMENT_ENVIRONMENTS associa a ogni ambiente
# del modello la directory d'ambiente dei moduli radice (es. dev=dev-aidea;prod=prod-aidea); una
# directory che non vi compare entra negli ambienti con cui scambia remote state. C4_TERRAFORM_INSTANCES
# istanzia un modulo radice una volta per ogni directory che un glob trova, con il nome della directory in
# una variabile (es. Tenant-Customers:customer_tenant_id=environments/{environment}/data/*).
# Ogni ambiente ne scrive due, ciascuno per una domanda. L'allocazione: regione, piano di calcolo e le
# applicazioni che ospita, con i servizi che ospitano container nella loro regione. La rete: reti virtuali
# con subnet, applicazioni integrate, private endpoint e Application Gateway, profili Front Door con i loro
# endpoint, e le relazioni di peering, origine e backend; un collegamento che la dichiarazione non risolve
# da' un avviso. Ogni elemento porta il gruppo di risorse e il modulo radice che lo dichiara.
# Un container del modello (FRAGMENT_DIRECTORY) sta sulla risorsa che ha il suo nome nel codice o su quella
# che un frammento dichiara in hosts. Una risorsa che ospita un container o che gira su un piano, di un tipo
# che le regole non riconoscono, ferma la lettura nominandola.

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
    azurerm_cdn_frontdoor_profile              = @{ Level = 'ingress'; Arm = 'Microsoft.Cdn/profiles' }
    azurerm_cdn_frontdoor_endpoint             = @{ Level = 'ingressEndpoint'; Arm = 'Microsoft.Cdn/profiles/afdEndpoints'; Parent = 'cdn_frontdoor_profile_id' }
    azurerm_cdn_frontdoor_origin               = @{ Level = 'origin' }
    azurerm_cdn_frontdoor_route                = @{ Level = 'route' }
    azurerm_application_gateway                = @{ Level = 'gateway'; Arm = 'Microsoft.Network/applicationGateways' }
    azurerm_virtual_network_peering            = @{ Level = 'peering' }
    azurerm_dns_a_record                       = @{ Level = 'dnsRecord' }
    azurerm_dns_cname_record                   = @{ Level = 'dnsRecord' }
}
$Applications | ForEach-Object { $Rules[$_] = @{ Level = 'application'; Arm = 'Microsoft.Web/sites' } }
$ArmLevels = @{}
$Rules.Values | Where-Object Arm | ForEach-Object { $ArmLevels[$_.Arm.ToLowerInvariant()] = $_.Level }
$LevelTechnology = @{ subscription = 'Microsoft.Resources/subscriptions'; resourceGroup = 'Microsoft.Resources/resourceGroups' }
$RegionTechnology = 'Azure region'
$NetworkEnvironmentSuffix = $DocumentLanguage.NetworkEnvironmentSuffix

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
    if ($Rules[$type].Parent) { return "$(Format-TfValue (Get-ResourceAttribute $Resource $Rules[$type].Parent))/$(($Rules[$type].Arm -split '/')[-1])/$name" }
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
            [void]$script:DeclaredPatterns.Add($pattern)
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
                    Environment = $Environment
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
# l'indirizzo o il nome Azure che un frammento dichiara in hosts. Un indirizzo dichiarato senza istanze in
# nessun ambiente (un'alternativa di count, come l'app Windows di un modulo che sceglie il sistema) non ospita
# nulla e non e' un rilievo.
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
        $matched = if ($entry.name) { @($byName["$($entry.name)".ToLowerInvariant()]) } else { @($Items | Where-Object { $_.Pattern -eq $entry.resource -or $_.Key -eq $entry.resource } | ForEach-Object Key) }
        $matched = @($matched | Where-Object { $_ } | Sort-Object -Unique)
        $wanted = if ($entry.name) { $entry.name } else { $entry.resource }
        if (-not $matched -and ($entry.name -or -not $script:DeclaredPatterns.Contains($entry.resource))) { $issues.Add((New-Issue $Repository 'risorsa che ospita un container assente dalla dichiarazione' "$($entry.container): $wanted")); continue }
        $matched | ForEach-Object { & $add $_ $entry.container }
    }
    return [pscustomobject]@{ Hosted = $hosted; Issues = $issues.ToArray() }
}

# ── Nodi ─────────────────────────────────────────────────────────────────────

# element e' l'elemento di Structurizr, kind il livello del nodo, da cui l'esportazione compone la sua descrizione.
function New-Node([string]$Environment, [string]$Path, [string]$Name, [string]$Technology, [string]$Element, [string]$Kind, [string]$Module, [string]$ResourceGroup, [string]$AzureName) {
    return [ordered]@{
        id = ConvertTo-Identifier "$Repository.$Environment.$Path"; name = $Name; azureName = $AzureName; technology = $Technology; element = $Element; kind = $Kind
        module = $Module; resourceGroup = $ResourceGroup
        children = [System.Collections.Generic.List[object]]::new(); instances = [System.Collections.Generic.List[object]]::new()
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

# Un identificativo senza la sottoscrizione: la stessa risorsa letta da due moduli radice puo' avere la
# sottoscrizione di provider diversi, o una variabile che il repository non valorizza.
function Get-NormalId([string]$Id) {
    return ($Id -replace '^/subscriptions/[^/]*', '').ToLowerInvariant()
}

function Get-ItemName($Item) {
    $name = Get-Name $Item
    if ($name) { return $name }
    return Get-IdName $Item.Id
}

function Get-ItemResourceGroup($Item) {
    if ($Item.Type -eq 'azurerm_resource_group') { return Get-ItemName $Item }
    $parts = Split-AzureId $Item.Id
    if ($parts -and $parts.ResourceGroup) { return $parts.ResourceGroup }
    return Get-Value $Item.Resource 'resource_group_name'
}

function New-ItemNode($State, $Item, [string]$Element, [string]$Path, [string]$Name = (Get-ItemName $Item)) {
    return New-Node $State.Environment $Path $Name (Get-TechnologyOf $Item) $Element $Item.Level $Item.Root (Get-ItemResourceGroup $Item) (Get-ItemName $Item)
}

function Add-Root($State, [string]$Path, $Node) {
    $State.Roots.Add($Node)
    $State.Nodes[$Path] = $Node
    return $Node
}

function Add-Instances($Parent, $Item, [string[]]$Containers) {
    foreach ($container in $Containers) {
        if (@($Parent.instances | Where-Object container -EQ $container).Count) { continue }
        $Parent.instances.Add([ordered]@{ container = $container; azureName = Get-ItemName $Item; resourceGroup = Get-ItemResourceGroup $Item; module = $Item.Root })
    }
}

# Una risorsa che ospita container ne porta le istanze, altrimenti e' un nodo dell'infrastruttura.
function Add-Hosted($State, $Item, $Parent) {
    $containers = @($State.Hosted[$Item.Key])
    if ($containers) {
        Add-Instances $Parent $Item $containers
        return @($containers | ForEach-Object { [ordered]@{ node = $Parent.id; container = $_ } })
    }
    $node = Add-Child $Parent (New-ItemNode $State $Item 'infrastructureNode' (Get-NormalId $Item.Id))
    return , [ordered]@{ node = $node.id }
}

function Get-IdentifiedItems($Items) {
    foreach ($item in $Items) {
        if ($item.Level -and $item.Level -ne 'integration') {
            $id = Get-AzureId $item.Resource
            if ($id -isnot [string]) { $id = Format-TfValue $id }
            $item | Add-Member -Force -NotePropertyName Id -NotePropertyValue $id
        }
        $item
    }
}

function Get-ItemKeys($Item) {
    if (-not $Item.Id) { return }
    if ($Item.Id.StartsWith('/subscriptions/')) { "id:$(Get-NormalId $Item.Id)" }
    "addr:$($Item.Resource.Address.ToLowerInvariant())"
}

function Get-RecordHost($Item) {
    $name = Get-Value $Item.Resource 'name'
    $zone = Get-Value $Item.Resource 'zone_name'
    if ($name -eq '@') { return $zone.ToLowerInvariant() }
    return "$name.$zone".ToLowerInvariant()
}

function New-NodeState([string]$Environment, $Items, $Hosted) {
    $state = @{
        Environment = $Environment; Items = @($Items); Hosted = $Hosted; Roots = [System.Collections.Generic.List[object]]::new(); Nodes = @{}
        ById = @{}; ByKey = @{}; Integrations = @{}; Records = @{}; Elements = @{}; Users = @{}
    }
    foreach ($item in @($Items | Where-Object Id)) {
        $state.ById[(Get-NormalId $item.Id)] = $item
        Get-ItemKeys $item | ForEach-Object { $state.ByKey[$_] = $item }
    }
    foreach ($item in @($Items | Where-Object Level -EQ 'integration')) {
        $state.Integrations[(Get-Value $item.Resource 'app_service_id').ToLowerInvariant()] = Get-Value $item.Resource 'subnet_id'
    }
    foreach ($item in @($Items | Where-Object Level -EQ 'dnsRecord')) {
        $recordHost = Get-RecordHost $item
        if (-not $state.Records.ContainsKey($recordHost)) { $state.Records[$recordHost] = [System.Collections.Generic.List[object]]::new() }
        $state.Records[$recordHost].Add($item)
    }
    return $state
}

function Get-ItemsOfLevel($State, [string]$Level) {
    return @($State.Items | Where-Object Level -EQ $Level)
}

# ── Allocazione ──────────────────────────────────────────────────────────────

function Get-ItemLocation($Item) {
    $value = Get-ResourceAttribute $Item.Resource 'location'
    if ($value -is [string] -and $value.Trim()) { return ($value -replace '\s', '').ToLowerInvariant() }
    return $null
}

# La regione della risorsa, altrimenti quella del suo gruppo di risorse, altrimenti il segnaposto del valore
# sconosciuto.
function Get-ItemRegion($State, $Item) {
    $own = Get-ItemLocation $Item
    if ($own) { return $own }
    $group = $State.ById["/resourcegroups/$("$(Get-ItemResourceGroup $Item)".ToLowerInvariant())"]
    if ($group -and (Get-ItemLocation $group)) { return Get-ItemLocation $group }
    $value = Get-ResourceAttribute $Item.Resource 'location'
    if ($null -ne $value) { return Format-TfValue $value }
    return '{location}'
}

function Get-RegionNode($State, [string]$Region) {
    $path = "region/$Region"
    if ($State.Nodes.ContainsKey($path)) { return $State.Nodes[$path] }
    return Add-Root $State $path (New-Node $State.Environment $path $Region $RegionTechnology 'deploymentNode' 'region' 'azure' '' '')
}

# Un piano che il codice non dichiara sta nella regione della sua applicazione.
function Get-PlanNode($State, [string]$PlanId, $Application) {
    $declared = $State.ById[(Get-NormalId $PlanId)]
    $region = if ($declared) { Get-ItemRegion $State $declared } else { Get-ItemRegion $State $Application }
    $parent = Get-RegionNode $State $region
    $path = "$region/$(Get-NormalId $PlanId)"
    $parts = Split-AzureId $PlanId
    $node = if ($declared) { New-ItemNode $State $declared 'deploymentNode' $path }
    else { New-Node $State.Environment $path (Get-IdName $PlanId) $parts.Type 'deploymentNode' 'hostingPlan' 'azure' $parts.ResourceGroup (Get-IdName $PlanId) }
    return Add-Child $parent $node
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

# Un'applicazione senza piano e' il nodo di se stessa, con dentro le istanze dei container che ospita.
function Add-PlanlessApplication($State, $Item) {
    $region = Get-RegionNode $State (Get-ItemRegion $State $Item)
    $containers = @($State.Hosted[$Item.Key])
    if (-not $containers) { [void](Add-Hosted $State $Item $region); return }
    Add-Instances (Add-Child $region (New-ItemNode $State $Item 'deploymentNode' (Get-NormalId $Item.Id))) $Item $containers
}

# Regione, piano di calcolo, istanze: un servizio gestito che ospita un container e' un'istanza nella sua
# regione, una risorsa che non ne ospita resta fuori.
function Get-AllocationNodes($State) {
    foreach ($item in (Get-ItemsOfLevel $State 'application')) {
        $placement = Get-ApplicationPlacement $item $State.Integrations
        if ($placement.PlanId) { [void](Add-Hosted $State $item (Get-PlanNode $State $placement.PlanId $item)) }
        else { Add-PlanlessApplication $State $item }
    }
    foreach ($item in (Get-ItemsOfLevel $State 'service')) {
        $containers = @($State.Hosted[$item.Key])
        if ($containers) { Add-Instances (Get-RegionNode $State (Get-ItemRegion $State $item)) $item $containers }
    }
    return $State.Roots
}

# ── Rete ─────────────────────────────────────────────────────────────────────

function Add-NetworkWarning([string]$Detail) {
    Write-Host "##vso[task.logissue type=warning]${Repository}: collegamento di rete non risolto ($Detail)"
}

function Register-Element($State, [hashtable]$Index, [string[]]$Keys, $References) {
    foreach ($key in @($Keys | Where-Object { $_ })) {
        if (-not $Index.ContainsKey($key)) { $Index[$key] = [System.Collections.Generic.List[object]]::new() }
        @($References) | Where-Object { $_ } | ForEach-Object { $Index[$key].Add($_) }
    }
}

# I blocchi annidati di una risorsa, anche quelli che un blocco dynamic produce, con l'iteratore del blocco.
function Get-NestedBlocks($Item, [string]$Name) {
    foreach ($block in @($Item.Resource.Block.Blocks)) {
        if ($block.Type -eq $Name) { [pscustomobject]@{ Block = $block; Names = @{} }; continue }
        if ($block.Type -ne 'dynamic' -or $block.Labels[0] -ne $Name) { continue }
        $content = @($block.Blocks | Where-Object Type -EQ 'content') | Select-Object -First 1
        $collection = Invoke-TfAttribute $Item.Resource.Module $block 'for_each' $Item.Resource.Entry.Each $Item.Resource.Entry.Count
        if (-not $content -or (Test-TfUnknown $collection) -or $collection -is [TfLazy]) { throw [TfError]::new("$($block.File):$($block.Line): blocchi $Name sconosciuti") }
        $iterator = if ($block.Attributes['iterator']) { $block.Attributes['iterator'].Text.Trim() } else { $Name }
        foreach ($pair in (Get-TfPairs $collection)) {
            [pscustomobject]@{ Block = $content; Names = @{ $iterator = [ordered]@{ key = (ConvertTo-TfKey $pair.Key); value = $pair.Value } } }
        }
    }
}

function Get-NestedValue($Item, $Nested, [string]$Name) {
    $expression = $Nested.Block.Attributes[$Name]
    if (-not $expression) { return $null }
    $scope = @{ Module = $Item.Resource.Module; Each = $Item.Resource.Entry.Each; Count = $Item.Resource.Entry.Count; Where = "$($expression.File):$($expression.Line)"; Names = $Nested.Names }
    return Invoke-TfExpression (ConvertTo-TfSyntax $expression.Text $scope.Where) $scope
}

function Get-NestedValues($Item, [string]$Name, [string]$Attribute) {
    foreach ($nested in (Get-NestedBlocks $Item $Name)) { , (Get-NestedValue $Item $nested $Attribute) }
}

$AddressPattern = '^(?<address>(?:[^/]+/)*(?:data\.)?[a-z][a-z0-9]*_[a-z0-9_]+\.[A-Za-z0-9_-]+(?:\[[^\]]*\])?)\.'

# Le chiavi con cui un valore nomina una risorsa: il suo identificativo Azure, o l'indirizzo della risorsa
# di cui un valore sconosciuto nomina un attributo.
function Get-ValueKeys($Value) {
    foreach ($each in (Get-TfItems $Value)) {
        $text = Format-TfValue $each
        if ($text.StartsWith('/subscriptions/')) { "id:$(Get-NormalId $text)" }
        foreach ($match in [regex]::Matches($text, '\{([^{}]+)\}')) {
            if ($match.Groups[1].Value -match $AddressPattern) { "addr:$($Matches.address.ToLowerInvariant())" }
        }
    }
}

# Un nome host nomina le risorse che i record DNS della dichiarazione con quel nome indicano.
function Get-HostKeys($State, $Value) {
    foreach ($each in (Get-TfItems $Value)) {
        $text = (Format-TfValue $each).TrimEnd('.').ToLowerInvariant()
        if ($text -notmatch '^[a-z0-9*-]+(\.[a-z0-9-]+)+$' -or -not $State.Records.ContainsKey($text)) { continue }
        foreach ($record in $State.Records[$text]) {
            foreach ($attribute in 'records', 'record', 'target_resource_id') { Get-ValueKeys (Get-ResourceAttribute $record.Resource $attribute) }
        }
    }
}

function Expand-Keys($State, [string[]]$Keys) {
    $expanded = @($Keys | Where-Object { $_ }) + @($Keys | Where-Object { $_ -and $State.ByKey.ContainsKey($_) } | ForEach-Object { Get-ItemKeys $State.ByKey[$_] })
    return @($expanded | Select-Object -Unique)
}

# Gli elementi dell'ambiente di rete che un valore nomina; una risorsa che non e' un elemento porta al nodo
# che la usa.
function Resolve-Targets($State, $Value) {
    $keys = Expand-Keys $State (@(Get-ValueKeys $Value) + @(Get-HostKeys $State $Value))
    $found = @($keys | Where-Object { $State.Elements.ContainsKey($_) } | ForEach-Object { $State.Elements[$_] } | ForEach-Object { $_ })
    if (-not $found) { $found = @($keys | Where-Object { $State.Users.ContainsKey($_) } | ForEach-Object { $State.Users[$_] } | ForEach-Object { $_ }) }
    $seen = @{}
    foreach ($reference in $found) {
        $key = "$($reference.node)|$($reference.container)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $reference
    }
}

function Get-NetworkIdNode($State, [string]$Id) {
    $normal = Get-NormalId $Id
    if ($State.Nodes.ContainsKey($normal)) { return $State.Nodes[$normal] }
    $parts = Split-AzureId $Id
    if (-not $parts -or $parts.Type -notmatch '^Microsoft\.Network/virtualNetworks(/subnets)?$') { return $null }
    $declared = $State.ById[$normal]
    $node = if ($declared) { New-ItemNode $State $declared 'deploymentNode' $normal }
    else { New-Node $State.Environment $normal (Get-IdName $Id) $parts.Type 'deploymentNode' (Get-IdLevel $Id) 'azure' $parts.ResourceGroup (Get-IdName $Id) }
    if ($parts.Names.Count -lt 2) { return Add-Root $State $normal $node }
    $network = Get-NetworkIdNode $State (Get-AncestorIds $Id)[-2]
    $State.Nodes[$normal] = Add-Child $network $node
    return $State.Nodes[$normal]
}

function Get-ProfileNode($State, [string]$Id) {
    $normal = Get-NormalId $Id
    if ($State.Nodes.ContainsKey($normal)) { return $State.Nodes[$normal] }
    $declared = $State.ById[$normal]
    $node = if ($declared) { New-ItemNode $State $declared 'deploymentNode' $normal }
    else { New-Node $State.Environment $normal (Get-IdName $Id) 'Microsoft.Cdn/profiles' 'deploymentNode' 'ingress' 'azure' (Split-AzureId $Id).ResourceGroup (Get-IdName $Id) }
    return Add-Root $State $normal $node
}

function Add-NetworkElement($State, $Item, $Parent, [string]$Name = (Get-ItemName $Item)) {
    $node = Add-Child $Parent (New-ItemNode $State $Item 'infrastructureNode' (Get-NormalId $Item.Id) $Name)
    Register-Element $State $State.Elements (Get-ItemKeys $Item) @([ordered]@{ node = $node.id })
    return $node
}

# Il private endpoint si chiama con la risorsa che espone: il container che ospita, se ne ospita uno.
function Add-PrivateEndpoint($State, $Item) {
    $subnet = Get-NetworkIdNode $State (Get-Value $Item.Resource 'subnet_id')
    if (-not $subnet) { return }
    $connection = @(Get-NestedValues $Item 'private_service_connection' 'private_connection_resource_id') | Select-Object -First 1
    $keys = Expand-Keys $State @(Get-ValueKeys $connection)
    $exposed = @($keys | Where-Object { $State.ByKey.ContainsKey($_) } | ForEach-Object { $State.ByKey[$_] }) | Select-Object -First 1
    $container = if ($exposed) { @($State.Hosted[$exposed.Key]) | Select-Object -First 1 }
    $exposedName = if ($container) { $State.ContainerNames[$container] } elseif ($exposed) { Get-ItemName $exposed } elseif ("$connection".StartsWith('/subscriptions/')) { Get-IdName "$connection" }
    $node = Add-NetworkElement $State $Item $subnet $(if ($exposedName) { $exposedName } else { Get-ItemName $Item })
    if ($exposedName) { $node.exposedName = $exposedName }
    if ($container) { $node.exposes = $container }
    $subresources = @(Get-NestedValues $Item 'private_service_connection' 'subresource_names') | Select-Object -First 1
    $node.subresources = @(Get-TfItems $subresources | ForEach-Object { Format-TfValue $_ }) -join ', '
    Register-Element $State $State.Users $keys @([ordered]@{ node = $node.id })
}

function Add-Gateway($State, $Item) {
    $subnetId = @(Get-NestedValues $Item 'gateway_ip_configuration' 'subnet_id') | Select-Object -First 1
    $subnet = if ($subnetId) { Get-NetworkIdNode $State (Format-TfValue $subnetId) }
    if (-not $subnet) { Add-NetworkWarning "$($Item.Key): subnet del gateway"; return }
    $node = Add-NetworkElement $State $Item $subnet
    $publicIps = @(Get-NestedValues $Item 'frontend_ip_configuration' 'public_ip_address_id')
    Register-Element $State $State.Users (Expand-Keys $State @($publicIps | ForEach-Object { Get-ValueKeys $_ })) @([ordered]@{ node = $node.id })
}

function Add-IntegratedApplication($State, $Item) {
    $placement = Get-ApplicationPlacement $Item $State.Integrations
    $subnet = if ($placement.SubnetId) { Get-NetworkIdNode $State $placement.SubnetId }
    if (-not $subnet) { return }
    Register-Element $State $State.Elements (Get-ItemKeys $Item) @(Add-Hosted $State $Item $subnet)
}

function Invoke-NetworkStep($Item, [scriptblock]$Step) {
    try { & $Step }
    catch [TfError] { Add-NetworkWarning "$($Item.Key): $($_.Exception.Message)" }
}

# Reti virtuali con le subnet e il loro contenuto, e i profili Front Door con i loro endpoint.
function Get-NetworkNodes($State) {
    foreach ($item in @((Get-ItemsOfLevel $State 'virtualNetwork') + (Get-ItemsOfLevel $State 'subnet'))) { [void](Get-NetworkIdNode $State $item.Id) }
    foreach ($item in (Get-ItemsOfLevel $State 'ingress')) { [void](Get-ProfileNode $State $item.Id) }
    foreach ($item in (Get-ItemsOfLevel $State 'ingressEndpoint')) {
        $profileId = Get-Value $item.Resource 'cdn_frontdoor_profile_id'
        if ($profileId) { [void](Add-NetworkElement $State $item (Get-ProfileNode $State $profileId)) }
    }
    foreach ($item in (Get-ItemsOfLevel $State 'application')) { Invoke-NetworkStep $item { Add-IntegratedApplication $State $item } }
    foreach ($item in (Get-ItemsOfLevel $State 'privateEndpoint')) { Invoke-NetworkStep $item { Add-PrivateEndpoint $State $item } }
    foreach ($item in (Get-ItemsOfLevel $State 'gateway')) { Invoke-NetworkStep $item { Add-Gateway $State $item } }
    return $State.Roots
}

function New-NetworkRelationship([string]$Kind, $Source, $Target) {
    return [ordered]@{ kind = $Kind; source = $Source.node; sourceContainer = $Source.container; target = $Target.node; targetContainer = $Target.container }
}

function Get-RelationshipsBetween([string]$Kind, $Sources, $Targets, [string]$Detail) {
    if (-not @($Targets).Count -or -not @($Sources).Count) { Add-NetworkWarning $Detail; return }
    foreach ($source in $Sources) {
        foreach ($target in $Targets) {
            if ("$($source.node)|$($source.container)" -ne "$($target.node)|$($target.container)") { New-NetworkRelationship $Kind $source $target }
        }
    }
}

function Get-PeeringRelationships($State) {
    $written = @{}
    foreach ($item in (Get-ItemsOfLevel $State 'peering')) {
        $local = "/resourcegroups/$(Get-Value $item.Resource 'resource_group_name')/providers/microsoft.network/virtualnetworks/$(Get-Value $item.Resource 'virtual_network_name')".ToLowerInvariant()
        $remote = Get-NormalId (Get-Value $item.Resource 'remote_virtual_network_id')
        $ends = @($local, $remote | ForEach-Object { $State.Nodes[$_] })
        if (@($ends | Where-Object { $_ }).Count -lt 2) { Add-NetworkWarning "$($item.Key): $local -> $remote"; continue }
        $pair = (@($ends.id) | Sort-Object) -join '|'
        if ($written.ContainsKey($pair)) { continue }
        $written[$pair] = $true
        New-NetworkRelationship 'Peering' ([ordered]@{ node = $ends[0].id }) ([ordered]@{ node = $ends[1].id })
    }
}

# Un'origine di Front Door si raggiunge dagli endpoint delle route del suo gruppo di origini.
function Get-OriginRelationships($State) {
    $routes = Get-ItemsOfLevel $State 'route'
    foreach ($origin in (Get-ItemsOfLevel $State 'origin')) {
        Invoke-NetworkStep $origin {
            $group = @(Get-ValueKeys (Get-ResourceAttribute $origin.Resource 'cdn_frontdoor_origin_group_id'))
            $endpoints = @($routes | Where-Object { $routeGroup = @(Get-ValueKeys (Get-ResourceAttribute $_.Resource 'cdn_frontdoor_origin_group_id')); @($routeGroup | Where-Object { $group -contains $_ }).Count } |
                    ForEach-Object { Resolve-Targets $State (Get-ResourceAttribute $_.Resource 'cdn_frontdoor_endpoint_id') })
            $hostName = Get-ResourceAttribute $origin.Resource 'host_name'
            Get-RelationshipsBetween 'Origin' $endpoints @(Resolve-Targets $State $hostName) "$($origin.Key): $(Format-TfValue $hostName)"
        }
    }
}

function Get-BackendRelationships($State) {
    foreach ($gateway in (Get-ItemsOfLevel $State 'gateway')) {
        $source = @($State.Elements[(Get-ItemKeys $gateway | Select-Object -First 1)]) | Select-Object -First 1
        if (-not $source) { continue }
        Invoke-NetworkStep $gateway {
            foreach ($pool in (Get-NestedBlocks $gateway 'backend_address_pool')) {
                foreach ($attribute in 'fqdns', 'ip_addresses') {
                    foreach ($address in (Get-TfItems (Get-NestedValue $gateway $pool $attribute))) {
                        Get-RelationshipsBetween 'Backend' @($source) @(Resolve-Targets $State $address) "$($gateway.Key): $(Format-TfValue $address)"
                    }
                }
            }
        }
    }
}

# Piu' route verso lo stesso gruppo di origini, o piu' pool verso lo stesso backend, sono una relazione sola.
function Get-NetworkRelationships($State) {
    $written = @{}
    foreach ($relationship in @(Get-PeeringRelationships $State) + @(Get-OriginRelationships $State) + @(Get-BackendRelationships $State)) {
        $key = "$($relationship.kind)|$($relationship.source)|$($relationship.sourceContainer)|$($relationship.target)|$($relationship.targetContainer)"
        if ($written.ContainsKey($key)) { continue }
        $written[$key] = $true
        $relationship
    }
}

# Ogni ambiente del modello ha l'ambiente dell'allocazione, con il suo nome, e quello della rete.
function Get-DeploymentEnvironments([string]$Name, $Items, $Hosted, [hashtable]$ContainerNames) {
    $identified = @(Get-IdentifiedItems $Items)
    $allocation = New-NodeState $Name $identified $Hosted
    [ordered]@{ name = $Name; kind = 'allocation'; nodes = @(Get-AllocationNodes $allocation) }
    $networkName = "$Name $NetworkEnvironmentSuffix"
    $network = New-NodeState $networkName $identified $Hosted
    $network.ContainerNames = $ContainerNames
    $nodes = @(Get-NetworkNodes $network)
    [ordered]@{ name = $networkName; kind = 'network'; environment = $Name; nodes = $nodes; relationships = @(Get-NetworkRelationships $network) }
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
        $script:DeclaredPatterns = [System.Collections.Generic.HashSet[string]]::new()
        $hostPatterns = @($model.Hosts | ForEach-Object { $_.resource } | Where-Object { $_ })
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
        $containerNames = @{}
        $model.Containers | ForEach-Object { $containerNames["$($_.id)"] = "$($_.name)" }
        $deployment = @(foreach ($name in $itemsByEnvironment.Keys) { Get-DeploymentEnvironments $name $itemsByEnvironment[$name] $hosted $containerNames })
    }
    catch [TfError] { return New-Issue $Repository 'dichiarazione Terraform non valutata' $_.Exception.Message }
    $manifests = @(Get-SourceFiles '*.tf' | ForEach-Object { Get-RelativePath $_.FullName })
    Write-C4Fragment 'terraform' $manifests @() @() -Deployment $deployment
}

Invoke-Verification { Get-ReadIssues } "Dichiarazione Terraform di $Repository letta" 'Lettura della dichiarazione Terraform disattivata'
