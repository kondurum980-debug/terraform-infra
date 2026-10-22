terraform {
  backend "s3" {
    bucket       = "terraform-infra-state-backend1234"
    key          = "infra/vpc/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
