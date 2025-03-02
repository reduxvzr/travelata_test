ssh slavedb "echo \"alias etcdctl='etcdctl --cacert=/etc/etcd/etcd-certs/ca.crt --key=/etc/etcd/etcd-certs/etcd-node3.key --cert=/etc/etcd/etcd-certs/etcd-node3.crt'\" >> /root/.bashrc"
ssh slavedb "source /root/.bashrc"
