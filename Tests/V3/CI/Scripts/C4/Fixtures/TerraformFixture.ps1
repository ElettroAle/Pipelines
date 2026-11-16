# SPDX-License-Identifier: Apache-2.0

# Repository Terraform finto per il lettore Terraform del modello C4: un modulo radice condiviso (shared)
# con la rete delle risorse comuni, un modulo radice App in dev, sta e prod con il suo modulo WebApp, un
# modulo radice Customers istanziato per cliente. Le chiavi sono i percorsi sotto source/.

. "$PSScriptRoot/C4CodeFixture.ps1"

function New-Backend([string]$Workspace) {
    return "terraform {`n  cloud {`n    organization = `"contoso`"`n    workspaces {`n      name = `"$Workspace`"`n    }`n  }`n}`n"
}

function New-TerraformRepository {
    $files = [ordered]@{}
    $files['source/Shared/main.tf'] = @'
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "environment" {
  type = string
}

resource "azurerm_resource_group" "shared" {
  name     = "rg-shared-${var.environment}"
  location = "westeurope"
}

resource "azurerm_virtual_network" "shared" {
  name                = "vnet-shared"
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_resource_group.shared.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "endpoints" {
  name                 = "snet-endpoints"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.shared.name
  address_prefixes     = ["10.0.1.0/24"]
}

output "endpoints_subnet_id" {
  value = azurerm_subnet.endpoints.id
}
'@
    $files['source/Shared/environments/shared/backend.tf'] = New-Backend 'contoso-shared'
    $files['source/Shared/environments/shared/values.tfvars'] = "environment = `"shared`"`n"

    $files['source/App/main.tf'] = @'
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "environment" {
  type = string
}

variable "shared_workspace" {
  type    = string
  default = "contoso-shared"
}

variable "settings" {
  type = object({
    worker  = optional(bool, true)
    archive = optional(bool)
  })
  default = {}
}

data "terraform_remote_state" "shared" {
  backend = "remote"
  config = {
    organization = "contoso"
    workspaces = {
      name = var.shared_workspace
    }
  }
}

locals {
  suffix = "contoso-${var.environment}"
}

resource "azurerm_resource_group" "app" {
  name     = "rg-${local.suffix}"
  location = "westeurope"
}

resource "azurerm_virtual_network" "app" {
  name                = "vnet-${local.suffix}"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.1.0.0/16"]
}

resource "azurerm_subnet" "engine" {
  name                 = "snet-engine"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.1.1.0/24"]
}

resource "azurerm_subnet" "worker" {
  name                 = "snet-worker"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = ["10.1.2.0/24"]
}

resource "azurerm_service_plan" "backend" {
  name                = "asp-${local.suffix}"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  os_type             = "Linux"
  sku_name            = "P0v3"
}

module "api" {
  source              = "../../../Modules/WebApp"
  name                = "app-${local.suffix}-api"
  resource_group_name = azurerm_resource_group.app.name
  service_plan_id     = azurerm_service_plan.backend.id
}

resource "azurerm_app_service_virtual_network_swift_connection" "api" {
  app_service_id = module.api.id
  subnet_id      = azurerm_subnet.engine.id
}

module "worker" {
  source              = "../../../Modules/WebApp"
  count               = var.settings.worker ? 1 : 0
  name                = "app-${local.suffix}-worker"
  resource_group_name = azurerm_resource_group.app.name
  service_plan_id     = azurerm_service_plan.backend.id
  subnet_id           = azurerm_subnet.worker.id
}

resource "azurerm_storage_account" "archive" {
  count               = coalesce(var.settings.archive, false) ? 1 : 0
  name                = "stcontosoarchive${var.environment}"
  resource_group_name = azurerm_resource_group.app.name
}

resource "azurerm_key_vault" "secrets" {
  name                = "kv-${local.suffix}"
  resource_group_name = azurerm_resource_group.app.name
}

resource "azurerm_private_endpoint" "api" {
  name                = "pe-${local.suffix}-api"
  resource_group_name = azurerm_resource_group.app.name
  subnet_id           = data.terraform_remote_state.shared.outputs.endpoints_subnet_id
}

resource "azurerm_role_assignment" "secrets" {
  scope        = azurerm_key_vault.secrets.id
  principal_id = module.api.principal_id
}
'@
    $files['source/Modules/WebApp/main.tf'] = @'
variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "service_plan_id" {
  type = string
}

variable "subnet_id" {
  type    = string
  default = null
}

resource "azurerm_linux_web_app" "this" {
  name                      = var.name
  resource_group_name       = var.resource_group_name
  service_plan_id           = var.service_plan_id
  virtual_network_subnet_id = var.subnet_id
}

output "id" {
  value = azurerm_linux_web_app.this.id
}

output "principal_id" {
  value = azurerm_linux_web_app.this.identity[0].principal_id
}
'@
    foreach ($environment in 'dev', 'sta', 'prod') {
        $files["source/App/environments/$environment-x/backend.tf"] = New-Backend "contoso-app-$environment"
        $files["source/App/environments/$environment-x/values.tfvars"] = "environment = `"$environment`"`n"
    }
    $files['source/App/environments/dev-x/values.tfvars'] = "environment = `"dev`"`nsettings = {`n  archive = true`n}`n"
    $files['source/App/environments/sta-x/values.tfvars'] = "environment = `"sta`"`nsettings = {`n  worker = false`n}`n"

    $files['source/Customers/main.tf'] = @'
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "environment" {
  type = string
}

variable "customer_id" {
  type = string
}

locals {
  customer = jsondecode(file("${path.module}/../data/${var.customer_id}/customer.json"))
}

resource "azurerm_resource_group" "customer" {
  name     = "rg-${var.customer_id}-${var.environment}"
  location = "westeurope"
}

resource "azurerm_communication_service" "mail" {
  count               = local.customer.mail ? 1 : 0
  name                = "acs-${var.customer_id}-${var.environment}"
  resource_group_name = azurerm_resource_group.customer.name
}
'@
    $files['source/Customers/environments/prod-x/infra/backend.tf'] = "terraform {`n  cloud {`n    organization = `"contoso`"`n  }`n}`n"
    $files['source/Customers/environments/prod-x/infra/values.tfvars'] = "environment = `"prod`"`n"
    $files['source/Customers/environments/prod-x/data/north/customer.json'] = '{ "mail": true }'
    $files['source/Customers/environments/prod-x/data/south/customer.json'] = '{ "mail": false }'
    return $files
}

# I frammenti dei lettori dei container: due applicazioni di un altro repository con le risorse che le
# ospitano, un servizio del repository dell'infrastruttura con il suo nome nel codice.
function New-ContainerFragments {
    $applications = [ordered]@{
        containers = @(
            [ordered]@{ id = 'contoso_shop_ai_api'; name = 'Api'; codeName = 'Contoso.Shop.AI.Api'; tags = @('Applicazione'); components = @() }
            [ordered]@{ id = 'contoso_shop_ai_worker'; name = 'Worker'; codeName = 'Contoso.Shop.AI.Worker'; tags = @('Applicazione'); components = @() }
        )
        relationships = @()
    }
    $infrastructure = [ordered]@{
        containers = @([ordered]@{ id = 'contoso_infrastructure_kv_contoso_prod'; name = 'kv-contoso-prod'; codeName = 'kv-contoso-prod'; tags = @(); components = @() })
        relationships = @()
        hosts = @(
            [ordered]@{ container = 'contoso_shop_ai_api'; resource = 'App/module.api/azurerm_linux_web_app.this' }
            [ordered]@{ container = 'contoso_shop_ai_worker'; resource = 'App/module.worker/azurerm_linux_web_app.this' }
        )
    }
    return @{
        'contoso.shop.ai.dotnet10.json'        = ($applications | ConvertTo-Json -Depth 10)
        'contoso.infrastructure.azure.json' = ($infrastructure | ConvertTo-Json -Depth 10)
    }
}

function Invoke-TerraformReader([System.Collections.IDictionary]$Files, [hashtable]$Fragments = (New-ContainerFragments), [string]$Instances = 'Customers:customer_id=environments/{environment}/data/*') {
    $root = Join-Path ([IO.Path]::GetTempPath()) "pester-c4-terraform-$(New-Guid)"
    Write-SourceFiles $root $Files
    $fragmentFiles = [ordered]@{}
    $Fragments.Keys | ForEach-Object { $fragmentFiles["fragments/$_"] = $Fragments[$_] }
    Write-SourceFiles $root $fragmentFiles
    $variables = @{
        SOURCE_DIRECTORY = 'source'; SOURCE_REPOSITORY = 'Contoso.Infrastructure'; FRAGMENT_DIRECTORY = 'fragments'; GATE_MODE = 'enforce'
        C4_SCRIPTS_DIRECTORY = "$C4ScriptsDirectory"; DOCUMENT_LANGUAGE = ''
        C4_DEPLOYMENT_ENVIRONMENTS = 'dev=dev-x;sta=sta-x;prod=prod-x'; C4_TERRAFORM_INSTANCES = $Instances
    }
    Push-Location $root
    try {
        $result = Invoke-C4Script 'C4/Read-C4TerraformModel.ps1' $variables
        $path = Join-Path $root 'fragments/contoso.infrastructure.terraform.json'
        $fragment = if (Test-Path $path) { Get-Content -Raw $path | ConvertFrom-Json }
        return [pscustomobject]@{ ExitCode = $result.ExitCode; Output = $result.Output; Fragment = $fragment }
    }
    finally {
        Pop-Location
        Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
    }
}

function Get-DeploymentEnvironment($Fragment, [string]$Name) {
    return $Fragment.deployment | Where-Object name -EQ $Name
}

function Get-AllNodes($Nodes) {
    foreach ($node in @($Nodes | Where-Object { $_ })) { $node; Get-AllNodes $node.children }
}

function Find-Node($Fragment, [string]$Environment, [string]$Name) {
    return Get-AllNodes (Get-DeploymentEnvironment $Fragment $Environment).nodes | Where-Object name -EQ $Name
}

# La catena dei nomi dei nodi dalla radice al nodo che contiene il container o il nodo cercato.
function Get-NodePath($Nodes, [scriptblock]$Match) {
    foreach ($node in @($Nodes | Where-Object { $_ })) {
        if (& $Match $node) { return , @($node.name) }
        $inner = Get-NodePath $node.children $Match
        if ($inner) { return , (@($node.name) + $inner) }
    }
    return $null
}
