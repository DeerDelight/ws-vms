# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Windsurf VM — Lightweight IDE workspace
# Managed by vm.ps1 | vm.bat
#

VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

  # ─── Base Box ───────────────────────────────────────────────────────────────
  # Pre-provisioned box: Ubuntu 22.04 + XFCE + xrdp + Python 3.13 + Windsurf
  # Build: vagrant package --output windsurf-base.box && vagrant box add windsurf-base windsurf-base.box
  config.vm.box = "windsurf-base"
  config.vm.box_check_update = false

  # ─── Instance Identity (set by vm.ps1 via env vars) ─────────────────────────
  instance_name = ENV["VM_INSTANCE_NAME"] || "default"
  rdp_port      = (ENV["VM_RDP_PORT"]     || "3390").to_i
  project_path  = ENV["VM_PROJECT_PATH"]  || "C:/Users/email/Desktop/mkt_tools"

  config.vm.hostname = "windsurf-#{instance_name}"

  # ─── Network ────────────────────────────────────────────────────────────────
  # RDP access from host
  config.vm.network "forwarded_port",
    guest: 3389,
    host:  rdp_port,
    id:    "rdp",
    auto_correct: true

  # Disable default SSH port forwarding conflict check
  config.vm.network "forwarded_port", guest: 22, host: 2222, id: "ssh", auto_correct: true

  # ─── Shared Folders ─────────────────────────────────────────────────────────
  # Project folder via VirtualBox shared folder (no credentials needed)
  # Note: requires VirtualBox Guest Additions in the box (ubuntu/jammy64 includes them)
  config.vm.synced_folder project_path, "/project",
    type: "virtualbox",
    owner: "vagrant",
    group: "vagrant",
    mount_options: ["dmode=775", "fmode=664"]

  # Disable default /vagrant share
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # ─── VirtualBox Provider ────────────────────────────────────────────────────
  config.vm.provider "virtualbox" do |vb|
    vb.name   = "windsurf-#{instance_name}"
    vb.memory = 6144   # 6 GB — comfortable for Windsurf dev on 16GB host
    vb.cpus   = 4

    vb.gui = false     # Headless — access via RDP

    # Display
    vb.customize ["modifyvm", :id, "--vram",         "128"]
    vb.customize ["modifyvm", :id, "--accelerate3d", "off"]

    # Quality of life
    vb.customize ["modifyvm", :id, "--clipboard",  "bidirectional"]
    vb.customize ["modifyvm", :id, "--draganddrop","bidirectional"]

    # Disable unused hardware (faster boot)
    vb.customize ["modifyvm", :id, "--audio", "none"]
    vb.customize ["modifyvm", :id, "--usb",   "off"]

    # CPU execution cap (don't starve the host)
    vb.customize ["modifyvm", :id, "--cpuexecutioncap", "80"]

    # Paravirtualization: KVM gives best perf on Linux guests
    vb.customize ["modifyvm", :id, "--paravirtprovider", "kvm"]
  end

  # ─── Provisioning ───────────────────────────────────────────────────────────
  config.vm.provision "shell",
    path:       "provision.sh",
    privileged: true,
    env: {
      "VAGRANT_USER" => "vagrant"
    }

end
