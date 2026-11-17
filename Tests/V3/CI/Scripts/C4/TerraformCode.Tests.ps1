#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/TerraformCode.ps1

.DESCRIPTION
    Il parser dei file .tf e i riferimenti seguiti per nome attraverso locals, variabili, moduli e remote
    state, su un repository Terraform finto scritto in una directory temporanea.
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/C4CodeFixture.ps1"
    . "$C4ScriptsDirectory/C4/TerraformCode.ps1"

    function New-Code([System.Collections.IDictionary]$Files) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-terraform-code-$(New-Guid)"
        Write-SourceFiles $root $Files
        $script:Roots += @($root)
        return Read-TerraformRepository $root
    }

    function New-Expression([string]$Text) {
        return [pscustomobject]@{ Text = $Text; File = 'main.tf'; Line = 1 }
    }

    $script:Roots = @()
    $script:Code = New-Code ([ordered]@{
            'Shared/main.tf'                         = "output `"subnet_id`" {`n  value = azurerm_subnet.shared.id`n}`nresource `"azurerm_subnet`" `"shared`" {`n  name = `"snet`"`n}`n"
            'Shared/environments/dev/backend.tf'     = "terraform {`n  cloud {`n    workspaces {`n      name = `"shared-dev`"`n    }`n  }`n}`n"
            'App/main.tf'                            = @'
variable "shared" {
  default = "shared"
}

variable "plain" {
}

locals {
  name = "app-${var.plain}"
  plan = azurerm_service_plan.this.id
}

data "terraform_remote_state" "shared" {
  backend = "remote"
  config = {
    workspaces = {
      name = "${var.shared}-dev"
    }
  }
}

data "azurerm_client_config" "current" {}

resource "azurerm_service_plan" "this" {
  name = local.name
}

module "web" {
  source          = "../../../Modules/Web"
  service_plan_id = local.plan
}

module "remote" {
  source = "git::https://example.org/module.git"
}
'@
            'App/environments/dev/backend.tf'        = "terraform {`n  cloud {`n    workspaces {`n      name = `"app-dev`"`n    }`n  }`n}`n"
            'App/environments/dev/values.tfvars'     = "plain = `"dev`"`n"
            'Modules/Web/main.tf'                    = @'
variable "service_plan_id" {}

resource "azurerm_linux_web_app" "this" {
  service_plan_id = var.service_plan_id
}

output "id" {
  value = azurerm_linux_web_app.this.id
}

output "plan" {
  value = var.service_plan_id
}
'@
        })
}

AfterAll {
    $script:Roots | ForEach-Object { Remove-Item -Recurse -Force $_ -ErrorAction SilentlyContinue }
}

Describe 'Read-TerraformFile' {
    BeforeAll {
        $path = Join-Path ([IO.Path]::GetTempPath()) "pester-terraform-file-$(New-Guid).tf"
        [IO.File]::WriteAllText($path, @'
# commento
/* commento
   su piu' righe */
resource "azurerm_linux_web_app" "api" { // in linea
  name = "app-${lower("API")}" # dopo
  tags = {
    owner = "team"
  }
  script = <<-EOT
    echo "}"
  EOT
  list = [
    1, 2,
  ]
  site_config {
    always_on = true
  }
}
'@)
        $file = Read-TerraformFile $path 'main.tf'
        Remove-Item $path
        $block = $file.Blocks[0]
    }

    It 'legge tipo, etichette e riga di un blocco' {
        $block.Type | Should -Be 'resource'
        $block.Labels | Should -Be @('azurerm_linux_web_app', 'api')
        $block.Line | Should -Be 4
    }

    It "legge il testo di un attributo fino alla fine della riga, fuori da stringhe e parentesi" {
        $block.Attributes['name'].Text | Should -Be '"app-${lower("API")}"'
        $block.Attributes['tags'].Text | Should -Match '(?s)^\{.*owner = "team".*\}$'
        $block.Attributes['script'].Text | Should -Match '(?s)^<<-EOT.*EOT$'
        $block.Attributes['list'].Text | Should -Match '(?s)^\[.*\]$'
    }

    It 'legge i blocchi annidati' {
        $block.Blocks[0].Type | Should -Be 'site_config'
        $block.Blocks[0].Attributes['always_on'].Text | Should -Be 'true'
    }

    It 'ferma la lettura su una sintassi che non riconosce' {
        $path = Join-Path ([IO.Path]::GetTempPath()) "pester-terraform-file-$(New-Guid).tf"
        [IO.File]::WriteAllText($path, "resource `"a`" `"b`" {`n  = 1`n}`n")
        { Read-TerraformFile $path 'broken.tf' } | Should -Throw '*broken.tf:2: sintassi Terraform non riconosciuta*'
        Remove-Item $path
    }
}

Describe 'Get-ExpressionReferences' {
    It 'trova i riferimenti fuori dal testo letterale delle stringhe' {
        @(Get-ExpressionReferences '"var.not_a_reference ${local.name}-${azurerm_subnet.this[0].id}"') | Should -Be @('local.name', 'azurerm_subnet.this.id')
    }

    It "ignora gli iteratori dei for, each, count e path e segue i riferimenti negli indici" {
        @(Get-ExpressionReferences '[for k, v in var.items : v.name if each.key != path.module]') | Should -Be @('var.items')
        @(Get-ExpressionReferences 'local.map[var.key].id') | Should -Be @('var.key', 'local.map.id')
    }

    It 'salta i caratteri di escape delle stringhe' {
        @(Get-ExpressionReferences '"a\"b" == var.x') | Should -Be @('var.x')
    }
}

Describe 'Get-ReferencedResources' {
    BeforeAll {
        $root = New-TerraformFrame 'App' 'App' '' $null $null
        function Get-References([string]$Text) { return @(Get-ReferencedResources $Code $root (New-Expression $Text) 'dev') }
    }

    It "segue un local fino alla risorsa" {
        (Get-References 'local.plan').Key | Should -Be 'App/azurerm_service_plan.this'
    }

    It "segue l'output di un modulo fino alla risorsa del modulo e l'argomento della chiamata fino al modulo chiamante" {
        @((Get-References 'module.web.id').Key) | Should -Be @('App/module.web/azurerm_linux_web_app.this')
        @((Get-References 'module.web.plan').Key) | Should -Be @('App/azurerm_service_plan.this')
    }

    It "segue il remote state fino all'output del modulo radice che dichiara il workspace" {
        (Get-References 'data.terraform_remote_state.shared.outputs.subnet_id').Key | Should -Be 'Shared/azurerm_subnet.shared'
    }

    It 'si ferma senza rilievi su una variabile del modulo radice e su un data source dichiarato' {
        Get-References 'var.plain' | Should -BeNullOrEmpty
        Get-References 'data.azurerm_client_config.current.tenant_id' | Should -BeNullOrEmpty
    }

    It 'accetta il prefisso resource.' {
        (Get-References 'resource.azurerm_service_plan.this.id').Key | Should -Be 'App/azurerm_service_plan.this'
    }

    It 'segnala i riferimenti che non sa seguire' -TestCases @(
        @{ Text = 'local.missing' }
        @{ Text = 'var.missing' }
        @{ Text = 'module.missing.id' }
        @{ Text = 'module.remote.id' }
        @{ Text = 'module.web.missing' }
        @{ Text = 'data.terraform_remote_state.missing.outputs.id' }
        @{ Text = 'data.azurerm_missing.this.id' }
        @{ Text = 'azurerm_missing.this.id' }
    ) {
        $result = Get-References $Text
        $result.Kind | Should -Be 'unfollowable'
        $result.Location | Should -Be 'main.tf:1'
    }
}

Describe 'Valori letterali di un modulo radice' {
    It "legge una variabile dai values.tfvars dell'ambiente o dal default" {
        Get-RootVariableValue $Code 'App' 'plain' 'dev' | Should -Be 'dev'
        Get-RootVariableValue $Code 'App' 'shared' 'dev' | Should -Be 'shared'
        Get-RootVariableValue $Code 'App' 'plain' 'sta' | Should -BeNullOrEmpty
    }

    It 'risolve un template di sole variabili e rinuncia a uno con altre interpolazioni' {
        Resolve-StringTemplate $Code 'App' (New-Expression '"${var.shared}-dev"') 'dev' | Should -Be 'shared-dev'
        Resolve-StringTemplate $Code 'App' (New-Expression 'var.plain') 'dev' | Should -Be 'dev'
        Resolve-StringTemplate $Code 'App' (New-Expression '"${local.name}"') 'dev' | Should -BeNullOrEmpty
        Resolve-StringTemplate $Code 'App' (New-Expression 'local.name') 'dev' | Should -BeNullOrEmpty
        Resolve-StringTemplate $Code 'App' $null 'dev' | Should -BeNullOrEmpty
    }

    It 'trova il modulo radice che dichiara un workspace in un ambiente' {
        Find-WorkspaceRoot $Code 'shared-dev' 'dev' | Should -Be 'Shared'
        Find-WorkspaceRoot $Code 'shared-dev' 'prod' | Should -BeNullOrEmpty
    }
}
