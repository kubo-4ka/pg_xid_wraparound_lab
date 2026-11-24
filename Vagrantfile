# PostgreSQL XID wraparound 実験環境 (AlmaLinux 9 + PostgreSQL 18)
Vagrant.configure("2") do |config|
  config.vm.box = "almalinux/9"
  config.vm.box_version = "9.7.20260518"
  config.vm.hostname = "pgxidlab"
  config.vm.boot_timeout = 600
  config.vm.synced_folder ".", "/vagrant", type: "virtualbox"
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end
  config.vm.provider "virtualbox" do |vb|
    vb.name   = "pg_xid_wraparound_lab"
    vb.cpus   = 4
    vb.memory = 4096
    vb.customize ["modifyvm", :id, "--vrde", "off"]
    vb.customize ["modifyvm", :id, "--audio-driver", "none"]
    vb.customize ["modifyvm", :id, "--uartmode1", "disconnected"]
    lab_vdi = File.join(__dir__, "disks", "lab.vdi")
    unless File.exist?(lab_vdi)
      vb.customize ["createmedium", "disk", "--filename", lab_vdi, "--format", "VDI", "--size", 60 * 1024]
    end
    vb.customize ["storageattach", :id, "--storagectl", "SATA Controller", "--port", 1, "--device", 0, "--type", "hdd", "--medium", lab_vdi]
  end
  config.vm.provision "shell", path: "scripts/provision.sh"
end
