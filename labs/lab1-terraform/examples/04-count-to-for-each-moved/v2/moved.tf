# -----------------------------------------------------------------------------
# moved blocks (Terraform 1.1+) - a refactor recorded IN CODE.
#
# Each block tells Terraform "the object at the old address is the object at the
# new address": rename it in state, do not destroy and recreate it.
#
# Why this and not `terraform state mv`:
#   - it is reviewed in the pull request like any other change,
#   - it runs automatically in EVERY environment and every workspace that applies
#     this code - no one has to remember to run a command against prod state,
#   - `plan` shows the moves before anything happens.
#
# Keep moved blocks for at least one release, until every environment has
# applied past them. Removing one early turns the move back into destroy+create
# for any environment that has not yet applied it.
# -----------------------------------------------------------------------------

moved {
  from = terraform_data.user[0]
  to   = terraform_data.user["alice"]
}

moved {
  from = terraform_data.user[1]
  to   = terraform_data.user["bob"]
}

moved {
  from = terraform_data.user[2]
  to   = terraform_data.user["carol"]
}

# The same mechanism covers other refactors:
#   moved { from = terraform_data.user            to = module.users.terraform_data.user }  # into a module
#   moved { from = module.old_name                to = module.new_name }                   # rename a module
