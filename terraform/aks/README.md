# AKS static validation

This configuration models AKS Standard with Entra-backed Azure RBAC and Azure CNI Overlay with Cilium. The explicit node pool makes the comparison reproducible. The Free cluster tier describes the control plane SKU. Compute would incur charges if provisioned.

Run without Azure credentials from the repository root.

```bash
terraform -chdir=terraform/aks fmt -check
terraform -chdir=terraform/aks init -backend=false
terraform -chdir=terraform/aks validate
```
