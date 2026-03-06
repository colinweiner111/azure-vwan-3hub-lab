// =============================================================================
// FRR/strongSwan VM Module - Primary Router (Instance 0) - Multi-Hub Transit
// =============================================================================
// Creates:
// - Linux VM with FRRouting + strongSwan
// - Cloud-init configuration for:
//   * 3 IPsec tunnels to each hub's vWAN VPN Gateway Instance 0
//   * BGP peers to each Instance 0, advertising on-prem 10.0.0.0/16
//   * Transit routing: re-advertises routes learned from Hub1 ↔ Hub3
//   * Hub2 only receives static on-prem prefix (no transit)
// =============================================================================

param location string
param adminUsername string
@secure()
param adminPassword string
param sshPublicKey string
param vmSize string
param subnetId string
@secure()
param vpnPsk string

// Hub1 vWAN VPN Gateway Instance 0
param hubVpnGwBgpIp0 string      // e.g., 192.168.1.13
param hubVpnGwPublicIp0 string   // Instance 0 public IP

// Hub2 vWAN VPN Gateway Instance 0
param hub2VpnGwBgpIp0 string     // e.g., 192.168.2.13
param hub2VpnGwPublicIp0 string  // Instance 0 public IP

// Hub3 vWAN VPN Gateway Instance 0
param hub3VpnGwBgpIp0 string     // e.g., 192.168.3.13
param hub3VpnGwPublicIp0 string  // Instance 0 public IP

var vmName = 'frr-router'
var nicName = '${vmName}-nic'
var publicIpName = '${vmName}-pip'
var onpremAsn = 65001

// =============================================================================
// Public IP
// =============================================================================
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// =============================================================================
// Network Interface
// =============================================================================
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
          primary: true
        }
      }
    ]
    enableIPForwarding: true
  }
}

// =============================================================================
// Cloud-init configuration for FRR + strongSwan (Primary - Multi-Hub Transit)
// =============================================================================
// 3 IPsec tunnels (one per hub) + 3 BGP peers
// Hub1 & Hub3 = TRANSIT peers (re-advertise learned routes between them)
// Hub2 = STANDARD peer (only on-prem prefix, no transit)
//
// format() placeholders:
//   {0} = Hub1 VPN GW Public IP (Instance 0)
//   {1} = VPN PSK
//   {2} = on-prem ASN (65001)
//   {3} = Hub1 VPN GW BGP IP (Instance 0)
//   {4} = Hub2 VPN GW Public IP (Instance 0)
//   {5} = Hub2 VPN GW BGP IP (Instance 0)
//   {6} = Hub3 VPN GW Public IP (Instance 0)
//   {7} = Hub3 VPN GW BGP IP (Instance 0)
// =============================================================================
var cloudInitConfig = format('''#cloud-config
package_update: true
package_upgrade: true

packages:
  - strongswan
  - strongswan-pki
  - libcharon-extra-plugins
  - frr
  - frr-pythontools
  - netcat-openbsd

write_files:
  # strongSwan ipsec.conf - 3 tunnels to each hub's VPN Gateway Instance 0
  - path: /etc/ipsec.conf
    content: |
      config setup
        charondebug="ike 1, knl 1"

      conn %default
        ikelifetime=28800s
        keylife=3600s
        rekeymargin=3m
        keyingtries=3
        keyexchange=ikev2
        authby=secret
        ike=aes256-sha256-modp1024!
        esp=aes256-sha256!
        type=tunnel
        auto=start
        dpdaction=clear
        dpddelay=30s
        dpdtimeout=120s

      # Hub1 tunnel (westus3) - VPN GW Instance 0
      conn primary-hub1
        left=%defaultroute
        leftsubnet=10.0.0.0/16
        leftid=%any
        right={0}
        rightsubnet=192.168.1.0/24,10.100.0.0/16,10.200.0.0/16
        rightid={0}

      # Hub2 tunnel (eastus2) - VPN GW Instance 0
      conn primary-hub2
        left=%defaultroute
        leftsubnet=10.0.0.0/16
        leftid=%any
        right={4}
        rightsubnet=192.168.2.0/24,10.110.0.0/16,10.210.0.0/16
        rightid={4}

      # Hub3 tunnel (westus) - VPN GW Instance 0
      conn primary-hub3
        left=%defaultroute
        leftsubnet=10.0.0.0/16
        leftid=%any
        right={6}
        rightsubnet=192.168.3.0/24,10.120.0.0/16,10.220.0.0/16
        rightid={6}

  # strongSwan secrets
  - path: /etc/ipsec.secrets
    permissions: '0600'
    content: |
      : PSK "{1}"

  # FRR daemons config
  - path: /etc/frr/daemons
    content: |
      zebra=yes
      bgpd=yes
      ospfd=no
      ospf6d=no
      ripd=no
      ripngd=no
      isisd=no
      pimd=no
      ldpd=no
      nhrpd=no
      eigrpd=no
      babeld=no
      sharpd=no
      staticd=yes
      pbrd=no
      bfdd=no
      fabricd=no
      vrrpd=no
      pathd=no

  # FRR configuration - Transit router between Hub1 and Hub3
  # Hub2 only gets static on-prem prefix (no transit re-advertisement)
  # __LOCAL_IP__ will be replaced at runtime with actual private IP
  - path: /etc/frr/frr.conf
    content: |
      frr version 8.1
      frr defaults traditional
      hostname frr-router
      log syslog informational
      service integrated-vtysh-config
      !
      ! Static route for on-prem network
      ip route 10.0.0.0/16 Null0
      !
      ! Allow next-hop resolution via default route (required for BGP
      ! next-hops reachable only through IPsec tunnel policies)
      ip nht resolve-via-default
      !
      ! === Prefix Lists ===
      ! ONPREM: static on-prem prefix only
      ip prefix-list ONPREM seq 5 permit 10.0.0.0/16
      !
      ! AZURE_LEARNED: accept spoke prefixes learned from Azure hubs
      ip prefix-list AZURE_LEARNED seq 5 permit 10.100.0.0/16
      ip prefix-list AZURE_LEARNED seq 10 permit 10.200.0.0/16
      ip prefix-list AZURE_LEARNED seq 15 permit 10.110.0.0/16
      ip prefix-list AZURE_LEARNED seq 20 permit 10.210.0.0/16
      ip prefix-list AZURE_LEARNED seq 25 permit 10.120.0.0/16
      ip prefix-list AZURE_LEARNED seq 30 permit 10.220.0.0/16
      !
      ! === Route Maps ===
      ! TRANSIT_OUT: advertise on-prem + re-advertise learned Azure routes
      ! as-path exclude 65515 strips the Azure VPN GW ASN to prevent loop detection
      ! when re-advertising routes back to the hub that originally sent them
      route-map TRANSIT_OUT permit 10
        match ip address prefix-list ONPREM
      route-map TRANSIT_OUT permit 20
        match ip address prefix-list AZURE_LEARNED
        set as-path exclude 65515
      route-map TRANSIT_OUT deny 100
      !
      ! TRANSIT_IN: strip Azure VPN GW ASN on inbound to avoid sender-side
      ! eBGP loop check when re-advertising to another AS 65515 peer
      route-map TRANSIT_IN permit 10
        set as-path exclude 65515
      !
      ! STANDARD_OUT: only advertise on-prem prefix (no transit)
      route-map STANDARD_OUT permit 10
        match ip address prefix-list ONPREM
      route-map STANDARD_OUT deny 100
      !
      ! === BGP Configuration ===
      router bgp {2}
        bgp router-id __LOCAL_IP__
        no bgp ebgp-requires-policy
        bgp log-neighbor-changes
        !
        ! --- TRANSIT peers: Hub1 and Hub3 (re-advertise between them) ---
        !
        ! Hub1 (westus3) - VPN GW Instance 0
        neighbor {3} remote-as 65515
        neighbor {3} ebgp-multihop 64
        neighbor {3} update-source __LOCAL_IP__
        neighbor {3} timers 3 9
        neighbor {3} description TRANSIT-HUB1
        !
        ! Hub3 (westus) - VPN GW Instance 0
        neighbor {7} remote-as 65515
        neighbor {7} ebgp-multihop 64
        neighbor {7} update-source __LOCAL_IP__
        neighbor {7} timers 3 9
        neighbor {7} description TRANSIT-HUB3
        !
        ! --- STANDARD peer: Hub2 (on-prem only, no transit) ---
        !
        ! Hub2 (eastus2) - VPN GW Instance 0
        neighbor {5} remote-as 65515
        neighbor {5} ebgp-multihop 64
        neighbor {5} update-source __LOCAL_IP__
        neighbor {5} timers 3 9
        neighbor {5} description STANDARD-HUB2
        !
        address-family ipv4 unicast
          redistribute static
          !
          ! Hub1: accept all, advertise on-prem + transit routes
          neighbor {3} soft-reconfiguration inbound
          neighbor {3} route-map TRANSIT_IN in
          neighbor {3} route-map TRANSIT_OUT out
          neighbor {3} as-override
          !
          ! Hub3: accept all, advertise on-prem + transit routes
          neighbor {7} soft-reconfiguration inbound
          neighbor {7} route-map TRANSIT_IN in
          neighbor {7} route-map TRANSIT_OUT out
          neighbor {7} as-override
          !
          ! Hub2: accept all, advertise on-prem only (no transit)
          neighbor {5} soft-reconfiguration inbound
          neighbor {5} route-map STANDARD_OUT out
        exit-address-family
      !
      line vty
      !

  # Setup script - replaces __LOCAL_IP__ and adds routes
  - path: /opt/setup-vpn.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      
      LOG=/var/log/vpn-setup.log
      exec > >(tee -a $LOG) 2>&1
      echo "=== Primary Router Multi-Hub Transit Setup started at $(date) ==="
      
      # Get local private IP
      LOCAL_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){{3}}' | head -1)
      echo "Local IP: $LOCAL_IP"
      
      # Get default gateway
      DEFAULT_GW=$(ip route | grep default | awk '{{print $3}}')
      echo "Default Gateway: $DEFAULT_GW"
      
      # Replace __LOCAL_IP__ placeholder in FRR config
      sed -i "s/__LOCAL_IP__/$LOCAL_IP/g" /etc/frr/frr.conf
      
      # Enable IP forwarding
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
      sysctl -w net.ipv4.ip_forward=1
      
      echo "Starting IPsec..."
      systemctl enable ipsec
      systemctl restart ipsec
      
      # Wait for tunnels to establish
      echo "Waiting for IPsec tunnels..."
      sleep 30
      ipsec status || true
      
      # Add routes to all 3 BGP peers via default gateway
      echo "Adding routes to BGP peers..."
      ip route add {3}/32 via $DEFAULT_GW dev eth0 || true
      ip route add {5}/32 via $DEFAULT_GW dev eth0 || true
      ip route add {7}/32 via $DEFAULT_GW dev eth0 || true
      
      echo "Starting FRR..."
      systemctl enable frr
      systemctl restart frr
      
      # Wait for BGP to establish
      sleep 30
      
      echo "=== Setup complete at $(date) ==="
      echo ""
      echo "IPsec status:"
      ipsec status || true
      echo ""
      echo "BGP summary:"
      vtysh -c "show ip bgp summary" || true

runcmd:
  - /opt/setup-vpn.sh
''', hubVpnGwPublicIp0, vpnPsk, string(onpremAsn), hubVpnGwBgpIp0, hub2VpnGwPublicIp0, hub2VpnGwBgpIp0, hub3VpnGwPublicIp0, hub3VpnGwBgpIp0)

// =============================================================================
// Virtual Machine
// =============================================================================
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: sshPublicKey != ''
        ssh: sshPublicKey != '' ? {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        } : null
      }
      customData: base64(cloudInitConfig)
    }
    storageProfile: {
      imageReference: {
        publisher: 'canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================
output vmId string = vm.id
output vmName string = vm.name
output publicIpAddress string = publicIp.properties.ipAddress
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
