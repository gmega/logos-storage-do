# Logos Storage - Private Devnet

This repository contains a self-contained Logos Storage devnet for the Digital Ocean platform. It includes storage nodes and mix relays, as well as a portal and dashboard. It's been mostly generated with AI.

----

## Network

The v0.4 devnet runs six DigitalOcean droplets. Terraform creates the infrastructure and generates the Ansible inventory. Ansible installs the storage module, starts the nodes, and publishes their bootstrap records.

| Node | Location | Role |
| --- | --- | --- |
| logos-mp-1 | New York (`nyc3`) | Bootstrap, service provider, and dashboard host |
| logos-mp-2 | London (`lon1`) | Service provider |
| logos-mp-3 | Amsterdam (`ams3`) | Service provider |
| logos-mp-4 | Singapore (`sgp1`) | Service provider |
| logos-rs-1 | Toronto (`tor1`) | Regular storage, source datasets, and name publisher |
| logos-rs-2 | Frankfurt (`fra1`) | Regular storage and transfer verification |

MP1 starts with an empty bootstrap list. The other droplets bootstrap from MP1’s signed peer record (SPR) over TCP port 8080. Joining clients receive the TCP records for all four MP nodes. Nodes discover Mix relays, DHT proxies, AutoNAT servers, and circuit relays through the network.

## Join the devnet

Open **Join Devnet** on the dashboard and run the installer for your platform. The page lists the prerequisites and provides a link to inspect each script. [Join Devnet](https://104.236.228.87/join)

| Platform | Installer |
| --- | --- |
| Linux x86-64 | [install-linux-x86_64.sh](https://logos-storage-network.fra1.digitaloceanspaces.com/v0.4/install-linux-x86_64.sh) |
| macOS 14+ on Apple Silicon | [install-macos-arm64.sh](https://logos-storage-network.fra1.digitaloceanspaces.com/v0.4/install-macos-arm64.sh) |

Run the executable printed by the installer and use **Start** to launch your node. New local nodes listen on port 8090. To refresh an existing installation after the network moves, rerun the installer and restart the local node. The default install directory is `~/.local/share/logos-devnet`. You can override it with `LOGOS_DEVNET_HOME`.

For a standalone storage client, generate a config from the published TCP records. The JSON and TOML commands write to stdout. TOML output requires the Python package `tomli-w`.

```bash
scripts/gen_config.sh json ./logos-storage-data > config.json
```

Use `toml` in place of `json` for TOML, or set `ARTIFACT_URL` to another bucket and prefix. The public bootstrap records are available as [JSON](https://logos-storage-network.fra1.digitaloceanspaces.com/v0.4/tcp-sprs.json) or [one record per line](https://logos-storage-network.fra1.digitaloceanspaces.com/v0.4/tcp-sprs.txt).

## Dashboard

The public HTTPS dashboard on MP1 refreshes node health every 30 seconds. Each card shows the node’s location, connections, DHT peers, and discovered providers. Expand **Detailed status** for the storage module’s debug response. Snapshots older than 90 seconds are marked stale. [Network health](https://104.236.228.87/)

- **Files.** Select the book or the 200 MiB random file and download it directly or via Mix. The presence indicator checks for the dataset CID in that node’s manifests. The download page estimates speed separately for the node download and the copy to the dashboard. Both stages verify SHA-256. Cached data can satisfy either mode. A completed file is available for 15 minutes.
- **Delete.** Removes the selected dataset from that node’s storage. RS1 retains the source copies. The file API and the node both enforce this restriction.
- **Name Service.** Use **Copy CID** beside `Farewell to Westphalia` or `Random 200MB` on RS1. Paste the name CID into another node’s **Resolve** field to retrieve its current dataset CID.

The dashboard and its APIs allow anonymous access. The file service runs at most two jobs at once and one per node. Nginx rate-limits job submissions and name lookups, and limits the concurrent requests and bandwidth on job status and content routes. Peers downloading directly over the storage network bypass these dashboard limits.

## Deploy

Run the commands below from the repository root on the deployment machine. You need Bash, Terraform 1.5+, `flock`, `jq`, Python 3, curl, OpenSSH, `doctl`, and a Conda environment containing Ansible. The scripts activate `logos-storage-do` by default. Set `CONDA_ENV` to use another environment.

Export `DO_TOKEN` or `DIGITALOCEAN_ACCESS_TOKEN`. The deployment uses a separate Spaces access key for bucket operations. The key helper creates `scripts/.spaces.env` if needed. The configured SSH key is `giulianos-public-key-2` in DigitalOcean, with the corresponding private key at `~/.ssh/id_ed25519-2` on the controller.

The per-node region assignments are in `terraform/main.tf`. The checked-in `terraform/terraform.tfvars` selects Ubuntu 24.04, droplet size `s-8vcpu-16gb`, the Frankfurt Spaces bucket, and the `v0.4` object prefix. Changing a live droplet’s region requires replacing it.

```bash
scripts/deploy.sh
```

The script selects the newest published storage module from the dev catalog, requires a Linux AMD64 build, and saves the version, download URL, and SHA-256 in `artifacts/release.json`. It compares that release with the bucket’s root `metadata.json` before changing infrastructure. Use `scripts/deploy.sh --force` when you intend to redeploy the same version.

Ansible installs checksum-verified precompiled packages with the pinned `logosctl` 0.3.2, starts the `logoscore` systemd service, and preloads the book and a random file on each RS node. The dashboard takes its catalog from RS1. The deployment publishes the TCP bootstrap records, verifies the network and dashboard, then records the successful module version in [deployment metadata](https://logos-storage-network.fra1.digitaloceanspaces.com/metadata.json).

## Verify and operate

```bash
terraform -chdir=terraform output -raw dashboard_url
python3 -m unittest discover -s tests -v
source scripts/conda.sh
(cd ansible && ansible-playbook verify-playbook.yml -e @../artifacts/release.json)
```

The live verification checks the nodes’ module versions, DHT routing and all four provider tables. It compares the published bootstrap records with the controller’s exports, then uploads a fresh 1 MiB file to RS1, downloads it privately on RS2, and compares checksums.

- **Logs.** The storage daemon writes to `/var/log/logoscore.log` on each droplet. For a recent excerpt across the fleet, run `(cd ansible && ansible all -m command -a 'tail -n 20 /var/log/logoscore.log')` with the Ansible environment active. On MP1, use `journalctl -u logos-dashboard -u logos-dashboard-files` for the collector and file API.
- **Restart nodes.** Run `scripts/restart.sh` with the generated inventory present. It restarts MP1 first, then the MP followers one at a time, then the RS nodes. A full deployment also refreshes the public bootstrap records.
- **Update the dashboard.** From `ansible/`, run `ansible-playbook dashboard-playbook.yml -e @../artifacts/release.json`. To update just the portal pages and nginx routes, use `ansible-playbook dashboard-playbook.yml --tags portal --limit mp_bootstrap`. The deployment saves the dashboard’s self-signed TLS certificate to `scripts/.dashboard/server.crt` for local HTTPS verification.
- **Publish installers.** If RS1’s catalog changes, refresh `local-test/catalog.json` before building the native installers. Extract `install.sh` from each platform’s GitHub Actions bundle and run `scripts/publish-join-installer.sh /path/to/extracted/install.sh` for each. The publisher selects the public filename from the embedded platform and verifies the uploaded script.
- **Teardown.** `scripts/destroy.sh` runs Terraform destroy with automatic approval. The separately published installers must be removed before Spaces can delete a nonempty bucket. Pass `--delete-key` to also request deletion of the deployment’s Spaces access key and remove its local credentials file.
