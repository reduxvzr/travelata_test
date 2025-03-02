ssh etcd "echo \"alias etcdctl='etcdctl --cacert=/etc/etcd/etcd-certs/ca.crt --key=/etc/etcd/etcd-certs/etcd-node1.key --cert=/etc/etcd/etcd-certs/etcd-node1.crt'\" >> /root/.bashrc"
ssh etcd "source /root/.bashrc"
