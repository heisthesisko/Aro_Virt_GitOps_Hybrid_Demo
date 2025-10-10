#!/bin/bash
# -------------------------------------------
# Install OpenShift CLI (oc) and kubectl in Azure Cloud Shell (no sudo)
# -------------------------------------------

set -e

echo "🔧 Installing OpenShift CLI and kubectl in user space..."

# Define directories
BIN_DIR="$HOME/.local/bin"
TMPDIR=$(mktemp -d)
mkdir -p "$BIN_DIR"

# Download OpenShift CLI tarball (latest stable)
echo "⬇️ Downloading OpenShift client..."
curl -sL -o "$TMPDIR/openshift-client-linux.tar.gz" \
  https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz

# Extract oc and kubectl to ~/.local/bin
echo "📦 Extracting oc and kubectl..."
tar -xzf "$TMPDIR/openshift-client-linux.tar.gz" -C "$TMPDIR"
mv "$TMPDIR/oc" "$BIN_DIR/"
mv "$TMPDIR/kubectl" "$BIN_DIR/"

# Ensure ~/.local/bin is in PATH
if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
  echo 'export PATH=$HOME/.local/bin:$PATH' >> "$HOME/.bashrc"
  export PATH=$HOME/.local/bin:$PATH
fi

# Verify installation
echo "✅ Verifying installation..."
"$BIN_DIR/oc" version --client
"$BIN_DIR/kubectl" version --client

echo "🎉 Done! 'oc' and 'kubectl' are ready to use in Azure Cloud Shell."
