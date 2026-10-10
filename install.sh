#!/usr/bin/env bash
# ============================================================================
#  luatools-moon — one-shot installer
# ============================================================================
#  Installs the full stack in a single command:
#
#    curl -fsSL https://raw.githubusercontent.com/swwayps/luatools-moon/main/install.sh | bash
#
#  Pipeline:
#    1. Pre-flight checks (not-root, x86_64, internet, NATIVE Steam).
#    2. Runtime dependencies (jq, curl, tar, unzip).
#    3. slsteam-moon   — download latest release, extract, run setup.sh install.
#    4. Lumen          — download latest release into ~/.local/share/Lumen.
#    5. This plugin    — download latest release into ~/.local/share/Lumen/luatools.
#
#  Bilingual (English / Português) based on the system locale.
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Command-line options (parsed by parse_args; see main)
# ----------------------------------------------------------------------------
# --noplugin : install only the runtime stack (slsteam-moon + Lumen) and skip
#              the LuaTools plugin. CloudRedirect is still offered (its prompt
#              defaults to "no"). Invoke as: curl ... | bash -s -- --noplugin
OPT_NOPLUGIN=0
OPT_HELP=0
OPT_BAD_ARG=""
OPT_SLS_CHANNEL="stable"
OPT_PLUGIN_CHANNEL="stable"
OPT_LUMEN_CHANNEL="stable"

# ----------------------------------------------------------------------------
# Repositories / release sources
# ----------------------------------------------------------------------------
SLS_REPO="swwayps/slsteam-moon"
SLS_ASSET_PREFIX="slsteam-moon-linux"          # asset is slsteam-moon-linux-<ver>.zip
SLS_BETA_PATH="dist/slsteam-moon-linux.zip"
# Lumen line: pick the newest release whose asset is the Lumen wrapper build
# (named slsteam-moon-linux-<ver>-lumen.zip). Convention-based, so publishing a
# new version (e.g. v2.5-lumen) needs no installer edit.
SLS_ASSET_GLOB="^${SLS_ASSET_PREFIX}-.*-lumen\\.zip$"

PLUGIN_REPO="swwayps/luatools-moon"
PLUGIN_ASSET="luatools-linux.zip"
PLUGIN_BETA_PATH="dist/luatools-linux.zip"
PLUGIN_NAME="luatools"                          # plugin.json "name"

LUMEN_REPO="swwayps/lumen"
LUMEN_ASSET="lumen-linux.zip"
LUMEN_BETA_PATH="dist/lumen-linux.zip"
LUMEN_DIR="$HOME/.local/share/Lumen"            # binary + lua/ + luatools/

# Stable release fallback. The manifest is small and mutable; every archive URL
# inside it is pinned to the mirror commit that introduced those exact bytes.
RELEASE_MIRROR_MANIFEST="https://cdn.jsdelivr.net/gh/swwayps/jsdelivr@main/manifest.json"

# CloudRedirect hook (the patched 32-bit cloud_redirect.so) lives in its own
# repo now; we fetch the prebuilt hook straight from its raw branch.
CR_MOON_REPO="swwayps/cloudredirect-moon"

# CloudRedirect (optional) — redirects Steam Cloud for added games to the
# user's own Google Drive / OneDrive / R2 / S3 / local folder. We deploy a
# patched 32-bit hook plus its CLI from cloudredirect-moon and load the hook via
# Steam wrapper's LD_PRELOAD. Provider sign-in lives in Lumen Settings → Cloud
# Saves (the Lumen backend runs the OAuth flow and writes the hook's config
# directly), so the main line needs no flatpak login app. The flatpak helpers
# below are retained for the millennium fallback branch only.
#
# The branch follows upstream v2.6.x while retaining the Linux attachment and
# runtime-safety fixes still needed by this stack. Both artifacts are built for
# an old-enough glibc to load in the Steam runtime.
CR_MOON_RAW_BASE="https://raw.githubusercontent.com/${CR_MOON_REPO}/master"
CR_SO_URL="${CR_MOON_RAW_BASE}/cloud_redirect.so"
CR_CLI_URL="${CR_MOON_RAW_BASE}/cloud_redirect_cli"
CR_REPO="Selectively11/CloudRedirect"
CR_FLATPAK_APP_ID="org.cloudredirect.CloudRedirect"
CR_DIR="$HOME/.local/share/CloudRedirect"
CR_SO_PATH="$CR_DIR/cloud_redirect.so"
CR_CLI_PATH="$CR_DIR/cloud_redirect_cli"
CR_KDE_RUNTIME="org.kde.Platform//6.10"

# ============================================================================
# Pretty output — "moonlit night" palette, matching slsteam-moon's setup.sh.
# Degrades to plain text on dumb / non-TTY terminals.
# ============================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
	if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
		HAS_256=1
	elif [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ]; then
		HAS_256=1
	else
		HAS_256=0
	fi

	BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
	if [ "$HAS_256" = 1 ]; then
		MOON=$'\033[38;5;153m'; NIGHT=$'\033[38;5;75m'; HALO=$'\033[38;5;231m'
		MUTED=$'\033[38;5;110m'; GREEN=$'\033[38;5;114m'; YELLOW=$'\033[38;5;221m'
		RED=$'\033[38;5;203m'
	else
		MOON=$'\033[1;34m'; NIGHT=$'\033[0;36m'; HALO=$'\033[1;37m'
		MUTED=$'\033[0;34m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
		RED=$'\033[0;31m'
	fi
else
	BOLD=""; DIM=""; NC=""
	MOON=""; NIGHT=""; HALO=""; MUTED=""
	GREEN=""; YELLOW=""; RED=""
fi

# ============================================================================
# Localization. L "<english>" "<português>" picks the string for the locale.
# ============================================================================
detect_language() {
	local l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
	case "$l" in
		pt*|*_BR*|*_PT*) LANG_IS_PT=1 ;;
		*)               LANG_IS_PT=0 ;;
	esac
}

L() { if [ "${LANG_IS_PT:-0}" = 1 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

log_info()    { echo -e "${NIGHT}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }
log_step()    { echo -e "${MOON}•${NC} $1"; }

fail() { log_error "$1"; exit 1; }

print_banner() {
	echo ""
	echo -e "${MOON}${BOLD}"
	echo "┌─────────────────────────────────────────────────────────┐"
	printf "│            ${HALO}${BOLD}◯${NC}${MOON}${BOLD}  slsteammoon · LuaTools installer          │\n"
	echo "└─────────────────────────────────────────────────────────┘"
	echo -e "${NC}"
}

print_section() {
	echo ""
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
	echo -e "${NIGHT}${BOLD}❯ $1${NC}"
	echo -e "${NIGHT}─────────────────────────────────────────────────────────${NC}"
}

# Ask a yes/no question and return 0 for yes, 1 for no. Works even when the
# installer runs as `curl ... | bash`: stdin is the pipe, so the prompt is
# written to and read from the controlling terminal (/dev/tty), same trick as
# flatpak_tty. $1 = English prompt, $2 = Português prompt, $3 = default answer
# ("y" or "n", defaults to "y"). With no controlling terminal (CI / truly
# non-interactive) it returns the default instead of blocking forever.
prompt_yes_no() {
	local q_en="$1" q_pt="$2" def="${3:-y}" prompt hint ans
	prompt="$(L "$q_en" "$q_pt")"
	if [ "$def" = "y" ]; then
		hint="$(L "[Y/n]" "[S/n]")"
	else
		hint="$(L "[y/N]" "[s/N]")"
	fi

	# No usable terminal → don't hang; honour the default.
	if ! { [ -e /dev/tty ] && { : >/dev/tty; } 2>/dev/null; }; then
		[ "$def" = "y" ]
		return
	fi

	while true; do
		printf '%s %s ' "$prompt" "$hint" >/dev/tty
		IFS= read -r ans </dev/tty || ans=""
		ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
		case "$ans" in
			"")       [ "$def" = "y" ]; return ;;
			y*|s*)    return 0 ;;
			n*)       return 1 ;;
			*) echo "$(L "Please answer y (yes) or n (no)." \
			            "Responda s (sim) ou n (não).")" >/dev/tty ;;
		esac
	done
}

# ── Deferred/optional prompts (Deck on-screen-keyboard friendly) ────────────
# On SteamOS / Bazzite and derivatives the on-screen keyboard needs Steam
# RUNNING to type into a terminal. But main() stops Steam early — before the
# CloudRedirect / Game Mode yes/no prompts — so a Deck user with no physical
# keyboard couldn't answer them. On those systems we ask up front, while Steam
# is still open (preask_prompts, called before stop_steam), and cache the
# answers here; the install steps reuse them via resolve_yesno instead of
# prompting after Steam is gone. Desktop (mutable) installs are unaffected and
# keep prompting inline. The question strings live here so the pre-ask and the
# inline sites can't drift apart.
Q_CLOUD_EN="Do you want Steam Cloud saves to work for your games? This installs CloudRedirect, which syncs to Google Drive, OneDrive, R2, S3 or a custom folder. Say no if you don't need cloud saves."
Q_CLOUD_PT="Você quer que os saves da Steam Cloud funcionem nos seus jogos? Isso instala o CloudRedirect, com Google Drive, OneDrive, R2, S3 ou uma pasta personalizada. Responda não se você não precisa de cloud saves."
Q_GAMEMODE_EN="Enable the plugin in Game Mode too? This changes how Steam is launched in Gaming Mode (reversible by the uninstaller)."
Q_GAMEMODE_PT="Ativar o plugin também no Game Mode? Isso altera como a Steam é iniciada no modo Gaming (reversível pelo desinstalador)."

# Cached answers (empty = not asked yet). Populated by preask_prompts.
PREASK_CLOUD=""
PREASK_GAMEMODE=""

# resolve_yesno CACHE_VAR "q_en" "q_pt" def -> 0 (yes) / 1 (no).
# Uses a previously cached y/n answer (by variable name) if present; otherwise
# prompts now and stores the answer so a later call is consistent.
resolve_yesno() {
	local -n __cache="$1"
	local q_en="$2" q_pt="$3" def="$4"
	case "$__cache" in
		y) return 0 ;;
		n) return 1 ;;
	esac
	if prompt_yes_no "$q_en" "$q_pt" "$def"; then __cache="y"; return 0; fi
	__cache="n"; return 1
}

# Ask the optional yes/no questions BEFORE Steam is stopped, on immutable/Deck-
# class systems only (SteamOS, Bazzite, ...), where the on-screen keyboard needs
# Steam running. No-op on mutable desktops and on non-interactive runs (those
# keep the inline prompts / defaults). Answers are cached for the install steps.
preask_prompts() {
	is_immutable_distro || return 0
	{ [ -e /dev/tty ] && { : >/dev/tty; } 2>/dev/null; } || return 0

	print_section "$(L "A couple of questions (answer now, before Steam closes)" \
	                   "Algumas perguntas (responda agora, antes de a Steam fechar)")"
	log_info "$(L "On Steam Deck / SteamOS the on-screen keyboard needs Steam open, so we ask these before stopping it." \
	             "No Steam Deck / SteamOS o teclado virtual precisa da Steam aberta, então perguntamos isto antes de fechá-la.")"

	# Game Mode question only when a gamescope session exists on this host.
	if has_gamescope_session; then
		resolve_yesno PREASK_GAMEMODE "$Q_GAMEMODE_EN" "$Q_GAMEMODE_PT" "n" || true
	fi
	# Cloud-save question only when the hook isn't deployed yet. An existing
	# install is kept current silently, so asking again would be noise.
	if ! cloudredirect_installed; then
		resolve_yesno PREASK_CLOUD "$Q_CLOUD_EN" "$Q_CLOUD_PT" "n" || true
	fi
}

# Mutable-system launcher privilege preflight. This is deliberately best-effort:
# user-local desktop coverage remains usable when sudo is unavailable or denied.
export SLSM_SUDO_PRIMED="${SLSM_SUDO_PRIMED:-0}"
export SLSM_SUDO_DENIED="${SLSM_SUDO_DENIED:-0}"
preask_launcher_sudo() {
	is_immutable_distro && return 0
	[ "$(id -u)" -ne 0 ] || return 0
	command -v sudo >/dev/null 2>&1 || {
		log_info "$(L "No sudo available; user-local .desktop coverage remains the fallback." \
		             "Sudo não disponível; a cobertura .desktop local do usuário continua como fallback.")"
		return 0
	}

	local tty="${SLSM_SUDO_TTY:-/dev/tty}"
	if ! [ -e "$tty" ] || ! { : > "$tty"; } 2>/dev/null; then
		log_info "$(L "No controlling terminal; user-local .desktop coverage remains the fallback." \
		             "Sem terminal de controle; a cobertura .desktop local do usuário continua como fallback.")"
		return 0
	fi

	if sudo -n true >/dev/null 2>&1; then
		SLSM_SUDO_PRIMED=1
		return 0
	fi

	# Only this credential-requesting function emits the password hint. The
	# package/dependency path retains its own ensure_sudo behavior later.
	sudo_hint
	if sudo -v <"$tty" >"$tty" 2>&1; then
		SLSM_SUDO_PRIMED=1
		SLSM_SUDO_DENIED=0
		log_info "$(L "Administrator access primed for launcher coverage." \
		             "Acesso de administrador preparado para a cobertura do launcher.")"
	else
		SLSM_SUDO_DENIED=1
		log_warn "$(L "Administrator access was not granted; user-local .desktop coverage remains the fallback." \
		             "O acesso de administrador não foi concedido; a cobertura .desktop local do usuário continua como fallback.")"
	fi
	return 0
}

# Compatibility entry point for older/internal callers. The installer itself
# uses the explicit launcher-policy name above.
preask_sudo() {
	preask_launcher_sudo "$@"
}

# ============================================================================
# Distro detection
# ============================================================================
# Path to the os-release file. Overridable so the detection helpers can be
# unit-tested against synthetic fixtures (scripts/test-distro-detect.sh).
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

get_distro_family() {
	if [ -f "$OS_RELEASE_FILE" ]; then
		# shellcheck disable=SC1090
		. "$OS_RELEASE_FILE"
		if [ "${ID:-}" = "ubuntu" ] || [ "${ID:-}" = "debian" ] || [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
			echo "debian"
		elif [ "${ID:-}" = "fedora" ] || [ "${ID:-}" = "rhel" ] || [ "${ID:-}" = "centos" ] || [[ "${ID_LIKE:-}" =~ (fedora|rhel) ]]; then
			echo "fedora"
		elif [ "${ID:-}" = "arch" ] || [[ "${ID_LIKE:-}" =~ arch ]]; then
			echo "arch"
		elif [[ "${ID:-}" =~ opensuse ]] || [[ "${ID_LIKE:-}" =~ opensuse ]]; then
			echo "opensuse"
		else
			echo "unknown"
		fi
	else
		echo "unknown"
	fi
}

# Echo the lowercased distro ID (e.g. bazzite, steamos, ubuntu) for messaging
# and immutable-OS detection. "unknown" when os-release is unavailable.
get_distro_id() {
	if [ -f "$OS_RELEASE_FILE" ]; then
		# Read in a subshell so the sourced vars don't leak to the caller.
		(
			# shellcheck disable=SC1090
			. "$OS_RELEASE_FILE" >/dev/null 2>&1
			printf '%s' "${ID:-unknown}"
		) | tr '[:upper:]' '[:lower:]'
	else
		printf 'unknown'
	fi
}

# True on immutable / atomic systems (Bazzite, SteamOS, Fedora Atomic, ublue,
# ...) where the root (/usr) is read-only and the package manager must NOT be
# used to install dependencies: rpm-ostree needs a reboot, and SteamOS's
# `steamos-readonly disable` + keyring re-init is fragile and wiped on update.
# We never probe /usr writability — the installer runs non-root, so /usr is
# unwritable on EVERY distro and that would false-positive everywhere.
is_immutable_distro() {
	local id like
	id="$(get_distro_id)"
	case "$id" in
		bazzite|steamos|steamdeck|holoiso|\
		silverblue|kinoite|sericea|onyx|\
		bluefin|aurora|ucore)
			return 0 ;;
	esac

	# Fedora Atomic variants advertise themselves via VARIANT_ID even when ID
	# is plain "fedora" (e.g. ID=fedora VARIANT_ID=silverblue).
	if [ -f "$OS_RELEASE_FILE" ]; then
		like="$(
			# shellcheck disable=SC1090
			. "$OS_RELEASE_FILE" >/dev/null 2>&1
			printf '%s' "${VARIANT_ID:-}"
		)"
		case "$like" in
			silverblue|kinoite|sericea|onyx|*atomic*) return 0 ;;
		esac
	fi

	# Image-based / atomic tooling present -> treat as immutable.
	if command -v rpm-ostree >/dev/null 2>&1 || command -v steamos-readonly >/dev/null 2>&1; then
		return 0
	fi

	# Last resort: a read-only root mount (ostree deployments mount / ro).
	if command -v findmnt >/dev/null 2>&1; then
		case ",$(findmnt -no OPTIONS / 2>/dev/null)," in
			*,ro,*) return 0 ;;
		esac
	fi

	return 1
}

# ----------------------------------------------------------------------------
# Game Mode (gamescope session) detection — distro-agnostic
# ----------------------------------------------------------------------------
# Deck/handheld images boot a gamescope "Game Mode" where Steam is launched by a
# session wrapper (NOT a .desktop), so our LD_AUDIT + Lumen never run unless we
# re-point that wrapper. The wrapper layer comes from ChimeraOS's session repos;
# Bazzite/ChimeraOS ship it as "gamescope-session-plus", older setups as
# "gamescope-session". We NEVER hardcode a name: we discover whichever flavour
# is installed so the same logic adapts across Bazzite / SteamOS / similars.
#
# Overridable so the logic can be unit-tested against synthetic fixtures.
GAMESCOPE_SHARE_DIRS="${GAMESCOPE_SHARE_DIRS:-/usr/share /etc}"

# Echo the installed gamescope-session config base name (the dir under
# /usr/share or /etc that holds sessions.d/steam), or "" when none is present.
gamescope_session_base() {
	local root base
	for root in $GAMESCOPE_SHARE_DIRS; do
		for base in gamescope-session-plus gamescope-session; do
			if [ -f "$root/$base/sessions.d/steam" ] \
			   || [ -d "$root/$base/sessions.d" ]; then
				printf '%s' "$base"
				return 0
			fi
		done
	done
	printf ''
}

# Echo the gamescope client-config names ($1 = config base) that lead to Steam,
# newest-discovered last, "steam" always first.
#
# WHY this is not just "steam": the session is instantiated PER CLIENT
# (gamescope-session-plus@<client>.service) and sources ONLY sessions.d/<client>
# — the system copy, then /etc, then ours. Bazzite 44 moved its Game Mode
# autologin from the "steam" client to "ogui-steam" (OpenGamepadUI quick-access
# on top of Steam). "ogui-steam" sources the SYSTEM "steam" config but never our
# user override for it, so a hook written only for "steam" is dead weight and
# Game Mode comes up silently un-injected. Covering every installed Steam-ish
# client keeps us correct whichever one the image (or the user) boots, now and
# after the next rename.
gamescope_session_clients() {
	local base="$1" root f name
	{
		printf 'steam\n'
		for root in $GAMESCOPE_SHARE_DIRS; do
			for f in "$root/$base/sessions.d/"*; do
				[ -f "$f" ] || continue
				name="${f##*/}"
				# Skip package-manager and our own leftovers.
				case "$name" in
					*.bak.*|*.rpmnew|*.rpmsave|*.dpkg-*|*~) continue ;;
				esac
				# Only clients that actually launch Steam.
				grep -qi steam "$f" 2>/dev/null || continue
				printf '%s\n' "$name"
			done
		done
	} | awk '!seen[$0]++'
}

# True when a Game Mode hook of ours is already installed (either mechanism).
# Used to treat a re-run as "already opted in" so the hook set can be refreshed
# after a distro upgrade without re-asking an invasive question.
gamemode_hook_present() {
	local cfg="${XDG_CONFIG_HOME:-$HOME/.config}" base f
	for base in gamescope-session-plus gamescope-session; do
		for f in "$cfg/$base/sessions.d/"*; do
			[ -f "$f" ] || continue
			grep -qF "$GAMEMODE_HOOK_SENTINEL" "$f" 2>/dev/null && return 0
		done
	done
	f="$cfg/systemd/user/steam-launcher.service.d/slsteammoon.conf"
	[ -f "$f" ] && grep -qF "$GAMEMODE_HOOK_SENTINEL" "$f" 2>/dev/null && return 0
	return 1
}

# True when this host can launch Steam in a gamescope Game Mode session.
has_gamescope_session() {
	[ -n "$(gamescope_session_base)" ] && return 0
	has_steamos_gamescope && return 0
	command -v gamescope-session-plus >/dev/null 2>&1 && return 0
	command -v gamescope-session >/dev/null 2>&1 && return 0
	return 1
}

# SteamOS launches Game Mode Steam from a systemd *user* unit
# (steam-launcher.service -> /usr/lib/steamos/steam-launcher -> `exec steam`),
# NOT from a gamescope-session/sessions.d/steam override.  Detect + hook that
# separately.  Dirs/launcher path overridable so the logic is unit-testable
# against synthetic fixtures.
STEAMOS_SESSION_UNIT_DIRS="${STEAMOS_SESSION_UNIT_DIRS:-/usr/lib/systemd/user /etc/systemd/user /run/systemd/user}"
STEAMOS_STEAM_LAUNCHER="${STEAMOS_STEAM_LAUNCHER:-/usr/lib/steamos/steam-launcher}"

# Echo the path to the SteamOS Game Mode steam unit, or "" when none is present.
steamos_steam_launcher_unit() {
	local d
	for d in $STEAMOS_SESSION_UNIT_DIRS; do
		if [ -f "$d/steam-launcher.service" ]; then
			printf '%s' "$d/steam-launcher.service"
			return 0
		
