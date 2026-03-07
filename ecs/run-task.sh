#!/usr/bin/env bash
# Run vLLM Qwen2.5-7B-Instruct on ECS (EC2 launch type, bridge mode).
# Prerequisites: ECS cluster with GPU capacity, task definition registered.

set -e

CLUSTER="${ECS_CLUSTER:-vllm-cluster}"
TASK_DEF="${ECS_TASK_DEF:-vllm-qwen}"
REGION="${AWS_REGION:-us-east-1}"

# Register task definition if file exists
TASK_JSON="$(dirname "$0")/task-definition.json"
if [[ -f "$TASK_JSON" ]]; then
  echo "Registering task definition..."
  aws ecs register-task-definition \
    --cli-input-json "file://$TASK_JSON" \
    --region "$REGION" \
    --output text --query 'taskDefinition.taskDefinitionArn'
fi

echo "Running task on cluster $CLUSTER (bridge mode)..."
TASK_ARN=$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEF" \
  --launch-type EC2 \
  --region "$REGION" \
  --output text --query 'tasks[0].taskArn')

echo "Task: $TASK_ARN"
echo "With bridge mode, vLLM listens on the instance's port 8000."
echo "Use the EC2 instance's public IP to test: curl http://<INSTANCE_IP>:8000/v1/models"
echo ""
echo "Test: curl http://<INSTANCE_IP>:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"Qwen/Qwen2.5-7B-Instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
