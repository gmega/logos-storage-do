# Logos Storage v0.2 — Mix-Proxy network on DigitalOcean

Deploys the **Mix-Proxy (MP) network** for Logos Storage v0.2: four MP nodes,
one DigitalOcean droplet each, managed with **Terraform** and provisioned with
**Ansible**. After the network is up, the two global config artifacts are
published to a public DigitalOcean Spaces bucket:

- `mix-pool.json` — merged mix relay pool (all MP nodes)
- `tcp-sprs.txt` / `tcp-sprs.json` — the MP nodes' TCP SPRs (one per node)

These are what the Regular Storage (RS) nodes need to route their queries
through the mix network. See [infra-logos#25](https://github.com/status-im/infra-logos/issues/25)
and the [reference harness](https://github.com/gmega/logos-storage-runner).

Two Regular Storage nodes (stage 2) are also deployed: each consumes the MP artifacts
(mix-pool + the MP TCP SPRs as `dht-mix-proxy`) and is preloaded with content —
Jarrad's book and a randomly generated 200 MB file (`ansible/rs-playbook.yml`).

## Architecture

```
              Terraform                         Ansible
  ┌─────────────────────────────┐   ┌────────────────────────────────────┐
  │ 4x droplet (fra1, 4vcpu/8gb) │   │ build logoscore + lgpm + storage   │
  │ cloud firewall 22,8080       │──▶│ module (Nix), run logoscore daemon │
  │ Spaces bucket                │   │ as systemd service, start MP node  │
  │ -> ansible/inventory.ini     │   │ export mix info + SPRs             │
  └─────────────────────────────┘   └────────────────┬───────────────────┘
                 ▲                                    │ fetch
                 │ publish mix-pool.json, tcp-sprs.*  ▼
          ┌──────┴───────────────┐         artifacts/ (merged on controller)
          │ Spaces (public-read) │◀────────────────────
          └──────────────────────┘
```

Node 1 is the bootstrap (`no-bootstrap-node: true`); nodes 2–4 bootstrap off
node 1's TCP SPR. All nodes run with `mix-enabled: true` and join the mix pool.

## Repo layout

```
terraform/        Droplets, firewall, Spaces bucket + object uploads, inventory
  templates/      Ansible inventory template (rendered from droplet data)
ansible/
  playbook.yml    MP: build → bootstrap → followers → export → merge
  rs-playbook.yml RS: build → configure (mix-pool/dht-mix-proxy) → preload
  verify-playbook.yml Service/version/DHT checks, public artifacts, RS transfer
  roles/storage_node/  build / run / run_rs / export / preload + templates
  tasks/merge.yml Controller-side merge into the published artifacts
  files/          Vendored mix_helper.py (from the reference harness)
scripts/
  env.sh          Loads DIGITALOCEAN_ACCESS_TOKEN + Spaces creds
  00-spaces-key.sh  Mints a Spaces key -> scripts/.spaces.env
  deploy.sh       One-shot: tf apply → ansible → tf apply (publish)
  destroy.sh      Tear everything down
artifacts/        Generated at deploy time (gitignored)
```

## Prerequisites

- `DO_TOKEN` exported (DigitalOcean API token) — already present in this shell.
- SSH key **`giulianos-public-key-2`** registered in the DO account, with the
  matching private key at `~/.ssh/id_ed25519-2` (used by Ansible).
- `terraform`, `doctl`, and `jq` on PATH (`doctl` creates the Spaces key).
- A conda env with Ansible (kept out of the global/base env):

  ```bash
  # conda-forge avoids the Anaconda channel ToS prompt.
  conda create -y -n logos-storage-do -c conda-forge --override-channels python=3.12
  conda activate logos-storage-do
  pip install "ansible-core>=2.16"
  # Provides the log_plays callback (ansible.cfg) that writes logs/<host>.
  ansible-galaxy collection install community.general
  ```

  `scripts/conda.sh` finds the conda install (`$CONDA_EXE`, `~/miniconda3`,
  `~/anaconda3`, `~/miniforge3`, `~/mambaforge`, `/opt/conda`) and activates
  that env; `deploy.sh` and `restart.sh` source it.

## Configuration

Edit `terraform/terraform.tfvars` to change region, size, node count, SSH key,
bucket name, or version prefix. Defaults:

| Variable        | Default                  |
|-----------------|--------------------------|
| `region`        | `fra1`                   |
| `droplet_size`  | `s-4vcpu-8gb`            |
| `node_count`    | `4`                      |
| `ssh_key_name`  | `giulianos-public-key-2` |
| `bucket_name`   | `logos-storage-network`  |
| `version_prefix`| `v0.2`                   |

Set `storage_module_ref` and `libstorage_ref` in
`ansible/roles/storage_node/defaults/main.yml` to select the module release and
its logos-storage dependency branch (or full tag ref). The Nix build overrides
the module’s `logos-storage` input, including submodules.

Published object keys are namespaced under the version prefix, e.g.
`v0.2/mix-pool.json`.

## Deploy

```bash
source scripts/env.sh        # DO token + Spaces creds (mints key on first run)
scripts/deploy.sh            # tf apply → ansible → tf apply (publish)
```

Or run the stages manually:

```bash
scripts/00-spaces-key.sh        # create the Spaces key -> scripts/.spaces.env (once)
source scripts/env.sh           # load DO token + Spaces creds

cd terraform && terraform init && terraform apply        # droplets + firewall + bucket + inventory
cd ../ansible && ansible-playbook playbook.yml           # build + run + export
cd ../terraform && terraform apply                       # publish artifacts
```

> The Nix builds compile Nim from source and can take a long time on a cold
> cache (tens of minutes per node, run in parallel). The Ansible build step
> allows up to 4h per build (`nix_build_timeout`).

Deployment finishes by verifying services, module versions, TCP addresses, DHT
peers, and public artifacts. With at least two RS nodes, it also downloads the
first RS node's 1 MiB verification sample on the second and compares SHA-256 hashes.
Both RS nodes must have private queries enabled. The downloaded verification
file is saved as `/opt/logos/verify-transfer.bin` on the second RS node.

## Result

```bash
cd terraform && terraform output
```

Public URLs (after the publish apply):

- `https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/mix-pool.json`
- `https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/tcp-sprs.txt`
- `https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/tcp-sprs.json`

## Regular Storage node

`deploy.sh` provisions the RS node(s) automatically after the MP artifacts
exist. To (re-)run just the RS stage:

```bash
source scripts/env.sh
cd ansible && ansible-playbook rs-playbook.yml
```

It builds the same toolchain, writes an RS `config.json` (`mix-pool` +
`dht-mix-proxy` from the MP TCP SPRs, bootstrapped off node 1's TCP SPR), starts
the node, and preloads it with the book + a 200 MB random file via `uploadUrl`.
The number of RS nodes is `rs_node_count` (default 2) in `terraform.tfvars`.
Confirm the preloaded content with:

```bash
ssh root@<rs-ip> '/opt/logos/build/logos/bin/logoscore \
  --config-dir=/var/lib/logoscore call storage_module manifests' | jq
```

## Teardown

```bash
source scripts/env.sh
scripts/destroy.sh                # droplets + firewall + bucket + objects
scripts/destroy.sh --delete-key   # also delete the minted Spaces key
```

## Notes & assumptions

- **Versions** (from infra-logos#25): logos-core CLI `master`, package manager
  `master`, storage module `v2.1.3`, libstorage `feat/mix-transport`. Tunable in
  `ansible/roles/storage_node/defaults/main.yml`.
- **Ports**: `8080/tcp` (libp2p and KadDHT), `22/tcp` (SSH).
  Kept in sync between the Terraform firewall and the node config.
- **NAT**: droplets have public IPs directly, so `nat: extip:<public-ip>` and
  `listen-ip: <public-ip>`.
- **Readiness**: a node is considered up once `debug` returns a non-null TCP
  SPR in `result.value.spr`.
- **Spaces credentials**: the DO API token cannot create buckets or upload
  objects (that's the S3 data plane), which need separate Spaces access keys.
  The key is created out-of-band by `scripts/00-spaces-key.sh` (`doctl`) and
  passed to Terraform as the `SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY`
  env vars. It lives only in `scripts/.spaces.env` (gitignored); nothing secret
  is committed.
