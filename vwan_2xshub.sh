#!/usr/bin/zsh
############################################################################
# Created by Jose Moreno
# March 2023
#
# This is a subset of the content of the vwan_2xshub.azcli script, which is
# a script to deploy a 2x hub virtual WAN with ER, VPN GWs, Azure Firewall, etc.
# This version can be run as a script without the interactive parts or the need
# to copy/paste the code.
# 
# CLI extensions required:
# * virtual-wan
# * azure-firewall
#
# Tested with zsh
############################################################################

###############
#  Variables  #
###############

# Control
no_of_hubs=2         # 1 or 2 hubs
no_of_spokes=2       # Number of spokes per hub (without counting the hub with NVA for indirect spokes)
secure_hub=yes       # Whether firewalls are provisioned in the hubs
create_routes=no     # Whether static routes are created or not in RT's secure hub(s)
create_custom_rt=no  # Whether a custom RT for VNets will be created
indirect_spokes=no   # Whether spokes with Linux NVAs and indirect spokes are created
nva_bgp=yes          # If using an NVA in last spoke (for example 14/24), whether configuring BGP on it towards VWAN
route_thru_nva=no    # Whether a static route pointing to the NVA in the last spoke is configured
vnet_ass=default     # Route table to associate VNet connections. Can be 'default' or 'vnet' (if 'vnet', $create_custom_rt must be yes)
vnet_prop=default    # Route table to propagate from VNet connections. Can be 'default', 'vnet' or 'none' (if 'vnet', $create_custom_rt must be yes)
nva_in_hub1=no       # Whether a Linux NVA is deployed in hub1 (note you need to have a valid NVA image in the same subscription!)
nva_in_hub2=yes      # Whether a Linux NVA is deployed in hub2 (note you need to have a valid NVA image in the same subscription!)
deploy_vpngw=yes     # Whether VPN GWs should be deployed
deploy_er=no         # Whether ER should be provided (note you need an account with a provider such as Megaport)
deploy_gcp=no        # Whether an onprem location to be connected over ER should be deployed in Google Cloud
er_bow_tie=no        # If creating ER in multiple regions, whether each region should be connected to both virtual hubs
public_ip=no         # Whether extra VMs are created with public IP addressing
global_reach=no      # If 2 hubs and ER, connect both circuits via GR
routing_intent=yes   # Whether RI is configured
ri_policy=both       # internet/private/both
private_link=yes     # whether private endpoints will be created for the storage accounts in each region (in the first spoke, using the flow logs storage accounts)
location1=eastus
location2=westcentralus

# Generic variables
rg=vwan
vwan=vwan
password=Microsoft123!
vwan_hub1_prefix=192.168.0.0/23
vwan_hub2_prefix=192.168.2.0/23
username=$(whoami)
vm_size=Standard_B1s
nva_size=Standard_B2ms
wait_interval=15
azfw_policy_name=vwanfwpolicy
# Branches
publisher=cisco
offer=cisco-csr-1000v
sku=16_12-byol
version=$(az vm image list -p $publisher -f $offer -s $sku --all --query '[0].version' -o tsv)
branch1_prefix=10.4.1.0/24
branch1_prefix_long="10.4.1.0 255.255.255.0"
branch1_subnet=10.4.1.0/26
branch1_vm_subnet=10.4.1.64/26
branch1_gateway=10.4.1.1
branch1_bgp_ip=10.4.1.10
branch1_asn=65501
branch2_prefix=10.5.1.0/24
branch2_prefix_long="10.5.1.0 255.255.255.0"
branch2_vm_subnet=10.5.1.64/26
branch2_subnet=10.5.1.0/26
branch2_gateway=10.5.1.1
branch2_bgp_ip=10.5.1.10
branch2_2ary_bgp_ip=10.5.1.20
branch2_asn=65502
branch3_prefix=10.4.3.0/24
branch3_subnet=10.4.3.0/26
branch3_vm_subnet=10.4.3.64/26
branch3_gateway=10.4.3.1
branch3_bgp_ip=10.4.3.75
branch3_asn=65503
branch3_test_route=3.3.3.0/24
branch4_prefix=10.5.3.0/24
branch4_vm_subnet=10.5.3.64/26
branch4_subnet=10.5.3.0/26
branch4_gateway=10.5.3.1
branch4_bgp_ip=10.5.3.75
branch4_asn=65504
branch4_test_route=4.4.4.0/24
# ER (optional)
er_provider=Megaport
er_circuit_sku=Premium
megaport_script_path="/home/jose/repos/azcli/megaport.sh"
# hub1_er_pop=Sydney
hub1_er_pop=Dallas
mcr1_asn=65001
gr_ip_range=172.16.31.0/29
hub1_er_circuit_name="er1-$hub1_er_pop"
hub2_er_pop=Dallas
hub2_er_circuit_name="er2-$hub2_er_pop"
mcr2_asn=65002
# gcloud variables to simulate onprem via ER
project_name=cci-sandbox-jomore
project_id=cci-sandbox-jomore
machine_type=e2-micro
gcp_asn=16550
# gcp region 1
# region1=australia-southeast1
# zone1=australia-southeast1-b
# region1=europe-west3
# zone1=europe-west3-b
region1=us-west2
zone1=us-west2-b
gcp_vm1_name=vm1
gcp_vpc1_name=vpc1
gcp_subnet1_name=vm1
gcp_subnet1_prefix='10.4.2.0/24'
attachment1_name=attachment1
router1_name=router1
# gcp region 2
region2=us-west2
zone2=us-west2-b
gcp_vm2_name=vm2
gcp_vpc2_name=vpc2
gcp_subnet2_name=vm2
gcp_subnet2_prefix='10.5.2.0/24'
attachment2_name=attachment2
router2_name=router2
# REST URLs and JSON templates
vwan_api_version=2022-07-01
rtintent_json='{ properties: { routingPolicies: [ $routing_policies ] } }'
rtintent_policy_json='{name: $policy_name, destinations: [ $policy_destination ], nextHop: $policy_nexthop}'
subscription_id=$(az account show -o tsv --query id)

#############
# Functions #
#############

# REST API: PUT routing intent
# https://learn.microsoft.com/en-us/rest/api/virtualwan/routing-intent/create-or-update?tabs=HTTP
# Parameters:
# 1. hub id (1 or 2)
# 2. policies (internet, private or both)
# 3. next hop (azfw/nva)
function put_routing_intent() {
    # Get AzFW ID
    hub_id=$1
    if [[ "$hub_id" == "1" ]]; then
        location="$location1"
    else
        location="$location2"
    fi
    if [[ -z "$3" ]] || [[ "$3" == "azfw" ]]; then
        nexthop_id=$(az network vhub show -n hub${hub_id} -g $rg --query 'azureFirewall.id' -o tsv)
    else
        nexthop_id=$(az network virtual-appliance list -g $rg -o tsv --query "[?location=='$location'].id" | head -1)
    fi
    echo "Using next hop ID $nexthop_id to create/update routing intent policy..."
    # Construct JSON for policies (Internet/Private)
    rtintent_policy_internet_json_string=$(jq -n \
        --arg policy_name "InternetTraffic" \
        --arg policy_destination "Internet" \
        --arg policy_nexthop "$nexthop_id" \
        "$rtintent_policy_json")
    rtintent_policy_private_json_string=$(jq -n \
        --arg policy_name "PrivateTrafficPolicy" \
        --arg policy_destination "PrivateTraffic" \
        --arg policy_nexthop "$nexthop_id" \
        "$rtintent_policy_json")
    # Construct JSON for routing intent (depending on parameter)
    policy=$2
    if [[ "$policy" == 'internet' ]]; then
        rtintent_json_string=$(jq -n \
            --arg routing_policies "${rtintent_policy_internet_json_string}" \
            "$rtintent_json")
    elif [[ "$policy" == 'private' ]]; then
        rtintent_json_string=$(jq -n \
            --arg routing_policies "${rtintent_policy_private_json_string}" \
            "$rtintent_json")
    elif [[ "$policy" == 'both' ]]; then
        rtintent_json_string=$(jq -n \
            --arg routing_policies "${rtintent_policy_internet_json_string},${rtintent_policy_private_json_string}" \
            "$rtintent_json")
    else
        echo "Routing intent policy $2 not recognized, only 'internet', 'private' or 'both' supported"
        return
    fi
    # Remove escapes from string (jq substitution doesnt work for objects)
    rtintent_json_string=$(echo "$rtintent_json_string" | sed "s@\\\\@@g")
    rtintent_json_string=$(echo "${rtintent_json_string}" | sed "s@\"{@{@g")
    rtintent_json_string=$(echo "${rtintent_json_string}" | sed "s@}\"@}@g")
    # Send REST
    subscription_id=$(az account show --query id -o tsv)
    hub_name="hub$1"
    intent_name="intent$1"
    rtintent_uri="https://management.azure.com/subscriptions/${subscription_id}/resourceGroups/${rg}/providers/Microsoft.Network/virtualHubs/${hub_name}/routingIntent/${intent_name}?api-version=$vwan_api_version"
    # echo "Sending PUT request to $rtintent_uri..."
    az rest --method put --uri $rtintent_uri --headers Content-Type=application/json --body $rtintent_json_string -o none
    wait_until_finished_rest $rtintent_uri
}

# Get details of routing intent for a hub
function get_routing_intent() {
    hub_name="hub$1"
    intent_name="intent$1"
    rtintent_uri="https://management.azure.com/subscriptions/${subscription_id}/resourceGroups/${rg}/providers/Microsoft.Network/virtualHubs/${hub_name}/routingIntent/${intent_name}?api-version=$vwan_api_version"
    # echo "Sending GET request to $rtintent_uri..."
    az rest --method get --uri $rtintent_uri
}

# Using the REST API for the effective routes
function get_async_routes {
    uri=$1
    body=$2
    if [[ -z "$body" ]]; then
        request1_data=$(az rest --method post --uri $uri --debug 2>&1)
    else
        request1_data=$(az rest --method post --uri $uri --body $body --debug 2>&1)
    fi
    location=$(echo $request1_data | grep Location | cut -d\' -f 4)
    echo "Waiting to get info from $location..."
    wait_interval=5
    sleep $wait_interval
    table=$(az rest --method get --uri $location --query 'value')
    # table=$(az rest --method get --uri $location --query 'value[]' -o table | sed "s|/subscriptions/e7da9914-9b05-4891-893c-546cb7b0422e/resourceGroups/vwanlab2/providers/Microsoft.Network||g")
    until [[ -n "$table" ]]
    do
        sleep $wait_interval
        table=$(az rest --method get --uri $location --query 'value')
    done
    # Remove verbosity
    table=$(echo $table | sed "s|/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network||g")
    table=$(echo $table | sed "s|/virtualHubs/||g")
    table=$(echo $table | sed "s|/vpnGateways/||g")
    table=$(echo $table | sed "s|/hubVirtualNetworkConnections||g")
    # echo $table | jq
    echo "Route Origin\tAddress Prefixes\tNext Hop Type\tNext Hops\tAS Path"
    echo $table | jq -r '.[] | "\(.routeOrigin)\t\(.addressPrefixes[])\t\(.nextHopType)\t\(.nextHops[])\t\(.asPath)"'
}
function effective_routes_rt {
    hub_name=$1
    rt_name=$2
    rt_id="/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub_name/hubRouteTables/$rt_name"
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/effectiveRoutes?api-version=$vwan_api_version"
    body="{\"resourceId\": \"$rt_id\", \"virtualWanResourceType\": \"RouteTable\"}"
    get_async_routes $uri $body
}
function effective_routes_vpncx {
    hub_name=$1
    vpncx_name=$2
    vpngw_id=$(az network vhub show -n ${hub_name} -g $rg --query vpnGateway.id -o tsv)
    vpngw_name=$(echo $vpngw_id | cut -d/ -f 9)
    vpncx_id=$(az network vpn-gateway connection show -n $vpncx_name --gateway-name $vpngw_name -g $rg --query id -o tsv)
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/effectiveRoutes?api-version=$vwan_api_version"
    body="{\"resourceId\": \"$vpncx_id\", \"virtualWanResourceType\": \"VpnConnection \"}"
    get_async_routes $uri $body
}
# Inbound routes
function inbound_routes_vpncx {
    hub_name=$1
    vpncx_name=$2
    vpngw_id=$(az network vhub show -n ${hub_name} -g $rg --query vpnGateway.id -o tsv)
    vpngw_name=$(echo $vpngw_id | cut -d/ -f 9)
    vpncx_id=$(az network vpn-gateway connection show -n $vpncx_name --gateway-name $vpngw_name -g $rg --query id -o tsv)
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/inboundRoutes?api-version=$vwan_api_version"
    body="{\"resourceUri\": \"$vpncx_id\", \"connectionType\": \"VpnConnection \"}"
    get_async_routes $uri $body
}
function outbound_routes_vpncx {
    hub_name=$1
    vpncx_name=$2
    vpngw_id=$(az network vhub show -n ${hub_name} -g $rg --query vpnGateway.id -o tsv)
    vpngw_name=$(echo $vpngw_id | cut -d/ -f 9)
    vpncx_id=$(az network vpn-gateway connection show -n $vpncx_name --gateway-name $vpngw_name -g $rg --query id -o tsv)
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/outboundRoutes?api-version=$vwan_api_version"
    body="{\"resourceUri\": \"$vpncx_id\", \"connectionType\": \"VpnConnection \"}"
    get_async_routes $uri $body
}

# Advertised routes
# https://learn.microsoft.com/en-us/rest/api/virtualwan/virtual-hub-bgp-connections/list-advertised-routes?tabs=HTTP
function bgp_advertised_routes {
    hub_name=$1
    bgp_connection_name=$(az network vhub bgpconnection list --vhub-name hub1 -g $rg --query '[0].name' -o tsv)
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/bgpConnections/${bgp_connection_name}/advertisedRoutes?api-version=$vwan_api_version"
    get_async_routes $uri
}

# Learnt routes
# https://learn.microsoft.com/en-us/rest/api/virtualwan/virtual-hub-bgp-connections/list-learned-routes?tabs=HTTP
function bgp_learned_routes {
    hub_name=$1
    bgp_connection_name=$(az network vhub bgpconnection list --vhub-name hub1 -g $rg --query '[0].name' -o tsv)
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/bgpConnections/${bgp_connection_name}/learnedRoutes?api-version=$vwan_api_version"
    get_async_routes $uri
}

function effective_routes_vnetcx {
    hub_name=$1
    cx_name=$2
    cx_id=$(az network vhub connection show -n $cx_name --vhub-name $hub_name -g $rg --query id -o tsv)
    uri="https://management.azure.com/subscriptions/$subscription_id/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/${hub_name}/effectiveRoutes?api-version=$vwan_api_version"
    body="{\"resourceId\": \"$cx_id\", \"virtualWanResourceType\": \"ExpressRouteConnection\"}"
    get_async_routes $uri $body
}


# Wait for resource to be created
function wait_until_finished {
     resource_id=$1
     resource_name=$(echo $resource_id | cut -d/ -f 9)
     echo "Waiting for resource $resource_name to finish provisioning..."
     start_time=`date +%s`
     state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     until [[ "$state" == "Succeeded" ]] || [[ "$state" == "Failed" ]] || [[ -z "$state" ]]
     do
        sleep $wait_interval
        state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     done
     if [[ -z "$state" ]]
     then
        echo "Something really bad happened..."
     else
        run_time=$(expr `date +%s` - $start_time)
        ((minutes=${run_time}/60))
        ((seconds=${run_time}%60))
        echo "Resource $resource_name provisioning state is $state, wait time $minutes minutes and $seconds seconds"
     fi
}

# Wait for resource to be created, use REST API
function wait_until_finished_rest {
     resource_uri=$1
     echo "Waiting for resource $resource_uri to finish provisioning..."
     start_time=`date +%s`
     state=$(az rest --method get --uri $rtintent_uri | jq -r '.properties.provisioningState')
     until [[ "$state" == "Succeeded" ]] || [[ "$state" == "Failed" ]] || [[ -z "$state" ]]
     do
        sleep $wait_interval
        state=$(az rest --method get --uri $rtintent_uri | jq -r '.properties.provisioningState')
     done
     if [[ -z "$state" ]]
     then
        echo "Something really bad happened..."
     else
        run_time=$(expr `date +%s` - $start_time)
        ((minutes=${run_time}/60))
        ((seconds=${run_time}%60))
        echo "Resource provisioning state is $state, wait time $minutes minutes and $seconds seconds"
     fi
}


# Helper function to calculate the default gateway for a subnet
# Example: default_gw 172.16.1.31 255.255.255.248
function default_gw(){
    IP=$1
    MASK=$2
    DEBUG=$3    # Set to yes for message debugging
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
    MASK_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $MASK | sed -e 's/\./ /g'`)
    IP_DEC=$(echo "ibase=16; $IP_HEX" | bc)
    MASK_DEC=$(echo "ibase=16; $MASK_HEX" | bc)
    SUBNET_DEC=$(( IP_DEC&MASK_DEC ))
    GW_DEC=$(( $SUBNET_DEC + 1 ))
    GW_HEX=$(printf '%x\n' $GW_DEC)
    if [[ "${#GW_HEX}" == "7" ]]; then
        GW_HEX="0${GW_HEX}"
    fi
    GW=$(printf '%d.%d.%d.%d\n' `echo $GW_HEX | sed -r 's/(..)/0x\1 /g'`)
    if [[ "$DEBUG" == "yes" ]]
    then
        echo "Input: ${IP}/${MASK}"
        echo "Decimal: ${IP_DEC}/${MASK_DEC}"
        echo "Subnet decimal: ${SUBNET_DEC}"
        echo "Gateway dec: ${GW_DEC}"
        echo "Gateway hex: ${GW_HEX}"
        echo "Gateway: ${GW}"
    else
        echo "$GW"
    fi
}

# Create a VNet with a test VM and optionally attach it to a hub
function create_spoke() {
    hub=$1
    spoke=$2
    if [[ -z "$hub" ]] || [[ -z "spoke" ]]
    then
        echo "You need to provide a hub ID and a spoke ID"
        exit
    fi
    connect_to_hub=$3
    if [[ -z "$connect_to_hub" ]]
    then
        connect_to_hub="yes"
    fi
    spoke_id="${hub}${spoke}"
    hub_name="hub${hub}"
    vnet_prefix="10.${hub}.${spoke}.0/24"
    subnet_prefix="10.${hub}.${spoke}.0/26"
    if [[ "$hub" == "1" ]]
    then
        location="$location1"
        nsg_name="$nsg1_name"
        hub_vnet_ass_rt_id="$hub1_vnet_ass_rt_id"
        hub_vnet_prop_rt_id="$hub1_vnet_prop_rt_id"
    elif [[ "$hub" == "2" ]]
    then
        location="$location2"
        nsg_name="$nsg2_name"
        hub_vnet_ass_rt_id="$hub2_vnet_ass_rt_id"
        hub_vnet_prop_rt_id="$hub2_vnet_prop_rt_id"
    else
        echo "ERROR: $hub is not a valid hub ID"
        exit
    fi
    echo "Creating VM spoke${spoke_id}-vm in VNet spoke${spoke_id}-$location..."
    az vm create -n spoke${spoke_id}-vm -g $rg -l $location --image ubuntuLTS --admin-username $username --generate-ssh-keys \
        --public-ip-address spoke${spoke_id}-pip --public-ip-sku Standard --vnet-name spoke${spoke_id}-$location --nsg $nsg_name --size $vm_size \
        --vnet-address-prefix $vnet_prefix --subnet vm --subnet-address-prefix $subnet_prefix --custom-data $cloudinit_file -o none
    echo "Installing Network Watcher extension in VM spoke${spoke_id}-vm..."
    az vm extension set --vm-name spoke${spoke_id}-vm -g $rg -n NetworkWatcherAgentLinux --publisher Microsoft.Azure.NetworkWatcher --version 1.4 -o none
    if [[ "$connect_to_hub" == "yes" ]]
    then
        echo "Connecting VNet spoke${spoke_id} to $hub_name..."
        az network vhub connection create -n spoke${spoke_id} -g $rg --vhub-name $hub_name --remote-vnet spoke${spoke_id}-$location \
            --internet-security true --associated-route-table $hub_vnet_ass_rt_id --propagated-route-tables $hub_vnet_prop_rt_id --labels $vnet_prop_label -o none
    else
        echo "Skipping connection to the hub"
    fi
}

# Create a linux VM to simulate a branch to connect to an NVA deployed in the hub
function create_hub_nva_branch() {
    hub_id=$1
    hub_name="hub${hub_id}"
    nva_name="${hub_name}-nva"
    nva_asn="6510${hub_id}"
    # Set variables depending on which hub we are connecting the branch to
    if [[ "$hub_id" == "1" ]]
    then
        onprem_vnet_name=branch3
        onprem_vnet_prefix=$branch3_prefix
        onprem_nva_subnet_name=onpremnva
        onprem_nva_subnet_prefix=$branch3_vm_subnet
        onprem_linuxnva_asn=${branch3_asn}
        onprem_linuxnva_name=branch3-nva
        onprem_linuxnva_pip=${onprem_linuxnva_name}-pip
        onprem_linuxnva_ip=$branch3_bgp_ip
        onprem_test_route=$branch3_test_route
        vhub_space="$vwan_hub1_prefix"
        location=$location1
        storage_account_name=$storage_account1_name
    else
        onprem_vnet_name=branch4
        onprem_vnet_prefix=$branch4_prefix
        onprem_nva_subnet_name=onpremnva
        onprem_nva_subnet_prefix=$branch4_vm_subnet
        onprem_linuxnva_asn=${branch4_asn}
        onprem_linuxnva_name=branch4-nva
        onprem_linuxnva_pip=${onprem_linuxnva_name}-pip
        onprem_linuxnva_ip=$branch4_bgp_ip
        onprem_test_route=$branch4_test_route
        vhub_space="$vwan_hub2_prefix"
        location=$location2
        storage_account_name=$storage_account2_name
    fi
    # Get RS values from the virtual hub
    echo "Getting IP addresses and ASN from ${hub_name}..."
    rs_ip1=$(az network vhub show -n $hub_name -g $rg --query 'virtualRouterIps[0]' -o tsv) && echo $rs_ip1
    rs_ip2=$(az network vhub show -n $hub_name -g $rg --query 'virtualRouterIps[1]' -o tsv) && echo $rs_ip2
    rs_asn=$(az network vhub show -n $hub_name -g $rg --query 'virtualRouterAsn' -o tsv) && echo $rs_asn
    # Create VNet
    echo "Creating VNet $onprem_vnet_name with $onprem_vnet_prefix..."
    az network vnet create -n $onprem_vnet_name -g $rg -l $location --address-prefixes $onprem_vnet_prefix --subnet-name $onprem_nva_subnet_name --subnet-prefixes $onprem_nva_subnet_prefix -o none
    # Cloudinit file for onprem NVA
    linuxnva_cloudinit_file=/tmp/linuxnva_cloudinit.txt
    cat <<EOF > $linuxnva_cloudinit_file
#cloud-config
runcmd:
  - apt update && apt install -y bird strongswan
  - sysctl -w net.ipv4.ip_forward=1
  - sysctl -w net.ipv4.conf.all.accept_redirects=0 
  - sysctl -w net.ipv4.conf.all.send_redirects=0
EOF
    # NSG for onprem NVA
    echo "Creating NSG ${onprem_linuxnva_name}-nsg..."
    az network nsg create -n "${onprem_linuxnva_name}-nsg" -g $rg -l $location -o none
    az network nsg rule create -n SSH --nsg-name "${onprem_linuxnva_name}-nsg" -g $rg --priority 1000 --destination-port-ranges 22 --access Allow --protocol Tcp -o none
    az network nsg rule create -n IKE --nsg-name "${onprem_linuxnva_name}-nsg" -g $rg --priority 1010 --destination-port-ranges 4500 --access Allow --protocol Udp -o none
    az network nsg rule create -n IPsec --nsg-name "${onprem_linuxnva_name}-nsg" -g $rg --priority 1020 --destination-port-ranges 500 --access Allow --protocol Udp -o none
    az network nsg rule create -n ICMP --nsg-name "${onprem_linuxnva_name}-nsg" -g $rg --priority 1030 --destination-port-ranges '*' --access Allow --protocol Icmp -o none
    # az network watcher flow-log create -l $location -n ${onprem_linuxnva_name}-nsg -g $rg \
    #     --nsg ${onprem_linuxnva_name}-nsg --storage-account $storage_account_name --log-version 2 --retention 7 -o none
    # VM for onprem NVA
    echo "Creating VM $onprem_linuxnva_name..."
    az vm create -n $onprem_linuxnva_name -g $rg -l $location --image ubuntuLTS --generate-ssh-keys \
        --public-ip-address $onprem_linuxnva_pip --public-ip-sku Standard --vnet-name $onprem_vnet_name --size $vm_size --subnet $onprem_nva_subnet_name \
        --custom-data $linuxnva_cloudinit_file --private-ip-address "$onprem_linuxnva_ip" --nsg "${onprem_linuxnva_name}-nsg" -o none
    onprem_linuxnva_nic_id=$(az vm show -n $onprem_linuxnva_name -g "$rg" --query 'networkProfile.networkInterfaces[0].id' -o tsv)
    az network nic update --ids $onprem_linuxnva_nic_id --ip-forwarding -o none
    echo "Getting information about the created VM..."
    onprem_linuxnva_pip_ip=$(az network public-ip show -n $onprem_linuxnva_pip -g $rg --query ipAddress -o tsv) && echo $onprem_linuxnva_pip_ip
    onprem_linuxnva_private_ip=$(az network nic show --ids $onprem_linuxnva_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv) && echo $onprem_linuxnva_private_ip
    onprem_linuxnva_default_gw=$(default_gw "$onprem_linuxnva_ip" "255.255.255.192") && echo $onprem_linuxnva_default_gw
    # Public IPs of the external interfaces of the VWAN NVAs
    echo "Getting public IPs of the NVA $nva_name deployed in the virtual hub..."
    pip1=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[1].publicIpAddress' -o tsv) && echo $pip1
    pip2=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[3].publicIpAddress' -o tsv) && echo $pip2
    # Private IPs of the external interfaces of the VWAN NVAs
    echo "Getting private IPs (external NICs) of the NVA $nva_name deployed in the virtual hub..."
    nva_ip21=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[1].privateIpAddress' -o tsv) && echo $nva_ip21
    nva_ip22=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[3].privateIpAddress' -o tsv) && echo $nva_ip22
    # Private IPs VWAN NVAs
    echo "Getting private IPs (internal NICs) of the NVA $nva_name deployed in the virtual hub..."
    nva_private_ip11=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[0].privateIpAddress' -o tsv) && echo $nva_private_ip11
    nva_private_ip12=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[2].privateIpAddress' -o tsv) && echo $nva_private_ip12
    # Gateway for the VWAN NVA (internal NIC)
    nva_internal_mask=$(ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes "$pip1" "ifconfig eth1 | grep netmask | sed -n 's/.* netmask \([^ ]*\).*/\1/p'") && echo "Network mask $nva_internal_mask"
    if [[ "${nva_internal_mask:0:11}" != "255.255.255" ]]
    then
        echo "It looks like $nva_internal_mask is not a correct network mask, defaulting to 255.255.255.240..."
        nva_internal_mask="255.255.255.240"
    fi
    nva_default_gw=$(default_gw "$nva_private_ip11" "$nva_internal_mask") && echo "Internal gateway $nva_default_gw"
    # Private/public endpoints (A/B are the redundant hub NVAs, C is onprem)
    endpoint_a_public="$pip1"
    endpoint_a_private="$nva_ip21"
    endpoint_b_public="$pip2"
    endpoint_b_private="$nva_ip22"
    endpoint_c_public="$onprem_linuxnva_pip_ip"
    endpoint_c_private="$onprem_linuxnva_private_ip"
    echo "Configuring VPN between A:${endpoint_a_public}/${endpoint_a_private} and C:${endpoint_c_public}/${endpoint_c_private}"
    echo "Configuring VPN between B:${endpoint_b_public}/${endpoint_b_private} and C:${endpoint_c_public}/${endpoint_c_private}"
    # Initial config: NVA 0
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo ip route add $vhub_space via $nva_default_gw"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo ip tunnel add vti0 local $endpoint_a_private remote $endpoint_c_public mode vti key 11"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo sysctl -w net.ipv4.conf.vti0.disable_policy=1"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo ip link set up dev vti0"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo ip route add ${endpoint_c_private}/32 dev vti0"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo sed -i 's/# install_routes = yes/install_routes = no/' /etc/strongswan.d/charon.conf"
    # Initial config: NVA 1
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo ip route add $vhub_space via $nva_default_gw"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo ip tunnel add vti0 local $endpoint_b_private remote $endpoint_c_public mode vti key 11"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo sysctl -w net.ipv4.conf.vti0.disable_policy=1"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo ip link set up dev vti0"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo ip route add ${endpoint_c_private}/32 dev vti0"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo sed -i 's/# install_routes = yes/install_routes = no/' /etc/strongswan.d/charon.conf"
    # Initial config: Onprem
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo ip tunnel add vti0 local $endpoint_c_private remote $endpoint_a_public mode vti key 11"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo sysctl -w net.ipv4.conf.vti0.disable_policy=1"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo ip link set up dev vti0"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo ip route add ${nva_ip21}/32 dev vti0"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo ip tunnel add vti1 local $endpoint_c_private remote $endpoint_b_public mode vti key 12"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo sysctl -w net.ipv4.conf.vti1.disable_policy=1"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo ip link set up dev vti1"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo ip route add ${nva_ip22}/32 dev vti1"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo sed -i 's/# install_routes = yes/install_routes = no/' /etc/strongswan.d/charon.conf"
    # IPsec Config files
    vpn_psk=$(openssl rand -base64 64)
    vpn_psk=${vpn_psk//$'\n'/}  # Remove line breaks
    psk_file_a=/tmp/ipsec.secrets.a
    psk_file_b=/tmp/ipsec.secrets.b
    psk_file_c=/tmp/ipsec.secrets.c
    # PSK VWAN NVA 0
    cat <<EOF > $psk_file_a
$endpoint_a_public $endpoint_c_public : PSK "$vpn_psk"
EOF
    # PSK VWAN NVA 1
    cat <<EOF > $psk_file_b
$endpoint_b_public $endpoint_c_public : PSK "$vpn_psk"
EOF
    # PSK onprem
    cat <<EOF > $psk_file_c
$endpoint_c_public $endpoint_a_public : PSK "$vpn_psk"
$endpoint_c_public $endpoint_b_public : PSK "$vpn_psk"
EOF
    ipsec_file_a=/tmp/ipsec.conf.a
    ipsec_file_b=/tmp/ipsec.conf.b
    ipsec_file_c=/tmp/ipsec.conf.c
    cat <<EOF > $ipsec_file_a
config setup
        charondebug="all"
        uniqueids=yes
        strictcrlpolicy=no
conn to-onprem
  authby=secret
  leftid=$endpoint_a_public
  leftsubnet=0.0.0.0/0
  right=$endpoint_c_public
  rightsubnet=0.0.0.0/0
  ike=aes256-sha2_256-modp1024!
  esp=aes256-sha2_256!
  keyingtries=0
  ikelifetime=1h
  lifetime=8h
  dpddelay=30
  dpdtimeout=120
  dpdaction=restart
  auto=start
  mark=11
EOF
    # IPsec VWAN NVA 1
    cat <<EOF > $ipsec_file_b
config setup
        charondebug="all"
        uniqueids=yes
        strictcrlpolicy=no
conn to-onprem
  authby=secret
  leftid=$endpoint_b_public
  leftsubnet=0.0.0.0/0
  right=$endpoint_c_public
  rightsubnet=0.0.0.0/0
  ike=aes256-sha2_256-modp1024!
  esp=aes256-sha2_256!
  keyingtries=0
  ikelifetime=1h
  lifetime=8h
  dpddelay=30
  dpdtimeout=120
  dpdaction=restart
  auto=start
  mark=11
EOF
    # IPsec onprem
    cat <<EOF > $ipsec_file_c
config setup
        charondebug="all"
        uniqueids=yes
        strictcrlpolicy=no
conn to-azure1
  authby=secret
  leftid=$endpoint_c_public
  leftsubnet=0.0.0.0/0
  right=$endpoint_a_public
  rightsubnet=0.0.0.0/0
  ike=aes256-sha2_256-modp1024!
  esp=aes256-sha2_256!
  keyingtries=0
  ikelifetime=1h
  lifetime=8h
  dpddelay=30
  dpdtimeout=120
  dpdaction=restart
  auto=start
  mark=11
conn to-azure2
  authby=secret
  leftid=$endpoint_c_public
  leftsubnet=0.0.0.0/0
  right=$endpoint_b_public
  rightsubnet=0.0.0.0/0
  ike=aes256-sha2_256-modp1024!
  esp=aes256-sha2_256!
  keyingtries=0
  ikelifetime=1h
  lifetime=8h
  dpddelay=30
  dpdtimeout=120
  dpdaction=restart
  auto=start
  mark=12
EOF
    username=$(whoami)
    # Deploy files to NVA1
    scp $psk_file_a $pip1:/home/$username/ipsec.secrets
    scp $ipsec_file_a $pip1:/home/$username/ipsec.conf
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo mv ./ipsec.* /etc/"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo systemctl restart ipsec"
    # Deploy files to NVA2
    scp $psk_file_b $pip2:/home/$username/ipsec.secrets
    scp $ipsec_file_b $pip2:/home/$username/ipsec.conf
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo mv ./ipsec.* /etc/"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo systemctl restart ipsec"
    # Deploy files to onprem
    scp $psk_file_c $onprem_linuxnva_pip_ip:/home/$username/ipsec.secrets
    scp $ipsec_file_c $onprem_linuxnva_pip_ip:/home/$username/ipsec.conf
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo mv ./ipsec.* /etc/"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo systemctl restart ipsec"
    # Configure BGP with Bird
    # =======================
    bird_config_file_a=/tmp/bird.conf.a  # NVA 1/2
    bird_config_file_c=/tmp/bird.conf.c  # onprem
    # BGP config VWAN NVA (both instances)
    cat <<EOF > $bird_config_file_a
log syslog all;
protocol device {
        scan time 10;
}
protocol direct {
      disabled;
}
protocol kernel {
      preference 254;
      learn;
      merge paths on;
      import filter {
          if net ~ ${endpoint_c_private}/32 then accept;
          else reject;
      };
      export filter {
          if net ~ ${endpoint_c_private}/32 then reject;
          if net ~ [ 0.0.0.0/0{0,1} ] then reject;
          else accept;
      };
}
protocol static {
      import all;
      route $vhub_space via $nva_default_gw;
}
filter DROP_LONG {
      # Drop long prefixes
      if ( net ~ [ 0.0.0.0/0{30,32} ] ) then { reject; }
      else accept;
}
protocol bgp RS1 {
      description "RS1";
      multihop;
      local as $nva_asn;
      neighbor $rs_ip1 as $rs_asn;
          import filter {accept;};
          # export filter {accept;};
          export filter DROP_LONG;
}
protocol bgp RS2 {
      description "RS1";
      multihop;
      local as $nva_asn;
      neighbor $rs_ip2 as $rs_asn;
          import filter {accept;};
          # export filter {accept;};
          export filter DROP_LONG;
}
protocol bgp onprem {
      description "BGP to Onprem";
      multihop;
      local as $nva_asn;
      neighbor $endpoint_c_private as $onprem_linuxnva_asn;
          import filter {accept;};
          # export filter {accept;};
          export filter DROP_LONG;
}
EOF
    # Configure BGP with Bird (onprem)
    cat <<EOF > $bird_config_file_c
log syslog all;
router id $endpoint_c_private;
protocol device {
        scan time 10;
}
protocol direct {
      disabled;
}
protocol kernel {
      preference 254;
      learn;
      merge paths on;
      import filter {
          if net ~ ${nva_ip21}/32 then accept;
          if net ~ ${nva_ip22}/32 then accept;
          else reject;
      };
      export filter {
          if net ~ ${nva_ip21}/32 then reject;
          if net ~ ${nva_ip22}/32 then reject;
          if net ~ [ 0.0.0.0/0{0,1} ] then reject;
          else accept;
      };
}
protocol static {
      import all;
      route $onprem_test_route via $onprem_linuxnva_default_gw;
      route $onprem_vnet_prefix via $onprem_linuxnva_default_gw;
}
filter DROP_LONG {
      # Drop long prefixes
      if ( net ~ [ 0.0.0.0/0{30,32} ] ) then { reject; }
      else accept;
}
protocol bgp NVA1 {
      description "BGP to NVA1";
      multihop;
      local $endpoint_c_private as $onprem_linuxnva_asn;
      neighbor $endpoint_a_private as $nva_asn;
          import filter {accept;};
          #export filter {accept;};
          export filter DROP_LONG;
}
protocol bgp NVA2 {
      description "BGP to NVA2";
      multihop;
      local $endpoint_c_private as $onprem_linuxnva_asn;
      neighbor $endpoint_b_private as $nva_asn;
          import filter {accept;};
          #export filter {accept;};
          export filter DROP_LONG;
}
EOF
    # Deploy BGP config files
    username=$(whoami)
    # NVA instance 0
    scp $bird_config_file_a "${pip1}:/home/${username}/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo mv /home/${username}/bird.conf /etc/bird/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip1 "sudo systemctl restart bird"
    # NVA instance 1
    scp $bird_config_file_a "${pip2}:/home/${username}/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo mv /home/${username}/bird.conf /etc/bird/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $pip2 "sudo systemctl restart bird"
    # Onprem
    scp $bird_config_file_c "${onprem_linuxnva_pip_ip}:/home/${username}/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo mv /home/${username}/bird.conf /etc/bird/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo systemctl restart bird"
    # Some diagnostics
    echo "IPSec status in onprem NVA:"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo ipsec status"
    echo "BGP peerings in onprem NVA:"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem_linuxnva_pip_ip "sudo birdc show protocols"
}

# Create a Linux NVA in the hub
# Most code from nva_vwan.azcli in this repo
function create_hub_nva() {
    hub_id=$1
    hub_name="hub${hub_id}"
    nva_location=$(az network vhub show -n $hub_name -g $rg --query location -o tsv)
    subscription_id=$(az account show --query id -o tsv)
    vendor="Jose_generic_test_nva"
    version=latest
    deploy_mode=rest        # arm and rest supported at this time
    vpn_endpoint=public     # if "private", deploys ER to connect to onprem too. Use "public" if you dont have access to ER
    nva_name="${hub_name}-nva"
    nva_asn="6510${hub_id}"
    gnva_cloudinit="/tmp/nva-cloudinit.txt"
    username=$(whoami)
    public_ssh_key=$(more ~/.ssh/id_rsa.pub)
    # Verify subscription ID
    if [[ "$subscription_id" != "e7da9914-9b05-4891-893c-546cb7b0422e" ]]
    then
        "ERROR: $subscription_id is not a valid subscription for NVA $vendor"
        exit
    fi
    # Get IDs
    vwan_id=$(az network vwan show -n $vwan -g $rg --query name -o tsv)
    hub_arm_id=$(az network vhub show -n $hub_name -g $rg --query id -o tsv)
    # Create cloudinit file
    cat <<EOF > $gnva_cloudinit
#cloud-config
users:
  - default
  - name: $username
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    ssh-authorized-keys:
     - $public_ssh_key
packages:
  - jq
runcmd:
  - apt update
  - UCF_FORCE_CONFOLD=1 DEBIAN_FRONTEND=noninteractive apt install -y bird strongswan
  - sysctl -w net.ipv4.ip_forward=1
  - sysctl -w net.ipv4.conf.all.accept_redirects=0 
  - sysctl -w net.ipv4.conf.all.send_redirects=0
EOF
    cloudinit_string=$(cat $gnva_cloudinit | python3 -c 'import json, sys; print( json.dumps( sys.stdin.read() ) )')
    # REST payload
    json_payload='{
        "properties": {
        "nvaSku": {
                "vendor": "'$vendor'",
                "bundledScaleUnit": "2",
                "marketPlaceVersion": "'$version'"
        },
        "virtualHub": {
                "id": "'$hub_arm_id'"
        },
        "virtualApplianceAsn": '$nva_asn',
        "cloudInitConfiguration": '$cloudinit_string'
        },
        "location": "'$nva_location'",
        "tags": {
        "tagexample1": "tagvalue1"
        }
    }'
    uri="/subscriptions/${subscription_id}/resourceGroups/${rg}/providers/Microsoft.Network/NetworkVirtualAppliances/${nva_name}?api-version=2021-02-01"
    # Deploy NVA
    echo "Sending REST request to $uri..."
    az rest --method PUT --uri $uri --body "$json_payload" -o none
    # az network virtual-appliance create -n $nva_name -g $rg --scale-unit 2 --vendor $vendor --version $version --vhub $hub_arm_id --asn $nva_asn --init-config $cloudinit_string --tags tagExample="xyz"
    nva_id=$(az network virtual-appliance show -n $nva_name -g $rg --query id -o tsv)
    wait_until_finished $nva_id
    # Diagnostics
    echo "Getting IP addresses for the NVA instances in the hub..."
    nva_pip1=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[1].publicIpAddress' -o tsv) && echo $nva_pip1
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$nva_pip1" "ip a"
    nva_pip2=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[3].publicIpAddress' -o tsv) && echo $nva_pip2
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$nva_pip2" "ip a"
}

# Configure BGP in a hub NVA
function configure_hub_nva_bgp() {
    hub_id=$1
    hub_name="hub${hub_id}"
    nva_name="${hub_name}-nva"
    echo "Getting public IP addresses of NVA $nva_name..."
    nva_pip1=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[1].publicIpAddress' -o tsv --only-show-errors) && echo $nva_pip1
    nva_pip2=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[3].publicIpAddress' -o tsv --only-show-errors) && echo $nva_pip2
    # Get RS IPs
    echo "Finding information about Route Service in $hub_name..."
    rs_ip1=$(az network vhub show -n $hub_name -g $rg --query 'virtualRouterIps[0]' -o tsv) && echo $rs_ip1
    rs_ip2=$(az network vhub show -n $hub_name -g $rg --query 'virtualRouterIps[1]' -o tsv) && echo $rs_ip2
    rs_asn=$(az network vhub show -n $hub_name -g $rg --query 'virtualRouterAsn' -o tsv) && echo $rs_asn
    # Get NVA private IPs
    echo "Finding internal private IPs of NVA $nva_name..."
    nva_ip1=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[0].privateIpAddress' -o tsv) && echo $nva_ip1
    nva_ip2=$(az network virtual-appliance show -n $nva_name -g $rg --query 'virtualApplianceNics[2].privateIpAddress' -o tsv) && echo $nva_ip2
    # Find out the gateway for the private ip
    nva_internal_mask=$(ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes "$nva_pip1" "ifconfig eth1 | grep netmask | sed -n 's/.* netmask \([^ ]*\).*/\1/p'") && echo "Network mask $nva_internal_mask"
    if [[ "${nva_internal_mask:0:11}" != "255.255.255" ]]
    then
        echo "It looks like $nva_internal_mask is not a correct network mask, defaulting to 255.255.255.240..."
        nva_internal_mask="255.255.255.240"
    fi
    nva_default_gw=$(default_gw "$nva_ip1" "$nva_internal_mask") && echo "Internal gateway is $nva_default_gw"
    # Adding static IP routes
    if [[ $hub_id == "1" ]]
    then
        vhub_space="$vwan_hub1_prefix"
    else
        vhub_space="$vwan_hub2_prefix"
    fi
    echo "Adding static routes to NVA instances for the hub prefix $vhub_space..."
    ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes "$nva_pip1" "sudo ip route add $vhub_space via $nva_default_gw"
    ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes "$nva_pip2" "sudo ip route add $vhub_space via $nva_default_gw"
    # Create BGP file
    bird_config_file=/tmp/bird.conf
    echo "Generating BIRD config file in $bird_config_file..."
    cat <<EOF > $bird_config_file
log syslog all;
#router id $nva_ip1;
protocol device {
        scan time 10;
}
protocol direct {
      disabled;
}
protocol kernel {
      preference 254;
      learn;
      merge paths on;
      export all;
      #disabled;
}
protocol static {
      import all;
      # route $vhub_space via $linuxnva_default_gw;
}
filter DROP_LONG {
      # Drop long prefixes
      if ( net ~ [ 0.0.0.0/0{30,32} ] ) then { reject; }
      else accept;
}
protocol bgp RS1 {
      description "RS1";
      multihop;
      #local $nva_ip1 as $nva_asn;
      local as $nva_asn;
      neighbor $rs_ip1 as $rs_asn;
          import filter {accept;};
          # export filter {accept;};
          export filter DROP_LONG;
}
protocol bgp RS2 {
      description "RS1";
      multihop;
      #local $nva_ip1 as $nva_asn;
      local as $nva_asn;
      neighbor $rs_ip2 as $rs_asn;
          import filter {accept;};
          # export filter {accept;};
          export filter DROP_LONG;
}
EOF
    # Deploy file
    echo "Copying BIRD configuration files to both NVA instances..."
    username=$(whoami)
    scp $bird_config_file "${nva_pip1}:/home/${username}/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva_pip1 "sudo mv /home/${username}/bird.conf /etc/bird/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva_pip1 "sudo systemctl restart bird"
    scp $bird_config_file "${nva_pip2}:/home/${username}/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva_pip2 "sudo mv /home/${username}/bird.conf /etc/bird/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva_pip2 "sudo systemctl restart bird"
    # Diagnostics
    echo "Running some quick BGP diagnostics on both NVA instances..."
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva_pip1 "sudo birdc show prot"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva_pip2 "sudo birdc show prot"
}

#############
#   Start   #
#############

# Start: create RG
az group create -n $rg -l $location1 -o none

# vwan and hubs
echo "Creating Virtual WAN and Virtual Hubs..."
az network vwan create -n $vwan -g $rg -l $location1 --branch-to-branch-traffic true --type Standard -o none
az network vhub create -n hub1 -g $rg --vwan $vwan -l $location1 --address-prefix $vwan_hub1_prefix -o none
if [[ "$no_of_hubs" == "2" ]]
then
    az network vhub create -n hub2 -g $rg --vwan $vwan -l $location2 --address-prefix $vwan_hub2_prefix -o none
fi

# Create RT for vnets
if [[ "$create_custom_rt" == "yes" ]]; then
    echo "Creating custom RT for VNets..."
    az network vhub route-table create -n hub1Vnet --vhub-name hub1 -g $rg --labels vnet -o none
    if [[ "$no_of_hubs" == "2" ]]
    then
        az network vhub route-table create -n hub2Vnet --vhub-name hub2 -g $rg --labels vnet -o none
    fi
fi

# Add nohub1/nohub2 labels to default RTs
# az network vhub route-table update -n defaultRouteTable --vhub-name hub1 -g $rg --labels default nohub2
# az network vhub route-table update -n defaultRouteTable --vhub-name hub2 -g $rg --labels default nohub1

# Retrieve IDs of RTs. We will need this when creating the connections
hub1_default_rt_id=$(az network vhub route-table show --vhub-name hub1 -g $rg -n defaultRouteTable --query id -o tsv)
hub1_none_rt_id=$(az network vhub route-table show --vhub-name hub1 -g $rg -n noneRouteTable --query id -o tsv)
if [[ "$create_custom_rt" == "yes" ]]; then
    hub1_vnet_rt_id=$(az network vhub route-table show --vhub-name hub1 -g $rg -n hub1Vnet --query id -o tsv)
fi
if [[ "$no_of_hubs" == "2" ]]
then
    hub2_default_rt_id=$(az network vhub route-table show --vhub-name hub2 -g $rg -n defaultRouteTable --query id -o tsv)
    hub2_none_rt_id=$(az network vhub route-table show --vhub-name hub2 -g $rg -n noneRouteTable --query id -o tsv)
    if [[ "$create_custom_rt" == "yes" ]]; then
        hub2_vnet_rt_id=$(az network vhub route-table show --vhub-name hub2 -g $rg -n hub2Vnet --query id -o tsv)
    fi
fi

# Define which association/propagations we will use
if [[ "$vnet_ass" == "vnet" ]]
then
    hub1_vnet_ass_rt_id="$hub1_vnet_rt_id"
    hub2_vnet_ass_rt_id="$hub2_vnet_rt_id"
else
    hub1_vnet_ass_rt_id="$hub1_default_rt_id"
    hub2_vnet_ass_rt_id="$hub2_default_rt_id"
fi
if [[ "$vnet_prop" == "vnet" ]]
then
    hub1_vnet_prop_rt_id="$hub1_vnet_rt_id"
    hub2_vnet_prop_rt_id="$hub2_vnet_rt_id"
    vnet_prop_label='vnet'
elif [[ "$vnet_prop" == "none" ]]
then
    hub1_vnet_prop_rt_id="$hub1_none_rt_id"
    hub2_vnet_prop_rt_id="$hub2_none_rt_id"
    vnet_prop_label='none'
else
    hub1_vnet_prop_rt_id="$hub1_default_rt_id"
    hub2_vnet_prop_rt_id="$hub2_default_rt_id"
    vnet_prop_label="default"
fi


# Create VPN gateways (not using --no-wait to avoid race conditions due to parallelism)
if [[ "$deploy_vpngw" == "yes" ]]
then
    echo "Creating VPN Gateways..."
    az network vpn-gateway create -n hubvpn1 -g $rg -l $location1 --vhub hub1 --asn 65515 -o none
    if [[ "$no_of_hubs" == "2" ]]
    then
        az network vpn-gateway create -n hubvpn2 -g $rg -l $location2 --vhub hub2 --asn 65515 -o none
    fi
fi

# Create NSGs to be used by VMs
echo "Creating NSGs for Virtual Machines..."
nsg1_name=vm-nsg-$location1
az network nsg create -n $nsg1_name -g $rg -l $location1 -o none
az network nsg rule create --nsg-name $nsg1_name -g $rg -n Allow_Inbound_SSH --priority 1000 \
    --access Allow --protocol Tcp --source-address-prefixes '*' --direction Inbound \
    --destination-address-prefixes '*' --destination-port-ranges 22 -o none
az network nsg rule create --nsg-name $nsg1_name -g $rg -n Allow_Inbound_HTTP --priority 1010 --direction Inbound \
    --access Allow --protocol Tcp --source-address-prefixes '10.0.0.0/8' '172.16.0.0/12' '20.0.0.0/6' '192.168.0.0/16' \
    --destination-address-prefixes '*' --destination-port-ranges 9 80 443 -o none
# az network nsg rule create --nsg-name $nsg1_name -g $rg -n Allow_Inbound_HTTP_Return --priority 1015 --direction Inbound \
#     --access Allow --protocol Tcp --source-address-prefixes '*' \
#     --destination-address-prefixes '10.0.0.0/8' '172.16.0.0/12' '20.0.0.0/6' '192.168.0.0/16' --destination-port-ranges 80 443
az network nsg rule create --nsg-name $nsg1_name -g $rg -n Allow_Inbound_IPsec --priority 1020 \
    --access Allow --protocol Udp --source-address-prefixes 'Internet' --direction Inbound \
    --destination-address-prefixes '*' --destination-port-ranges 500 4500 -o none
az network nsg rule create --nsg-name $nsg1_name -g $rg -n Allow_Inbound_NTP --priority 1030 \
    --access Allow --protocol Udp --source-address-prefixes '10.0.0.0/8' '172.16.0.0/12' '20.0.0.0/6' '192.168.0.0/16' --direction Inbound \
    --destination-address-prefixes '*' --destination-port-ranges 123 -o none
az network nsg rule create --nsg-name $nsg1_name -g $rg -n Allow_Inbound_Icmp --priority 1040 \
    --access Allow --protocol Icmp --source-address-prefixes '*' --direction Inbound \
    --destination-address-prefixes '*' --destination-port-ranges '*' -o none
az network nsg rule create --nsg-name $nsg1_name -g $rg -n Allow_Outbound_All --priority 1000 \
    --access Allow --protocol '*' --source-address-prefixes '*' --direction Outbound \
    --destination-address-prefixes '*' --destination-port-ranges '*' -o none
# Configure NSG flow logs
echo "Configuring NSG flow logs..."
storage_account1_name=vwan$RANDOM$location1
az storage account create -n $storage_account1_name -g $rg --sku Standard_LRS --kind StorageV2 -l $location1 -o none
az network watcher flow-log create -l $location1 -n flowlog-$location1 -g $rg \
    --nsg $nsg1_name --storage-account $storage_account1_name --log-version 2 --retention 7 -o none

# Hub2
if [[ "$no_of_hubs" == "2" ]]
then
    nsg2_name=vm-nsg-$location2
    if [[ "$location1" != "$location2" ]]
    then
        az network nsg create -n $nsg2_name -g $rg -l $location2 -o none
        az network nsg rule create --nsg-name $nsg2_name -g $rg -n Allow_Inbound_SSH --priority 1000 \
            --access Allow --protocol Tcp --source-address-prefixes '*' --direction Inbound \
            --destination-address-prefixes '*' --destination-port-ranges 22 -o none
        az network nsg rule create --nsg-name $nsg2_name -g $rg -n Allow_Inbound_HTTP --priority 1010 \
            --access Allow --protocol Tcp --source-address-prefixes '10.0.0.0/8' '172.16.0.0/12' '20.0.0.0/6' '192.168.0.0/16' \
            --destination-address-prefixes '*' --destination-port-ranges 9 80 443 -o none
        az network nsg rule create --nsg-name $nsg2_name -g $rg -n Allow_Inbound_IPsec --priority 1020 \
            --access Allow --protocol Udp --source-address-prefixes 'Internet' --direction Inbound \
            --destination-address-prefixes '*' --destination-port-ranges 500 4500 -o none
        az network nsg rule create --nsg-name $nsg2_name -g $rg -n Allow_Inbound_NTP --priority 1030 \
            --access Allow --protocol Udp --source-address-prefixes '10.0.0.0/8' '172.16.0.0/12' '20.0.0.0/6' '192.168.0.0/16' --direction Inbound \
            --destination-address-prefixes '*' --destination-port-ranges 123 -o none
        az network nsg rule create --nsg-name $nsg2_name -g $rg -n Allow_Inbound_Icmp --priority 1040 \
            --access Allow --protocol Icmp --source-address-prefixes '*' --direction Inbound \
            --destination-address-prefixes '*' --destination-port-ranges '*' -o none
        az network nsg rule create --nsg-name $nsg2_name -g $rg -n Allow_Outbound_All --priority 1000 \
            --access Allow --protocol '*' --source-address-prefixes '*' --direction Outbound \
            --destination-address-prefixes '*' --destination-port-ranges '*' -o none
    fi
    if [[ "$location1" != "$location2" ]]
    then
        storage_account2_name=vwan$RANDOM$location2
    else
        storage_account2_name=$storage_account1_name
    fi
    az storage account create -n $storage_account2_name -g $rg --sku Standard_LRS --kind StorageV2 -l $location2 -o none
    az network watcher flow-log create -l $location2 -n flowlog-$location2 -g $rg \
        --nsg $nsg2_name --storage-account $storage_account2_name --log-version 2 --retention 7 -o none
fi

# Create CSRs only if there are VPN Gateways

# Create CSR to simulate branch1
if [[ "$deploy_vpngw" == "yes" ]]
then
    # You might have to accept the CSR marketplace terms to deploy the image
    echo "Accepting the Cisco marketplace image for Cisco CSR..."
    az vm image terms accept -p $publisher -f $offer --plan $sku -o none
    echo "Creating NVAs..."
    az vm create -n branch1-nva -g $rg -l $location1 --image ${publisher}:${offer}:${sku}:${version} \
        --generate-ssh-keys --admin-username $username --nsg $nsg1_name --size $nva_size --disable-integrity-monitoring \
        --public-ip-address branch1-pip --public-ip-address-allocation static --public-ip-sku Standard --private-ip-address $branch1_bgp_ip \
        --vnet-name branch1 --vnet-address-prefix $branch1_prefix --subnet nva --subnet-address-prefix $branch1_subnet -o none
    branch1_ip=$(az network public-ip show -n branch1-pip -g $rg --query ipAddress -o tsv)
    # az network vpn-site create -n branch1 -g $rg -l $location1 --virtual-wan $vwan \
    #     --asn $branch1_asn --bgp-peering-address $branch1_bgp_ip --ip-address $branch1_ip --address-prefixes ${branch1_ip}/32 --device-vendor cisco --device-model csr --link-speed 100 -o none
    # az network vpn-gateway connection create -n branch1 --gateway-name hubvpn1 -g $rg --remote-vpn-site branch1 \
    #     --enable-bgp true --protocol-type IKEv2 --shared-key "$password" --connection-bandwidth 100 --routing-weight 10 \
    #     --associated-route-table $hub1_default_rt_id --propagated-route-tables $hub1_default_rt_id --labels default --internet-security true -o none
    # az network vpn-site create -n branch1 -g $rg -l $location1 --virtual-wan $vwan --address-prefixes ${branch1_ip}/32 --device-vendor cisco --device-model csr --link-speed 100 --ip-address $branch1_ip  \
    #     --asn $branch1_asn --bgp-peering-address $branch1_bgp_ip --with-link -o none
    az network vpn-site create -n branch1 -g $rg -l $location1 --virtual-wan $vwan --device-vendor cisco --device-model csr --link-speed 100 --ip-address $branch1_ip  \
        --asn $branch1_asn --bgp-peering-address $branch1_bgp_ip --with-link -o none
    # az network vpn-site link add -n branch1 -g $rg --ip-address $branch1_ip --asn $branch1_asn --bgp-peering-address $branch1_bgp_ip --site-name branch1 --link-speed-in-mbps 100 --link-provider-name msft -o none
    branch1_link_id=$(az network vpn-site link list --site-name branch1 -g $rg --query '[0].id' -o tsv)
    az network vpn-gateway connection create -n branch1 --gateway-name hubvpn1 -g $rg --remote-vpn-site branch1 --with-link true --vpn-site-link $branch1_link_id \
        --enable-bgp true --protocol-type IKEv2 --shared-key "$password" --connection-bandwidth 100 --routing-weight 10 \
        --associated-route-table $hub1_default_rt_id --propagated-route-tables $hub1_default_rt_id --labels default --internet-security true -o none
    if [[ "$no_of_hubs" == "2" ]]
    then
        # Create CSR to simulate branch2
        az vm create -n branch2-nva -g $rg -l $location2 --image ${publisher}:${offer}:${sku}:${version} \
            --generate-ssh-keys --admin-username $username --nsg $nsg2_name --size $nva_size --disable-integrity-monitoring \
            --public-ip-address branch2-pip --public-ip-address-allocation static --public-ip-sku Standard --private-ip-address $branch2_bgp_ip \
            --vnet-name branch2 --vnet-address-prefix $branch2_prefix --subnet nva --subnet-address-prefix $branch2_subnet -o none
        branch2_ip=$(az network public-ip show -n branch2-pip -g $rg --query ipAddress -o tsv)
        # az network vpn-site create -n branch2 -g $rg -l $location2 --virtual-wan $vwan --with-link --device-vendor cisco --device-model csr --link-speed 100 \
        #     --asn $branch2_asn --bgp-peering-address $branch2_bgp_ip --ip-address $branch2_ip --address-prefixes ${branch2_ip}/32 -o none
        az network vpn-site create -n branch2 -g $rg -l $location2 --virtual-wan $vwan --with-link --device-vendor cisco --device-model csr --link-speed 100 \
            --asn $branch2_asn --bgp-peering-address $branch2_bgp_ip --ip-address $branch2_ip -o none
        branch2_link_id=$(az network vpn-site link list --site-name branch2 -g $rg --query '[0].id' -o tsv)
        az network vpn-gateway connection create -n branch2 --gateway-name hubvpn2 -g $rg --remote-vpn-site branch2 --with-link true --vpn-site-link $branch2_link_id \
            --enable-bgp true --protocol-type IKEv2 --shared-key "$password" --connection-bandwidth 100 --routing-weight 10 \
            --associated-route-table $hub2_default_rt_id --propagated-route-tables $hub2_default_rt_id  --labels default --internet-security true -o none
    fi
fi

# Configure branches (CSRs)

# Get parameters for VPN GW in hub1
if [[ "$deploy_vpngw" == "yes" ]]
then
    vpngw1_config=$(az network vpn-gateway show -n hubvpn1 -g $rg)
    site=branch1
    vpngw1_gw0_pip=$(echo $vpngw1_config | jq -r '.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]')
    vpngw1_gw1_pip=$(echo $vpngw1_config | jq -r '.bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]')
    vpngw1_gw0_bgp_ip=$(echo $vpngw1_config | jq -r '.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]')
    vpngw1_gw1_bgp_ip=$(echo $vpngw1_config | jq -r '.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]')
    vpngw1_bgp_asn=$(echo $vpngw1_config | jq -r '.bgpSettings.asn')  # This is today always 65515
    echo "Extracted info for hubvpn1: Gateway0 $vpngw1_gw0_pip, $vpngw1_gw0_bgp_ip. Gateway1 $vpngw1_gw1_pip, $vpngw1_gw0_bgp_ip. ASN $vpngw1_bgp_asn"

    if [[ "$no_of_hubs" == "2" ]]
    then
        # Get parameters for VPN GW in hub2
        vpngw2_config=$(az network vpn-gateway show -n hubvpn2 -g $rg)
        site=branch2
        vpngw2_gw0_pip=$(echo $vpngw2_config | jq -r '.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]')
        vpngw2_gw1_pip=$(echo $vpngw2_config | jq -r '.bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]')
        vpngw2_gw0_bgp_ip=$(echo $vpngw2_config | jq -r '.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]')
        vpngw2_gw1_bgp_ip=$(echo $vpngw2_config | jq -r '.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]')
        vpngw2_bgp_asn=$(echo $vpngw2_config | jq -r '.bgpSettings.asn')  # This is today always 65515
        echo "Extracted info for hubvpn2: Gateway0 $vpngw2_gw0_pip, $vpngw2_gw0_bgp_ip. Gateway1 $vpngw2_gw1_pip, $vpngw2_gw0_bgp_ip. ASN $vpngw2_bgp_asn"
    fi

    # Wait until CSR in branch1 takes SSH connections
    wait_interval_csr=30
    echo "Waiting until CSR in branch${branch_id} is reachable..."
    command="sho ver | i uptime"
    command_output=$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no  -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch1_ip "$command")
    until [[ -n "$command_output" ]]
    do
        sleep $wait_interval_csr
        command_output=$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no  -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch1_ip "$command")
    done
    echo $command_output

    # Create CSR config for branch 1
    csr_config_url="https://raw.githubusercontent.com/erjosito/azure-wan-lab/master/csr_config_2tunnels_tokenized.txt"
    config_file_csr='branch1_csr.cfg'
    config_file_local='/tmp/branch1_csr.cfg'
    wget $csr_config_url -O $config_file_local
    sed -i "s|\*\*PSK\*\*|${password}|g" $config_file_local
    sed -i "s|\*\*GW0_Private_IP\*\*|${vpngw1_gw0_bgp_ip}|g" $config_file_local
    sed -i "s|\*\*GW1_Private_IP\*\*|${vpngw1_gw1_bgp_ip}|g" $config_file_local
    sed -i "s|\*\*GW0_Public_IP\*\*|${vpngw1_gw0_pip}|g" $config_file_local
    sed -i "s|\*\*GW1_Public_IP\*\*|${vpngw1_gw1_pip}|g" $config_file_local
    sed -i "s|\*\*BGP_ID\*\*|${branch1_asn}|g" $config_file_local
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch1_ip <<EOF
  config t
    file prompt quiet
EOF
    scp -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $config_file_local ${branch1_ip}:/${config_file_csr}
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch1_ip "copy bootflash:${config_file_csr} running-config"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch1_ip "wr mem"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch1_ip "sh ip int b"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch1_ip "sh ip bgp summary"
    myip=$(curl -s4 ifconfig.co)
    loopback_ip=10.11.11.11
    default_gateway=$branch1_gateway
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch1_ip <<EOF
config t
    username $username password 0 $password
    no ip domain lookup
    interface Loopback0
        ip address ${loopback_ip} 255.255.255.255
    router bgp ${branch1_asn}
        redistribute static route-map S2B
    route-map S2B
        match ip address prefix-list S2B
    ip prefix-list S2B permit ${branch1_prefix}
    ip route ${branch1_prefix_long} ${default_gateway}
    ip route ${vpngw1_gw0_pip} 255.255.255.255 ${default_gateway}
    ip route ${vpngw1_gw1_pip} 255.255.255.255 ${default_gateway}
    ip route ${myip} 255.255.255.255 ${default_gateway}
    line vty 0 15
        exec-timeout 0 0
end
write mem
EOF

    if [[ "$no_of_hubs" == "2" ]]
    then
        # Wait until CSR in branch2 takes SSH connections
        wait_interval_csr=30
        echo "Waiting until CSR in branch${branch_id} is reachable..."
        command="sho ver | i uptime"
        command_output=$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch2_ip "$command")
        until [[ -n "$command_output" ]]
        do
            sleep $wait_interval_csr
            command_output=$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch2_ip "$command")
        done
        echo $command_output

        # Create CSR config for branch 2
        csr_config_url="https://raw.githubusercontent.com/erjosito/azure-wan-lab/master/csr_config_2tunnels_tokenized.txt"
        config_file_csr='branch2_csr.cfg'
        config_file_local='/tmp/branch2_csr.cfg'
        wget $csr_config_url -O $config_file_local
        sed -i "s|\*\*PSK\*\*|${password}|g" $config_file_local
        sed -i "s|\*\*GW0_Private_IP\*\*|${vpngw2_gw0_bgp_ip}|g" $config_file_local
        sed -i "s|\*\*GW1_Private_IP\*\*|${vpngw2_gw1_bgp_ip}|g" $config_file_local
        sed -i "s|\*\*GW0_Public_IP\*\*|${vpngw2_gw0_pip}|g" $config_file_local
        sed -i "s|\*\*GW1_Public_IP\*\*|${vpngw2_gw1_pip}|g" $config_file_local
        sed -i "s|\*\*BGP_ID\*\*|${branch2_asn}|g" $config_file_local
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch2_ip <<EOF
  config t
    file prompt quiet
EOF
        scp -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $config_file_local ${branch2_ip}:/${config_file_csr}
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch2_ip "copy bootflash:${config_file_csr} running-config"
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch2_ip "wr mem"
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch2_ip "sh ip int b"
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch2_ip "sh ip bgp summary"
        myip=$(curl -s4 ifconfig.co)
        loopback_ip=10.22.22.22
        default_gateway=$branch2_gateway
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o KexAlgorithms=diffie-hellman-group-exchange-sha1 $branch2_ip <<EOF
config t
    username $username password 0 $password
    no ip domain lookup
    interface Loopback0
        ip address ${loopback_ip} 255.255.255.255
    router bgp ${branch2_asn}
        redistribute static route-map S2B
    route-map S2B
        match ip address prefix-list S2B
    ip prefix-list S2B permit ${branch2_prefix}
    ip route ${branch2_prefix_long} ${default_gateway}
    ip route ${vpngw2_gw0_pip} 255.255.255.255 ${default_gateway}
    ip route ${vpngw2_gw1_pip} 255.255.255.255 ${default_gateway}
    ip route ${myip} 255.255.255.255 ${default_gateway}
    line vty 0 15
        exec-timeout 0 0
end
wr mem
EOF
    fi   # If $no_of_hubs == 2
fi  # if $deploy_vpngw == yes

# Configure VPN gateways to log to Azure Monitor
# Create LA workspace if it doesnt exist
logws_name=$(az monitor log-analytics workspace list -g $rg --query '[0].name' -o tsv)
if [[ -z "$logws_name" ]]
then
    logws_name=vwanlogs$RANDOM
    echo "Creating log analytics workspace $logws_name..."
    az monitor log-analytics workspace create -n $logws_name -g $rg -l $location1 -o none
fi
logws_id=$(az resource list -g $rg -n $logws_name --query '[].id' -o tsv)
logws_customerid=$(az monitor log-analytics workspace show -n $logws_name -g $rg --query customerId -o tsv)
if [[ "$deploy_vpngw" == "yes" ]]
then
    # VPN gateways
    echo "Configuring VPN gateways..."
    gw_id_list=$(az network vpn-gateway list -g $rg --query '[].id' -o tsv)
    while IFS= read -r gw_id; do
        az monitor diagnostic-settings create -n mydiag --resource $gw_id --workspace $logws_id \
            --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
            --logs '[{"category": "GatewayDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                    {"category": "TunnelDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}},
                    {"category": "RouteDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}},
                    {"category": "IKEDiagnosticLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' -o none
    done <<< "$gw_id_list"
fi

if [[ "$secure_hub" == "yes" ]]
then
    # Create Azure Firewall policy with sample policies
    az network firewall policy create -n $azfw_policy_name -g $rg -o none
    az network firewall policy rule-collection-group create -n ruleset01 --policy-name $azfw_policy_name -g $rg --priority 100 -o none
    # Allow SSH and HTTP for connection monitor (uses TCP9 too)
    echo "Creating rule to allow SSH and HTTP..."
    az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
        --name mgmt --collection-priority 101 --action Allow --rule-name allowSSHnHTTP --rule-type NetworkRule --description "TCP 22" \
        --destination-addresses 10.0.0.0/8 172.16.0.0/12 20.0.0.0/6 --source-addresses 10.0.0.0/8 172.16.0.0/12 20.0.0.0/6 --ip-protocols TCP --destination-ports 9 22 80 -o none
    # Allow ICMP
    echo "Creating rule to allow ICMP..."
    az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
        --name icmp --collection-priority 102 --action Allow --rule-name allowICMP --rule-type NetworkRule --description "ICMP traffic" \
        --destination-addresses 10.0.0.0/8 172.16.0.0/12 20.0.0.0/6 --source-addresses 10.0.0.0/8 172.16.0.0/12 20.0.0.0/6 --ip-protocols ICMP --destination-ports "1-65535" -o none
    # Allow NTP
    echo "Creating rule to allow NTP..."
    az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
        --name ntp --collection-priority 103 --action Allow --rule-name allowNTP --rule-type NetworkRule --description "Egress NTP traffic" \
        --destination-addresses '*' --source-addresses "10.0.0.0/8" "20.0.0.0/6" --ip-protocols UDP --destination-ports "123" -o none
    # Example application collection with 2 rules (ipconfig.co, api.ipify.org)
    echo "Creating rule to allow ifconfig.co and api.ipify.org..."
    az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
        --name ifconfig --collection-priority 201 --action Allow --rule-name allowIfconfig --rule-type ApplicationRule --description "ifconfig" \
        --target-fqdns "ifconfig.co" --source-addresses "10.0.0.0/8" "172.16.0.0/12" "20.0.0.0/6" --protocols Http=80 Https=443 -o none
    az network firewall policy rule-collection-group collection rule add -g $rg --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 --collection-name ifconfig \
        --name ipify --target-fqdns "api.ipify.org" --source-addresses "10.0.0.0/8" "172.16.0.0/12" "20.0.0.0/6" --protocols Http=80 Https=443 --rule-type ApplicationRule -o none
    # Example application collection with wildcards (*.ubuntu.com)
    echo "Creating rule to allow *.ubuntu.com..."
    az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
        --name ubuntu --collection-priority 202 --action Allow --rule-name repos --rule-type ApplicationRule --description "ubuntucom" \
        --target-fqdns 'ubuntu.com' '*.ubuntu.com' --source-addresses '*' --protocols Http=80 Https=443 -o none
    # Mgmt traffic to Azure
    az network firewall policy rule-collection-group collection add-filter-collection --policy-name $azfw_policy_name --rule-collection-group-name ruleset01 -g $rg \
        --name azure --collection-priority 203 --action Allow --rule-name azmonitor --rule-type ApplicationRule --description "Azure Monitor" \
        --target-fqdns '*.opinsights.azure.com' '*.azure-automation.net' --source-addresses '*' --protocols Https=443 -o none

    # Create Azure Firewalls in the virtual hubs and configure static routes to firewall in the VWAN hub route tables
    echo "Creating Azure Firewall in hub1..."
    az network firewall create -n azfw1 -g $rg --vhub hub1 --policy $azfw_policy_name -l $location1 --sku AZFW_Hub --public-ip-count 1 -o none
    azfw1_id=$(az network firewall show -n azfw1 -g $rg --query id -o tsv)
    if [[ "$create_routes" == "yes" ]]; then
        echo "Creating static routes in hub1..."
        az network vhub route-table route add -n defaultRouteTable --vhub-name hub1 -g $rg \
            --route-name default --destination-type CIDR --destinations "0.0.0.0/0" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" \
            --next-hop-type ResourceId --next-hop $azfw1_id -o none
        if [[ "$create_custom_rt" == "yes" ]]; then
            az network vhub route-table route add -n hub1Vnet --vhub-name hub1 -g $rg \
                --route-name default --destination-type CIDR --destinations "0.0.0.0/0" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" \
                --next-hop-type ResourceId --next-hop $azfw1_id -o none
        fi
    fi
    if [[ "$no_of_hubs" == "2" ]]
    then
        echo "Creating Azure Firewall in hub2..."
        az network firewall create -n azfw2 -g $rg --vhub hub2 --policy $azfw_policy_name -l $location2 --sku AZFW_Hub --public-ip-count 1 -o none
        azfw2_id=$(az network firewall show -n azfw2 -g $rg --query id -o tsv)
        if [[ "$create_routes" == "yes" ]]; then
            echo "Creating static routes in hub2..."
            az network vhub route-table route add -n defaultRouteTable --vhub-name hub2 -g $rg \
                --route-name default --destination-type CIDR --destinations '0.0.0.0/0' '10.0.0.0/8' '172.16.0.0/12' '192.168.0.0/16' \
                --next-hop-type ResourceId --next-hop $azfw2_id -o none
            if [[ "$create_custom_rt" == "yes" ]]; then
                az network vhub route-table route add -n hub2Vnet --vhub-name hub2 -g $rg \
                    --route-name default --destination-type CIDR --destinations '0.0.0.0/0' '10.0.0.0/8' '172.16.0.0/12' '192.168.0.0/16' \
                    --next-hop-type ResourceId --next-hop $azfw2_id -o none
            fi
        fi
    fi

    # Azure Firewalls
    echo "Configuring Azure Firewalls for logging..."
    fw_id_list=$(az network firewall list -g $rg --query '[].id' -o tsv)
    while IFS= read -r fw_id; do
        # --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
        az monitor diagnostic-settings create -n mydiag --resource $fw_id --workspace $logws_id \
            --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
            --logs '[{"category": "AzureFirewallApplicationRule", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                    {"category": "AzureFirewallNetworkRule", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' -o none
    done <<< "$fw_id_list"
fi

# Create cloudinit file
# - Installing apache to use to verify TCP on port 80
# - Enabling OS IP fwding everywhere, even if it is not really needed
cloudinit_file=/tmp/cloudinit.txt
cat <<EOF > $cloudinit_file
#cloud-config
package_upgrade: true
packages:
  - apache2
runcmd:
  - sysctl -w net.ipv4.ip_forward=1
EOF

# Create spokes
for spoke in $(seq 1 ${no_of_spokes})
do
    create_spoke 1 $spoke
done
if [[ "$no_of_hubs" == "2" ]]
then
    for spoke in $(seq 1 ${no_of_spokes})
    do
        create_spoke 2 $spoke
    done
fi

# Backdoor for access from the testing device over the Internet
myip=$(curl -s4 ifconfig.co)
echo "Creating RT for spokes in $location1..."
az network route-table create -n spokes-$location1 -g $rg -l $location1 -o none
az network route-table route create -n mypc -g $rg --route-table-name spokes-$location1 --address-prefix "${myip}/32" --next-hop-type Internet -o none
for spoke in $(seq 1 ${no_of_spokes})
do
    echo "Associating VNet spoke1${spoke}-${location1} to RT spokes-$location1..."
    az network vnet subnet update -n vm --vnet-name spoke1${spoke}-${location1} -g $rg --route-table spokes-$location1 -o none
done
if [[ "$no_of_hubs" == "2" ]]
then
    if [[ "$location1" != "$location2" ]]
    then
    echo "Creating RT for spokes in $location2..."
        az network route-table create -n spokes-$location2 -g $rg -l $location2 -o none
        az network route-table route create -n mypc -g $rg --route-table-name spokes-$location2 --address-prefix "${myip}/32" --next-hop-type Internet -o none
    fi
    for spoke in $(seq 1 ${no_of_spokes})
    do
        echo "Associating VNet spoke2${spoke}-${location1} to RT spokes-$location2..."
        az network vnet subnet update -n vm --vnet-name spoke2${spoke}-${location2} -g $rg --route-table spokes-$location2 -o none
    done
fi

# Optional: route through NVA (convert VM  to NVA and add static route in defaultRT)
# I think this is redundant? Commenting out for the time being...
# if [[ "$route_thru_nva" == "yes" ]]
# then
#     nva_spoke_id=$no_of_spokes
#     # Hub 1: Configure IP fwding for the NVAs
#     vm_name="spoke1${nva_spoke_id}-vm"
#     echo "Enabling IP Forwarding for ${vm_name}..."
#     vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
#     az network nic update --ids $vm_nic_id --ip-forwarding -o none
#     # Hub 2: Configure IP fwding for the NVAs
#     if [[ "$no_of_hubs" == "2" ]]
#     then
#         vm_name="spoke2${nva_spoke_id}-vm"
#         echo "Enabling IP Forwarding for ${vm_name}..."
#         vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
#         echo "Enabling IP forwarding for VM $vm and NIC $vm_nic_id..."
#         az network nic update --ids $vm_nic_id --ip-forwarding -o none
#     fi
#     # Hub 1: Configure NVA VNet connection to not learn the default route, and add route to route-table
#     cx_name="spoke1${nva_spoke_id}"
#     cx_id=$(az network vhub connection show --vhub-name hub1 -g $rg -n $cx_name --query id -o tsv)
#     echo "Adding default route to defaultRouteTable in hub1..."
#     az network vhub route-table route add -n defaultRouteTable -g $rg --vhub-name hub1 --destination-type CIDR --destinations "0.0.0.0/0" --next-hop-type ResourceId --next-hop $cx_id --route-name default -o none
#     az network vhub connection update --ids $cx_id --set "enableInternetSecurity=false" -o none
#     # Hub 1: Adding route to Vnet connection
#     vm_name="spoke1${nva_spoke_id}-vm"
#     echo "Finding out IP address for NVA ${vm_name}..."
#     vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
#     nva_ip=$(az network nic show --ids $vm_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv)
#     echo "Private IP address for ${vm_name} is ${nva_ip}"
#     vnet_route="{
#         \"name\": \"default\",
#         \"nextHopIpAddress\": \"${nva_ip}\",
#         \"addressPrefixes\": [ \"0.0.0.0/0\" ]}"
#     # Delete all existing routes in the VNet connection
#     vnet_route_name=$(az network vhub connection show --ids $cx_id --query 'routingConfiguration.vnetRoutes.staticRoutes[0].name' -o tsv)
#     while [[ -n "$vnet_route_name" ]]
#     do
#         # If there was a route, delete it first
#         echo "Previous route $vnet_route_name detected, deleting first..."
#         az network vhub connection update --ids $cx_id --remove "routingConfiguration.vnetRoutes.staticRoutes" "0" -o none
#         vnet_route_name=$(az network vhub connection show --ids $cx_id --query 'routingConfiguration.vnetRoutes.staticRoutes[0].name' -o tsv)
#     done
#     echo "Creating static route in connection $cx_id with next hop ${nva_ip}..."
#     az network vhub connection update --ids $cx_id --add "routingConfiguration.vnetRoutes.staticRoutes" $vnet_route -o none
#     # Hub 2: Configure NVA VNet connection to not learn the default route, and add route to route-table
#     if [[ "$no_of_hubs" == "2" ]]
#     then
#         cx_name="spoke2${nva_spoke_id}"
#         cx_id=$(az network vhub connection show --vhub-name hub2 -g $rg -n $cx_name --query id -o tsv)
#         echo "Adding default route to defaultRouteTable in hub2..."
#         az network vhub route-table route add -n defaultRouteTable -g $rg --vhub-name hub2 --destination-type CIDR --destinations "0.0.0.0/0" --next-hop-type ResourceId --next-hop $cx_id --route-name default -o none
#         az network vhub connection update --ids $cx_id --set "enableInternetSecurity=false" -o none
#         # Hub 2: Adding route to Vnet connection
#         vm_name="spoke2${nva_spoke_id}-vm"
#         echo "Finding out IP address for NVA ${vm_name}..."
#         vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
#         nva_ip=$(az network nic show --ids $vm_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv)
#         echo "Private IP address for ${vm_name} is ${nva_ip}"
#         vnet_route="{
#             \"name\": \"default\",
#             \"nextHopIpAddress\": \"${nva_ip}\",
#             \"addressPrefixes\": [ \"0.0.0.0/0\" ]}"
#         # Delete all existing routes in the VNet connection
#         vnet_route_name=$(az network vhub connection show --ids $cx_id --query 'routingConfiguration.vnetRoutes.staticRoutes[0].name' -o tsv)
#         while [[ -n "$vnet_route_name" ]]
#         do
#             # If there was a route, delete it first
#             echo "Previous route $vnet_route_name detected, deleting first..."
#             az network vhub connection update --ids $cx_id --remove "routingConfiguration.vnetRoutes.staticRoutes" "0" -o none
#             vnet_route_name=$(az network vhub connection show --ids $cx_id --query 'routingConfiguration.vnetRoutes.staticRoutes[0].name' -o tsv)
#         done
#         echo "Creating static route in connection $cx_id with next hop ${nva_ip}..."
#         az network vhub connection update --ids $cx_id --add "routingConfiguration.vnetRoutes.staticRoutes" $vnet_route -o none
#     fi
#     # Hub 1: configure IP fwding and NAT on NVAs
#     vm_name="spoke1${nva_spoke_id}-vm"
#     echo "Finding out public IP address for NVA ${vm_name}..."
#     vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
#     nva_pip_id=$(az network nic show --ids $vm_nic_id --query 'ipConfigurations[0].publicIpAddress.id' -o tsv)
#     nva_pip=$(az network public-ip show --ids $nva_pip_id --query 'ipAddress' -o tsv)
#     echo "Public IP address for ${vm_name} is ${nva_pip}. Configuring IP forwarding and SNAT at OS level..."
#     ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$nva_pip" "sudo sysctl -w net.ipv4.ip_forward=1"
#     ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$nva_pip" "sudo iptables -t nat -A POSTROUTING ! -d 10.0.0.0/8 -o eth0 -j MASQUERADE"
#     # Hub 2: configure IP fwding and NAT on NVAs
#     if [[ "$no_of_hubs" == "2" ]]
#     then
#         vm_name="spoke2${nva_spoke_id}-vm"
#         echo "Finding out public IP address for NVA ${vm_name}..."
#         vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
#         nva_pip_id=$(az network nic show --ids $vm_nic_id --query 'ipConfigurations[0].publicIpAddress.id' -o tsv)
#         nva_pip=$(az network public-ip show --ids $nva_pip_id --query 'ipAddress' -o tsv)
#         echo "Public IP address for ${vm_name} is ${nva_pip}. Configuring IP forwarding and SNAT at OS level..."
#         ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$nva_pip" "sudo sysctl -w net.ipv4.ip_forward=1"
#         ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$nva_pip" "sudo iptables -t nat -A POSTROUTING ! -d 10.0.0.0/8 -o eth0 -j MASQUERADE"
#     fi
# fi

# Optional: additional spokes with NVA and 2 indirect spokes attached to them
if [[ "$indirect_spokes" == "yes" ]]
then
    indirect_spoke_id=$((no_of_spokes+1))
    # Create VMs and VNets
    echo "Creating NVA spoke 1${indirect_spoke_id} and indirect spokes 1${indirect_spoke_id}1 and 1${indirect_spoke_id}2..."
    create_spoke 1 ${indirect_spoke_id}
    create_spoke 1 ${indirect_spoke_id}1 no
    create_spoke 1 ${indirect_spoke_id}2 no
    if [[ "$no_of_hubs" == "2" ]]
    then
        echo "Creating NVA spoke 2${indirect_spoke_id} and indirect spokes 2${indirect_spoke_id}1 and 2${indirect_spoke_id}2..."
        create_spoke 2 ${indirect_spoke_id}
        create_spoke 2 ${indirect_spoke_id}1 no
        create_spoke 2 ${indirect_spoke_id}2 no
    fi

    # Indirect spoke peerings
    echo "Creating VNet peerings to indirect spokes..."
    az network vnet peering create -n 1${indirect_spoke_id}1to1${indirect_spoke_id} -g $rg --vnet-name spoke1${indirect_spoke_id}1-${location1} --remote-vnet spoke1${indirect_spoke_id}-${location1} --allow-vnet-access --allow-forwarded-traffic -o none
    az network vnet peering create -n 1${indirect_spoke_id}2to1${indirect_spoke_id} -g $rg --vnet-name spoke1${indirect_spoke_id}2-${location1} --remote-vnet spoke1${indirect_spoke_id}-${location1} --allow-vnet-access --allow-forwarded-traffic -o none
    az network vnet peering create -n 1${indirect_spoke_id}to1${indirect_spoke_id}1 -g $rg --vnet-name spoke1${indirect_spoke_id}-${location1} --remote-vnet spoke1${indirect_spoke_id}1-${location1} --allow-vnet-access --allow-forwarded-traffic -o none
    az network vnet peering create -n 1${indirect_spoke_id}to1${indirect_spoke_id}2 -g $rg --vnet-name spoke1${indirect_spoke_id}-${location1} --remote-vnet spoke1${indirect_spoke_id}2-${location1} --allow-vnet-access --allow-forwarded-traffic -o none
    if [[ "$no_of_hubs" == "2" ]]
    then
        az network vnet peering create -n 2${indirect_spoke_id}1to2${indirect_spoke_id} -g $rg --vnet-name spoke2${indirect_spoke_id}1-${location2} --remote-vnet spoke2${indirect_spoke_id}-${location2} --allow-vnet-access --allow-forwarded-traffic -o none
        az network vnet peering create -n 2${indirect_spoke_id}2to2${indirect_spoke_id} -g $rg --vnet-name spoke2${indirect_spoke_id}2-${location2} --remote-vnet spoke2${indirect_spoke_id}-${location2} --allow-vnet-access --allow-forwarded-traffic -o none
        az network vnet peering create -n 24to2${indirect_spoke_id}1 -g $rg --vnet-name spoke2${indirect_spoke_id}-${location2} --remote-vnet spoke2${indirect_spoke_id}1-${location2} --allow-vnet-access --allow-forwarded-traffic -o none
        az network vnet peering create -n 24to2${indirect_spoke_id}2 -g $rg --vnet-name spoke2${indirect_spoke_id}-${location2} --remote-vnet spoke2${indirect_spoke_id}2-${location2} --allow-vnet-access --allow-forwarded-traffic -o none
    fi
    # Configure IP forwarding in the NVA NICs
    echo "Configuring IP forwarding in NVA NICs..."
    vm_names=("spoke1${indirect_spoke_id}-vm" "spoke2${indirect_spoke_id}-vm")
    for vm_name in ${vm_names[@]}; do
        echo "Enabling IP forwarding for $vm_name..."
        vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        az network nic update --ids $vm_nic_id --ip-forwarding -o none
    done
    # Route table for indirect spokes 1${indirect_spoke_id}1/1${indirect_spoke_id}2
    echo "Creating route tables for indirect spokes with default route pointing to the NVA..."
    myip=$(curl -s4 ifconfig.co)
    nva1_nic_id=$(az vm show -n spoke1${indirect_spoke_id}-vm -g "$rg" --query 'networkProfile.networkInterfaces[0].id' -o tsv)
    nva1_ip=$(az network nic show --ids $nva1_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv)
    az network route-table create -n indirectspokes-$location1 -g $rg -l $location1 -o none
    az network route-table route create -n default -g $rg --route-table-name indirectspokes-$location1 \
        --address-prefix "0.0.0.0/0" --next-hop-type VirtualAppliance --next-hop-ip-address $nva1_ip -o none
    az network route-table route create -n mypc -g $rg --route-table-name indirectspokes-$location1 \
        --address-prefix "${myip}/32" --next-hop-type Internet -o none
    az network vnet subnet update -n vm --vnet-name spoke1${indirect_spoke_id}1-${location1} -g $rg --route-table indirectspokes-$location1 -o none
    az network vnet subnet update -n vm --vnet-name spoke1${indirect_spoke_id}2-${location1} -g $rg --route-table indirectspokes-$location1 -o none
    if [[ "$no_of_hubs" == "2" ]]
    then
        nva2_nic_id=$(az vm show -n spoke2${indirect_spoke_id}-vm -g "$rg" --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        nva2_ip=$(az network nic show --ids $nva2_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv)
        az network route-table create -n indirectspokes-$location2 -g $rg -l $location2 -o none
        az network route-table route create -n default -g $rg --route-table-name indirectspokes-$location2 \
            --address-prefix "0.0.0.0/0" --next-hop-type VirtualAppliance --next-hop-ip-address $nva2_ip -o none
        az network route-table route create -n mypc -g $rg --route-table-name indirectspokes-$location2 \
            --address-prefix "${myip}/32" --next-hop-type Internet -o none
        az network vnet subnet update -n vm --vnet-name spoke2${indirect_spoke_id}1-${location2} -g $rg --route-table indirectspokes-$location2 -o none
        az network vnet subnet update -n vm --vnet-name spoke2${indirect_spoke_id}2-${location2} -g $rg --route-table indirectspokes-$location2 -o none
    fi
    # RT with backdoor for nva spokes and default to Internet
    echo "Creating route tables for the NVAs and adding default routing to the Internet..."
    az network route-table create -n nva1${indirect_spoke_id}-$location1 -g $rg -l $location1 -o none
    az network route-table route create -n default -g $rg --route-table-name nva1${indirect_spoke_id}-$location1 \
        --address-prefix "0.0.0.0/0" --next-hop-type Internet -o none
    az network vnet subnet update -n vm --vnet-name spoke1${indirect_spoke_id}-$location1 -g $rg --route-table nva1${indirect_spoke_id}-$location1 -o none
    if [[ "$no_of_hubs" == "2" ]]
    then
        az network route-table create -n nva2${indirect_spoke_id}-$location2 -g $rg -l $location2 -o none
        az network route-table route create -n default -g $rg --route-table-name nva2${indirect_spoke_id}-$location2 \
            --address-prefix "0.0.0.0/0" --next-hop-type Internet -o none
        az network vnet subnet update -n vm --vnet-name spoke2${indirect_spoke_id}-$location2 -g $rg --route-table nva2${indirect_spoke_id}-$location2 -o none
    fi
    # Install BIRD in the NVAs
    echo "Installing BIRD in NVAs..."
    if [[ "$no_of_hubs" == "1" ]]
    then
        vm_names=( "spoke1${indirect_spoke_id}-vm" )
    else
        vm_names=("spoke1${indirect_spoke_id}-vm" "spoke2${indirect_spoke_id}-vm")
    fi
    for vm_name in ${vm_names[@]}; do
        echo "Installing BIRD in VM $vm_name..."
        nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        pip_id=$(az network nic show --ids $nic_id --query 'ipConfigurations[0].publicIpAddress.id' -o tsv)
        vm_pip=$(az network public-ip show --ids $pip_id --query 'ipAddress' -o tsv)
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $vm_pip "sudo apt update && sudo apt install -y bird"
    done
fi

# VMs in VPN branches
if [[ "$deploy_vpngw" == "yes" ]]
then
    # VM in branch1
    az vm create -n branch1-vm -g $rg -l $location1 --image ubuntuLTS --admin-username $username --generate-ssh-keys \
        --public-ip-address branch1-vm-pip --public-ip-sku Standard --vnet-name branch1 --nsg $nsg1_name --size $vm_size \
        --subnet vm --subnet-address-prefix $branch1_vm_subnet --custom-data $cloudinit_file -o none
    az vm extension set --vm-name branch1-vm -g $rg -n NetworkWatcherAgentLinux --publisher Microsoft.Azure.NetworkWatcher --version 1.4 -o none
    az network route-table create -n branch1vm-$location1 -g $rg -l $location1 -o none
    myip=$(curl -s4 ifconfig.co)
    az network route-table route create -n mypc -g $rg --route-table-name branch1vm-$location1 \
        --address-prefix "${myip}/32" --next-hop-type Internet -o none
    az network route-table route create -n default -g $rg --route-table-name branch1vm-$location1 \
        --address-prefix "0.0.0.0/0" --next-hop-type VirtualAppliance --next-hop-ip-address $branch1_bgp_ip -o none
    az network vnet subnet update -n vm --vnet-name branch1 -g $rg --route-table branch1vm-$location1 -o none
    # VM in branch2
    if [[ "$no_of_hubs" == "2" ]]
    then
        az vm create -n branch2-vm -g $rg -l $location2 --image ubuntuLTS --admin-username $username --generate-ssh-keys \
            --public-ip-address branch2-vm-pip --public-ip-sku Standard --vnet-name branch2 --nsg $nsg2_name --size $vm_size \
            --subnet vm --subnet-address-prefix $branch2_vm_subnet --custom-data $cloudinit_file -o none
        az vm extension set --vm-name branch2-vm -g $rg -n NetworkWatcherAgentLinux --publisher Microsoft.Azure.NetworkWatcher --version 1.4 -o none
        az network route-table create -n branch2vm-$location2 -g $rg -l $location2 -o none
        az network route-table route create -n mypc -g $rg --route-table-name branch2vm-$location2 \
            --address-prefix "${myip}/32" --next-hop-type Internet -o none
        az network route-table route create -n default -g $rg --route-table-name branch2vm-$location2 \
            --address-prefix "0.0.0.0/0" --next-hop-type VirtualAppliance --next-hop-ip-address $branch2_bgp_ip -o none
        az network vnet subnet update -n vm --vnet-name branch2 -g $rg --route-table branch2vm-$location2 -o none
    fi
    # Configure IP forwarding in the CSR NICs
    if [[ "$no_of_hubs" == "2" ]]
    then
        vm_names=("branch1-nva")
    else
        vm_names=("branch1-nva" "branch2-nva")
    fi
    for vm_name in ${vm_names[@]}; do
        echo "Enabling IP forwarding for $vm_name..."
        vm_nic_id=$(az vm show -n $vm_name -g $rg --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        az network nic update --ids $vm_nic_id --ip-forwarding -o none
    done
fi

# Optional: configure BGP in the NVAs in NVA spokes to VWAN
if [[ "$nva_bgp" == "yes" ]]
then
    # Variables
    echo "Getting information about NVA in spoke 1${indirect_spoke_id}..."
    username=$(whoami)
    nva1_nic_id=$(az vm show -n "spoke1${indirect_spoke_id}-vm" -g "$rg" --query 'networkProfile.networkInterfaces[0].id' -o tsv)
    nva1_ip=$(az network nic show --ids $nva1_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv) && echo "$nva1_ip"
    nva1_pip=$(az network public-ip show -n "spoke1${indirect_spoke_id}-pip" -g $rg --query ipAddress -o tsv) && echo "$nva1_pip"
    nva1_default_gw="10.1.${indirect_spoke_id}.1"
    nva1_asn="6501${indirect_spoke_id}"
    echo "Getting information about the Route Service in hub1..."
    hub1_rs_ip1=$(az network vhub show -n hub1 -g $rg --query 'virtualRouterIps[0]' -o tsv) && echo $hub1_rs_ip1
    hub1_rs_ip2=$(az network vhub show -n hub1 -g $rg --query 'virtualRouterIps[1]' -o tsv) && echo $hub1_rs_ip2
    hub1_rs_asn=$(az network vhub show -n hub1 -g $rg --query 'virtualRouterAsn' -o tsv) && echo $hub1_rs_asn
    echo "Configuring static route in NVA1 for the hub address space $vwan_hub1_prefix"
    ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes "$nva1_pip" "sudo ip route add $vwan_hub1_prefix via $nva1_default_gw"
    # if [[ "$nva_in_hub2" == "yes" ]] && [[ "$no_of_hubs" == "2" ]]
    if [[ "$no_of_hubs" == "2" ]]
    then
        echo "Getting information about NVA in spoke 2${indirect_spoke_id}..."
        nva2_nic_id=$(az vm show -n "spoke2${indirect_spoke_id}-vm" -g "$rg" --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        nva2_ip=$(az network nic show --ids $nva2_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv) && echo "$nva2_ip"
        nva2_pip=$(az network public-ip show -n "spoke2${indirect_spoke_id}-pip" -g $rg --query ipAddress -o tsv) && echo "$nva2_pip"
        nva2_default_gw="10.2.${indirect_spoke_id}.1"
        nva2_asn="6502${indirect_spoke_id}"
        echo "Getting information about the Route Service in hub2..."
        hub2_rs_ip1=$(az network vhub show -n hub2 -g $rg --query 'virtualRouterIps[0]' -o tsv) && echo $hub2_rs_ip1
        hub2_rs_ip2=$(az network vhub show -n hub2 -g $rg --query 'virtualRouterIps[1]' -o tsv) && echo $hub2_rs_ip2
        hub2_rs_asn=$(az network vhub show -n hub2 -g $rg --query 'virtualRouterAsn' -o tsv) && echo $hub2_rs_asn
        echo "Configuring static route in NVA2 for the hub address space $vwan_hub2_prefix"
        ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes "$nva2_pip" "sudo ip route add $vwan_hub2_prefix via $nva2_default_gw"
    fi
    # spoke14-vm config
    bird_config_file="/tmp/bird1${indirect_spoke_id}.conf"
    cat <<EOF > $bird_config_file
log syslog all;
router id $nva1_ip;
protocol device {
        scan time 10;
}
protocol direct {
    disabled;
}
protocol kernel {
    preference 254;
    learn;
    merge paths on;
    export all;
    import all;
    #export none;
    #disabled;
}
protocol static {
    # route 1${indirect_spoke_id}.1${indirect_spoke_id}.1${indirect_spoke_id}.1${indirect_spoke_id}/32 via $nva1_default_gw;   # Test route
    route 10.1.${indirect_spoke_id}1.0/24 via $nva1_default_gw; # Route to spoke1${spoke}1
    route 10.1.${indirect_spoke_id}2.0/24 via $nva1_default_gw; # Route to spoke1${spoke}2
}
protocol bgp rs0 {
    description "VWAN Route Service instance 0";
    multihop;
    local $nva1_ip as $nva1_asn;
    neighbor $hub1_rs_ip1 as $hub1_rs_asn;
        import filter {accept;};
        export filter {accept;};
}
protocol bgp rs1 {
    description "VWAN Route Service instance 1";
    multihop;
    local $nva1_ip as $nva1_asn;
    neighbor $hub1_rs_ip2 as $hub1_rs_asn;
        import filter {accept;};
        export filter {accept;};
}
EOF
    echo "Copying BIRD config file to NVA in spoke 1${indirect_spoke_id}..."
    scp $bird_config_file "${nva1_pip}:/home/${username}/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo mv /home/${username}/bird.conf /etc/bird/bird.conf"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo systemctl restart bird"

    if [[ "$no_of_hubs" == "2" ]]
    then
        # Get information
        nva2_nic_id=$(az vm show -n "spoke2${indirect_spoke_id}-vm" -g "$rg" --query 'networkProfile.networkInterfaces[0].id' -o tsv)
        nva2_ip=$(az network nic show --ids $nva2_nic_id --query 'ipConfigurations[0].privateIpAddress' -o tsv) && echo "$nva2_ip"
        nva2_pip=$(az network public-ip show -n "spoke2${indirect_spoke_id}-pip" -g $rg --query ipAddress -o tsv) && echo "$nva2_pip"
        nva2_default_gw="10.2.${indirect_spoke_id}.1"
        nva2_asn="6501${indirect_spoke_id}"
        echo "Getting information about the Route Service in hub2..."
        hub2_rs_ip1=$(az network vhub show -n hub2 -g $rg --query 'virtualRouterIps[0]' -o tsv) && echo $hub2_rs_ip1
        hub2_rs_ip2=$(az network vhub show -n hub2 -g $rg --query 'virtualRouterIps[1]' -o tsv) && echo $hub2_rs_ip2
        hub2_rs_asn=$(az network vhub show -n hub2 -g $rg --query 'virtualRouterAsn' -o tsv) && echo $hub2_rs_asn
        echo "Configuring static route in NVA1 for the hub address space $vwan_hub2_prefix"
        ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes "$nva2_pip" "sudo ip route add $vwan_hub2_prefix via $nva2_default_gw"

        # NVA in spoke24-vm config
        bird_config_file=/tmp/bird2${indirect_spoke_id}.conf
        cat <<EOF > $bird_config_file
log syslog all;
router id $nva2_ip;
protocol device {
        scan time 10;
}
protocol direct {
    disabled;
}
protocol kernel {
    preference 254;
    learn;
    merge paths on;
    export all;
    import all;
    #export none;
    #disabled;
}
protocol static {
    # route 2${indirect_spoke_id}.2${indirect_spoke_id}.2${indirect_spoke_id}.2${indirect_spoke_id}/32 via $nva2_default_gw;   # Test route
    route 10.2.${indirect_spoke_id}1.0/24 via $nva2_default_gw; # Route to spoke2${spoke}1
    route 10.2.${indirect_spoke_id}2.0/24 via $nva2_default_gw; # Route to spoke2${spoke}2
}
protocol bgp rs0 {
    description "VWAN Route Service instance 0";
    multihop;
    local $nva2_ip as $nva2_asn;
    neighbor $hub2_rs_ip1 as $hub2_rs_asn;
        import filter {accept;};
        export filter {accept;};
}
protocol bgp rs1 {
    description "VWAN Route Service instance 1";
    multihop;
    local $nva2_ip as $nva2_asn;
    neighbor $hub2_rs_ip2 as $hub2_rs_asn;
        import filter {accept;};
        export filter {accept;};
}
EOF
        echo "Copying BIRD config file to NVA in spoke 2${indirect_spoke_id}..."
        scp $bird_config_file "${nva2_pip}:/home/${username}/bird.conf"
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo mv /home/${username}/bird.conf /etc/bird/bird.conf"
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo systemctl restart bird"
    fi
    # Now configure the VWAN side
    nva1_cx_id=$(az network vhub connection show -n "spoke1${indirect_spoke_id}" --vhub-name hub1 -g $rg -o tsv --query id)
    echo "Creating BGP peering to hub1..."
    az network vhub bgpconnection create -n spoke1${indirect_spoke_id} -g $rg --vhub-name hub1 --peer-asn "$nva1_asn" --peer-ip "$nva1_ip" --vhub-conn "$nva1_cx_id" -o none
    if [[ "$no_of_hubs" == "2" ]]
    then
        nva2_cx_id=$(az network vhub connection show -n spoke2${indirect_spoke_id} --vhub-name hub2 -g $rg -o tsv --query id)
        echo "Creating BGP peering to hub2..."
        az network vhub bgpconnection create -n spoke2${indirect_spoke_id} -g $rg --vhub-name hub2 --peer-asn "$nva2_asn" --peer-ip "$nva2_ip" --vhub-conn "$nva2_cx_id" -o none
    fi
    # Wait
    echo "Waiting 30 seconds for BGP to come up..."
    sleep 30
    # Diagnostics for NVA in hub1
    echo "Performing some checks on NVA in spoke1${indirect_spoke_id}..."
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo birdc show protocols"
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo birdc show route protocol rs0"
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo birdc show route export rs0"
    az network nic show-effective-route-table --ids $nva1_nic_id -o table
    # Diagnostics for NVA attached to hub2
    # if [[ "$nva_in_hub2" == "yes" ]] && [[ "$no_of_hubs" == "2" ]]
    if [[ "$no_of_hubs" == "2" ]]
    then
        echo "Performing some checks on NVA in spoke2${indirect_spoke_id}..."
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo birdc show protocols"
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo birdc show route protocol rs0"
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo birdc show route export rs0"
        az network nic show-effective-route-table --ids $nva2_nic_id -o table
    fi
fi

# Optional: enable/disable SNAT in the NVAs
if [[ "$indirect_spokes" == "yes" ]]
then
    nva1_pip=$(az network public-ip show -n "spoke1${indirect_spoke_id}-pip" -g $rg --query ipAddress -o tsv)
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -t nat -A POSTROUTING ! -d '10.0.0.0/8' -o eth0 -j MASQUERADE"
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -t nat -D POSTROUTING ! -d '10.0.0.0/8' -o eth0 -j MASQUERADE"
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE"
    echo "Current NAT configuration in NVA in spoke 1${indirect_spoke_id}:"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -L -t nat"
    # Optional: enable/disable a rule to drop ICMP traffic in the NVA
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -A INPUT -p ICMP --icmp-type 8 -j DROP"
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -A FORWARD -p ICMP --icmp-type 8 -j DROP"
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -D INPUT -p ICMP --icmp-type 8 -j DROP"
    # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -D FORWARD -p ICMP --icmp-type 8 -j DROP"
    echo "Current iptables rules in NVA in spoke 1${indirect_spoke_id}:"
    ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva1_pip "sudo iptables -L"
    if [[ "$no_of_hubs" == "2" ]]
    then
        nva2_pip=$(az network public-ip show -n "spoke2${indirect_spoke_id}-pip" -g $rg --query ipAddress -o tsv)
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -t nat -A POSTROUTING ! -d '10.0.0.0/8' -o eth0 -j MASQUERADE"
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -t nat -D POSTROUTING ! -d '10.0.0.0/8' -o eth0 -j MASQUERADE"
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE"
        echo "Current NAT configuration in NVA in spoke 2${indirect_spoke_id}:"
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -L -t nat"
        # Optional: enable/disable a rule to drop ICMP traffic in the NVA
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -A INPUT -p ICMP --icmp-type 8 -j DROP"
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -A FORWARD -p ICMP --icmp-type 8 -j DROP"
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -D INPUT -p ICMP --icmp-type 8 -j DROP"
        # ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -D FORWARD -p ICMP --icmp-type 8 -j DROP"
        echo "Current iptables rules in NVA in spoke 2${indirect_spoke_id}:"
        ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $nva2_pip "sudo iptables -L"
    fi
fi

# Optional: add some VMs with public IPs
# This can be used to test AzFW default SNAT behavior
if [[ "$public_ip" == "yes" ]]
then
    # Add public subnet to branch1
    new_subnet=21.21.21.0/24
    new_subnet_long="21.21.21.0 255.255.255.0"
    new_subnet_name=public
    vm_name=branch1-vm2
    az network vnet update -n branch1 -g $rg --address-prefixes $branch1_prefix $new_subnet
    az vm create -n $vm_name -g $rg -l $location1 --image ubuntuLTS --admin-username $username --generate-ssh-keys \
        --public-ip-address ${vm_name}-pip --public-ip-sku Standard --vnet-name branch1 --nsg $nsg1_name --size $vm_size \
        --subnet $new_subnet_name --subnet-address-prefix $new_subnet --custom-data $cloudinit_file
    az vm extension set --vm-name $vm_name -g $rg -n NetworkWatcherAgentLinux --publisher Microsoft.Azure.NetworkWatcher --version 1.4
    az network vnet subnet update -n $new_subnet_name --vnet-name branch1 -g $rg --route-table branch1vm-$location1
    default_gateway=$branch1_gateway
    branch1_ip=$(az network public-ip show -n branch1-pip -g $rg --query ipAddress -o tsv)
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no $branch1_ip <<EOF
config t
    ip prefix-list S2B permit ${new_subnet}
    ip route ${new_subnet_long} ${default_gateway}
end
wr mem
EOF

    # Add public subnet to branch2
    new_subnet=22.22.22.0/24
    new_subnet_long="22.22.22.0 255.255.255.0"
    new_subnet_name=public
    vm_name=branch2-vm2
    az network vnet update -n branch2 -g $rg --address-prefixes $branch2_prefix $new_subnet
    az vm create -n $vm_name -g $rg -l $location2 --image ubuntuLTS --admin-username $username --generate-ssh-keys \
        --public-ip-address ${vm_name}-pip --public-ip-sku Standard --vnet-name branch2 --nsg $nsg2_name --size $vm_size \
        --subnet $new_subnet_name --subnet-address-prefix $new_subnet --custom-data $cloudinit_file
    az vm extension set --vm-name $vm_name -g $rg -n NetworkWatcherAgentLinux --publisher Microsoft.Azure.NetworkWatcher --version 1.4
    az network vnet subnet update -n $new_subnet_name --vnet-name branch2 -g $rg --route-table branch2vm-$location2
    default_gateway=$branch2_gateway
    branch2_ip=$(az network public-ip show -n branch2-pip -g $rg --query ipAddress -o tsv)
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no $branch2_ip <<EOF
config t
    ip prefix-list S2B permit ${new_subnet}
    ip route ${new_subnet_long} ${default_gateway}
end
wr mem
EOF
fi

# Optional: deploy NVA in the hubs
if [[ "$nva_in_hub1" == "yes" ]]
then
    echo "Deploying NVA in hub 1..."
    create_hub_nva 1
    #configure_hub_nva_bgp 1    # If no branches (only configures BGP to RS)
    create_hub_nva_branch 1     # Takes care as well of the BGP config to the RS, so previous command is redundant
fi
if [[ "$nva_in_hub2" == "yes" ]] && [[ "$no_of_hubs" == "2" ]]
then
    echo "Deploying NVA in hub 2..."
    create_hub_nva 2
    #configure_hub_nva_bgp 2    # If no branches (only configures BGP to RS)
    create_hub_nva_branch 2     # Takes care as well of the BGP config to the RS, so previous command is redundant
fi

# Optional: ExpressRoute
if [[ "$deploy_er" == "yes" ]]
then
    # Create VWAN ER and circuits
    echo "Creating ER gateway in hub1..."
    az network express-route gateway create -g $rg -n hub1ergw --virtual-hub hub1 -l $location1 -o none
    echo "Creating ER circuit in $hub1_er_pop"
    az network express-route create -n $hub1_er_circuit_name --peering-location $hub1_er_pop -g $rg \
        --bandwidth 50 Mbps --provider $er_provider -l $location1 --sku-family MeteredData --sku-tier $er_circuit_sku -o none
    service_key_1=$(az network express-route show -n $hub1_er_circuit_name -g $rg --query serviceKey -o tsv) && echo "Service Key is $service_key_1"
    if [[ "$no_of_hubs" == "2" ]]
    then
        echo "Creating ER gateway in hub2..."
        az network express-route gateway create -g $rg -n hub2ergw --virtual-hub hub2 -l $location2 -o none
        echo "Creating ER circuit in $hub2_er_pop"
        az network express-route create -n $hub2_er_circuit_name --peering-location $hub2_er_pop -g $rg \
            --bandwidth 50 Mbps --provider $er_provider -l $location2 --sku-family MeteredData --sku-tier $er_circuit_sku -o none
        service_key_2=$(az network express-route show -n $hub2_er_circuit_name -g $rg --query serviceKey -o tsv) && echo "Service Key is $service_key_2"
    fi
    # Provision Megaport MCR in locations for hub1/hub2 (it could be the same)
    if [[ -e "$megaport_script_path" ]]
    then
        echo "Creating MCR in $hub1_er_pop..."
        $megaport_script_path -s=jomore-${hub1_er_pop} -a=create_mcr -k=$service_key_1 --asn=$mcr1_asn
        sleep 120  # Wait 1 minute before creating the connections. This could be replaced with a loop checking megaport.sh -a=list_live
        echo "Connecting MCR in $hub1_er_pop with ER circuit in hub1..."
        $megaport_script_path -s=jomore-${hub1_er_pop} -a=create_vxc -k=$service_key_1
        if [[ "$no_of_hubs" == "2" ]]
        then
            if [[ "$hub1_er_pop" != "$hub2_er_pop" ]]
            then
                echo "Creating MCR in $hub2_er_pop..."
                $megaport_script_path -s=jomore-${hub2_er_pop} -a=create_mcr -k=$service_key_2 --asn=$mcr2_asn
                sleep 120  # Wait 1 minute before creating the connections. This could be replaced with a loop checking ./megaport.sh -a=list_live
            fi
            echo "Connecting MCR in $hub2_er_pop with ER circuit in hub2..."
            $megaport_script_path -s=jomore-${hub2_er_pop} -a=create_vxc -k=$service_key_2
        fi
    else
        echo "Sorry, I cannot seem to find the script $megaport_script_path to interact with the Megaport API"
    fi
    # Wait until circuits are provisioned
    az network express-route update -n $hub1_er_circuit_name -g $rg -o none
    circuit1_id=$(az network express-route show -n $hub1_er_circuit_name -g $rg -o tsv --query id) && echo "Circuit ID is $circuit1_id"
    circuit1_state=$(az network express-route show -n $hub1_er_circuit_name -g $rg -o tsv --query serviceProviderProvisioningState) && echo "Circuit state is $circuit1_state"
    echo "Waiting until ER circuit in hub1 is provisioned..."
    until [[ "$circuit1_state" == "Provisioned" ]]
    do
        sleep 30
        az network express-route update -n $hub1_er_circuit_name -g $rg -o none
        circuit1_state=$(az network express-route show -n $hub1_er_circuit_name -g $rg -o tsv --query serviceProviderProvisioningState) && echo "Circuit state is $circuit1_state"
    done
    if [[ "$no_of_hubs" == "2" ]]
    then
        az network express-route update -n $hub2_er_circuit_name -g $rg -o none
        circuit2_id=$(az network express-route show -n $hub2_er_circuit_name -g $rg -o tsv --query id) && echo "Circuit ID is $circuit2_id"
        circuit2_state=$(az network express-route show -n $hub2_er_circuit_name -g $rg -o tsv --query serviceProviderProvisioningState) && echo "Circuit state is $circuit2_state"
        echo "Waiting until ER circuit in hub2 is provisioned..."
        until [[ "$circuit2_state" == "Provisioned" ]]
        do
            sleep 30
            az network express-route update -n $hub2_er_circuit_name -g $rg -o none
            circuit2_state=$(az network express-route show -n $hub2_er_circuit_name -g $rg -o tsv --query serviceProviderProvisioningState) && echo "Circuit state is $circuit2_state"
        done
    fi
    # Create connections to Virtual WAN
    sleep 60 # Wait 1min more to the private peering to show up
    peering_id_1=$(az network express-route peering show -n "AzurePrivatePeering" --circuit-name $hub1_er_circuit_name -g $rg -o tsv --query id) && echo "Private peering ID is $peering_id_1"
    if [[ -z "$peering_id_1" ]]
    then
        echo "Could not find private peering for ER circuit 1, you might have to refresh in the portal?"
    else
        hub1_default_rt_id=$(az network vhub route-table show --vhub-name hub1 -g $rg -n defaultRouteTable --query id -o tsv) && echo $hub1_default_rt_id
        echo "Connecting VWAN hub1 to ER circuit 1..."
        az network express-route gateway connection create --gateway-name hub1ergw -n "hub1ergw-${hub1_er_pop}" -g $rg --peering $peering_id_1 \
            --associated-route-table $hub1_default_rt_id --propagated-route-tables $hub1_default_rt_id --labels default -o none
    fi
    if [[ "$no_of_hubs" == "2" ]]
    then
        peering_id_2=$(az network express-route peering show -n "AzurePrivatePeering" --circuit-name $hub2_er_circuit_name -g $rg -o tsv --query id) && echo "Private peering ID is $peering_id_2"
        if [[ -z "$peering_id_2" ]]
        then
            echo "Could not find private peering for ER circuit 2, you might have to refresh in the portal?"
        else
            hub2_default_rt_id=$(az network vhub route-table show --vhub-name hub2 -g $rg -n defaultRouteTable --query id -o tsv) && echo $hub1_default_rt_id
            echo "Connecting VWAN hub2 to ER circuit 2..."
            az network express-route gateway connection create --gateway-name hub2ergw -n "hub2ergw-${hub2_er_pop}" -g $rg --peering $peering_id_2 \
                --associated-route-table $hub2_default_rt_id --propagated-route-tables $hub2_default_rt_id --labels default -o none
            # Optionally, cross-connect the ER circuits
            if [[ "$er_bow_tie" == "yes" ]]; then
                echo "Connecting VWAN hub2 to ER circuit 1..."
                az network express-route gateway connection create --gateway-name hub2ergw -n "hub2ergw-${hub1_er_pop}" -g $rg --peering $peering_id_1 \
                    --associated-route-table $hub2_default_rt_id --propagated-route-tables $hub2_default_rt_id --labels default -o none
                echo "Connecting VWAN hub1 to ER circuit 2..."
                az network express-route gateway connection create --gateway-name hub1ergw -n "hub1ergw-${hub2_er_pop}" -g $rg --peering $peering_id_2 \
                    --associated-route-table $hub1_default_rt_id --propagated-route-tables $hub1_default_rt_id --labels default -o none
                # Optionally, change the routing preference of the vhubs
                az network vhub update -n hub1 -g $rg --hub-routing-preference ASPath -o none
                az network vhub update -n hub2 -g $rg --hub-routing-preference ASPath -o none
            fi
        fi
    fi

    # Configure Global Reach (optional)
    if [[ "$global_reach" == "yes" ]]; then
        echo "Creating Global Reach connection..."
        hub2_er_circuit_id=$(az network express-route show -n $hub2_er_circuit_name -g $rg -o tsv --query id)
        az network express-route peering connection create -g $rg --circuit-name $hub1_er_circuit_name --peering-name AzurePrivatePeering \
            -n "${hub1_er_pop}-to-${hub2_er_pop}" --peer-circuit $hub2_er_circuit_id --address-prefix $gr_ip_range -o none
    fi

    # Simulate ER onprem with Google Cloud (optional)
    if [[ "$deploy_gcp" == "yes" ]]; then
        # gcloud auth list
        # gcloud config set account 'erjosito1138@gmail.com'
        gcloud config set account 'jomore@contosohotels.com'
        gcloud config set project $project_id
        # Get environment info
        # account=$(gcloud info --format json | jq -r '.config.account')
        # billing_account=$(gcloud beta billing accounts list --format json | jq -r '.[0].name')
        # billing_account_short=$(echo "$billing_account" | cut -f 2 -d/)
        # Create project
        # gcloud projects create $project_id --name $project_name
        # gcloud config set project $project_id
        # gcloud beta billing projects link "$project_id" --billing-account "$billing_account_short"
        # gcloud services enable compute.googleapis.com
        # VPC and instance
        gcloud compute networks create "$gcp_vpc1_name" --bgp-routing-mode=regional --mtu=1500 --subnet-mode=custom
        gcloud compute networks subnets create "$gcp_subnet1_name" --network "$gcp_vpc1_name" --range "$gcp_subnet1_prefix" --region=$region1
        gcloud compute instances create "$gcp_vm1_name" --image-family=ubuntu-2004-lts --image-project=ubuntu-os-cloud --machine-type "$machine_type" --network "$gcp_vpc1_name" --subnet "$gcp_subnet1_name" --zone "$zone1"
        gcloud compute firewall-rules create "${gcp_vpc1_name}-allow-icmp" --quiet --network "$gcp_vpc1_name" --priority=1000 --direction=INGRESS --rules=icmp --source-ranges=0.0.0.0/0 --action=ALLOW
        gcloud compute firewall-rules create "${gcp_vpc1_name}-allow-ssh" --quiet --network "$gcp_vpc1_name" --priority=1010 --direction=INGRESS --rules=tcp:22 --source-ranges=0.0.0.0/0 --action=ALLOW
        gcloud compute firewall-rules create "${gcp_vpc1_name}-allow-web" --quiet --network "$gcp_vpc1_name" --priority=1020 --direction=INGRESS --rules=tcp:80 --source-ranges=192.168.0.0/16 --action=ALLOW
        # For IPsec (only required if configuring the VM as IPsec NVA)
        gcloud compute firewall-rules create "${gcp_vpc1_name}-allow-udp4500" --verbosity=error --network "$gcp_vpc1_name" --priority=1050 --direction=INGRESS --rules=udp:4500 --source-ranges=192.168.0.0/16 --action=ALLOW
        gcloud compute firewall-rules create "${gcp_vpc1_name}-allow-udp500" --verbosity=error --network "$gcp_vpc1_name" --priority=1060 --direction=INGRESS --rules=udp:500 --source-ranges=192.168.0.0/16 --action=ALLOW
        gcloud compute firewall-rules create "${gcp_vpc1_name}-allow-udp4500-egress" --verbosity=error --network "$gcp_vpc1_name" --priority=1150 --direction=EGRESS --rules=udp:4500 --source-ranges=0.0.0.0/0 --action=ALLOW
        gcloud compute firewall-rules create "${gcp_vpc1_name}-allow-udp500-egress" --verbosity=error --network "$gcp_vpc1_name" --priority=1160 --direction=EGRESS --rules=udp:500 --source-ranges=0.0.0.0/0 --action=ALLOW
        # gcloud compute ssh $gcp_vm1_name --zone=$zone1 --command="ip a"    # This command will pause the script if the key file is password-protected
        # Create interconnect
        gcloud compute routers create $router1_name --project=$project_id --network=$gcp_vpc1_name --asn=$gcp_asn --region=$region1
        gcloud compute interconnects attachments partner create $attachment1_name --region $region1 --router $router1_name --edge-availability-domain availability-domain-1
        pairing_key1=$(gcloud compute interconnects attachments describe $attachment1_name --region $region1 --format json | jq -r '.pairingKey')
        # Create VXC in Megaport
        $megaport_script_path -g -s=jomore-${hub1_er_pop} -a=create_vxc -k=$pairing_key1
        # Activate attachment
        # wait_for_gcp_attachment_ready $attachment1_name $region1
        sleep 180
        gcloud compute interconnects attachments partner update $attachment1_name --region $region1 --admin-enabled
        # gcloud compute interconnects attachments partner update $attachment1_name --region $region1 --no-enable-admin
        if [[ "$no_of_hubs" == "2" ]]; then
            # VPC and instance
            gcloud compute networks create "$gcp_vpc2_name" --bgp-routing-mode=regional --mtu=1500 --subnet-mode=custom
            gcloud compute networks subnets create "$gcp_subnet2_name" --network "$gcp_vpc2_name" --range "$gcp_subnet2_prefix" --region=$region2
            gcloud compute instances create "$gcp_vm2_name" --image-family=ubuntu-2004-lts --image-project=ubuntu-os-cloud --machine-type "$machine_type" --network "$gcp_vpc2_name" --subnet "$gcp_subnet2_name" --zone "$zone2"
            gcloud compute firewall-rules create "${gcp_vpc2_name}-allow-icmp" --network "$gcp_vpc2_name" --priority=1000 --direction=INGRESS --rules=icmp --source-ranges=0.0.0.0/0 --action=ALLOW
            gcloud compute firewall-rules create "${gcp_vpc2_name}-allow-ssh" --network "$gcp_vpc2_name" --priority=1010 --direction=INGRESS --rules=tcp:22 --source-ranges=0.0.0.0/0 --action=ALLOW
            gcloud compute firewall-rules create "${gcp_vpc2_name}-allow-web" --network "$gcp_vpc2_name" --priority=1020 --direction=INGRESS --rules=tcp:80 --source-ranges=192.168.0.0/16 --action=ALLOW
            # gcloud compute ssh $gcp_vm2_name --zone=$zone2 --command="ip a"    # This command will pause the script if the key file is password-protected
            # Create interconnect
            gcloud compute routers create $router2_name --project=$project_id --network=$gcp_vpc2_name --asn=$gcp_asn --region=$region2
            gcloud compute interconnects attachments partner create $attachment2_name --region $region2 --router $router2_name --edge-availability-domain availability-domain-1
            pairing_key2=$(gcloud compute interconnects attachments describe $attachment2_name --region $region2 --format json | jq -r '.pairingKey')
            # Create VXC in Megaport
            $megaport_script_path -g -s=jomore-${hub2_er_pop} -a=create_vxc -k=$pairing_key2
            # Activate attachment
            # wait_for_gcp_attachment_ready $attachment1_name $region1
            sleep 120
            gcloud compute interconnects attachments partner update $attachment2_name --region $region2 --admin-enabled
            # gcloud compute interconnects attachments partner update $attachment2_name --region $region2 --no-enable-admin
        fi
    fi
fi

# Optional: enable routing intent
if [[ "$routing_intent" == "yes" ]]; then
    put_routing_intent 1 $ri_policy azfw
    if [[ "$no_of_hubs" == "2" ]]; then
        put_routing_intent 2 $ri_policy azfw
    fi
fi

# Optional: create private endpoints
# Variables
storage_container_name=privatelink
storage_blob_name=test.txt
tmp_file='/tmp/${storage_blob_name}'
subnet_name=privateendpoints
dns_zone_name=privatelink.blob.core.windows.net
# Function:
function create_storage_private_link() {
    hub_id=$1
    storage_endpoint_name=storageep${hub_id}
    if [[ "$hub_id" == "1" ]]; then
        location=$location1
    else
        location=$location2
    fi
    vnet_name=spoke${hub_id}1-$location
    subnet_prefix="10.${hub_id}.1.64/26"
    # Get storage account name
    echo "Trying to find storage account in $location..."
    storage_account_name=$(az storage account list -g $rg -o tsv --query "[?location=='$location'].name" | head -1)
    storage_account_key=$(az storage account keys list -n $storage_account_name -g $rg --query '[0].value' -o tsv)
    echo "Storage account $storage_account_name found in location $location, uploading test file..."
    find_container=$(az storage container show -n $storage_container_name --account-name $storage_account_name --auth-mode key --account-key $storage_account_key)
    if [[ -z "$find_container" ]]; then
        az storage container create -n $storage_container_name --public-access container --auth-mode key --account-name $storage_account_name --account-key $storage_account_key -o none
        echo 'Hello world!' >"$tmp_file"
        az storage blob upload -n "$storage_blob_name" -c "$storage_container_name" -f "/tmp/${storage_blob_name}" --auth-mode key --account-name "$storage_account_name" --account-key "${storage_account_key}" --overwrite -o none
    else
        echo "Container $storage_container_name already exists"
    fi
    # Create private DNS zone and register with all VNets
    find_zone=$(az network private-dns zone show -n $dns_zone_name -g $rg 2>/dev/null)
    if [[ -z "$find_zone" ]]; then
        az network private-dns zone create -n $dns_zone_name -g $rg -o none
        vnet_list=$(az network vnet list -g $rg --query '[].name' -o tsv)
        while IFS= read -r vnet_to_link; do
            echo "Linking zone $dns_zone_name to VNet $vnet_to_link..."
            az network private-dns link vnet create -g $rg -z $dns_zone_name -n $vnet_to_link --virtual-network $vnet_to_link --registration-enabled false --only-show-errors -o none
        done <<< "$vnet_list"
    else
        echo "Private DNS Zone $dns_zone_name already exists in RG $rg"
    fi
    # Create endpoint
    echo "Creating private endpoint for storage account $storage_account_name..."
    find_endpoint=$(az network private-endpoint show -n $storage_endpoint_name -g $rg 2>/dev/null)
    if [[ -z "$find_endpoint" ]]; then
        storage_account_id=$(az storage account show -n $storage_account_name -g $rg -o tsv --query id)
        az network vnet subnet create -g $rg -n $subnet_name --vnet-name $vnet_name --address-prefix $subnet_prefix -o none
        az network private-endpoint create -n $storage_endpoint_name -l $location -g $rg --vnet-name $vnet_name --subnet $subnet_name --private-connection-resource-id $storage_account_id --group-id blob --connection-name blob -o none
        az network private-endpoint dns-zone-group create --endpoint-name $storage_endpoint_name -g $rg -n myzonegroup --zone-name zone1 --private-dns-zone $dns_zone_name -o none
    else
        echo "Endpoint $storage_endpoint_name already exists"
    fi
}
# Main:
if [[ "$private_link" == "yes" ]]; then
    create_storage_private_link 1
    if [[ "$no_of_hubs" == "2" ]]; then
        create_storage_private_link 2
    fi
fi
