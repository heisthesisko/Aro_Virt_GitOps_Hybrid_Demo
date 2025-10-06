# ATO 2025 — ARO Virtualization + Arc Hybrid Demo

Files included:

- `ato-2025-aro-virt-hybrid-demo.md` — conference-ready talk track with Mermaid diagrams.
- `demo.sh` — one-shot setup script (Arc connect, Flux GitOps, Fedora VM on OpenShift Virtualization).
- `cleanup.sh` — removes demo resources from the cluster.

## Quick start

```bash
chmod +x demo.sh cleanup.sh
./demo.sh
# ...present your talk...
./cleanup.sh
```

> Prereqs: ARO/OpenShift with OpenShift Virtualization enabled, `oc`, `kubectl`, `az` CLIs, and Azure subscription access.
