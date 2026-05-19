output "frontend_repository_url" { value = aws_ecr_repository.frontend.repository_url }
output "backend_repository_url"  { value = aws_ecr_repository.backend.repository_url }
output "repository_arns" {
  value = [
    aws_ecr_repository.frontend.arn,
    aws_ecr_repository.backend.arn,
  ]
}
