"""Map the detailed WeFlow JSON file format into Hub evidence."""

def scope_value(value, field="account, conversation ID or title"):
    if (not isinstance(value, str) or not 1 <= len(value) <= 512 or
            value != value.strip() or not value.isprintable()):
        raise ValueError(f"Expected {field} with 1–512 printable characters and no surrounding whitespace.")
    return value


def _platform_id(value):
    if value is None or value == "" or (type(value) in (int, str) and str(value) == "0"):
        return None
    if type(value) is int:
        return str(value)
    return scope_value(value, "WeFlow message identifier")


def _seconds_to_ms(value, field):
    # WeFlow writes Unix seconds. A millisecond input is a different format.
    if type(value) is not int or not 0 < value < 10_000_000_000:
        raise ValueError(f"WeFlow {field} must be a Unix timestamp in seconds.")
    return value * 1000


def weflow_rows(archive, batch_sha256, account, tier, stable_id):
    """Preserve the export's message boundaries; never open referenced media."""
    account = scope_value(account, "--account namespace")
    if not isinstance(archive, dict):
        raise ValueError("Expected a WeFlow native JSON export.")
    header, session, messages = (archive.get(key) for key in ("weflow", "session", "messages"))
    if (not isinstance(header, dict) or header.get("generator") != "WeFlow" or
            header.get("format", "json") != "json" or not isinstance(session, dict) or
            not isinstance(messages, list)):
        raise ValueError("Expected WeFlow native JSON with weflow, session and messages.")
    conversation = scope_value(session.get("accountId"), "WeFlow session.accountId")
    if "messageCount" in session and (type(session["messageCount"]) is not int or
                                       session["messageCount"] != len(messages)):
        raise ValueError("WeFlow session.messageCount differs from the selected messages.")
    observed = _seconds_to_ms(header.get("exportedAt"), "exportedAt")
    version = scope_value(header.get("version"), "WeFlow format version")
    episode = stable_id("wechat-conversation", account, conversation)
    for index, message in enumerate(messages):
        if not isinstance(message, dict):
            raise ValueError(f"Expected a WeFlow message object at index {index}.")
        at = _seconds_to_ms(message.get("createTime"), "createTime")
        sent = message.get("isSend")
        local_type = message.get("localType")
        if type(sent) is not int or sent not in (0, 1) or type(local_type) is not int:
            raise ValueError(f"Invalid WeFlow isSend or localType at index {index}.")
        if "content" not in message or not isinstance(message["content"], (str, type(None))):
            raise ValueError(f"Invalid WeFlow message content at index {index}.")

        platform_id = _platform_id(message.get("platformMessageId"))
        if platform_id is None:
            identifier = stable_id("weflow", episode, "file", batch_sha256, index)
        else:
            identifier = stable_id("weflow", episode, "message", platform_id)
        provenance = {"connector": "WeFlow", "source_id": identifier, "version": version,
                      "locator": f"sha256:{batch_sha256}#/messages/{index}"}
        if platform_id is not None:
            provenance["platform_message_id"] = platform_id
        context = {"account": account, "conversation_id": conversation, "local_type": local_type}
        for obj, key, destination in ((session, "displayName", "conversation_name"),
                                      (session, "type", "conversation_type"),
                                      (message, "type", "message_type"),
                                      (message, "senderUsername", "sender_id"),
                                      (message, "senderDisplayName", "sender_name")):
            if isinstance(obj.get(key), str) and obj[key]:
                context[destination] = obj[key]

        # Media export options can produce a path, placeholder or transcription
        # in the same field. Keep those values in the export's representation.
        content = {}
        if local_type == 1 and message["content"] is not None:
            content["text"] = message["content"]
        else:
            content["exported_content"] = message["content"]
        for key in ("quotedSender", "quotedContent"):
            if isinstance(message.get(key), str):
                content[key] = message[key]
        if message.get("appMsgKind") == "quote" and content.get("quotedContent"):
            # The producer appends this exact suffix when rendering a reply.
            # Only index the speaker's own words if the quoted part agrees.
            quote_label = content["quotedContent"]
            if content.get("quotedSender"):
                quote_label = content["quotedSender"] + "：" + quote_label
            suffix = "[引用 " + quote_label + "]"
            rendered = message["content"]
            if isinstance(rendered, str) and rendered.endswith(suffix):
                content["exported_content"] = rendered
                content["text"] = rendered.removesuffix(suffix)
        event = {"id": identifier, "source": "wechat.message", "kind": "message",
                 "episode_id": episode, "actor": "self" if sent else context.get("sender_id", "unknown"),
                 "t_start": at, "t_end": at, "t_observed": observed, "content": content,
                 "context": context, "provenance": provenance, "privacy": {"tier": tier}}
        reply = _platform_id(message.get("replyToMessageId"))
        if reply is not None:
            provenance["reply_to_message_id"] = reply
            event["links"] = [{"relation": "reply_to",
                               "target_id": stable_id("weflow", episode, "message", reply)}]
        yield event
