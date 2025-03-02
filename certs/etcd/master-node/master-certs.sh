# Generate a private key
openssl genrsa -out etcd-node2.key 2048

# Create temp file for config
cat > temp.cnf <<EOF
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_req
[ req_distinguished_name ]
[ v3_req ]
subjectAltName = @alt_names
[ alt_names ]
IP.1 = 192.168.2.16
IP.2 = 127.0.0.1
EOF

# Create a csr
openssl req -new -key etcd-node2.key -out etcd-node2.csr \
  -subj "/C=US/ST=YourState/L=YourCity/O=YourOrganization/OU=YourUnit/CN=etcd-node2" \
  -config temp.cnf

# Sign the cert
openssl x509 -req -in etcd-node2.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out etcd-node2.crt -days 7300 -sha256 -extensions v3_req -extfile temp.cnf

# Verify the cert and be sure you see Subject Name Alternative
openssl x509 -in etcd-node2.crt -text -noout | grep -A1 "Subject Alternative Name"

# Remove temp file
rm temp.cnf

# Create directory for storing
ssh masterdb "mkdir -p /etc/etcd/etcd-certs/"

# Copy files
scp ./etcd-node* ca.crt masterdb:/etc/etcd/etcd-certs/

ssh masterdb "chown etcd:etcd -R /etc/etcd/"
