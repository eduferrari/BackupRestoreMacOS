#!/usr/bin/env bash
#
# macbackup.sh — Backup e restore de arquivos, apps e configurações do macOS
#
# Cria snapshots incrementais no HD externo (rsync --link-dest + hard links):
# cada snapshot parece um backup completo, mas só ocupa espaço com o que mudou.
#
# COMANDOS
#   init       Cria ~/.macbackup.conf (volume, pastas, dotfiles, retenção)
#   backup     Cria um novo snapshot no HD externo
#   restore    Restaura um snapshot (apps, dotfiles, configurações, arquivos)
#   list       Lista os snapshots existentes no HD
#
# OPÇÕES
#   -v, --volume PATH     Volume do HD externo       (padrão: VOLUME do config)
#   -s, --snapshot NOME   Snapshot a restaurar        (padrão: latest)
#   -H, --host NOME       Mac de origem no HD         (padrão: nome deste Mac)
#   -o, --only LISTA      Seções separadas por vírgula
#                           backup:  inventory,dotfiles,library,files,apps
#                           restore: apps,dotfiles,library,files
#   -n, --dry-run         Simula, sem gravar nada
#   -y, --yes             Não pergunta nada (assume "sim")
#       --with-apps       (backup) Copia também os .app de /Applications
#   -h, --help            Mostra esta ajuda
#
# EXEMPLOS
#   ./macbackup.sh init
#   ./macbackup.sh backup -v /Volumes/BackupMac
#   ./macbackup.sh backup --only dotfiles,library --dry-run
#   ./macbackup.sh list
#   ./macbackup.sh restore
#   ./macbackup.sh restore -H MacBook-Pro -s 2026-09-26_132600 --only apps,dotfiles
#
# REQUISITOS
#   - Terminal com "Acesso Total ao Disco" (Ajustes do Sistema → Privacidade e Segurança)
#   - HD em APFS (de preferência "APFS (Criptografado)")
#   - Recomendado: brew install rsync  (rsync 3.x preserva atributos estendidos)

set -Eeuo pipefail

readonly VERSION="1.0.0"
readonly CONFIG_FILE="${MACBACKUP_CONFIG:-$HOME/.macbackup.conf}"
TS="$(date +%Y-%m-%d_%H%M%S)"
readonly TS

# ------------------------------------------------------------------------------
# Configuração padrão — fonte única; `init` grava isto em ~/.macbackup.conf
# ------------------------------------------------------------------------------
default_config() {
  cat <<'EOF'
# ~/.macbackup.conf — configuração do macbackup.sh (é um arquivo bash)

# Volume do HD externo (veja em /Volumes)
VOLUME="/Volumes/BackupMac"

# Pasta raiz dos backups dentro do HD
BACKUP_DIR_NAME="MacBackups"

# Quantos snapshots manter (0 = manter todos)
KEEP_SNAPSHOTS=7

# Copiar também os .app de /Applications (útil p/ apps fora do Homebrew/App Store)
BACKUP_APP_BUNDLES=false

# Pastas do usuário (relativas a ~). As que não existirem são ignoradas.
USER_DIRS=(
  Documents
  Desktop
  Downloads
  Pictures
  Movies
  Music
  Projects
  Workspace
  Developer
  source
  repos
)

# Dotfiles e configs de ferramentas (relativos a ~)
DOTFILES=(
  .zshrc .zprofile .zshenv .zsh_history
  .bashrc .bash_profile .profile
  .p10k.zsh .oh-my-zsh/custom
  .gitconfig .gitignore_global
  .ssh .gnupg
  .config
  .local/bin
  .aws .azure .kube
  .docker/config.json
  .nuget/NuGet/NuGet.Config
  .microsoft/usersecrets
  .npmrc
  .vimrc .tmux.conf
)

# Itens de ~/Library (configurações de apps)
LIBRARY_ITEMS=(
  "Preferences"
  "Fonts"
  "Services"
  "LaunchAgents"
  "Keyboard Layouts"
  "Application Support/JetBrains"
  "Application Support/Code/User"
  "Application Support/Cursor/User"
  "Application Support/Azure Data Studio/User"
  "Application Support/DBeaverData"
  "Application Support/iTerm2"
  "Application Support/Sublime Text"
  "Developer/Xcode/UserData"
)

# Exclusões extras no padrão do rsync (ex.: "*.iso" "VirtualBox VMs/")
EXTRA_EXCLUDES=()
EOF
}

eval "$(default_config)"
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# ------------------------------------------------------------------------------
# Estado global
# ------------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
WITH_APPS=0
ONLY=""
SNAPSHOT="latest"
HOST="$( (scutil --get ComputerName 2>/dev/null || hostname -s) | sed 's/[^A-Za-z0-9._-]/-/g')"
WARNINGS=0
ERRORS=0
LOG=/dev/null
EXCLUDES_FILE=""
RSYNC_BIN=""
RSYNC_OPTS=()
ROOT=""
SNAP=""
PREV=""
SNAPDIR=""
SAFETY=""

if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1;34m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi

# ------------------------------------------------------------------------------
# Utilitários
# ------------------------------------------------------------------------------
_emit() {
  local color="$1" tag="$2"; shift 2
  printf '%s%s%s %s\n' "$color" "$tag" "$C_0" "$*"
  printf '[%s] %s %s\n' "$(date +%H:%M:%S)" "$tag" "$*" >>"$LOG"
}
step() { echo; _emit "$C_B" "==>" "$@"; }
info() { _emit "" "   " "$@"; }
ok()   { _emit "$C_G" " ✓ " "$@"; }
warn() { _emit "$C_Y" " ! " "$@"; WARNINGS=$((WARNINGS + 1)); }
fail() { _emit "$C_R" " ✗ " "$@"; ERRORS=$((ERRORS + 1)); }
die()  { _emit "$C_R" " ✗ " "$@"; exit 1; }

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

ask() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local a=""
  read -r -p "$1 [s/N] " a </dev/tty || return 1
  [[ "$a" =~ ^[sSyY] ]]
}

want() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }

# Executa um comando, ou apenas mostra o que faria em --dry-run
do_run() {
  if [ "$DRY_RUN" = 1 ]; then info "[simulação] $*"; return 0; fi
  "$@"
}

on_error() {
  local line="$1"
  printf '%s ✗ Erro inesperado na linha %s. Log: %s%s\n' "$C_R" "$line" "$LOG" "$C_0" >&2
  if [ -n "$SNAP" ] && [[ "$SNAP" == *.inprogress ]]; then
    printf '   O snapshot incompleto será descartado no próximo backup.\n' >&2
  fi
}
trap 'on_error $LINENO' ERR

setup_rsync() {
  local c v
  RSYNC_BIN=""
  for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync "$(command -v rsync || true)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then RSYNC_BIN="$c"; break; fi
  done
  [ -n "$RSYNC_BIN" ] || die "rsync não encontrado."
  v="$("$RSYNC_BIN" --version 2>/dev/null | head -n1 || true)"
  if [[ "$v" == *"version 3."* ]]; then
    RSYNC_OPTS=(-aHX --human-readable)
  else
    RSYNC_OPTS=(-a --human-readable)
    if [ "${1:-}" != quiet ]; then
      warn "rsync do sistema em uso (sem atributos estendidos). Recomendado: brew install rsync"
    fi
  fi
}

# rsync com tratamento de códigos: 23/24 = arquivos sem permissão ou que sumiram
run_rsync() {
  local rc=0 extra=()
  [ "$DRY_RUN" = 1 ] && extra+=(-n)
  [ -n "$EXCLUDES_FILE" ] && extra+=(--exclude-from="$EXCLUDES_FILE")
  "$RSYNC_BIN" "${RSYNC_OPTS[@]}" ${extra[@]+"${extra[@]}"} "$@" >>"$LOG" 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    23|24) warn "Cópia parcial (rsync $rc) em ${*: -2:1} — alguns arquivos sem permissão/alterados. Veja o log." ;;
    *) fail "rsync falhou (código $rc): ${*: -2:1} → ${*: -1}" ;;
  esac
  return 0
}

# Snapshot mais recente concluído (symlink "latest" ou arquivo LATEST em exFAT)
resolve_latest() {
  if [ -d "$ROOT/latest" ]; then
    (cd "$ROOT/latest" && pwd -P)
  elif [ -f "$ROOT/LATEST" ] && [ -d "$ROOT/$(cat "$ROOT/LATEST")" ]; then
    echo "$ROOT/$(cat "$ROOT/LATEST")"
  fi
}

print_summary() {
  echo
  if [ "$ERRORS" -gt 0 ]; then
    printf '%sConcluído com %d erro(s) e %d aviso(s).%s Log: %s\n' "$C_R" "$ERRORS" "$WARNINGS" "$C_0" "$LOG"
  elif [ "$WARNINGS" -gt 0 ]; then
    printf '%sConcluído com %d aviso(s).%s Log: %s\n' "$C_Y" "$WARNINGS" "$C_0" "$LOG"
  else
    printf '%sConcluído sem avisos.%s Log: %s\n' "$C_G" "$C_0" "$LOG"
  fi
}

# ------------------------------------------------------------------------------
# BACKUP
# ------------------------------------------------------------------------------
check_volume_for_backup() {
  [ -d "$VOLUME" ] || die "Volume não encontrado: $VOLUME — o HD está conectado? Use -v /Volumes/NOME"
  [ -w "$VOLUME" ] || die "Sem permissão de escrita em $VOLUME"

  local dinfo fs
  dinfo="$(diskutil info "$VOLUME" 2>/dev/null || true)"
  fs="$(printf '%s\n' "$dinfo" | awk -F': *' '/Type \(Bundle\)/{print $2; exit}')"
  case "$fs" in
    apfs|hfs) ok "Volume $VOLUME ($fs)" ;;
    *)
      warn "Sistema de arquivos '${fs:-desconhecido}': sem hard links/permissões — cada snapshot será uma cópia completa."
      ask "Continuar mesmo assim?" || exit 1
      ;;
  esac
  if [[ "$dinfo" =~ FileVault:[[:space:]]+Yes ]]; then
    ok "Volume criptografado"
  else
    warn "Volume NÃO criptografado — o backup inclui chaves SSH, credenciais de cloud e user-secrets."
  fi
  info "Espaço livre: $(df -h "$VOLUME" | awk 'NR==2{print $4}')"
}

check_full_disk_access() {
  if [ -d "$HOME/Library/Safari" ] && ! ls "$HOME/Library/Safari" >/dev/null 2>&1; then
    warn "O Terminal NÃO tem 'Acesso Total ao Disco' — parte de ~/Library será ignorada."
    info "Ajustes do Sistema → Privacidade e Segurança → Acesso Total ao Disco → habilite seu terminal."
    ask "Continuar mesmo assim?" || exit 1
  fi
}

write_excludes() {
  local common="$SNAP/.excludes-common" lib="$SNAP/.excludes-library" e
  cat >"$common" <<'EOF'
.DS_Store
.Trash/
.Spotlight-V100/
.fseventsd/
.TemporaryItems/
*.tmp
node_modules/
.venv/
__pycache__/
bin/Debug/
bin/Release/
obj/
.vs/
TestResults/
.gradle/
EOF
  for e in ${EXTRA_EXCLUDES[@]+"${EXTRA_EXCLUDES[@]}"}; do echo "$e" >>"$common"; done

  # Caches só são excluídos de ~/Library e dotfiles (nunca das pastas de projeto)
  cp "$common" "$lib"
  cat >>"$lib" <<'EOF'
Caches/
Cache/
CachedData/
GPUCache/
Code Cache/
Service Worker/
logs/
workspaceStorage/
EOF
  EXCL_COMMON="$common"
  EXCL_LIBRARY="$lib"
}

# sync_path <origem absoluta> <destino relativo ao snapshot>
sync_path() {
  local src="$1" rel="$2" dst="$SNAP/$2" link=()
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    if [ -n "$PREV" ] && [ -d "$PREV/$rel" ]; then link=(--link-dest="$PREV/$rel"); fi
    run_rsync ${link[@]+"${link[@]}"} "$src/" "$dst/"
  else
    mkdir -p "$(dirname "$dst")"
    if [ -n "$PREV" ] && [ -d "$(dirname "$PREV/$rel")" ]; then link=(--link-dest="$(dirname "$PREV/$rel")"); fi
    run_rsync ${link[@]+"${link[@]}"} "$src" "$(dirname "$dst")/"
  fi
}

backup_inventory() {
  step "Inventário de apps e ferramentas"
  local inv="$SNAP/inventory" c n
  mkdir -p "$inv"
  { sw_vers; echo "Arch: $(uname -m)"; echo "Host: $HOST"; echo "Snapshot: $TS"; } >"$inv/system.txt" 2>/dev/null || true

  if command -v brew >/dev/null 2>&1; then
    if brew bundle dump --file="$inv/Brewfile" --force --describe >>"$LOG" 2>&1; then
      n="$(grep -cE '^(tap|brew|cask|mas|vscode) ' "$inv/Brewfile" || true)"
      ok "Brewfile: $n itens (fórmulas, casks, App Store, extensões)"
    else
      fail "Falha ao gerar o Brewfile"
    fi
  else
    warn "Homebrew não instalado — apps não serão inventariados via Brewfile"
  fi

  if command -v mas >/dev/null 2>&1; then
    mas list >"$inv/mas.txt" 2>>"$LOG" || true
    ok "App Store: $(wc -l <"$inv/mas.txt" | tr -d ' ') apps"
  else
    info "mas não instalado (brew install mas) — apps da App Store só aparecerão na lista geral"
  fi

  {
    ls -1 /Applications 2>/dev/null || true
    if [ -d "$HOME/Applications" ]; then ls -1 "$HOME/Applications" | sed 's#^#~/Applications/#'; fi
  } >"$inv/applications.txt"
  ok "Lista de /Applications: $(wc -l <"$inv/applications.txt" | tr -d ' ') itens"

  if command -v dotnet >/dev/null 2>&1; then
    dotnet --list-sdks >"$inv/dotnet-sdks.txt" 2>/dev/null || true
    dotnet tool list -g >"$inv/dotnet-tools.txt" 2>/dev/null || true
    ok ".NET: SDKs e global tools"
  fi
  if command -v npm >/dev/null 2>&1; then
    { npm ls -g --depth=0 -p 2>/dev/null || true; } | sed 1d | sed 's#.*/node_modules/##' \
      | grep -vE '^(npm|corepack)$' >"$inv/npm-global.txt" || true
    ok "npm: pacotes globais"
  fi
  for c in code cursor; do
    if command -v "$c" >/dev/null 2>&1; then
      "$c" --list-extensions >"$inv/$c-extensions.txt" 2>/dev/null || true
      ok "$c: $(wc -l <"$inv/$c-extensions.txt" | tr -d ' ') extensões"
    fi
  done
  if crontab -l >"$inv/crontab.txt" 2>/dev/null; then ok "crontab"; else rm -f "$inv/crontab.txt"; fi
}

backup_list_section() { # <título> <base de origem> <dir no snapshot> <manifest> <excludes> <itens...>
  local title="$1" base="$2" dir="$3" manifest="$4" excl="$5" item n=0
  shift 5
  step "$title"
  EXCLUDES_FILE="$excl"
  : >"$SNAP/$manifest"
  for item in "$@"; do
    [ -e "$base/$item" ] || continue
    sync_path "$base/$item" "$dir/$item"
    echo "$item" >>"$SNAP/$manifest"
    info "$item"
    n=$((n + 1))
  done
  EXCLUDES_FILE=""
  ok "$n item(ns)"
}

backup_app_bundles() {
  step "Pacotes .app de /Applications"
  EXCLUDES_FILE=""   # nunca excluir nada de dentro de um .app
  sync_path "/Applications" "apps/Applications"
  ok "Apps copiados"
}

cmd_backup() {
  [ "$WITH_APPS" = 1 ] && BACKUP_APP_BUNDLES=true

  check_volume_for_backup
  check_full_disk_access
  setup_rsync

  ROOT="$VOLUME/$BACKUP_DIR_NAME/$HOST"
  [ "$DRY_RUN" = 1 ] || mkdir -p "$ROOT"

  local s
  for s in "$ROOT"/*.inprogress; do
    [ -d "$s" ] || continue
    warn "Descartando snapshot incompleto: $(basename "$s")"
    do_run rm -rf "$s"
  done

  PREV="$(resolve_latest || true)"
  if [ "$DRY_RUN" = 1 ]; then
    SNAP="$(mktemp -d "${TMPDIR:-/tmp}/macbackup.XXXXXX")"
    mkdir -p "$HOME/Library/Logs"
    LOG="$HOME/Library/Logs/macbackup-dryrun-$TS.log"
  else
    SNAP="$ROOT/$TS.inprogress"
    mkdir -p "$SNAP"
    LOG="$SNAP/backup.log"
  fi
  : >"$LOG"

  # Impede o Mac de dormir enquanto o script roda
  caffeinate -dimsu -w $$ >/dev/null 2>&1 &

  write_excludes
  step "Backup de '$HOST' → $ROOT/$TS"
  if [ -n "$PREV" ]; then info "Incremental sobre: $(basename "$PREV")"; else info "Primeiro backup (completo)"; fi
  [ "$DRY_RUN" = 1 ] && warn "Modo simulação: nada será gravado no HD"

  if want inventory; then backup_inventory; fi
  if want dotfiles; then
    backup_list_section "Dotfiles e configs de ferramentas (~)" "$HOME" home home.manifest \
      "$EXCL_LIBRARY" ${DOTFILES[@]+"${DOTFILES[@]}"}
  fi
  if want library; then
    backup_list_section "Configurações de apps (~/Library)" "$HOME/Library" library library.manifest \
      "$EXCL_LIBRARY" ${LIBRARY_ITEMS[@]+"${LIBRARY_ITEMS[@]}"}
  fi
  if want files; then
    backup_list_section "Arquivos do usuário" "$HOME" files files.manifest \
      "$EXCL_COMMON" ${USER_DIRS[@]+"${USER_DIRS[@]}"}
  fi
  if want apps && [ "$BACKUP_APP_BUNDLES" = true ]; then backup_app_bundles; fi

  if [ "$DRY_RUN" = 1 ]; then
    rm -rf "$SNAP"
    ok "Simulação concluída — veja no log o que seria copiado."
  else
    date '+%Y-%m-%d %H:%M:%S' >"$SNAP/.completed"
    mv "$SNAP" "$ROOT/$TS"
    SNAP="$ROOT/$TS"
    LOG="$SNAP/backup.log"
    ln -sfn "$TS" "$ROOT/latest" 2>/dev/null || echo "$TS" >"$ROOT/LATEST"
    prune_snapshots
    ok "Snapshot $TS concluído"
    info "Espaço livre no HD: $(df -h "$VOLUME" | awk 'NR==2{print $4}')"
  fi
  print_summary
}

prune_snapshots() {
  [ "$KEEP_SNAPSHOTS" -gt 0 ] || return 0
  local snaps=() s n=0 i del
  # O glob já retorna em ordem alfabética = cronológica (AAAA-MM-DD_HHMMSS)
  for s in "$ROOT"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]; do
    [ -d "$s" ] && [ ! -L "$s" ] || continue
    snaps+=("$(basename "$s")"); n=$((n + 1))
  done
  del=$((n - KEEP_SNAPSHOTS))
  [ "$del" -gt 0 ] || return 0
  step "Retenção: removendo $del snapshot(s) antigo(s) (mantendo $KEEP_SNAPSHOTS)"
  for ((i = 0; i < del; i++)); do
    rm -rf "${ROOT:?}/${snaps[$i]}"
    info "Removido ${snaps[$i]}"
  done
}

# ------------------------------------------------------------------------------
# RESTORE
# ------------------------------------------------------------------------------
resolve_root() {
  local base="$VOLUME/$BACKUP_DIR_NAME" h n=0 hosts=""
  [ -d "$base" ] || die "Nenhum backup encontrado em $base"
  if [ -d "$base/$HOST" ]; then ROOT="$base/$HOST"; return 0; fi
  for h in "$base"/*/; do
    [ -d "$h" ] || continue
    h="$(basename "$h")"; hosts="$hosts $h"; n=$((n + 1))
  done
  if [ "$n" -eq 1 ]; then
    HOST="${hosts# }"; ROOT="$base/$HOST"
    info "Usando backup do Mac: $HOST"
    return 0
  fi
  [ "$n" -gt 0 ] || die "Nenhum backup encontrado em $base"
  die "Backup de '$HOST' não encontrado. Use --host com um destes:$hosts"
}

# Copia o que vai ser sobrescrito para ~/.macbackup-safety/<timestamp>
safety_copy() {
  local src="$1" rel="$2"
  [ -e "$src" ] || return 0
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$(dirname "$SAFETY/$rel")"
  ditto "$src" "$SAFETY/$rel" 2>>"$LOG" || warn "Não foi possível salvar cópia de segurança de $src"
}

# restore_path <origem no snapshot> <destino> [opções extras do rsync]
restore_path() {
  local src="$1" dst="$2"
  shift 2
  if [ ! -e "$src" ]; then warn "Não encontrado no snapshot: $src"; return 0; fi
  if [ -d "$src" ]; then
    [ "$DRY_RUN" = 1 ] || mkdir -p "$dst"
    run_rsync "$@" "$src/" "$dst/"
  else
    [ "$DRY_RUN" = 1 ] || mkdir -p "$(dirname "$dst")"
    run_rsync "$@" "$src" "$(dirname "$dst")/"
  fi
}

ensure_brew() {
  local p
  command -v brew >/dev/null 2>&1 && return 0
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$p" ]; then eval "$("$p" shellenv)"; return 0; fi
  done
  ask "Homebrew não está instalado. Instalar agora?" || return 1
  do_run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$p" ]; then eval "$("$p" shellenv)"; return 0; fi
  done
  [ "$DRY_RUN" = 1 ]
}

restore_apps() {
  step "Apps e ferramentas"
  local inv="$SNAPDIR/inventory" t e c a n=0 missing=""

  if [ -f "$inv/Brewfile" ]; then
    if ensure_brew; then
      if grep -q '^mas ' "$inv/Brewfile"; then
        info "O Brewfile tem apps da App Store: faça login na App Store antes de continuar."
        ask "Já está logado na App Store?" || warn "Apps da App Store podem falhar — rode o restore de apps de novo depois."
      fi
      if [ "$DRY_RUN" = 1 ]; then
        brew bundle check --file="$inv/Brewfile" --verbose || true
      else
        info "Instalando itens do Brewfile (pode demorar e pedir sua senha)..."
        if brew bundle install --file="$inv/Brewfile" --no-upgrade 2>&1 | tee -a "$LOG"; then
          ok "Brewfile aplicado"
        else
          fail "Alguns itens do Brewfile falharam. Tente de novo: brew bundle --file=\"$inv/Brewfile\""
        fi
      fi
      setup_rsync quiet   # passa a usar o rsync do Homebrew, se instalado agora
    else
      warn "Sem Homebrew — pulando o Brewfile"
    fi
  fi

  if [ -d "$SNAPDIR/apps/Applications" ]; then
    info "Copiando .app do backup que ainda não existem em /Applications..."
    restore_path "$SNAPDIR/apps/Applications" "/Applications" --ignore-existing
    ok "Pacotes .app restaurados"
  fi

  if [ -f "$inv/dotnet-tools.txt" ] && command -v dotnet >/dev/null 2>&1; then
    while IFS= read -r t <&3; do
      [ -n "$t" ] || continue
      if do_run dotnet tool install -g "$t" </dev/null >>"$LOG" 2>&1; then ok "dotnet tool: $t"
      else info "dotnet tool $t: já instalado ou falhou (veja o log)"; fi
    done 3< <(awk 'NR>2 && NF {print $1}' "$inv/dotnet-tools.txt")
  fi

  if [ -s "$inv/npm-global.txt" ] && command -v npm >/dev/null 2>&1; then
    while IFS= read -r t <&3; do
      [ -n "$t" ] || continue
      if do_run npm install -g "$t" </dev/null >>"$LOG" 2>&1; then ok "npm: $t"; else fail "npm: $t"; fi
    done 3<"$inv/npm-global.txt"
  fi

  for c in code cursor; do
    [ -s "$inv/$c-extensions.txt" ] || continue
    command -v "$c" >/dev/null 2>&1 || { warn "$c não está no PATH — extensões não instaladas"; continue; }
    while IFS= read -r e <&3; do
      [ -n "$e" ] || continue
      do_run "$c" --install-extension "$e" --force </dev/null >>"$LOG" 2>&1 || fail "$c: $e"
    done 3<"$inv/$c-extensions.txt"
    ok "Extensões do $c"
  done

  if [ -s "$inv/crontab.txt" ] && ask "Restaurar o crontab (substitui o atual)?"; then
    do_run crontab "$inv/crontab.txt" && ok "crontab restaurado"
  fi

  # Apps que ainda faltam (instalados fora do Homebrew/App Store)
  if [ -f "$inv/applications.txt" ]; then
    while IFS= read -r a <&3; do
      [ -n "$a" ] || continue
      # shellcheck disable=SC2088  # "~/" aqui é texto literal da lista, não caminho
      case "$a" in
        "~/Applications/"*) [ -e "$HOME/Applications/${a#\~/Applications/}" ] && continue ;;
        *) [ -e "/Applications/$a" ] && continue ;;
      esac
      missing="$missing$a"$'\n'; n=$((n + 1))
    done 3<"$inv/applications.txt"
    if [ "$n" -gt 0 ]; then
      warn "$n app(s) ainda não instalado(s) — instale manualmente:"
      printf '%s' "$missing" | sed 's/^/      • /'
      if [ "$DRY_RUN" != 1 ]; then
        printf '%s' "$missing" >"$HOME/Desktop/apps-para-instalar.txt"
        info "Lista salva em ~/Desktop/apps-para-instalar.txt"
      fi
    else
      ok "Todos os apps da lista estão instalados"
    fi
  fi
}

restore_manifest_section() { # <título> <dir no snapshot> <base destino> <manifest> <modo>
  local title="$1" dir="$2" base="$3" manifest="$4" mode="$5" item
  step "$title"
  if [ ! -f "$SNAPDIR/$manifest" ]; then warn "Seção não existe neste snapshot"; return 0; fi
  while IFS= read -r item <&3; do
    [ -n "$item" ] || continue
    if [ "$mode" = library ] && [ "$item" = "Preferences" ]; then
      ask "Restaurar ~/Library/Preferences inteiro? (recomendado só em Mac novo/limpo)" || { info "Preferences ignorado"; continue; }
    fi
    if [ "$mode" = files ]; then
      restore_path "$SNAPDIR/$dir/$item" "$base/$item" --update
    else
      safety_copy "$base/$item" "$dir/$item"
      restore_path "$SNAPDIR/$dir/$item" "$base/$item"
    fi
    info "$item"
  done 3<"$SNAPDIR/$manifest"
  ok "$title: concluído"
}

fix_permissions() {
  [ "$DRY_RUN" = 1 ] && return 0
  if [ -d "$HOME/.ssh" ]; then
    chmod 700 "$HOME/.ssh"
    find "$HOME/.ssh" -type f ! -name '*.pub' ! -name 'known_hosts*' -exec chmod 600 {} +
  fi
  if [ -d "$HOME/.gnupg" ]; then chmod -R go-rwx "$HOME/.gnupg"; fi
  return 0
}

cmd_restore() {
  [ -d "$VOLUME" ] || die "Volume não encontrado: $VOLUME — o HD está conectado? Use -v /Volumes/NOME"
  resolve_root
  if [ "$SNAPSHOT" = latest ]; then SNAPDIR="$(resolve_latest || true)"; else SNAPDIR="$ROOT/$SNAPSHOT"; fi
  if [ -z "$SNAPDIR" ] || [ ! -f "$SNAPDIR/.completed" ]; then
    die "Snapshot inválido ou incompleto: ${SNAPDIR:-latest} (use o comando list)"
  fi

  mkdir -p "$HOME/Library/Logs"
  LOG="$HOME/Library/Logs/macbackup-restore-$TS.log"
  : >"$LOG"
  SAFETY="$HOME/.macbackup-safety/$TS"
  setup_rsync
  caffeinate -dimsu -w $$ >/dev/null 2>&1 &

  step "Restore de '$HOST' — snapshot $(basename "$SNAPDIR")"
  if [ -f "$SNAPDIR/inventory/system.txt" ]; then
    info "Origem: $(awk -F':[ \t]*' '/ProductVersion/{v=$2} /Arch/{a=$2} END{print "macOS " v " (" a ")"}' "$SNAPDIR/inventory/system.txt")"
  fi
  info "Destino: macOS $(sw_vers -productVersion 2>/dev/null || echo '?') ($(uname -m))"
  [ "$DRY_RUN" = 1 ] && warn "Modo simulação: nada será alterado"
  info "Arquivos sobrescritos de dotfiles/configurações são salvos antes em ~/.macbackup-safety/$TS"
  warn "Feche todos os apps (exceto o Terminal) antes de restaurar configurações."
  ask "Iniciar o restore?" || exit 0

  if want apps; then restore_apps; fi
  if want dotfiles; then
    restore_manifest_section "Dotfiles e configs de ferramentas" home "$HOME" home.manifest dotfiles
    fix_permissions
  fi
  if want library; then
    restore_manifest_section "Configurações de apps (~/Library)" library "$HOME/Library" library.manifest library
    if [ "$DRY_RUN" != 1 ]; then killall cfprefsd 2>/dev/null || true; fi
    info "Faça logout/login (ou reinicie) para aplicar todas as preferências."
  fi
  if want files; then
    restore_manifest_section "Arquivos do usuário" files "$HOME" files.manifest files
  fi

  print_summary
  if [ -d "$SAFETY" ]; then info "Cópias de segurança do que foi sobrescrito: $SAFETY"; fi
}

# ------------------------------------------------------------------------------
# LIST / INIT
# ------------------------------------------------------------------------------
cmd_list() {
  local base="$VOLUME/$BACKUP_DIR_NAME" h s name latest st osv mark
  [ -d "$base" ] || die "Nenhum backup encontrado em $base"
  for h in "$base"/*/; do
    [ -d "$h" ] || continue
    ROOT="${h%/}"
    latest="$(resolve_latest || true)"; latest="$(basename "${latest:-none}")"
    printf '\n%s%s%s\n' "$C_B" "$(basename "$ROOT")" "$C_0"
    for s in "$ROOT"/*; do
      if [ ! -d "$s" ] || [ -L "$s" ]; then continue; fi
      name="$(basename "$s")"
      st="ok"; [ -f "$s/.completed" ] || st="INCOMPLETO"
      osv=""
      if [ -f "$s/inventory/system.txt" ]; then
        osv="$(awk -F':[ \t]*' '/ProductVersion/{print "macOS " $2}' "$s/inventory/system.txt")"
      fi
      mark=""; [ "$name" = "$latest" ] && mark="  ← latest"
      printf '  %-28s %-11s %s%s\n' "$name" "$st" "$osv" "$mark"
    done
  done
  echo
  info "Espaço livre no HD: $(df -h "$VOLUME" | awk 'NR==2{print $4}')"
}

cmd_init() {
  if [ -f "$CONFIG_FILE" ] && ! ask "$CONFIG_FILE já existe. Sobrescrever?"; then exit 0; fi
  default_config >"$CONFIG_FILE"
  ok "Configuração criada em $CONFIG_FILE — ajuste VOLUME e as listas antes do primeiro backup."
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  [ $# -gt 0 ] && shift

  while [ $# -gt 0 ]; do
    case "$1" in
      -v|--volume)   VOLUME="${2:?informe o volume}"; shift 2 ;;
      -s|--snapshot) SNAPSHOT="${2:?informe o snapshot}"; shift 2 ;;
      -H|--host)     HOST="${2:?informe o host}"; shift 2 ;;
      -o|--only)     ONLY="${2:?informe as seções}"; shift 2 ;;
      -n|--dry-run)  DRY_RUN=1; shift ;;
      -y|--yes)      ASSUME_YES=1; shift ;;
      --with-apps)   WITH_APPS=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) die "Opção desconhecida: $1 (use --help)" ;;
    esac
  done
  VOLUME="${VOLUME%/}"

  if [ "$(uname -s)" != Darwin ] && [ "${MACBACKUP_ALLOW_NON_DARWIN:-0}" != 1 ]; then
    die "Este script é para macOS."
  fi

  case "$cmd" in
    backup)  cmd_backup ;;
    restore) cmd_restore ;;
    list)    cmd_list ;;
    init)    cmd_init ;;
    version|--version) echo "macbackup $VERSION" ;;
    help|-h|--help) usage ;;
    *) die "Comando desconhecido: $cmd (use --help)" ;;
  esac
}

main "$@"
