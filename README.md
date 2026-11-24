# Logos Storage v0.4 on DigitalOcean

Terraform manages four provider (MP) droplets, two regular storage (RS) droplets,
a Spaces bucket, and firewalls. Ansible installs precompiled portable binaries,
starts the network and verifies discovery plus an RS-to-RS content transfer.

Nodes learn Mix relays, DHT proxies, AutoNAT servers and circuit relays through
service discovery. Only bootstrap SPRs are supplied statically. MP nodes advertise
all four services (`mix-enabled`, `dht-proxy-server`, `autonat-server`,
`relay-server`). RS nodes use discovery to find DHT proxies and relays.

## Deploy

Requirements: Terraform, jq, Python 3, OpenSSL, curl, doctl, an SSH key registered
in DigitalOcean, and the `logos-storage-do` conda environment with Ansible.
`scripts/conda.sh` locates that environment. Set `DO_TOKEN` (or
`DIGITALOCEAN_ACCESS_TOKEN`); Spaces credentials live in the ignored
`scripts/.spaces.env` and are created by `scripts/00-spaces-key.sh` if needed.

MP1 through MP4 run in New York, London, Amsterdam and Singapore, respectively.
RS1 runs in Toronto and RS2 in Frankfurt. The dashboard displays each node’s
location beside its name. The region assignments are in `terraform/main.tf`.
Configure the Spaces region, droplet sizes and counts in `terraform/terraform.tfvars`.
Additional nodes use the Spaces region by default.
The configured SSH key is `giulianos-public-key-2`, with the private key at
`~/.ssh/id_ed25519-2`. Then run:

```bash
scripts/deploy.sh
scripts/deploy.sh --force   # explicitly allow the same version again
```

The deployment resolves the newest **published** `storage_module` release by
publication time from the [dev catalog](https://github.com/logos-co/logos-modules-dev).
It pins its complete version, download URL and SHA-256 once, in
`artifacts/release.json`, for every node. A release without Linux AMD64 is refused;
it does not silently fall back to an older version. A build still running in
Actions is not yet a published release.

Before changing infrastructure or nodes, it compares that version with the
bucket's root `metadata.json`, whose global `version` field records the last
successfully verified deployment. An identical version is refused unless
`--force` is passed. Network/authentication errors are fatal; only HTTP 404 means
there is no prior metadata. Metadata is updated after node versions, discovery,
public bootstrap artifacts and the transfer test pass. Failed deployments leave
the previous successful version in place and can be retried.

Portable `logosctl` 0.3.2 is pinned by SHA-256 in the storage role defaults.
The AppImage is extracted so droplets do not need FUSE or Nix. The bundled storage module and package downloader are preserved outside the
runtime scan path: CLI 0.3.2 otherwise starts its own storage node automatically.
Ansible downloads packages, and the package manager installs local LGX files.
The package is
installed into `/var/lib/logoscore` using its package manager. The systemd service
keeps the name `logoscore` for operational continuity, but runs `logosctl`.

```bash
terraform -chdir=terraform output
ssh root@NODE 'logosctl --config-dir=/var/lib/logoscore call storage_module debug'
scripts/restart.sh
```

## Dashboard

The bootstrap droplet serves the dashboard on HTTPS port 443. No extra droplet
is required. Run `terraform -chdir=terraform output -raw dashboard_url` for its URL.

The dashboard is public; no login is required. Both the page and
`/health.json` expose node addresses, versions, peer connections and debug data.
Dashboard v1.1 allows downloading two fixed datasets directly or via Mix, and deleting their local storage copies except on RS1.
A compromise of the host itself is more serious: it also runs the bootstrap
storage node. The dashboard SSH key permits snapshots, fixed file operations and name lookups.

With no DNS name configured, HTTPS uses a self-signed certificate containing the
droplet IP. The public certificate is saved in `scripts/.dashboard/server.crt`.
Previously generated basic-auth passwords are no longer used.

The dashboard shows runtime health, exact deployed version, DHT peers,
connections, NAT status and discovered providers by service. Expand a provider
section to inspect peer addresses and last-seen timestamps; the full debug
response is also available. Empty discovery tables are marked incomplete and
snapshots older than 90 seconds are marked stale.

A systemd timer refreshes snapshots every 30 seconds. The collector runs as the
unprivileged `logos-dashboard` user. Its dedicated SSH key is restricted on each
node to a forced command that validates file IDs and operations, with forwarding disabled and source IP
restricted to the dashboard host. SSH host keys are pinned through Ansible.
No daemon control port is exposed publicly.

The dashboard playbook publishes `Farewell to Westphalia` and `Random 200MB`
from RS1 using the same dataset CIDs as the file catalog. Each publication
uses sequence number zero so the module selects the sequence number. In RS1’s
**Name Service** panel, use **Copy CID** beside a label. Paste that name CID
into another node’s **Name Service** panel and select **Resolve** to look up
the dataset CID from that node. A new publication can take time to reach peers.

Each node card has selectable random-file and book entries. Green/red presence is
based on CID membership in manifests; gray means the snapshot is unavailable.
Downloads are asynchronous: the node downloads the dataset, the dashboard copies
and verifies its SHA-256, and the browser opens the PDF or saves the random binary.
The download tab shows node-side bytes and percentage, sampled from the output
file every two seconds, then separate verification and dashboard-copy stages.
Progress is reported over SSH stderr, separately from the file bytes.
The completion link remains available for 15 minutes. Mix uses `isPrivate=true`
and `advertise=false`; cached data can satisfy either mode. Delete waits for the
manifest to disappear. RS1 deletion is blocked in both the API and the node command.

The unprivileged file service allows two jobs at once, one per node, and at most
eight retained jobs (up to 1.6 GiB of file data). Nginx limits job submissions to
six per minute per IP and four concurrent API requests at 1 MiB/s each. These
bounds reduce abuse but are not a hard spending cap for a public service.
No cloud provisioning credentials are used by the dashboard. File API logs are
in `journalctl -u logos-dashboard-files`.


```bash
cd ansible
ansible-playbook dashboard-playbook.yml -e @../artifacts/release.json
```

## Join Devnet

The portal’s `/join` page offers installers for Linux x86-64 and macOS 14+ on Apple Silicon, each with the native TUI and node runtime using the standalone installer in the public devnet bucket. The public filenames are `install-linux-x86_64.sh` and `install-macos-arm64.sh`. To publish a new installer, extract `install.sh` from the reviewed platform-specific GitHub Actions bundle and run this command from the repository root:

```bash
scripts/publish-join-installer.sh /path/to/extracted/install.sh
```

To update the portal pages and routes on an existing dashboard, run `ansible-playbook dashboard-playbook.yml --tags portal --limit mp_bootstrap` from `ansible/`.

## Bootstrap artifacts and client configuration

The bucket publishes `v0.4/tcp-sprs.json` and `v0.4/tcp-sprs.txt` as bootstrap
records. It no longer publishes or consumes a static mix pool. The root
`metadata.json` is independent of this namespace.

```bash
scripts/gen_config.sh json ./logos-storage-data
scripts/gen_config.sh toml ./logos-storage-data   # requires Python tomli-w
```

Set `ARTIFACT_URL` to use a different bucket/prefix. Existing old `v0.2` URLs
are not the configuration source for v0.4 clients.

## Validation and operations

```bash
python3 -m unittest discover -s tests -v
terraform -chdir=terraform validate
source scripts/conda.sh
cd ansible
ansible-playbook verify-playbook.yml -e @../artifacts/release.json
```

Verification waits for all four service provider tables to populate and checks
that nodes run the same storage revision. A 1 MiB sample uploaded to the first RS
node is downloaded by the second and checked by SHA-256. Book and 200 MiB sample
preloads remain part of the RS deployment.

Node logs are in `/var/lib/logoscore/logs/` and systemd's `logoscore` journal.
Collector logs are in `journalctl -u logos-dashboard.service`.
`scripts/destroy.sh` tears down the Terraform-managed network and bucket;
`--delete-key` also removes the minted Spaces key.
