import Foundation

/// Which build this is, read back out of the bundle it was stamped into.
///
/// `scripts/build.sh` passes `OMODACHI_BUILD_COMMIT` and `OMODACHI_BUILD_TIME`
/// to every xcodebuild invocation; the Info.plist expands them into
/// `OmodachiBuildCommit` and `CFBundleVersion`. A build made without the script
/// (a bare `xcodebuild`, or Xcode's own Run) keeps `project.yml`'s defaults, so
/// the values are always present and the line always reads the same shape.
enum BuildStamp {
    /// The git short sha the build was made from, or `"unknown"`.
    static var commit: String { string("OmodachiBuildCommit") ?? "unknown" }

    /// `CFBundleVersion` — `yyyymmddHHMM` when the script stamped it.
    static var version: String { string("CFBundleVersion") ?? "" }

    /// `yyyymmddHHMM` read back as `yyyy-mm-dd HH:MM`. Anything that is not
    /// twelve digits is handed back untouched rather than mangled.
    static var time: String { Self.readableTime(version) }

    /// The one line the Settings surface shows.
    static var summary: String { Strings.settingsBuildStamp(commit, time) }

    static func readableTime(_ raw: String) -> String {
        let digits = raw.trimmingCharacters(in: .whitespaces)
        guard digits.count == 12, digits.allSatisfy(\.isNumber) else { return digits }
        return Format.stamp(digits) ?? digits
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
