<#
    Script Name: DiskLUNMap.ps1
    Version: 2.0.0
    Last Updated: 2025-10-06
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
 
# Define allowed subscriptions (only these will be processed)
$targetSubscriptionIds = @(
    "242ea273-f410-4701-9f78-f9d5d1bf4788",
    "325841e1-5f9d-4828-9042-02c0afe1fa43",
    "15a10332-e234-483c-b5f8-98c893e1bded",
    "ccdaa912-583c-4bae-9d31-8dbb7856f763",
    "c897867e-5a88-4dda-a0a7-fbab47742925",
    "3d0d5d6e-e792-4473-bac4-710a6867edfc",
    "0440ef6c-4bdb-486d-8ae1-530547560c79",
    "66649cd4-be10-4cae-9e3a-b6696460f9f0",
    "547f24d3-6c9a-4a28-8b57-b15e2984fef9",
    "db7c19f5-bea7-44ca-9a52-7c5a3ef73f71",
    "76569fbe-c870-4d4e-9359-6376262f21e1",
    "86a9be82-dae6-44e6-9b96-7b7433356db3",
    "c5a9f5d6-1aa1-44ad-bcec-36217430cd77",
    "b69aab00-5450-4a61-989e-0af16401e9e9",
    "c4464a5d-6eac-4407-a9b9-6fafce1086eb",
    "e759fb00-b4cb-47a9-8f5b-112720a2a8f5",
    "dadca81d-8560-4826-acae-3be792ac93e9",
    "9b7ca093-85bf-4634-8ff5-9c509606e5af",
    "2cf8dbb5-8708-40ee-92a9-089714260fbd",
    "354c53a6-45f8-49c8-ad6e-4cbd5fc578f6",
    "e3f7401b-554b-40d2-9234-1f2c8f6e2439",
    "4def8413-d6b5-445a-9a80-84d122c5464b",
    "fcfcaa65-27bf-4965-80ef-350eb863744e",
    "b9c9a7fe-21f0-4e36-bbda-fd41076dc69f",
    "08a7c685-a9b3-4692-89c5-ee656d7924df"
)
 
# Get only those subscriptions
$subscriptions = Get-AzSubscription | Where-Object { $_.Id -in $targetSubscriptionIds }

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