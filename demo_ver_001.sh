#!/usr/bin/env bash
set -euo pipefail

# ------------------------------
# Config (edit these)
# ------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-aro-demo-rg}"
LOCATION="${LOCATION:-eastus}"
ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME:-aro-open-demo}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null || echo "")}"

# GitOps app (public OSS)
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/stefanprodan/podinfo}"
GIT_BRANCH="${GIT_BRANCH:-master}"

# Namespaces
NS_GITOPS="gitops-demo"
NS_VIRT="virt-demo"

# ------------------------------
# Pre-flight checks
# ------------------------------
echo "🔎 Checking CLI availability..."
command -v az >/dev/null || { echo "az not found"; exit 1; }
command -v oc >/dev/null || { echo "oc not found"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }

echo "🔐 Verifying Azure login..."
az account show >/dev/null || az login >/dev/null

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
fi
az account set --subscription "$SUBSCRIPTION_ID"

echo "🧪 Verifying oc login (current project):"
oc project >/dev/null

# ------------------------------
# Azure resource group (idempotent)
# ------------------------------
echo "🧱 Ensuring resource group: $RESOURCE_GROUP in $LOCATION"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null

# ------------------------------
# Connect OpenShift cluster to Azure Arc (idempotent)
# ------------------------------
echo "🔗 Onboarding cluster to Azure Arc (connectedk8s)..."
if az connectedk8s show -g "$RESOURCE_GROUP" -n "$ARC_CLUSTER_NAME" >/dev/null 2>&1; then
  echo "ℹ️ Arc connection already exists: $ARC_CLUSTER_NAME"
else
  az connectedk8s connect \
    --name "$ARC_CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --distribution "openshift" \
    --location "$LOCATION"
fi

# ------------------------------
# Check for Flux Operator Installation on ARO
# ------------------------------
echo "🔍 Checking if Flux is installed on the ARO cluster..."

# Verify Flux is installed as an Operator in OpenShift
if oc get csv -n openshift-operators | grep -qi flux; then
  echo "✅ Flux Operator is installed on the cluster."
else
  echo "❌ Flux Operator not detected on this ARO cluster."
  echo "⚠️  Please install the Flux Operator via the OpenShift OperatorHub in the ARO console before continuing."
  echo "   👉 Console path: Operators → OperatorHub → Search 'Flux' → Install (Marketplace version recommended)"
  exit 1
fi

# ------------------------------
# Bootstrap Git source + Kustomization (namespace-scoped)
# ------------------------------
echo "📦 Creating namespace for GitOps app: $NS_GITOPS"
oc new-project "$NS_GITOPS" >/dev/null 2>&1 || true

# Define Flux GitRepository & Kustomization via Kubernetes manifests
WORKDIR="$(mktemp -d)"
cat > "$WORKDIR/git-source.yaml" <<EOF
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: podinfo-source
  namespace: $NS_GITOPS
spec:
  interval: 1m
  url: $GIT_REPO_URL
  ref:
    branch: $GIT_BRANCH
EOF

cat > "$WORKDIR/kustomization.yaml" <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: podinfo-kustomize
  namespace: $NS_GITOPS
spec:
  interval: 1m
  targetNamespace: $NS_GITOPS
  sourceRef:
    kind: GitRepository
    name: podinfo-source
  path: "./kustomize"
  prune: true
  wait: true
EOF

echo "🚀 Applying Flux objects..."
kubectl apply -f "$WORKDIR/git-source.yaml"
kubectl apply -f "$WORKDIR/kustomization.yaml"

echo "⏳ Waiting for Podinfo rollout (up to ~2 minutes)..."
kubectl -n "$NS_GITOPS" wait --for=condition=available --timeout=180s deploy -l app.kubernetes.io/name=podinfo || true

echo "🔎 Services in $NS_GITOPS:"
kubectl -n "$NS_GITOPS" get svc

# ------------------------------
# OpenShift Virtualization: Fedora VM with nginx via cloud-init
# ------------------------------
echo "🧰 Creating virtualization namespace: $NS_VIRT"
oc new-project "$NS_VIRT" >/dev/null 2>&1 || true

cat > "$WORKDIR/virtualmachine.yaml" <<'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: fedora-nginx
  labels:
    app: fedora-nginx
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/domain: fedora-nginx
        app: fedora-nginx
    spec:
      domain:
        cpu:
          cores: 2
        resources:
          requests:
            memory: 2Gi
        devices:
          disks:
            - name: containerdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
      networks:
        - name: podnet
          pod: {}
      volumes:
        - name: containerdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:39
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: fedora
              chpasswd: { expire: False }
              packages:
                - nginx
              runcmd:
                - [ sh, -c, "systemctl enable --now nginx" ]
                - [ sh, -c, "echo 'hello from kubevirt on openshift' > /usr/share/nginx/html/index.html" ]
EOF

# Optional service (ClusterIP) to reach nginx from within the cluster
cat > "$WORKDIR/svc.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: fedora-nginx-svc
  namespace: $NS_VIRT
spec:
  selector:
    app: fedora-nginx
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
  type: ClusterIP
EOF

echo "🖥️  Creating VM and service..."
kubectl -n "$NS_VIRT" apply -f "$WORKDIR/virtualmachine.yaml"
kubectl -n "$NS_VIRT" apply -f "$WORKDIR/svc.yaml"

echo "⏳ Waiting for VM to be Running..."
# Wait until the corresponding VMI is running
for i in {1..30}; do
  PHASE="$(kubectl -n "$NS_VIRT" get vmi fedora-nginx -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")"
  [[ "$PHASE" == "Running" ]] && break
  sleep 5
done
kubectl -n "$NS_VIRT" get vmi

echo "🔎 Pod backing the VM and its IP (for quick curl inside cluster):"
kubectl -n "$NS_VIRT" get pod -l kubevirt.io/domain=fedora-nginx -o wide || true
kubectl -n "$NS_VIRT" get svc fedora-nginx-svc -o wide || true

cat > cleanup.sh <<'CLEAN'
#!/usr/bin/env bash
set -e
echo "🧹 Cleaning up demo resources..."
NS_GITOPS="gitops-demo"
NS_VIRT="virt-demo"

kubectl -n "$NS_VIRT" delete -f "$WORKDIR/svc.yaml" --ignore-not-found || true
kubectl -n "$NS_VIRT" delete -f "$WORKDIR/virtualmachine.yaml" --ignore-not-found || true
oc delete project "$NS_VIRT" --ignore-not-found || true

kubectl -n "$NS_GITOPS" delete kustomization.kustomize.toolkit.fluxcd.io/podinfo-kustomize --ignore-not-found || true
kubectl -n "$NS_GITOPS" delete gitrepository.source.toolkit.fluxcd.io/podinfo-source --ignore-not-found || true
oc delete project "$NS_GITOPS" --ignore-not-found || true

# Uncomment to remove Arc connection:
# az connectedk8s delete -g "$RESOURCE_GROUP" -n "$ARC_CLUSTER_NAME" -y || true

echo "✅ Cleanup complete."
CLEAN
chmod +x cleanup.sh

echo ""
echo "✅ Demo setup complete."
echo "   - GitOps app namespace: $NS_GITOPS (Podinfo)"
echo "   - VM namespace: $NS_VIRT (Fedora VM with nginx)"
echo "   - Cleanup: ./cleanup.sh"
echo ""
echo "👉 Next: Inside the cluster, try: kubectl -n $NS_VIRT run curl --image=curlimages/curl --rm -it -- sh -c 'curl -s http://fedora-nginx-svc.$NS_VIRT.svc.cluster.local/'"

