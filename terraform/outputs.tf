output "droplet_ips" {
  description = "Public IPv4 address of each Mix-Proxy node, in node order."
  value       = { for d in digitalocean_droplet.mp : d.name => d.ipv4_address }
}

output "bootstrap_node" {
  description = "The node whose TCP SPR bootstraps the rest of the network."
  value       = digitalocean_droplet.mp[0].name
}

output "rs_droplet_ips" {
  description = "Public IPv4 address of each Regular Storage node."
  value       = { for d in digitalocean_droplet.rs : d.name => d.ipv4_address }
}

output "bucket_name" {
  description = "Spaces bucket holding the published artifacts."
  value       = digitalocean_spaces_bucket.artifacts.name
}

output "bucket_endpoint" {
  description = "Base HTTPS endpoint for the Spaces bucket."
  value       = "https://${digitalocean_spaces_bucket.artifacts.name}.${var.region}.digitaloceanspaces.com"
}

output "mix_pool_url" {
  description = "Public URL for mix-pool.json (available after the publish apply)."
  value       = "https://${digitalocean_spaces_bucket.artifacts.name}.${var.region}.digitaloceanspaces.com/${local.mix_pool_key}"
}

output "tcp_sprs_txt_url" {
  description = "Public URL for the newline-delimited TCP SPR list (available after the publish apply)."
  value       = "https://${digitalocean_spaces_bucket.artifacts.name}.${var.region}.digitaloceanspaces.com/${local.tcp_spr_key}"
}

output "tcp_sprs_json_url" {
  description = "Public URL for the JSON TCP SPR list (available after the publish apply)."
  value       = "https://${digitalocean_spaces_bucket.artifacts.name}.${var.region}.digitaloceanspaces.com/${local.tcp_json_key}"
}
