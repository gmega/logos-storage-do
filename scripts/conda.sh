#!/usr/bin/env bash
# Source this file to activate the conda env holding Ansible:  source scripts/conda.sh
#
# Ansible lives in a dedicated conda env (never installed globally). The conda
# install location varies per machine (anaconda3/miniconda3/miniforge3/...), so
# probe the usual spots rather than hardcoding one.
#
# Env override:
#   CONDA_ENV   env name to activate  (default: logos-storage-do)

_conda_env="${CONDA_ENV:-logos-storage-do}"
_conda_sh=""
for _c in "${CONDA_EXE:+$(dirname "$(dirname "${CONDA_EXE}")")}" \
  "${HOME}/miniconda3" "${HOME}/anaconda3" "${HOME}/miniforge3" \
  "${HOME}/mambaforge" /opt/conda; do
  if [[ -n "${_c}" && -f "${_c}/etc/profile.d/conda.sh" ]]; then
    _conda_sh="${_c}/etc/profile.d/conda.sh"
    break
  fi
done

if [[ -z "${_conda_sh}" ]]; then
  echo "ERROR: no conda install found (looked for etc/profile.d/conda.sh under" \
    "\$CONDA_EXE, ~/miniconda3, ~/anaconda3, ~/miniforge3, ~/mambaforge, /opt/conda)." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${_conda_sh}"
conda activate "${_conda_env}"
unset _c _conda_sh _conda_env
