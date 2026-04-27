# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Windsurf VM — Lightweight IDE workspace
# Managed by vm.ps1 | vm.bat
#

VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|

  # ─── Instance Identity + Resources (set by vm.ps1 via env vars) ──────────────
  instance_name = ENV["VM_INSTANCE_NAME"] || "default"
  rdp_port      = (ENV["VM_RDP_PORT"]     || "3390").to_i
  project_path  = ENV["VM_PROJECT_PATH"]  || Dir.home + "/Desktop/my-project"
  vm_ram        = (ENV["VM_RAM"]          || "6144").to_i
  vm_cpus       = (ENV["VM_CPUS"]         || "4").to_i
  vm_disk_gb    = (ENV["VM_DISK_GB"]      || "40").to_i

  # ─── Base Box ───────────────────────────────────────────────────────────────
  # vm.ps1 auto-selects: windsurf-base (if built, fast) or ubuntu/jammy64 (fresh)
  # To build windsurf-base: see README.md > Building the Base Box
  config.vm.box = ENV["VM_BOX"] || "ubuntu/jammy64"
  config.vm.box_check_update = false

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

  # Host-only network for SSH bridge (VM ↔ Host private link)
  # Only activated when vm.ps1 passes VM_HOST_ONLY_IP (bridge configured).
  host_only_ip = ENV["VM_HOST_ONLY_IP"].to_s
  unless host_only_ip.empty?
    config.vm.network "private_network", ip: host_only_ip
  end

  # ─── Shared Folders ─────────────────────────────────────────────────────────
  # Multi-project support: vm.ps1 passes a JSON array via VM_PROJECTS listing
  # all projects to mount. Each entry has `name` and `host_path` — mounted at
  # /projects/<name> inside the guest.
  #
  # Empty/missing VM_PROJECTS = legacy single-mount mode: mount the single
  # host path from VM_PROJECT_PATH at /project (backward-compat for VMs
  # created before the multi-project feature).
  require "json"
  projects_env = ENV["VM_PROJECTS"].to_s
  projects     = []
  begin
    parsed = JSON.parse(projects_env) unless projects_env.empty?
    projects = parsed if parsed.is_a?(Array)
  rescue JSON::ParserError
    # Fall through to legacy mode with a warning at `vagrant up` time.
    warn "[Vagrantfile] VM_PROJECTS is not valid JSON, falling back to legacy /project mount"
  end

  # Skip shared folders entirely when bridge is active and no projects specified
  # (Windsurf accesses host filesystem directly via Remote-SSH).
  bridge_active = !host_only_ip.empty?

  if projects.empty? && !bridge_active
    config.vm.synced_folder project_path, "/project",
      type: "virtualbox",
      owner: "vagrant",
      group: "vagrant",
      mount_options: ["dmode=775", "fmode=664"]
  elsif !projects.empty?
    projects.each do |p|
      next unless p.is_a?(Hash) && p["name"] && p["host_path"]
      config.vm.synced_folder p["host_path"], "/projects/#{p['name']}",
        type: "virtualbox",
        owner: "vagrant",
        group: "vagrant",
        mount_options: ["dmode=775", "fmode=664"]
    end
  end

  # Disable default /vagrant share
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # ─── VirtualBox Provider ────────────────────────────────────────────────────
  config.vm.provider "virtualbox" do |vb|
    vb.name   = "windsurf-#{instance_name}"
    vb.memory = vm_ram
    vb.cpus   = vm_cpus

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

    # ─── Network optimizations ────────────────────────────────────────────────
    # natdnshostresolver1: use host's DNS resolver (faster, more reliable than
    # the default NAT DNS proxy). Do NOT combine with --natdnsproxy1.
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    # virtio NIC has higher throughput than emulated e1000 for Linux guests
    vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
  end

  # ─── Disk size (resizable primary disk) ─────────────────────────────────────
  # Vagrant 2.4+ native support. Requires growpart + resize2fs in provision.sh
  # to actually grow the guest filesystem after the VDI is resized.
  #
  # IMPORTANT: only applied for `ubuntu/jammy64` (VDI format, resizable).
  # Packaged boxes from `vagrant package` use VMDK monolithic format which
  # VirtualBox cannot resize ("Resize medium operation for this format is not
  # implemented yet") — attempting it would break `vm new` on windsurf-base.
  # To increase disk size of VMs built from windsurf-base, rebuild the base
  # box after bumping $VmDiskGB.
  if config.vm.box == "ubuntu/jammy64"
    config.vm.disk :disk, size: "#{vm_disk_gb}GB", primary: true
  end

  # ─── Provisioning ───────────────────────────────────────────────────────────
  # Ship vm-requirements.txt into the guest BEFORE provision.sh runs so the
  # shell script can `pip install -r /tmp/vm-requirements.txt` (single source
  # of truth for Python deps — no hardcoded package list in provision.sh).
  config.vm.provision "file",
    source:      "vm-requirements.txt",
    destination: "/tmp/vm-requirements.txt"

  config.vm.provision "shell",
    path:       "provision.sh",
    privileged: true,
    env: {
      "VAGRANT_USER"  => "vagrant",
      "VM_HOST_IP"    => ENV["VM_HOST_IP"].to_s,
      "VM_HOST_USER"  => ENV["VM_HOST_USER"].to_s,
      "VM_BRIDGE_KEY" => ENV["VM_BRIDGE_KEY"].to_s,
      "VM_HOST_KEY"   => ENV["VM_HOST_KEY"].to_s,
      "VM_PROJECTS"   => ENV["VM_PROJECTS"].to_s
    }

end
