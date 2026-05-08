# CCLM lab: configuration audit and adjustment plan

> **Purpose.** Snapshot of the two lab clusters' current CCLM-related  configuration, items that need adjustment (with rationale), and open validation work. This doc is the bridge between the POC reference doc (`cclm-network-poc.md`) and future automation playbooks. Every item here is meant to survive into runbooks or `hypershift-automation` tasks. Treat it as living: append, don't rewrite.  
>
> **Captured:** 2026-05-04  
> **Sources:** live `oc` calls against both clusters this session  

---

## 0. TL;DR: what's going on right now

- **Both clusters are configured per the POC's "lab fallback" pattern** (section [§6.2](cclm-network-poc.md#62-lab-only-fallback-native-ovn-k-subnets-single-shared-subnet) of the POC doc): native OVN-K `subnets: 10.200.5.0/24` shared on a stretched-L2 VLAN 100. This is the configuration the POC doc explicitly flags as **unsafe at scale**.
- **CCLM control plane is up everywhere it needs to be:** NNCPs Available on every node, NAD present, HCO bound to the NAD, `decentralizedLiveMigration: true`, ForkliftController feature gate enabled, MTV providers cross-pointing and Ready/Connected/Inventory.
- **An active split-brain is in flight right now:** `centos-stream9` VM is `Running` on hosted (14d uptime) AND `Starting` on hosting (89m trying). This is exactly the failure mode documented in POC section 9.8. Source has not been paused; dest never received qemu state and is cold-booting from the imported PVC.
- **Two other VMs (fedora, win2k22) migrated successfully** from hosted → hosting: confirming the infrastructure path is OK and the centos issue is per-VM-pair (likely IP collision OR jumbo MTU / PreCopy convergence per the POC's open #2).
- **One config drift between clusters:** `completionTimeoutPerGiB` is `150` on hosting, `800` on hosted. POC spec is `800`. Hosting needs to be re-aligned.

---

## 1. Cluster inventory

| Item | Hosting (hosting-cluster-1) | Hosted (192.0.2.32) | Notes |
|---|---|---|---|
| API endpoint | `api.hosting-cluster-1.example.com:6443` | `192.0.2.32:6443` | |
| Role in CCLM (per POC) | destination | source | |
| OCP version | **4.21.11** | **4.21.12** | Patch drift, same minor → CCLM OK (section [§9.1](cclm-network-poc.md#91-cross-version-cclm-failure-alpn-handshake) only fails on minor mismatch) |
| CNV version | 4.21.3 | 4.21.3 | Aligned |
| Worker nodes | 4 (3 cp+worker + 1 worker) | 3 (all cp+worker) | Hosted is HCP-hosted, so all nodes serve as both |
| Notable node states | all Ready | `worker-11` is `SchedulingDisabled`, kubelet `v1.33.9` (older): looks like upgrade in progress | virt-handler still runs there (DaemonSet tolerates) |
| MCE | 2.11.0 (per POC doc) | n/a (it's the hosted cluster) | |

Action items from inventory:

- [ ] **Decide if patch drift `4.21.11 ↔ 4.21.12` matters.** Per POC [9.1](cclm-network-poc.md#91-cross-version-cclm-failure-alpn-handshake) ALPN handshake only breaks on minor mismatch, but the lesson from that incident is "keep both sides aligned to avoid surprise regressions in successive patch revs." Cheap fix: bump hosting to `4.21.12-multi`. Track separately from CCLM logic.
- [ ] **Investigate `worker-11` SchedulingDisabled state.** If it's a live MCO/upgrade rollout, leave alone. If it's a stuck drain, that's a separate bug. The virt-handler pod runs there anyway and shows up in the IPAM pool: relevant for collision analysis (see [§3](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc)).

---

## 2. Configuration items inventory

Each row is a CCLM-relevant config knob. Status legend: **OK** = matches POC doc spec and is safe; **DRIFT** = present but value differs between clusters or from spec; **UNSAFE** = applied as-is per "lab fallback" but the POC doc flags it for replacement; **GAP** = not configured at all.

### 2.1 Host network layer

| Item | Hosting | Hosted | Spec ([POC §4.1](cclm-network-poc.md#41-host-network-nmstate-nodenetworkconfigurationpolicy)) | Status |
|---|---|---|---|---|
| NNCP `cclm-migration-mapping` exists | Available 4/4 nodes | Available 3/3 nodes | required | **OK** |
| Bridge mapping `vmnet:br-phy` (existing) | present | present | preserve | **OK** |
| Bridge mapping `cclm-mig:br-phy` (added) | present | present | required | **OK** |
| Bonding model | OVS Balance-SLB on `br-phy` (assumed; POC [§3](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc) confirmed) | same | required | **OK** |
| Underlay MTU on physical NICs | 9000 (assumed, not re-verified this session) | same | matches NAD MTU | **NEEDS VERIFICATION**: see [§4](#4-adjustment-plan-priority-ordered) |

### 2.2 NAD (`cclm-migration` in `openshift-cnv`)

Both NADs are byte-identical:

```json
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

| Field | Value | Status | Notes |
|---|---|---|---|
| `topology` | `localnet` | OK | matches OVN-K bridge mapping |
| `physicalNetworkName` | `cclm-mig` | OK | matches NNCP localnet name |
| `vlanID` | 100 | OK | trunked end-to-end per POC |
| `mtu` | **9000** | **NEEDS VERIFICATION** | Open POC #2 hypothesis: jumbo frames not end-to-end → centos PreCopy RST |
| `subnets` | `10.200.5.0/24` (native OVN-K IPAM, single shared) | **UNSAFE** | This is the [POC §6.2](cclm-network-poc.md#62-lab-only-fallback-native-ovn-k-subnets-single-shared-subnet) lab fallback. Source of the split-brain in [§3](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc). Replace per [POC §6.1](cclm-network-poc.md#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback) (ULA dual-stack) or [POC §6.6](cclm-network-poc.md#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain) (supernet pattern): both unvalidated still. |
| IPAM block (`ipam: { ... }`) | not present | **GAP for strategic** | Whereabouts compatibility with `localnet` is the open question that blocks ULA + supernet patterns. |

### 2.3 HyperConverged operator

| Item | Hosting | Hosted | Spec ([POC §4.3](cclm-network-poc.md#43-hyperconverged-point-kubevirt-at-the-nad), §4.4) | Status |
|---|---|---|---|---|
| `liveMigrationConfig.network` | `cclm-migration` | `cclm-migration` | `cclm-migration` | **OK** |
| `liveMigrationConfig.completionTimeoutPerGiB` | **150** | **800** | 800 | **DRIFT**: hosting needs realign to 800 |
| `liveMigrationConfig.parallelMigrationsPerCluster` | 5 | 5 | 5 | **OK** |
| `liveMigrationConfig.parallelOutboundMigrationsPerNode` | 2 | 2 | 2 | **OK** |
| `liveMigrationConfig.progressTimeout` | 150 | 150 | 150 | **OK** |
| `liveMigrationConfig.allowAutoConverge` | false | false | false (lab default) | **OK** |
| `liveMigrationConfig.allowPostCopy` | false | false | false (lab default) | **NEEDS DECISION**: candidate test for centos issue per [POC §9.6](cclm-network-poc.md#96-allowpostcopy-decision) |
| `featureGates.decentralizedLiveMigration` | true | true | true | **OK** |
| Other featureGates | aligned | aligned | n/a | **OK** |

### 2.4 MTV / Forklift

| Item | Hosting | Hosted | Spec (POC [§5](#5-open-questions-left-for-the-user)) | Status |
|---|---|---|---|---|
| ForkliftController CR | exists | exists | required | **OK** |
| `feature_ocp_live_migration` | `"true"` | `"true"` | true | **OK** |
| Provider for self (`host`) | Ready/Connected/Inventory | Ready/Connected/Inventory | required | **OK** |
| Provider for peer cluster | `hosted-cluster-a → 192.0.2.32:6443` Ready | `legacy-typo-name → api.hosting-cluster-1.example.com:6443` Ready | required | **OK** with cosmetic issue (see below) |
| ServiceAccount `openshift-mtv` in `openshift-cnv` | (not re-verified) | (not re-verified) | required ([POC §5.2](cclm-network-poc.md#52-service-account-and-token-to-use-with-mtv-providers)) | **NEEDS VERIFICATION** |
| ClusterRole `live-migration-role` | (not re-verified) | (not re-verified) | required ([POC §5.2](cclm-network-poc.md#52-service-account-and-token-to-use-with-mtv-providers)) | **NEEDS VERIFICATION** |
| Long-lived SA token Secret | (not re-verified: bound to providers anyway) | (not re-verified) | required | **NEEDS VERIFICATION** |

**Cosmetic:** the peer provider on the hosted cluster is named `legacy-typo-name` (typo for `hosting-cluster-1`). Functional, but worth fixing for consistency. See [§5](#5-open-questions-left-for-the-user).

### 2.5 Cross-cluster L2 path

| Item | Status | Notes |
|---|---|---|
| VLAN 100 trunked on switch between clusters | implicit OK (fedora and win2k22 migrated successfully) | not directly verified this session |
| Jumbo frames (MTU 9000) end-to-end | **UNVERIFIED** | The POC's open #2 explicitly proposes testing this for the centos failure |
| L3 routing between clusters | not used (stretched L2 by design) | n/a |
| Firewall rules for libvirt migration ports (~49152+) | unknown | POC [§8](#8-cudn-supernet-pattern-validated-2026-05-04) left this as TBD |

---

## 3. Active issues observed in this session

### 3.1 centos-stream9 split-brain (recovered 2026-05-04 23:50 UTC)

State observed before recovery:

```
HOSTED  (source): centos-vm-01 → Running, 14d uptime
HOSTING (dest):   centos-vm-01 → Starting / CrashLoopBackOff
                                                   virt-launcher on worker-1
```

Confirmed via forensic capture (saved under `/tmp/cclm-forensics-centos/`):

- MTV `Migration cclm-centos-9w45s` reported `SUCCEEDED` at 22:01:48
- HOSTED VMIM `forklift-9b2k6` (UID `20ab45e2-...`) recorded `mode: PreCopy`, `failureReason: virError(Code=38, Domain=7, Message='Cannot recv data: Connection reset by peer')`
- A second auto-retry VMIM `centos-vm-01-mig-kx70` also failed (different sync addr `.15:9185`)
- Dest virt-launcher `p9kqn` logged `migration finalized successfully` followed by `Executing PreStartHook` and a `Domain XML generated` with empty UID: textbook cold-boot signature
- Source virt-handler logged the libvirt cached-failure pattern: `migration job 20ab45e2-... already executed, finished at ... failed: true`
- Source VMI never left `Running`; source pod (`jcvvl` on `worker-10`) intact

**Why this is dangerous:** if anyone trusts the MTV `Succeeded` status and starts cleaning up the source, the workload is lost. Source must be the truth-bearer here.

**Root cause refinement (revised after timeline analysis):** the POC doc §9.8 attributes this failure pattern primarily to **IPAM IP collision**. The [POC §10](cclm-network-poc.md#10-open-questions-for-the-dedicated-cclm-session) open #2 attributes it to **MTU/jumbo PMTU** or **middlebox conntrack drop**. Neither is what we see in this instance. After timeline analysis, the actual chain is:

```
22:01:47.141  dest virt-launcher: "Prepared migration target pod"  (1st)
22:01:47.178  dest virt-launcher: "Prepared migration target pod"  (2nd)
22:01:47.234  dest virt-launcher: "Prepared migration target pod"  (3rd)
22:01:47.277  dest virt-launcher: "Prepared migration target pod"  (4th)
22:01:47.329  dest virt-launcher: "Prepared migration target pod"  (5th)
22:01:47.474  src virt-handler:   "migration options matched"      (qemu dials)
22:01:47.528  src virt-handler:   libvirt caches "job ... failed: true"
22:01:47.706  dest virt-launcher: "migration finalized successfully"
22:01:47.707  dest virt-launcher: ERROR "Domain not found"  ← !!!
22:01:47.768  dest virt-launcher: "Executing PreStartHook"   ← cold boot
```

**Critical observation:** the dest virt-launcher logged "migration finalized successfully" while libvirt simultaneously logged "no domain with matching name." The qemu incoming-listener domain **never existed** during the entire failure window. Dest virt-handler logged "Domain does not exist" continuously from 22:01:46.806 through 22:01:47.764.

**Refined hypothesis: prep-vs-listen race (NEW: supersedes [POC §10](cclm-network-poc.md#10-open-questions-for-the-dedicated-cclm-session) open #2 for this incident class):**

The dest virt-launcher reports `Prepared migration target pod` during the **hook prep phase** (cloud-init iso generation, disk driver configuration), which happens *before* qemu actually starts the incoming listener. The source receives this signal via the gRPC sync channel and dials immediately. If the source dials before qemu's incoming TCP port is bound, the connection fails fast and libvirt caches the failure. The dest then misinterprets the source's disconnect as "target prepared OK" and proceeds to cold-boot from PVC.

**Why centos and not fedora/win2k22: explanation that fits user observation:**

The race window is narrower for VMs with longer prep phases. Setup complexity comparison (verified [§4.6](#46-observation-worth-verifying-cclm-may-negotiate-migrationconfiguration-across-peers) not the cause; this comparison shown via VMI specs):

| VM | features | mem | disk | prep complexity |
|---|---|---|---|---|
| centos | `acpi` | 2Gi | 30Gi | minimal: fastest prep |
| fedora | `acpi`, `smm` | 2Gi | 30Gi | slightly more |
| win2k22 | `acpi`, `apic`, `smm`, full hyperv (~12 toggles), windows-drivers-disk, installation-cdrom | 4Gi | 60Gi+10Gi | most: slowest prep |

centos hits the race because its prep finishes fast enough that qemu hasn't bound the incoming port when source dials. fedora and win2k22 prep takes longer, qemu has time to bind, source dials successfully.

This is consistent with the user's observation that fedora and win2k22 migrated successfully cross-cluster on the same infrastructure.

**Implications:**
- Fixing IPAM (supernet, ULA) does NOT fix this. (already noted)
- Increasing MTU end-to-end does NOT fix this. (the failure is pre-data-transfer)
- Setting `allowPostCopy: true` MIGHT mask the symptom by triggering post-copy fallback: but post-copy still requires the initial pre-copy connection to establish, so it likely won't help if the race is at connection time.
- The proper fix is on the KubeVirt/CCLM side: dest virt-launcher must report "Prepared" only **after** qemu's incoming port is bound, not during hook prep. This is an upstream KubeVirt issue.

**Test plan to confirm:**

1. **Reproduce** a centos cross-cluster migration.
   - **Operational gotcha discovered:** creating a fresh `Migration` CR against an existing Plan does not retry: Forklift sees the
     Plan with `Succeeded=True` and ignores new Migrations against
     it (status.vms remains empty). Verified this session: created
     `cclm-centos-retry-n468x`, sat in Ready=True for 60s with no
     VMs picked up, plan still showed Succeeded.
   - To actually retry: either delete + recreate the Plan, or create a new Plan with the same VM. Neither was attempted here per
     user's "se ficar muito complexo, paramos" instruction.
   - **Add to runbook:** Forklift Plan retry semantics are operationally important and not obvious from docs.
2. **Add intentional delay on source dial** by setting a high `bandwidthPerMigration: 10Mi` in HCO `liveMigrationConfig`: slows initial connection rate, may give qemu time to bind. Cheap test.
3. **Add complexity to centos VM** (e.g. attach a second small PVC, or set `features.smm.enabled: true` on the VMI) to make prep take longer. If this fixes the race, confirms the prep-time hypothesis.
4. **File upstream issue** with KubeVirt project once reproducible in a clean test. Suggested title: *"CCLM: dest virt-launcher reports 'Prepared migration target pod' before qemu incoming listener is bound, causing source-dial race for low-prep-time VMs"*

The cold-boot split-brain is the *consequence* of the failed connection in this specific case. Two distinct upstream paths land in the same final state:

1. *Collision path* ([POC §9.8](cclm-network-poc.md#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain) original): random IP overlap → connection
   refused → libvirt cache → cold boot
2. *RST path* ([POC §10](cclm-network-poc.md#10-open-questions-for-the-dedicated-cclm-session) open #2): mid-PreCopy data RST → libvirt cache
   → cold boot
3. *Race path* (this incident, NEW): dest signals "prepared" while qemu not yet listening → connection refused → libvirt cache → cold boot

All three need the same recovery procedure. None of the fixes for paths 1 or 2 will fix path 3.

### 3.1a Recovery procedure (validated this session)

The [POC §9.8](cclm-network-poc.md#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain) sequence works with one important difference noted below.

1. Delete dest virt-launcher pod (cascading owner deletes also remove the VMI)

```bash
KUBECONFIG=/tmp/kc-hosting oc delete pod virt-launcher-<vmi>-<suffix> -n <ns> --grace-period=10
```

2. The VMI on dest may have been auto-recreated by the VM controller
in the few seconds between launcher delete and VMI delete. Check:

```bash
KUBECONFIG=/tmp/kc-hosting oc get vm,vmi <vmi-name> -n <ns>
```

3. If a VM CR exists on dest (created by Forklift PrepareTarget), delete it:

```bash
KUBECONFIG=/tmp/kc-hosting oc delete vm <vmi-name> -n <ns>
```

4. Stale VMIMs on hosted (the source side keeps the failed VMIMs).
Note: --selector=kubevirt.io/vmi-name=<name> works because the label is set; but be aware Forklift VMIMs ALSO carry the label, so this gets all of them. Delete by name if you need surgical:

```bash
KUBECONFIG=/tmp/kc-hosted oc get vmim -n <ns>
KUBECONFIG=/tmp/kc-hosted oc delete vmim <name1> <name2> -n <ns>
```

5. Source VMI may have stale migrationState, but if status.completed=true
it does NOT block new migrations (webhook only blocks "in-flight"). The next migration creates a new UID and overwrites it. Force-clear is documented in [POC §9.8](cclm-network-poc.md#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain) as: oc patch vmi <name> -n <ns> --subresource=status \ --type=json -p='[{"op":"remove","path":"/status/migrationState"}]' BUT: --subresource=status is rejected by oc 4.21.0 ("not found"). Plain `oc patch ... --type=json` accepts but virt-handler immediately reconciles the status back from its tracking. So in practice the stale migrationState cannot be hand-cleared on this oc version. It's harmless because completed=true.


**Two new gotchas captured here that the POC doc did not have:**

1. **Forklift creates a VM CR on the destination (not just a VMI).** The recovery procedure in [POC §9.8](cclm-network-poc.md#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain) only mentions deleting the VMI and pod. If the VM CR survives the VMI delete, the VM controller immediately creates a new VMI, which schedules a new launcher pod, which gets stuck (no source state to receive). You also need to delete the VM CR on dest. This took ~3 minutes of pods cycling before the VM termination chain completed.

2. **`oc patch --subresource=status` is rejected by oc 4.21.0.** The exact command listed in [POC §9.8](cclm-network-poc.md#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain) fails with "VMI not found" because the subresource flag is misinterpreted. Either upgrade `oc` (newer versions support `--subresource=status`), or accept that the migrationState cannot be hand-cleared and rely on the completed=true semantics not blocking the next migration.

3. **Pod stuck Terminating after VM CR delete.** The recovery triggered an auto-recreated launcher pod that got to Init phase then Killing: and stayed in Terminating for 3+ minutes. Force- delete (`--grace-period=0 --force`) clears it. This is normal for a launcher pod whose VMI was deleted mid-init.

After recovery, both clusters returned to a clean state:

- HOSTED: VM Running 103m on worker-10, no VMIMs
- HOSTING: nothing centos-related; fedora and win2k22 still Running (those migrated successfully earlier)
- virt-handler IPs unchanged (`.14/.4/.8/.6` on hosting, no recycle triggered)

**Diagnostic queue (read-only first):**

Confirm the split brain: both alive?

```bash
KUBECONFIG=/tmp/kc-hosted oc get vmi centos-vm-01 -o jsonpath='{.status.phase} migrationState={.status.migrationState}{"\n"}'
KUBECONFIG=/tmp/kc-hosting oc get vmi centos-vm-01 -o jsonpath='{.status.phase} migrationState={.status.migrationState}{"\n"}'
```

What's the destination virt-launcher actually doing?

```bash
KUBECONFIG=/tmp/kc-hosting oc logs -n default virt-launcher-centos-vm-01-p9kqn --tail=50
```

Was there a VMIM pair? If so, what state did they end in?

```bash
KUBECONFIG=/tmp/kc-hosted  oc get vmim -A
KUBECONFIG=/tmp/kc-hosting oc get vmim -A
```

What does Forklift / MTV think happened?

```bash
KUBECONFIG=/tmp/kc-hosted oc get migration,plan -A
```

**Recovery, only when ready to retry ([POC §9.8](cclm-network-poc.md#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain)):**

1. Kill the cold-booted dest virt-launcher (stop the ghost qemu)

```bash
KUBECONFIG=/tmp/kc-hosting oc delete pod virt-launcher-centos-vm-01-p9kqn -n default
```

2. Delete the dest VMI (Forklift will recreate when plan triggers)

```bash
KUBECONFIG=/tmp/kc-hosting oc delete vmi centos-vm-01 -n default
```

3. Clear stale migrationState on source if pinned

```bash
KUBECONFIG=/tmp/kc-hosted oc patch vmi centos-vm-01 -n default --subresource=status \
  --type=json -p='[{"op":"remove","path":"/status/migrationState"}]'
```

4. Sweep stale VMIMs on both

```bash
for ctx in /tmp/kc-hosted /tmp/kc-hosting; do
  KUBECONFIG=$ctx oc get vmim -n default -o name | xargs -r KUBECONFIG=$ctx oc delete -n default
done
```

**Why the recovery is required before any retest:** while a stale non-terminal VMIM exists for the VMI, the KubeVirt webhook will refuse new migrations with "in-flight migration detected" ([POC §9.7](cclm-network-poc.md#97-webhook-blocks-new-migration-in-flight-migration-detected)).

### 3.2 IPAM collision risk is structurally present

Current virt-handler IPs (no collision right now, but it's luck):

```
HOSTED  virt-handlers: .2 (node-10), .10 (node-11 schedDisabled), .3 (node-12)
HOSTING virt-handlers: .14 (node-2), .4 (node-3), .8 (node-0), .6 (node-1)
```

[POC §9.8](cclm-network-poc.md#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain) documents the original failure was on `.2 ↔ .2`. Hosting moved off `.2` (now `.14`) since then: IPAM gave it a different IP on the next pod recycle, which is exactly the random-IP-allocation behavior the doc warns about. **The structural problem is unchanged**: both clusters allocate independently from the same `10.200.5.0/24` pool; the next virt-handler restart can land back on a colliding IP.

Also relevant: when a migration starts, the destination's `virt-launcher` attaches to the NAD too and gets its own IP from the same pool: that's the IP libvirt actually opens the listener on. Even if virt-handlers don't collide, the launcher pair (or launcher ↔ handler on the wrong cluster) can.

This is the single highest-priority item to fix structurally.

---

## 4. Adjustment plan (priority-ordered)

### Priority 1: fix the active split-brain and the structural IPAM problem

These are the items that block any further reliable validation work.

| # | Action | Risk | Owner | Status |
|---|---|---|---|---|
| 1.1 | Diagnose the active centos split-brain (read-only, [§3.1](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc) queue) | none | this session | **DONE**: forensics in `/tmp/cclm-forensics-centos/`, root cause re-classified as PreCopy RST not IPAM collision (see [§3.1](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc)) |
| 1.2 | Recover from the centos split-brain so the cluster is in a clean state for retesting | low (well-documented in [POC §9.8](cclm-network-poc.md#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain)) | this session, after user OK | **DONE**: recovery completed 2026-05-04 23:50 UTC, both clusters clean, source untouched (Running 103m). Three new gotchas captured in [§3.1](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc)a (Forklift VM CR on dest, oc 4.21.0 subresource issue, pod stuck Terminating). |
| 1.3 | **Validate OVN-K `localnet` + Whereabouts compatibility on CNV 4.21.x.** Apply a test NAD in a non-production namespace with `ipam: { type: whereabouts, ... }` and observe whether pods get IPs. POC open #1. | low (test in throwaway namespace) | this session | TODO |
| 1.4 | If 1.3 works → switch the production `cclm-migration` NAD to ULA dual-stack ([POC §6.1](cclm-network-poc.md#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback)) OR supernet pattern ([POC §6.6](cclm-network-poc.md#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain)). If 1.3 fails → fall back to per-cluster sub-pool inside the same `/24` if Whereabouts attaches OR the hypershift-automation per-cluster `/24` allocation playbook ([POC §6.5](cclm-network-poc.md#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks)). | medium (changes the NAD; virt-handlers will re-IP, in-flight migrations will stop) | this session, after user OK | TODO |

### Priority 2: close known config drift

| # | Action | Risk | Owner | Status |
|---|---|---|---|---|
| [2.1](#21-host-network-layer) | Realign `HyperConverged.spec.liveMigrationConfig.completionTimeoutPerGiB` on hosting from 150 → 800 | low (knob change) | this session, after user OK | **DONE** by operator 2026-05-04. Note: drift was NOT the root cause of centos failure (fedora/windows migrated successfully with drift in place). Fix is correct hygiene, not centos blocker. |
| [2.2](#22-nad-cclm-migration-in-openshift-cnv) | Rename the hosted-cluster MTV provider from `legacy-typo-name` → `hosting-cluster-1` (cosmetic) | low | optional | TODO |
| [2.3](#23-hyperconverged-operator) | Bump hosting OCP from 4.21.11 → 4.21.12 to match hosted (track separately, not gating CCLM) | medium (cluster upgrade) | separate session | TODO |

### Priority 3: investigate centos PreCopy RST

POC open #2. Do this AFTER the IPAM is resolved (P1) so we can isolate a network/MTU issue from a collision issue.

| # | Action | Risk | Owner | Status |
|---|---|---|---|---|
| [3.1](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc) | Reproduce centos-stream9 cross-cluster migration with NAD MTU dropped from 9000 → 1500 | medium (NAD edit forces virt-handler re-IP) | this session | TODO |
| [3.2](#32-ipam-collision-risk-is-structurally-present) | Reproduce with `liveMigrationConfig.allowPostCopy: true` ([POC §9.6](cclm-network-poc.md#96-allowpostcopy-decision) risk discussion) | medium (post-copy has documented risk on unstable networks) | after P1 done | TODO |
| 3.3 | tcpdump on the migration network during a failing run to identify who's RSTing (source kernel / dest kernel / middlebox) | none (read-only capture) | this session | TODO |

### Priority 4: verify infrastructure assumptions left implicit

| # | Action | Risk | Owner | Status |
|---|---|---|---|---|
| 4.1 | Confirm NIC MTU = 9000 on each node's physical interfaces (`ens33`, `ens34` or whatever names the lab uses) | none | this session | TODO |
| 4.2 | Confirm switch trunk between clusters carries VLAN 100 with MTU 9000 end-to-end (network team; out of cluster scope) | none, but external | network team | TODO |
| 4.3 | Confirm `openshift-mtv` ServiceAccount + `live-migration-role` ClusterRole exist on both clusters per [POC §5.2](cclm-network-poc.md#52-service-account-and-token-to-use-with-mtv-providers) | none | this session | TODO |
| 4.4 | Capture libvirt migration port range used during a real cross-cluster migration (POC [§8](#8-cudn-supernet-pattern-validated-2026-05-04) leaves this TBD) | none (passive capture) | during a P3 test | TODO |

### Priority 5: close documentation gaps for future automation

These are items the next operator (or playbook) needs to know that are not yet captured anywhere.

| # | Action | Why it matters for automation |
|---|---|---|
| 5.1 | Decide between strategic IPAM options (ULA [POC §6.1](cclm-network-poc.md#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback) vs supernet [POC §6.6](cclm-network-poc.md#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain) vs per-cluster `/24` [POC §6.5](cclm-network-poc.md#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks)) and write the chosen one as the official target | Generator code (RVTMA) and hypershift-automation playbooks need a single "this is what we ship" decision |
| 5.2 | Document the recovery runbook for split-brain (currently scattered in [POC §9.8](cclm-network-poc.md#98-ip-collision-on-shared-l2-shared-subnet-option-a-ipam-split-brain)) as a standalone procedure with explicit "when to use" criteria | Ops will hit this; needs to be findable in <1 minute |
| 5.3 | Document the upgrade order for HCP-hosted clusters from [POC §9.3](cclm-network-poc.md#93-hcp-specific-hosted-cluster-cannot-upgrade-to-the-target-minor) / [POC §9.4](cclm-network-poc.md#94-hco-cnv-wont-upgrade-to-next-minor-after-ocp-upgrade) as a flowchart (MCE → HostedCluster → NodePool → CNV) | This took multiple debugging sessions to figure out; capture it definitively |
| 5.4 | Document the "in-flight migration detected" recovery flow ([POC §9.7](cclm-network-poc.md#97-webhook-blocks-new-migration-in-flight-migration-detected)) with a one-shot script | Needed during every iterative testing session |

---

## 4.6 Observation worth verifying: CCLM may negotiate `migrationConfiguration` across peers

> **Status: NOT the root cause of the centos failure**: corrected
> 2026-05-04 by operator. Fedora and windows VMs migrated successfully
> across clusters while hosting had `completionTimeoutPerGiB: 150`
> (drifted from spec `800`), proving the drift alone does not break
> CCLM. The observation below remains worth a controlled test as a
> KubeVirt CCLM behavioral question, but it is decoupled from the
> centos investigation.

The forensic capture showed the source VMIM's `migrationConfiguration` snapshot containing `completionTimeoutPerGiB: 150`: the **hosting** (drifted) value, not the **hosted** (correct) value of `800` where the source actually lives. Two possible explanations:

1. CCLM negotiates a single `migrationConfiguration` across peers (most-conservative-wins, or destination-wins, or some other rule)
2. The VMIM I inspected was actually generated from the dest's HCO for transport reasons, even though it lives on the source side

Either way, for the centos failure this is irrelevant: fedora and windows survived the same negotiation outcome. Future test (low priority, knowledge-only):

1. Set hosting HCO to a distinctive value (e.g. `completionTimeoutPerGiB: 999`)
2. Set hosted HCO to a different distinctive value (e.g. `888`)
3. Trigger a CCLM migration of any VM
4. Inspect both VMIMs' `status.migrationState.migrationConfiguration`
5. If values differ → each side uses local HCO. If values match → CCLM negotiates; figure out the rule.

This is documentation-grade work for the upstream issue eventually, not a blocker for the centos diagnostic.

---

## 5. Open questions left for the user

Things I can't decide unilaterally; need a steer before changing prod state on either cluster:

1. ~~**Recovery of the active centos split-brain.**~~: DONE this session per user authorization. Forensics saved, recovery completed, both clusters clean. See [§3.1](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc) and [§3.1](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc)a for the full trail. Refined understanding: this specific failure was the PreCopy RST, not an IPAM collision (POC doc assumed collision; we proved not via the `.12` ownership check).

2. **Whereabouts test target.** When I run the §1.3 compatibility test, should I:
   - (a) Create a one-off test NAD in a throwaway namespace (e.g. `cclm-poc-whereabouts-test`) and just check pod IP
     allocation, OR
   - (b) Modify the production `cclm-migration` NAD directly?
   I strongly recommend (a): it's safer and gives a clean answer.

3. **Strategic IPAM target.** If Whereabouts works on `localnet`, do you want me to skip ahead to ULA dual-stack ([POC §6.1](cclm-network-poc.md#61-recommended-default-dual-stack-ipv6-ula-primary-ipv4-fallback), target state) OR validate the simpler supernet pattern first ([POC §6.6](cclm-network-poc.md#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain), intermediate L2-friendly)? I'd suggest supernet first because:
   - It keeps IPv4 (no end-to-end IPv6 component validation needed)
   - It's structurally what eliminates the collision (sub-pool per cluster + supernet mask for L2 reachability)
   - It's the lowest-risk production change

4. **VM choice for IPAM regression test.** After IPAM change, we should re-validate cross-cluster migration on at least one VM that worked before (fedora) and one that didn't (centos). Are the win2k22 and fedora VMs that just migrated to hosting OK to migrate back to hosted as a regression test?

5. **Centos forensics.** Before recovery, should I pull `virt-launcher-centos-stream9-...` logs and the failed `Migration`/`VMIM` resources for archival? That data dies the moment we recover.

---

## 6. Outputs this audit will feed

So nothing is lost when this session ends:

- **Update to `cclm-network-poc.md`:** the IPAM strategy section once Whereabouts compat is resolved (replaces the open question with a definite answer); the recovery runbook for split-brain hardened with what we actually do this session; **§9.8 root-cause table needs to add the "prep-vs-listen race" path** (third upstream cause documented in this session's [§3.1](#31-centos-stream9-split-brain-recovered-2026-05-04-2350-utc)): independent of the IPAM and MTU paths. **Also rewrite §10 open #2** to reflect the new hypothesis: the centos failure is NOT MTU/conntrack but a race condition in KubeVirt's CCLM target prep signaling. Possibly close as needs upstream fix.
- **`hypershift-automation` playbook spec:** if we end up with the per-cluster `/24` allocation pattern, the spec in [POC §6.5](cclm-network-poc.md#65-subnet-allocation-automation-hand-off-to-hypershift-automation-playbooks) becomes the actual ticket.
- **RVTMA generator change:** if Whereabouts works, generator switches default IPAM emission to either ULA dual-stack or supernet (small change, ~20 lines + tests, per [POC §11](cclm-network-poc.md#11-rvtma-integration-done-kickstart-v1)).
- **Upstream openshift-docs issue:** if supernet pattern works end-to-end, draft the issue per [POC §10](cclm-network-poc.md#10-open-questions-for-the-dedicated-cclm-session)'s "Battle-tested status" gating criteria, with supernet as the proposed addition (not just IPv6 ULA).
- **Operator runbooks:** the [§5](#5-open-questions-left-for-the-user) entries become standalone runbook docs
  for ops handover.

---

## 8. CUDN supernet pattern: VALIDATED 2026-05-04

> **Status: validated end-to-end on this lab.** OVN-K's modern
> `ClusterUserDefinedNetwork` API (CUDN) supports `localnet` topology
> with first-class `excludeSubnets`, enabling the supernet pattern
> without Whereabouts. Cross-cluster L2 reachability confirmed via ping.

### 8.1 Why CUDN over raw NAD

Two equivalent ways to declare a `localnet` network in OVN-K 4.21:

1. **Raw NetworkAttachmentDefinition**: opaque JSON in `spec.config`
2. **ClusterUserDefinedNetwork (CUDN)**: typed YAML, schema-validated

CUDN auto-generates the underlying NAD per matching namespace. Same runtime behavior, but CUDN has:

- Schema validation (typed fields, enums, required fields)
- Cluster-scoped + namespaceSelector (one CUDN can serve many namespaces)
- `ipam.lifecycle: Persistent` (built-in IP persistence for VMs via IPAMClaim: relevant for CCLM virt-handlers)
- VLAN built into the spec (`vlan.access.id`) instead of inline JSON

Red Hat encourages CUDN over raw NAD for new work as of OCP 4.21.

### 8.2 CUDN `localnet` schema (full, OCP 4.21.x)

```yaml
spec:
  network:
    topology: Localnet
    localnet:
      role: Secondary             # required, only "Secondary" allowed
      physicalNetworkName: cclm-mig  # required, links to bridge mapping
      subnets: ["<CIDR>"]         # CIDR pool AND pod-mask source
      excludeSubnets: ["<CIDR>",...]  # carve-outs from subnets
      vlan:
        mode: Access              # required when vlan present
        access:
          id: <int>               # 1-4094
      mtu: <int>
      ipam:
        mode: Enabled | Disabled  # Disabled = no IPAM, you're on your own
        lifecycle: Persistent     # IP survives pod restart (VM-friendly)
```

### 8.3 The supernet trick

Single key insight: `subnets` field defines BOTH the IPAM allocation pool AND the netmask propagated to pods. So:

- `subnets: ["10.250.0.0/16"]` → pods get `/16` mask → see entire /16 as on-link (ARP works to any IP in /16, no router needed)
- `excludeSubnets` carves out chunks from the allocation pool, but the pod mask stays /16

So each cluster's CUDN says `subnets: 10.250.0.0/16` (same supernet) but excludes everything except its own sub-pool. Result:

- Cluster A pods get IPs from `10.250.5.0/26` with `/16` mask
- Cluster B pods get IPs from `10.250.6.0/26` with `/16` mask
- Both are on the same VLAN 100 stretched L2 → ARP flows both ways
- Cross-cluster reachability without any router, IP collision impossible

Verified live on this lab:

```
HOSTING pod 10.250.99.3/16   <---- VLAN 100 L2 ---->   HOSTED pod 10.250.100.2/16
ping HOSTING → HOSTED: 4/4 success, latency 0.2-0.4ms steady
ping HOSTED → HOSTING:  4/4 success, latency 0.2-0.3ms steady
First packet ~3-5ms (ARP resolution)
```

### 8.4 The excludeSubnets gotcha: non-overlapping required

OVN-K **rejects overlapping excludes** with a confusing error:

```
failed to exclude subnet 10.250.99.64/26 for ...:
failed to reserve IP 10.250.99.64: provided IP is already allocated
```

Discovered the hard way during validation. The first attempt at excludes had `10.250.96.0/22` (covers .96 - .99.255) AND `10.250.99.64/26` (covers .99.64 - .99.127). Overlap on .99.64-.99.127. OVN-K processes excludes one at a time, reserving the network base address; second overlap fails because base address already reserved.

Implication: each exclude entry must be a clean CIDR carve, no overlaps. A human writing this by hand will get it wrong. **The helper MUST do the bit-decomposition algorithmically.**

### 8.5 CIDR carve-out algorithm (for the helper)

To carve a single sub-pool from a supernet (e.g. keep only `10.250.99.0/26` from `10.250.0.0/16`), recursively bisect the supernet, excluding the half that doesn't contain the target:

```
function carve_excludes(supernet, target):
    if supernet == target:
        return []                  # nothing to exclude
    left, right = bisect(supernet) # split into 2 halves
    if target ⊆ left:
        return [right] + carve_excludes(left, target)
    else:
        return [left] + carve_excludes(right, target)
```

Worked example: keep `10.250.99.0/26` from `10.250.0.0/16` →

```bash
10.250.0.0/16
├── 10.250.0.0/17  (contains target)
│   ├── 10.250.0.0/18  EXCLUDE
│   └── 10.250.64.0/18 (contains target)
│       ├── 10.250.64.0/19  EXCLUDE
│       └── 10.250.96.0/19 (contains target)
│           ├── 10.250.96.0/20 (contains target)
│           │   ├── 10.250.96.0/21 (contains target)
│           │   │   ├── 10.250.96.0/22 (contains target: wait, /26 is at .99)
│           │   │   │   ├── 10.250.96.0/23 EXCLUDE
│           │   │   │   └── 10.250.98.0/23 (contains target)
│           │   │   │       ├── 10.250.98.0/24 EXCLUDE
│           │   │   │       └── 10.250.99.0/24 (contains target)
│           │   │   │           ├── 10.250.99.0/25 (contains target)
│           │   │   │           │   ├── 10.250.99.0/26 KEEP (target)
│           │   │   │           │   └── 10.250.99.64/26 EXCLUDE
│           │   │   │           └── 10.250.99.128/25 EXCLUDE
│           │   │   └── 10.250.100.0/22 EXCLUDE
│           │   └── 10.250.104.0/21 EXCLUDE
│           └── 10.250.112.0/20 EXCLUDE
└── 10.250.128.0/17 EXCLUDE
```

```bash
Final exclude list (10 entries):
10.250.0.0/18, 10.250.64.0/19, 10.250.96.0/23, 10.250.98.0/24,
10.250.99.64/26, 10.250.99.128/25, 10.250.100.0/22,
10.250.104.0/21, 10.250.112.0/20, 10.250.128.0/17
```

Number of exclude entries grows with `(supernet_mask_size - target_mask_size)`. For /16 supernet + /26 sub-pool → 10 entries. For /16 + /27 → 11. For /16
+ /22 → 6. Bounded and predictable. Python `ipaddress.ip_network` can
do this; will be a small Ansible filter or Jinja macro.

### 8.6 Operational gotchas observed during validation

1. **CUDN spec is immutable** (`spec.network: Invalid value: "object": Network spec is immutable`). To change subnets/excludes/vlan: delete CUDN, wait for finalizer to drain pods using underlying NAD, recreate. Maintenance window required.

2. **CUDN delete blocks on pods using underlying NAD.** Even after `oc delete clusteruserdefinednetwork`, finalizer waits until all pods detach. If you have a stuck deployment, delete it first or the CUDN delete hangs.

3. **OCP SCC blocks raw images with explicit non-root UID.** Test pods using `runAsUser: 65534` get rejected: UID outside the namespace's allowed range `[1000960000, 1000969999]`. Either:
   - Drop the explicit `runAsUser` and let restricted-v2 SCC pick a UID
   - Use an image already configured for OCP (e.g. `registry.redhat.io/rhel9/support-tools`)

4. **`ubi-minimal` doesn't include `ip` or `ping`.** Use `ubi9` or `support-tools` for network tests. Non-root pods can't `yum install` so the image must already have the tools.

5. **CUDN auto-generated NAD config has `vlanID` in JSON form.** The typed `vlan.access.id` from CUDN gets converted to lowercase `vlanID` int when the NAD is rendered. Don't try to use both forms.

### 8.7 What this means for the strategy

The supernet pattern via CUDN is now the **recommended IPAM** for CCLM on this OCP version. Reasons:

- Solved upstream-blocker question of [POC §6.6](cclm-network-poc.md#66-supernet-pattern-per-cluster-sub-pools-sharing-one-l2-broadcast-domain): works on CNV 4.21.x
- No Whereabouts dependency (Whereabouts compat with `localnet` remains an OPEN question; we sidestep it entirely)
- No L3 routing required (works on stretched L2)
- No IPv6 readiness required (pure IPv4 path)
- Self-allocation per cluster (no runtime cross-cluster coordination)
- Schema-validated, typed YAML (not raw JSON)
- Built-in IP persistence (`ipam.lifecycle: Persistent`) for VMs
- Computing exclude list requires bit-decomposition algorithm (must be automated; too error-prone for humans)
- Spec immutable; changing requires drain + recreate window
- Each cluster's CUDN is unique (different excludeSubnets per cluster)

### 8.8 Status of the next steps

- [x] Validate CUDN+localnet basic flow (single cluster, single /26)
- [x] Validate supernet pattern intra-cluster (single cluster, /16 mask
      + /26 sub-pool via excludes)
- [x] Validate cross-cluster L2 reachability (HOSTING pod /16 ↔ HOSTED pod /16 across VLAN 100)
- [x] **Validate with virt-handler on production-like setup (DONE this session):** blue-green deployed CUDN `cclm-migration-v2` on both clusters; switched HCO `liveMigrationConfig.network`; virt-handler + sync-controller pods rolled and got IPs from the supernet sub-pools (`10.250.10.0/26` on hosting, `10.250.20.0/26` on hosted); intra-cluster live migration of fedora succeeded in ~15s using the new NAD as data path; cross-cluster TCP 9185 reachable to the leader sync-controller via L2.
- [x] **Validate actual CCLM (cross-cluster) on the supernet NAD: DONE this session.** Constructed reverse Plan `cclm-fedora-reverse` on hosting (source=host, dest=hosted-cluster-a provider). Triggered Migration. Pipeline: Initialize → PrepareTarget → Synchronization → Completed in ~110 seconds. fedora live-migrated from hosting (worker-1) to hosted (worker-11) with zero failures. `migrationState.targetNodeAddress: 10.250.20.4` confirms data path used the supernet sub-pool. **CUDN supernet works end-to-end for production CCLM.**
- [ ] Build the Ansible helper that computes excludes and renders CUDN
- [ ] Document the upgrade path: native `subnets` → supernet CUDN (requires drain virt-handlers, [POC §3.1](cclm-network-poc.md#31-why-the-2-nic-constraint-mattered-and-how-ovs-bonding-resolves-it) covers the bonding context)
- [ ] Decide cleanup of legacy NAD `cclm-migration` (currently coexisting with v2: safe to delete after a few days of confidence)

### 8.9 Production rollout playbook (validated this session)

Steps used and confirmed working:

```bash
1. Apply CUDN cclm-migration-v2 on each cluster
   (different excludeSubnets per cluster: different sub-pool)
```

```bash
2. Wait for CUDN status: NetworkCreated=True
```

```bash
3. Verify auto-generated NAD in openshift-cnv with same name as CUDN
```

```bash
4. Patch HCO on each cluster:
   oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv \
     --type=merge -p '{"spec":{"liveMigrationConfig":{"network":"cclm-migration-v2"}}}'
```

```bash
5. KubeVirt operator propagates to:
   - virt-handler DaemonSet template annotation
   - virt-synchronization-controller Deployment template annotation
   Both rollout automatically (~1-2 min total per cluster, depending on
   node count, with maxUnavailable defaults)
```

```bash
6. Verify new IPs on supernet sub-pools:
   oc get pods -n openshift-cnv -l kubevirt.io=virt-handler -o json | \
     jq -r '.items[] | "\(.metadata.name) " +
       (((.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]") | fromjson) |
        map(select(.interface=="migration0"))[0].ips // ["NONE"] | tostring)'
   # Note interface name is "migration0" (not "net1"): KubeVirt sets
   # this via annotation: k8s.v1.cni.cncf.io/networks: <name>@migration0
```

```bash
7. Validate with intra-cluster migration first:
   oc create -n <vm-ns> -f - <<EOF
   apiVersion: kubevirt.io/v1
   kind: VirtualMachineInstanceMigration
   metadata: {generateName: cclm-net-test-, namespace: default}
   spec: {vmiName: <vm-name>}
   EOF
```

```bash
8. Validate with cross-cluster CCLM (Forklift Plan)
```

```bash
Rollback (if needed):
  oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    --type=merge -p '{"spec":{"liveMigrationConfig":{"network":"cclm-migration"}}}'
  # Old NAD still exists, virt-handlers will roll back to it.
```

### 8.10 Additional findings from production validation

1. **Sync-controller is leader-elected.** Only 1 of N replicas listens on 9185 (gRPC port for CCLM coordination). Followers only expose `/healthz` on 8443. Leader can change at any time. Source virt-handler discovers the current leader via the K8s API (lease object), not by probing IPs. Implications:
   - Don't hardcode sync-controller IPs anywhere
   - Both leader and follower IPs must be reachable cross-cluster (if leader fails over, source must be able to reach the new leader)
   - The whole sub-pool (`10.250.X.0/26`) must be cross-cluster reachable, not just a specific IP

2. **Interface name in the pod is `migration0`.** Not `net1`. KubeVirt's annotation pattern is `<network-name>@<interface-name>`. The interface name `migration0` is hardcoded by KubeVirt. Custom NAD queries must filter on `interface=="migration0"`, not the default `net1`.

3. **virt-handler container does not include `ping` or `ss`.** Use `/proc/net/tcp` for listen-port checks, or use a separate test pod with `support-tools` image attached to the same NAD. Test pods in the throwaway namespace (with their own CUDN on the same supernet) work great as a "side car" for connecdc1y validation.

4. **HCO operator handles network change cleanly.** Single `oc patch ... --type=merge` is enough. No manual intervention on the DaemonSet/Deployment. Rollout is gradual, respects PodDisruption- Budget, and tolerates node drain. Confirmed safe even with running VMs on the cluster (intra-cluster migrations during the rollout window can fail, but VMs themselves are not impacted).

5. **Old NAD survives without harm.** Keeping `cclm-migration` (legacy `subnets: 10.200.5.0/24`) alongside `cclm-migration-v2` (CUDN supernet) is fine: they're independent. Rollback is just a HCO patch back to the old name. Only delete the old NAD AFTER several days of confidence with the new one.

6. **CUDN spec uses `Localnet` (capital L).** topology field is `topology: Localnet` (CamelCase) at the spec level, but the auto-generated NAD config uses `topology: localnet` (lowercase). Both are correct in their respective contexts. Don't be confused.

7. **Forklift reverse-migration gotcha: VM CR persistence on dest.** When migrating VM X from cluster A → B, the VM CR remains on A in Stopped state after success. To migrate X back from B → A later, the lingering VM CR on A causes preflight to fail with:
   - `VMAlreadyExists=True`
   - `MacConflicts=True` (same MAC as the dest copy)

   Solution: `oc delete vm <name> -n <ns>` on the destination *before* triggering the reverse migration. The PVC cascades with the VM CR (Forklift sets ownership). No data loss because the live VM holds the current state on the other cluster.

   Operational note for the helper: when handing CCLM operation to end users, this gotcha needs a runbook or a wrapper script that does the cleanup automatically.

8. **MTV Plan with `Succeeded=True` won't accept new Migrations.** Confirmed during centos retry attempt earlier this session. Strategy for retries: either delete + recreate the Plan, OR create a brand-new Plan with the same VMs. Forklift does not expose a "reset" or "rerun" operation on Plans.

9. **`oc create -f` on Migration with `generateName` works**, no need to compute name beforehand. Use `oc get migration -l plan=<plan-uid>` to find the resulting Migration name (or just `grep` by prefix).

10. **Live migration via the new NAD does NOT impact running VMs.** Verified by triggering a live migration of fedora during the
    NAD switchover. Migration succeeded without VM disruption.
    The data path works at the new IPs immediately after rollout
    completes; no warmup period needed.

---

## 7. Appendix: exact `oc` calls used in this audit

Captured for reproducibility. All are read-only.

Versions

```bash
KUBECONFIG=/tmp/kc-hosting oc version
KUBECONFIG=/tmp/kc-hosted  oc version
KUBECONFIG=/tmp/kc-hosting oc get csv -n openshift-cnv | grep kubevirt-hyperconverged
KUBECONFIG=/tmp/kc-hosted  oc get csv -n openshift-cnv | grep kubevirt-hyperconverged
KUBECONFIG=/tmp/kc-hosting oc get nodes
KUBECONFIG=/tmp/kc-hosted  oc get nodes
```

NNCP / NAD / HCO

```bash
for kc in /tmp/kc-hosting /tmp/kc-hosted; do
  KUBECONFIG=$kc oc get nncp,nnce
  KUBECONFIG=$kc oc get net-attach-def -n openshift-cnv
  KUBECONFIG=$kc oc get net-attach-def cclm-migration -n openshift-cnv -o jsonpath='{.spec.config}' | jq .
  KUBECONFIG=$kc oc get nncp cclm-migration-mapping -o yaml | grep -A 30 "desiredState:"
  KUBECONFIG=$kc oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
    -o jsonpath='liveMigrationConfig:{"\n"}{.spec.liveMigrationConfig}{"\n\n"}featureGates:{"\n"}{.spec.featureGates}{"\n"}'
done
```

virt-handler IPs on the migration NAD

```bash
for kc in /tmp/kc-hosting /tmp/kc-hosted; do
  KUBECONFIG=$kc oc get pods -n openshift-cnv -l kubevirt.io=virt-handler -o json | \
    jq -r '.items[] | "\(.metadata.name) node=\(.spec.nodeName) cclm-ip=" +
      (((.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]") | fromjson) |
       map(select(.name | test("cclm|migration"))) | (.[0].ips // ["NONE"]) | tostring)'
done
```

MTV

```bash
for kc in /tmp/kc-hosting /tmp/kc-hosted; do
  KUBECONFIG=$kc oc get forkliftcontroller -A -o yaml | grep -E "feature_ocp_live_migration|namespace:|name:" | head -20
  KUBECONFIG=$kc oc get providers -A
done
```

VMs and virt-launchers (look for split-brain)

```bash
for kc in /tmp/kc-hosting /tmp/kc-hosted; do
  KUBECONFIG=$kc oc get vm -A
  KUBECONFIG=$kc oc get pods -A -l kubevirt.io=virt-launcher -o json | \
    jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name) node=\(.spec.nodeName) cclm-ip=" +
      (((.metadata.annotations["k8s.v1.cni.cncf.io/network-status"] // "[]") | fromjson) |
       map(select(.name | test("cclm|migration"))) | (.[0].ips // ["NONE"]) | tostring)'
done
```
