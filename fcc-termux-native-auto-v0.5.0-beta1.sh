#!/data/data/com.termux/files/usr/bin/bash
# FCC Termux Native — instalador-orquestrador automático v0.5.0
# Escopo: Termux nativo Android ARM64. Não é instalador oficial do FCC.
set -Eeuo pipefail

PROJECT_VERSION="0.5.0-beta1"
FCC_VERSION="6.19.11"       # versão validada no aparelho de referência do projeto
PYTHON_REQUIRED="3.14.10"  # Requires-Python da versão FCC fixada
GRPCIO_VERSION="1.85.1"    # única correção de source-cache automatizada neste release
MODE="install"
LOG_FILE=""
WAKE_LOCK_ACTIVE=0

usage() {
  cat <<USAGE
FCC Termux Native v${PROJECT_VERSION}

Uso:
  bash fcc-termux-native-auto-v${PROJECT_VERSION}.sh [--install|--check|--help]

  --install  (padrão) instala somente dependências ausentes, compila/instala
             FCC ${FCC_VERSION}, executa diagnóstico e valida os comandos.
  --check    somente leitura: verifica ambiente e dependências sem instalar.
  --help     mostra esta ajuda.

Proteções:
  - exige Termux nativo ARM64; não aceita Ubuntu, PRoot ou root.
  - não substitui instalação FCC já existente.
  - não executa pkg upgrade e não limpa caches.
  - só adiciona ~/.local/bin ao arquivo de inicialização do shell após sucesso,
    com backup; não altera outras configurações.
  - correção grpcio só após assinatura conhecida, com backup e uma repetição.
  - não tenta corrigir erros desconhecidos.
USAGE
}

fail() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }
info() { printf '\n[%s] %s\n' "$1" "$2"; }

case "${1:---install}" in
  --install) MODE="install" ;;
  --check) MODE="check" ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; fail "Opção desconhecida: $1" ;;
esac
[[ "$#" -le 1 ]] || fail "Informe somente uma opção."

# Verificação deliberadamente restrita ao prefixo oficial usado na homologação.
[[ "${PREFIX:-}" == "/data/data/com.termux/files/usr" ]] \
  || fail "Termux oficial não detectado em PREFIX. Execute no Termux nativo (não use PRoot/Ubuntu)."
[[ "$(uname -o 2>/dev/null || true)" == "Android" ]] \
  || fail "O kernel não foi identificado como Android. Este instalador não roda em Linux/PRoot."
[[ "$(uname -m 2>/dev/null || true)" == "aarch64" ]] \
  || fail "Arquitetura não homologada: $(uname -m 2>/dev/null || echo desconhecida). Este release exige ARM64/aarch64."
[[ "$(id -u)" != "0" ]] || fail "Não execute como root. Use o usuário normal do Termux."
command -v pkg >/dev/null 2>&1 || fail "Comando pkg não encontrado; instalação Termux incompleta ou ambiente incorreto."

ORIGINAL_PATH="${PATH:-}"
export PATH="$PREFIX/bin:$HOME/.local/bin:$PATH"

# Registra o processo sem coletar nem enviar credenciais.
umask 077
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$HOME/fcc-native-${PROJECT_VERSION}-${STAMP}-$$.log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

on_unexpected_error() {
  local status="$1" line="$2" command_text="$3"
  trap - ERR
  printf '\nFALHA NÃO TRATADA (código %s), linha %s.\n' "$status" "$line" >&2
  printf 'Comando: %s\nLog para diagnóstico: %s\n' "$command_text" "$LOG_FILE" >&2
  exit "$status"
}
trap 'on_unexpected_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

cleanup() {
  if [[ "$WAKE_LOCK_ACTIVE" -eq 1 ]] && command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

printf '============================================================\n'
printf ' FCC TERMUX NATIVE — v%s\n' "$PROJECT_VERSION"
printf ' Modo: %s | FCC fixado: %s | Python: %s\n' "$MODE" "$FCC_VERSION" "$PYTHON_REQUIRED"
printf ' Arquitetura: %s | Android: %s\n' "$(uname -m)" "$(getprop ro.build.version.release 2>/dev/null || echo não identificado)"
printf ' Log: %s\n' "$LOG_FILE"
printf '============================================================\n'

find_python() {
  command -v python 2>/dev/null || command -v python3 2>/dev/null || true
}
find_uv() {
  command -v uv 2>/dev/null || { [[ -x "$HOME/.local/bin/uv" ]] && printf '%s\n' "$HOME/.local/bin/uv"; } || true
}
has_fcc_command() {
  command -v fcc-claude >/dev/null 2>&1 \
    || command -v fcc-server >/dev/null 2>&1 \
    || command -v fcc-doctor >/dev/null 2>&1
}
contains_fcc_tool() {
  grep -Eiq '(^|[[:space:]])free-claude-code([[:space:]]|$)' <<<"$1"
}

# Uma instalação existente nunca é atualizada/substituída automaticamente.
info "1/7" "Procurando uma instalação FCC existente..."
if has_fcc_command; then
  echo "FCC já instalado: encontrei ao menos um comando fcc-*."
  echo "Por segurança, não instalarei nem alterarei essa instalação."
  if command -v fcc-doctor >/dev/null 2>&1; then
    echo "Executando fcc-doctor para conferir a instalação existente:"
    fcc-doctor || fail "fcc-doctor apontou falha na instalação existente. Nenhuma alteração foi feita."
  fi
  echo "CHECK: instalação existente preservada."
  exit 0
fi

UV_BIN="$(find_uv)"
if [[ -n "$UV_BIN" ]]; then
  EXISTING_TOOLS="$("$UV_BIN" tool list 2>&1)" \
    || fail "Não foi possível consultar 'uv tool list'; não é seguro continuar."
  if contains_fcc_tool "$EXISTING_TOOLS"; then
    echo "$EXISTING_TOOLS"
    fail "free-claude-code já consta no UV. Não vou substituir nem reparar por cima."
  fi
fi

# Mapeia ferramentas para os pacotes oficiais Termux. Instala apenas grupos ausentes.
info "2/7" "Verificando dependências e preparando a lista do que falta..."
MISSING_PACKAGES=()
add_package_once() {
  local wanted="$1" item
  for item in "${MISSING_PACKAGES[@]:-}"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  MISSING_PACKAGES+=("$wanted")
}

PYTHON_BIN="$(find_python)"
[[ -n "$PYTHON_BIN" ]] || add_package_once python
[[ -n "$UV_BIN" ]] || add_package_once uv
BUILD_TOOLS_MISSING=0
for tool in clang make pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || BUILD_TOOLS_MISSING=1
done
[[ "$BUILD_TOOLS_MISSING" -eq 0 ]] || add_package_once build-essential
if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
  add_package_once rust
fi

if [[ "$MODE" == "check" ]]; then
  if ((${#MISSING_PACKAGES[@]})); then
    printf 'Dependências ausentes; modo --check não instala nada: %s\n' "${MISSING_PACKAGES[*]}"
    echo "Execute novamente sem --check para instalar apenas o que falta."
    exit 1
  fi
else
  if ((${#MISSING_PACKAGES[@]})); then
    printf 'Pacotes que serão instalados: %s\n' "${MISSING_PACKAGES[*]}"
    echo "Atualizando apenas os índices de pacotes (sem upgrade geral)..."
    pkg update -y
    echo "Instalando somente os pacotes ausentes..."
    pkg install -y "${MISSING_PACKAGES[@]}"
  else
    echo "Dependências de sistema já presentes; nenhuma instalação de pacote necessária."
  fi
fi

# Reavalia PATH depois do pkg install.
export PATH="$PREFIX/bin:$HOME/.local/bin:$PATH"
PYTHON_BIN="$(find_python)"
UV_BIN="$(find_uv)"
[[ -n "$PYTHON_BIN" ]] || fail "Python ausente mesmo após a tentativa de instalação do pacote python."
[[ -n "$UV_BIN" ]] || fail "uv ausente mesmo após a tentativa de instalação do pacote uv."
for tool in clang make pkg-config rustc cargo; do
  command -v "$tool" >/dev/null 2>&1 || fail "Dependência '$tool' continua ausente após a preparação."
done

info "3/7" "Validando versões e compiladores..."
PYTHON_VERSION="$("$PYTHON_BIN" --version 2>&1 | awk '{print $2}')"
[[ "$PYTHON_VERSION" == "$PYTHON_REQUIRED" ]] \
  || fail "Python encontrado: ${PYTHON_VERSION:-desconhecido}; esta versão FCC exige Python ${PYTHON_REQUIRED}. Não farei downgrade/upgrade automático do Python."
UV_VERSION="$("$UV_BIN" --version 2>&1 | head -n 1)"
CLANG_VERSION="$(clang --version 2>&1 | head -n 1)"
MAKE_VERSION="$(make --version 2>&1 | head -n 1)"
PKG_CONFIG_VERSION="$(pkg-config --version 2>&1 | head -n 1)"
RUSTC_VERSION="$(rustc --version 2>&1 | head -n 1)"
CARGO_VERSION="$(cargo --version 2>&1 | head -n 1)"
FREE_KB="$(df -Pk "$HOME" 2>/dev/null | awk 'END {print $4}')"
MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
if [[ "$FREE_KB" =~ ^[0-9]+$ ]] && ((FREE_KB < 4000000)); then
  echo "AVISO: espaço livre abaixo de 4 GB (${FREE_KB} KB). A compilação pode falhar por falta de armazenamento."
fi
if [[ "$MEM_KB" =~ ^[0-9]+$ ]] && ((MEM_KB < 2500000)); then
  echo "AVISO: RAM total abaixo de 2,5 GB (${MEM_KB} KB). A compilação poderá ser encerrada pelo Android por falta de memória."
fi
printf 'Python: %s (%s)\nUV: %s (%s)\nClang: %s\nMake: %s\npkg-config: %s\nRust: %s\nCargo: %s\n' \
  "$PYTHON_VERSION" "$PYTHON_BIN" "$UV_VERSION" "$UV_BIN" "$CLANG_VERSION" \
  "$MAKE_VERSION" "$PKG_CONFIG_VERSION" "$RUSTC_VERSION" "$CARGO_VERSION"

TMP_PROBE="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/fcc-native-probe.XXXXXX")" \
  || fail "Não foi possível criar pasta temporária de teste."
cleanup_probe() { rm -rf "$TMP_PROBE"; }
trap 'cleanup_probe; cleanup' EXIT
printf 'int main(void) { return 0; }\n' > "$TMP_PROBE/probe.c"
clang "$TMP_PROBE/probe.c" -o "$TMP_PROBE/probe-clang" \
  || fail "Clang não conseguiu compilar o teste C mínimo."
"$TMP_PROBE/probe-clang" || fail "O executável C de teste não iniciou."
printf 'fn main() {}\n' > "$TMP_PROBE/probe.rs"
rustc "$TMP_PROBE/probe.rs" -o "$TMP_PROBE/probe-rust" \
  || fail "Rust não conseguiu compilar o teste mínimo."
"$TMP_PROBE/probe-rust" || fail "O executável Rust de teste não iniciou."
"$PYTHON_BIN" -c 'import ssl, sys; assert sys.version.split()[0] == "3.14.10"; print("Python/SSL: OK")' \
  || fail "Teste de execução/importação do Python falhou."

# Perfil conservador para reduzir pressão de memória em aparelhos Android.
export UV_PYTHON_PREFERENCE="only-system"
export GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS="1"
export CARGO_BUILD_JOBS="1"
export MAKEFLAGS="-j1"
export CMAKE_BUILD_PARALLEL_LEVEL="1"
# Evita que maturin/puccinialin tente baixar uma toolchain rustup incompatível
# com o target Android quando o Rust nativo do Termux já está instalado.
export MATURIN_NO_INSTALL_RUST="1"

if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock && WAKE_LOCK_ACTIVE=1 || true
fi

if [[ "$MODE" == "check" ]]; then
  echo "CHECK concluído: dependências, Python e compiladores validados."
  echo "Nenhum pacote, cache, arquivo de configuração ou FCC foi alterado."
  exit 0
fi

info "4/7" "Confirmando novamente que o FCC não está instalado..."
TOOL_LIST="$("$UV_BIN" tool list 2>&1)" \
  || fail "Não foi possível consultar 'uv tool list'; instalação cancelada."
if contains_fcc_tool "$TOOL_LIST" || has_fcc_command; then
  fail "FCC apareceu durante a preparação. Instalação cancelada para preservar o estado atual."
fi

# Correção estrita para a falha grpcio/c-ares já reproduzida no projeto.
is_known_grpcio_cares_build_failure() {
  local file="$1"
  grep -Eiq 'grpcio[-_/ ]?1\.85\.1|grpcio[^[:cntrl:]]{0,120}1\.85\.1|1\.85\.1[^[:cntrl:]]{0,120}grpcio' "$file" || return 1
  grep -Eiq 'third_party/cares|ares_config\.h|GETSERVBYPORT_R_ARGS' "$file" || return 1
  grep -Eiq 'error: subprocess-exited-with-error|failed to build|build backend failed|compilation terminated|error: command .* failed|(^|[[:space:]])error:' "$file" || return 1
  return 0
}

apply_known_grpcio_patch() {
  local cache_dir android_header cares_dir target linux_header backup
  cache_dir="${UV_CACHE_DIR:-$("$UV_BIN" cache dir 2>/dev/null)}"
  [[ -n "$cache_dir" && -d "$cache_dir" ]] || fail "Cache UV não encontrado; não aplicarei patch fora do cache identificado."
  android_header="$(find "$cache_dir" -type f -path "*/pypi/grpcio/${GRPCIO_VERSION}/*/src/third_party/cares/config_android/ares_config.h" -print 2>/dev/null | sort | head -n 1)"
  [[ -n "$android_header" && -f "$android_header" ]] || fail "Cabeçalho Android do grpcio ${GRPCIO_VERSION} não foi localizado no cache UV."
  cares_dir="$(dirname "$(dirname "$android_header")")"
  target="$cares_dir/ares_config.h"
  linux_header="$cares_dir/config_linux/ares_config.h"
  [[ -f "$target" && -f "$linux_header" ]] || fail "Cabeçalhos de referência incompletos; nenhum arquivo foi alterado."
  if cmp -s "$target" "$android_header"; then
    echo "Cabeçalho principal já corresponde ao Android; patch desnecessário."
    return 0
  fi
  cmp -s "$target" "$linux_header" \
    || fail "Cabeçalho atual não corresponde exatamente à referência Linux; patch recusado."
  backup="${target}.backup-fcc-native-${STAMP}-$$"
  cp -p "$target" "$backup"
  cp "$android_header" "$target"
  cmp -s "$target" "$android_header" \
    || fail "Validação do patch falhou. Backup preservado em: $backup"
  echo "Patch conhecido aplicado; backup: $backup"
}

info "5/7" "Iniciando a instalação/compilação do FCC ${FCC_VERSION}..."
printf 'Configuração: UV_PYTHON_PREFERENCE=%s | GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS=%s | CARGO_BUILD_JOBS=%s | MATURIN_NO_INSTALL_RUST=%s\n' \
  "$UV_PYTHON_PREFERENCE" "$GRPC_PYTHON_BUILD_EXT_COMPILER_JOBS" "$CARGO_BUILD_JOBS" "$MATURIN_NO_INSTALL_RUST"
echo "A compilação pode consumir bastante bateria, memória e armazenamento. Não feche o Termux."

INSTALL_CMD=("$UV_BIN" tool install --refresh-package free-claude-code --python "$PYTHON_BIN" "free-claude-code==${FCC_VERSION}" -vv)
if "${INSTALL_CMD[@]}"; then
  INSTALL_STATUS=0
else
  INSTALL_STATUS=$?
fi

if [[ "$INSTALL_STATUS" -ne 0 ]]; then
  echo "Primeira tentativa falhou com código ${INSTALL_STATUS}. Conferindo se houve instalação parcial..."
  TOOL_LIST="$("$UV_BIN" tool list 2>&1)" \
    || fail "Falha da instalação e consulta UV indisponível. Não repetirei a instalação."
  if contains_fcc_tool "$TOOL_LIST" || has_fcc_command; then
    fail "Há sinais de instalação FCC parcial. Patch e nova tentativa foram bloqueados. Log: $LOG_FILE"
  fi
  if ! is_known_grpcio_cares_build_failure "$LOG_FILE"; then
    fail "O erro não corresponde à assinatura conhecida grpcio ${GRPCIO_VERSION}/c-ares. Nenhum patch foi aplicado e não haverá repetição. Log: $LOG_FILE"
  fi
  info "5b/7" "Erro conhecido grpcio/c-ares confirmado. Aplicando correção com backup..."
  apply_known_grpcio_patch
  TOOL_LIST="$("$UV_BIN" tool list 2>&1)" \
    || fail "Não foi possível revalidar UV depois do patch. Nova tentativa cancelada."
  if contains_fcc_tool "$TOOL_LIST" || has_fcc_command; then
    fail "FCC apareceu após o patch; nova tentativa cancelada."
  fi
  echo "Executando a única repetição permitida..."
  "${INSTALL_CMD[@]}" || fail "A única repetição também falhou. Não haverá outra tentativa automática. Log: $LOG_FILE"
fi

info "6/7" "Validando o registro UV e os comandos instalados..."
TOOL_LIST="$("$UV_BIN" tool list 2>&1)" \
  || fail "Instalação terminou, mas 'uv tool list' não pôde ser consultado."
echo "$TOOL_LIST"
contains_fcc_tool "$TOOL_LIST" \
  || fail "free-claude-code não apareceu em 'uv tool list'. Consulte o log: $LOG_FILE"
grep -Eiq "free-claude-code[[:space:]]+v?${FCC_VERSION}([[:space:]]|$)" <<<"$TOOL_LIST" \
  || fail "A versão registrada em UV não corresponde à versão fixada ${FCC_VERSION}."
for tool in fcc-server fcc-claude fcc-doctor; do
  command -v "$tool" >/dev/null 2>&1 || fail "Executável '$tool' não foi encontrado após a instalação."
  printf '%s: %s\n' "$tool" "$(command -v "$tool")"
done
SERVER_VERSION_OUTPUT="$(fcc-server --version 2>&1)" \
  || fail "fcc-server --version falhou; o servidor não passou na validação básica."
echo "fcc-server --version: $SERVER_VERSION_OUTPUT"
grep -Fq "$FCC_VERSION" <<<"$SERVER_VERSION_OUTPUT" \
  || fail "fcc-server não reportou a versão ${FCC_VERSION}; consulte o log."

info "7/7" "Executando fcc-doctor..."
DOCTOR_LOG="$HOME/fcc-doctor-${STAMP}-$$.log"
if ! fcc-doctor > "$DOCTOR_LOG" 2>&1; then
  cat "$DOCTOR_LOG"
  fail "fcc-doctor retornou erro. A instalação existe, mas não foi aprovada no diagnóstico. Log: $DOCTOR_LOG"
fi
cat "$DOCTOR_LOG"
# O doctor da versão homologada expõe errors: []. Se houver uma lista não vazia,
# falhamos; se o formato mudar, o exit code do próprio doctor continua registrado.
if ! "$PYTHON_BIN" - "$DOCTOR_LOG" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="replace")
m = re.search(r'"?errors"?\s*:\s*\[(.*?)\]', text, re.S)
if m and m.group(1).strip():
    print("fcc-doctor informou itens na lista errors.", file=sys.stderr)
    raise SystemExit(1)
PY
then
  fail "fcc-doctor encontrou erros. Preserve os logs para diagnóstico."
fi

# UV costuma expor os comandos das ferramentas em ~/.local/bin. Persiste apenas
# esse diretório no shell do usuário, com backup e bloco idempotente.
persist_uv_tool_path() {
  local rc_file shell_name marker backup
  local uv_bin_dir="$HOME/.local/bin"
  [[ -d "$uv_bin_dir" ]] || return 0
  case ":$ORIGINAL_PATH:" in
    *":$uv_bin_dir:"*)
      echo "PATH já contém $uv_bin_dir."
      return 0
      ;;
  esac
  shell_name="${SHELL##*/}"
  case "$shell_name" in
    zsh) rc_file="$HOME/.zshrc" ;;
    *) rc_file="$HOME/.bashrc" ;;
  esac
  marker="# >>> FCC Termux Native: UV tool PATH >>>"
  if ! grep -Fq "$marker" "$rc_file" 2>/dev/null; then
    if [[ -f "$rc_file" ]]; then
      backup="${rc_file}.backup-fcc-native-${STAMP}-$$"
      cp -p "$rc_file" "$backup"
      echo "Backup do shell: $backup"
    else
      : > "$rc_file"
      chmod 600 "$rc_file"
    fi
    cat >> "$rc_file" <<'PATH_BLOCK'

# >>> FCC Termux Native: UV tool PATH >>>
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< FCC Termux Native: UV tool PATH <<<
PATH_BLOCK
    echo "PATH persistido em $rc_file. Abra uma nova sessão do Termux para carregar a alteração."
  else
    echo "Bloco PATH do FCC Termux Native já existe em $rc_file."
  fi
}
persist_uv_tool_path

cat <<SUCCESS

============================================================
 INSTALAÇÃO CONCLUÍDA E VALIDAÇÃO APROVADA
============================================================
Projeto: ${PROJECT_VERSION}
FCC: ${FCC_VERSION}
Python: ${PYTHON_VERSION}
UV: ${UV_VERSION}
Clang: ${CLANG_VERSION}
Rust: ${RUSTC_VERSION}
Doctor: execução concluída sem erro reportado.
Log da instalação: ${LOG_FILE}
Log do diagnóstico: ${DOCTOR_LOG}

PARA INICIAR O FCC:
1) No Termux, execute: fcc-server
2) Mantenha essa sessão aberta e acesse: http://127.0.0.1:8082/admin
3) Abra uma nova sessão (para carregar o PATH) e execute: fcc-claude

Este projeto é comunitário e independente; não é um instalador oficial do FCC,
Anthropic/Claude Code, gRPC ou Termux.
============================================================
SUCCESS