#!/usr/bin/env bash
#
# Builds the Dolibarr image, pushes it to ECR, and deploys it as an ECS
# Fargate service behind the shared ALB (tickets-platform-alb), wired to its
# own RDS MySQL instance. Sibling to tickets-microservice/deploy/deploy.sh —
# same pattern, same Learner Lab assumptions (LabRole, pre-existing cluster).
#
# Usage: cp .env.deploy.example .env.deploy && fill it in, then:
#   ./deploy/deploy.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${ENV_FILE:-.env.deploy}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. Copy .env.deploy.example to $ENV_FILE and fill in real values." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${AWS_REGION:?set in .env.deploy}"
: "${AWS_ACCOUNT_ID:?set in .env.deploy}"
: "${ECS_CLUSTER_NAME:?set in .env.deploy}"
: "${ECS_SERVICE_NAME:?set in .env.deploy}"
: "${ECR_REPO_NAME:?set in .env.deploy}"
: "${DOLI_DB_SERVER:?set in .env.deploy}"
: "${DOLI_DB_PASSWORD:?set in .env.deploy}"
: "${DOLI_ADMIN_PASSWORD:?set in .env.deploy}"

export AWS_DEFAULT_REGION="$AWS_REGION"

echo "==> Verifying AWS credentials"
aws sts get-caller-identity >/dev/null

echo "==> Ensuring ECR repo '$ECR_REPO_NAME' exists"
aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$ECR_REPO_NAME" >/dev/null

ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"
IMAGE_TAG="$(git rev-parse --short HEAD 2>/dev/null || date +%s)"
IMAGE_URI="${ECR_URI}:${IMAGE_TAG}"

echo "==> Logging in to ECR"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_URI"

echo "==> Building image ${IMAGE_URI} (this takes a few minutes — compiles several PHP extensions)"
docker build --platform linux/amd64 -t "$IMAGE_URI" -t "${ECR_URI}:latest" "$ROOT_DIR"

echo "==> Pushing image"
docker push "$IMAGE_URI"
docker push "${ECR_URI}:latest"

echo "==> Locating RDS instance for host $DOLI_DB_SERVER"
DB_INSTANCE_JSON="$(aws rds describe-db-instances \
  --query "DBInstances[?Endpoint.Address=='${DOLI_DB_SERVER}'] | [0]" \
  --output json)"

if [[ "$DB_INSTANCE_JSON" == "null" || -z "$DB_INSTANCE_JSON" ]]; then
  echo "Could not find an RDS instance with endpoint $DOLI_DB_SERVER in $AWS_REGION" >&2
  exit 1
fi

VPC_ID="$(echo "$DB_INSTANCE_JSON" | jq -r '.DBSubnetGroup.VpcId')"
RDS_SG_ID="$(echo "$DB_INSTANCE_JSON" | jq -r '.VpcSecurityGroups[0].VpcSecurityGroupId')"
echo "    VPC: $VPC_ID  RDS security group: $RDS_SG_ID"

echo "==> Ensuring ECS service security group exists"
APP_SG_NAME="${ECS_SERVICE_NAME}-sg"
APP_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${APP_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"

if [[ -z "$APP_SG_ID" || "$APP_SG_ID" == "None" ]]; then
  APP_SG_ID="$(aws ec2 create-security-group \
    --group-name "$APP_SG_NAME" \
    --description "dolibarr ECS service" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)"
  echo "    Created $APP_SG_ID"
else
  echo "    Reusing $APP_SG_ID"
fi

if [[ -n "${ALB_SG_ID:-}" ]]; then
  aws ec2 authorize-security-group-ingress \
    --group-id "$APP_SG_ID" \
    --protocol tcp --port 80 --source-group "$ALB_SG_ID" >/dev/null 2>&1 || true
  aws ec2 revoke-security-group-ingress \
    --group-id "$APP_SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
else
  aws ec2 authorize-security-group-ingress \
    --group-id "$APP_SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
fi

echo "==> Ensuring RDS security group allows inbound 3306 from the ECS service"
aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG_ID" \
  --protocol tcp --port 3306 --source-group "$APP_SG_ID" >/dev/null 2>&1 || true

echo "==> Picking subnets in $VPC_ID"
SUBNET_IDS="$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')"
echo "    Subnets: $SUBNET_IDS"

echo "==> Rendering task definition"
export AWS_ACCOUNT_ID AWS_REGION IMAGE_URI DOLI_DB_SERVER DOLI_DB_PORT DOLI_DATABASE DOLI_DB_USER DOLI_DB_PASSWORD DOLI_URL_ROOT DOLI_ADMIN_LOGIN DOLI_ADMIN_PASSWORD TICKETS_MICROSERVICE_URL_INTERNAL TICKETS_MICROSERVICE_URL_PUBLIC LOG_GROUP
envsubst < "$ROOT_DIR/ecs/task-definition.template.json" > "$ROOT_DIR/ecs/task-definition.json"

echo "==> Registering task definition"
TASK_DEF_ARN="$(aws ecs register-task-definition \
  --cli-input-json "file://$ROOT_DIR/ecs/task-definition.json" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
echo "    $TASK_DEF_ARN"

CONTAINER_NAME="$(jq -r '.containerDefinitions[0].name' "$ROOT_DIR/ecs/task-definition.json")"

echo "==> Creating/updating ECS service"
SERVICE_STATUS="$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$ECS_SERVICE_NAME" \
    --query 'services[0].status' --output text 2>/dev/null || true)"

if [[ "$SERVICE_STATUS" == "ACTIVE" && -n "${TARGET_GROUP_ARN:-}" ]]; then
  EXISTING_LB_COUNT="$(aws ecs describe-services --cluster "$ECS_CLUSTER_NAME" --services "$ECS_SERVICE_NAME" \
    --query 'length(services[0].loadBalancers)' --output text)"
  if [[ "$EXISTING_LB_COUNT" == "0" ]]; then
    echo "    Service exists without a load balancer attached; recreating the service"
    aws ecs update-service --cluster "$ECS_CLUSTER_NAME" --service "$ECS_SERVICE_NAME" --desired-count 0 >/dev/null
    aws ecs delete-service --cluster "$ECS_CLUSTER_NAME" --service "$ECS_SERVICE_NAME" --force >/dev/null
    aws ecs wait services-inactive --cluster "$ECS_CLUSTER_NAME" --services "$ECS_SERVICE_NAME" 2>/dev/null || true
    SERVICE_STATUS=""
  fi
fi

if [[ "$SERVICE_STATUS" == "ACTIVE" ]]; then
  aws ecs update-service \
    --cluster "$ECS_CLUSTER_NAME" \
    --service "$ECS_SERVICE_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --force-new-deployment >/dev/null
else
  if [[ -n "${TARGET_GROUP_ARN:-}" ]]; then
    aws ecs create-service \
      --cluster "$ECS_CLUSTER_NAME" \
      --service-name "$ECS_SERVICE_NAME" \
      --task-definition "$TASK_DEF_ARN" \
      --desired-count 1 \
      --launch-type FARGATE \
      --health-check-grace-period-seconds 90 \
      --load-balancers "targetGroupArn=${TARGET_GROUP_ARN},containerName=${CONTAINER_NAME},containerPort=80" \
      --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${APP_SG_ID}],assignPublicIp=ENABLED}" >/dev/null
  else
    aws ecs create-service \
      --cluster "$ECS_CLUSTER_NAME" \
      --service-name "$ECS_SERVICE_NAME" \
      --task-definition "$TASK_DEF_ARN" \
      --desired-count 1 \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],securityGroups=[${APP_SG_ID}],assignPublicIp=ENABLED}" >/dev/null
  fi
fi

echo "==> Waiting for service to stabilize (this can take a few minutes)"
aws ecs wait services-stable --cluster "$ECS_CLUSTER_NAME" --services "$ECS_SERVICE_NAME"

echo "==> Done."
