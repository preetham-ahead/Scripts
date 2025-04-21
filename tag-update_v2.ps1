# Connect to Azure account
#Connect-AzAccount
 
# Path to the CSV file
$csvFilePath = "C:\Users\ADPrUmesh\Documents\tags.csv"
$subscriptionId = "3d0d5d6e-e792-4473-bac4-710a6867edfc"
Select-AzSubscription -SubscriptionId $subscriptionId
 
# Read CSV file
$tagsData = Import-Csv -Path $csvFilePath
 
# Define the parallel script block
$scriptBlock = {
    param (
        $row
    )
 
    # Extract the resourceId
    $resourceId = $row.resourceId
    # Extract tags from the row, ignoring the resourceId column
    $tags = @{}
    foreach ($column in $row.PSObject.Properties) {
        if ($column.Name -ne 'resourceId') {
            $tags[$column.Name] = $column.Value
        }
    }
 
    try {
        # Remove existing tags
        $existingTags = (Get-AzTag -ResourceId $resourceId).Tags
        if ($existingTags) {
            Remove-AzTag -ResourceId $resourceId -Tag $existingTags.Keys
        }
 
        # Set new tags from the CSV
        Set-AzTag -ResourceId $resourceId -Tag $tags -Operation Replace
        Write-Host "Successfully updated tags for resource: $resourceId"
    } catch {
        Write-Host "Failed to update tags for resource: $resourceId. Error: $_"
    }
}