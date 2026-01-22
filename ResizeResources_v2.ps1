# -------------------------
#   User-Editable Variables
# -------------------------
#$UserCSVPathCloudShell    = "$HOME/NewResizing/server.csv"      # CSV path in Cloud Shell
$UserCSVPathWindows       = "C:\Users\ADPrUmesh\Desktop\Scripts\Resize\server.csv"       # CSV path in Windows
#$UserCSVPathMacOS         = "$HOME/NewResizing/server.csv"       # CSV path in macOS

#$UserLogDirectoryCloudShell = "$HOME"                            # Log directory in Cloud Shell
$UserLogDirectoryWindows    = "C:\Users\ADPrUmesh\Desktop\Scripts\Resize\Logs"            # Log directory in Windows
#$UserLogDirectoryMacOS      = "$HOME/NewResizing/Logs"            # Log directory in macOS

$UserLogFilePrefix = "ResizeToNewSize_Log_"

# -------------------------
#   Helper Functions: Environment Detection
# -------------------------
<#function Test-RunningInCloudShell {
    return (Test-Path "$HOME/.cloudshell")
}

function Get-OSPlatform {
    if ($IsWindows) {
        return "Windows"
    } elseif ($IsMacOS) {
        return "MacOS"
    } else {
        throw "Unsupported OS platform"
    }
}

# -------------------------
#   Environment-Specific Path Setup
# -------------------------
if (Test-RunningInCloudShell) {
    Write-Host "Running in Cloud Shell environment."
    $csvPath = $UserCSVPathCloudShell
    $logDirectory = $UserLogDirectoryCloudShell
} else {
    $platform = Get-OSPlatform
    Write-Host "Running on local platform: $platform"
    if ($platform -eq "Windows") {
         $csvPath = $UserCSVPathWindows
         $logDirectory = $UserLogDirectoryWindows
    } elseif ($platform -eq "MacOS") {
         $csvPath = $UserCSVPathMacOS
         $logDirectory = $UserLogDirectoryMacOS
    }
}

# Ensure the log directory exists
if (-not (Test-Path $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}#>

# Define log file name using current date
$currentDate   = Get-Date -Format "yyyyMMdd"
$logFilePath = Join-Path $logDirectory ("{0}{1}.csv" -f $UserLogFilePrefix, $currentDate)

# Remove any pre-existing log file for this run
if (Test-Path $logFilePath) {
    Remove-Item $logFilePath -Force
}

# -------------------------
#   Import CSV
# -------------------------
$resources = Import-Csv -Path $csvPath

# -------------------------
#   Helper Function: Convert-ResourceId
# -------------------------
function Convert-ResourceId {
    param(
        [string]$ResourceId
    )
    # Example Resource ID:
    # /subscriptions/<subId>/resourceGroups/<rgName>/providers/Microsoft.Compute/virtualMachines/<vmName>
    # /subscriptions/<subId>/resourceGroups/<rgName>/providers/Microsoft.Compute/disks/<diskName>

    $parts = $ResourceId -split '/'

    $subscriptionId = $parts[2]
    $resourceGroup  = $parts[4]
    $provider       = $parts[6]     # e.g. "Microsoft.Compute"
    $resourceType   = $parts[7]     # "virtualMachines" or "disks"
    $resourceName   = $parts[8]

    return [PSCustomObject]@{
        SubscriptionId = $subscriptionId
        ResourceGroup  = $resourceGroup
        Provider       = $provider
        ResourceType   = $resourceType
        ResourceName   = $resourceName
    }
}

# -------------------------
#   Main Loop: Process Each Resource
# -------------------------
foreach ($item in $resources) {
    # Each row in the CSV is either a VM or a Disk.
    # CSV columns assumed to be: ResourceId, OldSize, NewSize (adjust as needed)
    $resourceId = $item.ResourceId
    $oldSize    = $item.OldSize
    $newSize    = $item.NewSize

    # Parse the resource ID for details.
    $parsed = Convert-ResourceId -ResourceId $resourceId
    $subscriptionId = $parsed.SubscriptionId
    $resourceGroup  = $parsed.ResourceGroup
    $resourceType   = $parsed.ResourceType
    $resourceName   = $parsed.ResourceName

    # Keep track of original power state
    $originalPowerState = $null

    # For logging
    $status       = "Success"
    $errorMessage = ""

    try {
        # Set subscription context
        az account set --subscription $subscriptionId

        if ($resourceType -eq "virtualMachines") {
            # -------------------------
            #   VM Resize Logic
            # -------------------------
            $originalPowerState = az vm get-instance-view `
                --name $resourceName `
                --resource-group $resourceGroup `
                --query "instanceView.powerState.code" -o tsv

            if ($originalPowerState -match "running$") {
                $originalPowerState = "VM running"
            } elseif ($originalPowerState -match "deallocated$") {
                $originalPowerState = "VM deallocated"
            } elseif ($originalPowerState -match "stopped$") {
                $originalPowerState = "VM stopped"
            }

            if ($originalPowerState -eq "VM running") {
                Write-Host "Stopping and deallocating VM: $resourceName (RG: $resourceGroup)"
                az vm stop --resource-group $resourceGroup --name $resourceName
                az vm deallocate --resource-group $resourceGroup --name $resourceName
            }

            Write-Host "Resizing VM '$resourceName' to size '$newSize'"
            az vm resize --resource-group $resourceGroup --name $resourceName --size $newSize

            if ($originalPowerState -eq "VM running") {
                Write-Host "Starting VM: $resourceName"
                az vm start --resource-group $resourceGroup --name $resourceName
            }
        }
        elseif ($resourceType -eq "disks") {
            # -------------------------
            #   Disk Resize (Re-tier) Logic with VM Power Off/On
            # -------------------------
            Write-Host "Re-tiering Disk '$resourceName' to SKU '$newSize'"

            # Check if the disk is attached to any VM
            $vmAttached = az disk show --ids $resourceId --query "managedBy" -o tsv

            if (-not [string]::IsNullOrEmpty($vmAttached)) {
                Write-Host "Disk '$resourceName' is attached to VM: $vmAttached"
                $attachedVm = Convert-ResourceId -ResourceId $vmAttached
                $vmSubId    = $attachedVm.SubscriptionId
                $vmRG       = $attachedVm.ResourceGroup
                $vmName     = $attachedVm.ResourceName

                $originalPowerState = az vm get-instance-view `
                    --name $vmName `
                    --resource-group $vmRG `
                    --query "instanceView.powerState.code" -o tsv

                if ($originalPowerState -match "running$") {
                    $originalPowerState = "VM running"
                } elseif ($originalPowerState -match "deallocated$") {
                    $originalPowerState = "VM deallocated"
                } elseif ($originalPowerState -match "stopped$") {
                    $originalPowerState = "VM stopped"
                }

                if ($originalPowerState -eq "VM running") {
                    Write-Host "Stopping and deallocating VM: $vmName (RG: $vmRG) before disk re-tier"
                    az vm stop --resource-group $vmRG --name $vmName
                    az vm deallocate --resource-group $vmRG --name $vmName
                }

                az disk update --ids $resourceId --set sku.name=$newSize

                if ($originalPowerState -eq "VM running") {
                    Write-Host "Starting VM: $vmName"
                    az vm start --resource-group $vmRG --name $vmName
                }
            }
            else {
                Write-Host "Disk '$resourceName' not attached to any VM. Re-tiering directly."
                az disk update --ids $resourceId --set sku.name=$newSize
            }
        }
        else {
            $status = "Skipped"
            $errorMessage = "Unknown resource type: $resourceType"
            Write-Host "Skipping unknown resource type in Resource ID: $resourceId"
        }
    }
    catch {
        $status = "Failed"
        $errorMessage = $_.Exception.Message
        Write-Host "Error occurred on resource '$resourceName': $errorMessage"
    }

    # -------------------------
    #   Incremental Logging
    # -------------------------
    $logRecord = [PSCustomObject]@{
        ResourceId      = $resourceId
        ResourceType    = $resourceType
        SubscriptionId  = $subscriptionId
        ResourceGroup   = $resourceGroup
        ResourceName    = $resourceName
        OldSize         = $oldSize
        NewSize         = $newSize
        Status          = $status
        ErrorMessage    = $errorMessage
        Timestamp       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    # If log file doesn't exist, create it (with headers), else append.
    if (-not (Test-Path $logFilePath)) {
        $logRecord | Export-Csv -Path $logFilePath -NoTypeInformation -Encoding UTF8
    }
    else {
        $logRecord | Export-Csv -Path $logFilePath -Append -NoTypeInformation -Encoding UTF8
    }
}

Write-Host "`nAll done! Log file saved to: $logFilePath"