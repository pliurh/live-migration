#!/bin/bash
set -eux -o pipefail
table="nat"
chain_name="OVN-KUBE-SNAT-MGMTPORT"

chain_exists()
{
    local chain_name="$1" ; shift
    [ $# -eq 1 ] && local table="--table $1"
    iptables -t ${table} -n --list "${chain_name}" >/dev/null 2>&1
}

until
  chain_exists ${chain_name}
do
  sleep 3
  echo "chain ${chain_name} no ready"
done
iptables -t ${table} -I ${chain_name} -s 10.128.0.0/14 -o ovn-k8s-mp0 -j ACCEPT
