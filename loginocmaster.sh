# Set these to your cluster
RG="ATO2025DEMOCENTRAL"
CLUSTER="ato-central-aro-virt"

# Get API URL and kubeadmin password from Azure
API_URL=$(az aro show -g "$RG" -n "$CLUSTER" --query apiserverProfile.url -o tsv)
KUBEADMIN_PW=$(az aro list-credentials -g "$RG" -n "$CLUSTER" --query kubeadminPassword -o tsv)

# Log in
oc login "$API_URL" -u kubeadmin -p "$KUBEADMIN_PW"