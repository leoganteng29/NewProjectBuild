#!/usr/bin/env bash
# Helper Telegram: rich card, tombol berwarna, emoji premium, Local Bot API (file besar)
source "$(dirname "${BASH_SOURCE[0]}")/emoji.sh"
API_CLOUD="https://api.telegram.org/bot${TG_BOT_TOKEN:-}"
LOCAL_API="http://127.0.0.1:8081/bot${TG_BOT_TOKEN:-}"
FILE_API="$API_CLOUD"

esc()     { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
strip_t() { sed -E 's#<tg-emoji emoji-id="[0-9]+">([^<]*)</tg-emoji>#\1#g'; }
strip_k() { jq -c 'walk(if type=="object" then del(.icon_custom_emoji_id,.style) else . end)'; }

em() { local id="${EMOJI[$1]:-}"
  if [ -n "$id" ]; then printf '<tg-emoji emoji-id="%s">%s</tg-emoji>' "$id" "$2"; else printf '%s' "$2"; fi; }

bar() { local p="$1" f=$(( $1 / 10 )) s="" i
  for ((i=0;i<10;i++)); do if [ "$i" -lt "$f" ]; then s+="▰"; else s+="▱"; fi; done
  printf '%s %s%%' "$s" "$p"; }

kind_label() { if [ "${KIND:-}" = "web" ]; then printf 'Web → APK'; else printf 'Flutter · %s' "${BUILD_TYPE^}"; fi; }
src_label()  { if [ "${KIND:-}" = "web" ]; then printf '%s' "${SOURCE:-}" | cut -c1-60 | esc; else printf 'ZIP Flutter'; fi; }
user_label() { printf '%s' "${USER_LABEL:-user}" | cut -c1-60 | esc; }

_btn() { # _btn <label> <fb> <emoji-name> <key> <value> <style>
  local id="${EMOJI[$3]:-}"
  if [ -n "$id" ]; then jq -cn --arg t "$1" --arg k "$4" --arg v "$5" --arg s "$6" --arg i "$id" '{text:$t,style:$s,icon_custom_emoji_id:$i}+{($k):$v}'
  else jq -cn --arg t "$2 $1" --arg k "$4" --arg v "$5" --arg s "$6" '{text:$t,style:$s}+{($k):$v}'; fi; }
kbtn() { _btn "$1" "$2" "$3" url "$4" "$5"; }            # tombol link
cbtn() { _btn "$1" "$2" "$3" callback_data "$4" "$5"; }  # tombol callback

card() { cat <<EOF
$(em robot 🤖) <b>APK Builder</b> <code>#${JOB_ID}</code>
<blockquote>$(em package 📦) Sumber: <code>$(src_label)</code>
$(em build 🛠) Mode: <b>$(kind_label)</b>
$(em user 👤) User: $(user_label)</blockquote>
$(bar "$1")
<i>$2</i>
EOF
}

_edit() { jq -n --arg c "$CHAT_ID" --argjson m "$MESSAGE_ID" --arg t "$1" --argjson k "$2" \
  '{chat_id:$c,message_id:$m,text:$t,parse_mode:"HTML",link_preview_options:{is_disabled:true}} + (if $k then {reply_markup:$k} else {} end)' \
  | curl -sS -X POST -H 'Content-Type: application/json' -d @- "$API_CLOUD/editMessageText"; }

tg_edit() { local t="$1" k="${2:-null}" out
  out=$(_edit "$t" "$k") || true
  if [ "$(jq -r '.ok // false' <<<"$out" 2>/dev/null)" != "true" ]; then
    out=$(_edit "$(strip_t <<<"$t")" "$(strip_k <<<"$k")") || true
  fi; }

progress() { tg_edit "$(card "$1" "$2")"; }

notify_admin() { [ -n "${LOG_CHAT:-}" ] || return 0
  local out
  out=$(curl -sS -X POST "$API_CLOUD/sendMessage" --data-urlencode "chat_id=$LOG_CHAT" --data-urlencode "parse_mode=HTML" \
    --data-urlencode "text=$1" --data-urlencode 'link_preview_options={"is_disabled":true}') || true
  if [ "$(jq -r '.ok // false' <<<"$out" 2>/dev/null)" != "true" ]; then
    curl -sS -X POST "$API_CLOUD/sendMessage" --data-urlencode "chat_id=$LOG_CHAT" --data-urlencode "parse_mode=HTML" \
      --data-urlencode "text=$(strip_t <<<"$1")" --data-urlencode 'link_preview_options={"is_disabled":true}' >/dev/null || true
  fi; }

# ---- Local Bot API server (file sampai 2 GB) ----
start_local_api() {
  [ -n "${TG_API_ID:-}" ] && [ -n "${TG_API_HASH:-}" ] || return 1
  mkdir -p /tmp/tgdata && chmod 777 /tmp/tgdata
  docker rm -f tgapi >/dev/null 2>&1 || true
  docker run -d --name tgapi -p 127.0.0.1:8081:8081 -v /tmp/tgdata:/var/lib/telegram-bot-api \
    -e TELEGRAM_API_ID="$TG_API_ID" -e TELEGRAM_API_HASH="$TG_API_HASH" -e TELEGRAM_LOCAL=1 \
    aiogram/telegram-bot-api:latest >/dev/null || return 1
  local i
  for i in $(seq 1 40); do curl -sS -o /dev/null "http://127.0.0.1:8081/" 2>/dev/null && return 0; sleep 1; done
  return 1
}

local_download() { # <file_id> <dest>
  local out p
  out=$(curl -sS --max-time 1500 "$LOCAL_API/getFile" --data-urlencode "file_id=$1") || return 1
  p=$(jq -r '.result.file_path // empty' <<<"$out")
  [ -n "$p" ] || { echo "getFile (local) gagal: $(jq -r '.description // empty' <<<"$out")" >&2; return 1; }
  docker cp "tgapi:$p" "$2" 2>/dev/null || cp "/tmp/tgdata${p#/var/lib/telegram-bot-api}" "$2"
}

cloud_download() { # <file_id> <dest>  (maks 20 MB)
  local p
  p=$(curl -sS "$API_CLOUD/getFile" --data-urlencode "file_id=$1" | jq -r '.result.file_path // empty')
  [ -n "$p" ] || return 1
  curl -sSfL -o "$2" "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${p}"
}

# Kirim file TANPA caption (info ada di rich card)
tg_send_doc() { # <file>
  local f="$1" out size
  out=$(curl -sS --max-time 1800 -X POST "$FILE_API/sendDocument" \
    --form-string "chat_id=$CHAT_ID" --form-string "reply_parameters={\"message_id\":$MESSAGE_ID}" \
    -F "document=@$f") || true
  [ "$(jq -r '.ok // false' <<<"$out" 2>/dev/null)" = "true" ] && return 0
  size=$(stat -c%s "$f")
  if [ "$FILE_API" != "$API_CLOUD" ] && [ "$size" -le $((49*1024*1024)) ]; then
    out=$(curl -sS --max-time 600 -X POST "$API_CLOUD/sendDocument" \
      --form-string "chat_id=$CHAT_ID" --form-string "reply_parameters={\"message_id\":$MESSAGE_ID}" \
      -F "document=@$f") || true
    [ "$(jq -r '.ok // false' <<<"$out" 2>/dev/null)" = "true" ] && return 0
  fi
  return 1
}
