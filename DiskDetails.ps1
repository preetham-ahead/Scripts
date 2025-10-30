<#
    Script Name: Disk.ps1
    Version: 2.1.0
    Last Updated: 2024-11-08
    Author: Preetham Umesh - AHEAD

    Description: This script is designed to run on azure cloudshell and is used to
    query all managed disks in azure and gather it's performance metrics like IOPS,
    bandwidth, disk tier, allocated size etc. The script was developed to analyze 
    current disk allocation and resize SKU for cost savings.

#>


param (
    [Parameter(Mandatory = $true, HelpMessage = "Enter you Azure Subscription Id")]
    [ValidateNotNullOrEmpty()]
    [ValidateScript(
        { $null -ne (Get-AzSubscription -SubscriptionId $_ -WarningAction silentlyContinue) },
        ErrorMessage = "Subscription was not found in tenant {0} . Please verify that the subscription exists in the signed-in tenant."
    )]
    [string]
    $subscriptionId,
    [Parameter(HelpMessage = "(Optional) Enter your Resource Group Name")]
    [string]
    $resourceGroupName
)

# # Connect to your Azure account
# Connect-AzAccount

# Connect to your Azure account
Set-AzContext -Subscription $subscriptionId

# Install the Azure PowerShell module if it's not already installed
if (-not(Get-Module Az.Accounts)) {
    Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
}

if (-not [string]::IsNullOrEmpty($resourceGroupName)) {
    if (Get-AzResourceGroup -name $resourceGroupName -WarningAction silentlyContinue) {
        $virtualMachines = Get-AzVM -ResourceGroupName $resourceGroupName
    } else {
        Write-Host "The Resource Group Name entered does not exist" -ForegroundColor Red
        Exit
    }
} else {
    # Get all the virtual machines in your subscription
    $virtualMachines = Get-AzVM 
    Write-Host "#_________________________________________________________"
    Write-Host "# No Resource Group Selected, All Virtual Machine info in the subscription will be collected" -ForegroundColor Yellow
}


# Initialize an array to store the data disk information
$dataDiskInfoTSDictionary = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()
################################################

# Loop through each virtual machine
$virtualMachines | ForEach-Object -Parallel {
    $vm = $_
    $subscriptionId = $using:subscriptionId
    $resourceGroupName = $using:resourceGroupName
    $dataDiskInfoTSDictionary = $using:dataDiskInfoTSDictionary

     # Get the data disks attached to the virtual machine
     $dataDisks = $vm.StorageProfile.DataDisks

     $dataDisks | ForEach-Object -Parallel {
         $dataDisk = $_
             
         $subscriptionId = $using:subscriptionId
         $resourceGroupName = $using:resourceGroupName
         $vm = $using:vm
         $dataDiskInfoTSDictionary = $using:dataDiskInfoTSDictionary


        # Get the size, IOPS, and bandwidth of the data disk
        $diskSize = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $dataDisk.Name | Select-Object -ExpandProperty DiskSizeGB
        $diskIops = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $dataDisk.Name | Select-Object -ExpandProperty DiskIOPSReadWrite
        $diskBandwidth = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $dataDisk.Name | Select-Object -ExpandProperty DiskMBpsReadWrite
        $diskSKU = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $dataDisk.Name | Select-Object -ExpandProperty Sku | Select-Object -ExpandProperty Name
        $resourceGroup = $vm.ResourceGroupName
        $dataDiskName = $dataDisk.Name
        $location = $vm.Location
        $operatingSystem = $vm.StorageProfile.OsDisk.OsType

        #Get Network Info
        $vmnic = ($vm.NetworkProfile.NetworkInterfaces.id).Split('/')[-1]
        $vmnicinfo = Get-AzNetworkInterface -Name $vmnic
        $vmvnet = $((($vmnicinfo.IpConfigurations.subnet.id).Split('/'))[-3])

        # Check if VM is deplyed in availabilityZone or None
        $availabilityZone = $vm.Zones
        if ([string]::IsNullOrWhiteSpace($availabilityZone)) {
            $availabilityZone = "No Zone"
        } else {
            $availabilityZone = $vm.Zones | Select-Object -Index 0
        }

        # Get consumed utilized storage IO (IOPS,BW) for the data disk

            ## Specify the time range for the metrics data
        $startTime = (Get-Date).AddDays(-30)  # Start time (e.g., 24 hours ago) <<- Change to number of days or switch to hours .AddHours(-24)
        # $endTime = Get-Date                    # End time (current time)
        $TimeGrain = [TimeSpan]::Parse("1:00:00")
        $MetricName = @("Composite Disk Write Operations/sec", "Composite Disk Read Operations/sec", "Composite Disk Read Bytes/sec", "Composite Disk Write Bytes/sec")

            ## Get the consumed metrics for the managed disk
        $metrics = Get-AzMetric `
            -ResourceId "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Compute/disks/$dataDiskName" `
            -StartTime $startTime `
            -TimeGrain $TimeGrain `
            -MetricNames $MetricName `
            -WarningAction silentlyContinue

        foreach ($Metric in $metrics)
        {
            $Results += $Metric.Data | Select-Object TimeStamp, Average, @{Name="Metric"; Expression={$Metric.Name.Value}}
        }
        ################################################
                    # -AggregationType Average `
                    # -TimeGrain $TimeGrain `
        # $Results | Sort-Object -Property TimeStamp, Metric | Format-Table
        $disk_IOPS_read_Max = ($Results | Where-Object { $_.Metric -eq "Composite Disk Read Operations/sec" } | Measure-Object -Property Average -Maximum).Maximum 
        $disk_IOPS_write_Max = ($Results | Where-Object { $_.Metric -eq "Composite Disk Write Operations/sec" } | Measure-Object -Property Average -Maximum).Maximum  
        #$disk_BW_read_Avg = ($Results | Where-Object { $_.Metric -eq "Composite Disk Read Bytes/sec" } | Measure-Object -Property Average -Average).Average 
        $disk_BW_read_Max = ($Results | Where-Object { $_.Metric -eq "Composite Disk Read Bytes/sec" } | Measure-Object -Property Average -Maximum).Maximum 
        #$disk_BW_write_Avg = ($Results | Where-Object { $_.Metric -eq "Composite Disk Write Bytes/sec" } | Measure-Object -Property Average -Average).Average  
        $disk_BW_write_Max = ($Results | Where-Object { $_.Metric -eq "Composite Disk Write Bytes/sec" } | Measure-Object -Property Average -Maximum).Maximum  


        # Check if the same data disk has already been added
        $existingDisk = $dataDiskInfo | Where-Object { $_.DataDiskName -eq $dataDisk.Name }
        if ($existingDisk) {
            # Update the existing disk information with the latest values
            $existingDisk.SizeGB = $diskSize
            $existingDisk.Provisioned_IOPS = $diskIops
            $existingDisk.Provisioned_BW_MBps = $diskBandwidth
        }
        else {
            # Create a hashtable to store the data disk information
            $dataDiskHashtable = @{
                VMName = $vm.Name
                DataDiskName = $dataDiskName
                SizeGB = $diskSize
                Provisioned_IOPS = $diskIops 
                Provisioned_BW_MBps = $diskBandwidth 
                DiskSKU =  $diskSKU
                AvailabilityZone = $availabilityZone
                OperatingSystem = $operatingSystem
                Location = $location
                Utilized_Read_IOPS = $disk_IOPS_read_Max
                Utilized_Write_IOPS = $disk_IOPS_write_Max 
                #Utilized_Read_Avg_BW_MBps = $disk_BW_read_Avg / 1MB
                Utilized_Read_Max_BW_MBps = $disk_BW_read_Max / 1MB
                #Utilized_Write_Avg_BW_MBps = $disk_BW_write_Avg / 1MB
                Utilized_Write_Max_BW_MBps = $disk_BW_write_Max / 1MB
                VirtualNetwork = $vmvnet
            }

            # Add the hashtable to the array
            $outputObject = New-Object -TypeName PSObject -Property $dataDiskHashtable
            $dataDiskInfoTSDictionary[$dataDisk.Name] = $outputObject;
        }
    }
}
################################################

# Display the data disk information as a table
$dataDiskInfoTSDictionary.Values | Format-Table VMName, Location, AvailabilityZone, OperatingSystem, DataDiskName, DiskSKU, SizeGB, Provisioned_IOPS, Utilized_Read_IOPS, Utilized_Write_IOPS, Provisioned_BW_MBps, Utilized_Read_Avg_BW_MBps, Utilized_Read_Max_BW_MBps, Utilized_Write_Avg_BW_MBps, Utilized_Write_Max_BW_MBps, VirtualNetwork

$reportName = "AzureDataDisk.csv"
$dataDiskInfoTSDictionary.Values  | Export-csv .\$reportName



For all subscription ID.. Paste the below script in black screen and then run the command in blue one : 
./Automate-AzDataDisk-Storage-IO-BW.ps1 


# Array of subscription IDs
$subscriptionIds = @(
    "c4464a5d-6eac-4407-a9b9-6fafce1086eb",
    "3d0d5d6e-e792-4473-bac4-710a6867edfc",
    "66649cd4-be10-4cae-9e3a-b6696460f9f0",
    "9b7ca093-85bf-4634-8ff5-9c509606e5af",
    "2cf8dbb5-8708-40ee-92a9-089714260fbd",
    "354c53a6-45f8-49c8-ad6e-4cbd5fc578f6",
    "e3f7401b-554b-40d2-9234-1f2c8f6e2439",
    "fcfcaa65-27bf-4965-80ef-350eb863744e",
    "4def8413-d6b5-445a-9a80-84d122c5464b",
    "b69aab00-5450-4a61-989e-0af16401e9e9",
    "e759fb00-b4cb-47a9-8f5b-112720a2a8f5",
    "15a10332-e234-483c-b5f8-98c893e1bded",
    "325841e1-5f9d-4828-9042-02c0afe1fa43"
)
 
# Loop through each subscription ID and execute the script
foreach ($subscriptionId in $subscriptionIds) {
    # Run the PowerShell script for the current subscription ID
    & "./Get-AzDataDisk-Storage-IO-BW.ps1" -subscriptionId $subscriptionId
 
    # Check if the AzureDataDisk.csv file exists
    $csvFilePath = "AzureDataDisk.csv"
    if (Test-Path $csvFilePath) {
        # Rename the CSV file to the subscription ID's name
        $newFileName = "$subscriptionId.csv"
        Rename-Item -Path $csvFilePath -NewName $newFileName
        Write-Host "Renamed AzureDataDisk.csv to $newFileName"
    } else {
        Write-Host "AzureDataDisk.csv not found for subscription $subscriptionId"
    }

}
