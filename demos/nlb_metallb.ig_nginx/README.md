How to build a k8s cluster and enable network loadbalancer for L2 (Metallb) and enable ingress gateway (nginx):

# create cluster
kind create cluster --config kind.yaml

# deploy nginx webapp to cluster
kubectl create deploy nginx --image nginx

Ensure nginx pod is deployed:

kubectl get pods -A --watch

# install metallb L2 load balancer
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb

# get subnet for kind bridge network
docker ps
docker network ls
docker inspect bd9798ccd583

grab subnet cidr and update metallb.yaml with 10 ip's from the cidr block

# install IPAddressPool via metallb.yaml

kubectl apply -f metallb.ipaddresspool.yaml

# install L2Advertisement via metallb.l2.yaml

kubectl apply -f metallb.l2.yaml

# install service nginx
kubectl expose deployment nginx --port=80 --target-port=80 --name=nginx-service --type=LoadBalancer

# test ingress
curl 172.18.255.0:80
