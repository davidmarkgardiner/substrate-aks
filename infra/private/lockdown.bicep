// Air-gap lockdown: outbound Internet is denied for the AKS and jumpbox
// subnets, except Azure control-plane/registry service tags and explicit
// extra CIDRs. Attach with:
//   az network vnet subnet update -g <net-rg> --vnet-name substrate-vnet -n <aks|jumpbox> --network-security-group substrate-lockdown
param location string = resourceGroup().location
@description('Extra outbound-allowed IPv4 CIDRs on 443, for example the resolved addresses of an LLM endpoint.')
param extraAllowedCidrs array = []
@description('Azure region name used in regional service tags, for example UKSouth.')
param regionTag string = 'UKSouth'

var azureTags = [
  'AzureActiveDirectory'
  'AzureResourceManager'
  'MicrosoftContainerRegistry'
  'AzureFrontDoor.FirstParty'
  'AzureContainerRegistry.${regionTag}'
  'Storage.${regionTag}'
]

var tagRules = [for (tag, i) in azureTags: {
  name: 'allow-${replace(tag, '.', '-')}'
  properties: {
    priority: 100 + i
    direction: 'Outbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: tag
    destinationPortRange: '443'
  }
}]

var extraRules = empty(extraAllowedCidrs) ? [] : [
  {
    name: 'allow-extra-443'
    properties: {
      priority: 200
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefixes: extraAllowedCidrs
      destinationPortRange: '443'
    }
  }
]

var denyRules = [
  {
    name: 'deny-internet-outbound'
    properties: {
      priority: 4000
      direction: 'Outbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '*'
    }
  }
]

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'substrate-lockdown'
  location: location
  properties: {
    securityRules: concat(tagRules, extraRules, denyRules)
  }
}

output nsgId string = nsg.id
