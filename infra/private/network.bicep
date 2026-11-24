// Stage 0 for a private substrate-aks install: the VNet, private DNS zones,
// NAT gateway and a jumpbox VM with no public IP. The installer then runs on
// the jumpbox (inside the VNet) with aks.privateNetwork pointing at these IDs.
targetScope = 'subscription'

param location string = 'uksouth'
param networkResourceGroupName string = 'substrate-private-net'
@description('Public key for the jumpbox admin user. The VM has no inbound path; use `az vm run-command` to operate it.')
param adminSshPublicKey string
param jumpboxVmSize string = 'Standard_D2s_v6'
@description('Grant the jumpbox identity Owner on the subscription so the installer can create the resource group and role assignments. Remove after the install.')
param grantJumpboxOwner bool = true

var owner = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')

resource group 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: networkResourceGroupName
  location: location
}

module network 'network-rg.bicep' = {
  name: 'substrate-private-network'
  scope: group
  params: {
    location: location
    adminSshPublicKey: adminSshPublicKey
    jumpboxVmSize: jumpboxVmSize
  }
}

resource jumpboxOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantJumpboxOwner) {
  name: guid(subscription().id, networkResourceGroupName, 'jumpbox-owner')
  properties: {
    principalId: network.outputs.jumpboxPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: owner
  }
}

output aksSubnetId string = network.outputs.aksSubnetId
output endpointSubnetId string = network.outputs.endpointSubnetId
output blobPrivateDnsZoneId string = network.outputs.blobPrivateDnsZoneId
output controlPlaneIdentityId string = network.outputs.controlPlaneIdentityId
output jumpboxName string = network.outputs.jumpboxName
output jumpboxPrincipalId string = network.outputs.jumpboxPrincipalId
output networkResourceGroup string = networkResourceGroupName
