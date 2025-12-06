output "elb_dns_name" {
  description = "DNS name of the Classic ELB"
  value       = aws_elb.app_elb.dns_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}
