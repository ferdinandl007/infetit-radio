import XCTest

final class VibePlayerUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testMusicModelDownloadOnSimulator() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--show-model-setup"]
        app.launch()
        let download = app.buttons["Download music model"]
        XCTAssertTrue(download.waitForExistence(timeout: 30))
        capture("Music model setup")
        download.tap()
        XCTAssertTrue(app.progressIndicators["music-model-progress"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Pause download"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["music-model-speed"].waitForExistence(timeout: 180), "Transfer speed should appear while a file is downloading")
        capture("Music model download progress")
        app.buttons["Pause download"].tap()
        let resume = app.buttons["Continue download"]
        XCTAssertTrue(resume.waitForExistence(timeout: 60))
        resume.tap()
        let pause = app.buttons["Pause download"]
        XCTAssertTrue(pause.waitForExistence(timeout: 30))
        let finished = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pause)
        wait(for: [finished], timeout: 1800)
        XCTAssertFalse(app.buttons["Continue download"].exists, "The download must finish, rather than stop on an error")
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 30))
        capture("Radio after model installation")
    }
    func testRadioPlayerAndSoundEditors() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 20))
        capture("Radio")
        app.buttons["station-Joyful Pop"].tap()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        capture("Player")
        let language = app.buttons["radio-language"]
        language.tap()
        XCTAssertTrue(app.navigationBars["Shape your sound"].waitForExistence(timeout: 15))
        let french = app.buttons["French"]
        XCTAssertTrue(french.waitForExistence(timeout: 5))
        french.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Shape your sound"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(language.value as? String, "French")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Shape your sound"].waitForExistence(timeout: 15))
        capture("Sound picker")
        app.buttons["Instruments"].tap()
        XCTAssertTrue(app.buttons["Piano"].waitForExistence(timeout: 5))
        app.buttons["Voice"].tap()
        XCTAssertTrue(app.buttons["Instrumental"].waitForExistence(timeout: 5))
        app.buttons["Moods"].tap()
        XCTAssertTrue(app.buttons["Dreamy"].waitForExistence(timeout: 5))
        app.buttons["Dreamy"].tap()
        app.buttons["Done"].tap()
        let dreamy = app.descendants(matching: .any).matching(identifier: "sound-control-cloud.moon.fill-Dreamy").firstMatch
        XCTAssertTrue(dreamy.waitForExistence(timeout: 5))
        capture("Direct sound sliders")
        let start = dreamy.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        let finish = dreamy.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: finish)
        let intensityValue = String(describing: dreamy.value ?? "")
        let intensityNumber = Int(intensityValue.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? -1
        XCTAssertTrue((20...40).contains(intensityNumber), "Unexpected intensity after drag: \(intensityValue)")
        let tempo = app.descendants(matching: .any).matching(identifier: "tempo-control").firstMatch
        XCTAssertTrue(tempo.waitForExistence(timeout: 5))
        let tempoStart = tempo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let tempoEnd = tempo.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        tempoStart.press(forDuration: 0.1, thenDragTo: tempoEnd)
        let tempoValue = String(describing: tempo.value ?? "")
        let tempoNumber = Int(tempoValue.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? -1
        XCTAssertTrue((145...165).contains(tempoNumber), "Unexpected tempo after drag: \(tempoValue)")
        XCTAssertFalse(app.buttons["Like and save song"].isEnabled)
        app.buttons["Sleep timer"].tap()
        XCTAssertTrue(app.buttons["15 minutes"].waitForExistence(timeout: 5))
        app.buttons["15 minutes"].tap()
        app.buttons["player-playback"].tap()
        XCTAssertEqual(app.buttons["player-playback"].label, "Pause")
        app.buttons["player-playback"].tap()
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 5))
    }
    func testCustomSoundsAndPickerCancellation() throws {
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["Add"].tap()
        let sections = app.scrollViews["sound-sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 10))
        sections.swipeLeft()
        let textures = app.buttons["Textures"]
        if !textures.isHittable { sections.swipeLeft() }
        textures.tap()
        XCTAssertTrue(app.buttons["Airy"].waitForExistence(timeout: 5))
        let lyrics = app.buttons["Lyrics"]
        for _ in 0..<4 where !lyrics.isHittable { sections.swipeLeft() }
        XCTAssertTrue(lyrics.isHittable)
        lyrics.tap()
        XCTAssertTrue(app.buttons["Poetic"].waitForExistence(timeout: 5))
        app.buttons["Poetic"].tap(); app.buttons["Poetic"].tap()
        for _ in 0..<4 where !textures.isHittable { sections.swipeRight() }
        XCTAssertTrue(textures.isHittable)
        textures.tap()
        let term = "Glow " + String(UUID().uuidString.prefix(5))
        let field = app.textFields["sound-search"]
        field.tap(); field.typeText(term)
        XCTAssertTrue(app.buttons["add-custom-sound"].waitForExistence(timeout: 5))
        app.buttons["add-custom-sound"].tap()
        app.navigationBars["Shape your sound"].buttons["Done"].tap()
        let slider = app.descendants(matching: .any).matching(identifier: "sound-control-waveform.path-" + term).firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let from = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        let to = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to)
        let displayed = String(describing: slider.value ?? "")
        let number = Int(displayed.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? -1
        XCTAssertTrue((25...45).contains(number), "Unexpected custom intensity: \(displayed)")
        app.buttons["Add"].tap()
        let sectionsAgain = app.scrollViews["sound-sections"]
        sectionsAgain.swipeLeft()
        if !app.buttons["Textures"].isHittable { sectionsAgain.swipeLeft() }
        app.buttons["Textures"].tap()
        let searchAgain = app.textFields["sound-search"]
        searchAgain.tap(); searchAgain.typeText(term)
        XCTAssertTrue(app.buttons[term].waitForExistence(timeout: 5))
        app.buttons[term].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(slider.exists, "Cancel should keep the previously saved slider")
    }
    func testCreateAndLibrary() throws {
        app.tabBars.buttons["Create"].tap()
        XCTAssertTrue(app.textViews["song-prompt"].waitForExistence(timeout: 10))
        capture("Create")
        let ideaTitle = "Moonlight " + String(UUID().uuidString.prefix(6))
        let prompt = app.textViews["song-prompt"]
        prompt.tap(); prompt.typeText(ideaTitle)
        app.buttons["edit-styles"].tap()
        XCTAssertTrue(app.textViews["styles-editor"].waitForExistence(timeout: 5))
        capture("Styles editor")
        app.buttons["mellow"].tap()
        app.buttons["Done"].tap()
        app.buttons["edit-lyrics"].tap()
        let lyrics = app.textViews["lyrics-editor"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap(); lyrics.typeText("Under the moonlight")
        capture("Lyrics editor")
        app.buttons["Done"].tap()
        app.buttons["Create options"].tap()
        app.buttons["Save idea"].tap()
        XCTAssertTrue(app.staticTexts["idea-saved"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts[ideaTitle].waitForExistence(timeout: 5))
        capture("Library")
        app.staticTexts[ideaTitle].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[ideaTitle].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["mellow"].exists)
        XCTAssertTrue(app.staticTexts["Under the moonlight"].exists)
        capture("Song idea")
    }
    func testSongwritingSettings() throws {
        app.tabBars.buttons["Create"].tap()
        let options = app.buttons["Create options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        app.buttons["Songwriting settings"].tap()
        let cloud = app.switches["Send songwriting text to Gemini"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        if cloud.value as? String == "0" { cloud.tap() }
        XCTAssertTrue(app.secureTextFields["gemini-api-key"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Songwriting"].exists)
        app.buttons["Done"].tap()
    }
    func testAudioImportPicker() throws {
        app.tabBars.buttons["Library"].tap()
        let importButton = app.buttons["Import audio"]
        if !importButton.isHittable { app.swipeUp() }
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 35))
        capture("Audio file picker")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Your vibes"].waitForExistence(timeout: 5))
    }
    func testRadioSongCanBeSavedAndSurvivesRelaunch() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["player-playback"].tap()
        let like = app.buttons["Like and save song"]
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: like)
        waitForExpectations(timeout: 20)
        like.tap()
        XCTAssertTrue(app.buttons["Saved to library"].waitForExistence(timeout: 5))
        let ready = app.staticTexts["radio-ready-count"]
        let queueFull = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "10 ready"), object: ready)
        XCTAssertEqual(XCTWaiter.wait(for: [queueFull], timeout: 10), .completed)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "radio-queued-track").count, 2)
        XCTAssertTrue(app.buttons["radio-queue-disclosure"].exists)
        capture("Radio playback and ready queue")
        app.buttons["Next song"].tap()
        XCTAssertTrue(app.buttons["Like and save song"].waitForExistence(timeout: 15), "Radio should advance to the prepared next song")
        let previous = app.buttons["Previous song"]
        let canGoBack = XCTNSPredicateExpectation(predicate: enabled, object: previous)
        XCTAssertEqual(XCTWaiter.wait(for: [canGoBack], timeout: 8), .completed)
        previous.tap()
        XCTAssertTrue(app.buttons["Saved to library"].waitForExistence(timeout: 5))
        app.buttons["Close player"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Song options"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--fixture-renderer"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Song options"].waitForExistence(timeout: 10))
    }
    func testRadioPlaylistSupportsSkippingAndSeeking() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["player-playback"].tap()

        let current = app.buttons["radio-playlist-current"]
        let upNext = app.buttons.matching(identifier: "radio-queued-track")
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        XCTAssertTrue(upNext.element(boundBy: 1).waitForExistence(timeout: 10))
        let titles = [current.label, upNext.element(boundBy: 0).label, upNext.element(boundBy: 1).label]
        XCTAssertEqual(Set(titles).count, 3)

        let next = app.buttons["Next song"]
        let previous = app.buttons["Previous song"]
        next.tap()
        XCTAssertEqual(current.label, titles[1])
        next.tap()
        XCTAssertEqual(current.label, titles[2])
        previous.tap()
        XCTAssertEqual(current.label, titles[1])
        previous.tap()
        XCTAssertEqual(current.label, titles[0])
        XCTAssertFalse(previous.isEnabled)
        XCTAssertEqual(upNext.element(boundBy: 0).label, titles[1])
        XCTAssertEqual(upNext.element(boundBy: 1).label, titles[2])

        app.buttons["player-playback"].tap()
        let seek = app.sliders["radio-seek"]
        let position = try XCTUnwrap(seek.value as? String)
        seek.adjust(toNormalizedSliderPosition: 0.55)
        XCTAssertNotEqual(seek.value as? String, position)
        XCTAssertEqual(current.label, titles[0])
        capture("Radio playlist and playback position")
    }
    func testSwipeDownClosesRadioPlayer() throws {
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        let handle = app.buttons["player-dismiss-handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: 250))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 5))
    }
    func testAdaptiveRadioPlayer() throws {
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        XCTAssertTrue(app.buttons["player-dismiss-handle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Add"].exists)
        XCTAssertTrue(app.buttons["player-playback"].exists)
        capture("Adaptive radio player")
        app.buttons["player-dismiss-handle"].tap()
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 5))
    }
    func testIPadSystemNavigation() throws {
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        capture("iPad system navigation")
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        create.tap()
        XCTAssertTrue(app.textViews["song-prompt"].waitForExistence(timeout: 5))
        app.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
        app.buttons["Radio"].firstMatch.tap()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 5))
    }
    func testSavedSongUsesTrackPlayer() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["player-playback"].tap()
        let like = app.buttons["Like and save song"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: like)
        waitForExpectations(timeout: 20)
        like.tap()
        app.buttons["Close player"].tap()
        app.tabBars.buttons["Library"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Lofi Beats")).firstMatch.tap()
        XCTAssertTrue(app.otherElements["single-track-player"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sliders["Playback position"].exists)
        XCTAssertTrue(app.otherElements["track-artwork"].exists)
        XCTAssertFalse(app.buttons["Add"].exists)
        capture("Single track player")
        let handle = app.buttons["player-dismiss-handle"]
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 250)))
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
    }
    func testPromptedSongIsSaved() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer", "--fixture-full-context-audio",
                               "-vibe-create-acoustics", "streaming"]
        app.launch()
        app.tabBars.buttons["Create"].tap()
        let prompt = app.textViews["song-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        prompt.tap(); prompt.typeText("A bright new day")
        app.buttons["edit-lyrics"].tap()
        let lyrics = app.textViews["lyrics-editor"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap(); lyrics.typeText("Here comes the morning")
        app.buttons["Done"].tap()
        app.buttons["create-song"].tap()
        app.buttons["open-generation-progress"].tap()
        XCTAssertTrue(app.staticTexts["Whole-song synthesis · step 1 of 16"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Playing while rendering"].waitForExistence(timeout: 8))
        app.buttons["Close generation progress"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Song options"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["A bright new day"].exists)
    }
    func testCreatePlaysBeforeSavingAndThenFinishes() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer", "--fixture-early-audio"]
        app.launch()
        app.tabBars.buttons["Create"].tap()
        app.buttons["Create options"].tap()
        let earlyPlayback = app.buttons["Early playback"].firstMatch
        if !earlyPlayback.exists { app.buttons["Rendering"].tap() }
        XCTAssertTrue(earlyPlayback.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["High quality"].exists)
        earlyPlayback.tap()
        app.buttons["A hazy late-night drive"].tap()
        app.buttons["edit-lyrics"].tap()
        let lyrics = app.textViews["lyrics-editor"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap(); lyrics.typeText("Here comes the morning")
        app.buttons["Done"].tap()
        app.buttons["create-song"].tap()
        let progress = app.buttons["open-generation-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["A little atmosphere"].exists)
        capture("Create playback and rendering in one dock")
        progress.tap()
        XCTAssertTrue(app.staticTexts["Generation queue"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Playing while rendering"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["cancel-creation"].isHittable)
        capture("Expanded generation progress")
        app.buttons["Add another prompt"].tap()
        app.buttons["Warm piano on a rainy day"].tap()
        app.buttons["edit-lyrics"].tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap(); lyrics.typeText("Rain on the window")
        app.buttons["Done"].tap()
        let enqueue = app.buttons["queue-create-song"]
        XCTAssertTrue(enqueue.isHittable)
        enqueue.tap()
        progress.tap()
        XCTAssertTrue(app.staticTexts["Up next"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Warm piano on a rainy day"].exists)
        capture("Expanded progress with a queued prompt")
        app.buttons["Close generation progress"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["A hazy late-night drive"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Warm piano on a rainy day"].waitForExistence(timeout: 15))
    }
    func testCreateDockStaysReachableWithKeyboard() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        let createTab = app.tabBars.buttons["Create"]
        (createTab.exists ? createTab : app.buttons["Create"].firstMatch).tap()
        let prompt = app.textViews["song-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        prompt.tap()
        prompt.typeText("Soft drums and a low piano")
        XCTAssertTrue(app.buttons["create-song"].isHittable)
        XCTAssertFalse(app.staticTexts["A little atmosphere"].exists)
        capture("Create with keyboard and one dock")
    }
    func testRadioWaitsBetweenTracksAndResumesAutomatically() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer", "--fixture-radio-gap"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        let loading = app.descendants(matching: .any)["radio-loading"].firstMatch
        app.buttons["player-playback"].tap()
        for state in ["Waiting for audio", "Preparing in the background", "Waiting for audio", "Preparing in the background"] {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", state), object: loading)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
        }
    }
    func testReadyRadioKeepsPlayingInBackground() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["player-playback"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "radio-queued-track").firstMatch.waitForExistence(timeout: 15))
        let current = app.buttons["radio-playlist-current"]
        let titleBeforeBackground = current.label

        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(15))
        XCTAssertEqual(app.state, .runningBackground)
        app.activate()
        XCTAssertNotEqual(current.label, titleBeforeBackground)
        XCTAssertTrue(app.buttons["Previous song"].isEnabled, "Radio should advance to a ready song while in the background")
        XCTAssertEqual(app.buttons["player-playback"].label, "Pause")
    }
    func testTempoChangeReplacesThePlayingRadioSong() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["player-playback"].tap()
        let like = app.buttons["Like and save song"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: like)
        waitForExpectations(timeout: 20)
        like.tap()
        XCTAssertTrue(app.buttons["Saved to library"].waitForExistence(timeout: 5))

        let tempo = app.descendants(matching: .any).matching(identifier: "tempo-control").firstMatch
        XCTAssertTrue(tempo.exists)
        if !tempo.isHittable { app.swipeUp() }
        let start = tempo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let end = tempo.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(app.staticTexts["radio-sound-change"].waitForExistence(timeout: 2))
        XCTAssertTrue(like.waitForExistence(timeout: 8), "The changed tempo should produce a replacement song during playback")
        XCTAssertEqual(app.buttons["player-playback"].label, "Pause")
    }
    func testBrowseStationCatalog() throws {
        let count = app.staticTexts["station-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "50 stations")
        capture("Station catalog")

        app.buttons["Christmas"].tap()
        XCTAssertEqual(count.label, "7 stations")
        let search = app.textFields["station-search"]
        search.tap()
        search.typeText("jazz\n")
        XCTAssertEqual(count.label, "1 station")
        let jazz = app.buttons["station-Christmas Jazz"]
        XCTAssertTrue(jazz.waitForExistence(timeout: 5))
        capture("Christmas station search")
        jazz.tap()
        XCTAssertTrue(app.staticTexts["Christmas Jazz"].waitForExistence(timeout: 5))
    }

    func testCreateCustomStation() throws {
        let newStation = app.buttons["New station"]
        XCTAssertTrue(newStation.waitForExistence(timeout: 15))
        newStation.tap()
        let name = app.textFields["new-station-name"]
        let create = app.buttons["create-station"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled)
        app.buttons["new-station-template"].tap()
        app.buttons["From scratch"].tap()
        app.buttons["new-station-template"].tap()
        app.collectionViews.buttons["Workout"].tap()
        app.collectionViews.buttons["Power Hour"].tap()
        XCTAssertEqual(app.buttons["new-station-template"].value as? String, "Power Hour")
        capture("New station")
        name.tap()
        name.typeText("Night Drive")
        XCTAssertTrue(create.isHittable)
        create.tap()
        XCTAssertTrue(app.staticTexts["Night Drive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["sound-control-music.note-Electro house"].exists)

        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Night Drive"].waitForExistence(timeout: 5))
    }
    func testLandscapeNavigation() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Create"].tap()
        XCTAssertTrue(app.textViews["song-prompt"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Your vibes"].waitForExistence(timeout: 5))
    }
}
