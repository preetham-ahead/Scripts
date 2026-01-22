# -----------------------------------------
# Azure Disk Encryption Status Report
# Across Selected Subscriptions
# -----------------------------------------
 
# Login
Connect-AzAccount
 
# List of subscription IDs (add your 29 here)
$subscriptionList = @(
"242ea273-f410-4701-9f78-f9d5d1bf4788",
"325841e1-5f9d-4828-9042-02c0afe1fa43",
"15a10332-e234-483c-b5f8-98c893e1bded",
"ccdaa912-583c-4bae-9d31-8dbb7856f763",
"0273fdc3-4cbc-4c1c-940d-3b46e56ae333",
"c897867e-5a88-4dda-a0a7-fbab47742925",
"3d0d5d6e-e792-4473-bac4-710a6867edfc",
"0440ef6c-4bdb-486d-8ae1-530547560c79",
"66649cd4-be10-4cae-9e3a-b6696460f9f0",
"76569fbe-c870-4d4e-9359-6376262f21e1",
"86a9be82-dae6-44e6-9b96-7b7433356db3",
"c5a9f5d6-1aa1-44ad-bcec-36217430cd77",
"b69aab00-5450-4a61-989e-0af16401e9e9",
"c4464a5d-6eac-4407-a9b9-6fafce1086eb",
"e759fb00-b4cb-47a9-8f5b-112720a2a8f5",
"dadca81d-8560-4826-acae-3be792ac93e9",
"8470cb56-e408-4906-a871-b677ded674b1",
"eacb2b72-994c-4e85-a8ae-ba2594545d00",
"9b7ca093-85bf-4634-8ff5-9c509606e5af",
"2cf8dbb5-8708-40ee-92a9-089714260fbd",
"354c53a6-45f8-49c8-ad6e-4cbd5fc578f6",
"e3f7401b-554b-40d2-9234-1f2c8f6e2439",
"4def8413-d6b5-445a-9a80-84d122c5464b",
"fcfcaa65-27bf-4965-80ef-350eb863744e",
"b9c9a7fe-21f0-4e36-bbda-fd41076dc69f"
)
 
# Storage for results
$results = @()
 
foreach ($sub in $subscriptionList) {
 
    Write-Host "Processing subscription: $sub" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub | Out-Null
 
    $vms = Get-AzVM
 
    foreach ($vm in $vms) {
 
        # ----- OS Disk -----
        $osDisk = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $vm.StorageProfile.OsDisk.Name
 
        $results += [PSCustomObject]@{
            SubscriptionId   = $sub
            ResourceGroup    = $vm.ResourceGroupName
            VMName           = $vm.Name
            DiskType         = "OSDisk"
            DiskName         = $osDisk.Name
            Location         = $vm.Location
            OsType           = $vm.StorageProfile.OsDisk.OsType
            EncryptionType   = $osDisk.Encryption.Type
            DESId            = $osDisk.Encryption.DiskEncryptionSetId
            CMK_Enabled      = if ($osDisk.Encryption.Type -like "*cmk*" -or $osDisk.Encryption.DiskEncryptionSetId) { "True" } else { "False" }
          }
    }
}
 
$exportPath = "C:\Users\ADPrUmesh\Desktop\Scripts\AzureDiskEncryptionReport_OS.csv"
$results | Export-Csv -Path $exportPath -NoTypeInformation -Force
 
Write-Host "`nReport generated:" -ForegroundColor Green
Write-Host $exportPath -ForegroundColor Yellow