# Cross-Cluster Live Migration (CCLM): network setup POC + technical reference

> **Status: FULLY VALIDATED on OCP 4.20.** As of 2026-05-10, end-to-end
> cross-cluster live migration works for fedora, rhel9, centos-stream9
> and windows guests on the validated stack (OCP 4.20.13 + CNV 4.20.x
> + MCE 2.11 + MTV 2.11.5). Previous centos-stream9 PreCopy failure
> (jumbo frame / middlebox PMTU hypothesis) no longer reproduces after
> the supernet CUDN was deployed. Intra-cluster live migration on the
> dedicated network keeps working as before.
>
> **Last updated:** 2026-05-10
>
> **Update 2026-05-10:** full CCLM workflow validated on OCP 4.20.13
> + MCE 2.11 + MTV 2.11.5. Three VM guests (centos-stream9, fedora,
> rhel9) migrated successfully cross-cluster via Plans/Migrations
> created on the source cluster (hosted -> hosting direction).
> Automated Phase A (NNCP/IPAM/CUDN) + Phase B (HCO + Forklift
> patches) via the `cclm` role in `hypershift-automation`. Phase C
> (MTV cross-cluster Providers) is still manual at this date and
> required the operator to create on each cluster: a custom
> ClusterRole (`live-migration-role` per MTV docs), a ServiceAccount
> in `openshift-cnv`, a ClusterRoleBinding, a long-lived
> service-account-token Secret, and a Provider + provider-Secret pair
> per peer in `openshift-mtv`. The supernet pattern's per-cluster /26
> sub-pool prevented the split-brain failure mode documented in
> [§9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain).
> Empirical confirmation that the `liveMigrationConfig.network` field
> and the `decentralizedLiveMigration` feature gate ARE both exposed
> by the HyperConverged CRD on CNV 4.20.x bundled with MCE 2.11.
>
> **Update 2026-05-08:** validated end-to-end TCP roundtrip across the
> `cclm-migration` CUDN via pods on both clusters (no firewall, MTU
> fine, L2 fine). Confirmed the launcher pod **does NOT** carry
> `cclm-migration` in its `k8s.v1.cni.cncf.io/network-status` annotation :
> the migration network is attached transiently during migration via a
> sidecar mechanism, not via Multus on the main launcher. Operators
> looking at `network-status` and not seeing `cclm-migration` should
> not interpret as misconfig. Phase A and Phase B (HCO + Forklift)
> automation lives in `hypershift-automation`, role `cclm`. Phase C
> (MTV cross-cluster Providers) remains here.
>
> **Revision history:**
> - First draft proposed building a dedicated `br-migration` OVS bridge
>   with a Linux VLAN sub-interface as port. Wrong for the typical CNV
>   deployment where bonding lives inside OVS (balance-slb) and there is
>   no Linux-level `bond0` device.
> - Second draft corrected to just extend `ovn.bridge-mappings` on the
>   existing `br-phy`. Applied cleanly on first try.
> - 2026-04-29 revision captured validated lab end-state. IPAM uses
>   OVN-K8s's native `subnets` field (no Whereabouts), lab used VLAN 100.
>   Sections [4.2](#42-networkattachmentdefinition-the-migration-nad) and 5 rewritten.
> - **2026-05-04 revision** (this one): battle-tested at scale and
>   captured operational findings:
>   - HCP upgrade chain (MCE → HostedCluster → NodePool → CNV) added
>     after the lab's source cluster was found stuck on 4.20 against a
>     4.21 dest, producing CCLM ALPN handshake failure
>   - IPAM strategy completely rewritten (section 6): ULA dual-stack
>     established as production target after IP collision on shared `/24`
>     was diagnosed as silent split-brain failure ([§9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain))
>   - Section [§6.5](#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks) added as task spec for hypershift-automation hand-off
>   - Section [§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain) added with supernet-with-sub-pools pattern (L2-domain-
>     preserving allocation that doesn't need cross-cluster coordination
>     at runtime)
>   - 9 troubleshooting subsections added ([9.1](#91-cross-version-cclm-failure-alpn-handshake) to [9.9](#99-doc-vs-real-version-notes-420-421-transition)) covering all
>     observed failure modes with diagnostic + recovery commands
>   - Section 11 (RVTMA implications) marked as done: RVTMA generator
>     v1 shipped on `main` (commits 0f6680e, a03713b) emitting
>     NNCP+NAD+HCO patch+README

---

## 0. Where we are (start here for fresh sessions)

**This section exists so a fresh conversation picking up CCLM work can orient in 2 minutes without reading the whole doc.**

### What's working end-to-end

- **Intra-cluster live migration on the dedicated network**: virt-handler uses VLAN 100 / subnet `10.200.5.0/24` for all internal migrations. Verified by `kubevirt-evacuation-*` and `kubevirt-workload-update-*` VMIMs reaching `Succeeded` during NodePool rolling upgrades.
- **Cross-cluster live migration for fedora and windows VMs**: full Forklift plan → VMIM → libvirt qemu state transfer → cutover → destination running. Source pauses, destination resumes, source pod terminates.
- **MTV providers, feature gates, NAD attachment to virt-handler**: all configured per sections 4 + 5 of this doc.

### What's NOT working / open

| Item | Symptom | Hypothesis | Status |
|---|---|---|---|
| centos-stream9 cross-cluster mig | `Cannot recv data: Connection reset by peer` mid-PreCopy | MTU/jumbo not end-to-end OR middlebox idle/conntrack timeout. Larger disk = longer transfer = more exposure. Specs identical to fedora | **Open. Tests proposed in 9.X (try MTU 1500, allowPostCopy=true, tcpdump).** |
| IPv6 ULA dual-stack | Cannot validate the recommended target IPAM ([§6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback)) | OVN-K `localnet` topology may not accept Whereabouts `ipam` block on CNV 4.21.x. Initial attempt produced no working IPs. | **Open. Top-priority for the dedicated CCLM session: unblocks long-term scale story.** |
| Shared-subnet split brain ([§9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain)) | Silent failure: Forklift VMIM "Succeeded" while VM never migrates | OVN-K IPAM allocates colliding IPs across clusters in shared L2 domain. Connection-refused → libvirt cached failure → cold boot from imported disk on dest. | **Mitigated tactically (cordon colliding nodes, retry). Permanent fix needs [6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain) supernet pattern OR ULA dual-stack.** |
| Subnet allocation across N clusters | No automation; each new cluster hand-picks subnet OR collides | Generator can only emit one cluster's NAD; cross-cluster coordination is a separate concern | **Specced in [§6.5](#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks) as hand-off to hypershift-automation playbooks. Not yet built.** |

### Architectural decisions made (with section pointers)

- **Version baseline:** OCP 4.21 + CNV 4.21 + MTV 2.11.x. Both clusters must match minor (mismatch caused [9.1](#91-cross-version-cclm-failure-alpn-handshake) ALPN failure). 4.20 path documented for compatibility but not the recommended baseline. (1, [9.9](#99-doc-vs-real-version-notes-420-421-transition))
- **Bonding model assumption:** OVS Balance-SLB inside `br-phy`. No Linux-level `bond0`. (3)
- **Migration network:** dedicated VLAN trunked end-to-end on both clusters' fabric. Stretched L2, not L3 routed. (2, 8)
- **IPAM target state:** dual-stack ULA `/112` per-cluster + optional IPv4 fallback via Whereabouts `ipRanges`. ([6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback), [6.4](#64-architectural-rationale-why-ula-dual-stack-is-the-default))
- **IPAM lab-current state:** OVN-K native `subnets` in shared `/24`. Acknowledged unsafe at scale (split-brain risk). ([§6.2](#62-lab-only-fallback-native-ovn-k-subnets-single-shared-subnet))
- **IPAM intermediate option:** supernet `/16` with per-cluster sub-pools, pod mask = supernet mask, on-link reachability via L2. Eliminates collision without needing L3 routing. ([6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain): recommended next-step validation in lab.)
- **L3 routing path (Option B, [6.3](#63-optional-opportunistic-alternative-distinct-subnets-per-cluster-l3-routing)):** documented but explicitly NOT
  the default: depends on customer network team coordination that we cannot assume.

### Done: handed off

- **RVTMA generator v1** (commits `0f6680e` + `a03713b` on `main`): emits NNCP + NAD + HCO patch + operator README for the OVS-bonded 2-NIC case. 51 tests on the generator, 16 on the modal UI, all passing as of 2026-05-04. Generator output validated against both lab clusters via `oc apply --dry-run=server`. Files: `js/cclm-network-generator.js`, `js/generate-physical-network-content-modal.js`, `tests/cclm-network-generator.test.js`, `tests/cclm-modal-ui.test.js`.

### Pending: next session priorities

1. **Investigate centos-stream9 PreCopy RST.** Quick wins: drop MTU to 1500, set `allowPostCopy: true`, tcpdump on the migration network during a failing run. Likely PMTU/middlebox.
2. **Validate OVN-K `localnet` + Whereabouts compatibility** on CNV 4.21.3. If it works, ULA dual-stack becomes live. If it doesn't, either (a) file upstream issue, (b) commit to the supernet pattern ([§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)) as the strategic answer, OR (c) accept native `subnets` plus the hypershift-automation allocation playbook ([§6.5](#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks)).
3. **Validate the supernet pattern ([§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)) end-to-end:** apply NAD with
   `range: 10.200.0.0/16` + `range_start/end` carving a per-cluster sub-pool, ping pod-to-pod across clusters on L2, run a real CCLM migration. If this works, it might be the answer that unblocks everything else without needing Whereabouts ipv6 ULA work to land.
4. **Build the hypershift-automation subnet allocation playbook** per [6.5](#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks) spec: gates the "many clusters joining the fleet" scenario.
5. **Once battle-tested:** file upstream openshift-docs issue with the IPAM strategy gap (see end of section 10).

### Cluster context

- **Source (hosted cluster):** `hosted-cluster-a` in namespace `hosting-cluster-1-hosted-cluster-a` on the management cluster. OCP 4.21.11, CNV 4.21.3, OVS Balance-SLB, 3 worker nodes.
- **Destination (management cluster):** `hosting-cluster-1.example.com`, OCP 4.21.11, CNV 4.21.3, MCE 2.11.0, 4 worker nodes including the hosting cluster nodes.
- Both share the migration VLAN (100) over stretched L2.

---

## 1. What CCLM is, in one paragraph

Cross-Cluster Live Migration (decentralized live migration) lets you move a running KubeVirt VM from one OCP cluster to another, **without restarting the workload**. It is a 4.21 feature, layered on top of MTV (Migration Toolkit for Virtualization, a.k.a. Forklift). The two clusters coordinate the migration through MTV providers; the actual VM RAM transfer flows directly between `virt-handler` pods on the source and destination nodes - which is why the two clusters need a network path that lets those pods talk.

This is **different from MTV cold migration** (where the VM is shut down, disk copied, restarted on the destination). CCLM keeps the VM up the whole time, like vSphere vMotion across vCenters.

**Status:** **GA in OCP 4.21.** Confirmed by lab testing (fedora and centos cross-cluster migrations succeeded end-to-end on 4.21.11 / 4.21.12). The OKD 4.21 docs (`virt-enabling-cclm-for-vms`, `virt-configuring-cross-cluster-live-migration-network`) document the feature. The `decentralizedLiveMigration` feature gate flag still exists in HCO for backward compatibility but is on by default in 4.21.

---

## 2. The lab topology we're targeting

```mermaid
flowchart LR
    subgraph A["Cluster A (ACM hub)"]
        A1[ACM operator]
        A2[OpenShift Virt]
        A3["MTV (Forklift)"]
        A4[virt-sync-controller]
        A5["Each node: 2 physical NICs"]
    end
    subgraph B["Cluster B (workload)"]
        B1[HCP hosting cluster]
        B2[Hosted clusters]
        B3["OpenShift Virt<br/>(where VMs run)"]
        B4["Each node: 2 physical NICs"]
    end
    A <-->|"L2 / L3 underlay<br/>(customer responsibility)"| B
```

**Open question for the POC:** does Cluster B also have OpenShift Virt and MTV installed, or only Cluster A? CCLM requires **both** clusters to be CNV-enabled and to have the MTV feature gate flipped. If Cluster B is purely HCP-as-a-service without its own CNV stack, CCLM doesn't apply - that would be a different migration story (HCP node movement, not VM live migration).

> Action: confirm Cluster B has the OpenShift Virtualization operator
> deployed and at least one node configured as a virt-capable worker.

---

## 3. The cluster topology this doc assumes (read this first)

This doc was written specifically for OCP-V clusters that bond their physical NICs **inside OVS** (typically `balance-slb` mode), which is the pattern Red Hat OpenShift Virtualization recommends and that the HyperShift / ACM automation produces by default. The lab cluster used here looks like this:

```mermaid
flowchart TB
    nics["ens33, ens34<br/>(physical NICs, MTU 9000)"]
    bond["ovs-bond<br/>(OVS-level bond, balance-slb mode<br/>no Linux 'bond0' device exists)"]
    brphy["br-phy<br/>(physical-underlay bridge)"]
    patch1["patch-phy-to-ex<br/>(access VLAN 100, cluster default network)"]
    brex["br-ex<br/>(OVN primary bridge)"]
    patch2["patch-br-ex-to-br-int"]
    brint["br-int<br/>(OVN integration bridge, internal)"]
    nics --> bond --> brphy --> patch1 --> brex --> patch2 --> brint
```

Critical implications of this topology:

1. **There is no Linux `bond0` device.** `nmcli device show bond0` returns "Device 'bond0' not found". The bonding happens inside OVS. Anything you write that tries to attach a `vlan` interface to a Linux `bond0` parent will fail with `Bug: Manager(UnknownDevice)`.

2. **Adding a new VLAN traffic class never means creating a new bridge.** The physical bridge `br-phy` already exists and already carries the bonded uplink. To add a new logical network on a different VLAN, you register an OVN `localnet` mapping pointing at the existing `br-phy`, and your NAD specifies the VLAN tag. OVN handles the rest (tagging at egress, untagging at ingress, multiplexing through the same bond).

3. **`br-ex` and `br-phy` are off-limits for direct mutation.** You don't add ports to them, change their port lists, or recreate them. They were configured by the cluster's day-0 NMState and any change to that risks breaking the entire cluster's primary network. The migration network is added by adding metadata (a bridge mapping) to `br-phy`, not by changing `br-phy`'s structure.

If your cluster uses **Linux-level bonding** instead (kernel `bond0` managed by NetworkManager, with OVS bridges layered on top), this doc does NOT apply directly - the NMState side is more complex and you'd need a different approach (typically a dedicated `br-migration` OVS bridge with a `bond0.<VID>` Linux VLAN sub-interface as port). That variant is the pattern you'll find in older Red Hat KB articles, but it's not what current CNV installs produce.

> **Action before applying any of this:** confirm your cluster's bonding
> model. Quick check on any worker node:
>
> ```bash
> oc debug node/<worker> -- chroot /host bash -c '
>   nmcli device show bond0 2>&1 | head -3
>   ovs-vsctl list-br
>   ovs-vsctl get open_vswitch . external_ids:ovn-bridge-mappings
> '
> ```
>
> If `bond0` returns "Device not found" and you see `br-phy` in the
> bridge list with an existing `<name>:br-phy` mapping, you're in the
> OVS-bonded topology this doc covers.

---

## 3.1 Why the 2-NIC constraint mattered (and how OVS-bonding resolves it)

The original concern was: with only 2 physical NICs, we can't dedicate one to live migration. They have to carry **everything** multiplexed - pod network, VM data, migration - distinguished by VLAN tag.

In **Linux bonding** topology that means juggling VLAN sub-interfaces (`bond0.100`, `bond0.200`, `bond0.300`) and chaining them into multiple bridges - which is where the original bad approach came from.

In **OVS bonding** topology the multiplexing is already there for free: `ovs-bond` carries every VLAN trunked from the switch into `br-phy`, and OVN's bridge-mappings let you slice that into as many logical networks as you want. Adding the migration network is a one-line configuration change to a CRD field - no new bridges, no VLAN sub-interfaces, no host-level network surgery.

This is one of those cases where the design done by the cluster install already paid the operational cost we were worried about, and we just need to plug into it correctly.

---

## 4. The architecture - layer by layer

### 4.1 Host network (NMState / NodeNetworkConfigurationPolicy)

Because the cluster uses OVS-level bonding (see section 3), the entire host-network change collapses to **one CRD field**: extending the `ovn.bridge-mappings` entry on the existing `br-phy`. No interfaces section. No bridge creation. No VLAN sub-interface.

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: cclm-migration-mapping
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    ovn:
      bridge-mappings:
        - bridge: br-phy
          localnet: vmnet     # ← preserve the existing mapping the cluster
                              #   already had (replace with whatever name
                              #   `ovs-vsctl get open_vswitch .
                              #   external_ids:ovn-bridge-mappings` returns
                              #   on your worker)
          state: present
        - bridge: br-phy
          localnet: cclm-mig  # ← the new mapping for the migration network
          state: present
```

**Why both entries are listed**: NMState reconciles the `ovn.bridge-mappings` list against the current OVS database state. Listing both with `state: present` is the safe form - it asserts the desired final state explicitly and won't accidentally remove the pre-existing mapping by omission. (To remove a mapping later, change its `state: present` to `state: absent` and re-apply.)

**`localnet` name choice**: `cclm-mig` is what the NAD will reference via `physicalNetworkName`. Pick any short stable string; it's a logical handle, not parsed by anything. Don't change it after the NAD is deployed - changing it breaks the binding.

**No physical interface, VLAN sub-interface, or bridge declaration is needed.** OVN sees the new mapping, creates the patch ports it needs between `br-int` and `br-phy` automatically, and starts tagging frames with whatever VLAN the NAD specifies (see [§4.2](#42-networkattachmentdefinition-the-migration-nad)) when they egress to `br-phy`. The existing `ovs-bond` carries the new VLAN out to the switch alongside the cluster's other VLANs, multiplexed.

**Don't try to add `interfaces:` to this NNCP** to "set up" anything extra. The temptation is to declare a VLAN sub-interface, an OVS bridge, an internal port - all of those are wrong for this topology and have specific failure modes documented from earlier debugging:

| Attempted shape | Failure mode |
|---|---|
| `bond0.300` Linux VLAN sub-interface | `Bug: Manager(UnknownDevice): Failed to find a compatible device` - there is no `bond0` Linux device for NM to anchor the VLAN to |
| `br-migration` ovs-bridge with `bond0` as port | OVS rejects: `bond0` doesn't exist as an OVS interface either; the OVS bond inside `br-phy` is named `ovs-bond` and is already a port on `br-phy` |
| `br-migration` parallel to `br-phy` | Works mechanically but disconnected from the physical underlay - frames go nowhere because neither bridge has a path to the bond |

The "just extend bridge-mappings" form is the **only** correct shape for this topology, and it's also the simplest.

**Pre-flight checks before applying:**

1. **Switch trunk includes the migration VLAN.** Confirm with the network team that VLAN 300 (or whichever ID you pick) is permitted on the same trunk port that already carries VLAN 100 (cluster default). If the switch isn't trunking it, the frame leaves `br-phy` tagged but the switch drops it.

2. **VLAN ID not in conflict.** Confirm 300 isn't already in use for storage, hypervisor management, or another tenant.

3. **Existing `localnet` name preserved.** Get the current value from any worker:
   ```bash
   oc debug node/<worker> -- chroot /host \
     ovs-vsctl get open_vswitch . external_ids:ovn-bridge-mappings
   ```
   If it returns `vmnet:br-phy`, the YAML above is correct. If it's different (like `physnet:br-phy` or a comma-separated list), update the first entry to match.

### 4.2 NetworkAttachmentDefinition (the migration NAD)

The NAD references the `localnet` name registered in section [§4.1](#41-host-network-nmstate-nodenetworkconfigurationpolicy)'s bridge-mappings, and tells OVN which VLAN to tag with. The validated lab shape:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: cclm-migration
  namespace: openshift-cnv     # CNV namespace - virt-handler runs here
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "cclm-migration",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "openshift-cnv/cclm-migration",
      "physicalNetworkName": "cclm-mig",
      "vlanID": 100,
      "mtu": 9000,
      "subnets": "10.200.5.0/24"
    }
```

Field-by-field:

- **`type: ovn-k8s-cni-overlay` + `topology: localnet`**: OVN-Kubernetes plugin path that integrates with the OVN logical network and uses bridge-mappings to figure out which physical bridge to egress through. On OVN-K clusters this is the canonical choice for pod attachments to a physical-underlay network.
- **`physicalNetworkName: cclm-mig`**: matches the `localnet` value in the NNCP from [4.1](#41-host-network-nmstate-nodenetworkconfigurationpolicy). This is the link between NAD and bridge mapping; if it doesn't match, OVN can't find a bridge to send the traffic to.
- **`vlanID: 100`**: OVN tags egress frames with this when they leave `br-phy` toward `ovs-bond`. The frame arrives on the wire with the 802.1Q tag. The destination side untags by matching VLAN 100 in its own bridge-mappings. **Pick any VLAN ID** that is (a) trunked between both clusters' switches and (b) not in conflict with another use. The lab landed on 100 because that VLAN was already trunked end-to-end; customer deployments will pick whatever fits their fabric.
- **`mtu: 9000`**: matches the underlay (`ens33` / `ens34` are at 9000 in the lab cluster). Live migration is bandwidth-heavy and benefits from jumbo frames; the bond and switch are already configured for it. If the underlay is at 1500, drop this to 1500 too.
- **`subnets: "10.200.5.0/24"`**: OVN-K8s's native IPAM for localnet topologies. OVN allocates IPs from this range to virt-handler pods attached to this NAD. **No external IPAM package required** - `subnets` is the simplest correct shape for OVN-K8s localnet. See section 5 for the rationale and the case where Whereabouts would be preferable instead.

### 4.3 HyperConverged (point KubeVirt at the NAD)

Same edit on **both** clusters:

```bash
oc edit hyperconverged kubevirt-hyperconverged -n openshift-cnv
```

```yaml
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  liveMigrationConfig:
    network: cclm-migration         # <-- the NAD name
    completionTimeoutPerGiB: 800
    parallelMigrationsPerCluster: 5
    parallelOutboundMigrationsPerNode: 2
    progressTimeout: 150
```

After this `oc apply`, **virt-handler pods restart** and the dedicated network is in use for any subsequent migration (intra-cluster or CCLM).

### 4.4 Enable Cross Cluster Live Migration

```bash
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type json -p '[{"op":"replace", "path": "/spec/featureGates/decentralizedLiveMigration", "value": true}]'
```

```bash
oc get pods -n openshift-cnv | grep virt-synchronization
```

### 4.5 Virtualization Settings

Before going any further, setup your Virtualization Environment. Go to `Virtualization > Overview > Settings` and setup/enable:

- Live migration network: cclm-migration
- Enable folders in Virtual Machines tree view
- Enable advanced CD-ROM features


---

## 5 Migration Toolkit for Virtualization Operator

Install MTV Operator in both clusters, and create the **Forklift Controller**.

### 5.1 MTV feature gate (CCLM enablement)

On **both** clusters with MTV installed:

```bash
oc patch ForkliftController forklift-controller \
  -n openshift-mtv \
  --type json \
  -p '[{"op": "add", "path": "/spec/feature_ocp_live_migration", "value": "true"}]'
```

Verify:

```bash
oc get ForkliftController forklift-controller -n openshift-mtv -o yaml | \
  grep feature_ocp_live_migration
```

Should show: `feature_ocp_live_migration: "true"`.

### 5.2 Service account and token to use with MTV providers

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: live-migration-role
rules:
  - apiGroups:
      - forklift.konveyor.io
    resources:
      - '*'
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - secrets
      - namespaces
      - configmaps
      - persistentvolumes
      - persistentvolumeclaims
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  - apiGroups:
      - k8s.cni.cncf.io
    resources:
      - network-attachment-definitions
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - storage.k8s.io
    resources:
      - storageclasses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - kubevirt.io
    resources:
      - virtualmachines
      - virtualmachines/finalizers
      - virtualmachineinstancemigrations
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  - apiGroups:
      - kubevirt.io
    resources:
      - kubevirts
      - virtualmachineinstances
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - cdi.kubevirt.io
    resources:
      - datavolumes
      - datavolumes/finalizers
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  - apiGroups:
      - apps
    resources:
      - deployments
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  - apiGroups:
      - instancetype.kubevirt.io
    resources:
      - virtualmachineclusterpreferences
      - virtualmachineclusterinstancetypes
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - instancetype.kubevirt.io
    resources:
      - virtualmachinepreferences
      - virtualmachineinstancetypes
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
```

Service Account:

```bash
oc create serviceaccount openshift-mtv -n openshift-cnv
oc create clusterrolebinding openshift-mtv --clusterrole=live-migration-role --serviceaccount=openshift-cnv:openshift-mtv
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sa-openshift-mtv-secret
  namespace: openshift-cnv
  annotations:
    kubernetes.io/service-account.name: openshift-mtv
type: kubernetes.io/service-account-token
```

Token:

```bash
TOKEN_BASE64=$(oc get secret "sa-openshift-mtv-secret" -n "openshift-cnv" -o jsonpath='{.data.token}')
  TOKEN=$(echo "$TOKEN_BASE64" | base64 --decode)
  echo "$TOKEN"
```

Token example:

Cluster 1 (HOSTING-CLUSTER-1 - LAB)

```text
eyJhbGciOiJSUzI1NiIsImtpZCI6InZienlyTjIxd29aNUYyTTJiSm4zdXhMYlc1aFRtbXAwVGMwUXY0MTRyNmMifQ.eyJpc3MiOiJrdWJlcm5ldGVzL3NlcnZpY2VhY2NvdW50Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9uYW1lc3BhY2UiOiJvcGVuc2hpZnQtY252Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZWNyZXQubmFtZSI6InNhLW9wZW5zaGlmdC1tdHYtc2VjcmV0Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZXJ2aWNlLWFjY291bnQubmFtZSI6Im9wZW5zaGlmdC1tdHYiLCJrdWJlcm5ldGVzLmlvL3NlcnZpY2VhY2NvdW50L3NlcnZpY2UtYWNjb3VudC51aWQiOiIyNjJmZTA0NC01YjE2LTRhNjAtYTYwZS00ZmI5MGFiYmE3NzAiLCJzdWIiOiJzeXN0ZW06c2VydmljZWFjY291bnQ6b3BlbnNoaWZ0LWNudjpvcGVuc2hpZnQtbXR2In0.ihx7TV1Cu7iHumdnT48b7Y8PGqqYekNQphLZOk4OIfCAFVzOc8jjjvisrYV8rsnPuz0gqJQPUppW95agkaAstB06Q5XaL3SZBZRVIO8LCYRqP6daZprEGbxpgUqRDj2o6JrpVPUKjx4CROhA3JLx4oGAh9eLcnS8V7_YMlQPcdNarwYAVFlrSNwlqd6Up42PgBJnr3D-5wPajYbwosZ1AresMJru2QysWckCh8Elds_bS08FL4XrjAXs26dvhaP4GcZzD91kaykl5J2173XUa9slPbxGm3syqHPWv1jjjx9K1HTDxDwuSlg7ZJ3c-P6auJRc-t38hJxISuJ4XIQny2pcbzwoeyneuMMwjDV15NAo3aDpHy7cjb7edNYNwVZe5Qqt7oAiEExXL6RnGsomt5zGHKOEKs__Sh6HHNo9mWS9NwNgZYbitesEj5ZHL1iu9VCIiaojq6bs5bDX4rNVIrAVnEAiCB21NKwWYHHTFXofiKqrAq7HIHrbfMXCx8CYI-d7XrRg8FMR_ZZh9AZlwPlTZ_UHaJW8NxTQw6sago6CnZ9l0oX16pG6pB9MWfqHsrPlDsO0yragmsVUiYP8riRxh1gYlDs-zcZGAD_vLL24fEwQTfbSaYw1FKvLZaXtjmk3KzEPuZbkUaI94WZcA-gw-rPqRKSkdwpXg_6P4aU
```

Cluster 2 (HOSTED-CLUSTER-A - LAB)

```text
eyJhbGciOiJSUzI1NiIsImtpZCI6IlRuUWI2dzhZemxmMzBHenliWHozSVRoSTh1MHdfR081RXZmTGY5dGhtWlEifQ.eyJpc3MiOiJrdWJlcm5ldGVzL3NlcnZpY2VhY2NvdW50Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9uYW1lc3BhY2UiOiJvcGVuc2hpZnQtY252Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZWNyZXQubmFtZSI6InNhLW9wZW5zaGlmdC1tdHYtc2VjcmV0Iiwia3ViZXJuZXRlcy5pby9zZXJ2aWNlYWNjb3VudC9zZXJ2aWNlLWFjY291bnQubmFtZSI6Im9wZW5zaGlmdC1tdHYiLCJrdWJlcm5ldGVzLmlvL3NlcnZpY2VhY2NvdW50L3NlcnZpY2UtYWNjb3VudC51aWQiOiIxZTU0MjFkNy1hN2EyLTRlZTUtOTliMC1jMWViYzRkODIwN2IiLCJzdWIiOiJzeXN0ZW06c2VydmljZWFjY291bnQ6b3BlbnNoaWZ0LWNudjpvcGVuc2hpZnQtbXR2In0.fN_V6xvcFCGtRGRUtH3b4AgLWN7ckGAizUCDRjSGXwU4YQWJ_ceYlWjJDDBzsprcVc0hsKxEfJtbZbk0yMVx49LDVicbVK42AY7DmsgyrckrmVuap2gY5VXqENrABeS0OzEcLgf93JodrYpXA-ZxZKETCZpXF-67efA842COHMJbYVN8ecE8LWkVWz3EKU3IHLC8G1LoRQ0F8Zb3FePbqdn0qN9Fwfal0j7o93WpELYm_mk6GgbVhWYCPmKUYnzn1cYlqTPEFIO96J2it4rj5O6rD_vHeqyzHl8C20Ktl-4YLHagCPQA7VDdOgyC11hX_fVS5Fe_vg7MFN6WY4_ONw
```

### 5.3 MTV providers (each cluster knows the other)

Each cluster needs an MTV `Provider` for the **destination** cluster (and typically a local one for itself). The provider stores credentials + an endpoint for the other cluster's API. Detailed provider setup varies and is documented at:

- https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization/2.9/html-single/installing_and_using_the_migration_toolkit_for_virtualization/index#adding-source-provider_cnv

For the POC, we'll use long-lived service-account tokens (simpler than ACM-managed mTLS for first-pass validation).

Use the tokens obtained above.

VDDK: Is needed for cross cluster live migration???

---

# TIP: HCP Upgrade

First, update MCE Operator to 2.1.

1. Upgrade the hosted cluster control plane first.

```bash
oc patch hostedcluster hosted-cluster-a -n hosting-cluster-1-hosted-cluster-a --type merge \
  -p '{"spec":{"release":{"image":"quay.io/openshift-release-dev/ocp-release:4.21.11-multi"}}}'
```

2. Watch the control plane rollout. Wait for `Progressing=True` to flip to `Completed` and `VERSION` to land at 4.21.11.

```bash
oc get hostedcluster hosted-cluster-a -n hosting-cluster-1-hosted-cluster-a -w
```

3. Once the control plane is done, upgrade the workers.

```bash
oc patch nodepool hosted-cluster-a -n hosting-cluster-1-hosted-cluster-a --type merge \
  -p '{"spec":{"release":{"image":"quay.io/openshift-release-dev/ocp-release:4.21.11-multi"}}}'
```

4. Watch the NodePool. `UPDATINGVERSION=True` during the rolling update, then `VERSION=4.21.11` at the end.

```bash
oc get nodepool hosted-cluster-a -n hosting-cluster-1-hosted-cluster-a -w
```

---

## 6. IPAM strategy

The IPAM strategy is the single most consequential architectural decision in this design. It determines whether CCLM scales as the cluster fleet grows, whether new clusters can join without coordination with the network team, and whether [9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain)-style IP collisions are possible at all.

The hierarchy below reflects the **target end-state for production**, not the order in which we built the lab. Section [§6.4](#64-architectural-rationale-why-ula-dual-stack-is-the-default) explains the rationale.

### 6.1 Recommended default: dual-stack (IPv6 ULA primary + IPv4 fallback)

Each cluster picks its own globally-unique ULA `/112` prefix from `fd00::/8`, plus optionally an IPv4 range for environments where L3 routing happens to be available. Whereabouts handles both via `ipRanges`:

```yaml
# Per-cluster NAD (each cluster picks its own ULA prefix)
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "cclm-migration",
      "type": "ovn-k8s-cni-overlay",
      "topology": "localnet",
      "netAttachDefName": "openshift-cnv/cclm-migration",
      "physicalNetworkName": "cclm-mig",
      "vlanID": 100,
      "mtu": 9000,
      "ipam": {
        "type": "whereabouts",
        "ipRanges": [
          { "range": "fd42:cclm:01::/112" },     # cluster A's ULA
          { "range": "10.200.5.0/24" }            # IPv4 fallback (optional)
        ]
      }
    }

# Cluster B uses a different ULA prefix:
#   { "range": "fd42:cclm:02::/112" }
# Cluster C: fd42:cclm:03::/112
# ... and so on. ULAs are picked freely; collision probability is
# astronomically low if the second hextet is randomized.
```

**Why this is the default:**

- **Eliminates collision by construction.** Two clusters cannot accidentally pick the same ULA `/112` if the prefix scheme reserves a unique hextet per cluster (or just randomizes). [9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain) is structurally impossible with IPv6 between clusters.
- **No coordination with the network team to onboard a new cluster.** ULA is link-local enough that the cluster can self-allocate. The L2 segment carrying VLAN 100 between DCs is already there for the underlay; ULA traffic rides it transparently.
- **IPv4 fallback for environments where it just works.** Some sites have L3 routing already in place between DC fabrics for the migration VLAN. When IPv4 routing is available end-to-end, dual-stack lets virt-handler pick whichever family establishes the connection first. When it isn't, IPv6 carries the traffic and IPv4 is dead weight (fine: the only cost is a slightly longer IPAM allocation step).

**Caveats** (carry over from earlier IPv6 notes):

1. **virt-handler / libvirt IPv6 readiness.** Recent libvirt versions (10.x+) are IPv6-clean for migration; pre-10.x had quirks. Validate end-to-end on the lab cluster before committing to a customer environment.

2. **Whereabouts /65 limit.** Whereabouts has a uint64 offset bug for prefixes ≤ /65: only the first /65 is addressable. `/112` is far below that, no issue. Don't allocate from a `/48` or `/64` directly.

3. **OVN-K cluster network must include IPv6.** Check `oc get network.config cluster -o yaml` for IPv6 entries in `serviceNetwork` / `clusterNetwork`. If the cluster was installed IPv4-only, the dual-stack NAD may attach but IPv6 won't actually flow. Some clusters need a dual-stack reinstall or a stack-conversion procedure to enable IPv6.

4. **Reverse DNS.** ULA addresses don't have rDNS unless you set up local `ip6.arpa` zones. Some health checks or logging assume rDNS resolves. Usually not blocking, but a warning.

5. **OVN-K `localnet` + Whereabouts compatibility.** The lab attempt to switch from native `subnets` IPAM to a Whereabouts `ipam` block on the OVN-K `localnet` topology did not produce working IPs on CNV 4.21.x: needs deeper investigation. Track this as the open question blocking the dual-stack default.

### 6.2 Lab-only fallback: native OVN-K `subnets` (single shared subnet)

What the lab is currently running and how the docs example reads. Single `/24` shared between clusters via stretched L2, OVN-K's native `subnets` field for IPAM:

```yaml
ipam:                                  # NOT used: this shape uses
                                       # OVN-K's native field instead
spec:
  config: |
    {
      ...
      "subnets": "10.200.5.0/24"
    }
```

**Why this is lab-only and must NOT be used in production:**

- **OVN-K IPAM runs independently per cluster.** Both clusters allocate from the same range without knowing about each other. Collisions are not just possible: they are inevitable at scale (n nodes per cluster, m clusters, single /24 → exhaustion + collision).
- **Manifests in [§9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain): split-brain migration with cold-boot fallback on
  the destination.** The failure mode is intermittent and silent: Forklift reports `Succeeded` while the workload is actually frozen on the source.
- **No path forward as the fleet grows.** Each new cluster increases collision probability; you cannot escape it without changing the IPAM strategy.

**Use only for:**
- Initial PoC where the goal is "validate that CCLM control plane and cluster wiring work end-to-end" and you accept dice-roll migrations.
- Single-cluster setups where CCLM-cross-cluster isn't actually in scope (intra-cluster migration only).

### 6.3 Optional opportunistic alternative: distinct subnets per cluster + L3 routing

Each cluster has its own RFC1918 subnet, with a router between them (static routes or BGP):

```yaml
# Cluster A NAD: 10.200.5.0/24
# Cluster B NAD: 10.200.6.0/24
# Routes on the underlay carry traffic between them.
```

**Use only when:**
- The customer's network team has already agreed to provision and route a per-cluster migration subnet, AND
- There is a clear commitment to expand routing to every future cluster joining the fleet.

**Why this is NOT the default:**
- L3 routing on the migration network is **not universally available**. Many enterprise environments have a flat L2 fabric between DCs for workload reasons and adding routing requires the network team's cooperation, security review, and ongoing maintenance.
- Every new cluster requires a new subnet allocation request and a routing change. This is a coordination tax that compounds with cluster count and ages poorly as the fleet grows.
- ULA dual-stack solves the same scaling problem without any of that coordination, so when both options are on the table, ULA wins.

This option is documented because some environments already have the plumbing and are happy with it: there's no reason to fight a working setup. But don't propose it as the default.

### 6.4 Architectural rationale (why ULA dual-stack is the default)

Three constraints drive the design:

1. **No control over the customer's L3 fabric.** Migration networks need to traverse between DCs, and we can't assume the network team will provision routing on demand for every CCLM-participating cluster. The architecture must work whether or not L3 routing exists.

2. **Cluster fleet grows over time.** The deployment model is "many clusters joining the fleet, often the same DC, often on shared network infrastructure." Any IPAM scheme that requires per-cluster coordination (with the network team, or with other clusters) breaks under that growth. Self-allocation is mandatory.

3. **Collisions in shared-subnet IPAM are a silent failure mode.** When IPAM collides, CCLM doesn't error cleanly: it produces a split-brain with a falsely-successful Forklift status ([§9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain)). This is the worst failure shape for a customer-facing tool: looks like it works, doesn't.

Mapping constraints to options:

| Strategy | Self-alloc? | Survives no-L3-routing? | Collision-free? | Result |
|---|---|---|---|---|
| Lab default (Option A: shared `/24` + OVN-K native) | yes | yes (L2 stretch) | **no** | only for lab |
| Per-cluster RFC1918 + L3 (Option B / [6.3](#63-optional-opportunistic-alternative-distinct-subnets-per-cluster-l3-routing)) | **no** (needs network team) | **no** | yes | opportunistic only |
| ULA dual-stack ([§6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback)) | yes | yes (L2 stretch carries v6) | yes (per-cluster prefix) | **default** |

ULA dual-stack is the only option that satisfies all three constraints. The IPv4 fallback in the dual-stack pair adds optional interop with sites that already have L3 routing, at no cost in environments that don't.

The sequencing for an existing deployment is:

1. Validate IPv6 path on the lab end-to-end (libvirt + virt-handler + sync-controller + actual cross-cluster migration on IPv6).
2. Resolve the OVN-K `localnet` + Whereabouts compatibility question on the target CNV version.
3. Switch one cluster pair to dual-stack NAD, validate intra and cross-cluster migration both work.
4. Roll dual-stack as the default for new cluster onboarding.
5. Migrate existing single-stack lab clusters to dual-stack opportunistically.

### 6.6 Supernet pattern: per-cluster sub-pools sharing one L2 broadcast domain

> **Status: not yet validated in lab.** Promising L3-free alternative to
> ULA dual-stack that may unblock the scaling story without needing
> Whereabouts to work on OVN-K `localnet`. **Recommended next-step
> validation in the dedicated CCLM session.**

The pattern below exploits a basic L2/L3 distinction that the official docs and most discussions of CCLM glide over:

- **L2 broadcast domain** is defined by the VLAN (or absence of). Every pod attached to the migration NAD on VLAN 100 is in the same L2 domain regardless of cluster. ARP/NDP flow naturally between them.
- **Subnet** (range + mask) is a host-side decision about which IPs the kernel treats as on-link vs off-link. Multiple subnets can coexist on one L2 domain: and the host's subnet mask is what determines whether it tries to ARP for a destination or hand the packet to a default route.

The trick: pick a **supernet** big enough to cover the whole fleet (e.g. `10.200.0.0/16`), then have each cluster's NAD allocate a **sub-pool** from inside that supernet, but advertise the **supernet mask to pods** instead of the sub-pool mask.

```yaml
# Cluster A NAD
ipam:
  type: whereabouts
  range: 10.200.0.0/16              # ← MASK PROPAGATED TO PODS
  range_start: 10.200.5.10           # ← this cluster's sub-pool only
  range_end:   10.200.5.250

# Cluster B NAD
ipam:
  type: whereabouts
  range: 10.200.0.0/16              # same supernet, same mask
  range_start: 10.200.6.10
  range_end:   10.200.6.250

# Cluster C uses 10.200.7.0/24 sub-pool, etc.
```

Cluster A's pod gets `10.200.5.42/16`. The /16 mask means it sees **all of `10.200.0.0/16` as on-link**. To reach `10.200.6.42` (cluster B pod) it sends ARP into the L2 domain (VLAN 100), cluster B's pod responds, traffic flows. **No router needed, no L3 routing configuration, no per-cluster subnet announcement.** Just one VLAN trunked between clusters, and a smart mask choice.

#### Why this elegantly sidesteps every problem

| Problem we hit | Pattern A (PoC [6.2](#62-lab-only-fallback-native-ovn-k-subnets-single-shared-subnet) lab default) | Pattern B (this [6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain) supernet) | ULA dual-stack ([§6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback)) |
|---|---|---|---|
| IPAM collision ([§9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain)) | Yes, silent | No, sub-pools enforce uniqueness | No, per-cluster ULA prefix |
| Needs L3 routing | No (L2 stretch) | No (L2 stretch + supernet mask) | No (L2 stretch carries v6) |
| Needs Whereabouts working in OVN-K localnet | No | **Yes: open question** | **Yes: open question** |
| Scales to N clusters | No | Yes (250 sub-pools in /16) | Yes (16-bit hextet space) |
| Self-allocation per cluster | No (shared pool collides) | Yes (sub-pool from cluster ID) | Yes (random ULA prefix) |
| Battle-tested in adjacent contexts | N/A | Standard L2 datacenter practice for 20+ years | New for CCLM |

The supernet pattern is the **single least-invasive** option: keeps IPv4, keeps stretched L2, doesn't need the network team, doesn't need ULA tooling to work: just needs Whereabouts to attach to the OVN-K `localnet` topology.

#### What needs validation in the lab before adopting

1. **OVN-K `localnet` accepts `ipam: whereabouts` block.** This is the open question (also blocks [6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback)). If Whereabouts works at all, it probably works with this shape.
2. **A pod with mask `/16` actually sends ARP for IPs in that mask.** Standard kernel behavior: should be fine, but verify with `ip route` inside a virt-launcher pod.
3. **A pod from cluster A can ping a pod from cluster B** without any route configuration, just via L2.
4. **virt-handler/libvirt opens the migration TCP connection across the supernet** without any special routing or proxying.
5. **A real CCLM migration completes** with the supernet-mask pods.

If all five pass, this becomes the **recommended IPAM strategy**, and section [§6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback) (ULA dual-stack) drops to a longer-term option for fleets that grow past `/16` (250+ clusters with `/24`-per-cluster, or smaller sub-pools for more clusters) or want IPv6-native operations.

#### Why this should also be the openshift-docs upstream proposal

Once battle-tested, this pattern is what the upstream docs should recommend in place of the current "single shared subnet" example. It:

- Works with the docs' existing assumption of stretched L2
- Doesn't require any new tooling (Whereabouts already supported)
- Doesn't require IPv6 conversion
- Eliminates the silent split-brain failure mode ([§9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain))
- Has clear self-allocation semantics for new clusters joining

The proposed openshift-docs issue (mentioned in section 10) should include this pattern as the suggested replacement, not just IPv6 ULA.

### 6.5 Subnet allocation automation (hand-off to hypershift-automation playbooks)

> **Scope of this section:** task specification for the automation work that
> needs to happen in the `hypershift-automation` playbooks repo. This doc
> defines *what* the automation must do and *why*; the actual playbook
> implementation is out of scope here. Pick this up in a separate
> conversation focused on hypershift-automation.

#### Context: why this automation is needed

The recommended IPAM strategy ([§6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback)) is dual-stack via Whereabouts. The lab discovered that **OVN-K `localnet` topology on CNV 4.21.x does not accept a Whereabouts `ipam` block cleanly** (initial attempts produced no working IPs). Until that compatibility is resolved upstream, the only working IPAM on this combo is OVN-K's native `subnets` field on the NAD spec: which has no concept of cross-cluster coordination and reproduces the collision problem documented in [9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain).

Section [§6.2](#62-lab-only-fallback-native-ovn-k-subnets-single-shared-subnet) (lab-only fallback) documents why shared-subnet `subnets` is unsafe at scale. To use it safely **at all**, each cluster's NAD must be configured with a **unique, non-overlapping `subnets` range** allocated from a pre-defined pool. This allocation must happen automatically as part of cluster provisioning: there is no manual workflow that survives the deployment model "many clusters joining the fleet over time."

This is the gap that needs automation in `hypershift-automation`.

#### Problem statement

When a new HCP-hosted cluster is provisioned through the existing hypershift-automation flow, the playbook currently produces (or will produce) the migration NAD as a fixed YAML template with a hard-coded `subnets` value (e.g. `10.200.5.0/24`). If two clusters are provisioned from the same template, both end up advertising IPs from the same range on the same stretched-L2 migration VLAN, producing the collision in [9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain).

The automation needs to:

1. **Maintain a pool of available migration subnets** (CIDR ranges).
2. **Allocate a unique range from the pool** to each new HCP-hosted cluster at provisioning time.
3. **Render the NAD** with that allocated range substituted into `spec.config.subnets`.
4. **Persist the allocation** so a re-run of the playbook for the same cluster picks the same range (idempotency).
5. **Release the range** back to the pool when a cluster is decommissioned.

#### Inputs / outputs

**Inputs:**
- A **pool definition**: list of available CIDR ranges. Format suggestion: list of `/24`s carved from a parent block (e.g. `10.200.0.0/16` → `10.200.5.0/24`, `10.200.6.0/24`, ..., `10.200.255.0/24` = 251 usable). Pool size determines maximum cluster fleet count.
- A **cluster identifier**: stable string per HostedCluster. Suggested: `<HostedCluster.namespace>/<HostedCluster.name>` or the HostedCluster UID. Must survive cluster re-creation if appropriate (or be re-allocated if not: design decision).
- The **NAD template** (current playbook artifact, with `subnets` as a templated value).

**Outputs:**
- A rendered NAD applied to the hosted cluster with a unique `subnets` value.
- A persisted allocation record: `cluster_id → cidr` mapping, stored somewhere durable (see "State storage" below).

#### Workflow

```bash
Provisioning a new HCP cluster:
  1. Playbook reads the allocation state.
  2. If cluster_id already has an allocation:
       use that CIDR (idempotent re-run).
  3. Else:
       a. Find the first unused CIDR in the pool.
       b. If pool exhausted → fail loudly with a clear message.
       c. Reserve the CIDR (write to state with cluster_id binding).
  4. Render the NAD template substituting subnets = allocated CIDR.
  5. Apply the NAD to the hosted cluster (after the cluster is
     reachable; this likely happens in a "post-cluster-ready" task).
  6. Optionally annotate the HostedCluster CR on the management cluster
     with the allocated CIDR for visibility:
       hypershift-automation.local/cclm-migration-subnet: 10.200.42.0/24
```

```bash
Decommissioning an HCP cluster:
  1. Playbook reads the allocation for cluster_id.
  2. Removes the binding from state, returning the CIDR to the pool.
  3. (Optional) waits or confirms the cluster is fully gone before
     releasing: to avoid race where a recreated cluster collides
     with a still-alive workload.
```

#### State storage: design options

The allocation record needs to survive playbook reruns and be queryable by future runs. Three reasonable options, ordered by recommendation:

1. **ConfigMap on the management cluster** in a dedicated namespace (e.g. `hypershift-automation` or `cclm-config`). Schema:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: cclm-subnet-allocations
     namespace: hypershift-automation
   data:
     pool: |
       - 10.200.5.0/24
       - 10.200.6.0/24
       - 10.200.7.0/24
       ...
     allocations: |
       hosting-cluster-1-hosted-cluster-a/hosted-cluster-a: 10.200.5.0/24
       hosting-cluster-2-app-prod/app-prod:  10.200.6.0/24
   ```
   Pros: lives where the playbook runs, no external dependency, RBAC is straightforward. Cons: concurrent updates need optimistic concurrency (compare-resourceVersion-and-update); two playbook runs in parallel could race.

2. **Annotation on the HostedCluster CR.** Each cluster carries its own allocation:
   ```yaml
   metadata:
     annotations:
       hypershift-automation.local/cclm-migration-subnet: "10.200.42.0/24"
   ```
   Pros: collocated with the cluster it describes, no central state file, no race window because each annotation is on a different object. Cons: pool/used-set computation requires listing all HostedClusters and parsing their annotations: slow at scale, and the "pool" itself has nowhere to live (could go in a separate ConfigMap with just the pool definition).

3. **External store** (Vault, etcd, Consul, an SQLite file in the playbook repo). Pros: no Kubernetes dependency, transactionally safe. Cons: external dependency complicates the deployment model; out of character for the existing playbooks.

**Recommendation: option 2** (annotation on HostedCluster) plus a lightweight pool ConfigMap. Rationale: each cluster's allocation lives with the cluster, the playbook reconstructs the used-set by listing HostedClusters with the annotation, and the pool definition is read-only config that doesn't race. Aligns with the "kubectl is the database" pattern that hypershift itself follows.

#### Edge cases the playbook must handle

- **Pool exhausted.** Fail with a message that points to expanding the pool definition (and notes the longer-term fix is moving to ULA dual-stack). Do not allocate from outside the pool.
- **Re-run on existing cluster.** Read the existing annotation; if present and valid, no-op. If annotation is missing but a NAD on the cluster has a `subnets` value, prefer the on-cluster value and back-fill the annotation.
- **Drift detection** (optional but recommended). Compare the NAD's `subnets` value against the annotation; if they differ, fail loudly rather than silently overwriting. Likely indicates manual intervention that the playbook shouldn't paper over.
- **Two playbook runs in parallel** for two new clusters at the same time. If using option 1 (ConfigMap), implement optimistic concurrency: read resourceVersion, allocate, write with that resourceVersion as precondition; on conflict, re-read and retry. If using option 2 (annotations), the race is on listing-then-allocating: same retry pattern applies.
- **Cluster deleted but allocation orphaned.** Run a periodic reconcile (or as a playbook step) that lists HostedClusters and deletes allocations whose cluster no longer exists. Decide whether to release the CIDR back to the pool immediately or after a grace period.

#### Constraints / non-goals

- **Not a Kubernetes operator.** This is playbook-layer automation. Don't build a controller for it; the playbook runs at provisioning/decom time and that's enough.
- **Not solving the collision problem structurally.** This is a tactical unblocker for the lab → small-fleet stage. The strategic answer remains ULA dual-stack ([§6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback)). When OVN-K + Whereabouts compatibility is fixed (or CNV ships a different IPAM path), this automation becomes redundant and should be deprecated.
- **Pool size is bounded by the parent block.** A `/16` parent gives ~250 `/24` slots. If the fleet grows past that, either expand the parent or switch to ULA. Don't try to dynamically resize the pool.
- **No L3 routing implied.** The migration network remains stretched-L2 over the migration VLAN. The per-cluster `/24`s do NOT need to be routable between clusters: they share the same broadcast domain and rely on L2 for cross-cluster reachability. They just need to be non-overlapping so virt-handler IP allocation in each cluster doesn't produce collisions.

#### Hand-off summary for the hypershift-automation conversation

> *Build a playbook task that, before applying the CCLM migration NAD
> to a newly-provisioned HCP-hosted cluster, allocates a unique `/24`
> from a pre-defined pool and substitutes it into the NAD's
> `spec.config.subnets` value. Persist the allocation as an annotation on
> the HostedCluster CR (`hypershift-automation.local/cclm-migration-subnet`).
> Maintain the pool definition in a ConfigMap on the management cluster.
> Implement re-run idempotency, pool-exhaustion failure mode, drift
> detection, and a decommission path that releases the allocation. Cover
> the concurrent-provisioning race with optimistic concurrency on the
> ConfigMap. See PoC sections [6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback) (target state with Whereabouts ULA),
> [6.2](#62-lab-only-fallback-native-ovn-k-subnets-single-shared-subnet) (why we're falling back to native subnets), [6.4](#64-architectural-rationale-why-ula-dual-stack-is-the-default) (architectural
> rationale), and [9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain) (the collision failure mode this prevents) for
> context.*

---

## 7. Step-by-step setup procedure

### Per cluster (do everything in BOTH clusters):

**Step 0.** Confirm topology. (Skip if you've already done this once.)

```bash
oc debug node/<worker> -- chroot /host bash -c '
  echo "--- bond0 (should NOT exist) ---"
  nmcli device show bond0 2>&1 | head -3
  echo "--- bridges ---"
  ovs-vsctl list-br
  echo "--- existing bridge-mappings ---"
  ovs-vsctl get open_vswitch . external_ids:ovn-bridge-mappings
'
```

Confirm: `bond0` returns "Device not found", `br-phy` is in the list, and the existing mapping name is what you'll preserve in the NNCP.

**Step 1.** Apply the NNCP that extends bridge-mappings.

```bash
oc apply -f cclm-nncp.yaml
oc wait --for=condition=Available nncp/cclm-migration-mapping --timeout=2m
oc get nnce  # confirm Available on every node
```

Verify the new mapping landed:

```bash
oc debug node/<worker> -- chroot /host \
  ovs-vsctl get open_vswitch . external_ids:ovn-bridge-mappings
# Expected: "vmnet:br-phy,cclm-mig:br-phy"  (or with whatever existing
# mapping name you preserved)
```

**Step 2.** Create the NAD (Phase 1 IPv4 first).

```bash
oc apply -f cclm-nad-ipv4.yaml
```

**Step 3.** Patch HyperConverged.

```bash
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type merge \
  -p '{"spec":{"liveMigrationConfig":{"network":"cclm-migration"}}}'
```

Wait for virt-handler pods to restart:

```bash
oc rollout status daemonset/virt-handler -n openshift-cnv
```

**Step 4.** Enable the MTV feature gate.

```bash
oc patch ForkliftController forklift-controller \
  -n openshift-mtv \
  --type json \
  -p '[{"op": "add", "path": "/spec/feature_ocp_live_migration", "value": "true"}]'
```

**Step 5.** Verify `virt-synchronization-controller` is up.

```bash
oc get pods -n openshift-mtv | grep virt-synchronization
```

### After both clusters are configured:

**Step 6.** Create the cross-MTV providers (one cluster pointing at the other). This is per the MTV docs link in section [4.5](#45-virtualization-settings).

**Step 7.** Test path: deploy a small test VM on Cluster A, trigger a cross-cluster migration to Cluster B via MTV.

**Step 8.** Verify the migration actually used the dedicated network:

On Cluster B (destination), find the migration target VMI and check which IP it received the migration on:

```bash
oc get vmi <vmi-name> -o jsonpath='{.status.migrationState.targetNodeAddress}'
# Expected: an IP from the 10.200.5.0/24 range, NOT a pod-network IP
```

---

## 8. Cross-cluster connecdc1y - what's NOT in this doc

The migration NAD only does its job if the two clusters can actually exchange traffic on VLAN 300 (or whatever you pick). This is **customer infrastructure**, not OpenShift configuration. Options:

- **Single switch / stretched VLAN** (lab): trivial, both clusters' uplinks are on the same trunk.
- **VPN / IPsec tunnel** between DCs (lab-friendly, not production-grade for high-bandwidth migration).
- **L3 routed underlay** (production): each cluster announces its migration subnet via BGP / OSPF, the underlay routes between them. Requires Option B IPAM (distinct subnets per cluster).
- **L2VPN / VXLAN / EVPN** (production stretched L2): turns the migration VLAN into a single broadcast domain across DCs. Allows Option A IPAM. This is what you'd build in real DCs, but it's a network team task.

For the POC, stretched VLAN on a single lab switch is fine.

**Firewall ports:** I couldn't find authoritative documentation for the exact ports virt-handler uses for cross-node migration on OCP 4.21. The upstream KubeVirt project uses a configurable port range for libvirt migration (default starts around 49152). To be confirmed in the lab: during a test migration, capture the conversation with `tcpdump -i br-migration` and note the actual ports used. Then add firewall rules between the clusters (if any L3 firewall exists between them) for that port range.

---

## 9. Verification + troubleshooting cheat sheet

### Smoke checks after applying everything:

1. NMState converged on every node?

```bash
oc get nnce | grep cclm-migration-bridge
# All nodes should show: NetworkConfigurationPolicy ... Available
```

2. virt-handler picked up the new network?

```bash
oc get pods -n openshift-cnv -l kubevirt.io=virt-handler -o yaml | \
  grep -A2 networks
# Should show the cclm-migration NAD attached
```

3. Whereabouts has lease objects?

```bash
oc get ipamclaims -A | grep cclm-migration
```

4. Test connecdc1y between virt-handler pods:

```bash
SRC_POD=$(oc get pod -n openshift-cnv -l kubevirt.io=virt-handler \
  -o jsonpath='{.items[0].metadata.name}')
DST_POD=$(oc get pod -n openshift-cnv -l kubevirt.io=virt-handler \
  -o jsonpath='{.items[1].metadata.name}')
DST_IP=$(oc exec -n openshift-cnv $DST_POD -c virt-handler -- \
  ip -4 addr show net1 | grep inet | awk '{print $2}' | cut -d/ -f1)
oc exec -n openshift-cnv $SRC_POD -c virt-handler -- ping -c3 $DST_IP
```

### Common failure modes:

| Symptom | Likely cause |
|---|---|
| NNCP stuck "Progressing" | Switch port doesn't have the VLAN 300 trunk; check switch config |
| virt-handler crashloops after HyperConverged patch | NAD name typo, or NAD not in `openshift-cnv` namespace |
| `targetNodeAddress` is a pod-network IP, not the migration IP | HyperConverged patch didn't propagate; check `liveMigrationConfig` on the HCO |
| Migration starts but stalls at low % | Bandwidth issue or jumbo frames misconfigured. Try smaller VM (1GB RAM) first |
| Cross-cluster migration fails before transfer starts | MTV provider misconfig - check provider status, certs, tokens |
| IPv6 path: ping works but migration fails | virt-handler / libvirt IPv6 quirk - drop back to IPv4, file an issue |
| `WaitingForReceiver` / `WaitingForSync` / `Synchronizing` forever | **First suspect:** stale state from a previous failed migration: orphan VMIMs (`oc get vmim` on both clusters), VM/VMI stub on destination (MAC conflict), orphan NAD blocking CUDN ownership. Run `hypershift-automation/scripts/cclm-preflight-migration.sh --fix` to clean. **Then:** version mismatch between source and destination CNV (see [§9.1](#91-cross-version-cclm-failure-alpn-handshake)). **Then:** stale syncAddress (see [§9.2](#92-stale-syncaddress-after-virt-handler-reschedule)). Network reachability is rarely the actual cause; validate end-to-end with a pod attached to `cclm-migration` doing TCP roundtrip if in doubt. |
| `ValidReleaseImage=False: latest version supported is X.Y` on `HostedCluster` | Hypershift operator (MCE) too old to host that minor: upgrade MCE first (see [§9.3](#93-hcp-specific-hosted-cluster-cannot-upgrade-to-the-target-minor)) |
| HostedCluster console UI doesn't offer next-minor upgrade | `status.availableUpdates: null`. Patch `spec.release.image` directly, ignore the UI (see [§9.3](#93-hcp-specific-hosted-cluster-cannot-upgrade-to-the-target-minor)) |
| HCO/CNV stuck on current minor after OCP upgrade attempt | OCP must upgrade FIRST so the catalog source exposes new CNV channels (see [§9.4](#94-hco-cnv-wont-upgrade-to-next-minor-after-ocp-upgrade)) |
| `admission webhook ... denied: in-flight migration detected` | Stale VMIM from a previous failed attempt: delete it on both clusters before retrying (see [§9.7](#97-webhook-blocks-new-migration-in-flight-migration-detected)) |
| Migration "Succeeded" in MTV but VM on dest is stuck in `Scheduled` / `Starting`, source VM still Running | IP collision in shared-L2 IPAM (Option A): source dialed its own IP instead of dest's, libvirt cached the failed job (see [§9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain)). Intermittent: depends on per-pod IP allocation luck. |

---

### 9.1 Cross-version CCLM failure: ALPN handshake

**Symptom on the destination's `virt-synchronization-controller` logs:**

```
rpc error: code = Unavailable desc = connection error: desc =
"transport: authentication handshake failed: credentials:
cannot check peer: missing selected ALPN property"
```

**Diagnostic:**

Get versions on both clusters

```bash
oc version | grep "Server Version"
oc get csv -n openshift-cnv | grep kubevirt-hyperconverged
```

Check sync controller logs on the side reporting the error

```bash
oc logs -n openshift-cnv -l kubevirt.io=virt-synchronization-controller \
  --tail=30 | grep -iE "error|alpn|cert"
```

**Cause:** CCLM is **Tech Preview in OCP 4.20** and **GA in OCP 4.21**. The GA version hardened the `virt-synchronization-controller` gRPC TLS profile to require ALPN negotiation of `h2`. The 4.20 TP server does not advertise ALPN, so a 4.21 client refuses the handshake. The two clusters MUST be on the same minor (and the docs implicitly assume this: "OCP and Virtualization minor versions must match" is written for *within* a cluster but the same constraint applies between clusters for CCLM).

**Fix:** align both clusters to the same minor (4.21 baseline recommended). For HCP-hosted clusters, see [9.3](#93-hcp-specific-hosted-cluster-cannot-upgrade-to-the-target-minor).

---

### 9.2 Stale `syncAddress` after virt-handler reschedule

**Symptom on the destination's sync controller logs (after upgrade or pod recycle):**

```
rpc error: code = Unavailable desc = connection error: desc =
"transport: Error while dialing: dial tcp 10.200.5.X:9185:
connect: connection refused"
```

The VMIM still references an IP from a virt-handler pod that no longer exists (rescheduled, replaced during upgrade, or recreated for any reason).

**Diagnostic:**

What IP is the migration trying to reach?

```bash
oc get vmi <vmi-name> -n <ns> -o jsonpath='{.status.migrationState}{"\n"}'
```

Is there actually a virt-handler at that IP?

```bash
oc get pods -n openshift-cnv -l kubevirt.io=virt-handler -o json | \
  jq -r '.items[] | "\(.metadata.name) " +
  ((.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]") |
   fromjson | map(select(.name=="openshift-cnv/cclm-migration")) |
   (.[0].ips // ["NONE"]) | tostring)'
```

**Cause:** the IP listed in `migrationState.sourceState.syncAddress` (or `targetState.syncAddress`) was assigned to a virt-handler that has since been replaced. The old VMIM is permanently stuck: it will never recover because the negotiated endpoint is gone.

**Fix:** delete the stale VMIM on **both** clusters. MTV will create a new one when you trigger the migration plan again.

On the destination cluster

```bash
oc delete vmim <vmim-name> -n <ns>
```

On the source cluster

```bash
oc delete vmim --all -n <ns>   # or by name
```

---

### 9.3 HCP-specific: hosted cluster cannot upgrade to the target minor

**Symptom:** patching `HostedCluster.spec.release.image` to the target minor leaves status with:

```
ValidReleaseImage=False: "the latest version supported is: 4.20.0.
Attempting to use: 4.21.11"
```

**Diagnostic:**

Check the supported-versions configmap (reconciled by the hypershift operator). This is the authoritative cap.

```bash
oc get cm -n hypershift supported-versions -o jsonpath='{.data.supported-versions}{"\n"}'
# Example output: {"versions":["4.20","4.19","4.18",...]}
# If your target minor is missing, the hypershift operator (MCE) is too old.
```

Check MCE version

```bash
oc get csv -n multicluster-engine | grep multicluster-engine
```

What's available in the catalog?

```bash
oc get packagemanifest multicluster-engine -n openshift-marketplace \
  -o jsonpath='defaultChannel={.status.defaultChannel}{"\n"}{range .status.channels[*]}  {.name} -> {.currentCSV}{"\n"}{end}'
```

**Cause:** `supported-versions` is reconciled by the hypershift operator, which is shipped by MCE (or ACM). Each MCE minor declares which OCP minors it can host. **MCE 2.10 hosts up to OCP 4.20. MCE 2.11 hosts up to OCP 4.21.**

Editing the configmap by hand does not help: the operator overwrites it.

**Fix:** upgrade MCE first.

On the management cluster

```bash
oc patch sub multicluster-engine -n multicluster-engine --type merge \
  -p '{"spec":{"channel":"stable-2.11"}}'
```

Watch the new InstallPlan

```bash
oc get installplan -n multicluster-engine -w
# When the new CSV is "Succeeded", verify supported-versions updated:
oc get cm -n hypershift supported-versions \
  -o jsonpath='{.data.supported-versions}{"\n"}'
# Should now include the target minor (e.g. "4.21").
```

After MCE finishes upgrading, the previously-rejected `HostedCluster.spec.release.image` patch becomes valid and the hosted control plane starts upgrading automatically. Then patch `NodePool` to roll the workers.

**Why the UI didn't show the upgrade option:** the HCP console computes upgrade options from `HostedCluster.status.version.availableUpdates`, which was `null` because the hypershift operator wouldn't publish a path it couldn't validate. Patching `spec.release.image` directly bypasses the UI and is the supported HCP workflow.

---

### 9.4 HCO / CNV won't upgrade to next minor after OCP upgrade

**Symptom:** OCP minor upgraded successfully but CNV / HCO stays on the previous minor. Subscription is on `channel: stable` (or `stable-X.Y`) and approval is `Automatic`, but no new InstallPlan appears.

**Diagnostic:**

What channels does the catalog source actually expose for CNV?

```bash
oc get packagemanifest kubevirt-hyperconverged -n openshift-marketplace \
  -o jsonpath='defaultChannel={.status.defaultChannel}{"\n"}{range .status.channels[*]}  {.name} -> {.currentCSV}{"\n"}{end}'
```

If the only channels listed are for the *previous* minor (e.g. `stable -> 4.20.x`, no `stable-4.21` shown), the catalog hasn't refreshed.

**Cause (per upstream [`virt-about-upgrading-virt.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.21/modules/virt-about-upgrading-virt.adoc)):**

> *"OLM provides z-stream and minor version updates for OpenShift
> Virtualization. Minor version updates become available when you update
> OpenShift Container Platform to the next minor version. **You cannot
> update OpenShift Virtualization to the next minor version without first
> updating OpenShift Container Platform.**"*

The `redhat-operators` CatalogSource ships with OCP itself and indexes operators compatible with the current OCP minor. CNV 4.21 bundles only appear in the catalog after the cluster is on OCP 4.21.

**Fix:** finish the OCP minor upgrade. For HCP, that means waiting for both the hosted control plane (`HostedCluster`) and the workers (`NodePool`) to reach the target minor. Once OCP is on 4.21:

1. Catalog source refreshes → `stable` channel now points to a 4.21.x CSV.
2. Subscription with `installPlanApproval: Automatic` triggers a new InstallPlan automatically.
3. HCO upgrades, then reconciles all CNV component CSVs.

If after waiting the channel still doesn't show next-minor versions, restart the catalog source pod to force a refresh:

```bash
oc delete pod -n openshift-marketplace -l olm.catalogSource=redhat-operators
```

---

### 9.5 Tokens expiring during long-running upgrades

OCP/HCP upgrades can take 30 min to a few hours. Service-account tokens created with short TTLs (e.g. `oc create token --duration=1h`) expire mid-upgrade and every subsequent `oc` command returns `Unauthorized`. Re-login with a fresh token.

For the MTV providers themselves, the token used in the `Provider` CR is typically a long-lived service-account-token Secret (the YAML pattern documented in section 4.6 of this doc). Those don't expire on the same schedule as user tokens: but if you rotated the SA or its bound secret between attempts, the provider will start failing too.

---

### 9.6 `allowPostCopy` decision

Lives in `HyperConverged.spec.liveMigrationConfig.allowPostCopy`. Default: `false`.

**What it does when `true`:** if the pre-copy phase doesn't converge within `progressTimeout`, KubeVirt switches to **post-copy**: VM CPUs pause on the source, the minimum required pages transfer, CPUs resume on the destination, and the remaining pages stream in on demand at runtime.

**Risk** (per upstream [`virt-vm-migration-tuning.adoc`](https://github.com/openshift/openshift-docs/blob/enterprise-4.21/modules/virt-vm-migration-tuning.adoc)):

> *"Post copy mode should not be used for critical data, or with unstable
> networks."*

If the network drops during post-copy, the VM ends up split between source (no CPU state) and destination (incomplete memory): risk of corruption. Pre-copy without post-copy fallback simply cancels and the VM continues intact on the source.

**Lab POC:** `allowPostCopy: true` is reasonable to validate convergence of busy VMs. **Production:** keep `false` and tune `bandwidthPerMigration` + `progressTimeout` instead. Reach for `true` only on a per-workload basis, with a stable migration network.

---

### 9.7 Webhook blocks new migration: "in-flight migration detected"

**Symptom** when triggering a new migration plan in MTV (or `oc create vmim`):

```
admission webhook "migration-create-validator.kubevirt.io" denied the request:
in-flight migration detected. Active migration job (<UID>) is currently
already in progress for VMI <vmi-name>.
```

**Diagnostic:**

Find the offending VMIM(s) on both clusters

```bash
oc get vmim -A
# Look for any phase that isn't Succeeded/Failed: Pending, Scheduling,
# PreparingTarget, TargetReady, Running, Synchronizing, WaitingForSync.
```

Cross-check with what the VMI thinks is the active migration

```bash
oc get vmi <vmi-name> -n <ns> -o jsonpath='{.status.migrationState}{"\n"}'
# The migrationUID here matches the UID in the webhook error message.
```

**Cause:** an earlier migration attempt left a VMIM in a non-terminal phase (very common after [9.1](#91-cross-version-cclm-failure-alpn-handshake) ALPN failures, [9.2](#92-stale-syncaddress-after-virt-handler-reschedule) stale syncAddress, or any abort mid-handshake). KubeVirt's webhook refuses to start a new migration while it sees one "in flight" for the same VMI. Even after the underlying infrastructure issue is fixed, the old VMIM is not retried automatically : it has to be deleted manually.

**Fix:** delete the stuck VMIM on **both** clusters (CCLM creates one VMIM per side, so you can have a stale one on either or both).

Source side

```bash
oc delete vmim <vmim-name> -n <ns>
```

Destination side

```bash
oc delete vmim <vmim-name> -n <ns>
```

Verify the VMI's migrationState clears (usually within a few seconds)

```bash
oc get vmi <vmi-name> -n <ns> -o jsonpath='{.status.migrationState}{"\n"}'
```

If the migrationState is still pinned to the old UID after 30s, force-clear:

```bash
oc patch vmi <vmi-name> -n <ns> --subresource=status \
  --type=json -p='[{"op":"remove","path":"/status/migrationState"}]'
```

Then re-trigger the migration plan in MTV. A fresh pair of VMIMs will be created and the webhook will accept them.

**Tip:** if you've been retrying CCLM repeatedly during troubleshooting, sweep both clusters periodically:

Bulk-delete anything not in a terminal phase for the test VM

```bash
oc get vmim -n <ns> -o json | \
  jq -r '.items[] | select(.spec.vmiName=="<vmi-name>") |
   select(.status.phase!="Succeeded" and .status.phase!="Failed") |
   .metadata.name' | xargs -r oc delete vmim -n <ns>
```

---

### 9.8 IP collision on shared-L2 / shared-subnet (Option A IPAM): split brain

**Symptom (intermittent: affects some VMs, not others, in the same migration plan):**

- MTV reports the migration `Succeeded`.
- Destination VMI stays in `Scheduled` (never reaches `Running`).
- Destination `printableStatus: Starting`. The dest's libvirt domain is actually running, but it's a **fresh boot** (cold start from the imported PVC): not a live-migration arrival.
- **Source VM is still Running** at its original IP: never paused.
- Workloads that DID migrate cleanly in the same batch confirm infra is OK. In the lab, fedora and windows VMs migrated fine; only one centos VM hit this.

**The smoking gun in source `virt-handler` logs:**

```
"dial tcp 10.200.5.X:41841: connect: connection refused"
"unable to create outbound leg of proxy to host"
...
"server error. command Migrate failed: \"migration job <UID> already executed,
 finished at <time>, failed: true, abortStatus: \"\""
```

And the destination's `virt-launcher` logs show the cold-boot signature:

```
event="started" detail="booted"      ← reason 0 (BOOTED), not reason 1 (MIGRATED)
event="resumed" detail="unpaused"    ← reason 0 (UNPAUSED), not reason 1 (MIGRATED)
"Domain XML generated. ... <uid></uid>"   ← empty UID = fresh, not received state
```

**Cause.** With Option A IPAM (single subnet, stretched L2), each cluster runs its own OVN-K IPAM independently from the same pool. Two virt-handler pods (one per cluster) can be assigned the **same IP** because neither IPAM knows about the other. ARP on the L2 segment then becomes ambiguous and a host dialing that IP usually resolves it to **itself** (local interface short-circuit). Concretely, in the lab:

```
SOURCE virt-handler-htnpz (node worker-10) -> 10.200.5.2  (source VM runs here)
DEST   virt-handler-x5gxf (node worker-2)  -> 10.200.5.2  (target prepared here)
```

When source dials `10.200.5.2:41841` the packet stays local, port 41841 is closed on source itself → connection refused → the libvirt migration job fails immediately. The **proxy retry succeeds** ~250ms later (because the proxy itself can be re-created), but libvirt has already cached the migration job UID as failed and refuses to retry it:

```
command Migrate failed: "migration job <UID> already executed, ... failed: true"
```

The destination's virt-handler (which is on a different node, so it sees a different `10.200.5.2`) signals `migration finalized` to its virt-launcher based on the **target-prep** flow completing: not because qemu state was actually received. virt-launcher then defines a fresh domain from the imported disk, qemu boots cold. Forklift sees "finalize succeeded" and marks the wrapper VMIM `Succeeded`. Split brain established.

**Why it's intermittent.** The collision is per-pod-pair. If the source virt-handler holding the VMI happens to share an IP with the dest virt-handler chosen as migration target, the migration breaks. Other VMIs on other source nodes: or with target prep landing on a different dest node : migrate fine. In the lab, the source had `.2/.3/.10` and the dest had `.2/.4/.6/.8`; the centos VMI happened to be on the source `.2` node and the migration controller picked the dest `.2` node as target.

**Diagnostic: list virt-handler IPs on both clusters and look for overlaps:**

```bash
for ctx in source dest; do
  echo "=== $ctx virt-handlers ==="
  KUBECONFIG=/tmp/kc-$ctx oc get pods -n openshift-cnv -l kubevirt.io=virt-handler -o json | \
    jq -r '.items[] | "\(.metadata.name) node=\(.spec.nodeName) cclm=" +
      ((.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]") |
       fromjson | map(select(.name=="openshift-cnv/cclm-migration")) |
       (.[0].ips // ["NONE"]) | tostring)'
done
# Any IP appearing in both lists is a potential collision target.
```

Also check `virt-launcher` pods on both clusters: they also attach to the NAD and can collide. Migration target listener IP is a virt-launcher IP, not virt-handler.

**Recovery from a single split-brain instance:**

1. Kill the cold-booted dest virt-launcher (stop the ghost qemu)

```bash
KUBECONFIG=<dest> oc delete pod virt-launcher-<vmi>-<suffix> -n <ns>
```

2. Delete the dest VMI (Forklift recreates it on next plan trigger)

```bash
KUBECONFIG=<dest> oc delete vmi <vmi-name> -n <ns>
```

3. Clear stale migrationState on source

```bash
KUBECONFIG=<source> oc patch vmi <vmi-name> -n <ns> --subresource=status \
  --type=json -p='[{"op":"remove","path":"/status/migrationState"}]'
```

4. Sweep stale VMIMs on both sides

```bash
for ctx in source dest; do
  KUBECONFIG=/tmp/kc-$ctx oc get vmim -n <ns> -o name | \
    grep -i forklift | xargs -r KUBECONFIG=/tmp/kc-$ctx oc delete -n <ns>
done
```

Source VM keeps running uninterrupted throughout this: no workload loss.


**Workarounds (ordered by effort):**

1. **Cordon the colliding dest node and retry.** Forces the migration controller to pick a different dest node (different virt-handler, different IP).
   ```bash
   KUBECONFIG=<dest> oc adm cordon <colliding-node>
   # Re-trigger migration. Uncordon afterwards.
   ```
   Lowest-friction unblocker for one-off PoC validation. Doesn't fix the underlying problem.

2. **Force IP rotation on the colliding virt-handler.** Delete the pod; OVN-K may pick a different IP from the pool when it respawns.
   ```bash
   KUBECONFIG=<dest> oc delete pod <colliding-vh> -n openshift-cnv
   ```
   Roll-the-dice: the new pod can land on the same IP again because IPAM is order-of-arrival-based.

3. **Switch IPAM to Whereabouts with explicit non-overlapping per-cluster ranges.** This is Option A.1 in section [6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback). Same `/24` shared across both clusters via L2 stretch, but Whereabouts enforces:
   ```yaml
   # SOURCE NAD
   ipam:
     type: whereabouts
     range: 10.200.5.0/24
     range_start: 10.200.5.10
     range_end:   10.200.5.99
   # DEST NAD
   ipam:
     type: whereabouts
     range: 10.200.5.0/24
     range_start: 10.200.5.110
     range_end:   10.200.5.200
   ```
   **Caveat from lab observation:** the OVN-K `localnet` topology with `type: ovn-k8s-cni-overlay` may not accept a Whereabouts `ipam` block cleanly on this version (CNV 4.21.x): initial attempt did not produce working IPs. Needs investigation. If you can't make Whereabouts attach to the OVN-K plugin, your Option-A choices reduce to "live with the collision and use cordon" or move to Option B.

4. **Move to Option B: distinct subnets per cluster + L3 routing.** Eliminates collision by construction. Requires a router/L3 switch between clusters capable of routing the migration subnets, and the network team needs to announce/route both subnets. Operationally cleaner for production.

5. **Long-term: IPv6 ULA (Phase 2).** This is the only solution that scales to many clusters joining the fleet over time without exhausting RFC1918 address space and without requiring the network team to provision a distinct routed subnet for every new CCLM-participating cluster. Picking `fd00::/8` ULA prefixes per cluster gives effectively unlimited non-overlapping ranges and L3 routing across DCs becomes a one-time plumbing exercise. Cost: needs end-to-end IPv6 validation of virt-handler / libvirt / sync controller (PoC section [§6.2](#62-lab-only-fallback-native-ovn-k-subnets-single-shared-subnet)).

**For an enterprise that adds clusters continuously**, only options 4 and 5 scale. Option A in any flavor is a lab convenience. Plan to migrate before cluster count makes per-cluster subnet allocation painful.

**The race-condition compounding factor.** Even without IP collision, the dest sometimes signals "Migration Target Prepared" before qemu's incoming listener actually accepts on the allocated ports. Source dial-too-soon returns connection refused, and the libvirt-cached-failure pattern poisons the retry. The collision makes this dramatically more likely (because "connection refused on yourself" is instant, vs a brief network-side race on dest). Option A.1+ workarounds remove the collision; the underlying prep-vs-listen race remains a CCLM-implementation concern worth tracking upstream.

---

### 9.9 Doc-vs-real version notes (4.20 → 4.21 transition)

| Item | 4.20 | 4.21 |
|---|---|---|
| CCLM support status | Tech Preview | GA (`technology-preview.adoc` snippet removed from the assembly) |
| MTV feature gate `feature_ocp_live_migration` | **Required step** | **Removed from the assembly**. The module file still exists but is no longer included in `virt-enabling-cclm-for-vms.adoc`. Setting it is harmless if already set; it is no longer documented as required. |
| Sync controller TLS | No ALPN advertised | ALPN required (causes [9.1](#91-cross-version-cclm-failure-alpn-handshake) when versions mismatch) |
| Upstream assembly file | Includes both `virt-setting-openshiftv-lm-feature-gates` AND `virt-setting-mtv-lm-feature-gates` | Only `virt-setting-openshiftv-lm-feature-gates` |

Source for the diff: `openshift/openshift-docs` branches `enterprise-4.20` vs `enterprise-4.21`, file `virt/live_migration/virt-enabling-cclm-for-vms.adoc`.

### 9.10 ForkliftController auto-managed `host` Provider not created on the hosting cluster

**Symptom.** After installing MTV operator and creating ForkliftController on
the hosting (management) cluster, the MTV web console's Plan creation form
does not offer the local cluster as a source Provider. Only the cross-cluster
Providers (peers) appear in the dropdown. Reverse migrations (from hosting
back to a hosted) are blocked because there is no "source" to pick.

**Diagnosis.** Confirmed empirically on 2026-05-10 (OCP 4.20.13 + MCE 2.11 +
MTV 2.11.5). The MTV web console populates the "source provider" dropdown
from the `Provider` CRs in `openshift-mtv`. The local-cluster representative
is the Provider literally named `host`, which the ForkliftController is
supposed to create automatically on initial reconcile, with this shape:

```yaml
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: host
  namespace: openshift-mtv
  ownerReferences:
  - apiVersion: forklift.konveyor.io/v1beta1
    kind: ForkliftController
    name: forklift-controller
    uid: <FC uid>
spec:
  secret: {}
  type: openshift
  url: ""
```

The ansible-operator playbook that backs ForkliftController has a task named
`Setup default provider` (visible in the operator pod logs) that creates this
record. On healthy installs the task runs during the initial reconcile and
the `host` Provider appears within ~60 seconds of ForkliftController becoming
`Successful`.

In the affected hosting (created 16:01 UTC), the playbook completed with
`ok=54, skipped=28` but the `host` Provider was never materialized.
Symptomatic state was visible in:

```bash
# Hosting (broken):
oc get provider -n openshift-mtv
# NAME           TYPE        READY
# wl-linux-lab   openshift   True       ← only the cross-cluster Provider
#                                         no "host" Provider

# Hosted (healthy, same MTV version):
oc get provider -n openshift-mtv
# NAME           TYPE        READY
# host           openshift   True       ← auto-created by ForkliftController
# sp1-hst-01     openshift   True       ← cross-cluster Provider
```

ForkliftController status reported `Successful=True` with stale
`lastTransitionTime` from the initial reconcile, indicating no follow-up
reconcile had been triggered after the gap was created.

**Workaround (validated).** Delete the operator pod by name to force a fresh
ansible-operator startup. Standard `oc rollout restart` was accepted by the
apiserver but did NOT replace the pod (a new ReplicaSet was created scaled
to 0, while the old RS stayed at 1). Direct pod delete worked:

```bash
oc delete pod -n openshift-mtv -l app=forklift,name=controller-manager
```

Pod is recreated by the Deployment within ~20 seconds. The new ansible-
operator re-runs the playbook from scratch. The `Setup default provider`
task creates the missing `host` Provider, which reaches `Ready=True` after
about 30 more seconds of inventory load.

Empirical timeline observed in the operator logs after restart:

```
22:43:59  apiserver start
22:44:28  task: Fetch NetworkAttachmentDefinition for transfer network
22:44:28  task: Fail if NAD not found
22:44:29  task: Setup controller deployment
22:44:50  task: Setup providers validating webhook configuration
22:44:56  task: Setup providers mutating webhook configuration
22:44:57  task: Setup default provider          ← creates host Provider
22:44:58  Cache miss: ... Kind=Provider, openshift-mtv/host
22:45:01  Provider host appears (Status=Staging)
22:45:30  Provider host = Ready/Connected/Inventory
```

**Root cause (hypothesis).** Race condition or state regression in the
ansible-operator reconcile after `feature_ocp_live_migration` is toggled
from `"false"` to `"true"` (or some other transient state during initial
install). Same MTV version on the hosted cluster did NOT exhibit this. The
two installs differed in the timing between FC creation and the patch that
enables CCLM features, which is the most likely trigger.

**Why `oc rollout restart` did not work.** Unconfirmed root cause. The
deployment `forklift-operator` accepted the rollout command (`successfully
rolled out` returned), a new ReplicaSet `forklift-operator-59bf4bdc4` was
created, but its replica count stayed at 0 while the old RS
`forklift-operator-64759d9bb8` stayed at 1. The old pod was never replaced
despite the rollout being marked successful. Direct pod delete bypassed
whatever was holding the rollout back.

**Prevention.** Until upstream MTV fixes the underlying race, after every
MTV install on a hosting (or any cluster where you intend to run the source
side of a migration), confirm:

```bash
oc get provider host -n openshift-mtv
```

If absent, force the operator playbook to re-run with the pod-delete
workaround above. The role `cclm` in `hypershift-automation` should add
this check as Tier 1 verification material once Phase C (Providers)
automation lands.

**Filed as Bugzilla anchor** in `OPEN-SOURCE-TODO.md` under "Publishing
and upstream feedback" with the title:

> ForkliftController auto-managed "host" Provider intermittently fails to
> be created on initial install (MTV 2.11.5, OCP 4.20.13)

---

## 10. Open questions for the dedicated CCLM session

Updated as of 2026-05-04. Items grouped by status. Anything in **OPEN** is what the next session should pick up.

### OPEN: high priority

1. **OVN-K `localnet` + Whereabouts compatibility on CNV 4.21.x.** Single biggest blocker. Without this working, the strategic IPAM options ([6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback) ULA dual-stack, [6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain) supernet pattern) cannot be implemented. Try: substitute the NAD's native `subnets` field for an `ipam: { type: whereabouts, ... }` block; observe whether virt-handler pods get IPs. If they don't, capture exact behavior (no IP allocated? wrong namespace? plugin error?) and decide whether to file upstream (Whereabouts? OVN-K? CNV?) or commit to a different strategic answer.

2. **Centos-stream9 cross-cluster migration RST mid-PreCopy.** Failure reason: `Cannot recv data: Connection reset by peer` after PreCopy started. Fedora and Windows VMs on the same plan migrated cleanly, so it is not a generic CCLM problem. Tests proposed:
   a. Drop NAD MTU from 9000 to 1500, re-attempt migration. If fixes, jumbo PMTU is not end-to-end on the underlay.
   b. Set `HyperConverged.spec.liveMigrationConfig.allowPostCopy: true`, re-attempt. If fixes, PreCopy convergence is the issue (high memory dirty rate). See [9.6](#96-allowpostcopy-decision) for the operational risks.
   c. `tcpdump` on the migration network during a failing run; confirm who initiated the RST (source kernel, dest kernel, middlebox).

   Expected most-likely cause: jumbo MTU not trunked end-to-end OR a middlebox dropping long-lived flows.

3. **Validate the supernet pattern ([§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)) end-to-end.** This is the
   pattern most likely to unblock the scaling story without needing ULA work to land. Steps in [6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain).

### OPEN: secondary

4. **Exact firewall port range** virt-handler uses for cross-cluster migration. Capture from `tcpdump` during a real migration. Useful for sites with L3 firewalls between cluster fabrics.

5. **IPv6-only viability**: once `localnet` + Whereabouts works, does the full flow (libvirt, virt-handler, virt-sync-controller) work with IPv6-only on the migration network? Or do we need dual-stack for some component to be happy?

6. **HCP-hosted cluster CCLM specifics.** When the dest is a hosted control plane, do VMs running INSIDE the hosted cluster (on the hosted KubeVirt tier) participate in CCLM, or only VMs on the management cluster's own KubeVirt? Lab observation so far suggests only one tier participates per HCP hierarchy; needs explicit verification.

### CLOSED: answered during this PoC body of work

- ~~CCLM 4.21 status (GA/TP/DP)?~~ → **GA in 4.21** (`technology-preview` snippet removed from upstream assembly). TP in 4.20. (See [9.9](#99-doc-vs-real-version-notes-420-421-transition).)
- ~~Cross-version (4.20↔4.21) migration?~~ → **Does not work.** ALPN TLS handshake hardened in 4.21 GA breaks against 4.20's TP server. Both clusters must be on same minor. ([§9.1](#91-cross-version-cclm-failure-alpn-handshake))
- ~~MTV `feature_ocp_live_migration` requirement?~~ → **Required in 4.20, removed from 4.21 assembly.** Setting in 4.21 is harmless. ([§9.9](#99-doc-vs-real-version-notes-420-421-transition))
- ~~Why was the source cluster stuck unable to upgrade past 4.20.19?~~ → HCP upgrade chain: MCE 2.10 caps at hosting OCP 4.20. Need MCE 2.11 on the management cluster first to unlock OCP 4.21 hosted clusters. Patch `HostedCluster.spec.release.image` directly (UI doesn't show upgrade options when `availableUpdates` is null). ([§9.3](#93-hcp-specific-hosted-cluster-cannot-upgrade-to-the-target-minor))
- ~~Why was HCO not upgrading after OCP upgrade?~~ → Catalog source ships per-OCP-minor; CNV 4.21 channels only appear after OCP itself reaches 4.21. Subscription on `stable` + `Automatic` then auto- upgrades. ([§9.4](#94-hco-cnv-wont-upgrade-to-next-minor-after-ocp-upgrade))
- ~~Why does Forklift sometimes report `Succeeded` while VM didn't migrate?~~ → IPAM collision in shared subnet → libvirt migration job fails on connection-refused → cold-boot from imported PVC on dest while source keeps running. Silent split brain. ([§9.8](#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain))

### Battle-tested status: gating for upstream openshift-docs issue

Before submitting the openshift-docs IPAM gap issue (mentioned in [§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain) and [6.4](#64-architectural-rationale-why-ula-dual-stack-is-the-default)), the following must hold:

- [ ] OVN-K `localnet` + Whereabouts confirmed working OR confirmed unsupported with a documented reason
- [ ] Supernet pattern ([§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)) demonstrated end-to-end with real CCLM
      migration across two clusters using `range: 10.X.0.0/16` mask
- [ ] At least one repeat of the test (different VMs, different days) to confirm not a one-off
- [ ] Centos-stream9 RST issue resolved (so we're not conflating two bugs in the issue narrative)

Once all four pass, draft the upstream issue using the supernet pattern as the proposed addition to the docs (not just IPv6 ULA).

---

## 11. RVTMA integration: DONE (kickstart v1)

> **Status: shipped on `main`** as of 2026-05-04. This section is now a
> pointer, not a spec. RVTMA does the kickstart artifact emission
> (NNCP + NAD + HCO patch + README) for the OVS-bonded + 2-NIC case.
> Architectural / operational concerns (multi-cluster IPAM coordination,
> centos PreCopy investigation, ULA validation) are CCLM session work,
> not RVTMA scope.

### What's in main

- **Generator**: `js/cclm-network-generator.js` (commit `0f6680e`). Pure function `generateCCLMNetworkArtifacts(opts)` returning `{ nncp, nad, hcoPatch, readme, composite }`. 51 unit tests covering inputs, outputs, structural invariants, and the operator-facing README warnings.
- **Modal UI integration**: `js/generate-physical-network-content-modal.js` (commit `a03713b`). Live Migration Options sub-section in the Physical Network modal, gates on OVS Balance-SLB + 2 NICs, 4 input fields, inline validation error surfacing. 16 UI tests covering visibility triggers, defaults, error handling, README+HCO patch composition.
- **Validation**: generator output verified end-to-end via `oc apply --dry-run=server` against both lab clusters: NNCP unchanged, NAD unchanged, HCO patch accepted as no-op (cluster already in matching state). Schema and admission webhooks happy.

### What RVTMA does NOT do (intentional, per "kickstart only")

- Does not coordinate subnet allocation across clusters → handed to `hypershift-automation` per section [§6.5](#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks)
- Does not implement ULA dual-stack output → blocked on the OVN-K + Whereabouts compatibility question ([6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback), [6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)); when validated, it's a contained generator change
- Does not generate the Linux-bonded variant → narrow scope by design
- Does not emit the MTV `ForkliftController` feature_ocp_live_migration patch → removed from the upstream 4.21 GA assembly per [9.9](#99-doc-vs-real-version-notes-420-421-transition). Mentioned in the generator's README output as a 4.20 compatibility note.
- Does not detect bonding model from the cluster (UI asks via the bonding mode dropdown). Cluster-introspection-mode is a v2 concern.

### Future RVTMA changes (only when CCLM session unblocks them)

- **When Whereabouts + OVN-K compat is resolved** (section [§6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback) / [6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)):
  switch generator default from native `subnets` to either ULA dual-stack `ipRanges` ([§6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback)) or the supernet pattern ([§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)). Generator change is small (~20 lines + tests).
- **When `hypershift-automation` ships the subnet allocation playbook** (section [§6.5](#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks)): no RVTMA change needed: the playbook computes the per-cluster subnet, RVTMA's input field accepts whatever string is passed in.

---

## 12. Next actions for the dedicated CCLM session

This list assumes the dedicated session picks up where this doc leaves off. Items in priority order.

### Priority 1: unblock IPAM strategy

- [ ] **Test OVN-K `localnet` topology with Whereabouts `ipam` block** on CNV 4.21.x. If it works, run a real CCLM migration with the ULA dual-stack NAD shape from [6.1](#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback).
- [ ] **Test the supernet pattern ([§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)) end-to-end** as a parallel / backup track. Same lab, different NAD shape (`range: 10.200.0.0/16` + per-cluster `range_start/end`). If this works and Whereabouts doesn't, supernet becomes the strategic answer.
- [ ] Document the outcome of both in section 6 (collapse the open question into a definite recommendation).

### Priority 2: finish the centos cross-cluster migration

- [ ] Reproduce the centos-stream9 RST, run the 3-test diagnostic (MTU 1500, allowPostCopy=true, tcpdump). See section 10 OPEN #2.
- [ ] If MTU is the cause: document the underlay PMTU requirement in section 8 ("Cross-cluster connecdc1y"), add a tshoot subsection
      under 9 with the symptom + fix.
- [ ] If allowPostCopy resolves it: validate that [9.6](#96-allowpostcopy-decision)'s risk discussion
      still applies and adjust if needed.

### Priority 3: operational tooling

- [ ] Spec hand-off to `hypershift-automation` per [6.5](#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks). Spawn a
      dedicated session for the playbook implementation. Bundle this
      doc's section 6 (especially [6.5](#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks) + the answered Whereabouts /
      supernet question) as input.
- [ ] Build the playbook task per [§6.5](#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks) spec.

### Priority 4: knowledge propagation

- [ ] Once the supernet pattern ([§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)) is battle-tested, draft the
      upstream openshift-docs issue per the criteria in section 10
      ("Battle-tested status: gating for upstream openshift-docs issue").
- [ ] Submit the issue. Use the supernet pattern as the proposed addition (not just IPv6 ULA: supernet is the lower-cost win
      that also fixes the silent split-brain).

### Done: completed during this PoC body of work

- [x] Cluster topology validated (OVS Balance-SLB, br-phy + vmnet mapping pre-existing)
- [x] NNCP applied on both clusters with `cclm-mig:br-phy` mapping
- [x] NAD created on both clusters (`cclm-migration` in `openshift-cnv`)
- [x] HyperConverged patched (binds NAD via `liveMigrationConfig.network`)
- [x] MTV feature gate enabled (4.20-style; 4.21 doesn't require it)
- [x] MTV providers cross-pointing
- [x] Source cluster upgraded from OCP 4.20.19 → 4.21.11 (full HCP chain: MCE 2.10 → 2.11 → HostedCluster.spec.release → NodePool)
- [x] Cross-cluster migration validated for fedora and windows
- [x] RVTMA kickstart generator v1 shipped
- [x] PoC doc captures all 9 troubleshooting subsections, IPAM strategy, supernet pattern, hypershift-automation hand-off

---

## Sources

- **OKD 4.21 docs (web):**
  - https://docs.okd.io/4.21/virt/live_migration/virt-enabling-cclm-for-vms.html
  - https://docs.okd.io/4.21/virt/live_migration/virt-configuring-cross-cluster-live-migration-network.html
  - https://docs.okd.io/4.21/virt/live_migration/virt-about-live-migration.html

- **openshift/openshift-docs repo (raw asciidoc, branches `enterprise-4.20` and `enterprise-4.21`):**
  - `virt/live_migration/virt-enabling-cclm-for-vms.adoc`
  - `virt/live_migration/virt-configuring-cross-cluster-live-migration-network.adoc`
  - `virt/updating/upgrading-virt.adoc`
  - `modules/virt-setting-openshiftv-lm-feature-gates.adoc`
  - `modules/virt-setting-mtv-lm-feature-gates.adoc`
  - `modules/virt-configuring-secondary-network-vm-live-migration.adoc`
  - `modules/virt-configuring-live-migration-limits.adoc` (allowPostCopy)
  - `modules/virt-vm-migration-tuning.adoc` (post-copy concept + risk)
  - `modules/virt-about-upgrading-virt.adoc` (the "OCP must upgrade first" rule cited in [§9.4](#94-hco-cnv-wont-upgrade-to-next-minor-after-ocp-upgrade))
  - `modules/nw-multus-bridge-object.adoc`

- **Whereabouts CNI:** https://github.com/k8snetworkplumbingwg/whereabouts (IPv6 + dual-stack support confirmed in README; `range_start`/ `range_end` documented for sub-pool allocation patterns used in [§6.6](#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain))

- **MTV (Migration Toolkit for Virtualization) 2.11.x docs:** https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization

- **HyperShift / MCE versioning:**
  - MCE 2.10 → hosts up to OCP 4.20
  - MCE 2.11 → hosts up to OCP 4.21
  - The `supported-versions` ConfigMap in the `hypershift` namespace is the authoritative cap (reconciled by the hypershift operator;
    do not edit by hand). See [9.3](#93-hcp-specific-hosted-cluster-cannot-upgrade-to-the-target-minor).

- **RVTMA generator code & tests** (this work):
  - `js/cclm-network-generator.js`
  - `js/generate-physical-network-content-modal.js`
  - `tests/cclm-network-generator.test.js` (51 tests)
  - `tests/cclm-modal-ui.test.js` (16 tests)
  - Commits: `0f6680e` (generator), `a03713b` (UI integration)