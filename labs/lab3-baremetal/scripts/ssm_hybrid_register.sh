#!/usr/bin/env bash
# =============================================================================
# Register a PHYSICAL server as an AWS Systems Manager managed instance.
#
#   ./scripts/ssm_hybrid_register.sh canon-gw01          # print the plan
#   ./scripts/ssm_hybrid_register.sh canon-gw01 --apply  # create the activation
#
# REFERENCE SCRIPT. Like scripts/bmc_baseline.sh, it targets hardware and an
# AWS account that do not exist in this lab, so it is shellcheck-clean and
# syntax-checked rather than executed. Everything it does is one AWS API call
# and one agent install.
#
# WHY THIS EXISTS
#
# Lab 2 reaches EC2 instances over Session Manager: no inbound rule, no bastion,
# no SSH key, IAM for authorisation and CloudTrail for the audit trail. The
# obvious objection is that it only works for instances AWS created - and it is
# wrong. A HYBRID ACTIVATION registers anything that can reach the SSM
# endpoints: a server in a rack, a VM in vSphere, a machine in another cloud.
# Registered hosts get an `mi-` id instead of an `i-` id and are otherwise
# ordinary managed instances.
#
# What that buys, concretely:
#
#   ONE inventory       lab 2's aws_ec2 plugin is EC2-only, but the SSM
#                       inventory covers both, so "every host in prod" is one
#                       query instead of two systems joined by hand
#   ONE access path     the same connection plugin, the same IAM policy and the
#                       same CloudTrail records for a server in a data centre
#                       and an instance in a VPC
#   NO inbound rules    the agent polls outbound to the SSM endpoints, so the
#                       data centre firewall needs no hole for automation
#   patch + inventory   SSM Patch Manager and Inventory work on mi- instances,
#                       which for a small physical fleet can replace a
#                       separately-run patch server
#
# THE TWO THINGS TO GET RIGHT
#
# 1. An activation code and id are a CREDENTIAL, valid for every registration
#    until they expire, and anyone holding them can register a machine into
#    your account. So: a short expiry (24h), a registration limit that matches
#    the number of servers being built, and never in a git repository or a
#    kickstart %post that stays on disk. This script prints them to stdout for
#    one immediate use; a real build pipeline fetches them from Secrets Manager
#    at registration time and lets them expire.
#
# 2. The IAM role the activation grants is the identity EVERY host registered
#    with it assumes. It is not per-host, so it gets the SSM managed policy and
#    nothing else - no S3 access, no secrets - and anything host-specific is
#    granted elsewhere.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

HOSTNAME_ARG="${1:-}"
APPLY="${2:-}"

# The role the registered servers assume. Created once per account, with
# AmazonSSMManagedInstanceCore attached and a trust policy for ssm.amazonaws.com.
SSM_ROLE="${SSM_ROLE:-canon-hybrid-ssm}"
REGION="${AWS_REGION:-us-east-1}"
EXPIRY_HOURS=24

if [ -z "$HOSTNAME_ARG" ]; then
  echo "usage: $0 <hostname from hosts.yml> [--apply]"
  exit 2
fi

# The hostname must come from the source of truth. Registering a machine under
# a name nobody recorded produces exactly the orphan this pipeline exists to
# prevent - the SSM console equivalent of a server nobody knows about, which is
# the same rule ipxe/boot.ipxe enforces for unregistered MAC addresses.
if ! grep -q "hostname: $HOSTNAME_ARG\$" hosts.yml; then
  echo "[ERROR] $HOSTNAME_ARG is not in hosts.yml."
  echo "        Add the record first: a host that is not in the source of truth"
  echo "        must not be registered, or it becomes a managed instance with no owner."
  exit 1
fi

ROLE_LINE="$(grep -A9 "hostname: $HOSTNAME_ARG\$" hosts.yml | grep -m1 'role:' || true)"
HOST_ROLE="${ROLE_LINE##*: }"
EXPIRY="$(date -u -v+${EXPIRY_HOURS}H +%Y-%m-%dT%H:%M:%S 2>/dev/null ||
          date -u -d "+${EXPIRY_HOURS} hours" +%Y-%m-%dT%H:%M:%S)"

cat <<EOF
== hybrid activation for $HOSTNAME_ARG
   role            $HOST_ROLE
   iam role        $SSM_ROLE
   region          $REGION
   expires         $EXPIRY  (${EXPIRY_HOURS}h)
   registrations   1
   tags            Name=$HOSTNAME_ARG Role=$HOST_ROLE ManagedBy=ansible Platform=baremetal

   The tags are the same contract as the cloud half: lab 2 finds hosts by tag,
   so a physical server registered with these tags lands in the same groups as
   an EC2 instance with them - tag_Role_$HOST_ROLE and the rest.
EOF

if [ "$APPLY" != "--apply" ]; then
  cat <<'EOF'

   Dry run. Re-run with --apply to create the activation. What it would do:

   1. aws ssm create-activation \
        --default-instance-name <hostname> \
        --iam-role <role> --registration-limit 1 \
        --expiration-date <24h> --tags ... --region <region>

   2. On the server, once, from the %post section or the first Ansible run:

        curl -o /tmp/amazon-ssm-agent.rpm \
          https://s3.<region>.amazonaws.com/amazon-ssm-<region>/latest/linux_arm64/amazon-ssm-agent.rpm
        dnf install -y /tmp/amazon-ssm-agent.rpm
        systemctl stop amazon-ssm-agent
        amazon-ssm-agent -register -code "<code>" -id "<id>" -region "<region>"
        systemctl enable --now amazon-ssm-agent

      `-register` writes the credential to /var/lib/amazon/ssm and the
      activation code is never needed again - which is why a 24h expiry costs
      nothing operationally.

   3. Verify from the controller, and note it is by TAG, not by name:

        aws ssm describe-instance-information \
          --filters "Key=tag:ManagedBy,Values=ansible" \
          --query 'InstanceInformationList[].[InstanceId,ComputerName,PingStatus]'

      PingStatus must be Online. "ConnectionLost" after a successful
      registration is almost always egress: the agent needs 443 to the ssm,
      ssmmessages and ec2messages endpoints, and a data centre proxy needs
      https_proxy in the agent's systemd unit, not just in the shell.
EOF
  exit 0
fi

echo
echo "creating activation..."
aws ssm create-activation \
  --default-instance-name "$HOSTNAME_ARG" \
  --iam-role "$SSM_ROLE" \
  --registration-limit 1 \
  --expiration-date "$EXPIRY" \
  --region "$REGION" \
  --tags "Key=Name,Value=$HOSTNAME_ARG" \
         "Key=Role,Value=$HOST_ROLE" \
         "Key=ManagedBy,Value=ansible" \
         "Key=Platform,Value=baremetal" \
  --output json

cat <<'EOF'

The ActivationCode above is a credential. Use it now, on the one server it was
created for, and do not store it: a new activation is one API call, and a code
left in a file is a standing invitation to register a machine into this account.
EOF
