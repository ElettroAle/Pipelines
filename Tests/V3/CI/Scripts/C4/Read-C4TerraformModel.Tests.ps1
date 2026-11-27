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

        It "E ogni nodo generato ha il livello da cui nasce la sua descrizione" {
            $nodes = @($result.Fragment.deployment | ForEach-Object { Get-AllNodes $_.nodes })
            $nodes.Count | Should -BeGreaterThan 0
            $levels = (Import-PowerShellDataFile "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/Languages/IT.psd1").NodeDescriptions
            @($nodes | Where-Object { -not $levels.ContainsKey("$($_.kind)") }) | Should -BeNullOrEmpty
        }

        It "E ogni livello di nodo generato ha in ogni lingua il nome con cui le descrizioni delle viste lo riassumono (ADR-2148)" {
            $kinds = @($result.Fragment.deployment | ForEach-Object { Get-AllNodes $_.nodes } | ForEach-Object { "$($_.kind)" } | Sort-Object -Unique)
            foreach ($language in 'IT', 'EN') {
                $summaries = (Import-PowerShellDataFile "$PSScriptRoot/../../../../../V3/CI/Scripts/Common/Languages/$language.psd1").LevelSummaries
                @($kinds + 'containerInstance' | Where-Object { -not $summaries -or -not $summaries.ContainsKey($_) }) | Should -BeNullOrEmpty -Because $language
            }
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

    Context "Scenario: una vista di deployment il cui soggetto e' un elemento del modello lo porta nelle proprieta' (ADR-2165)" {
        BeforeAll {
            function Get-IdentifiedNodeName($Nodes, [string]$Identifier) {
                foreach ($node in @($Nodes | Where-Object { $_ })) {
                    if ($node.properties.'structurizr.dsl.identifier' -eq $Identifier) { return $node.name }
                    Get-IdentifiedNodeName $node.children $Identifier
                }
            }
        }

        It "Allora la vista di un'applicazione ha come soggetto il container dell'applicazione" {
            (Get-ExportedView $export 'deployment_prod_app_contoso_shop_ai_api').properties.subject | Should -Be 'contoso_shop_ai_api'
        }

        It "E la vista di una rete ha come soggetto il nodo della rete" {
            $subject = (Get-ExportedView $export 'deployment_prod_rete_vnet_shared').properties.subject
            $subject | Should -Not -BeNullOrEmpty
            Get-IdentifiedNodeName $export.Workspace.model.deploymentNodes $subject | Should -Be 'vnet-shared'
        }

        It "E le viste d'insieme dell'ambiente, il cui soggetto e' l'ambiente e non un elemento, non hanno soggetto" {
            (Get-ExportedView $export 'deployment_prod').properties.subject | Should -BeNullOrEmpty
            (Get-ExportedView $export 'deployment_prod_rete').properties.subject | Should -BeNullOrEmpty
        }

        It "E nessuna vista di deployment ha un livello" {
            @($export.Workspace.views.deploymentViews | Where-Object { $_.properties.level }) | Should -BeNullOrEmpty
        }
    }

    Context "Scenario: la descrizione di ogni vista nasce dal suo contenuto con le frasi della lingua, fuori dal disegno, e nomina una volta ogni elemento collegato (ADR-2140, ADR-2148)" {
        It "Allora la descrizione di ogni vista di deployment nomina il soggetto, gli elementi che mostra e le relazioni con il loro testo" -ForEach @(
            @{ Key = 'deployment_prod'; Expected = "Applicazioni dell'ambiente prod: Api e Worker. Piani di calcolo e risorse che le ospitano: asp-contoso-prod. Chiamate fra le applicazioni: Worker → Api." }
            @{ Key = 'deployment_prod_app_contoso_shop_ai_api'; Expected = "Nell'ambiente prod, Api gira su asp-contoso-prod. Si rivolge a kv-contoso-prod. Riceve le richieste di Worker." }
            @{ Key = 'deployment_prod_app_contoso_shop_ai_worker'; Expected = "Nell'ambiente prod, Worker gira su asp-contoso-prod. Si rivolge a Api." }
            @{ Key = 'deployment_prod_rete'; Expected = "Reti virtuali dell'ambiente prod: vnet-contoso-prod e vnet-shared. Ingresso del traffico pubblico: afd-contoso-prod. Collegamenti fra le reti: afd-contoso-prod → vnet-contoso-prod (Inoltra le richieste all'origine) e vnet-contoso-prod → vnet-shared." }
            @{ Key = 'deployment_prod_rete_vnet_contoso_prod'; Expected = "Subnet della rete vnet-contoso-prod nell'ambiente prod: snet-engine, snet-gateway e snet-worker. Applicazioni integrate nella rete: Api e Worker. Riceve il traffico da afd-contoso-prod (Inoltra le richieste all'origine). Si collega a vnet-shared." }
            @{ Key = 'deployment_prod_rete_vnet_shared'; Expected = "Subnet della rete vnet-shared nell'ambiente prod: snet-endpoints. Risorse raggiunte in privato dalla rete: Api. Riceve il traffico da vnet-contoso-prod." }
        ) {
            (Get-ExportedView $export $Key).properties.description | Should -Be $Expected
        }

        It "E la descrizione sta nella proprieta' della vista: il disegno mostra solo il titolo" {
            $views = @($export.Workspace.views.deploymentViews)
            $views.Count | Should -Be 17
            @($views | Where-Object { $_.description }) | Should -BeNullOrEmpty
            @($views | Where-Object { -not $_.properties.description }) | Should -BeNullOrEmpty
        }

        It "E ogni descrizione nomina almeno un elemento che la vista mostra" {
            foreach ($view in $export.Workspace.views.deploymentViews) {
                $description = $view.properties.description
                @(Get-ShownNames $export $view.key | Where-Object { $description.Contains($_) }).Count | Should -BeGreaterThan 0 -Because "$($view.key): $description"
            }
        }

        It "E due viste diverse non hanno la stessa descrizione" {
            $descriptions = @($export.Workspace.views.deploymentViews | ForEach-Object { $_.properties.description })
            @($descriptions | Sort-Object -Unique).Count | Should -Be $descriptions.Count
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

Describe "Funzionalità: Relazioni, testi dei nodi e tabella dei gruppi di risorse da una regola sul modello" {
    BeforeAll {
        $generation = Invoke-DeploymentGeneration
        $export = Export-DeploymentWorkspace $generation
        $deployment = $generation.Generated['deployment/contoso.infrastructure.dsl'] -replace "`r`n", "`n"

        function Get-NodeText([string]$Dsl, [string]$Environment, [string]$Name) {
            $block = Get-Block $Dsl "^deploymentEnvironment `"$([regex]::Escape($Environment))`" \{"
            $match = [regex]::Match($block, "= (?:deploymentNode|infrastructureNode) `"$([regex]::Escape($Name))`" `"(?<text>[^`"]*)`"")
            if (-not $match.Success) { throw "nodo $Name assente da $Environment" }
            return $match.Groups['text'].Value
        }

        function Get-ExportedNodes($Nodes) {
            foreach ($node in @($Nodes | Where-Object { $_ })) {
                $node
                @($node.infrastructureNodes) | Where-Object { $_ }
                Get-ExportedNodes $node.children
            }
        }
    }

    Context "Scenario: in ogni vista una relazione si disegna fra gli elementi più vicini alle sue estremità che la vista mostra" {
        It "Allora nella vista della rete che mostra l'Application Gateway la freccia del Front Door arriva al gateway" {
            $generation.ExitCode | Should -Be 0 -Because $generation.Output
            $export.Error | Should -BeNullOrEmpty
            Get-ShownRelationships $export 'deployment_prod_rete_vnet_contoso_prod' | Should -Contain "afd-contoso-prod -> agw-contoso-prod: Inoltra le richieste all'origine"
        }

        It "E «Inoltra le richieste al backend» parte dal gateway e arriva alla rete chiusa che contiene il private endpoint" {
            Get-ShownRelationships $export 'deployment_prod_rete_vnet_contoso_prod' | Should -Contain 'agw-contoso-prod -> vnet-shared: Inoltra le richieste al backend'
        }

        It "E la vista non mostra le frecce fra reti che appartengono alla vista d'insieme" {
            $shown = Get-ShownRelationships $export 'deployment_prod_rete_vnet_contoso_prod'
            $shown | Should -Not -Contain "afd-contoso-prod -> vnet-contoso-prod: Inoltra le richieste all'origine"
            $shown | Should -Not -Contain 'vnet-contoso-prod -> vnet-shared: Inoltra le richieste al backend'
        }

        It "E nella vista d'insieme, con le reti chiuse, la freccia arriva alla rete" {
            Get-ShownRelationships $export 'deployment_prod_rete' | Should -Contain "afd-contoso-prod -> vnet-contoso-prod: Inoltra le richieste all'origine"
        }

        It "E nella vista della rete condivisa la freccia parte dalla rete chiusa e arriva al private endpoint che la vista mostra" {
            Get-ShownRelationships $export 'deployment_prod_rete_vnet_shared' | Should -Be @('vnet-contoso-prod -> Api · sites: Inoltra le richieste al backend', 'vnet-contoso-prod -> vnet-shared: Collega le due reti con un peering')
        }
    }

    Context "Scenario: la descrizione di un nodo di deployment nasce dal modello con una frase della lingua per livello" {
        It "Allora la descrizione dice che cosa il nodo ospita o collega" {
            Get-NodeText $deployment 'prod rete' 'vnet-contoso-prod' | Should -Be 'Contiene le subnet snet-engine, snet-gateway e snet-worker. Collegata in peering a vnet-shared.'
            Get-NodeText $deployment 'prod rete' 'snet-engine' | Should -Be 'Ospita Api. Si trova in vnet-contoso-prod.'
            Get-NodeText $deployment 'prod rete' 'agw-contoso-prod' | Should -Be 'Riceve le richieste da fde-contoso-prod e le inoltra a Api.'
            Get-NodeText $deployment 'prod rete' 'Api · sites' | Should -Be 'Accesso privato a Api.'
            Get-NodeText $deployment 'prod rete' 'afd-contoso-prod' | Should -Be 'Ingresso pubblico verso agw-contoso-prod.'
            Get-NodeText $deployment 'prod' 'asp-contoso-prod' | Should -Be 'Piano di calcolo di Api e Worker.'
        }

        It "E vale per ogni ambiente: cambiano solo i nomi delle risorse di ciascuno" {
            foreach ($environment in 'dev', 'sta') {
                foreach ($name in 'vnet-contoso', 'snet-engine') {
                    $own = $(if ($name -eq 'vnet-contoso') { "$name-$environment" } else { $name })
                    $expected = Get-NodeText $deployment 'prod rete' $(if ($name -eq 'vnet-contoso') { "$name-prod" } else { $name })
                    (Get-NodeText $deployment "$environment rete" $own).Replace("-$environment", '-prod') | Should -Be $expected
                }
            }
        }

        It "E non nomina il tipo della risorsa" {
            $nodes = @(Get-ExportedNodes $export.Workspace.model.deploymentNodes)
            $nodes.Count | Should -BeGreaterThan 0
            foreach ($node in $nodes) {
                $type = @("$($node.technology)" -split '[/ ]')[-1]
                "$($node.description)" | Should -Not -Match "(?i)\b$([regex]::Escape($type))\b" -Because "$($node.name): $($node.description)"
            }
        }

        It "E non va a capo" {
            foreach ($node in @(Get-ExportedNodes $export.Workspace.model.deploymentNodes)) {
                "$($node.description)" | Should -Not -Match '\n' -Because $node.name
                "$($node.description)" | Should -Not -BeNullOrEmpty -Because $node.name
            }
        }

        It "E in inglese le frasi sono quelle della lingua del documento" {
            $english = Invoke-DeploymentGeneration (New-TerraformRepository) 'EN'
            $english.ExitCode | Should -Be 0 -Because $english.Output
            Get-NodeText ($english.Generated['deployment/contoso.infrastructure.dsl'] -replace "`r`n", "`n") 'prod network' 'snet-engine' | Should -Be 'Hosts Api. Sits in vnet-contoso-prod.'
        }

        It "E un livello senza frasi nella lingua ferma l'esportazione nominando il livello" {
            $fragments = New-ContainerFragments
            $firewall = [ordered]@{ id = 'x_fw'; name = 'fw'; technology = 'T'; element = 'infrastructureNode'; kind = 'firewall'; children = @(); instances = @() }
            $vnet = [ordered]@{ id = 'x_vnet'; name = 'vnet'; technology = 'T'; element = 'deploymentNode'; kind = 'virtualNetwork'; children = @($firewall); instances = @() }
            $fragments['contoso.infrastructure.deployment.json'] = [ordered]@{ containers = @(); relationships = @(); deployment = @(
                    [ordered]@{ name = 'prod'; kind = 'allocation'; nodes = @() }
                    [ordered]@{ name = 'prod rete'; kind = 'network'; environment = 'prod'; nodes = @($vnet); relationships = @() }
                ) } | ConvertTo-Json -Depth 10
            $stopped = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' $fragments @{ GATE_MODE = 'enforce' }
            $stopped.ExitCode | Should -Not -Be 0
            $stopped.Output | Should -Match 'livello di nodo senza frasi nella lingua \(firewall\)'
            $stopped.Generated.Keys | Should -Not -Contain 'deployment/contoso.infrastructure.dsl'
        }
    }

    Context "Scenario: ogni nodo porta il nome Azure della risorsa per la tabella dei gruppi di risorse" {
        It "Allora il private endpoint, che nella vista si chiama con la parte che raggiunge, porta il suo nome Azure" {
            Get-Block (Get-Block $deployment '^deploymentEnvironment "prod rete" \{') 'infrastructureNode "Api · sites"' | Should -Match '"azureName" "pe-contoso-prod-api"'
        }

        It "E un'istanza porta il nome Azure della risorsa che la ospita" {
            Get-Block (Get-Block $deployment '^deploymentEnvironment "prod" \{') 'containerInstance contoso_shop_ai_api' | Should -Match '"azureName" "app-contoso-prod-api"'
        }

        It "E una regione non ha un nome Azure" {
            $region = Get-Block (Get-Block $deployment '^deploymentEnvironment "prod" \{') 'deploymentNode "westeurope"'
            [regex]::Match($region, '(?s)^.*?properties \{(?<own>.*?)\}').Groups['own'].Value | Should -Not -Match 'azureName'
        }
    }

    Context "Scenario: una risorsa o un modulo nuovi non chiedono codice nuovo" {
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
            $grownDeployment = $grown.Generated['deployment/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
        }

        It "Allora i nodi nuovi hanno la descrizione delle frasi del loro livello" {
            $grown.ExitCode | Should -Be 0 -Because $grown.Output
            Get-NodeText $grownDeployment 'prod rete' 'vnet-edge-prod' | Should -Be 'Contiene le subnet snet-jobs.'
            Get-NodeText $grownDeployment 'prod rete' 'snet-jobs' | Should -Be 'Ospita Worker. Si trova in vnet-edge-prod.'
            Get-NodeText $grownDeployment 'prod' 'asp-edge-prod' | Should -Be 'Piano di calcolo di Worker.'
        }

        It "E portano il nome Azure e il gruppo di risorse per la tabella" {
            Get-Block (Get-Block $grownDeployment '^deploymentEnvironment "prod" \{') 'deploymentNode "asp-edge-prod"' | Should -Match '"resourceGroup" "rg-edge-prod"\s+"module" "App"\s+"azureName" "asp-edge-prod"'
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
            $endpoint.element | Should -Be 'infrastructureNode'
            $endpoint.kind | Should -Be 'privateEndpoint'
            $endpoint.azureName | Should -Be 'pe-contoso-prod-api'
            $endpoint.exposedName | Should -Be 'Api'
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

        It "scrive su ogni nodo il nome Azure della risorsa, e su ogni istanza quello della risorsa che la ospita" {
            (Find-Node $result.Fragment 'prod' 'asp-contoso-prod').azureName | Should -Be 'asp-contoso-prod'
            (Find-Node $result.Fragment 'prod' 'westeurope').azureName | Should -BeNullOrEmpty
            $instance = (Find-Node $result.Fragment 'prod' 'asp-contoso-prod').instances | Where-Object container -EQ 'contoso_shop_ai_api'
            $instance.azureName | Should -Be 'app-contoso-prod-api'
        }

        It "scrive su ogni nodo il suo livello" {
            (Find-Node $result.Fragment 'prod' 'westeurope').kind | Should -Be 'region'
            (Find-Node $result.Fragment 'prod' 'asp-contoso-prod').kind | Should -Be 'hostingPlan'
            (Find-Node $result.Fragment 'prod rete' 'vnet-contoso-prod').kind | Should -Be 'virtualNetwork'
            (Find-Node $result.Fragment 'prod rete' 'snet-gateway').kind | Should -Be 'subnet'
            (Find-Node $result.Fragment 'prod rete' 'agw-contoso-prod').kind | Should -Be 'gateway'
            (Find-Node $result.Fragment 'prod rete' 'afd-contoso-prod').kind | Should -Be 'ingress'
            (Find-Node $result.Fragment 'prod rete' 'fde-contoso-prod').kind | Should -Be 'ingressEndpoint'
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

    It 'annida i nodi con tecnologia, tag dei generati e descrizione composta dal modello, senza il testo salvato' {
        $deployment | Should -Match 'deploymentNode "snet-engine" "Ospita Api\. Si trova in vnet-contoso-prod\." "Microsoft.Network/virtualNetworks/subnets" "Generato" \{'
        $deployment | Should -Match 'infrastructureNode "agw-contoso-prod" "Riceve le richieste da fde-contoso-prod e le inoltra a Api\." "Microsoft.Network/applicationGateways" "Generato"'
        $deployment | Should -Not -Match 'La subnet delle API'
    }

    It "distingue con i servizi esposti due private endpoint della stessa risorsa nella stessa subnet" {
        $deployment | Should -Match 'infrastructureNode "Api · sites"'
        $deployment | Should -Match 'infrastructureNode "Api · scm"'
    }

    It "scrive nell'ambiente della rete le relazioni con il tag della rete e, una volta sola, le derivate con il tag dei riassunti e un identificativo" {
        $network = Get-Block $deployment 'deploymentEnvironment "prod rete"'
        $network | Should -Match '(?m)^    \w+_vnet_contoso_prod -> \w+_vnet_shared "Collega le due reti con un peering" "" "Generato,Rete"$'
        $network | Should -Match '(?m)^    (?<id>\w+_afd_contoso_prod__to__\w+_vnet_contoso_prod) = \w+_afd_contoso_prod -> \w+_vnet_contoso_prod "Inoltra le richieste all''origine" "" "Generato,Rete,Riassunto"$'
        @([regex]::Matches($network, '_afd_contoso_prod -> \w+_applicationgateways_agw_contoso_prod "')).Count | Should -Be 1
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
        $region = [ordered]@{ id = 'x_region'; name = 'westeurope'; technology = 'Azure region'; element = 'deploymentNode'; kind = 'region'; children = @(); instances = @('contoso_shop_ai_api') }
        $fragments['contoso.infrastructure.deployment.json'] = [ordered]@{ containers = @(); relationships = @(); deployment = @([ordered]@{ name = 'prod'; nodes = @($region) }) } | ConvertTo-Json -Depth 10
        $alone = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' $fragments
        $alone.ExitCode | Should -Be 0 -Because $alone.Output
        $aloneViews = $alone.Generated['deployment-views/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
        Get-Block $aloneViews 'deployment \* "prod" "deployment_prod" ' | Should -Match 'include \*'
        Get-Block $aloneViews 'deployment \* "prod" "deployment_prod" ' | Should -Match '"resourceGroups" "prod"'
        $aloneViews | Should -Not -Match 'rete'
    }

    It "da' alle relazioni nominate nelle descrizioni delle viste il testo che il modello scrive per la relazione fra i container (ADR-2140)" {
        $described = [ordered]@{ units = [ordered]@{ contoso_shop_ai_worker = [ordered]@{ elements = @{}; relationships = [ordered]@{ 'contoso_shop_ai_worker -> contoso_shop_ai_api' = @{ description = 'Chiede le risposte'; technology = 'HTTPS' } } } } }
        $files = New-TerraformRepository
        $files['docs/architecture/c4/generated/model.text.json'] = $described | ConvertTo-Json -Depth 10
        $generation = Invoke-DeploymentGeneration $files
        $generation.ExitCode | Should -Be 0 -Because $generation.Output
        $generated = $generation.Generated['deployment-views/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
        Get-Block $generated 'deployment \* "prod" "deployment_prod_app_contoso_shop_ai_worker" ' | Should -Match ([regex]::Escape('"description" "Nell''ambiente prod, Worker gira su asp-contoso-prod. Si rivolge a Api (Chiede le risposte)."'))
        Get-Block $generated 'deployment \* "prod" "deployment_prod" ' | Should -Match ([regex]::Escape('Chiamate fra le applicazioni: Worker → Api (Chiede le risposte).'))
    }

    It "ferma la generazione se due viste diverse avrebbero la stessa descrizione (ADR-2140)" {
        $fragments = New-ContainerFragments
        $network = {
            param($Id)
            $endpoint = [ordered]@{ id = "${Id}_pe"; name = 'pe'; exposedName = 'archivio'; technology = 'T'; element = 'infrastructureNode'; kind = 'privateEndpoint'; children = @(); instances = @() }
            $subnet = [ordered]@{ id = "${Id}_snet"; name = 'snet'; technology = 'T'; element = 'deploymentNode'; kind = 'subnet'; children = @($endpoint); instances = @() }
            [ordered]@{ id = $Id; name = 'vnet'; resourceGroup = "rg-$Id"; technology = 'T'; element = 'deploymentNode'; kind = 'virtualNetwork'; children = @($subnet); instances = @() }
        }
        $fragments['contoso.infrastructure.deployment.json'] = [ordered]@{ containers = @(); relationships = @(); deployment = @(
                [ordered]@{ name = 'prod'; kind = 'allocation'; nodes = @() }
                [ordered]@{ name = 'prod rete'; kind = 'network'; environment = 'prod'; nodes = @((& $network 'x_a'), (& $network 'x_b')); relationships = @() }
            ) } | ConvertTo-Json -Depth 10
        $twins = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' $fragments
        $twins.ExitCode | Should -Not -Be 0
        $twins.Output | Should -Match ([regex]::Escape("descrizione uguale per piu' viste (deployment_prod_rete_rg_x_a_vnet, deployment_prod_rete_rg_x_b_vnet)"))
        $twins.Generated.Keys | Should -Not -Contain 'deployment-views/contoso.infrastructure.dsl'
    }

    It "ferma la generazione se la descrizione di una vista non nomina nessun elemento che la vista mostra (ADR-2140)" {
        $fragments = New-ContainerFragments
        $site = [ordered]@{ id = 'x_site'; name = 'site'; technology = 'T'; element = 'deploymentNode'; kind = 'application'; children = @(); instances = @('contoso_shop_ai_api') }
        $fragments['contoso.infrastructure.deployment.json'] = [ordered]@{ containers = @(); relationships = @(); deployment = @(
                [ordered]@{ name = 'prod'; kind = 'allocation'; nodes = @() }
                [ordered]@{ name = 'prod rete'; kind = 'network'; environment = 'prod'; nodes = @($site); relationships = @() }
            ) } | ConvertTo-Json -Depth 10
        $silent = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' $fragments
        $silent.ExitCode | Should -Not -Be 0
        $silent.Output | Should -Match ([regex]::Escape('descrizione di una vista che non nomina nessun elemento che la vista mostra (deployment_prod_rete)'))
    }

    It "da' i nomi della posizione a due nodi fratelli che restano uguali" {
        $fragments = New-ContainerFragments
        $twin = { param($Id) [ordered]@{ id = $Id; name = 'pe'; exposedName = 'archivio'; technology = 'T'; element = 'infrastructureNode'; kind = 'privateEndpoint'; children = @(); instances = @() } }
        $subnet = [ordered]@{ id = 'x_snet'; name = 'snet'; technology = 'T'; element = 'deploymentNode'; kind = 'subnet'; children = @((& $twin 'x_a'), (& $twin 'x_b')); instances = @() }
        $network = [ordered]@{ id = 'x_vnet'; name = 'vnet'; technology = 'T'; element = 'deploymentNode'; kind = 'virtualNetwork'; children = @($subnet); instances = @() }
        $fragments['contoso.infrastructure.deployment.json'] = [ordered]@{ containers = @(); relationships = @(); deployment = @(
                [ordered]@{ name = 'prod'; kind = 'allocation'; nodes = @() }
                [ordered]@{ name = 'prod rete'; kind = 'network'; environment = 'prod'; nodes = @($network); relationships = @() }
            ) } | ConvertTo-Json -Depth 10
        $twins = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' $fragments
        $twins.ExitCode | Should -Be 0 -Because $twins.Output
        $twins.Generated['deployment/contoso.infrastructure.dsl'] | Should -Match 'x_a = infrastructureNode "pe · 1"'
        $twins.Generated['deployment/contoso.infrastructure.dsl'] | Should -Match 'x_b = infrastructureNode "pe · 2"'
    }

    It "in inglese da' alle viste i titoli e le frasi delle descrizioni della lingua" {
        $english = Invoke-DeploymentGeneration (New-TerraformRepository) 'EN'
        $english.ExitCode | Should -Be 0 -Because $english.Output
        $englishViews = $english.Generated['deployment-views/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
        $englishViews | Should -Match 'title "Allocation · prod"'
        $englishViews | Should -Match '"deployment_prod_network" '
        $englishViews | Should -Match 'title "Network · prod · vnet-shared"'
        Get-Block $englishViews 'deployment \* "prod network" "deployment_prod_network_vnet_shared" ' | Should -Match ([regex]::Escape('"description" "Subnets of the network vnet-shared in the prod environment: snet-endpoints.'))
        $english.Generated['deployment/contoso.infrastructure.dsl'] | Should -Match 'deploymentEnvironment "prod network"'
    }
}
