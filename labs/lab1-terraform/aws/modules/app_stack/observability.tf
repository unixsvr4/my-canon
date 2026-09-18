# -----------------------------------------------------------------------------
# observability.tf - D. for_each over ANOTHER RESOURCE.
#
# `for_each = aws_ecs_service.this` iterates that resource's INSTANCES. The keys
# are the same service names, and each.value is the whole resource object, so
# attributes that only exist after apply (the generated service name, the
# cluster it landed in) are available without repeating them.
#
# The point is that nobody keeps two lists in sync: add a service to the map and
# it gets its alarms automatically. A fleet where "most services have alarms" is
# a fleet where the unmonitored one is the one that breaks.
#
#   address -> aws_cloudwatch_metric_alarm.unhealthy["api"]
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy_tasks" {
  for_each = aws_ecs_service.this

  alarm_name        = "${each.value.name}-running-below-desired"
  alarm_description = "${each.key} has fewer running tasks than desired for 2 consecutive minutes."

  namespace   = "ECS/ContainerInsights"
  metric_name = "RunningTaskCount"
  statistic   = "Minimum"
  period      = 60

  comparison_operator = "LessThanThreshold"
  threshold           = each.value.desired_count
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  # The default is "missing data is fine". For a "did the tasks die" alarm,
  # missing data IS the incident: no metric usually means no running task to
  # report one. `breaching` is the setting people wish they had had.
  treat_missing_data = "breaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.this.name
    ServiceName = each.value.name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${each.value.name}-running", Service = each.key })
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  for_each = aws_lb_target_group.this

  alarm_name        = "${var.name_prefix}-${each.key}-target-5xx"
  alarm_description = "${each.key} returned 5xx responses to the load balancer."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_Target_5XX_Count"
  statistic   = "Sum"
  period      = 60

  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 2

  # Here `notBreaching` is right: no requests means no errors. The same setting
  # as above would page whenever a low-traffic service was simply idle.
  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = each.value.arn_suffix
  }

  alarm_actions = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${each.key}-5xx", Service = each.key })
}

# The database is a singleton, so its alarms are too - no for_each.
resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name        = "${var.name_prefix}-db-free-storage"
  alarm_description = "Less than 15% of allocated storage free on ${aws_db_instance.this.identifier}."

  namespace   = "AWS/RDS"
  metric_name = "FreeStorageSpace"
  statistic   = "Minimum"
  period      = 300

  comparison_operator = "LessThanThreshold"
  threshold           = var.db_allocated_storage * 1024 * 1024 * 1024 * 0.15
  evaluation_periods  = 2
  treat_missing_data  = "breaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.this.identifier
  }

  alarm_actions = local.alarm_actions

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-db-storage" })
}

# One dashboard for the stack, generated from the same map. A dashboard built by
# hand in the console is a dashboard that is missing the newest service.
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.name_prefix}-app-stack"

  dashboard_body = jsonencode({
    widgets = concat(
      [
        for idx, key in sort(keys(var.services)) : {
          type   = "metric"
          x      = (idx % 2) * 12
          y      = floor(idx / 2) * 6
          width  = 12
          height = 6

          properties = {
            title  = "${key}: running vs desired"
            region = data.aws_region.current.region
            view   = "timeSeries"
            metrics = [
              ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", aws_ecs_service.this[key].name],
              [".", "DesiredTaskCount", ".", ".", ".", "."],
            ]
          }
        }
      ],
      [
        {
          type   = "metric"
          x      = 0
          y      = ceil(length(var.services) / 2) * 6
          width  = 24
          height = 6

          properties = {
            title  = "database"
            region = data.aws_region.current.region
            view   = "timeSeries"
            metrics = [
              ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.this.identifier],
              [".", "CPUUtilization", ".", "."],
              [".", "ReadLatency", ".", "."],
              [".", "WriteLatency", ".", "."],
            ]
          }
        }
      ],
    )
  })
}
