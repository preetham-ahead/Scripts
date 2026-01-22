Connect-AzAccount
$vault = Get-AzRecoveryServicesVault -ResourceGroupName "rg-d2-p-lzprod-bc-01" -Name "recovery-d2-p-lzprod-bc-t2gainternal"
Set-AzRecoveryServicesAsrVaultContext -Vault $vault
$fabricName = "asr-a2a-default-eastus"
$fabric = Get-AzRecoveryServicesAsrFabric -Name $fabricName
$containers = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric -Name "asr-a2a-default-eastus-container"
$LogStorageAccountId = "/subscriptions/c4464a5d-6eac-4407-a9b9-6fafce1086eb/resourceGroups/rg-d1-p-lzprod-bc-01/providers/Microsoft.Storage/storageAccounts/sad1plzprodrsvcache01"
$SourceDiskId = "/subscriptions/c4464a5d-6eac-4407-a9b9-6fafce1086eb/resourceGroups/RG-D1-P-LZPROD-DB-01/providers/Microsoft.Compute/disks/425tcdmsql-datadisk-05"
$RecoveryResourceGroupId = "/subscriptions/c4464a5d-6eac-4407-a9b9-6fafce1086eb/resourceGroups/rg-d2-p-lzprod-bc-01"
$targetDes = Get-AzDiskEncryptionSet -Name "encset-d2-p-lzprod-sec-01" -ResourceGroupName "rg-d2-p-lzprod-sec-01"


$filePath = "C:\Temp\VaultSettings.json"
$creds = Get-AzRecoveryServicesVaultSettingsFile -Vault $vault -Path $filePath
Import-AzRecoveryServicesAsrVaultSettingsFile -Path $filePath

$protectedItem = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $containers -Name "674d53d8-f22d-4ed6-8419-7ae4518a929c"

$diskIdToDiskEncryptionSetMap = New-Object "System.Collections.Generic.Dictionary``2[System.String,System.String]"
$sourceDiskId = ($protectedItem.ProtectedDisks | Where-Object {$_.DiskName -eq "425tcdmsql-datadisk-05"}).DiskId
$targetDesResourceId = "/subscriptions/c4464a5d-6eac-4407-a9b9-6fafce1086eb/resourceGroups/rg-d2-p-lzprod-sec-01/providers/Microsoft.Compute/diskEncryptionSets/encset-d2-p-lzprod-sec-01"
$diskIdToDiskEncryptionSetMap.Add($sourceDiskId, $targetDesResourceId)
Set-AzRecoveryServicesAsrReplicationProtectedItem -InputObject $protectedItem -DiskIdToDiskEncryptionSetMap $diskIdToDiskEncryptionSetMap

$diskConfig = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk -LogStorageAccountId $LogStorageAccountId -DiskId $SourceDiskId -RecoveryResourceGroupId $RecoveryResourceGroupId -RecoveryDiskEncryptionSetId $targetDES.Id
# Supply Disk SKU values for source and destination (StandardSSD_LRS/Standard_LRS/Premium_LRS)

$job = Add-AzRecoveryServicesAsrReplicationProtectedItemDisk -ReplicationProtectedItem $protectedItem -AzureToAzureDiskReplicationConfiguration $diskConfig
Write-Host "Add disk job started. Job Name: $($job.Name)"
while (($job.State -eq "InProgress") -or ($job.State -eq "NotStarted")) 
{
    Sleep 30
    $job = Get-AzRecoveryServicesAsrJob -Name $job.Name
}
if ($job.State -eq "Succeeded") {
    Write-Host "Disk added successfully and replication enabled."} 
    else {
    Write-Host "Disk addition failed. Job state: $($job.State)" 
    }