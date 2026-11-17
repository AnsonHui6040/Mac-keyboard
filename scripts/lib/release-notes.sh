# 找發佈說明檔，供打包腳本 source 使用。在 repo 根目錄執行。
# find_release_notes <版本> <build>：印出路徑並回傳 0；找不到或有多個候選時不印、回傳 1。
# 順序：release-notes/v<版本>-b<build>.md；否則 release-notes/v<版本>-*.md 恰好一個。
find_release_notes() {
  local version="$1" build="$2" exact matches=()
  exact="release-notes/v${version}-b${build}.md"
  if [ -f "$exact" ]; then
    printf '%s\n' "$exact"
    return 0
  fi
  local f
  for f in "release-notes/v${version}"-*.md; do
    [ -f "$f" ] && matches+=("$f")
  done
  if [ "${#matches[@]}" -eq 1 ]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi
  return 1
}
