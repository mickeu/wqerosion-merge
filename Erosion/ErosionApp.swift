//
//  ErosionApp.swift
//  Erosion — merged into WQ Files.
//
//  Originally the @main SwiftUI App. For the merged app, WQ Files' UIKit
//  main() owns the app lifecycle; Erosion boots via wqErosionBootstrap() and
//  is hosted with WQErosionMakeRootViewController() (a UIHostingController).
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

final class WQErosionTab: ObservableObject {
    static let shared = WQErosionTab()
    @Published var index = 0
    func move(_ d: Int) { index = min(2, max(0, index + d)) }
}

let device = UIDevice.current
let fm = FileManager.default
var weOnADebugBuild = false
var pipe = Pipe()
var sema = DispatchSemaphore(value: 0)

// Was ErosionApp.init(). Call once, before hosting ErosionRootView.
func wqErosionBootstrap() {
    UserDefaults.standard.register(defaults: [
        "mgWriteAtomically": true,
        "maxInode": 15000000
    ])
    if !UserDefaults.standard.bool(forKey: "mgAtomicDefaultMigrated") {
        UserDefaults.standard.set(true, forKey: "mgWriteAtomically")
        UserDefaults.standard.set(true, forKey: "mgAtomicDefaultMigrated")
    }

    setvbuf(stdout, nil, _IONBF, 0)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

    // fix file picker
    let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:)))!
    let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:)))!
    method_exchangeImplementations(origMethod, fixMethod)

    #if DEBUG
    weOnADebugBuild = true
    #else
    weOnADebugBuild = false
    #endif
}

struct ErosionRootView: View {
    @StateObject private var mgr = ErosionManager.shared
    @StateObject private var langMgr = LocalizationManager.shared
    @ObservedObject private var tab = WQErosionTab.shared
    @State private var didBootstrapLogs = false

    var body: some View {
        VStack(spacing: 0) {
            let bar = HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Button {
                        withAnimation(.snappy) { tab.index = i }
                    } label: {
                        Image(systemName: ["house.fill", "wrench.and.screwdriver.fill", "folder.fill"][i])
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(tab.index == i ? Color.accentColor : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .modifier(WQTopTabGlass(selected: tab.index == i))
                }
            }
            .padding(6)
            Group {
                if #available(iOS 19.0, *) {
                    bar.glassEffect(.regular, in: .capsule)
                } else {
                    bar.background(.ultraThinMaterial, in: .capsule)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
            Group {
                switch tab.index {
                case 0: ContentView()
                case 1: TweaksView()
                default: FMRootView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(langMgr.refreshID)
        .environment(\.locale, langMgr.effectiveLocale)
        .environmentObject(mgr)
        .onAppear {
            guard !didBootstrapLogs else { return }
            didBootstrapLogs = true
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData

                if data.isEmpty {
                    fh.readabilityHandler = nil
                    sema.signal()
                    return
                }

                guard let text = String(data: data, encoding: .utf8) else {
                    return
                }

                DispatchQueue.main.async {
                    mgr.logOutput.append(text)
                }
            }
            print("")
            print("[*] Erosion v\(AppInfo.appVersion) (\(build))")
            print(L("[*] 运行环境：\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)，设备标识符：\(machineName()) (\(buildNumber()))"))
            if !isSupported() && !weOnADebugBuild {
                Alertinator.shared.alert(title: L("当前 \(device.systemName) 版本暂不支持！"), body: AppMsg.unsupported, showCancel: false, actionLabel: "退出", action: { exitinator() })
            }
            group = wq.getAppGroup()
            print(L("(wq) 当前使用 App Group：\(group)"))
            if isRunningInLiveContainer() {
                print(LocalizationManager.isEnglish
                    ? "[!] (lc) Currently running inside LiveContainer: if container authorization fails, check host App Group settings in LiveContainer or install standalone."
                    : "[!] (lc) 当前运行在 LiveContainer 内，若遇容器授权失败，请在 LiveContainer 应用设置中检查宿主 App Group 配置，或使用独立侧载安装。")
            }
        }
        .overlay {
            if mgr.shouldRespring {
                RespringView()
                    .brightness(-1.0)
                    .ignoresSafeArea()
            }
        }
    }
}

/// Per-button Liquid Glass for the top tab strip: each icon is its own glass
/// capsule; the selected one is tinted (like the native bottom tab bar).
struct WQTopTabGlass: ViewModifier {
    let selected: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if selected {
            if #available(iOS 19.0, *) {
                content.glassEffect(.regular.interactive().tint(Color.accentColor.opacity(0.28)), in: .capsule)
            } else {
                content.background(.ultraThinMaterial, in: .capsule)
            }
        } else {
            content
        }
    }
}

// Objective-C entry point: builds the Erosion UI as a hostable controller.
final class WQErosionHostingController: UIHostingController<ErosionRootView>,
                                        UIGestureRecognizerDelegate {
    private var swipeRecognizers: [UISwipeGestureRecognizer] = []

    // Window-level: a recognizer on the hosting view is swallowed by the
    // SwiftUI buttons and scroll views inside the pages.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let win = view.window, swipeRecognizers.isEmpty else { return }
        for dir in [UISwipeGestureRecognizer.Direction.left, .right] {
            let g = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            g.direction = dir
            g.delegate = self
            g.cancelsTouchesInView = false
            win.addGestureRecognizer(g)
            swipeRecognizers.append(g)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        swipeRecognizers.forEach { $0.view?.removeGestureRecognizer($0) }
        swipeRecognizers.removeAll()
    }
    @objc func swiped(_ g: UISwipeGestureRecognizer) {
        // Same behaviour as the top bar buttons; the tab bar item is a UITabBarController.
        if g.direction == .left { WQErosionTab.shared.move(1) } else { WQErosionTab.shared.move(-1) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

@_cdecl("WQErosionMakeRootViewController")
public func WQErosionMakeRootViewController() -> UIViewController {
    wqErosionBootstrap()
    let host = WQErosionHostingController(rootView: ErosionRootView())
    host.title = "Erosion"
    return host
}

extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}
