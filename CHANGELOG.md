# Changelog

## 1.0.9

- If a copy stops halfway, the unfinished file is closed and removed. It does not stay in the incoming folder until the next launch.
- A folder without owner write, such as mode 0555, receives its files before that mode is applied.

## 1.0.8

- The disk is redrawn. It rises over the hole and flattens into a horizontal band, in orange rather than gold, with a separate ring underneath and a thinner rim.

## 1.0.7

- The Mac’s name under the hole is smaller and quieter. Ready is easier to read. The lower rings fade out before they reach the type, and the name sits a little lower. Dragging still replaces that pair with Drop into that Mac.

## 1.0.6

- The outer disk is quieter, so the hole is the place to drop a file. The other Mac’s name sits under the hole, with Ready beneath it. While dragging, that line reads Drop into that Mac. A file coming in speeds the disk and swells the hole; a finished copy leaves one ripple. The window is a little shorter.

## 1.0.5

- The window opens smaller. The disk is an edge-on hole: a bright rim, the bowed disk above it, and the bent underside below.

## 1.0.4

- A menu bar icon stays after the window closes. Black hole keeps listening. The menu has the File commands, Show Black hole, and Quit.

## 1.0.3

- Clear the incoming folder once at launch, and only after a peer has introduced itself. A second connection no longer deletes a file that is still arriving.
- Drop a connection that does not say hello within 8 seconds, and count those waiting connections toward the limit of 16.
- Copy permission bits, including the executable bit. Dates, extended attributes, resource forks, hard links, symlinks, and setuid are not copied.
- Say when something was left out: "Sent to Mac mini — 2 items skipped." `.DS_Store` stays quiet.
- A folder that is already there is filled in. Files inside still keep both names.

## 1.0.2

- Keep the network connection alive through the hello. 1.0.1 opened the socket and then forgot it, so the other Mac's name never appeared.

## 1.0.1

- Other Macs show up even when Bonjour leaves out the service details. 1.0.0 found them and then ignored them.

## 1.0.0

- Drop zone window. Files and folders dropped on the disk are copied to every other Black hole on the local network.
- Received files land in `Downloads/Black hole`, or a folder you choose.
- Optional pairing code. Blank links with any Black hole on the network.
- Originals are not moved or deleted. Files are not encrypted.
