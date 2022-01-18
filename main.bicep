@description('Location for the resources.')
param location string

@description('User name for the Virtual Machine.')
param adminUsername string

@allowed([
  'password'
  'sshPublicKey'
])
@description('Type of authentication to use on the Virtual Machine.')
param authenticationType string

@secure()
@description('Password or ssh key for the Virtual Machine.')
param adminPasswordOrKey string

@description('virtualNetwork properties from VirtualNetworkCombo')
param virtualNetwork object

// tailscale 
@description('tailscale VM size choice')
param vmSizeSelector string

@description('tailscale VM Name')
param tsVmName string

@description('tailscale Pre-Auth Key')
param tsPreAuthKey string

@description('tailscale Routed Subnets')
param tsRoutedSubnets string = ''

@description('tags from TagsByResource')
param tagsByResource object

var cloudInit = loadFileAsBase64('cloud-init.template.yml')

var linuxConfiguration = {
  disablePasswordAuthentication: true
  ssh: {
    publicKeys: [
      {
        path: '/home/${adminUsername}/.ssh/authorized_keys'
        keyData: adminPasswordOrKey
      }
    ]
  }
}

var tssubnetId = virtualNetwork.newOrExisting == 'new' ? tssubnet.id : resourceId(virtualNetwork.resourceGroup, 'Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, virtualNetwork.subnets.tsSubnet.name)


// Resource Creation
resource vnet 'Microsoft.Network/virtualNetworks@2020-11-01' = if (virtualNetwork.newOrExisting == 'new') {
  name: virtualNetwork.name
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: virtualNetwork.addressPrefixes
    }
  }
  tags: contains(tagsByResource, 'Microsoft.Network/virtualNetworks') ? tagsByResource['Microsoft.Network/virtualNetworks'] : null
}

resource tssubnet 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' = if (virtualNetwork.newOrExisting == 'new') {
  name: virtualNetwork.subnets.tsSubnet.name
  parent: vnet
  properties: {
    addressPrefix: virtualNetwork.subnets.tsSubnet.addressPrefix
  }
}

resource tsnsg 'Microsoft.Network/networkSecurityGroups@2020-11-01' = {
  name: '${tsVmName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Block SSH'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
  tags: contains(tagsByResource, 'Microsoft.Network/networkSecurityGroups') ? tagsByResource['Microsoft.Network/networkSecurityGroups'] : null
}

/*
  tailscale gateway
*/

resource tspip 'Microsoft.Network/publicIPAddresses@2020-11-01' = {
  name: '${tsVmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  zones: [
    '1'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: tsVmName
    }
  }
  tags: contains(tagsByResource, 'Microsoft.Network/publicIpAddresses') ? tagsByResource['Microsoft.Network/publicIpAddresses'] : null
}

resource tsnic 'Microsoft.Network/networkInterfaces@2020-11-01' = {
  name: '${tsVmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: '${tsVmName}-ipconfig'
        properties: {
          subnet: {
            id: tssubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: tspip.id
          }
        }
      }
    ]
    enableAcceleratedNetworking: false
  }
  tags: contains(tagsByResource, 'Microsoft.Network/networkInterfaces') ? tagsByResource['Microsoft.Network/networkInterfaces'] : null
}

resource tsvm 'Microsoft.Compute/virtualMachines@2020-12-01' = {
  name: tsVmName
  location: location
  zones: [
    '1'
  ]
  properties: {
    hardwareProfile: {
      vmSize: vmSizeSelector
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        name: '${tsVmName}-osDisk'
      }
      imageReference: {
        publisher: 'Canonical'
        offer: 'UbuntuServer'
        sku: '18.04-LTS'
        version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: tsnic.id 
        }
      ]
    }
    osProfile: {
      computerName: tsVmName
      adminUsername: adminUsername
      adminPassword: adminPasswordOrKey
      linuxConfiguration: any(authenticationType == 'password' ? null : linuxConfiguration) // TODO: workaround for https://github.com/Azure/bicep/issues/449
      customData: format(cloudInit, tsPreAuthKey, tsRoutedSubnets)
    }
  }
  tags: contains(tagsByResource, 'Microsoft.Compute/virtualMachines') ? tagsByResource['Microsoft.Compute/virtualMachines'] : null
}

/*

# cloud-init
users:
  - default
  - name: {0}
    groups: sudo {1}
    shell: {2}

var values = {
  username: 'mikael'
  groups: ''
  shell: '/bin/bash'
}

var cloudInit = loadContentAsBase64('user-data.template.yml')

resource my_vm 'Microsoft.Compute/virtualMachine' = {
  properties: {
    osProfile: {
      customData: format(cloudInit, values[0], values[1], values[2])
    }
  }
}

*/
