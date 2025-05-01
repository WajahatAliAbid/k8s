#!/bin/bash
set -euo pipefail

_cluster=${1:-"p1"}
_port=${2:-"7000"}
_environment=${3:-"development"}

# 1. Create registry container unless it already exists
_registry_name="$_cluster-registry"
_registry_port=$_port

_registry_directory="/etc/containerd/certs.d/localhost:${_registry_port}"

# 1. Create registry container unless it already exists
if [ "$(docker inspect -f '{{.State.Running}}' "${_registry_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=always -p "127.0.0.1:${_registry_port}:5000" --name "${_registry_name}" \
    registry:2
fi

# 2. Create kind cluster with containerd registry config dir enabled
# See:
# https://github.com/kubernetes-sigs/kind/issues/2875
# https://github.com/containerd/containerd/blob/main/docs/cri/config.md#registry-configuration
# See: https://github.com/containerd/containerd/blob/main/docs/hosts.md

cat <<EOF | kind create cluster --name $_cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
- role: worker
- role: worker
- role: worker
networking:
  disableDefaultCNI: true
  podSubnet: 10.96.0.0/24
EOF

# 3. Add the registry config to the nodes
#
# This is necessary because localhost resolves to loopback addresses that are
# network-namespace local.
# In other words: localhost in the container is not localhost on the host.
#
# We want a consistent name that works from both ends, so we tell containerd to
# alias localhost:${reg_port} to the registry container when pulling images

kubectl ctx "kind-$_cluster"

echo "Adding the registry config to the nodes of $_cluster"
for node in $(kind get nodes --name $_cluster); 
do
    docker exec "${node}" mkdir -p "${_registry_directory}"
    cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${_registry_directory}/hosts.toml"
[host."http://${_registry_name}:5000"]
EOF
done
# 4. Connect the registry to the cluster network if not already connected
# This allows kind to bootstrap the network but ensures they're on the same network
echo "Connect the registry to the cluster network if not already connected"
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${_registry_name}")" = 'null' ]; 
then
    docker network connect kind "${_registry_name}"
fi

# 5. Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${_registry_port}"
    hostFromContainerRuntime: "registry:${_registry_port}"
    hostFromClusterNetwork: "${_registry_name}:${_registry_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $_environment
  labels:
    env: $_environment
EOF
echo "Namespace $_environment created"

echo "Installing Calico"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml