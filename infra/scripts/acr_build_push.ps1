# =============================================================================
# ACR Build and Push Script (PowerShell)
# This script builds container images remotely using Azure Container Registry
# and updates the Container Apps to use the new images.
# =============================================================================
 param(
    [string]$ResourceGroupName
)

$ErrorActionPreference = "Stop"
 
Write-Host "============================================================"
Write-Host "ACR Build and Push - Starting..."
Write-Host "============================================================"
 
if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {

    Write-Host "Using azd environment values..."

    $ACR_NAME                    = azd env get-value CONTAINER_REGISTRY_NAME
    $ACR_LOGIN_SERVER            = azd env get-value CONTAINER_REGISTRY_LOGIN_SERVER
    $RESOURCE_GROUP              = azd env get-value AZURE_RESOURCE_GROUP
    $CONTAINER_APP_NAME          = azd env get-value CONTAINER_APP_NAME
    $CONTAINER_API_APP_NAME      = azd env get-value CONTAINER_API_APP_NAME
    $CONTAINER_WEB_APP_NAME      = azd env get-value CONTAINER_WEB_APP_NAME
    $CONTAINER_WORKFLOW_APP_NAME = azd env get-value CONTAINER_WORKFLOW_APP_NAME
    $USER_IDENTITY_ID            = azd env get-value CONTAINER_APP_USER_IDENTITY_ID

}
else {

    Write-Host "Using existing deployment from Resource Group: $ResourceGroupName"

    $RESOURCE_GROUP = $ResourceGroupName

    # Get ACR
    $acr = az acr list `
        --resource-group $RESOURCE_GROUP `
        --query "[0]" `
        | ConvertFrom-Json

    if (-not $acr) {
        throw "No Azure Container Registry found in $RESOURCE_GROUP"
    }

    $ACR_NAME = $acr.name
    $ACR_LOGIN_SERVER = $acr.loginServer

    # Get Container Apps
    $containerApps = az containerapp list `
        --resource-group $RESOURCE_GROUP `
        | ConvertFrom-Json

    foreach ($app in $containerApps) {

        switch -Wildcard ($app.name) {

            "*-api" {
                $CONTAINER_API_APP_NAME = $app.name
            }

            "*-web" {
                $CONTAINER_WEB_APP_NAME = $app.name
            }

            "*-wkfl" {
                $CONTAINER_WORKFLOW_APP_NAME = $app.name
            }

            default {
                $CONTAINER_APP_NAME = $app.name
            }
        }
    }

    # Optional - Get Managed Identity
    $USER_IDENTITY_ID = (
        az identity list `
            --resource-group $RESOURCE_GROUP `
            --query "[0].id" `
            -o tsv
    )
}
 
$IMAGE_TAG = "latest"
$DeploymentType = az group show `
    --name $RESOURCE_GROUP `
    --query "tags.Type" `
    -o tsv
  if ($DeploymentType -eq "WAF") {

    Write-Host ""
    Write-Host "WAF deployment detected. Temporarily relaxing ACR restrictions..."

    $acrAllowExport = az acr update `
        --name $ACR_NAME `
        --resource-group $RESOURCE_GROUP `
        --allow-exports true

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to enable ACR exports."
    }

    $acrPublicNetwork = az acr update `
        --name $ACR_NAME `
        --resource-group $RESOURCE_GROUP `
        --public-network-enabled true

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to enable ACR public network access."
    }

    $acrDefaultAction = az acr update `
        --name $ACR_NAME `
        --resource-group $RESOURCE_GROUP `
        --default-action Allow

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set ACR default action to Allow."
    }

    Write-Host "ACR restrictions temporarily relaxed."
}

 
# Get the script directory and navigate to repo root
$ScriptDir = $PSScriptRoot
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "../..")).Path
 
Write-Host ""
Write-Host "  ACR Name: $ACR_NAME"
Write-Host "  ACR Login Server: $ACR_LOGIN_SERVER"
Write-Host "  Resource Group: $RESOURCE_GROUP"
Write-Host "  Image Tag: $IMAGE_TAG"
Write-Host ""

function Build-Image {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageName,
        [Parameter(Mandatory = $true)]
        [string]$Dockerfile,
        [Parameter(Mandatory = $true)]
        [string]$BuildContext
    )

    $ContextPath = [System.IO.Path]::GetRelativePath($RepoRoot, $BuildContext)
    $DockerfilePath = [System.IO.Path]::GetRelativePath($BuildContext, $Dockerfile)
    $StagingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "acr-build-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $StagingDirectory | Out-Null

    try {
        $SourceFiles = git -C $RepoRoot ls-files `
            --cached `
            --others `
            --exclude-standard `
            -- $ContextPath

        if ($LASTEXITCODE -ne 0) { throw "Failed to collect build context for $ImageName" }

        foreach ($SourceFile in $SourceFiles) {
            $StagedFile = [System.IO.Path]::GetRelativePath($ContextPath, $SourceFile)
            $Destination = Join-Path $StagingDirectory $StagedFile
            $DestinationDirectory = Split-Path -Parent $Destination
            New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot $SourceFile) -Destination $Destination
        }

        az acr build `
            --registry $ACR_NAME `
            --image "${ImageName}:$IMAGE_TAG" `
            --file (Join-Path $StagingDirectory $DockerfilePath) `
            --platform linux `
            $StagingDirectory

        if ($LASTEXITCODE -ne 0) { throw "Failed to build $ImageName image" }
    }
    finally {
        Remove-Item -LiteralPath $StagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    # =============================================================================
    # Step 1: Build and push images to ACR using az acr build
    # =============================================================================

    Write-Host "============================================================"
    Write-Host "Step 1: Building and pushing images to ACR..."
    Write-Host "============================================================"
    
    # --- ContentProcessor ---
    Write-Host ""
    Write-Host "  Building contentprocessor image..."
        Build-Image `
            -ImageName "contentprocessor" `
            -Dockerfile (Join-Path $RepoRoot "src/ContentProcessor/Dockerfile") `
            -BuildContext (Join-Path $RepoRoot "src/ContentProcessor")
    Write-Host "  [OK] contentprocessor image built and pushed."
    
    # --- ContentProcessorAPI ---
    Write-Host ""
    Write-Host "  Building contentprocessorapi image..."
        Build-Image `
            -ImageName "contentprocessorapi" `
            -Dockerfile (Join-Path $RepoRoot "src/ContentProcessorAPI/Dockerfile") `
            -BuildContext (Join-Path $RepoRoot "src/ContentProcessorAPI")
    Write-Host "  [OK] contentprocessorapi image built and pushed."
    
    # --- ContentProcessorWeb ---
    Write-Host ""
    Write-Host "  Building contentprocessorweb image..."
        Build-Image `
            -ImageName "contentprocessorweb" `
            -Dockerfile (Join-Path $RepoRoot "src/ContentProcessorWeb/Dockerfile") `
            -BuildContext (Join-Path $RepoRoot "src/ContentProcessorWeb")
    Write-Host "  [OK] contentprocessorweb image built and pushed."
    
    # --- ContentProcessorWorkflow ---
    Write-Host ""
    Write-Host "  Building contentprocessorworkflow image..."
        Build-Image `
            -ImageName "contentprocessorworkflow" `
            -Dockerfile (Join-Path $RepoRoot "src/ContentProcessorWorkflow/Dockerfile") `
            -BuildContext (Join-Path $RepoRoot "src/ContentProcessorWorkflow")
    Write-Host "  [OK] contentprocessorworkflow image built and pushed."
    
    Write-Host ""
    Write-Host "  All images built and pushed successfully."
    
    # =============================================================================
    # Step 2: Update Container Apps to use the new images from ACR
    # =============================================================================
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Step 2: Updating Container Apps with new images..."
    Write-Host "============================================================"
    
    # --- Update ContentProcessor Container App ---
    Write-Host ""
    Write-Host "  Updating $CONTAINER_APP_NAME..."
    az containerapp update `
      --name $CONTAINER_APP_NAME `
      --resource-group $RESOURCE_GROUP `
      --image "$ACR_LOGIN_SERVER/contentprocessor:$IMAGE_TAG"
    
    if ($LASTEXITCODE -ne 0) { throw "Failed to update $CONTAINER_APP_NAME" }
    Write-Host "  [OK] $CONTAINER_APP_NAME updated."
    
    # --- Update ContentProcessorAPI Container App ---
    Write-Host ""
    Write-Host "  Updating $CONTAINER_API_APP_NAME..."
    az containerapp update `
      --name $CONTAINER_API_APP_NAME `
      --resource-group $RESOURCE_GROUP `
      --image "$ACR_LOGIN_SERVER/contentprocessorapi:$IMAGE_TAG"
    
    if ($LASTEXITCODE -ne 0) { throw "Failed to update $CONTAINER_API_APP_NAME" }
    Write-Host "  [OK] $CONTAINER_API_APP_NAME updated."
    
    # --- Update ContentProcessorWeb Container App ---
    Write-Host ""
    Write-Host "  Updating $CONTAINER_WEB_APP_NAME..."
    az containerapp update `
      --name $CONTAINER_WEB_APP_NAME `
      --resource-group $RESOURCE_GROUP `
      --image "$ACR_LOGIN_SERVER/contentprocessorweb:$IMAGE_TAG"
    
    if ($LASTEXITCODE -ne 0) { throw "Failed to update $CONTAINER_WEB_APP_NAME" }
    Write-Host "  [OK] $CONTAINER_WEB_APP_NAME updated."
    
    # --- Update ContentProcessorWorkflow Container App ---
    Write-Host ""
    Write-Host "  Updating $CONTAINER_WORKFLOW_APP_NAME..."
    az containerapp update `
      --name $CONTAINER_WORKFLOW_APP_NAME `
      --resource-group $RESOURCE_GROUP `
      --image "$ACR_LOGIN_SERVER/contentprocessorworkflow:$IMAGE_TAG"
    
    if ($LASTEXITCODE -ne 0) { throw "Failed to update $CONTAINER_WORKFLOW_APP_NAME" }
    Write-Host "  [OK] $CONTAINER_WORKFLOW_APP_NAME updated."
    
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "ACR Build and Push - Completed Successfully!"
    Write-Host "============================================================"
}
finally {

    if ($DeploymentType -eq "WAF") {

        Write-Host ""
        Write-Host "Restoring WAF ACR configuration..."

        $acrDefaultAction = az acr update `
            --name $ACR_NAME `
            --resource-group $RESOURCE_GROUP `
            --default-action Deny

         $acrPublicNetwork = az acr update `
            --name $ACR_NAME `
            --resource-group $RESOURCE_GROUP `
            --public-network-enabled false

        $acrAllowExport = az acr update `
            --name $ACR_NAME `
            --resource-group $RESOURCE_GROUP `
            --allow-exports false

        Write-Host "ACR configuration restored."
    }
}