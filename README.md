# Logos Storage v0.2 — Mix-Proxy network on DigitalOcean

Deploys the **Mix-Proxy (MP) network** for Logos Storage v0.2: four MP nodes,
one DigitalOcean droplet each, managed with **Terraform** and provisioned with
**Ansible**. After the network is up, the two global config artifacts are
published to a public DigitalOcean Spaces bucket:

- `mix-pool.json` — merged mix relay pool (all MP nodes)
- `tcp-sprs.txt` / `tcp-sprs.json` — the MP nodes' TCP SPRs (one per node)
- `udp-sprs.txt` / `udp-sprs.json` — the MP nodes' UDP SPRs (one per node)

These are what the Regular Storage (RS) nodes (stage 2, out of scope here) need
to route mix queries. See [infra-logos#25](https://github.com/status-im/infra-logos/issues/25)
and the [reference harness](https://github.com/gmega/logos-storage-runner).

## Architecture

```
              Terraform                         Ansible
  ┌─────────────────────────────┐   ┌────────────────────────────────────┐
  │ 4x droplet (fra1, 4vcpu/8gb) │   │ build logoscore + lgpm + storage   │
  │ cloud firewall 22,8080,8090  │──▶│ module (Nix), run logoscore daemon │
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
node 1's UDP SPR. All nodes run with `mix-enabled: true` and join the mix pool.

## Repo layout

```
terraform/        Droplets, firewall, Spaces bucket + object uploads, inventory
  templates/      Ansible inventory template (rendered from droplet data)
ansible/
  playbook.yml    5 phases: build → bootstrap → followers → export → merge
  roles/mp_node/  build / run / export / get_udp_spr tasks + templates
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
- SSH key **`giulianos-public-key`** registered in the DO account, with the
  matching private key at `~/.ssh/id_ed25519` (used by Ansible).
- `terraform`, `doctl`, and `jq` on PATH (`doctl` creates the Spaces key).
- A conda env with Ansible (kept out of the global/base env):

  ```bash
  conda create -y -n logos-storage-do python=3.12
  conda activate logos-storage-do
  pip install "ansible-core>=2.16"
  ```

## Configuration

Edit `terraform/terraform.tfvars` to change region, size, node count, SSH key,
bucket name, or version prefix. Defaults:

| Variable        | Default                  |
|-----------------|--------------------------|
| `region`        | `fra1`                   |
| `droplet_size`  | `s-4vcpu-8gb`            |
| `node_count`    | `4`                      |
| `ssh_key_name`  | `giulianos-public-key`   |
| `bucket_name`   | `logos-storage-network`  |
| `version_prefix`| `v0.2`                   |

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

## Result

```bash
cd terraform && terraform output
```

Public URLs (after the publish apply):

- `https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/mix-pool.json`
- `https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/tcp-sprs.txt`
- `https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/tcp-sprs.json`
- `https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/udp-sprs.txt`
- `https://logos-storage-network.fra1.digitaloceanspaces.com/v0.2/udp-sprs.json`

## Teardown

```bash
source scripts/env.sh
scripts/destroy.sh                # droplets + firewall + bucket + objects
scripts/destroy.sh --delete-key   # also delete the minted Spaces key
```

## Notes & assumptions

- **Versions** (from infra-logos#25): logos-core CLI `master`, package manager
  `master`, storage module `v1.2.0`, libstorage `v0.4.0-rc4`. Tunable in
  `ansible/roles/mp_node/defaults/main.yml`.
- **Ports**: `8080/tcp` (libp2p listen), `8090/udp` (discovery), `22/tcp` (SSH).
  Kept in sync between the Terraform firewall and the node config.
- **NAT**: droplets have public IPs directly, so `nat: extip:<public-ip>` and
  `listen-ip: <public-ip>`.
- **Readiness**: a node is considered up once `Started Storage node` appears in
  `/var/log/logoscore.log`.
- **Spaces credentials**: the DO API token cannot create buckets or upload
  objects (that's the S3 data plane), which need separate Spaces access keys.
  The key is created out-of-band by `scripts/00-spaces-key.sh` (`doctl`) and
  passed to Terraform as the `SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY`
  env vars. It lives only in `scripts/.spaces.env` (gitignored); nothing secret
  is committed.
