#!/usr/bin/env bash
set -euo pipefail
# Demo Script v003 (Auto) — Hybrid GitOps + VM Demo (multi-instance)
# Each run creates a unique timestamp suffix.

SUFFIX=$(date +%Y%m%d-%H%M)
RESOURCE_GROUP="aro-demo-rg"
LOCATION="eastus"
ARC_CLUSTER_NAME="aro-open-demo-$SUFFIX"
NS_GITOPS="gitops-demo-$SUFFIX"
NS_VIRT="virt-demo-$SUFFIX"
GIT_REPO_URL="https://github.com/stefanprodan/podinfo"
GIT_BRANCH="master"

echo "🆕 Starting demo instance with suffix: $SUFFIX"

command -v az >/dev/null || { echo "az not found"; exit 1; }
command -v oc >/dev/null || { echo "oc not found"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }

az account show >/dev/null || az login >/dev/null
az account set --subscription "$(az account show --query id -o tsv)"

az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null
if ! az connectedk8s show -g "$RESOURCE_GROUP" -n "$ARC_CLUSTER_NAME" >/dev/null 2>&1; then
  az connectedk8s connect --name "$ARC_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --distribution "openshift" --location "$LOCATION"
fi

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
echo "✅ Demo instance created with suffix: $SUFFIX"
echo "🔗 Podinfo URL:  http://$(oc get route podinfo -n $NS_GITOPS -o jsonpath='{.spec.host}')"
echo "🔗 Fedora VM URL: http://$(oc get route fedora-nginx-svc -n $NS_VIRT -o jsonpath='{.spec.host}')"
echo ""
echo "👉 To delete this instance later: ./cleanup.sh $SUFFIX"
