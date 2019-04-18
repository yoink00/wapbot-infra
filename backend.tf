terraform {
  backend "remote" {
    hostname = "app.terraform.io"
    organization = "wapbot"

    workspaces {
      name = "swdev"
    }
  }
}

