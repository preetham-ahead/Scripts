##Connect-AzAccount
#Script will run through all subscriptions
$Output = @()
$UniqueTags = @('Application','Business Criticality','Business Unit','Compliance','Cost Center','Data Sensitivity','Environment','Purpose')
##Get-AzSubscription |where-object Name -In ('connectivity-prod-ent-001')|Select-AzSubscription|ForEach-Object {$_

Get-AzSubscription |Select-AzSubscription|ForEach-Object {$_

$SubscriptionId=(Get-AzContext).Subscription
$SubscriptionName=(Get-AzSubscription -SubscriptionId $SubscriptionId.id).Name
$SubscriptionName
# Initialize output array

##Get-AzTag


# Collect all the resources from the current subscription
$AZResources = Get-AzResource
 
# Obtain a unique list of tags for these groups collectively
##$UniqueTags = $AZResources.Tags.GetEnumerator().Keys | Sort-Object -Unique
 
# Loop through the resources
foreach ($AZResource in $AZResources) {
    # Create a new ordered hashtable and add the normal properties first.
    $ResourceHT = [ordered] @{}
    $ResourceHT.Add("Name",$AZResource.ResourceName)
    $ResourceHT.Add("Location",$AZResource.Location)
    $ResourceHT.Add("Id",$AZResource.ResourceId)
    $ResourceHT.Add("Subscription",$SubscriptionName)
    $ResourceHT.Add("SubscriptionId",$AZResource.SubscriptionId)
    $ResourceHT.Add("ResourceGroupName",$AZResource.ResourceGroupName)
    $ResourceHT.Add("ResourceType",$AZResource.ResourceType)
    $ResourceHT.Add("ParentResource",$AZResource.ParentResource)
    $ResourceHT.Add("ManagedBy",$AZResource.ManagedBy)
    $ResourceHT.Add("Identity",$AZResource.Identity)
    $ResourceHT.Add("Kind",$AZResource.Kind)
 
    # Loop through possible tags adding the property if there is one, adding it with a hyphen as it's value if it doesn't.
    if ($AZResource.Tags.Count -ne 0) {
        $UniqueTags | Foreach-Object {
            if ($AZResource.Tags[$_]) {
                $ResourceHT.Add("$_ (Tag)",$AZResource.Tags[$_])
            }
            else {
                $ResourceHT.Add("$_ (Tag)","-")
            }
        }
    }
    else {
        $UniqueTags | Foreach-Object { $ResourceHT.Add("$_ (Tag)","-") }
    }
 
    # Update the output array, adding the ordered hashtable we have created for the AZResource details.
    $Output += New-Object psobject -Property $ResourceHT 
}
 
# Sent the final output to CSV
} 

$ResourceHT = [ordered] @{}
 $Output|get-member|Where-Object MemberType -EQ 'NoteProperty'|ForEach-Object {

 $ResourceHT.Add($_.Name,'A')

}
$DateTime=(Get-Date).ToString('MMddyyyy_hhmmss')
$Output | Sort-Object -Property Name,Subscription|Export-Csv -Path C:\Users\ADPrUmesh\Desktop\Scripts\AZResources-AllSubscriptions-${DateTime}.csv -NoTypeInformation -Encoding UTF8 -Force 





