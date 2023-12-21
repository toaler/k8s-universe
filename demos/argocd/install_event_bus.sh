#!/bin/bash

# Resources
#
# https://dev.to/ciscoemerge/how-to-deploy-apache-kafkar-on-kubernetes-if-youre-in-a-time-crunch-50b7
# https://github.com/pravega/zookeeper-operator

set -x
set -o errexit
set -o nounset
set -o pipefail

TIMEOUT=300s

source ./functions.sh

log "Install zookeepr-operator"
helm install zookeeper-operator --repo https://charts.pravega.io zookeeper-operator --namespace=zookeeper --create-namespace

log "install zookeeper"
kubectl create -f - <<EOF
apiVersion: zookeeper.pravega.io/v1beta1
kind: ZookeeperCluster
metadata:
    name: zookeeper
    namespace: zookeeper
spec:
    replicas: 1
    persistence:
        reclaimPolicy: Delete
EOF

kubectl get pods -n zookeeper

kubectl wait --for=condition=Ready pod/zookeeper-0 -n zookeeper --timeout=300s

kubectl create --validate=false -f https://github.com/banzaicloud/koperator/releases/download/v0.24.1/kafka-operator.crds.yaml

helm install kafka-operator --repo https://kubernetes-charts.banzaicloud.com kafka-operator --namespace=kafka --create-namespace

kubectl wait --for=condition=Ready pod -n kafka -l app.kubernetes.io/name=kafka-operator --timeout=300s

curl https://raw.githubusercontent.com/banzaicloud/koperator/master/config/samples/simplekafkacluster.yaml -o simplekafkacluster.yaml
sed -i.bak 's/zookeeper-server-client.zookeeper/zookeeper-client.zookeeper.svc.cluster.local/g' simplekafkacluster.yaml
kubectl create -n kafka -f simplekafkacluster.yaml

kubectl wait --for=condition=Ready pods -n kafka -l app=kafka --timeout=300s
kubectl wait --for=condition=Ready pods -n kafka -l app=cruisecontrol --timeout=300s

kubectl create -n kafka -f - <<EOF
apiVersion: kafka.banzaicloud.io/v1alpha1
kind: KafkaTopic
metadata:
    name: my-topic
spec:
    clusterRef:
        name: kafka
    name: my-topic
    partitions: 1
    replicationFactor: 1
    config:
        "retention.ms": "604800000"
        "cleanup.policy": "delete"
EOF

pod_name=$(kubectl get pods -n kafka | grep kafka-0 | awk '{print $1}')


# Check if the pod name is not empty before port forwarding
if [ -n "$pod_name" ]; then
    kubectl port-forward -n kafka "$pod_name" 29092:29092 > /dev/null 2>&1 &
else
    echo "Pod not found."
    exit 1
fi


# Can test by opening up two shells and run the following:
#
# shell 1 > kubectl -n kafka run kafka-producer -it --image=ghcr.io/banzaicloud/kafka:2.13-3.1.0 --rm=true --restart=Never -- /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server kafka-headless:29092 --topic my-topic
#
# shell 2 > kubectl -n kafka run kafka-consumer -it --image=ghcr.io/banzaicloud/kafka:2.13-3.1.0 --rm=true --restart=Never -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server kafka-headless:29092 --topic my-topic --from-beginning
