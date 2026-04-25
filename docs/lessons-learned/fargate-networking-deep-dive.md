# Fargate Networking Deep Dive: Branch ENIs, Pre-DNAT SG Evaluation, and the EKS Service CIDR

This document explains how networking actually works on EKS Fargate — specifically
the branch ENI model, why it causes SG evaluation to happen before DNAT, what the
Kubernetes service CIDR is and why it matters, and how packets actually flow through
VPC NACLs and security groups in a private Fargate cluster. It was written after
extended debugging of a production-grade private cluster and is intended as the
reference document AWS never wrote.

If you are debugging silent connection failures, DNS timeouts, or unexpected NACL
drops on EKS Fargate, start here.

---

## Background: How Networking Works on Regular EC2 Nodes

To understand what Fargate changes, you need to understand the baseline.

On a standard EKS cluster with EC2 managed nodes, the networking model is:

1. **One ENI per node.** The EC2 instance has an Elastic Network Interface with a
   real VPC IP (e.g., `10.0.0.10`). All pods on that node share this ENI.

2. **Pods get overlay IPs.** The VPC CNI (or Flannel, Calico, etc.) assigns each pod
   an IP from a secondary IP range or from a pool of IPs pre-allocated on the node.
   These are real VPC IPs with the VPC CNI but virtual overlay IPs with other CNIs.

3. **iptables DNAT runs in the host kernel.** `kube-proxy` installs rules in the
   Linux kernel's `netfilter` subsystem on every node. When a pod sends a packet
   to a Kubernetes Service ClusterIP, `netfilter` intercepts it in the `PREROUTING`
   chain — *before the packet touches the node's physical NIC* — and rewrites the
   destination to a real pod IP.

4. **The SG sees post-DNAT addresses.** By the time the packet exits the node ENI,
   the ClusterIP has already been rewritten. The security group attached to the node
   ENI evaluates the packet with a real pod IP as the destination. Self-referencing
   SG rules ("allow traffic between pods in this SG") work correctly.

```
Pod on node 10.0.0.10 sends to kube-dns ClusterIP:

  pod (10.0.1.5) ──► kernel netfilter DNAT ──► real CoreDNS IP (10.0.0.22:53)
                       rewrites 172.20.0.10                ▲
                       to 10.0.0.22                        │
                                                   node ENI SG evaluates
                                                   (sees 10.0.0.22, real VPC IP)
                                                   self-referencing rule matches ✓
```

This model is intuitive because it mirrors how Linux networking has always worked:
routing and NAT happen in the kernel before packets hit the wire.

---

## What a Branch ENI Is

On Fargate, AWS runs each pod inside a dedicated **microVM** — a lightweight
virtual machine managed entirely by AWS. You never see or access it. Each pod
gets its own isolated compute environment.

To give each pod a VPC network identity, the VPC CNI creates a **branch ENI**
for that pod. A branch ENI is a real Elastic Network Interface with:

- A real VPC IP address drawn from a subnet
- Its own security group assignment
- Its own AZ placement
- Its own flow log entries

The branch ENI is attached at the **hypervisor layer** — the AWS infrastructure
beneath the Fargate microVM — not inside the microVM's kernel. The pod sees a
regular Linux network interface, but that interface is backed by a branch ENI
that AWS controls at a layer the pod cannot reach.

```
AWS Fargate hypervisor
  │
  ├── Fargate microVM (pod A)
  │     └── Linux network interface (sees 10.0.0.5)
  │              │
  │         branch ENI ── SG evaluated here, at hypervisor
  │              │         OUTSIDE the microVM kernel
  │              └── VPC fabric (10.0.0.5/24)
  │
  └── Fargate microVM (pod B)
        └── Linux network interface (sees 10.0.0.6)
                 │
            branch ENI ── separate SG, separate VPC IP
                 └── VPC fabric (10.0.0.6/24)
```

This is the fundamental difference from EC2 nodes. On a node, the SG is attached
to the node ENI inside the OS's network stack. On Fargate, the SG is attached to
a branch ENI at the hypervisor, outside the pod's OS entirely.

---

## The Kubernetes Service CIDR

The service CIDR (e.g., `172.20.0.0/16` on this cluster) is a **virtual address
space that exists only inside Kubernetes**. It has no presence in the VPC:

- No route table entries for `172.20.0.0/16`
- No ENIs with addresses in this range
- No subnets
- No VPC endpoints

When you create a Kubernetes Service, the API server assigns it a stable virtual
IP from the service CIDR — a ClusterIP (e.g., `172.20.0.10` for `kube-dns`). This
IP never changes even as the pods behind the service come and go.

The ClusterIP is purely a `kube-proxy` / iptables construct. No packet with
`172.20.x.x` as its destination should ever reach a physical NIC — DNAT in the
kernel is supposed to rewrite it first. On EC2 nodes, that invariant holds. On
Fargate, it does not.

---

## Why Pre-DNAT SG Evaluation Breaks the Kubernetes Networking Model

On Fargate, the packet traversal order is:

```
1. Pod sends: src=10.0.0.5:54321  dst=172.20.0.10:53

2. Packet exits pod network namespace

3. Branch ENI SG evaluates at hypervisor:
      "Is egress to 172.20.0.10:53 permitted?"
      172.20.0.10 is not a VPC IP.
      Self-referencing rule: allows traffic to/from pod IPs in the same SG.
                             172.20.0.10 is not a pod IP → no match.
      Result: DROPPED (silently) if no explicit rule for 172.20.0.0/16

4. iptables DNAT never fires — packet was dropped before reaching the kernel
   rules that would have rewritten it.
```

The pod's kernel never gets the chance to rewrite the ClusterIP to a real pod IP,
because the packet was evaluated and dropped at the hypervisor before re-entering
the microVM for routing.

The fix is an explicit SG egress rule for the service CIDR:

```hcl
# Must explicitly allow traffic to the Kubernetes service CIDR.
# On Fargate, SG evaluation happens before iptables DNAT — the SG sees
# the ClusterIP (172.20.x.x), not the real pod IP the DNAT would produce.
egress {
  description = "Egress to Kubernetes ClusterIP services (pre-DNAT Fargate SG evaluation)"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["172.20.0.0/16"]
}
```

Without this rule, any pod-to-service communication fails silently — the packet
is dropped at the hypervisor with no log entry visible from inside the pod.

---

## Where NACLs Fit In

NACLs operate at the subnet boundary — they evaluate packets crossing from one
subnet to another. By the time a packet crosses a subnet boundary, DNAT has
already fired. NACLs see post-DNAT addresses (real VPC IPs), not ClusterIPs.

This means:

- **SG rules must account for the service CIDR** (`172.20.0.0/16`) on Fargate.
- **NACL rules only need real VPC CIDRs** — intra subnet ranges, private subnet
  ranges, etc.
- The pre-DNAT problem is a **SG-only concern**. NACLs are unaffected.

---

## Full Request/Response Trace: ArgoCD Pod → CoreDNS

Concrete example using this cluster's architecture. ArgoCD pod in the private
subnet needs to resolve `github.com`.

**Addresses:**
- ArgoCD pod (private subnet): `10.0.0.5`
- kube-dns ClusterIP: `172.20.0.10`
- CoreDNS pod (intra subnet): `10.0.128.5`
- ArgoCD SG: `sg-argocd`
- EKS primary SG (CoreDNS uses this): `sg-eks-primary`

---

### Step 1 — Pod sends DNS query

```
src: 10.0.0.5:54321   dst: 172.20.0.10:53   proto: UDP
```

ArgoCD's DNS resolver sends to the kube-dns ClusterIP, as Kubernetes pods always do.

---

### Step 2 — Branch ENI SG evaluated (pre-DNAT)

`sg-argocd` egress rules are checked against `dst=172.20.0.10:53`.

```
Rule: egress UDP 53 to 172.20.0.0/16 → ALLOW ✓
```

If this rule is absent the packet is silently dropped here. No error in pod logs.
No NACL log entry. No flow log REJECT. The packet ceases to exist at the hypervisor.

---

### Step 3 — iptables DNAT fires

Now inside the Fargate microVM's kernel, `kube-proxy`'s iptables rules run:

```
172.20.0.10:53  →  10.0.128.5:53   (CoreDNS pod's real VPC IP)
```

Packet is now:
```
src: 10.0.0.5:54321   dst: 10.0.128.5:53   proto: UDP
```

From this point forward, all network infrastructure sees real VPC addresses.

---

### Step 4 — Private subnet NACL outbound evaluated (stateless)

The packet is leaving the private subnet (`10.0.0.0/17`) heading to the intra
subnet (`10.0.128.0/18`).

```
Rule 120: egress UDP 53 to 0.0.0.0/0 → ALLOW ✓
```

NACLs are stateless — the return path (CoreDNS response back to the ephemeral
port) requires a separate inbound rule on the private NACL. That rule exists:

```
Rule 105: ingress UDP 1024-65535 from 0.0.0.0/0 → ALLOW ✓  (evaluated on response)
```

---

### Step 5 — VPC routes packet to intra subnet

Both subnets are in `10.0.0.0/16`. VPC local routing forwards the packet to
the intra subnet without traversing any gateway.

---

### Step 6 — Intra subnet NACL inbound evaluated (stateless)

Packet arriving at the intra subnet from the private subnet.

```
Rule 120: ingress UDP 53 from 10.0.0.0/17 (private_subnets_aggregate) → ALLOW ✓
```

This is scoped to `local.private_subnets_aggregate` — not `vpc_cidr`. This is
intentional: public subnets should have no NACL-permitted path into the intra
tier where kube-system workloads run.

---

### Step 7 — CoreDNS branch ENI SG evaluated

`sg-eks-primary` (the EKS-managed cluster SG that all pods without a
`SecurityGroupPolicy` use, including CoreDNS) ingress rules checked:

```
Rule: ingress UDP 53 from sg-argocd → ALLOW ✓
```

This rule must be added explicitly in Terraform. The default cluster SG only
allows traffic from itself (self-referencing). ArgoCD pods use `sg-argocd` via
`SecurityGroupPolicy`, so a cross-SG ingress rule is required.

---

### Step 8 — CoreDNS receives and processes the query

CoreDNS resolves `github.com` (forwarding to the VPC DNS resolver at `10.0.0.2`,
which is the AWS-managed DNS server at `<vpc-cidr-base>.2`) and prepares a response.

---

### Step 9 — CoreDNS sends response

```
src: 10.0.128.5:53   dst: 10.0.0.5:54321   proto: UDP
```

---

### Step 10 — Intra subnet NACL outbound evaluated (stateless)

```
Rule 135: egress UDP 1024-65535 to 10.0.0.0/17 (private_subnets_aggregate) → ALLOW ✓
```

Scoped to the private aggregate — CoreDNS responses go to private subnet pods only.
This rule is separate from the intra-to-intra ephemeral rule (rule 141) which covers
kube-system pods talking to each other.

---

### Step 11 — Private subnet NACL inbound evaluated (stateless)

```
Rule 105: ingress UDP 1024-65535 from 0.0.0.0/0 → ALLOW ✓
```

Uses `0.0.0.0/0` intentionally — return traffic from NAT gateway (internet responses
to the poller) and from CoreDNS in intra subnets both arrive at ephemeral ports.
A single permissive rule covers both paths; the routing layer (NAT gateway for
internet, VPC local for intra) provides the actual security boundary.

---

### Step 12 — ArgoCD branch ENI SG evaluated (return traffic)

AWS security groups are **stateful**. Because the original outbound UDP flow was
permitted (step 2), the return traffic is automatically allowed without a separate
inbound rule. This is the key difference from NACLs, which are stateless and require
explicit rules in both directions.

---

### Step 13 — ArgoCD pod receives the DNS response

CoreDNS delivers `github.com → 140.82.114.4`. ArgoCD proceeds to open a TCP
connection to GitHub, which follows a similar path through the NAT gateway.

---

## Practical Implications

### SG rules on Fargate

Every pod SG on Fargate must explicitly allow:
1. Egress to the Kubernetes service CIDR (`172.20.0.0/16`) for any service
   communication — including DNS to kube-dns
2. Egress to real VPC CIDRs for pod-to-pod traffic that bypasses services
   (direct pod IP communication)
3. Self-referencing rules are insufficient for service communication

### The egress enforcement gap and NetworkPolicy as compensation

The pre-DNAT SG evaluation model creates an asymmetric enforcement surface that
has a direct consequence for pod-to-service access control.

**Egress side — control is lost.**
A pod's egress SG must allow `172.20.0.0/16` (the full service CIDR) for any
service communication to work. At egress evaluation time, all Kubernetes services
look identical — they are all `172.20.x.x`. The SG cannot distinguish "allow
traffic to CoreDNS" from "allow traffic to some other service in a different subnet
tier." The egress SG is reduced to a binary control: can this pod use Kubernetes
services at all. Fine-grained per-service or per-destination-tier egress enforcement
at the SG level is not possible on Fargate.

**Ingress side — control is intact.**
The destination pod's ingress SG evaluates the packet post-DNAT. It sees the real
source IP (`10.0.0.5`) and the real destination port. Ingress rules can still be
scoped to specific source SGs or source CIDRs. "Allow DNS only from `sg-argocd`"
works correctly. The ingress half of SG enforcement is unaffected.

**Practical consequence: NACLs become load-bearing for subnet segmentation.**
With egress SGs unable to enforce which services a pod can reach, the only control
left for subnet-level egress segmentation is the NACL at the subnet boundary. A
NACL can enforce "pods in private subnets can reach pods in intra subnets on port
53" and nothing else from public. That is subnet-granularity control — it
distinguishes tiers but cannot distinguish services within a tier or pods within
a subnet.

**The correct compensation control is NetworkPolicy.**
`NetworkPolicy` operates inside the Kubernetes network layer, where DNAT has
already resolved ClusterIPs to real pod IPs. A NetworkPolicy egress rule can
specify `podSelector`, `namespaceSelector`, or `ipBlock` against actual pod
addresses — the virtual service CIDR is never involved. This restores fine-grained
egress enforcement that SGs cannot provide on Fargate:

```yaml
# Example: restrict an iss-tracker pod to only reach CoreDNS and DynamoDB
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
        podSelector:
          matchLabels:
            k8s-app: kube-dns
    ports:
      - protocol: UDP
        port: 53
  - to:
      - ipBlock:
          cidr: 10.0.128.0/18   # intra subnets — VPC endpoints
    ports:
      - protocol: TCP
        port: 443
```

This is why NetworkPolicy is listed as a required secure-baseline control, not
optional cleanup. The SG model on Fargate makes it the only layer capable of
enforcing egress access control at per-service or per-pod granularity.

**Layer summary:**

| Layer | Granularity | Fargate egress gap? |
|-------|-------------|---------------------|
| Security group egress | Service CIDR only (all services indistinguishable) | Yes — enforces "can use services" only |
| NACL | Subnet tier (post-DNAT IP ranges) | No gap — but only subnet-granularity |
| NetworkPolicy | Per-pod, per-namespace, per-port | No gap — operates post-DNAT |
| Security group ingress | Per-source-SG or per-source-CIDR | No gap — destination sees real source IP |

### NACL rules on Fargate

NACLs behave the same as on EC2 nodes — they only see real VPC addresses.
The Fargate-specific concerns are:
1. **Stateless** — every flow needs both an outbound rule and an inbound return rule
2. **Both directions at every subnet boundary** — a packet crossing private → intra
   requires an outbound rule on the private NACL and an inbound rule on the intra NACL
3. **Scope to subnet tier CIDRs, not `vpc_cidr`** — the VPC CIDR spans all tiers
   including public; NACL rules between tiers should be scoped to the specific
   tier CIDRs that legitimately originate the traffic

### The pod IP exhaustion problem

Because each Fargate pod gets a dedicated branch ENI with a real VPC IP, pod
density is bounded by subnet address space. A `/24` gives 251 usable addresses.
Subtract VPC-reserved addresses, ENIs for VPC endpoints, and ENIs for other
infrastructure, and the practical pod ceiling per subnet is well under 251.

On EC2 with an overlay CNI (Flannel, Cilium), pod IPs come from a virtual address
space entirely separate from the VPC. A single `/24` node subnet can host a node
running hundreds of pods. On Fargate, the same `/24` limits you to roughly 200
pods across all AZs sharing that subnet. This is a hard architectural constraint
and a primary reason to allocate private subnets generously (a `/17` provides
128 `/24`s of expansion room).

### Why this doesn't match the AWS documentation

AWS's documentation describes the branch ENI model accurately but incompletely.
The pre-DNAT SG evaluation consequence is mentioned in one paragraph in the VPC
CNI documentation, not in the EKS Fargate guide, not in the SecurityGroupPolicy
guide, and not in any troubleshooting runbook. The practical implication — that
you must add the Kubernetes service CIDR to your pod SG rules — is left as an
exercise for the operator.

The debugging path when this is misconfigured: pods appear healthy (no crash
loops, no OOM), DNS queries time out, and there are no REJECT entries in VPC
flow logs because the packet was dropped at the hypervisor before it was
flow-logged as a VPC packet. The silence is the tell.

---

## Summary Checklist for a New Fargate Namespace

When adding a new namespace with a `SecurityGroupPolicy`, every SG assigned to
pods in that namespace must have:

| Rule | Why |
|------|-----|
| Egress to `172.20.0.0/16` all ports | ClusterIP service communication (pre-DNAT) |
| Egress UDP/TCP 53 to `172.20.0.0/16` | DNS via kube-dns ClusterIP (pre-DNAT) |
| Egress TCP 443 to intra subnet CIDRs | Kubernetes API server |
| Egress TCP 443 to VPC endpoint CIDRs | AWS service calls via VPC endpoints |
| Egress to internet (if needed) | NAT gateway for external API calls |
| Ingress from cluster SG (TCP 443, TCP 4443) | Webhook callbacks from API server |

And the EKS primary cluster SG (`eks_primary_sg_id`) must have:
| Rule | Why |
|------|-----|
| Ingress UDP/TCP 53 from the new pod SG | CoreDNS access for the new namespace |