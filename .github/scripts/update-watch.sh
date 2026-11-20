#!/usr/bin/env bash
# update-watch: следим за апстримами тарбалов, запиненных в Dockerfile.
#
# Сравнивает ARG <TOOL>_VERSION с последним GitHub-release апстрима и действует
# по ярусу дельты:
#   patch / minor -> ветка update/<tool>-<ver> + PR (Dockerfile: VERSION+SHA256,
#                   sha пересчитывается по скачанному релизному тарбалу).
#                   Мерж — только руками после зелёных build+smoke на PR.
#   major         -> issue (API-совместимость решают люди).
# Дедупликация: существующая ветка/открытый PR -> пропуск; закрытый неслитый PR
# того же апдейта -> issue «skip earlier» (раз в ветку, PR больше не плодится).
#
# Окружение: GITHUB_TOKEN, GITHUB_REPOSITORY (owner/name), DRY_RUN=1 (только
# план), BASE_BRANCH (по умолчанию текущая ветка), DOCKERFILE (путь).
set -euo pipefail
if [ -z "${GITHUB_TOKEN:-}" ]; then
  printf 'missing env: %s\n' "GITHUB_TOKEN" >&2; exit 1
fi
if [ -z "${GITHUB_REPOSITORY:-}" ]; then
  printf 'missing env: %s (owner/name)\n' "GITHUB_REPOSITORY" >&2; exit 1
fi

API="${GITHUB_API_URL:-https://api.github.com}"
REPO="$GITHUB_REPOSITORY"
OWNER="${REPO_OWNER:-${REPO%%/*}}"
DRY_RUN="${DRY_RUN:-0}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
REPO_DIR=$(cd "$(dirname "$DOCKERFILE")" && pwd)
BASE_BRANCH="${BASE_BRANCH:-$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo main)}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

log() { printf '%s\n' "$*"; }

api() { # api <path> [curl args...] -> stdout; HTTP-код в API_CODE
  local path=$1; shift
  API_CODE=$(curl -sS -o "$TMP/resp" -w '%{http_code}' \
    -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' \
    "$API$path" "$@")
  cat "$TMP/resp"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# tool | апстрим | паттерн URL релизного тарбала (VER — версия, VERu — с _ вместо .)
upstreams() {
  echo 'JQ   | jqlang/jq          | https://github.com/jqlang/jq/releases/download/jq-VER/jq-VER.tar.gz'
  echo 'XZ   | tukaani-project/xz | https://github.com/tukaani-project/xz/releases/download/vVER/xz-VER.tar.gz'
  echo 'CURL | curl/curl          | https://github.com/curl/curl/releases/download/curl-VERu/curl-VER.tar.gz'
  echo 'OPENSSL | openssl/openssl | https://github.com/openssl/openssl/releases/download/openssl-VER/openssl-VER.tar.gz'
}

tag_to_version() {
  case "$1" in
    JQ)      echo "${2#jq-}" ;;
    XZ)      echo "${2#v}" ;;
    CURL)    echo "${2#curl-}" | tr _ . ;;
    OPENSSL) echo "${2#openssl-}" ;;
  esac
}

# <ver> -> "M N P suffix"; формат не трёхкомпонентный -> вывод = вход
semver_split() { echo "$1" | sed -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+)(.*)$/\1 \2 \3 \4/'; }

# tier <cur> <new> -> skip | patch | minor | major | odd
tier() {
  local c n cm mm pm sm cn mn pn sn
  c=$(semver_split "$1"); n=$(semver_split "$2")
  { [ "$c" != "$1" ] && [ "$n" != "$2" ]; } || { echo odd; return; }
  read -r cm mm pm sm <<<"$c"
  read -r cn mn pn sn <<<"$n"
  # даунгрейд (запинено свежее latest — пре-релиз и т.п.) — не трогаем
  if [ "$cm" -gt "$cn" ] ||
     { [ "$cm" -eq "$cn" ] && [ "$mm" -gt "$mn" ]; } ||
     { [ "$cm" -eq "$cn" ] && [ "$mm" -eq "$mn" ] && [ "$pm" -gt "$pn" ]; }; then
    echo skip; return
  fi
  [ "$cm" -lt "$cn" ] && { echo major; return; }
  [ "$mm" -lt "$mn" ] && { echo minor; return; }
  [ "$pm" -lt "$pn" ] && { echo patch; return; }
  # числа равны: буквенный хвост (openssl 3.0.12a) = security-патч
  [ "$sm" = "$sn" ] && { echo skip; return; }
  case "$sn" in
    ''|*[0-9]*) echo odd ;;
    *) echo patch ;;
  esac
}

# create_pr <tool-lower> <old> <new> <tier> <old-sha> <new-sha>
create_pr() {
  local tool=$1 old=$2 new=$3 tr=$4 osha=$5 nsha=$6
  local branch="update/$1-$3" st body
  st=$(api "/repos/$REPO/pulls?state=all&per_page=100&head=$OWNER:$branch" |
       jq -r '.[0].state // empty')
  if [ "$st" = open ]; then log "$tool: PR уже открыт — пропускаю"; return; fi
  if [ "$st" = closed ]; then
    [ "$DRY_RUN" = 1 ] && { log "DRY: создал бы issue о закрытом PR"; return; }
    api "/repos/$REPO/issues" -X POST -d "$(jq -n \
      --arg t "update skipped earlier: $tool $old -> $new" \
      --arg b "Открывался PR на \`$new\`, закрыт без мержа. Решение в силе — закрой этот issue; передумали — бампни вручную." \
      '{title:$t, body:$b}')" >/dev/null
    log "$tool: PR закрывали -> issue-напоминание"; return
  fi
  body="Апстрим выпустил \`$new\` (запинено \`$old\`; ярус дельты: **$tr**).

| | было | стало |
|---|---|---|
| версия | \`$old\` | \`$new\` |
| sha256 | \`$osha\` | \`$nsha\` |

sha256 пересчитан по скачанному релизному тарбалу апстрима.
Сборка и smoke на этом PR — единственная проверка; мерж только вручную после
зелёного прогона обеих арок. Автоматическое слияние не выполняется."
  [ "$DRY_RUN" = 1 ] && { log "DRY: создал бы PR $branch ($tr)"; return; }
  api "/repos/$REPO/pulls" -X POST -d "$(jq -n \
    --arg t "build($tool): $old -> $new" --arg h "$branch" --arg b "$body" \
    '{title:$t, head:$h, base:env.BASE_BRANCH, body:$b}')" |
    jq -r '"  PR #" + (.number|tostring)' 2>/dev/null || log "  PR не создан (HTTP $API_CODE)"
}

while IFS='|' read -r tool upstream url_tpl; do
  tool=$(echo "$tool" | tr -d ' '); upstream=$(echo "$upstream" | tr -d ' ')
  [ -n "$tool" ] || continue
  pinned=$(sed -nE "s/^ARG ${tool}_VERSION=([0-9A-Za-z._-]+).*/\1/p" "$DOCKERFILE")
  pinned_sha=$(sed -nE "s/^ARG ${tool}_SHA256=([0-9a-f]+).*/\1/p" "$DOCKERFILE")
  [ -n "$pinned" ] || { log "$tool: версия не найдена в $DOCKERFILE"; continue; }
  tag=$(api "/repos/$upstream/releases/latest" | jq -r .tag_name)
  { [ -n "$tag" ] && [ "$tag" != null ]; } || { log "$tool: $upstream не отдал releases/latest"; continue; }
  new=$(tag_to_version "$tool" "$tag")
  tr=$(tier "$pinned" "$new")
  log "$tool: pinned=$pinned latest=$new -> $tr"
  case "$tr" in skip) continue ;; esac

  tool_l=$(echo "$tool" | tr 'A-Z' 'a-z')
  if [ "$tr" = odd ]; then log "$tool: формат '$new' не разобрал — нужна ручная проверка"; continue; fi

  if [ "$tr" = major ]; then
    title="update available: $tool_l $pinned -> $new (major)"
    dup=$(api "/repos/$REPO/issues?state=open&per_page=100" |
          jq -r --arg t "$title" '[.[] | select(.title==$t)][0].number // empty')
    [ -n "$dup" ] && { log "$tool: issue #$dup уже открыт"; continue; }
    [ "$DRY_RUN" = 1 ] && { log "DRY: создал бы issue: $title"; continue; }
    api "/repos/$REPO/issues" -X POST -d "$(jq -n --arg t "$title" \
      --arg b "Апстрим [$upstream](https://github.com/$upstream) выпустил \`$new\`; запинено \`$pinned\`. Major: совместимость проверяем руками, автopr не создаётся намеренно." \
      '{title:$t, body:$b, labels:["enhancement"]}')" >/dev/null
    log "$tool: issue создан"; continue
  fi

  # patch | minor -> bump-PR
  branch="update/${tool_l}-${new}"
  ref_code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GITHUB_TOKEN" \
    "$API/repos/$REPO/git/ref/heads/$branch")
  if [ "$ref_code" = 200 ]; then log "$tool: ветка $branch уже есть — пропускаю"; continue; fi
  tarurl=${url_tpl//VERu/$(echo "$new" | tr . _)}; tarurl=${tarurl//VER/$new}
  if [ "$DRY_RUN" = 1 ]; then log "DRY: ветка $branch; tarball $tarurl"; continue; fi
  curl -sSLf --max-time 120 -o "$TMP/pkg.tar.gz" "$tarurl" || { log "$tool: не скачал $tarurl"; continue; }
  nsha=$(sha256 "$TMP/pkg.tar.gz")

  git -C "$REPO_DIR" fetch -q origin "$BASE_BRANCH" 2>/dev/null || true
  git -C "$REPO_DIR" checkout -q -b "$branch" "origin/$BASE_BRANCH" 2>/dev/null \
    || git -C "$REPO_DIR" checkout -q -b "$branch"
  sed -E "s|^ARG ${tool}_VERSION=.*|ARG ${tool}_VERSION=${new}|" -i "$DOCKERFILE"
  sed -E "s|^ARG ${tool}_SHA256=.*|ARG ${tool}_SHA256=${nsha}|" -i "$DOCKERFILE"
  git -C "$REPO_DIR" -c user.name='update-watch' -c user.email='update-watch@users.noreply.github.com' \
    commit -q -am "build($tool_l): $pinned -> $new (upstream $tr)"
  git -C "$REPO_DIR" push -q "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git" "$branch" ||
    { log "$tool: не запушил $branch"; git -C "$REPO_DIR" checkout -q "$BASE_BRANCH"; continue; }
  create_pr "$tool_l" "$pinned" "$new" "$tr" "$pinned_sha" "$nsha"
  git -C "$REPO_DIR" checkout -q "$BASE_BRANCH"
done <<EOF
$(upstreams)
EOF
