locals {
  # Public-facing bucket name (fixed, no suffix).
  bucket = var.bucket_name

  # Keep node indices stable across regions. Extra nodes use the default region.
  mp_regions = ["nyc3", "lon1", "ams3", "sgp1"]
  rs_regions = ["tor1", "fra1"]
  locations = {
    nyc3 = "US - New York"
    lon1 = "UK - London"
    ams3 = "Netherlands - Amsterdam"
    sgp1 = "Singapore"
    tor1 = "Canada - Toronto"
    fra1 = "Germany - Frankfurt"
  }

  # Objects are namespaced under the version prefix, e.g. v0.4/tcp-sprs.json.
  key_prefix   = var.version_prefix == "" ? "" : "${var.version_prefix}/"
  tcp_spr_key  = "${local.key_prefix}tcp-sprs.txt"
  tcp_json_key = "${local.key_prefix}tcp-sprs.json"

  # Local artifact files (flat) that Ansible drops; uploaded under the prefixed keys above.
  artifacts = {
    tcp_txt  = "${path.module}/${var.artifacts_dir}/tcp-sprs.txt"
    tcp_json = "${path.module}/${var.artifacts_dir}/tcp-sprs.json"
  }
}

data "digitalocean_ssh_key" "default" {
  name = var.ssh_key_name
}

resource "digitalocean_droplet" "mp" {
  count    = var.node_count
  name     = "${var.name_prefix}-${count.index + 1}"
  image    = var.image
  size     = var.droplet_size
  region   = try(local.mp_regions[count.index], var.region)
  ssh_keys = [data.digitalocean_ssh_key.default.fingerprint]
  tags     = var.tags

  # RAM/CPU-only resize (no disk grow) so size changes stay reversible and the
  # droplet is resized in place rather than replaced.
  resize_disk = false
}

# Regular Storage (RS) nodes discover network services after bootstrap.
resource "digitalocean_droplet" "rs" {
  count    = var.rs_node_count
  name     = "${var.rs_name_prefix}-${count.index + 1}"
  image    = var.image
  size     = var.droplet_size
  region   = try(local.rs_regions[count.index], var.region)
  ssh_keys = [data.digitalocean_ssh_key.default.fingerprint]
  tags     = concat(var.tags, ["regular-storage"])

  resize_disk = false
}

# Cloud firewall: SSH and libp2p/KadDHT TCP. All egress allowed. Covers MP + RS.
resource "digitalocean_firewall" "mp" {
  name        = "${var.name_prefix}-fw"
  droplet_ids = concat(digitalocean_droplet.mp[*].id, digitalocean_droplet.rs[*].id)

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "8080"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# Spaces bucket that hosts the published artifacts. The bucket itself stays
# private; individual objects are uploaded with a public-read ACL below.
# Credentials come from the provider (SPACES_* env vars). The Spaces key is
# created out-of-band by scripts/00-spaces-key.sh — Terraform never mints it.
resource "digitalocean_spaces_bucket" "artifacts" {
  name   = local.bucket
  region = var.region
  acl    = "private"
}

# Ansible inventory rendered from live droplet data. Node 1 is the bootstrap.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content = templatefile("${path.module}/templates/inventory.tftpl", {
    nodes = [
      for idx, d in digitalocean_droplet.mp : {
        name      = d.name
        ip        = d.ipv4_address
        location  = lookup(local.locations, d.region, d.region)
        index     = idx + 1
        bootstrap = idx == 0
      }
    ]
    rs_nodes = [
      for idx, d in digitalocean_droplet.rs : {
        name     = d.name
        ip       = d.ipv4_address
        index    = idx + 1
        location = lookup(local.locations, d.region, d.region)
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Published objects. These only exist after Ansible has produced the artifacts
# locally, so each upload is guarded by fileexists(): the first apply (before
# provisioning) skips them, and the publish apply (after provisioning) uploads.
# ---------------------------------------------------------------------------
resource "digitalocean_spaces_bucket_object" "tcp_sprs_txt" {
  count = fileexists(local.artifacts.tcp_txt) ? 1 : 0

  region       = var.region
  bucket       = digitalocean_spaces_bucket.artifacts.name
  key          = local.tcp_spr_key
  source       = local.artifacts.tcp_txt
  etag         = filemd5(local.artifacts.tcp_txt)
  acl          = "public-read"
  content_type = "text/plain"
}

resource "digitalocean_spaces_bucket_object" "tcp_sprs_json" {
  count = fileexists(local.artifacts.tcp_json) ? 1 : 0

  region       = var.region
  bucket       = digitalocean_spaces_bucket.artifacts.name
  key          = local.tcp_json_key
  source       = local.artifacts.tcp_json
  etag         = filemd5(local.artifacts.tcp_json)
  acl          = "public-read"
  content_type = "application/json"
}

# Publish only after every node and the transfer check pass. Root metadata is
# independent of the network namespace, so subsequent deploys can compare it.
resource "digitalocean_spaces_bucket_object" "metadata" {
  count        = fileexists("${path.module}/${var.artifacts_dir}/metadata.json") ? 1 : 0
  region       = var.region
  bucket       = digitalocean_spaces_bucket.artifacts.name
  key          = "metadata.json"
  source       = "${path.module}/${var.artifacts_dir}/metadata.json"
  etag         = filemd5("${path.module}/${var.artifacts_dir}/metadata.json")
  acl          = "public-read"
  content_type = "application/json"
}

# MP1 serves the ACME HTTP challenge and the HTTPS dashboard.
resource "digitalocean_firewall" "dashboard" {
  name        = "${var.name_prefix}-dashboard-fw"
  droplet_ids = [digitalocean_droplet.mp[0].id]
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
}
