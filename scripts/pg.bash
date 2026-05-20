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
