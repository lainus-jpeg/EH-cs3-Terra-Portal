output "vpc_id"                  { value = aws_vpc.main.id }
output "public_subnet_ids"       { value = aws_subnet.public[*].id }
output "private_subnet_ids"      { value = aws_subnet.private[*].id }
output "db_subnet_ids"           { value = aws_subnet.db[*].id }
output "monitoring_subnet_ids"   { value = aws_subnet.monitoring[*].id }
output "db_subnet_group_name"    { value = aws_db_subnet_group.main.name }
