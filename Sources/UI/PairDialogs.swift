// 配对流程的弹窗：
//   InviteDialog       被控方「邀请主控设备」（设计稿 03）：本机设备名 + 8 位配对码 + 正在广播
//   CodeRenewedDialog  被控方：对方输错 5 次，配对码已换新（08「密钥已自动更新」）
//   SeekDialog         主控方「添加被控设备」（04）：局域网里正在邀请的设备列表
//   NoDevicesDialog    主控方：查找一阵仍没有可配对设备（08「没找到可配对的设备」）
//   CodeDialog         主控方输入 8 位配对码（05）；配对码不对时在输入框下方显示红色提示，可以重输
//   PairSuccessDialog  配对成功（08）
//   StateDialog        08 那种带右上角关闭按钮、底部操作按钮的状态卡片（各弹窗共用）

import SwiftUI

// MARK: - 03 发起邀请

struct InviteDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("等待另一台 Mac 来连接").font(.ui(24, .semibold)).lh(24).foregroundStyle(Theme.text)
            Text("在另一台 Mac 点击「添加被控设备」，选择本机并输入下方配对码。").font(.ui(13)).lh(13).foregroundStyle(Theme.sub)
            VStack(alignment: .leading, spacing: 18) {
                Text("本机设备名").font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
                Text(model.me.name).font(.ui(22, .semibold)).lh(22).foregroundStyle(Theme.text)
                CodeDigits(code: model.inviteCode).frame(maxWidth: .infinity)
                if let p = model.inviteProblem {
                    Text(p).font(.ui(13)).lh(13).foregroundStyle(Theme.red)
                } else if model.inviteRenewed {
                    Text("密钥已自动更新 · 请让对方使用新密钥重新输入").font(.ui(13)).lh(13).foregroundStyle(Theme.amber)
                } else {
                    Text("正在局域网广播 · 等待配对…").font(.ui(13)).lh(13).foregroundStyle(Theme.blue)
                }
                Text("请仅向你信任的设备提供此密钥。").font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
            }
            HStack(spacing: 12) {
                Button("取消配对") { model.cancelInvite() }.buttonStyle(KVMButtonStyle(kind: .secondary))
                Text("取消后立即停止广播").font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
            }
        }
        .padding(28)
        .frame(width: 700, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
    }
}

/// 8 位码按 4 + 4 分组
func grouped(_ code: String, sep: String) -> String {
    let c = Array(code)
    guard c.count > 4 else { return code }
    return String(c.prefix(4)) + sep + String(c.dropFirst(4))
}

private struct CodeDigits: View {
    let code: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(code.enumerated()), id: \.offset) { i, ch in
                if i == 4 {
                    Text("–").font(.ui(28)).lh(28).foregroundStyle(Theme.sub)
                }
                Text(String(ch))
                    .font(.ui(32, .medium)).lh(32)
                    .foregroundStyle(Theme.text)
                    .frame(width: 64, height: 70)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.codeCell))
            }
        }
    }
}

// MARK: - 04 查找设备

struct SeekDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("连接另一台 Mac").font(.ui(24, .semibold)).lh(24).foregroundStyle(Theme.text)
            Text("选择要连接的设备。对方需先点击「邀请主控设备」。").font(.ui(13)).lh(13).foregroundStyle(Theme.sub)
            VStack(alignment: .leading, spacing: 18) {
                Text("局域网设备").font(.ui(15, .semibold)).lh(15).foregroundStyle(Theme.text)
                Text("持续查找中 · 列表自动更新").font(.ui(11)).lh(11).foregroundStyle(Theme.sub)
                if model.seekDevices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.seekProblem ?? "正在查找正在邀请的 Mac…")
                            .font(.ui(13)).lh(13).foregroundStyle(model.seekProblem == nil ? Theme.sub : Theme.red)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.windowBG))
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.seekDevices) { d in
                            HStack(spacing: 10) {
                                Text(d.name).font(.ui(14, .medium)).lh(14).foregroundStyle(Theme.blue).lineLimit(1)
                                Spacer()
                                Button("配对…") { model.chooseDevice(d) }
                                    .buttonStyle(KVMButtonStyle(padV: 9, padH: 16, radius: 7))
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rowSelected))
                        }
                    }
                }
            }
            Button("取消") { model.cancelSeek() }.buttonStyle(KVMButtonStyle(kind: .secondary))
        }
        .padding(28)
        .frame(width: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
    }
}

// MARK: - 05 输入配对码

struct CodeDialog: View {
    @EnvironmentObject var model: AppModel
    let device: DiscoveredDevice
    @FocusState private var focused: Bool

    /// 输入框里显示成「5829 – 1604」，存的只是 8 位数字
    private var text: Binding<String> {
        Binding(
            get: {
                // 数字之间插细空格，近似设计稿里的字间距（TextField 不支持 tracking）
                let spaced = model.codeInput.map(String.init)
                let a = spaced.prefix(4).joined(separator: "\u{2009}")
                let b = spaced.dropFirst(4).joined(separator: "\u{2009}")
                return b.isEmpty ? a : a + "\u{2002}–\u{2002}" + b
            },
            set: { v in
                let d = String(PairingCrypto.digits(v).prefix(8))
                if d != model.codeInput { model.codeInput = d }
                if model.codeError != nil, !d.isEmpty { model.codeError = nil }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("与「\(device.name)」配对").font(.ui(20, .semibold)).lh(20).foregroundStyle(Theme.text)
            Text("输入对方屏幕上显示的 8 位配对码").font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
            VStack(alignment: .leading, spacing: 8) {
                TextField("", text: text, prompt: Text("8 位数字").foregroundStyle(Theme.sub.opacity(0.6)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22).monospacedDigit()).lh(22)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { model.submitCode() }
                    .disabled(model.pairingBusy)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(model.codeError == nil ? Theme.blue : Theme.red, lineWidth: 1))
                if let e = model.codeError {
                    Text(e).font(.ui(12)).lh(12).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { model.cancelCodeEntry() }.buttonStyle(KVMButtonStyle(kind: .grey))
                Button(model.pairingBusy ? "配对中…" : "配对") { model.submitCode() }
                    .buttonStyle(KVMButtonStyle())
                    .disabled(model.pairingBusy || model.codeInput.count != 8)
            }
        }
        .padding(28)
        .frame(width: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .onAppear { focused = true }
    }
}

// MARK: - 08 状态弹窗

struct CodeRenewedDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StateDialog(title: "密钥已自动更新",
                    message: "对方连续 5 次输错密钥，旧密钥已作废。\n新密钥：\(grouped(model.inviteCode, sep: "–"))",
                    note: "查看新密钥并告知对方；取消邀请将停止广播。",
                    onClose: { model.showNewCode() }) {
            Button("取消邀请") { model.cancelInvite() }.buttonStyle(DialogButton(kind: .grey))
            Button("查看新密钥") { model.showNewCode() }.buttonStyle(DialogButton())
        }
    }
}

struct NoDevicesDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StateDialog(title: "没找到可配对的设备",
                    message: model.seekProblem ?? "请在另一台 Mac 点击「邀请主控设备」，并确认两台处于同一局域网。",
                    note: "设备列表持续更新；取消查找可返回角色选择。",
                    onClose: { model.continueSeek() }) {
            Button("取消查找") { model.cancelSeek() }.buttonStyle(DialogButton(kind: .grey))
            Button("继续查找") { model.continueSeek() }.buttonStyle(DialogButton())
        }
    }
}

struct PairSuccessDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let done = { model.dialog = nil; model.tab = .connection }
        StateDialog(title: "配对成功",
                    message: model.isController
                        ? "已与「\(model.peerName)」配对。\n本机操作对方，从蓝色相接边段推出光标即可切过去。"
                        : "已与「\(model.peerName)」配对。\n本机由对方操作，局域网广播已停止。",
                    onClose: done) {
            Button("完成，查看设备连接", action: done).buttonStyle(DialogButton(size: 13, padH: 16))
        }
    }
}

/// 设计稿 08 的弹窗卡片：标题 + 右上角关闭 + 说明 + 补充说明，底部右对齐的操作按钮
struct StateDialog<Actions: View>: View {
    let title: String
    let message: String
    var note: String? = nil
    let onClose: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(title).font(.ui(15, .semibold)).lh(15).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.sub)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.closeBG))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            Text(message).font(.ui(12)).foregroundStyle(Theme.sub).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note).font(.ui(12, .medium)).lh(12).foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                actions()
            }
        }
        .padding(18)
        .frame(width: 414, height: 246, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// 08 弹窗底部的按钮：蓝底白字或浅灰底，12 号中粗字，内边距 8×14，圆角 7
struct DialogButton: ButtonStyle {
    var kind: KVMButtonStyle.Kind = .primary
    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    var padH: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        KVMButtonStyle(kind: kind, size: size, weight: weight, padV: 8, padH: padH, radius: 7)
            .makeBody(configuration: configuration)
    }
}
