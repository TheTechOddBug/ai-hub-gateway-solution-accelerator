/**
 * @module version-api
 * @description Creates a lightweight "Release Version" API in API Management that exposes
 * a single GET operation returning the accelerator release version manifest (release.json)
 * as static JSON content. The content is embedded into an operation-level policy at deploy
 * time via a mock (return-response) response, so no backend is required.
 *
 * This module is shared by both the primary accelerator deployment (apim.bicep) and the
 * APIM Gateway Upgrade (apim-gateway-upgrade/main.bicep) so the version endpoint is always
 * created/updated to reflect the currently deployed release manifest.
 */

// ------------------
//    PARAMETERS
// ------------------

@description('The name of the API Management instance to deploy the version API to.')
@minLength(1)
param apiManagementName string

@description('The name (resource id segment) of the version API.')
param versionApiName string = 'release-version-api'

@description('The display name of the version API.')
param versionApiDisplayName string = 'Release Version API'

@description('The description of the version API.')
param versionApiDescription string = 'Returns the AI Hub Gateway accelerator release version manifest (release.json) as static JSON content.'

@description('The relative path (URL suffix) for the version API in the APIM gateway.')
param versionApiPath string = 'version'

@description('Set to true if a subscription key is required to call the version API. Defaults to false so the endpoint can be queried anonymously (health/version style).')
param subscriptionRequired bool = false

@description('The name of the subscription key header (only relevant when subscriptionRequired is true).')
param subscriptionKeyName string = 'api-key'

@description('The raw JSON content of the release manifest to serve. Defaults to the repository release.json.')
param releaseContent string = loadTextContent('../../../../release.json')

// ------------------
//    VARIABLES
// ------------------

// The release manifest is embedded verbatim into a return-response policy as a literal body.
// release.json contains only JSON-safe characters ({ } " : , and version strings) so it does
// not need XML escaping. If this ever changes, escape < > & before embedding.
// NOTE: Bicep multi-line strings ('''...''') do NOT support interpolation, so the policy is
// composed from a prefix and suffix with the release content concatenated in between.
var versionApiPolicyPrefix = '''
<policies>
    <inbound>
        <base />
        <return-response>
            <set-status code="200" reason="OK" />
            <set-header name="Content-Type" exists-action="override">
                <value>application/json</value>
            </set-header>
            <set-body>'''

var versionApiPolicySuffix = '''</set-body>
        </return-response>
    </inbound>
    <backend>
        <base />
    </backend>
    <outbound>
        <base />
    </outbound>
    <on-error>
        <base />
    </on-error>
</policies>'''

var versionApiPolicyXml = '${versionApiPolicyPrefix}${releaseContent}${versionApiPolicySuffix}'

// ------------------
//    RESOURCES
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apiManagementName
}

resource versionApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: versionApiName
  parent: apimService
  properties: {
    apiType: 'http'
    description: versionApiDescription
    displayName: versionApiDisplayName
    path: versionApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: subscriptionRequired
    subscriptionKeyParameterNames: {
      header: subscriptionKeyName
    }
    serviceUrl: 'https://to-be-replaced-by-policy'
  }
}

resource versionApiGetOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'get-version'
  parent: versionApi
  properties: {
    displayName: 'Get Release Version'
    method: 'GET'
    urlTemplate: '/'
    description: 'Returns the accelerator release version manifest as static JSON content.'
    responses: [
      {
        statusCode: 200
        description: 'The release version manifest.'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

resource versionApiGetOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: versionApiGetOperation
  properties: {
    format: 'rawxml'
    value: versionApiPolicyXml
  }
}

// ------------------
//    OUTPUTS
// ------------------

@description('The resource id of the version API.')
output versionApiId string = versionApi.id

@description('The name (resource id segment) of the version API.')
output versionApiResourceName string = versionApi.name

@description('The gateway path of the version API.')
output versionApiPathOut string = versionApiPath
