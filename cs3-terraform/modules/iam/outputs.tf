output "eks_cluster_role_arn"    { value = aws_iam_role.eks_cluster.arn }
output "eks_node_role_arn"       { value = aws_iam_role.eks_node.arn }
output "eks_node_role_name"      { value = aws_iam_role.eks_node.name }
output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }
output "alb_controller_policy_arn" { value = aws_iam_policy.alb_controller.arn }

output "iam_group_names" {
  value = {
    management = aws_iam_group.management.name
    it_ops     = aws_iam_group.it_ops.name
    security   = aws_iam_group.security.name
    platform   = aws_iam_group.platform.name
    employees  = aws_iam_group.employees.name
  }
}
