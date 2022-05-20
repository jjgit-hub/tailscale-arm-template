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
var routedsubnets = empty(tsRoutedSubnets) ? '' : '--advertise-routes=${tsRoutedSubnets}'
var cloudInitTemplate = format(loadTextContent('cloud-init.template.yml'), tsPreAuthKey, routedsubnets)

@description('tags from TagsByResource')
param tagsByResource object

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

/*
  tailscale gateway
*/

resource tspip 'Microsoft.Network/publicIPAddresses@2020-11-01' = {
  name: '${tsVmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
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
        offer: '0001-com-ubuntu-server-focal'
        publisher: 'Canonical'
        sku: '20_04-lts'
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
      customData: base64(cloudInitTemplate)
    }
  }
  tags: contains(tagsByResource, 'Microsoft.Compute/virtualMachines') ? tagsByResource['Microsoft.Compute/virtualMachines'] : null
}
