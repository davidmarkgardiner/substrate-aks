# Air-gapped install handoff: ate-system + kagent

Scope: **install onto an existing cluster** (adopt mode, section 3). Cluster build, registry choice, privileges and network/egress are handled elsewhere and are out of scope here.

Proven on 2026-11-24 (branch `private-aks`): Substrate v1.0.0 (microVM) and kagent v1.0.1 on a private AKS 1.37 cluster with outbound Internet denied. A kagent agent answered a GLM-5 call over A2A, and a counter actor kept its state across suspend and resume. Evidence: `docs/evidence/private-airgap-2026-11-24.md`.

Items marked **(code review)** come from a read-only review of the repo, not from a run.

## 0. Sort these first

| # | Item | What the install needs |
|---|---|---|
| 1 | **Postgres, Substrate** | Substrate bundles a Postgres StatefulSet that pulls `postgres:18-alpine` from Docker Hub. Mirror the image and export `SUBSTRATE_AKS_POSTGRES_IMAGE=<registry>/...postgres@sha256:<digest>` (digest form required) before `install`. **Fixed on this branch:** the variable now selects its own source-cache directory, so a checkout cached before it was set is no longer reused. The fix builds and passes the unit tests but was **not re-run on a cluster**; verify with `kubectl -n ate-system get sts postgres -o jsonpath='{..image}'`. Or use a managed Postgres. |
| 2 | **Postgres, kagent** | Needs a Postgres, the owner and readwrite secrets, and `setup.sql`. The PoC used an in-cluster `postgres:17-alpine` on `emptyDir` (data lost on pod restart; if it restarts, delete the two secrets and rerun the script). The script uses `$AIRGAP_REGISTRY/library/postgres:17-alpine`; set `KAGENT_PG_IMAGE=<full image ref>` to use another (for example the mirrored 18-alpine). For anything beyond a PoC use a managed Postgres or a PVC. |
| 3 | **Azure Blob backend** | A storage account and blob containers `snapshots` and `assets`, reachable from the cluster, with the node and control identities holding Storage Blob Data Contributor on `snapshots` and Reader on `assets`. The `azure-blob` plugin image must be built in a connected stage and mirrored. |
| 4 | **OIDC** | ate-api validates ServiceAccount tokens against the AKS OIDC issuer. In the PoC the public issuer endpoint (`<region>.oic.prod-aks.azure.com`, 443) was allowed as an IP rule. Either keep that reachable or serve the JWKS internally. The internal option is **untested**. |
| 5 | **Git server** | **Not done.** The PoC used a local bare mirror on the jumpbox with git `insteadOf`. Need an internal git host with the Substrate repo (tag `v1.0.0`) and the plugin repo, serving fetch-by-SHA. |
| 6 | **Images** | Mirrored to the trusted registry with digests preserved (section 1). |
| 7 | **Install inputs** | Skip the `images` step and set the `substrate.images.*` values by hand (section 3). |

## 1. Container images to mirror

Copy in a way that **preserves digests** (`skopeo copy --all`, `crane copy`, or `az acr import`). Re-pushing changes the digest and breaks the `@sha256` references.

### Substrate v1.0.0 release images
Source: `ghcr.io/agent-substrate/substrate/<name>:v1.0.0`. Target: `<registry>/substrate/<name>:v1.0.0`.

| Image | Digest (v1.0.0) |
|---|---|
| ate-idp-server | sha256:9553c0e60a8ad8bbb1c54c59e59cf0d33a338bf4f883b6f806610dc407f49f7c |
| ateapi | sha256:2f1ee444b126b6e3620045b61d2a87507fb0f889da0249656c474ab59dc2beaf |
| atecontroller | sha256:44b3a127048e1da8c15dff35f65defe73f4e54ebb985bc020aa9bb0e6eb029b2 |
| atelet | sha256:79abc69f982392adbcbc3332cd8191cf74ac3cd1f4a43c44e9c8a3ce16488b6e |
| atenet (router and egress gateway) | sha256:04f7d93dc3fb3deda688137077226c12ce2da41cd4753adff708e3737dc59e20 |
| ateworker-microvm | sha256:e4dcfec5aa085bfbdb60c7ccbadde64207a50ad341709487f567026b1696b292 |
| envoy-dataplane | sha256:fc8e4c3ee9060a01153e4d4af571f3db294e60d536422e8a8c2996fa4a72bf8b |
| kubernetes-secrets (credential provider) | sha256:21d494e2461d920bb03a66a0cdf574835c7d2e019b7941acef675ecff5702344 |
| podcertcontroller | sha256:1005579b2142f63412507342f095894eb435fe3736607f32dbad406d0e05c5a5 |
| objectstore-plugin | sha256:485cf92b31fed761c53f478d17ed69bf552a2cd8e8cf3b24b98a3e06789ee274 |
| ateworker-gvisor | sha256:f8987236c6256f58c4b2625e543b43f4ae4bdded6ee6821c03d966effb7c0f17 |

The installer passes `--sandbox-classes gvisor` on every ate-system install, so `ateworker-gvisor` is needed by design **(code review)**.

### Images built in a connected stage (not published upstream)
| Image | Built from | Notes |
|---|---|---|
| `substrate/plugins/objectstore/azure-blob:v1.0.0` | `agent-substrate-plugins/objectstore-azure-blob` at commit `5639af04ad429cf51d2dbf452c80709d3b68e48b`, built with ko | Required. Needs the public Go proxy to build. Record the digest; it changes per build. |
| `substrate/counter:v1.0.0` | `demos/counter` in the Substrate source, built with ko | **Required for kagent.** `install-kagent.sh` takes `workerImage` from the demo's `counter-microvm` WorkerPool and exits if there is none, so the `demo` step must run. Alternative: pass `--set substrateWorkerPool.workerImage=<registry>/substrate/ateworker-microvm:v1.0.0` and edit the script. |

### Third-party images
| Image | Used by |
|---|---|
| `postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15` | Substrate's bundled Postgres |
| `postgres:17-alpine` | kagent Postgres in `deploy/kagent/postgres.yaml` and `install-kagent.sh` (path `library/postgres:17-alpine`) |
| `python:3.13-alpine@sha256:bf12ecc0bea3f171d55145dd02c78b5eeb09f30ee2ac9cc2b4c9e4e8f5e30741` | Installer KVM probe. Set `SUBSTRATE_AKS_PROBE_IMAGE` to the mirrored reference. |

### kagent v1.0.1
Source `ghcr.io/kagent-dev/kagent/...`, target `<registry>/kagent-dev/kagent/...` (the chart's `global.imageRegistry` swaps only the host).

| Image | Reference |
|---|---|
| controller | `controller:1.0.1` |
| ui | `ui:1.0.1` |
| tools | `tools:0.3.0` |
| golang-adk (agent runtime) | `golang-adk@sha256:d3b1151d39c529a6f921a58a995ff699963012001d2e5075f69bf613abebc24d` |
| claude-harness | `claude-harness@sha256:111d28bc8552469b028d91ecd2352c9d44811aba07be12b1e6868db7948f904e` (only if used) |
| codex-harness | `codex-harness@sha256:6885f229b4ee70c9babf37f89ef5d93438eab049875e5bc129799fef6e4cfd19` (only if used) |

**Authoritative lists:** this table is hand-maintained. For kagent, `deploy/kagent/seed-kagent-airgap.sh` derives `images.txt` from `helm template`, but its grep now also matches `quay.io` and `registry.k8s.io`; still check the output. For Substrate, capture the real set from a working cluster:

```
kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
```

**Registry caveat (code review):** the atelet credential provider (`deploy/components/actor-images/credential-provider.yaml`) only matches `*.azurecr.io`. Actor and worker image pulls from a non-ACR registry would need that provider config changed. Confirm before choosing the trusted registry.

## 2. Other artifacts to stage

| Artifact | Detail |
|---|---|
| Substrate source | Tag `v1.0.0`, commit `b34fbee742906494b5eb4f1f36987176bf8770a4` (`github.com/agent-substrate/substrate`). |
| Azure Blob plugin source | Commit `5639af04ad429cf51d2dbf452c80709d3b68e48b` (`github.com/agent-substrate-plugins/objectstore-azure-blob`). |
| Git mirrors | The installer runs `git fetch --depth=1 <github url> <tag or sha>` on every install. Host both repos internally and rewrite: `git config --global url."<internal>".insteadOf "https://github.com/agent-substrate/substrate.git"` (and the plugin URL). Must serve the tag and fetch-by-SHA (`uploadpack.allowAnySHA1InWant`). Delete the cached `source-*` directory if mirrors change. |
| MicroVM runtime assets | A directory with `cloud-hypervisor`, `virtiofsd`, `vmlinux`, `rootfs.img` (amd64). Set `substrate.runtime.assetsDir`. Built from Kata 4.3.1 static and Cloud Hypervisor v53.0 (`ate-setup publish microvm-assets` downloads them from GitHub). SHA-256 must match the pinned SandboxConfig: cloud-hypervisor `448af3d4e59b22c2987f7df94c213ad40fb53a10d437e42b5ee6c4fce7c29ecc`, virtiofsd `15b2e72a78cc08a9bd8a6943e89fb69c88cb3cbeb63069efceade835342ac7d4`, vmlinux `f87d8359035cb7557b16a319e6431ea09b183e62268aef436bf8dc6530d786b6`, rootfs.img `6770db2cca5710593f27c9ac5e1d9d7aab836422695a5e5c4807496a92a0f24d`. `install` uploads them to the Blob `assets` container (`az storage blob upload --auth-mode login`), so the install host's identity must be allowed to write there and must resolve the blob endpoint **(code review)**. |
| kagent charts | `kagent-crds-1.0.1.tgz`, `kagent-1.0.1.tgz` from `oci://ghcr.io/kagent-dev/kagent/helm/`, installed from local files. `seed-kagent-airgap.sh` pulls them. |
| kagent DB setup SQL | `go/core/pkg/postgressetup/setup.sql` from kagent tag `v1.0.1`. |
| Installer binary | Build `bin/substrate-aks` from this branch in a connected stage. Its own Go dependencies are not vendored. |
| Go toolchain | Go 1.27.3 (the installer's stated requirement; `install` runs `go run ./cmd/ate-setup`). Pre-seed it in the Go module cache. With it cached, the install ran with `GOPROXY=off`, because Substrate ships a `vendor/` directory. |
| Install host tools | `az`, `kubectl` 1.37, `kubelogin`, `helm` 3, `git`, `python3`, `curl`, `openssl`, Bicep installed ahead of time. |

## 3. Install onto an existing cluster (adopt mode)

The stock installer only works on clusters it created. This branch adds an `existing` block to `installation.json`: the installer then reads its infrastructure from there, skips its Bicep-deployment lookup and resource-group ownership checks, skips its ACR login, and does not require `aks.apiAuthorizedCidrs`. Unit-tested only; **not yet run against a real cluster.**

### Before you run it, the cluster side must already have
- AKS 1.37 with the **OIDC issuer and workload identity enabled**.
- A **microVM node pool**: label `substrate-aks/runtime=microvm`, taint `ate.dev/sandboxClass=microvm:NoSchedule`, node count equal to `aks.workerPool.count`, a `_v6`/`_v7` size with nested virtualisation, amd64 Linux, kubelet 1.37.
- A **storage account** with containers `snapshots` and `assets`, reachable from the cluster.
- Two **user-assigned managed identities** with federated credentials (issuer = the cluster's OIDC issuer URL, audience `api://AzureADTokenExchange`):
  - node identity, subject `system:serviceaccount:ate-system:atelet`: Storage Blob Data Contributor on `snapshots`, Reader on `assets`.
  - control identity, subject `system:serviceaccount:ate-system:ate-api-server`: Storage Blob Data Contributor on `snapshots`.
- The install identity (`azure.assetPublisherObjectId`) needs Storage Blob Data Contributor on `assets`.
- Images pullable by the nodes and by Substrate's atelet (see the registry caveat in section 1).

### Steps
1. `kubectl`/`az` working against the cluster (`az aks get-credentials` as you do today). The installer runs `az aks get-credentials` itself, so `az login` must be done on the install host.
2. `substrate-aks init` to write `installation.json`, then edit it. Cluster and resource-group names must match `^[a-z][a-z0-9-]{1,38}[a-z0-9]$`.
3. Set these (values are examples):

```json
{
  "azure": {"subscriptionId": "<sub>", "location": "uksouth", "resourceGroup": "<existing-rg>",
            "assetPublisherObjectId": "<object id of the install identity>"},
  "aks": {"clusterName": "<existing-cluster>", "kubernetesVersion": "1.37",
          "workerPool": {"vmSize": "Standard_D4s_v6", "count": 1}},
  "existing": {"storageAccount": "<account>", "nodeClientId": "<uuid>",
               "controlClientId": "<uuid>", "tenantId": "<uuid>"},
  "substrate": {
    "images": {"repository": "<registry>/substrate", "tag": "v1.0.0",
               "plugin": "<registry>/substrate/plugins/objectstore/azure-blob@sha256:<recorded>"},
    "runtime": {"assetsDir": "/abs/path/to/microvm-assets"}
  }
}
```
   Leave `installation.ownership` at its default. Do **not** run `provision` or `images`.
4. Export `SUBSTRATE_AKS_POSTGRES_IMAGE`, `SUBSTRATE_AKS_PROBE_IMAGE` and the git `insteadOf` rewrites (sections 0 and 2).
5. `substrate-aks check`, then `substrate-aks install`, then `substrate-aks demo` (required for kagent).
6. `deploy/kagent/install-kagent.sh`.

Everything else from section 2 (Go toolchain, source mirrors, assets) still applies.

## 4. What had to be fixed to make kagent work

| Symptom | Fix |
|---|---|
| Controller waits for secrets `kagent-postgres-owner` and `kagent-postgres-readwrite` | Provide Postgres and create the secrets (`deploy/kagent/postgres.yaml`, `setup.sql`). |
| Controller crashes: `dial ate-api ... deadline exceeded` | Label the `kagent` namespace `ate.dev/api-access=true`. |
| `PermissionDenied ... lacks can_get on actor_template` | Add `spiffe://cluster.local/ns/kagent/sa/kagent-controller` to ate-api `--authz-bootstrap-owners`. |
| `ActorTemplateRejected (InvalidArgument)` with no detail | Run ate-api with `--preview=ALL`. `PerTemplateSnapshotLocation,GoldenEgressPolicy` alone were not enough; the third gate is not identified. |
| `SendMessage` returns `KAGENT_SEND_NOT_ACCEPTED` forever | Add the kagent SPIFFE ID to the router's `--ingress-allowed-spiffe-ids`. |
| `403 Forbidden egress denied` for the LLM host | Create an `EgressPolicy` for the host, and add `policies: [{atespace: kagent, allowedNamespaces: [kagent]}]` to the `k8s-credential-provider-namespace-policy` ConfigMap. |
| Chart default snapshot location | Set `harnesses.snapshotLocation=azblob://snapshots/kagent/`. |
| Client | Retry `SendMessage` with the same `messageId`; a new ID starts a new session. Use `POST /agents/<ns>/<name>` with `A2A-Version: 1.0`. |

`deploy/kagent/install-kagent.sh` applies all of these. Notes:
- It is **GLM-specific**: it needs `GLM_API_KEY` and creates an Anthropic-provider ModelConfig and an EgressPolicy for `api.z.ai`. Adapt it for the work LLM endpoint.
- `AIRGAP_REGISTRY` and `ASSETS_DIR` must be set together; the script now exits if only one is set.
- The credential-provider namespace policy is now **merged** into the existing ConfigMap instead of replaced (merge logic checked on sample inputs, not on a cluster).
- `KAGENT_PG_IMAGE` overrides kagent's Postgres image.
- The ate-api args, router args and credential-provider ConfigMap are live patches. **Re-running `substrate-aks install` reverts them**, so reapply the script afterwards.

## 5. Open items and caveats

1. **`--preview=ALL` and the bootstrap-owner entry** are PoC shortcuts. No method is given to replace them yet. Identify the third preview gate.
2. **OIDC issuer** is still a public dependency (row 4 above).
3. **Not tested:** installing without `objectstore-plugin` and `ateworker-gvisor`, a real internal git server, Entra-only cluster access (the PoC used local admin kubeconfig), and the OIDC-internal option.
4. **Open question:** whether kagent with `harnesses.enabled=true` pre-creates ActorTemplates that make the Claude and Codex harness images required.
5. **Open question:** whether `ate-setup install` pulls any gVisor or `runsc` asset from the Internet. It worked in the PoC, but only with an allow-all-443 rule whose contents were not recorded.
