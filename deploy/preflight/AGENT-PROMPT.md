# Prompt to paste into the work agent

Copy everything below the line.

---

You are helping install Agent Substrate (ate-system) onto an EXISTING private AKS cluster, with no
public dependencies. Work from the repo https://github.com/davidmarkgardiner/substrate-aks, branch
`private-aks` (clone it; if it has moved to an internal git server, use that URL). Everything you need
is in `deploy/preflight/`.

## Goal and desired end state
1. All pods in namespace `ate-system` are Ready.
2. The microVM sandbox config is applied and the counter demo actor keeps state across suspend/resume.
3. Later: kagent installed and one A2A call answered by the LLM.
Nothing may be pulled from public registries or fetched from github.com during the install.

## Your job right now: PRE-FLIGHT ONLY
1. Read `deploy/preflight/START-HERE.md` and `deploy/preflight/README.md`.
2. Ask me for the values listed in `deploy/preflight/preflight.env.example`: subscription, resource group
   and name of the existing cluster, trusted registry prefix, mirrored Postgres 18 and python 3.13 image
   references (with digests), storage account and identity names if known, asset directories, and
   internal git mirror URLs. Write them to `deploy/preflight/preflight.env`.
3. Make sure you are logged in with `az login` on a host that can reach the private cluster API.
4. Run `deploy/preflight/preflight.sh`.
5. Report back to me: (a) the full "Gaps to close" table from `report/preflight-report.md`, with each
   suggested fix; (b) the contents of `report/installation.draft.json`; (c) the PASS/WARN/FAIL counts.

## Rules
- `preflight.sh` is read-only. Do NOT fix gaps yourself, and do NOT run `substrate-aks provision`,
  `images`, `install`, `demo` or `destroy` until I say "go".
- Never print, log or commit secrets. If something asks for one, stop and ask me.
- If an image or path is not found, report it. Do not guess another path or pull from the Internet.
- Do not modify my kubeconfig; the script uses a temporary one.
- Quote errors verbatim.

## After I say "go" (not before)
Follow "Stage 2" in `deploy/preflight/README.md`: create `installation.json` with `substrate-aks init`,
merge the draft config, export `SUBSTRATE_AKS_POSTGRES_IMAGE` and `SUBSTRATE_AKS_PROBE_IMAGE`, then run
`substrate-aks check`, `install`, `demo`. Stop and report after each command.
