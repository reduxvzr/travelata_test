sudo qm create 100 \
  --autostart 1 \
  --bios ovmf \
  --name haproxydeb \
  --cpu host \
  --cores 2 \
  --memory 1024 \
  --ide2 Hard1:iso/debian-12.9.0-amd64-netinst.iso,media=cdrom \
  --net0 bridge=vmbr0,model=virtio \
  --machine q35 \
  --scsihw virtio-scsi-single \
  --scsi0 Hard1:15

&& sudo qm clone 100 101 --name "dbmaster" --full
&& sudo qm clone 101 102 --name "dbslave" --full
&& sudo qm clone 101 111 --name "etcd" --full
&& sudo qm config 100