#!/usr/bin/env bash
set -euo pipefail

# Demo Script v002 — Hybrid GitOps + VM Demo for ARO
RESOURCE_GROUP="${RESOURCE_GROUP:-aro-demo-rg}"
LOCATION="${LOCATION:-eastus}"
ARC_CLUSTER_NAME="${ARC_CLUSTER_NAME:-aro-open-demo}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null || echo "")}"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/stefanprodan/podinfo}"
GIT_BRANCH="${GIT_BRANCH:-master}"
NS_GITOPS="gitops-demo"
NS_VIRT="virt-demo"

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
oc project >/dev/null

az config set extension.use_dynamic_install=yes_without_prompt
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null

if ! az connectedk8s show -g "$RESOURCE_GROUP" -n "$ARC_CLUSTER_NAME" >/dev/null 2>&1; then
  az connectedk8s connect --name "$ARC_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --distribution "openshift" --location "$LOCATION"
fi

echo "🔍 Checking if Flux is installed..."
if ! oc get csv -n openshift-operators | grep -qi flux; then
  echo "❌ Flux Operator not found. Install it from OperatorHub first."; exit 1;
fi

oc new-project "$NS_GITOPS" >/dev/null 2>&1 || true
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

kubectl apply -f "$WORKDIR/git-source.yaml"
kubectl apply -f "$WORKDIR/kustomization.yaml"

kubectl -n "$NS_GITOPS" wait --for=condition=available --timeout=180s deploy -l app.kubernetes.io/name=podinfo || true
kubectl -n "$NS_GITOPS" get pods

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
          interfaces:
            - name: default
              masquerade: {}
          disks:
            - name: containerdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
      networks:
        - name: default
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

kubectl -n "$NS_VIRT" apply -f "$WORKDIR/virtualmachine.yaml"
kubectl -n "$NS_VIRT" apply -f "$WORKDIR/svc.yaml"

for i in {1..30}; do
  PHASE="$(kubectl -n "$NS_VIRT" get vmi fedora-nginx -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")"
  [[ "$PHASE" == "Running" ]] && break
  sleep 5
done

oc expose svc podinfo -n "$NS_GITOPS" >/dev/null 2>&1 || true
oc expose svc fedora-nginx-svc -n "$NS_VIRT" >/dev/null 2>&1 || true

echo ""
echo "🔗 ROUTE URLs"
echo "--------------------------------------------"
oc get route -n "$NS_GITOPS" -o custom-columns='NAME:.metadata.name,URL:.spec.host'
oc get route -n "$NS_VIRT" -o custom-columns='NAME:.metadata.name,URL:.spec.host'
echo "--------------------------------------------"
echo ""
echo "✅ Podinfo (Flux app):     http://$(oc get route podinfo -n $NS_GITOPS -o jsonpath='{.spec.host}')"
echo "✅ Fedora VM (nginx):      http://$(oc get route fedora-nginx-svc -n $NS_VIRT -o jsonpath='{.spec.host}')"
echo ""
echo "👉 Open in browser to verify both applications are online!"
