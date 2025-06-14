packer {
  required_plugins {
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = "~> 1"
    }
    vmware = {
      source = "github.com/hashicorp/vmware"
      version = "~> 1"
    }
  }
}

variable "luks_pwd" {
    type        = string
    description = "Password to unlock the LUKS partition"
    sensitive   = true
}

variable "grub_pwd" {
    type        = string
    description = "Password to unlock GRUB superuser"
    sensitive   = true
}

variable "root_pwd" {
    type = string
    description = "Linux root user password"
    sensitive   = true
}

variable "forti_username" {
  type        = string
  description = "Default username for OpenFortiVPN"
  default     = "invalid_user"
}

variable "forti_dns" {
  type        = string
  description = "VPN server hostname"
  default     = "vpn.example.net"
}

variable "vm_name" {
  type        = string
  description = "VM name"
  default     = "packer-fortress"
}

local "packer_pwd" {
  expression = "{${uuidv4()}}"
  sensitive = true
}

locals {
  iso_url      = "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-virt-3.22.0-x86_64.iso"
  iso_checksum = "sha256:c935c3715c80ca416e2ce912c552f0cbfd8531219b7973ae4a600873c793eb1b"
}

source "hyperv-iso" "vm" {
  iso_url                = "${local.iso_url}"
  iso_checksum           = "${local.iso_checksum}"
  enable_dynamic_memory  = false
  enable_secure_boot     = false
  secure_boot_template   = "MicrosoftUEFICertificateAuthority"
  cpus                   = "2"
  memory                 = "256"
  disk_size              = "512"
  generation             = "2"
  switch_name            = "Default Switch"
  vm_name                = "${var.vm_name}"
  communicator           = "ssh"
  ssh_username           = "packer"
  ssh_password           = "${local.packer_pwd}"
  ssh_disable_agent_forwarding = true
  output_directory       = "output\\hyperv"
  boot_wait              = "5s"
  boot_keygroup_interval = "20ms"
  boot_command           = [
    "root<enter><wait>",
    "setup-interfaces -ar<enter><wait2>",
    "setup-ntp chrony<enter><wait6>",
    "setup-apkrepos -1c<enter><wait>",
    "setup-sshd openssh<enter><wait>",
    "adduser packer<enter><wait>",
    "${local.packer_pwd}<enter><wait>",
    "${local.packer_pwd}<enter><wait>",
    "apk add --no-cache doas<enter><wait>",
    "echo 'permit nopass packer' >> /etc/doas.d/packer.conf<enter><wait>",
    "apk add --no-cache hvtools && rc-service hv_kvp_daemon start<enter>"
  ]
}

source "vmware-iso" "vm" {
  iso_url                = "${local.iso_url}"
  iso_checksum           = "${local.iso_checksum}"
  firmware               = "efi"
  cpus                   = "2"
  memory                 = "256"
  disk_size              = "512"
  disk_adapter_type      = "nvme"
  disk_type_id           = "0"
  guest_os_type          = "other6xlinux-64"
  network_adapter_type   = "vmxnet3"
  vm_name                = "${var.vm_name}"
  communicator           = "ssh"
  ssh_username           = "packer"
  ssh_password           = "${local.packer_pwd}"
  ssh_disable_agent_forwarding = true
  output_directory       = "output\\vmware"
  boot_wait              = "9s"
  boot_command           = [
    "root<enter><wait>",
    "setup-interfaces -ar<enter><wait2>",
    "setup-ntp chrony<enter><wait8>",
    "setup-apkrepos -1c<enter><wait>",
    "setup-sshd openssh<enter><wait3>",
    "adduser packer<enter><wait>",
    "${local.packer_pwd}<enter><wait>",
    "${local.packer_pwd}<enter><wait>",
    "apk add --no-cache doas<enter><wait2>",
    "echo 'permit nopass packer' >> /etc/doas.d/paker.conf<enter><wait>"
  ]
}

build {
  sources = ["sources.hyperv-iso.vm"]
  #sources = ["sources.vmware-iso.vm"]

  provisioner "shell-local" {
    only    = ["hyperv-iso.vm"]
    command = "pwsh -nol -Command \"& {Set-VMNetworkAdapter -VMName ${var.vm_name} -DhcpGuard On -RouterGuard On}\""
  }

  # copy files to the image
  provisioner "file" {
    sources = [
      "conf",
      "scripts"
    ]
    destination = "/tmp/"
  }

  # set variables
  provisioner "shell" {
    inline = [
      "sed -i 's/__LUKS__/${var.luks_pwd}/g' /tmp/scripts/00_install.sh",
      "sed -i 's/__FORTI_DNS__/${var.forti_dns}/' /tmp/conf/openfortivpn.conf",
      "sed -i 's/__FORTI_USERNAME__/${var.forti_username}/' /tmp/conf/openfortivpn.conf",
      "sed -i 's/__FORTI_DNS__/${var.forti_dns}/' /tmp/conf/openconnect.conf",
      "sed -i 's/__FORTI_USERNAME__/${var.forti_username}/' /tmp/conf/openconnect.conf",
      "sed -i 's/__ROOT_PWD__/${var.root_pwd}/' /tmp/scripts/01_chroot.sh",
      "doas apk add grub",
      "p=$(echo -e \"${var.grub_pwd}\n${var.grub_pwd}\" | grub-mkpasswd-pbkdf2 | grep ^PBKDF2 | awk '{print $7}')",
      "sed -i \"s/__GRUB_PWD__/$p/g\" /tmp/conf/05_users",
      "chmod +x /tmp/scripts/*.sh"
    ]
  }

  # execute installation scripts
  provisioner "shell" {
    inline = [
      "doas /tmp/scripts/00_install.sh",
      "doas chroot /mnt /tmp/scripts/01_chroot.sh",
      "doas /tmp/scripts/20_secureboot.sh",
      "doas chroot /mnt /tmp/scripts/90_debug.sh",
      "doas /tmp/scripts/99_seal.sh"
    ]
  }

  provisioner "shell" {
    expect_disconnect = true
    pause_after = "4s"
    inline = [
      "doas eject",
      "doas reboot",
    ]
  }

  provisioner "shell-local" {
    only    = ["hyperv-iso.vm"]
    command = "pwsh -nol -ep bypass -File mokmok.ps1 -VMName ${var.vm_name}"
  }

  provisioner "shell-local" {
    only    = ["vmware.vm"]
    command = "pwsh -nol -ep bypass -File mokmok-vmware.ps1 -VMXPath ${var.vm_name}"
  }
}
