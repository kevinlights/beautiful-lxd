set -eu

mkdir -p /data/haproxy
cat > /data/haproxy/haproxy.cfg << 'EOF'
global
    maxconn 100

defaults
    log global
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /

listen postgres
    bind *:5000
    option httpchk
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server postgres1 10.0.0.219:5432 maxconn 100 check port 8008
    server postgres2 10.0.0.180:5432 maxconn 100 check port 8008
    server postgres3 10.0.0.55:5432 maxconn 100 check port 8008
EOF

docker rm -f haproxy || true
docker run -d \
  --name haproxy \
  --network host \
  --restart unless-stopped \
  -v /data/haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro \
  haproxy:latest

mkdir -p /data/patroni
cat > /data/patroni/patroni.yml << 'EOF'
scope: postgres
namespace: /db/
name: postgresql1

restapi:
  listen: 10.0.0.219:8008
  connect_address: 10.0.0.219:8008

etcd:
  hosts:
    - 10.0.0.219:2379
    - 10.0.0.180:2379
    - 10.0.0.55:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        listen_addresses: "0.0.0.0"
        max_connections: 100
  initdb:
  - encoding: UTF8
  - data-checksums
  pg_hba:
  - host replication replicator 0.0.0.0/0 md5
  - host all all 0.0.0.0/0 md5
  users:
    admin:
      password: admin
      options:
        - createrole
        - createdb

postgresql:
  listen: 10.0.0.219:5432
  connect_address: 10.0.0.219:5432
  data_dir: /data/postgresql
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    replication:
      username: replicator
      password: "repl-pass"
    superuser:
      username: postgres
      password: "super-pass"

tags:
    nofailover: false
    noloadbalance: false
    clonefrom: false
    nosync: false
EOF

mkdir -p /data/postgresql
# docker run --rm ghcr.io/zalando/spilo-16:3.3-p1 id postgres
# uid=101(postgres) gid=103(postgres) groups=103(postgres),0(root),102(ssl-cert)
chown -R 101:103 /data/patroni /data/postgresql
chmod -R 700 /data/postgresql
chmod -R 755 /data/patroni


docker rm -f patroni || true
docker run -d \
  --name patroni \
  --network host \
  --restart unless-stopped \
  -u postgres \
  -e ETCD_DISABLE=true \
  -e ETCDCTL_ENDPOINTS="http://10.0.0.219:2379,http://10.0.0.180:2379,http://10.0.0.55:2379" \
  -e SCOPE="postgres" \
  -e PGDATA="/data/postgresql" \
  -e PATRONI_ETCD_HOSTS="10.0.0.219:2379,10.0.0.180:2379,10.0.0.55:2379" \
  -v /data/patroni:/etc/patroni:ro \
  -v /data/postgresql:/data/postgresql \
  ghcr.io/zalando/spilo-16:3.3-p1 patroni /etc/patroni/patroni.yml