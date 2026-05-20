set -eu

# 以下是当前 ssh 连接到的系统信息
PRETTY_NAME="Ubuntu 26.04 LTS"
NAME="Ubuntu"
VERSION_ID="26.04"
VERSION="26.04 (Resolute Raccoon)"
VERSION_CODENAME=resolute
Linux ubuntu26 7.0.0-15-generic #15-Ubuntu SMP PREEMPT_DYNAMIC Wed Apr 22 15:54:12 UTC 2026 aarch64 GNU/Linux

# 安装了 lxc, lxd 6.7

lxd init
# Would you like to use LXD clustering? (yes/no) [default=no]: 
# Do you want to configure a new storage pool? (yes/no) [default=yes]: 
# Name of the new storage pool [default=default]: dir
# Name of the storage backend to use (dir, pure, zfs, lvm, powerflex, alletra, btrfs, ceph) [default=zfs]: dir
# Would you like to connect to a MAAS server? (yes/no) [default=no]: 
# Would you like to create a new local network bridge? (yes/no) [default=yes]: yes
# What should the new bridge be called? [default=lxdbr0]: 
# What IPv4 address should be used? (CIDR subnet notation, “auto” or “none”) [default=auto]: 10.0.0.1/24
# Would you like LXD to NAT IPv4 traffic on your bridge? [default=yes]:     
# What IPv6 address should be used? (CIDR subnet notation, “auto” or “none”) [default=auto]: 
# Would you like the LXD server to be available over the network? (yes/no) [default=no]: 
# Would you like stale cached images to be updated automatically? (yes/no) [default=yes]: no
# Would you like a YAML "lxd init" preseed to be printed? (yes/no) [default=no]:

# 在 lxc 中创建 vm1, vm2, vm3, 使用 ubuntu:22.04 镜像
lxc launch ubuntu:22.04 vm1
lxc launch ubuntu:22.04 vm2
lxc launch ubuntu:22.04 vm3

lxc list
# +------+---------+-------------------+-----------------------------------------------+-----------+-----------+
# | NAME |  STATE  |       IPV4        |                     IPV6                      |   TYPE    | SNAPSHOTS |
# +------+---------+-------------------+-----------------------------------------------+-----------+-----------+
# | vm1  | RUNNING | 10.0.0.219 (eth0) | fd42:b78e:c85b:5921:216:3eff:feb5:4943 (eth0) | CONTAINER | 0         |
# +------+---------+-------------------+-----------------------------------------------+-----------+-----------+
# | vm2  | RUNNING | 10.0.0.180 (eth0) | fd42:b78e:c85b:5921:216:3eff:fe57:c682 (eth0) | CONTAINER | 0         |
# +------+---------+-------------------+-----------------------------------------------+-----------+-----------+
# | vm3  | RUNNING | 10.0.0.55 (eth0)  | fd42:b78e:c85b:5921:216:3eff:fea5:9021 (eth0) | CONTAINER | 0         |
# +------+---------+-------------------+-----------------------------------------------+-----------+-----------+


# check network
lxc exec vm1 -- ping -c 3 8.8.8.8
lxc exec vm2 -- ping -c 3 8.8.8.8
lxc exec vm3 -- ping -c 3 8.8.8.8

# check connectivity between vms
lxc exec vm1 -- ping -c 3 10.0.0.180 # ping vm2
lxc exec vm1 -- ping -c 3 10.0.0.55 # ping vm3
lxc exec vm2 -- ping -c 3 10.0.0.55 # ping vm3
lxc exec vm3 -- ping -c 3 10.0.0.180 # ping vm2
lxc exec vm3 -- ping -c 3 10.0.0.219 # ping vm1
lxc exec vm2 -- ping -c 3 10.0.0.219 # ping vm1

# install docker engine in vm1, vm2, vm3
# copy lxd/install-docker.bash to vm1, vm2, vm3
# scp ./lxd/install-docker.bash kevin@192.168.64.3:/tmp/install-docker.bash
lxc file push /tmp/install-docker.bash vm1/root/install-docker.bash
lxc file push /tmp/install-docker.bash vm2/root/install-docker.bash
lxc file push /tmp/install-docker.bash vm3/root/install-docker.bash

lxc exec vm1 -- bash /root/install-docker.bash
lxc exec vm2 -- bash /root/install-docker.bash
lxc exec vm3 -- bash /root/install-docker.bash

lxc stop vm1
lxc config set vm1 security.nesting true
lxc start vm1

lxc stop vm2
lxc config set vm2 security.nesting true
lxc start vm2

lxc stop vm3
lxc config set vm3 security.nesting true
lxc start vm3

lxc exec vm1 -- docker run --rm hello-world
lxc exec vm2 -- docker run --rm hello-world
lxc exec vm3 -- docker run --rm hello-world

# check network in docker container
lxc exec vm1 -- docker run --rm busybox ping -c 3 8.8.8.8
lxc exec vm2 -- docker run --rm busybox ping -c 3 8.8.8.8
lxc exec vm3 -- docker run --rm busybox ping -c 3 8.8.8.8

lxc exec vm1 -- docker run --rm busybox ping -c 3 10.0.0.180
lxc exec vm2 -- docker run --rm busybox ping -c 3 10.0.0.55
lxc exec vm3 -- docker run --rm busybox ping -c 3 10.0.0.219

lxc exec vm1 -- ip route
lxc exec vm1 -- docker run --rm busybox ip route


