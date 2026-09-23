import Foundation

/// Every word the app says, in one place (ARCH-1 §6).
///
/// The source language is Simplified Chinese: that is what Leo reads, what the
/// boards are drawn in, and what `Localizable.xcstrings` stores as the default
/// value of each key. English is a translation in the same catalog.
///
/// Three rules hold every entry here, and `scripts/lint_views.sh` keeps them:
///
/// * **A control gets a label of four words or fewer.** "结束会话", not "结束
///   这次 Remote 会话并回到刚才的面板".
/// * **A state gets one short sentence with a verb**, and nothing else — no
///   parentheses, no em-dash aside, no sentence that starts with 这 and no
///   sentence that tells the user what they just did.
/// * **The host's own words are never in here.** A menu row's label, a
///   keybinding's name, a notification's body and core's own reason strings
///   arrive from the machine and are drawn verbatim, untranslated, because
///   they name things that exist on that computer.
enum Strings {
    static let actionCancel = String(localized: "action.cancel", defaultValue: "取消")
    static let actionRetry = String(localized: "action.retry", defaultValue: "重试")
    static let actionConfirmEnd = String(localized: "action.confirmEnd", defaultValue: "确认结束")
    static let actionDismiss = String(localized: "action.dismiss", defaultValue: "关闭")
    static let actionDelete = String(localized: "action.delete", defaultValue: "删除")
    static let actionCollapse = String(localized: "action.collapse", defaultValue: "收起")
    static let actionConnect = String(localized: "action.connect", defaultValue: "连接")
    static let actionOpenSettings = String(localized: "action.openSettings", defaultValue: "去设置")
    static let panelMenu = String(localized: "panel.menu", defaultValue: "Omarchy 菜单")
    static let panelRemote = String(localized: "panel.remote", defaultValue: "Remote")
    static let panelAgent = String(localized: "panel.agent", defaultValue: "Agent")
    static let panelHerdr = String(localized: "panel.herdr", defaultValue: "Herdr")
    static let panelSsh = String(localized: "panel.ssh", defaultValue: "SSH")
    static let panelSettings = String(localized: "panel.settings", defaultValue: "设置")
    static let panelNotifications = String(localized: "panel.notifications", defaultValue: "通知")
    static let panelKeybindings = String(localized: "panel.keybindings", defaultValue: "Keybindings")
    static let panelPanelTab = String(localized: "panel.panelTab", defaultValue: "Panel")
    static let barLogoLabel = String(localized: "bar.logo.label", defaultValue: "Omarchy 菜单与 Keybindings")
    static let barLogoOpen = String(localized: "bar.logo.open", defaultValue: "已打开")
    static let barLogoClosed = String(localized: "bar.logo.closed", defaultValue: "未打开")
    static let barConnection = String(localized: "bar.connection", defaultValue: "与主机的连接")
    static let barConnectionConnected = String(localized: "bar.connection.connected", defaultValue: "已连接")
    static let barConnectionConnecting = String(localized: "bar.connection.connecting", defaultValue: "正在连接")
    static let barConnectionReconnecting = String(localized: "bar.connection.reconnecting", defaultValue: "正在重连")
    static let barConnectionUnavailable = String(localized: "bar.connection.unavailable", defaultValue: "连不上")
    static let barConnectionSuspended = String(localized: "bar.connection.suspended", defaultValue: "已挂起")
    static let barConnectionDisconnected = String(localized: "bar.connection.disconnected", defaultValue: "未连接")
    /// PAIR-5 §2: nobody answered. Not the same thing as 连不上 (red), which is
    /// now only a host that answered with something this device cannot use.
    static let barConnectionOffline = String(localized: "bar.connection.offline", defaultValue: "主机离线")
    static func panelHostOffline(_ a: String) -> String {
        String(localized: "panel.hostOffline", defaultValue: "\(a) 离线。连上之后这里会自己恢复。")
    }
    static let barWorkspaces = String(localized: "bar.workspaces", defaultValue: "工作区")
    static func barWorkspaceName(_ a: String) -> String {
        String(localized: "bar.workspace.name", defaultValue: "工作区 \(a)")
    }
    static let barWorkspaceCurrent = String(localized: "bar.workspace.current", defaultValue: "当前")
    static let barWorkspaceOccupied = String(localized: "bar.workspace.occupied", defaultValue: "有窗口")
    static let barWorkspaceEmpty = String(localized: "bar.workspace.empty", defaultValue: "空")
    static let barWorkspaceUnknown = String(localized: "bar.workspace.unknown", defaultValue: "未知")
    static let barWorkspaceMoveHere = String(localized: "bar.workspace.moveHere", defaultValue: "移动聚焦窗口")
    static let barMore = String(localized: "bar.more", defaultValue: "更多快捷动作")
    static let barEdgeLeft = String(localized: "bar.edge.left", defaultValue: "bar 放左边")
    static let barEdgeRight = String(localized: "bar.edge.right", defaultValue: "bar 放右边")
    static let barEdgeTop = String(localized: "bar.edge.top", defaultValue: "bar 放上面")
    static let barEdgeBottom = String(localized: "bar.edge.bottom", defaultValue: "bar 放下面")
    static let quickKeyboard = String(localized: "quick.keyboard", defaultValue: "键盘")
    static let quickRotationLock = String(localized: "quick.rotationLock", defaultValue: "锁定旋转")
    static let quickPointerMode = String(localized: "quick.pointerMode", defaultValue: "指针模式")
    static let quickHostAudio = String(localized: "quick.hostAudio", defaultValue: "主机音频")
    static let quickEndSession = String(localized: "quick.endSession", defaultValue: "结束会话")
    static let quickKeyboardUp = String(localized: "quick.keyboard.up", defaultValue: "已弹出")
    static let quickKeyboardDown = String(localized: "quick.keyboard.down", defaultValue: "已收起")
    static let quickRotationLocked = String(localized: "quick.rotation.locked", defaultValue: "已锁定")
    static let quickRotationUnlocked = String(localized: "quick.rotation.unlocked", defaultValue: "未锁定")
    static let quickPointerTouchpad = String(localized: "quick.pointer.touchpad", defaultValue: "触控板")
    static let quickPointerDirect = String(localized: "quick.pointer.direct", defaultValue: "直接触摸")
    static let quickOn = String(localized: "quick.on", defaultValue: "开")
    static let quickOff = String(localized: "quick.off", defaultValue: "关")
    static let quickTwoStep = String(localized: "quick.twoStep", defaultValue: "两步确认")
    static let quickUnavailable = String(localized: "quick.unavailable", defaultValue: "不可用")
    static let quickAudioNoChannel = String(localized: "quick.audio.noChannel", defaultValue: "VNC 没有音频通道，换 Sunshine")
    static let quickAudioOff = String(localized: "quick.audio.off", defaultValue: "主机音频在设置里关着")
    static let menuSearch = String(localized: "menu.search", defaultValue: "搜索 Omarchy…")
    static let menuSearchClear = String(localized: "menu.search.clear", defaultValue: "清除搜索")
    static let menuGroup = String(localized: "menu.group", defaultValue: "OMARCHY 菜单")
    static let menuResults = String(localized: "menu.results", defaultValue: "搜索结果")
    static let menuUnavailable = String(localized: "menu.unavailable", defaultValue: "不可用")
    static let menuHostCurrent = String(localized: "menu.host.current", defaultValue: "当前主机")
    static let menuHostLocked = String(localized: "menu.host.locked", defaultValue: "会话中")
    static let menuGone = String(localized: "menu.gone", defaultValue: "主机上已不存在")
    static let menuNoTerminalTarget = String(localized: "menu.noTerminalTarget", defaultValue: "主机没有给出终端目标")
    static let menuNoLongerAvailable = String(localized: "menu.noLongerAvailable", defaultValue: "主机上已经没有这一行")
    // PERF-5: one line on the row itself, for the last invocation that failed.
    static let menuSending = String(localized: "menu.sending", defaultValue: "发送中")
    /// MENU-4 / A-68: a row that changes the machine, armed by its first tap.
    static let menuTapAgain = String(localized: "menu.tapAgain", defaultValue: "再点一次执行")
    static let menuFailedStale = String(localized: "menu.failed.stale", defaultValue: "主机上变了，刷新后再试")
    static let menuFailedNoFocus = String(localized: "menu.failed.noFocus", defaultValue: "主机上没有聚焦的窗口")
    static let menuFailedRefused = String(localized: "menu.failed.refused", defaultValue: "主机拒绝了")
    static let menuFailedUnknown = String(localized: "menu.failed.unknown", defaultValue: "结果未知")
    static let menuFailedUnreachable = String(localized: "menu.failed.unreachable", defaultValue: "没连上主机")
    static let pinnedEditDone = String(localized: "pinned.editDone", defaultValue: "完成")
    static let pinnedEmpty = String(localized: "pinned.empty", defaultValue: "还没有 pin 任何东西。")
    static let pinnedEmptyMenuHint = String(localized: "pinned.empty.menuHint", defaultValue: "长按菜单里的一行，或用「编辑」露出图钉。")
    static let pinnedEmptyKeyHint = String(localized: "pinned.empty.keyHint", defaultValue: "长按列表里的一条绑定，或用「编辑」露出图钉。")
    static func pinnedPin(_ a: String) -> String {
        String(localized: "pinned.pin", defaultValue: "pin \(a)")
    }
    static func pinnedUnpin(_ a: String) -> String {
        String(localized: "pinned.unpin", defaultValue: "取消 pin \(a)")
    }
    static let keybindingsSearch = String(localized: "keybindings.search", defaultValue: "搜索动作或快捷键…")
    static func keybindingsHidden(_ a: String) -> String {
        String(localized: "keybindings.hidden", defaultValue: "已隐藏 \(a) 条与 bar 或菜单重复的动作")
    }
    static func keybindingsAlsoIn(_ a: String) -> String {
        String(localized: "keybindings.alsoIn", defaultValue: "也在 \(a)")
    }
    static let keybindingsUseSurface = String(localized: "keybindings.useSurface", defaultValue: "用这个面板自己的控件。")
    static let remoteDefault = String(localized: "remote.default", defaultValue: "默认")
    static let remoteStartTakeover = String(localized: "remote.startTakeover", defaultValue: "开始接管")
    static let remoteExtendWhy = String(localized: "remote.extend.why", defaultValue: "电脑旁边多出来的一块屏。本地屏继续可用，窗口可以拖过来。")
    static let remoteTakeoverWhy = String(localized: "remote.takeover.why", defaultValue: "把当前桌面整块搬过来。电脑屏幕熄灭，结束后按快照恢复。")
    static let remoteAdvanced = String(localized: "remote.advanced", defaultValue: "高级")
    static func remoteAdvancedBackend(_ a: String) -> String {
        String(localized: "remote.advanced.backend", defaultValue: "画面后端 · \(a)")
    }
    static let remoteStepConnected = String(localized: "remote.step.connected", defaultValue: "已连接")
    static let remoteSunshineUnapproved = String(localized: "remote.sunshineUnapproved", defaultValue: "Sunshine 还没批准这台设备")
    static let remotePairAgain = String(localized: "remote.pairAgain", defaultValue: "补一次 Sunshine 配对")
    static let remotePairCancel = String(localized: "remote.pairCancel", defaultValue: "取消配对")
    static let remoteUseVNC = String(localized: "remote.useVNC", defaultValue: "改用 VNC 连接")
    static func remoteOccupied(_ a: String) -> String {
        String(localized: "remote.occupied", defaultValue: "\(a) 上已经有一个会话")
    }
    static let remoteReclaim = String(localized: "remote.reclaim", defaultValue: "结束它并接管")
    static func remoteEndItThere(_ a: String) -> String {
        String(localized: "remote.endItThere", defaultValue: "在 \(a) 上结束它。")
    }
    static func remoteTakeoverTitle(_ a: String) -> String {
        String(localized: "remote.takeoverTitle", defaultValue: "接管 \(a) 的桌面")
    }
    static let remoteTakeoverEffect = String(localized: "remote.takeover.effect", defaultValue: "电脑屏幕熄灭，工作区搬过来。结束后按快照恢复。")
    static let remoteLockLocalInput = String(localized: "remote.lockLocalInput", defaultValue: "锁定电脑本地键鼠")
    static let remoteLockLocalInputDetail = String(localized: "remote.lockLocalInput.detail", defaultValue: "会话期间电脑上的键鼠不响应。掉线后 60 秒自动解锁。")
    static func remoteSessionRunning(_ a: String) -> String {
        String(localized: "remote.session.running", defaultValue: "\(a) · 进行中")
    }
    static let remoteSessionHost = String(localized: "remote.session.host", defaultValue: "主机")
    static let remoteSessionBackend = String(localized: "remote.session.backend", defaultValue: "后端")
    static let remoteSessionState = String(localized: "remote.session.state", defaultValue: "状态")
    static let remoteSessionReturnTo = String(localized: "remote.session.returnTo", defaultValue: "结束后回到")
    static let remoteResume = String(localized: "remote.resume", defaultValue: "回到画面")
    static func remoteEnd(_ a: String) -> String {
        String(localized: "remote.end", defaultValue: "结束 Remote · \(a)")
    }
    static let remotePicture = String(localized: "remote.picture", defaultValue: "主机画面")
    static let remoteRetainedFrame = String(localized: "remote.retainedFrame", defaultValue: "保留的上一帧，输入已暂停")
    // REMOTE-4: the host rebuilt its display under a session it still holds.
    static let remoteHostReconfiguring = String(localized: "remote.hostReconfiguring", defaultValue: "主机重新配置中，正在重新连接…")
    static let remoteHostReconfigureStalled = String(localized: "remote.hostReconfigureStalled", defaultValue: "主机重新配置后画面没回来。会话还在，可以重试。")
    static let remoteHostReconfigureRetry = String(localized: "remote.hostReconfigureRetry", defaultValue: "重试")
    // REMOTE-6: WayVNC switched from the compositor's logical size to the
    // output's own pixels. The picture stays; only its sharpness changes.
    static let remoteFramebufferResizing = String(localized: "remote.framebufferResizing", defaultValue: "正在切到主机的原生像素…")
    static let remoteToastNotification = String(localized: "remote.toast.notification", defaultValue: "点这条打开通知")
    static let remoteToastApproval = String(localized: "remote.toast.approval", defaultValue: "点这条打开 Agent")
    static let remoteToastConnection = String(localized: "remote.toast.connection", defaultValue: "点这条打开 Remote")
    static let remoteToastApprovalNeeded = String(localized: "remote.toast.approvalNeeded", defaultValue: "default agent 需要一次审批")
    static func remoteToastReconnecting(_ a: String) -> String {
        String(localized: "remote.toast.reconnecting", defaultValue: "\(a) 连接中断，正在重连")
    }
    static let remoteClosePanel = String(localized: "remote.closePanel", defaultValue: "收起面板")
    static let agentComposer = String(localized: "agent.composer", defaultValue: "跟 agent 说点什么…")
    static let agentSend = String(localized: "agent.send", defaultValue: "发送")
    static let agentSteer = String(localized: "agent.steer", defaultValue: "补充")
    static let agentInterrupt = String(localized: "agent.interrupt", defaultValue: "中断")
    static let agentRun = String(localized: "agent.run", defaultValue: "执行")
    static let agentModel = String(localized: "agent.model", defaultValue: "模型")
    static let agentModelThread = String(localized: "agent.model.thread", defaultValue: "跟随线程")
    static let agentDetails = String(localized: "agent.details", defaultValue: "详情")
    static let agentAnswer = String(localized: "agent.answer", defaultValue: "回答")
    static let agentReconnect = String(localized: "agent.reconnect", defaultValue: "重连")
    /// D-15 / A-63: one row, only while the turn really is in flight and
    /// nothing has come back from it yet.
    static let agentThinking = String(localized: "agent.thinking", defaultValue: "正在想…")
    static let agentDismissResult = String(localized: "agent.dismissResult", defaultValue: "关闭结果")
    static let agentRefreshCommands = String(localized: "agent.refreshCommands", defaultValue: "刷新命令")
    static let agentLiteralText = String(localized: "agent.literalText", defaultValue: "当作普通文本")
    static let agentHandoffKeep = String(localized: "agent.handoff.keep", defaultValue: "继续用现在的 agent")
    static let agentHandoffReview = String(localized: "agent.handoff.review", defaultValue: "查看这次改动")
    static let agentHandoffConfirm = String(localized: "agent.handoff.confirm", defaultValue: "确认交接")
    static let agentHandoffLater = String(localized: "agent.handoff.later", defaultValue: "以后再说")
    static let agentHandoffAgain = String(localized: "agent.handoff.again", defaultValue: "再看一次")
    static let agentHandoffDetail = String(localized: "agent.handoff.detail", defaultValue: "终端里的会话要交接一次才能用原生聊天。先看清改动，确认前什么都不动。")
    static let herdrClosePane = String(localized: "herdr.closePane", defaultValue: "关闭 pane")
    static let herdrClosePaneDetail = String(localized: "herdr.closePane.detail", defaultValue: "主机上这个 pane 的进程会结束。其他 pane 不受影响。")
    static let herdrNoPanes = String(localized: "herdr.noPanes", defaultValue: "没有可观察的 pane")
    static let herdrFocused = String(localized: "herdr.focused", defaultValue: "聚焦")
    static let herdrZoomed = String(localized: "herdr.zoomed", defaultValue: "放大")
    /// A-63: entering ⑤ dials the paired host, so the only thing this surface
    /// has to say before the shell is up is that it is dialling. The screen
    /// that used to ask first — "这台设备还没有开 SSH 会话。" plus an "开一个
    /// 终端" button — is deleted, and so are its two strings.
    static func sshConnecting(_ a: String) -> String {
        String(localized: "ssh.connecting", defaultValue: "正在连接 \(a)")
    }
    static let sshUnavailable = String(localized: "ssh.unavailable", defaultValue: "这个会话已经不在了。")
    static let sshTerminal = String(localized: "ssh.terminal", defaultValue: "终端")
    static let sshDemo = String(localized: "ssh.demo", defaultValue: "演示 · 未连接主机")
    static let sshToggleKeyboard = String(localized: "ssh.toggleKeyboard", defaultValue: "切换键盘")
    static let sshPaste = String(localized: "ssh.paste", defaultValue: "粘贴")
    static let sshCopy = String(localized: "ssh.copy", defaultValue: "复制选中")
    static let sshSelectAll = String(localized: "ssh.selectAll", defaultValue: "全选")
    static let sshTextLarger = String(localized: "ssh.textLarger", defaultValue: "字大一点")
    static let sshTextSmaller = String(localized: "ssh.textSmaller", defaultValue: "字小一点")
    static let sshModifierRowShow = String(localized: "ssh.modifierRow.show", defaultValue: "显示修饰键行")
    static let sshModifierRowHide = String(localized: "ssh.modifierRow.hide", defaultValue: "隐藏修饰键行")
    static let sshDisconnect = String(localized: "ssh.disconnect", defaultValue: "断开 SSH")
    static let sshClose = String(localized: "ssh.close", defaultValue: "关闭会话")
    static let sshCloseDetail = String(localized: "ssh.close.detail", defaultValue: "断开 SSH。主机上的进程不受影响。")
    static func sshSize(_ a: String, _ b: String) -> String {
        String(localized: "ssh.size", defaultValue: "\(a) × \(b)")
    }
    static let sshDismissError = String(localized: "ssh.dismissError", defaultValue: "关闭错误")
    /// UX-2 §1. A connection that gave up says which step it gave up on. The
    /// one line that used to cover all six steps — "SSH 连接结束或被拒绝" — is
    /// what the real iPad got for two minutes of nothing.
    static let sshFailedUnreachable = String(localized: "ssh.failed.unreachable", defaultValue: "连不上主机的 22 端口。")
    static func sshFailedHandshake(_ a: String) -> String {
        String(localized: "ssh.failed.handshake", defaultValue: "主机接受了连接，但 \(a) 秒内没有完成握手。")
    }
    static let sshFailedHostKeyWait = String(localized: "ssh.failed.hostKeyWait", defaultValue: "还没确认主机指纹，连接已放弃。")
    static func sshFailedShell(_ a: String) -> String {
        String(localized: "ssh.failed.shell", defaultValue: "登录成功，但 \(a) 秒内没有拿到终端。")
    }
    /// UX-3 §2. Userauth got its own budget and its own sentence; before this
    /// a deadline during authentication said "没有完成握手", which is true of
    /// four other steps as well.
    static func sshFailedAuth(_ a: String) -> String {
        String(localized: "ssh.failed.auth", defaultValue: "主机接受了连接，但 \(a) 秒内没有通过认证。")
    }
    /// UX-3 §2. The host refused this device's SSH key. It is not a network
    /// problem and retrying will not fix it, so the sentence says what does.
    static let sshKeyRejected = String(localized: "ssh.keyRejected",
                                       defaultValue: "主机拒绝了这台设备的 SSH 密钥。在设置里忘记这台主机，再配对一次。")
    /// UX-3 §2. The ladder is standing back, and says for how long.
    static func sshBackingOff(_ a: String) -> String {
        String(localized: "ssh.backingOff", defaultValue: "连接失败，\(a) 秒后再试一次。")
    }
    /// UX-4 §2. The device noticed the host does not hold its key and is
    /// saying so. It is one or two seconds, and then either a shell or the
    /// sentence below.
    static let sshKeyReplacing = String(localized: "ssh.keyReplacing",
                                        defaultValue: "主机不认得这台设备的密钥，正在重新登记…")
    /// The host answered and refused the new key. Retrying will not change it.
    static let sshKeyReplaceRefused = String(localized: "ssh.keyReplaceRefused",
                                             defaultValue: "主机没有接受这台设备的新 SSH 密钥。在设置里忘记这台主机，再配对一次。")
    /// Nobody answered. Unlike the two above, this one is worth trying again.
    static let sshKeyReplaceUnreachable = String(localized: "ssh.keyReplaceUnreachable",
                                                 defaultValue: "联系不上主机，没能重新登记这台设备的 SSH 密钥。")
    static let sshGaveUp = String(localized: "ssh.gaveUp",
                                  defaultValue: "连续几次都没连上，已停止重试。点「重连」再试。")
    static let settingsDiagnostics = String(localized: "settings.diagnostics", defaultValue: "诊断")
    static let settingsDiagnosticsDetail = String(localized: "settings.diagnostics.detail",
                                                  defaultValue: "这台设备自己的记录。复制后可以直接贴给维护者。")
    static let settingsDiagnosticsSsh = String(localized: "settings.diagnostics.ssh", defaultValue: "SSH 连接")
    static let settingsDiagnosticsApproval = String(localized: "settings.diagnostics.approval", defaultValue: "主机验证")
    static let settingsDiagnosticsEmpty = String(localized: "settings.diagnostics.empty", defaultValue: "这次启动之后还没有记录。")
    static let settingsDiagnosticsCopy = String(localized: "settings.diagnostics.copy", defaultValue: "复制")
    static let settingsDiagnosticsCopied = String(localized: "settings.diagnostics.copied", defaultValue: "已复制")
    /// UX-4 §2. The two fingerprints side by side: what this device would
    /// offer, and what the host has written down. They were only ever readable
    /// one at a time, on two different machines.
    static let settingsDiagnosticsKeyLocal = String(localized: "settings.diagnostics.key.local",
                                                    defaultValue: "本机 SSH 指纹")
    static let settingsDiagnosticsKeyHost = String(localized: "settings.diagnostics.key.host",
                                                   defaultValue: "主机登记的指纹")
    static let settingsDiagnosticsKeyNone = String(localized: "settings.diagnostics.key.none",
                                                   defaultValue: "主机没有这台设备的密钥")
    static let settingsDiagnosticsKeyMismatch = String(localized: "settings.diagnostics.key.mismatch",
                                                       defaultValue: "两边不一致：下次进 SSH 会自动重新登记一次。")
    static let settingsDiagnosticsKeyUnread = String(localized: "settings.diagnostics.key.unread",
                                                     defaultValue: "读不到主机登记的指纹。")
    static func settingsDiagnosticsIdentity(_ a: String) -> String {
        String(localized: "settings.diagnostics.identity", defaultValue: "主机认得这台设备的编号：\(a)")
    }
    static let notificationsDnd = String(localized: "notifications.dnd", defaultValue: "勿扰")
    static let notificationsDndOn = String(localized: "notifications.dnd.on", defaultValue: "勿扰开着：横幅不再弹，通知仍然进这张列表。")
    static func notificationsEarlier(_ a: String) -> String {
        String(localized: "notifications.earlier", defaultValue: "再往前 \(a) 条…")
    }
    static let notificationsClear = String(localized: "notifications.clear", defaultValue: "清除全部")
    static let notificationsClearConfirm = String(localized: "notifications.clear.confirm", defaultValue: "确认清除")
    static let notificationsDelete = String(localized: "notifications.delete", defaultValue: "删除这条通知")
    static let notificationsInvoke = String(localized: "notifications.invoke", defaultValue: "在电脑上打开")
    static let notificationsHistory = String(localized: "notifications.history", defaultValue: "历史")
    static let settingsNoHosts = String(localized: "settings.noHosts", defaultValue: "这台设备还没有配对过电脑。")
    static let settingsNoHostsDetail = String(localized: "settings.noHosts.detail", defaultValue: "在主机列表里选一台，在电脑上批准一次。")
    static let settingsFindHosts = String(localized: "settings.findHosts", defaultValue: "查找其它主机…")
    static let settingsRemote = String(localized: "settings.remote", defaultValue: "REMOTE")
    static let settingsMode = String(localized: "settings.mode", defaultValue: "默认模式")
    static let settingsBackend = String(localized: "settings.backend", defaultValue: "画面后端")
    static let settingsPlacement = String(localized: "settings.placement", defaultValue: "扩展屏摆放")
    static let settingsTouchMode = String(localized: "settings.touchMode", defaultValue: "触控方式")

    // STREAM-1
    static let streamPresetHost = String(localized: "stream.preset.host", defaultValue: "主机默认")
    static let streamPresetPerformance = String(localized: "stream.preset.performance", defaultValue: "速度优先")
    static let streamPresetBalanced = String(localized: "stream.preset.balanced", defaultValue: "平衡")
    static let streamPresetQuality = String(localized: "stream.preset.quality", defaultValue: "画质优先")
    static let streamPresetCustom = String(localized: "stream.preset.custom", defaultValue: "自定义")
    static let streamPresetAuto = String(localized: "stream.preset.auto", defaultValue: "自动")
    static let settingsStream = String(localized: "settings.stream", defaultValue: "串流")
    static let settingsStreamDetail = String(localized: "settings.stream.detail", defaultValue: "只对这台设备生效。串流中切换会原地重新连接一次，画面停一两秒。")
    static let settingsStreamPreset = String(localized: "settings.stream.preset", defaultValue: "清晰度")
    static let settingsStreamFrameRate = String(localized: "settings.stream.frameRate", defaultValue: "帧率")
    static let settingsStreamBitrate = String(localized: "settings.stream.bitrate", defaultValue: "码率")
    static let settingsStreamAutoDetail = String(localized: "settings.stream.autoDetail", defaultValue: "从画质优先起步；连续 5 秒丢帧超过 5 % 或延迟超过 80 ms 降一档，连续 60 秒稳定后升一档。")
    static let settingsDiagnosticsStream = String(localized: "settings.diagnostics.stream", defaultValue: "串流实时数据")
    static let settingsDiagnosticsStreamIdle = String(localized: "settings.diagnostics.streamIdle", defaultValue: "没有正在进行的 Sunshine 串流。")
    static func streamHostDefaultIs(_ a: String) -> String {
        String(localized: "stream.hostDefaultIs", defaultValue: "主机当前设为「\(a)」。")
    }
    static let settingsHostAudioDetail = String(localized: "settings.hostAudio.detail", defaultValue: "把主机的声音播到这台设备。VNC 后端没有音频通道。")
    static let settingsCornerHandle = String(localized: "settings.cornerHandle", defaultValue: "bar 隐藏时显示角落把手")
    static let settingsCornerHandleDetail = String(localized: "settings.cornerHandle.detail", defaultValue: "主机 bar 不在画面上时，画面角落留一个把手召唤面板。")
    static let remoteCornerHandle = String(localized: "remote.cornerHandle", defaultValue: "召唤面板")
    static let remoteMarkPanel = String(localized: "remote.mark.panel", defaultValue: "面板")
    static let settingsBarEntries = String(localized: "settings.barEntries", defaultValue: "BAR 上的入口")
    static let settingsBarEntriesNote = String(localized: "settings.barEntries.note", defaultValue: "关掉一项，它的入口从 bar 上消失；主机 bar 上的图标仍然打得开它。")
    static let settingsBarEntryLocked = String(localized: "settings.barEntry.locked", defaultValue: "设置自己不能关掉")
    static func settingsBarEntryLabel(_ a: String) -> String {
        String(localized: "settings.barEntry.label", defaultValue: "\(a) 的 bar 入口")
    }
    static let settingsDevice = String(localized: "settings.device", defaultValue: "这台设备")
    static let settingsBadge = String(localized: "settings.badge", defaultValue: "未读标记")
    static let settingsBarEdge = String(localized: "settings.barEdge", defaultValue: "bar 位置")
    static let settingsBarEdgeDetail = String(localized: "settings.barEdge.detail", defaultValue: "竖屏时在左还是右。横屏恒在上。")
    static let settingsAbout = String(localized: "settings.about", defaultValue: "关于")
    static let settingsVersion = String(localized: "settings.version", defaultValue: "版本")
    static let settingsContract = String(localized: "settings.contract", defaultValue: "契约")
    static let settingsRevoke = String(localized: "settings.revoke", defaultValue: "撤销")
    static func settingsRevokeOnHost(_ a: String) -> String {
        String(localized: "settings.revoke.onHost", defaultValue: "在电脑上跑 omodachi-host devices revoke \(a)。")
    }
    static let settingsForget = String(localized: "settings.forget", defaultValue: "忘记这台主机")
    static let settingsForgetConfirm = String(localized: "settings.forget.confirm", defaultValue: "再按一次以忘记")
    static let settingsPinnedAt = String(localized: "settings.pinnedAt", defaultValue: "配对时钉住")
    static let settingsPresentedNow = String(localized: "settings.presentedNow", defaultValue: "现在出示")
    static let settingsTrustCertificate = String(localized: "settings.trustCertificate", defaultValue: "确认信任新证书")
    static let settingsTrustCertificateConfirm = String(localized: "settings.trustCertificate.confirm", defaultValue: "再按一次以信任")

    // AUTH-1. The host's own words never appear here: a service name, a
    // host name and the line describing the prompt all arrive from the
    // machine and are drawn verbatim.
    static let settingsApproval = String(localized: "settings.approval", defaultValue: "主机验证")
    static let settingsApprovalToggle = String(localized: "settings.approval.toggle", defaultValue: "用生物识别批准主机验证")
    static let settingsApprovalDetail = String(localized: "settings.approval.detail", defaultValue: "电脑弹出密码框时，可以在这台设备上用 Face ID 或 Touch ID 通过。主机那边也要打开这个开关。")
    static let settingsApprovalHostOff = String(localized: "settings.approval.hostOff", defaultValue: "主机上的开关还没打开。在插件设置里打开后才会生效。")
    static let settingsShowUnrunnable = String(localized: "settings.showUnrunnable", defaultValue: "显示无法在此执行的绑定")
    static let settingsShowUnrunnableDetail = String(localized: "settings.showUnrunnable.detail", defaultValue: "主机把这几条快捷键绑在 Lua 函数上，没有可执行的记录，这台设备永远跑不了。打开后它们回到列表里，仍然是灰的。")
    static let settingsClipboard = String(localized: "settings.clipboard", defaultValue: "剪贴板")
    static let settingsClipboardDirection = String(localized: "settings.clipboard.direction", defaultValue: "跨设备剪贴板")
    static let settingsClipboardDetail = String(localized: "settings.clipboard.detail", defaultValue: "单向：主机上复制的文字自动到这台设备。双向：这台设备复制的文字也送到主机。主机那边也要打开。只同步文字，上限 64 KB。")
    static let settingsClipboardOff = String(localized: "settings.clipboard.off", defaultValue: "关")
    static let settingsClipboardOneWay = String(localized: "settings.clipboard.oneWay", defaultValue: "单向")
    static let settingsClipboardBoth = String(localized: "settings.clipboard.both", defaultValue: "双向")
    static let settingsClipboardPasteBanner = String(localized: "settings.clipboard.pasteBanner", defaultValue: "双向时，每次回到 App，iOS 会问一次是否允许粘贴。允许后这次复制的文字才送到主机。")
    static let settingsClipboardHostOff = String(localized: "settings.clipboard.hostOff", defaultValue: "主机上的开关还没打开，或者只开到单向。在插件设置里改。")
    static let settingsClipboardHostUnsupported = String(localized: "settings.clipboard.hostUnsupported", defaultValue: "这台主机不共享剪贴板。升级主机上的 Omodachi 服务后可用。")
    static let settingsClipboardMoved = String(localized: "settings.clipboard.moved", defaultValue: "已同步")
    static let settingsClipboardSend = String(localized: "settings.clipboard.send", defaultValue: "把本机剪贴板送到主机")
    static func settingsClipboardCounts(_ a: String, _ b: String) -> String {
        String(localized: "settings.clipboard.counts", defaultValue: "收到 \(a) · 送出 \(b)")
    }
    static let reasonClipboardSyncDisabled = String(localized: "reason.clipboardSyncDisabled", defaultValue: "主机上的剪贴板开关是关的。")
    static let reasonClipboardWriteDisabled = String(localized: "reason.clipboardWriteDisabled", defaultValue: "主机只把剪贴板送出来，不接收。")
    static let reasonClipboardTooLarge = String(localized: "reason.clipboardTooLarge", defaultValue: "剪贴板内容超过 64 KB，没有同步。")
    static let reasonClipboardNotText = String(localized: "reason.clipboardNotText", defaultValue: "剪贴板里不是文字。这一版只同步文字。")
    static let reasonClipboardInvalid = String(localized: "reason.clipboardInvalid", defaultValue: "这份剪贴板内容送不出去。")
    static let reasonClipboardUnavailable = String(localized: "reason.clipboardUnavailable", defaultValue: "读不到主机的剪贴板。")
    static let settingsApprovalUnsupported = String(localized: "settings.approval.unsupported", defaultValue: "这台主机还不支持设备批准。更新主机服务后再试。")
    static let settingsApprovalNoBiometry = String(localized: "settings.approval.noBiometry", defaultValue: "这台设备没有可用的 Face ID 或 Touch ID。")
    static let settingsApprovalKeys = String(localized: "settings.approval.keys", defaultValue: "已注册的密钥")
    static let settingsApprovalEnclave = String(localized: "settings.approval.enclave", defaultValue: "安全隔区")
    static let settingsApprovalKeychain = String(localized: "settings.approval.keychain", defaultValue: "钥匙串")
    static let settingsApprovalOff = String(localized: "settings.approval.off", defaultValue: "已关闭")
    static let settingsApprovalNone = String(localized: "settings.approval.none", defaultValue: "还没有设备注册过密钥。")
    static func approvalNotificationTitle(_ a: String) -> String {
        String(localized: "approval.notification.title", defaultValue: "\(a) 在等你确认")
    }
    static func approvalPromptReason(_ a: String, _ b: String) -> String {
        String(localized: "approval.prompt.reason", defaultValue: "在 \(a) 上通过\(b)")
    }
    static func approvalEnrollReason(_ a: String) -> String {
        String(localized: "approval.enroll.reason", defaultValue: "注册这台设备，用来批准 \(a) 的密码框")
    }
    static func approvalRevokeOnHost(_ a: String) -> String {
        String(localized: "approval.revoke.onHost", defaultValue: "在电脑上跑 omodachi-host auth revoke 来撤销 \(a)。")
    }
    static let approvalErrorNoBiometry = String(localized: "approval.error.noBiometry", defaultValue: "生物识别不可用，已回到密码。")
    static let approvalErrorKeyInvalid = String(localized: "approval.error.keyInvalid", defaultValue: "密钥已失效，请重新注册。")
    static let approvalErrorCancelled = String(localized: "approval.error.cancelled", defaultValue: "已取消，电脑会继续要密码。")
    static let approvalErrorGeneric = String(localized: "approval.error.generic", defaultValue: "这次没能通过，电脑会继续要密码。")
    static let approvalToastAsking = String(localized: "approval.toast.asking", defaultValue: "主机在等你确认")
    static let approvalToastApproved = String(localized: "approval.toast.approved", defaultValue: "已通过")
    static let approvalToastDeclined = String(localized: "approval.toast.declined", defaultValue: "已拒绝")
    static let approvalToastTimeout = String(localized: "approval.toast.timeout", defaultValue: "已超时")
    static let approvalDecline = String(localized: "approval.decline", defaultValue: "拒绝")
    static let badgeDot = String(localized: "badge.dot", defaultValue: "点")
    static let badgeCount = String(localized: "badge.count", defaultValue: "数字")
    static let badgeHidden = String(localized: "badge.hidden", defaultValue: "不显示")
    static func hostsFoundOnWifi(_ a: String) -> String {
        String(localized: "hosts.foundOnWifi", defaultValue: "这个 Wi-Fi 上的 \(a) 台")
    }
    static let hostsSearching = String(localized: "hosts.searching", defaultValue: "正在查找")
    static let hostsSearchingDetail = String(localized: "hosts.searchingDetail", defaultValue: "正在这个 Wi-Fi 上查找电脑…")
    static let hostsLanSearch = String(localized: "hosts.lanSearch", defaultValue: "局域网查找")
    static let hostsNone = String(localized: "hosts.none", defaultValue: "在这个 Wi-Fi 上没有找到任何电脑。")
    static let hostsNoneDetail = String(localized: "hosts.noneDetail", defaultValue: "确认电脑上 Host 在跑，两台设备在同一个 Wi-Fi 上。")
    static let hostsSearchAgain = String(localized: "hosts.searchAgain", defaultValue: "再找一次")
    /// PAIR-5 §2: the one line that tells a returning device why it is looking
    /// at the host list again instead of at its Panel.
    static func hostsCredentialStale(_ a: String) -> String {
        String(localized: "hosts.credentialStale", defaultValue: "\(a) 不再认这台设备的凭据，本机已经把它清掉了。点这一行重新配对。")
    }
    /// CORE-2 §1: the same line for a refusal the host explained — who, why,
    /// and what to do about it.
    static func hostsCredentialLine(_ a: String, _ b: String, _ c: String) -> String {
        String(localized: "hosts.credentialLine", defaultValue: "\(a)：\(b)\(c)")
    }
    static let hostsCredentialExpiredAction = String(localized: "hosts.credentialExpiredAction", defaultValue: "点这一行重新配对，在电脑上批准一次就好。")
    static let hostsCredentialRevokedAction = String(localized: "hosts.credentialRevokedAction", defaultValue: "本机已经把它放下了。不是你撤销的话，先去电脑上看一眼；要重新连接，点这一行重新配对。")
    static let hostsPermission = String(localized: "hosts.permission", defaultValue: "本地网络权限")
    static let hostsPermissionDetail = String(localized: "hosts.permissionDetail", defaultValue: "Omodachi 还没拿到「本地网络」权限。")
    static let hostsPermissionAsk = String(localized: "hosts.permissionAsk", defaultValue: "再问一次")
    static let hostsManual = String(localized: "hosts.manual", defaultValue: "手动添加…")
    static let hostsManualTitle = String(localized: "hosts.manualTitle", defaultValue: "手动添加")
    static let hostsManualField = String(localized: "hosts.manualField", defaultValue: "主机名或 IP")
    static let hostsManualNote = String(localized: "hosts.manualNote", defaultValue: "手动添加不需要局域网发现权限。")
    static let pairingRequest = String(localized: "pairing.request", defaultValue: "请求配对")
    static let pairingRequesting = String(localized: "pairing.requesting", defaultValue: "正在请求连接")
    static let pairingWaiting = String(localized: "pairing.waiting", defaultValue: "等待电脑上批准")
    static let pairingGrants = String(localized: "pairing.grants", defaultValue: "这一次批准授予")
    static let pairingFingerprint = String(localized: "pairing.fingerprint", defaultValue: "证书指纹 · 前 8 位")
    static let pairingReadingFingerprint = String(localized: "pairing.readingFingerprint", defaultValue: "正在读取证书指纹…")
    static let pairingCompareFingerprint = String(localized: "pairing.compareFingerprint", defaultValue: "在电脑上核对这 8 位，两边一样就按 Approve。")
    static let pairingApproveOnComputer = String(localized: "pairing.approveOnComputer", defaultValue: "在电脑上按一次 Approve。屏幕、终端、Agent 一起授权。")
    static let pairingExpired = String(localized: "pairing.expired", defaultValue: "这次请求过期了")
    static func pairingExpiredDetail(_ a: String) -> String {
        String(localized: "pairing.expiredDetail", defaultValue: "请求 5 分钟有效，这段时间里没有人在 \(a) 上批准。")
    }
    static let pairingRejected = String(localized: "pairing.rejected", defaultValue: "电脑上拒绝了这次连接")
    static func pairingRejectedDetail(_ a: String) -> String {
        String(localized: "pairing.rejectedDetail", defaultValue: "按 Reject 的不是你，就先确认 \(a) 真的是你的电脑。")
    }
    static let pairingNotStarted = String(localized: "pairing.notStarted", defaultValue: "这次配对没有开始")
    static let pairingAgain = String(localized: "pairing.again", defaultValue: "再请求一次")
    static let pairingOther = String(localized: "pairing.other", defaultValue: "换一台")
    static let pairingRefused = String(localized: "pairing.refused", defaultValue: "连接被拒绝")
    static let pairingInviteOnly = String(localized: "pairing.inviteOnly", defaultValue: "这台电脑开启了邀请模式")
    static func pairingInviteOnlyDetail(_ a: String) -> String {
        String(localized: "pairing.inviteOnlyDetail", defaultValue: "\(a) 要一段一次性邀请码，所以请求没有发出去。")
    }
    static let pairingInviteHow = String(localized: "pairing.inviteHow", defaultValue: "在电脑上跑 omodachi-host pair begin，把它给的邀请贴进来。")
    static func pairingCertificateChanged(_ a: String) -> String {
        String(localized: "pairing.certificateChanged", defaultValue: "\(a) 的证书变了")
    }
    static let gateSshHostKey = String(localized: "gate.sshHostKey", defaultValue: "验证主机密钥")
    static let gateSshHostKeyNew = String(localized: "gate.sshHostKey.new", defaultValue: "新的 SSH 主机")
    static let gateSshHostKeyHost = String(localized: "gate.sshHostKey.host", defaultValue: "主机")
    static let gateSshHostKeyAlgorithm = String(localized: "gate.sshHostKey.algorithm", defaultValue: "算法")
    static let gateSshHostKeyDetail = String(localized: "gate.sshHostKey.detail", defaultValue: "在电脑上核对这串指纹。钉住的记录只留在这台设备上。")
    static let gateSshHostKeyTrust = String(localized: "gate.sshHostKey.trust", defaultValue: "信任这个主机密钥")
    static let gateSshHostKeyReject = String(localized: "gate.sshHostKey.reject", defaultValue: "取消连接")
    static func workspaceLayoutApply(_ a: String, _ b: String) -> String {
        String(localized: "workspace.layout.apply", defaultValue: "工作区 \(a) 换成 \(b)")
    }
    static let hostsPermissionAskDetail = String(localized: "hosts.permissionAskDetail", defaultValue: "iOS 会问一次「本地网络」。在它问之前，系统设置里没有这一项。")
    static func remoteOwnedBy(_ a: String) -> String {
        String(localized: "remote.ownedBy", defaultValue: "现在用它的是 \(a)")
    }
    static let hostManualHint = String(localized: "host.manualHint", defaultValue: "只要主机名或 IP。端口与 https 由 App 补齐。")
    // GEST-1 / A-64 / N-37: the picture's own gestures, and what they resolve to.
    static let gestureSection = String(localized: "gesture.section", defaultValue: "手势")
    static let gestureSectionNote = String(localized: "gesture.sectionNote", defaultValue: "画面里的手势是主机上那一行的别名：主机改绑定，手势跟着改；主机没有那一行，手势就不存在。")
    static let gestureThreeFingerTap = String(localized: "gesture.threeFingerTap", defaultValue: "三指轻点")
    static let gestureThreeFingerLeft = String(localized: "gesture.threeFingerLeft", defaultValue: "三指左滑")
    static let gestureThreeFingerRight = String(localized: "gesture.threeFingerRight", defaultValue: "三指右滑")
    static let gestureThreeFingerUp = String(localized: "gesture.threeFingerUp", defaultValue: "三指上滑")
    static let gesturePinch = String(localized: "gesture.pinch", defaultValue: "三指捏合 / 张开")
    static let gestureWorkspaceNext = String(localized: "gesture.workspaceNext", defaultValue: "下一个工作区")
    static let gestureWorkspacePrevious = String(localized: "gesture.workspacePrevious", defaultValue: "上一个工作区")
    static let gestureKeyboardLocal = String(localized: "gesture.keyboardLocal", defaultValue: "本机软键盘")
    static let gestureNoHostBinding = String(localized: "gesture.noHostBinding", defaultValue: "主机没有此绑定")
    static let gestureNoWorkspaces = String(localized: "gesture.noWorkspaces", defaultValue: "主机没有可切换的工作区")
    static let settingsMultitaskingGestures = String(localized: "settings.multitaskingGestures", defaultValue: "Remote 的三指手势和 iPadOS 的多任务手势抢同一只手。在系统设置里关掉多任务手势。")
    static let pairingCertificateChangedDetail = String(localized: "pairing.certificateChangedDetail", defaultValue: "刚跑过 omodachi-host tls rotate 就是预期的。否则不要信任。")
    static func agentModelValue(_ a: String, _ b: String) -> String {
        String(localized: "agent.modelValue", defaultValue: "模型 \(a)，强度 \(b)")
    }
    static let agentContext = String(localized: "agent.context", defaultValue: "上下文")
    static func pair(_ a: String, _ b: String) -> String {
        String(localized: "pair", defaultValue: "\(a)，\(b)")
    }
    static func percent(_ a: String, _ b: String) -> String {
        String(localized: "percent", defaultValue: "\(a) 百分之 \(b)")
    }
    static let pairingDelivered = String(localized: "pairing.delivered", defaultValue: "已送达")
    static let keybindingsRefreshFirst = String(localized: "keybindings.refreshFirst", defaultValue: "先刷新主机的快捷键列表。")
    static let keybindingsRemoteUpdating = String(localized: "keybindings.remoteUpdating", defaultValue: "Remote 正在更新，等画面就绪再试。")
    static let keybindingsSent = String(localized: "keybindings.sent", defaultValue: "已发出，等主机的结果。")
    static let keybindingsDone = String(localized: "keybindings.done", defaultValue: "已执行。")
    static let keybindingsGone = String(localized: "keybindings.gone", defaultValue: "主机上没有这一行了，刷新一下。")
    static let keybindingsUnconfirmed = String(localized: "keybindings.unconfirmed", defaultValue: "结果没有确认，先在电脑上看一眼。")
    static let keybindingsNoFocusedWindow = String(localized: "keybindings.noFocusedWindow", defaultValue: "主机上没有聚焦的窗口。")
    static let keybindingsStale = String(localized: "keybindings.stale", defaultValue: "列表过期了，已刷新并重发。")
    // PERF-5: the receipt that says the row did not run. The line above is for
    // the path that really does resend; this one does not claim it.
    static let keybindingsOutOfDate = String(localized: "keybindings.outOfDate", defaultValue: "列表过期了，这一行没有执行。下拉刷新后再试。")
    static func keybindingsRanHere(_ a: String) -> String {
        String(localized: "keybindings.ranHere", defaultValue: "在这台设备上打开了 \(a)。")
    }
    static func keybindingsNowOnWorkspace(_ a: String) -> String {
        String(localized: "keybindings.nowOnWorkspace", defaultValue: "已到工作区 \(a)。")
    }
    static func keybindingsNowFocused(_ a: String) -> String {
        String(localized: "keybindings.nowFocused", defaultValue: "已聚焦 \(a)。")
    }
    static let keybindingsChanged = String(localized: "keybindings.changed", defaultValue: "主机上变了。")

    // ARCH-1 §6, second pass: the words layers 1–3 still had written down.
    static let hostPairingNew = String(localized: "host.pairing.new", defaultValue: "未配对")
    static let hostPairingPaired = String(localized: "host.pairing.paired", defaultValue: "已配对")
    static let hostPairingUnconfirmed = String(localized: "host.pairing.unconfirmed", defaultValue: "待确认")
    static let hostPairingCertChanged = String(localized: "host.pairing.certChanged", defaultValue: "证书已更改")
    static let hostPairingInviteNeeded = String(localized: "host.pairing.inviteNeeded", defaultValue: "需要邀请")
    static let menuLayoutUnknown = String(localized: "menu.layout.unknown", defaultValue: "工作区布局 · 状态未知")
    static let menuLayoutStale = String(localized: "menu.layout.stale", defaultValue: "目标工作区已变。取消后重新选。")
    static let menuLayoutScope = String(localized: "menu.layout.scope", defaultValue: "只改这里显示的工作区。")
    static func menuHostLockedValue(_ a: String) -> String {
        String(localized: "menu.host.lockedValue", defaultValue: "\(a)，会话进行中不能换")
    }
    static let menuEmpty = String(localized: "menu.empty", defaultValue: "连上主机后这里是它的菜单。")
    static let menuEmptyNoMatch = String(localized: "menu.empty.noMatch", defaultValue: "没有匹配的菜单项")
    static let menuEmptySearchHint = String(localized: "menu.empty.searchHint", defaultValue: "搜索覆盖合并后的菜单。")
    static let menuRootPath = String(localized: "menu.rootPath", defaultValue: "Omarchy 菜单")
    static let pinnedEdit = String(localized: "pinned.edit", defaultValue: "编辑")
    static let herdrClosePaneTitle = String(localized: "herdr.closePaneTitle", defaultValue: "关闭这个 pane？")
    static let herdrLoadingLayout = String(localized: "herdr.loadingLayout", defaultValue: "正在读取布局…")
    static let herdrNoPanesDetail = String(localized: "herdr.noPanesDetail", defaultValue: "在主机上开一个 pane，这里会出现。")
    static let herdrLoading = String(localized: "herdr.loading", defaultValue: "正在读取…")
    static let herdrNoWorkspace = String(localized: "herdr.noWorkspace", defaultValue: "这个会话里没有 workspace。")
    static let herdrSession = String(localized: "herdr.session", defaultValue: "Herdr 会话")
    static let herdrSessionOwned = String(localized: "herdr.session.owned", defaultValue: "Omodachi 自建")
    static let herdrSessionStopped = String(localized: "herdr.session.stopped", defaultValue: "已停止")
    static let herdrSessionUnreadable = String(localized: "herdr.session.unreadable", defaultValue: "没有应答")
    static let herdrSessionEmpty = String(localized: "herdr.session.empty", defaultValue: "还没有 pane")
    static let herdrSessionSwitching = String(localized: "herdr.session.switching", defaultValue: "正在切换会话…")
    static func herdrSessionShape(_ a: String, _ b: String, _ c: String) -> String {
        String(localized: "herdr.session.shape", defaultValue: "\(a) 工作区 · \(b) pane · \(c) agent")
    }
    static let remoteTouchHintTouchpad = String(localized: "remote.touchHint.touchpad", defaultValue: "滑动移指针，轻点点击，长按拖动")
    static let remoteTouchHintDirect = String(localized: "remote.touchHint.direct", defaultValue: "点画面直接操作，按住拖动")
    static func remoteTouchHintRest(_ a: String) -> String {
        String(localized: "remote.touchHint.rest", defaultValue: "\(a)；双指滚动，三指轻点切键盘，三指左右滑切工作区。")
    }
    static let remoteStartExtend = String(localized: "remote.startExtend", defaultValue: "开始扩展")
    static let remoteStartTakeoverShort = String(localized: "remote.startTakeoverShort", defaultValue: "开始接管")
    static func remoteUseVNCWith(_ a: String) -> String {
        String(localized: "remote.useVNCWith", defaultValue: "用 VNC \(a)")
    }
    static let remoteStepPrepare = String(localized: "remote.step.prepare", defaultValue: "准备主机输出")
    static let remoteStepWaitFrame = String(localized: "remote.step.waitFrame", defaultValue: "等待画面")
    static let notificationsEmpty = String(localized: "notifications.empty", defaultValue: "电脑上还没有通知。")
    static let notificationsLoading = String(localized: "notifications.loading", defaultValue: "正在读电脑上的通知…")
    static let notificationsEmptyDetail = String(localized: "notifications.emptyDetail", defaultValue: "主机上弹出的每一条都会到这里。")
    static func notificationsUnreadCount(_ a: String) -> String {
        String(localized: "notifications.unreadCount", defaultValue: "未读 \(a)")
    }
    static let notificationsAll = String(localized: "notifications.all", defaultValue: "全部")
    static let notificationsDndUnknown = String(localized: "notifications.dndUnknown", defaultValue: "主机还没有报告")
    static let settingsConnected = String(localized: "settings.connected", defaultValue: "已连接")
    static func settingsSwitchedTo(_ a: String) -> String {
        String(localized: "settings.switchedTo", defaultValue: "已切到 \(a)。")
    }
    static let settingsPlacementLeft = String(localized: "settings.placement.left", defaultValue: "左")
    static let settingsPlacementRight = String(localized: "settings.placement.right", defaultValue: "右")
    static let settingsPlacementAbove = String(localized: "settings.placement.above", defaultValue: "上")
    static let settingsPlacementBelow = String(localized: "settings.placement.below", defaultValue: "下")
    static let settingsTouchDirect = String(localized: "settings.touch.direct", defaultValue: "直接触摸")
    static let settingsTouchTouchpad = String(localized: "settings.touch.touchpad", defaultValue: "触控板")
    static let settingsForgetPartial = String(localized: "settings.forgetPartial", defaultValue: "钥匙串拒绝删除部分凭据。主机已从列表移除，解锁后再忘记一次可清干净。")
    static let pairingStepExpired = String(localized: "pairing.step.expired", defaultValue: "5 分钟内没人批准")
    static let pairingStepRejected = String(localized: "pairing.step.rejected", defaultValue: "电脑上按了 Reject")
    static let pairingStepNotDelivered = String(localized: "pairing.step.notDelivered", defaultValue: "没能送达")
    static let pairingThisComputer = String(localized: "pairing.thisComputer", defaultValue: "这台电脑")
    static let pairingGrantScreen = String(localized: "pairing.grant.screen", defaultValue: "屏幕")
    static let pairingGrantTerminal = String(localized: "pairing.grant.terminal", defaultValue: "终端")
    static let pairingGrantAgent = String(localized: "pairing.grant.agent", defaultValue: "Agent")
    static let pairingInviteField = String(localized: "pairing.inviteField", defaultValue: "43 位邀请")
    static let hostsTitlePairing = String(localized: "hosts.title.pairing", defaultValue: "配对")
    static let hostsTitleConnect = String(localized: "hosts.title.connect", defaultValue: "连接到电脑")
    static let routeUnavailable = String(localized: "route.unavailable", defaultValue: "这个入口本机打不开，会话保留。")
    static let badgeLive = String(localized: "badge.live", defaultValue: "进行中")
    static func badgePendingApprovals(_ a: String) -> String {
        String(localized: "badge.pendingApprovals", defaultValue: "\(a) 条待审批")
    }
    static let badgeDisconnected = String(localized: "badge.disconnected", defaultValue: "已断开")
    static func badgeUnread(_ a: String) -> String {
        String(localized: "badge.unread", defaultValue: "\(a) 条未读")
    }

    // MARK: - I18N-1 §2: core's reason codes

    static let reasonRemoteSessionExists = String(localized: "reason.remote.sessionExists", defaultValue: "主机上已经有一个 Remote 会话。请先在原设备上结束它。")
    static let reasonStaleRevision = String(localized: "reason.staleRevision", defaultValue: "主机上的会话已经变了，请重试。")
    static let reasonSessionNotFound = String(localized: "reason.sessionNotFound", defaultValue: "这个会话已经结束。")
    static let reasonSessionNotReady = String(localized: "reason.sessionNotReady", defaultValue: "主机正在切换会话，稍后重试。")
    static let reasonRemotePermissionDenied = String(localized: "reason.remote.permissionDenied", defaultValue: "这个 Remote 会话属于另一台设备。")
    static let reasonMediaPairingRequired = String(localized: "reason.mediaPairingRequired", defaultValue: "Sunshine 还没批准这台设备的串流证书。")
    static let reasonWayvncRequired = String(localized: "reason.wayvncRequired", defaultValue: "主机没装 WayVNC 0.10.1，VNC 用不了。")
    static let reasonSunshineDesktopUnavailable = String(localized: "reason.sunshineDesktopUnavailable", defaultValue: "主机上的 Sunshine 没有在跑受管桌面控制。")
    static let reasonSunshineControlUnavailable = String(localized: "reason.sunshineControlUnavailable", defaultValue: "暂时联系不上主机的 Sunshine。")
    static let reasonBackendNotInstalled = String(localized: "reason.backendNotInstalled", defaultValue: "这台主机没有装 Sunshine 后端。")
    static let reasonSunshineAssetsMissing = String(localized: "reason.sunshineAssetsMissing", defaultValue: "Sunshine 在软件编码，延迟会明显偏高。")
    static let reasonRemoteRuntimeUnavailable = String(localized: "reason.remoteRuntimeUnavailable", defaultValue: "这台电脑现在没有图形会话，开不了 Remote。")
    static let reasonDynamicResolutionDenied = String(localized: "reason.dynamicResolutionDenied", defaultValue: "主机不允许远端改这块屏的几何，画面保持原尺寸。")
    static let reasonHostWaking = String(localized: "reason.hostWaking", defaultValue: "主机屏幕正在唤醒，稍后重试。")
    static let reasonVncBridgeUnavailable = String(localized: "reason.vncBridgeUnavailable", defaultValue: "主机的 VNC 通道还没准备好，请重试。")
    static let reasonVncBridgeExists = String(localized: "reason.vncBridgeExists", defaultValue: "这个会话上已经有一个 VNC 通道。")
    static let reasonProfileUnsupported = String(localized: "reason.profileUnsupported", defaultValue: "主机无法为当前屏幕比例或密度生成画面规格。")
    static let reasonRemoteRefused = String(localized: "reason.remoteRefused", defaultValue: "主机拒绝了这次 Remote 请求。请刷新连接后重试。")
    static let reasonRemoteSessionRequired = String(localized: "reason.remoteSessionRequired", defaultValue: "Remote 正在用这台主机的工作区。请在 Remote 画面里切换。")
    static let reasonDisplayOutputLimit = String(localized: "reason.displayOutputLimit", defaultValue: "主机的显示输出已经用满。")
    static let reasonDisplayAsleep = String(localized: "reason.displayAsleep", defaultValue: "主机屏幕已休眠。先唤醒它再试。")
    static let reasonDisplayCommandFailed = String(localized: "reason.displayCommandFailed", defaultValue: "主机没能改动这块屏。")
    static let reasonResizeFailed = String(localized: "reason.resizeFailed", defaultValue: "主机没能按新的尺寸调整画面。")
    static let reasonReleaseFailed = String(localized: "reason.releaseFailed", defaultValue: "主机没能收回这次会话，稍后会自己超时。")
    static let reasonExpiredAwaitingCleanup = String(localized: "reason.expiredAwaitingCleanup", defaultValue: "会话已过期，主机正在收尾 Sunshine。")
    static let reasonSunshineRevocationUnavailable = String(localized: "reason.sunshineRevocationUnavailable", defaultValue: "主机无法撤销这张串流证书，请在电脑上处理。")
    static let reasonSunshineUnitUnreadable = String(localized: "reason.sunshineUnitUnreadable", defaultValue: "主机读不到 Sunshine 的服务定义。")
    static let reasonDisabledOutputLeft = String(localized: "reason.disabledOutputLeft", defaultValue: "主机留下了一块关掉的输出，需要在电脑上恢复。")
    static let reasonMediaPairingUnavailable = String(localized: "reason.mediaPairingUnavailable", defaultValue: "主机没有在跑受管 Sunshine 的配对桥。")
    static let reasonMediaRequestNotUnique = String(localized: "reason.mediaRequestNotUnique", defaultValue: "主机上没有正好一个属于本设备的待配对请求。请重新发起。")
    static let reasonMediaRequestNotPending = String(localized: "reason.mediaRequestNotPending", defaultValue: "这个配对请求已经不在等待中，请重新发起。")
    static let reasonMediaCertificateAssociated = String(localized: "reason.mediaCertificateAssociated", defaultValue: "这张证书已经和主机配对过了。")
    static let reasonMediaBindingMismatch = String(localized: "reason.mediaBindingMismatch", defaultValue: "配对绑定与本设备不符，请重新发起。")
    static let reasonMediaPermissionRequired = String(localized: "reason.mediaPermissionRequired", defaultValue: "主机还没有授权本设备串流。请在电脑上批准。")
    static let reasonMediaInvalidPin = String(localized: "reason.mediaInvalidPin", defaultValue: "PIN 不是四位数字。")
    static let reasonMediaCapacity = String(localized: "reason.mediaCapacity", defaultValue: "主机上待处理的配对太多，稍后再试。")
    static let reasonMediaNotFound = String(localized: "reason.mediaNotFound", defaultValue: "这次配对尝试已经不在主机上了。")
    static let reasonMediaTimeout = String(localized: "reason.mediaTimeout", defaultValue: "主机的配对桥没有及时响应。")
    static let reasonMediaRefused = String(localized: "reason.mediaRefused", defaultValue: "主机拒绝了这次配对请求。请刷新连接后重试。")
    static let reasonMediaPinSpent = String(localized: "reason.mediaPinSpent", defaultValue: "这次配对的一次性验证码已经用过了。退出后再补一次配对。")
    static let reasonMediaGrantRevoked = String(localized: "reason.mediaGrantRevoked", defaultValue: "主机撤销了本设备的串流授权。")
    static let reasonMediaRevocationPending = String(localized: "reason.mediaRevocationPending", defaultValue: "主机还在撤销上一张证书，稍后再试。")
    static let reasonMediaStateUnavailable = String(localized: "reason.mediaStateUnavailable", defaultValue: "读不到主机的串流配对状态。")
    static let reasonHerdrControlInUse = String(localized: "reason.herdrControlInUse", defaultValue: "另一端正在控制这个 pane。当前是只读观察。")
    static let reasonHerdrUnavailable = String(localized: "reason.herdrUnavailable", defaultValue: "主机的 Herdr 会话没有应答。")
    static let reasonHerdrRequestFailed = String(localized: "reason.herdrRequestFailed", defaultValue: "Herdr 拒绝了这次操作。")
    static let reasonInvalidPane = String(localized: "reason.invalidPane", defaultValue: "这个 pane 已经不在主机的布局里了。")
    static let reasonInvalidWorkspace = String(localized: "reason.invalidWorkspace", defaultValue: "这个 workspace 已经不在主机的布局里了。")
    static let reasonInvalidGeometry = String(localized: "reason.invalidGeometry", defaultValue: "终端尺寸超出 Herdr 能接受的范围。")
    static let reasonHerdrActionUnsupported = String(localized: "reason.herdrActionUnsupported", defaultValue: "主机的 Herdr 桥不支持这个动作。")
    static let reasonVoxtypeNotInstalled = String(localized: "reason.voxtypeNotInstalled", defaultValue: "电脑上没有装 Voxtype。")
    static let reasonVoiceUplinkDisabled = String(localized: "reason.voiceUplinkDisabled", defaultValue: "电脑上关掉了语音上行。")
    static let reasonAudioInputBusy = String(localized: "reason.audioInputBusy", defaultValue: "别的东西正在用电脑的麦克风输入。")
    static let reasonAudioInputUnavailable = String(localized: "reason.audioInputUnavailable", defaultValue: "电脑现在收不了麦克风流。")
    static let reasonAudioBackendNotInstalled = String(localized: "reason.audioBackendNotInstalled", defaultValue: "电脑上没有装音频后端。")
    static let reasonAudioBackendUnavailable = String(localized: "reason.audioBackendUnavailable", defaultValue: "电脑的音频后端没有应答。")
    static let reasonAudioCleanupPending = String(localized: "reason.audioCleanupPending", defaultValue: "电脑还在收尾上一次录音，稍后再试。")
    static let reasonAudioBackpressure = String(localized: "reason.audioBackpressure", defaultValue: "音频上行跟不上，本次录音已停。")
    static let reasonVoxtypeWaitUnsupported = String(localized: "reason.voxtypeWaitUnsupported", defaultValue: "这个 Voxtype 太旧，等不到转写结果。")
    static let reasonVoxtypeConfigUnsupported = String(localized: "reason.voxtypeConfigUnsupported", defaultValue: "Voxtype 的配置里没有指向麦克风的音频设备。")
    static let reasonVoxtypeServiceInactive = String(localized: "reason.voxtypeServiceInactive", defaultValue: "电脑上装了 Voxtype 但没在跑。")
    static let reasonMicrophonePermissionDenied = String(localized: "reason.microphonePermissionDenied", defaultValue: "iOS 设置里关掉了 Omodachi 的麦克风权限。")
    static let reasonRouteChanged = String(localized: "reason.routeChanged", defaultValue: "麦克风换了，录音已停。准备好再开始。")
    static let reasonInterrupted = String(localized: "reason.interrupted", defaultValue: "别的东西抢走了麦克风，录音已停。")
    static let reasonAudioSessionError = String(localized: "reason.audioSessionError", defaultValue: "这台设备打不开自己的麦克风。")
    static let reasonConversionFailed = String(localized: "reason.conversionFailed", defaultValue: "麦克风格式转不成电脑要的样子。")
    static let reasonTransportClosed = String(localized: "reason.transportClosed", defaultValue: "到电脑麦克风的连接断了。")
    static let reasonVoiceHostUnavailable = String(localized: "reason.voiceHostUnavailable", defaultValue: "现在连不上电脑的语音通道。")
    static let reasonVoiceUserDisabled = String(localized: "reason.voiceUserDisabled", defaultValue: "你停掉了这次录音。")
    static let reasonVoiceSessionEnd = String(localized: "reason.voiceSessionEnd", defaultValue: "会话结束，录音一起停了。")
    static let reasonVoiceDisconnected = String(localized: "reason.voiceDisconnected", defaultValue: "和电脑断开了，录音已停。")
    static let reasonVoiceReady = String(localized: "reason.voiceReady", defaultValue: "电脑的语音通道已就绪。")
    static let reasonHandoffRequired = String(localized: "reason.handoffRequired", defaultValue: "现有的 agent 需要做一次连接交接。")
    static let reasonAgentBusy = String(localized: "reason.agentBusy", defaultValue: "agent 正在干活，任务保留着。空了再试。")
    static let reasonHandoffRolledBack = String(localized: "reason.handoffRolledBack", defaultValue: "连接没能改动，原来的终端和对话已复原。")
    static let reasonHandoffStale = String(localized: "reason.handoffStale", defaultValue: "会话变了或方案过期。看一份新的再继续。")
    static let reasonHandoffUnconfirmed = String(localized: "reason.handoffUnconfirmed", defaultValue: "交接结果未确认。先检查现有会话再重试。")
    static let reasonHandoffTransportUnavailable = String(localized: "reason.handoffTransportUnavailable", defaultValue: "这次交接需要的通道还没连上。")
    static let reasonAgentStartFailed = String(localized: "reason.agentStartFailed", defaultValue: "主机上的 agent 没能启动。")
    static let reasonAgentBlocked = String(localized: "reason.agentBlocked", defaultValue: "agent 被挡住了，原有进程保留。")
    static let reasonAgentNotWorking = String(localized: "reason.agentNotWorking", defaultValue: "agent 现在没有在跑任务。")
    static let reasonAgentKindMismatch = String(localized: "reason.agentKindMismatch", defaultValue: "主机偏好与现有 agent 不一致，请在电脑上解决。")
    static let reasonAgentKindUnsupported = String(localized: "reason.agentKindUnsupported", defaultValue: "主机默认的 agent 类型这里还不支持。")
    static let reasonAgentChatUnavailable = String(localized: "reason.agentChatUnavailable", defaultValue: "这台主机没有提供 agent 对话。")
    static let reasonAgentApprovalUnknown = String(localized: "reason.agentApprovalUnknown", defaultValue: "主机不认识这条审批。")
    static let reasonAgentApprovalInvalid = String(localized: "reason.agentApprovalInvalid", defaultValue: "主机不接受这个审批选项。")
    static let reasonAgentCliRejected = String(localized: "reason.agentCliRejected", defaultValue: "agent 拒绝了这次请求。")
    static let reasonDefaultAgentUnset = String(localized: "reason.defaultAgentUnset", defaultValue: "先在电脑的 Omarchy 菜单里选一个默认 agent。")
    static let reasonDefaultAgentExists = String(localized: "reason.defaultAgentExists", defaultValue: "这台主机上已经有一个默认 agent。")
    static let reasonProviderAdapterUnavailable = String(localized: "reason.providerAdapterUnavailable", defaultValue: "主机连不上这个 agent 的服务商。")
    static let reasonProviderThreadMissing = String(localized: "reason.providerThreadMissing", defaultValue: "主机上找不到这段对话。")
    static let reasonAgentSessionLost = String(localized: "reason.agentSessionLost", defaultValue: "主机重启后这段空会话没了。")
    static let reasonTaskTooLarge = String(localized: "reason.taskTooLarge", defaultValue: "这条任务超过了允许的长度。")
    static let reasonEmptyTask = String(localized: "reason.emptyTask", defaultValue: "任务是空的。")
    static let reasonHistoryUnavailable = String(localized: "reason.historyUnavailable", defaultValue: "读不到这段对话的历史。")
    static let reasonCancellationPending = String(localized: "reason.cancellationPending", defaultValue: "主机还在停这一轮，稍后再试。")
    static let reasonWorkspaceLayoutApplied = String(localized: "reason.workspaceLayoutApplied", defaultValue: "布局已切换。")
    static let reasonWorkspaceLayoutFailed = String(localized: "reason.workspaceLayoutFailed", defaultValue: "电脑端没能完成这次布局切换。")
    static let reasonWorkspaceOutcomeUnknown = String(localized: "reason.workspaceOutcomeUnknown", defaultValue: "布局结果未确认，请刷新检查。")
    static let reasonWorkspacePreflightUnavailable = String(localized: "reason.workspacePreflightUnavailable", defaultValue: "电脑端读不到当前布局，没有发送切换。")
    static let reasonInvalidWorkspaceRequest = String(localized: "reason.invalidWorkspaceRequest", defaultValue: "这次布局请求不完整，没有发送。")
    static let reasonStalePlan = String(localized: "reason.stalePlan", defaultValue: "目标已变化，这次请求没有发送。")
    static let reasonExistingFileConflict = String(localized: "reason.existingFileConflict", defaultValue: "布局配置有并发改动，电脑端保留了现有文件。")
    static let reasonNoFocusedWindow = String(localized: "reason.noFocusedWindow", defaultValue: "主机上没有焦点窗口，没有发送移动。")
    static let reasonNoBackup = String(localized: "reason.noBackup", defaultValue: "电脑端没有可回滚的备份。")
    static let reasonNewerThanCutoff = String(localized: "reason.newerThanCutoff", defaultValue: "电脑端的文件比这次请求还新。")
    static let reasonDaemonUnavailable = String(localized: "reason.daemonUnavailable", defaultValue: "电脑端服务没在跑。")
    static let reasonLiveStateUnavailable = String(localized: "reason.liveStateUnavailable", defaultValue: "读不到主机的实时状态。")
    static let reasonRouteUnavailable = String(localized: "reason.routeUnavailable", defaultValue: "主机没有提供这个入口。")
    static let reasonThemeUnavailable = String(localized: "reason.themeUnavailable", defaultValue: "这台主机没有发布主题。")
    static let reasonFontsUnavailable = String(localized: "reason.fontsUnavailable", defaultValue: "这台主机没有发布字体。")
    static let reasonIconNotFound = String(localized: "reason.iconNotFound", defaultValue: "这台主机没有这个图标。")
    static let reasonNotificationsUnavailable = String(localized: "reason.notificationsUnavailable", defaultValue: "读不到电脑上的通知。")
    static let reasonAppsReaderUnavailable = String(localized: "reason.appsReaderUnavailable", defaultValue: "读不到电脑上的应用列表。")
    static let reasonStaleCatalogRevision = String(localized: "reason.staleCatalogRevision", defaultValue: "菜单在主机上变了，正在刷新。")
    static let reasonBindingAdapterUnavailable = String(localized: "reason.bindingAdapterUnavailable", defaultValue: "这条快捷键在主机上没有可执行的绑定。")
    static let reasonConditionUnavailable = String(localized: "reason.conditionUnavailable", defaultValue: "主机算不出这一项的状态。")
    static let reasonConditionDisabled = String(localized: "reason.conditionDisabled", defaultValue: "主机暂时停用了此项")
    static let reasonConditionTimeout = String(localized: "reason.conditionTimeout", defaultValue: "主机没来得及检查此项。")
    static let reasonConditionSpawnFailed = String(localized: "reason.conditionSpawnFailed", defaultValue: "主机无法检查此项。")
    static let reasonConditionPending = String(localized: "reason.conditionPending", defaultValue: "主机还在检查此项。")
    static let reasonExecutableMissing = String(localized: "reason.executableMissing", defaultValue: "主机上找不到这个命令。")
    // MENU-4: the menu rows the host looked at and will not run, and why a run failed.
    static let reasonMenuActionNeedsTerminal = String(localized: "reason.menuActionNeedsTerminal", defaultValue: "要在终端里运行")
    static let reasonMenuActionEmpty = String(localized: "reason.menuActionEmpty", defaultValue: "主机没给这一项命令")
    static let reasonMenuRowNotInvocable = String(localized: "reason.menuRowNotInvocable", defaultValue: "这是一个子菜单。")
    static let reasonGraphicalSessionUnavailable = String(localized: "reason.graphicalSessionUnavailable", defaultValue: "电脑上没有登录的桌面。")
    static let reasonExecutionFailed = String(localized: "reason.executionFailed", defaultValue: "主机没能执行这次动作。")
    static let reasonSetupRequired = String(localized: "reason.setupRequired", defaultValue: "电脑上还需要装一次，才能用这一项。")
    static let reasonCredentialRegistryUnavailable = String(localized: "reason.credentialRegistryUnavailable", defaultValue: "主机读不到自己的设备凭据表。")
    // CORE-2 §1: why a credential was refused, and the two renewal answers.
    static let reasonCredentialExpired = String(localized: "reason.credentialExpired", defaultValue: "这台设备的凭据过期了（凭据的有效期是 30 天）。")
    static let reasonCredentialRevoked = String(localized: "reason.credentialRevoked", defaultValue: "这台设备的授权在电脑上被撤销了。")
    static let reasonDevicePurged = String(localized: "reason.devicePurged", defaultValue: "电脑撤销了这台设备，并把它从设备列表里移除了。")
    static let reasonUnknownCredential = String(localized: "reason.unknownCredential", defaultValue: "电脑不认这份凭据：它不是这台电脑签发的，或者已经损坏。")
    static let reasonCredentialRenewalNotDue = String(localized: "reason.credentialRenewalNotDue", defaultValue: "凭据还没到最后一周，现在不用续期。")
    static let reasonPluginCredential = String(localized: "reason.pluginCredential", defaultValue: "这是电脑上 Omodachi 面板自己的凭据，不能从这里续期或撤销。")
    static let reasonDiscoveryUnavailable = String(localized: "reason.discoveryUnavailable", defaultValue: "主机没能在局域网上广播自己。")
    static let reasonDesktopEntryUnavailable = String(localized: "reason.desktopEntryUnavailable", defaultValue: "主机上没有这个桌面项。")
    static let reasonPreferencesInvalid = String(localized: "reason.preferencesInvalid", defaultValue: "主机的偏好设置无效。")
    static let reasonSocketNotShared = String(localized: "reason.socketNotShared", defaultValue: "电脑端服务的套接字不在共享目录里。")
    static let reasonQueueOverflow = String(localized: "reason.queueOverflow", defaultValue: "主机的事件队列满了，请刷新状态。")
    static let reasonApprovalOutcomeUnknown = String(localized: "reason.approvalOutcomeUnknown", defaultValue: "审批结果未确认。")
    static let reasonAlreadyAuthorized = String(localized: "reason.alreadyAuthorized", defaultValue: "这台设备已经获授权。")
    /// UX-4. The two outcomes `PUT /v1/ssh/key` reports besides
    /// `already_authorized`. They are results, not refusals, and they read like
    /// the neighbour above: what the host now holds, not what went wrong.
    static let reasonSshKeyAdded = String(localized: "reason.sshKeyAdded", defaultValue: "这台设备的 SSH 密钥已经登记到主机上。")
    static let reasonSshKeyReplaced = String(localized: "reason.sshKeyReplaced", defaultValue: "主机上这台设备的 SSH 密钥已经换成新的一把。")
    static let reasonPermissionDenied = String(localized: "reason.permissionDenied", defaultValue: "主机拒绝了这次请求。")
    static let reasonTimeout = String(localized: "reason.timeout", defaultValue: "主机没有及时响应。")
    static let reasonUnavailable = String(localized: "reason.unavailable", defaultValue: "这台主机上没有这一项。")
    static let reasonRateLimited = String(localized: "reason.rateLimited", defaultValue: "主机收到的请求太多，稍后再试。")
    static func reasonPartNotReady(_ a: String) -> String {
        String(localized: "reason.partNotReady", defaultValue: "主机的这一部分还没就绪（\(a)）。")
    }
    static func reasonRemoteUnknown(_ a: String) -> String {
        String(localized: "reason.remote.unknown", defaultValue: "主机未能完成这次 Remote 请求（\(a)）。")
    }
    static func reasonMediaUnknown(_ a: String) -> String {
        String(localized: "reason.media.unknown", defaultValue: "主机未能完成这次配对（\(a)）。")
    }
    static func reasonHerdrUnknown(_ a: String) -> String {
        String(localized: "reason.herdr.unknown", defaultValue: "主机未能完成这次 Herdr 请求（\(a)）。")
    }
    static func reasonVoiceUnknown(_ a: String) -> String {
        String(localized: "reason.voice.unknown", defaultValue: "语音现在用不了（\(a)）。")
    }
    static func reasonAgentUnknown(_ a: String) -> String {
        String(localized: "reason.agent.unknown", defaultValue: "主机未能完成这次 agent 请求（\(a)）。")
    }
    static func reasonWorkspaceUnknown(_ a: String) -> String {
        String(localized: "reason.workspace.unknown", defaultValue: "电脑端未能完成这次工作区请求（\(a)）。")
    }
    static func reasonHostUnknown(_ a: String) -> String {
        String(localized: "reason.host.unknown", defaultValue: "主机未能完成这次请求（\(a)）。")
    }

    // MARK: - I18N-1: Remote

    static let remoteModeExtend = String(localized: "remote.mode.extend", defaultValue: "扩展屏")
    static let remoteModeTakeover = String(localized: "remote.mode.takeover", defaultValue: "接管桌面")
    static let remoteExitHowToFix = String(localized: "remote.exit.howToFix", defaultValue: "怎么修")
    static let remoteExitContinue = String(localized: "remote.exit.continue", defaultValue: "继续")
    static let remoteExitTakeOver = String(localized: "remote.exit.takeOver", defaultValue: "接管它")
    static let remoteExitLater = String(localized: "remote.exit.later", defaultValue: "稍后再试")
    static func remoteSessionOwnedBy(_ a: String, _ b: String) -> String {
        String(localized: "remote.session.ownedBy", defaultValue: "\(a) 正在用这台主机（\(b)）。一台主机同时只能有一个 Remote 会话。")
    }
    static let remoteBackendChoiceAuto = String(localized: "remote.backend.auto", defaultValue: "自动")

    // MARK: - I18N-1: Sunshine pairing

    static func mediaPairingAwaitingApproval(_ a: String) -> String {
        String(localized: "media.pairing.awaitingApproval", defaultValue: "等电脑批准串流证书（插件面板 › 设备 里按 Approve），还剩 \(a) 秒。")
    }
    static func mediaPairingPinDelivered(_ a: String) -> String {
        String(localized: "media.pairing.pinDelivered", defaultValue: "已把 PIN 交给主机，还剩 \(a) 秒。")
    }
    static let mediaPairingExchanging = String(localized: "media.pairing.exchanging", defaultValue: "主机已批准，正在交换证书。")
    static let mediaPairingDone = String(localized: "media.pairing.done", defaultValue: "Sunshine 配对完成。")
    static let mediaPairingNotAuthorized = String(localized: "media.pairing.notAuthorized", defaultValue: "主机已配对，但还没授权本设备串流。")
    static let mediaPairingExpired = String(localized: "media.pairing.expired", defaultValue: "配对请求已过期，请重新开始。")
    static let mediaPairingCancelled = String(localized: "media.pairing.cancelled", defaultValue: "配对已取消。")
    static let mediaPairingFailed = String(localized: "media.pairing.failed", defaultValue: "配对失败，请重新开始。")
    static func mediaPairingStatus(_ a: String) -> String {
        String(localized: "media.pairing.status", defaultValue: "配对状态：\(a)")
    }

    // MARK: - I18N-1: voice

    static let voiceAlreadyTranscribed = String(localized: "voice.alreadyTranscribed", defaultValue: "电脑已经转写过那一段了。")
    static let voiceNothingTranscribed = String(localized: "voice.nothingTranscribed", defaultValue: "没有转写出内容。")
    static let voiceNoTranscript = String(localized: "voice.noTranscript", defaultValue: "主机没有返回转写结果。")

    // MARK: - I18N-1: the host client

    static let hostErrorInvalidEndpoint = String(localized: "host.error.invalidEndpoint", defaultValue: "主机地址必须是一个 HTTPS 地址，不带查询串。")
    static let hostErrorNotConnected = String(localized: "host.error.notConnected", defaultValue: "还没有连上电脑端服务。")
    static let hostErrorMissingCredential = String(localized: "host.error.missingCredential", defaultValue: "本机没有这台主机的凭据。")
    static let hostErrorUnauthorized = String(localized: "host.error.unauthorized", defaultValue: "主机拒绝了本机的授权。")
    static let hostErrorCertificateChanged = String(localized: "host.error.certificateChanged", defaultValue: "这台主机的证书变了。在确认是你自己轮换了证书之前，不要继续连接。")
    static let hostErrorBadRequest = String(localized: "host.error.badRequest", defaultValue: "这次请求的目标或参数无效，没有发送。")
    static let hostErrorDifferentAgentTarget = String(localized: "host.error.differentAgentTarget", defaultValue: "主机返回了另一个 agent，请在电脑上检查这条任务。")
    static let hostErrorEventStreamEnded = String(localized: "host.error.eventStreamEnded", defaultValue: "与主机的事件连接断了。重新连接以刷新状态。")
    static let hostErrorInvalidEvent = String(localized: "host.error.invalidEvent", defaultValue: "主机发来的事件无效。请刷新状态。")
    static let hostErrorContractMismatch = String(localized: "host.error.contractMismatch", defaultValue: "主机的响应与支持的协议不符。")
    static let hostErrorTooLarge = String(localized: "host.error.tooLarge", defaultValue: "内容超过了允许的大小。")
    static let hostErrorNotHTTP = String(localized: "host.error.notHTTP", defaultValue: "主机返回的不是 HTTP 响应。")
    static let hostErrorUnreachable = String(localized: "host.error.unreachable", defaultValue: "无法安全连上这台主机。")

    // MARK: - I18N-1: host actions

    static let hostWakeFailed = String(localized: "host.wakeFailed", defaultValue: "没能唤醒主机屏幕。")
    static let hostNoTerminalTarget = String(localized: "host.noTerminalTarget", defaultValue: "主机没有给出终端启动目标。")
    static let hostActionOutcomeUnknown = String(localized: "host.action.outcomeUnknown", defaultValue: "动作结果未知。刷新后再检查。")
    static let hostActionAccepted = String(localized: "host.action.accepted", defaultValue: "主机收下了这次动作，等待状态确认。")
    static let hostActionApplied = String(localized: "host.action.applied", defaultValue: "主机报告动作已生效。")
    static let hostActionPrepared = String(localized: "host.action.prepared", defaultValue: "主机准备好了这个界面，还没接上。")
    static let hostActionBlocked = String(localized: "host.action.blocked", defaultValue: "主机挡住了这次动作。")
    static let hostDemoLocalState = String(localized: "host.demoLocalState", defaultValue: "演示主机用的是本地样例状态。")
    static let hostDisconnected = String(localized: "host.disconnected", defaultValue: "电脑端服务已断开。SSH 会话要单独管理。")
    static let hostAddressMissing = String(localized: "host.addressMissing", defaultValue: "先填上电脑端服务的 HTTPS 地址。")
    static let hostReconnecting = String(localized: "host.reconnecting", defaultValue: "状态连接断了，正在重连并刷新。")
    static let hostConnectFirst = String(localized: "host.connectFirst", defaultValue: "先连上电脑端服务，再发送任务。")
    static let agentTaskAccepted = String(localized: "agent.task.accepted", defaultValue: "主机收下了这条任务，还没确认完成。")
    static let agentTaskDone = String(localized: "agent.task.done", defaultValue: "主机报告任务已完成。")
    static let agentTaskRefused = String(localized: "agent.task.refused", defaultValue: "主机没能接受这条任务。")
    static let agentTaskOutcomeUnknown = String(localized: "agent.task.outcomeUnknown", defaultValue: "任务投递结果未知。发送前先去 Agent 看一眼。")
    static let agentNoAttachTarget = String(localized: "agent.noAttachTarget", defaultValue: "主机没有给出可接入的 Agent 目标，任务未发送。")
    static func workspaceLayoutRetryUnknown(_ a: String) -> String {
        String(localized: "workspace.layout.retryUnknown", defaultValue: "工作区 \(a) 的布局结果未知。先检查状态；重试会用同一个请求。")
    }

    // MARK: - I18N-1: workspace layout

    static let workspaceLayoutDwindle = String(localized: "workspace.layout.dwindle", defaultValue: "平铺")
    static let workspaceLayoutScrolling = String(localized: "workspace.layout.scrolling", defaultValue: "滚动")
    static func workspaceLayoutOfferLabel(_ a: String, _ b: String) -> String {
        String(localized: "workspace.layout.offerLabel", defaultValue: "工作区 \(a) · \(b)布局")
    }
    static func workspaceLayoutSwap(_ a: String, _ b: String, _ c: String) -> String {
        String(localized: "workspace.layout.swap", defaultValue: "工作区 \(a)：\(b) → \(c)")
    }
    static func workspaceLayoutConfirmed(_ a: String, _ b: String) -> String {
        String(localized: "workspace.layout.confirmed", defaultValue: "工作区 \(a) 已换成\(b)布局。")
    }
    static func workspaceLayoutPartial(_ a: String, _ b: String) -> String {
        String(localized: "workspace.layout.partial", defaultValue: "工作区 \(a) 的布局没有完整落地：\(b)。请刷新检查。")
    }
    static let workspaceRuntimeConfirmed = String(localized: "workspace.runtime.confirmed", defaultValue: "运行变更已确认")
    static let workspaceRuntimeUnconfirmed = String(localized: "workspace.runtime.unconfirmed", defaultValue: "运行变更未确认")
    static let workspacePersistedConfirmed = String(localized: "workspace.persisted.confirmed", defaultValue: "持久化已确认")
    static let workspacePersistedUnconfirmed = String(localized: "workspace.persisted.unconfirmed", defaultValue: "持久化未确认")
    static let workspaceReadbackConfirmed = String(localized: "workspace.readback.confirmed", defaultValue: "读回已确认")
    static let workspaceReadbackUnconfirmed = String(localized: "workspace.readback.unconfirmed", defaultValue: "读回未确认")

    // MARK: - I18N-1: pairing, discovery, Herdr, VNC

    static let pairErrorInvalidInput = String(localized: "pair.error.invalidInput", defaultValue: "填一个 HTTPS 地址和一个设备名。")
    static let pairErrorExistingCredential = String(localized: "pair.error.existingCredential", defaultValue: "本机还留着这台电脑的旧凭据。回到列表再点一次这一行。")
    static let pairErrorUnavailable = String(localized: "pair.error.unavailable", defaultValue: "这台电脑暂时不接受配对。确认它上面的 Omodachi 在跑。")
    static let pairErrorRejected = String(localized: "pair.error.rejected", defaultValue: "这次请求已被拒绝、用掉或过期。回到列表再点一次。")
    static let pairErrorInvalidResponse = String(localized: "pair.error.invalidResponse", defaultValue: "这台电脑的配对响应无效。回到列表再点一次。")
    static let pairErrorTransport = String(localized: "pair.error.transport", defaultValue: "无法安全完成配对。回到列表再点一次。")
    static let pairErrorKeychain = String(localized: "pair.error.keychain", defaultValue: "存不下设备凭据。检查钥匙串后重新配对。")
    static let pairErrorCancelled = String(localized: "pair.error.cancelled", defaultValue: "配对已取消。回到列表再点一次。")
    static let pairErrorInvitationRequired = String(localized: "pair.error.invitationRequired", defaultValue: "这台电脑开了邀请模式，需要一段一次性邀请码。")
    static func pairErrorDeviceRegistered(_ a: String) -> String {
        String(localized: "pair.error.deviceRegistered", defaultValue: "这台电脑上还留着本设备的授权（\(a)），本机的凭据却没了。在电脑上撤销它再试。")
    }
    static let pairCredentialUnverified = String(localized: "pair.credentialUnverified", defaultValue: "这台电脑没回答本机凭据还算不算数，所以先不动它。确认它上面的 Omodachi 在跑，再点一次。")
    static let pairInvitationShape = String(localized: "pair.invitationShape", defaultValue: "邀请码是电脑上那 43 位。整段复制。")
    static let pairFingerprintSaveFailed = String(localized: "pair.fingerprintSaveFailed", defaultValue: "存不下新的证书指纹。解锁设备后重试。")
    static let probeUnreachable = String(localized: "probe.unreachable", defaultValue: "连不上这个地址。确认电脑开着、和这台设备在同一个 Wi-Fi 上。")
    static let probeNotOmodachi = String(localized: "probe.notOmodachi", defaultValue: "这个地址答的不是 Omodachi 电脑端服务。")
    static let discoveryPermissionDenied = String(localized: "discovery.permissionDenied", defaultValue: "本机不许查找局域网设备。在系统设置的「本地网络」里允许 Omodachi，或手动填地址。")
    static let discoveryUnavailable = String(localized: "discovery.unavailable", defaultValue: "局域网查找暂时用不了。可以手动填主机的 HTTPS 地址。")
    static func herdrStreamClosed(_ a: String) -> String {
        String(localized: "herdr.streamClosed", defaultValue: "Herdr 关掉了这个 pane 的流（\(a)）。")
    }
    static let herdrReadOnly = String(localized: "herdr.readOnly", defaultValue: "这个 pane 现在是只读观察。")
    static let herdrNoSelectedPane = String(localized: "herdr.noSelectedPane", defaultValue: "没有选中的 pane。")
    static let herdrOnlyOnePane = String(localized: "herdr.onlyOnePane", defaultValue: "这个 tab 里只有一个 pane。")
    static let vncLoopbackUnavailable = String(localized: "vnc.loopbackUnavailable", defaultValue: "本机开不了 VNC 中转端口。")
    static let vncUnauthorized = String(localized: "vnc.unauthorized", defaultValue: "主机不再接受本设备的凭据，请重新配对。")
    static let vncWayvncNotAccepting = String(localized: "vnc.wayvncNotAccepting", defaultValue: "主机的 WayVNC 还没开始接受连接。")
    static func vncRefused(_ a: String) -> String {
        String(localized: "vnc.refused", defaultValue: "主机拒绝了 VNC 通道（HTTP \(a)）。")
    }
    static let vncNoChannel = String(localized: "vnc.noChannel", defaultValue: "没能和主机建立 VNC 通道。")
    static let vncNoLocalPort = String(localized: "vnc.noLocalPort", defaultValue: "VNC 通道没有给出可用的本地端口。")

    // MARK: - I18N-1: the Remote session

    static let remoteStatusIdle = String(localized: "remote.status.idle", defaultValue: "准备连接主机屏幕")
    static let remoteStatusCreating = String(localized: "remote.status.creating", defaultValue: "正在申请 Remote 会话")
    static let remoteStatusConnecting = String(localized: "remote.status.connecting", defaultValue: "正在连接主机画面")
    static let remoteStatusStreaming = String(localized: "remote.status.streaming", defaultValue: "正在接收主机画面")
    static let remoteStatusWaitingFrame = String(localized: "remote.status.waitingFrame", defaultValue: "已连接，正在等第一帧")
    static let remoteStatusResizing = String(localized: "remote.status.resizing", defaultValue: "正在按新方向调整画面")
    static let remoteStatusStopping = String(localized: "remote.status.stopping", defaultValue: "正在结束 Remote 会话")
    static let remotePairingIncomplete = String(localized: "remote.pairingIncomplete", defaultValue: "Sunshine 配对没有完成，请重试。")
    static func remoteFailureAtStage(_ a: String, _ b: String) -> String {
        String(localized: "remote.failureAtStage", defaultValue: "\(a)（在\(b)）")
    }
    static let remotePairingRenewing = String(localized: "remote.pairingRenewing", defaultValue: "主机上没有本设备的串流证书，正在重新申请配对…")
    static let remotePairingStarting = String(localized: "remote.pairingStarting", defaultValue: "正在向主机的 Sunshine 申请配对…")
    static let remoteFingerprintUnusable = String(localized: "remote.fingerprintUnusable", defaultValue: "本机的串流证书指纹不可用。")
    static let remoteWaitingViewport = String(localized: "remote.waitingViewport", defaultValue: "正在等窗口尺寸，稍后再连接。")
    static let remoteStartFailed = String(localized: "remote.startFailed", defaultValue: "Remote 没能启动。检查主机服务后重试。")
    static let remotePairStepDiscover = String(localized: "remote.pair.step.discover", defaultValue: "查找配对请求")
    static let remotePairStepSubmit = String(localized: "remote.pair.step.submit", defaultValue: "提交 PIN")
    static let remotePairStepPoll = String(localized: "remote.pair.step.poll", defaultValue: "查询配对状态")
    static let remotePairFinding = String(localized: "remote.pair.finding", defaultValue: "正在主机上查找这张串流证书的配对请求…")
    static let remotePairSubmitting = String(localized: "remote.pair.submitting", defaultValue: "已找到配对请求，正在提交 PIN…")
    static let remotePairNeverApproved = String(localized: "remote.pair.neverApproved", defaultValue: "电脑上一直没人批准这张串流证书。在插件面板 › 设备 里按 Approve，再补一次配对。")
    static let remotePairGaveUp = String(localized: "remote.pair.gaveUp", defaultValue: "主机迟迟没有批准，配对已放弃。")
    static func remotePairStepFailed(_ a: String, _ b: String) -> String {
        String(localized: "remote.pair.stepFailed", defaultValue: "\(a)失败：\(b)")
    }
    static func remotePairStepUnfinished(_ a: String) -> String {
        String(localized: "remote.pair.stepUnfinished", defaultValue: "\(a)没能完成，请重试。")
    }
    static let remotePairNoPin = String(localized: "remote.pair.noPin", defaultValue: "主机的 Sunshine 没有给出配对 PIN，配对没有开始。")
    static let remoteConnectionIncomplete = String(localized: "remote.connectionIncomplete", defaultValue: "主机返回的连接信息不完整。")
    static let remotePreviousStreamOpen = String(localized: "remote.previousStreamOpen", defaultValue: "上一个串流连接还没结束。")
    static let remoteStreamFailed = String(localized: "remote.streamFailed", defaultValue: "串流连接失败。")

    // MARK: - I18N-1: SSH, keybindings, agent

    static let sshTransportUnavailable = String(localized: "ssh.transportUnavailable", defaultValue: "这个版本没有带上 SSH 传输。")
    static let sshMissingKey = String(localized: "ssh.missingKey", defaultValue: "钥匙串里没有这个账户的 SSH 私钥。")
    static let sshUnsupportedKey = String(localized: "ssh.unsupportedKey", defaultValue: "这把密钥不受支持或已加密。导入一把未加密的 Ed25519。")
    static let sshNotConnected = String(localized: "ssh.notConnected", defaultValue: "SSH 会话没有连上。")
    static let sshAlreadyConnected = String(localized: "ssh.alreadyConnected", defaultValue: "SSH 会话已经连上了。")
    static let sshHostKeyRejected = String(localized: "ssh.hostKeyRejected", defaultValue: "主机密钥被拒绝。")
    static let sshOptionsInvalid = String(localized: "ssh.optionsInvalid", defaultValue: "SSH 连接参数无效。")
    static let sshNoPairedTarget = String(localized: "ssh.noPairedTarget", defaultValue: "配对没有给出 SSH 目标。在电脑上忘记这台设备后重新配对。")
    static let sshImportKeyFirst = String(localized: "ssh.importKeyFirst", defaultValue: "先在设置里导入或生成一把 SSH 密钥，再连接。")
    static let sshConnectionEnded = String(localized: "ssh.connectionEnded", defaultValue: "SSH 连接结束或被拒。检查主机、账户和已固定的密钥。")
    static let sshKeyNotAuthorized = String(localized: "ssh.keyNotAuthorized", defaultValue: "配对没能把这台设备的公钥写进主机。在电脑上忘记这台设备后重新配对。")
    static let sshHostKeyChanged = String(localized: "ssh.hostKeyChanged", defaultValue: "主机密钥变了，连接已拒绝。核实这台主机后再重设它的固定值。")
    static let sshHostKeyDeclined = String(localized: "ssh.hostKeyDeclined", defaultValue: "没有信任这个主机密钥，什么都没连。")
    static let sshCommandEnded = String(localized: "ssh.commandEnded", defaultValue: "这条命令已经结束。从菜单里再打开一次。")
    static let keybindingsUnavailable = String(localized: "keybindings.unavailable", defaultValue: "主机的快捷键现在读不到。")
    static let keybindingsLoadFailed = String(localized: "keybindings.loadFailed", defaultValue: "读不到这台主机的快捷键。连上后重试。")
    static let shortcutTargetBarButton = String(localized: "shortcut.target.barButton", defaultValue: "bar 上的 Omodachi 按钮")
    static let shortcutTargetThisList = String(localized: "shortcut.target.thisList", defaultValue: "这张列表")
    static func shortcutTargetWorkspace(_ a: String) -> String {
        String(localized: "shortcut.target.workspace", defaultValue: "bar 上的工作区 \(a)")
    }
    static let agentTurnFailed = String(localized: "agent.turnFailed", defaultValue: "这一轮失败了。")
    static func agentWaitingForYou(_ a: String) -> String {
        String(localized: "agent.waitingForYou", defaultValue: "\(a) 在等你")
    }

    // MARK: - I18N-1: the agent conversation

    static let agentIdentityChanged = String(localized: "agent.identityChanged", defaultValue: "agent 会话变了。回到主机上重新打开你要的那个 agent。")
    static let agentPreviousSendUnconfirmed = String(localized: "agent.previousSendUnconfirmed", defaultValue: "上一条还没确认送达。先确认再发别的。")
    static let agentSendUnconfirmed = String(localized: "agent.sendUnconfirmed", defaultValue: "这条没有确认送达。重新连接后再看这段对话。")
    static let agentSteerTooLate = String(localized: "agent.steerTooLate", defaultValue: "这一轮在补充到达前就结束了。作为新消息发出去吧。")
    static let agentSteerUnconfirmed = String(localized: "agent.steerUnconfirmed", defaultValue: "补充没有确认。你的文字还在，检查这一轮后再发。")
    static let agentAnswerUnconfirmed = String(localized: "agent.answerUnconfirmed", defaultValue: "主机没有确认这个回答，agent 还在等。")
    static let agentModelsUnreadable = String(localized: "agent.modelsUnreadable", defaultValue: "读不到这个 agent 的模型。下一条沿用当前设置。")
    static let agentCommandsUnreadable = String(localized: "agent.commandsUnreadable", defaultValue: "读不到这个 agent 的命令。草稿没有动。")
    static let agentUnknownCommand = String(localized: "agent.unknownCommand", defaultValue: "没有这个命令。换一个，或按普通文字发出去。")
    static let agentCommandUnsupported = String(localized: "agent.commandUnsupported", defaultValue: "这个命令这里还用不了。")
    static let agentWaitForTurn = String(localized: "agent.waitForTurn", defaultValue: "等这一轮跑完再用这个命令。")
    static let agentCommandUnconfirmed = String(localized: "agent.commandUnconfirmed", defaultValue: "命令结果未确认，草稿没有动。")
    static let agentCommandNeedsNative = String(localized: "agent.commandNeedsNative", defaultValue: "这个命令需要一个还没接上的原生动作。")
    static let agentStopUnconfirmed = String(localized: "agent.stopUnconfirmed", defaultValue: "没能确认停止。重新连接后看这一轮。")
    static let approvalKindCommand = String(localized: "approval.kind.command", defaultValue: "执行一条命令")
    static let approvalKindFileChange = String(localized: "approval.kind.fileChange", defaultValue: "改动文件")
    static let approvalKindPermissions = String(localized: "approval.kind.permissions", defaultValue: "授予更多权限")
    static let approvalKindUserInput = String(localized: "approval.kind.userInput", defaultValue: "agent 需要你的输入")
    static let approvalAccept = String(localized: "approval.accept", defaultValue: "同意")
    static let approvalAcceptSession = String(localized: "approval.acceptSession", defaultValue: "本次会话都同意")
    static let agentWaitingOnYou = String(localized: "agent.waitingOnYou", defaultValue: "在等你")
    static let agentNeedsInput = String(localized: "agent.needsInput", defaultValue: "需要你的输入")

    // MARK: - I18N-1: the panels

    static func agentWaitingCount(_ a: String) -> String {
        String(localized: "agent.waitingCount", defaultValue: "\(a) 条待审批")
    }
    static let agentDefault = String(localized: "agent.default", defaultValue: "默认")
    static let agentStarting = String(localized: "agent.starting", defaultValue: "正在启动默认 agent…")
    static let agentContinue = String(localized: "agent.continue", defaultValue: "接着用默认 agent。")
    static let agentRoleYou = String(localized: "agent.role.you", defaultValue: "你")
    static let agentRoleAgent = String(localized: "agent.role.agent", defaultValue: "Agent")
    static let agentLoadingCommands = String(localized: "agent.loadingCommands", defaultValue: "正在读命令…")
    static let agentCheckingSession = String(localized: "agent.checkingSession", defaultValue: "正在检查当前会话…")
    static let agentHandoffRollback = String(localized: "agent.handoffRollback", defaultValue: "如果连接失败")
    static let agentConnectingConversation = String(localized: "agent.connectingConversation", defaultValue: "正在接上同一段对话…")
    static let agentPhaseStarting = String(localized: "agent.phase.starting", defaultValue: "正在启动…")
    static let agentPhaseReady = String(localized: "agent.phase.ready", defaultValue: "就绪")
    static let agentPhaseSending = String(localized: "agent.phase.sending", defaultValue: "正在发送…")
    static let agentPhaseWorking = String(localized: "agent.phase.working", defaultValue: "正在干活…")
    static let agentPhaseStopping = String(localized: "agent.phase.stopping", defaultValue: "正在停止…")
    static let agentPhaseReconnecting = String(localized: "agent.phase.reconnecting", defaultValue: "正在重连…")
    static let agentPhaseFailed = String(localized: "agent.phase.failed", defaultValue: "需要你处理")
    static let agentLoadingModels = String(localized: "agent.loadingModels", defaultValue: "正在读这个 agent 的模型…")
    static let approvalAnswered = String(localized: "approval.answered", defaultValue: "已回答")
    static func approvalAnsweredOnHost(_ a: String) -> String {
        String(localized: "approval.answeredOnHost", defaultValue: "\(a)（在电脑上）")
    }
    static let approvalYourAnswer = String(localized: "approval.yourAnswer", defaultValue: "你的回答")
    static let herdrModeControl = String(localized: "herdr.mode.control", defaultValue: "控制")
    static let herdrModeObserve = String(localized: "herdr.mode.observe", defaultValue: "观察")
    static func herdrModeRetry(_ a: String) -> String {
        String(localized: "herdr.mode.retry", defaultValue: "重试 \(a)")
    }
    static let herdrModeOffline = String(localized: "herdr.mode.offline", defaultValue: "离线")
    static func herdrTab(_ a: String) -> String {
        String(localized: "herdr.tab", defaultValue: "tab \(a)")
    }
    static let pinnedTitle = String(localized: "pinned.title", defaultValue: "PINNED")
    static let keybindingsEmpty = String(localized: "keybindings.empty", defaultValue: "没有别的快捷键。")
    static let keybindingsNoMatch = String(localized: "keybindings.noMatch", defaultValue: "没有匹配的动作。")
    static let keybindingsRunHint = String(localized: "keybindings.runHint", defaultValue: "在主机上执行这个动作")
    static let sshHostSessionMayRun = String(localized: "ssh.hostSessionMayRun", defaultValue: "主机上的会话可能还在跑。")
    static let sshReconnectOpensNew = String(localized: "ssh.reconnectOpensNew", defaultValue: "重连会开一个新 shell，命令不会重放。")
    static let sshReattach = String(localized: "ssh.reattach", defaultValue: "重新接入")
    static let sshReconnect = String(localized: "ssh.reconnect", defaultValue: "重新连接")
    static let sshCloseConfirm = String(localized: "ssh.closeConfirm", defaultValue: "关掉这个本地 SSH 会话？")
    static let sshDemoLabel = String(localized: "ssh.demoLabel", defaultValue: "演示")
    static func settingsBuildStamp(_ a: String, _ b: String) -> String {
        String(localized: "settings.buildStamp", defaultValue: "build \(a) · \(b)")
    }

    // MARK: - I18N-1: last of the backend copy

    static let herdrActionPreviousPane = String(localized: "herdr.action.previousPane", defaultValue: "上一个 pane")
    static let herdrActionNextPane = String(localized: "herdr.action.nextPane", defaultValue: "下一个 pane")
    static let herdrActionSplitRight = String(localized: "herdr.action.splitRight", defaultValue: "向右分屏")
    static let herdrActionSplitDown = String(localized: "herdr.action.splitDown", defaultValue: "向下分屏")
    static let herdrActionZoom = String(localized: "herdr.action.zoom", defaultValue: "放大")
    static let herdrActionClosePane = String(localized: "herdr.action.closePane", defaultValue: "关掉 pane")
    static let herdrActionNewTab = String(localized: "herdr.action.newTab", defaultValue: "新建 tab")
    static func keybindingsCoveredHere(_ a: String) -> String {
        String(localized: "keybindings.coveredHere", defaultValue: "这是\(a)。在那里用。")
    }
    static let notificationsDndUnchanged = String(localized: "notifications.dndUnchanged", defaultValue: "电脑上的勿扰没有改动。")
    static let remoteFirstFrameRejected = String(localized: "remote.firstFrameRejected", defaultValue: "第一帧的尺寸对不上，已丢弃。")

    // MARK: - I18N-1: tool rows

    static let toolStatusRunning = String(localized: "tool.status.running", defaultValue: "执行中")
    static let toolStatusSucceeded = String(localized: "tool.status.succeeded", defaultValue: "成功")
    static let toolStatusFailed = String(localized: "tool.status.failed", defaultValue: "失败")
    static let toolStatusCancelled = String(localized: "tool.status.cancelled", defaultValue: "已取消")
    static let toolStatusUnknown = String(localized: "tool.status.unknown", defaultValue: "未知")

    // MARK: - I18N-1: SSH session state

    static let sessionStateDisconnected = String(localized: "session.state.disconnected", defaultValue: "未连接")
    static let sessionStateConnecting = String(localized: "session.state.connecting", defaultValue: "连接中")
    static let sessionStateConnected = String(localized: "session.state.connected", defaultValue: "已连接")
    static let sessionStateSuspended = String(localized: "session.state.suspended", defaultValue: "已挂起")
    static let sessionStateFailed = String(localized: "session.state.failed", defaultValue: "失败")
    static let sessionStateExited = String(localized: "session.state.exited", defaultValue: "已退出")
}
