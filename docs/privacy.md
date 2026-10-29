# Privacy and data flow

Device control runs on your Mac and connected iPhone. Your AI client reads screenshots, interface text and task context, then sends data to the chosen model according to its configuration. When using a cloud model, phone content may leave the Mac.

[简体中文](privacy.zh-CN.md)

## What runs where?

| Component | Responsibility | Data to consider |
| --- | --- | --- |
| iPhone | Runs the target apps; provides device observations and receives actions. | Visible app content and, in Runner mode, available accessibility elements. |
| iPhone-use on your Mac | Maintains the device session and returns observations and action results. | Screenshot files, observation text, session state and diagnostic output. |
| Your AI client | Runs commands, opens images, builds model requests and presents results. | Images, tool output, task history and any client-side logs or sync. |
| Your chosen model service | Plans actions and interprets the data the client supplies. | The actual images/text included in requests; retention depends on that service and account settings. |

Both control modes can supply phone content to the client. The client configuration determines which model receives it and which data is sent.

## What can remain on the Mac?

Session artifacts default to `/private/tmp/iphone-use-<uid>`; `IPHONE_USE_STATE_DIR` can select another location. Configuration is stored in `~/.iphone-use/config.json`, and packaged Runner preparation in `~/Library/Application Support/iphone-use`. Preview access credentials are stored in `~/.iphone-use/previews/<port>/`, subject to `IPHONE_USE_CONFIG_DIR`; signing private keys stay in Keychain. See [architecture](architecture.md) and [mode configuration](control-modes.md).

Treat screenshots, recordings, device identifiers and logs as potentially private. Disconnecting a session is not a promise to erase saved recordings, copied files, client history or provider-side records. The read-only local preview is for viewing; closing its browser tab does not stop the preview service or disconnect the device. Disconnect stops the picture but does not invalidate the preview URL: it can access a later preview explicitly enabled for the same device. To invalidate an old link, follow [preview access revocation](local-preview.md#稳定入口与原标签页重连).

## Before using personal apps

- Check which model endpoint and image-reading tools the client uses, and its retention, logging and synchronization settings.
- Start with a simple navigation task such as Settings → General and check for device information or private notifications in the screenshot. Review the entire image before a public demonstration.
- If screenshots and screen text must stay local, verify local inference and every client, logging and fallback path that handles them. A local CLI alone does not establish that guarantee.
- Share only reviewed, redacted evidence when reporting a problem. Never publish private captures, device identifiers, signing profiles or credentials. Use [private security reporting](../SECURITY.md) for vulnerabilities.

Check your chosen model service's policy and account settings for its data retention rules.
