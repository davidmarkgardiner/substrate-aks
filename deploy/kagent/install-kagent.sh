#!/usr/bin/env bash
# Installs kagent on a substrate-aks cluster (Substrate v1.0.0, microVM) and
# runs an end-to-end test with a GLM model.
#
# Run from a host that can reach the cluster API (the jumpbox, for a private
# cluster) with kubectl, helm, curl and python3. The GLM key is read from
# GLM_API_KEY and stored only in a Kubernetes Secret; Substrate's egress
# gateway injects it, so the agent runtime never holds it.
#
# Every Substrate-side change below was needed to make kagent v1.0.1 work with
# the substrate-aks defaults; see README.md in this directory.
set -euo pipefail

KAGENT_VERSION="${KAGENT_VERSION:-1.0.1}"
NS="${KAGENT_NAMESPACE:-kagent}"
GLM_BASE_URL="${GLM_BASE_URL:-https://api.z.ai/api/anthropic}"
GLM_MODEL="${GLM_MODEL:-GLM-5}"
AGENT="${AGENT_NAME:-substrate-hello}"
: "${GLM_API_KEY:?set GLM_API_KEY}"

log() { printf '\n==> %s\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing $1" >&2; exit 1; }; }
for c in kubectl helm curl python3 openssl; do need "$c"; done

# arg_set DEPLOY INDEX_PREFIX NEW_ARG  -- replace the container arg starting with PREFIX
arg_set() {
  local deploy="$1" prefix="$2" value="$3" idx
  idx=$(kubectl -n ate-system get deploy "$deploy" -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for j,a in enumerate(d['spec']['template']['spec']['containers'][0]['args']):
    if a.startswith('$prefix'): print(j); break")
  [ -n "$idx" ] || { echo "$deploy has no arg $prefix" >&2; exit 1; }
  kubectl -n ate-system patch deploy "$deploy" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/$idx\",\"value\":\"$value\"}]"
  kubectl -n ate-system rollout status deploy/"$deploy" --timeout=300s
}

log "Substrate: let kagent's controller identity call ate-api and the ingress router"
KAGENT_SPIFFE="spiffe://cluster.local/ns/$NS/sa/kagent-controller"
arg_set ate-api-server '--authz-bootstrap-owners=' \
  "--authz-bootstrap-owners=system:serviceaccount:ate-system:ate-client,$KAGENT_SPIFFE"
# kagent sets per-template snapshot locations and golden egress policies, which
# Substrate v1.0.0 gates as previews. ALL is the only value verified to work.
arg_set ate-api-server '--preview=' '--preview=ALL'
arg_set atenet-router '--ingress-allowed-spiffe-ids=' \
  "--ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client,$KAGENT_SPIFFE"

log "Substrate: allow atespace $NS to resolve Secrets in namespace $NS (egress credential injection)"
kubectl -n ate-system patch cm k8s-credential-provider-namespace-policy --type=merge \
  -p "{\"data\":{\"namespace-policy.yaml\":\"policies:\\n- atespace: $NS\\n  allowedNamespaces:\\n  - $NS\\n\"}}"
kubectl -n ate-system rollout restart deploy/k8s-credential-provider
kubectl -n ate-system rollout status deploy/k8s-credential-provider --timeout=180s

log "Namespace $NS, labelled for ate-api access (Substrate NetworkPolicy)"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" ate.dev/api-access=true --overwrite

log "PostgreSQL for kagent"
if ! kubectl -n "$NS" get secret kagent-postgres-owner >/dev/null 2>&1; then
  PW_ADMIN=$(openssl rand -hex 12); PW_OWN=$(openssl rand -hex 12); PW_RW=$(openssl rand -hex 12)
  kubectl -n "$NS" create secret generic kagent-pg-admin --from-literal=password="$PW_ADMIN" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n "$NS" -f "$(dirname "$0")/postgres.yaml"
  kubectl -n "$NS" rollout status deploy/kagent-pg --timeout=300s
  curl -fsSL "https://raw.githubusercontent.com/kagent-dev/kagent/v$KAGENT_VERSION/go/core/pkg/postgressetup/setup.sql" -o /tmp/kagent-setup.sql
  kubectl -n "$NS" cp /tmp/kagent-setup.sql "$(kubectl -n "$NS" get pod -l app=kagent-pg -o name | head -1 | cut -d/ -f2)":/tmp/setup.sql
  kubectl -n "$NS" exec deploy/kagent-pg -- psql -U postgres -d kagent --no-psqlrc --set=ON_ERROR_STOP=1 --single-transaction \
    --set=kagent_schema=kagent --set=kagent_owner_role=kagent_owner --set=kagent_owner_user=kagent_owner_user \
    --set=kagent_owner_password="$PW_OWN" --set=kagent_readwrite_role=kagent_readwrite \
    --set=kagent_readwrite_user=kagent_readwrite_user --set=kagent_readwrite_password="$PW_RW" --file=/tmp/setup.sql
  kubectl -n "$NS" create secret generic kagent-postgres-owner \
    --from-literal=ownerConnectionString="postgres://kagent_owner_user:$PW_OWN@kagent-pg.$NS.svc:5432/kagent?sslmode=disable"
  kubectl -n "$NS" create secret generic kagent-postgres-readwrite \
    --from-literal=readWriteConnectionString="postgres://kagent_readwrite_user:$PW_RW@kagent-pg.$NS.svc:5432/kagent?sslmode=disable"
fi

log "GLM credentials (Secret only; never on a command line)"
kubectl -n "$NS" create secret generic kagent-glm --from-literal=ANTHROPIC_API_KEY="$GLM_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

log "kagent $KAGENT_VERSION (microvm WorkerPool)"
WORKER_IMAGE=$(kubectl get workerpools -A -o jsonpath='{.items[?(@.spec.sandboxClasses[0].name=="microvm")].spec.workerImage}' | awk '{print $1}')
[ -n "$WORKER_IMAGE" ] || { echo "no microvm workerImage found; install substrate-aks with --with-demo" >&2; exit 1; }
helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds --version "$KAGENT_VERSION" -n "$NS"
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version "$KAGENT_VERSION" -n "$NS" \
  --set providers.default=openAI --set providers.openAI.apiKey=unused \
  --set controller.substrateClientCertificate.enabled=true \
  --set substrateWorkerPool.create=true --set substrateWorkerPool.sandboxClass=microvm \
  --set substrateWorkerPool.workerImage="$WORKER_IMAGE" \
  --set harnesses.enabled=true --set harnesses.snapshotLocation="azblob://snapshots/kagent/" \
  --timeout 10m
kubectl -n "$NS" rollout status deploy/kagent-controller --timeout=300s

log "GLM model, egress policy, agent"
kubectl apply -f - <<YAML
apiVersion: api.kagent.dev/v1alpha3
kind: ModelConfig
metadata: {name: glm-model-config, namespace: $NS}
spec:
  provider: Anthropic
  model: $GLM_MODEL
  apiKeySecret: kagent-glm
  apiKeySecretKey: ANTHROPIC_API_KEY
  anthropic:
    baseUrl: $GLM_BASE_URL
---
apiVersion: api.kagent.dev/v1alpha3
kind: EgressPolicy
metadata: {name: allow-glm, namespace: $NS}
spec:
  destinations:
  - origin: ${GLM_BASE_URL%/api/anthropic}
---
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata: {name: $AGENT, namespace: $NS}
spec:
  harnessRef: {name: kagent-default}
  egressPolicyRefs: [{name: allow-glm}]
  template:
    inline:
      description: Hello agent running as a Substrate microVM actor on AKS
      systemPrompt: You are a concise assistant.
      modelConfig: {name: glm-model-config}
YAML
for _ in $(seq 1 60); do
  [ "$(kubectl -n "$NS" get agent "$AGENT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] && break
  sleep 5
done
kubectl -n "$NS" get agent "$AGENT" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}{"\n"}'

log "End-to-end A2A call"
kubectl -n "$NS" port-forward svc/kagent-controller 18083:8083 >/tmp/kagent-pf.log 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT; sleep 4
MSG="e2e-$(date +%s)"   # a retry must reuse the same messageId
BODY="{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"SendMessage\",\"params\":{\"message\":{\"messageId\":\"$MSG\",\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"Reply with exactly: GLM on private Substrate microVM OK\"}]}}}"
for _ in $(seq 1 12); do
  curl -sS --max-time 170 -X POST "http://localhost:18083/agents/$NS/$AGENT" -H 'X-User-Id: e2e' \
    -H 'A2A-Version: 1.0' -H 'Content-Type: application/json' -d "$BODY" -o /tmp/a2a.json || true
  grep -q '"result"' /tmp/a2a.json 2>/dev/null && break
  sleep 8
done
python3 - <<'PY'
import json,sys
t=json.load(open('/tmp/a2a.json')).get('result',{}).get('task',{})
state=t.get('status',{}).get('state')
art=[p.get('text') for a in t.get('artifacts',[]) for p in a.get('parts',[])]
msg=[p.get('text') for p in t.get('status',{}).get('message',{}).get('parts',[])]
print('state:',state); print('artifacts:',art); print('status message:',msg)
sys.exit(0 if state=='TASK_STATE_COMPLETED' else 1)
PY
