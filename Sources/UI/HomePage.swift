// 未配对首页（设计稿 02）：「我是主控」（添加被控设备）/「我是被控」（邀请主控设备）两张卡片。

import SwiftUI

struct HomePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 统一页面骨架：标题区 64、主体（346）、底部说明 40，间距 12
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("从这台 Mac 开始").font(.ui(26, .semibold)).lh(26).foregroundStyle(Theme.text)
                Text("尚未配对。请让两台 Mac 接入同一局域网，并在对方打开 MacKVM。")
                    .font(.ui(13)).lh(13).foregroundStyle(Theme.sub)
            }
            .frame(height: 64)
            HStack(alignment: .top, spacing: 20) {
                RoleCard(controller: true, title: "我是主控", line: "键盘和鼠标接在这台 Mac 上",
                         hint: "查找另一台 Mac，输入它显示的密钥。", button: "添加被控设备") { model.openSeek() }
                RoleCard(controller: false, title: "我是被控", line: "用另一台 Mac 的键鼠控制本机",
                         hint: "显示配对密钥，等待另一台 Mac 连接。", button: "邀请主控设备") { model.openInvite() }
            }
            .frame(maxHeight: .infinity)
            Text("只需配对一次，以后开机或断线后都会自动重新连接。").font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
                .frame(height: 40)
        }
    }
}

private struct RoleCard: View {
    let controller: Bool
    let title: String
    let line: String
    let hint: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            DeviceIcon(withInput: controller, color: Theme.blue)
            Text(title).font(.ui(20, .semibold)).lh(20).foregroundStyle(Theme.text)
            Text(line).font(.ui(13)).lh(13).foregroundStyle(Theme.text)
            Text(hint).font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
            Button(button, action: action).buttonStyle(KVMButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}
