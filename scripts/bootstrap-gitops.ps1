[CmdletBinding()]
param(
  [string]$ClusterName = "sports-store-cluster",
  [string]$Region = "us-east-1"
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

Invoke-Checked aws eks update-kubeconfig --name $ClusterName --region $Region
$serverVersion = kubectl version -o json | ConvertFrom-Json
if (-not $serverVersion.serverVersion.gitVersion) { throw "kubectl cannot reach the EKS API" }

Push-Location $repositoryRoot
try {
  Invoke-Checked kubectl apply -f bootstrap/00-namespaces.yaml
  Invoke-Checked kubectl get storageclass ebs-gp3-retain

  # Terraform owns the Argo CD Helm release. This script only registers the
  # GitOps applications after that release is healthy.
  Invoke-Checked helm status argocd --namespace argocd
  Invoke-Checked kubectl wait --for=condition=Available deployment --all --namespace argocd --timeout=5m
  Invoke-Checked kubectl apply -f projects/sports-store-project.yaml
  Invoke-Checked kubectl apply -f apps/root-app.yaml
  Invoke-Checked kubectl apply -f apps/platform-controllers.yaml
  Invoke-Checked kubectl apply -f apps/monitoring/prometheus-stack.yaml
  Invoke-Checked kubectl wait --for=create `
    crd/prometheusrules.monitoring.coreos.com `
    crd/servicemonitors.monitoring.coreos.com --timeout=5m
  Invoke-Checked kubectl wait --for=condition=Established `
    crd/prometheusrules.monitoring.coreos.com `
    crd/servicemonitors.monitoring.coreos.com --timeout=5m
  Invoke-Checked kubectl apply -f apps/kubecost/kubecost.yaml

  Write-Host "GitOps bootstrap submitted. Inspect reconciliation with:"
  Write-Host "  kubectl -n argocd get applications"
  Write-Host "  kubectl -n kubecost get pods,services,pvc"
}
finally {
  Pop-Location
}
