# The running example. Single-file by design — Module 7 splits it.
#
# Slice 004 (this file): wires the data tier and identity. UAMI on the
# Container App reads DATABASE_URL out of Key Vault (RBAC mode, private-only
# via PE into snet-pe). Postgres Flexible Server (burstable Standard_B1ms,
# 32GB, no HA) lives in snet-pg's delegated subnet, registered against the
# privatelink.postgres.database.azure.com zone. random_password generates
# the admin password; it lands in KV as a secret and never appears in
# terraform output. End-to-end: POST /shorten → 200, GET /<code> → 302.

# ── Random suffix (stable across applies, unique per student) ────────────────

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
  numeric = true
}

# ── Subscription / client config ─────────────────────────────────────────────

data "azapi_client_config" "current" {}

# ── Resource group ───────────────────────────────────────────────────────────

resource "azapi_resource" "rg" {
  type      = "Microsoft.Resources/resourceGroups@2021-04-01"
  name      = "rg-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = "/subscriptions/${data.azapi_client_config.current.subscription_id}"
  location  = var.location
}

# ── Networking — VNet, subnets, NAT Gateway, NSG, private DNS zones ──────────

resource "azapi_resource" "vnet" {
  type      = "Microsoft.Network/virtualNetworks@2024-01-01"
  name      = "vnet-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    properties = {
      addressSpace = {
        addressPrefixes = ["10.0.0.0/16"]
      }
    }
  }
}

# Public IP + NAT Gateway. The NAT Gateway gives the Container Apps subnet a
# stable outbound SNAT address — required so a real workload could be allowed
# through partner firewalls. ~$1/day fixed cost is accepted per the PRD.

resource "azapi_resource" "pip_nat" {
  type      = "Microsoft.Network/publicIPAddresses@2024-01-01"
  name      = "pip-nat-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    sku = { name = "Standard" }
    properties = {
      publicIPAllocationMethod = "Static"
      publicIPAddressVersion   = "IPv4"
    }
  }
}

resource "azapi_resource" "natgw" {
  type      = "Microsoft.Network/natGateways@2024-01-01"
  name      = "natgw-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    sku = { name = "Standard" }
    properties = {
      idleTimeoutInMinutes = 4
      publicIpAddresses    = [{ id = azapi_resource.pip_nat.id }]
    }
  }
}

# One NSG per subnet — defense in depth. Default rules only in v1: AllowVNet
# inbound/outbound, AllowAzureLoadBalancer inbound, DenyAll. Delegated subnets
# (CAE, Postgres Flex) accept an NSG but the managed services require specific
# platform traffic; sticking to default rules keeps the attachment safe while
# still giving us a place to add bespoke rules later.

resource "azapi_resource" "nsg_cae" {
  type      = "Microsoft.Network/networkSecurityGroups@2024-01-01"
  name      = "nsg-cae-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    properties = {}
  }
}

resource "azapi_resource" "nsg_pg" {
  type      = "Microsoft.Network/networkSecurityGroups@2024-01-01"
  name      = "nsg-pg-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    properties = {}
  }
}

resource "azapi_resource" "nsg_pe" {
  type      = "Microsoft.Network/networkSecurityGroups@2024-01-01"
  name      = "nsg-pe-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    properties = {}
  }
}

resource "azapi_resource" "nsg_reserved" {
  type      = "Microsoft.Network/networkSecurityGroups@2024-01-01"
  name      = "nsg-reserved-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    properties = {}
  }
}

# Subnets are declared as child resources (rather than inline in the VNet
# body) so Module 7 can teach them as their own type. Azure ARM serialises
# writes against a single VNet — parallel subnet creates collide with
# AnotherOperationInProgress. We let Terraform schedule them in parallel and
# rely on azapi's retry block to absorb the conflict, rather than chaining
# siblings with depends_on. ReferencedResourceNotProvisioned covers the
# eventual-consistency lag where the NAT Gateway / NSG isn't visible to the
# network RP yet, even though Terraform has already seen the create return.
# The retry block is identical on each subnet — written inline rather than
# pulled into a shared local so Module 7 can read one resource end-to-end.

resource "azapi_resource" "snet_cae" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = "snet-cae"
  parent_id = azapi_resource.vnet.id

  body = {
    properties = {
      addressPrefixes = ["10.0.0.0/23"]
      delegations = [{
        name = "delegation"
        properties = {
          serviceName = "Microsoft.App/environments"
        }
      }]
      natGateway           = { id = azapi_resource.natgw.id }
      networkSecurityGroup = { id = azapi_resource.nsg_cae.id }
    }
  }

  retry = {
    error_message_regex = [
      "AnotherOperationInProgress",
      "ReferencedResourceNotProvisioned",
      "RetryableError",
    ]
  }
}

resource "azapi_resource" "snet_pg" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = "snet-pg"
  parent_id = azapi_resource.vnet.id

  body = {
    properties = {
      addressPrefixes = ["10.0.2.0/28"]
      delegations = [{
        name = "delegation"
        properties = {
          serviceName = "Microsoft.DBforPostgreSQL/flexibleServers"
        }
      }]
      networkSecurityGroup = { id = azapi_resource.nsg_pg.id }
    }
  }

  retry = {
    error_message_regex = [
      "AnotherOperationInProgress",
      "ReferencedResourceNotProvisioned",
      "RetryableError",
    ]
  }
}

resource "azapi_resource" "snet_pe" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = "snet-pe"
  parent_id = azapi_resource.vnet.id

  body = {
    properties = {
      addressPrefixes                   = ["10.0.3.0/27"]
      networkSecurityGroup              = { id = azapi_resource.nsg_pe.id }
      privateEndpointNetworkPolicies    = "Enabled"
      privateLinkServiceNetworkPolicies = "Enabled"
    }
  }

  retry = {
    error_message_regex = [
      "AnotherOperationInProgress",
      "ReferencedResourceNotProvisioned",
      "RetryableError",
    ]
  }
}

resource "azapi_resource" "snet_reserved" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-01-01"
  name      = "snet-reserved"
  parent_id = azapi_resource.vnet.id

  body = {
    properties = {
      addressPrefixes      = ["10.0.4.0/27"]
      networkSecurityGroup = { id = azapi_resource.nsg_reserved.id }
    }
  }

  retry = {
    error_message_regex = [
      "AnotherOperationInProgress",
      "ReferencedResourceNotProvisioned",
      "RetryableError",
    ]
  }
}

# Private DNS zones — global zones, linked to the VNet. No private endpoints
# created in this slice; slice 004 attaches Postgres Flex and Key Vault PEs
# into snet-pe and registers them against these zones.
#
# Destroy ordering: ARM marks the child virtualNetworkLinks DELETE as
# successful before its removal has fully propagated into the parent zone's
# nested-resource list. Terraform then issues the parent zone DELETE while
# the link is still listed and ARM responds 409 CannotDeleteResource. The
# inline retry block below absorbs that 409 — by the time the retry fires,
# ARM's view has caught up. Project convention: use azapi retry for ARM
# eventual-consistency, not depends_on or time_sleep.

resource "azapi_resource" "pdns_postgres" {
  type      = "Microsoft.Network/privateDnsZones@2024-06-01"
  name      = "privatelink.postgres.database.azure.com"
  parent_id = azapi_resource.rg.id
  location  = "global"

  body = {
    properties = {}
  }

  retry = {
    error_message_regex = [
      "CannotDeleteResource",
    ]
  }
}

resource "azapi_resource" "pdns_keyvault" {
  type      = "Microsoft.Network/privateDnsZones@2024-06-01"
  name      = "privatelink.vaultcore.azure.net"
  parent_id = azapi_resource.rg.id
  location  = "global"

  body = {
    properties = {}
  }

  retry = {
    error_message_regex = [
      "CannotDeleteResource",
    ]
  }
}

resource "azapi_resource" "pdns_postgres_link" {
  type      = "Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01"
  name      = "vnet-link"
  parent_id = azapi_resource.pdns_postgres.id
  location  = "global"

  body = {
    properties = {
      registrationEnabled = false
      virtualNetwork = {
        id = azapi_resource.vnet.id
      }
    }
  }
}

resource "azapi_resource" "pdns_keyvault_link" {
  type      = "Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01"
  name      = "vnet-link"
  parent_id = azapi_resource.pdns_keyvault.id
  location  = "global"

  body = {
    properties = {
      registrationEnabled = false
      virtualNetwork = {
        id = azapi_resource.vnet.id
      }
    }
  }
}

# ── Identity — User-Assigned Managed Identity ────────────────────────────────
#
# One UAMI for the Container App. Used to read DATABASE_URL out of Key Vault
# at runtime. principalId is the object id Azure RBAC role assignments must
# reference; clientId is what apps use against IMDS / DefaultAzureCredential
# (not needed in v1 because Container Apps resolves the KV secret reference
# itself, but exporting it costs nothing and is useful in module 7 callouts).

resource "azapi_resource" "uami" {
  type      = "Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31"
  name      = "id-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {}

  response_export_values = ["properties.principalId", "properties.clientId"]
}

# ── Secrets — Key Vault (RBAC mode, private-only) + role assignment + PE ─────
#
# RBAC mode (no access policies) per the PRD. publicNetworkAccess = Disabled
# locks the data plane to the VNet via the private endpoint into snet-pe;
# ARM control-plane operations (including the secrets PUT below) still go
# through management.azure.com regardless, so Terraform can write secrets
# from a laptop without a public-access escape hatch.
#
# Soft delete is mandatory in Azure and stays on (7-day retention, the
# minimum). enablePurgeProtection is intentionally OMITTED rather than set
# to false — Azure's KV API rejects the literal `false` at create time
# ("Enabling the purge protection for a vault is an irreversible action."),
# treating the property as a one-way switch. Leaving it unset gives us the
# default (no purge protection), which is what the course wants: terraform
# destroy is a clean teardown, and the random_string suffix on the vault
# name regenerates on the next apply so there's no collision with the
# previous run's soft-deleted vault. Gate 009 (destroy → redeploy ×2) is
# what verifies the cycle end to end.

resource "azapi_resource" "kv" {
  type      = "Microsoft.KeyVault/vaults@2023-07-01"
  name      = "kv-${var.environment}-${var.location_short}-${var.common_name}-${random_string.suffix.result}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    properties = {
      tenantId = data.azapi_client_config.current.tenant_id
      sku = {
        family = "A"
        name   = "standard"
      }
      enableRbacAuthorization   = true
      publicNetworkAccess       = "Disabled"
      enableSoftDelete          = true
      softDeleteRetentionInDays = 7
      networkAcls = {
        bypass        = "AzureServices"
        defaultAction = "Deny"
      }
    }
  }

  response_export_values = ["properties.vaultUri"]
}

# Key Vault Secrets User on the vault scope, granted to the UAMI. The role
# definition GUID is the well-known constant for "Key Vault Secrets User".
# uuidv5 keeps the assignment name stable across applies for the same
# (principalId, role, scope) tuple — destroy + apply gets a new principalId
# (UAMI is recreated), which yields a new GUID, so no stale-assignment
# collision.

resource "azapi_resource" "ra_uami_kv_secrets_user" {
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  name      = uuidv5("oid", "${azapi_resource.uami.output.properties.principalId}/4633458b-17de-408a-b874-0445c86b69e6/${azapi_resource.kv.id}")
  parent_id = azapi_resource.kv.id

  body = {
    properties = {
      roleDefinitionId = "/subscriptions/${data.azapi_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
      principalId      = azapi_resource.uami.output.properties.principalId
      principalType    = "ServicePrincipal"
    }
  }
}

# Private endpoint for KV into snet-pe. The DNS zone group registers the PE
# in the privatelink.vaultcore.azure.net zone slice 003 already linked to
# the VNet, so the Container App resolves the vault FQDN to a private IP.

resource "azapi_resource" "pe_kv" {
  type      = "Microsoft.Network/privateEndpoints@2024-01-01"
  name      = "pe-kv-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    properties = {
      subnet = { id = azapi_resource.snet_pe.id }
      privateLinkServiceConnections = [{
        name = "kv"
        properties = {
          privateLinkServiceId = azapi_resource.kv.id
          groupIds             = ["vault"]
        }
      }]
    }
  }
}

resource "azapi_resource" "pe_kv_dns_zone_group" {
  type      = "Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01"
  name      = "default"
  parent_id = azapi_resource.pe_kv.id

  body = {
    properties = {
      privateDnsZoneConfigs = [{
        name = "vaultcore"
        properties = {
          privateDnsZoneId = azapi_resource.pdns_keyvault.id
        }
      }]
    }
  }
}

# ── Data — Postgres Flexible Server ──────────────────────────────────────────
#
# Cheapest burstable SKU per the PRD cost target (<$2/day with everything up).
# Network: VNet integration via subnet delegation (snet-pg from slice 003),
# linked to the privatelink.postgres.database.azure.com zone — server FQDN
# resolves to a private IP from the VNet. No HA, 7-day backup retention
# (the default minimum), 32GB storage. Auth is password-only in v1; the Entra
# auth refactor is a future module 7 lesson per the PRD.
#
# administratorLoginPassword goes in sensitive_body so Terraform never echoes
# it through plan/apply output and azapi doesn't try to drift-check it
# against the response (the API never returns the password).

resource "random_password" "pg_admin" {
  length           = 24
  special          = true
  override_special = "_-"
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
}

resource "azapi_resource" "pg" {
  type      = "Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview"
  name      = "pg-${var.environment}-${var.location_short}-${var.common_name}-${random_string.suffix.result}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    sku = {
      name = "Standard_B1ms"
      tier = "Burstable"
    }
    properties = {
      version            = "16"
      administratorLogin = "pgadmin"
      storage = {
        storageSizeGB = 32
      }
      backup = {
        backupRetentionDays = 7
        geoRedundantBackup  = "Disabled"
      }
      highAvailability = {
        mode = "Disabled"
      }
      network = {
        delegatedSubnetResourceId   = azapi_resource.snet_pg.id
        privateDnsZoneArmResourceId = azapi_resource.pdns_postgres.id
      }
      authConfig = {
        passwordAuth        = "Enabled"
        activeDirectoryAuth = "Disabled"
      }
    }
  }

  sensitive_body = {
    properties = {
      administratorLoginPassword = random_password.pg_admin.result
    }
  }

  response_export_values = ["properties.fullyQualifiedDomainName"]

  depends_on = [
    azapi_resource.pdns_postgres_link,
  ]
}

resource "azapi_resource" "pg_db" {
  type      = "Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview"
  name      = "urlshortener"
  parent_id = azapi_resource.pg.id

  body = {
    properties = {
      charset   = "UTF8"
      collation = "en_US.utf8"
    }
  }
}

# DATABASE_URL — libpq URI written to Key Vault. The Container App pulls this
# at startup via the UAMI; the password never appears in any output beyond
# the standard (sensitive value) marker because it transitively derives from
# random_password.pg_admin.result.
#
# random_password is constrained to alphanumerics + `_-` (URL-unreserved)
# so no percent-encoding is needed in the userinfo segment.
#
# This is azapi_resource_action (PUT), not azapi_resource. Reason: ARM's
# proxy resource type Microsoft.KeyVault/vaults/secrets is PUT-only —
# DELETE returns 405 DeleteNotSupported. Modelling it as a full-lifecycle
# azapi_resource means terraform destroy fails on the way down (and with
# publicNetworkAccess=Disabled, the data-plane DELETE isn't reachable from
# a laptop anyway). The action variant issues the same PUT on apply to
# create / update, but on destroy it just drops out of state — the parent
# vault's DELETE then cascade-soft-deletes the secret along with it.

resource "azapi_resource_action" "kv_secret_db_url" {
  type        = "Microsoft.KeyVault/vaults@2023-07-01"
  resource_id = azapi_resource.kv.id
  action      = "secrets/database-url"
  method      = "PUT"

  body = {
    properties = {
      value = "postgresql://pgadmin:${random_password.pg_admin.result}@${azapi_resource.pg.output.properties.fullyQualifiedDomainName}:5432/urlshortener?sslmode=require"
    }
  }

  depends_on = [
    azapi_resource.pg_db,
  ]
}

# ── Observability — Log Analytics workspace ──────────────────────────────────

resource "azapi_resource" "law" {
  type      = "Microsoft.OperationalInsights/workspaces@2022-10-01"
  name      = "log-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    properties = {
      sku = {
        name = "PerGB2018"
      }
      retentionInDays = 30
    }
  }

  response_export_values = ["properties.customerId"]
}

# Shared keys are read at plan time via a data-source action so the Container
# Apps Environment can route logs to this workspace.
data "azapi_resource_action" "law_shared_keys" {
  type                   = "Microsoft.OperationalInsights/workspaces@2022-10-01"
  resource_id            = azapi_resource.law.id
  action                 = "sharedKeys"
  method                 = "POST"
  response_export_values = ["primarySharedKey"]
}

# ── Compute — Container Apps Environment + Container App ─────────────────────

resource "azapi_resource" "cae" {
  type      = "Microsoft.App/managedEnvironments@2024-03-01"
  name      = "cae-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    properties = {
      appLogsConfiguration = {
        destination = "log-analytics"
        logAnalyticsConfiguration = {
          customerId = azapi_resource.law.output.properties.customerId
          sharedKey  = data.azapi_resource_action.law_shared_keys.output.primarySharedKey
        }
      }
      # VNet-injected so slice 004's Postgres Flex + Key Vault PE are reachable
      # over private IPs only. internal=false keeps external HTTPS ingress on
      # *.azurecontainerapps.io; outbound traffic egresses via the NAT Gateway
      # attached to snet-cae.
      vnetConfiguration = {
        infrastructureSubnetId = azapi_resource.snet_cae.id
        internal               = false
      }
    }
  }
}

resource "azapi_resource" "app" {
  type      = "Microsoft.App/containerApps@2024-03-01"
  name      = "ca-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location

  body = {
    identity = {
      type = "UserAssigned"
      userAssignedIdentities = {
        (azapi_resource.uami.id) = {}
      }
    }
    properties = {
      managedEnvironmentId = azapi_resource.cae.id
      configuration = {
        ingress = {
          external      = true
          targetPort    = 8080
          transport     = "auto"
          allowInsecure = false
        }
        # Container Apps resolves keyVaultUrl using the assigned identity at
        # deploy time and again on rotation. The UAMI must already have
        # Key Vault Secrets User on the vault, the PE must already exist,
        # and the privatelink DNS record must be in place — depends_on
        # below makes that ordering explicit so first-apply doesn't race.
        secrets = [
          {
            name        = "database-url"
            keyVaultUrl = "${azapi_resource.kv.output.properties.vaultUri}secrets/database-url"
            identity    = azapi_resource.uami.id
          }
        ]
      }
      template = {
        containers = [
          {
            name  = "urlshortener"
            image = "ghcr.io/${var.image_owner}/urlshortener:v1.0.0"
            resources = {
              cpu    = 0.25
              memory = "0.5Gi"
            }
            env = [
              {
                name      = "DATABASE_URL"
                secretRef = "database-url"
              }
            ]
          }
        ]
        scale = {
          minReplicas = 0
          maxReplicas = 1
        }
      }
    }
  }

  # RBAC propagation lags the role-assignment create by 30-60s; if the
  # Container App's first revision spins up before the UAMI is effectively
  # authorized, KV resolution returns Forbidden and the revision is marked
  # failed. Retry absorbs that window per project convention (azapi retry
  # over depends_on/serialization).
  retry = {
    error_message_regex = [
      "Forbidden",
      "Unauthorized",
      "AuthorizationFailed",
      "KeyVaultReferenceFailure",
      "ManagedIdentityCredential",
    ]
  }

  response_export_values = ["properties.configuration.ingress.fqdn"]

  depends_on = [
    azapi_resource.ra_uami_kv_secrets_user,
    azapi_resource_action.kv_secret_db_url,
    azapi_resource.pe_kv_dns_zone_group,
  ]
}

# ── Observability — App Insights, diagnostic settings, action group, 5xx alert

# Workspace-based Application Insights. WorkspaceResourceId points at the LAW
# from above; IngestionMode=LogAnalytics is what makes it "workspace-based"
# (vs. the legacy classic mode that has its own data store). Default sampling
# is whatever the SDK chooses — explicit overrides are deferred to v1.1.

resource "azapi_resource" "appi" {
  type      = "Microsoft.Insights/components@2020-02-02"
  name      = "appi-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = var.location
  body = {
    kind = "web"
    properties = {
      Application_Type    = "web"
      Flow_Type           = "Bluefield"
      Request_Source      = "rest"
      WorkspaceResourceId = azapi_resource.law.id
      IngestionMode       = "LogAnalytics"
    }
  }
}

# Diagnostic settings — every resource in the artifact that supports them
# ships logs + metrics to the LAW. Resources without diagnostic-settings
# support (RG, subnets, private DNS zones + links, UAMI, the PG database
# child, the Key Vault private endpoint, action group, alert) are omitted.
#
# The body shape varies per target type because the RPs disagree on what
# they accept:
#   - default (vnet, pip_nat, kv, pg, cae): categoryGroup="allLogs" + AllMetrics
#   - metrics-only (natgw, app): no log categories supported
#     (Container App logs are emitted at the Environment scope, not per-app)
#   - nsg (all 4 NSGs): explicit log categories — RP rejects metric export
# Private Endpoint is omitted entirely; the resource type does not support
# diagnostic settings (RP returns ResourceTypeNotSupported on the GET).
#
# One explicit resource per target, body written inline. The diagnostic-setting
# resource name is fixed to "to-law" — it lives at the source resource's scope
# (parent_id), so the name only needs to be unique per scope.

resource "azapi_resource" "diag_vnet" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.vnet.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      logs = [
        {
          categoryGroup = "allLogs"
          enabled       = true
        }
      ]
      metrics = [
        {
          category = "AllMetrics"
          enabled  = true
        }
      ]
    }
  }
}

resource "azapi_resource" "diag_pip_nat" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.pip_nat.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      logs = [
        {
          categoryGroup = "allLogs"
          enabled       = true
        }
      ]
      metrics = [
        {
          category = "AllMetrics"
          enabled  = true
        }
      ]
    }
  }
}

resource "azapi_resource" "diag_natgw" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.natgw.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      metrics = [
        {
          category = "AllMetrics"
          enabled  = true
        }
      ]
    }
  }
}

resource "azapi_resource" "diag_nsg_cae" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.nsg_cae.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      logs = [
        {
          category = "NetworkSecurityGroupEvent"
          enabled  = true
        },
        {
          category = "NetworkSecurityGroupRuleCounter"
          enabled  = true
        },
      ]
    }
  }
}

resource "azapi_resource" "diag_nsg_pg" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.nsg_pg.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      logs = [
        {
          category = "NetworkSecurityGroupEvent"
          enabled  = true
        },
        {
          category = "NetworkSecurityGroupRuleCounter"
          enabled  = true
        },
      ]
    }
  }
}

resource "azapi_resource" "diag_nsg_pe" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.nsg_pe.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      logs = [
        {
          category = "NetworkSecurityGroupEvent"
          enabled  = true
        },
        {
          category = "NetworkSecurityGroupRuleCounter"
          enabled  = true
        },
      ]
    }
  }
}

resource "azapi_resource" "diag_nsg_reserved" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.nsg_reserved.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      logs = [
        {
          category = "NetworkSecurityGroupEvent"
          enabled  = true
        },
        {
          category = "NetworkSecurityGroupRuleCounter"
          enabled  = true
        },
      ]
    }
  }
}

resource "azapi_resource" "diag_kv" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.kv.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      logs = [
        {
          categoryGroup = "allLogs"
          enabled       = true
        }
      ]
      metrics = [
        {
          category = "AllMetrics"
          enabled  = true
        }
      ]
    }
  }
}

resource "azapi_resource" "diag_pg" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.pg.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      logs = [
        {
          categoryGroup = "allLogs"
          enabled       = true
        }
      ]
      metrics = [
        {
          category = "AllMetrics"
          enabled  = true
        }
      ]
    }
  }
}

resource "azapi_resource" "diag_cae" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.cae.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      logs = [
        {
          categoryGroup = "allLogs"
          enabled       = true
        }
      ]
      metrics = [
        {
          category = "AllMetrics"
          enabled  = true
        }
      ]
    }
  }
}

resource "azapi_resource" "diag_app" {
  type      = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  name      = "to-law"
  parent_id = azapi_resource.app.id

  body = {
    properties = {
      workspaceId = azapi_resource.law.id
      metrics = [
        {
          category = "AllMetrics"
          enabled  = true
        }
      ]
    }
  }
}

# Action group — one email receiver pulled from var.alert_email. groupShortName
# is capped at 12 chars by the API and shows up as the SMS/email "from" tag.
# location must be "global" for action groups; the per-region ones are a
# workspace-routing thing we don't need.

resource "azapi_resource" "ag" {
  type      = "Microsoft.Insights/actionGroups@2023-01-01"
  name      = "ag-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = "global"

  body = {
    properties = {
      groupShortName = "alerts"
      enabled        = true
      emailReceivers = [
        {
          name                 = "primary"
          emailAddress         = var.alert_email
          useCommonAlertSchema = true
        }
      ]
    }
  }
}

# 5xx-volume metric alert on the Container App. Container Apps emits a Requests
# metric with a statusCodeCategory dimension ("1xx" / "2xx" / ... / "5xx"); a
# dimension filter on Include 5xx + timeAggregation=Total gives a count of 5xx
# responses over the window, not a rate. Threshold 5 over a 5-minute window is
# a placeholder — tunable per workload, called out in the README.
#
# autoMitigate=true so the alert auto-resolves once Requests with that
# dimension drops back below the threshold for a window. Without it, the
# alert sticks open until manually closed in the portal.

resource "azapi_resource" "alert_5xx" {
  type      = "Microsoft.Insights/metricAlerts@2018-03-01"
  name      = "alert-5xx-${var.environment}-${var.location_short}-${var.common_name}"
  parent_id = azapi_resource.rg.id
  location  = "global"

  body = {
    properties = {
      description          = "Container App 5xx response count exceeded the threshold over the window."
      severity             = 2
      enabled              = true
      scopes               = [azapi_resource.app.id]
      evaluationFrequency  = "PT1M"
      windowSize           = "PT5M"
      autoMitigate         = true
      targetResourceType   = "Microsoft.App/containerApps"
      targetResourceRegion = var.location
      criteria = {
        "odata.type" = "Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria"
        allOf = [
          {
            criterionType   = "StaticThresholdCriterion"
            name            = "5xx"
            metricNamespace = "Microsoft.App/containerApps"
            metricName      = "Requests"
            operator        = "GreaterThan"
            threshold       = 5
            timeAggregation = "Total"
            dimensions = [
              {
                name     = "statusCodeCategory"
                operator = "Include"
                values   = ["5xx"]
              }
            ]
          }
        ]
      }
      actions = [
        {
          actionGroupId = azapi_resource.ag.id
        }
      ]
    }
  }
}
