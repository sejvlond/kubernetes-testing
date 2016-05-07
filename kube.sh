#!/bin/bash

set -e

# Make sure k8s version env is properly set
K8S_VERSION=${K8S_VERSION:-"1.2.3"}
ETCD_VERSION=${ETCD_VERSION:-"2.2.1"}
FLANNEL_VERSION=${FLANNEL_VERSION:-"0.5.5"}
FLANNEL_IPMASQ=${FLANNEL_IPMASQ:-"true"}
FLANNEL_IFACE=${FLANNEL_IFACE:-"eth0"}
ARCH=${ARCH:-"amd64"}

NAME="k8s.$1"
# Make sure master ip is properly set
if [ -z ${MASTER_IP} ]; then
    echo "MASTER_IP is not set; Possibly use: hostname -I | awk '{print \$1}'"
    exit 1
fi

ETCD_SERVERS="http://${MASTER_IP}:4001"
SERVICERANGE="172.18.0.0/24"

API_SERVERS="http://${MASTER_IP}:8080"

BOOTSTRAP_SOCKET="unix:///var/run/docker-bootstrap.sock"

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

remove_container () {
    if docker ps -a | grep "$NAME" > /dev/null; then
        docker stop "$NAME" > /dev/null
        docker rm "$NAME" > /dev/null
        echo "old $NAME container removed"
    fi
}

remove_bootstrap_container () {
    if docker -H $BOOTSTRAP_SOCKET ps -a | grep "$NAME" > /dev/null; then
        docker -H $BOOTSTRAP_SOCKET stop "$NAME" > /dev/null
        docker -H $BOOTSTRAP_SOCKET rm "$NAME" > /dev/null
        echo "old $NAME container removed"
    fi
}


case "$1" in
"info")
    echo "K8S_VERSION is set to: ${K8S_VERSION}"
    echo "ETCD_VERSION is set to: ${ETCD_VERSION}"
    echo "FLANNEL_VERSION is set to: ${FLANNEL_VERSION}"
    echo "FLANNEL_IFACE is set to: ${FLANNEL_IFACE}"
    echo "FLANNEL_IPMASQ is set to: ${FLANNEL_IPMASQ}"
    echo "MASTER_IP is set to: ${MASTER_IP}"
    echo "ARCH is set to: ${ARCH}"
    ;;

"start-master")
    $0 "info"
    set +e
    service docker stop
    set -e
    service docker start
    $0 "bootstrap_daemon"
    sleep 1
    $0 "etcd"
    sleep 8
    $0 "flannel-master"
    sleep 5
    $0 "kubelet-master"
    $0 "apiserver"
    $0 "proxy"
    $0 "scheduler"
    $0 "controller-manager"
    ;;

"start-worker")
    $0 "info"
    set +e
    service docker stop
    set -e
    service docker start
    $0 "bootstrap_daemon"
    sleep 1
    $0 "flannel-worker"
    sleep 5
    $0 "etcd"
    $0 "kubelet-worker"
    $0 "proxy"
    ;;

"pull-only")
    docker pull "$IMAGE"
    ;;

"bootstrap_daemon")
    echo "Starting bootstrap daemon ..."

    docker daemon\
        -H $BOOTSTRAP_SOCKET \
        -p /var/run/docker-bootstrap.pid \
        --iptables=false \
        --ip-masq=false \
        --bridge=none \
        --graph=/var/lib/docker-bootstrap \
            2> /var/log/docker-bootstrap.log \
            1> /dev/null &
    ;;

"etcd")
    echo "Starting $NAME ..."

    remove_bootstrap_container "$NAME"

    etcd_ips=${ETCD_SERVERS}
    if [ "$ETCD_SERVERS" != "http://127.0.0.1:4001" ]; then
        etcd_ips="http://127.0.0.1:4001,${etcd_ips}"
    fi
    # Start etcd
    docker -H $BOOTSTRAP_SOCKET run \
        --restart=always \
        --name "$NAME" \
        --net=host \
        -d \
        gcr.io/google_containers/etcd-${ARCH}:${ETCD_VERSION} \
        /usr/local/bin/etcd \
            --listen-client-urls=${etcd_ips} \
            --advertise-client-urls=${ETCD_SERVERS} \
            --data-dir=/var/etcd/data
    ;;

"flannel-master")
    echo "Starting flannel for master ..."

    # Set flannel net config
    docker -H $BOOTSTRAP_SOCKET run \
        --rm \
        --net=host gcr.io/google_containers/etcd:${ETCD_VERSION} \
        etcdctl \
        set /coreos.com/network/config \
            '{ "Network": "10.1.0.0/16", "Backend": {"Type": "vxlan"}}'

    # iface may change to a private network interface, eth0 is for default
    remove_bootstrap_container "$NAME"

    flannelCID=$(docker -H ${BOOTSTRAP_SOCKET} run \
        --name "$NAME" \
        --restart=always \
        -d \
        --net=host \
        --privileged \
        -v /dev/net:/dev/net \
        quay.io/coreos/flannel:${FLANNEL_VERSION} \
        /opt/bin/flanneld \
            --ip-masq="${FLANNEL_IPMASQ}" \
            --iface="${FLANNEL_IFACE}")

    # Copy flannel env out and source it on the host
    docker -H $BOOTSTRAP_SOCKET \
        cp ${flannelCID}:/run/flannel/subnet.env .
    source subnet.env

    # Configure docker net settings, then restart it
    DOCKER_CONF="/etc/default/docker"
    echo "DOCKER_OPTS=\"\$DOCKER_OPTS --mtu=${FLANNEL_MTU} --bip=${FLANNEL_SUBNET}\"" | tee -a ${DOCKER_CONF}
    ifconfig docker0 down
    apt-get install bridge-utils
    brctl delbr docker0
    service docker stop
    while [ `ps aux | grep /usr/bin/docker | grep -v grep | wc -l` -gt 0 ]; do
        echo "Waiting for docker to terminate"
        sleep 1
    done
    service docker start
    ;;

"flannel-worker")
    echo "Starting flannel for worker ..."

    # iface may change to a private network interface, eth0 is for default
    remove_bootstrap_container "$NAME"

    flannelCID=$(docker -H $BOOTSTRAP_SOCKET run \
        --name "$NAME" \
        --restart=always \
        -d \
        --net=host \
        --privileged \
        -v /dev/net:/dev/net \
        quay.io/coreos/flannel:${FLANNEL_VERSION} \
        /opt/bin/flanneld \
            --ip-masq="${FLANNEL_IPMASQ}" \
            --etcd-endpoints=${ETCD_SERVERS} \
            --iface="${FLANNEL_IFACE}")

    sleep 8

    # Copy flannel env out and source it on the host
    docker -H $BOOTSTRAP_SOCKET \
        cp ${flannelCID}:/run/flannel/subnet.env .
    source subnet.env

    # Configure docker net settings, then restart it
    DOCKER_CONF="/etc/default/docker"
    echo "DOCKER_OPTS=\"\$DOCKER_OPTS --mtu=${FLANNEL_MTU} --bip=${FLANNEL_SUBNET}\"" | tee -a ${DOCKER_CONF}
    ifconfig docker0 down
    apt-get install bridge-utils
    brctl delbr docker0
    service docker stop
    while [ `ps aux | grep /usr/bin/docker | grep -v grep | wc -l` -gt 0 ]; do
        echo "Waiting for docker to terminate"
        sleep 1
    done
    service docker start
    ;;

"kubelet-master")
    echo "Starting $NAME ..."

    remove_bootstrap_container "$NAME"

    docker -H ${BOOTSTRAP_SOCKET} run \
        --name "$NAME" \
        --net=host \
        --pid=host \
        --privileged \
        --restart=always \
        -d \
        -v /sys:/sys:ro \
        -v /var/run:/var/run:rw \
        -v /:/rootfs:ro \
        -v /var/lib/docker/:/var/lib/docker:rw \
        -v /var/lib/kubelet/:/var/lib/kubelet:rw \
        gcr.io/google_containers/hyperkube-${ARCH}:v${K8S_VERSION} \
        /hyperkube kubelet \
            --address=0.0.0.0 \
            --allow-privileged=true \
            --enable-server \
            --api-servers=${API_SERVERS} \
            --config="" \
            --cluster-dns=10.0.0.10 \
            --cluster-domain=cluster.local \
            --containerized \
            --v=2
    ;;

"kubelet-worker")
    echo "Starting $NAME ..."

    remove_bootstrap_container "$NAME"

    docker -H ${BOOTSTRAP_SOCKET} run \
        --name "$NAME" \
        --net=host \
        --pid=host \
        --privileged \
        --restart=always \
        -d \
        -v /sys:/sys:ro \
        -v /var/run:/var/run:rw \
        -v /:/rootfs:ro \
        -v /var/lib/docker/:/var/lib/docker:rw \
        -v /var/lib/kubelet/:/var/lib/kubelet:rw \
        gcr.io/google_containers/hyperkube-${ARCH}:v${K8S_VERSION} \
        /hyperkube kubelet \
            --address=0.0.0.0 \
            --allow-privileged=true \
            --enable-server \
            --api-servers=${API_SERVERS} \
            --cluster-dns=10.0.0.10 \
            --config="" \
            --cluster-domain=cluster.local \
            --containerized \
            --v=2
    ;;

"proxy")
    echo "Starting $NAME ..."

    remove_bootstrap_container "$NAME"

    docker -H ${BOOTSTRAP_SOCKET} run \
        --name "$NAME" \
        -d \
        --net=host \
        --pid=host \
        --privileged \
        --restart=always \
        gcr.io/google_containers/hyperkube-${ARCH}:v${K8S_VERSION} \
        /hyperkube proxy \
            --master=${API_SERVERS} \
            --v=2
    ;;


"apiserver")
    echo "Starting $NAME ..."

    remove_bootstrap_container "$NAME"

    docker -H ${BOOTSTRAP_SOCKET} run \
        --name "$NAME" \
        -d \
        --restart=always \
        --privileged \
        --net=host \
        --pid=host \
        gcr.io/google_containers/hyperkube-${ARCH}:v${K8S_VERSION} \
        /hyperkube apiserver \
            --insecure-bind-address=$MASTER_IP \
            --external-hostname=$MASTER_IP \
            --bind-address=$MASTER_IP \
            --secure-port=0 \
            --etcd-servers=$ETCD_SERVERS \
            --service-cluster-ip-range=$SERVICERANGE \
            --v=2
    ;;

"controller-manager")
    echo "Starting $NAME ..."

    remove_bootstrap_container "$NAME"

    docker -H ${BOOTSTRAP_SOCKET} run \
        --name "$NAME" \
        -d \
        --restart=always \
        --privileged \
        --net=host \
        --pid=host \
        gcr.io/google_containers/hyperkube-${ARCH}:v${K8S_VERSION} \
         /hyperkube controller-manager \
            --master=${API_SERVERS} \
            --v=2
    ;;

"scheduler")
    echo "Starting $NAME ..."

    remove_bootstrap_container "$NAME"

    docker -H ${BOOTSTRAP_SOCKET} run \
        --name "$NAME" \
        -d \
        --restart=always \
        --privileged \
        --net=host \
        --pid=host \
        gcr.io/google_containers/hyperkube-${ARCH}:v${K8S_VERSION} \
        /hyperkube scheduler \
            --master=${API_SERVERS} \
            --v=2
    ;;

*)
    echo "unknown command $1"
    ;;
esac
