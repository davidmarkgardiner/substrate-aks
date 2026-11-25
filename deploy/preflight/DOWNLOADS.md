# Artifact downloads (for the Nexus import forms)

Every URL below was checked on 2026-11-25 and returns HTTP 200. Sizes and checksums are from that check.
These are **plain files**, the same kind of request as importing a binary such as `runsc`.
Container images are not here: they go through the image import (`import-list.csv`).

## A. Needed for the install

| # | Artifact | URL | Size | Checksum / identity | Used for |
|---|---|---|---|---|---|
| 1 | Cloud Hypervisor v53.0 | https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v53.0/cloud-hypervisor-static | 7 MB | sha256 `448af3d4e59b22c2987f7df94c213ad40fb53a10d437e42b5ee6c4fce7c29ecc` | becomes asset file `cloud-hypervisor` (rename, mode 755) |
| 2 | Kata Containers 4.3.1 static | https://github.com/kata-containers/kata-containers/releases/download/4.3.1/kata-static-4.3.1-amd64.tar.zst | 1.02 GB | none published here; the three extracted files are checked below | source of `vmlinux`, `rootfs.img`, `virtiofsd` |
| 3 | Substrate source at the pinned commit | https://github.com/agent-substrate/substrate/archive/b34fbee742906494b5eb4f1f36987176bf8770a4.tar.gz | 26 MB | commit `b34fbee742906494b5eb4f1f36987176bf8770a4` (see note) | installer source, SandboxConfig template, `ate-setup` |
| 4 | Azure Blob plugin source at the pinned commit | https://github.com/agent-substrate-plugins/objectstore-azure-blob/archive/5639af04ad429cf51d2dbf452c80709d3b68e48b.tar.gz | 82 KB | commit `5639af04ad429cf51d2dbf452c80709d3b68e48b` | plugin manifests and the plugin image build |
| 5 | This fork, branch `private-aks` | https://github.com/davidmarkgardiner/substrate-aks/archive/refs/heads/private-aks.tar.gz (or `.zip`) | small | branch tip changes; record the commit you imported | installer, preflight, docs |

## B. Needed for the build and the kagent step

| # | Artifact | URL | Size | Checksum | Used for |
|---|---|---|---|---|---|
| 6 | Go 1.27.3 toolchain, linux/amd64 | https://go.dev/dl/go1.27.3.linux-amd64.tar.gz | 71 MB | sha256 `65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40` | running `ate-setup`, building the installer |
| 7 | kagent database setup SQL, tag v1.0.1 | https://raw.githubusercontent.com/kagent-dev/kagent/v1.0.1/go/core/pkg/postgressetup/setup.sql | 6 KB | sha256 `ed02e38bd6ae05c6ac9b374610d3728bdb9c8749e238e358b92a146cd1184f59` | kagent Postgres schema (save as `kagent-setup.sql`) |
| 8 | kagent Helm charts (OCI artifacts, not file URLs) | `ghcr.io/kagent-dev/kagent/helm/kagent:1.0.1` and `ghcr.io/kagent-dev/kagent/helm/kagent-crds:1.0.1` | small | n/a | add to the **image import** if it accepts OCI artifacts; otherwise run `helm pull` on a connected machine |

## C. After the files are in Nexus

**Asset directory (the four files).** On a Linux host with `zstd` and `tar`:
```bash
mkdir kata && zstd -d -c kata-static-4.3.1-amd64.tar.zst | tar -x -C kata
mkdir microvm-assets
cp -L kata/opt/kata/share/kata-containers/vmlinux.container microvm-assets/vmlinux
cp -L kata/opt/kata/share/kata-containers/kata-containers.img microvm-assets/rootfs.img
cp -L kata/opt/kata/libexec/virtiofsd microvm-assets/virtiofsd
cp cloud-hypervisor-static microvm-assets/cloud-hypervisor
chmod 755 microvm-assets/virtiofsd microvm-assets/cloud-hypervisor
cd microvm-assets && sha256sum cloud-hypervisor virtiofsd vmlinux rootfs.img
```
The four sums must equal the table in `SOURCE-AND-ASSETS.md` (`448af3d4…`, `15b2e72a…`, `f87d8359…`, `6770db2c…`).
The extraction paths follow the upstream installer's own code, but I have not run these exact commands: the sums decide.

**Source archives are not git repos.** The installer fetches source with `git fetch <url> <commit>` and then checks that `HEAD` is the pinned commit. A tar.gz has no history, so unpacking it does not satisfy that check today. Items 3 and 4 do carry the pinned commit ID inside the archive (verified with `git get-tar-commit-id`), so we can prove what you imported. To use them the installer needs a "source from archive" mode, which does not exist yet. Until it does, source must come from a real git remote (`SOURCE-AND-ASSETS.md`, section 1).

## D. Not covered by file downloads
- **Go module dependencies.** The installer's own Go dependencies are not vendored, and the azure-blob plugin image build downloads Go modules. Either point `GOPROXY` at a Nexus Go proxy, or build those two things in a connected stage.
- **The two images we build** (`azure-blob` plugin, `counter`): built with ko, then imported like any other image.
- **`runsc` / gVisor:** not needed for the microVM install. The gVisor worker image is in `import-list.csv`.
