#!/usr/bin/env bash
# super-board one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/EricTechPro/super-board/main/get.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/EricTechPro/super-board/main/get.sh | bash -s -- --protect-main
#
# Options (everything else that starts with "-" goes straight to install.sh):
#   --target <dir>        project to install into (default: the current folder)
#   --ref <tag|branch>    which version to fetch (default: the latest release)
#   --no-helper-skills    skip `npx skills@latest add mattpocock/skills`
#   -h, --help            show this help
# Passed through to install.sh: --no-hooks, --protect-main.
#
# Environment:
#   SUPER_BOARD_REF       same as --ref
#   SUPER_BOARD_REPO      GitHub owner/repo to fetch from (default EricTechPro/super-board)
#   SUPER_BOARD_TARBALL   exact tarball URL to fetch instead (file:// works; used by tests)
#
# Written for bash 3.2 (stock macOS). The whole script lives in main(), called on
# the last line, so a download cut off halfway through runs nothing.

set -euo pipefail

say()  { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die()  { printf '❌ %s\n' "$*" >&2; exit "${2:-1}"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() { sed -n '2,19p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//' || true; }

# Matt Pocock's skills count as present when the project's skills-lock.json
# lists them, or two of their skills already sit in a skills folder Claude reads.
helper_skills_present() {
  local t="$1" d
  if [ -f "$t/skills-lock.json" ] && grep -q 'mattpocock/skills' "$t/skills-lock.json" 2>/dev/null; then
    return 0
  fi
  for d in "$t/.claude/skills" "${HOME:-/nonexistent}/.claude/skills"; do
    if [ -f "$d/grilling/SKILL.md" ] && [ -f "$d/tdd/SKILL.md" ]; then return 0; fi
  done
  return 1
}

main() {
  local target="" ref="${SUPER_BOARD_REF:-}" helpers=1
  local repo="${SUPER_BOARD_REPO:-EricTechPro/super-board}"
  local pass=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --target) [ $# -ge 2 ] || die "--target needs a folder" 64; target="$2"; shift 2 ;;
      --target=*) target="${1#--target=}"; shift ;;
      --ref) [ $# -ge 2 ] || die "--ref needs a tag or branch name" 64; ref="$2"; shift 2 ;;
      --ref=*) ref="${1#--ref=}"; shift ;;
      --no-helper-skills) helpers=0; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) pass+=("$1"); shift ;;
      *) [ -z "$target" ] || die "two target folders given: '$target' and '$1'" 64; target="$1"; shift ;;
    esac
  done
  target="${target:-$PWD}"

  # --- safety -----------------------------------------------------------
  if [ "$(id -u)" -eq 0 ]; then
    die "please don't run this as root (or with sudo). Run it as your normal user, inside your project folder." 1
  fi
  [ -d "$target" ] || die "the target '$target' is not a folder. Create it first, or pass --target <an existing folder>." 64
  target="$(cd "$target" && pwd)"

  say "🧩 super-board installer"
  say "   target: $target"

  # --- prerequisites ----------------------------------------------------
  local fetch=""
  if have curl && have tar; then fetch="tar"
  elif have git; then fetch="git"
  else die "I need either curl + tar, or git, to download super-board. Install one of those and run this again." 69
  fi
  have python3 || die "python3 is missing. super-board's installer and scripts use it. Install Python 3 (https://www.python.org/downloads/) and run this again." 69

  # One grouped line: what is here ✓, what is not ✗ (onboard's 🔍 Checks installs it).
  local later="" ok="" t
  for t in curl tar git python3 gh jq node; do
    case "$t" in
      curl|tar) [ "$fetch" = "tar" ] || continue ;;
      git) [ "$fetch" = "git" ] || continue ;;
    esac
    if have "$t" && { [ "$t" != node ] || have npx; }; then ok="${ok:+$ok · }$t"; else later="$later $t"; fi
  done
  say "🔍 checking what you need"
  if [ -n "$later" ]; then
    say "   ✓ $ok   ✗$later (🔍 Checks in onboard installs them)"
  else
    say "   ✓ $ok"
  fi
  case " $later " in *" node "*) helpers=0 ;; esac

  # --- download ---------------------------------------------------------
  local tmp
  tmp="$(mktemp -d 2>/dev/null || mktemp -d -t super-board)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT INT TERM

  local url="${SUPER_BOARD_TARBALL:-}" label
  if [ -n "$url" ]; then
    fetch="tar"; label="$url"
  elif [ "$fetch" = "tar" ]; then
    if [ -z "$ref" ]; then
      ref="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tag_name",""))
except Exception: print("")' 2>/dev/null || true)"
      if [ -z "$ref" ]; then warn "couldn't find a published release; using the main branch instead."; ref="main"; fi
    fi
    url="https://codeload.github.com/$repo/tar.gz/$ref"
    label="$repo@$ref"
  else
    label="$repo@${ref:-default branch}"
  fi

  say "📦 downloading $label"
  local src=""
  if [ "$fetch" = "tar" ]; then
    curl -fsSL "$url" -o "$tmp/pack.tgz" || die "download failed: $url. Check the version name and your internet connection." 1
    mkdir -p "$tmp/x"
    tar -xzf "$tmp/pack.tgz" -C "$tmp/x" || die "the download isn't a valid tarball: $url" 1
    if [ -f "$tmp/x/install.sh" ]; then src="$tmp/x"
    else
      local d
      for d in "$tmp"/x/*/; do
        if [ -f "${d}install.sh" ]; then src="${d%/}"; break; fi
      done
    fi
  else
    if [ -n "$ref" ]; then
      git clone -q --depth 1 --branch "$ref" "https://github.com/$repo.git" "$tmp/x" || die "git clone of $label failed." 1
    else
      git clone -q --depth 1 "https://github.com/$repo.git" "$tmp/x" || die "git clone of $label failed." 1
    fi
    src="$tmp/x"
  fi
  [ -n "$src" ] && [ -f "$src/install.sh" ] || die "the download has no install.sh at its top level — is '$label' really super-board?" 1
  local version="?"
  [ -f "$src/VERSION" ] && version="$(tr -d '[:space:]' < "$src/VERSION")"

  # --- install ----------------------------------------------------------
  # Quiet mode: install.sh prints only its "🔧 installing" group; the summary is ours.
  SUPER_BOARD_QUIET_NEXT=1 bash "$src/install.sh" ${pass[@]+"${pass[@]}"} "$target" || die "install.sh stopped with an error (see above). Nothing else was changed after that point." 1

  # --- helper skills ----------------------------------------------------
  local helper_note
  if [ "$helpers" -eq 0 ]; then
    case " $later " in
      *" node "*) helper_note="skipped — 🔍 Checks will fix this" ;;
      *) helper_note="skipped (--no-helper-skills)" ;;
    esac
  elif helper_skills_present "$target"; then
    helper_note="already installed"
  else
    # stdin is this script when piped into bash, so give npx nothing to read. npx's
    # own chatter goes to a log so the summary stays grouped.
    if (cd "$target" && npx -y skills@latest add mattpocock/skills --skill '*' -a claude-code -y </dev/null >"$tmp/npx.log" 2>&1); then
      helper_note="installed"
    else
      helper_note="failed — 🔍 Checks retries it (or: npx skills@latest add mattpocock/skills)"
    fi
  fi

  # --- summary ----------------------------------------------------------
  say "🧠 helper skills: $helper_note"
  say "🎉 super-board $version is installed"
  say "👉 next: open Claude Code here and run /super-board onboard"
}

main "$@"
