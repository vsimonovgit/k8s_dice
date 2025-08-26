#!/usr/bin/env bash

# Settings
IMAGE_TAG="${IMAGE_TAG:-dice-app:latest}"
NS_APP="dice"
NS_MON="monitoring"
GRAFANA_SECRET="grafana-admin"
GRAFANA_USER="${GRAFANA_USER:-admin}"
DASHBOARD_CM="dice-grafana-dashboard"

# Helpers
say(){ echo -e "\033[1;36m[+] $*\033[0m"; }
err(){ echo -e "\033[1;31m[!] $*\033[0m" >&2; }
need(){ command -v "$1" >/dev/null 2>&1; }

# Clone repo
REPO_URL="https://github.com/vsimonovgit/k8s_dice.git"
WORKDIR="$HOME/test"

clone_repo(){
  mkdir -p "$WORKDIR" && cd "$WORKDIR"
  say "Cloning repo from $REPO_URL ..."
  if [ -d "$WORKDIR/.git" ]; then
    say "Repo already exists at $WORKDIR — pulling latest changes"
    git -C "$WORKDIR" pull --rebase
  else
    git clone "$REPO_URL" "$WORKDIR"
  fi
  say "Switched into repo directory: $(pwd)"
}

[ "$(basename "$(pwd)")" = "k8s_dice" ] || clone_repo

open_url(){
  local url="$1"
  if command -v open >/dev/null 2>&1; then open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
  else echo "→ open: $url"; fi
}

install_kubectl(){
  need kubectl && return
  say "Installing kubectl..."
  OS=$(uname | tr '[:upper:]' '[:lower:]')
  REL="$(curl -sL https://dl.k8s.io/release/stable.txt)"
  curl -LO "https://dl.k8s.io/release/${REL}/bin/${OS}/amd64/kubectl"
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl
}

install_minikube(){
  need minikube && return
  say "Installing minikube..."
  OS=$(uname | tr '[:upper:]' '[:lower:]')
  curl -Lo minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-${OS}-amd64"
  chmod +x minikube && sudo mv minikube /usr/local/bin/minikube
}

install_helm(){
  need helm && return
  say "Installing helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

ensure_docker(){
  if need docker; then
    return
  fi

  say "Did not find Docker. Installing..."

  case "$(uname -s)" in
    Linux)
      # Get local OS type
      if [ -f /etc/os-release ]; then
        . /etc/os-release
      fi

      if command -v apt-get >/dev/null 2>&1; then
        # Debian-like
        sudo apt-get update -y
        sudo apt-get install -y ca-certificates curl gnupg lsb-release
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$ID/gpg | \
          sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
          https://download.docker.com/linux/$ID \
          $(lsb_release -cs) stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        sudo systemctl enable --now docker
        say "Docker installed and run."

      elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        # RHEL-like
        PKG_MANAGER=$(command -v dnf || command -v yum)
        sudo $PKG_MANAGER -y install yum-utils device-mapper-persistent-data lvm2
        sudo $PKG_MANAGER -y remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true
        sudo $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo $PKG_MANAGER -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
        sudo systemctl enable --now docker
        say "Docker installed and run."

      else
        err "Unknown package manager. Please install Docker manually."
        exit 1
      fi
      ;;

    Darwin)
      # MacOS
      if command -v brew >/dev/null 2>&1; then
        brew install docker colima
        colima start
        say "Docker installed."
      else
        err "Homebrew is needed for MacOS. Please install it manually."
        exit 1
      fi
      ;;

    *)
      err "Docker auto-installing in this OS is not supported. Please, install Docker manually."
      exit 1
      ;;
  esac

  # Check after installation
  if ! need docker; then
    err "Docker was not find yet."
    exit 1
  fi
}

rand_pass(){ LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

# Prepare k8s
ensure_docker
install_kubectl
install_minikube
install_helm

# Start minikube
say "Starting minikube + enabling ingress..."
minikube status >/dev/null 2>&1 || minikube start
minikube addons enable ingress >/dev/null

# Build docker image & load
say "Building docker image: $IMAGE_TAG"
docker build -t "$IMAGE_TAG" .

say "Loading image into minikube"
minikube image load "$IMAGE_TAG"

# Deploy Dice app
say "Applying app manifests:"
kubectl apply -f deploy/k8s/namespace.yaml
kubectl apply -f deploy/k8s/deployment.yaml
kubectl apply -f deploy/k8s/service.yaml
kubectl -n dice rollout status deploy/dice-app
say "Waiting for dice-app rollout..."
kubectl -n "$NS_APP" rollout status deploy/dice-app --timeout=180s
kubectl -n ingress-nginx wait --for=condition=Available deploy/ingress-nginx-controller --timeout=180s
kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission
kubectl apply -f deploy/k8s/ingress.yaml

# Helm monitoring
say "Helm repo add/update prometheus-community"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# Secret for grafana admin if absent
if ! kubectl -n "$NS_MON" get secret "$GRAFANA_SECRET" >/dev/null 2>&1; then
  say "Creating Grafana admin Secret ($GRAFANA_SECRET)"
  PASS="$(rand_pass)"
  kubectl create ns "$NS_MON" >/dev/null 2>&1 || true
  kubectl -n "$NS_MON" create secret generic "$GRAFANA_SECRET" \
    --from-literal=admin-user="$GRAFANA_USER" \
    --from-literal=admin-password="$PASS" >/dev/null
  say "Grafana admin password: $PASS"
else
  say "Grafana admin Secret exists — keeping current password."
fi

say "Installing/Upgrading kube-prometheus-stack with deploy/monitoring/values.yaml"
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n "$NS_MON" --create-namespace -f deploy/monitoring/values.yaml

say "Waiting Grafana & Prometheus to be Ready..."
kubectl -n "$NS_MON" rollout status deploy/monitoring-grafana --timeout=300s
kubectl -n "$NS_MON" rollout status deploy/monitoring-kube-prometheus-operator --timeout=300s || true
PROM_STS="$(kubectl -n "$NS_MON" get sts \
  -l app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=monitoring \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [ -n "$PROM_STS" ]; then
  say "Found Prometheus StatefulSet: $PROM_STS"
  kubectl -n "$NS_MON" rollout status sts/"$PROM_STS" --timeout=360s
else
  say "Prometheus StatefulSet was not found. Waiting for Prometheus pods become ready..."
  kubectl -n "$NS_MON" wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=monitoring \
    --timeout=120s
fi

# ServiceMonitor + dashboard + alerts
say "Applying ServiceMonitor & dashboard & alerts"
kubectl apply -f deploy/k8s/servicemonitor.yaml
kubectl apply -f deploy/monitoring/dice-dashboard.yaml
kubectl apply -f deploy/monitoring/dice-alerts.yaml

# Warm up: hit /dice 10 times
say "Warming up: hitting http://localhost/dice x10 via Ingress"
kubectl -n dice port-forward svc/dice-svc 8080:80 >/dev/null 2>&1 &
sleep 1
for i in $(seq 1 10); do
  curl -sS http://localhost:8080/dice || true
  echo
  sleep 0.3
done

# Port-forward & open
say "Port-forward Prometheus & Grafana (background)"
# just make sure port-forwarding is clean
pkill -f "kubectl.*port-forward.*monitoring-grafana" >/dev/null 2>&1 || true
pkill -f "kubectl.*port-forward.*monitoring-kube-prometheus-prometheus" >/dev/null 2>&1 || true

# Prometheus
kubectl -n "$NS_MON" port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 1

# Grafana
kubectl -n "$NS_MON" port-forward svc/monitoring-grafana 3000:80 >/dev/null 2>&1 &
sleep 2

say "Opening Grafana & Prometheus in your browser..."
open_url "http://localhost:9090/targets"   # Prometheus targets
open_url "http://localhost:3000"           # Grafana

# Credentials for Grafana user
G_PASS="$(kubectl -n "$NS_MON" get secret "$GRAFANA_SECRET" -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || true)"
say "Grafana credentials → user: $GRAFANA_USER   pass: ${G_PASS:-'<in secret>'}"

say "Done. Check dashboard 'Dice App Status' in Grafana."
