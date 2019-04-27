provider "cloudflare" {
  email = "${var.cloudflare_email}"
  token = "${var.cloudflare_token}"
}

variable "cloudflare_email" {}

variable "cloudflare_token" {}

variable "cloudflare_zone" {}

resource "cloudflare_record" "k3s-cluster-server" {
  domain = "${var.cloudflare_zone}"
  name   = "k3scluster"
  value  = "${scaleway_server.k3s_server.public_ip}"
  type   = "A"
  ttl    = 1
}

resource "cloudflare_record" "k3s-cluster-agent" {
  count  = "${var.agent_count}"
  domain = "${var.cloudflare_zone}"
  name   = "k3scluster"
  value  = "${scaleway_server.k3s_agent.*.public_ip[count.index]}"
  type   = "A"
  ttl    = 1
}

