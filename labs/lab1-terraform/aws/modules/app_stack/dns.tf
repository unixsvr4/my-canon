# -----------------------------------------------------------------------------
# dns.tf - C. for_each over a FILTERED map.
#
# Only services marked public get a DNS record. This is the idiomatic way to
# make a resource conditional PER KEY: filter the map, don't wrap the resource
# in a count ternary. In an environment where nothing is public, this resource
# simply has ZERO instances - no special case, no `count = var.x ? 1 : 0`, and
# no `[0]` indexing anywhere downstream.
#
#   address -> aws_route53_record.public["api"]
# -----------------------------------------------------------------------------
resource "aws_route53_record" "public" {
  for_each = local.public_services

  zone_id = var.hosted_zone_id
  name    = "${each.key}.${var.environment}.${var.domain}"
  type    = "A"

  # An ALIAS record, not a CNAME. Aliases resolve to the load balancer's
  # current addresses with no TTL to wait out, they are free to query, and they
  # can sit at the zone apex - a CNAME cannot. `evaluate_target_health` takes
  # the record out when the ALB has no healthy targets in that zone.
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }

  # The record must not exist before something answers on it. The listener rule
  # for this service is what makes the ALB respond to this host header; without
  # the dependency, DNS can resolve to a 404 for the length of an apply.
  depends_on = [aws_lb_listener_rule.this]
}
