#Connect-AzAccount

$Output = @()
$subscriptions=Get-AzSubscription
#$subscriptions=Get-AzSubscription|Where-Object {('connectivity-prod-ent-001') -contains $_.Name}
#$subscriptions=Get-AzSubscription|Where-Object {$_.State -eq 'Enabled'}|Where-Object Name -NotIn ('connectivity-prod-ent-001','landzone-prod-ent-001')

foreach($Subscription in $Subscriptions) {

Set-AzContext -Subscription $Subscription.Name | Out-Null
Write-Host "Running for subscription: " $Subscription.Name
$UniqueTags=Get-AzTag|select Name
##Get-AzVM |where-object { $_.TimeCreated -gt [datetime]"2023/05/31"}|select-object -ExpandProperty StorageProfile
###[System.Collections.ArrayList]$vms=@(get-azvm)
##$vms[0].id
$ASRDtls=@()
Get-AzRecoveryServicesVault|Where-Object Location -eq 'westus'|%{
Set-AzRecoveryServicesAsrVaultContext -Vault $_ | Out-Null
##Get-AzRecoveryServicesAsrVaultContext
$Rvault=$_.Name
Write-Host "Running for ASR Vault: " $Rvault
$Fabric = Get-AzRecoveryServicesAsrFabric |Where-Object FriendlyName -eq 'East US'
##$Fabric
   foreach($invfabric in $Fabric)
   {
    
    $Container=Get-AzRecoveryServicesAsrProtectionContainer -Fabric $invfabric
    Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $Container|%{
    $AsrInfo=[PSCustomObject]@{
      ##"Fabric"=$invfabric.Name
      "VmName"=$_.FriendlyName
      "ASRVault"=$Rvault
      "ProtectionState"=$_.ProtectionState
      "ReplicationHealth"=$_.ReplicationHealth
      }
     $ASRDtls += $AsrInfo
     }
  }

 }

$BackupDtls=@()
Get-AzRecoveryServicesVault|%{
$Bvault=$_.Name
Write-Host "Running for Backup Vault: " $Bvault
Set-AzRecoveryServicesVaultContext -Vault $_|out-null
$BContainers = Get-AzRecoveryServicesBackupContainer -ContainerType "AzureVM" -VaultId $_.ID
  foreach($BContainer in $BContainers)
  {
    $BackupDtls+=get-azrecoveryservicesbackupitem -Container $BContainer -WorkloadType "AzureVM"|select Name,ProtectionStatus,HealthStatus,LastBackupStatus,LastBackupTime,@{Name='BVault';expression={$Bvault}}
  }
}

Get-AzVM|where-object { $_.TimeCreated -gt [datetime]"2024/07/01" }|%{

$VMName = $_.Name
$ResourceId = $_.Id
$VMTimeCreated= $_.TimeCreated
$VmTag=$_.Tags
$VmResourceGroup=$_.ResourceGroupName
$OSDiskInfo = Get-AzDisk -ResourceGroupName $VmResourceGroup -DiskName $_.StorageProfile.OsDisk.Name
$OSDiskName=$_.StorageProfile.OsDisk.Name
$OSDiskId=$OSDiskInfo.Id
$OSDiskTimeCreated=$OSDiskInfo.TimeCreated 


$ResourceHT = [ordered] @{}
$ResourceHT.Add("Subscription",$Subscription.Name)
$ResourceHT.Add("VM_Name",$VMName)
$ResourceHT.Add("VM_ResourceId",$ResourceId)
$ResourceHT.Add("VM_TimeCreated",$VMTimeCreated)
$ResourceHT.Add("DiskName",$OSDiskName)
$ResourceHT.Add("DiskType","OSDisk")
$ResourceHT.Add("DiskId",$OSDiskId)
$ResourceHT.Add("DiskTimeCreated",$OSDiskTimeCreated)
if(($ASRDtls.Count -gt 0) -and ($ASRDtls.VmName.Contains($VMName)))
{
  $ResourceHT.Add("ASR Configured","YES")
  $ResourceHT.Add("ASRVault",($ASRDtls|where-object VmName -EQ $VMName).ASRVault)
  $ResourceHT.Add("ProtectionState",($ASRDtls|where-object VmName -EQ $VMName).ProtectionState)
  $ResourceHT.Add("ReplicationHealth",($ASRDtls|where-object VmName -EQ $VMName).ReplicationHealth)
}
else
{
  $ResourceHT.Add("ASR Configured","NO")
  $ResourceHT.Add("ASRVault",'-')
  $ResourceHT.Add("ProtectionState",'-')
  $ResourceHT.Add("ReplicationHealth",'-')

}
if(($BackupDtls.Count -gt 0) -and ((($BackupDtls.name) -imatch $VMName).Count -gt 0))
{
     $ResourceHT.Add("Backup Configured","YES")
     $ResourceHT.Add("BackupVault",($BackupDtls|where-object Name -imatch $VMName).BVault)
     $ResourceHT.Add("ProtectionStatus",($BackupDtls|where-object Name -imatch $VMName).ProtectionStatus)
     $ResourceHT.Add("HealthStatus",($BackupDtls|where-object Name -imatch $VMName).HealthStatus)
     $ResourceHT.Add("LastBackupStatus",($BackupDtls|where-object Name -imatch $VMName).LastBackupStatus)
     $ResourceHT.Add("LastBackupTime",($BackupDtls|where-object Name -imatch $VMName).LastBackupTime)
 }
else
{
     $ResourceHT.Add("Backup Configured","NO")
     $ResourceHT.Add("BackupVault",'-')
     $ResourceHT.Add("ProtectionStatus",'-')
     $ResourceHT.Add("HealthStatus",'-')
     $ResourceHT.Add("LastBackupStatus",'-')
     $ResourceHT.Add("LastBackupTime",'-')

}


if ($VmTag.Count -ne 0) {
    $UniqueTags | Foreach-Object{
        if(($VmTag.keys).Contains($_.Name))
          {
              $ResourceHT.Add($_.Name,$VmTag.Item($_.Name))
           }
        }
     }

    $Output += New-Object psobject -Property $ResourceHT
            $_.StorageProfile.DataDisks.Name|
            %{
              $MgDiskName=$_
              if($MgDiskName.Length -gt 0)
              {
               $MgDiskInfo =Get-AzDisk -ResourceGroupName $VmResourceGroup -DiskName $MgDiskName
               $DataDiskId = $MgDiskInfo.Id
               $DataDiskTimeCreated=$MgDiskInfo.TimeCreated

               $ResourceHT = [ordered] @{}
               $ResourceHT.Add("Subscription",$Subscription.Name)
               $ResourceHT.Add("VM_Name",$VMName)
               $ResourceHT.Add("VM_ResourceId",$ResourceId)
               $ResourceHT.Add("VM_TimeCreated",$VMTimeCreated)
               $ResourceHT.Add("DiskName",$MgDiskName)
               $ResourceHT.Add("DiskType","DataDisk")
               $ResourceHT.Add("DiskId",$DataDiskId)
               $ResourceHT.Add("DiskTimeCreated",$DataDiskTimeCreated)
               if(($ASRDtls.Count -gt 0) -and ($ASRDtls.VmName.Contains($VMName)))
               {
                   $ResourceHT.Add("ASR Configured","YES")
                   $ResourceHT.Add("ASRVault",($ASRDtls|where-object VmName -EQ $VMName).ASRVault)
                   $ResourceHT.Add("ProtectionState",($ASRDtls|where-object VmName -EQ $VMName).ProtectionState)
                   $ResourceHT.Add("ReplicationHealth",($ASRDtls|where-object VmName -EQ $VMName).ReplicationHealth)
               }
               else
               {
                   $ResourceHT.Add("ASR Configured","NO")
                   $ResourceHT.Add("ASRVault",'-')
                   $ResourceHT.Add("ProtectionState",'-')
                   $ResourceHT.Add("ReplicationHealth",'-')

               }

if(($BackupDtls.Count -gt 0) -and ((($BackupDtls.name) -imatch $VMName).Count -gt 0))
{
     $ResourceHT.Add("Backup Configured","YES")
     $ResourceHT.Add("ProtectionStatus",($BackupDtls|where-object Name -imatch $VMName).ProtectionStatus)
     $ResourceHT.Add("BackupVault",($BackupDtls|where-object Name -imatch $VMName).BVault)
     $ResourceHT.Add("HealthStatus",($BackupDtls|where-object Name -imatch $VMName).HealthStatus)
     $ResourceHT.Add("LastBackupStatus",($BackupDtls|where-object Name -imatch $VMName).LastBackupStatus)
     $ResourceHT.Add("LastBackupTime",($BackupDtls|where-object Name -imatch $VMName).LastBackupTime)
 }
else
{
     $ResourceHT.Add("Backup Configured","NO")
     $ResourceHT.Add("BackupVault",'-')
     $ResourceHT.Add("ProtectionStatus",'-')
     $ResourceHT.Add("HealthStatus",'-')
     $ResourceHT.Add("LastBackupStatus",'-')
     $ResourceHT.Add("LastBackupTime",'-')

}
               if ($VmTag.Count -ne 0) {
                  $UniqueTags | Foreach-Object{
                    if(($VmTag.keys).Contains($_.Name))
                    {
                     $ResourceHT.Add($_.Name,$VmTag.Item($_.Name))
                    }
                 }
              }
              $Output += New-Object psobject -Property $ResourceHT
           }
         }
      }
}

$Output|sort-object -Property Application,VM_Name|Export-Csv C:\Users\ADprumesh\Desktop\GetNewVM\NewlyCreatedVM12.csv -NoTypeInformation -Encoding UTF8 -Force -Append