# 🚀 Terraform EC2 Deployment & AMI Versioning Automation

This Terraform script automates a full workflow for:
1. Pulling and building code on an EC2 instance in an Auto Scaling Group (ASG)
2. Creating a versioned Amazon Machine Image (AMI)
3. Updating the Launch Template with the new AMI
4. Setting the new Launch Template version as default
5. Deregistering the previous AMI

---

## 📁 Overview of Components

| Resource | Purpose |
|----------|---------|
| `provider "aws"` | Specifies AWS region |
| `variable` | Holds reusable input values |
| `local_file` + `null_resource` | Tracks and increments AMI version |
| `data` sources | Gets ASG and instance information |
| `null_resource` with SSH | Connects to instance, pulls code, builds project |
| `local-exec` provisioners | Creates AMI, waits for availability, updates LT |
| `data "aws_ami"` | Finds previous AMI |
| `null_resource` | Deregisters previous AMI |

---

## 📦 Prerequisites

- ✅ AWS CLI configured
- ✅ SSH private key for EC2 instance
- ✅ Terraform installed
- ✅ Permissions for managing EC2, ASG, AMIs, and Launch Templates

---

## 🔧 Variables

Define these in a `.tfvars` file or set via CLI:

```hcl
variable "asg_name" {
  default = "Auto_scaling_group_name"
}

variable "instance_key" {
  default = "/path/to/key.pem"
}

variable "instance_user" {
  default = "ec2-user"
}

variable "ami_name" {
  default = "my-application-ami"
}

variable "launch_template_name" {
  default = "my-launch-template"
}
