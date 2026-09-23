#!/bin/zsh
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/pocketctrl-cu-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# Compile real protocol and injector declarations without starting the host, sockets or UI.
python3 - "$test_dir/Extracted.swift" <<'PY'
from pathlib import Path
import sys
r=Path('PocketCtrlNative')
s=(r/'PocketCtrl/RemoteInput.swift').read_text()
parts=['import AppKit\nimport CryptoKit\nimport Foundation\nimport ApplicationServices\n']
parts += [s[s.index('enum RemoteInputKind:'):s.index('struct ViewerFeedback:')]]
parts += [s[s.index('enum ControlPayloadType:'):s.index('enum ClipboardVideoDatagram')]]
parts += [s[s.index('final class MacInputInjector:'):]]
s=(r/'PocketCtrl/SecureSessionDatagram.swift').read_text()
parts += [s[:s.index('struct ActiveViewerSessionSnapshot')]]
s=(r/'PocketCtrlMobile/ClientModel.swift').read_text()
parts += [s[s.index('enum ClientControlPayloadType:'):s.index('struct ClientSavedMac:')]]
Path(sys.argv[1]).write_text('\n'.join(parts))
PY
xcrun swiftc -parse-as-library -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "${TMPDIR:-/tmp}/pocketctrl-cu-test-module-cache" \
    PocketCtrlNative/Shared/ComputerUseProtocol.swift \
    PocketCtrlNative/Shared/ComputerUseDiagnostics.swift \
    PocketCtrlNative/PocketCtrl/TrustedDeviceStore.swift \
    PocketCtrlNative/PocketCtrlMobile/ClientSecureSessionDatagram.swift \
    PocketCtrlNative/PocketCtrlMobile/ClientComputerUseSession.swift \
    PocketCtrlNative/PocketCtrl/OpenAIComputerUseProvider.swift \
    PocketCtrlNative/PocketCtrl/OpenAIComputerUseOptions.swift \
    PocketCtrlNative/PocketCtrl/OpenAIModelCatalog.swift \
    PocketCtrlNative/PocketCtrl/ComputerUseFocusResolver.swift \
    PocketCtrlNative/PocketCtrl/ComputerUseCoordinator.swift \
    PocketCtrlNative/PocketCtrl/ComputerUseDesktop.swift \
    PocketCtrlNative/PocketCtrl/ComputerUseScreenValidation.swift \
    Tests/ComputerUseTestSupport.swift "$test_dir/Extracted.swift" \
    Tests/ComputerUseCases.swift -o "$test_dir/tests"
"$test_dir/tests" "$@"
