locals {
  # Public-facing bucket name (fixed, no suffix).
  bucket = var.bucket_name

  # Objects are namespaced under the version prefix, e.g. v0.2/mix-pool.json.
  key_prefix   = var.version_prefix == "" ? "" : "${var.version_prefix}/"
  mix_pool_key = "${local.key_prefix}mix-pool.json"
  tcp_spr_key  = "${local.key_prefix}tcp-sprs.txt"
  tcp_json_key = "${local.key_prefix}tcp-sprs.json"
  udp_spr_key  = "${local.key_prefix}udp-sprs.txt"
  udp_json_key = "${local.key_prefix}udp-sprs.json"

  # Local artifact files (flat) that Ansible drops; uploaded under the prefixed keys above.
  artifacts = {
    mix_pool = "${path.module}/${var.artifacts_dir}/mix-pool.json"
    tcp_txt  = "${path.module}/${var.artifacts_dir}/tcp-sprs.txt"
    tcp_json = "${path.module}/${var.artifacts_dir}/tcp-sprs.json"
    udp_txt  = "${path.module}/${var.artifacts_dir}/udp-sprs.txt"
    udp_json = "${path.module}/${var.artifacts_dir}/udp-sprs.json"
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
  region   = var.region
  ssh_keys = [data.digitalocean_ssh_key.default.fingerprint]
  tags     = var.tags

  # RAM/CPU-only resize (no disk grow) so size changes stay reversible and the
  # droplet is resized in place rather than replaced.
  resize_disk = false
}

# Regular Storage (RS) nodes. Same toolchain/build as MP nodes, but configured
# to USE the mix network (mix-pool + dht-mix-proxy) rather than relay it.
resource "digitalocean_droplet" "rs" {
  count    = var.rs_node_count
  name     = "${var.rs_name_prefix}-${count.index + 1}"
  image    = var.image
  size     = var.droplet_size
  region   = var.region
  ssh_keys = [data.digitalocean_ssh_key.default.fingerprint]
  tags     = concat(var.tags, ["regular-storage"])

  resize_disk = false
}

# Cloud firewall: SSH for provisioning, libp2p TCP listen port, UDP discovery
# port. Everything else is denied inbound; all egress allowed. Covers MP + RS.
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
    protocol         = "udp"
    port_range       = "8090"
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
        index     = idx + 1
        bootstrap = idx == 0
      }
    ]
    rs_nodes = [
      for idx, d in digitalocean_droplet.rs : {
        name  = d.name
        ip    = d.ipv4_address
        index = idx + 1
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Published objects. These only exist after Ansible has produced the artifacts
# locally, so each upload is guarded by fileexists(): the first apply (before
# provisioning) skips them, and the publish apply (after provisioning) uploads.
# ---------------------------------------------------------------------------
resource "digitalocean_spaces_bucket_object" "mix_pool" {
  count = fileexists(local.artifacts.mix_pool) ? 1 : 0

  region       = var.region
  bucket       = digitalocean_spaces_bucket.artifacts.name
  key          = local.mix_pool_key
  source       = local.artifacts.mix_pool
  etag         = filemd5(local.artifacts.mix_pool)
  acl          = "public-read"
  content_type = "application/json"
}

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

resource "digitalocean_spaces_bucket_object" "udp_sprs_txt" {
  count = fileexists(local.artifacts.udp_txt) ? 1 : 0

  region       = var.region
  bucket       = digitalocean_spaces_bucket.artifacts.name
  key          = local.udp_spr_key
  source       = local.artifacts.udp_txt
  etag         = filemd5(local.artifacts.udp_txt)
  acl          = "public-read"
  content_type = "text/plain"
}

resource "digitalocean_spaces_bucket_object" "udp_sprs_json" {
  count = fileexists(local.artifacts.udp_json) ? 1 : 0

  region       = var.region
  bucket       = digitalocean_spaces_bucket.artifacts.name
  key          = local.udp_json_key
  source       = local.artifacts.udp_json
  etag         = filemd5(local.artifacts.udp_json)
  acl          = "public-read"
  content_type = "application/json"
}
