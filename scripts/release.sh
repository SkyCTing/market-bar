#!/bin/bash
#
# 一条命令发布一个版本：改版本号 → 打包 → 提交 → 打 tag → 推送 → 建 Release 传 DMG
#
#   scripts/release.sh 1.0.28
#   scripts/release.sh 1.0.28 "这一版修了什么，写在这里"
#   scripts/release.sh 1.0.28 --yes        # 跳过确认
#
# 为什么要有这个脚本：版本号原来散在两处（build-dmg.sh 的 VERSION、提交信息里的版本），
# 早晚会漂移。这里让它成为**唯一一次写入**，tag 和 Release 都由它生成，
# 三者不可能对不上。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${PROJECT_DIR}"

BUILD_SCRIPT="scripts/build-dmg.sh"
REMOTE="origin"
BRANCH="master"

VERSION="${1:-}"
NOTE="${2:-}"
ASSUME_YES=""
for arg in "$@"; do
    [ "$arg" = "--yes" ] && ASSUME_YES=1
done
[ "$NOTE" = "--yes" ] && NOTE=""

die() { echo "❌ $*" >&2; exit 1; }

# ── 参数
[ -n "$VERSION" ] || die "用法: scripts/release.sh <版本号> [说明] [--yes]
   例如: scripts/release.sh 1.0.28 \"修了悬浮面板的对齐\""
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号要写成 x.y.z，收到的是「${VERSION}」"

TAG="v${VERSION}"

# ── 前置检查（每一条都是「现在停下来」比「发出去再收拾」便宜）
[ -f "$BUILD_SCRIPT" ] || die "找不到 $BUILD_SCRIPT"

git rev-parse --git-dir >/dev/null 2>&1 || die "这不是 git 仓库"
[ -z "$(git status --porcelain)" ] || die "工作区不干净。先提交或 stash ——
   发布提交里只应该有版本号那一处改动，混进别的东西就说不清了"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$BRANCH" ] || die "当前在 $CURRENT_BRANCH 分支，发布要在 $BRANCH 上"

git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && die "tag ${TAG} 已经存在"
git ls-remote --exit-code --tags "$REMOTE" "refs/tags/${TAG}" >/dev/null 2>&1 \
    && die "远端已经有 tag ${TAG} 了"

CURRENT_VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$BUILD_SCRIPT" | head -1)"
[ -n "$CURRENT_VERSION" ] || die "从 $BUILD_SCRIPT 里读不出版本号"

echo "即将发布 ${TAG}（当前是 ${CURRENT_VERSION}）"
echo "  · 把 $BUILD_SCRIPT 的版本号改成 ${VERSION}"
echo "  · 打包出 dist/MarketBar-${VERSION}.dmg"
echo "  · 提交「Release ${VERSION}」、打 tag ${TAG}"
echo "  · 推 ${BRANCH} 和 ${TAG} 到 ${REMOTE}"
echo "  · 建 GitHub Release 并把 DMG 传上去"

if [ -z "$ASSUME_YES" ]; then
    printf "继续？[y/N] "
    read -r reply
    [ "$reply" = "y" ] || [ "$reply" = "Y" ] || { echo "已取消"; exit 0; }
fi

# ── 改版本号（唯一一次写入）
# BSD 与 GNU 的 sed -i 语法不同，用临时文件避开这个坑
sed "s/^VERSION=\".*\"\$/VERSION=\"${VERSION}\"/" "$BUILD_SCRIPT" > "${BUILD_SCRIPT}.tmp"
mv "${BUILD_SCRIPT}.tmp" "$BUILD_SCRIPT"
grep -q "^VERSION=\"${VERSION}\"$" "$BUILD_SCRIPT" || die "版本号没写进去，检查 $BUILD_SCRIPT 的 VERSION 那行"
echo "✅ 版本号 → ${VERSION}"

# ── 打包
bash "$BUILD_SCRIPT"
DMG="dist/MarketBar-${VERSION}.dmg"
[ -f "$DMG" ] || die "打包完没找到 $DMG"
echo "✅ 打出 $DMG"

# ── 提交 + 打 tag
git add "$BUILD_SCRIPT"
git commit -q -m "Release ${VERSION}" -m "${NOTE}"
git tag -a "${TAG}" -m "MarketBar ${VERSION}"
echo "✅ 已提交并打 tag ${TAG}"

# ── 推送
git push "$REMOTE" "$BRANCH"
git push "$REMOTE" "${TAG}"
echo "✅ 已推送"

# ── GitHub Release
NOTES="${NOTE:-MarketBar ${VERSION}}"
if ! gh release create "${TAG}" "$DMG" --title "MarketBar ${VERSION}" --notes "$NOTES"; then
    cat >&2 <<'MSG'

❌ Release 没建成。最常见的原因是 gh 的 token 缺 workflow 权限
   （仓库历史上出现过 .github/workflows 就会要求这个）：
       gh auth refresh -h github.com -s workflow
   授权完手动补一次即可，tag 和提交都已经推上去了：
       gh release create <tag> <dmg 路径> --title "MarketBar <版本>" --notes "…"
MSG
    exit 1
fi

echo ""
echo "🎉 发布完成：${TAG}"
gh release view "${TAG}" --json url -q .url 2>/dev/null || true
