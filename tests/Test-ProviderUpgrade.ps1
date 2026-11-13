[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,
    [Parameter(Mandatory)]
    [string]$TenantId,
    [string]$TerraformPath = "terraform",
    [string]$BeforeSource = "git::https://github.com/MB-External/terraform-azurerm-avm-res-compute-virtualmachine?ref=2702faa55df85a60c28a6b88f08ee4837f715a7f"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root (Join-Path ".terraform" ("provider-upgrade-" + [guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Path $directory | Out-Null
$oldTelemetry = $env:AZURE_CORE_COLLECT_TELEMETRY
$env:AZURE_CORE_COLLECT_TELEMETRY = "no"
$resourceGroup = "/subscriptions/$SubscriptionId/resourceGroups/rg-upgrade-fixture"
$vmId = "$resourceGroup/providers/Microsoft.Compute/virtualMachines/vm-fixture"
$nicId = "$resourceGroup/providers/Microsoft.Network/networkInterfaces/nic-fixture"
$diskId = "$resourceGroup/providers/Microsoft.Compute/disks/data-fixture"

function Invoke-Terraform {
    param([string[]]$Arguments)
    $result = & $TerraformPath "-chdir=$directory" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($result -join "`n")
    }
    return ($result -join "`n")
}

function Get-Plan {
    Invoke-Terraform @("plan", "-refresh=false", "-input=false", "-no-color", "-out=upgrade.tfplan") | Out-Null
    return (Invoke-Terraform @("show", "-json", "upgrade.tfplan") | ConvertFrom-Json -AsHashtable)
}

function Assert-UnchangedResources {
    param($Plan, [string]$Label, [hashtable]$ExpectedMetrics = @{})
    foreach ($resource in $Plan.resource_changes) {
        $change = $resource.change
        $actions = $change.actions -join ","
        if ($actions -eq "no-op") {
            continue
        }
        $sameValues = (ConvertTo-Json $change.before -Depth 100 -Compress) -eq (ConvertTo-Json $change.after -Depth 100 -Compress)
        $hasUnknowns = (ConvertTo-Json $change.after_unknown -Depth 100 -Compress) -match ':\s*true\b'
        if ($actions -eq "update" -and -not $hasUnknowns -and $resource.type -eq "azurerm_monitor_diagnostic_setting" -and $ExpectedMetrics.ContainsKey($resource.address)) {
            $otherChanges = @($change.before.Keys | Where-Object {
                $_ -ne "enabled_metric" -and
                (ConvertTo-Json $change.before[$_] -Depth 100 -Compress) -ne (ConvertTo-Json $change.after[$_] -Depth 100 -Compress)
            })
            $categories = @($change.after.enabled_metric | ForEach-Object category | Sort-Object)
            if ($otherChanges.Count -eq 0 -and ($categories -join ",") -eq ($ExpectedMetrics[$resource.address] -join ",")) {
                Write-Warning "$Label migrates metric to enabled_metric in place for $($resource.address), preserving all configured metric categories."
                continue
            }
        }
        if ($actions -ne "update" -or -not $sameValues -or $hasUnknowns) {
            throw "$Label changes resource values or identity: $($resource | ConvertTo-Json -Depth 100 -Compress)"
        }
        Write-Warning "$Label reports an SDK update with identical before/after values for $($resource.address); this synthetic check is not a live no-op guarantee."
    }
}

try {
    foreach ($os in @("Windows", "Linux")) {
        $configuration = @{
            terraform = @{ required_providers = @{ azurerm = @{ source = "hashicorp/azurerm"; version = "=4.81.0" } } }
            provider = @{ azurerm = @{ subscription_id = $SubscriptionId; tenant_id = $TenantId; resource_provider_registrations = "none"; features = @{} } }
            module = @{
                virtual_machine = @{
                    source = $BeforeSource
                    name = "vm-fixture"
                    computer_name = "vm-fixture"
                    location = "northeurope"
                    resource_group_name = "rg-upgrade-fixture"
                    zone = "1"
                    os_type = $os
                    sku_size = "Standard_D2s_v5"
                    enable_telemetry = $false
                    source_image_resource_id = "$resourceGroup/providers/Microsoft.Compute/images/image-fixture"
                    account_credentials = @{
                        password_authentication_disabled = $os -eq "Windows"
                        admin_credentials = @{
                            username = "fixtureadmin"
                            password = "Synthetic-fixture-only-123!"
                            generate_admin_password_or_ssh_key = $false
                        }
                    }
                    os_disk = @{
                        caching = "ReadWrite"
                        name = "os-fixture"
                        storage_account_type = "StandardSSD_LRS"
                        disk_size_gb = 128
                        disk_encryption_set_id = "$resourceGroup/providers/Microsoft.Compute/diskEncryptionSets/des-fixture"
                    }
                    data_disk_managed_disks = @{
                        "0" = @{ name = "data-fixture"; lun = 0; disk_size_gb = 16; storage_account_type = "StandardSSD_LRS"; caching = "None" }
                    }
                    network_interfaces = @{
                        primary = @{
                            name = "nic-fixture"
                            ip_configurations = @{
                                internal = @{
                                    name = "internal"
                                    is_primary_ipconfiguration = $true
                                    private_ip_subnet_resource_id = "$resourceGroup/providers/Microsoft.Network/virtualNetworks/vnet-fixture/subnets/default"
                                    private_ip_address_allocation = "Static"
                                    private_ip_address = "10.0.0.4"
                                }
                            }
                            diagnostic_settings = @{
                                metrics = @{ name = "nic-metrics"; workspace_resource_id = "$resourceGroup/providers/Microsoft.OperationalInsights/workspaces/law-fixture"; metric_categories = @("AllMetrics") }
                            }
                        }
                    }
                    diagnostic_settings = @{
                        metrics = @{ name = "vm-metrics"; workspace_resource_id = "$resourceGroup/providers/Microsoft.OperationalInsights/workspaces/law-fixture"; metric_categories = @("AllMetrics") }
                    }
                }
            }
        }
        $configuration | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $directory "main.tf.json") -Encoding utf8NoBOM
        $stateFile = Join-Path $directory "terraform.tfstate"
        if (Test-Path -LiteralPath $stateFile) {
            Remove-Item -LiteralPath $stateFile
        }
        Invoke-Terraform @("init", "-backend=false", "-upgrade", "-input=false", "-no-color") | Out-Null
        $schema = Invoke-Terraform @("providers", "schema", "-json") | ConvertFrom-Json -AsHashtable
        $initial = Get-Plan
        $resources = @()
        $expectedMetrics = @{}
        foreach ($resource in $initial.planned_values.root_module.child_modules[0].resources) {
            $attributes = $resource.values
            switch ($resource.type) {
                "azurerm_network_interface" {
                    $attributes.id = $nicId
                    $attributes.ip_configuration[0].gateway_load_balancer_frontend_ip_configuration_id = ""
                    $attributes.ip_configuration[0].public_ip_address_id = ""
                    $attributes.applied_dns_servers = @()
                    $attributes.private_ip_addresses = @("10.0.0.4")
                }
                "azurerm_managed_disk" { $attributes.id = $diskId }
                { $_ -in @("azurerm_windows_virtual_machine", "azurerm_linux_virtual_machine") } {
                    $attributes.id = $vmId
                    $attributes.network_interface_ids = @($nicId)
                    $attributes.os_disk[0].id = "$resourceGroup/providers/Microsoft.Compute/disks/os-fixture"
                    $attributes.os_disk[0].secure_vm_disk_encryption_set_id = ""
                    $attributes.os_disk[0].security_encryption_type = ""
                    $attributes.private_ip_addresses = @("10.0.0.4")
                    $attributes.public_ip_addresses = @()
                    $attributes.private_ip_address = "10.0.0.4"
                    $attributes.public_ip_address = ""
                    $attributes.virtual_machine_id = "11111111-1111-1111-1111-111111111111"
                    $attributes.vm_agent_platform_updates_enabled = $false
                    if ($resource.type -eq "azurerm_windows_virtual_machine") {
                        # The v4 Read function populates both aliases from the same API value.
                        $attributes.automatic_updates_enabled = $attributes.enable_automatic_updates
                    }
                }
                "azurerm_virtual_machine_data_disk_attachment" {
                    $attributes.id = "$vmId/dataDisks/data-fixture"
                    $attributes.virtual_machine_id = $vmId
                    $attributes.managed_disk_id = $diskId
                }
                "azurerm_monitor_diagnostic_setting" {
                    $attributes.target_resource_id = if ($resource.address -like "*this_nic_diags*") { $nicId } else { $vmId }
                    $attributes.id = "$($attributes.target_resource_id)|$($attributes.name)"
                    $expectedMetrics[$resource.address] = @($attributes.metric | Where-Object enabled | ForEach-Object category | Sort-Object)
                }
                default { throw "Unexpected fixture resource $($resource.address)." }
            }
            $resources += @{
                module = "module.virtual_machine"
                mode = "managed"
                type = $resource.type
                name = $resource.name
                provider = 'provider["registry.terraform.io/hashicorp/azurerm"]'
                instances = @(@{
                    index_key = $resource.index
                    schema_version = $schema.provider_schemas["registry.terraform.io/hashicorp/azurerm"].resource_schemas[$resource.type].version
                    attributes = $attributes
                    sensitive_attributes = @()
                })
            }
        }
        @{ version = 4; serial = 1; lineage = [guid]::NewGuid().ToString(); outputs = @{}; resources = $resources } |
            ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $stateFile -Encoding utf8NoBOM
        $baseline = Get-Plan
        Assert-UnchangedResources -Plan $baseline -Label "$os v4 baseline"
        $configuration.terraform.required_providers.azurerm.version = "=5.13.0"
        $configuration.module.virtual_machine.source = $root
        $configuration | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $directory "main.tf.json") -Encoding utf8NoBOM
        Invoke-Terraform @("init", "-backend=false", "-upgrade", "-input=false", "-no-color") | Out-Null
        $upgraded = Get-Plan
        Assert-UnchangedResources -Plan $upgraded -Label "$os v5 upgrade" -ExpectedMetrics $expectedMetrics
        Write-Output "PASS ${os}: v4-to-v5 upgrade preserves VM, NIC, disk and attachment values, and diagnostic metric categories, without creation, replacement or deletion (synthetic state)."
    }
}
catch {
    Write-Output "Provider upgrade check failed: $($_.Exception.Message)"
    throw
}
finally {
    $env:AZURE_CORE_COLLECT_TELEMETRY = $oldTelemetry
    Remove-Item -LiteralPath $directory -Recurse -Force
}
