param(

    [string]$VMName,

    [string]$VMResourceGroup,

    [string]$VaultName,

    [string]$VaultResourceGroup,

    [string]$FabricName,

    [string]$ContainerName,

    [string]$LogStorageAccountId,

    [string]$RecoveryResourceGroupId,

    [string]$RecoveryDiskEncryptionSetId

)
 
Write-Host "Starting ASR Repair for VM: $VMName"
 
#Connect-AzAccount
 
# Vault Context

$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroup -Name $VaultName

Set-AzRecoveryServicesAsrVaultContext -Vault $vault
 
$fabric = Get-AzRecoveryServicesAsrFabric | Where-Object {
    $_.FabricType -eq "Azure"
}
 
if (-not $fabric) {
    throw "Azure Fabric not found."
}
 
# Get protection container WITHOUT Select-Object
$containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric
 
if ($containers.Count -eq 0) {
    throw "No protection containers found."
}
 
$container = $containers[0]
 
# Validate object type
if ($container -isnot [Microsoft.Azure.Commands.RecoveryServices.SiteRecovery.ASRProtectionContainer]) {
    throw "Container object is not valid type."
}
 
$protectedItem = Get-AzRecoveryServicesAsrReplicationProtectedItem `

    -ProtectionContainer $container `

    -Name $VMName
 
if (-not $protectedItem) {

    throw "Protected item not found."

}
 
$vm = Get-AzVM -Name $VMName -ResourceGroupName $VMResourceGroup
 
# Collect VM Disk IDs

$vmDiskIds = @()

$vmDiskIds += $vm.StorageProfile.OsDisk.ManagedDisk.Id

$vm.StorageProfile.DataDisks | ForEach-Object {

    $vmDiskIds += $_.ManagedDisk.Id

}
 
# ASR Disk IDs

$asrDisks = $protectedItem.ProtectedDisks
 
$mismatchedDisks = @()
 
foreach ($disk in $asrDisks) {

    if ($disk.DiskId -notin $vmDiskIds) {

        $mismatchedDisks += $disk

    }

}
 
if ($mismatchedDisks.Count -eq 0) {

    Write-Host "No disk mismatch detected. Replication healthy."

    return

}
 
Write-Host "$($mismatchedDisks.Count) mismatched disk(s) detected."
 
# OS-only VM check

if ($vm.StorageProfile.DataDisks.Count -eq 0) {
 
    Write-Host "OS-only VM detected."
 
    try {

        Write-Host "Attempting Protection Direction Update..."

        Update-AzRecoveryServicesAsrProtectionDirection `

            -ReplicationProtectedItem $protectedItem `

            -Direction PrimaryToRecovery `

            -AzureToAzure `

            -LogStorageAccountId $LogStorageAccountId
 
        Write-Host "Protection direction update triggered."

        return

    }

    catch {

        Write-Host "Direction update failed. Proceeding with reprotect."

        Disable-AzRecoveryServicesAsrReplicationProtectedItem `

            -ReplicationProtectedItem $protectedItem `

            -Force
 
        Write-Host "Replication disabled. Re-enabling..."
 
        New-AzRecoveryServicesAsrReplicationProtectedItem `

            -AzureToAzure `

            -Name $VMName `

            -ProtectionContainer $container `

            -PolicyId $protectedItem.PolicyId `

            -PrimaryResourceGroupId $vm.ResourceGroupId `

            -RecoveryResourceGroupId $RecoveryResourceGroupId `

            -LogStorageAccountId $LogStorageAccountId
 
        Write-Host "Reprotection initiated."

        return

    }

}
 
# Multi-disk scenario

foreach ($disk in $mismatchedDisks) {
 
    Write-Host "Removing disk: $($disk.DiskName)"
 
    $removeJob = Remove-AzRecoveryServicesAsrReplicationProtectedItemDisk `

        -ReplicationProtectedItem $protectedItem `

        -DiskId $disk.DiskId
 
    while (($removeJob.State -eq "InProgress") -or ($removeJob.State -eq "NotStarted")) {

        Start-Sleep -Seconds 30

        $removeJob = Get-AzRecoveryServicesAsrJob -Name $removeJob.Name

    }
 
    if ($removeJob.State -ne "Succeeded") {

        throw "Failed removing disk $($disk.DiskName)"

    }
 
    # Match new disk by name

    $newDiskId = $null
 
    if ($vm.StorageProfile.OsDisk.Name -like "$($disk.DiskName)*") {

        $newDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id

    }

    else {

        $match = $vm.StorageProfile.DataDisks | Where-Object {

            $_.Name -like "$($disk.DiskName)*"

        }

        if ($match) {

            $newDiskId = $match.ManagedDisk.Id

        }

    }
 
    if (-not $newDiskId) {

        throw "Unable to find matching restored disk."

    }
 
    Write-Host "Re-adding disk: $($disk.DiskName)"
 
    $diskConfig = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig `

        -ManagedDisk `

        -DiskId $newDiskId `

        -LogStorageAccountId $LogStorageAccountId `

        -RecoveryResourceGroupId $RecoveryResourceGroupId `

        -RecoveryDiskEncryptionSetId $RecoveryDiskEncryptionSetId
 
    $addJob = Add-AzRecoveryServicesAsrReplicationProtectedItemDisk `

        -ReplicationProtectedItem $protectedItem `

        -AzureToAzureDiskReplicationConfiguration $diskConfig
 
    while (($addJob.State -eq "InProgress") -or ($addJob.State -eq "NotStarted")) {

        Start-Sleep -Seconds 30

        $addJob = Get-AzRecoveryServicesAsrJob -Name $addJob.Name

    }
 
    if ($addJob.State -ne "Succeeded") {

        throw "Failed re-adding disk $($disk.DiskName)"

    }
 
    Write-Host "Disk $($disk.DiskName) repaired."

}
 
Write-Host "All mismatched disks repaired successfully."
 
# Final Health Check

$finalState = (Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container -Name $VMName).Health
 
Write-Host "Final Replication Health: $finalState"

 