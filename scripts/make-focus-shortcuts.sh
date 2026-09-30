#!/bin/bash
#
# 生成会议模式要用的两个快捷指令文件（切专注模式）。
#
#   bash scripts/make-focus-shortcuts.sh
#
# 产出在 FocusShortcuts/，用户双击导入即可。
#
# 为什么要自己生成而不是让用户手建：macOS **没有**任何公开 API 能设置专注模式
# （`INFocusStatus.isFocused` 是 readonly，没有 DoNotDisturb framework，老的
# `defaults write com.apple.notificationcenterui` 在 Big Sur 之后已失效），
# 只能借道快捷指令。而手建要在 Shortcuts 里点七八下，还容易点错。
#
# ⚠️ 两个坑（都踩过，写在这儿免得下次再踩）：
#   1. `shortcuts sign` 只吃**二进制** plist，喂 XML 会报「格式不对」
#   2. 输入文件**必须带 `.shortcut` 扩展名**，叫 `.bin` / `.plist` 一样报错
#
# 动作的参数结构是从用户机器上的快捷指令数据库里读出来的（只读）：
#   is.workflow.actions.dnd.set
#     Enabled    = 1 / 0            ← 开 / 关
#     FocusModes = { Identifier: com.apple.donotdisturb.mode.default }

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${PROJECT_DIR}/FocusShortcuts"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

command -v shortcuts >/dev/null 2>&1 || { echo "❌ 找不到 shortcuts 命令（macOS 12+ 自带）" >&2; exit 1; }

# $1 = Enabled（1 开 / 0 关），$2 = 输出文件名（不带扩展名）
write_template() {
    cat > "${WORK_DIR}/$2.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WFWorkflowClientVersion</key><string>3036.0.4</string>
	<key>WFWorkflowClientRelease</key><string>2.0</string>
	<key>WFWorkflowMinimumClientVersion</key><integer>900</integer>
	<key>WFWorkflowMinimumClientVersionString</key><string>900</string>
	<key>WFWorkflowIcon</key>
	<dict>
		<key>WFWorkflowIconStartColor</key><integer>4271458815</integer>
		<key>WFWorkflowIconGlyphNumber</key><integer>61440</integer>
	</dict>
	<key>WFWorkflowImportQuestions</key><array/>
	<key>WFWorkflowTypes</key><array><string>NCWidget</string></array>
	<key>WFWorkflowInputContentItemClasses</key><array/>
	<key>WFWorkflowActions</key>
	<array>
		<dict>
			<key>WFWorkflowActionIdentifier</key><string>is.workflow.actions.dnd.set</string>
			<key>WFWorkflowActionParameters</key>
			<dict>
				<key>Enabled</key><integer>$1</integer>
				<key>FocusModes</key>
				<dict>
					<key>DisplayString</key><string>Do Not Disturb</string>
					<key>Identifier</key><string>com.apple.donotdisturb.mode.default</string>
				</dict>
			</dict>
		</dict>
	</array>
</dict>
</plist>
EOF
}

make_shortcut() {   # $1 = Enabled, $2 = 给人看的名字
    local enabled="$1" name="$2"
    local stem
    stem="$(echo "${name}" | tr -d ' ')"
    # 先转二进制，并且**必须**用 .shortcut 当扩展名（见文件头的坑 2）
    plutil -convert binary1 "${WORK_DIR}/${stem}.plist" -o "${WORK_DIR}/${stem}-unsigned.shortcut"
    shortcuts sign --mode anyone \
        -i "${WORK_DIR}/${stem}-unsigned.shortcut" \
        -o "${OUT_DIR}/${name}.shortcut"
}

mkdir -p "${OUT_DIR}"
write_template 1 "MeetingStart"
write_template 0 "MeetingEnd"
make_shortcut 1 "Meeting Start"
make_shortcut 0 "Meeting End"

# 校验：签名前的输入里 Enabled 对不对，产物是不是 AEA 签名容器
for entry in "MeetingStart:Meeting Start:1" "MeetingEnd:Meeting End:0"; do
    stem="${entry%%:*}"; rest="${entry#*:}"; name="${rest%%:*}"; want="${rest##*:}"
    got="$(plutil -convert xml1 -o - "${WORK_DIR}/${stem}-unsigned.shortcut" \
        | sed -n '/<key>Enabled<\/key>/{n;s/.*<integer>\([0-9]*\)<\/integer>.*/\1/p;}')"
    [ "${got}" = "${want}" ] || { echo "❌ ${name} 的 Enabled 应为 ${want}，实际 ${got}" >&2; exit 1; }
    head -c 4 "${OUT_DIR}/${name}.shortcut" | grep -q "AEA1" \
        || { echo "❌ ${name}.shortcut 不是 AEA 签名容器" >&2; exit 1; }
    echo "✅ ${name}.shortcut  Enabled=${got}  $(stat -f%z "${OUT_DIR}/${name}.shortcut") 字节"
done

echo ""
echo "产出目录: ${OUT_DIR}"
echo "用户操作：双击 →「添加快捷指令」→ 在「会议模式设置…」里填上这两个名字"
