/// Dictation's transport marker. Apply exactly once at the controller's final voice-post boundary,
/// not in the general session client, composer, recognition, captions or transcript logs.
public enum VoicePost {
    public static let prefix = "[voice] "
    public static func transportText(_ transcript: String) -> String { prefix + transcript }
}
