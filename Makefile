# =============================================================================
# One entry point for every check and demo in the repository.
#
#   make help          list targets
#   make ci            everything that needs no Docker (what CI runs)
#   make all           ci + the Docker-backed Ansible and bare-metal checks
#
# Each target is the exact command documented in the lab READMEs, so a green
# `make all` means the READMEs are true.
# =============================================================================
SHELL := /bin/bash
.DEFAULT_GOAL := help

LAB1 := labs/lab1-terraform
LAB2 := labs/lab2-ansible
LAB3 := labs/lab3-baremetal

TF_ROOTS    := $(LAB1)/modules/app_stack $(LAB1)/envs/dev $(LAB1)/envs/prod \
               $(LAB1)/examples/01-count-vs-for-each $(LAB1)/examples/02-for-each-shapes \
               $(LAB1)/examples/03-nested-for-each \
               $(LAB1)/examples/04-count-to-for-each-moved/v1 $(LAB1)/examples/04-count-to-for-each-moved/v2
TF_EXAMPLES := 01-count-vs-for-each 02-for-each-shapes 03-nested-for-each 04-count-to-for-each-moved

# The AWS roots are linted with the aws tflint ruleset (see aws/.tflint.hcl) and
# tested with mock_provider, so they need no credentials and cost nothing.
TF_AWS       := $(LAB1)/aws
TF_AWS_ROOTS := $(TF_AWS)/modules/app_stack $(TF_AWS)/envs/dev $(TF_AWS)/envs/prod $(TF_AWS)/envs/bootstrap

# Trace logging (if set in a shell profile) makes every Terraform call slow.
unexport TF_LOG TF_LOG_PATH

.PHONY: help ci all check test \
        lab1-static lab1-test tf-examples lab1-scan tf-scan \
        lab1-aws-static lab1-aws-test \
        lab1-up lab1-verify lab1-verify-demo lab1-down lab1-e2e \
        lab2-static lab2-up lab2-test lab2-idempotence-demo lab2-patch-demo lab2-drift-demo lab2-down \
        lab2-distros-up lab2-kernel-test lab2-kernel-demo lab2-distros-down \
        lab2-vms-up lab2-kernel-reboot lab2-vms-down \
        lab3-static lab3-test lab3-artifacts clean

help: ## List targets
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  \033[1m%-24s\033[0m %s\n", $$1, $$2}'

ci: check test ## Static checks + tests that need no Docker (what CI runs)

all: ci lab1-e2e lab2-up lab2-test lab2-patch-demo lab2-distros-up lab2-kernel-test lab3-artifacts ## Everything, including Docker-backed checks

check: lab1-static lab1-aws-static tf-scan lab2-static lab3-static ## All static checks

test: lab1-test lab1-aws-test tf-examples lab3-test ## All tests that need no Docker

# --- Lab 1: Terraform ----------------------------------------------------------
lab1-static: ## terraform fmt -check, init -backend=false, validate, tflint on every root
	terraform fmt -check -recursive $(LAB1)
	@for d in $(TF_ROOTS); do \
	  echo "== $$d"; \
	  (cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate -no-color && tflint --no-color) || exit 1; \
	done

tf-scan: ## trivy config scan of EVERY Terraform root in the repo (misconfiguration gate)
	@# Both Terraform trees, not just lab 1's: lab 2 grew an EC2 rig for the
	@# kernel role's reboot test, and a scan that silently stops at one
	@# directory is a gate with a hole in it.
	trivy config --quiet --exit-code 1 $(LAB1)
	trivy config --quiet --exit-code 1 $(LAB2)/aws

lab1-scan: tf-scan ## Alias kept so the documented command still works

lab1-aws-static: ## init/validate/tflint the AWS roots with the aws ruleset (no credentials needed)
	tflint --init --config="$(CURDIR)/$(TF_AWS)/.tflint.hcl" >/dev/null
	@for d in $(TF_AWS_ROOTS); do \
	  echo "== $$d"; \
	  (cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate -no-color && \
	   tflint --no-color --config="$(CURDIR)/$(TF_AWS)/.tflint.hcl") || exit 1; \
	done

lab1-aws-test: ## terraform test on the AWS module: 18 plan runs + 4 apply runs against mock_provider
	cd $(TF_AWS)/modules/app_stack && terraform init -backend=false -input=false >/dev/null && terraform test -no-color

lab1-test: ## terraform test on the app_stack module (12 plan runs + 4 apply runs)
	cd $(LAB1)/modules/app_stack && terraform init -backend=false -input=false >/dev/null && terraform test -no-color

tf-examples: ## Run the four for_each demos (self-cleaning)
	@for e in $(TF_EXAMPLES); do ./$(LAB1)/examples/$$e/demo.sh || exit 1; done

lab1-up: ## Apply dev and prod from reviewed, saved plans
	@for e in dev prod; do \
	  echo "== envs/$$e"; \
	  (cd $(LAB1)/envs/$$e && terraform init -input=false >/dev/null && \
	   terraform plan -input=false -no-color -out=tfplan | grep -E '^Plan:|^No changes' && \
	   terraform apply -input=false -no-color tfplan | grep -E '^Apply complete') || exit 1; \
	done

lab1-verify: ## Post-apply verification of the live dev and prod environments
	cd $(LAB1) && ./verify-env.py envs/dev && ./verify-env.py envs/prod

lab1-verify-demo: ## Tamper with prod; verify must fail; remediate step by step until it passes
	cd $(LAB1) && ./tamper-env.sh envs/prod
	cd $(LAB1) && if ./verify-env.py envs/prod; then echo "ERROR: verify passed on a tampered environment"; exit 1; fi
	@echo "== remediation 1: terraform apply (fixes what plan can see)"
	cd $(LAB1)/envs/prod && terraform apply -input=false -no-color -auto-approve | grep -E '^Apply complete'
	cd $(LAB1) && if ./verify-env.py envs/prod; then echo "ERROR: apply should not fix unmanaged objects or permissions"; exit 1; fi
	@echo "== remediation 2: delete the unmanaged object, -replace the object with drifted permissions"
	rm $(LAB1)/envs/prod/.artifacts/canon-prod-hotfix.json
	cd $(LAB1)/envs/prod && terraform apply -input=false -no-color -auto-approve \
	  -replace='module.app_stack.local_file.stateful_store' | grep -E '^Apply complete'
	cd $(LAB1) && ./verify-env.py envs/prod

lab1-down: ## Destroy dev and prod, then prove nothing was left behind
	@for e in dev prod; do \
	  echo "== envs/$$e"; \
	  (cd $(LAB1)/envs/$$e && terraform init -input=false >/dev/null && \
	   terraform destroy -input=false -no-color -auto-approve | grep -E '^Destroy complete') || exit 1; \
	done
	cd $(LAB1) && ./verify-env.py --destroyed envs/dev && ./verify-env.py --destroyed envs/prod

lab1-e2e: lab1-up lab1-verify lab1-verify-demo lab1-down ## Full lifecycle: apply, verify, tamper, remediate, destroy

# --- Lab 2: Ansible ------------------------------------------------------------
lab2-static: ## ansible-lint (production profile) + syntax checks
	cd $(LAB2) && { [ -d collections/ansible_collections/community/docker ] || \
	  ansible-galaxy collection install -r requirements.yml -p ./collections >/dev/null; }
	cd $(LAB2) && ansible-lint
	cd $(LAB2) && for p in site.yml patch.yml kernel.yml examples/idempotence/idempotent.yml examples/idempotence/not-idempotent.yml; do \
	  ansible-playbook --syntax-check $$p >/dev/null || exit 1; echo "syntax ok: $$p"; done
	@# The EC2 dynamic inventory needs credentials to LIST hosts, but parsing it
	@# needs only the collection - so CI can still prove the plugin is installed
	@# and the config is valid YAML the plugin accepts.
	cd $(LAB2) && ansible-inventory -i inventory/aws_ec2.yml --list >/dev/null 2>&1 && \
	  echo "parse ok: inventory/aws_ec2.yml (aws_ec2 plugin, no credentials needed to parse)"

lab2-up: ## Create the six lab containers and install pinned collections
	cd $(LAB2) && ./setup.sh

lab2-test: ## Converge, prove idempotence, prove the input contract, run the drift cycle
	cd $(LAB2) && tests/idempotence.sh
	cd $(LAB2) && tests/input-validation.sh
	$(MAKE) lab2-idempotence-demo lab2-drift-demo

lab2-idempotence-demo: ## Anti-patterns fail the idempotence test; fixes pass
	cd $(LAB2) && ansible-playbook examples/idempotence/reset.yml >/dev/null
	cd $(LAB2) && if tests/idempotence.sh examples/idempotence/not-idempotent.yml; then \
	  echo "ERROR: the anti-pattern playbook unexpectedly passed"; exit 1; fi
	cd $(LAB2) && ansible-playbook examples/idempotence/reset.yml >/dev/null
	cd $(LAB2) && tests/idempotence.sh examples/idempotence/idempotent.yml
	cd $(LAB2) && ansible-playbook examples/idempotence/reset.yml >/dev/null

lab2-drift-demo: ## Tamper -> drift (exit 2) -> remediate -> clean (exit 0), record kept
	cd $(LAB2) && ./tamper.sh db01
	cd $(LAB2) && ./drift-check.sh; rc=$$?; [ $$rc -eq 2 ] || { echo "expected exit 2, got $$rc"; exit 1; }
	cd $(LAB2) && ansible-playbook site.yml --limit db01 >/dev/null
	cd $(LAB2) && ./drift-check.sh
	cd $(LAB2) && ./drift-show.py

lab2-patch-demo: ## Rolling patch: stops at web03; retry only the failures
	cd $(LAB2) && rm -rf reports/run reports/patch.retry
	cd $(LAB2) && if ansible-playbook patch.yml; then echo "ERROR: expected the run to abort at web03"; exit 1; fi
	cd $(LAB2) && ansible-playbook patch.yml --limit @reports/patch.retry -e simulate_health_failure=false
	cd $(LAB2) && ./summarize.sh

lab2-distros-up: ## Create the four distribution containers for the kernel role
	cd $(LAB2) && ./setup-distros.sh

lab2-kernel-test: ## Kernel tuning on RHEL, Ubuntu, SUSE and Amazon Linux: artifacts, idempotence, input contract
	cd $(LAB2) && tests/kernel-multidistro.sh
	cd $(LAB2) && tests/kernel-contract.sh

lab2-kernel-demo: ## Show what each distribution got, and what is still waiting for a reboot
	cd $(LAB2) && ansible-playbook -i inventory/kernel-hosts.yml kernel.yml
	@echo
	@echo "== the bootloader mechanism each distribution uses"
	@for h in ktr-rhel ktr-suse ktr-amazon; do \
	  printf '%-12s ' "$$h"; docker exec lab-$$h grep -h '^GRUB_CMDLINE_LINUX' /etc/default/grub; done
	@printf '%-12s ' ktr-ubuntu; docker exec lab-ktr-ubuntu grep -h '^_canon_args=' /etc/default/grub.d/99-canon-kernel.cfg

lab2-distros-down: ## Remove the four distribution containers
	cd $(LAB2) && ./setup-distros.sh --down

# --- Lab 2: the real-kernel half -----------------------------------------------
#
# These are NOT in `make all`. They boot four QEMU virtual machines, reboot them
# and install a new kernel in each, which takes about 15 minutes and a few GB of
# downloaded images - too slow for a commit gate, and the only way to test the
# one claim containers cannot make.
lab2-vms-up: ## Boot four real VMs (own kernel, own bootloader) for the kernel role
	cd $(LAB2) && ./vms/up.sh

lab2-kernel-reboot: ## THE reboot proof on real kernels: apply, reboot, verify, upgrade the kernel, re-apply (about 15 min)
	cd $(LAB2) && tests/kernel-reboot.sh

lab2-vms-down: ## Shut the VMs down and delete their disks
	cd $(LAB2) && ./vms/down.sh --clean

lab2-down: ## Remove the lab containers
	cd $(LAB2) && ./teardown.sh

# --- Lab 3: bare metal -----------------------------------------------------------
lab3-static: ## Compile Python, bash -n shell scripts, lint + syntax-check acceptance.yml
	python3 -m py_compile $(LAB3)/scripts/*.py $(LAB3)/tests/*.py
	@for s in $(LAB3)/scripts/*.sh; do bash -n $$s && echo "bash -n ok: $$s"; done
	cd $(LAB3) && ./scripts/render.py >/dev/null && ansible-lint acceptance.yml
	cd $(LAB3) && ansible-playbook --syntax-check -i out/inventory.yml acceptance.yml >/dev/null && echo "syntax ok: acceptance.yml"

lab3-test: ## Validate hosts.yml, render artifacts, run 20 unit tests
	cd $(LAB3) && ./scripts/validate_hosts.py && ./scripts/render.py
	cd $(LAB3) && python3 -m unittest discover -s tests

lab3-artifacts: ## dhcpd -t and ksvalidator on rendered artifacts (Docker)
	cd $(LAB3) && ./scripts/check_artifacts.sh

# --- housekeeping ----------------------------------------------------------------
clean: ## Remove generated artifacts, local state and run records (not containers)
	rm -rf $(LAB3)/out $(LAB2)/reports $(LAB2)/drift-history $(LAB1)/drift-history
	find $(LAB1) -name .terraform -type d -prune -exec rm -rf {} +
	find $(LAB1) \( -name 'terraform.tfstate*' -o -name '*.tfplan' -o -name tfplan -o -name .artifacts \
	  -o -name drift.plan.json \) -prune -exec rm -rf {} +
	find labs -name __pycache__ -type d -prune -exec rm -rf {} +
