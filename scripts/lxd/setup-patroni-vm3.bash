set -eu

mkdir -p /data/patroni
cat > /data/patroni/patroni.yml << 'EOF'
scope: postgres
namespace: /db/
name: postgresql3

restapi:
  listen: 10.0.0.55:8008
  connect_address: 10.0.0.55:8008

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
  listen: 10.0.0.55:5432
  connect_address: 10.0.0.55:5432
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

docker rm -f patroni || true
docker run -d \
  --name patroni \
  --network host \
  --restart unless-stopped \
  -v /data/patroni:/etc/patroni:ro \
  -v /data/postgresql:/data/postgresql \
  swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/zalando/spilo-16:3.3-p1