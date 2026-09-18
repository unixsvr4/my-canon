# -----------------------------------------------------------------------------
# tflint configuration for the AWS roots.
#
# The bundled terraform ruleset only knows the language. The aws ruleset knows
# the PROVIDER: it rejects an instance type that does not exist, an invalid
# engine version, a name longer than the API allows, a deprecated argument - the
# class of mistake `terraform validate` cannot see and a mocked `terraform test`
# cannot either, because a mock accepts anything.
#
# Install the plugin once (the Makefile target does this):
#
#     tflint --init --config=labs/lab1-terraform/aws/.tflint.hcl
#
# It is scoped to this directory rather than the repository root so the $0
# local-provider roots keep linting with nothing but the bundled rules.
# -----------------------------------------------------------------------------

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # `deep_check` would call AWS to verify that referenced resources really
  # exist. It needs credentials and it costs API calls, so it stays off here and
  # belongs in a pipeline that already has a role to assume.
}

# Every variable and output in this repository is documented, and the rule is
# on so it stays that way.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}
