# 091.005 — Review fixes

## Context

A review loop on the stack (#1084, #1085, #1087) and an end-to-end pass in a Debug app.
This file records the findings that changed code.

## Change

| Finding | Problem | Correction |
| --- | --- | --- |
| R1 | The listen address and port were saved only when a listener became ready. An edit in Settings followed by a quit was lost, and a start at launch could use a wider address than the one shown. | `MirrorHost.address` and `MirrorHost.port` save each valid edit to `UserDefaults`. An invalid value does not replace the saved one. |
| R2 | A failed read of the saved devices showed **No paired devices.** | `MirrorHost.deviceListError` holds the failure. Settings shows it with **Try Again**, which reads again without a listener start. A missing identity is still an empty list. |
