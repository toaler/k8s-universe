# k8s-universe
A comprehensive Kubernetes ecosystem with GitOps, service mesh, monitoring, and development tools.

## 🚀 What's Included

This repository contains a complete Kubernetes development environment with:

- **ArgoCD** - GitOps continuous delivery platform
- **Istio Service Mesh** - Complete service mesh with gateway
- **Prometheus & Grafana** - Monitoring and observability stack
- **Kiali** - Service mesh observability and visualization
- **Telepresence** - Local development tool for Kubernetes
- **Demo Applications** - Sample microservices for testing

## 📋 Pre-requisites

### 1. Required Software
- **Docker** - Container runtime
- **Kind** - Kubernetes in Docker
- **kubectl** - Kubernetes command line tool
- **Helm** - Kubernetes package manager
- **ArgoCD CLI** - ArgoCD command line tool
- **Telepresence** - Development tool

### 2. Telepresence Configuration
Create `$HOME/Library/Application Support/telepresence/config.yml`:

```yaml
timeouts:
  helm: 600
```

### 3. Install Required Tools
```bash
# Install Kind
brew install kind

# Install Helm
brew install helm

# Install ArgoCD CLI
brew install argocd

# Install Telepresence
brew install telepresenceio/telepresence/telepresence-oss
```

## 🏗️ Cluster Setup

### Quick Start
```bash
# Navigate to the ArgoCD demo directory
cd demos/argocd

# Run the cluster setup script
chmod +x cluster_setup.sh
./cluster_setup.sh
```

### What the Setup Does
1. **Creates a multi-node Kind cluster** named "argo"
2. **Installs ArgoCD** with GitOps capabilities
3. **Deploys Istio Service Mesh** with gateway
4. **Sets up monitoring stack** (Prometheus, Grafana, Kiali)
5. **Deploys demo applications** (Service A, Service B, HTTPBin)
6. **Configures port forwarding** for all services

## 🌐 Access URLs

Once the cluster is running, access the services at:

| Service | URL | Credentials | Description |
|---------|-----|-------------|-------------|
| **ArgoCD UI** | http://localhost:8886 | admin / IBPetvdPpAhINdbb | GitOps management interface |
| **Kiali** | http://localhost:8887 | Anonymous | Service mesh observability |
| **Prometheus** | http://localhost:8888 | No auth | Metrics and monitoring |
| **Grafana** | http://localhost:8889 | admin / admin | Dashboards and visualization |
| **HTTPBin** | http://localhost:8890 | No auth | API testing service |

## 📊 Cluster Information

- **Cluster Name:** argo
- **Context:** kind-argo
- **Worker Node IP:** 100.121.20.35
- **Istio Gateway Port:** 30188
- **Namespaces:** argocd, istio-system, monitoring, default

## 🔧 Available Demos

### 1. ArgoCD Demo (`demos/argocd/`)
Complete setup with ArgoCD, Istio, monitoring stack, and demo applications.

### 2. NLB MetalLB with Istio (`demos/nlb_metallb.ig_istio/`)
Network load balancer setup with MetalLB and Istio ingress gateway.

### 3. NLB MetalLB with Nginx (`demos/nlb_metallb.ig_nginx/`)
Network load balancer setup with MetalLB and Nginx ingress.

## 🛠️ Management Commands

### Check Cluster Status
```bash
# Check all pods
kubectl get pods -A

# Check ArgoCD applications
kubectl get applications -n argocd

# Check Istio resources
kubectl get virtualservices,gateways -A
```

### Port Forwarding
```bash
# ArgoCD
kubectl port-forward svc/argocd-server 8886:80 -n argocd

# Kiali
kubectl port-forward svc/kiali 8887:20001 -n istio-system

# Prometheus
kubectl port-forward -n monitoring service/prometheus-server 8888:80

# Grafana
kubectl port-forward -n monitoring service/grafana 8889:80

# HTTPBin
kubectl port-forward svc/httpbin 8890:80
```

### Cleanup
```bash
# Delete the cluster
kind delete cluster --name argo

# Clean up Docker network
docker network rm kind
```

## 🎯 Use Cases

This setup is perfect for:
- **Learning Kubernetes** and service mesh concepts
- **Developing microservices** with Istio
- **Practicing GitOps** with ArgoCD
- **Testing monitoring** and observability tools
- **Local development** with Telepresence

## 🔍 Troubleshooting

### Common Issues
1. **Port conflicts** - Kill existing port-forward processes
2. **ArgoCD login timeout** - Wait for pods to be fully ready
3. **Image pull issues** - Check network connectivity

### Reset Cluster
```bash
# Delete and recreate cluster
kind delete cluster --name argo
./cluster_setup.sh
```

## 📚 Additional Resources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Istio Documentation](https://istio.io/docs/)
- [Kiali Documentation](https://kiali.io/docs/)
- [Telepresence Documentation](https://www.telepresence.io/docs/)

## 🤝 Contributing

Feel free to contribute by:
- Adding new demo scenarios
- Improving documentation
- Fixing issues
- Adding new tools or services

