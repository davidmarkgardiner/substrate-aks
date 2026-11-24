param location string
param adminSshPublicKey string
param jumpboxVmSize string

var networkContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')

resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'substrate-nat-ip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'substrate-nat'
  location: location
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [{ id: natIp.id }]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'substrate-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.50.0.0/16'] }
    subnets: [
      {
        name: 'aks'
        properties: { addressPrefix: '10.50.0.0/22' }
      }
      {
        name: 'endpoints'
        properties: {
          addressPrefix: '10.50.8.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'jumpbox'
        properties: {
          addressPrefix: '10.50.9.0/24'
          defaultOutboundAccess: false
          natGateway: { id: nat.id }
        }
      }
    ]
  }
}

resource blobZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

resource blobLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: blobZone
  name: 'substrate-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

// AKS control-plane identity, pre-granted on the VNet so the cluster can use
// the pre-created subnet.
resource controlPlane 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'substrate-aks-control'
  location: location
}

resource controlPlaneNetwork 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vnet.id, controlPlane.id, networkContributor)
  scope: vnet
  properties: {
    principalId: controlPlane.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributor
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'substrate-jumpbox-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/jumpbox' }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource jumpbox 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: 'substrate-jumpbox'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: jumpboxVmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    osProfile: {
      computerName: 'substrate-jumpbox'
      adminUsername: 'azureuser'
      customData: loadFileAsBase64('jumpbox-cloud-init.yaml')
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/azureuser/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
  }
}

output aksSubnetId string = '${vnet.id}/subnets/aks'
output endpointSubnetId string = '${vnet.id}/subnets/endpoints'
output blobPrivateDnsZoneId string = blobZone.id
output controlPlaneIdentityId string = controlPlane.id
output jumpboxName string = jumpbox.name
output jumpboxPrincipalId string = jumpbox.identity.principalId
