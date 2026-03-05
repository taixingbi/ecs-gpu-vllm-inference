#!/usr/bin/env bash
# Run vLLM Qwen2.5-7B-Instruct on ECS (EC2 launch type).
# Prerequisites: ECS cluster with GPU capacity, task definition registered.

set -e

CLUSTER="${ECS_CLUSTER:-vllm-cluster}"
TASK_DEF="${ECS_TASK_DEF:-vllm-qwen}"
REGION="${AWS_REGION:-us-east-1}"
SUBNETS="${ECS_SUBNETS:-}"
SECURITY_GROUPS="${ECS_SECURITY_GROUPS:-}"

if [[ -z "$SUBNETS" || -z "$SECURITY_GROUPS" ]]; then
  echo "Set ECS_SUBNETS and ECS_SECURITY_GROUPS (comma-separated IDs)."
  echo "Example:"
  echo "  export ECS_SUBNETS=subnet-xxx,subnet-yyy"
  echo "  export ECS_SECURITY_GROUPS=sg-xxx"
  exit 1
fi

# Convert comma-separated to JSON arrays for aws cli
SUBNET_ARR="[\"$(echo "$SUBNETS" | sed 's/,/","/g')\"]"
SG_ARR="[\"$(echo "$SECURITY_GROUPS" | sed 's/,/","/g')\"]"

# Register task definition if file exists
TASK_JSON="$(dirname "$0")/task-definition.json"
if [[ -f "$TASK_JSON" ]]; then
  echo "Registering task definition..."
  aws ecs register-task-definition \
    --cli-input-json "file://$TASK_JSON" \
    --region "$REGION" \
    --output text --query 'taskDefinition.taskDefinitionArn'
fi

echo "Running task on cluster $CLUSTER..."
TASK_ARN=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEF" \
  --launch-type EC2 \
  --network-configuration "awsvpcConfiguration={subnets=$SUBNET_ARR,securityGroups=$SG_ARR,assignPublicIp=DISABLED}" \
  --region "$REGION" \
  --output text --query 'tasks[0].taskArn')

echo "Task: $TASK_ARN"
echo "Wait for RUNNING, then get private IP:"
echo "  aws ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARN --region $REGION --query 'tasks[0].attachments[0].details[?name==\`privateIPv4Address\`].value' --output text"
echo ""
echo "Test: curl http://<TASK_IP>:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"Qwen/Qwen2.5-7B-Instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
