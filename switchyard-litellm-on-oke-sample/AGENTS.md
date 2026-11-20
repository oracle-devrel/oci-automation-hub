# Repository Instructions

This repository deploys infrastructure with Terraform
and configure the Kubernetes cluster with Helm and
kubectl commands.

## Deployment and cleanup

When the user asks to:
- "Deploy this repository"
- "Deploy the application"
- "Clean up the resources"
- "Run terraform destroy"
- "Remove all the created resources"

Use the deployment and cleanup skill:
.agents/skills/deploy-repository/SKILL.md

Follow the skill's instructions.

Do not invent Terraform or Helm commands.

Never print credentials or tokens.

Always present the Terraform plan and obtain
explicit approval before performing changes.
