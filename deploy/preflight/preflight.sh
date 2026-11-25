#!/usr/bin/env bash
# Read-only prerequisite check for installing ate-system (Substrate v1.0.0, microVM)
# onto an EXISTING AKS cluster with substrate-aks adopt mode.
#
# It changes nothing: no kubeconfig is modified (a temp kubeconfig is used), nothing is
# applied to the cluster, nothing is written to Azure or the registry. It writes a report
# and a draft installation.json fragment into ./report/.
#
#   cp preflight.env.example preflight.env   # fill in
#   ./preflight.sh [path/to/preflight.env]
#
# Exit code: 0 = no FAIL rows, 1 = at least one FAIL, 2 = bad usage.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${1:-$HERE/preflight.env}"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy preflight.env.example and fill it in)" >&2; exit 2; }
set -a; . "$ENV_FILE"; set +a
OUT="${OUT_DIR:-$HERE/report}"; mkdir -p "$OUT"
ROWS="$OUT/results.tsv"; : > "$ROWS"
FAILS=0; WARNS=0; PASSES=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

SUBSTRATE_COMMIT="b34fbee742906494b5eb4f1f36987176bf8770a4"
PLUGIN_COMMIT="5639af04ad429cf51d2dbf452c80709d3b68e48b"
SUBSTRATE_URL="https://github.com/agent-substrate/substrate.git"
PLUGIN_URL="https://github.com/agent-substrate-plugins/objectstore-azure-blob.git"

rec() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$ROWS"
  case "$1" in FAIL) FAILS=$((FAILS+1));; WARN) WARNS=$((WARNS+1));; PASS) PASSES=$((PASSES+1));; esac
  printf '[%-4s] %-28s %s\n' "$1" "$2" "$3"; }
pass() { rec PASS "$1" "$2"; }
fail() { rec FAIL "$1" "$2" "$3"; }
warn() { rec WARN "$1" "$2" "$3"; }
errline() { grep -m1 -E "ERROR|rror" "$1" 2>/dev/null | head -c 200 || true; }
have() { command -v "$1" >/dev/null 2>&1; }
py() { python3 -I -c "$@"; }

# Values discovered along the way, written to the draft config at the end.
CL_LOCATION=""; CL_VMSIZE=""; CL_WORKERS=""; CL_STORAGE=""; CL_NODE_CID=""; CL_CONTROL_CID=""
CL_TENANT=""; CL_PLUGIN_DIGEST=""; CL_ISSUER=""; CL_INSTALL_OID=""

echo "== 1. CLI tools =="
for t in az kubectl kubelogin helm git python3 curl openssl; do
  if have "$t"; then pass "tool.$t" "$(command -v "$t")"
  else fail "tool.$t" "not installed" "install $t on the install host"; fi
done
if have kubectl; then
  v="$(kubectl version --client 2>/dev/null | head -1)"; pass "tool.kubectl.version" "${v:-unknown}"
fi
if have go; then
  pass "tool.go" "$(go version)"
  mc="$(go env GOMODCACHE 2>/dev/null)"
  if ls -d "$mc"/golang.org/toolchain@*go1.27.3* >/dev/null 2>&1; then pass "tool.go.toolchain" "go1.27.3 toolchain is in the module cache"
  else warn "tool.go.toolchain" "go1.27.3 toolchain not in module cache; install fetches it from the Internet unless GOTOOLCHAIN=local with Go >= 1.27.3" "pre-seed the toolchain (see handoff doc section 2)"; fi
else fail "tool.go" "not installed" "install Go; the installer runs 'go run ./cmd/ate-setup'"; fi
BIN="${SUBSTRATE_AKS_BIN:-}"
[ -z "$BIN" ] && have substrate-aks && BIN="$(command -v substrate-aks)"
[ -z "$BIN" ] && [ -x "$HERE/../../bin/substrate-aks" ] && BIN="$HERE/../../bin/substrate-aks"
if [ -n "$BIN" ]; then pass "tool.substrate-aks" "$BIN"
else fail "tool.substrate-aks" "installer binary not found" "build bin/substrate-aks from branch private-aks in a connected stage, or set SUBSTRATE_AKS_BIN"; fi
COPY=""; have skopeo && COPY=skopeo; [ -z "$COPY" ] && have crane && COPY=crane
if [ -n "$COPY" ]; then pass "tool.registry-inspect" "$COPY"
else fail "tool.registry-inspect" "neither skopeo nor crane found" "install skopeo or crane (needed to verify mirrored images)"; fi

echo "== 2. Azure login =="
if have az; then
  CUR="$(az account show --query id -o tsv 2>/dev/null)"
  if [ -z "$CUR" ]; then fail "azure.login" "az is not logged in" "az login (or az login --identity on the jumpbox)"
  elif [ -n "${SUBSCRIPTION_ID:-}" ] && [ "$CUR" != "$SUBSCRIPTION_ID" ]; then
    fail "azure.subscription" "logged into $CUR, expected $SUBSCRIPTION_ID" "az account set --subscription $SUBSCRIPTION_ID"
  else pass "azure.login" "subscription $CUR"; [ -z "${SUBSCRIPTION_ID:-}" ] && SUBSCRIPTION_ID="$CUR"; fi
  CL_INSTALL_OID="${INSTALL_OBJECT_ID:-$(az ad signed-in-user show --query id -o tsv 2>/dev/null)}"
  if [ -n "$CL_INSTALL_OID" ]; then pass "azure.install-identity" "object id $CL_INSTALL_OID"
  else warn "azure.install-identity" "could not read the signed-in user's object id (service principal or managed identity?)" "set INSTALL_OBJECT_ID in preflight.env"; fi
fi

echo "== 3. Cluster =="
KCFG=""
if have az && [ -n "${RESOURCE_GROUP:-}" ] && [ -n "${CLUSTER_NAME:-}" ]; then
  if az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" -o json > "$TMP/aks.json" 2>"$TMP/aks.err"; then
    pass "cluster.exists" "$CLUSTER_NAME in $RESOURCE_GROUP"
    py '
import json,re,sys
d=json.load(open(sys.argv[1]))
p=d.get("agentPoolProfiles") or []
print("LOCATION="+d.get("location",""))
print("K8S="+(d.get("currentKubernetesVersion") or d.get("kubernetesVersion") or ""))
print("OIDC="+str(bool((d.get("oidcIssuerProfile") or {}).get("enabled"))))
print("ISSUER="+((d.get("oidcIssuerProfile") or {}).get("issuerUrl") or (d.get("oidcIssuerProfile") or {}).get("issuerURL") or ""))
print("WI="+str(bool(((d.get("securityProfile") or {}).get("workloadIdentity") or {}).get("enabled"))))
print("PRIVATE="+str(bool((d.get("apiServerAccessProfile") or {}).get("enablePrivateCluster"))))
for x in p:
    labels=x.get("nodeLabels") or {}
    taints=x.get("nodeTaints") or []
    if labels.get("substrate-aks/runtime")=="microvm":
        print("POOL=%s|%s|%s|%s"%(x.get("name"),x.get("count"),x.get("vmSize"),",".join(taints)))
' "$TMP/aks.json" > "$TMP/aks.kv"
    CL_LOCATION="$(sed -n 's/^LOCATION=//p' "$TMP/aks.kv")"
    K8S="$(sed -n 's/^K8S=//p' "$TMP/aks.kv")"
    CL_ISSUER="$(sed -n 's/^ISSUER=//p' "$TMP/aks.kv")"
    case "$K8S" in 1.37*) pass "cluster.version" "$K8S";; *) fail "cluster.version" "AKS version is '$K8S', need 1.37.x" "upgrade or use a 1.37 cluster";; esac
    [ "$(sed -n 's/^OIDC=//p' "$TMP/aks.kv")" = "True" ] && pass "cluster.oidc" "issuer $CL_ISSUER" || fail "cluster.oidc" "OIDC issuer is not enabled" "az aks update --enable-oidc-issuer"
    [ "$(sed -n 's/^WI=//p' "$TMP/aks.kv")" = "True" ] && pass "cluster.workload-identity" "enabled" || fail "cluster.workload-identity" "workload identity is not enabled" "az aks update --enable-workload-identity"
    pool="$(sed -n 's/^POOL=//p' "$TMP/aks.kv" | head -1)"
    if [ -z "$pool" ]; then fail "cluster.microvm-pool" "no node pool labelled substrate-aks/runtime=microvm" "create/label a microVM pool (see handoff doc section 3)"
    else
      IFS='|' read -r pname pcount pvm ptaints <<< "$pool"; CL_VMSIZE="$pvm"
      pass "cluster.microvm-pool" "pool $pname, $pcount node(s), $pvm"
      case "$ptaints" in *"ate.dev/sandboxClass=microvm:NoSchedule"*) pass "cluster.microvm-taint" "$ptaints";; *) fail "cluster.microvm-taint" "taints are '$ptaints'" "add taint ate.dev/sandboxClass=microvm:NoSchedule to the pool";; esac
      case "$pvm" in *_v6|*_v7|*v6|*v7) pass "cluster.microvm-vmsize" "$pvm";; *) warn "cluster.microvm-vmsize" "$pvm is not a _v6/_v7 size; nested virtualisation (/dev/kvm) is needed" "confirm the size supports nested virtualisation";; esac
    fi
    KCFG="$TMP/kubeconfig"
    if az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --file "$KCFG" --context "$CLUSTER_NAME" --overwrite-existing >/dev/null 2>"$TMP/cred.err"; then
      have kubelogin && kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KCFG" >/dev/null 2>&1
      pass "cluster.credentials" "fetched into a temp kubeconfig (your kubeconfig is untouched)"
    else fail "cluster.credentials" "$(errline "$TMP/cred.err")" "check RBAC (cluster admin) and that this host can reach the private API"; KCFG=""; fi
  else fail "cluster.exists" "$(errline "$TMP/aks.err")" "check RESOURCE_GROUP, CLUSTER_NAME and Reader access"; fi
else fail "cluster.config" "RESOURCE_GROUP / CLUSTER_NAME not set" "fill preflight.env"; fi

if [ -n "$KCFG" ] && have kubectl; then
  if KUBECONFIG="$KCFG" kubectl get nodes -o json > "$TMP/nodes.json" 2>"$TMP/nodes.err"; then
    pass "cluster.api-reachable" "kubectl can list nodes"
    py '
import json,sys
n=json.load(open(sys.argv[1]))["items"]
m=[x for x in n if x["metadata"].get("labels",{}).get("substrate-aks/runtime")=="microvm"]
ready=lambda x: any(c["type"]=="Ready" and c["status"]=="True" for c in x["status"]["conditions"])
bad=[x["metadata"]["name"] for x in n if x["status"]["nodeInfo"]["architecture"]!="amd64" or x["status"]["nodeInfo"]["operatingSystem"]!="linux" or not x["status"]["nodeInfo"]["kubeletVersion"].startswith("v1.37.")]
print("MICROVM=%d"%len(m)); print("READY=%d"%sum(ready(x) for x in m)); print("BADNODES="+",".join(bad))
' "$TMP/nodes.json" > "$TMP/nodes.kv"
    mv_n="$(sed -n 's/^MICROVM=//p' "$TMP/nodes.kv")"; rd_n="$(sed -n 's/^READY=//p' "$TMP/nodes.kv")"; CL_WORKERS="$mv_n"
    if [ "${mv_n:-0}" -ge 1 ]; then pass "cluster.microvm-nodes" "$mv_n labelled node(s), $rd_n ready"
    else fail "cluster.microvm-nodes" "no nodes labelled substrate-aks/runtime=microvm" "scale the microVM pool up"; fi
    [ -n "${WORKER_COUNT:-}" ] && [ "$mv_n" != "$WORKER_COUNT" ] && fail "cluster.worker-count" "found $mv_n microVM nodes, WORKER_COUNT=$WORKER_COUNT (installer requires aks.workerPool.count to match exactly)" "set WORKER_COUNT to $mv_n or resize the pool"
    bad="$(sed -n 's/^BADNODES=//p' "$TMP/nodes.kv")"
    [ -z "$bad" ] && pass "cluster.node-platform" "all nodes linux/amd64 kubelet 1.37" || fail "cluster.node-platform" "nodes not linux/amd64/1.37: $bad" "fix node pools"
    for api in podcertificaterequests.certificates.k8s.io clustertrustbundles.certificates.k8s.io; do
      KUBECONFIG="$KCFG" kubectl api-resources --api-group=certificates.k8s.io -o name 2>/dev/null | grep -qx "$api" \
        && pass "cluster.api.$api" "served" || fail "cluster.api.$api" "not served" "needs Kubernetes 1.37 with this API enabled"
    done
    KUBECONFIG="$KCFG" kubectl auth can-i '*' '*' >/dev/null 2>&1 && pass "cluster.admin" "caller is cluster admin" || warn "cluster.admin" "caller may not be cluster admin" "the install creates namespaces, CRDs, ClusterRoles; grant AKS RBAC Cluster Admin"
    if KUBECONFIG="$KCFG" kubectl get ns ate-system >/dev/null 2>&1; then warn "cluster.ate-system" "namespace ate-system already exists" "installer refuses to adopt an installation without its own install record; check what is there first"
    else pass "cluster.ate-system" "namespace not present (clean install)"; fi
  else fail "cluster.api-reachable" "$(errline "$TMP/nodes.err")" "run from a host inside the cluster's network"; fi
fi

echo "== 4. Storage backend =="
STORAGE_ID=""
if have az && [ -n "${RESOURCE_GROUP:-}" ]; then
  SA="${STORAGE_ACCOUNT:-}"
  if [ -z "$SA" ]; then
    names="$(az storage account list -g "$RESOURCE_GROUP" --query '[].name' -o tsv 2>/dev/null)"
    [ "$(printf '%s\n' "$names" | grep -c .)" = 1 ] && SA="$names"
  fi
  if [ -z "$SA" ]; then fail "storage.account" "no single storage account found; set STORAGE_ACCOUNT" "create the account with containers snapshots and assets"
  elif STORAGE_ID="$(az storage account show -n "$SA" --query id -o tsv 2>/dev/null)" && [ -n "$STORAGE_ID" ]; then
    CL_STORAGE="$SA"; pass "storage.account" "$SA"
    pna="$(az storage account show -n "$SA" --query publicNetworkAccess -o tsv 2>/dev/null)"; pass "storage.network" "publicNetworkAccess=$pna (cluster and install host must be able to reach the blob endpoint)"
    for c in snapshots assets; do
      ex="$(az storage container exists --account-name "$SA" --name "$c" --auth-mode login --query exists -o tsv 2>"$TMP/ct.err")"
      if [ "$ex" = "true" ]; then pass "storage.container.$c" "exists"
      elif [ "$ex" = "false" ]; then fail "storage.container.$c" "missing" "az storage container create --name $c --account-name $SA --auth-mode login"
      else warn "storage.container.$c" "could not check: $(errline "$TMP/ct.err")" "needs a Blob Data role and network access to the blob endpoint"; fi
    done
  else fail "storage.account" "storage account '$SA' not found" "check STORAGE_ACCOUNT"; fi
fi

echo "== 5. Identities and RBAC =="
EXP_NODE_SUBJ="system:serviceaccount:ate-system:atelet"
EXP_CTRL_SUBJ="system:serviceaccount:ate-system:ate-api-server"
role_ok() { # principalId containerName "Role A,Role B"
  az role assignment list --assignee-object-id "$1" --all -o json 2>/dev/null | py '
import json,sys
want=set(sys.argv[3].split(","));target=(sys.argv[1]+"/blobServices/default/containers/"+sys.argv[2]).lower()
ok=[a for a in json.load(sys.stdin) if a.get("roleDefinitionName") in want and target.startswith(a["scope"].lower())]
print("yes" if ok else "no")' "$STORAGE_ID" "$2" "$3"
}
ident() { # label name expectedSubject
  local label="$1" name="$2" subj="$3"
  if [ -z "$name" ]; then
    name="$(az identity list -g "$RESOURCE_GROUP" --query "[?ends_with(name,'-$label-store')].name | [0]" -o tsv 2>/dev/null)"
  fi
  [ -z "$name" ] && { fail "identity.$label" "no managed identity found; set the identity name in preflight.env" "create it and federate it"; return; }
  if ! az identity show -g "$RESOURCE_GROUP" -n "$name" -o json > "$TMP/id-$label.json" 2>/dev/null; then fail "identity.$label" "identity '$name' not found in $RESOURCE_GROUP" "create it"; return; fi
  cid="$(py 'import json;print(json.load(open("'"$TMP/id-$label.json"'"))["clientId"])')"
  pid="$(py 'import json;print(json.load(open("'"$TMP/id-$label.json"'"))["principalId"])')"
  tid="$(py 'import json;print(json.load(open("'"$TMP/id-$label.json"'"))["tenantId"])')"
  pass "identity.$label" "$name clientId=$cid"; CL_TENANT="$tid"
  [ "$label" = node ] && CL_NODE_CID="$cid" || CL_CONTROL_CID="$cid"
  fed="$(az identity federated-credential list -g "$RESOURCE_GROUP" --identity-name "$name" -o json 2>/dev/null | py '
import json,sys
want_s,want_i=sys.argv[1],sys.argv[2].rstrip("/")
print("yes" if any(f.get("subject")==want_s and f.get("issuer","").rstrip("/")==want_i and "api://AzureADTokenExchange" in (f.get("audiences") or []) for f in json.load(sys.stdin)) else "no")' "$subj" "$CL_ISSUER")"
  [ "$fed" = yes ] && pass "identity.$label.federation" "subject $subj, issuer matches the cluster" \
    || fail "identity.$label.federation" "no federated credential with subject $subj, issuer $CL_ISSUER, audience api://AzureADTokenExchange" "az identity federated-credential create"
  if [ -n "$STORAGE_ID" ]; then
    if [ "$label" = node ]; then
      [ "$(role_ok "$pid" snapshots "Storage Blob Data Contributor,Storage Blob Data Owner")" = yes ] && pass "rbac.node.snapshots" "Blob Data Contributor" || fail "rbac.node.snapshots" "node identity lacks Storage Blob Data Contributor on snapshots" "az role assignment create"
      [ "$(role_ok "$pid" assets "Storage Blob Data Reader,Storage Blob Data Contributor,Storage Blob Data Owner")" = yes ] && pass "rbac.node.assets" "Blob Data Reader or better" || fail "rbac.node.assets" "node identity lacks Storage Blob Data Reader on assets" "az role assignment create"
    else
      [ "$(role_ok "$pid" snapshots "Storage Blob Data Contributor,Storage Blob Data Owner")" = yes ] && pass "rbac.control.snapshots" "Blob Data Contributor" || fail "rbac.control.snapshots" "control identity lacks Storage Blob Data Contributor on snapshots" "az role assignment create"
    fi
  fi
}
if have az && [ -n "${RESOURCE_GROUP:-}" ]; then
  ident node "${NODE_IDENTITY_NAME:-}" "$EXP_NODE_SUBJ"
  ident control "${CONTROL_IDENTITY_NAME:-}" "$EXP_CTRL_SUBJ"
  if [ -n "$STORAGE_ID" ] && [ -n "$CL_INSTALL_OID" ]; then
    [ "$(role_ok "$CL_INSTALL_OID" assets "Storage Blob Data Contributor,Storage Blob Data Owner")" = yes ] \
      && pass "rbac.installer.assets" "install identity can write assets" || fail "rbac.installer.assets" "install identity lacks Storage Blob Data Contributor on assets (the install uploads the microVM files)" "az role assignment create"
  fi
fi

echo "== 6. Images in the trusted registry =="
REG="${REGISTRY:-}"
if [ -z "$REG" ]; then fail "images.registry" "REGISTRY not set" "fill preflight.env"
elif [ -z "$COPY" ]; then warn "images.skipped" "no skopeo/crane, image checks skipped" "install skopeo or crane"
else
  digest_of() { # ref -> digest on stdout
    if [ "$COPY" = skopeo ]; then skopeo inspect --format '{{.Digest}}' "docker://$1" 2>/dev/null
    else crane digest "$1" 2>/dev/null; fi
  }
  while IFS='|' read -r id ref want req; do
    case "$id" in ''|\#*) continue;; esac
    ref="${ref//\{REG\}/$REG}"; ref="${ref//\{PG\}/${POSTGRES_IMAGE:-}}"; ref="${ref//\{PROBE\}/${PROBE_IMAGE:-}}"
    if [ -z "$ref" ]; then fail "image.$id" "reference is empty (POSTGRES_IMAGE / PROBE_IMAGE not set)" "fill preflight.env"; continue; fi
    got="$(digest_of "$ref")"
    if [ -z "$got" ]; then
      [ "$req" = y ] && fail "image.$id" "not found: $ref" "mirror it (digest-preserving copy)" || warn "image.$id" "not found (optional): $ref" "mirror it only if you use it"
    elif [ "$want" != "-" ] && [ "$got" != "$want" ]; then
      fail "image.$id" "digest mismatch: got $got, want $want" "re-copy with 'skopeo copy --all' so the digest is preserved"
    else
      pass "image.$id" "$got"
      case "$id" in substrate/azure-blob-plugin*) CL_PLUGIN_DIGEST="$got";; esac
    fi
  done < "$HERE/images.list"
fi

echo "== 7. Source mirrors (git) =="
if have git; then
  ins="$(git config --global --get-regexp '^url\..*\.insteadof$' 2>/dev/null | head -5)"
  [ -n "$ins" ] && pass "git.insteadOf" "$(printf '%s' "$ins" | tr '\n' ';')" || warn "git.insteadOf" "no url.<mirror>.insteadOf rewrite configured" "needed unless the host can reach github.com"
  fetch_check() { # id url commit
    local d="$TMP/git-$1"; git init -q "$d"
    if git -C "$d" fetch -q --depth=1 "$2" "$3" 2>"$TMP/git.err"; then pass "git.$1" "fetched $3 from $2"
    else fail "git.$1" "cannot fetch $3 from $2: $(head -c 150 "$TMP/git.err")" "host the repo internally; the server must allow fetch-by-SHA (uploadpack.allowAnySHA1InWant)"; fi
  }
  fetch_check substrate "${GIT_MIRROR_SUBSTRATE:-$SUBSTRATE_URL}" "$SUBSTRATE_COMMIT"
  fetch_check plugin "${GIT_MIRROR_PLUGIN:-$PLUGIN_URL}" "$PLUGIN_COMMIT"
fi

echo "== 8. Runtime assets and charts =="
if [ -z "${ASSETS_DIR:-}" ]; then fail "assets.dir" "ASSETS_DIR not set" "fill preflight.env"
else
  sha_of() { if have sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
  for pair in cloud-hypervisor:448af3d4e59b22c2987f7df94c213ad40fb53a10d437e42b5ee6c4fce7c29ecc \
              virtiofsd:15b2e72a78cc08a9bd8a6943e89fb69c88cb3cbeb63069efceade835342ac7d4 \
              vmlinux:f87d8359035cb7557b16a319e6431ea09b183e62268aef436bf8dc6530d786b6 \
              rootfs.img:6770db2cca5710593f27c9ac5e1d9d7aab836422695a5e5c4807496a92a0f24d; do
    f="${pair%%:*}"; want="${pair##*:}"
    if [ ! -f "$ASSETS_DIR/$f" ]; then fail "assets.$f" "missing in $ASSETS_DIR" "stage the microVM assets"
    elif [ "$(sha_of "$ASSETS_DIR/$f")" = "$want" ]; then pass "assets.$f" "sha256 ok"
    else fail "assets.$f" "sha256 does not match the pinned SandboxConfig" "rebuild the assets from Kata 4.3.1 + Cloud Hypervisor v53.0"; fi
  done
fi
if [ -n "${KAGENT_ASSETS_DIR:-}" ]; then
  for f in kagent-crds-1.0.1.tgz kagent-1.0.1.tgz kagent-setup.sql; do
    [ -f "$KAGENT_ASSETS_DIR/$f" ] && pass "kagent.$f" "present" || fail "kagent.$f" "missing in $KAGENT_ASSETS_DIR" "run deploy/kagent/seed-kagent-airgap.sh in a connected stage"
  done
else warn "kagent.assets" "KAGENT_ASSETS_DIR not set; kagent files not checked" "set it before the kagent step"; fi

echo "== 9. Environment and reachability =="
[ -n "${SUBSTRATE_AKS_POSTGRES_IMAGE:-}" ] && pass "env.SUBSTRATE_AKS_POSTGRES_IMAGE" "set" || warn "env.SUBSTRATE_AKS_POSTGRES_IMAGE" "not exported in this shell" "export it (name@sha256:digest) before 'substrate-aks install'"
[ -n "${SUBSTRATE_AKS_PROBE_IMAGE:-}" ] && pass "env.SUBSTRATE_AKS_PROBE_IMAGE" "set" || warn "env.SUBSTRATE_AKS_PROBE_IMAGE" "not exported in this shell" "export it before 'substrate-aks check'"
if [ -n "$CL_ISSUER" ] && have curl; then
  code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "${CL_ISSUER%/}/.well-known/openid-configuration" 2>/dev/null)"
  [ "$code" = 200 ] && pass "oidc.reachable-from-here" "HTTP 200" || warn "oidc.reachable-from-here" "HTTP ${code:-none} from this host" "ate-api must reach the issuer from inside the cluster; verify that path separately"
fi

# ---- reports ----
export CL_LOCATION CL_VMSIZE CL_WORKERS CL_STORAGE CL_NODE_CID CL_CONTROL_CID CL_TENANT CL_PLUGIN_DIGEST CL_ISSUER CL_INSTALL_OID SUBSCRIPTION_ID
python3 -I - "$OUT" "$FAILS" "$WARNS" "$PASSES" <<'PY'
import csv, json, os, sys
out, fails, warns, passes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
rows = list(csv.reader(open(os.path.join(out, "results.tsv")), delimiter="\t"))
e = os.environ
with open(os.path.join(out, "preflight-report.md"), "w") as f:
    f.write(f"# Preflight report\n\n{passes} pass, {warns} warn, {fails} fail\n\n")
    gaps = [r for r in rows if r[0] in ("FAIL", "WARN")]
    f.write("## Gaps to close\n\n")
    if not gaps: f.write("None.\n")
    else:
        f.write("| Status | Check | Detail | Suggested fix |\n|---|---|---|---|\n")
        for r in gaps: f.write("| %s | %s | %s | %s |\n" % tuple((r + [""] * 4)[:4]))
    f.write("\n## Passed\n\n")
    for r in rows:
        if r[0] == "PASS": f.write(f"- {r[1]}: {r[2]}\n")
cfg = {
  "azure": {"subscriptionId": e.get("SUBSCRIPTION_ID", ""), "location": e.get("CL_LOCATION", ""),
            "resourceGroup": e.get("RESOURCE_GROUP", ""), "assetPublisherObjectId": e.get("CL_INSTALL_OID", "")},
  "aks": {"clusterName": e.get("CLUSTER_NAME", ""), "kubernetesVersion": "1.37",
          "workerPool": {"vmSize": e.get("CL_VMSIZE", ""), "count": int(e.get("CL_WORKERS") or 0)}},
  "existing": {"storageAccount": e.get("CL_STORAGE", ""), "nodeClientId": e.get("CL_NODE_CID", ""),
               "controlClientId": e.get("CL_CONTROL_CID", ""), "tenantId": e.get("CL_TENANT", "")},
  "substrate": {"images": {"repository": (e.get("REGISTRY", "") + "/substrate"), "tag": "v1.0.0",
                           "plugin": (e.get("REGISTRY", "") + "/substrate/plugins/objectstore/azure-blob@" + e.get("CL_PLUGIN_DIGEST", ""))},
                "runtime": {"assetsDir": e.get("ASSETS_DIR", "")}},
}
json.dump(cfg, open(os.path.join(out, "installation.draft.json"), "w"), indent=2)
PY
echo
echo "Result: $PASSES pass, $WARNS warn, $FAILS fail"
echo "Report: $OUT/preflight-report.md"
echo "Draft config fragment (merge into the file made by 'substrate-aks init'): $OUT/installation.draft.json"
[ "$FAILS" -eq 0 ]
