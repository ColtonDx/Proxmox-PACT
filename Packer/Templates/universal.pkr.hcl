################################################################################
# Universal Proxmox VM Customization Template
#
# This Packer template can build images for multiple distributions by passing
# the 'distro' variable. Supported distros:
#   - debian11, debian12, debian13
#   - ubuntu2204, ubuntu2404, ubuntu2604
#   - fedora43, fedora44
#
# Usage:
#   packer build -var "distro=debian12" -var-file=vars.json universal.pkr.hcl
#
################################################################################

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.2"
      source  = "github.com/hashicorp/proxmox"
    }
    ansible = {
      version = ">= 1.0.0, < 1.1.4"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# Variable Definitions
variable "proxmox_api_url" {
  type        = string
  description = "URL of the Proxmox API"
}

variable "proxmox_api_token_id" {
  type        = string
  description = "Proxmox API token ID"
}

variable "proxmox_api_token_secret" {
  type        = string
  sensitive   = true
  description = "Proxmox API token secret"
}

variable "proxmox_target_node" {
  type        = string
  sensitive   = true
  description = "Proxmox target node name"
}

variable "proxmox_storage" {
  type        = string
  description = "Proxmox storage pool name"
}

variable "vmid" {
  type        = string
  description = "VM ID for the build"
}

variable "distro" {
  type        = string
  description = "Distribution to build (debian11, debian12, debian13, ubuntu2204, ubuntu2404, ubuntu2604, fedora43, fedora44)"
}

variable "ansible_playbook" {
  type        = string
  default     = "./Ansible/Playbooks/image_customizations.yml"
  description = "Path to Ansible playbook for template customization"
}

variable "ansible_varfile" {
  type        = string
  default     = "./Ansible/Variables/vars.yml"
  description = "Path to Ansible variables file for playbook"
}

# Locals for distro-specific configuration
locals {
  distro_config = {
    debian11 = {
      template_name = "Template-Debian-11"
      vm_name       = "PACT-Debian-11"
    }
    debian12 = {
      template_name = "Template-Debian-12"
      vm_name       = "PACT-Debian-12"
    }
    debian13 = {
      template_name = "Template-Debian-13"
      vm_name       = "PACT-Debian-13"
    }
    ubuntu2204 = {
      template_name = "Template-Ubuntu-2204"
      vm_name       = "PACT-Ubuntu-2204"
    }
    ubuntu2404 = {
      template_name = "Template-Ubuntu-2404"
      vm_name       = "PACT-Ubuntu-2404"
    }
    ubuntu2604 = {
      template_name = "Template-Ubuntu-2604"
      vm_name       = "PACT-Ubuntu-2604"
    }
    fedora43 = {
      template_name = "Template-Fedora-43"
      vm_name       = "PACT-Fedora-43"
    }
    fedora44 = {
      template_name = "Template-Fedora-44"
      vm_name       = "PACT-Fedora-44"
    }
  }

  config     = local.distro_config[var.distro]
  build_time = timestamp()
}

# Resource Definition for the VM Template
source "proxmox-clone" "vm" {
  # Proxmox Connection Settings
  proxmox_url              = "${var.proxmox_api_url}"
  username                 = "${var.proxmox_api_token_id}"
  token                    = "${var.proxmox_api_token_secret}"
  insecure_skip_tls_verify = true

  # VM General Settings
  node                 = "${var.proxmox_target_node}"
  vm_id                = "${var.vmid}"
  vm_name              = local.config.vm_name
  template_description = "An Image Customized by Packer. Distribution: ${var.distro}. Build Date: ${local.build_time}"
  clone_vm             = local.config.template_name
  ssh_username         = "root"
  qemu_agent           = true

  # VM Hard Disk Settings
  scsi_controller = "virtio-scsi-pci"

  # VM CPU/MEM Settings
  cores    = "1"
  cpu_type = "host"
  memory   = "1024"

  # VM Network Settings
  network_adapters {
    model    = "virtio"
    bridge   = "vmbr0"
    firewall = "false"
  }

  ipconfig {
    ip = "dhcp"
  }

  # VM Cloud-Init Settings
  cloud_init              = true
  cloud_init_storage_pool = var.proxmox_storage
}

# Build Definition to create the VM Template
build {
  name    = "Clone VM"
  sources = ["proxmox-clone.vm"]

  # Wait for Cloud-Init to finish
  provisioner "shell" {
    inline = [
      "while [ ! -f /var/lib/cloud/instance/boot-finished ]; do echo 'Waiting for cloud-init...'; sleep 1; done"
    ]
  }

  # Run Ansible playbook for customization (handles updates and configuration)
  provisioner "ansible" {
    playbook_file   = var.ansible_playbook
    use_proxy       = false
    extra_arguments = ["-e", "@${var.ansible_varfile}", "-e", "distro=${var.distro}"]
  }

  # Generalize the Image
  provisioner "shell" {
    inline = [
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo truncate -s 0 /etc/machine-id",
      "if command -v apt-get &> /dev/null; then sudo apt-get -y autoremove --purge && sudo apt-get clean; fi",
      "if command -v dnf &> /dev/null; then sudo dnf autoremove -y && sudo dnf clean all; fi",
      "sudo cloud-init clean",
      "sudo rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg",
      "sudo rm -f /etc/NetworkManager/system-connections/*",
      "sudo sync",
      "sudo rm -rf /var/log/* /home/*/.bash_history"
    ]
  }
}
