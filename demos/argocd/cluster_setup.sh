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

# Kill any existing port-forward processes to avoid conflicts
pkill -f "kubectl port-forward.*8886" || true

# Wait for ArgoCD server to be fully ready
log "Waiting for ArgoCD server to be ready"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s || fail "ArgoCD server pod not ready"

# Start port-forward with better error handling
kubectl port-forward svc/argocd-server 8886:80 -n argocd --address 0.0.0.0 &
PORT_FORWARD_PID=$!
log "Created port-forwarding for svc/argocd-server 8886:80 (PID: $PORT_FORWARD_PID)"

# Wait for port-forward to be established
sleep 10

# Test if ArgoCD is accessible
log "Testing ArgoCD connectivity"
for i in {1..10}; do
    if curl -k -s https://localhost:8886 > /dev/null 2>&1; then
        log "ArgoCD is accessible"
        break
    fi
    if [ $i -eq 10 ]; then
        log "WARNING: ArgoCD is not accessible after 10 attempts, but continuing..."
    fi
    log "Waiting for ArgoCD to be accessible... (attempt $i/10)"
    sleep 3
done

log "Creating argocd session"
# Try ArgoCD login once, but don't fail if it doesn't work
if argocd login --insecure --username admin --password "$PASSWORD" localhost:8886 --grpc-web; then
    log "Successfully logged into ArgoCD"
else
    log "WARNING: ArgoCD login failed, but continuing with setup using kubectl..."
fi

log "Argo UI http://localhost:8886 username/password admin/$PASSWORD"

log "Display argocd resources"
kubectl -n ${NAMESPACE} get all || fail "Failed to get argo k8s resources"

kubectl config set-context --current --namespace=${NAMESPACE} || fail "Failed to set current namespace to ${NAMESPACE}"

# Bootstrap Helm charts
log "Inject Helm charts URL's into Argocd"
# Use kubectl to add repositories instead of argocd CLI to avoid login issues
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: istio-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  url: https://istio-release.storage.googleapis.com/charts
  name: istio
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: prometheus-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  url: https://prometheus-community.github.io/helm-charts
  name: prometheus-community
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  url: https://grafana.github.io/helm-charts
  name: grafana
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kiali-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  url: https://kiali.org/helm-charts
  name: kiali
EOF

# Install Istio
log "Add Istio application to Argo"
kubectl create namespace istio-system || fail "Failed to create istio-system namespace"

# Create Istio applications using kubectl instead of argocd CLI
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-base
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://istio-release.storage.googleapis.com/charts
    chart: base
    targetRevision: 1.20.0
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istiod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://istio-release.storage.googleapis.com/charts
    chart: istiod
    targetRevision: 1.20.0
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

kubectl label ns default istio-injection=enabled --overwrite || fail "Failed to inject auto istio proxy (sidecar) configuration in default namespace"

# Wait for ArgoCD applications to sync and deploy
log "Waiting for Istio applications to sync and deploy"
sleep 30

# Wait for istio-base to be ready
log "Waiting for istio-base to be ready"
kubectl wait --for=condition=Ready --timeout=300s application/istio-base -n argocd || log "WARNING: istio-base application not ready"

# Wait for istiod to be ready
log "Waiting for istiod to be ready"
kubectl wait --for=condition=Ready --timeout=300s application/istiod -n argocd || log "WARNING: istiod application not ready"

# Wait for istiod pods to be ready
log "Waiting for istiod pods to be ready"
kubectl wait pods --for=condition=Ready -l app=istiod -n istio-system --timeout=${TIMEOUT} || log "WARNING: istiod pods not ready, but continuing..."

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-gateway
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://istio-release.storage.googleapis.com/charts
    chart: gateway
    targetRevision: 1.20.0
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

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

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prometheus
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: prometheus
    targetRevision: 25.8.0
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

log "Waiting for prometheus to be ready"
wait_for_pods_ready "app.kubernetes.io/name=prometheus" "monitoring"

# Install grafana

log "Install grafana"
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grafana
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: grafana
    targetRevision: 7.0.8
    helm:
      values: |
        adminPassword: admin
        service:
          type: NodePort
          nodePort: 30001
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

wait_for_pods_ready "app.kubernetes.io/name=grafana" "monitoring"

# Install Kiali

log "Install Kiali"
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kiali-server
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://kiali.org/helm-charts
    chart: kiali-server
    targetRevision: 1.77.0
    helm:
      values: |
        auth:
          strategy: anonymous
        external_services:
          istio:
            root_namespace: istio-system
        server:
          port: 20001
          web_root: /kiali
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

wait_for_pods_ready "app.kubernetes.io/name=kiali" "istio-system"
# TODO how to get this to be picked up as part of argocd app create
kubectl apply -f ./kiali-vs.yaml -n istio-system || fail "Failed to install kiali virtual service"
log "kiali URL = $IP:30000/kiali"

# Install httpbin (TODO move to argocd)
kubectl apply -f httpbin.yaml
wait_for_pods_ready "app=httpbin" "argocd"

# Kill any existing port-forward processes to avoid conflicts
pkill -f "kubectl port-forward.*8890" || true
pkill -f "kubectl port-forward.*8887" || true
pkill -f "kubectl port-forward.*8888" || true
pkill -f "kubectl port-forward.*8889" || true

# Wait for services to be ready before port-forwarding
log "Waiting for services to be ready before setting up port forwarding"

# Wait for Kiali to be ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=kiali -n istio-system --timeout=300s || log "WARNING: Kiali pod not ready, skipping port-forward"

# Wait for Prometheus to be ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=300s || log "WARNING: Prometheus pod not ready, skipping port-forward"

# Wait for Grafana to be ready
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s || log "WARNING: Grafana pod not ready, skipping port-forward"

# Wait for HTTPBin to be ready
kubectl wait --for=condition=Ready pod -l app=httpbin -n argocd --timeout=300s || log "WARNING: HTTPBin pod not ready, skipping port-forward"

# Set up port forwarding with error handling
log "Setting up port forwarding for services"

# HTTPBin port-forward
if kubectl get pod -l app=httpbin -n argocd --no-headers | grep -q Running; then
    kubectl port-forward svc/httpbin 8890:80 &
    log "HTTPBin port-forward started on 8890"
else
    log "WARNING: HTTPBin not ready, skipping port-forward"
fi

log "Install telepresence"
telepresence helm install

# Set up additional port forwarding with error handling
log "Setting up additional port forwarding"

# Kiali port-forward
if kubectl get pod -l app.kubernetes.io/name=kiali -n istio-system --no-headers | grep -q Running; then
    kubectl port-forward svc/kiali 8887:20001 -n istio-system > /dev/null 2>&1 &
    log "Kiali port-forward started on 8887"
else
    log "WARNING: Kiali not ready, skipping port-forward"
fi

# Prometheus port-forward
if kubectl get pod -l app.kubernetes.io/name=prometheus -n monitoring --no-headers | grep -q Running; then
    kubectl port-forward -n monitoring service/prometheus-server 8888:80 > /dev/null 2>&1 &
    log "Prometheus port-forward started on 8888"
else
    log "WARNING: Prometheus not ready, skipping port-forward"
fi

# Grafana port-forward
if kubectl get pod -l app.kubernetes.io/name=grafana -n monitoring --no-headers | grep -q Running; then
    kubectl port-forward -n monitoring service/grafana 8889:80 > /dev/null 2>&1 &
    log "Grafana port-forward started on 8889"
else
    log "WARNING: Grafana not ready, skipping port-forward"
fi

log "L I N K S"
log "Argo UI: http://localhost:8886 username/password admin/$PASSWORD"
log "Kiali UI: http://localhost:8887"
log "Prometheus UI: http://localhost:8888"
log "Grafana: http://localhost:8889 username/password admin/admin"
log "HTTPBin: http://localhost:8890"

log "Cluster setup completed successfully!"
log "Note: Some services may take a few minutes to be fully accessible."
