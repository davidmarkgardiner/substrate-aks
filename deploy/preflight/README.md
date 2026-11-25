# Work-agent bundle: prerequisite check, then install

Goal: install **ate-system (Substrate v1.0.0, microVM)** onto an **existing private AKS cluster**
with no public dependencies, using the fork's adopt mode (`existing` block in `installation.json`).
This bundle is stage 1: find the gaps. **Do not run the installer until the gaps are closed and
David says to go.**

## Rules for the agent
1. `preflight.sh` is read-only. Run it; do not "fix" anything it reports without being asked.
2. Do not run `substrate-aks provision`, `images` or `destroy`. They are not part of this job.
3. Never print or save secrets. Nothing in this bundle needs one.
4. If an image path is not found, report it. Do not guess another path or pull from the Internet.

## Stage 1: get the prerequisites checked
1. Ask David for the values in `preflight.env.example` (copy it to `preflight.env`):
   subscription, resource group and name of the existing cluster, the trusted registry prefix,
   mirrored Postgres and probe image references (with digests), assets directories, and any
   internal git mirror URLs. Blank values are auto-discovered where possible.
2. `az login` on the install host (inside the cluster's network), then `./preflight.sh`.
3. Read `report/preflight-report.md`. Send David:
   - the **Gaps** table (every FAIL and WARN with its suggested fix),
   - `report/installation.draft.json` (values it discovered: storage account, identity client IDs,
     tenant, plugin image digest, worker count, VM size).
4. Stop. Wait for the gaps to be closed, then re-run `preflight.sh` until there are no FAIL rows.

## What the checks cover
| Area | Checks |
|---|---|
| CLI tools | az, kubectl, kubelogin, helm, git, python3, curl, openssl, go (1.27.3 toolchain cached), `substrate-aks` binary, skopeo or crane |
| Azure | logged into the right subscription; install identity object ID |
| Cluster | exists, AKS 1.37, OIDC issuer and workload identity on, microVM pool (label `substrate-aks/runtime=microvm`, taint `ate.dev/sandboxClass=microvm:NoSchedule`, `_v6/_v7` size), nodes linux/amd64 kubelet 1.37 and ready, certificates APIs served, caller is cluster admin, `ate-system` not already present |
| Backends | storage account with `snapshots` and `assets` containers; node and control managed identities, federated to `ate-system/atelet` and `ate-system/ate-api-server` with the cluster's issuer; their Blob Data roles; the install identity's write access to `assets` |
| Images | every image in `images.list` exists in `REGISTRY` with the expected digest (Substrate release set, the built azure-blob plugin and counter images, Postgres 18 and 17, KVM probe, kagent set) |
| Source | the pinned Substrate and plugin commits can be fetched from the mirror (or via the `insteadOf` rewrite) by SHA |
| Assets | microVM files present and sha256-correct; kagent charts and `setup.sql` |
| Environment | `SUBSTRATE_AKS_POSTGRES_IMAGE`, `SUBSTRATE_AKS_PROBE_IMAGE` exported; OIDC issuer reachable from this host |

## Closing common gaps
| Check | Fix |
|---|---|
| `cluster.microvm-pool`, `-taint` | label the pool `substrate-aks/runtime=microvm`, taint `ate.dev/sandboxClass=microvm:NoSchedule` |
| `cluster.worker-count` | set `aks.workerPool.count` to the number of labelled nodes (the installer requires an exact match) |
| `identity.*.federation` | `az identity federated-credential create` with issuer = cluster OIDC issuer URL, audience `api://AzureADTokenExchange`, subject `system:serviceaccount:ate-system:atelet` (node) or `...:ate-api-server` (control) |
| `rbac.*` | Storage Blob Data Contributor on `snapshots` for node and control identities; Reader on `assets` for the node identity; Contributor on `assets` for the install identity |
| `image.*` digest mismatch | re-copy with `skopeo copy --all` (or `crane copy`) so the digest is preserved |
| `image.substrate/azure-blob-plugin`, `counter` | built in a connected stage with ko; see `docs/AIRGAP-BUILD-HANDOFF.md` section 1 |
| `git.*` | host both repos internally; the server must allow fetch-by-SHA |
| `oidc.reachable-from-here` | ate-api must reach the cluster's OIDC issuer from inside the cluster; this check only tests the install host |

## Stage 2: install (only after David approves)
1. Create the config: `substrate-aks init`, then merge `report/installation.draft.json` into the
   generated `installation.json` (keep the generated `installation` block; leave `ownership` as is).
2. Export `SUBSTRATE_AKS_POSTGRES_IMAGE` (name@sha256:digest) and `SUBSTRATE_AKS_PROBE_IMAGE`.
3. `substrate-aks check`, then `substrate-aks install`, then `substrate-aks demo`.
4. `AIRGAP_REGISTRY=<registry> ASSETS_DIR=<kagent assets> GLM_API_KEY=... deploy/kagent/install-kagent.sh`
   (adapt the LLM settings first; the script is GLM-specific).
5. Report every error verbatim. Do not retry destructive steps.

Full background, image digests and known caveats: `docs/AIRGAP-BUILD-HANDOFF.md`.
