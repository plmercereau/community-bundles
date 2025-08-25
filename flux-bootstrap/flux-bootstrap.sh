#!/bin/bash

# Override with the `flux.env.KUBECONFIG` key if necessary
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Seconds
short=5

configmap=flux-bootstrap

info () {
  echo $'\e[36mINFO\e[0m: ' "$1"
}

warn() {
  echo $'\e[33mWARN\e[0m:' "$1"
}

error() {
  echo $'\e[31mERROR\e[0m:' "$1"
}

bootstrap() {
  NS=flux-system
  REPO_URL=$(kairos-agent config get "flux.url")
  BRANCH=$(kairos-agent config get "flux.branch")
  PATH_IN_REPO="$(kairos-agent config get "flux.path")" # TODO replace with the cluster id
  KEY=$(kairos-agent config get "flux.syncKeyFile")
  COMPONENTS_EXTRA=$(kairos-agent config get "flux.components-extra")

  flux install --namespace "$NS" --components-extra="$COMPONENTS_EXTRA"

  kubectl -n "$NS" rollout status deploy/source-controller --timeout=180s
  kubectl -n "$NS" rollout status deploy/kustomize-controller --timeout=180s

  kubectl -n "$NS" delete secret flux-system >/dev/null 2>&1 || true
  flux create secret git flux-system --namespace "$NS" --url "$REPO_URL" --private-key-file "$KEY"

  flux create source git flux-system --namespace "$NS" --url "$REPO_URL" --branch "$BRANCH" --secret-ref flux-system 

  flux create kustomization flux-system --namespace "$NS" --source "GitRepository/flux-system" --path "$PATH_IN_REPO" --prune true
}

cleanup() {
  info "Removing bootstrap configmap"
  timeout $short kubectl delete configmap -n default $configmap
}

# Don't bootstrap if the cluster is already bootstrapped
if flux version &>/dev/null; then
  info "Flux is already bootstrapped, exiting..."
  exit 0
fi

# Try to bootstrap Flux for 30 minutes, sleep 15 seconds between attempts
minutes=30
sleep=15
retry_attempt=1
total_attempts=$(( minutes * 60 / sleep ))
active="false"

while [[ $retry_attempt -le $total_attempts ]]; do
  if [[ "$active" != "true" ]]; then
    # Ensure only one host tries to bootstrap, whichever makes the configmap first
    if ! timeout $short kubectl version &> /dev/null; then
      info "Kubernetes API not ready yet, sleeping"
    else
      if ! timeout $short kubectl create configmap $configmap --from-literal=hostname="$(hostname)"; then
        warn "Unable to create configmap, another node may be active"
      fi

      # The configmap exists but we must finally check if the hostname matches
      if [[ "$(timeout $short kubectl get configmap -n default $configmap -o jsonpath='{.data.hostname}')" != "$(hostname)" ]]; then
        error "Flux bootstrap ConfigMap exists but another node is active, exiting..."
        exit 3
      fi

      # We must be the active node
      active="true"
    fi
  fi
  
  if [[ "$active" == "true" ]]; then
    if bootstrap; then
      cleanup
      exit 0
    fi
  fi

  warn "Install attempt $retry_attempt (of $total_attempts) failed, retrying in $sleep seconds"
  (( retry_attempt = retry_attempt + 1 ))
  sleep $sleep
done


error "Failed to bootstrap with Flux, timed out ($minutes minutes)"
exit 4
