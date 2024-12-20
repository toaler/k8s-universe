# References
# Istio Gateway Setup --> https://www.youtube.com/watch?v=6tEy9Rp__kw
set -x
set -o errexit
set -o nounset
set -o pipefail

# TODO --> make sure to validate that the system properties are defined or fail the script
# sysctl net.bridge.bridge-nf-call-iptables=0
# sysctl net.bridge.bridge-nf-call-arptables=0
# sysctl net.bridge.bridge-nf-call-ip6tables=0

TIMEOUT=300s

log() {
    local timestamp
    timestamp=$(date +"%Y-%m-%d %T")
    local log_message="$timestamp [INFO] : $1"
    echo "$log_message"
}

fail() {
  set +x
  local -r all_args=("$@")
  local -r reason=$1
  local -r blob=("${all_args[@]:1}")


  if (( ${#blob[@]} )); then
    local line
    for line in "${blob[@]}"
    do
      >&2 echo "$line"
    done
  fi

  if [ -z "$reason" ]; then
    >&2 echo "FAILED"
  else
    >&2 echo "FAILED: $reason"
  fi

  exit 1
}

# Function to check if kind is installed
check_kind_installed() {
    if command -v kind &> /dev/null; then
        log "kind is already installed."
        return 0
    else
        log "kind is not installed."
        return 1
    fi
}

# Install kind if not installed
install_kind() {
    log "Installing kind..."
    if command -v brew &> /dev/null; then
        brew install kind
        if [ $? -eq 0 ]; then
            log "kind installed successfully."
        else
            fail "Failed to install kind. Please check your Homebrew setup."
        fi
    else
        fail "Homebrew is not installed. Please install Homebrew and rerun the script."
    fi
}


wait_for_pods_ready() {
  local LABEL=$1
  local NAMESPACE=$2
  local TIMEOUT=600
  local MAX_RETRIES=90
  local RETRY_INTERVAL=10

  # Loop to retry the kubectl get pods and kubectl wait commands
  for i in $(seq 1 $MAX_RETRIES); do
    echo "Checking for pods with label '$LABEL' in namespace '$NAMESPACE' (Attempt: $i/$MAX_RETRIES)"
    
    # Check if any pods are available with the specified label
    PODS=$(kubectl get pods -l $LABEL -n $NAMESPACE --no-headers)

    if [ -n "$PODS" ]; then
      # Pods found, proceed to wait for them to be ready
      echo "Pods found, waiting for them to be ready..."
      
      # Run kubectl wait for readiness with the specified timeout
      kubectl wait pods -l $LABEL --for=condition=Ready -n $NAMESPACE --timeout=${TIMEOUT}s
      WAIT_STATUS=$?

      # If kubectl wait times out (exit status 1), retry the whole process
      if [ $WAIT_STATUS -eq 1 ]; then
        echo "kubectl wait timed out. Retrying... ($i/$MAX_RETRIES)"
        sleep $RETRY_INTERVAL  # Wait before checking again
        continue  # Skip the return 0 and retry the entire loop
      fi

      # If the wait was successful (pods are ready), break out of the loop
      echo "Pods are ready!"
      return 0  # Exit successfully when pods are ready
    else
      # No pods found, retry after sleep
      echo "No pods found yet, retrying in $RETRY_INTERVAL seconds..."
      sleep $RETRY_INTERVAL  # Wait before checking again
    fi
  done

  # If we exit the loop without finding the pods, return failure
  echo "Pods were not found within the retry limit of $MAX_RETRIES."
  return 1  # Failure
}

# Main script logic
if ! check_kind_installed; then
    install_kind
fi

cluster_name="argo"
log "Deleting existing kind cluster"
if kind get clusters | grep -q "^$cluster_name$"; then
    kind delete cluster --name "$cluster_name"
    echo "Cluster '$cluster_name' deleted."
else
    echo "Cluster '$cluster_name' does not exist."
fi

log "Configure docker"

# TODO --> Make sure to fail the script if this command fails
# Check if the network exists before trying to delete
if docker network ls --quiet --filter name=kind | grep -q .; then

  # Step 1: Get a list of all running container IDs
  CONTAINER_IDS=$(docker ps -q)

  # Step 2: Check if there are any running containers
  if [ -z "$CONTAINER_IDS" ]; then
    echo "No running containers found."
  else
    echo "Stopping all running containers..."
    # Stop all running containers
    docker stop $CONTAINER_IDS
    # Step 3: Wait for containers to stop (optional)
    echo "Waiting for containers to stop..."
    docker wait $CONTAINER_IDS
  fi

  docker network rm kind || fail "Couldn't successfully delete docker network"
else
  echo "Docker network 'kind' does not exist, no need to delete."
fi

docker network create kind --subnet 100.121.20.32/27 --gateway 100.121.20.33 --ipv6=false \
--opt "com.docker.network.driver.mtu=1500" \
--opt "com.docker.network.bridge.name"="kind" \
--opt "com.docker.network.bridge.enable_ip_masquerade=true" \
  || fail "couldn't create docker network for kind cluster"


log "Creating kind cluster"
kind create cluster --config kind.yaml --name argo || fail "cound't create kind cluster argo"

log "Setting kubectl cluster-info to kind-argo"
kubectl cluster-info --context kind-argo || fail "failed to retreive cluster info from argo cluster"

image_names=(
    "quay.io/argoproj/argocd:v2.9.2"
    "ghcr.io/dexidp/dex:v2.37.0"
    "docker.io/library/redis:7.0.11-alpine"
    "docker.io/library/nginx:latest"
    "quay.io/prometheus/prometheus:v2.48.0"
    # Add more image names here if needed
)

# Loop through the array of image names
for image_name in "${image_names[@]}"
do
    # Pull the Docker image
    docker pull "$image_name" || fail "Failed to pull image $image_name"

    # Load the Docker image into the 'kind' cluster
    kind load docker-image "$image_name" --name argo || fail "Failed to load $image_name into kind repo"
done

log "install brew helm and argocd software"

if [[ "$(uname -s)" == "Darwin" ]]; then
    # macOS (Darwin) specific installations using Homebrew
    brew install helm
    brew install argocd

    if command -v telepresence >/dev/null 2>&1; then
      log "Telepresence exists in the PATH!"
    else
      log "Telepresence not found. Installing..."
      brew install telepresenceio/telepresence/telepresence-oss
    fi

elif [[ "$(uname -s)" == "Linux" ]]; then
    # Linux specific installations (modify this according to your package manager)
    # For example, if using apt:
    if [ ! -e "/snap/bin/helm" ]; then
      sudo snap install helm --classic
    else
      log "helm already installed"
    fi

    if [ ! -e "/usr/local/bin/argocd" ]; then
      curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
      sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
      rm argocd-linux-amd64
    else
      log "argocd already installed"
    fi

    if [ -f "/usr/local/bin/telepresence" ]; then
      log "Telepresence exists!"
    else
      curl -fL https://app.getambassador.io/download/tel2oss/releases/download/v2.17.0/telepresence-darwin-amd64 -o /usr/local/bin/telepresence
      sudo chmod a+x /usr/local/bin/telepresence
    fi

else
    log "Unsupported operating system"
    exit 1
fi

# Bootstrap Argo
ARGO_VER=2.9.2
log "Install Argo version ${ARGO_VER}"
kubectl create namespace argocd || fail "Failed to create argocd namespace"

curl "https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGO_VER}/manifests/install.yaml" -o argo_install.yaml || fail "Failed to download argo-cd manifest"


 if [[ "$(uname -s)" == "Darwin" ]]; then
     sed -i '' 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g' argo_install.yaml || fail "Failed to replace image pull policy in argo manifest"
 elif [[ "$(uname -s)" == "Linux" ]]; then
     sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g' argo_install.yaml || fail "Failed to replace image pull policy in argo manifest"
 else
     log "Unsupported operating system"
     exit 1
 fi


kubectl apply -n argocd -f argo_install.yaml || fail "Failed to kubectl apply argo_install"

NAMESPACE="argocd"

kubectl patch service argocd-server -p '{"spec": {"type": "NodePort"}}' -n ${NAMESPACE} || fail "Failed to patch argocd-server"
kubectl wait --for=condition=Ready --timeout=10m --all pods -n ${NAMESPACE} || fail "Failed to create pods in ${NAMESPACE}"

IP=$(kubectl get node argo-worker -o=jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
PORT=$(kubectl get service argocd-server -o=jsonpath='{.spec.ports[?(@.nodePort)].nodePort}' -n ${NAMESPACE}| awk '{print $1}')
PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n ${NAMESPACE} -o jsonpath='{.data.password}' | base64 --decode)

sleep 120

kubectl port-forward svc/argocd-server 8886:80 -n argocd &
log "Created port-forwarding for svc/argocd-server 8886:80"

sleep 5

log "Creating argocd session"
argocd login --insecure --username admin --password $PASSWORD localhost:8886 || fail "Failed to login to argocd"

log "Argo UI http://localhost:8886 username/password admin/$PASSWORD"

log "Display argocd resources"
kubectl -n ${NAMESPACE} get all || fail "Failed to get argo k8s resources"

kubectl config set-context --current --namespace=${NAMESPACE} || fail "Failed to set current namespace to ${NAMESPACE}"

# Bootstrap Helm charts
log "Inject Helm charts URL's into Argocd"
argocd repo add https://istio-release.storage.googleapis.com/charts --type helm --name istio --upsert || fail "Failed to istio helm chart to argo"
argocd repo add https://prometheus-community.github.io/helm-charts --type helm --name prometheus-community --upsert || fail "Failed to add prometheus helm chart to argo"
argocd repo add https://grafana.github.io/helm-charts --type helm --name grafana --upsert || fail "Failed to add grafana helm chart to argo"
argocd repo add https://kiali.org/helm-charts --type helm --name kiali --upsert || fail "Failed to add kiali helm chart to argo"

# Install Istio
log "Add Istio application to Argo"
kubectl create namespace istio-system || fail "Failed to create istio-system namespace"
argocd app create istio-base --repo https://istio-release.storage.googleapis.com/charts --helm-chart base --revision 1.20.0 --dest-namespace istio-system --dest-server https://kubernetes.default.svc || fail "Failed to create istio-base argo app"
argocd app sync istio-base || fail "Failed to sync istio-base argo app"

argocd app create istiod --repo https://istio-release.storage.googleapis.com/charts --helm-chart istiod --revision 1.20.0 --dest-namespace istio-system --dest-server https://kubernetes.default.svc || fail "Failed to create istiod argo app"
argocd app sync istiod || fail "Failed to sync istiod argo app"

kubectl label ns default istio-injection=enabled --overwrite || fail "Failed to inject auto istio proxy (sidecar) configuration in default namespace"

kubectl wait pods --for=condition=Ready -l app=istiod -n istio-system --timeout=${TIMEOUT} || fail "Failed to deploy istiod pods"

argocd app create istio-gateway --repo https://istio-release.storage.googleapis.com/charts --helm-chart gateway --revision 1.20.0 --dest-namespace istio-system --dest-server https://kubernetes.default.svc || fail "Failed to create istio-gateway argo app"
argocd app sync istio-gateway || fail "Failed to sync istio-gateway argo app"

kubectl patch service istio-gateway -n istio-system --patch-file ./gateway-svc-patch.yaml || fail "Failed to patch istio-gateway"
# TODO figure out how to decouple VirtualService from gateway.yaml
kubectl apply -f ./gateway.yaml -n default || fail "Failed to apply gateway manifest"

log "Istio installed"

# Eventually replace with a proper ArgoCD managed app
kubectl apply -f ./services.yaml -n default || fail "Failed to install demo services"
log "Demo services installed"
log "Test demo services"
kubectl wait pods --for=condition=Ready -l app=service-a -n default --timeout=${TIMEOUT} || fail "Failed to deploy service-a"
kubectl wait pods --for=condition=Ready -l app=service-b -n default --timeout=${TIMEOUT} || fail "Failed to deploy service-b"
#curl "$IP:30000/appA"
#curl "$IP:30000/appB"

# Install Prometheus

log "Install prometheus"
kubectl create namespace monitoring || fail "Failed to create monitoring namespace"
kubectl label ns monitoring istio-injection=enabled --overwrite || fail "Failed to configure service mesh in monitoring namespace"
argocd app create prometheus --repo https://prometheus-community.github.io/helm-charts --helm-chart prometheus --revision 25.8.0 --dest-namespace monitoring --dest-server https://kubernetes.default.svc || fail "Failed to create prometheus argo app"
argocd app sync prometheus || fail "Failed to sync prometheus argo app"

log "Waiting for prometheus to be ready"
wait_for_pods_ready "app.kubernetes.io/name=prometheus" "monitoring"

# Install grafana

log "Install grafana"
argocd app create grafana --repo https://grafana.github.io/helm-charts --helm-chart grafana --revision 7.0.8 --dest-namespace monitoring --dest-server https://kubernetes.default.svc --values-literal-file grafana-value.yaml --upsert || fail "Failed to create grafana argo app"
argocd app sync grafana || fail "Failed to sync grafana app"
wait_for_pods_ready "app.kubernetes.io/name=grafana" "monitoring"

# Install Kiali

log "Install Kiali"
argocd app create kiali-server --repo https://kiali.org/helm-charts --helm-chart kiali-server --revision 1.77.0 --dest-namespace istio-system --dest-server https://kubernetes.default.svc --values-literal-file kiali.yaml --upsert || fail "Failed to create Kiali argo app"
argocd app sync kiali-server || fail "Failed to sync kiali argo app"
wait_for_pods_ready "app.kubernetes.io/name=kiali" "istio-system"
# TODO how to get this to be picked up as part of argocd app create
kubectl apply -f ./kiali-vs.yaml -n istio-system || fail "Failed to install kiali virtual service"
log "kiali URL = $IP:30000/kiali"

# Install httpbin (TODO move to argocd)
kubectl apply -f httpbin.yaml
wait_for_pods_ready "app=httpbin" "argocd"
kubectl port-forward svc/httpbin 8890:80 &

log "Install telepresence"
telepresence helm install
telepresence --run-shell &


log "L I N K S"
log "Argo UI";
log "http://locahost:8886 username/password admin/$PASSWORD"
kubectl port-forward svc/kiali 8887:20001 -n istio-system > /dev/null 2>&1 &
log "Kiali UI"
log "http://localhost:8887"
kubectl port-forward -n monitoring service/prometheus-server 8888:80 > /dev/null 2>&1 &
log "Prometheus UI"
log "http://localhost:8888"
kubectl port-forward -n monitoring service/grafana 8889:80 > /dev/null 2>&1 &
log "Grafana"
log "http://localhost:8889 username/password admin/admin"
log "httpbin"

log "http://localhost:8890"
