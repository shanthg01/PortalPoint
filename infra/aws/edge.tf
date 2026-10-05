# Frontend: private S3 bucket behind CloudFront (OAC), with /api/* routed to the ALB
# so the SPA can keep calling relative /api paths.

resource "aws_s3_bucket" "frontend" {
  bucket        = "portalpoint-frontend"
  force_destroy = true # destroy empties the bucket (it only holds the rebuildable Vite dist/)
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Read access for this one distribution only.
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.main.arn }
      }
    }]
  })
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "portalpoint-oac"
  description                       = ""
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "spa_routing" {
  name    = "spa-routing"
  runtime = "cloudfront-js-2.0"
  comment = "Rewrite SPA client-side routes to index.html (default behavior only)"
  # replace(): the docs copy may be checked out with CRLF on Windows; live code is LF.
  code = replace(file("${path.module}/../../docs/cloudfront-spa-routing-function.js"), "\r\n", "\n")
}

# Decommission mode (var.redirect_to set): one viewer-request function 301s every
# path -- app and /api -- to the new frontend, and the ALB origin + /api route
# are dropped so CloudFront no longer depends on the backend (ECS/ALB/RDS can be
# destroyed while this keeps old links working). Set redirect_to = null on a
# rebuild to get normal SPA serving back.
resource "aws_cloudfront_function" "redirect" {
  count   = local.redirect ? 1 : 0
  name    = "portalpoint-decommission-redirect"
  runtime = "cloudfront-js-2.0"
  comment = "301 everything to the new PortalPoint frontend"
  code    = replace(file("${path.module}/functions/redirect.js"), "__TARGET__", var.redirect_to)
}

locals {
  redirect = var.redirect_to != null
  # /api/* -> ALB only in normal serving mode, and only once the ALB's DNS name is known.
  api_route = !local.redirect && var.alb_origin_domain != null

  # AWS managed policies
  cache_policy_caching_optimized = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  cache_policy_caching_disabled  = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  origin_request_all_except_host = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader -- passes Authorization through
}

resource "aws_cloudfront_distribution" "main" {
  comment             = "PortalPoint frontend + API"
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2"
  price_class         = "PriceClass_100"
  default_root_object = "index.html"

  origin {
    origin_id                = "s3-frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # The ALB is wired in by plain string (var.alb_origin_domain), NOT a reference to
  # aws_lb.main: any reference makes CloudFront depend on the backend, so a targeted
  # destroy of the ALB would cascade into destroying this redirector too.
  dynamic "origin" {
    for_each = local.api_route ? [1] : []
    content {
      origin_id   = "alb-backend"
      domain_name = var.alb_origin_domain
      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = local.cache_policy_caching_optimized

    function_association {
      event_type   = "viewer-request"
      function_arn = local.redirect ? aws_cloudfront_function.redirect[0].arn : aws_cloudfront_function.spa_routing.arn
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = local.api_route ? [1] : []
    content {
      path_pattern             = "/api/*"
      target_origin_id         = "alb-backend"
      viewer_protocol_policy   = "https-only"
      allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = local.cache_policy_caching_disabled
      origin_request_policy_id = local.origin_request_all_except_host
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
