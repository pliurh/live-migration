#!/bin/bash
set -eu -o pipefail
node_names=($(oc get node -o wide| grep -E -v NAME| awk '{print $1}'))
master_ips=($(oc get node -o wide| grep master | awk '{print $6}'))

# add static route to ovn
ovn_nbdb=$(printf ",ssl:%s:9641" "${master_ips[@]}")
ovn_nbdb=${ovn_nbdb:1}

declare -A ovn_sdn_subnet_map

for node in "${node_names[@]}"
do
    sdn_subnet=$(oc get hostsubnets $node|grep -E -v NAME|awk '{print $4}')
    ovn_subnet=$(oc get node $node -o jsonpath='{.metadata.annotations.k8s\.ovn\.org\/node-subnets}'| jq -r '.default')
    ovn_gw_ip=${ovn_subnet::-4}"2"
    ovn_sdn_subnet_map[$ovn_gw_ip]=$sdn_subnet
done

for ovn_gw_ip in ${!ovn_sdn_subnet_map[*]};do
  oc get pod -n openshift-ovn-kubernetes | grep ovnkube-master|awk '{print $1}'|head -n 1|xargs -i oc rsh -n openshift-ovn-kubernetes {} ovn-nbctl --db ${ovn_nbdb}  -p /ovn-cert/tls.key -c /ovn-cert/tls.crt -C /ovn-ca/ca-bundle.crt --policy=dst-ip lr-route-add ovn_cluster_router "${ovn_sdn_subnet_map[${ovn_gw_ip}]}" "${ovn_gw_ip}" || true
done



