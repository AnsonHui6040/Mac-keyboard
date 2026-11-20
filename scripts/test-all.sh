#!/usr/bin/env bash
# 一次跑完 repo 內所有自動化測試，印出摘要表。每個 suite 的完整 log 在 build/test-all/<suite>.log。
# 真機項目（BLE、相機、觸控板手感）不在其中。
set -u

usage() {
  cat <<USAGE
用法：scripts/test-all.sh [--only 名稱[,名稱]] [--skip 名稱[,名稱]] [-h]

suite 依序為：core rime receiver clippy ios mac video e2e
  core      swift test（Packages/RemoteKeyboardCore）
  rime      swift test（Packages/RimeEngine；RimeC.xcframework 不存在時記為失敗）
  receiver  cargo test --workspace（receiver/）
  clippy    cargo clippy --workspace --all-targets -D warnings
  ios       xcodebuild build（RemoteKeyboardApp，iOS Simulator）
  mac       xcodebuild test（MacReceiver，macOS）
  video     npm test（video/；node_modules 不存在時先 npm ci）
  e2e       python3 unittest（e2e/scripts）

任何 suite 失敗時結束碼為 1。環境變數 TEST_ALL_CORE_PKG 可改 core 的套件路徑（驗證失敗流程用）。
USAGE
}

ALL=(core rime receiver clippy ios mac video e2e)
ONLY=""; SKIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only|--skip)
      [ $# -ge 2 ] || { echo "$1 需要參數" >&2; exit 64; }
      if [ "$1" = "--only" ]; then ONLY="$2"; else SKIP="$2"; fi
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "不認得的參數：$1" >&2; usage >&2; exit 64 ;;
  esac
done

in_list() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }
for n in ${ONLY//,/ } ${SKIP//,/ }; do
  in_list "$n" "$(IFS=,; echo "${ALL[*]}")" || { echo "不認得的 suite：$n" >&2; exit 64; }
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="build/test-all"
mkdir -p "$OUT"
CORE_PKG="${TEST_ALL_CORE_PKG:-Packages/RemoteKeyboardCore}"
WORKSPACE="RemoteKeyboard.xcworkspace"

cmd_core() { swift test --package-path "$CORE_PKG"; }
cmd_rime() {
  if [ ! -d Packages/RimeEngine/Artifacts/RimeC.xcframework ]; then
    echo "Packages/RimeEngine/Artifacts/RimeC.xcframework 不存在，先在 repo 根目錄執行："
    echo "  scripts/rime/fetch.sh"
    echo "  scripts/rime/build-xcframework.sh"
    return 1
  fi
  swift test --package-path Packages/RimeEngine
}
cmd_receiver() { cargo test --manifest-path receiver/Cargo.toml --workspace; }
cmd_clippy() { cargo clippy --manifest-path receiver/Cargo.toml --workspace --all-targets -- -D warnings; }
cmd_ios() {
  xcodebuild -workspace "$WORKSPACE" -scheme RemoteKeyboardApp -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$OUT/dd" ARCHS=arm64 build # RimeC.xcframework 只有 arm64，不建 x86_64 模擬器切片
}
cmd_mac() {
  xcodebuild -workspace "$WORKSPACE" -scheme MacReceiver -destination 'platform=macOS' \
    -derivedDataPath "$OUT/dd" test
}
cmd_video() {
  cd video || return 1
  if [ ! -d node_modules ]; then npm ci || return 1; fi
  npm test
}
cmd_e2e() { python3 -m unittest discover -s e2e/scripts -p 'test_*.py'; }

# count_of <suite> <log>：從 log 取測試數；取不到印 -。
count_of() {
  local log="$2" a b
  case "$1" in
    core|rime)
      a="$(grep -E 'Executed [0-9]+ tests?' "$log" | tail -n 1 | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')"
      b="$(grep -E 'Test run with [0-9]+ tests?' "$log" | tail -n 1 | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/')"
      if [ -n "$a" ] && [ -n "$b" ]; then echo "$((a + b))"; elif [ -n "$a" ]; then echo "$a"; else echo "-"; fi ;;
    mac)
      a="$(grep -E 'Executed [0-9]+ tests?' "$log" | tail -n 1 | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')"
      echo "${a:--}" ;;
    receiver)
      a="$(grep -E '^test result: ' "$log" | sed -E 's/^test result: [a-zA-Z]+\. ([0-9]+) passed.*/\1/' | paste -sd+ - | bc 2>/dev/null)"
      echo "${a:--}" ;;
    video)
      a="$(grep -E '^ℹ tests [0-9]+' "$log" | tail -n 1 | sed -E 's/^ℹ tests ([0-9]+).*/\1/')"
      echo "${a:--}" ;;
    e2e)
      a="$(grep -E '^Ran [0-9]+ tests?' "$log" | tail -n 1 | sed -E 's/^Ran ([0-9]+) tests?.*/\1/')"
      echo "${a:--}" ;;
    *) echo "-" ;;
  esac
}

NAMES=(); RESULTS=(); SECS=(); COUNTS=()
FAILED=0
for s in "${ALL[@]}"; do
  [ -z "$ONLY" ] || in_list "$s" "$ONLY" || continue
  ! in_list "$s" "$SKIP" || continue
  log="$OUT/$s.log"
  echo "== $s"
  start=$SECONDS
  if { [ "$s" = ios ] || [ "$s" = mac ]; } && [ ! -d "$WORKSPACE" ]; then
    {
      echo "$WORKSPACE 不存在，先在 repo 根目錄執行："
      echo "  xcodegen generate"
      echo "  LANG=en_US.UTF-8 pod install"
    } | tee "$log"
    rc=1
  else
    ( "cmd_$s" ) >"$log" 2>&1
    rc=$?
  fi
  secs=$((SECONDS - start))
  NAMES+=("$s"); SECS+=("$secs"); COUNTS+=("$(count_of "$s" "$log")")
  if [ "$rc" -eq 0 ]; then RESULTS+=(PASS); else RESULTS+=(FAIL); FAILED=$((FAILED + 1)); fi
done

echo
printf '%-10s %-6s %8s %8s  %s\n' suite result seconds tests log
i=0
while [ "$i" -lt "${#NAMES[@]}" ]; do
  printf '%-10s %-6s %8s %8s  %s\n' "${NAMES[$i]}" "${RESULTS[$i]}" "${SECS[$i]}" "${COUNTS[$i]}" "$OUT/${NAMES[$i]}.log"
  i=$((i + 1))
done
echo
if [ "$FAILED" -gt 0 ]; then echo "FAIL：$FAILED 個 suite 失敗"; exit 1; fi
echo "全部 PASS（${#NAMES[@]} 個 suite）"
