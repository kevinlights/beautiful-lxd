
mkdir -p /data/etcd

# export ETCD_NAME="etcd1"
# export ETCD_NAME="etcd2"
# export ETCD_NAME="etcd3"
VM_IP=$(hostname -I | awk '{print $2}')
echo ETCD_NAME=${ETCD_NAME}, VM_IP=${VM_IP}
# confirm before run etcd container
read -p "Are you sure to run etcd container with name ${ETCD_NAME}? (y/n) " -n 1 -r
echo    # move to a new line
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborting..."
    exit 1
fi

export INITIAL_CLUSTER="etcd1=http://10.0.0.219:2380,etcd2=http://10.0.0.180:2380,etcd3=http://10.0.0.55:2380"

docker rm -f etcd || true
docker run -d \
  --name etcd \
  --network host \
  --restart unless-stopped \
  -v /data/etcd:/etcd-data \
  -e ETCD_NAME=${ETCD_NAME} \
  -e ETCD_DATA_DIR=/etcd-data \
  -e ETCD_INITIAL_ADVERTISE_PEER_URLS=http://${VM_IP}:2380 \
  -e ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380 \
  -e ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379 \
  -e ETCD_ADVERTISE_CLIENT_URLS=http://${VM_IP}:2379 \
  -e ETCD_INITIAL_CLUSTER=${INITIAL_CLUSTER} \
  -e ETCD_INITIAL_CLUSTER_TOKEN="postgres-ha-cluster" \
  -e ETCD_INITIAL_CLUSTER_STATE="new" \
  quay.io/coreos/etcd:v3.5.12
