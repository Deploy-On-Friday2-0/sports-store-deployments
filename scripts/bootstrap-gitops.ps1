[CmdletBinding()]
param(
  [string]$ClusterName = "sports-store-cluster",
  [string]$Region = "us-east-1",
  [string]$ArgoChartVersion = "10.2.2"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Checked {
  param(
    [Parameter(Mandatory)] [string]$Command,
    [Parameter(ValueFromRemainingArguments)] [string[]]$Arguments
  )
  & $Command @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

function Export-EmbeddedHelmValues {
  param(
    [Parameter(Mandatory)] [string]$ManifestPath,
    [Parameter(Mandatory)] [string]$OutputPath
  )
  $manifest = Get-Content -LiteralPath $ManifestPath
  $startMatch = $manifest | Select-String -Pattern '^      values: \|$'
  $endMatch = $manifest | Select-String -Pattern '^  destination:$'
  if (-not $startMatch -or -not $endMatch -or $endMatch.LineNumber -le $startMatch.LineNumber) {
    throw "Unable to extract embedded Helm values from $ManifestPath"
  }
  $values = $manifest[$startMatch.LineNumber..($endMatch.LineNumber - 2)] |
    ForEach-Object { $_ -replace '^        ', '' }
  Set-Content -LiteralPath $OutputPath -Value $values -Encoding utf8
}

Invoke-Checked aws eks update-kubeconfig --name $ClusterName --region $Region
$serverVersion = kubectl version -o json | ConvertFrom-Json
if (-not $serverVersion.serverVersion.gitVersion) { throw "kubectl cannot reach the EKS API" }

Push-Location $repositoryRoot
try {
  Invoke-Checked kubectl apply -f bootstrap/00-namespaces.yaml
  Invoke-Checked kubectl get storageclass ebs-gp3-retain

  $releaseStatus = $null
  $statusJson = helm status argocd --namespace argocd --output json 2>$null
  if ($LASTEXITCODE -eq 0) { $releaseStatus = ($statusJson | ConvertFrom-Json).info.status }
  if ($releaseStatus -in @("pending-install", "failed")) {
    Write-Host "Removing incomplete Argo CD release in state '$releaseStatus'."
    Invoke-Checked helm uninstall argocd --namespace argocd --wait --timeout 5m
  }

  $valuesFile = [IO.Path]::GetTempFileName()
  try {
    Export-EmbeddedHelmValues -ManifestPath "bootstrap/argocd.yaml" -OutputPath $valuesFile
    Invoke-Checked helm upgrade --install argocd argo/argo-cd `
      --version $ArgoChartVersion --namespace argocd --create-namespace `
      --values $valuesFile --wait --timeout 10m
  }
  finally {
    Remove-Item -LiteralPath $valuesFile -Force -ErrorAction SilentlyContinue
  }

  Invoke-Checked kubectl wait --for=condition=Available deployment --all --namespace argocd --timeout=5m
  Invoke-Checked kubectl apply -f projects/sports-store-project.yaml
  Invoke-Checked kubectl apply -f bootstrap/argocd.yaml
  Invoke-Checked kubectl apply -f apps/root-app.yaml
  Invoke-Checked kubectl apply -f apps/platform-controllers.yaml
  Invoke-Checked kubectl apply -f apps/kubecost/kubecost.yaml

  Write-Host "GitOps bootstrap submitted. Inspect reconciliation with:"
  Write-Host "  kubectl -n argocd get applications"
  Write-Host "  kubectl -n kubecost get pods,services,pvc"
}
finally {
  Pop-Location
}
