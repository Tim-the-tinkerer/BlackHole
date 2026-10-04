# Black hole

A drop zone for copying files to another Mac on the same network.

Open Black hole on both computers. The window is a small edge-on black hole. The other Mac’s name sits under the hole. Drop files or folders on the disk. They are copied into `Downloads/Black hole` on the other Mac. The originals stay where they are.

The copy includes the file’s bytes and its permission bits. A simple app stays launchable. A bundle that depends on symlinks may not, because symlinks are left out, along with dates, extended attributes, resource forks, hard links, and setuid. A folder that is already in the receive folder is filled in, not renamed to “Folder 2”. Files inside still keep both names (`note.txt`, then `note 2.txt`). `.DS_Store` is left out quietly. If anything else could not be sent, the status says so: “Sent to Office — 2 items skipped.”

The File menu, and the same menu on the menu bar icon, can show received files, choose a receive folder, or set a pairing code. Closing the window leaves Black hole in the menu bar. It keeps listening. Show Black hole opens the disk again. Quit is in that menu. Leave the code blank to link with every Black hole on the network. Set the same code on both Macs if other people are on the network. The code decides who may connect. It does not encrypt the files.

macOS may ask to allow incoming connections and local network access. Allow both, on both Macs. Both computers need to be awake, on the same network, with Black hole open.

Copy `Black hole.app` to the other Mac. The first time you open it there, use Control-click → Open if Gatekeeper asks.

```bash
./build-app.sh
```
