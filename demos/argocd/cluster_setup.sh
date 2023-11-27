#!/bin/bash

log() {
    local timestamp=$(date +"%Y-%m-%d %T")
    local log_message="$timestamp [INFO] : $1"
    echo "$log_message"
}

log "Deleting existing kind cluster"
kind delete cluster --name argo

log "Creating kind cluster"
kind create cluster --config kind.yaml --name argo

log "Setting kubectl cluster-info to kind-argo"
kubectl cluster-info --context kind-argo

log "install brew helm and argocd software"
brew install helm
brew install argocd

# Bootstrap Argo
log "Install Argo"
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.2/manifests/install.yaml
kubectl wait --for=condition=Ready --timeout=5m --all pods -n argocd
kubectl patch service argocd-server -p '{"spec": {"type": "NodePort"}}' -n argocd

IP=$(kubectl get node argo-worker -o=jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
PORT=$(kubectl get service argocd-server -o=jsonpath='{.spec.ports[?(@.nodePort)].nodePort}' -n argocd | awk '{print $1}')
PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 --decode)

sleep 15
log "Creating argocd session"
argocd login --insecure --username admin --password $PASSWORD $IP:$PORT

log "Argo UI http://$IP:$PORT username/password admin/$PASSWORD"

log "Display argocd configuration"
kubectl -n argocd get all

kubectl config set-context --current --namespace=argocd

# Bootstrap Helm charts
log "Inject Helm charts URL's into Argocd"
argocd repo add https://istio-release.storage.googleapis.com/charts --type helm --name istio --upsert
argocd repo add https://prometheus-community.github.io/helm-charts --type helm --name prometheus-community --upsert
argocd repo add https://grafana.github.io/helm-charts --type helm --name grafana --upsert
argocd repo add https://kiali.org/helm-charts --type helm --name kiali --upsert

# Install Istio
log "Add Istio application to Argo"
kubectl create namespace istio-system
argocd app create istio-base --repo https://istio-release.storage.googleapis.com/charts --helm-chart base --revision 1.20.0 --dest-namespace istio-system --dest-server https://kubernetes.default.svc
argocd app sync istio-base

argocd app create istiod --repo https://istio-release.storage.googleapis.com/charts --helm-chart istiod --revision 1.20.0 --dest-namespace istio-system --dest-server https://kubernetes.default.svc
argocd app sync istiod

kubectl label ns default istio-injection=enabled --overwrite

kubectl wait pods --for=condition=Ready -l app=istiod -n istio-system

argocd app create istio-gateway --repo https://istio-release.storage.googleapis.com/charts --helm-chart gateway --revision 1.20.0 --dest-namespace istio-system --dest-server https://kubernetes.default.svc
argocd app sync istio-gateway

kubectl patch service istio-gateway -n istio-system --patch-file ./gateway-svc-patch.yaml
# TODO figure out how to decouple VirtualService from gateway.yaml
kubectl apply -f ./gateway.yaml -n default

log "Istio installed"

# Eventually replace with a proper ArgoCD managed app
kubectl apply -f ./services.yaml -n default
log "Demo services installed"
log "Teset demo services"
curl $IP:30000/appA
curl $IP:30000/appB
kubectl wait pods --for=condition=Ready -l app=service-a -n default
kubectl wait pods --for=condition=Ready -l app=service-b -n default

# Install Prometheus

log "Install prometheus"
kubectl create namespace monitoring
argocd app create prometheus --repo https://prometheus-community.github.io/helm-charts --helm-chart prometheus --revision 25.8.0 --dest-namespace monitoring --dest-server https://kubernetes.default.svc
argocd app sync prometheus

log "Waiting for prometheus to be ready"
kubectl wait pods --for=condition=Ready -l app.kubernetes.io/name=prometheus -n monitoring

kubectl port-forward -n monitoring service/prometheus-server 8888:80 &
log "prometheus-server available on http://localhost:8888"

# Install grafana

log "Install grafana"
argocd app create grafana --repo https://grafana.github.io/helm-charts --helm-chart grafana --revision 7.0.8 --dest-namespace monitoring --dest-server https://kubernetes.default.svc --values-literal-file grafana-value.yaml --upsert
argocd app sync grafana
kubectl wait pods --for=condition=Ready -l app.kubernetes.io/name=grafana -n monitoring

kubectl port-forward -n monitoring service/grafana 8889:80 &
log "grafana available on http://localhost:8889"

# Install Kiali

log "Install Kiali"
argocd app create kiali-server --repo https://kiali.org/helm-charts --helm-chart kiali-server --revision 1.77.0 --dest-namespace istio-system --dest-server https://kubernetes.default.svc --values-literal-file kiali.yaml --upsert
argocd app sync kiali-server 

kubectl wait pods --for=condition=Ready -l app.kubernetes.io/name=kiali -n istio-system
# TODO how to get this to be picked up as part of argocd app create
kubectl apply -f ./kiali-vs.yaml -n istio-system

kubectl port-forward svc/kiali 8890:20001 -n istio-system &
log "kiali available on http://localhost:8890"

# Install Test App
argocd app create guestbook --repo https://github.com/argoproj/argocd-example-apps.git --path guestbook --dest-server https://kubernetes.default.svc --dest-namespace default

argocd app get guestbook

argocd app sync guestbook

kubectl wait --for=condition=Ready pod -l app=guestbook-ui --timeout=5m -n default

log "guestbook deployed"
