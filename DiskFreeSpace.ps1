<#
    Script Name: DiskLUNMap.ps1
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

# Provide the full file path (with name) for output
$path = Read-Host -Prompt "Please provide a file path to export the CSV"
 
# Arrays to store Mapping and comparision report data
$vmDriveMap = @()
$finalReport = @()
 
# Get all subscriptions
$subscriptions = Get-AzSubscription

# Loop through each subscription 
foreach ($subscription in $subscriptions) {
    Select-AzSubscription -SubscriptionId $subscription.Id
    Write-Host "Running for subscription: $($subscription.Name)"
 
    # Get all VMs in the subscription and gather uniqueVM data for easier comparison
    $vms = Get-AzVM
    $uniqueVMs = $vms.Name | Sort-Object -Unique
    $totalVMs = $uniqueVMs.Count
    $counter = 0
 
    # Collect logical disk mappings for each VM
    foreach ($vm in $uniqueVMs) {
        $counter++
        Write-Progress -Activity "Querying VMs..." -Status "[$counter of $totalVMs] $vm" -PercentComplete (($counter / $totalVMs) * 100)
 
        try {
            if (Test-Connection -ComputerName $vm -Count 1 -Quiet) {
                $diskDrives   = Get-WmiObject -Class Win32_DiskDrive -ComputerName $vm
                $partitions   = Get-WmiObject -Class Win32_DiskPartition -ComputerName $vm
                $mappings     = Get-WmiObject -Class Win32_LogicalDiskToPartition -ComputerName $vm
                $logicalDisks = Get-WmiObject -Class Win32_LogicalDisk -ComputerName $vm | Where-Object { $_.DriveType -eq 3 }
 
                foreach ($disk in $diskDrives) {
                    $matchedPartitions = $partitions | Where-Object { $_.DiskIndex -eq $disk.Index }
 
                    foreach ($partition in $matchedPartitions) {
                        $matchedLinks = $mappings | Where-Object {
                            $_.Antecedent -like "*Disk #$($disk.Index)*" -and $_.Antecedent -like "*Partition #$($partition.Index)*"
                        }
 
                        foreach ($link in $matchedLinks) {
                            $logicalDisk = ([WMI]$link.Dependent)
                            $logicalInfo = $logicalDisks | Where-Object { $_.DeviceID -eq $logicalDisk.DeviceID }
 
                            if ($logicalDisk.DeviceID -in "C:", "D:") { continue }
 
                            $vmDriveMap += [PSCustomObject]@{
                                VMName        = $vm
                                DeviceID      = $disk.DeviceID
                                Model         = $disk.Model
                                Size          = $disk.Size
                                Index         = $disk.Index
                                SCSITargetId  = $disk.SCSITargetId
                                DriveLetter   = $logicalDisk.DeviceID
                                TotalSizeGB   = [math]::Round($logicalInfo.Size / 1GB, 2)
                                FreeSpaceGB   = [math]::Round($logicalInfo.FreeSpace / 1GB, 2)
                                UsedSpaceGB   = [math]::Round(($logicalInfo.Size - $logicalInfo.FreeSpace) / 1GB, 2)
                            }
                        }
                    }
                }
            } else {
                Write-Warning "VM $vm is unreachable."
            }
        } catch {
            Write-Warning "Failed to get disk info for $vm : $_"
        }
    }
 
    # Compare the above output to the VM list that was generated from azure query
    foreach ($vm in $vms) {
        $osDiskName = $vm.StorageProfile.OsDisk.Name
        $vmDisks = $vmDriveMap | Where-Object { $_.VMName -eq $vm.Name }
        $claimedDrives = @()
 
        foreach ($disk in $vm.StorageProfile.DataDisks) {
            Write-Host "Matching for VM: $($vm.Name) Disk: $($disk.Name) LUN: $($disk.Lun) Size: $($disk.DiskSizeGB)"
            foreach ($d in $vmDisks) {
                Write-Host "  WMI Disk => SCSITargetId: $($d.SCSITargetId), SizeGB: $([math]::Round($d.Size / 1GB)), Drive: $($d.DriveLetter)"
            }
 
            $match = $vmDisks | Where-Object {
                $_.SCSITargetId -eq $disk.Lun -and
                [math]::Abs($_.Size / 1GB - $disk.DiskSizeGB) -lt 1 -and
                -not ($_.DriveLetter -in $claimedDrives)
            } | Select-Object -First 1
 
            if (-not $match) {
                $match = $vmDisks | Where-Object {
                    [math]::Abs($_.Size / 1GB - $disk.DiskSizeGB) -lt 1 -and
                    -not ($_.DriveLetter -in $claimedDrives)
                } | Select-Object -First 1
            }
 
            if ($match) {
                Write-Host "Matched Disk: $($match.DeviceID) Drive Letter: $($match.DriveLetter)"
                $claimedDrives += $match.DriveLetter
            } else {
                Write-Host "No match found for LUN: $($disk.Lun) with Size: $($disk.DiskSizeGB) GB"
            }
 
            $finalReport += [PSCustomObject]@{
                VMName        = $vm.Name
                DiskName      = $disk.Name
                DriveLetter   = if ($match) { $match.DriveLetter } else { "NotFound" }
                DiskSizeGB    = $disk.DiskSizeGB
                DiskTier      = $disk.ManagedDisk.StorageAccountType
                LUN           = $disk.Lun
                TotalSizeGB   = if ($match) { $match.TotalSizeGB } else { "N/A" }
                FreeSpaceGB   = if ($match) { $match.FreeSpaceGB } else { "N/A" }
                UsedSpaceGB   = if ($match) { $match.UsedSpaceGB } else { "N/A" }
                Subscription  = $subscription.Name
                ResourceGroup = $vm.ResourceGroupName
            }
        }
    }
}
 
# Track the final export and output path
$finalReport | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
Write-Host "Export complete. File saved to $path" -ForegroundColor Green