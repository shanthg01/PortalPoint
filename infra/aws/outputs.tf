output "alb_dns_name" {
  description = "Feed into var.alb_origin_domain on a rebuild's second apply."
  value       = aws_lb.main.dns_name
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}
