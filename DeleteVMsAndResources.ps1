<#
    Script Name: DeleteVMsAndResources.ps1
    Version: 1.5
    Last Updated: 2025-09-15

    Description:
    ------------
    Deletes VMs and their associated resources (NICs, Public IPs, NSGs, OS/ Data disks) 
    from a CSV list. Supports Dry Run. Logs actions and generates a summary.
#>

param(
    [switch]$DryRun
)

# -------------------------
#   User-Editable Variables
# -------------------------
$UserCSVPathWindows    = "C:\Users\ADPrUmesh\Desktop\Scripts\Delete\vmdelete.csv"
$UserLogDirectory      = "C:\Users\ADPrUmesh\Desktop\Scripts\Delete\Logs"
$UserLogFilePrefix     = "DeleteVM_Log_"

# -------------------------
#   Setup Logging
# -------------------------
if (-not (Test-Path $UserLogDirectory)) {
    New-Item -ItemType Directory -Path $UserLogDirectory -Force | Out-Null
}
$currentDate = Get-Date -Format "yyyyMMdd_HHmmss"
$logFilePath = Join-Path $UserLogDirectory ("{0}{1}.csv" -f $UserLogFilePrefix, $currentDate)

$resources = Import-Csv -Path $UserCSVPathWindows
$totalVMs  = $resources.Count

# -------------------------
#   Summary Counters
# -------------------------
$SummaryCounts = @{
    Total     = 0
    Deleted   = 0
    Skipped   = 0
    Failed    = 0
}

# -------------------------
#   Helper Functions
# -------------------------
function Convert-ResourceId { param([string]$ResourceId)
    $parts = $ResourceId -split '/'
    return [PSCustomObject]@{
        SubscriptionId = $parts[2]
        ResourceGroup  = $parts[4]
        ResourceType   = $parts[7]
        ResourceName   = $parts[8]
    }
}

function Safe-Delete {
    param(
        [string]$ResourceType,
        [string]$ResourceName,
        [string]$Command,
        [string]$ActionReason = "Deleted"
    )

    if ($DryRun) {
        Write-Host "[DryRun] Would delete $ResourceType: $ResourceName"
    } elseif ($ActionReason -eq "Deleted") {
        Write-Host "Deleting $ResourceType: $ResourceName"
        Invoke-Expression $Command
    } else {
        Write-Host "Skipping $ResourceType: $ResourceName ($ActionReason)"
    }

    switch ($ActionReason) {
        "Deleted"        { $SummaryCounts.Deleted++ }
        "Skipped (Shared)" { $SummaryCounts.Skipped++ }
        "Failed"         { $SummaryCounts.Failed++ }
    }
    $SummaryCounts.Total++
    return $ActionReason
}

# -------------------------
#   Main Loop
# -------------------------
$vmCounter = 0
foreach ($item in $resources) {
    $vmCounter++
    $parsed = Convert-ResourceId -ResourceId $item.ResourceId
    $subscriptionId = $parsed.SubscriptionId
    $resourceGroup  = $parsed.ResourceGroup
    $vmName         = $parsed.ResourceName

    $status = "Success"
    $errorMessage = ""
    $actionDetails = @()

    try {
        az account set --subscription $subscriptionId

        $vmDetails = az vm show `
            --resource-group $resourceGroup --name $vmName `
            --query "{disks:storageProfile.dataDisks[].managedDisk.id, osdisk:storageProfile.osDisk.managedDisk.id, nics:networkProfile.networkInterfaces[].id}" `
            -o json | ConvertFrom-Json

        $resourcesToDelete = @()
        $resourcesToDelete += ,@("VM", $vmName)
        foreach ($nicId in $vmDetails.nics) {
            $nicName = ($nicId -split '/')[8]
            $resourcesToDelete += ,@("NIC", $nicName)
            $nicDetails = az network nic show --ids $nicId -o json | ConvertFrom-Json

            foreach ($ipConfig in $nicDetails.ipConfigurations) {
                if ($ipConfig.publicIpAddress) {
                    $pipName = ($ipConfig.publicIpAddress.id -split '/')[8]
                    $resourcesToDelete += ,@("Public IP", $pipName)
                }
            }

            if ($nicDetails.networkSecurityGroup) {
                $nsgName = ($nicDetails.networkSecurityGroup.id -split '/')[8]
                $resourcesToDelete += ,@("NSG", $nsgName)
            }
        }
        if ($vmDetails.osdisk) { $resourcesToDelete += ,@("OS Disk", ($vmDetails.osdisk -split '/')[8]) }
        foreach ($dataDiskId in $vmDetails.disks) { $resourcesToDelete += ,@("Data Disk", ($dataDiskId -split '/')[8]) }

        $resCounter = 0
        $resTotal   = $resourcesToDelete.Count

        foreach ($res in $resourcesToDelete) {
            $resCounter++
            $overallPercent = [math]::Round((($vmCounter-1 + ($resCounter/$resTotal)) / $totalVMs) * 100, 0)
            Write-Progress -Activity "Deleting Resources" `
                -Status "VM $vmCounter of $totalVMs | Processing $($res[0]): $($res[1]) ($resCounter/$resTotal)" `
                -PercentComplete $overallPercent

            try {
                switch ($res[0]) {
                    "VM" { $act = Safe-Delete -ResourceType "VM" -ResourceName $res[1] `
                             -Command "az vm delete --resource-group $resourceGroup --name $res[1] --yes" }
                    "NIC" {
                        $nicId = ($vmDetails.nics | Where-Object {$_ -like "*/$($res[1])"})
                        $nicDetails = az network nic show --ids $nicId -o json | ConvertFrom-Json

                        foreach ($ipConfig in $nicDetails.ipConfigurations) {
                            if ($ipConfig.publicIpAddress) {
                                $pipId = $ipConfig.publicIpAddress.id
                                $pipName = ($pipId -split '/')[8]
                                $pipRefs = az resource show --ids $pipId --query "ipConfiguration.id" -o tsv
                                if ([string]::IsNullOrEmpty($pipRefs) -or $pipRefs -eq $ipConfig.id) {
                                    $act = Safe-Delete -ResourceType "Public IP" -ResourceName $pipName `
                                           -Command "az network public-ip delete --ids $pipId"
                                } else { $act = Safe-Delete -ResourceType "Public IP" -ResourceName $pipName -Command "" -ActionReason "Skipped (Shared)" }
                            }
                        }

                        if ($nicDetails.networkSecurityGroup) {
                            $nsgId = $nicDetails.networkSecurityGroup.id
                            $nsgName = ($nsgId -split '/')[8]
                            $nsgRefs = az network nic list --query "[?networkSecurityGroup.id=='$nsgId'].[id]" -o tsv
                            if (($nsgRefs -split "`n").Count -eq 1) {
                                $act = Safe-Delete -ResourceType "NSG" -ResourceName $nsgName `
                                       -Command "az network nsg delete --ids $nsgId"
                            } else { $act = Safe-Delete -ResourceType "NSG" -ResourceName $nsgName -Command "" -ActionReason "Skipped (Shared)" }
                        }

                        $act = Safe-Delete -ResourceType "NIC" -ResourceName $res[1] `
                               -Command "az network nic delete --ids $nicId"
                    }
                    "OS Disk" { $act = Safe-Delete -ResourceType "OS Disk" -ResourceName $res[1] `
                                   -Command "az disk delete --ids $vmDetails.osdisk --yes" }
                    "Data Disk" {
                        $diskId = ($vmDetails.disks | Where-Object {$_ -like "*/$($res[1])"})
                        $act = Safe-Delete -ResourceType "Data Disk" -ResourceName $res[1] `
                               -Command "az disk delete --ids $diskId --yes"
                    }
                }
                $actionDetails += "$($res[0])-$($res[1])=$act"
            } catch {
                $act = "Failed"
                $SummaryCounts.Failed++
                $SummaryCounts.Total++
                $actionDetails += "$($res[0])-$($res[1])=$act"
            }
        }
    }
    catch {
        $status = "Failed"
        $errorMessage = $_.Exception.Message
        Write-Host "Error processing VM $vmName: $errorMessage"
    }

    $logRecord = [PSCustomObject]@{
        ResourceId     = $item.ResourceId
        ResourceGroup  = $resourceGroup
        VMName         = $vmName
        Status         = $status
        ErrorMessage   = $errorMessage
        DryRun         = $DryRun.IsPresent
        Actions        = ($actionDetails -join "; ")
        Timestamp      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    if (-not (Test-Path $logFilePath)) { $logRecord | Export-Csv -Path $logFilePath -NoTypeInformation -Encoding UTF8 }
    else { $logRecord | Export-Csv -Path $logFilePath -Append -NoTypeInformation -Encoding UTF8 }
}

# -------------------------
#   Print and Log Summary
# -------------------------
Write-Host "`nSummary of VM Deletion Run:"
Write-Host "--------------------------------"
Write-Host "Total Resources Processed: $($SummaryCounts.Total)"
Write-Host "Deleted: $($SummaryCounts.Deleted)"
Write-Host "Skipped (Shared): $($SummaryCounts.Skipped)"
Write-Host "Failed: $($SummaryCounts.Failed)"
Write-Host "--------------------------------"

$summaryRecord = [PSCustomObject]@{
    ResourceId    = "Summary"
    ResourceGroup = ""
    VMName        = ""
    Status        = "Completed"
    ErrorMessage  = ""
    DryRun        = $DryRun.IsPresent
    Actions       = "Total=$($SummaryCounts.Total); Deleted=$($SummaryCounts.Deleted); Skipped=$($SummaryCounts.Skipped); Failed=$($SummaryCounts.Failed)"
    Timestamp     = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}
$summaryRecord | Export-Csv -Path $logFilePath -Append -NoTypeInformation -Encoding UTF8

Write-Host "`nAll done! Log file saved to: $logFilePath"
if ($DryRun) { Write-Host "Dry Run completed — no resources were actually deleted." }
