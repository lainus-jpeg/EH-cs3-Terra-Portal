output "db_endpoint" { value = module.rds.db_endpoint }
output "db_name"     { value = module.rds.db_name }
output "db_port"     { value = module.rds.db_port }
output "rds_sg_id"   { value = module.rds.rds_sg_id }

output "frontend_repository_url" { value = module.ecr.frontend_repository_url }
output "backend_repository_url"  { value = module.ecr.backend_repository_url }

output "alb_dns_name" {
  value = try(kubernetes_ingress_v1.main.status[0].load_balancer[0].ingress[0].hostname, "ALB not yet provisioned")
}

output "eks_cluster_name" {
  description = "EKS cluster name — use for kubectl config"
  value       = module.eks.cluster_name
}

output "onboarding_lambda_name"  { value = aws_lambda_function.onboarding.function_name }
output "offboarding_lambda_name" { value = aws_lambda_function.offboarding.function_name }
output "onboarding_lambda_arn"   { value = aws_lambda_function.onboarding.arn }
output "offboarding_lambda_arn"  { value = aws_lambda_function.offboarding.arn }
