# Runbook Standards — ISS Tracker

Standards for operational runbooks covering infrastructure provisioning,
application deployment, and cluster lifecycle procedures.

**Update this document when:**
- A new required runbook section is identified from operational experience
- A verification or failure-mode pattern recurs across multiple runbooks
- The standard for command formatting or structure changes

---

## Runbook Update Triggers

Every runbook shall include an **Update this runbook when:** block immediately
after the title. This block documents the conditions under which the runbook
must be revised to remain accurate. A runbook without update triggers has no
defined maintenance contract and will silently drift from reality.

Typical update triggers for a provisioning runbook:

```
**Update this runbook when:**
- A new provisioning step is added or an existing step is removed
- A helm chart version is bumped (verify commands and flag names remain valid)
- A Secrets Manager key name or structure changes
- A bootstrap script path or behavior changes
- A new known failure mode is discovered during an actual provisioning run
- The target end state changes (new workload, new namespace, new endpoint)
```

The update trigger list is not exhaustive — it names the most likely sources
of drift for that specific runbook. When a change is made to any artifact
referenced by a runbook step (a script, a manifest path, a helm chart, a
Terraform output), the author of that change is responsible for updating the
runbook in the same commit or PR.

---

## When a Runbook Is Required

A runbook is required for any multi-step procedure that:
- Involves manual actions on live infrastructure
- Has an ordering dependency that is not self-evident from the code
- Requires out-of-band secrets, credentials, or external tool configuration
- Could leave infrastructure in a partially-provisioned state if a step is
  skipped or performed out of order

Examples: provisioning a new cluster from scratch, onboarding a new namespace,
rotating secrets, tearing down and re-provisioning the environment.

Runbooks live in `docs/runbooks/`. They are written documents, not scripts.
Scripts automate; runbooks provide the verified, reasoned sequence that a human
or machine reader follows to reach a known end state.

---

## Required Sections

Every runbook must contain the following sections in order.

### 1. Starting State and Prerequisites

Document the exact state the environment must be in before the runbook begins.
Distinguish between:

- **Infrastructure prerequisites** — resources that must already exist and be
  operational (e.g., "S3 state backend provisioned," "ECR images built and pushed")
- **Tool prerequisites** — CLI tools and versions required on the operator's
  workstation or the bastion host (e.g., Terraform, kubectl, helm, AWS CLI,
  `envsubst`)
- **Access prerequisites** — IAM permissions, VPN or bastion access, kubeconfig
  context configured

Prerequisites are not steps — they are preconditions. If a prerequisite is not
met, the runbook cannot start. Reference the runbook or procedure that provisions
each prerequisite if one exists.

### 2. Objective and Target End State

One paragraph. Describe what the runbook accomplishes and what a fully successful
execution looks like from the outside. Be specific: name the services that should
be running, the endpoints that should respond, and any observable state (e.g.,
"ArgoCD is syncing the api and poller Applications; `curl /positions` returns
ISS position data").

### 3. Steps

Each step is a discrete, verifiable action. Step content must include:

**Action description** — one sentence stating what this step does and why it
is necessary at this point in the sequence.

**Command** — the exact command to run, including all flags, with placeholders
clearly marked. Use shell variable assignment (`INSTANCE_ID=$(...)`) to reduce
copy-paste errors on derived values:

```bash
# Correct — derives the value; operator does not need to look it up
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=iss-tracker-eks-bastion" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text --region us-east-2)
```

**Verification** — a command the operator runs immediately after the action to
confirm it succeeded before proceeding. Verification must produce observable
output, not just exit 0:

```bash
# Correct — output shows the pod is actually ready
kubectl rollout status deployment argocd-server -n argocd

# Incorrect — exits 0 on success but produces no output the operator can read
kubectl apply -f manifest.yaml && echo "done"
```

**Known failure modes** — the one or two most likely reasons this step fails,
with the diagnostic command to confirm and the corrective action. Focus on
failures that are non-obvious or that have been encountered in this project.
Reference lessons-learned documents where a failure mode has a deeper writeup.

### 4. Caveats and Ordering Rationale

A dedicated section (or inline callout where appropriate) explaining:
- Why steps that appear independent must nevertheless be performed in a specific
  order
- Why a step that looks overly permissive or unusual is correct
- Any timing dependencies (e.g., "ESO must complete its initial sync before
  deploy.sh runs — deploy.sh reads K8s secrets at execution time, not at sync
  time")

This section exists specifically for the non-obvious. If the reason a step comes
before another is evident from the action descriptions, a separate rationale entry
is not needed. Write it when a reader following the runbook for the first time
would reasonably question the sequence.

### 5. End-to-End Smoke Test

A final verification block that confirms the full target end state — not just
that the last step succeeded, but that the system behaves correctly as a whole.
The smoke test must exercise the primary user-facing path end-to-end:

```bash
# Example — ISS tracker smoke test
ALB_DNS=$(kubectl get ingress -n iss-tracker \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
curl "http://${ALB_DNS}/positions"
# Expected: JSON array of ISS position records, HTTP 200
```

Include expected output or observable success criteria explicitly. "No errors"
is not an acceptable success criterion.

---

## Command Formatting Rules

- All commands must be copy-paste executable. No `<PLACEHOLDER>` values that
  require manual substitution — derive them via shell commands or environment
  variables set earlier in the runbook.
- Multi-line commands use `\` continuation and align arguments for readability.
- Commands that must run on the bastion (not locally) are labeled explicitly.
  Unlabeled commands are assumed to run locally.
- Destructive or irreversible commands (`terraform destroy`, `kubectl delete`,
  secret rotation) are called out with a warning before the command block.

---

## Anti-patterns

- **No step without a verification.** A step that cannot be verified is a step
  that cannot be confirmed as done. If verification seems unnecessary, the step
  is probably too small to be its own step.
- **No verification that only checks exit code.** Verification must produce
  output the operator can read and judge correct.
- **No abstract instructions.** "Configure kubectl" is not a step. "Run
  `aws eks update-kubeconfig --name iss-tracker-eks --region us-east-2`" is.
- **No prerequisites buried in steps.** If something must be true before the
  runbook starts, it belongs in the Prerequisites section, not step 1.
- **No runbook that relies on operator tribal knowledge.** A runbook that a
  new team member cannot follow without asking questions is incomplete.