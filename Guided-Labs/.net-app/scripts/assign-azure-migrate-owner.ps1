# CloudLabs PowerShellV2 deployment script - Azure-Migrate-Owner, Run = Per User
# Injected parameters (no param() block - it would shadow them with $null):
#   $userobjectid   GET-AZUSER-OBJECTID
#   $deploymentid   GET-DEPLOYMENT-ID
#   $subscriptionid GET-SUBSCRIPTION
#
# Kept deliberately lean: every extra ARM round trip pushes the invocation closer to the
# CloudLabs caller timeout ("One or more errors occurred.").

$ErrorActionPreference = 'Stop'

# GUID rather than -RoleDefinitionName "Azure Migrate Owner": the name form costs an
# extra ARM lookup, and this script is already close to the CloudLabs caller timeout.
$roleDefinitionId = 'fd8ea4d5-6509-4db0-bada-356ab233b4fa'   # Azure Migrate Owner
$scope = "/subscriptions/$subscriptionid/resourceGroups/hands-on-lab-$deploymentid"

Write-Host "User=$userobjectid Scope=$scope"

# The managed identity does not default to the lab subscription.
Select-AzSubscription -SubscriptionId $subscriptionid -ErrorAction Stop | Out-Null

try {
    New-AzRoleAssignment -ObjectId $userobjectid `
                         -RoleDefinitionId $roleDefinitionId `
                         -Scope $scope `
                         -ErrorAction Stop | Out-Null
    Write-Host "Assigned Azure Migrate Owner to $userobjectid"
}
catch {
    # Re-runs are expected (per-user script, retried deployments) - existing is success.
    if ($_.Exception.Message -match 'already exists|RoleAssignmentExists|Conflict') {
        Write-Host "Assignment already present - nothing to do."
    }
    else {
        Write-Host "FAILED: $($_.Exception.Message)"
        throw
    }
}