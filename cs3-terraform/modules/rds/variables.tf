variable "project"             { type = string }
variable "environment"         { type = string }
variable "vpc_id"              { type = string }
variable "db_subnet_group_name" { type = string }
variable "eks_cluster_sg_id"   { type = string }
variable "db_name"             { type = string }
variable "db_username"         { type = string }
# db_password is auto-generated via random_password — no longer a variable
# db_host is set after RDS is created — used for Secrets Manager entry
variable "db_host" {
  type    = string
  default = "pending"  # updated after first apply
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = true
}
