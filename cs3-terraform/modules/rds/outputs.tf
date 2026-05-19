output "db_endpoint"   { value = aws_db_instance.postgres.endpoint }
output "db_name"       { value = aws_db_instance.postgres.db_name }
output "db_port"       { value = aws_db_instance.postgres.port }
output "rds_sg_id"     { value = aws_security_group.rds.id }
output "db_password"   { value = aws_db_instance.postgres.password }
output "db_password_value" { 
  value     = random_password.db.result 
  sensitive = true
}
