// 未配对首页（设计稿 02）：「我是主控」（添加被控设备）/「我是被控」（邀请主控设备）两张卡片。

import SwiftUI

struct HomePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 统一页面骨架：标题区 64、主体（346）、底部说明 40，间距 12
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.homeTitle).font(.ui(26, .semibold)).lh(26).foregroundStyle(Theme.text)
                Text(L.homeSubtitle)
                    .font(.ui(13)).lh(13).foregroundStyle(Theme.sub)
            }
            .frame(height: 64)
            HStack(alignment: .top, spacing: 20) {
                RoleCard(controller: true, title: L.homeControllerTitle, line: L.homeControllerLine,
                         hint: L.homeControllerHint, button: L.homeControllerButton) { model.openSeek() }
                RoleCard(controller: false, title: L.homeControlledTitle, line: L.homeControlledLine,
                         hint: L.homeControlledHint, button: L.homeControlledButton) { model.openInvite() }
            }
            .frame(maxHeight: .infinity)
            Text(L.homeFootnote).font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
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
