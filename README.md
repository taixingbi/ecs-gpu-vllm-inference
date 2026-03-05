# vLLM GPU Inference

Deploy [vLLM](https://github.com/vllm-project/vllm) with Qwen/Qwen2.5-7B-Instruct in two ways:

- **AWS ECS** – EC2 launch type with GPU (recommended for containerized deployments)
- **EC2** – Direct g5.xlarge via GitHub Actions

See [plan.md](plan.md) for the ECS architecture and design.

## Architecture

- **Port 8000**: vLLM OpenAI API (`/v1/chat/completions`, `/v1/completions`)
- **Instance**: g5.xlarge (1× A10G 24GB) or g6.xlarge
- **Model**: Qwen/Qwen2.5-7B-Instruct

## Quick test

```bash
curl http://EC2_IP:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"hello"}]}'
```

Replace `EC2_IP` with the Elastic IP, ECS task IP, or `localhost` for local Docker.

## Configuration

### Repo variables

| Variable | Description |
|---------|-------------|
| `AWS_AMI_ID` | GPU AMI (optional; auto-resolved if unset) |
| `AWS_REGION` | Region (default: `us-east-1`) |
| `AWS_SECURITY_GROUP_ID` | SG with inbound 22, 8000 |
| `EC2_KEY_PAIR` | SSH key name (default: `ec2`) |
| `EC2_ELASTIC_IP_ALLOCATION_ID` | Reuse existing EIP (avoids AddressLimitExceeded; e.g. `eipalloc-xxx`) |
| `EC2_SUBNET_ID` | Public subnet for auto public IP when EIP limit reached (optional) |
| `EC2_INSTANCE_TYPE` | GPU instance (default: `g5.xlarge`). Use `g4dn.xlarge` if vCPU limit exceeded |

### Repo secrets

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | AWS credentials |
| `EC2_SSH_KEY` | Private key for `ec2-user` (ECS AMI) |
| `HUGGING_FACE_HUB_TOKEN` | Optional; for gated models |

### Model (deploy/.env)

| Variable | Description |
|----------|-------------|
| `INFER_MODEL` | Model to serve (default: `Qwen/Qwen2.5-7B-Instruct`) |
| `VLLM_IMAGE` | Image (default: `vllm/vllm-openai:cu130-nightly`) |
| `VLLM_USE_NGC` | Set to `1` for NGC image + pip install vllm |

**Driver issues:** If you see 803 or numpy/flash-attn errors, use `VLLM_IMAGE=nvcr.io/nvidia/pytorch:25.01-py3` and `VLLM_USE_NGC=1`.

## Docker (local)

Requires [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html).

```bash
cd deploy && cp .env.example .env
docker compose up -d
```

Models cached in the `models` volume (`/root/.cache/huggingface`).

## Deploy (EC2 via GitHub Actions)

Push to `qa` or run the workflow manually. Steps: create g5.xlarge with ECS GPU AMI → attach EIP → install Docker + NVIDIA → run vLLM. SSH user is `ec2-user`.

---

## ECS Deployment

Deploy vLLM with Qwen2.5-7B-Instruct on AWS ECS (EC2 launch type). ECS Fargate does not support GPUs.

### Prerequisites

Create once via Console or CLI:

| Resource | Purpose |
|----------|---------|
| ECS Cluster | Container orchestration |
| VPC + Subnets | Network (default VPC is fine) |
| Security Group | Inbound 8000 from your IP or VPC |
| EC2 GPU instance | g5.xlarge (or g6.xlarge) with ECS-optimized GPU AMI |
| IAM roles | `ecsTaskExecutionRole`, `AmazonEC2ContainerServiceforEC2Role` |

**GPU AMI** (region-specific):

```bash
aws ssm get-parameters --names /aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended --region us-east-1
```

**EC2 user data** must include:

```
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config
```

### Task Definition

1. Edit `ecs/task-definition.json`: replace `ACCOUNT_ID` in `executionRoleArn` with your AWS account ID.
2. Create CloudWatch log group: `aws logs create-log-group --log-group-name /ecs/vllm-qwen`
3. Register: `aws ecs register-task-definition --cli-input-json file://ecs/task-definition.json`

### Run Task

```bash
export ECS_CLUSTER=vllm-cluster
export ECS_SUBNETS=subnet-xxx,subnet-yyy
export ECS_SECURITY_GROUPS=sg-xxx
./ecs/run-task.sh
```

Or manually:

```bash
aws ecs run-task --cluster vllm-cluster --task-definition vllm-qwen \
  --launch-type EC2 \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx],assignPublicIp=DISABLED}"
```

### Get Endpoint and Test

After the task is RUNNING, get the private IP:

```bash
aws ecs describe-tasks --cluster vllm-cluster --tasks <TASK_ARN> \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' --output text
```

Test (from within VPC or via bastion):

```bash
curl http://<TASK_IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"hello"}]}'
```

### Gated Models

If the model is gated, add to the task definition `containerDefinitions[0].environment`:

```json
{"name": "HUGGING_FACE_HUB_TOKEN", "value": "<token>"}
```

Prefer AWS Secrets Manager for production.
