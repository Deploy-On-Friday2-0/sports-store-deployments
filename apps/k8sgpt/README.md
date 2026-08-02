# K8sGPT Operator GitOps Deployment

This directory contains the GitOps manifests to deploy the **K8sGPT Operator** and its custom resources inside the EKS cluster.

## 📂 Manifests

1.  **`k8sgpt.yaml`**: The Argo CD Application to deploy the operator from the official charts repository.
2.  **`k8sgpt-resources.yaml`**: Configures `ExternalSecret` to fetch API/Webhook keys from AWS Secrets Manager, and defines the `K8sGPT` resource to use Google Gemini AI diagnostics.

## 📋 Prerequisites

Before syncing, ensure you have populated the following keys in your AWS Secrets Manager secret **`sports-store/production/config`**:

*   `GOOGLE_API_KEY`: Your Gemini API key from Google AI Studio (Free tier).
*   `SLACK_WEBHOOK_URL`: Your Slack Incoming Webhook URL linked to `#k8s-ai-diagnostics`.

## 🧪 Verification

Verify that the operator is running and scanning successfully:

```bash
# Check operator pod status
kubectl get pods -n k8sgpt-operator-system

# Check the sync status of the K8sGPT Custom Resource
kubectl describe k8sgpt k8sgpt-prod -n k8sgpt-operator-system
```
