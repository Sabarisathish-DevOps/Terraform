provider "aws" {
  region = "Region"
}

# Define variables for autoscaling group and other required parameters
variable "asg_name" {
  type    = string
  default = "Auto_scaling_group_name"
}

variable "instance_key" {
  type    = string
  default = "/path/to/the/key.pem"
}

variable "instance_user" {
  type    = string
  default = "login_user"
}

variable "ami_name" {
  type    = string
  default = "AWS_ami_name"
}

variable "launch_template_name" {
  type    = string
  default = "AWS_launch_template_name"
}

# Initialize AMI counter if the file does not exist
resource "null_resource" "initialize_ami_counter" {
  provisioner "local-exec" {
    command = "echo '0' > ${path.module}/ami_counter.txt || true"
  }

  triggers = {
    always_run = "${timestamp()}"
  }
}

# Read the current AMI counter from the file
data "local_file" "ami_counter" {
  filename = "${path.module}/ami_counter.txt"
}

locals {
  ami_number = tonumber(coalesce(trim(data.local_file.ami_counter.content, " "), "0")) + 1
}

# Update the counter file with the new number
resource "local_file" "update_ami_counter" {
  filename = "${path.module}/ami_counter.txt"
  content  = "${local.ami_number}"
  depends_on = [null_resource.initialize_ami_counter]
}

# Use the ami_number in the AMI name
locals {
  ami_name_with_version = "${var.ami_name}-v${local.ami_number}"
}

# Get the details of the Auto Scaling Group
data "aws_autoscaling_group" "target_asg" {
  name = var.asg_name
}

# Get EC2 instances filtered by tag or based on ASG
data "aws_instances" "asg_instances" {
  filter {
    name   = "tag:aws:autoscaling:groupName"
    values = [data.aws_autoscaling_group.target_asg.name]
  }
}

# Get the instance IDs from the Auto Scaling Group (first instance)
data "aws_instance" "first_instance" {
  instance_id = data.aws_instances.asg_instances.ids[0]
}

# Execute the code pull and build process on the first instance of the ASG
resource "null_resource" "update_source_reload_pm2" {
  connection {
    type        = "ssh"
    user        = var.instance_user
    private_key = file(var.instance_key)
    host        = data.aws_instance.first_instance.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "PROJECT_DIR=$(find / -type d -name 'DIRECTORY_NAME' -print -quit)",
      "cd $PROJECT_DIR",
      "git remote -v",
      "git pull origin BRANCH_NAME",
      "npm install",
      "npm run build",
      "pm2 reload 1",
      # Monitor PM2 logs for process 1 for the success message
      "timeout 180 sh -c 'LOG_PRINTED=false; until pm2 logs 1 --lines 10 | grep -q \"Nest application successfully started\"; do echo \"Waiting for successful start...\"; sleep 5; done; if [ \"$$LOG_PRINTED\" = false ]; then echo \"Nest application successfully started\"; LOG_PRINTED=true; fi'",
      # Check if process 1 is running before attempting to reload process 2
      "if pm2 status | grep -q '1.*online'; then pm2 reload 2; else echo \"Process 1 is not running. Skipping reload of process 2.\"; fi"
    ]
  }

  triggers = {
    always_run = "${timestamp()}"
  }
}

# Create an AMI from the instance without rebooting using AWS CLI
resource "null_resource" "create_ami" {
  provisioner "local-exec" {
    command = "aws ec2 create-image --instance-id ${data.aws_instance.first_instance.id} --name '${local.ami_name_with_version}' --no-reboot"
  }

  triggers = {
    always_run   = "${timestamp()}"
    update_source = null_resource.update_source_reload_pm2.id
  }

  depends_on = [null_resource.update_source_reload_pm2, local_file.update_ami_counter]
}

# Wait for the AMI to become available before updating the launch template
resource "null_resource" "wait_for_ami" {
  provisioner "local-exec" {
    command = <<EOT
      while true; do
        ami_status=$(aws ec2 describe-images --image-ids $(aws ec2 describe-images --filters Name=name,Values=${local.ami_name_with_version} --query 'Images[0].ImageId' --output text) --query 'Images[0].State' --output text)
        if [ "$ami_status" = "available" ]; then
          echo "AMI is available."
          break
        else
          echo "Waiting for AMI to become available..."
          sleep 30
        fi
      done
    EOT
  }

  triggers = {
    ami_creation = null_resource.create_ami.id
  }

  depends_on = [null_resource.create_ami]
}

# Create a new version of the existing Launch Template using the new AMI
resource "null_resource" "update_launch_template_version" {
  provisioner "local-exec" {
    command = <<EOT
      aws ec2 create-launch-template-version \
        --launch-template-name ${var.launch_template_name} \
        --source-version $(aws ec2 describe-launch-templates --launch-template-names ${var.launch_template_name} --query "LaunchTemplates[0].LatestVersionNumber") \
        --launch-template-data "{\"ImageId\":\"$(aws ec2 describe-images --filters Name=name,Values=${local.ami_name_with_version} --query 'Images[0].ImageId' --output text)\"}"
    EOT
  }

  triggers = {
    ami_ready = null_resource.wait_for_ami.id
  }

  depends_on = [null_resource.wait_for_ami]
}

# Modify the Launch Template to set the new version as the default
resource "null_resource" "set_default_launch_template_version" {
  provisioner "local-exec" {
    command = <<EOT
      aws ec2 modify-launch-template \
        --launch-template-name ${var.launch_template_name} \
        --default-version $(aws ec2 describe-launch-templates --launch-template-names ${var.launch_template_name} --query "LaunchTemplates[0].LatestVersionNumber")
    EOT
  }

  triggers = {
    always_run                   = "${timestamp()}"
    update_launch_template_version = null_resource.update_launch_template_version.id
  }

  depends_on = [null_resource.update_launch_template_version]
}

# Get the previous AMI ID (assuming the naming convention follows the pattern)
data "aws_ami" "previous_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["${var.ami_name}-v${local.ami_number - 1}"]  # Use the previous version number
  }provider "aws" {
  region = "Region"
}

# Define variables for autoscaling group and other required parameters
variable "asg_name" {
  type    = string
  default = "Auto_scaling_group_name"
}

variable "instance_key" {
  type    = string
  default = "/path/to/the/key.pem"
}

variable "instance_user" {
  type    = string
  default = "login_user"
}

variable "ami_name" {
  type    = string
  default = "AWS_ami_name"
}

variable "launch_template_name" {
  type    = string
  default = "AWS_launch_template_name"
}

# Initialize AMI counter if the file does not exist
resource "null_resource" "initialize_ami_counter" {
  provisioner "local-exec" {
    command = "echo '0' > ${path.module}/ami_counter.txt || true"
  }

  triggers = {
    always_run = "${timestamp()}"
  }
}

# Read the current AMI counter from the file
data "local_file" "ami_counter" {
  filename = "${path.module}/ami_counter.txt"
}

locals {
  ami_number = tonumber(coalesce(trim(data.local_file.ami_counter.content, " "), "0")) + 1
}

# Update the counter file with the new number
resource "local_file" "update_ami_counter" {
  filename = "${path.module}/ami_counter.txt"
  content  = "${local.ami_number}"
  depends_on = [null_resource.initialize_ami_counter]
}

# Use the ami_number in the AMI name
locals {
  ami_name_with_version = "${var.ami_name}-v${local.ami_number}"
}

# Get the details of the Auto Scaling Group
data "aws_autoscaling_group" "target_asg" {
  name = var.asg_name
}

# Get EC2 instances filtered by tag or based on ASG
data "aws_instances" "asg_instances" {
  filter {
    name   = "tag:aws:autoscaling:groupName"
    values = [data.aws_autoscaling_group.target_asg.name]
  }
}

# Get the instance IDs from the Auto Scaling Group (first instance)
data "aws_instance" "first_instance" {
  instance_id = data.aws_instances.asg_instances.ids[0]
}

# Execute the code pull and build process on the first instance of the ASG
resource "null_resource" "update_source_reload_pm2" {
  connection {
    type        = "ssh"
    user        = var.instance_user
    private_key = file(var.instance_key)
    host        = data.aws_instance.first_instance.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "PROJECT_DIR=$(find / -type d -name 'DIRECTORY_NAME' -print -quit)",
      "cd $PROJECT_DIR",
      "git remote -v",
      "git pull origin BRANCH_NAME",
      "npm install",
      "npm run build",
      "pm2 reload 1",
      # Monitor PM2 logs for process 1 for the success message
      "timeout 180 sh -c 'LOG_PRINTED=false; until pm2 logs 1 --lines 10 | grep -q \"Nest application successfully started\"; do echo \"Waiting for successful start...\"; sleep 5; done; if [ \"$$LOG_PRINTED\" = false ]; then echo \"Nest application successfully started\"; LOG_PRINTED=true; fi'",
      # Check if process 1 is running before attempting to reload process 2
      "if pm2 status | grep -q '1.*online'; then pm2 reload 2; else echo \"Process 1 is not running. Skipping reload of process 2.\"; fi"
    ]
  }

  triggers = {
    always_run = "${timestamp()}"
  }
}

# Create an AMI from the instance without rebooting using AWS CLI
resource "null_resource" "create_ami" {
  provisioner "local-exec" {
    command = "aws ec2 create-image --instance-id ${data.aws_instance.first_instance.id} --name '${local.ami_name_with_version}' --no-reboot"
  }

  triggers = {
    always_run   = "${timestamp()}"
    update_source = null_resource.update_source_reload_pm2.id
  }

  depends_on = [null_resource.update_source_reload_pm2, local_file.update_ami_counter]
}

# Wait for the AMI to become available before updating the launch template
resource "null_resource" "wait_for_ami" {
  provisioner "local-exec" {
    command = <<EOT
      while true; do
        ami_status=$(aws ec2 describe-images --image-ids $(aws ec2 describe-images --filters Name=name,Values=${local.ami_name_with_version} --query 'Images[0].ImageId' --output text) --query 'Images[0].State' --output text)
        if [ "$ami_status" = "available" ]; then
          echo "AMI is available."
          break
        else
          echo "Waiting for AMI to become available..."
          sleep 30
        fi
      done
    EOT
  }

  triggers = {
    ami_creation = null_resource.create_ami.id
  }

  depends_on = [null_resource.create_ami]
}

# Create a new version of the existing Launch Template using the new AMI
resource "null_resource" "update_launch_template_version" {
  provisioner "local-exec" {
    command = <<EOT
      aws ec2 create-launch-template-version \
        --launch-template-name ${var.launch_template_name} \
        --source-version $(aws ec2 describe-launch-templates --launch-template-names ${var.launch_template_name} --query "LaunchTemplates[0].LatestVersionNumber") \
        --launch-template-data "{\"ImageId\":\"$(aws ec2 describe-images --filters Name=name,Values=${local.ami_name_with_version} --query 'Images[0].ImageId' --output text)\"}"
    EOT
  }

  triggers = {
    ami_ready = null_resource.wait_for_ami.id
  }

  depends_on = [null_resource.wait_for_ami]
}

# Modify the Launch Template to set the new version as the default
resource "null_resource" "set_default_launch_template_version" {
  provisioner "local-exec" {
    command = <<EOT
      aws ec2 modify-launch-template \
        --launch-template-name ${var.launch_template_name} \
        --default-version $(aws ec2 describe-launch-templates --launch-template-names ${var.launch_template_name} --query "LaunchTemplates[0].LatestVersionNumber")
    EOT
  }

  triggers = {
    always_run                   = "${timestamp()}"
    update_launch_template_version = null_resource.update_launch_template_version.id
  }

  depends_on = [null_resource.update_launch_template_version]
}

# Get the previous AMI ID (assuming the naming convention follows the pattern)
data "aws_ami" "previous_ami" {
  most_recent = true

  filter {
    name   = "name"
    values = ["${var.ami_name}-v${local.ami_number - 1}"]  # Use the previous version number
  }
}

# Deregister the previous AMI if it exists
resource "null_resource" "deregister_previous_ami" {
  provisioner "local-exec" {
    command = "aws ec2 deregister-image --image-id ${data.aws_ami.previous_ami.id}"
  }

  # This will only run if a previous AMI is found
  count = data.aws_ami.previous_ami.id != "" ? 1 : 0

  triggers = {
    always_run = "${timestamp()}"
    set_default_version = null_resource.set_default_launch_template_version.id  # Trigger after setting default version
  }

  depends_on = [null_resource.set_default_launch_template_version]
}

}

# Deregister the previous AMI if it exists
resource "null_resource" "deregister_previous_ami" {
  provisioner "local-exec" {
    command = "aws ec2 deregister-image --image-id ${data.aws_ami.previous_ami.id}"
  }

  # This will only run if a previous AMI is found
  count = data.aws_ami.previous_ami.id != "" ? 1 : 0

  triggers = {
    always_run = "${timestamp()}"
    set_default_version = null_resource.set_default_launch_template_version.id  # Trigger after setting default version
  }

  depends_on = [null_resource.set_default_launch_template_version]
}
