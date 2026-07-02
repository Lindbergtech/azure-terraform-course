# Terraform on Azure (azapi-first)

The companion repository for the Udemy course *Terraform on Azure, azapi-first —
build a real workload from zero*. You are looking at your own private copy,
created from the course template.

What you build over the course: a private, observable URL shortener API on Azure
Container Apps, backed by Postgres Flexible Server, with secrets in Key Vault and
telemetry in Application Insights — all in Terraform, azapi-first.

---

## How the code-along works

The intended path is **code-along**: type the Terraform alongside the videos.
Your `infra/` directory is **empty on day 0** — Module 1 starts you typing the
first `.tf` file from scratch, which is itself a teaching beat (why `providers.tf`
exists, what would otherwise go into `main.tf`, when to split files).

Every module's finished state is captured under `solutions/module-N-end/`. Use
these checkpoints to diff against your own work, to recover from a typo, or to
drop in mid-course:

```sh
cp solutions/module-3-end/*.tf infra/    # jump to the end of Module 3
cp solutions/module-7-end/*.tf infra/    # the complete final example
```

No branches, no tags, no stashing — a checkpoint is just a folder you copy.

Dropping in still needs the backend: bootstrap it (step 3) and run
`terraform init -backend-config=../bootstrap/backend.tfbackend` (step 4) before
`terraform apply`.

---

## Prerequisites

You need an **Azure subscription** (free tier or pay-as-you-go is fine) and the
tools below installed locally. Versions are pinned to what the course is recorded
against; later patch releases of the same minor should be fine.

| Tool                 | Pinned version | Why                                       |
| -------------------- | -------------- | ----------------------------------------- |
| Terraform            | `~> 1.11`      | The infrastructure tool the course is about. |
| Azure CLI (`az`)     | `>= 2.60`      | Sign-in, the backend bootstrap script, OIDC setup. |
| GitHub CLI (`gh`)    | `>= 2.40`      | OIDC pipeline setup in Module 7.          |
| Go                   | `1.22`         | Building the URL shortener locally (Module 4 onwards). |
| Docker               | latest stable  | **Optional** — only if you want to build the app image yourself. The Container App pulls a prebuilt image by default. |
| `git`                | any recent     | Cloning and version-controlling your work. |

VS Code with the **Microsoft Terraform** and **HashiCorp Azure Provider (azapi)**
extensions is the recorded editor setup — not required, but the diagnostics
quoted in the videos come from those extensions.

### Install — macOS (Homebrew)

```sh
brew install hashicorp/tap/terraform
brew install azure-cli
brew install gh
brew install go
brew install --cask docker   # optional
```

### Install — Windows (winget)

```powershell
winget install --id=Hashicorp.Terraform -e
winget install --id=Microsoft.AzureCLI -e
winget install --id=GitHub.cli         -e
winget install --id=GoLang.Go          -e
winget install --id=Docker.DockerDesktop -e   # optional
```

Open a fresh shell after install so the new tools land on `PATH`.

### Verify

```sh
terraform version    # Terraform v1.11.x or later
az version           # azure-cli 2.60+
gh --version         # gh version 2.40+
go version           # go1.22.x
docker --version     # optional
```

---

## First-time setup

This is the exact sequence the course's Gate 1 verification walks on a clean
machine. No off-script steps.

### 1. Clone your copy

```sh
git clone https://github.com/<your-username>/<your-repo-name>.git
cd <your-repo-name>
```

### 2. Sign in to Azure

```sh
az login
az account set --subscription "<your-subscription-id>"
```

### 3. Bootstrap the remote state backend (one time, ever)

The backend storage account holds Terraform state for the rest of the course. It
is created **once** by a script — not by Terraform itself — to avoid the
chicken-and-egg problem.

The script firewalls the state storage account to a single IP — yours. Find it
with `curl -s ifconfig.me` (macOS / Linux) or
`(Invoke-WebRequest ifconfig.me -UseBasicParsing).Content.Trim()` (PowerShell),
then pass it in:

**bash / macOS / Linux:**

```sh
./bootstrap/backend.sh <your-public-ip>
```

**PowerShell / Windows:**

```powershell
./bootstrap/backend.ps1 -AllowedIp <your-public-ip>
```

The script writes `bootstrap/backend.tfbackend` (gitignored, per-student) with
the four values `terraform init` needs. It also grants your signed-in user
`Storage Blob Data Contributor` on the new account so Terraform can read/write
state with Entra auth — give RBAC ~30–60s to propagate before the next step.

### 4. Initialize Terraform against the backend

Once you have written your first `.tf` files (Module 1) or dropped in a
checkpoint:

```sh
cd infra
terraform init -backend-config=../bootstrap/backend.tfbackend
```

### 5. Deploy the running example

```sh
terraform apply
```

First deploy takes ~10 minutes. Outputs include the URL shortener's FQDN.

### 6. Smoke-test the shortener

Replace `<fqdn>` with the `container_app_fqdn` output from `terraform apply`:

```sh
# Create a short code — expect HTTP 200 and a JSON body containing the code.
curl -i -X POST "https://<fqdn>/shorten" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com"}'

# Follow the short code — expect HTTP 302 with Location: https://example.com
curl -i "https://<fqdn>/<code>"
```

`curl -L` will transparently follow the redirect if you'd rather see the final
response.

---

## Region

The course is recorded and verified against **Sweden Central**. Other regions
should work but are not personally tested.

If you do change region, override **both** `location` and `location_short`
together. There is deliberately no derivation and no lookup map: the short code
is a free-form 3–4 char slug that goes into resource names, and the long name is
whatever `az account list-locations` shows. Pick one pair and stick with it:

```sh
terraform apply \
  -var location=westeurope \
  -var location_short=weu
```

The defaults (`swedencentral` / `swc`) live in `infra/variables.tf` once you have
authored it.

---

## Cost

The fully deployed running example costs **~$2/day** if left up. The dominant
cost is Postgres Flexible Server (cheapest burstable SKU).

To stop costs at the end of a session:

```sh
cd infra
terraform destroy -auto-approve
```

The URL shortener's data is regeneratable; nothing here is worth preserving
between sessions.

A budget alert is the first thing the course teaches you to set. Do not skip it.

---

## Observability — wiring up the 5xx alert

Module 5 ships a metric alert that fires when the Container App returns 5xx
responses. By default the alert sends to a placeholder address
(`alerts-noreply@example.invalid`) so the action group exists end-to-end without
spamming a real inbox. To actually receive notifications, override `alert_email`:

```sh
terraform apply -var alert_email=you@example.com
```

Or put it in a `terraform.tfvars` (gitignored):

```hcl
alert_email = "you@example.com"
```

---

## CI / CD (Module 7)

Module 7 wires your repository to Azure with workload identity federation so
`.github/workflows/terraform.yml` can `plan` on PRs and `apply` on pushes to
`main` — no client secret anywhere. The pipeline file ships here from day 0 but
is set to run only on manual dispatch, so it won't fire before you have wired
OIDC. The step-by-step runbook is attached to the Module 7 lesson on Udemy. You
don't need it for Modules 1–6.

---

## Repository layout

```
.
├── README.md
├── app/                  # URL shortener container source (Go), informational
├── bootstrap/
│   ├── backend.sh        # remote-state bootstrap, bash
│   └── backend.ps1       # remote-state bootstrap, PowerShell
├── infra/                # empty on day 0 — you build this up module by module
├── solutions/
│   └── module-N-end/     # end-state checkpoints, one folder per module
├── scripts/              # lint + snapshot validation used by CI
└── .github/workflows/
    └── terraform.yml     # OIDC pipeline (Module 7); manual dispatch only
```

---

## Getting help

The course Q&A on Udemy is the primary support channel — post your lesson number
and what you are seeing.
