import XCTest

/// Work the app preserved from a library it could not read, or from an earlier launch, used to be
/// reachable only by reading the raw defaults plist. These tests guard the surface that shows those
/// projects and puts them back in the cart, plus the discard path that drops them for good.
///
/// The app plants deterministic recovery payloads behind launch arguments — the whole surface, or a
/// single backup for the case where a payload still holds a project the user cleared. Every mode
/// plants every key it depends on, so no test inherits state from whatever the simulator holds or
/// from another test.
final class PreservedProjectsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchWithPreservedProject() -> XCUIApplication {
        launchWithSeed("--preserved-projects-ui-test")
    }

    /// Launches with one seed mode. Each mode plants every key it needs, so a test can run on its
    /// own rather than depending on what a previous launch left behind.
    @MainActor
    private func launchWithSeed(_ argument: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [argument]
        app.launch()
        return app
    }

#if DEBUG
    /// The recovery dump is what a written-up report gets read from, so it is checked end to end: the
    /// cart offers it, it opens, and it describes the state the seed planted. Debug builds only, the
    /// same gate the dump itself is behind.
    @MainActor
    func testRecoveryDiagnosticsReportCanBeOpenedFromTheCart() throws {
        let app = launchWithPreservedProject()
        openProjectCart(app)

        let reportButton = app.buttons["projectLibrary.diagnostics"]
        XCTAssertTrue(reportButton.waitForExistence(timeout: 8), "the cart should offer the recovery dump")
        reportButton.tap()

        XCTAssertTrue(app.staticTexts["RECOVERY DIAGNOSTICS"].waitForExistence(timeout: 4), "the dump should open")
        let report = app.staticTexts["projectLibrary.diagnosticsReport"]
        XCTAssertTrue(report.waitForExistence(timeout: 4), "the dump should have a body")
        XCTAssertTrue(report.label.contains("deleted stack: 1 of"), "got: \(report.label)")
        XCTAssertTrue(report.label.contains("recoverable rows: 3"), "got: \(report.label)")
        XCTAssertTrue(report.label.contains("from deleted: 1"), "got: \(report.label)")
        XCTAssertTrue(report.label.contains("ERASED TAKE [deleted, missing]"), "got: \(report.label)")
    }
#endif

    @MainActor
    private func openProjectCart(_ app: XCUIApplication) {
        let libraryButton = app.buttons["Open project library"]
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 8), "project cart button should exist")
        libraryButton.tap()
    }

    /// The preserved rows carry the same identifier, so they are told apart by name rather than by
    /// position — the cart's own list rows do not carry it.
    @MainActor
    private func preservedRow(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons
            .matching(identifier: "projectLibrary.restorePreservedProject")
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
    }

    @MainActor
    private func preservedRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(identifier: "projectLibrary.restorePreservedProject")
    }

    /// The per-row remove control names its project in the accessibility label, so rows are told
    /// apart the same way the restore controls are.
    @MainActor
    private func removeControl(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons
            .matching(identifier: "projectLibrary.dismissRecoverable")
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
    }

    @MainActor
    func testLostProjectIsOfferedAndRestoresIntoTheCart() throws {
        let app = launchWithPreservedProject()
        openProjectCart(app)

        XCTAssertTrue(
            app.staticTexts["RECOVERABLE PROJECTS"].waitForExistence(timeout: 8),
            "the recoverable section should be on screen"
        )
        XCTAssertEqual(preservedRows(app).count, 3, "every preserved and deleted case should be offered")
        XCTAssertFalse(
            app.buttons["RESTORE LAST DELETED PROJECT"].exists,
            "the single restore row is retired in favour of the one list"
        )

        let deletedRow = preservedRow(app, named: "ERASED TAKE")
        XCTAssertTrue(deletedRow.exists, "a deleted project belongs in the same list")
        XCTAssertTrue(deletedRow.label.contains("DELETED"), "got: \(deletedRow.label)")

        let lostRow = preservedRow(app, named: "LOST TAKE")
        XCTAssertTrue(lostRow.waitForExistence(timeout: 8), "the lost project should be offered for restore")
        XCTAssertTrue(lostRow.label.contains("UNREADABLE COPY"), "got: \(lostRow.label)")

        let olderRow = preservedRow(app, named: "GHOST TAKE")
        XCTAssertTrue(olderRow.exists, "an earlier version of the cart's own project should be offered")
        XCTAssertTrue(olderRow.label.contains("EARLIER VERSION"), "got: \(olderRow.label)")

        lostRow.tap()

        XCTAssertTrue(app.staticTexts["LOST TAKE"].exists, "the restored project should be in the cart")
        XCTAssertFalse(preservedRow(app, named: "LOST TAKE").exists, "a restored project stops being offered")
        XCTAssertTrue(olderRow.exists, "restoring one project must leave the other alone")
    }

    @MainActor
    func testEarlierVersionRestoresAsASeparateCopyWithItsOwnName() throws {
        let app = launchWithPreservedProject()
        openProjectCart(app)

        let olderRow = preservedRow(app, named: "GHOST TAKE")
        XCTAssertTrue(olderRow.waitForExistence(timeout: 8), "the earlier version should be offered")
        olderRow.tap()

        // The copy arrives beside the project that was already in the cart, under a free name.
        XCTAssertTrue(app.staticTexts["GHOST TAKE COPY"].waitForExistence(timeout: 8), "the copy should join the cart")
        XCTAssertTrue(app.staticTexts["GHOST TAKE"].exists, "the newer project must still be in the cart")
        XCTAssertFalse(preservedRow(app, named: "GHOST TAKE").exists, "a copy is not offered twice")
        XCTAssertTrue(preservedRow(app, named: "LOST TAKE").exists, "the other preserved project is still offered")
    }

    @MainActor
    func testRestoreCanBeTakenBackWithTheEditorUndoControl() throws {
        let app = launchWithPreservedProject()
        openProjectCart(app)

        let lostRow = preservedRow(app, named: "LOST TAKE")
        XCTAssertTrue(lostRow.waitForExistence(timeout: 8))
        lostRow.tap()
        XCTAssertEqual(preservedRows(app).count, 2, "the restored project stops being offered")

        // The editor's banner is behind this sheet, so the cart has to show the notice itself —
        // otherwise nothing on screen says the restore can be taken back.
        XCTAssertTrue(
            app.staticTexts["pocketToast.cart"].waitForExistence(timeout: 2),
            "the cart should say the restore is undoable"
        )

        app.buttons["DONE"].firstMatch.tap()
        let undoButton = app.buttons["Undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 8), "the editor undo control should be reachable")
        undoButton.tap()

        openProjectCart(app)
        XCTAssertTrue(
            preservedRow(app, named: "LOST TAKE").waitForExistence(timeout: 8),
            "undo must offer the project again"
        )
        XCTAssertEqual(preservedRows(app).count, 3, "the deleted row comes back with the preserved copies")
    }

    /// Deleted projects are rows in the same recovery list as preserved copies, under their own
    /// DELETED label, and the separate "restore last deleted" affordance is gone.
    @MainActor
    func testDeletedProjectIsOfferedInTheSameRecoveryList() throws {
        let app = launchWithPreservedProject()
        openProjectCart(app)

        let deletedRow = preservedRow(app, named: "ERASED TAKE")
        XCTAssertTrue(deletedRow.waitForExistence(timeout: 8), "a deleted project should be offered")
        XCTAssertTrue(deletedRow.label.contains("DELETED"), "got: \(deletedRow.label)")
        XCTAssertFalse(
            app.buttons["RESTORE LAST DELETED PROJECT"].exists,
            "the single restore row should be retired"
        )

        deletedRow.tap()
        XCTAssertTrue(app.staticTexts["ERASED TAKE"].exists, "the project rejoins the cart")
        XCTAssertFalse(preservedRow(app, named: "ERASED TAKE").exists, "a restored project stops being offered")
        XCTAssertEqual(preservedRows(app).count, 2, "the preserved copies are untouched")
    }

    /// A deleted row's clear path goes through its own stack rather than a preserved payload, so it
    /// is driven here rather than assumed from the preserved-row test. Clearing it also has to stick:
    /// the deletion lives on disk, and a relaunch that does not re-seed reads what the clear stored.
    @MainActor
    func testDeletedRowCanBeClearedAndStaysCleared() throws {
        let app = launchWithPreservedProject()
        openProjectCart(app)

        XCTAssertEqual(preservedRows(app).count, 3, "precondition: the deleted row is offered")
        let remove = removeControl(app, named: "ERASED TAKE")
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        remove.tap()

        XCTAssertFalse(preservedRow(app, named: "ERASED TAKE").exists, "the deleted row goes")
        XCTAssertFalse(app.staticTexts["ERASED TAKE"].exists, "clearing a row must not restore it")
        XCTAssertEqual(preservedRows(app).count, 2, "the preserved rows are untouched")
        XCTAssertTrue(preservedRow(app, named: "LOST TAKE").exists)
        XCTAssertTrue(preservedRow(app, named: "GHOST TAKE").exists)

        // Relaunch with the seed switched off, so the app opens on the state the clear persisted
        // instead of having the deleted project planted again.
        app.terminate()
        app.launchArguments.removeAll { $0 == "--preserved-projects-ui-test" }
        app.launch()
        openProjectCart(app)

        XCTAssertFalse(
            preservedRow(app, named: "ERASED TAKE").exists,
            "a cleared deletion must not come back on the next launch"
        )
        XCTAssertTrue(preservedRow(app, named: "LOST TAKE").exists, "the preserved copy is still offered")
    }

    /// A payload can still hold a project the user cleared — the rolling backup does, for a
    /// generation — and the remembered dismissal is what stops it coming back under a different
    /// label. The fixture plants that backup and the dismissal together, so the case is reachable
    /// from a single launch rather than depending on what a previous one left behind, because a
    /// launch rotates the backup forward before the user can act on it.
    @MainActor
    func testBackupHoldingAClearedProjectIsNotOfferedAgain() throws {
        let app = launchWithSeed("--preserved-projects-ui-test-backup")
        openProjectCart(app)

        XCTAssertTrue(
            app.staticTexts["GHOST TAKE"].waitForExistence(timeout: 8),
            "the cart should be on screen"
        )
        XCTAssertFalse(
            app.staticTexts["RECOVERABLE PROJECTS"].exists,
            "the cleared project is the only row the backup could offer, and it must not be offered"
        )
        XCTAssertEqual(preservedRows(app).count, 0)
    }

    /// The control for the test above: same fixture, same backup, no dismissal — so the cleared
    /// project is offered again, labelled as coming from the backup. Without it, "the cleared
    /// project is not offered" would pass just as well if the fixture offered nothing at all.
    @MainActor
    func testBackupHoldingAClearedProjectIsOfferedWhenNotDismissed() throws {
        let app = launchWithSeed("--preserved-projects-ui-test-backup-undismissed")
        openProjectCart(app)

        let row = preservedRow(app, named: "ERASED TAKE")
        XCTAssertTrue(row.waitForExistence(timeout: 8), "the backup still holds the cleared project")
        XCTAssertTrue(row.label.contains("LAST LAUNCH"), "it comes back under the backup's label — got: \(row.label)")
    }

    /// A single row can be cleared on its own — without restoring it, and without touching the rest
    /// of the list or the bulk discard.
    @MainActor
    func testOneRecoverableRowCanBeRemovedOnItsOwn() throws {
        let app = launchWithPreservedProject()
        openProjectCart(app)

        let removeControls = app.buttons.matching(identifier: "projectLibrary.dismissRecoverable")
        XCTAssertTrue(removeControls.firstMatch.waitForExistence(timeout: 8), "each row should offer its own remove control")
        XCTAssertEqual(removeControls.count, 3, "one remove control per row")

        let remove = removeControl(app, named: "LOST TAKE")
        XCTAssertTrue(remove.exists, "the control should name the project it removes")
        remove.tap()

        XCTAssertEqual(preservedRows(app).count, 2, "only that row goes")
        XCTAssertFalse(preservedRow(app, named: "LOST TAKE").exists)
        XCTAssertFalse(app.staticTexts["LOST TAKE"].exists, "removing a row must not also restore it")
        XCTAssertTrue(preservedRow(app, named: "GHOST TAKE").exists, "the other rows are untouched")
        XCTAssertTrue(preservedRow(app, named: "ERASED TAKE").exists, "the deleted row is untouched")
    }

    /// Clearing a row is undoable through the same editor control that undoes an edit, and redo has
    /// to clear it again rather than replay the state before the removal. Both directions run
    /// through the real button the user has, not a store shortcut.
    @MainActor
    func testClearingARowCanBeTakenBackWithTheEditorUndoControl() throws {
        let app = launchWithPreservedProject()
        openProjectCart(app)

        let remove = removeControl(app, named: "LOST TAKE")
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        remove.tap()
        XCTAssertEqual(preservedRows(app).count, 2, "the cleared row stops being offered")
        XCTAssertFalse(app.staticTexts["LOST TAKE"].exists, "clearing a row must not also restore it")

        // The editor's banner is behind this sheet, so the cart has to show the notice itself —
        // otherwise nothing on screen says the row can be brought back.
        XCTAssertTrue(
            app.staticTexts["pocketToast.cart"].waitForExistence(timeout: 2),
            "the cart should say the removal is undoable"
        )

        app.buttons["DONE"].firstMatch.tap()
        let undoButton = app.buttons["Undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 8), "the editor undo control should be reachable")
        XCTAssertTrue(undoButton.isEnabled, "clearing a row must leave something to undo")
        undoButton.tap()

        openProjectCart(app)
        XCTAssertTrue(
            preservedRow(app, named: "LOST TAKE").waitForExistence(timeout: 8),
            "undo must offer the row again"
        )
        XCTAssertEqual(preservedRows(app).count, 3, "every row is back")

        app.buttons["DONE"].firstMatch.tap()
        let redoButton = app.buttons["Redo"]
        XCTAssertTrue(redoButton.waitForExistence(timeout: 8), "the editor redo control should be reachable")
        XCTAssertTrue(redoButton.isEnabled, "taking the removal back must leave something to redo")
        redoButton.tap()

        openProjectCart(app)
        XCTAssertFalse(preservedRow(app, named: "LOST TAKE").exists, "redo must clear the row again")
        XCTAssertEqual(preservedRows(app).count, 2)
    }

    /// One list, one control: discarding clears the deleted project along with the preserved
    /// copies, and leaves the cart itself alone.
    @MainActor
    func testRecoverableProjectsCanBeDiscarded() throws {
        let app = launchWithPreservedProject()
        openProjectCart(app)

        let discardButton = app.buttons["projectLibrary.discardRecoverable"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 8), "the discard control should exist while work is recoverable")
        discardButton.tap()

        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "discarding must be confirmed")
        confirm.buttons["DISCARD"].tap()

        XCTAssertFalse(
            app.staticTexts["RECOVERABLE PROJECTS"].exists,
            "the surface should be gone once everything recoverable is discarded"
        )
        XCTAssertEqual(preservedRows(app).count, 0, "the deleted project goes with the preserved copies")
        XCTAssertTrue(app.staticTexts["GHOST TAKE"].exists, "the project in the cart is untouched")
    }
}
