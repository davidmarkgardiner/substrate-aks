# Private air-gapped run, 2026-11-24

Substrate v1.0.0 + kagent v1.0.1 on private AKS 1.37.1 (uksouth), NSG deny-Internet.

## Cluster evidence (collected on the jumpbox)
```
== AKS
{
  "k8s": "1.37",
  "localAccounts": true,
  "pools": [
    {
      "c": 1,
      "n": "system",
      "vm": "Standard_D4s_v6"
    },
    {
      "c": 1,
      "n": "microvm",
      "vm": "Standard_D4s_v6"
    }
  ],
  "private": true,
  "publicFqdn": null
}
== Storage
{
  "defaultAction": "Deny",
  "peConn": [
    "Approved"
  ],
  "public": "Disabled"
}
== pods
ate-system: 11/11 Running
kagent: 5/5 Running
ate-demo-counter-microvm: 2/2 Running
== image registries in use (all pods)
     35 mcr.microsoft.com
     27 substrateyyrzdtw2jotuc.azurecr.io
== NSG outbound
100	allow-AzureActiveDirectory	Allow
101	allow-AzureResourceManager	Allow
102	allow-MicrosoftContainerRegistry	Allow
103	allow-AzureFrontDoor-FirstParty	Allow
104	allow-AzureContainerRegistry-UKSouth	Allow
105	allow-Storage-UKSouth	Allow
200	allow-extra-443	Allow
210	allow-aks-oidc-issuer	Allow
4000	deny-internet-outbound	Deny
== workload nodes
aks-microvm-10797963-vmss000000 Ready v1.37.1 10.50.0.6
aks-system-10797963-vmss000000 Ready v1.37.1 10.50.0.5
```

## Results
- Counter actor: memory/file/rootfs counters 1, 2, suspend --mode=sync, 3.
- kagent A2A SendMessage to agent substrate-hello: state TASK_STATE_COMPLETED, artifact "GLM on private Substrate microVM OK" (GLM-5 via api.z.ai).

## Public dependencies found by the lockdown
1. Substrate/plugin source fetched from GitHub on every install (fixed with git url.insteadOf to local mirrors).
2. KVM probe image from Docker Hub (SUBSTRATE_AKS_PROBE_IMAGE override added).
3. Bundled Postgres from Docker Hub (mirrored; StatefulSet repointed).
4. ate-api validates SA tokens against the AKS public OIDC issuer (one endpoint allowed).
