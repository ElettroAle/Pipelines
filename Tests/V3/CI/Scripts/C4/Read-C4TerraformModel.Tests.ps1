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
        return [bool]@(Get-AllNodes (Get-DeploymentEnvironment $Fragment $Environment).nodes | Where-Object { @($_.instances) -contains $Container }).Count
    }

    function Get-ViewOpening([string]$Key) {
        return "^deployment \* `"prod`" `"$Key`"( `"[^`"]*`")? \{"
    }

    # Un gruppo con istanze in piu' rami e uno con un ramo solo; le relazioni fra i container le dichiara un
    # altro repository, quello delle applicazioni.
    function Invoke-BranchGeneration {
        $node = { param($Name, $Children = @(), $Instances = @(), $Kind = 'deploymentNode') [ordered]@{ id = "x_$($Name -replace '-', '_')"; name = $Name; technology = 'T'; kind = $Kind; text = 'x'; children = @($Children); instances = @($Instances) } }
        $app = & $node 'rg-app' @(
            & $node 'vnet' @(
                & $node 'snet-a' @(& $node 'plan-a' @() @('api'))
                & $node 'snet-b' @(& $node 'plan-b' @() @('worker'))
                & $node 'snet-pe' @(& $node 'pe-x' @() @() 'infrastructureNode')
                & $node 'snet-empty'
            )
        ) @('db', 'queue')
        $web = & $node 'rg-web' @(& $node 'vnet-web' @(& $node 'snet-web' @(& $node 'plan-web' @() @('web')))) @('cache')
        $ops = & $node 'rg-ops' @() @('logs')
        $relationships = [ordered]@{ 'api -> db' = 'Legge'; 'worker -> cache' = 'Scrive nella cache le sessioni che il worker elabora fuori dalla richiesta del portale.'; 'web -> api' = 'Chiama'; 'web -> worker' = 'Accoda'; 'web -> db' = 'Interroga'; 'web -> queue' = 'Pubblica'; 'worker -> logs' = 'Registra'; 'api -> logs' = 'Traccia'; 'queue -> logs' = 'Inoltra' }
        $fragments = New-ContainerFragments
        $fragments['contoso.shop.web.dotnet10.json'] = [ordered]@{ containers = @(); relationships = @($relationships.Keys | ForEach-Object { $ends = $_ -split ' -> '; [ordered]@{ source = $ends[0]; target = $ends[1] } }) } | ConvertTo-Json -Depth 10
        $fragments['contoso.infrastructure.deployment.json'] = [ordered]@{ containers = @(); relationships = @(); deployment = @([ordered]@{ name = 'prod'; nodes = @(& $node 'sub' @($app, $web, $ops)) }) } | ConvertTo-Json -Depth 20
        $described = [ordered]@{}
        $relationships.Keys | ForEach-Object { $described[$_] = [ordered]@{ description = $relationships[$_]; technology = '' } }
        $text = [ordered]@{ units = [ordered]@{ web = [ordered]@{ elements = @{}; relationships = $described } } } | ConvertTo-Json -Depth 10
        return Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n"; 'docs/architecture/c4/generated/model.text.json' = $text }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' $fragments
    }

    function Export-BranchWorkspace($Generation) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-branches-dsl-$(New-Guid)"
        try {
            Write-SourceFiles $dir ([ordered]@{
                    'generated/deployment/contoso.infrastructure.dsl'       = $Generation.Generated['deployment/contoso.infrastructure.dsl']
                    'generated/deployment-views/contoso.infrastructure.dsl' = $Generation.Generated['deployment-views/contoso.infrastructure.dsl']
                    'workspace.dsl'                                         = @'
workspace {
    model {
        sistema = softwareSystem "Contoso.Shop" {
            api = container "Api"
            worker = container "Worker"
            web = container "Web"
            db = container "Db"
            cache = container "Cache"
            queue = container "Queue"
            logs = container "Logs"
            api -> db "Legge"
            worker -> cache "Scrive"
            web -> api "Chiama"
            web -> worker "Accoda"
            web -> db "Interroga"
            web -> queue "Pubblica"
            worker -> logs "Registra"
            api -> logs "Traccia"
            queue -> logs "Inoltra"
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
            if (-not $export.Workspace) { return [pscustomobject]@{ Error = $export.Error; Workspace = $null; Names = @{}; Relationships = @{} } }
            $containers = @{}
            $export.Workspace.model.softwareSystems.containers | ForEach-Object { $containers["$($_.id)"] = $_.name }
            $names = @{}
            $relationships = @{}
            $nodes = @($export.Workspace.model.deploymentNodes)
            while ($nodes) {
                foreach ($each in $nodes) {
                    $names["$($each.id)"] = $each.name
                    @($each.relationships) | Where-Object { $_ } | ForEach-Object { $relationships["$($_.id)"] = $_ }
                    foreach ($instance in @($each.containerInstances | Where-Object { $_ })) {
                        $names["$($instance.id)"] = $containers["$($instance.containerId)"]
                        @($instance.relationships) | Where-Object { $_ } | ForEach-Object { $relationships["$($_.id)"] = $_ }
                    }
                }
                $nodes = @($nodes | ForEach-Object { @($_.children) } | Where-Object { $_ })
            }
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
    }
}

Describe 'Export-C4CodeModel.ps1 sugli ambienti di deployment' {
    BeforeAll {
        $previous = @{}
        $variables = @{ C4_DEPLOYMENT_ENVIRONMENTS = 'dev=dev-x;sta=sta-x;prod=prod-x'; C4_TERRAFORM_INSTANCES = 'Customers:customer_id=environments/{environment}/data/*'; GATE_MODE = 'enforce' }
        foreach ($name in $variables.Keys) { $previous[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $variables[$name]) }

        $text = [ordered]@{ units = [ordered]@{ contoso_infrastructure_app = [ordered]@{ elements = [ordered]@{ contoso_infrastructure_app_azurerm_subnet_engine = 'La subnet delle API' }; relationships = @{} } } }
        $files = New-TerraformRepository
        $files['docs/architecture/c4/generated/model.text.json'] = $text | ConvertTo-Json -Depth 10
        $result = Invoke-C4Steps $files 'Contoso.Infrastructure' @('C4/Read-C4TerraformModel.ps1', 'C4/Export-C4CodeModel.ps1') 'write' (New-ContainerFragments)
        $deployment = $result.Generated['deployment/contoso.infrastructure.dsl']
        $views = $result.Generated['deployment-views/contoso.infrastructure.dsl']
        $ProdGroupPrefix = 'contoso_infrastructure_prod_subscriptions_var_subscription_id_resourcegroups_'
    }

    AfterAll {
        foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
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

    It "scrive per ambiente la vista d'insieme con la sua chiave" {
        $views | Should -Match 'deployment \* "dev" "deployment_dev" \{'
        $views | Should -Match 'deployment \* "prod" "deployment_prod" \{'
    }

    It "la vista d'insieme mostra i gruppi di risorse senza il loro contenuto" {
        $overview = Get-Block $views 'deployment \* "prod" "deployment_prod" \{'
        $overview | Should -Match 'include \*'
        foreach ($group in 'rg_contoso_prod', 'rg_north_prod', 'rg_south_prod', 'rg_shared_shared') {
            $overview | Should -Match "exclude `"element\.parent==$($ProdGroupPrefix)$group`""
        }
    }

    It 'scrive una vista per ogni gruppo di risorse con contenuto, con il gruppo e tutto il suo contenuto' {
        foreach ($group in 'rg_contoso_prod', 'rg_north_prod', 'rg_shared_shared') {
            Get-Block $views "deployment \* `"prod`" `"deployment_prod_$group`" \{" | Should -Match "include $($ProdGroupPrefix)$group\s"
        }
    }

    It 'non scrive la vista di un gruppo di risorse senza istanze ne'' nodi dell''infrastruttura' {
        $views | Should -Not -Match 'deployment_prod_rg_south_prod'
    }

    It 'distingue con il nome del nodo che li contiene due gruppi con lo stesso nome nello stesso ambiente' {
        $group = { param($Root) [ordered]@{ id = "${Root}_rg_app"; name = 'rg-app'; technology = 'Group'; kind = 'deploymentNode'; text = 'x'; children = @([ordered]@{ id = "${Root}_rg_app_db"; name = 'db'; technology = 'Db'; kind = 'infrastructureNode'; text = 'x'; children = @(); instances = @() }); instances = @() } }
        $roots = @('sub-a', 'sub-b') | ForEach-Object { [ordered]@{ id = $_ -replace '-', '_'; name = $_; technology = 'Root'; kind = 'deploymentNode'; text = 'x'; children = @(& $group ($_ -replace '-', '_')); instances = @() } }
        $fragments = New-ContainerFragments
        $fragments['contoso.infrastructure.deployment.json'] = [ordered]@{ containers = @(); relationships = @(); deployment = @([ordered]@{ name = 'prod'; nodes = @($roots) }) } | ConvertTo-Json -Depth 10
        $twins = Invoke-C4Steps ([ordered]@{ 'source/README.md' = "# x`n" }) 'Contoso.Infrastructure' @('C4/Export-C4CodeModel.ps1') 'write' $fragments
        $twins.ExitCode | Should -Be 0 -Because $twins.Output
        $twinViews = $twins.Generated['deployment-views/contoso.infrastructure.dsl']
        Get-Block $twinViews 'deployment \* "prod" "deployment_prod_sub_a_rg_app" \{' | Should -Match 'include sub_a_rg_app\s'
        Get-Block $twinViews 'deployment \* "prod" "deployment_prod_sub_b_rg_app" \{' | Should -Match 'include sub_b_rg_app\s'
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
            @($export.Workspace.views.deploymentViews.key) | Should -Contain 'deployment_prod'
            @($export.Workspace.views.deploymentViews.key) | Should -Contain 'deployment_prod_rg_contoso_prod'
            $names = @{}
            $nodes = @($export.Workspace.model.deploymentNodes)
            while ($nodes) {
                $nodes | ForEach-Object { $names["$($_.id)"] = $_.name; @($_.infrastructureNodes) | Where-Object { $_ } | ForEach-Object { $names["$($_.id)"] = $_.name } }
                $nodes = @($nodes | ForEach-Object { @($_.children) } | Where-Object { $_ })
            }
            $shown = { param($Key) @(($export.Workspace.views.deploymentViews | Where-Object key -EQ $Key).elements | ForEach-Object { $names["$($_.id)"] } | Where-Object { $_ }) }
            $overview = & $shown 'deployment_prod'
            $overview | Should -Contain 'rg-contoso-prod'
            $overview | Should -Not -Contain 'snet-engine'
            $overview | Should -Not -Contain 'pe-contoso-prod-api'
            $group = & $shown 'deployment_prod_rg_contoso_prod'
            $group | Should -Contain 'vnet-contoso-prod'
            $group | Should -Not -Contain 'snet-engine'
            $group | Should -Not -Contain 'rg-shared-shared'
            & $shown 'deployment_prod_rg_contoso_prod_vnet_contoso_prod_snet_engine' | Should -Contain 'snet-engine'
        }
        finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    Context "un gruppo che ospita istanze in piu' rami" {
        BeforeAll {
            $branches = Invoke-BranchGeneration
            $branchViews = $branches.Generated['deployment-views/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
            $branchDeployment = $branches.Generated['deployment/contoso.infrastructure.dsl'] -replace "`r`n", "`n"
            $branchExport = Export-BranchWorkspace $branches
        }

        It "la vista del gruppo lo mostra con i nodi figli vuoti, senza le sue istanze in relazione con loro, e chiude i vicini, con le relazioni riassunte fra sottosezioni e vicini (ADR-2112)" {
            $branches.ExitCode | Should -Be 0 -Because $branches.Output
            Get-Block $branchViews (Get-ViewOpening 'deployment_prod_rg_app') | Should -Be (@(
                    'deployment * "prod" "deployment_prod_rg_app" "Comunica con: rg-web, rg-ops" {'
                    '    title "prod · rg-app"'
                    '    include x_rg_app'
                    '    include x_rg_web'
                    '    include x_rg_ops'
                    '    exclude x_rg_app__db'
                    '    exclude "element.parent==x_vnet"'
                    '    exclude "element.parent==x_rg_web"'
                    '    exclude "element.parent==x_rg_ops"'
                    '    exclude "relationship.tag==Riassunto"'
                    '    include "relationship.source==x_vnet && relationship.destination==x_rg_web"'
                    '    include "relationship.source==x_rg_web && relationship.destination==x_vnet"'
                    '    include "relationship.source==x_vnet && relationship.destination==x_rg_ops"'
                    '    autoLayout lr'
                    '}') -join "`n")
        }

        It "la vista di un nodo diviso non mostra le sue istanze in relazione con le sottosezioni e tiene le altre (ADR-2112)" {
            $shown = Get-ShownNames $branchExport 'deployment_prod_rg_app'
            $shown | Should -Not -Contain 'Db'
            $shown | Should -Contain 'Queue'
        }

        It "un figlio che ospita ancora istanze in piu' rami ha la sua vista con la chiave del padre, divisa allo stesso modo (ADR-2112)" {
            $vnet = Get-Block $branchViews (Get-ViewOpening 'deployment_prod_rg_app_vnet')
            $vnet | Should -Match 'include x_vnet\n'
            foreach ($subnet in 'snet_a', 'snet_b', 'snet_pe', 'snet_empty') { $vnet | Should -Match "exclude `"element\.parent==x_$subnet`"" }
            $vnet | Should -Match 'include x_rg_web\n'
            $vnet | Should -Match 'exclude "element\.parent==x_rg_web"'
        }

        It "la vista d'insieme di un nodo include solo le relazioni riassunte fra le sue sottosezioni e con i vicini (ADR-2112)" {
            $summaries = @([regex]::Matches((Get-Block $branchViews (Get-ViewOpening 'deployment_prod_rg_app_vnet')), 'include "relationship\.source==(\w+) && relationship\.destination==(\w+)"') | ForEach-Object { "$($_.Groups[1].Value) -> $($_.Groups[2].Value)" })
            $summaries | Should -Be @('x_rg_web -> x_snet_a', 'x_snet_a -> x_rg_ops', 'x_snet_b -> x_rg_web', 'x_rg_web -> x_snet_b', 'x_snet_b -> x_rg_ops')
        }

        It "la vista di un ramo mostra il nodo con tutto il contenuto, le istanze degli antenati in relazione con le sue e i vicini chiusi (ADR-2112)" {
            Get-Block $branchViews (Get-ViewOpening 'deployment_prod_rg_app_vnet_snet_a') | Should -Be (@(
                    'deployment * "prod" "deployment_prod_rg_app_vnet_snet_a" "Comunica con: rg-web, rg-ops" {'
                    '    title "prod · rg-app · vnet · snet-a"'
                    '    include x_snet_a'
                    '    include x_rg_app__db'
                    '    include x_rg_web'
                    '    include x_rg_ops'
                    '    exclude "element.parent==x_rg_web"'
                    '    exclude "element.parent==x_rg_ops"'
                    '    exclude "relationship.tag==Riassunto"'
                    '    include "relationship.source==x_rg_web && relationship.destination==x_snet_a"'
                    '    include "relationship.source==x_snet_a && relationship.destination==x_rg_ops"'
                    '    autoLayout lr'
                    '}') -join "`n")
        }

        It "la vista di un ramo senza istanze non ha vicini ne' riga dei vicini (ADR-2112, ADR-2113)" {
            Get-Block $branchViews (Get-ViewOpening 'deployment_prod_rg_app_vnet_snet_pe') | Should -Be (@(
                    'deployment * "prod" "deployment_prod_rg_app_vnet_snet_pe" {'
                    '    title "prod · rg-app · vnet · snet-pe"'
                    '    include x_snet_pe'
                    '    exclude "relationship.tag==Riassunto"'
                    '    autoLayout lr'
                    '}') -join "`n")
        }

        It "la riga dei vicini nomina solo i vicini, separati da virgole, su una riga, senza i testi delle relazioni (ADR-2113)" {
            Get-Block $branchViews (Get-ViewOpening 'deployment_prod_rg_app_vnet_snet_b') | Should -Match ([regex]::Escape('"deployment_prod_rg_app_vnet_snet_b" "Comunica con: rg-web, rg-ops" {'))
        }
        It "un figlio senza istanze ne' nodi dell'infrastruttura non ha vista" {
            $branchViews | Should -Not -Match 'deployment_prod_rg_app_vnet_snet_empty'
        }

        It "un gruppo che ospita istanze in un ramo solo resta una vista con tutto il contenuto, con i vicini chiusi (ADR-2112)" {
            Get-Block $branchViews (Get-ViewOpening 'deployment_prod_rg_web') | Should -Be (@(
                    'deployment * "prod" "deployment_prod_rg_web" "Comunica con: rg-app" {'
                    '    title "prod · rg-web"'
                    '    include x_rg_web'
                    '    include x_rg_app'
                    '    exclude "element.parent==x_rg_app"'
                    '    exclude "relationship.tag==Riassunto"'
                    '    include "relationship.source==x_rg_web && relationship.destination==x_rg_app"'
                    '    include "relationship.source==x_rg_app && relationship.destination==x_rg_web"'
                    '    autoLayout lr'
                    '}') -join "`n")
            $branchViews | Should -Not -Match 'deployment_prod_rg_web_'
        }

        It "la vista d'insieme dell'ambiente ha il titolo della lingua e le relazioni riassunte fra i gruppi (ADR-2112, ADR-2113)" {
            Get-Block $branchViews (Get-ViewOpening 'deployment_prod') | Should -Be (@(
                    'deployment * "prod" "deployment_prod" {'
                    '    title "Parti dell''ambiente prod"'
                    '    include *'
                    '    exclude "element.parent==x_rg_app"'
                    '    exclude "element.parent==x_rg_web"'
                    '    exclude "element.parent==x_rg_ops"'
                    '    exclude "relationship.tag==Riassunto"'
                    '    include "relationship.source==x_rg_app && relationship.destination==x_rg_web"'
                    '    include "relationship.source==x_rg_app && relationship.destination==x_rg_ops"'
                    '    include "relationship.source==x_rg_web && relationship.destination==x_rg_app"'
                    '    autoLayout lr'
                    '}') -join "`n")
        }

        It "scrive una volta sola nell'ambiente le relazioni riassunte che le viste usano, con il tag dei riassunti e i testi in ordine, senza il punto finale, fino a due con il numero degli altri solo se ne restano almeno due (ADR-2112)" {
            $summaries = @($branchDeployment -split "`n" | Where-Object { $_ -match '"Riassunto"$' } | ForEach-Object Trim)
            $summaries | Should -Be @(
                'x_rg_app -> x_rg_web "Scrive nella cache le sessioni che il worker elabora fuori dalla richiesta del portale" "" "Riassunto"'
                'x_rg_app -> x_rg_ops "Inoltra, Registra, Traccia" "" "Riassunto"'
                'x_rg_web -> x_rg_app "Accoda, Chiama e altre 2" "" "Riassunto"'
                'x_vnet -> x_rg_web "Scrive nella cache le sessioni che il worker elabora fuori dalla richiesta del portale" "" "Riassunto"'
                'x_rg_web -> x_vnet "Accoda, Chiama" "" "Riassunto"'
                'x_vnet -> x_rg_ops "Registra, Traccia" "" "Riassunto"'
                'x_rg_web -> x_snet_a "Chiama" "" "Riassunto"'
                'x_snet_a -> x_rg_ops "Traccia" "" "Riassunto"'
                'x_snet_b -> x_rg_web "Scrive nella cache le sessioni che il worker elabora fuori dalla richiesta del portale" "" "Riassunto"'
                'x_rg_web -> x_snet_b "Accoda" "" "Riassunto"'
                'x_snet_b -> x_rg_ops "Registra" "" "Riassunto"')
            Get-Block $branchDeployment 'deploymentEnvironment "prod" \{' | Should -Match 'x_snet_b -> x_rg_ops "Registra" "" "Riassunto"\n\}$'
        }

        It "da' a ogni istanza l'identificativo del suo nodo e del suo container" {
            $branchDeployment | Should -Match 'x_plan_a__api = containerInstance api'
            $branchDeployment | Should -Match 'x_rg_app__db = containerInstance db'
        }

        It "produce viste Structurizr valide che il marcatore per prefisso mostra dopo quella del padre" {
            $branchExport.Error | Should -BeNullOrEmpty
            $branch = Get-ShownNames $branchExport 'deployment_prod_rg_app_vnet_snet_a'
            $branch | Should -Contain 'Api'
            $branch | Should -Contain 'Db'
            $branch | Should -Contain 'rg-web'
            $branch | Should -Not -Contain 'Web'
            $branch | Should -Not -Contain 'Worker'
            $overview = Get-ShownNames $branchExport 'deployment_prod_rg_app_vnet'
            $overview | Should -Contain 'snet-a'
            $overview | Should -Not -Contain 'Api'
            @(Resolve-ViewMarker 'deployment_prod*' $branchExport.Workspace) | Should -Be @('deployment_prod', 'deployment_prod_rg_app', 'deployment_prod_rg_app_vnet',
                'deployment_prod_rg_app_vnet_snet_a', 'deployment_prod_rg_app_vnet_snet_b', 'deployment_prod_rg_app_vnet_snet_pe', 'deployment_prod_rg_ops', 'deployment_prod_rg_web')
        }

        It "una vista mostra solo le relazioni riassunte che include, insieme a quelle fra le istanze che mostra (ADR-2112)" {
            Get-ShownRelationships $branchExport 'deployment_prod_rg_app_vnet_snet_a' | Should -Be @('Api -> Db: Legge', 'rg-web -> snet-a: Chiama', 'snet-a -> rg-ops: Traccia')
            Get-ShownRelationships $branchExport 'deployment_prod_rg_app' | Should -Be @('rg-web -> vnet: Accoda, Chiama', 'vnet -> rg-ops: Registra, Traccia', 'vnet -> rg-web: Scrive nella cache le sessioni che il worker elabora fuori dalla richiesta del portale')
        }
    }
}

Describe "Funzionalità: Viste C4 divise che si leggono insieme" {
    BeforeAll {
        $generation = Invoke-BranchGeneration
        $export = Export-BranchWorkspace $generation
    }

    Context "Scenario: la vista d'insieme di un livello mostra solo le sue sottosezioni, con il loro nome, e le relazioni fra loro riassunte, con ciò che passa" {
        It "Allora la vista d'insieme dell'ambiente mostra i gruppi con il loro nome, senza il loro contenuto" {
            $generation.ExitCode | Should -Be 0 -Because $generation.Output
            $export.Error | Should -BeNullOrEmpty
            $shown = Get-ShownNames $export 'deployment_prod'
            $shown | Should -Contain 'rg-app'
            $shown | Should -Contain 'rg-web'
            $shown | Should -Contain 'rg-ops'
            $shown | Should -Not -Contain 'vnet'
            $shown | Should -Not -Contain 'Db'
        }

        It "E mostra le relazioni fra i gruppi riassunte, con ciò che passa" {
            Get-ShownRelationships $export 'deployment_prod' | Should -Be @('rg-app -> rg-ops: Inoltra, Registra, Traccia', 'rg-app -> rg-web: Scrive nella cache le sessioni che il worker elabora fuori dalla richiesta del portale', 'rg-web -> rg-app: Accoda, Chiama e altre 2')
        }

        It "E la vista d'insieme di un nodo diviso mostra le sue sottosezioni chiuse, con le relazioni riassunte" {
            $shown = Get-ShownNames $export 'deployment_prod_rg_app_vnet'
            foreach ($subnet in 'snet-a', 'snet-b', 'snet-pe') { $shown | Should -Contain $subnet }
            $shown | Should -Not -Contain 'Api'
            Get-ShownRelationships $export 'deployment_prod_rg_app_vnet' | Should -Be @('rg-web -> snet-a: Chiama', 'rg-web -> snet-b: Accoda', 'snet-a -> rg-ops: Traccia', 'snet-b -> rg-ops: Registra', 'snet-b -> rg-web: Scrive nella cache le sessioni che il worker elabora fuori dalla richiesta del portale')
        }

        It "E la vista d'insieme di un nodo diviso non mostra le istanze del nodo che hanno relazioni con le sue sottosezioni" {
            $shown = Get-ShownNames $export 'deployment_prod_rg_app'
            $shown | Should -Not -Contain 'Db'
            $shown | Should -Contain 'Queue'
        }
    }

    Context "Scenario: la vista di una sottosezione mostra il suo contenuto e, come riquadri chiusi con il loro nome, le altre sottosezioni con cui comunica" {
        It "Allora la vista della subnet mostra il suo contenuto" {
            Get-ShownNames $export 'deployment_prod_rg_app_vnet_snet_a' | Should -Contain 'Api'
        }

        It "E mostra chiuso, con il suo nome, il gruppo con cui comunica" {
            $shown = Get-ShownNames $export 'deployment_prod_rg_app_vnet_snet_a'
            $shown | Should -Contain 'rg-web'
            $shown | Should -Not -Contain 'Web'
            $shown | Should -Not -Contain 'vnet-web'
        }

        It "E non mostra le sottosezioni con cui non comunica" {
            $shown = Get-ShownNames $export 'deployment_prod_rg_app_vnet_snet_a'
            $shown | Should -Not -Contain 'snet-b'
            $shown | Should -Not -Contain 'Worker'
        }
    }

    Context "Scenario: ogni vista ha un titolo suo, fatto dai nomi delle parti che mostra, e una riga che nomina le parti con cui comunica" {
        It "Allora ogni vista di deployment ha un titolo suo" {
            $titles = @($export.Workspace.views.deploymentViews | ForEach-Object title)
            @($titles | Where-Object { $_ }).Count | Should -Be @($export.Workspace.views.deploymentViews).Count
            @($titles | Select-Object -Unique).Count | Should -Be $titles.Count
        }

        It "E il titolo e' fatto dai nomi delle parti che mostra" {
            Get-ExportedView $export 'deployment_prod_rg_app_vnet_snet_a' | ForEach-Object title | Should -Be 'prod · rg-app · vnet · snet-a'
        }

        It "E la riga nomina le parti con cui comunica, separate da virgole" {
            Get-ExportedView $export 'deployment_prod_rg_app_vnet_snet_a' | ForEach-Object description | Should -Be 'Comunica con: rg-web, rg-ops'
        }
    }
}
