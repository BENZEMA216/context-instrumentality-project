import Foundation

/// Watch disk-capacity observations and decisions remain on the Watch. This is
/// an outbound diagnostic boundary, not permission to change the local journal,
/// capture evidence, audio transfers, or durable receipts.
public enum WatchDiagnosticTransferPolicy {
    // New kinds require an explicit review before they can leave the Watch.
    // Free-form NSError/localized failure records intentionally remain local:
    // their text or error codes can reveal a disk-capacity failure indirectly.
    private static let transferableKinds: Set<String> = [
        "capture_start_requested", "audio_gap", "gap_closed", "audio_started",
        "audio_format_changed", "segment_opened", "segment_sealed",
        "tail_recovered", "recovered_unknown_interval", "microphone_permission_denied",
        "capture_attempt_started", "capture_engine_started", "capture_attempt_audio_confirmed",
        "automatic_resume_attempt", "automatic_resume_exhausted", "automatic_resume_scheduled",
        "capture_attempts_cancelled", "capture_telemetry", "audio_interruption",
        "audio_route_changed", "audio_engine_configuration_changed", "resume_requires_user",
        "watch.background_connectivity_started", "watch.background_connectivity_expired",
        "watch.background_connectivity_finished", "file_transfer_callback_ignored",
        "file_preemption_callback_ignored", "file_transfer_obsolete_callback",
        "file_delivered_waiting_ack", "phone_durable_ack", "file_transfer_disappeared_grace",
        "file_transfer_enqueued", "transfer_candidate_index_bootstrap",
        "file_transfer_priority_yield_requested", "phone_receipt_request_immediate_attempt",
        "phone_receipt_request_immediate_reply", "phone_receipt_request_enqueued",
        "file_stalled_transfer_cancel_requested", "file_transfer_cancel_requested_after_ack",
        "file_transfer_queue"
    ]

    // Snapshot details can wrap arbitrary writer/NSError messages. Only these
    // known capture-control messages are transferable; state and times remain
    // truthful even when the local explanation cannot be sent.
    private static let transferableDetails: Set<String> = [
        "idle", "starting", "recording", "paused", "interrupted", "ended", "failed",
        "音频状态待确认，你已选择重新连接麦克风。",
        "你已暂停，点击继续才会重新录音。",
        "本次录音已结束。已保存片段会继续等待手机确认。",
        "未收到新的麦克风音频，录音已中断，请点击继续。",
        "系统音频服务已重置，请点击继续。",
        "麦克风被系统或其他应用占用；未录到的时间会保留为缺口。",
        "音频输入发生变化，正在尝试恢复。",
        "音频硬件格式发生变化，正在重新连接。"
    ]

    public static func mayTransfer(_ event: RecordingEvent) -> Bool {
        if event.kind.hasPrefix("watch.transfer_") {
            guard let value = WatchTransferDiagnostic.parse(event) else { return false }
            // Disk-capacity observations remain local under the existing policy.
            return value.refusal?.reason != .capacityLimit
        }
        if ["user_paused", "user_ended", "capture_interrupted"].contains(event.kind) {
            return transferableDetails.contains(event.detail)
        }
        guard transferableKinds.contains(event.kind) else { return false }
        // Protect legacy records as well as known kinds accidentally reused for
        // disk observations. This rejects numeric and derived capacity facts.
        let compact = event.detail.lowercased().filter { $0.isLetter || $0.isNumber }
        let localOnlyMarkers = [
            "freebytes", "availablebytes", "remainingbytes", "disk", "storage", "capacity",
            "insufficientspace", "lowspace", "outofspace", "nospace", "enospc", "edquot",
            "空间", "存储", "储存", "磁盘", "容量",
            "domain", "error", "code", "localizeddescription", "nscocoaerrordomain", "nsposixerrordomain",
            "message", "description"
        ]
        guard !localOnlyMarkers.contains(where: compact.contains) else { return false }
        // The generic cancellation reason can follow a writer capacity failure;
        // more specific audio/user cancellation reasons remain transferable.
        return !(event.kind == "capture_attempts_cancelled" && compact.contains("reasoncapturefailed"))
    }

    /// A mixed or undecodable legacy event packet must be cancelled in full.
    /// Its eligible records can then be reselected from the unchanged journal.
    public static func transferableBatch(from data: Data?) -> [RecordingEvent]? {
        guard let data,
              let events = try? TransportCodec.decode([RecordingEvent].self, from: data),
              !events.isEmpty, events.allSatisfy(mayTransfer) else { return nil }
        return events
    }

    public static func shouldCancelQueuedUserInfo(_ userInfo: [String: Any]) -> Bool {
        guard userInfo.keys.contains(TransportCodec.eventsKey) else { return false }
        return transferableBatch(from: userInfo[TransportCodec.eventsKey] as? Data) == nil
    }

    public static func snapshotForTransfer(_ original: RecorderSnapshot) -> RecorderSnapshot {
        var result = original
        if let detail = original.detail, !transferableDetails.contains(detail) { result.detail = nil }
        return result
    }
}
