set -eu

# Patroni + etcd + HAProxy

# vm1: 10.0.0.219
# vm2: 10.0.0.180
# vm3: 10.0.0.55

# run pg container in vm1, vm2, vm3 in cluster mode
# scp ./lxd/setup-etcd.bash kevin@192.168.64.3:/tmp/setup-etcd.bash
lxc file push /tmp/setup-etcd.bash vm1/root/setup-etcd.bash
lxc file push /tmp/setup-etcd.bash vm2/root/setup-etcd.bash
lxc file push /tmp/setup-etcd.bash vm3/root/setup-etcd.bash

lxc exec vm1 -- bash -c 'ETCD_NAME="etcd1" bash /root/setup-etcd.bash'
lxc exec vm2 -- bash -c 'ETCD_NAME="etcd2" bash /root/setup-etcd.bash'
lxc exec vm3 -- bash -c 'ETCD_NAME="etcd3" bash /root/setup-etcd.bash'

# verify etcd cluster
lxc exec vm1 -- docker logs etcd
lxc exec vm1 -- docker exec -it etcd etcdctl member list
# 428ff43802ce16fe, started, etcd2, http://10.0.0.180:2380, http://10.0.0.180:2379, false
# 7eac14e4d397fb5f, started, etcd3, http://10.0.0.55:2380, http://10.0.0.55:2379, false
# f01c6ee6d90e90c0, started, etcd1, http://10.0.0.219:2380, http://10.0.0.219:2379, false
lxc exec vm1 -- docker exec -it etcd etcdctl endpoint health --cluster
# http://10.0.0.219:2379 is healthy: successfully committed proposal: took = 1.232794ms
# http://10.0.0.55:2379 is healthy: successfully committed proposal: took = 1.20496ms
# http://10.0.0.180:2379 is healthy: successfully committed proposal: took = 1.59646ms

# run vm1 script to setup haproxy + patroni
# scp ./lxd/setup-haproxy-patroni.bash kevin@192.168.64.3:/tmp/setup-haproxy-patroni.bash
# scp ./lxd/setup-patroni-vm2.bash kevin@192.168.64.3:/tmp/setup-patroni-vm2.bash
# scp ./lxd/setup-patroni-vm3.bash kevin@192.168.64.3:/tmp/setup-patroni-vm3.bash
lxc file push /tmp/setup-haproxy-patroni.bash vm1/root/setup-haproxy-patroni.bash
lxc file push /tmp/setup-patroni-vm2.bash vm2/root/setup-patroni-vm2.bash
lxc file push /tmp/setup-patroni-vm3.bash vm3/root/setup-patroni-vm3.bash

lxc exec vm1 -- bash /root/setup-haproxy-patroni.bash
lxc exec vm2 -- bash /root/setup-patroni-vm2.bash
lxc exec vm3 -- bash /root/setup-patroni-vm3.bash

lxc exec vm1 -- docker logs haproxy
lxc exec vm1 -- docker logs patroni

# run vm2 script to setup patroni
lxc exec vm2 -- docker logs patroni

# run vm3 script to setup patroni
lxc exec vm3 -- docker logs patroni


# verify patroni cluster
lxc exec vm1 -- docker exec -it patroni patronictl -c /etc/patroni/patroni.yml list
# + Cluster: postgres (7641951170765574165) -------+----+-----------+
# | Member      | Host       | Role    | State     | TL | Lag in MB |
# +-------------+------------+---------+-----------+----+-----------+
# | postgresql1 | 10.0.0.219 | Leader  | running   |  2 |           |
# | postgresql2 | 10.0.0.180 | Replica | running   |  1 |        28 |
# | postgresql3 | 10.0.0.55  | Replica | streaming |  2 |         0 |
# +-------------+------------+---------+-----------+----+-----------+


# docker exec -it patroni patronictl -c /etc/patroni/patroni.yml list
# docker exec -it patroni patronictl -c /etc/patroni/patroni.yml show-config postgres
# loop_wait: 10
# maximum_lag_on_failover: 1048576
# postgresql:
#   parameters:
#     listen_addresses: 0.0.0.0
#     max_connections: 100
#   use_pg_rewind: true
# retry_timeout: 10
# ttl: 30
# # manually switchover to test HAProxy health check
# docker exec -it patroni patronictl -c /etc/patroni/patroni.yml switchover postgres

# Current cluster topology
# + Cluster: postgres (7641951170765574165) -------+----+-----------+
# | Member      | Host       | Role    | State     | TL | Lag in MB |
# +-------------+------------+---------+-----------+----+-----------+
# | postgresql1 | 10.0.0.219 | Leader  | running   |  2 |           |
# | postgresql2 | 10.0.0.180 | Replica | running   |  1 |        28 |
# | postgresql3 | 10.0.0.55  | Replica | streaming |  2 |         0 |
# +-------------+------------+---------+-----------+----+-----------+
# Primary [postgresql1]: 
# Candidate ['postgresql2', 'postgresql3'] []: postgresql2
# When should the switchover take place (e.g. 2026-05-20T14:16 )  [now]: 
# Are you sure you want to switchover cluster postgres, demoting current leader postgresql1? [y/N]: y
# Switchover failed, details: 503, Switchover failed

# docker exec -it patroni patronictl -c /etc/patroni/patroni.yml switchover postgres
# Current cluster topology
# + Cluster: postgres (7641951170765574165) -------+----+-----------+
# | Member      | Host       | Role    | State     | TL | Lag in MB |
# +-------------+------------+---------+-----------+----+-----------+
# | postgresql1 | 10.0.0.219 | Leader  | running   |  2 |           |
# | postgresql2 | 10.0.0.180 | Replica | running   |  1 |        28 |
# | postgresql3 | 10.0.0.55  | Replica | streaming |  2 |         0 |
# +-------------+------------+---------+-----------+----+-----------+
# Primary [postgresql1]: 
# Candidate ['postgresql2', 'postgresql3'] []: postgresql3
# When should the switchover take place (e.g. 2026-05-20T14:18 )  [now]: 
# Are you sure you want to switchover cluster postgres, demoting current leader postgresql1? [y/N]: y
# 2026-05-20 13:18:22.71621 Successfully switched over to "postgresql3"
# + Cluster: postgres (7641951170765574165) -----+----+-----------+
# | Member      | Host       | Role    | State   | TL | Lag in MB |
# +-------------+------------+---------+---------+----+-----------+
# | postgresql1 | 10.0.0.219 | Replica | stopped |    |   unknown |
# | postgresql2 | 10.0.0.180 | Replica | running |  1 |        28 |
# | postgresql3 | 10.0.0.55  | Leader  | running |  2 |           |
# +-------------+------------+---------+---------+----+-----------+

# docker exec -it patroni bash

# run in leader node
# docker exec -it patroni psql -U postgres -c "SELECT usename, application_name, state, sync_state, replay_lag, flush_lag FROM pg_stat_replication;"

# docker exec -it patroni patronictl version

lxc exec vm2 -- docker logs patroni
lxc exec vm2 -- bash
# rm -rf /data/postgresql
# rm -rf /data/postgresql.failed

# root@vm1:~# docker exec -it patroni patronictl -c /etc/patroni/patroni.yml list
# + Cluster: postgres (7641951170765574165) -------+----+-----------+
# | Member      | Host       | Role    | State     | TL | Lag in MB |
# +-------------+------------+---------+-----------+----+-----------+
# | postgresql1 | 10.0.0.219 | Leader  | running   |  4 |           |
# | postgresql2 | 10.0.0.180 | Replica | streaming |  4 |         0 |
# | postgresql3 | 10.0.0.55  | Replica | streaming |  4 |         0 |
# +-------------+------------+---------+-----------+----+-----------+

# docker exec patroni psql -U postgres -c "SELECT pg_current_wal_lsn();"
# docker exec patroni ls -la /data/postgresql/pg_wal/ | tail -20

# docker exec patroni psql -U postgres -c "SELECT * FROM pg_stat_replication;"
# docker exec patroni psql -U postgres -c "SELECT * FROM pg_stat_wal_receiver;"
# docker exec patroni psql -U postgres -c "SELECT * FROM pg_stat_database;"


sudo lxc config device add vm1 haproxy-proxy proxy \
  listen=tcp:0.0.0.0:7000 \
  connect=tcp:10.0.0.219:7000

# sudo lxc config device add vm1 postgres-primary-proxy proxy \
#   listen=tcp:0.0.0.0:5000 \
#   connect=tcp:10.0.0.219:5000

# sudo lxc config device add vm1 postgres-replica-proxy proxy \
#   listen=tcp:0.0.0.0:5001 \
#   connect=tcp:10.0.0.219:5001

lxc config device list vm1
# haproxy-proxy
