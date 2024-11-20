
#!/bin/bash

echo "Cleaning up Kubernetes resources..."

# Delete the deployment
kubectl delete deployment chatbot-rag-app

# Delete the service
kubectl delete service chatbot-rag-service

# Delete any init jobs
kubectl delete jobs -l job-name=init-elasticsearch-index
kubectl delete jobs $(kubectl get jobs | grep init-elasticsearch | awk '{print $1}') || true

# Delete the secrets
kubectl delete secret chatbot-rag-secrets

# Optional: Delete any pods that might be stuck
kubectl delete pods -l app=chatbot-rag-app

echo "Cleanup complete!"

# Verify nothing is left
echo "Checking remaining resources..."
echo "Deployments:"
kubectl get deployments
echo "Services:"
kubectl get services
echo "Jobs:"
kubectl get jobs
echo "Secrets:"
kubectl get secrets
echo "Pods:"
kubectl get pods
