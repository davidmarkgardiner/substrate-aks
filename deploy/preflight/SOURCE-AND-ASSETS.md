# Unblocking "cannot connect to GitHub": the source and the four asset files

**Blocker the agent hit:** "I tried to fetch the pinned Substrate source but this environment cannot connect to GitHub."

**Short answer: the install needs both things below. The asset directory alone is not enough.**
`substrate-aks install` runs `git fetch --depth=1 <github url> <commit>` for the Substrate source
and the Azure Blob plugin source on every install, and reads the microVM SandboxConfig template and
runs `go run ./cmd/ate-setup` from that checkout. So the source must be reachable even when the
four asset files are already in a directory.

Do the steps in section 1 and 2 on a **connected** machine, carry the results across your normal
transfer process, then do section 3 on the **install host**.

## 1. Source mirrors (git)
| Repo | Pinned commit |
|---|---|
| `https://github.com/agent-substrate/substrate.git` (tag `v1.0.0`) | `b34fbee742906494b5eb4f1f36987176bf8770a4` |
| `https://github.com/agent-substrate-plugins/objectstore-azure-blob.git` | `5639af04ad429cf51d2dbf452c80709d3b68e48b` |

Connected machine:
```bash
git clone --mirror https://github.com/agent-substrate/substrate.git substrate.git
git clone --mirror https://github.com/agent-substrate-plugins/objectstore-azure-blob.git objectstore-azure-blob.git
for r in substrate.git objectstore-azure-blob.git; do git -C $r config uploadpack.allowAnySHA1InWant true; done
tar czf source-mirrors.tgz substrate.git objectstore-azure-blob.git
```
Install host (extract to e.g. `/opt/mirrors`, or push both repos to your internal git server, which
must allow fetch-by-SHA):
```bash
tar xzf source-mirrors.tgz -C /opt/mirrors
git config --global url."/opt/mirrors/substrate.git".insteadOf "https://github.com/agent-substrate/substrate.git"
git config --global url."/opt/mirrors/objectstore-azure-blob.git".insteadOf "https://github.com/agent-substrate-plugins/objectstore-azure-blob.git"
# if git says "dubious ownership":  git config --global --add safe.directory '*'
```
A tarball-only artifact repository (Artifactory generic, a blob container) is fine as the *transport*,
but the install host still needs it unpacked into a git repo like the above. The installer fetches
over git, not from an archive.

If the cached `source-*` directory in the installation folder predates the mirror, delete it.

## 2. The four runtime asset files (amd64)
They must be regular files with exactly these names and checksums. The installer refuses anything else.

| File | sha256 |
|---|---|
| `cloud-hypervisor` | `448af3d4e59b22c2987f7df94c213ad40fb53a10d437e42b5ee6c4fce7c29ecc` |
| `virtiofsd` | `15b2e72a78cc08a9bd8a6943e89fb69c88cb3cbeb63069efceade835342ac7d4` |
| `vmlinux` | `f87d8359035cb7557b16a319e6431ea09b183e62268aef436bf8dc6530d786b6` |
| `rootfs.img` | `6770db2cca5710593f27c9ac5e1d9d7aab836422695a5e5c4807496a92a0f24d` |

**Easiest route (connected machine, needs Go and the Substrate mirror from step 1):**
```bash
git clone substrate.git substrate-src && cd substrate-src && git checkout b34fbee742906494b5eb4f1f36987176bf8770a4
go run ./cmd/ate-setup publish microvm-assets \
  manifests/ate-install/sandboxconfig-microvm.yaml.tmpl /abs/path/microvm-assets amd64 \
  --no-dev-env --no-report-defaults
```
This downloads the Kata tarball (about 1 GB) and Cloud Hypervisor from GitHub, extracts the files and
verifies their checksums for you.

**Manual route (same result):**
- `https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v53.0/cloud-hypervisor-static`
  saved as `cloud-hypervisor` (mode 755). Its sha256 was checked against the pin above.
- `https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-amd64.tar.zst`,
  then take (following the symlinks to the real files): `opt/kata/share/kata-containers/vmlinux.container` as `vmlinux`,
  `opt/kata/share/kata-containers/kata-containers.img` as `rootfs.img`, `opt/kata/libexec/virtiofsd` as `virtiofsd` (mode 755).

Verify wherever the files land: `cd <dir> && sha256sum cloud-hypervisor virtiofsd vmlinux rootfs.img`
and compare with the table.

## 3. Wire it up on the install host
1. Put the four files in a directory, for example `/opt/microvm-assets`.
2. Set `ASSETS_DIR=/opt/microvm-assets` in `preflight.env`, and `substrate.runtime.assetsDir` in `installation.json` (absolute path).
3. Set `GIT_MIRROR_SUBSTRATE` and `GIT_MIRROR_PLUGIN` in `preflight.env` if you use an internal git server (leave blank to test the `insteadOf` rewrite).
4. Re-run `./preflight.sh`. The `git.substrate`, `git.plugin` and `assets.*` rows should turn PASS.

## Message to send the work agent
> The install needs two things, not one. (1) Git mirrors of the two pinned repos, wired in with git `insteadOf`
> (`deploy/preflight/SOURCE-AND-ASSETS.md`, section 1). (2) A directory with the four checksum-pinned asset files
> (section 2). I will provide both. Until they exist, stop at the preflight gaps report; do not retry GitHub.
