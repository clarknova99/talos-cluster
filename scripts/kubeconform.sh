#!/usr/bin/env bash
set -o errexit
set -o pipefail

KUBERNETES_DIR=$1

[[ -z "${KUBERNETES_DIR}" ]] && echo "Kubernetes location not specified" && exit 1

kustomize_args=("--load-restrictor=LoadRestrictionsNone")
kustomize_config="kustomization.yaml"
kubeconform_args=(
    "-strict"
    "-ignore-missing-schemas"
    "-skip"
    "Secret"
    "-skip"
    "Gateway"
    "-schema-location"
    "default"
    "-schema-location"
    "https://kubernetes-schemas.pages.dev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
    "-verbose"
)

echo "=== Validating standalone manifests in ${KUBERNETES_DIR}/flux ==="
find "${KUBERNETES_DIR}/flux" -maxdepth 1 -type f -name '*.yaml' -print0 | while IFS= read -r -d $'\0' file;
  do
    kubeconform "${kubeconform_args[@]}" "${file}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
      exit 1
    fi
done

echo "=== Validating kustomizations in ${KUBERNETES_DIR}/flux ==="
find "${KUBERNETES_DIR}/flux" -type f -name $kustomize_config -print0 | while IFS= read -r -d $'\0' file;
  do
    # Skip the vars directory as it contains SOPS-encrypted secrets
    if [[ "${file}" == *"/vars/"* ]]; then
      echo "=== Skipping SOPS-encrypted vars directory: ${file/%$kustomize_config} ==="
      continue
    fi
    echo "=== Validating kustomizations in ${file/%$kustomize_config} ==="
    kustomize build "${file/%$kustomize_config}" "${kustomize_args[@]}" | \
      kubeconform "${kubeconform_args[@]}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
      exit 1
    fi
done

echo "=== Validating kustomizations in ${KUBERNETES_DIR}/apps ==="
find "${KUBERNETES_DIR}/apps" -type f -name $kustomize_config -print0 | while IFS= read -r -d $'\0' file;
  do
    # Check if this kustomization directory contains any SOPS-encrypted files
    kustomization_dir="${file/%$kustomize_config}"
    if find "${kustomization_dir}" -name "*.sops.yaml" -type f | grep -q .; then
      echo "=== Skipping kustomization with SOPS-encrypted files: ${kustomization_dir} ==="
      continue
    fi
    echo "=== Validating kustomizations in ${kustomization_dir} ==="
    kustomize build "${kustomization_dir}" "${kustomize_args[@]}" | \
      kubeconform "${kubeconform_args[@]}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
      exit 1
    fi
done
