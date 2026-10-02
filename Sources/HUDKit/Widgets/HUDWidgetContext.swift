import Combine
import Foundation

/// What a widget view gets: which instance it draws, at what size, with which settings, and
/// whether MacHUD is in edit mode. Observe it (`@ObservedObject var context`) and the view
/// updates when MacHUD changes any of these.
///
/// ```swift
/// struct ClockWidget: View {
///     @ObservedObject var context: HUDWidgetContext
///     var body: some View {
///         TimelineView(.periodic(from: .now, by: 1)) { t in
///             Text(t.date, style: .time).font(context.size == .small ? .title : .largeTitle)
///         }
///     }
/// }
/// widgets.register("clock") { ClockWidget(context: $0) }
/// ```
@MainActor
public final class HUDWidgetContext: ObservableObject {
    /// MacHUD's instance id.
    public let instance: String
    /// The widget type (the manifest panel id).
    public let type: String
    /// The type's manifest description.
    public let spec: HUDWidgetSpec
    /// The type's per-instance settings schema, if it declares one.
    public let schema: HUDSettingsSchema?

    @Published public internal(set) var size: HUDWidgetSize
    @Published public internal(set) var layer: HUDWidgetLayer
    /// The instance's own settings (keys it was given); read through the subscript to fall
    /// back to the schema's defaults.
    @Published public internal(set) var settings: [String: HUDSettingValue]
    /// MacHUD's edit mode: HUDKit draws the edit controls over the widget and takes its
    /// clicks for dragging; the view may dim or simplify itself.
    @Published public internal(set) var isEditing: Bool

    weak var host: HUDWidgetHost?

    init(instance: HUDWidgetInstance, spec: HUDWidgetSpec, schema: HUDSettingsSchema?, isEditing: Bool, host: HUDWidgetHost?) {
        self.instance = instance.id
        self.type = instance.type
        self.spec = spec
        self.schema = schema
        self.size = instance.size
        self.layer = instance.layer
        self.settings = instance.settings
        self.isEditing = isEditing
        self.host = host
    }

    /// A setting's value, else the schema's default for it, else nil.
    public subscript(key: String) -> HUDSettingValue? {
        settings[key] ?? schema?.field(key)?.default
    }

    /// Changes some of this instance's settings from inside the widget (a city picked in
    /// place, a toggle). Values the schema lists are validated first (all or nothing; the
    /// error is `HUDControlError.invalid`); the change applies at once and is reported to
    /// MacHUD (`change: settings` event) so it persists.
    public func updateSettings(_ changes: [String: HUDSettingValue]) throws {
        var next = settings
        for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
            next[key] = try HUDWidgetInstance.validate(key, value, schema: schema)
        }
        guard next != settings else { return }
        settings = next
        host?.contextChangedSettings(self)
    }

    /// Opens the app for this widget (a tap on a calendar event, "more…"): calls the host's
    /// `onOpen`, or, when the app set none, reports `change: open` so MacHUD can summon the
    /// app's panel.
    public func openApp() {
        host?.open(self)
    }
}
