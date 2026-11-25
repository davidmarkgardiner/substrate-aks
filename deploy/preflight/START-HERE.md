# Start here (for the human)

One page. Read this first; hand `AGENT-PROMPT.md` to the work agent.

## What we're doing
Install **ate-system (Agent Substrate v1.0.0, microVM sandboxes)** onto the **private AKS cluster
that already exists**, then install **kagent** on top. Nothing may be pulled from the public Internet
during the install: images come from your trusted registry, source from an internal git server.

## Desired end state (how we know it worked)
1. Every pod in namespace `ate-system` is Ready (ate-api-server, controller, atelet, router, Postgres, ...).
2. The microVM sandbox config is applied and the **counter demo** actor keeps its state across
   suspend and resume. (This proves the Blob snapshot backend and the microVM nodes work.)
3. kagent is installed, an Agent is Ready, and one A2A call to it returns an answer from the LLM.
4. The install log shows no pull from a public registry and no fetch from github.com.

Steps 1 and 2 are the target for now. Step 3 comes after, once Substrate itself is healthy.

## What already has to exist (you provide; the installer does not build any of it)
| Thing | Detail |
|---|---|
| Cluster | AKS 1.37, OIDC issuer + workload identity on, a microVM node pool (label `substrate-aks/runtime=microvm`, taint `ate.dev/sandboxClass=microvm:NoSchedule`, `_v6/_v7` VM size) |
| Blob backend | A storage account with containers `snapshots` and `assets` |
| Two managed identities | One federated to `ate-system/atelet`, one to `ate-system/ate-api-server`, with Blob Data roles |
| Images | Everything in `import-list.csv` (full public path, version, digest) mirrored into the trusted registry, **digests preserved**. Two Docker Hub tags (`postgres:18-alpine`, `python:3.13-alpine`) have moved since we pinned them: import those **by digest** |
| Two images we build | `azure-blob` plugin and `counter` (built with ko in a connected stage; they are not published upstream) |
| Source | Internal git copies of the Substrate and plugin repos (fetch-by-SHA must work) |
| Files | The four microVM runtime files (checksums are pinned); kagent charts and SQL |
| Install host | Inside the cluster's network, with the CLI tools the preflight lists and the `substrate-aks` binary built from branch `private-aks` |

Postgres for Substrate needs nothing set up: it ships inside ate-system. You only need its image mirrored.

## The order
| # | Who | What |
|---|---|---|
| 0 | You | Decide the registry prefix and git mirror URLs. Mirror images, build the two images, stage the files. |
| 1 | Agent | Run `preflight.sh` (read-only). It lists every gap with a suggested fix and drafts the config values. |
| 2 | You | Close the gaps. Agent re-runs `preflight.sh` until there are no FAIL rows. |
| 3 | You | Say "go". Nothing is installed before this. |
| 4 | Agent | `substrate-aks check`, `install`, `demo`. Reports every error verbatim. |
| 5 | Agent | kagent via `deploy/kagent/install-kagent.sh` (adapt the LLM settings first). |

## Things to know before you start
- **Adopt mode is new and untested on a real cluster.** The fork's installer normally builds its own cluster;
  I added an `existing` config block so it installs onto yours. Expect the first real run to surface something.
- **Registry type matters.** Substrate's atelet credential provider only matches `*.azurecr.io`. If your trusted
  registry is not an ACR, actor and worker image pulls may fail until that config is changed.
- **OIDC:** ate-api validates tokens against the cluster's OIDC issuer; in the PoC we allowed that one public
  endpoint. A fully closed network needs another answer (untested).
- **PoC shortcuts still in the kagent step:** `--preview=ALL` and a bootstrap-owner entry. Re-running
  `substrate-aks install` reverts the kagent patches, so re-run the kagent script after.
- **The repo is public** (`davidmarkgardiner/substrate-aks`, branch `private-aks`). Nothing secret is in it;
  move it to an internal git server when you can.

Background and exact digests: `docs/AIRGAP-BUILD-HANDOFF.md`. Agent instructions: `README.md`.
