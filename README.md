# Cross-Cluster Live Migration (CCLM) reference for OpenShift Virtualization

This is the operator-side reference for live-migrating KubeVirt VMs **between** OCP clusters: the GA feature in OCP 4.21 that the docs sometimes call "decentralized live migration", and the rest of us call "vMotion across vCenters but with five extra moving parts".

What you get here:

- The minimum config to make CCLM actually work end-to-end (NNCP, CUDN, HCO patch, MTV feature gate)
- An IPAM helper that hands out non-overlapping `/26` sub-pools from a `/16` supernet so the OVN-K `ClusterUserDefinedNetwork` doesn't trip over duplicate addresses
- The full POC writeup with everything that did and didn't work along the way (read it once, never again, hopefully)
- Pointers to the Ansible automation that wraps all of this on the [`hypershift-automation`](https://github.com/Hypershift-Automation/hypershift-automation) side

**Validated on:** OCP 4.21 / OpenShift Virtualization 4.21 / MTV (Forklift) 2.11. Stretched-L2 across two clusters. Fedora, Windows, and CentOS guests migrated cross-cluster successfully.

## What's in this repo

| File | Read it for |
|------|-------------|
| [`cclm-kcs.md`](cclm-kcs.md) | The shortest path from "nothing" to "CCLM works". KCS-style: Issue / Environment / Resolution / Verification / Troubleshooting. Start here if you just want to configure CCLM and move on. |
| [`cclm-howto.md`](cclm-howto.md) | The same content as the KCS but with the "why". Useful when something doesn't work and the KCS table doesn't help. |
| [`cclm-network-poc.md`](cclm-network-poc.md) | The original POC: alternatives considered, debug trail, every dead end. Long. Reference material, not a tutorial. |
| [`cclm-config-audit.md`](cclm-config-audit.md) | Snapshot of two lab clusters' actual config with the gotchas marked, plus the adjustment plan. Useful as a checklist when auditing your own clusters. |
| [`cclm-pool-planning.md`](cclm-pool-planning.md) | How to size the migration supernet, the per-cluster sub-pool, and the state ConfigMap. |
| [`cclm-helper-guide.md`](cclm-helper-guide.md) | Every `cclm-helper.sh` subcommand, env var, and output format. |
| [`cclm-helper.sh`](cclm-helper.sh) | The actual IPAM helper. Five subcommands: `init`, `list`, `allocate`, `release`, `render`. |

## Quick start

If your two clusters share an L2 segment (typical lab or single DC) and you just want CCLM working without reading 5000 lines of context:

```bash
chmod +x cclm-helper.sh
KUBECONFIG=<hub> ./cclm-helper.sh init 10.250.0.0/16 26 100

KUBECONFIG=<hub> ./cclm-helper.sh allocate hosting-cluster-1
KUBECONFIG=<hub> ./cclm-helper.sh allocate hosted-cluster-a

KUBECONFIG=<hub> ./cclm-helper.sh render hosting-cluster-1 | KUBECONFIG=<cluster-A> oc apply -f -
KUBECONFIG=<hub> ./cclm-helper.sh render hosted-cluster-a  | KUBECONFIG=<cluster-B> oc apply -f -
```

The hub is any cluster you have admin access to: it just holds the state ConfigMap. The render output is plain stdout, so the apply target uses a different kubeconfig.

After that, follow [`cclm-kcs.md`](cclm-kcs.md) for the NNCP, HCO patch, and MTV feature gate (the parts the helper doesn't do).

## Automation

`cclm-helper.sh` is wrapped into an idempotent Ansible role in [`hypershift-automation`](https://github.com/Hypershift-Automation/hypershift-automation). That role also automates Phase B (the HCO and ForkliftController patches), so the same playbook covers Phase A + B end-to-end.

The same repo ships [`scripts/cclm-preflight-migration.sh`](https://github.com/Hypershift-Automation/hypershift-automation/blob/main/scripts/cclm-preflight-migration.sh): a pre-flight diagnostic with a `--fix` mode that cleans up the usual suspects when a migration gets stuck (orphan VMIMs, VM stubs on the destination, finalizer-stuck VMIMs). When a migration hangs, that's the first thing to run.

This repo stays as the home of:

- The `cclm-helper.sh` script itself: single source of truth, kept in sync with the copy bundled in the automation
- The KCS, how-to, POC, and audit documents
- Phase C content (MTV cross-cluster Providers, ServiceAccount tokens, RBAC): not yet automated, lives here as a manual procedure

## License

Apache License 2.0. See [LICENSE](LICENSE).

## Trademarks

OpenShift, OpenShift Virtualization, and Red Hat are trademarks of Red Hat, Inc., used here for identification only. This project is not affiliated with or endorsed by Red Hat.

KubeVirt is a CNCF project. KubeVirt and the upstream Forklift / Migration Toolkit for Virtualization names are used for identification only.
