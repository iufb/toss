// Toss — переключатель Bluetooth-наушников между Mac и телефоном в строке меню macOS.
// ЛКМ по иконке  — переключить (Mac ⇄ телефон)
// ПКМ по иконке  — меню: переключить / выбор наушников / запуск при входе / выход

import Cocoa
import IOBluetooth
import ServiceManagement

// Адрес выбранных наушников хранится в UserDefaults под этим ключом
let DEVICE_ADDRESS_KEY = "deviceAddress"

// Иконки: набор «Куда идёт звук»
let ICON_MAC     = "laptopcomputer"
let ICON_PHONE   = "iphone"
let ICON_NONE    = "laptopcomputer.slash"        // с ICON_MAC морфится (Magic Replace, macOS 15+)
let ICON_LOADING = "laptopcomputer.and.iphone"   // пульсирует, пока идёт переключение

let BUSY_TIMEOUT: TimeInterval = 15   // сколько максимум ждать смены состояния

// Картинка не перехватывает клики — их ловит монитор событий
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var busy = false
    private var busyTimer: Timer?
    private let iconView = PassthroughImageView()
    private var currentSymbol: String?
    private var isPulsing = false
    private let highlightView = NSView()
    private var mouseMonitor: Any?
    private var menuOpen = false

    private var selectedAddress: String? {
        get { UserDefaults.standard.string(forKey: DEVICE_ADDRESS_KEY) }
        set { UserDefaults.standard.set(newValue, forKey: DEVICE_ADDRESS_KEY) }
    }

    /// Выбранные наушники, если они всё ещё сопряжены с Mac
    private var device: IOBluetoothDevice? {
        guard let address = selectedAddress,
              let d = IOBluetoothDevice(addressString: address), d.isPaired() else { return nil }
        return d
    }

    private var deviceName: String {
        device?.name ?? "Наушники"
    }

    /// Сопряжённые устройства: сначала аудио, если их нет — все
    private func pairedCandidates() -> [IOBluetoothDevice] {
        let all = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let audio = all.filter { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) }
        let list = audio.isEmpty ? all : audio
        return list.sorted { ($0.name ?? "") .localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
    }

    private func sameAddress(_ a: String?, _ b: String?) -> Bool {
        func norm(_ s: String?) -> String { (s ?? "").lowercased().replacingOccurrences(of: ":", with: "-") }
        return a != nil && b != nil && norm(a) == norm(b)
    }

    private var connectedToMac: Bool {
        device?.isConnected() ?? false
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Раньше приложение называлось XM6Toggle (local.xm6toggle) — забираем оттуда
        // выбранные наушники, чтобы после переименования их не пришлось выбирать заново
        if selectedAddress == nil,
           let old = UserDefaults(suiteName: "local.xm6toggle")?.string(forKey: DEVICE_ADDRESS_KEY) {
            selectedAddress = old
        }

        // Постоянная ширина по самой широкой иконке, чтобы соседи в строке меню не прыгали
        let iconWidths = [ICON_MAC, ICON_PHONE, ICON_NONE, ICON_LOADING].compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.size.width
        }
        let fixedWidth = ceil(iconWidths.max() ?? 18) + 10   // + отступы по краям
        statusItem = NSStatusBar.system.statusItem(withLength: fixedWidth)
        if let button = statusItem.button {
            // Иконку рисует свой NSImageView: только он умеет анимировать смену символа
            // Вью растянута на всю кнопку и не меняет размер при смене символа —
            // иначе во время анимации старая иконка съезжает вбок.
            iconView.wantsLayer = true           // нужен для анимации растворения
            iconView.imageScaling = .scaleNone   // без растягивания
            iconView.imageAlignment = .alignCenter
            // Раскладка через autoresizing, а не Auto Layout: привязки к краям кнопки
            // меняли размер самой кнопки (она сжималась до 9 pt в высоту).
            // Autoresizing только следует за кнопкой и на её размер не влияет.
            iconView.frame = button.bounds
            iconView.autoresizingMask = [.width, .height]

            // Своя подсветка нажатия: мягкая капсула под иконкой
            highlightView.wantsLayer = true
            highlightView.layer?.cornerRadius = 8
            highlightView.layer?.cornerCurve = .continuous
            highlightView.alphaValue = 0
            highlightView.frame = button.bounds.insetBy(dx: 1, dy: 0)
            highlightView.autoresizingMask = [.width, .height]
            button.addSubview(highlightView)
            button.addSubview(iconView)   // иконка поверх капсулы
            // Клики перехватываем сами и НЕ отдаём кнопке. Если кнопка обрабатывает
            // нажатие, macOS рисует под ней свою тёмную подсветку-овал, и отключить
            // её настройками кнопки нельзя. Без нажатия кнопки нет и овала.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]
            ) { [weak self] event in
                guard let self = self, event.window === button.window else { return event }
                switch event.type {
                case .leftMouseDown, .rightMouseDown:
                    self.setHighlight(true)
                default:
                    let point = button.convert(event.locationInWindow, from: nil)
                    let inside = button.bounds.contains(point)
                    let isRight = event.type == .rightMouseUp
                    // Асинхронно: меню нельзя открывать прямо из обработчика события
                    DispatchQueue.main.async {
                        if inside { self.handleClick(right: isRight) }
                        if !self.menuOpen { self.setHighlight(false) }
                    }
                }
                return nil   // событие до кнопки не доходит
            }
        }
        refresh()
        // Состояние может поменяться и без нас (выключили наушники и т.п.)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - UI

    /// loading = true — иконка пульсирует, пока идёт переключение
    private func setIcon(_ symbol: String, tooltip: String, loading: Bool = false) {
        statusItem.button?.toolTip = tooltip

        // Сначала гасим пульс, чтобы морф шёл от «спокойной» иконки
        if !loading, isPulsing {
            if #available(macOS 14.0, *) { iconView.removeAllSymbolEffects() }
            isPulsing = false
        }

        // refresh() зовётся каждые 2 с — не перезапускаем анимацию на тот же символ
        if symbol != currentSymbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            image.isTemplate = true
            let previous = currentSymbol
            currentSymbol = symbol
            // Системный .replace рисует старую иконку в рамке новой, и при разной ширине
            // (22 pt → 14 pt) она съезжает. Поэтому Magic Replace — только для пары
            // ноутбук ↔ перечёркнутый ноутбук, остальное — плавное растворение.
            let morphPair = Set([previous, symbol]) == Set([ICON_MAC, ICON_NONE])
            if previous == nil {
                iconView.image = image   // первый показ — без анимации
            } else if #available(macOS 15.0, *), morphPair {
                iconView.setSymbolImage(image, contentTransition: .replace.magic(fallback: .replace.downUp))
            } else {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.25
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                iconView.layer?.add(fade, forKey: "iconSwap")
                iconView.image = image
            }
        }

        if loading, !isPulsing {
            if #available(macOS 14.0, *) { iconView.addSymbolEffect(.pulse, options: .repeating) }
            isPulsing = true
        }
    }

    /// Плавно показывает/прячет капсулу под иконкой. Цвет берётся из оформления
    /// строки меню: светлая капсула на тёмной строке, тёмная — на светлой.
    private func setHighlight(_ on: Bool) {
        guard let button = statusItem.button else { return }
        if on {
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                highlightView.layer?.backgroundColor =
                    NSColor.labelColor.withAlphaComponent(0.16).cgColor
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.08 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: on ? .easeOut : .easeInEaseOut)
            highlightView.animator().alphaValue = on ? 1 : 0
        }
    }

    private func refresh() {
        guard !busy else { return }
        if selectedAddress == nil {
            setIcon(ICON_NONE, tooltip: "Наушники не выбраны. Клик: выбрать")
        } else if device == nil {
            setIcon(ICON_NONE, tooltip: "Выбранные наушники больше не сопряжены с Mac. Клик: выбрать другие")
        } else if connectedToMac {
            setIcon(ICON_MAC, tooltip: "\(deviceName) → Mac. Клик: отдать телефону")
        } else {
            setIcon(ICON_PHONE, tooltip: "\(deviceName) → телефон. Клик: забрать на Mac")
        }
    }

    private func handleClick(right: Bool) {
        // Без выбранных наушников переключать нечего — сразу показываем меню
        if right || device == nil {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let hasDevice = device != nil
        let toggleItem = NSMenuItem(
            title: !hasDevice ? "Наушники не выбраны"
                 : busy ? "Переключаю…"
                 : connectedToMac ? "Отдать \(deviceName) телефону" : "Подключить \(deviceName) к Mac",
            action: (busy || !hasDevice) ? nil : #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Выбор наушников из сопряжённых устройств
        let devicesItem = NSMenuItem(title: "Наушники", action: nil, keyEquivalent: "")
        let devicesMenu = NSMenu()
        let candidates = pairedCandidates()
        if candidates.isEmpty {
            devicesMenu.addItem(NSMenuItem(title: "Нет сопряжённых устройств", action: nil, keyEquivalent: ""))
        }
        for d in candidates {
            let item = NSMenuItem(title: d.name ?? d.addressString ?? "Без имени",
                                  action: busy ? nil : #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.addressString
            item.state = sameAddress(d.addressString, selectedAddress) ? .on : .off
            devicesMenu.addItem(item)
        }
        devicesMenu.addItem(.separator())
        let btSettings = NSMenuItem(title: "Настройки Bluetooth…",
                                    action: #selector(openBluetoothSettings), keyEquivalent: "")
        btSettings.target = self
        devicesMenu.addItem(btSettings)
        devicesItem.submenu = devicesMenu
        menu.addItem(devicesItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Запускать при входе",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выход",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Показываем меню сами, под кнопкой. Через statusItem.menu + performClick
        // кнопка рисовала поверх себя тёмную «нажатую» подсветку-овал.
        guard let button = statusItem.button else { return }
        // Пока меню открыто, капсула горит — как у системных пунктов строки меню
        menuOpen = true
        setHighlight(true)
        // Открываем по экранным координатам (in: nil), а не «в кнопке». Если меню
        // привязано к кнопке строки меню, macOS 26 рисует под ней свою тёмную
        // подсветку выбранного пункта — тот самый чёрный овал.
        let rectInWindow = button.convert(button.bounds, to: nil)
        let rectOnScreen = button.window?.convertToScreen(rectInWindow) ?? .zero
        // Верх меню — сразу под строкой меню. Низ кнопки для этого не годится:
        // окно пункта выше кнопки, и меню залезало под строку меню, а потом
        // прокручивалось и «прыгало».
        let menuBarBottom = button.window?.screen?.visibleFrame.maxY
            ?? button.window?.frame.minY ?? rectOnScreen.minY
        let point = NSPoint(x: rectOnScreen.minX, y: menuBarBottom - 4)
        menu.popUp(positioning: nil, at: point, in: nil)   // возвращается, когда меню закрыли
        menuOpen = false
        setHighlight(false)
    }

    // MARK: - Actions

    @objc private func toggleFromMenu() { toggle() }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        selectedAddress = address
        refresh()
    }

    @objc private func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    private func toggle() {
        guard !busy, let device = device else { refresh(); return }
        let wasConnected = device.isConnected()
        let target = !wasConnected                  // какое состояние ждём
        busy = true
        setIcon(ICON_LOADING, tooltip: wasConnected ? "Отключаю…" : "Подключаю…", loading: true)

        if wasConnected {
            device.closeConnection()
        } else {
            // С target = self вызов асинхронный и не блокирует UI;
            // результат ловим опросом ниже, connectionComplete не нужен.
            device.openConnection(self)
        }

        // Держим иконку загрузки, пока состояние реально не сменится (или таймаут)
        let deadline = Date().addingTimeInterval(BUSY_TIMEOUT)
        busyTimer?.invalidate()
        busyTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if self.connectedToMac == target || Date() > deadline {
                t.invalidate()
                self.busyTimer = nil
                self.busy = false
                self.refresh()
            }
        }
    }

    // Колбэк для openConnection(self); состояние проверяется таймером
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // без иконки в Dock
app.run()
