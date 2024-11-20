#!/bin/bash

# Set your AWS region and account ID
AWS_REGION="us-east-1"  # Change this to your preferred region
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create a temporary working directory
WORK_DIR=$(mktemp -d)
cd $WORK_DIR

# Download and extract the application code
echo "Downloading application code..."
curl https://codeload.github.com/elastic/elasticsearch-labs/tar.gz/main | \
tar -xz --strip=2 elasticsearch-labs-main/example-apps/chatbot-rag-app

# Move to the application directory
cd chatbot-rag-app

# Copy the enhanced Dockerfile

# Copy the enhanced Dockerfile with fixed Node.js installation
# Create a temporary working directory
WORK_DIR=$(mktemp -d)
cd $WORK_DIR

# Download and extract the application code
echo "Downloading application code..."
curl https://codeload.github.com/elastic/elasticsearch-labs/tar.gz/main | \
tar -xz --strip=2 elasticsearch-labs-main/example-apps/chatbot-rag-app

# Move to the application directory
cd chatbot-rag-app

# First, modify requirements.txt to remove version constraints
sed -i 's/==.*//g' requirements.txt

# Create the Dockerfile
cat > Dockerfile << 'EOL'
FROM node:16-alpine as build-step
WORKDIR /app
ENV PATH /node_modules/.bin:$PATH
COPY frontend ./frontend
RUN rm -rf /app/frontend/node_modules
RUN cd frontend && yarn install
RUN cd frontend && REACT_APP_API_HOST=/api yarn build

FROM python:3.9-slim
WORKDIR /app
RUN mkdir -p ./frontend/build
COPY --from=build-step ./app/frontend/build ./frontend/build 
RUN mkdir ./api
RUN mkdir ./data

RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    software-properties-common \
    git \
    && rm -rf /var/lib/apt/lists/*

COPY api ./api
COPY data ./data
COPY requirements.txt ./requirements.txt

# Upgrade pip first and install dependencies without version constraints
RUN pip3 install --upgrade pip
RUN pip3 install --no-cache-dir -r ./requirements.txt
RUN pip3 install --no-cache-dir elastic-opentelemetry
RUN pip3 install --no-cache-dir opentelemetry-instrumentation-bedrock
RUN pip3 install --no-cache-dir opentelemetry-instrumentation-openai
RUN pip3 install --no-cache-dir opentelemetry-instrumentation-langchain

RUN opentelemetry-bootstrap -a install

ENV FLASK_ENV production
EXPOSE 4000

WORKDIR /app/api

# Use OpenTelemetry instrumentation
CMD ["opentelemetry-instrument", "flask", "run", "--host=0.0.0.0", "--port=4000"]
EOL

# Create ECR repository
echo "Creating ECR repository..."
aws ecr create-repository --repository-name chatbot-rag-app --region $AWS_REGION || true

# Login to ECR
echo "Logging into ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Copy deployment configuration
cat > k8s-deployment.yaml << 'EOL'
apiVersion: v1
kind: Secret
metadata:
  name: chatbot-rag-secrets
type: Opaque
data:
  AWS_ACCESS_KEY: "${AWS_ACCESS_KEY_BASE64}"
  AWS_SECRET_KEY: "${AWS_SECRET_KEY_BASE64}"
  ELASTIC_CLOUD_ID: "${ELASTIC_CLOUD_ID_BASE64}"
  ELASTIC_API_KEY: "${ELASTIC_API_KEY_BASE64}"
  OTEL_EXPORTER_OTLP_HEADERS: "${OTEL_EXPORTER_OTLP_HEADERS_BASE64}"
  OTEL_EXPORTER_OTLP_ENDPOINT: "${OTEL_EXPORTER_OTLP_ENDPOINT_BASE64}"

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatbot-rag-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: chatbot-rag-app
  template:
    metadata:
      labels:
        app: chatbot-rag-app
    spec:
      containers:
      - name: chatbot-rag-app
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/chatbot-rag-app:latest
        command: ["opentelemetry-instrument"]
        args: ["flask", "run", "--no-reload", "--host=0.0.0.0", "--port=4000"]
        ports:
        - containerPort: 4000
        env:
        - name: LLM_TYPE
          value: "bedrock"
        - name: AWS_REGION
          value: "${AWS_REGION}"
        - name: AWS_MODEL_ID
          value: "anthropic.claude-v2"
        - name: OTEL_LOGS_EXPORTER
          value: "otlp,console"
        - name: OTEL_TRACES_EXPORTER
          value: "otlp,console"
        - name: OTEL_METRICS_EXPORTER
          value: "otlp,console"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "service.name=chat-api,service.version=0.0.1,deployment.environment=dev"
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: "http/protobuf"
        - name: OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED
          value: "true"
        envFrom:
        - secretRef:
            name: chatbot-rag-secrets
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"

---
apiVersion: v1
kind: Service
metadata:
  name: chatbot-rag-service
spec:
  selector:
    app: chatbot-rag-app
  ports:
  - port: 80
    targetPort: 4000
  type: LoadBalancer
EOL

# Build and push Docker image
echo "Building and pushing Docker image..."
docker build -t chatbot-rag-app .
docker tag chatbot-rag-app:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/chatbot-rag-app:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/chatbot-rag-app:latest

# Create base64 encoded secrets
# Create base64 encoded secrets - Fixed version for special characters
AWS_ACCESS_KEY_BASE64=$(echo -n "$AWS_ACCESS_KEY" | base64 | tr -d '\n')
AWS_SECRET_KEY_BASE64=$(echo -n "$AWS_SECRET_KEY" | base64 | tr -d '\n')
ELASTIC_CLOUD_ID_BASE64=$(echo -n "$ELASTIC_CLOUD_ID" | base64 | tr -d '\n')
ELASTIC_API_KEY_BASE64=$(echo -n "$ELASTIC_API_KEY" | base64 | tr -d '\n')
OTEL_EXPORTER_OTLP_HEADERS_BASE64=$(echo -n "$OTEL_EXPORTER_OTLP_HEADERS" | base64 | tr -d '\n')
OTEL_EXPORTER_OTLP_ENDPOINT_BASE64=$(echo -n "$OTEL_EXPORTER_OTLP_ENDPOINT" | base64 | tr -d '\n')

# Replace variables in k8s-deployment.yaml
sed -i "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" k8s-deployment.yaml
sed -i "s/\${AWS_REGION}/$AWS_REGION/g" k8s-deployment.yaml
sed -i "s/\${AWS_ACCESS_KEY_BASE64}/$AWS_ACCESS_KEY_BASE64/g" k8s-deployment.yaml
sed -i "s/\${AWS_SECRET_KEY_BASE64}/$AWS_SECRET_KEY_BASE64/g" k8s-deployment.yaml
sed -i "s/\${ELASTIC_CLOUD_ID_BASE64}/$ELASTIC_CLOUD_ID_BASE64/g" k8s-deployment.yaml
sed -i "s/\${ELASTIC_API_KEY_BASE64}/$ELASTIC_API_KEY_BASE64/g" k8s-deployment.yaml
sed -i "s/\${OTEL_EXPORTER_OTLP_HEADERS_BASE64}/$OTEL_EXPORTER_OTLP_HEADERS_BASE64/g" k8s-deployment.yaml
sed -i "s/\${OTEL_EXPORTER_OTLP_ENDPOINT_BASE64}/$OTEL_EXPORTER_OTLP_ENDPOINT_BASE64/g" k8s-deployment.yaml

TIMESTAMP=$(date +%s)

# Create the job yaml with evaluated timestamp
cat > init-index-job.yaml << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: init-elasticsearch-index-${TIMESTAMP}
spec:
  template:
    spec:
      containers:
      - name: init-index
        image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/chatbot-rag-app:latest
        workingDir: /app/api
        command: ["python3", "-m", "flask", "--app", "app", "create-index"]
        env:
        - name: FLASK_APP
          value: "app"
        - name: LLM_TYPE
          value: "bedrock"
        - name: AWS_REGION
          value: "us-east-1"
        - name: AWS_MODEL_ID
          value: "anthropic.claude-v2"
        - name: ES_INDEX
          value: "workplace-app-docs"
        - name: ES_INDEX_CHAT_HISTORY
          value: "workplace-app-docs-chat-history"
        - name: ELASTIC_CLOUD_ID
          valueFrom:
            secretKeyRef:
              name: chatbot-rag-secrets
              key: ELASTIC_CLOUD_ID
        - name: ELASTIC_API_KEY
          valueFrom:
            secretKeyRef:
              name: chatbot-rag-secrets
              key: ELASTIC_API_KEY
        envFrom:
        - secretRef:
            name: chatbot-rag-secrets
      restartPolicy: Never
  backoffLimit: 4
EOF

# Delete old job
kubectl delete job $(kubectl get jobs | grep init-elasticsearch | awk '{print $1}') || true

# Apply new job
kubectl apply -f init-index-job.yaml

# Store the job name
JOB_NAME="init-elasticsearch-index-${TIMESTAMP}"

# Check job status
kubectl get jobs
kubectl logs job/"${JOB_NAME}"

# Apply Kubernetes configurations
echo "Applying Kubernetes configurations..."
kubectl apply -f k8s-deployment.yaml

# Wait for deployment to complete
echo "Waiting for deployment to complete..."
kubectl rollout status deployment/chatbot-rag-app

# Get the LoadBalancer URL
echo "Waiting for LoadBalancer to be ready..."
sleep 30
echo "Application URL:"
kubectl get service chatbot-rag-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Clean up temporary directory
cd -
rm -rf $WORK_DIR

echo "Deployment complete! Please make sure to check the logs and verify the application is running correctly."
