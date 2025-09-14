#!/usr/bin/env bash
# Lern-Pause Tracker (Shell) v1
# Plattform: Linux/macOS (POSIX Bash/Zsh; empfohlen: bash)
# Features:
# - Lern-Timer mit Live-Anzeige, Ende per Enter/Strg+C
# - Dynamische Pausen-Empfehlung (increase|decrease|linear)
# - Break-Timer mit Zielzeit und Benachrichtigung
# - Tages-Logging (~/.lp-tracker/YYYY-MM-DD.csv)
# - Report (Summe Lern-/Pausenminuten, Zyklen)

set -euo pipefail
LC_ALL=C

APP_DIR="${HOME}/.lp-tracker"
mkdir -p "${APP_DIR}"

today() { date +"%Y-%m-%d"; }
now_hm() { date +"%H:%M"; }
log_file() { echo "${APP_DIR}/$(today).csv"; }

ensure_log_header() {
  local f="$(log_file)"
  if [ ! -f "$f" ]; then
    echo "date,start_time,type,minutes,factor,break_recommendation,note" > "$f"
  fi
}

notify() {
  local title="${1:-Lern-Pause Tracker}"
  local message="${2:-}"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$message" || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${message}\" with title \"${title}\"" || true
  fi
}

beep() { printf "\\a"; }

ceil_div() { awk -v s="$1" 'BEGIN { m=int((s+59)/60); if(m<1) m=1; print m }'; }

factor_for() { # factor_for <minutes> <mode> [a] [b] [min] [max]
  local m="$1" mode="$2" a="${3:-0.22}" b="${4:--0.001}" fmin="${5:-0.18}" fmax="${6:-0.26}"
  awk -v m="$m" -v mode="$mode" -v a="$a" -v b="$b" -v fmin="$fmin" -v fmax="$fmax" '
    function clamp(x,lo,hi){ return (x<lo?lo:(x>hi?hi:x)); }
    BEGIN {
      if (mode=="increase") {
        if (m<=40) f=0.20; else if (m<=60) f=0.22; else f=0.25;
      } else if (mode=="decrease") {
        if (m<=40) f=0.25; else if (m<=60) f=0.22; else f=0.20;
      } else {
        f = clamp(a + b*m, fmin, fmax);
      }
      printf("%.2f", f);
    }'
}

start_session() {
  local mode="increase" A="0.22" B="-0.001" FMIN="0.18" FMAX="0.26"
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="$2"; shift 2;;
      --a) A="$2"; shift 2;;
      --b) B="$2"; shift 2;;
      --min) FMIN="$2"; shift 2;;
      --max) FMAX="$2"; shift 2;;
      *) echo "Unbekannte Option: $1"; exit 1;;
    esac
  done

  ensure_log_header
  local start_epoch end_epoch secs mins factor brk
  start_epoch=$(date +%s)

  echo "✅ Lernphase gestartet – Modus: $mode"
  echo "   Enter = beenden & loggen, Ctrl+C = beenden"
  echo

  stty_state="$(stty -g)"
  trap 'stty "$stty_state"; echo; echo "⏹️  Abgebrochen."; exit 130' INT
  stty -echo -icanon time 10 min 0

  while :; do
    end_epoch=$(date +%s)
    secs=$(( end_epoch - start_epoch ))
    printf "\\r⏱️  Elapsed: %02d:%02d:%02d  (Press Enter to end)  " \
      $((secs/3600)) $(((secs%3600)/60)) $((secs%60))
    if IFS= read -r -t 0.1 -n 1 key; then
      [ "$key" = $'\n' ] && break
    fi
    sleep 0.9
  done

  stty "$stty_state"
  echo

  mins=$(ceil_div "$secs")
  factor="$(factor_for "$mins" "$mode" "$A" "$B" "$FMIN" "$FMAX")"
  brk=$(awk -v m="$mins" -v f="$factor" 'BEGIN{ printf("%d", (m*f)+0.5) }')

  echo "$(today),$(now_hm),learn,${mins},${factor},${brk}," >> "$(log_file)"
  echo "📒 Geloggt: ${mins} min Lernen · Faktor ${factor} → empfohlene Pause ${brk} min"
  notify "Lernen beendet" "Empfohlene Pause: ${brk} min"
  beep

  read -r -p "▶️  Break jetzt starten? [y/N] " ans || true
  [[ "${ans:-}" =~ ^[Yy]$ ]] && break_timer "$brk"
}

break_timer() {
  ensure_log_header
  local target_min="${1:-0}" start_epoch secs mins left
  start_epoch=$(date +%s)
  echo "🛌 Pause gestartet ${target_min:+(Ziel: ${target_min} min)} – Enter beendet & loggt."

  stty_state="$(stty -g)"
  trap 'stty "$stty_state"; echo; echo "⏹️  Abgebrochen."; exit 130' INT
  stty -echo -icanon time 10 min 0

  while :; do
    secs=$(( $(date +%s) - start_epoch ))
    mins=$(( (secs + 59) / 60 ))
    if [ "$target_min" -gt 0 ]; then
      left=$(( target_min*60 - secs ))
      if [ "$left" -le 0 ]; then
        printf "\\n☑️  Ziel erreicht! Gesamte Pause: %02d:%02d  \\n" $((secs/60)) $((secs%60))
        break
      fi
      printf "\\r⏳ Break: %02d:%02d  (Rest ~%02d:%02d)  (Enter beendet)  " \
        $((secs/60)) $((secs%60)) $((left/60)) $((left%60))
    else
      printf "\\r⏳ Break: %02d:%02d  (Enter beendet)  " $((secs/60)) $((secs%60))
    fi
    if IFS= read -r -t 0.1 -n 1 key; then
      [ "$key" = $'\n' ] && break
    fi
    sleep 0.9
  done

  stty "$stty_state"
  mins=$(ceil_div "$secs")
  echo "$(today),$(now_hm),break,${mins},,," >> "$(log_file)"
  echo "📒 Geloggt: ${mins} min Pause"
  notify "Pause beendet" "${mins} min"
  beep
}

report_today() {
  ensure_log_header
  local f="$(log_file)"
  echo "===== Report $(today) ====="
  column -s, -t "$f" | sed 1q
  tail -n +2 "$f" | column -s, -t
  echo
  awk -F, 'NR>1 && $3=="learn"{l+=$4;c++} NR>1 && $3=="break"{b+=$4} END{printf "Gesamt Lernen: %d min\\nGesamt Pausen: %d min\\nZyklen: %d\\n",l,b,c}' "$f"
}

usage() {
  cat <<EOF
Lern-Pause Tracker (Shell)

Befehle:
  start [--mode increase|decrease|linear] [--a 0.22] [--b -0.001] [--min 0.18] [--max 0.26]
      Startet eine Lern-Session mit Live-Anzeige. Enter beendet & loggt.
  break [min]
      Startet einen Break-Countdown (optional Ziel in Minuten). Enter beendet & loggt.
  report
      Zeigt das heutige Log und Summen.
  help
      Zeigt diese Hilfe.
EOF
}

main() {
  case "${1:-help}" in
    start) shift; start_session "$@" ;;
    break) shift; break_timer "${1:-0}" ;;
    report) report_today ;;
    help|--help|-h) usage ;;
    *) echo "Unbekannter Befehl: $1"; usage; exit 1 ;;
  esac
}

main "$@"
