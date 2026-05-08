#!/usr/bin/env bash
# cclm-helper - shell helper for CCLM IPAM allocation via OVN-K CUDN supernet pattern
#
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Andre Rocha
#
# Stores per-cluster sub-pool allocations in a ConfigMap on the hub cluster.
# Computes the excludeSubnets carve-out algorithmically.
# Renders ClusterUserDefinedNetwork manifests ready for `oc apply`.
#
# Subcommands:
#   init [supernet] [block_size] [vlan]   - Create the cclm-pool ConfigMap (idempotent)
#   list                                   - Show config and allocations
#   allocate <cluster-id> [model] [vlan]   - Allocate next free block to a cluster
#   release <cluster-id>                   - Free a cluster's allocation
#   render <cluster-id> [nad-name]         - Print CUDN YAML for a cluster
#
# Env vars:
#   KUBECONFIG       (default ~/.kube/config) - which cluster holds the state ConfigMap
#   CCLM_NAMESPACE   (default cclm-system)
#   CCLM_CONFIGMAP   (default cclm-pool)
#
# Requirements: bash 4+, jq, python3 (with stdlib ipaddress), oc/kubectl

set -euo pipefail

CONFIGMAP_NAMESPACE="${CCLM_NAMESPACE:-cclm-system}"
CONFIGMAP_NAME="${CCLM_CONFIGMAP:-cclm-pool}"
KUBECTL="${KUBECTL:-oc}"

# ---- CIDR math (delegated to python3 stdlib) -----------------------------

carve_excludes() {
    # Compute the list of CIDRs to exclude in order to carve out a single
    # target sub-pool from a larger supernet. Result is a JSON array of strings.
    local supernet="$1"
    local target="$2"
    python3 - "$supernet" "$target" <<'PY'
import ipaddress, json, sys
def carve(s, t):
    if s == t:
        return []
    a, b = s.subnets(prefixlen_diff=1)
    if t.subnet_of(a):
        return [b] + carve(a, t)
    else:
        return [a] + carve(b, t)
sn = ipaddress.ip_network(sys.argv[1])
tg = ipaddress.ip_network(sys.argv[2])
print(json.dumps([str(e) for e in carve(sn, tg)]))
PY
}

next_free_block() {
    # Find the next free /<bs> block within <supernet> that does not
    # overlap any of the provided <allocated...> blocks.
    # Prints the block CIDR. Exits non-zero if pool exhausted.
    local supernet="$1"
    local block_size="$2"
    shift 2
    python3 - "$supernet" "$block_size" "$@" <<'PY'
import ipaddress, sys
sn = ipaddress.ip_network(sys.argv[1])
bs = int(sys.argv[2])
allocated = [ipaddress.ip_network(a) for a in sys.argv[3:]]
for b in sn.subnets(new_prefix=bs):
    if all(not b.overlaps(a) for a in allocated):
        print(b)
        sys.exit(0)
sys.exit(1)
PY
}

# ---- ConfigMap state -----------------------------------------------------

cm_get() {
    $KUBECTL get configmap -n "$CONFIGMAP_NAMESPACE" "$CONFIGMAP_NAME" -o json 2>/dev/null
}

cm_must_exist() {
    if ! cm_get >/dev/null; then
        echo "ERROR: ConfigMap $CONFIGMAP_NAMESPACE/$CONFIGMAP_NAME not found. Run '$0 init' first." >&2
        exit 1
    fi
}

cm_get_config() {
    cm_get | jq -r '.data["config.json"] // empty'
}

cm_get_allocations() {
    # Returns JSON array: [{cluster: "id", block: "cidr", vlan: N, network_model: "..."}]
    cm_get | jq '.data | to_entries
        | map(select(.key | startswith("alloc.")))
        | map(.value |= fromjson)
        | map({cluster: (.key | sub("^alloc."; "")), block: .value.block, vlan: .value.vlan, network_model: .value.network_model})'
}

# ---- Subcommands ---------------------------------------------------------

cmd_init() {
    local supernet="${1:-10.250.0.0/16}"
    local block_size="${2:-26}"
    local vlan="${3:-100}"
    local phys_net="${4:-cclm-mig}"

    if cm_get >/dev/null; then
        echo "ConfigMap $CONFIGMAP_NAMESPACE/$CONFIGMAP_NAME already exists. Existing config:"
        cm_get_config | jq .
        return
    fi

    $KUBECTL create namespace "$CONFIGMAP_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null

    local config_json
    config_json=$(jq -n -c \
        --arg supernet "$supernet" \
        --argjson block_size "$block_size" \
        --argjson vlan "$vlan" \
        --arg phys_net "$phys_net" \
        '{supernet: $supernet, block_size: $block_size, vlan_default: $vlan, physical_network_default: $phys_net}')

    local manifest
    manifest=$(jq -n -c \
        --arg ns "$CONFIGMAP_NAMESPACE" \
        --arg name "$CONFIGMAP_NAME" \
        --arg config "$config_json" \
        '{
            apiVersion: "v1",
            kind: "ConfigMap",
            metadata: {name: $name, namespace: $ns},
            data: {"config.json": $config}
        }')
    echo "$manifest" | $KUBECTL apply -f - >/dev/null

    echo "Initialized $CONFIGMAP_NAMESPACE/$CONFIGMAP_NAME"
    echo "  supernet:    $supernet"
    echo "  block_size:  /$block_size  ($((2 ** (32 - block_size))) IPs per cluster)"
    echo "  capacity:    $((2 ** (block_size - $(echo "$supernet" | cut -d/ -f2)))) clusters max"
    echo "  vlan_default: $vlan"
}

cmd_list() {
    cm_must_exist
    echo "Config:"
    cm_get_config | jq -r '"  supernet:               \(.supernet)
  block_size:             /\(.block_size)
  vlan_default:           \(.vlan_default)
  physical_network_default: \(.physical_network_default)"'
    echo
    echo "Allocations:"
    local allocs
    allocs=$(cm_get_allocations)
    local count
    count=$(echo "$allocs" | jq 'length')
    if [ "$count" = "0" ]; then
        echo "  (none)"
    else
        echo "$allocs" | jq -r '.[] | "  \(.cluster):\t\(.block)\tvlan=\(.vlan)\tmodel=\(.network_model)"' | column -t -s $'\t'
    fi
}

cmd_allocate() {
    cm_must_exist
    local cluster_id="${1:-}"
    local network_model="${2:-stretched_l2}"
    local vlan="${3:-}"

    if [ -z "$cluster_id" ]; then
        echo "Usage: $0 allocate <cluster-id> [model] [vlan]" >&2
        exit 1
    fi

    case "$network_model" in
        stretched_l2|l3_routed) ;;
        *) echo "ERROR: network_model must be stretched_l2 or l3_routed" >&2; exit 1 ;;
    esac

    # Idempotent re-run
    local existing
    existing=$(cm_get_allocations | jq -r ".[] | select(.cluster==\"$cluster_id\") | .block")
    if [ -n "$existing" ]; then
        echo "$cluster_id: already allocated → $existing (no-op)"
        return
    fi

    local config supernet block_size default_vlan
    config=$(cm_get_config)
    supernet=$(echo "$config" | jq -r .supernet)
    block_size=$(echo "$config" | jq -r .block_size)
    default_vlan=$(echo "$config" | jq -r .vlan_default)
    [ -z "$vlan" ] && vlan="$default_vlan"

    # Existing blocks
    local allocated_blocks
    mapfile -t allocated_blocks < <(cm_get_allocations | jq -r '.[].block')

    local block
    if ! block=$(next_free_block "$supernet" "$block_size" "${allocated_blocks[@]}" 2>/dev/null); then
        echo "ERROR: pool $supernet exhausted at /$block_size (current alloc count: ${#allocated_blocks[@]})" >&2
        exit 1
    fi

    # Persist
    local alloc_json
    alloc_json=$(jq -n -c \
        --arg block "$block" \
        --argjson vlan "$vlan" \
        --arg model "$network_model" \
        '{block: $block, vlan: $vlan, network_model: $model}')

    local patch
    patch=$(jq -n -c --arg key "alloc.$cluster_id" --arg val "$alloc_json" '{data: {($key): $val}}')

    $KUBECTL patch configmap "$CONFIGMAP_NAME" -n "$CONFIGMAP_NAMESPACE" --type=merge -p "$patch" >/dev/null

    echo "$cluster_id: allocated $block (vlan=$vlan, model=$network_model)"
}

cmd_release() {
    cm_must_exist
    local cluster_id="${1:-}"
    if [ -z "$cluster_id" ]; then
        echo "Usage: $0 release <cluster-id>" >&2
        exit 1
    fi

    local existing
    existing=$(cm_get_allocations | jq -r ".[] | select(.cluster==\"$cluster_id\") | .block")
    if [ -z "$existing" ]; then
        echo "$cluster_id: no allocation found (no-op)"
        return
    fi

    # JSON Patch to remove a key (note the ~1 escape for "/" in path)
    local key="alloc.$cluster_id"
    local escaped
    escaped=$(echo "$key" | sed 's|/|~1|g; s|~|~0|g')
    $KUBECTL patch configmap "$CONFIGMAP_NAME" -n "$CONFIGMAP_NAMESPACE" --type=json \
        -p "[{\"op\":\"remove\",\"path\":\"/data/$escaped\"}]" >/dev/null

    echo "$cluster_id: released $existing"
}

cmd_render() {
    cm_must_exist
    local cluster_id="${1:-}"
    local nad_name="${2:-cclm-migration}"

    if [ -z "$cluster_id" ]; then
        echo "Usage: $0 render <cluster-id> [nad-name]" >&2
        exit 1
    fi

    local alloc
    alloc=$(cm_get_allocations | jq -r ".[] | select(.cluster==\"$cluster_id\")")
    if [ -z "$alloc" ]; then
        echo "ERROR: no allocation for $cluster_id (run '$0 allocate $cluster_id' first)" >&2
        exit 1
    fi

    local block vlan model
    block=$(echo "$alloc" | jq -r .block)
    vlan=$(echo "$alloc" | jq -r .vlan)
    model=$(echo "$alloc" | jq -r .network_model)

    local config supernet phys_net
    config=$(cm_get_config)
    supernet=$(echo "$config" | jq -r .supernet)
    phys_net=$(echo "$config" | jq -r .physical_network_default)

    case "$model" in
        stretched_l2) render_stretched_l2 "$cluster_id" "$nad_name" "$supernet" "$block" "$vlan" "$phys_net" ;;
        l3_routed)    render_l3_routed    "$cluster_id" "$nad_name" "$supernet" "$block" "$vlan" "$phys_net" ;;
        *) echo "ERROR: unsupported model $model" >&2; exit 1 ;;
    esac
}

render_stretched_l2() {
    local cluster_id="$1" nad_name="$2" supernet="$3" block="$4" vlan="$5" phys_net="$6"

    local excludes_json excludes_yaml
    excludes_json=$(carve_excludes "$supernet" "$block")
    excludes_yaml=$(echo "$excludes_json" | jq -r '.[] | "        - \"\(.)\""')

    cat <<EOF
# CCLM CUDN: cluster $cluster_id
# Model: stretched_l2 (one VLAN spans all clusters; pods get supernet mask
#                     so they reach peer cluster pods via L2 ARP only).
# Supernet: $supernet
# This cluster's sub-pool: $block  (VLAN $vlan)
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: $nad_name
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: openshift-cnv
  network:
    topology: Localnet
    localnet:
      role: Secondary
      physicalNetworkName: $phys_net
      subnets: ["$supernet"]
      excludeSubnets:
$excludes_yaml
      mtu: 9000
      vlan:
        mode: Access
        access:
          id: $vlan
      ipam:
        mode: Enabled
        lifecycle: Persistent
EOF
}

render_l3_routed() {
    local cluster_id="$1" nad_name="$2" supernet="$3" block="$4" vlan="$5" phys_net="$6"

    # First IP in block reserved as gateway (router IP, configured by network team)
    local gateway
    gateway=$(python3 -c "import ipaddress; print(list(ipaddress.ip_network('$block').hosts())[0])")

    cat <<EOF
# CCLM CUDN: cluster $cluster_id
# Model: l3_routed (this cluster's pods get only their own /<mask>;
#                   default route points to network-team-managed gateway,
#                   gateway routes to peer clusters' sub-pools via VPN/BGP).
# Supernet (info only, NOT in spec): $supernet
# This cluster's sub-pool: $block  (VLAN $vlan)
# Reserved gateway:        $gateway  (must be configured on the migration VLAN router)
#
# IMPORTANT: this manifest does NOT use excludeSubnets. Network team must
# ensure gateway $gateway is reachable on VLAN $vlan and routes the
# supernet to other clusters' sub-pools.
apiVersion: k8s.ovn.org/v1
kind: ClusterUserDefinedNetwork
metadata:
  name: $nad_name
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: openshift-cnv
  network:
    topology: Localnet
    localnet:
      role: Secondary
      physicalNetworkName: $phys_net
      subnets: ["$block"]
      mtu: 9000
      vlan:
        mode: Access
        access:
          id: $vlan
      ipam:
        mode: Enabled
        lifecycle: Persistent
EOF
}

# ---- Dispatch ------------------------------------------------------------

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

case "${1:-}" in
    init)     shift; cmd_init "$@" ;;
    list)     shift; cmd_list ;;
    allocate) shift; cmd_allocate "$@" ;;
    release)  shift; cmd_release "$@" ;;
    render)   shift; cmd_render "$@" ;;
    -h|--help|help) usage 0 ;;
    *)        usage 1 ;;
esac
