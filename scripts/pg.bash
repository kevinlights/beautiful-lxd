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


# docker exec -it patroni patronictl list postgres
# docker exec -it patroni patronictl show-config
# # manually switchover to test HAProxy health check
# docker exec -it patroni patronictl switchover postgres
# docker exec -it patroni bash
# docker exec -it patroni tail -f /data/postgresql/log/postgresql.log