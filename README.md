# elck

<p align="center">
  <img src="https://github.com/alex-fomin/elck/blob/main/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png?raw=true" width="120" alt="elck app icon">
</p>

**elck** seals any file as `name.ext.elck` and opens it with Touch ID. The inner extension stays, so the default app for that type is the one that edits it.

Prebuilt download: **[Releases](https://github.com/alex-fomin/elck/releases)**.

## Use

- **Seal.** In Finder, right-click a file and choose **Services → Seal with elck**. The original is removed after the `.elck` is written. Sealing does not ask for Touch ID.
- **Open.** Open the `.elck`. macOS asks for Touch ID or the Mac password once. elck decrypts to a temporary file and opens it in the default app.
- **Edit.** Changes are written back into the `.elck` while you edit. Autosave does not ask again.
- **Close.** When the editor is done, elck writes the last copy and deletes the temporary file. VS Code, Cursor, Sublime Text, and BBEdit are waited on until the tab closes. Other apps are waited on until that app quits.
- **About.** Launch elck by itself to see About. The app quits when nothing is open.

Files that are already `.elck` are skipped. There is no menu-bar item and no lock button.

## Limits

The key lives in the Secure Enclave of this Mac. It cannot be exported, and there is no recovery passphrase. A lost key means the sealed files cannot be opened. A file sealed on one Mac cannot be opened on another.

While a file is open, the temporary copy is a normal file. Deleting it is not a secure erase on APFS.

## First launch

The download is not notarized, and it is signed with an Apple Development certificate for Apple silicon. After dragging **elck** to Applications:

- Right-click elck → **Open** → **Open**, or
- Remove quarantine:

```bash
xattr -d com.apple.quarantine /Applications/elck.app
```

On another Mac, build from source with your own signing identity. Sealed files still only open on the Mac that sealed them.

## Build

Requires macOS 14 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project elck.xcodeproj -scheme elck -configuration Release -derivedDataPath DerivedData build
swift test
```

`project.yml` sets `CODE_SIGN_IDENTITY`. Point it at a certificate on your machine before building.

## Format

An `.elck` file starts with `ELK1`, an ephemeral P-256 public key, and an AES-GCM wrap of a per-file key. The rest of the file is the contents sealed with AES-GCM. The wrap key is HKDF-SHA256 of the ECDH secret shared with the Secure Enclave key. Each save uses a new nonce. The enclave private key never leaves the chip.
