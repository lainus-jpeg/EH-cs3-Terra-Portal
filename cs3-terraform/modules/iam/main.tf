# ── EKS Cluster Role ─────────────────────────────────────────────────────────
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project}-${var.environment}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ── EKS Node Role ─────────────────────────────────────────────────────────────
resource "aws_iam_role" "eks_node" {
  name = "${var.project}-${var.environment}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_ssm" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ── ALB Controller Permissions (allows ALB controller running on nodes to manage ALBs) ───
resource "aws_iam_policy" "alb_controller" {
  name        = "${var.project}-${var.environment}-alb-controller-policy"
  description = "Full permissions for AWS Load Balancer Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteTags"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:ModifyListenerAttributes",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:SetRulePriorities",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:ModifyRule"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "waf-regional:GetWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.eks_node.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ── OIDC Provider for GitHub Actions ─────────────────────────────────────────
# Allows GitHub Actions to authenticate with AWS without storing credentials
data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name = "${var.project}-${var.environment}-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# GitHub Actions needs to push to ECR and deploy to EKS
resource "aws_iam_policy" "github_actions" {
  name        = "${var.project}-${var.environment}-github-actions-policy"
  description = "Allows GitHub Actions to push to ECR and update EKS deployments"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = var.ecr_arns
      },
      {
        Sid    = "EKSDescribe"
        Effect = "Allow"
        Action = ["eks:DescribeCluster"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}

# Grant GitHub Actions role kubectl access to EKS cluster
resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.github_actions.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_actions" {
  cluster_name  = var.eks_cluster_name
  principal_arn = aws_iam_role.github_actions.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.github_actions]
}

# ── IAM Groups (Innovatech org hierarchy) ────────────────────────────────────
resource "aws_iam_group" "management" {
  name = "${var.project}-${var.environment}-management"
}

resource "aws_iam_group" "it_ops" {
  name = "${var.project}-${var.environment}-it-ops"
}

resource "aws_iam_group" "security" {
  name = "${var.project}-${var.environment}-security"
}

resource "aws_iam_group" "platform" {
  name = "${var.project}-${var.environment}-platform"
}

resource "aws_iam_group" "employees" {
  name = "${var.project}-${var.environment}-employees"
}

# ── Group Policies ────────────────────────────────────────────────────────────

# Management — read-only dashboards and billing
resource "aws_iam_group_policy_attachment" "management_billing" {
  group      = aws_iam_group.management.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBillingReadOnlyAccess"
}

resource "aws_iam_group_policy_attachment" "management_readonly" {
  group      = aws_iam_group.management.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# IT Ops — manage EC2, EKS, RDS, IAM users
resource "aws_iam_group_policy_attachment" "it_ops_eks" {
  group      = aws_iam_group.it_ops.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_group_policy_attachment" "it_ops_ec2" {
  group      = aws_iam_group.it_ops.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

# Security — CloudWatch, GuardDuty, audit logs
resource "aws_iam_group_policy_attachment" "security_cloudwatch" {
  group      = aws_iam_group.security.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_group_policy_attachment" "security_guardduty" {
  group      = aws_iam_group.security.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonGuardDutyReadOnlyAccess"
}

# Platform — EKS, RDS, VPC, ECR full access
resource "aws_iam_group_policy_attachment" "platform_eks" {
  group      = aws_iam_group.platform.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_group_policy_attachment" "platform_rds" {
  group      = aws_iam_group.platform.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
}

resource "aws_iam_group_policy_attachment" "platform_ecr" {
  group      = aws_iam_group.platform.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

# Employees — minimal, read-only S3 for shared resources only
resource "aws_iam_group_policy_attachment" "employees_s3" {
  group      = aws_iam_group.employees.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# ── Self-Service Password Change (all groups) ─────────────────────────────────
# Required so IAM users can change their own password on first login.
# Must be explicit — group policies like ReadOnlyAccess do not grant this.
resource "aws_iam_policy" "self_service_password" {
  name        = "${var.project}-${var.environment}-self-service-password"
  description = "Allows IAM users to change their own password and view password policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["iam:ChangePassword", "iam:GetAccountPasswordPolicy"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_group_policy_attachment" "management_password" {
  group      = aws_iam_group.management.name
  policy_arn = aws_iam_policy.self_service_password.arn
}

resource "aws_iam_group_policy_attachment" "it_ops_password" {
  group      = aws_iam_group.it_ops.name
  policy_arn = aws_iam_policy.self_service_password.arn
}

resource "aws_iam_group_policy_attachment" "security_password" {
  group      = aws_iam_group.security.name
  policy_arn = aws_iam_policy.self_service_password.arn
}

resource "aws_iam_group_policy_attachment" "platform_password" {
  group      = aws_iam_group.platform.name
  policy_arn = aws_iam_policy.self_service_password.arn
}

resource "aws_iam_group_policy_attachment" "employees_password" {
  group      = aws_iam_group.employees.name
  policy_arn = aws_iam_policy.self_service_password.arn
}

variable "eks_cluster_name" {
  description = "EKS cluster name for GitHub Actions access entry"
  type        = string
}
