# Define variables
$subscriptionId = "91d66003-967d-4eef-a9b5-bdfadc906c98"
$wrongTagKey = " Business Unit"
$newTagKey = "Business Unit"
 
# Select the subscription
Select-AzSubscription -SubscriptionId $subscriptionId
 
# Get all resources in the subscription
$resources = Get-AzResource -ResourceType *
 
foreach ($resource in $resources) {
    # Check if the resource has the wrong tag key
    if ($resource.Tags.ContainsKey($wrongTagKey)) {
        # Get the value of the wrong tag key
        $tagValue = $resource.Tags[$wrongTagKey]
        # Remove the wrong tag key
        $resource.Tags.Remove($wrongTagKey)
 
        # Add the new tag key with the value from the wrong tag key
        $resource.Tags[$newTagKey] = $tagValue
 
        # Update the resource with the new tags
        try {
            Set-AzResource -ResourceId $resource.ResourceId -Tag $resource.Tags -Force -ErrorAction Stop
            Write-Output "Successfully updated tags for resource: $($resource.Name) with ResourceId: $($resource.ResourceId)"
        } catch {
            Write-Output "Failed to update tags for resource: $($resource.Name) with ResourceId: $($resource.ResourceId). Error: $_"
        }
    } else {
        Write-Output "Resource $($resource.Name) does not have the tag key $wrongTagKey"
    }
}
 
Write-Output "Tag key replacement completed."