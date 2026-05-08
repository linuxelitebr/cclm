# CCLM: Address Space Planning and Pool ConfigMap

## Why the address range can be anything

The CCLM migration network is **L2-isolated by design**: it lives on a dedicated VLAN (e.g. VLAN 100), with no L3 gateway on that VLAN and no route leaving it. The IPs allocated on this network:

- Do not route anywhere (they never leave the VLAN)
- Do not conflict with anything routed elsewhere in the customer network
- Are used only by `virt-handler`, `virt-launcher`, and the `virt-sync-controller` during migrations

The pods involved have two IPs: one on the primary pod network (routed, e.g. `10.128.0.x`) and one on the migration NAD (not routed, from the chosen range). CCLM uses only the second one for QEMU state transfer.

**Consequence:** any private range works for the migration network (even one already in use elsewhere in the customer network), as long as the network team guarantees that the dedicated VLAN does not receive a router interface.

Documented operational guarantee: *"VLAN 100 is pure L2 transport between the cluster switches, no default gateway, no router interface."*

## How to size

Each cluster needs simultaneously:

```
IPs per cluster = N nodes + M concurrent migrations + 1 (virt-handler)
                             (virt-launcher target)    (sync-controller)
```

Example: a 20-node cluster with 5 concurrent migrations = 26 IPs.

Per-cluster sizing table:

| Block | Usable hosts | Clusters in /16 | Coverage |
|---|---|---|---|
| /28 | 14 | 4096 | Edge clusters (up to ~10 nodes) |
| /27 | 30 | 2048 | Small clusters (10-25 nodes) |
| **/26** | **62** | **1024** | **Recommended default (up to ~50 nodes)** |
| /25 | 126 | 512 | Larger clusters (50-100 nodes) |
| /24 | 254 | 250 | Very large clusters |

For a fleet of up to ~500 nodes spread across HCP-hosted clusters of varying sizes: **/26 per cluster + /16 supernet** covers 1024 clusters of up to ~50 nodes each. Comfortable headroom. Larger clusters get `/25` when needed.

## How to choose the supernet

Criteria:

1. **Private range** (`10/8`, `172.16/12`, `192.168/16`, or CGNAT `100.64/10`)
2. Available across all DCs where the VLAN will be trunked
3. Documentable internally as "CCLM migration network, isolated, never routed"
4. /16 is the default (covers 1024 /26 clusters)

The reference deployment uses **`10.250.0.0/16`**: clean space across DCs, mnemonic (`.250` reads as "migration").

## Full Pool ConfigMap example

The ConfigMap lives on the hub (management) cluster and is the single source of truth for allocations. The `cclm-helper.sh` script reads from and writes to it.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cclm-pool
  namespace: cclm-system
data:
  # Global pool configuration
  config.json: |
    {
      "supernet": "10.250.0.0/16",
      "block_size": 26,
      "vlan_default": 100,
      "physical_network_default": "cclm-mig"
    }

  # Per-cluster allocations
  # Key:   alloc.<cluster-id>
  # Value: JSON with block, vlan, network_model

  alloc.hosting-cluster-1: |
    {"block":"10.250.0.0/26","vlan":100,"network_model":"stretched_l2"}

  alloc.hosted-cluster-a: |
    {"block":"10.250.0.64/26","vlan":100,"network_model":"stretched_l2"}

  alloc.hosted-app-prod: |
    {"block":"10.250.0.128/26","vlan":100,"network_model":"stretched_l2"}

  alloc.hosted-app-staging: |
    {"block":"10.250.0.192/26","vlan":100,"network_model":"stretched_l2"}

  alloc.hosting-cluster-2: |
    {"block":"10.250.1.0/26","vlan":100,"network_model":"stretched_l2"}

  alloc.hosted-db-prod: |
    {"block":"10.250.1.64/25","vlan":100,"network_model":"stretched_l2"}

  alloc.hosted-remote-site-1: |
    {"block":"10.250.2.0/26","vlan":200,"network_model":"l3_routed"}

  alloc.hosted-remote-site-2: |
    {"block":"10.250.2.64/26","vlan":200,"network_model":"l3_routed"}
```

### Notes on the example

- **Sequential by default:** the helper allocates in ascending order (`.0/26`, `.64/26`, `.128/26`, ...). This guarantees reproducibility: re-creating the pool with the same cluster IDs in the same order yields identical allocations.

- **Block size override:** `hosted-db-prod` got `/25` (126 hosts) because it is a larger cluster. To do this, edit the ConfigMap directly (the helper currently allocates only at the default `block_size`).

- **VLAN override:** remote sites use VLAN 200 because they enter the DC over a different trunk. The helper's `allocate` accepts a per-cluster VLAN.

- **`network_model`:**
  - `stretched_l2`: extended L2, all clusters share a single VLAN. Pods get a `/16` mask (from the supernet) and see the other
    sub-pools as on-link via ARP. No router needed. **Default.**
  - `l3_routed`: for remote sites over VPN. Pods get a `/26` mask (their own block). The default gateway in the segment points
    to a network router that knows routes to the other sub-pools
    via tunnels. Requires network team coordination.

- **`physical_network_default: cclm-mig`**: name of the `localnet` registered in the NNCP of each cluster (bridge mapping `cclm-mig:br-phy`). Same name across the fleet.

## Cluster ID convention

Stable identifier, used as the ConfigMap key. Recommended:

```
<role>-<deployment-name>
```

Examples:

- `hosting-cluster-1`: hosting cluster in DC 1
- `hosted-cluster-a`: hosted cluster running workload "a"
- `hosted-app-prod`: hosted cluster for the application team, prod
- `hosted-remote-site-1`: hosted cluster at a remote site

Helper restriction: regex `[a-zA-Z0-9-]+`. No dots, underscores, or special characters.

## ConfigMap operations

### Initialize (one-time)

```bash
KUBECONFIG=<hub> ./cclm-helper.sh init 10.250.0.0/16 26 100
```

Creates the `cclm-system` namespace and the `cclm-pool` ConfigMap with just `config.json`. Idempotent.

### List allocations

```bash
./cclm-helper.sh list
```

### Allocate

```bash
./cclm-helper.sh allocate <cluster-id> [model] [vlan]
# model:  stretched_l2 (default) | l3_routed
# vlan:   default comes from config.json
```

### Release

```bash
./cclm-helper.sh release <cluster-id>
```

Removes the entry from the ConfigMap only. **Does not delete the CUDN on the target cluster.** That step is manual:

```bash
KUBECONFIG=<target> oc delete clusteruserdefinednetwork cclm-migration
```

### Direct edit (block/VLAN override)

```bash
KUBECONFIG=<hub> oc edit configmap cclm-pool -n cclm-system
```

Each `alloc.<id>` value is a JSON string. Edit carefully to avoid breaking the syntax.

## State backup

The ConfigMap is the only state. Recommended backup:

```bash
KUBECONFIG=<hub> oc get configmap cclm-pool -n cclm-system -o yaml \
  > cclm-pool-backup-$(date +%F).yaml
```

Restore:

```bash
KUBECONFIG=<hub> oc apply -f cclm-pool-backup-2026-05-05.yaml
```

Versioning the ConfigMap in git is an option: it is declarative and PR review works well for changes.
