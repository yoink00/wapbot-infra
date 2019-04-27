# Configure the Scaleway Provider
provider "scaleway" {
  organization = "${var.scw_org}"
  token        = "${var.scw_token}"
  region       = "${var.region}"
}

# Configure the Random Provider
provider "random" {
}


variable "scw_org" {}

variable "scw_token" {}

variable "prefix" {}

variable "zt_api_key" {}

variable "zt_network" {}

variable "region" {
  default = "par1"
}

variable "type" {
  default = "C1"
}

variable "flannel_ip_range" {
  default = "172.26.78.0/24"
}

variable "agent_count" {
  default = 2
}

data "scaleway_image" "bionic" {
  architecture = "arm"
  name         = "Ubuntu Bionic"
}

resource "random_string" "cluster_secret" {
  length = 56
  special = false
}

resource "scaleway_ssh_key" "k3s_key" {
  key = "${file("id_rsa_swdev.pub")}"
}

resource "scaleway_ip" "k3s_server" {}

resource "scaleway_server" "k3s_server" {
  count               = "1"
  image               = "${data.scaleway_image.bionic.id}"
  type                = "${var.type}"
  name                = "${var.prefix}-k3sserver-${count.index}"
  security_group      = "${scaleway_security_group.k3s_cluster.id}"
  dynamic_ip_required = false
  public_ip           = "${scaleway_ip.k3s_server.ip}"

  depends_on = [ "scaleway_ssh_key.k3s_key" ]

  connection {
    type        = "ssh"
    user        = "root"
    private_key = "${file("id_rsa_swdev")}"
  }

  provisioner "file" {
    content = "${data.template_file.userdata_server.rendered}"
    destination = "/root/initialise"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /root/initialise",
      "/root/initialise > /root/initialise.log"
    ]
  }
}

resource "scaleway_server" "k3s_agent" {
  count               = "${var.agent_count}"
  image               = "${data.scaleway_image.bionic.id}"
  type                = "${var.type}"
  name                = "${var.prefix}-k3sagent-${count.index}"
  security_group      = "${scaleway_security_group.k3s_cluster.id}"
  dynamic_ip_required = true

  depends_on = [ "scaleway_ssh_key.k3s_key" ]

  connection {
    type        = "ssh"
    user        = "root"
    private_key = "${file("id_rsa_swdev")}"
  }

  provisioner "file" {
    content = "${data.template_file.userdata_agent.*.rendered[count.index]}"
    destination = "/root/initialise"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /root/initialise",
      "/root/initialise > /root/initialise.log"
    ]
  }
}

#resource "scaleway_user_data" "k3s_server" {
#  server = "${scaleway_server.k3s_server.id}"
#  key = "cloud-init"
#  value = "${data.template_file.userdata_server.rendered}"
#}
#
#resource "scaleway_user_data" "k3s_agent" {
#  count = "${var.agent_count}"
#  server = "${scaleway_server.k3s_agent.*.id[count.index]}"
#  key = "cloud-init"
#  value = "${data.template_file.userdata_agent.*.rendered[count.index]}"
#}

data "template_file" "userdata_server" {
  template = "${file("files/k3s_cloud_init.sh")}"

  vars {
    CLUSTER_SECRET        = "${random_string.cluster_secret.result}"
    ZT_STATIC_IP          = "${cidrhost(var.flannel_ip_range,1)}"
    ZT_API_KEY            = "${var.zt_api_key}"
    ZT_NET                = "${var.zt_network}"
    IS_SERVER             = true
    EXT_IP                = "${scaleway_ip.k3s_server.ip}"
  }
}
data "template_file" "userdata_agent" {
  template = "${file("files/k3s_cloud_init.sh")}"

  count = "${var.agent_count}"

  vars {
    CLUSTER_SECRET        = "${random_string.cluster_secret.result}"
    ZT_STATIC_IP          = "${cidrhost(var.flannel_ip_range,count.index+2)}"
    ZT_API_KEY            = "${var.zt_api_key}"
    ZT_NET                = "${var.zt_network}"
    IS_SERVER             = false
    ZT_SERVER_IP          = "${cidrhost(var.flannel_ip_range, 1)}"
  }
}

resource "scaleway_security_group" "k3s_cluster" {
  name        = "${var.prefix}-k3s_cluster"
  description = "k3s security group"
}

resource "scaleway_security_group_rule" "k3s_cluster_zt_accept" {
  security_group = "${scaleway_security_group.k3s_cluster.id}"

  action    = "accept"
  direction = "inbound"
  ip_range  = "0.0.0.0/0"
  protocol  = "UDP"
  port      = "9993"
}

output "k3s_server_ip" {
  value = "${scaleway_server.k3s_server.public_ip}"
}

