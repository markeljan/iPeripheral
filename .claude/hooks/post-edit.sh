#!/usr/bin/env bash
# After Claude edits a file: format Swift, regenerate the Xcode project when project.yml changes.
f="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))')"
root="$(cd "$(dirname "$0")/../.." && pwd)"
case "$f" in
  *.swift) xcrun swift-format format -i --configuration "$root/.swift-format" "$f" 2>/dev/null || true ;;
  */project.yml) (cd "$root" && xcodegen generate --quiet) >&2 || exit 2 ;;
esac
exit 0
