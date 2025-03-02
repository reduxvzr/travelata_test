openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -subj "/CN=etcd-ca" -days 7300 -out ca.crt

for dir in ../etcd-node ../master-node ../slave-node; do
    cp -v {ca.crt,ca.key} "$dir"
done
