# ── Azure API Management (Consumption tier) ──────────────────
# Lightweight APIM for API key auth + rate limiting.
# Consumption tier: no fixed cost, pay per call.
# The backend URL is configured by deploy.sh after the K8s LB gets its IP.

resource "azurerm_api_management" "this" {
  count               = var.apim_enabled ? 1 : 0
  name                = var.apim_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = "Consumption_0"
  tags                = var.tags
}

# ── API definition (OpenAI-compatible) ────────────────────────
resource "azurerm_api_management_api" "vllm" {
  count               = var.apim_enabled ? 1 : 0
  name                = "vllm-inference"
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.this.name
  revision            = "1"
  display_name        = "vLLM Inference API"
  path                = ""
  protocols           = ["https"]
  subscription_required = true

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }

  # Placeholder — deploy.sh updates this after K8s LB gets its public IP
  service_url = "http://placeholder.localhost"
}

# ── Catch-all operations ──────────────────────────────────────
resource "azurerm_api_management_api_operation" "wildcard_post" {
  count               = var.apim_enabled ? 1 : 0
  operation_id        = "wildcard-post"
  api_name            = azurerm_api_management_api.vllm[0].name
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Wildcard POST"
  method              = "POST"
  url_template        = "/*"
}

resource "azurerm_api_management_api_operation" "wildcard_get" {
  count               = var.apim_enabled ? 1 : 0
  operation_id        = "wildcard-get"
  api_name            = azurerm_api_management_api.vllm[0].name
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Wildcard GET"
  method              = "GET"
  url_template        = "/*"
}

# ── Product (groups the API + requires subscription key) ──────
resource "azurerm_api_management_product" "vllm" {
  count                 = var.apim_enabled ? 1 : 0
  product_id            = "vllm-inference"
  api_management_name   = azurerm_api_management.this[0].name
  resource_group_name   = azurerm_resource_group.this.name
  display_name          = "vLLM Inference"
  description           = "Access to vLLM inference API with rate limiting"
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "vllm" {
  count               = var.apim_enabled ? 1 : 0
  api_name            = azurerm_api_management_api.vllm[0].name
  product_id          = azurerm_api_management_product.vllm[0].product_id
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.this.name
}

# ── Subscription (generates the API key) ──────────────────────
resource "azurerm_api_management_subscription" "vllm" {
  count               = var.apim_enabled ? 1 : 0
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "vllm-default-key"
  product_id          = azurerm_api_management_product.vllm[0].id
  state               = "active"
}

# ── Rate limiting policy (API-level) ──────────────────────────
resource "azurerm_api_management_api_policy" "vllm" {
  count               = var.apim_enabled ? 1 : 0
  api_name            = azurerm_api_management_api.vllm[0].name
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.this.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <set-variable name="api-key-valid" value="@(context.Request.Headers.GetValueOrDefault("api-key","") == "${azurerm_api_management_subscription.vllm[0].primary_key}")" />
        <choose>
          <when condition="@(!Boolean.Parse((string)context.Variables["api-key-valid"]))">
            <return-response>
              <set-status code="401" reason="Unauthorized" />
              <set-header name="Content-Type" exists-action="override">
                <value>application/json</value>
              </set-header>
              <set-body>{"error":{"message":"API key required. Pass via 'api-key' header.","type":"auth_error","code":"unauthorized"}}</set-body>
            </return-response>
          </when>
        </choose>
        <rate-limit calls="${var.apim_rate_limit_calls}" renewal-period="${var.apim_rate_limit_period}" />
        <cors>
          <allowed-origins><origin>*</origin></allowed-origins>
          <allowed-methods><method>*</method></allowed-methods>
          <allowed-headers><header>*</header></allowed-headers>
        </cors>
      </inbound>
      <backend>
        <forward-request timeout="30" follow-redirects="false" buffer-request-body="false" />
      </backend>
      <outbound>
        <base />
        <set-header name="X-RateLimit-Limit" exists-action="override">
          <value>${var.apim_rate_limit_calls}</value>
        </set-header>
        <choose>
          <when condition="@(context.Response.StatusCode == 503 || context.Response.StatusCode == 502)">
            <set-header name="Content-Type" exists-action="override">
              <value>application/json</value>
            </set-header>
            <set-header name="Retry-After" exists-action="override">
              <value>30</value>
            </set-header>
            <set-body>{"error":{"message":"Perae que estamos trocando o pneu do aviao voando. O modelo esta sendo recarregado em uma nova instancia. Tente novamente em alguns instantes.","type":"server_error","code":"model_reloading"}}</set-body>
          </when>
        </choose>
      </outbound>
      <on-error>
        <set-variable name="is-auth-error" value="@(context.LastError.Reason == "SubscriptionKeyNotFound" || context.LastError.Reason == "SubscriptionKeyInvalid")" />
        <choose>
          <when condition="@((bool)context.Variables["is-auth-error"])">
            <return-response>
              <set-status code="401" reason="Unauthorized" />
              <set-header name="Content-Type" exists-action="override">
                <value>application/json</value>
              </set-header>
              <set-body>{"error":{"message":"API key required. Pass via 'api-key' header.","type":"auth_error","code":"unauthorized"}}</set-body>
            </return-response>
          </when>
          <otherwise>
            <return-response>
              <set-status code="503" reason="Service Unavailable" />
              <set-header name="Content-Type" exists-action="override">
                <value>application/json</value>
              </set-header>
              <set-header name="Retry-After" exists-action="override">
                <value>30</value>
              </set-header>
              <set-body>{"error":{"message":"Perae que estamos trocando o pneu do aviao voando. O modelo esta sendo recarregado em uma nova instancia. Tente novamente em alguns instantes.","type":"server_error","code":"model_reloading"}}</set-body>
            </return-response>
          </otherwise>
        </choose>
      </on-error>
    </policies>
  XML
}
