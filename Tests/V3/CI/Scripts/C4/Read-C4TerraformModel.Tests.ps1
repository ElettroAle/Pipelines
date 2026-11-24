#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/Read-C4TerraformModel.ps1

.DESCRIPTION
    Ogni scenario scrive un repository Terraform finto (Fixtures/TerraformFixture.ps1) con i frammenti dei
    lettori dei container ed esegue il lettore come in pipeline, in un processo separato.
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/TerraformFixture.ps1"
    . "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/Structurizr.ps1"

    function Set-FileText([System.Collections.IDictionary]$Files, [string]$Path, [string]$Old, [string]$New) {
        # Su Windows il checkout porta le here-string della fixture a CRLF.
        $Files[$Path] = $Files[$Path] -replace "`r`n", "`n"
        if (-not $Files[$Path].Contains($Old)) { throw "Testo assente da ${Path}: $Old" }
        $Files[$Path] = $Files[$Path].Replace($Old, $New)
    }

    function Test-HasInstance($Fragment, [string]$Environment, [string]$Container) {
        return [bool]@(Get-AllNodes (Get-DeploymentEnvironment $Fragment $Environment).nodes | Where-Object { (Get-InstanceContainers $_) -contains $Container }).Count
    }

    function Get-InstancePath($Fragment, [string]$Environment, [string]$Container) {
        return Get-NodePath (Get-DeploymentEnvironment $Fragment $Environment).nodes { param($node) (Get-InstanceContainers $node) -contains $Container }
    }

    # Le relazioni fra i container le dichiara il codice delle applicazioni: l'API legge i segreti del Key Vault e
    # il Worker chiama l'API.
    function New-RelatedFragments {
        $fragments = New-ContainerFragments
        $applications = $fragments['contoso.shop.ai.dotnet10.json'] | ConvertFrom-Json
        $applications.relationships = @(
            [pscustomobject]@{ source = 'contoso_shop_ai_api'; target = 'contoso_infrastructure_kv_contoso_prod' }
            [pscustomobject]@{ source = 'contoso_shop_ai_worker'; target = 'contoso_shop_ai_api' }
        )
        $fragments['contoso.shop.ai.dotnet10.json'] = $applications | ConvertTo-Json -Depth 10
        return $fragments
    }

    function Invoke-DeploymentGeneration([System.Collections.IDictionary]$Files = (New-TerraformRepository), [string]$Language = '') {
        $environment = @{ C4_DEPLOYMENT_ENVIRONMENTS = 'dev=dev-x;sta=sta-x;prod=prod-x'; C4_TERRAFORM_INSTANCES = 'Customers:customer_id=environments/{environment}/data/*'; GATE_MODE = 'enforce'; DOCUMENT_LANGUAGE = $Language }
        return Invoke-C4Steps $Files 'Contoso.Infrastructure' @('C4/Read-C4TerraformModel.ps1', 'C4/Export-C4CodeModel.ps1') 'write' (New-RelatedFragments) $environment
    }

    function Add-ElementNames($Element, [hashtable]$Names, [hashtable]$Relationships, [hashtable]$Containers) {
        $Names["$($Element.id)"] = if ($Element.containerId) { $Containers["$($Element.containerId)"] } else { $Element.name }
        @($Element.relationships) | Where-Object { $_ } | ForEach-Object { $Relationships["$($_.id)"] = $_ }
        foreach ($inner in @($Element.children) + @($Element.infrastructureNodes) + @($Element.containerInstances)) {
            if ($inner) { Add-ElementNames $inner $Names $Relationships $Containers }
        }
    }

    # Il modello generato nel workspace del documento, con i container delle applicazioni e le loro relazioni.
    function Export-DeploymentWorkspace($Generation) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-deployment-dsl-$(New-Guid)"
        try {
            Write-SourceFiles $dir ([ordered]@{
                    'generated/containers/contoso.infrastructure.dsl'       = $Generation.Generated['containers/contoso.infrastructure.dsl']
                    'generated/deployment/contoso.infrastructure.dsl'       = $Generation.Generated['deployment/contoso.infrastructure.dsl']
                    'generated/deployment-views/contoso.infrastructure.dsl' = $Generation.Generated['deployment-views/contoso.infrastructure.dsl']
                    'workspace.dsl'                                         = @'
workspace {
    model {
        sistema = softwareSystem "Contoso.Shop" {
            contoso_shop_ai_api = container "Api"
            contoso_shop_ai_worker = container "Worker"
            !include generated/containers
        }
        contoso_shop_ai_api -> contoso_infrastructure_kv_contoso_prod "Legge i segreti"
        contoso_shop_ai_worker -> contoso_shop_ai_api "Chiama"
        !include generated/deployment
    }
    views {
        !include generated/deployment-views
    }
}
'@
                })
            $export = Export-StructurizrWorkspace (Join-Path $dir 'workspace.dsl')
            $names = @{}
            $relationships = @{}
            $containers = @{}
            @($export.Workspace.model.softwareSystems.containers) | Where-Object { $_ } | ForEach-Object { $containers["$($_.id)"] = $_.name }
            @($export.Workspace.model.deploymentNodes) | Where-Object { $_ } | ForEach-Object { Add-ElementNames $_ $names $relationships $containers }
            return [pscustomobject]@{ Error = $export.Error; Workspace = $export.Workspace; Names = $names; Relationships = $relationships }
        }
        finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    function Get-ExportedView($Export, [string]$Key) {
        return $Export.Workspace.views.deploymentViews | Where-Object key -EQ $Key
    }

    function Get-ShownNames($Export, [string]$Key) {
        return @((Get-ExportedView $Export $Key).elements | ForEach-Object { $Export.Names["$($_.id)"] } | Where-Object { $_ })
    }

    function Get-ShownRelationships($Export, [string]$Key) {
        return @((Get-ExportedView $Export $Key).relationships | ForEach-Object { $Export.Relationships["$($_.id)"] } | Where-Object { $_ } |
                ForEach-Object { "$($Export.Names["$($_.sourceId)"]) -> $($Export.Names["$($_.destinationId)"]): $($_.description)" } | Sort-Object)
    }

    function Get-ViewKeys($Generation) {
        return @([regex]::Matches($Generation.Generated['deployment-views/contoso.infrastructure.dsl'], '(?m)^deployment \* "[^"]+" "([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    }
}

Describe "Funzionalità: Viste di deployment generate dall'infrastruttura" {

    Context "Scenario: viste di deployment generate" {
        BeforeAll { $result = Invoke-TerraformReader (New-TerraformRepository) }

        It "Allora il modello contiene gli ambienti di deployment ""dev"", ""sta"" e ""prod""" {
            $result.ExitCode | Should -Be 0 -Because $result.Output
            @($result.Fragment.deployment.name) | Should -Be @('dev', 'dev rete', 'sta', 'sta rete', 'prod', 'prod rete')
        }

        It "E ogni applicazione generata ha un'istanza negli ambienti in cui l'infrastruttura la dichiara" {
            foreach ($environment in 'dev', 'sta', 'prod') { Test-HasInstance $result.Fragment $environment 'contoso_shop_ai_api' | Should -BeTrue }
            Test-HasInstance $result.Fragment 'dev' 'contoso_shop_ai_worker' | Should -BeTrue
            Test-HasInstance $result.Fragment 'prod' 'contoso_shop_ai_worker' | Should -BeTrue
        }

        It "E ogni nodo generato ha una descrizione" {
            $nodes = @($result.Fragment.deployment | ForEach-Object { Get-AllNodes $_.nodes })
            $nodes.Count | Should -BeGreaterThan 0
            @($nodes | Where-Object { -not $_.text }) | Should -BeNullOrEmpty
        }

        It "E nessuna parte delle viste di deployment è scritta a mano" {
            @($result.Fragment.manifests) | Should -Contain 'App/main.tf'
            @($result.Fragment.containers) | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: applicazione integrata in una subnet" {
        BeforeAll { $result = Invoke-TerraformReader (New-TerraformRepository) }

        It "Allora nell'allocazione l'istanza dell'applicazione sta nel nodo del piano di hosting, nella sua regione" {
            (Get-InstancePath $result.Fragment 'prod' 'contoso_shop_ai_api') | Should -Be @('westeurope', 'asp-contoso-prod')
        }

        It "E nella rete l'istanza sta nella subnet ""snet-engine"" della sua rete virtuale" {
            (Get-InstancePath $result.Fragment 'prod rete' 'contoso_shop_ai_api') | Should -Be @('vnet-contoso-prod', 'snet-engine')
        }
    }

    Context "Scenario: risorsa dichiarata in un solo ambiente" {
        BeforeAll {
            $files = New-TerraformRepository
            $files['source/App/archive.tf'] = @'
resource "azurerm_private_endpoint" "archive" {
  count               = length(azurerm_storage_account.archive)
  name                = "pe-archive-${var.environment}"
  resource_group_name = azurerm_resource_group.app.name
  subnet_id           = azurerm_subnet.engine.id

  private_service_connection {
    name                           = "archive"
    private_connection_resource_id = azurerm_storage_account.archive[0].id
    subresource_names              = ["blob"]
  }
}
'@
            $result = Invoke-TerraformReader $files
        }

        It "Allora la vista di rete ""dev"" contiene il private endpoint dello Storage Account, con il nome della risorsa che espone" {
            $result.ExitCode | Should -Be 0 -Because $result.Output
            Find-Node $result.Fragment 'dev rete' 'stcontosoarchivedev' | Should -Not -BeNullOrEmpty
        }

        It "E le viste di rete ""sta"" e ""prod"" non lo contengono" {
            Find-Node $result.Fragment 'sta rete' 'stcontosoarchivesta' | Should -BeNullOrEmpty
            Find-Node $result.Fragment 'prod rete' 'stcontosoarchiveprod' | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: applicazione rimossa da un ambiente" {
        BeforeAll { $result = Invoke-TerraformReader (New-TerraformRepository) }

        It "Allora la vista di deployment ""sta"" non contiene un'istanza di ""Worker""" {
            $result.ExitCode | Should -Be 0 -Because $result.Output
            Test-HasInstance $result.Fragment 'sta' 'contoso_shop_ai_worker' | Should -BeFalse
        }
    }

    Context "Scenario: nodo non riconosciuto" {
        BeforeAll {
            $files = New-TerraformRepository
            $files['source/App/jobs.tf'] = @'
resource "azurerm_container_app" "jobs" {
  name            = "ca-jobs"
  service_plan_id = azurerm_service_plan.backend.id
}
'@
            $result = Invoke-TerraformReader $files
        }

        It "Allora la generazione fallisce nominando la risorsa" {
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'risorsa di hosting di un tipo che le regole non riconoscono \(App/azurerm_container_app\.jobs'
        }

        It "E il modello non cambia" {
            $result.Fragment | Should -BeNullOrEmpty
        }
    }
}

Describe "Funzionalità: Viste di deployment che rispondono a una domanda" {
    BeforeAll {
        $generation = Invoke-DeploymentGeneration
        $export = Export-DeploymentWorkspace $generation
        $purposes = (Import-PowerShellDataFile "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/Languages/IT.psd1").ViewPurposes
    }

    Context "Scenario: la vista di allocazione mostra solo i piani di calcolo con le applicazioni che ospitano e le chiamate fra le applicazioni" {
        It "Allora la vista ""deployment_prod"" mostra i piani di calcolo con le applicazioni che ospitano, nella loro regione" {
            $generation.ExitCode | Should -Be 0 -Because $generation.Output
            $export.Error | Should -BeNullOrEmpty
            Get-ShownNames $export 'deployment_prod' | Sort-Object | Should -Be @('Api', 'asp-contoso-prod', 'westeurope', 'Worker')
        }

        It "E non mostra reti, subnet, private endpoint, gruppi di risorse ne' servizi gestiti" {
            $shown = Get-ShownNames $export 'deployment_prod'
            foreach ($hidden in 'vnet-contoso-prod', 'snet-engine', 'Api · sites', 'rg-contoso-prod', 'kv-contoso-prod', 'afd-contoso-prod') { $shown | Should -Not -Contain $hidden }
        }

        It "E mostra le chiamate fra le applicazioni" {
            Get-ShownRelationships $export 'deployment_prod' | Should -Be @('Worker -> Api: Chiama')
        }
    }

    Context "Scenario: la vista di allocazione di un'applicazione mostra il suo piano e i servizi gestiti che usa, con le relazioni vere" {
        It "Allora la vista dell'applicazione mostra il suo piano, i servizi gestiti che usa e le applicazioni con cui comunica" {
            Get-ShownNames $export 'deployment_prod_app_contoso_shop_ai_api' | Sort-Object | Should -Be @('Api', 'asp-contoso-prod', 'kv-contoso-prod', 'westeurope', 'Worker')
        }

        It "E mostra solo le relazioni dell'applicazione, quelle che il codice dichiara" {
            Get-ShownRelationships $export 'deployment_prod_app_contoso_shop_ai_api' | Should -Be @('Api -> kv-contoso-prod: Legge i segreti', 'Worker -> Api: Chiama')
        }

        It "E la vista di un'altra applicazione non mostra i servizi che quella non usa" {
            Get-ShownNames $export 'deployment_prod_app_contoso_shop_ai_worker' | Should -Not -Contain 'kv-contoso-prod'
            Get-ShownRelationships $export 'deployment_prod_app_contoso_shop_ai_worker' | Should -Be @('Worker -> Api: Chiama')
        }
    }

    Context "Scenario: la vista di rete mostra come arriva il traffico e come si collegano le reti, ricavati dalla dichiarazione Terraform" {
        It "Allora la vista ""deployment_prod_rete"" mostra chiusi il Front Door e le reti virtuali" {
            Get-ShownNames $export 'deployment_prod_rete' | Sort-Object | Should -Be @('afd-contoso-prod', 'vnet-contoso-prod', 'vnet-shared')
        }

        It "E le relazioni fra loro dicono il peering e il percorso del traffico in ingresso" {
            Get-ShownRelationships $export 'deployment_prod_rete' | Should -Be @(
                "afd-contoso-prod -> vnet-contoso-prod: Inoltra le richieste all'origine"
                'vnet-contoso-prod -> vnet-shared: Collega le due reti con un peering'
                'vnet-contoso-prod -> vnet-shared: Inoltra le richieste al backend'
            )
        }

        It "E la vista di una rete mostra le subnet, le applicazioni integrate e l'Application Gateway, con chiuse le reti con cui comunica" {
            $shown = Get-ShownNames $export 'deployment_prod_rete_vnet_contoso_prod'
            foreach ($name in 'vnet-contoso-prod', 'snet-engine', 'Api', 'snet-worker', 'Worker', 'snet-gateway', 'agw-contoso-prod', 'vnet-shared', 'afd-contoso-prod') { $shown | Should -Contain $name }
            $shown | Should -Not -Contain 'snet-endpoints'
            $shown | Should -Not -Contain 'fde-contoso-prod'
        }

        It "E l'Application Gateway inoltra le richieste all'applicazione che il suo backend nomina" {
            Get-ShownRelationships $export 'deployment_prod_rete_vnet_contoso_prod' | Should -Contain 'agw-contoso-prod -> Api: Inoltra le richieste al backend'
        }

        It "E la rete condivisa mostra i private endpoint con il nome della risorsa che espongono e i servizi esposti" {
            $shown = Get-ShownNames $export 'deployment_prod_rete_vnet_shared'
            foreach ($name in 'snet-endpoints', 'Api · sites', 'Api · scm') { $shown | Should -Contain $name }
        }

        It "E un collegamento verso un indirizzo che la dichiarazione non risolve lo dice un avviso" {
            $generation.Output | Should -Match ([regex]::Escape('##vso[task.logissue type=warning]Contoso.Infrastructure: collegamento di rete non risolto (App/azurerm_cdn_frontdoor_origin.external: www.example.org)'))
        }
    }

    Context "Scenario: i gruppi di risorse stanno in una tabella del testo, con il contenuto e il modulo che li dichiara" {
        It "Allora la vista di allocazione nomina gli ambienti di cui il documento elenca i gruppi di risorse" {
            (Get-ExportedView $export 'deployment_prod').properties.resourceGroups | Should -Be 'prod;prod rete'
        }

        It "E ogni nodo e ogni istanza nei gruppi di risorse portano il gruppo e il modulo che li dichiara" {
            $deployment = $generation.Generated['deployment/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
            $allocation = Get-Block $deployment '^deploymentEnvironment "prod" \{'
            $network = Get-Block $deployment '^deploymentEnvironment "prod rete" \{'
            Get-Block $allocation 'containerInstance contoso_shop_ai_api' | Should -Match '"resourceGroup" "rg-contoso-prod"\s+"module" "App"'
            Get-Block $network 'infrastructureNode "Api · sites"' | Should -Match '"resourceGroup" "rg-contoso-prod"\s+"module" "App"'
            Get-Block $network 'deploymentNode "snet-endpoints"' | Should -Match '"resourceGroup" "rg-shared-shared"\s+"module" "Shared"'
        }
    }

    Context "Scenario: ogni tipo di vista porta una frase fissa che dice il suo scopo, nel disegno" {
        It "Allora ogni vista di deployment comincia la sua descrizione con la frase del suo tipo" {
            $kinds = [ordered]@{ '^deployment_prod$' = 'Allocation'; '^deployment_prod_app_' = 'ApplicationAllocation'; '^deployment_prod_rete$' = 'Network'; '^deployment_prod_rete_' = 'NetworkPart' }
            $views = @($export.Workspace.views.deploymentViews | Where-Object key -Like 'deployment_prod*')
            $views.Count | Should -Be 6
            foreach ($view in $views) {
                $kind = @($kinds.Keys | Where-Object { $view.key -match $_ } | ForEach-Object { $kinds[$_] }) | Select-Object -First 1
                ($view.description -replace '\s+', ' ') | Should -BeLike "$($purposes[$kind])*" -Because $view.key
            }
        }

        It "E il titolo dice il tipo della vista, l'ambiente e la parte che mostra" {
            (Get-ExportedView $export 'deployment_prod').title | Should -Be 'Allocazione · prod'
            (Get-ExportedView $export 'deployment_prod_app_contoso_shop_ai_api').title | Should -Be 'Allocazione · prod · Api'
            (Get-ExportedView $export 'deployment_prod_rete').title | Should -Be 'Rete · prod'
            (Get-ExportedView $export 'deployment_prod_rete_vnet_shared').title | Should -Be 'Rete · prod · vnet-shared'
        }
    }

    Context "Scenario: un gruppo, una rete o un'applicazione nuovi entrano nelle viste senza toccare la libreria" {
        BeforeAll {
            $files = New-TerraformRepository
            $files['source/App/edge.tf'] = @'
resource "azurerm_resource_group" "edge" {
  name     = "rg-edge-${var.environment}"
  location = "Italy North"
}

resource "azurerm_virtual_network" "edge" {
  name                = "vnet-edge-${var.environment}"
  resource_group_name = azurerm_resource_group.edge.name
  location            = azurerm_resource_group.edge.location
}

resource "azurerm_subnet" "jobs" {
  name                 = "snet-jobs"
  resource_group_name  = azurerm_resource_group.edge.name
  virtual_network_name = azurerm_virtual_network.edge.name
}

resource "azurerm_service_plan" "edge" {
  name                = "asp-edge-${var.environment}"
  resource_group_name = azurerm_resource_group.edge.name
  location            = azurerm_resource_group.edge.location
}
'@
            Set-FileText $files 'source/App/main.tf' "  service_plan_id     = azurerm_service_plan.backend.id`n  subnet_id           = azurerm_subnet.worker.id" "  service_plan_id     = azurerm_service_plan.edge.id`n  subnet_id           = azurerm_subnet.jobs.id"
            $grown = Invoke-DeploymentGeneration $files
            $grownExport = Export-DeploymentWorkspace $grown
        }

        It "Allora la vista di allocazione mostra il piano nuovo nella sua regione, con l'applicazione che ospita" {
            $grown.ExitCode | Should -Be 0 -Because $grown.Output
            $grownExport.Error | Should -BeNullOrEmpty
            Get-ShownNames $grownExport 'deployment_prod' | Sort-Object | Should -Be @('Api', 'asp-contoso-prod', 'asp-edge-prod', 'italynorth', 'westeurope', 'Worker')
        }

        It "E la rete nuova ha la sua vista, accanto a quelle che c'erano" {
            $keys = Get-ViewKeys $grown
            foreach ($key in (Get-ViewKeys $generation)) { $keys | Should -Contain $key }
            $keys | Should -Contain 'deployment_prod_rete_vnet_edge_prod'
            Get-ShownNames $grownExport 'deployment_prod_rete_vnet_edge_prod' | Should -Contain 'Worker'
        }
    }
}

Describe 'Read-C4TerraformModel.ps1' {
    Context 'sulla dichiarazione completa' {
        BeforeAll {
            $result = Invoke-TerraformReader (New-TerraformRepository)
        }

        It "scrive per ogni ambiente l'allocazione e la rete, che nomina l'ambiente a cui appartiene" {
            @($result.Fragment.deployment | ForEach-Object { "$($_.name):$($_.kind):$($_.environment)" }) | Should -Be @('dev:allocation:', 'dev rete:network:dev', 'sta:allocation:', 'sta rete:network:sta', 'prod:allocation:', 'prod rete:network:prod')
        }

        It 'mette un servizio che ospita un container nella regione della sua risorsa, con il gruppo di risorse e il modulo' {
            (Get-InstancePath $result.Fragment 'prod' 'contoso_infrastructure_kv_contoso_prod') | Should -Be @('westeurope')
            $instance = (Find-Node $result.Fragment 'prod' 'westeurope').instances | Where-Object container -EQ 'contoso_infrastructure_kv_contoso_prod'
            $instance.resourceGroup | Should -Be 'rg-contoso-prod'
            $instance.module | Should -Be 'App'
        }

        It "da' un'istanza del servizio anche negli ambienti dove la stessa risorsa ha un altro nome" {
            Test-HasInstance $result.Fragment 'dev' 'contoso_infrastructure_kv_contoso_prod' | Should -BeTrue
        }

        It 'dichiara la regione come tecnologia e il piano con il suo tipo Azure, il gruppo di risorse e il modulo' {
            $region = Find-Node $result.Fragment 'prod' 'westeurope'
            $region.technology | Should -Be 'Azure region'
            $plan = Find-Node $result.Fragment 'prod' 'asp-contoso-prod'
            $plan.technology | Should -Be 'Microsoft.Web/serverfarms'
            $plan.resourceGroup | Should -Be 'rg-contoso-prod'
            $plan.module | Should -Be 'App'
        }

        It 'mette un private endpoint nella subnet di un altro modulo letta dal remote state, con la risorsa e i servizi che espone' {
            $endpoint = Get-AllNodes (Get-DeploymentEnvironment $result.Fragment 'prod rete').nodes | Where-Object { $_.exposes -eq 'contoso_shop_ai_api' -and $_.subresources -eq 'sites' }
            $endpoint.kind | Should -Be 'infrastructureNode'
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod rete').nodes { param($node) $node.subresources -eq 'scm' }) | Should -Be @('vnet-shared', 'snet-endpoints', 'Api')
        }

        It "porta la rete condivisa negli ambienti che ne leggono lo stato" {
            foreach ($environment in 'dev rete', 'sta rete', 'prod rete') { Find-Node $result.Fragment $environment 'vnet-shared' | Should -Not -BeNullOrEmpty }
        }

        It "mette l'Application Gateway nella subnet della sua configurazione e l'endpoint del Front Door nel suo profilo" {
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod rete').nodes { param($node) $node.name -eq 'agw-contoso-prod' }) | Should -Be @('vnet-contoso-prod', 'snet-gateway', 'agw-contoso-prod')
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod rete').nodes { param($node) $node.name -eq 'fde-contoso-prod' }) | Should -Be @('afd-contoso-prod', 'fde-contoso-prod')
        }

        It "scrive una volta il peering fra due reti, dichiarato dai due lati" {
            $network = Get-DeploymentEnvironment $result.Fragment 'prod rete'
            @($network.relationships | Where-Object kind -EQ 'Peering').Count | Should -Be 1
        }

        It "lega l'endpoint del Front Door all'Application Gateway attraverso il record DNS e l'IP pubblico dell'origine" {
            $network = Get-DeploymentEnvironment $result.Fragment 'prod rete'
            $origin = @($network.relationships | Where-Object kind -EQ 'Origin')
            $origin.Count | Should -Be 1
            $origin[0].source | Should -Match 'afdendpoints_fde_contoso_prod$'
            $origin[0].target | Should -Match 'applicationgateways_agw_contoso_prod$'
        }

        It "lega l'Application Gateway all'applicazione del nome nel backend e al private endpoint dell'indirizzo in un blocco dinamico" {
            $network = Get-DeploymentEnvironment $result.Fragment 'prod rete'
            $backend = @($network.relationships | Where-Object kind -EQ 'Backend')
            @($backend | Where-Object targetContainer -EQ 'contoso_shop_ai_api').Count | Should -Be 1
            @($backend | Where-Object { $_.target -match 'privateendpoints_pe_contoso_prod_api$' }).Count | Should -Be 1
        }

        It "non scrive nell'allocazione un servizio che non ospita container" {
            Find-Node $result.Fragment 'dev' 'stcontosoarchivedev' | Should -BeNullOrEmpty
        }
    }

    Context 'piani e applicazioni' {
        It "toglie dalla subnet l'applicazione che non vi si integra e la lascia nel suo piano" {
            $files = New-TerraformRepository
            Set-FileText $files 'source/App/main.tf' '  subnet_id      = azurerm_subnet.engine.id' '  subnet_id      = azurerm_subnet.engine.id`n  count = 0'.Replace('`n', "`n")
            $result = Invoke-TerraformReader $files
            $result.ExitCode | Should -Be 0 -Because $result.Output
            (Get-InstancePath $result.Fragment 'prod' 'contoso_shop_ai_api') | Should -Be @('westeurope', 'asp-contoso-prod')
            (Get-InstancePath $result.Fragment 'prod rete' 'contoso_shop_ai_api') | Should -BeNullOrEmpty
        }

        It "legge piano e subnet di un'app dichiarata con azapi" {
            $files = New-TerraformRepository
            $files['source/App/backup.tf'] = @'
resource "azapi_resource" "backup" {
  type      = "Microsoft.Web/sites@2024-04-01"
  name      = "func-backup-${var.environment}"
  parent_id = azurerm_resource_group.app.id
  body = {
    properties = {
      serverFarmId           = azurerm_service_plan.backend.id
      virtualNetworkSubnetId = azurerm_subnet.worker.id
    }
  }
}

resource "azapi_resource" "ignored" {
  type      = "Microsoft.Insights/components@2020-02-02"
  name      = "ai-backup"
  parent_id = azurerm_resource_group.app.id
}
'@
            $result = Invoke-TerraformReader $files
            $result.ExitCode | Should -Be 0 -Because $result.Output
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod').nodes { param($node) $node.name -eq 'func-backup-prod' }) | Should -Be @('westeurope', 'asp-contoso-prod', 'func-backup-prod')
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod rete').nodes { param($node) $node.name -eq 'func-backup-prod' }) | Should -Be @('vnet-contoso-prod', 'snet-worker', 'func-backup-prod')
            Find-Node $result.Fragment 'prod' 'ai-backup' | Should -BeNullOrEmpty
        }

        It "mette nella regione della risorsa un'applicazione senza piano, e una regione segnaposto se nessuno la dichiara" {
            $files = New-TerraformRepository
            $files['source/App/site.tf'] = @'
resource "azurerm_static_web_app" "site" {
  name                = "stapp-${var.environment}"
  resource_group_name = "rg-existing"
}

resource "azurerm_static_web_app" "portal" {
  name                = "stapp-portal-${var.environment}"
  resource_group_name = azurerm_resource_group.app.name
  location            = "West Europe 2"
}
'@
            $result = Invoke-TerraformReader $files
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod').nodes { param($node) $node.name -eq 'stapp-prod' }) | Should -Be @('{location}', 'stapp-prod')
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod').nodes { param($node) $node.name -eq 'stapp-portal-prod' }) | Should -Be @('westeurope2', 'stapp-portal-prod')
        }

        It "applica i file override dell'ambiente" {
            $files = New-TerraformRepository
            $files['source/App/environments/prod-x/network_override.tf'] = "resource `"azurerm_subnet`" `"engine`" {`n  name = `"snet-engine-static`"`n}`n"
            $result = Invoke-TerraformReader $files
            Find-Node $result.Fragment 'prod rete' 'snet-engine-static' | Should -Not -BeNullOrEmpty
            Find-Node $result.Fragment 'dev rete' 'snet-engine' | Should -Not -BeNullOrEmpty
        }

        It "riconosce la risorsa di un provider con alias passato al modulo, a prescindere dalla sottoscrizione" {
            $files = New-TerraformRepository
            Set-FileText $files 'source/App/main.tf' 'variable "environment" {' "provider `"azurerm`" {`n  alias           = `"other`"`n  features {}`n  subscription_id = `"0000-1111`"`n}`n`nvariable `"environment`" {"
            Set-FileText $files 'source/App/main.tf' "module `"api`" {`n  source              = `"../../../Modules/WebApp`"" "module `"api`" {`n  source              = `"../../../Modules/WebApp`"`n  providers = {`n    azurerm = azurerm.other`n  }"
            Set-FileText $files 'source/App/main.tf' "resource `"azurerm_key_vault`" `"secrets`" {" "resource `"azurerm_key_vault`" `"secrets`" {`n  provider            = azurerm.other"
            $result = Invoke-TerraformReader $files
            $result.ExitCode | Should -Be 0 -Because $result.Output
            (Get-InstancePath $result.Fragment 'prod' 'contoso_infrastructure_kv_contoso_prod') | Should -Be @('westeurope')
            (Get-InstancePath $result.Fragment 'prod rete' 'contoso_shop_ai_api') | Should -Be @('vnet-contoso-prod', 'snet-engine')
        }
    }

    Context 'rilievi' {
        It 'nomina la risorsa che ospita un container ed e'' di un tipo sconosciuto' {
            $files = New-TerraformRepository
            $files['source/App/vm.tf'] = "resource `"azurerm_virtual_machine`" `"jobs`" {`n  name = `"vm-jobs`"`n}`n"
            $fragments = New-ContainerFragments
            $fragments['contoso.infrastructure.azure.json'] = $fragments['contoso.infrastructure.azure.json'].Replace('App/module.worker/azurerm_linux_web_app.this', 'App/azurerm_virtual_machine.jobs')
            $result = Invoke-TerraformReader $files $fragments
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'risorsa di hosting di un tipo che le regole non riconoscono \(App/azurerm_virtual_machine\.jobs \(azurerm_virtual_machine'
        }

        It 'segnala un servizio del modello che la dichiarazione non ospita' {
            $files = New-TerraformRepository
            Set-FileText $files 'source/App/main.tf' 'name                = "kv-${local.suffix}"' 'name                = "kv-other"'
            $result = Invoke-TerraformReader $files
            $result.ExitCode | Should -Not -Be 0
            $result.Output | Should -Match 'servizio del modello che la dichiarazione non ospita \(contoso_infrastructure_kv_contoso_prod'
        }

        It "ospita un container sulle risorse che hosts nomina con il nome Azure, in ogni istanza del modulo radice" {
            $fragments = New-ContainerFragments
            $grouped = [ordered]@{ containers = @([ordered]@{ id = 'contoso_infrastructure_mail'; name = 'Invio email dei clienti'; codeName = 'Invio email dei clienti'; tags = @(); components = @() }); relationships = @(); hosts = @([ordered]@{ container = 'contoso_infrastructure_mail'; name = 'ACS-NORTH-PROD' }) }
            $fragments['contoso.infrastructure.customers.json'] = $grouped | ConvertTo-Json -Depth 10
            $result = Invoke-TerraformReader (New-TerraformRepository) $fragments
            $result.ExitCode | Should -Be 0 -Because $result.Output
            (Get-InstancePath $result.Fragment 'prod' 'contoso_infrastructure_mail') | Should -Be @('westeurope')
            ((Find-Node $result.Fragment 'prod' 'westeurope').instances | Where-Object container -EQ 'contoso_infrastructure_mail').resourceGroup | Should -Be 'rg-north-prod'
        }

        It "accetta in hosts una risorsa dichiarata senza istanze in nessun ambiente" {
            $files = New-TerraformRepository
            $files['source/Modules/WebApp/windows.tf'] = "resource `"azurerm_windows_web_app`" `"this`" {`n  count           = 0`n  name            = var.name`n  service_plan_id = var.service_plan_id`n}`n"
            $fragments = New-ContainerFragments
            $infrastructure = $fragments['contoso.infrastructure.azure.json'] | ConvertFrom-Json
            $infrastructure.hosts += [pscustomobject]@{ container = 'contoso_shop_ai_api'; resource = 'App/module.api/azurerm_windows_web_app.this' }
            $fragments['contoso.infrastructure.azure.json'] = $infrastructure | ConvertTo-Json -Depth 10
            $result = Invoke-TerraformReader $files $fragments
            $result.ExitCode | Should -Be 0 -Because $result.Output
        }

        It "segnala un nome di hosts assente dalla dichiarazione" {
            $fragments = New-ContainerFragments
            $fragments['contoso.infrastructure.customers.json'] = [ordered]@{ containers = @(); relationships = @(); hosts = @([ordered]@{ container = 'contoso_infrastructure_mail'; name = 'acs-west-prod' }) } | ConvertTo-Json -Depth 10
            $result = Invoke-TerraformReader (New-TerraformRepository) $fragments
            $result.Output | Should -Match 'risorsa che ospita un container assente dalla dichiarazione \(contoso_infrastructure_mail: acs-west-prod'
        }

        It "segnala una risorsa di hosts assente dalla dichiarazione" {
            $fragments = New-ContainerFragments
            $fragments['contoso.infrastructure.azure.json'] = $fragments['contoso.infrastructure.azure.json'].Replace('module.worker', 'module.jobs')
            $result = Invoke-TerraformReader (New-TerraformRepository) $fragments
            $result.Output | Should -Match 'risorsa che ospita un container assente dalla dichiarazione \(contoso_shop_ai_worker: App/module\.jobs'
        }

        It 'ferma la lettura su istanze sconosciute di una risorsa dei nodi' {
            $files = New-TerraformRepository
            Set-FileText $files 'source/App/main.tf' 'count               = coalesce(var.settings.archive, false) ? 1 : 0' 'count               = var.subscription_id == "x" ? 1 : 0'
            $result = Invoke-TerraformReader $files
            $result.Output | Should -Match 'istanze di azurerm_storage_account\.archive sconosciute'
        }

        It 'segnala un ambiente senza directory' {
            $files = New-TerraformRepository
            @($files.Keys | Where-Object { $_ -like 'source/App/environments/sta-x/*' }) | ForEach-Object { $files.Remove($_) }
            $result = Invoke-TerraformReader $files
            $result.Output | Should -Match 'ambiente senza directory nella dichiarazione \(sta=sta-x\)'
        }

        It 'segnala gli ambienti non dichiarati' {
            $root = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-terraform-$(New-Guid)"
            Write-SourceFiles $root (New-TerraformRepository)
            Push-Location $root
            try {
                $output = Invoke-C4Script 'C4/Read-C4TerraformModel.ps1' @{ SOURCE_DIRECTORY = 'source'; SOURCE_REPOSITORY = 'Contoso.Infrastructure'; FRAGMENT_DIRECTORY = 'fragments'; C4_SCRIPTS_DIRECTORY = "$C4ScriptsDirectory"; C4_DEPLOYMENT_ENVIRONMENTS = ''; GATE_MODE = 'enforce' }
            }
            finally { Pop-Location; Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
            $output.Output | Should -Match 'ambienti del modello non dichiarati'
        }

        It "riporta un'espressione che il valutatore non conosce" {
            $files = New-TerraformRepository
            Set-FileText $files 'source/App/main.tf' 'suffix = "contoso-${var.environment}"' 'suffix = unknownfn(var.environment)'
            $result = Invoke-TerraformReader $files
            $result.Output | Should -Match 'dichiarazione Terraform non valutata \(App/main\.tf:\d+: funzione unknownfn non supportata'
        }

        It "da' un avviso, e non ferma la lettura, su un collegamento di rete che il valutatore non sa leggere" {
            $files = New-TerraformRepository
            Set-FileText $files 'source/App/main.tf' 'fqdns = [module.api.default_hostname]' 'fqdns = [unknownfn("app")]'
            $result = Invoke-TerraformReader $files
            $result.ExitCode | Should -Be 0 -Because $result.Output
            $result.Output | Should -Match 'type=warning\]Contoso\.Infrastructure: collegamento di rete non risolto \(App/azurerm_application_gateway\.edge: .*unknownfn'
        }
    }
}

Describe 'Export-C4CodeModel.ps1 sugli ambienti di deployment' {
    BeforeAll {
        $text = [ordered]@{ units = [ordered]@{ contoso_infrastructure_app = [ordered]@{ elements = [ordered]@{ contoso_infrastructure_app_azurerm_subnet_engine = 'La subnet delle API' }; relationships = @{} } } }
        $files = New-TerraformRepository
        $files['docs/architecture/c4/generated/model.text.json'] = $text | ConvertTo-Json -Depth 10
        $result = Invoke-DeploymentGeneration $files
        $deployment = $result.Generated['deployment/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
        $views = $result.Generated['deployment-views/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
    }

    It "scrive per ambiente del modello l'allocazione e la rete, fuori dalla parte dei container" {
        $result.ExitCode | Should -Be 0 -Because $result.Output
        @([regex]::Matches($deployment, '(?m)^deploymentEnvironment "([\w ]+)" \{') | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('dev', 'dev rete', 'sta', 'sta rete', 'prod', 'prod rete')
        $result.Generated['containers/contoso.infrastructure.dsl'] | Should -Not -Match 'deploymentEnvironment'
    }

    It 'annida i nodi con tecnologia, tag dei generati e descrizione dal testo del modello' {
        $deployment | Should -Match 'deploymentNode "snet-engine" "La subnet delle API" "Microsoft.Network/virtualNetworks/subnets" "Generato" \{'
        $deployment | Should -Match 'infrastructureNode "agw-contoso-prod" "" "Microsoft.Network/applicationGateways" "Generato"'
    }

    It "distingue con i servizi esposti due private endpoint della stessa risorsa nella stessa subnet" {
        $deployment | Should -Match 'infrastructureNode "Api · sites"'
        $deployment | Should -Match 'infrastructureNode "Api · scm"'
    }

    It "scrive nell'ambiente della rete le relazioni con il tag della rete e i riassunti fra le radici con il tag dei riassunti" {
        $network = Get-Block $deployment 'deploymentEnvironment "prod rete"'
        $network | Should -Match '_vnet_contoso_prod -> \w+_vnet_shared "Collega le due reti con un peering" "" "Generato,Rete"'
        $network | Should -Match '_afd_contoso_prod -> \w+_vnet_contoso_prod "Inoltra le richieste all''origine" "" "Generato,Rete,Riassunto"'
    }

    It "la vista d'insieme della rete esclude le relazioni fra le istanze e include solo quelle della rete" {
        $overview = Get-Block $views 'deployment \* "prod rete" "deployment_prod_rete" '
        $overview | Should -Match 'exclude relationship==\*'
        $overview | Should -Match 'include "relationship.tag==Rete"'
    }

    It "la vista di un'applicazione include solo le relazioni che partono dalle sue istanze o vi arrivano" {
        $application = Get-Block $views 'deployment \* "prod" "deployment_prod_app_contoso_shop_ai_worker" '
        $application | Should -Match 'include "relationship.source==\w+__contoso_shop_ai_worker"'
        $application | Should -Match 'include "relationship.destination==\w+__contoso_shop_ai_worker"'
    }

    It 'non scrive ambienti per un repository senza dichiarazione di deployment' {
        $result.Generated.Keys | Should -Contain 'containers/contoso.infrastructure.dsl'
        $other = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' (New-ContainerFragments)
        $other.Generated.Keys | Should -Not -Contain 'deployment/contoso.infrastructure.dsl'
    }

    It "scrive l'allocazione di un lettore che non scrive la rete, con tutti i nodi se non ha piani" {
        $fragments = New-ContainerFragments
        $region = [ordered]@{ id = 'x_region'; name = 'westeurope'; technology = 'Azure region'; kind = 'deploymentNode'; text = 'x'; children = @(); instances = @('contoso_shop_ai_api') }
        $fragments['contoso.infrastructure.deployment.json'] = [ordered]@{ containers = @(); relationships = @(); deployment = @([ordered]@{ name = 'prod'; nodes = @($region) }) } | ConvertTo-Json -Depth 10
        $alone = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' $fragments
        $alone.ExitCode | Should -Be 0 -Because $alone.Output
        $aloneViews = $alone.Generated['deployment-views/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
        Get-Block $aloneViews 'deployment \* "prod" "deployment_prod" ' | Should -Match 'include \*'
        Get-Block $aloneViews 'deployment \* "prod" "deployment_prod" ' | Should -Match '"resourceGroups" "prod"'
        $aloneViews | Should -Not -Match 'rete'
    }

    It "da' i nomi della posizione a due nodi fratelli che restano uguali" {
        $fragments = New-ContainerFragments
        $twin = { param($Id) [ordered]@{ id = $Id; name = 'pe'; technology = 'T'; kind = 'infrastructureNode'; text = 'x'; children = @(); instances = @() } }
        $subnet = [ordered]@{ id = 'x_snet'; name = 'snet'; technology = 'T'; kind = 'deploymentNode'; text = 'x'; children = @((& $twin 'x_a'), (& $twin 'x_b')); instances = @() }
        $network = [ordered]@{ id = 'x_vnet'; name = 'vnet'; technology = 'T'; kind = 'deploymentNode'; text = 'x'; children = @($subnet); instances = @() }
        $fragments['contoso.infrastructure.deployment.json'] = [ordered]@{ containers = @(); relationships = @(); deployment = @(
                [ordered]@{ name = 'prod'; kind = 'allocation'; nodes = @() }
                [ordered]@{ name = 'prod rete'; kind = 'network'; environment = 'prod'; nodes = @($network); relationships = @() }
            ) } | ConvertTo-Json -Depth 10
        $twins = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' $fragments
        $twins.ExitCode | Should -Be 0 -Because $twins.Output
        $twins.Generated['deployment/contoso.infrastructure.dsl'] | Should -Match 'x_a = infrastructureNode "pe · 1"'
        $twins.Generated['deployment/contoso.infrastructure.dsl'] | Should -Match 'x_b = infrastructureNode "pe · 2"'
    }

    It "in inglese da' alle viste i titoli e le frasi dello scopo della lingua" {
        $english = Invoke-DeploymentGeneration (New-TerraformRepository) 'EN'
        $english.ExitCode | Should -Be 0 -Because $english.Output
        $purposes = (Import-PowerShellDataFile "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/Languages/EN.psd1").ViewPurposes
        $englishViews = $english.Generated['deployment-views/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
        $englishViews | Should -Match 'title "Allocation · prod"'
        $englishViews | Should -Match '"deployment_prod_network" '
        $englishViews | Should -Match 'title "Network · prod · vnet-shared"'
        ($englishViews -replace '\\n', ' ') | Should -Match ([regex]::Escape($purposes.Network))
        $english.Generated['deployment/contoso.infrastructure.dsl'] | Should -Match 'deploymentEnvironment "prod network"'
    }
}
