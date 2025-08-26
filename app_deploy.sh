#!/usr/bin/env bash

# Just set 'chmod +x ./app_deploy.sh'
# and launch it:
# ./app_deploy.sh

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

# Util to get if there is MacOS
is_macos(){ [ "$(uname -s)" = "Darwin" ]; }
has_brew(){ command -v brew >/dev/null 2>&1; }

# PKG method: "brew" or "binary" (by default: macOS → brew, Linux → binary)
PKG_METHOD="${PKG_METHOD:-auto}"

use_brew_install(){
  if [ "$PKG_METHOD" = "brew" ]; then return 0; fi
  if [ "$PKG_METHOD" = "binary" ]; then return 1; fi

  is_macos && has_brew
}

install_kubectl(){
  if command -v kubectl >/dev/null 2>&1; then return; fi
  say "Installing kubectl..."

  if use_brew_install; then
    say "Using Homebrew to install kubectl (macOS)"
    brew install kubectl
    return
  fi

  # binary path (Linux or macOS w/o brew/forced)
  OS=$(uname | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  case "$ARCH" in x86_64|amd64) ARCH=amd64 ;; arm64|aarch64) ARCH=arm64 ;; *) err "Unsupported arch: $ARCH"; exit 1 ;; esac
  REL="$(curl -sL https://dl.k8s.io/release/stable.txt)"
  URL="https://dl.k8s.io/release/${REL}/bin/${OS}/${ARCH}/kubectl"
  say "Downloading: $URL"
  curl -L -o kubectl "$URL"
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl
  say "kubectl installed: $(kubectl version --client --short)"
}

install_minikube(){
  if command -v minikube >/dev/null 2>&1; then return; fi
  say "Installing minikube..."

  if use_brew_install; then
    say "Using Homebrew to install minikube (macOS)"
    brew install minikube
    return
  fi

  OS=$(uname | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  case "$ARCH" in x86_64|amd64) ARCH=amd64 ;; arm64|aarch64) ARCH=arm64 ;; *) err "Unsupported arch: $ARCH"; exit 1 ;; esac
  URL="https://storage.googleapis.com/minikube/releases/latest/minikube-${OS}-${ARCH}"
  say "Downloading: $URL"
  curl -L -o minikube "$URL"
  chmod +x minikube && sudo mv minikube /usr/local/bin/minikube
  say "minikube installed: $(minikube version)"
}

install_helm(){
  if command -v helm >/dev/null 2>&1; then return; fi
  say "Installing helm..."

  if use_brew_install; then
    say "Using Homebrew to install helm (macOS)"
    brew install helm
    return
  fi

  # binary path
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  say "helm installed: $(helm version --short)"
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

wait_ingress_ready() {
  say "Ensuring ingress-nginx is ready..."
  minikube addons enable ingress >/dev/null 2>&1 || true
  kubectl -n ingress-nginx wait --for=condition=Available deploy/ingress-nginx-controller --timeout=300s

  say "Waiting for admission webhook health..."
  for i in {1..10}; do
    if kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission -o jsonpath='{.subsets[0].addresses[0].ip}' >/dev/null 2>&1; then
      if kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller-admission 8443:443 >/dev/null 2>&1 & then
        sleep 2
        if curl -sk https://127.0.0.1:8443/healthz | grep -qi '^ok$'; then
          pkill -f "kubectl.*port-forward.*ingress-nginx-controller-admission.*8443:443" >/dev/null 2>&1 || true
          say "Admission webhook is healthy."
          return 0
        fi
        pkill -f "kubectl.*port-forward.*ingress-nginx-controller-admission.*8443:443" >/dev/null 2>&1 || true
      fi
    fi
    sleep 2
  done
  say "Admission still not ready → setting failurePolicy=Ignore"
  kubectl patch validatingwebhookconfiguration ingress-nginx-admission \
    --type='json' \
    -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]' || true
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

wait_ingress_ready
kubectl apply -f deploy/k8s/ingress.yaml || {
  say "Retry applying ingress after relaxing webhook..."
  kubectl patch validatingwebhookconfiguration ingress-nginx-admission \
    --type='json' \
    -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]' || true
  kubectl apply -f deploy/k8s/ingress.yaml
}

wait_prometheus_ready() {
  local ns="monitoring"
  say "[Prometheus] waiting for CRDs/Pods..."

  # Wait for Prometheus pods
  for i in {1..120}; do
    if kubectl -n "$ns" get pods -l app.kubernetes.io/name=prometheus \
         -o jsonpath='{.items[0].metadata.name}' >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  # Wait for rollout if there is statefulset — else wait for pod Ready
  if kubectl -n "$ns" get sts -l app.kubernetes.io/name=prometheus >/dev/null 2>&1; then
    local sts
    sts=$(kubectl -n "$ns" get sts -l app.kubernetes.io/name=prometheus \
            -o jsonpath='{.items[0].metadata.name}')
    say "[Prometheus] waiting for StatefulSet/$sts rollout..."
    kubectl -n "$ns" rollout status sts/"$sts" --timeout=10m || {
      err "[Prometheus] rollout status failed, showing pods:"; 
      kubectl -n "$ns" get pods -l app.kubernetes.io/name=prometheus -o wide
      return 1
    }
  else
    say "[Prometheus] waiting for pods Ready by label..."
    kubectl -n "$ns" wait --for=condition=Ready pod \
      -l app.kubernetes.io/name=prometheus --timeout=10m || {
      err "[Prometheus] pods not Ready, showing status:"; 
      kubectl -n "$ns" get pods -l app.kubernetes.io/name=prometheus -o wide
      return 1
    }
  fi

  say "[Prometheus] Ready."
}

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

wait_prometheus_ready

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
  kubectl -n "$NS_MON" wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus,app.kubernetes.io/instance=monitoring --timeout=180s
fi

# ServiceMonitor + dashboard + alerts
say "Applying ServiceMonitor & dashboard & alerts"
kubectl apply -f deploy/k8s/servicemonitor.yaml
kubectl apply -f deploy/monitoring/dice-dashboard.yaml
kubectl apply -f deploy/monitoring/dice-alerts.yaml

# Warm up: hit /dice 10 times
say "Warming up: hitting http://localhost:8080/dice x10 via Ingress"
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
sleep 2
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 3

# Grafana
kubectl -n "$NS_MON" port-forward svc/monitoring-grafana 3000:80 >/dev/null 2>&1 &
sleep 2

kubectl -n dice patch svc dice-svc --type=merge -p '{"metadata":{"labels":{"app":"dice","app.kubernetes.io/name":"dice","app.kubernetes.io/instance":"dice"}}}' \
&& kubectl -n monitoring patch prometheus $(kubectl -n monitoring get prometheus -o jsonpath='{.items[0].metadata.name}') --type=merge -p '{"spec":{"serviceMonitorSelector":{},"serviceMonitorNamespaceSelector":{},"podMonitorSelector":{},"podMonitorNamespaceSelector":{},"serviceMonitorSelectorNilUsesHelmValues":false,"podMonitorSelectorNilUsesHelmValues":false}}' \
&& kubectl -n monitoring rollout restart deploy/monitoring-kube-prometheus-operator

say "Opening Grafana & Prometheus in your browser..."
open_url "http://localhost:9090/targets"   # Prometheus targets
open_url "http://localhost:3000"           # Grafana

# Credentials for Grafana user
G_PASS="$(kubectl -n "$NS_MON" get secret "$GRAFANA_SECRET" -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || true)"
say "Grafana credentials → user: $GRAFANA_USER   pass: ${G_PASS:-'<in secret>'}"

say "Done. Check dashboard 'Dice App Status' in Grafana."
