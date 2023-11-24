kind create cluster --config kind.yaml

brew install helm

echo -e "Adding istio helm repo"
helm repo add istio https://istio-release.storage.googleapis.com/charts

echo -e "Installing istio base CRDs"
helm install istio-base istio/base -n istio-system --create-namespace

echo -e "Installing istiod (control plane)"
helm install istiod istio/istiod -n istio-system --wait

echo -e "Labelling default namespace to autoinject istio-proxy sidecar"
kubectl label ns default istio-injection=enabled --overwrite

echo -e "Waiting for istio to be ready"
kubectl wait pods --for=condition=Ready -l app=istiod -n istio-system

echo -e "\nIstio service mesh is ready"

echo -e "Deploy istio gateway"
helm install istio-gateway istio/gateway -n istio-system

echo -e "Patching istio gateway service"
kubectl patch service istio-gateway -n istio-system --patch-file ./gateway-svc-patch.yaml

echo -e "Waiting for istiod to be ready"
kubectl wait pods --for=condition=Ready -l app=istiod -n istio-system --timeout=60s

echo -e "Deploying test applications"
kubectl apply -f ./services.yaml -n default

curl http://127.0.0.1/appA
curl http://127.0.0.1/appB

echo -e "Creating gateway resource and VirtualService for test applications"
kubectl apply -f ./gateway.yaml -n default

echo -e "Setup kiali"

echo "Install Helm and add repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts

echo "Install prometheus"
helm install prometheus prometheus-community/prometheus -n monitoring --create-namespace

echo -e "Waiting for prometheus to be ready"
kubectl wait pods --for=condition=Ready -l app=prometheus -n monitoring --timeout=120s

echo  "Install grafana"
helm install grafana grafana/grafana -n monitoring -f grafana-value.yaml

echo -e "Waiting for grafana to be ready"
kubectl wait pods --for=condition=Ready -l app.kubernetes.io/instance=grafana -n monitoring --timeout=120s


echo  "To access grafana run 'kubectl port-forward svc/grafana 8080:80 -n monitoring'"

helm install kiali-server kiali-server --repo https://kiali.org/helm-charts --set auth.strategy="anonymous" --set external_services.prometheus.url="http://prometheus-server.monitoring" -n istio-system

echo -e "Setup Kiali access"
echo -e "*******************************************************************************************************************"
kubectl apply -f ./kiali-vs.yaml -n istio-system


echo -e "\n*******************************************************************************************************************"
echo -e "Waiting for kiali to be ready"
echo -e "*******************************************************************************************************************"
kubectl wait pods --for=condition=Ready -l app=kiali -n istio-system --timeout=60s

echo -e  "To access kiali open '127.0.0.1/kiali' in your browser"
