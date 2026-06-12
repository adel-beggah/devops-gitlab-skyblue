#!/usr/bin/env bash
# Rejoue TOUTE la chaîne de l'examen sur un cluster Kubernetes local (kind),
# sans dépendre de DockerHub ni de GitLab.com :
#   build image -> tests pytest -> cluster -> 4 namespaces -> helm x4 -> curl 200 x4
#
# Prérequis (macOS/brew) : docker(colima), kind, kubectl, helm
#   brew install colima docker kind kubectl helm && colima start --cpu 4 --memory 6
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=skyblue
echo "==> Build de l'image"
docker build -t fastapi:local .

echo "==> Tests unitaires (httpx épinglé <0.28, pytest depuis la racine)"
docker run --rm fastapi:local sh -c \
  "pip install -q pytest 'httpx<0.28' && python -m pytest app/ -v"

echo "==> Création du cluster kind (NodePorts 30000-30003 exposés)"
cat > /tmp/kind-skyblue.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - { containerPort: 30000, hostPort: 30000 }
      - { containerPort: 30001, hostPort: 30001 }
      - { containerPort: 30002, hostPort: 30002 }
      - { containerPort: 30003, hostPort: 30003 }
EOF
kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --config /tmp/kind-skyblue.yaml

echo "==> Namespaces + chargement de l'image"
kubectl apply -f k8s/namespaces.yaml
kind load docker-image fastapi:local --name "$CLUSTER"

echo "==> Déploiement Helm dans les 4 environnements"
for ns in dev qa staging prod; do
  helm upgrade --install fastapi ./fastapi -n "$ns" \
    --values ./fastapi/values-$ns.yaml \
    --set image.repository=fastapi --set image.tag=local --set image.pullPolicy=Never \
    --wait --timeout 120s
done

echo "==> Vérification HTTP de chaque environnement"
for entry in "dev:30000" "qa:30001" "staging:30002" "prod:30003"; do
  env=${entry%%:*}; port=${entry##*:}
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/")
  echo "[$env] http://localhost:$port/ -> HTTP $code"
done

echo "==> OK. Pour tout détruire : kind delete cluster --name $CLUSTER"
