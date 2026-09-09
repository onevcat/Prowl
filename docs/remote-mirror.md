# Remote Mirror panes

Remote Mirror connects two Prowl apps to the same running Host terminal. Both the
Host keyboard and one remote keyboard can send input. Each Host pane permits one
remote mirror; another subscription receives `PANE_BUSY`.

## Host

Open the network button next to notifications. Enter the listening IP and port,
then choose **Start Host**. `0.0.0.0` listens on all IPv4 interfaces; a specific local
IP restricts the listener to that address. Use this Mac's reachable IP on the Client.
Copy the random pairing key from the panel. Closing the panel keeps the service on.
Stopping Host disconnects mirrors without closing any local pane or program.
Quitting Prowl stops the service. This is not a detached terminal daemon.

## Client

Open **Add to Prowl → Remote Mirror Pane**. Enter the Host IP, port, and pairing key.
Connect, then select an available pane. The mirror appears under **Remote Mirrors**
in the sidebar. Closing it only disconnects the remote subscription.
After a disconnect, close the mirror and create a new one to get a fresh baseline.

The Host owns the terminal grid dimensions. A smaller Client scrolls the replica
canvas instead of resizing the Host PTY. Colors, cursor location, and changing
terminal text are transferred as complete VT frames. The Host samples subscribed
panes every 200 ms, and only sends changed frames. A slow link holds at most one
unacknowledged frame per pane. With no subscriptions, the Host does not read frames.
Each frame replaces the replica's display and terminal modes; remote key and paste
bytes are forwarded to the Host without re-encoding the text.

**History** loads retained text, 200 lines per request, from a bounded snapshot of
the Host's terminal history and screen (up to 2 MiB of UTF-8 text, trimmed at a complete character boundary). **Load Earlier**
fetches preceding pages of that same snapshot. **Refresh** requests current retained
text. Live output does not scroll this view. History currently preserves text, not
cell styling. Erased transient output is not recorded or recoverable.

## Transport and current boundaries

The native connection uses TLS 1.2 with a randomly generated pre-shared pairing
key. The key changes whenever Host starts. It authenticates before terminal
metadata or content is sent. There is no public web endpoint or new `prowl` command.
An internal subprocess of the app executable connects only to the Client's loopback
listener and renders VT data into the replica PTY. It never runs the Host's program.

The Ghostty bridge exports display state, not a complete terminal checkpoint.
OSC 8 link targets, cursor shape, and terminal graphics are not guaranteed. Brief
updates between samples may be skipped. Native app integration is under development;
see the implementation record for verification status before relying on this build.

## Local development

This branch requires the mirror bridge build of Ghostty. Build the sibling Ghostty
repository first, then use:

```sh
PROWL_GHOSTTY_SOURCE_DIR=../ghostty make build-app
```

The override copies its built XCFramework and terminal resources without changing
the pinned upstream artifact or downloading another Ghostty build. Both fork branches
can remain local until their changes are ready to publish.
