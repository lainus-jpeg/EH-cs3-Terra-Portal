# CS3-MA-NCA — Terraform Infrastructure

Provisions the full AWS infrastructure for the Innovatech self-service portal.

## Architecture
- **VPC** — 4 subnet tiers (public, private app/EKS, private DB, monitoring)
- **EKS** — managed Kubernetes cluster with auto-scaling node group
- **RDS** — PostgreSQL 15, Multi-AZ for failover
- **ECR** — private Docker registries for frontend and backend images
- **IAM** — groups, roles, OIDC for GitHub Actions (no stored credentials)

## Prerequisites
- AWS CLI configured (`aws configure`)
- Terraform >= 1.5.0
- kubectl installed

## First-time setup

### 1. Create S3 state bucket (once only)
```bash
aws s3 mb s3://cs3-terraform-state --region eu-central-1
aws s3api put-bucket-versioning \
  --bucket cs3-terraform-state \
  --versioning-configuration Status=Enabled
```

### 2. Configure variables
```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set db_password
```

### 3. Deploy
```bash
terraform init
terraform plan
terraform apply
```

## After deployment — connect kubectl to EKS
```bash
aws eks update-kubeconfig \
  --region eu-central-1 \
  --name cs3-dev-cluster
kubectl get nodes
```

## Tear down
```bash
terraform destroy
```

## Module structure
```
modules/
  vpc/    — VPC, subnets, NAT gateway, route tables
  iam/    — EKS roles, IAM groups, OIDC for GitHub Actions
  ecr/    — ECR repositories for frontend and backend
  rds/    — PostgreSQL RDS instance with Multi-AZ
  eks/    — EKS cluster and node group
```

## Cost notes (eu-central-1)
| Resource | Approx cost |
|---|---|
| EKS cluster | ~$0.10/hr |
| 2x t3.small nodes | ~$0.021/hr |
| RDS db.t3.micro | ~$0.025/hr |
| NAT Gateway | ~$0.048/hr + data |
| **Total** | **~$4-5/day** |

Destroy when not in use to save costs.
