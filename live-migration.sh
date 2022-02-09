#!/bin/bash
set -eu -o pipefail
node_names=($(oc get node -o wide| grep -E -v NAME| awk '{print $1}'))
master_ips=($(oc get node -o wide| grep master | awk '{print $6}'))

function wait_for_mcp()
{
oc wait mcp --all --for='condition=UPDATING=True' --timeout=30s
until
  oc wait mcp --all --for='condition=UPDATED=True' --timeout=10s && \
  oc wait mcp --all --for='condition=UPDATING=False' --timeout=10s && \
  oc wait mcp --all --for='condition=DEGRADED=False' --timeout=10s; 
do
  sleep 10
  echo "Some MachineConfigPool DEGRADED=True,UPDATING=True,or UPDATED=False";
done
}


function urlencode() {
    # urlencode <string>
    local length="${#1}"
    for (( i = 0; i < length; i++ )); do
        local c="${1:$i:1}"
        case $c in
            [a-zA-Z0-9.~_-]) printf '%s' "$c" ;;
            *) printf '%%%02X' "'$c" ;;
        esac
    done
}

function iptables-script-text()
{
cat <<EOT
#!/bin/bash
set -eux -o pipefail
table="nat"
chain_name="OVN-KUBE-SNAT-MGMTPORT"
chain_exists()
{
    local chain_name="\$1" ; shift
    [ \$# -eq 1 ] && local table="--table \$1"
    iptables -t \${table} -n --list "\${chain_name}" >/dev/null 2>&1
}
until
    chain_exists \${chain_name}
do
    sleep 3
    echo "chain \${chain_name} no ready"
done
iptables -t \${table} -I \${chain_name} -s $1 -o ovn-k8s-mp0 -j ACCEPT
EOT
}
function iptables-mc-text()
{
cat <<EOT
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: worker-iptables-rules
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:,$1%0A
          verification: {}
        mode: 0755
        overwrite: true
        path: /usr/local/bin/configure-migration-iptables-rules.sh
    systemd:
      units:
      - dropins:
        - contents: |
            [Service]
            ExecStartPost=/usr/local/bin/configure-migration-iptables-rules.sh
          name: 20-migration-iptables-rules.conf
        name: kubelet.service
---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: master-iptables-rules
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:,$1%0A
          verification: {}
        mode: 0755
        overwrite: true
        path: /usr/local/bin/configure-migration-iptables-rules.sh
    systemd:
      units:
      - dropins:
        - contents: |
            [Service]
            ExecStartPost=/usr/local/bin/configure-migration-iptables-rules.sh
          name: 20-migration-iptables-rules.conf
        name: kubelet.service
EOT
}

# prepare node for migration
oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\":{\"migration\":{\"networkType\":\"OVNKubernetes\"}}}"
wait_for_mcp

# inject iptables rules
# cluster_cidr="$(oc get network.config cluster -o jsonpath='{.spec.clusterNetwork[0].cidr}')"
# raw="$(iptables-script-text "$cluster_cidr")"
# source=$(urlencode "$raw")
# echo "$(iptables-mc-text "$source")" | oc apply -f -
# wait_for_mcp

# deploy ovnkube
oc patch Network.config.openshift.io cluster --type='merge' --patch '{"spec":{"networkType":"OVNKubernetes","clusterNetwork":[{"cidr":"10.132.0.0/14","hostPrefix":23}]}}'
timeout 300s oc rollout status ds/ovnkube-node -n openshift-ovn-kubernetes

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

# remove iptables rules and trigger reboot
oc delete mc master-iptables-rules
wait_for_mcp
