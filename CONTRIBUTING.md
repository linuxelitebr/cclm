# Contributing

This repo is documentation-heavy and tooling-light. Contributions that improve clarity, fix factual errors, or add empirically-validated operational findings are very welcome.

## Ground rules

- **Be empirical.** Claims should be backed by what was actually observed in a cluster, not assumed. If you cite a behavior, say what version (OCP, CNV, MTV) you saw it on.
- **Keep examples generic.** Replace real cluster names, IPs, and domains with neutral placeholders (`hosting-cluster-1`, `10.250.0.0/16`, `example.com`, etc.).
- **No customer data.** Anything specific to a real production environment should not appear in commits.

## Where to put what

| Change type | Target file |
|-------------|-------------|
| Quick how-to / KCS-style steps | `cclm-kcs.md` |
| In-depth explanation, design rationale | `cclm-howto.md` |
| Migration network internals, debug trail | `cclm-network-poc.md` |
| Address-space planning / pool design | `cclm-pool-planning.md` |
| `cclm-helper.sh` usage / output format | `cclm-helper-guide.md` |
| Helper script behavior / new subcommand | `cclm-helper.sh` (and update the guide) |

## `cclm-helper.sh` is mirrored

The script is also bundled into [`hypershift-automation`](https://github.com/Hypershift-Automation/hypershift-automation) as `scripts/cclm-helper.sh`. When you change it here, the `hypershift-automation` copy needs the same change to stay in sync. The Ansible role wraps the helper instead of reimplementing the IPAM logic, so divergence breaks the role's behavior.

## Testing

For changes to `cclm-helper.sh`, the [`hypershift-automation`](https://github.com/Hypershift-Automation/hypershift-automation) repo has `scripts/test-cclm-helper.sh` which runs the helper against a mock `oc` (no real cluster). Run that against your modified helper before submitting.

For documentation changes, please proofread for the conventions above (generic examples, empirical claims).

## Commit messages

Conventional Commits style is preferred but not strictly required:

- `docs(<file>): short description` for documentation
- `feat(helper): short description` for new helper subcommand
- `fix(helper): short description` for helper bug fix
- `chore: short description` for misc

## Reporting issues

Please include:

- OCP version (e.g. 4.21.6)
- CNV / OpenShift Virtualization version
- MTV / Forklift version
- Network topology (OVS Balance-SLB? Linux bond? VLAN trunked?)
- The exact symptom (error message, VMIM phase, etc.)
- What you tried before opening the issue
