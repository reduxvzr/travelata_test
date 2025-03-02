ssh masterdb "sudo sh -c 'cat /var/lib/postgresql/15/ssl/cluster.crt /var/lib/postgresql/15/ssl/cluster.key > /var/lib/postgresql/15/ssl/cluster.pem'"
ssh masterdb "sudo chown postgres:postgres /var/lib/postgresql/15/ssl/cluster.pem"
ssh masterdb "sudo chmod 600 /var/lib/postgresql/15/ssl/cluster.pem"

