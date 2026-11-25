# Air-gapped private build: handoff

Branch `private-aks` of this fork. Proven on 2026-11-24: Substrate v1.0.0 (microVM) and kagent v1.0.1 on a private AKS 1.37 cluster with outbound Internet denied by NSG. A kagent agent answered a GLM-5 call over A2A, and a counter actor kept its state across suspend and resume. Evidence: `docs/evidence/private-airgap-2026-11-24.md`.

Everything below is what the build needs staged **before** it runs, so nothing is pulled from the Internet during the install.

## 1. Container images to mirror

Mirror each image into the internal registry under the target path shown. The installer and the kagent chart both resolve images by that repository path.

### Substrate v1.0.0 release images
Source: `ghcr.io/agent-substrate/substrate/<name>:v1.0.0`. Target: `<registry>/substrate/<name>:v1.0.0`. Keep the digest.

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

`objectstore-plugin` and `ateworker-gvisor` were imported by the installer but not seen running on the microVM-only build. Mirror them anyway, since the installer imports the full set and I did not test an install without them.

### Images the installer builds (not published upstream)
| Image | Built from | Notes |
|---|---|---|
| `substrate/plugins/objectstore/azure-blob:v1.0.0` | `agent-substrate-plugins/objectstore-azure-blob` at commit `5639af04ad429cf51d2dbf452c80709d3b68e48b`, built with ko | Required. The installer builds it with Go modules from the public proxy, so build it in a connected stage and push it. Its digest changes per build; record it. |
| `substrate/counter:v1.0.0` | `demos/counter` in the Substrate source | Only for the counter demo. Skip it, or build it the same way. |

### Third-party images
| Image | Used by |
|---|---|
| `postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15` | Substrate's bundled Postgres (hard-coded upstream) |
| `python:3.13-alpine@sha256:bf12ecc0bea3f171d55145dd02c78b5eeb09f30ee2ac9cc2b4c9e4e8f5e30741` | The installer's KVM probe. Set `SUBSTRATE_AKS_PROBE_IMAGE` to the mirrored reference. |

### kagent v1.0.1
Source `ghcr.io/kagent-dev/kagent/...`. Target `<registry>/kagent-dev/kagent/...`, because the chart's `global.imageRegistry` swaps only the host.

| Image | Reference |
|---|---|
| controller | `controller:1.0.1` |
| ui | `ui:1.0.1` |
| tools | `tools:0.3.0` |
| golang-adk (the agent runtime) | `golang-adk@sha256:d3b1151d39c529a6f921a58a995ff699963012001d2e5075f69bf613abebc24d` |
| claude-harness | `claude-harness@sha256:111d28bc8552469b028d91ecd2352c9d44811aba07be12b1e6868db7948f904e` (only if the Claude harness is used) |
| codex-harness | `codex-harness@sha256:6885f229b4ee70c9babf37f89ef5d93438eab049875e5bc129799fef6e4cfd19` (only if the Codex harness is used) |

kagent v1.0.1 also needs a PostgreSQL. The PoC ran `postgres:17-alpine`; reusing the `postgres:18-alpine` image above, or a managed Postgres, avoids one more image.

AKS system images come from MCR and are not listed here. The node pools need the egress in section 4.

## 2. Other artifacts to stage

| Artifact | Detail |
|---|---|
| Substrate source | Tag `v1.0.0`, commit `b34fbee742906494b5eb4f1f36987176bf8770a4` (`github.com/agent-substrate/substrate`). |
| Azure Blob plugin source | Commit `5639af04ad429cf51d2dbf452c80709d3b68e48b` (`github.com/agent-substrate-plugins/objectstore-azure-blob`). |
| Git mirrors | The installer runs `git fetch --depth=1 <github url> <tag or sha>` on every install. Host both repos on an internal git server and rewrite the URLs: `git config --global url."<internal>".insteadOf "https://github.com/agent-substrate/substrate.git"` (and the plugin URL). The mirror must serve the tag and fetch-by-SHA (`uploadpack.allowAnySHA1InWant`). |
| MicroVM runtime assets | A directory with `cloud-hypervisor`, `virtiofsd`, `vmlinux`, `rootfs.img` for amd64. Set `substrate.runtime.assetsDir` to it. Built from Kata 4.3.1 static and Cloud Hypervisor v53.0 (`ate-setup publish microvm-assets` downloads them from GitHub). SHA-256 must match the pinned SandboxConfig: cloud-hypervisor `448af3d4e59b22c2987f7df94c213ad40fb53a10d437e42b5ee6c4fce7c29ecc`, virtiofsd `15b2e72a78cc08a9bd8a6943e89fb69c88cb3cbeb63069efceade835342ac7d4`, vmlinux `f87d8359035cb7557b16a319e6431ea09b183e62268aef436bf8dc6530d786b6`, rootfs.img `6770db2cca5710593f27c9ac5e1d9d7aab836422695a5e5c4807496a92a0f24d`. |
| kagent charts | `kagent-crds-1.0.1.tgz`, `kagent-1.0.1.tgz` (from `oci://ghcr.io/kagent-dev/kagent/helm/`), installed from local files. `deploy/kagent/seed-kagent-airgap.sh` pulls them. |
| kagent DB setup SQL | `go/core/pkg/postgressetup/setup.sql` from kagent tag `v1.0.1`. |
| Installer binary | Build `bin/substrate-aks` from this branch in a connected stage. Its own Go dependencies are not vendored. |
| Go toolchain | The jumpbox had Go 1.24.5 and the build fetched Go 1.27.3 on demand (the installer's stated requirement), so pre-seed that toolchain in the Go module cache. With it cached, the install ran with `GOPROXY=off`, because Substrate ships a `vendor/` directory. |
| Bicep | `az bicep install` downloads from GitHub. Install it ahead of time. |

To skip the installer's connected `images` step, set `substrate.images.*` and `substrate.runtime.assetsDir` in `installation.json` to your own published images and assets (see `docs/configuration.md`).

## 3. Azure prerequisites

- AKS 1.37 in the region, with x86 D, E or F `_v6` or `_v7` VM sizes that support nested virtualization (the microVM pool needs `/dev/kvm`). Use one CPU generation for the pool; memory snapshots only restore on a matching CPU model.
- vCPU quota for one system node and one microVM node (8 vCPU for two `Standard_D4s_v6`).
- A VNet with subnets for AKS and for private endpoints, and a `privatelink.blob.core.windows.net` zone linked to it. `infra/private/network.bicep` builds the PoC version.
- A user-assigned AKS control-plane identity with Network Contributor on the VNet.
- A builder host inside the VNet: `az`, `kubectl` 1.37, `kubelogin`, `helm` 3, `git`, `python3`, `curl`, `openssl`. A private API cannot be reached from a workstation.
- Install-time rights: Owner, or Contributor plus a role-assignment admin, on the subscription. The PoC gave the jumpbox identity Owner; use something narrower.
- An Entra operator object ID for cluster admin.

## 4. Outbound allow-list (443), everything else denied

AzureActiveDirectory, AzureResourceManager, MicrosoftContainerRegistry, AzureFrontDoor.FirstParty, your registry's region tag (AzureContainerRegistry), Storage for the region (or only the private endpoint), the **AKS OIDC issuer** (`<region>.oic.prod-aks.azure.com`), and the model endpoint if an LLM is used. `infra/private/lockdown.bicep` is the PoC NSG.

## 5. What had to be fixed to make kagent work

| Symptom | Fix |
|---|---|
| Controller waits for secrets `kagent-postgres-owner` and `kagent-postgres-readwrite` | Provide Postgres and create the secrets (`deploy/kagent/postgres.yaml`, `setup.sql`). |
| Controller crashes: `dial ate-api ... deadline exceeded` | Label the `kagent` namespace `ate.dev/api-access=true` (the ate-api NetworkPolicy allows only labelled namespaces). |
| `PermissionDenied ... lacks can_get on actor_template` | Add `spiffe://cluster.local/ns/kagent/sa/kagent-controller` to ate-api `--authz-bootstrap-owners`. |
| `ActorTemplateRejected (InvalidArgument)` with no detail | Run ate-api with `--preview=ALL`. `PerTemplateSnapshotLocation,GoldenEgressPolicy` alone were not enough; the third gate is not identified. |
| `SendMessage` returns `KAGENT_SEND_NOT_ACCEPTED` forever | Add the kagent SPIFFE ID to the router's `--ingress-allowed-spiffe-ids`. |
| `403 Forbidden egress denied` for the LLM host | Create an `EgressPolicy` for the host, and add `policies: [{atespace: kagent, allowedNamespaces: [kagent]}]` to the `k8s-credential-provider-namespace-policy` ConfigMap so the egress gateway can read the key Secret. |
| Chart default snapshot location | Set `harnesses.snapshotLocation=azblob://snapshots/kagent/`. |
| Client | Retry `SendMessage` with the same `messageId`; a new ID starts a new session. Use `POST /agents/<ns>/<name>` with `A2A-Version: 1.0`. |

`deploy/kagent/install-kagent.sh` applies all of these (set `AIRGAP_REGISTRY` and `ASSETS_DIR` for the air-gapped mode).

## 6. Public dependencies the lockdown exposed

1. The installer fetches Substrate and plugin source from GitHub on every install. Fixed with the git URL rewrite; also delete the cached `source-*` directory if you change the mirrors.
2. The KVM probe image came from Docker Hub. Fixed with `SUBSTRATE_AKS_PROBE_IMAGE`.
3. Bundled Postgres came from Docker Hub. **The `SUBSTRATE_AKS_POSTGRES_IMAGE` override in this branch did not take effect in the run.** The PoC repointed the StatefulSet by hand (`kubectl patch sts postgres`). Do that, or fix the override, before relying on it.
4. ate-api validates ServiceAccount tokens against the public AKS OIDC issuer. One endpoint was allowed. A fully closed network needs another answer.

## 7. Run order

1. Connected stage: mirror images (section 1), build the plugin image and installer binary, assemble the microVM assets, fetch charts and SQL, create the git mirrors.
2. Create the network, private DNS zone and builder host (`infra/private/network.bicep`), then apply the egress lockdown.
3. On the builder host: `substrate-aks init`, add `aks.privateNetwork` to `installation.json`, then `provision`, `install`, `demo`.
4. Run `deploy/kagent/install-kagent.sh`.
5. Replace the PoC shortcuts: `--preview=ALL` and the bootstrap-owner entry.
