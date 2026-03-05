# vLLM GPU Inference

Deploy [vLLM](https://github.com/vllm-project/vllm) with Qwen/Qwen2.5-7B-Instruct in two ways:

- **GitHub Actions** – Deploys to ECS cluster with EC2 GPU instance (recommended)
- **Manual ECS** – Use `ecs/run-task.sh` for manual deployment

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
| `AWS_SECURITY_GROUP_ID` | SG ID (sg-xxx) or name (default: `ec2`) with inbound 8000 |
| `ECS_CLUSTER` | ECS cluster name (default: `vllm-cluster`) |
| `EC2_IAM_INSTANCE_PROFILE` | IAM instance profile (default: `ec2-ssm-role`); must have `AmazonEC2ContainerServiceforEC2Role` for ECS |
| `EC2_ROOT_VOLUME_SIZE` | Root EBS volume size in GB (default: `100`; vLLM image + model need ~50GB+) |
| `EC2_KEY_PAIR` | SSH key name (optional; only needed for manual SSH) |
| `EC2_ELASTIC_IP_ALLOCATION_ID` | Reuse existing EIP (avoids AddressLimitExceeded; e.g. `eipalloc-xxx`) |
| `EC2_SUBNET_ID` | Subnet for EC2 instance (optional; must be public for task public IP) |
| `EC2_INSTANCE_TYPE` | GPU instance (default: `g5.xlarge`). Use `g4dn.xlarge` if vCPU limit exceeded |

### Repo secrets

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | AWS credentials (IAM user needs ECS, EC2, SSM permissions) |
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

Push to `qa` or run the workflow manually. Steps: create ECS cluster → create/start g5.xlarge with ECS GPU AMI → register EC2 with cluster → register task definition → run vLLM task. The EC2 instance needs IAM profile with `AmazonEC2ContainerServiceforEC2Role`; you must have `ecsTaskExecutionRole` for the task. The workflow creates the CloudWatch log group `/ecs/vllm-qwen` if missing.

**Existing instances:** If you have an instance from the previous direct-EC2 setup, delete it so a new one is created with ECS cluster in user-data. The instance must register with the cluster to run tasks.

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
