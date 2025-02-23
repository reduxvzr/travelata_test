# paths where key and certificate locate: 
# mkdir -p /var/lib/postgresql/15/data
# mkdir -p /var/lib/postgresql/15/ssl

# generate keys for tls-connection - patroni

# private key
openssl genrsa -out cluster.key 2048 
# certificate request
openssl req -new -key cluster.key -out cluster.req
# create certificate for 5 years 
openssl req -x509 -key cluster.key -in cluster.req -out cluster.crt -days 3650