kind create cluster --config kind.yaml --name argo

kubectl cluster-info --context kind-argo

brew install helm
brew install argocd

kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.9.2/manifests/install.yaml
kubectl wait --for=condition=Ready --timeout=5m --all deployments,pods,services -n argocd
kubectl patch service argocd-server -p '{"spec": {"type": "NodePort"}}' -n argocd

IP=$(kubectl get node argo-worker -o=jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
PORT=$(kubectl get service argocd-server -o=jsonpath='{.spec.ports[?(@.nodePort)].nodePort}' -n argocd | awk '{print $1}')
PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 --decode)

echo "Argo UI http://$IP:$PORT username/password admin/$PASSWORD"

kubectl -n argocd get all

kubectl config set-context --current --namespace=argocd

argocd app create guestbook --repo https://github.com/argoproj/argocd-example-apps.git --path guestbook --dest-server https://kubernetes.default.svc --dest-namespace default

argocd app get guestbook

argocd app sync guestbook

kubectl wait --for=condition=Ready pod -l app=guestbook-ui --timeout=5m -n default

echo "guestbook deployed"
