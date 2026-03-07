git add .
git commit -m "fix2"
git push


Create ECS cluster (lines 30–41) – Creates vllm-cluster if it doesn’t exist.
Create CloudWatch log group
Resolve security group
Find or create EC2 instance
Wait for instance running
Get instance subnet and EIP
Configure ECS agent via SSM
Wait for EC2 to register with ECS cluster (lines 186–208)