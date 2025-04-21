<#
    Script Name: DiskLUNMapping.ps1
    Version: 1.0.0
    Last Updated: 2025-04-15
    Author: Preetham Umesh - AHEAD

    Description: This script retrieves all Azure VM disks (Data disks) in part 1 from azure data plane
    part 2 from WMI (remote access) from within the VM. The goal is to stitch these 2 lists together
    and map data disk names with LUN #. These work only for VMs which are powered-on and have WMI open.
    From same WmiObject calls, we can query free disk space as well.

#>


# Connect to Azure
Connect-AzAccount
 
# Ask user where to save the CSV
$csvPath = Read-Host -Prompt "Enter the full file path to export CSV"
 
# Arrays to store results
$azureDisks = @()
$vmDriveMap = @()
$finalReport = @()
 
# Get all subscriptions
$subscriptions = Get-AzSubscription
 
# Loop through each subscription
foreach ($sub in $subscriptions) {
    Write-Host "Processing Subscription: $($sub.Name)" -ForegroundColor Cyan
    Select-AzSubscription -SubscriptionId $sub.Id
 
    $vms = Get-AzVM
 
    foreach ($vm in $vms) {
        $vmName = $vm.Name
        $resourceGroup = $vm.ResourceGroupName
        $subscriptionId = $sub.Id
 
        foreach ($disk in $vm.StorageProfile.DataDisks) {
            $azureDisks += [PSCustomObject]@{
                VMName        = $vmName
                DiskName      = $disk.Name
                LUN           = $disk.Lun
                DiskSizeGB    = $disk.DiskSizeGB
                DiskTier      = $disk.ManagedDisk.StorageAccountType
                Subscription  = $subscriptionId
                ResourceGroup = $resourceGroup
            }
        }
    }
}
 
# Get unique VM names for comparing and eliminating duplicates
$uniqueVMs = $azureDisks | Select-Object -ExpandProperty VMName -Unique
 
# Progress bar for ease
$totalVMs = $uniqueVMs.Count
$counter = 0
 
Write-Host "Collecting logical disk data from VMs..." -ForegroundColor Green
 
foreach ($vm in $uniqueVMs) {
    $counter++
    Write-Progress -Activity "Querying this VM..." -Status "[$counter of $totalVMs] $vm" -PercentComplete (($counter / $totalVMs) * 100)
 
    try {
        if (Test-Connection -ComputerName $vm -Count 1 -Quiet) {
            $diskDrives = Get-WmiObject -Class Win32_DiskDrive -ComputerName $vm
            $partitions = Get-WmiObject -Class Win32_DiskPartition -ComputerName $vm
            $logicalMap = Get-WmiObject -Class Win32_LogicalDiskToPartition -ComputerName $vm
            $logicalDisks = Get-WmiObject -Class Win32_LogicalDisk -ComputerName $vm | Where-Object { $_.DriveType -eq 3 }
 
            foreach ($map in $logicalMap) {
                $logicalDisk = ([WMI]$map.Dependent)
                $partition = ([WMI]$map.Antecedent)
                $diskIndex = $partition.DiskIndex
                $driveLetter = $logicalDisk.DeviceID
 
                # Query disk size, free disk space at a logical level
                $logicalInfo = $logicalDisks | Where-Object { $_.DeviceID -eq $driveLetter }
 
                $vmDriveMap += [PSCustomObject]@{
                    VMName      = $vm
                    DiskIndex   = $diskIndex
                    DriveLetter = $driveLetter
                    TotalSizeGB = [math]::Round($logicalInfo.Size / 1GB, 2)
                    FreeSpaceGB = [math]::Round($logicalInfo.FreeSpace / 1GB, 2)
                    UsedSpaceGB = [math]::Round(($logicalInfo.Size - $logicalInfo.FreeSpace) / 1GB, 2)
                }
            }
        }
        else {
            Write-Warning "VM $vm is unreachable."
        }
    }
    catch {
        Write-Warning "Failed to get disk info for $vm : $_"
    }
}
 
# From the previous azureDisks for uniqueVMs compare mapping information
foreach ($azDisk in $azureDisks) {
    $match = $vmDriveMap | Where-Object {
        $_.VMName -eq $azDisk.VMName -and $_.DiskIndex -eq $azDisk.LUN
    }
 
    $finalReport += [PSCustomObject]@{
        VMName        = $azDisk.VMName
        DiskName      = $azDisk.DiskName
        DriveLetter   = if ($match) { ($match.DriveLetter -join ",") } else { "NotFound" }
        DiskSizeGB    = $azDisk.DiskSizeGB
        DiskTier      = $azDisk.DiskTier
        LUN           = $azDisk.LUN
        TotalSizeGB   = if ($match) { $match.TotalSizeGB } else { "N/A" }
        FreeSpaceGB   = if ($match) { $match.FreeSpaceGB } else { "N/A" }
        UsedSpaceGB   = if ($match) { $match.UsedSpaceGB } else { "N/A" }
        Subscription  = $azDisk.Subscription
        ResourceGroup = $azDisk.ResourceGroup
    }
}
 
# Export Final report
$finalReport | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "CSV exported to: $csvPath" -ForegroundColor Green