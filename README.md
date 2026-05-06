# Mounter

A native macOS app that mounts SFTP servers in Finder using Apple's File Provider framework. No kernel extensions, no SIP changes, no macFUSE dependency.

## How It Works

- **Host app** manages SFTP connections (add, edit, remove, connect/disconnect)
- **File Provider extension** exposes remote files in Finder's sidebar, just like iCloud or Dropbox
- **SFTP transport** uses the system `sftp` binary via subprocess — no third-party SSH libraries

## Requirements

- macOS 13.0+
- Xcode 15+ (Swift 5.9)
- An SFTP server to connect to

## Building

1. Open `Mounter.xcodeproj` in Xcode
2. Select the "Mounter" scheme
3. Set your development team in both targets (Mounter and MounterFileProvider)
4. Update the App Group identifier if needed (`group.com.mounter.shared`)
5. Build and run

## Configuration Notes

### App Groups

Both the app and extension share data via an App Group container (`group.com.mounter.shared`). This stores connection configurations so the extension knows how to connect.

### Entitlements

- **App Sandbox** — enabled for both targets
- **Network Client** — required for SFTP connections
- **File Provider Testing Mode** — enabled for debug builds (allows testing without notarization)

### First Run

1. Launch Mounter
2. Click "+" to add a connection (host, username, auth method)
3. Click "Mount" — the SFTP server appears in Finder's sidebar
4. Browse, copy, edit files as if they were local

## Architecture

```
Mounter/                    # Host app (SwiftUI)
  MounterApp.swift          # Entry point
  ContentView.swift         # Connection list
  ConnectionFormView.swift  # Add/edit form
  ConnectionStore.swift     # Persistence + domain management
  KeychainHelper.swift      # Credential storage

MounterFileProvider/        # File Provider extension
  FileProviderExtension.swift   # NSFileProviderReplicatedExtension
  FileProviderEnumerator.swift  # Directory enumeration
  FileProviderItem.swift        # Item modeling

Shared/                     # Shared between app and extension
  SFTPConnection.swift      # SFTP subprocess manager
  SFTPFile.swift            # Remote file model
  ConnectionConfig.swift    # Connection configuration
```

## Limitations (v0.1)

- No conflict resolution (last write wins)
- No symlink support
- Password auth requires `sshpass` or SSH_ASKPASS trick (SSH key auth recommended)
- Single-page enumeration (no pagination for very large directories)
- No file change watching (manual refresh)

## License

MIT
