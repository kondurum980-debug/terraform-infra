terraform {
  backend "s3" {
    bucket       = "terraform-infra-state-backend222"
    key          = "infra/eks/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
