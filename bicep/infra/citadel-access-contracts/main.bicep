targetScope = 'subscription'

@description('APIM resource coordinates')
param apim object

@description('Target Key Vault for storing endpoint and API key secrets')
param keyVault object

@description('Whether to use Azure Key Vault for storing secrets. If false, secrets will be output instead.')
param useTargetAzureKeyVault bool = true

@description('Use case descriptor used in naming: <code>-<businessUnit>-<useCaseName>-<environment>')
param useCase object

@description('Map of service codes to their API names in APIM. Example: { OAI: ["azure-openai-service-api"], DOC: ["document-intelligence-api"] }')
param apiNameMapping object

@description('Required AI services for this use case. Each item: { code: "OAI", endpointSecretName: "OAI_ENDPOINT", apiKeySecretName: "OAI_KEY", policyXmlPath?: "path/to/policy.xml" }')
param services array

@description('Optional product terms shown to subscribers')
param productTerms string = ''

// ============================================================================
// KEY ROTATION PARAMETERS (OPTIONAL - BACKWARD COMPATIBLE)
// ============================================================================
// Zero-downtime subscription key rotation. Defaults reproduce existing behavior
// (primary key active, no rotation). See ./access-contract-key-rotation-guide.md.

@description('Which subscription key is ACTIVE (handed to consumers via Key Vault / Foundry / additional gateways). true = primary (default), false = secondary. Switch to false to move all in-contract services onto the secondary key without touching the still-valid primary key.')
param usePrimaryKey bool = true

@description('When true, the NON-active key is regenerated (overwritten with a fresh value), invalidating the old value. Combine with usePrimaryKey to rotate a specific key with no downtime. Default false = both keys preserved.')
param keyRotationEnabled bool = false

@description('Seed used to derive a fresh rotation key. Defaults to newGuid() so every deployment with keyRotationEnabled=true generates a new key. Ignored when rotationKeyOverride is set.')
param rotationKeySeed string = newGuid()

@description('Optional explicit rotation key value. When set, it is used verbatim as the new NON-active key (deterministic re-runs). When empty (default), a 64-char key is derived from rotationKeySeed.')
@secure()
param rotationKeyOverride string = ''

// ============================================================================
// AZURE AI FOUNDRY INTEGRATION PARAMETERS
// ============================================================================

@description('Whether to create Azure AI Foundry connection for this use case. If true, foundry parameter must be provided.')
param useTargetFoundry bool = false

@description('Azure AI Foundry configuration for creating APIM connections. Required if useTargetFoundry is true.')
param foundry object = {
  subscriptionId: ''
  resourceGroupName: ''
  accountName: ''
  projectName: ''
}

@description('Foundry connection configuration options')
param foundryConfig object = {
  // Connection naming: if empty, uses useCase naming convention
  connectionNamePrefix: ''
  // Foundry connection category: ApiManagement or ModelGateway
  connectionCategory: 'ApiManagement'
  // Whether deployment name is in URL path (true) or request body (false)
  deploymentInPath: 'false'
  // Share connection to all project users
  isSharedToAll: false
  // API version for inference calls (empty = APIM defaults)
  inferenceAPIVersion: ''
  // API version for deployment discovery (empty = APIM defaults)
  deploymentAPIVersion: ''
  // Static model list (optional)
  staticModels: []
  // Custom discovery endpoints (optional - leave empty for APIM defaults)
  listModelsEndpoint: ''
  getModelEndpoint: ''
  deploymentProvider: 'AzureOpenAI'
  // Custom headers for requests
  customHeaders: {}
  // Custom auth configuration
  authConfig: {}
}

// ============================================================================
// BUSINESS CONTINUITY & RESILIENCY PARAMETERS (OPTIONAL - BACKWARD COMPATIBLE)
// ============================================================================
// These parameters are all optional and default to empty. When left at their
// defaults the contract deploys exactly as before (single primary APIM gateway,
// primary Key Vault, primary Foundry). Populate them to mirror a single contract
// across additional gateways / Key Vaults / Foundry instances for resiliency.
// See ./access-contract-resiliency-guide.md for full guidance.

@description('Optional global gateway URL (e.g., Azure Front Door / Traffic Manager) fronting all APIM gateways. When set, it is used as the endpoint base for ALL Key Vault secrets and Foundry connections (primary + additional). Empty (default) preserves existing behavior of using the primary APIM gateway URL.')
param globalGatewayUrl string = ''

@description('Optional additional APIM gateway instances to mirror this contract into. Each item: { subscriptionId, resourceGroupName, name }. Deployed AFTER the primary gateway and reuse the SAME subscription key generated by the primary. Empty (default) = single gateway (existing behavior).')
param additionalApimGateways array = []

@description('Optional additional Key Vaults to also store the contract endpoint + key. Each item: { subscriptionId, resourceGroupName, name, endpointSource? }. endpointSource selects the endpoint stored: "global" | "primary" | "secondary:<index>" | "" (default = effective global-or-primary).')
param additionalKeyVaults array = []

@description('Optional additional Foundry instances to also create APIM connections in. Each item: { subscriptionId, resourceGroupName, accountName, projectName, endpointSource? }. endpointSource behaves the same as additionalKeyVaults.')
param additionalFoundries array = []

var productPostfix = '${useCase.businessUnit}-${useCase.useCaseName}-${useCase.environment}'

// Default APIM product policy (applied when a service item does not provide policyXmlPath)
var defaultProductPolicyXml = loadTextContent('./policies/default-ai-product-policy.xml')

// Fresh key used to regenerate the NON-active subscription key when keyRotationEnabled is true.
// Derived from rotationKeySeed (defaults to newGuid()) into a 64-char value, or taken verbatim from rotationKeyOverride.
var rotationKey = empty(rotationKeyOverride) ? toLower('${replace(rotationKeySeed, '-', '')}${replace(guid(rotationKeySeed), '-', '')}') : rotationKeyOverride

resource apimRg 'Microsoft.Resources/resourceGroups@2022-09-01' existing = {
  scope: subscription(apim.subscriptionId)
  name: apim.resourceGroupName
}

resource apimSvc 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  scope: apimRg
  name: apim.name
}

// Effective endpoint base used for Key Vault secrets and Foundry connections.
// When a global gateway URL is provided it is used for ALL instances (primary + additional);
// otherwise falls back to the primary APIM gateway URL (existing behavior).
var effectiveGatewayUrl = empty(globalGatewayUrl) ? apimSvc.properties.gatewayUrl : globalGatewayUrl

// Existing references to additional APIM gateways (for endpoint URL resolution and outputs)
resource additionalApim 'Microsoft.ApiManagement/service@2024-05-01' existing = [for gw in additionalApimGateways: {
  scope: resourceGroup(gw.subscriptionId, gw.resourceGroupName)
  name: gw.name
}]

resource kvRg 'Microsoft.Resources/resourceGroups@2022-09-01' existing = if (useTargetAzureKeyVault) {
  scope: subscription(keyVault.subscriptionId)
  name: keyVault.resourceGroupName
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (useTargetAzureKeyVault) {
  scope: kvRg
  name: keyVault.name
}

// Onboard each requested service into APIM
module onboard 'modules/apimOnboardService.bicep' = [for s in services: {
  name: 'onboard-${s.code}-${productPostfix}'
  scope: apimRg
  params: {
    apimName: apim.name
    productId: '${s.code}-${productPostfix}'
    productDisplayName: '${s.code} ${useCase.businessUnit} ${useCase.useCaseName} ${useCase.environment}'
    productDescription: 'AI Gateway product for ${s.code} - ${useCase.useCaseName}'
    productTerms: productTerms
    apiNames: apiNameMapping[s.code]
    // Use provided policy XML or default
    productPolicyXml: contains(s, 'policyXml') && !empty(s.policyXml) ? s.policyXml : defaultProductPolicyXml
    subscriptionName: '${s.code}-${productPostfix}-SUB-01'
    subscriptionDisplayName: '${s.code}-${productPostfix}-SUB-01'
    // Key rotation controls (primary gateway owns/regenerates the keys)
    usePrimaryKey: usePrimaryKey
    keyRotationEnabled: keyRotationEnabled
    rotationKey: rotationKey
  }
}]

// Write Key Vault secrets per service (only if useTargetAzureKeyVault is true)
// Create/update KV secrets; normalize names (Key Vault does not allow underscores)
module kvWrites 'modules/kvSecrets.bicep' = [for (s, i) in services: if (useTargetAzureKeyVault) {
  name: 'kv-${s.code}-${productPostfix}'
  scope: kvRg
  params: {
    keyVaultName: kv.name
    secretNames: [ toLower(replace(s.endpointSecretName, '_', '-')), toLower(replace(s.apiKeySecretName, '_', '-')) ]
    secretValues: {
      '${toLower(replace(s.endpointSecretName, '_', '-'))}': '${effectiveGatewayUrl}/${onboard[i].outputs.apiPath}'
      '${toLower(replace(s.apiKeySecretName, '_', '-'))}': onboard[i].outputs.subscriptionActiveKey
    }
  }
}]

// ============================================================================
// AZURE AI FOUNDRY CONNECTION DEPLOYMENT
// ============================================================================
// Create Foundry APIM connections per service (only if useTargetFoundry is true)
// This enables Foundry agents to access AI models through the APIM gateway

resource foundryRg 'Microsoft.Resources/resourceGroups@2022-09-01' existing = if (useTargetFoundry) {
  scope: subscription(foundry.subscriptionId)
  name: foundry.resourceGroupName
}

// Generate connection name based on config or use case naming
var foundryConnectionPrefix = !empty(foundryConfig.connectionNamePrefix) ? foundryConfig.connectionNamePrefix : 'Hub-${useCase.businessUnit}-${useCase.useCaseName}-${useCase.environment}'

module foundryConnections 'modules/foundryConnection.bicep' = [for (s, i) in services: if (useTargetFoundry) {
  name: 'foundry-${s.code}-${productPostfix}'
  scope: foundryRg
  params: {
    aiFoundryAccountName: foundry.accountName
    aiFoundryProjectName: foundry.projectName
    connectionName: '${foundryConnectionPrefix}-${s.code}'
    targetUrl: '${effectiveGatewayUrl}/${onboard[i].outputs.apiPath}'
    apimSubscriptionKey: onboard[i].outputs.subscriptionActiveKey
    connectionCategory: foundryConfig.?connectionCategory ?? 'ApiManagement'
    isSharedToAll: foundryConfig.?isSharedToAll ?? false
    deploymentInPath: foundryConfig.?deploymentInPath ?? 'false'
    inferenceAPIVersion: foundryConfig.?inferenceAPIVersion ?? ''
    deploymentAPIVersion: foundryConfig.?deploymentAPIVersion ?? ''
    staticModels: foundryConfig.?staticModels ?? []
    listModelsEndpoint: foundryConfig.?listModelsEndpoint ?? ''
    getModelEndpoint: foundryConfig.?getModelEndpoint ?? ''
    deploymentProvider: foundryConfig.?deploymentProvider ?? ''
    customHeaders: foundryConfig.?customHeaders ?? {}
    authConfig: foundryConfig.?authConfig ?? {}
  }
  dependsOn: [
    onboard
  ]
}]

// ============================================================================
// BUSINESS CONTINUITY & RESILIENCY DEPLOYMENTS (OPTIONAL)
// ============================================================================
// The following deployments only run when the corresponding optional arrays are
// populated. Bicep cannot nest module loops, so the (instance x service) combos
// are flattened into single arrays and iterated once. Each module sets its scope
// per-item to the target subscription/resource group.
//
// Deployment order (enforced via output references + dependsOn):
//   1. Primary gateway onboarding (module 'onboard' above) generates the keys
//   2. Additional gateways reuse those SAME primary keys (explicitPrimaryKey)
//   3. Additional Key Vaults and Foundry connections run AFTER all gateways

// --- Additional APIM gateways: mirror each (gateway x service) contract ---
// Flattened via index math (Bicep does not support nested for-expressions):
//   gatewayIndex = idx / svcCount, serviceIndex = idx % svcCount
var svcCount = length(services)

var additionalOnboardItems = [for idx in range(0, length(additionalApimGateways) * svcCount): {
  gatewayIndex: idx / svcCount
  serviceIndex: idx % svcCount
  gw: additionalApimGateways[idx / svcCount]
  s: services[idx % svcCount]
}]

module additionalOnboard 'modules/apimOnboardService.bicep' = [for item in additionalOnboardItems: {
  name: 'onboard-add${item.gatewayIndex}-${item.s.code}-${productPostfix}'
  scope: resourceGroup(item.gw.subscriptionId, item.gw.resourceGroupName)
  params: {
    apimName: item.gw.name
    productId: '${item.s.code}-${productPostfix}'
    productDisplayName: '${item.s.code} ${useCase.businessUnit} ${useCase.useCaseName} ${useCase.environment}'
    productDescription: 'AI Gateway product for ${item.s.code} - ${useCase.useCaseName}'
    productTerms: productTerms
    apiNames: apiNameMapping[item.s.code]
    productPolicyXml: (contains(item.s, 'policyXml') && !empty(item.s.policyXml)) ? item.s.policyXml : defaultProductPolicyXml
    subscriptionName: '${item.s.code}-${productPostfix}-SUB-01'
    subscriptionDisplayName: '${item.s.code}-${productPostfix}-SUB-01'
    // Reuse the SAME keys generated/rotated by the primary gateway so BOTH keys stay in sync
    // across gateways (required for zero-downtime rotation and for the active-key switch).
    explicitPrimaryKey: onboard[item.serviceIndex].outputs.subscriptionPrimaryKey
    explicitSecondaryKey: onboard[item.serviceIndex].outputs.subscriptionSecondaryKey
    usePrimaryKey: usePrimaryKey
  }
}]

// --- Additional Key Vaults: store endpoint + shared key per (KV x service) ---
var additionalKvItems = [for idx in range(0, length(additionalKeyVaults) * svcCount): {
  kvIndex: idx / svcCount
  serviceIndex: idx % svcCount
  kvCfg: additionalKeyVaults[idx / svcCount]
  endpointSecretName: toLower(replace(services[idx % svcCount].endpointSecretName, '_', '-'))
  apiKeySecretName: toLower(replace(services[idx % svcCount].apiKeySecretName, '_', '-'))
}]

module additionalKvWrites 'modules/kvSecrets.bicep' = [for item in additionalKvItems: {
  name: 'kv-add${item.kvIndex}-s${item.serviceIndex}-${productPostfix}'
  scope: resourceGroup(item.kvCfg.subscriptionId, item.kvCfg.resourceGroupName)
  params: {
    keyVaultName: item.kvCfg.name
    secretNames: [ item.endpointSecretName, item.apiKeySecretName ]
    secretValues: {
      '${item.endpointSecretName}': '${(item.kvCfg.?endpointSource ?? '') == 'global' ? globalGatewayUrl : (item.kvCfg.?endpointSource ?? '') == 'primary' ? apimSvc.properties.gatewayUrl : startsWith(item.kvCfg.?endpointSource ?? '', 'secondary:') ? additionalApim[int(replace(item.kvCfg.endpointSource, 'secondary:', ''))].properties.gatewayUrl : effectiveGatewayUrl}/${onboard[item.serviceIndex].outputs.apiPath}'
      '${item.apiKeySecretName}': onboard[item.serviceIndex].outputs.subscriptionActiveKey
    }
  }
  dependsOn: [
    additionalOnboard
  ]
}]

// --- Additional Foundry instances: create APIM connection per (foundry x service) ---
var additionalFoundryItems = [for idx in range(0, length(additionalFoundries) * svcCount): {
  foundryIndex: idx / svcCount
  serviceIndex: idx % svcCount
  f: additionalFoundries[idx / svcCount]
  s: services[idx % svcCount]
}]

module additionalFoundryConnections 'modules/foundryConnection.bicep' = [for item in additionalFoundryItems: {
  name: 'foundry-add${item.foundryIndex}-${item.s.code}-${productPostfix}'
  scope: resourceGroup(item.f.subscriptionId, item.f.resourceGroupName)
  params: {
    aiFoundryAccountName: item.f.accountName
    aiFoundryProjectName: item.f.projectName
    connectionName: '${foundryConnectionPrefix}-${item.s.code}'
    targetUrl: '${(item.f.?endpointSource ?? '') == 'global' ? globalGatewayUrl : (item.f.?endpointSource ?? '') == 'primary' ? apimSvc.properties.gatewayUrl : startsWith(item.f.?endpointSource ?? '', 'secondary:') ? additionalApim[int(replace(item.f.endpointSource, 'secondary:', ''))].properties.gatewayUrl : effectiveGatewayUrl}/${onboard[item.serviceIndex].outputs.apiPath}'
    apimSubscriptionKey: onboard[item.serviceIndex].outputs.subscriptionActiveKey
    connectionCategory: foundryConfig.?connectionCategory ?? 'ApiManagement'
    isSharedToAll: foundryConfig.?isSharedToAll ?? false
    deploymentInPath: foundryConfig.?deploymentInPath ?? 'false'
    inferenceAPIVersion: foundryConfig.?inferenceAPIVersion ?? ''
    deploymentAPIVersion: foundryConfig.?deploymentAPIVersion ?? ''
    staticModels: foundryConfig.?staticModels ?? []
    listModelsEndpoint: foundryConfig.?listModelsEndpoint ?? ''
    getModelEndpoint: foundryConfig.?getModelEndpoint ?? ''
    deploymentProvider: foundryConfig.?deploymentProvider ?? ''
    customHeaders: foundryConfig.?customHeaders ?? {}
    authConfig: foundryConfig.?authConfig ?? {}
  }
  dependsOn: [
    additionalOnboard
  ]
}]

output apimGatewayUrl string = apimSvc.properties.gatewayUrl
output useKeyVault bool = useTargetAzureKeyVault

// Key rotation status (for post-deployment verification)
output activeKeySlot string = usePrimaryKey ? 'primary' : 'secondary'
output keyRotationApplied bool = keyRotationEnabled

output products array = [for s in services: {
  productId: '${s.code}-${productPostfix}'
  displayName: '${s.code} ${useCase.businessUnit} ${useCase.useCaseName} ${useCase.environment}'
}]

// When using Key Vault, output references to the secret names in Key Vault
output subscriptions array = [for s in services: {
  name: '${s.code}-${productPostfix}-SUB-01'
  productId: '${s.code}-${productPostfix}'
  keyVaultApiKeySecretName: useTargetAzureKeyVault ? toLower(replace(s.apiKeySecretName, '_', '-')) : ''
  keyVaultEndpointSecretName: useTargetAzureKeyVault ? toLower(replace(s.endpointSecretName, '_', '-')) : ''
}]

// When NOT using Key Vault, output the actual endpoints and keys
// These outputs contain runtime values from the onboarding modules
// Note: When useTargetAzureKeyVault=false, the 'endpoints' output will contain sensitive API keys.
// Consumers should handle these values securely (e.g., store in environment variables, CI/CD secrets, etc.)
// The linter warning about secrets in outputs is intentional when Key Vault is disabled
#disable-next-line outputs-should-not-contain-secrets
output endpoints array = [for (s, i) in services: {
  code: s.code
  productId: '${s.code}-${productPostfix}'
  subscriptionName: '${s.code}-${productPostfix}-SUB-01'
  endpoint: useTargetAzureKeyVault ? '' : '${apimSvc.properties.gatewayUrl}/${onboard[i].outputs.apiPath}'
  // API key is marked secure in the module output, consumers should treat this as sensitive when not using Key Vault
  #disable-next-line outputs-should-not-contain-secrets
  apiKey: useTargetAzureKeyVault ? '' : string(onboard[i].outputs.subscriptionPrimaryKey)
}]

// ============================================================================
// FOUNDRY CONNECTION OUTPUTS
// ============================================================================
output useFoundry bool = useTargetFoundry

output foundryConnections array = [for (s, i) in services: useTargetFoundry ? {
  code: s.code
  connectionName: '${foundryConnectionPrefix}-${s.code}'
  targetUrl: '${apimSvc.properties.gatewayUrl}/${onboard[i].outputs.apiPath}'
  foundryAccount: foundry.accountName
  foundryProject: foundry.projectName
} : {}]

// ============================================================================
// BUSINESS CONTINUITY & RESILIENCY OUTPUTS (ADDITIVE - EMPTY WHEN UNUSED)
// ============================================================================
var serviceProductIds = [for s in services: '${s.code}-${productPostfix}']
var serviceConnectionNames = [for s in services: '${foundryConnectionPrefix}-${s.code}']

output globalGatewayUrl string = globalGatewayUrl
output effectiveGatewayUrl string = effectiveGatewayUrl
output additionalGatewayCount int = length(additionalApimGateways)

output additionalGateways array = [for (gw, g) in additionalApimGateways: {
  name: gw.name
  gatewayUrl: additionalApim[g].properties.gatewayUrl
  products: serviceProductIds
}]

output additionalKeyVaults array = [for kvCfg in additionalKeyVaults: {
  name: kvCfg.name
  endpointSource: kvCfg.?endpointSource ?? ''
}]

output additionalFoundryConnections array = [for f in additionalFoundries: {
  foundryAccount: f.accountName
  foundryProject: f.projectName
  connectionNames: serviceConnectionNames
}]
