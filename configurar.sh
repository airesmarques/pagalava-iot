#!/bin/bash
# Abre o gestor de ambientes IoT (TUI) usando o ambiente virtual do projeto.
# Uso: ./configurar.sh [--listar]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}" || exit 1

PYTHON="${SCRIPT_DIR}/.venv/bin/python"
if [ ! -x "${PYTHON}" ]; then
    echo "Python do ambiente virtual não encontrado em ${PYTHON}" >&2
    echo "Execute primeiro o script de instalação, ou crie o .venv." >&2
    exit 1
fi

exec "${PYTHON}" "${SCRIPT_DIR}/configurar.py" "$@"
