import SwiftUI

/// Order, hide and lock groups for the active playlist (stored on this phone).
struct GroupsManagerView: View {
    @EnvironmentObject var library: Library
    @State private var section: GroupSection = .live
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                Picker("القسم", selection: $section) { ForEach(GroupSection.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
            } footer: {
                Text("اسحب ☰ لتغيير الترتيب. 👁 إخفاء المجموعة من كل الشاشات. 🔒 تحتاج Face ID أو رمز الجهاز لفتحها، وتختفي محتوياتها من «الكل» والبحث والرئيسية حتى تُفتح.")
            }
            Section("\(section.title) (\(library.orderedCats(section).count))") {
                let _ = library.groupsTick
                ForEach(library.orderedCats(section)) { c in
                    let hidden = library.isHidden(c.id, section)
                    let locked = library.isLocked(c.id, section)
                    HStack(spacing: 14) {
                        Text(c.name).lineLimit(2).foregroundStyle(hidden ? .secondary : .primary).strikethrough(hidden)
                        Spacer()
                        Button { library.toggle("hidden", c.id, section) } label: {
                            Image(systemName: hidden ? "eye.slash" : "eye").foregroundStyle(hidden ? Color.secondary : Theme.teal)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(hidden ? "إظهار" : "إخفاء")
                        Button { library.toggle("locked", c.id, section) } label: {
                            Image(systemName: locked ? "lock.fill" : "lock.open").foregroundStyle(locked ? Theme.accent : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(locked ? "إلغاء القفل" : "قفل")
                    }
                }
                .onMove { library.moveGroups(section, from: $0, to: $1) }
            }
            Section {
                Button(role: .destructive) { confirmReset = true } label: { Label("إرجاع ترتيب المزوّد وإلغاء الإخفاء والقفل", systemImage: "arrow.uturn.backward") }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("المجموعات")
        .confirmationDialog("إرجاع \(section.title) كما يرسلها المزوّد؟", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("إرجاع", role: .destructive) { library.resetGroups(section) }
        }
    }
}

/// Settings entry: opening the manager needs the phone's lock when some groups are locked.
struct GroupsSettingsSection: View {
    @EnvironmentObject var library: Library
    @Binding var open: Bool

    var body: some View {
        Section {
            Button {
                if library.hasLocks && !library.isUnlocked { Task { if await library.unlock(reason: "إدارة المجموعات") { open = true } } }
                else { open = true }
            } label: { Label("ترتيب وإخفاء وقفل المجموعات", systemImage: "list.bullet.indent") }
            if library.hasLocks {
                if library.isUnlocked {
                    Button { library.lockNow() } label: { Label("اقفل المجموعات الآن", systemImage: "lock.fill") }
                } else {
                    Button { Task { _ = await library.unlock() } } label: { Label("افتح المجموعات المقفلة (15 دقيقة)", systemImage: "lock.open") }
                }
            }
        } header: { Text("المجموعات") }
    }
}

/// Preferred audio / subtitle language, applied when a stream opens (the player picks the matching track if there is one).
struct LanguageSettingsSection: View {
    @AppStorage(PlayerPrefs.audioKey) private var audio = ""
    @AppStorage(PlayerPrefs.subsKey) private var subs = ""
    @AppStorage(PlayerPrefs.autoPiPKey) private var autoPiP = true

    var body: some View {
        Section {
            Toggle("صورة داخل صورة عند الخروج من التطبيق", isOn: $autoPiP)
        } header: { Text("التشغيل") } footer: {
            Text("المشغّل مبني على mpv: يعرض ألوان Dolby Vision وترجمات ASS بشكل صحيح ويدعم صورة داخل صورة.")
        }
        Section {
            Picker("الصوت", selection: $audio) {
                Text("لغة الملف").tag("")
                Text("العربية").tag(PlayerPrefs.arabic)
                Text("الإنجليزية").tag(PlayerPrefs.english)
            }
            Picker("الترجمة", selection: $subs) {
                Text("بدون تفضيل").tag("")
                Text("العربية").tag(PlayerPrefs.arabic)
                Text("الإنجليزية").tag(PlayerPrefs.english)
            }
        } header: { Text("الصوت والترجمة") } footer: {
            Text("تُطبّق عند فتح فيلم أو حلقة أو قناة. إذا لم يوجد مسار بهذه اللغة يبقى اختيار الملف.")
        }
    }
}

enum PlayerPrefs {
    static let audioKey = "pref.audio", subsKey = "pref.subs", autoPiPKey = "pref.autopip", softwareKey = "pref.swdecode"
    /// Software decoding: slower and warmer, but fixes wrong colours on some HDR / Dolby Vision files.
    static var softwareDecoding: Bool { UserDefaults.standard.bool(forKey: softwareKey) }
    /// Leaving the app while a video plays moves it to the floating window (default on).
    static var autoPiP: Bool { UserDefaults.standard.object(forKey: autoPiPKey) as? Bool ?? true }
    static let arabic = "ara,ar,arabic", english = "eng,en,english"
    static var audio: String { UserDefaults.standard.string(forKey: audioKey) ?? "" }
    static var subs: String { UserDefaults.standard.string(forKey: subsKey) ?? "" }
}
