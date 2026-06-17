#!/bin/bash
# update_readme.sh
# 自动更新 README.md 的 build 信息（在 CI 中调用）
# 用法：./scripts/update_readme.sh <version> <commit_short> <status>
# 例如：./scripts/update_readme.sh v2.2.2 d64b728 passing

set -e

VERSION="${1:-unknown}"
COMMIT="${2:-$(git rev-parse --short HEAD)}"
STATUS="${3:-passing}"

# 状态 emoji
case "$STATUS" in
  passing)  STATUS_EMOJI="✅ passing" ;;
  failing)  STATUS_EMOJI="❌ failing" ;;
  *)        STATUS_EMOJI="⚠️ $STATUS" ;;
esac

if [ ! -f "README.md" ]; then
  echo "ERROR: README.md not found"
  exit 1
fi

export VERSION COMMIT STATUS_EMOJI
python3 << 'PYEOF'
import os, re
from datetime import datetime, timezone

version  = os.environ['VERSION']
commit   = os.environ['COMMIT']
status   = os.environ['STATUS_EMOJI']
# 用 Python UTC 时间（避免依赖系统 date 命令，跨平台）
date_str = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')

with open('README.md', 'r', encoding='utf-8') as f:
    content = f.read()

# 用 $ 变量占位符（避免 f-string 与 $ 冲突）
template = '<sub>📦 Latest build: <b>$VERSION</b> · commit <code>$COMMIT</code> · $DATE · $STATUS</sub>'
new_badge = template.replace('$VERSION', version) \
                    .replace('$COMMIT', commit) \
                    .replace('$DATE', date_str) \
                    .replace('$STATUS', status)

pattern = r'<!--BEGIN_BUILD_BADGE-->.*?<!--END_BUILD_BADGE-->'
replacement = f'<!--BEGIN_BUILD_BADGE-->\n{new_badge}\n<!--END_BUILD_BADGE-->'

new_content, count = re.subn(pattern, replacement, content, flags=re.DOTALL)

if count == 0:
    print("ERROR: BEGIN_BUILD_BADGE / END_BUILD_BADGE markers not found")
    exit(1)

# 同步更新"状态"表格里的"最新版本"行
pattern2 = r'\| 最新版本 \| v[\d.]+ \|'
replacement2 = f'| 最新版本 | {version} |'
new_content, count2 = re.subn(pattern2, replacement2, new_content)
if count2 == 0:
    print("WARN: '最新版本' row not found (table not updated)")

with open('README.md', 'w', encoding='utf-8') as f:
    f.write(new_content)

print(f"✅ Updated README.md: version={version}, commit={commit}, date={date_str}, status={status}")
PYEOF
