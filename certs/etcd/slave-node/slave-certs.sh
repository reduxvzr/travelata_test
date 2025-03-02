# Generate a private key
openssl genrsa -out etcd-node3.key 2048

# Create temp file for config
cat > temp.cnf <<EOF
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
[ req_distinguished_name ]
[ v3_req ]
subjectAltName = @alt_names
[ alt_names ]
IP.1 = 192.168.2.17
IP.2 = 127.0.0.1
EOF

# Create a csr
openssl req -new -key etcd-node3.key -out etcd-node3.csr \
  -subj "/C=US/ST=YourState/L=YourCity/O=YourOrganization/OU=YourUnit/CN=etcd-node3" \
  -config temp.cnf

#Sign the cert
openssl x509 -req -in etcd-node3.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out etcd-node3.crt -days 7300 -sha256 -extensions v3_req -extfile temp.cnf

# Verify the cert and be sure you see Subject Name Alternative
openssl x509 -in etcd-node3.crt -text -noout | grep -A1 "Subject Alternative Name"

# Remove temp file
rm temp.cnf
# Create directory for storing
ssh slavedb "mkdir -p /etc/etcd/etcd-certs/"

# Copy files
scp ./etcd-node* ca.crt slavedb:/etc/etcd/etcd-certs/

ssh slavedb "chown etcd:etcd -R /etc/etcd/"

ssh slavedb "usermod -aG etcd postgres"

ssh slavedb "chmod 640 /etc/etcd/etcd-certs/*.key"
ssh slavedb "ls -l /etc/etcd/etcd-certs/*.key"
