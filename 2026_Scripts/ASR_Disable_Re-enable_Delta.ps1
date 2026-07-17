# ==============================================================================
# 1. CONFIGURATION - VERIFY THESE BEFORE RUNNING
# ==============================================================================
$SubId          = "3d0d5d6e-e792-4473-bac4-710a6867edfc"
$VaultName      = "cenlar-dr-recovery-vault"
$VaultRG        = "cenlar-dr-backup-rg"
$VMName         = "D1WIN06P"
$SourceRG       = "cenlar-prod-citrix-rg"
$TargetRGId     = "/Subscriptions/$SubId/resourceGroups/cenlar-dr-backup-rg"
$FabricName     = "asr-a2a-default-eastus"
$ContainerName  = "asr-a2a-default-eastus-container"

# ==============================================================================
# 2. SETUP CONTEXT & CAPTURE SETTINGS
# ==============================================================================
Set-AzContext -SubscriptionId $SubId
$Vault = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $VaultRG
Set-AzRecoveryServicesAsrVaultContext -Vault $Vault

$Fabric    = Get-AzRecoveryServicesAsrFabric -Name $FabricName
$Container = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $Fabric -Name $ContainerName
$RPI       = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $Container | Where-Object { $_.FriendlyName -eq $VMName }

if (-not $RPI) { throw "VM $VMName not found in ASR. Check if already disabled." }

# Capture mapping and cache storage for the re-enable step
$Mapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $Container | Select-Object -First 1
$CacheStorage = Get-AzStorageAccount -ResourceGroupName $VaultRG | Where-Object { $_.StorageAccountName -like "*asr*" -or $_.StorageAccountName -like "*cache*" } | Select-Object -First 1

# ==============================================================================
# 3. DISABLE REPLICATION (CLEAR DISK ID BLOCK)
# ==============================================================================
Write-Host "Step 1/3: Disabling replication for $VMName to clear stale Disk IDs..." -ForegroundColor Yellow
$DisableJob = Remove-AzRecoveryServicesAsrReplicationProtectedItem -ReplicationProtectedItem $RPI

while ($DisableJob.State -in @("InProgress", "NotStarted")) {
    Write-Host "Waiting for Disable Job ($($DisableJob.State))..." -ForegroundColor Gray
    Start-Sleep -Seconds 20
    $DisableJob = Get-AzRecoveryServicesAsrJob -Job $DisableJob
}

if ($DisableJob.State -ne "Succeeded") { throw "Disable job failed. Check ASR Jobs in Portal." }

Write-Host "Waiting 2 minutes for Azure backend to purge metadata..." -ForegroundColor Cyan
Start-Sleep -Seconds 120

# ==============================================================================
# 4. RE-ENABLE REPLICATION (TRIGGER DELTA SYNC)
# ==============================================================================
Write-Host "Step 2/3: Re-enabling replication for $VMName..." -ForegroundColor Cyan
$VM = Get-AzVM -ResourceGroupName $SourceRG -Name $VMName

$EnableJob = New-AzRecoveryServicesAsrReplicationProtectedItem `
    -AzureToAzure `
    -AzureVmId $VM.Id `
    -Name $VM.Name `
    -ProtectionContainerMapping $Mapping `
    -RecoveryResourceGroupId $TargetRGId `
    -LogStorageAccountId $CacheStorage.Id

# ==============================================================================
# 5. MONITORING LOOP
# ==============================================================================
Write-Host "Step 3/3: Monitoring Initial Replication (Consistency Check)..." -ForegroundColor Green

do {
    # Refresh RPI object to get latest health/progress
    $CurrentRPI = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $Container | Where-Object { $_.FriendlyName -eq $VMName }
    
    $Health = $CurrentRPI.ReplicationHealth
    $Status = $CurrentRPI.ProtectionState
    # Progress is often found in the provider-specific details for A2A
    $Progress = $CurrentRPI.ReplicationHealthErrors[0].HealthErrorDetails # Fallback for detailed errors
    
    Clear-Host
    Write-Host "Monitoring ASR Sync for: $VMName" -ForegroundColor Cyan
    Write-Host "------------------------------------"
    Write-Host "Current Health: $Health" -ForegroundColor (if($Health -eq "Normal"){"Green"}else{"Yellow"})
    Write-Host "Status:         $Status"
    Write-Host "Last Refreshed: $(Get-Date)"
    
    if ($Status -eq "Protected") {
        Write-Host "`nSUCCESS: Replication is Healthy and Protected!" -ForegroundColor Green
        break
    }

    Start-Sleep -Seconds 60
} while ($true)
