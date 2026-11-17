#Requires -Modules Pester

<#
.SYNOPSIS
    Test Pester per V3/CI/Scripts/C4/TerraformValues.ps1

.DESCRIPTION
    Le espressioni Terraform valutate senza Terraform: sintassi, operatori, funzioni, valori sconosciuti
    e, su un repository finto in una directory temporanea, variabili, locals, istanze, moduli e remote state
    di un ambiente.
#>

BeforeAll {
    . "$PSScriptRoot/Fixtures/C4CodeFixture.ps1"
    . "$C4ScriptsDirectory/C4/TerraformCode.ps1"
    . "$C4ScriptsDirectory/C4/TerraformValues.ps1"

    function Get-Value([string]$Text, [hashtable]$Names = @{}, $Module = $null) {
        return Invoke-TfExpression (ConvertTo-TfSyntax $Text 'test.tf:1') @{ Module = $Module; Where = 'test.tf:1'; Names = $Names }
    }

    function Get-Items([string]$Text, [hashtable]$Names = @{}) {
        $value = Get-Value $Text $Names
        $value | Should -BeOfType ([TfList])
        return @($value.Items)
    }

    function Get-Text([string]$Text, [hashtable]$Names = @{}) {
        return Format-TfValue (Get-Value $Text $Names)
    }
}

Describe 'Espressioni' {
    It 'calcola gli operatori aritmetici con la precedenza di Terraform' -TestCases @(
        @{ Text = '1 + 2 * 3'; Expected = 7 }
        @{ Text = '(1 + 2) * 3'; Expected = 9 }
        @{ Text = '10 % 4 - 7 / 2'; Expected = -1.5 }
        @{ Text = '-3 + 1'; Expected = -2 }
        @{ Text = '"5" + 1'; Expected = 6 }
        @{ Text = '1 /* commento */ + 2'; Expected = 3 }
    ) {
        Get-Value $Text | Should -Be $Expected
    }

    It 'calcola confronti e operatori logici' -TestCases @(
        @{ Text = '1 < 2 && 2 >= 2'; Expected = $true }
        @{ Text = '1 > 2 || 2 <= 1'; Expected = $false }
        @{ Text = '!true'; Expected = $false }
        @{ Text = '"a" != "b"'; Expected = $true }
        @{ Text = 'null == null'; Expected = $true }
        @{ Text = '[1, 2] == [1, 2]'; Expected = $true }
        @{ Text = '[1, 2] == [1, 3]'; Expected = $false }
        @{ Text = '[1] == [1, 2]'; Expected = $false }
        @{ Text = '1 == "1"'; Expected = $false }
        @{ Text = '{ a = 1 } == { a = 1 }'; Expected = $false }
        @{ Text = '"true" && true'; Expected = $true }
        @{ Text = 'false && undefined_name.x'; Expected = $false }
        @{ Text = 'true || undefined_name.x'; Expected = $true }
    ) {
        Get-Value $Text | Should -Be $Expected
    }

    It "sceglie il ramo di una condizione" {
        Get-Value 'true ? "a" : "b"' | Should -Be 'a'
        Get-Value '1 > 2 ? "a" : "b"' | Should -Be 'b'
    }

    It 'compone template, sequenze di escape e heredoc' {
        Get-Value '"a-${1 + 1}-b"' | Should -Be 'a-2-b'
        Get-Value '"q\"\\\n\t\rA\x"' | Should -Be "q`"\`n`t`rAx"
        Get-Value '"$${x} %%{y}"' | Should -Be '${x} %{y}'
        Get-Value '"${true}"' | Should -BeTrue
        Get-Value '"${"a${"b"}"}c"' | Should -Be 'abc'
        Get-Value '"${ "x" ~}"' | Should -Be 'x'
        Get-Value ("<<EOT`nciao " + '${"mondo"}' + "`nEOT") | Should -Be "ciao mondo`n"
        Get-Value "<<-EOT`n    uno`n      due`n`n    EOT" | Should -Be "uno`n  due`n`n"
    }

    It 'costruisce tuple e oggetti' {
        Get-Items '[1, "a", true,]' | Should -Be @(1, 'a', $true)
        $object = Get-Value '{ a = 1, "b" : 2, "${"c"}" = 3 }'
        $object.Keys | Should -Be @('a', 'b', 'c')
        $object['c'] | Should -Be 3
    }

    It 'valuta le espressioni for su liste e oggetti' {
        Get-Items '[for x in [1, 2, 3] : x * 2 if x > 1]' | Should -Be @(4, 6)
        Get-Items '[for i, x in ["a", "b"] : "${i}${x}"]' | Should -Be @('0a', '1b')
        $object = Get-Value '{ for k, v in { a = 1, b = 2 } : upper(k) => v + 1 }'
        $object['A'] | Should -Be 2
        $object['B'] | Should -Be 3
        (Get-Value '{ for x in ["a", "b"] : x => 1... }').Keys | Should -Be @('a', 'b')
    }

    It 'legge attributi, indici e splat' {
        Get-Value '{ a = [10, 20] }.a[1]' | Should -Be 20
        Get-Value '[5, 6].1' | Should -Be 6
        Get-Value '{ a = 1 }["a"]' | Should -Be 1
        Get-Items '[{ n = 1 }, { n = 2 }][*].n' | Should -Be @(1, 2)
        Get-Items '[{ n = [7] }].*.n[0]' | Should -Be @(7)
        Get-Items '{ n = 3 }[*].n' | Should -Be @(3)
        @(Get-Items 'null[*].n') | Should -HaveCount 0
    }

    It "ferma la valutazione su un'espressione sbagliata nominando file e riga" -TestCases @(
        @{ Text = '"x" + 1'; Message = "*test.tf:1: '+' su valori che non sono numeri*" }
        @{ Text = '1 && true'; Message = "*test.tf:1: condizione che non e' un booleano*" }
        @{ Text = '{ a = 1 }["b"]'; Message = "*chiave 'b' assente*" }
        @{ Text = '[1][3]'; Message = '*indice 3 fuori dalla lista*' }
        @{ Text = '"a"[0]'; Message = "*indice su un valore che non e' una collezione*" }
        @{ Text = '{ a = 1 }.b'; Message = "*attributo 'b' assente*" }
        @{ Text = '"a".b'; Message = "*attributo 'b' su un valore che non e' un oggetto*" }
        @{ Text = 'each.key'; Message = '*each fuori da un for_each*' }
        @{ Text = 'count.index'; Message = '*count fuori da un count*' }
        @{ Text = '"%{ if true }x%{ endif }"'; Message = '*direttiva di template %{...} non supportata*' }
        @{ Text = '"aperta'; Message = '*stringa non chiusa*' }
        @{ Text = '1 2'; Message = "*testo dopo l'espressione*" }
        @{ Text = ']'; Message = '*sintassi non riconosciuta*' }
        @{ Text = '1 +'; Message = '*espressione incompleta*' }
        @{ Text = '{ a 1 }'; Message = "*atteso ':'*" }
        @{ Text = 'x.'; Message = '*attributo atteso dopo il punto*' }
        @{ Text = "<<EOT`nsenza fine"; Message = '*heredoc non chiuso*' }
        @{ Text = '<<EOT'; Message = '*heredoc non riconosciuto*' }
    ) {
        { Get-Value $Text @{ x = [ordered]@{} } } | Should -Throw $Message
    }

    It 'non riconosce un nodo di sintassi sconosciuto' {
        { Invoke-TfExpression @{ Kind = 'altro' } @{ Where = 'test.tf:1' } } | Should -Throw '*espressione non riconosciuta*'
    }
}

Describe 'Valori sconosciuti' {
    BeforeAll {
        $names = @{ u = [TfUnknown]::new('var.x'); l = [TfList]::new(@(1, [TfUnknown]::new('var.y'))) }
    }

    It 'si propagano scrivendo il riferimento che li origina' -TestCases @(
        @{ Text = 'u.a'; Expected = '{var.x.a}' }
        @{ Text = 'u[0]'; Expected = '{{var.x}[0]}' }
        @{ Text = 'u + 1'; Expected = '{{var.x} + 1}' }
        @{ Text = 'upper(u)'; Expected = '{var.x}' }
        @{ Text = '!u'; Expected = '{!{var.x}}' }
        @{ Text = '-u'; Expected = '{-{var.x}}' }
        @{ Text = '"a-${u}"'; Expected = '{a-{var.x}}' }
        @{ Text = '[for x in u : x]'; Expected = '{for in {var.x}}' }
        @{ Text = '[for x in [1] : x if u]'; Expected = '{for if {var.x}}' }
        @{ Text = '{ for x in [1] : u => x }'; Expected = '{for key {var.x}}' }
        @{ Text = 'u[*].a'; Expected = '{var.x}' }
        @{ Text = 'u ? 1 : 2'; Expected = '{{var.x} ? 1 : 2}' }
        @{ Text = 'terraform.workspace'; Expected = '{terraform.workspace}' }
        @{ Text = 'self'; Expected = '{self}' }
        @{ Text = 'timestamp()'; Expected = '{timestamp(...)}' }
        @{ Text = 'can(u)'; Expected = '{can}' }
        @{ Text = 'file(u)'; Expected = '{file(...)}' }
    ) {
        Get-Text $Text $names | Should -Be $Expected
    }

    It 'una condizione sconosciuta con rami uguali vale il ramo' {
        Get-Value 'u ? "a" : "a"' $names | Should -Be 'a'
    }

    It 'una lista con un elemento sconosciuto e'' sconosciuta' {
        Test-TfUnknown $names.l | Should -BeTrue
        Test-TfUnknown ([TfList]::new(@(1))) | Should -BeFalse
        ConvertTo-TfString $names.u | Should -BeOfType ([TfUnknown])
        ConvertTo-TfString 1.5 | Should -Be '1.5'
    }
}

Describe 'Funzioni' {
    It '<Text>' -TestCases @(
        @{ Text = 'lower("AbC")'; Expected = 'abc' }
        @{ Text = 'upper("abc")'; Expected = 'ABC' }
        @{ Text = 'title("ciao mondo")'; Expected = 'Ciao Mondo' }
        @{ Text = 'trimspace("  a ")'; Expected = 'a' }
        @{ Text = 'trimsuffix("app-dev", "-dev")'; Expected = 'app' }
        @{ Text = 'trimsuffix("app", "-dev")'; Expected = 'app' }
        @{ Text = 'trimprefix("app-dev", "app-")'; Expected = 'dev' }
        @{ Text = 'trimprefix("dev", "app-")'; Expected = 'dev' }
        @{ Text = 'startswith("app-dev", "app")'; Expected = $true }
        @{ Text = 'endswith("app-dev", "app")'; Expected = $false }
        @{ Text = 'replace("a-b-c", "-", "_")'; Expected = 'a_b_c' }
        @{ Text = 'replace("a1b22", "/([a-z])(\\d+)/", "$${2}$${1}")'; Expected = '1a22b' }
        @{ Text = 'substr("abcdef", 1, 3)'; Expected = 'bcd' }
        @{ Text = 'substr("abcdef", 2, -1)'; Expected = 'cdef' }
        @{ Text = 'format("%s-%d %v 100%%", "a", 2, true)'; Expected = 'a-2 true 100%' }
        @{ Text = 'join("-", ["a", 1])'; Expected = 'a-1' }
        @{ Text = 'strcat("a", "b", 1)'; Expected = 'ab1' }
        @{ Text = 'length("abc")'; Expected = 3 }
        @{ Text = 'length({ a = 1 })'; Expected = 1 }
        @{ Text = 'length([1, 2])'; Expected = 2 }
        @{ Text = 'lookup({ a = 1 }, "a")'; Expected = 1 }
        @{ Text = 'lookup({ a = 1 }, "b", 2)'; Expected = 2 }
        @{ Text = 'contains(["a", "b"], "b")'; Expected = $true }
        @{ Text = 'one([])'; Expected = $null }
        @{ Text = 'one(["a"])'; Expected = 'a' }
        @{ Text = 'alltrue([true, "true"])'; Expected = $true }
        @{ Text = 'anytrue([false, false])'; Expected = $false }
        @{ Text = 'sum([1, 2, 3])'; Expected = 6 }
        @{ Text = 'min(3, 1, 2)'; Expected = 1 }
        @{ Text = 'max(3, 1, 2)'; Expected = 3 }
        @{ Text = 'max([3, 4]...)'; Expected = 4 }
        @{ Text = 'tostring(1.5)'; Expected = '1.5' }
        @{ Text = 'tonumber("12")'; Expected = 12 }
        @{ Text = 'toint("-3")'; Expected = -3 }
        @{ Text = 'tobool("false")'; Expected = $false }
        @{ Text = 'coalesce(null, "", "a", "b")'; Expected = 'a' }
        @{ Text = 'jsonencode({ a = [1, "x"] })'; Expected = '{"a":[1.0,"x"]}' }
        @{ Text = 'jsondecode("{\"a\": {\"b\": [1, true]}}").a.b[0]'; Expected = 1 }
        @{ Text = 'sha256("a")'; Expected = 'ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb' }
        @{ Text = 'regex("^app-(\\w+)$", "app-dev")[0]'; Expected = 'dev' }
        @{ Text = 'regex("\\d+", "a12b")'; Expected = '12' }
        @{ Text = 'sensitive("s")'; Expected = 's' }
        @{ Text = 'nonsensitive("s")'; Expected = 's' }
        @{ Text = 'dirname("a/b/c.json")'; Expected = 'a/b' }
        @{ Text = 'tomap({ a = 1 }).a'; Expected = 1 }
        @{ Text = 'try(undefined_map.missing, { a = 1 }.b, "riserva")'; Expected = 'riserva' }
        @{ Text = 'can({ a = 1 }.a)'; Expected = $true }
        @{ Text = 'can({ a = 1 }.b)'; Expected = $false }
    ) {
        $undefined = [ordered]@{}
        Get-Value $Text @{ undefined_map = $undefined } | Should -Be $Expected
    }

    It 'restituisce liste e mappe' {
        Get-Items 'split("-", "a-b")' | Should -Be @('a', 'b')
        Get-Items 'keys({ b = 1, a = 2 })' | Should -Be @('a', 'b')
        Get-Items 'values({ b = 1, a = 2 })' | Should -Be @(2, 1)
        (Get-Value 'merge({ a = 1 }, null, { b = 2, a = 3 })').Values | Should -Be @(3, 2)
        Get-Items 'concat([1], [2, 3])' | Should -Be @(1, 2, 3)
        Get-Items 'flatten([1, [2, [3]]])' | Should -Be @(1, 2, 3)
        Get-Items 'distinct([1, 1, 2])' | Should -Be @(1, 2)
        Get-Items 'toset(["a", "a"])' | Should -Be @('a')
        Get-Items 'tolist(["a"])' | Should -Be @('a')
        Get-Items 'sort(["b", "a"])' | Should -Be @('a', 'b')
        Get-Items 'reverse([1, 2])' | Should -Be @(2, 1)
        Get-Items 'range(3)' | Should -Be @(0, 1, 2)
        Get-Items 'range(1, 3)' | Should -Be @(1, 2)
        Get-Items 'regexall("\\d", "a1b2")' | Should -Be @('1', '2')
        Get-Items 'setsubtract([1, 2, 3], [2])' | Should -Be @(1, 3)
        (Get-Items 'setproduct(["a"], [1, 2])')[1].Items | Should -Be @('a', 2)
        (Get-Value 'abspath("x")') | Should -Match '/x$'
    }

    It 'ferma la valutazione su una funzione sconosciuta o che non riesce' -TestCases @(
        @{ Text = 'unknownfn(1)'; Message = '*test.tf:1: funzione unknownfn non supportata*' }
        @{ Text = 'lookup({}, "a")'; Message = '*test.tf:1: lookup: chiave a assente*' }
        @{ Text = 'regex("x", "a")'; Message = '*regex senza corrispondenza*' }
        @{ Text = 'yamldecode("a: 1")'; Message = '*yamldecode non supportata*' }
        @{ Text = 'substr("ab", 5, 1)'; Message = '*test.tf:1: substr non valutata*' }
        @{ Text = 'try({}.a)'; Message = '*try senza alternative valide*' }
    ) {
        { Get-Value $Text } | Should -Throw $Message
    }

    Context 'sui file' {
        BeforeAll {
            $directory = Join-Path ([IO.Path]::GetTempPath()) "pester-terraform-values-$(New-Guid)"
            Write-SourceFiles $directory ([ordered]@{ 'data/a/x.json' = '{}'; 'data/b/y.txt' = 'testo' })
            $module = [pscustomobject]@{ WorkingDirectory = $directory }
        }
        AfterAll { Remove-Item -Recurse -Force $directory -ErrorAction SilentlyContinue }

        It 'legge un file dalla directory di lavoro del modulo' {
            Get-Value 'file("data/b/y.txt")' @{} $module | Should -Be 'testo'
            Get-Value 'fileexists("data/a/x.json")' @{} $module | Should -BeTrue
            Get-Value 'fileexists("data/a/z.json")' @{} $module | Should -BeFalse
        }

        It 'elenca i file di un glob' {
            (Get-Value 'fileset("data", "**/*.json")' @{} $module).Items | Should -Be @('a/x.json')
            (Get-Value 'fileset("data", "?/*")' @{} $module).Items | Should -Be @('a/x.json', 'b/y.txt')
            (Get-Value 'fileset("assente", "*")' @{} $module).Items | Should -HaveCount 0
        }

        It 'ferma la valutazione su un file assente' {
            { Get-Value 'file("data/z.txt")' @{} $module } | Should -Throw '*test.tf:1: file assente data/z.txt*'
        }
    }
}

Describe "Valori di un ambiente" {
    BeforeAll {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pester-terraform-values-$(New-Guid)"
        Write-SourceFiles $root ([ordered]@{
                'App/main.tf'                              = @'
variable "environment" {}
variable "secret" {}
variable "shared_workspace" {
  default = "shared-ws"
}
variable "settings" {
  type = object({
    size  = optional(number, 2)
    tags  = optional(map(object({ owner = optional(string, "team") })), {})
    items = optional(list(object({ name = string, zone = optional(string, "1") })), [])
    plain = optional(set(string))
  })
  default = {}
}

locals {
  name  = "app-${var.environment}"
  loop  = local.again
  again = local.loop
}

data "terraform_remote_state" "shared" {
  config = {
    workspaces = {
      name = var.shared_workspace
    }
  }
}

data "terraform_remote_state" "unknown" {
  config = {
    workspaces = {
      name = var.secret
    }
  }
}

data "terraform_remote_state" "outside" {
  config = {
    workspaces = {
      name = "other-repository"
    }
  }
}

data "terraform_remote_state" "nameless" {
  config = {}
}

data "azurerm_client_config" "current" {
  tenant = "t-${var.environment}"
}

resource "azurerm_resource_group" "main" {
  name = local.name
}

resource "azurerm_subnet" "numbered" {
  count = var.settings.size
  name  = "snet-${count.index}"
}

resource "azurerm_subnet" "named" {
  for_each = toset(["a", "b"])
  name     = "snet-${each.key}"
}

resource "azurerm_subnet" "mapped" {
  for_each = { x = "10.0.0.0/24" }
  name     = "${each.key}-${each.value}"
}

resource "azurerm_subnet" "unknown" {
  count = var.secret == "x" ? 1 : 0
}

module "child" {
  source = "../../../Modules/Child"
  prefix = local.name
}

module "copies" {
  source   = "../../../Modules/Child"
  for_each = toset(["one"])
  prefix   = each.key
}

module "external" {
  source = "git::https://example.org/m.git"
}

output "group" {
  value = azurerm_resource_group.main.name
}
'@
                'App/environments/dev/backend.tf'          = "terraform {`n  cloud {`n    workspaces {`n      name = `"app-dev`"`n    }`n  }`n}`n"
                'App/environments/dev/main.tf'             = "resource `"ignored`" `"hard_link`" {}`n"
                'App/environments/dev/extra.tf'            = "resource `"azurerm_subnet`" `"extra`" {`n  name = `"extra`"`n}`n"
                'App/environments/dev/name_override.tf'    = "resource `"azurerm_resource_group`" `"main`" {`n  location = `"westeurope`"`n}`nresource `"azurerm_subnet`" `"only_override`" {`n  name = `"o`"`n}`n"
                'App/environments/dev/values.tfvars'       = "environment = `"dev`"`nsettings = {`n  tags = { a = {} }`n  items = [{ name = `"n`" }]`n}`n"
                'App/environments/nobackend/main.tf'       = "locals {}`n"
                'Shared/main.tf'                           = "output `"subnet`" {`n  value = `"snet-shared`"`n}`n"
                'Shared/environments/all/nested/backend.tf' = "terraform {`n  backend `"remote`" {`n    workspaces {`n      name = `"shared-ws`"`n    }`n  }`n}`n"
                'Modules/Child/main.tf'                    = @'
variable "prefix" {}
variable "suffix" {
  default = "x"
}
variable "optional" {}

resource "azurerm_linux_web_app" "this" {
  name = "${var.prefix}-${var.suffix}"
}

output "name" {
  value = azurerm_linux_web_app.this.name
}

output "optional" {
  value = var.optional
}

output "undeclared" {
  value = var.undeclared
}

output "path" {
  value = path.module
}
'@
            })
        Reset-TfEvaluation
        $code = Read-TerraformRepository $root
        $environments = @(Get-TfEnvironments $code)
        $environment = $environments | Where-Object Directory -EQ 'App/environments/dev'
        $instance = Get-TfRootInstance $environment
        function Get-RootValue([string]$Text) { return Get-Value $Text @{} $instance }
    }
    AfterAll { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }

    It 'trova le directory d''ambiente con un backend, con workspace e values.tfvars' {
        @($environments.Directory) | Should -Be @('App/environments/dev', 'Shared/environments/all/nested')
        $environment.Workspace | Should -Be 'app-dev'
        $environment.Name | Should -Be 'dev'
        ($environments | Where-Object Root -EQ 'Shared').Name | Should -Be 'all'
        Get-TfEnvironments $code | Should -Be $environments
    }

    It "usa il codice del modulo radice, i file propri dell'ambiente e gli override" {
        @($instance.Blocks | Where-Object { $_.Labels[0] -eq 'ignored' }) | Should -HaveCount 0
        Get-RootValue 'azurerm_subnet.extra.name' | Should -Be 'extra'
        Get-RootValue 'azurerm_resource_group.main.location' | Should -Be 'westeurope'
        Get-RootValue 'azurerm_resource_group.main.name' | Should -Be 'app-dev'
        Get-RootValue 'azurerm_subnet.only_override.name' | Should -Be 'o'
    }

    It 'legge le variabili dai values.tfvars, dal default o come sconosciute' {
        Get-RootValue 'var.environment' | Should -Be 'dev'
        Get-RootValue 'var.shared_workspace' | Should -Be 'shared-ws'
        Get-RootValue 'var.secret' | Should -BeOfType ([TfUnknown])
    }

    It "applica i default optional() dei tipi oggetto, mappa e lista" {
        Get-RootValue 'var.settings.size' | Should -Be 2
        Get-RootValue 'var.settings.tags.a.owner' | Should -Be 'team'
        Get-RootValue 'var.settings.items[0].zone' | Should -Be '1'
        Get-RootValue 'var.settings.plain' | Should -BeNullOrEmpty
    }

    It 'valuta i locals e interrompe un ciclo con un valore sconosciuto' {
        Get-RootValue 'local.name' | Should -Be 'app-dev'
        Get-RootValue 'local.loop' | Should -BeOfType ([TfUnknown])
        { Get-RootValue 'local.missing' } | Should -Throw '*local.missing assente*'
    }

    It 'espande count e for_each nelle istanze di una risorsa' {
        Get-RootValue 'azurerm_subnet.numbered[1].name' | Should -Be 'snet-1'
        Get-RootValue 'azurerm_subnet.named["b"].name' | Should -Be 'snet-b'
        Get-RootValue 'azurerm_subnet.mapped["x"].name' | Should -Be 'x-10.0.0.0/24'
        (Get-TfInstances $instance (Find-TfBlock $instance 'resource' @('azurerm_subnet', 'unknown')))[0].Unknown | Should -Be '{{{var.secret} == x} ? 1 : 0}'
        Get-RootValue 'azurerm_subnet.unknown' | Should -BeOfType ([TfUnknown])
        Format-TfKey 1.0 | Should -Be '[1]'
        Format-TfKey 'a' | Should -Be '["a"]'
    }

    It "lascia sconosciuti gli attributi non dichiarati e chiede l'id a chi legge" {
        Get-RootValue 'azurerm_resource_group.main.location2' | Should -BeOfType ([TfUnknown])
        Format-TfValue (Get-RootValue 'azurerm_resource_group.main.id') | Should -Be '{azurerm_resource_group.main.id}'
        $script:TfResourceId = { param($resource) "/id/$($resource.Address)" }
        try { Get-RootValue 'azurerm_subnet.named["a"].id' | Should -Be '/id/azurerm_subnet.named["a"]' }
        finally { $script:TfResourceId = $null }
        { Get-RootValue 'azurerm_subnet.missing.id' } | Should -Throw '*azurerm_subnet.missing assente*'
        Format-TfValue (Get-RootValue 'azurerm_resource_group.main') | Should -Be '{azurerm_resource_group.main}'
    }

    It 'legge i data source dichiarati' {
        Get-RootValue 'data.azurerm_client_config.current.tenant' | Should -Be 't-dev'
        Get-RootValue 'data.azurerm_client_config.current.object_id' | Should -BeOfType ([TfUnknown])
    }

    It 'legge gli output dei moduli con gli argomenti della chiamata e i default' {
        Get-RootValue 'module.child.name' | Should -Be 'app-dev-x'
        Get-RootValue 'module.child.optional' | Should -BeNullOrEmpty
        Get-RootValue 'module.child.path' | Should -Be '../../../Modules/Child'
        Get-RootValue 'module.copies["one"].name' | Should -Be 'one-x'
        { Get-RootValue 'module.child.undeclared' } | Should -Throw '*variabile undeclared assente dal modulo*'
        { Get-RootValue 'module.child.missing' } | Should -Throw '*output missing assente*'
        { Get-RootValue 'module.missing.name' } | Should -Throw '*module.missing assente*'
        { Get-RootValue 'module.external.name' } | Should -Throw '*sorgente del modulo external non nel repository*'
        Get-RootValue 'path.module' | Should -Be '.'
    }

    It "elenca le istanze dei moduli dell'ambiente" {
        @(Get-TfModuleInstances $environment | ForEach-Object Path) | Should -Be @('', '/module.child', '/module.copies["one"]')
    }

    It "legge gli output del remote state di un altro ambiente del repository" {
        Get-RootValue 'data.terraform_remote_state.shared.outputs.subnet' | Should -Be 'snet-shared'
        Format-TfValue (Get-RootValue 'data.terraform_remote_state.unknown.outputs.subnet') | Should -Be '{data.terraform_remote_state.unknown.outputs.subnet}'
        Format-TfValue (Get-RootValue 'data.terraform_remote_state.outside.outputs.subnet') | Should -Be '{other-repository.outputs.subnet}'
        Format-TfValue (Get-RootValue 'data.terraform_remote_state.nameless.outputs.subnet') | Should -Be '{data.terraform_remote_state.nameless.outputs.subnet}'
    }

    It "ferma l'elenco su un modulo con istanze sconosciute" {
        $block = Find-TfBlock $instance 'module' @('copies')
        $previous = $block.Attributes['for_each']
        $block.Attributes['for_each'] = [pscustomobject]@{ Text = 'var.secret'; File = 'App/main.tf'; Line = 1 }
        try { { @(Get-TfModuleInstances $environment) } | Should -Throw '*istanze del modulo copies sconosciute*' }
        finally { $block.Attributes['for_each'] = $previous }
    }
}
