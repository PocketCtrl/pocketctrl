// SPDX-License-Identifier: MPL-2.0

// Run only against disposable defaults suites, never the real app's preferences.
func checkIdentity(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    print("PASS: \(message)")
}

func testHostIdentity() {
    let suiteName = "app.pocketctrl.tests.identity.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = PersistentHostIdentity.loadOrCreate(in: defaults)
    checkIdentity(first.hasPrefix("PCTRL-") && first.count == 22, "new installs generate the existing host ID format")
    checkIdentity(defaults.string(forKey: PersistentHostIdentity.defaultsKey) == first, "new identity is persisted")
    checkIdentity(PersistentHostIdentity.loadOrCreate(in: defaults) == first, "repeated startup preserves identity")

    let legacy = "PCTRL-0123456789ABCDEF"
    defaults.set(legacy, forKey: PersistentHostIdentity.defaultsKey)
    defaults.set("02:00:00:00:00:01", forKey: "PocketCtrl.hostIdentityMAC")
    checkIdentity(PersistentHostIdentity.loadOrCreate(in: defaults) == legacy, "upgrading preserves the existing host ID")
    defaults.set("02:00:00:00:00:02", forKey: "PocketCtrl.hostIdentityMAC")
    checkIdentity(PersistentHostIdentity.loadOrCreate(in: defaults) == legacy, "changed legacy network identity does not rotate the host ID")
    defaults.removeObject(forKey: "PocketCtrl.hostIdentityMAC")
    checkIdentity(PersistentHostIdentity.loadOrCreate(in: defaults) == legacy, "missing network identity does not rotate the host ID")
    let reopenedDefaults = UserDefaults(suiteName: suiteName)!
    checkIdentity(PersistentHostIdentity.loadOrCreate(in: reopenedDefaults) == legacy, "identity survives reopening its preferences store")

    defaults.set(" \n", forKey: PersistentHostIdentity.defaultsKey)
    let repaired = PersistentHostIdentity.loadOrCreate(in: defaults)
    checkIdentity(repaired.hasPrefix("PCTRL-") && repaired != legacy, "empty identity gets a new valid identity")
    checkIdentity(PersistentHostIdentity.loadOrCreate(in: defaults) == repaired, "repaired identity is stable")
    defaults.removeObject(forKey: PersistentHostIdentity.defaultsKey)
    checkIdentity(PersistentHostIdentity.loadOrCreate(in: defaults) != repaired, "explicit removal of app identity creates a new identity")
}

testHostIdentity()
