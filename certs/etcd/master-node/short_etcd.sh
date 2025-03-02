ssh masterdb "echo \"alias etcdctl='etcdctl --cacert=/etc/etcd/etcd-certs/ca.crt --key=/etc/etcd/etcd-certs/etcd-node2.key --cert=/etc/etcd/etcd-certs/etcd-node2.crt'\" >> /root/.bashrc"
ssh masterdb "source /root/.bashrc"
