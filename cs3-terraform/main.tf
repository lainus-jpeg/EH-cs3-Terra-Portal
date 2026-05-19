terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # Remote state — store in S3 so state is shared and persisted
  # Create the bucket manually once before running terraform init
  # Commented out for now — uncomment when S3 bucket is ready
  # backend "s3" {
  #   bucket         = "cs3-terraform-state"
  #   key            = "cs3/terraform.tfstate"
  #   region         = "eu-central-1"
  #   encrypt        = true
  #   use_lockfile   = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "CS3-MA-NCA"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# ── Kubernetes Provider (configured after EKS cluster is created) ──────────────
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.main.token
}

data "aws_eks_cluster_auth" "main" {
  name = module.eks.cluster_name
}

# ── Helm Provider ──────────────────────────────────────────────────────────────
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  project     = var.project
  environment = var.environment
  vpc_cidr    = var.vpc_cidr

  public_subnet_cidrs     = var.public_subnet_cidrs
  private_subnet_cidrs    = var.private_subnet_cidrs
  db_subnet_cidrs         = var.db_subnet_cidrs
  monitoring_subnet_cidrs = var.monitoring_subnet_cidrs

  availability_zones = var.availability_zones
}

# ── IAM ───────────────────────────────────────────────────────────────────────
module "iam" {
  source = "./modules/iam"

  project     = var.project
  environment = var.environment
  github_repo = var.github_repo
  ecr_arns    = module.ecr.repository_arns
}

# ── ECR ───────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "./modules/ecr"

  project     = var.project
  environment = var.environment
}

# ── EKS ───────────────────────────────────────────────────────────────────────
module "eks" {
  source = "./modules/eks"

  project     = var.project
  environment = var.environment

  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  eks_cluster_role_arn = module.iam.eks_cluster_role_arn
  node_role_arn        = module.iam.eks_node_role_arn

  node_instance_type = var.eks_node_instance_type
  node_desired_size  = var.eks_desired_nodes
  node_min_size      = var.eks_min_nodes
  node_max_size      = var.eks_max_nodes
}

# ── RDS ───────────────────────────────────────────────────────────────────────
module "rds" {
  source = "./modules/rds"

  project              = var.project
  environment          = var.environment
  vpc_id               = module.vpc.vpc_id
  db_subnet_group_name = module.vpc.db_subnet_group_name
  eks_cluster_sg_id    = module.eks.cluster_security_group_id

  db_name     = var.db_name
  db_username = var.db_username
  multi_az    = var.rds_multi_az
}

# ── Lambda — Employee Lifecycle Automation ────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "${var.project}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_iam" {
  name        = "${var.project}-${var.environment}-lambda-iam-policy"
  description = "Allows Lambda to create/delete IAM users for employee lifecycle"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:GetUser",
          "iam:TagUser",
          "iam:CreateLoginProfile",
          "iam:DeleteLoginProfile",
          "iam:UpdateLoginProfile",
          "iam:AddUserToGroup",
          "iam:RemoveUserFromGroup",
          "iam:ListGroupsForUser",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:ListAccessKeys",
          "iam:ListMFADevices",
          "iam:DeactivateMFADevice",
          "iam:DeleteVirtualMFADevice",
          "iam:PutUserPolicy",
          "iam:DeleteUserPolicy",
          "iam:ListUserPolicies",
        ]
        Resource = "*"
      },
      # SSM — device management
      {
        Effect = "Allow"
        Action = [
          "ssm:CreateActivation",
          "ssm:DeleteActivation",
          "ssm:DeregisterManagedInstance",
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeActivations",
          "ssm:AddTagsToResource",
        ]
        Resource = "*"
      },
      # PassRole so Lambda can assign the SSM registration role to activations
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.ssm_service_role.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_iam" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_iam.arn
}

# ── SSM Service Role — required for hybrid (non-EC2) device activations ────────
resource "aws_iam_role" "ssm_service_role" {
  name = "${var.project}-${var.environment}-SSMServiceRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_service_role_policy" {
  role       = aws_iam_role.ssm_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow EKS nodes (backend pods) to invoke Lambda functions
resource "aws_iam_policy" "invoke_lambda" {
  name        = "${var.project}-${var.environment}-invoke-lambda-policy"
  description = "Allows backend pods to invoke lifecycle Lambda functions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["lambda:InvokeFunction"]
      Resource = [
        aws_lambda_function.onboarding.arn,
        aws_lambda_function.offboarding.arn,
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_invoke_lambda" {
  role       = module.iam.eks_node_role_name
  policy_arn = aws_iam_policy.invoke_lambda.arn
}

# Allow backend pods to call SSM (device management) and PassRole to SSMServiceRole
resource "aws_iam_policy" "node_ssm" {
  name = "${var.project}-${var.environment}-node-ssm-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:CreateActivation",
          "ssm:DeleteActivation",
          "ssm:DeregisterManagedInstance",
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeActivations",
          "ssm:AddTagsToResource",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.ssm_service_role.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = module.iam.eks_node_role_name
  policy_arn = aws_iam_policy.node_ssm.arn
}

data "archive_file" "onboarding" {
  type        = "zip"
  source_file = "${path.module}/functions/onboarding/handler.py"
  output_path = "${path.module}/functions/onboarding.zip"
}

data "archive_file" "offboarding" {
  type        = "zip"
  source_file = "${path.module}/functions/offboarding/handler.py"
  output_path = "${path.module}/functions/offboarding.zip"
}

resource "aws_lambda_function" "onboarding" {
  function_name    = "${var.project}-${var.environment}-onboarding"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.onboarding.output_path
  source_code_hash = data.archive_file.onboarding.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      ENVIRONMENT = var.environment
      PROJECT     = var.project
    }
  }

  tags = { Name = "${var.project}-${var.environment}-onboarding" }
}

resource "aws_lambda_function" "offboarding" {
  function_name    = "${var.project}-${var.environment}-offboarding"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.offboarding.output_path
  source_code_hash = data.archive_file.offboarding.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      ENVIRONMENT = var.environment
      PROJECT     = var.project
    }
  }

  tags = { Name = "${var.project}-${var.environment}-offboarding" }
}

# ── IRSA Role for ALB Controller ───────────────────────────────────────────────
resource "aws_iam_role" "alb_controller_irsa" {
  name = "${var.project}-${var.environment}-alb-controller-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(module.eks.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            "${replace(module.eks.oidc_provider_url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = { Name = "${var.project}-${var.environment}-alb-controller-irsa-role" }
}

resource "aws_iam_role_policy_attachment" "alb_controller_irsa" {
  role       = aws_iam_role.alb_controller_irsa.name
  policy_arn = module.iam.alb_controller_policy_arn
}

# ── AWS Load Balancer Controller ───────────────────────────────────────────────
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller_irsa.arn
  }

  depends_on = [module.eks, aws_iam_role_policy_attachment.alb_controller_irsa]
}

# ── Kubernetes Secrets ─────────────────────────────────────────────────────────
resource "kubernetes_secret" "app_secrets" {
  metadata {
    name      = "app-secrets"
    namespace = "default"
  }

  data = {
    jwt_secret = var.jwt_secret
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret" "db_credentials" {
  metadata {
    name      = "db-credentials"
    namespace = "default"
  }

  data = {
    host     = split(":", module.rds.db_endpoint)[0]
    port     = "5432"
    dbname   = var.db_name
    username = var.db_username
    password = module.rds.db_password_value
    ssl      = "true"
  }

  depends_on = [module.eks, module.rds]
}

# ── Frontend Deployment ───────────────────────────────────────────────────────
resource "kubernetes_deployment" "frontend" {
  metadata {
    name      = "frontend"
    namespace = "default"
    labels    = { app = "frontend" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "frontend" }
    }

    template {
      metadata {
        labels = { app = "frontend" }
      }

      spec {
        container {
          name              = "frontend"
          image             = "${module.ecr.frontend_repository_url}:latest"
          image_pull_policy = "Always"

          port {
            container_port = 80
          }
        }
      }
    }
  }

  wait_for_rollout = false
  depends_on       = [module.eks, helm_release.aws_load_balancer_controller]
}

# ── Monitoring — Prometheus + Grafana ─────────────────────────────────────────
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [module.eks]
}

resource "helm_release" "monitoring" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "58.4.0"

  # Grafana
  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }
  set {
    name  = "grafana.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "grafana.grafana\\.ini.server.root_url"
    value = "%(protocol)s://%(domain)s/grafana"
  }
  set {
    name  = "grafana.grafana\\.ini.server.serve_from_sub_path"
    value = "true"
  }

  # Prometheus
  set {
    name  = "prometheus.service.type"
    value = "ClusterIP"
  }

  # Reduce resource usage on small clusters
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "7d"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.cpu"
    value = "100m"
  }

  # Scrape portal pods
  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  depends_on = [module.eks, helm_release.aws_load_balancer_controller, kubernetes_namespace.monitoring]
}

resource "kubernetes_service" "frontend" {
  metadata {
    name      = "frontend-service"
    namespace = "default"
  }

  spec {
    selector = { app = "frontend" }

    port {
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.frontend]
}

# ── Backend Deployment ────────────────────────────────────────────────────────
resource "kubernetes_deployment" "backend" {
  metadata {
    name      = "backend"
    namespace = "default"
    labels    = { app = "backend" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "backend" }
    }

    template {
      metadata {
        labels = { app = "backend" }
      }

      spec {
        container {
          name              = "backend"
          image             = "${module.ecr.backend_repository_url}:latest"
          image_pull_policy = "Always"

          port {
            container_port = 3000
          }

          env {
            name = "DB_HOST"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db_credentials.metadata[0].name
                key  = "host"
              }
            }
          }

          env {
            name = "DB_NAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db_credentials.metadata[0].name
                key  = "dbname"
              }
            }
          }

          env {
            name = "DB_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db_credentials.metadata[0].name
                key  = "username"
              }
            }
          }

          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db_credentials.metadata[0].name
                key  = "password"
              }
            }
          }

          env {
            name = "DB_PORT"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db_credentials.metadata[0].name
                key  = "port"
              }
            }
          }

          env {
            name  = "DB_SSL"
            value = "true"
          }

          env {
            name = "JWT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app_secrets.metadata[0].name
                key  = "jwt_secret"
              }
            }
          }

          env {
            name  = "ONBOARDING_LAMBDA_NAME"
            value = aws_lambda_function.onboarding.function_name
          }

          env {
            name  = "OFFBOARDING_LAMBDA_NAME"
            value = aws_lambda_function.offboarding.function_name
          }

          env {
            name  = "AWS_REGION"
            value = var.aws_region
          }

          env {
            name  = "SSM_REGISTRATION_ROLE"
            value = aws_iam_role.ssm_service_role.name
          }

          env {
            name  = "GRAFANA_URL"
            value = "/grafana"
          }

          env {
            name  = "PROMETHEUS_URL"
            value = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
          }
        }
      }
    }
  }

  wait_for_rollout = false
  depends_on       = [module.eks, helm_release.aws_load_balancer_controller, kubernetes_secret.db_credentials, aws_lambda_function.onboarding, aws_lambda_function.offboarding, aws_iam_role.ssm_service_role, helm_release.monitoring]
}

resource "kubernetes_service" "backend" {
  metadata {
    name      = "backend-service"
    namespace = "default"
  }

  spec {
    selector = { app = "backend" }

    port {
      port        = 3000
      target_port = 3000
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }

  depends_on = [kubernetes_deployment.backend]
}

# ── Ingress ───────────────────────────────────────────────────────────────────
resource "kubernetes_ingress_v1" "main" {
  metadata {
    name      = "cs3-ingress"
    namespace = "default"
    annotations = {
      "alb.ingress.kubernetes.io/target-type"  = "ip"
      "alb.ingress.kubernetes.io/scheme"       = "internet-facing"
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/group.name"   = "cs3-alb-group"
      "alb.ingress.kubernetes.io/group.order"  = "10"
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      http {
        path {
          path      = "/v1"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.backend.metadata[0].name
              port { number = 3000 }
            }
          }
        }

        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.frontend.metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_service.frontend, kubernetes_service.backend, helm_release.aws_load_balancer_controller]
}

# ── Grafana Ingress (monitoring namespace) ────────────────────────────────────
resource "kubernetes_ingress_v1" "grafana" {
  metadata {
    name      = "grafana-ingress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/target-type"  = "ip"
      "alb.ingress.kubernetes.io/scheme"       = "internet-facing"
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/group.name"   = "cs3-alb-group"
      "alb.ingress.kubernetes.io/group.order"  = "1"
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      http {
        path {
          path      = "/grafana"
          path_type = "Prefix"
          backend {
            service {
              name = "kube-prometheus-stack-grafana"
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.monitoring, helm_release.aws_load_balancer_controller]
}
