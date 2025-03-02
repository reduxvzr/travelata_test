# Generate a private key
openssl genrsa -out etcd-node1.key 2048

# Create temp file for config
cat > temp.cnf <<EOF
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
[ req_distinguished_name ]
[ v3_req ]
subjectAltName = @alt_names
[ alt_names ]
IP.1 = 192.168.2.18
IP.2 = 127.0.0.1
EOF

# Create a csr
openssl req -new -key etcd-node1.key -out etcd-node1.csr \
  -subj "/C=US/ST=YourState/L=YourCity/O=YourOrganization/OU=YourUnit/CN=etcd-node1" \
  -config temp.cnf

#Sign the cert
openssl x509 -req -in etcd-node1.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out etcd-node1.crt -days 7300 -sha256 -extensions v3_req -extfile temp.cnf

# Verify the cert and be sure you see Subject Name Alternative
openssl x509 -in etcd-node1.crt -text -noout | grep -A1 "Subject Alternative Name"

# Remove temp file
rm temp.cnf
# Create directory for storing
ssh etcd "mkdir -p /etc/etcd/etcd-certs/"

# Copy files
scp ./etcd-node* ca.crt etcd:/etc/etcd/etcd-certs/

ssh etcd "chown etcd:etcd -R /etc/etcd/"

ssh etcd "chmod 640 /etc/etcd/etcd-certs/*.key"
ssh etcd "ls -l /etc/etcd/etcd-certs/*.key"
