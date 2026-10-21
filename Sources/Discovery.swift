// 局域网 Bonjour 发现：
//   - _mackvm-pair._tcp：被控方点「发起邀请」后广播，主控方「查找设备」列表里显示的就是它；
//   - _mackvm._tcp：已配对的设备一直广播，只给配对过的另一台按设备 ID 找人重连用，不出现在可配对列表里。
// 两种记录的 TXT 里都带 id（设备 ID）和 name（设备名）。
// 这里只负责「列出当前能看到哪些设备」，连上去之后怎么握手归 Pairing.swift / Link.swift。

import Foundation
import Network

let kLinkServiceType = "_mackvm._tcp"
let kPairServiceType = "_mackvm-pair._tcp"

struct DiscoveredDevice: Identifiable, Equatable {
    let id: String              // 对方设备 ID
    let name: String            // 对方设备名
    let endpoint: NWEndpoint
}

/// 生成 Bonjour 记录里带的 TXT
func makeTXT(id: String, name: String) -> NWTXTRecord {
    var t = NWTXTRecord()
    t["id"] = id
    t["name"] = name
    t["v"] = kVersion
    return t
}

/// Bonjour 服务名最长 63 字节（UTF-8），设备名太长时截短
func bonjourName(_ s: String) -> String {
    var out = ""
    for ch in s {
        if (out + String(ch)).utf8.count > 63 { break }
        out.append(ch)
    }
    return out.isEmpty ? "MacKVM" : out
}

/// Bonjour 出错时给人看的说明：被拒绝通常是「本地网络」权限没开
func describeNetworkError(_ e: NWError) -> String {
    if case .dns(let code) = e, code == -65570 {
        return "没有本地网络权限：请到 系统设置 → 隐私与安全性 → 本地网络，打开 MacKVM"
    }
    return "\(e)"
}

/// 持续浏览某一类 Bonjour 服务，列表有变化就回调（主队列）。浏览失败 5 秒后自动重来。
final class BonjourBrowser {
    let type: String
    let label: String
    var onChange: (([DiscoveredDevice]) -> Void)?
    var onProblem: ((String?) -> Void)?
    private var browser: NWBrowser?
    private var stopped = true

    init(type: String, label: String) {
        self.type = type
        self.label = label
    }

    func start() {
        stopped = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: NWParameters())
        b.stateUpdateHandler = { [weak self, weak b] st in
            guard let self, !self.stopped else { return }
            switch st {
            case .ready:
                log("\(self.label)：开始在局域网查找 \(self.type)")
                self.onProblem?(nil)
            case .waiting(let e):
                log("\(self.label)：暂时无法查找：\(describeNetworkError(e))")
                self.onProblem?(describeNetworkError(e))
            case .failed(let e):
                log("\(self.label)：查找失败：\(describeNetworkError(e))，5 秒后重试")
                self.onProblem?(describeNetworkError(e))
                b?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.start()
                }
            default:
                break
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.stopped else { return }
            var list: [DiscoveredDevice] = []
            for r in results {
                guard case .bonjour(let txt) = r.metadata, let id = txt["id"], !id.isEmpty else { continue }
                var name = txt["name"] ?? ""
                if name.isEmpty, case .service(let n, _, _, _) = r.endpoint { name = n }
                if list.contains(where: { $0.id == id }) { continue }   // 同一台从多个网卡被看到，只留一条
                list.append(DiscoveredDevice(id: id, name: name, endpoint: r.endpoint))
            }
            list.sort { $0.name < $1.name }
            self.onChange?(list)
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        stopped = true
        browser?.cancel()
        browser = nil
    }
}
