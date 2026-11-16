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

    function Set-FileText([System.Collections.IDictionary]$Files, [string]$Path, [string]$Old, [string]$New) {
        if (-not $Files[$Path].Contains($Old)) { throw "Testo assente da ${Path}: $Old" }
        $Files[$Path] = $Files[$Path].Replace($Old, $New)
    }

    function Test-HasInstance($Fragment, [string]$Environment, [string]$Container) {
        return [bool]@(Get-AllNodes (Get-DeploymentEnvironment $Fragment $Environment).nodes | Where-Object { @($_.instances) -contains $Container }).Count
    }
}

Describe "Funzionalità: Viste di deployment generate dall'infrastruttura" {

    Context "Scenario: viste di deployment generate" {
        BeforeAll { $result = Invoke-TerraformReader (New-TerraformRepository) }

        It "Allora il modello contiene gli ambienti di deployment ""dev"", ""sta"" e ""prod""" {
            $result.ExitCode | Should -Be 0 -Because $result.Output
            @($result.Fragment.deployment.name) | Should -Be @('dev', 'sta', 'prod')
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
        BeforeAll {
            $result = Invoke-TerraformReader (New-TerraformRepository)
            $path = Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod').nodes { param($node) @($node.instances) -contains 'contoso_shop_ai_api' }
        }

        It "Allora l'istanza dell'applicazione sta nel nodo del piano di hosting" {
            $path[-1] | Should -Be 'asp-contoso-prod'
        }

        It "E il nodo del piano di hosting sta nel nodo della subnet ""snet-engine""" {
            $path[-2] | Should -Be 'snet-engine'
        }

        It "E il nodo della subnet sta nel nodo della rete virtuale, del gruppo di risorse e della sottoscrizione" {
            $path[0..2] | Should -Be @('var.subscription_id', 'rg-contoso-prod', 'vnet-contoso-prod')
        }
    }

    Context "Scenario: risorsa dichiarata in un solo ambiente" {
        BeforeAll { $result = Invoke-TerraformReader (New-TerraformRepository) }

        It "Allora la vista di deployment ""dev"" contiene lo Storage Account" {
            Find-Node $result.Fragment 'dev' 'stcontosoarchivedev' | Should -Not -BeNullOrEmpty
        }

        It "E le viste di deployment ""sta"" e ""prod"" non lo contengono" {
            Find-Node $result.Fragment 'sta' 'stcontosoarchivesta' | Should -BeNullOrEmpty
            Find-Node $result.Fragment 'prod' 'stcontosoarchiveprod' | Should -BeNullOrEmpty
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

Describe 'Read-C4TerraformModel.ps1' {
    Context 'sulla dichiarazione completa' {
        BeforeAll {
            $result = Invoke-TerraformReader (New-TerraformRepository)
            $prod = (Get-DeploymentEnvironment $result.Fragment 'prod').nodes
        }

        It 'mette un servizio del modello nel suo gruppo di risorse, per nome nel codice' {
            (Get-NodePath $prod { param($node) @($node.instances) -contains 'contoso_infrastructure_kv_contoso_prod' }) | Should -Be @('var.subscription_id', 'rg-contoso-prod')
        }

        It "da' un'istanza del servizio anche negli ambienti dove la stessa risorsa ha un altro nome" {
            Test-HasInstance $result.Fragment 'dev' 'contoso_infrastructure_kv_contoso_prod' | Should -BeTrue
        }

        It 'mette un private endpoint nella subnet di un altro modulo letta dal remote state' {
            (Get-NodePath $prod { param($node) $node.name -eq 'pe-contoso-prod-api' }) | Should -Be @('var.subscription_id', 'rg-shared-shared', 'vnet-shared', 'snet-endpoints', 'pe-contoso-prod-api')
            (Find-Node $result.Fragment 'prod' 'pe-contoso-prod-api').kind | Should -Be 'infrastructureNode'
        }

        It "porta la directory condivisa negli ambienti che ne leggono lo stato" {
            foreach ($environment in 'dev', 'sta', 'prod') { Find-Node $result.Fragment $environment 'rg-shared-shared' | Should -Not -BeNullOrEmpty }
        }

        It 'istanzia il modulo radice per ogni directory del glob' {
            Find-Node $result.Fragment 'prod' 'rg-north-prod' | Should -Not -BeNullOrEmpty
            Find-Node $result.Fragment 'prod' 'acs-north-prod' | Should -Not -BeNullOrEmpty
            Find-Node $result.Fragment 'prod' 'rg-south-prod' | Should -Not -BeNullOrEmpty
            Find-Node $result.Fragment 'prod' 'acs-south-prod' | Should -BeNullOrEmpty
        }

        It 'mette il piano nella subnet di ogni sua applicazione' {
            (Get-NodePath $prod { param($node) @($node.instances) -contains 'contoso_shop_ai_worker' }) | Should -Be @('var.subscription_id', 'rg-contoso-prod', 'vnet-contoso-prod', 'snet-worker', 'asp-contoso-prod')
        }

        It "da' lo stesso testo a un nodo in ogni ambiente e in ogni subnet" {
            @(Get-AllNodes $prod | Where-Object name -EQ 'asp-contoso-prod' | ForEach-Object text | Sort-Object -Unique) | Should -Be @('contoso_infrastructure_app_azurerm_service_plan_backend')
            (Find-Node $result.Fragment 'dev' 'snet-engine').text | Should -Be (Find-Node $result.Fragment 'prod' 'snet-engine').text
        }

        It "dichiara i tipi Azure come tecnologia e il modulo radice di ogni nodo" {
            (Find-Node $result.Fragment 'prod' 'snet-engine').technology | Should -Be 'Microsoft.Network/virtualNetworks/subnets'
            (Find-Node $result.Fragment 'prod' 'rg-contoso-prod').module | Should -Be 'App'
            (Find-Node $result.Fragment 'prod' 'var.subscription_id').technology | Should -Be 'Microsoft.Resources/subscriptions'
        }
    }

    Context 'piani e applicazioni' {
        It 'mette nel gruppo di risorse il piano senza applicazioni integrate' {
            $files = New-TerraformRepository
            Set-FileText $files 'source/App/main.tf' 'resource "azurerm_app_service_virtual_network_swift_connection" "api"' 'resource "azurerm_app_service_virtual_network_swift_connection" "api_unused"'
            Set-FileText $files 'source/App/main.tf' '  subnet_id      = azurerm_subnet.engine.id' '  subnet_id      = azurerm_subnet.engine.id`n  count = 0'.Replace('`n', "`n")
            $result = Invoke-TerraformReader $files
            $result.ExitCode | Should -Be 0 -Because $result.Output
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod').nodes { param($node) @($node.instances) -contains 'contoso_shop_ai_api' }) | Should -Be @('var.subscription_id', 'rg-contoso-prod', 'asp-contoso-prod')
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
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod').nodes { param($node) $node.name -eq 'func-backup-prod' }) | Should -Be @('var.subscription_id', 'rg-contoso-prod', 'vnet-contoso-prod', 'snet-worker', 'asp-contoso-prod', 'func-backup-prod')
            Find-Node $result.Fragment 'prod' 'ai-backup' | Should -BeNullOrEmpty
        }

        It "mette nel gruppo di risorse un'applicazione senza piano e un nodo di un gruppo che il codice non dichiara" {
            $files = New-TerraformRepository
            $files['source/App/site.tf'] = @'
resource "azurerm_static_web_app" "site" {
  name                = "stapp-${var.environment}"
  resource_group_name = "rg-existing"
}
'@
            $result = Invoke-TerraformReader $files
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod').nodes { param($node) $node.name -eq 'stapp-prod' }) | Should -Be @('var.subscription_id', 'rg-existing', 'stapp-prod')
            (Find-Node $result.Fragment 'prod' 'rg-existing').text | Should -Be 'contoso_infrastructure_resourcegroup_rg_existing'
        }

        It "applica i file override dell'ambiente" {
            $files = New-TerraformRepository
            $files['source/App/environments/prod-x/network_override.tf'] = "resource `"azurerm_subnet`" `"engine`" {`n  name = `"snet-engine-static`"`n}`n"
            $result = Invoke-TerraformReader $files
            Find-Node $result.Fragment 'prod' 'snet-engine-static' | Should -Not -BeNullOrEmpty
            Find-Node $result.Fragment 'dev' 'snet-engine' | Should -Not -BeNullOrEmpty
        }

        It "usa la sottoscrizione del provider con alias passato al modulo" {
            $files = New-TerraformRepository
            Set-FileText $files 'source/App/main.tf' 'variable "environment" {' "provider `"azurerm`" {`n  alias           = `"other`"`n  features {}`n  subscription_id = `"0000-1111`"`n}`n`nvariable `"environment`" {"
            Set-FileText $files 'source/App/main.tf' "module `"api`" {`n  source              = `"../../../Modules/WebApp`"" "module `"api`" {`n  source              = `"../../../Modules/WebApp`"`n  providers = {`n    azurerm = azurerm.other`n  }"
            Set-FileText $files 'source/App/main.tf' "resource `"azurerm_key_vault`" `"secrets`" {" "resource `"azurerm_key_vault`" `"secrets`" {`n  provider            = azurerm.other"
            $result = Invoke-TerraformReader $files
            $result.ExitCode | Should -Be 0 -Because $result.Output
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod').nodes { param($node) @($node.instances) -contains 'contoso_infrastructure_kv_contoso_prod' })[0] | Should -Be '0000-1111'
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

        It "ospita un container sulle risorse che hosts nomina con il nome Azure" {
            $fragments = New-ContainerFragments
            $grouped = [ordered]@{ containers = @([ordered]@{ id = 'contoso_infrastructure_mail'; name = 'Invio email dei clienti'; codeName = 'Invio email dei clienti'; tags = @(); components = @() }); relationships = @(); hosts = @([ordered]@{ container = 'contoso_infrastructure_mail'; name = 'ACS-NORTH-PROD' }) }
            $fragments['contoso.infrastructure.customers.json'] = $grouped | ConvertTo-Json -Depth 10
            $result = Invoke-TerraformReader (New-TerraformRepository) $fragments
            $result.ExitCode | Should -Be 0 -Because $result.Output
            (Get-NodePath (Get-DeploymentEnvironment $result.Fragment 'prod').nodes { param($node) @($node.instances) -contains 'contoso_infrastructure_mail' }) | Should -Be @('var.subscription_id', 'rg-north-prod')
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
    }
}

Describe 'Export-C4CodeModel.ps1 sugli ambienti di deployment' {
    BeforeAll {
        . "$PSScriptRoot/../../../../../V3/CI/Scripts/C4/Structurizr.ps1"
        $previous = @{}
        $variables = @{ C4_DEPLOYMENT_ENVIRONMENTS = 'dev=dev-x;sta=sta-x;prod=prod-x'; C4_TERRAFORM_INSTANCES = 'Customers:customer_id=environments/{environment}/data/*'; GATE_MODE = 'enforce' }
        foreach ($name in $variables.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $variables[$name]) }
        $previousToolsDirectory = $env:AGENT_TOOLSDIRECTORY
        $env:AGENT_TOOLSDIRECTORY = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-terraform-$(New-Guid)"

        $text = [ordered]@{ units = [ordered]@{ contoso_infrastructure_app = [ordered]@{ elements = [ordered]@{ contoso_infrastructure_app_azurerm_subnet_engine = 'La subnet delle API' }; relationships = @{} } } }
        $files = New-TerraformRepository
        $files['docs/architecture/c4/generated/model.text.json'] = $text | ConvertTo-Json -Depth 10
        $result = Invoke-C4Steps $files 'Contoso.Infrastructure' @('C4/Read-C4TerraformModel.ps1', 'C4/Export-C4CodeModel.ps1') 'write' (New-ContainerFragments)
        $deployment = $result.Generated['deployment/contoso.infrastructure.dsl']
        $views = $result.Generated['deployment-views/contoso.infrastructure.dsl']
    }

    AfterAll {
        foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
        Remove-Item -Recurse -Force $env:AGENT_TOOLSDIRECTORY -ErrorAction SilentlyContinue
        $env:AGENT_TOOLSDIRECTORY = $previousToolsDirectory
    }

    It 'scrive un ambiente di deployment per ambiente del modello, fuori dalla parte dei container' {
        $result.ExitCode | Should -Be 0 -Because $result.Output
        @([regex]::Matches($deployment, '(?m)^deploymentEnvironment "(\w+)" \{').Groups | Where-Object Name -EQ 1 | ForEach-Object Value) | Should -Be @('dev', 'sta', 'prod')
        $result.Generated['containers/contoso.infrastructure.dsl'] | Should -Not -Match 'deploymentEnvironment'
    }

    It 'annida i nodi con tecnologia, tag dei generati e descrizione dal testo del modello' {
        Get-Block $deployment 'deploymentNode "snet-engine"' | Should -Match '"snet-engine" "La subnet delle API" "Microsoft.Network/virtualNetworks/subnets" "Generato" \{'
        Get-Block $deployment 'deploymentNode "snet-engine"' | Should -Match 'deploymentNode "asp-contoso-dev"'
        $deployment | Should -Match 'infrastructureNode "pe-contoso-prod-api" "" "Microsoft.Network/privateEndpoints" "Generato"'
    }

    It "mette le istanze dei container nei loro nodi" {
        Get-Block $deployment 'deploymentNode "snet-engine"' | Should -Match 'containerInstance contoso_shop_ai_api'
        $deployment | Should -Match 'containerInstance contoso_infrastructure_kv_contoso_prod'
    }

    It 'scrive una vista di deployment per ambiente con la sua chiave' {
        $views | Should -Match 'deployment \* "dev" "deployment_dev" \{'
        $views | Should -Match 'deployment \* "prod" "deployment_prod" \{'
    }

    It 'non scrive ambienti per un repository senza dichiarazione di deployment' {
        $result.Generated.Keys | Should -Contain 'containers/contoso.infrastructure.dsl'
        $other = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' (New-ContainerFragments)
        $other.Generated.Keys | Should -Not -Contain 'deployment/contoso.infrastructure.dsl'
    }

    It "produce un modello Structurizr valido con i container a cui le istanze rimandano" {
        $dir = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-terraform-dsl-$(New-Guid)"
        try {
            Write-SourceFiles $dir ([ordered]@{
                    'generated/containers/contoso.infrastructure.dsl'      = $result.Generated['containers/contoso.infrastructure.dsl']
                    'generated/deployment/contoso.infrastructure.dsl'      = $deployment
                    'generated/deployment-views/contoso.infrastructure.dsl' = $views
                    'workspace.dsl'                                        = @'
workspace {
    model {
        sistema = softwareSystem "Contoso.Shop" {
            contoso_shop_ai_api = container "Api"
            contoso_shop_ai_worker = container "Worker"
            !include generated/containers
        }
        !include generated/deployment
    }
    views {
        !include generated/deployment-views
    }
}
'@
                })
            $export = Export-StructurizrWorkspace (Join-Path $dir 'workspace.dsl')
            $export.Error | Should -BeNullOrEmpty
            @($export.Workspace.views.deploymentViews.key) | Should -Be @('deployment_dev', 'deployment_sta', 'deployment_prod')
        }
        finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
}
