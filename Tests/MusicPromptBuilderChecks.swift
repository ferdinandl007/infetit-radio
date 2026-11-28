import Foundation

@main struct MusicPromptBuilderChecks {
    static func main() {
        let builder = MusicPromptBuilder()
        let traits: [MusicProfile.Trait] = [
            .init(name: "Lo-fi", category: .genre, intensity: 0.8),
            .init(name: "Boom bap", category: .genre, intensity: 0.2),
            .init(name: "Mellow", category: .mood, intensity: 0.5),
            .init(name: "Piano", category: .instrument, intensity: 0),
            .init(name: "Instrumental", category: .voice, intensity: 0.7)
        ]
        let profile = MusicProfile(name: "Lofi Beats", traits: traits, tempo: 78)
        let request = builder.makeRequest(profile: profile, seed: 42)
        precondition(request.stationName == "Lofi Beats" && request.seed == 42)
        precondition(request.style == "instrumental; styles: prominent lo-fi, subtle boom bap; moods: moderate mellow; 78 BPM")
        precondition(request.lyrics.isEmpty && request.maxSemanticFrames == 5_000 && request.synthesisSteps == 16)
        precondition(builder.makeRequest(profile: profile, seed: 43).style == request.style)
        let vocal = MusicProfile(name: "Vocals", traits: [.init(name: "Vocals", category: .voice, intensity: 1), .init(name: "Instrumental", category: .voice, intensity: 0.4)], tempo: 999)
        let vocalRequest = builder.makeRequest(profile: vocal, seed: 1)
        precondition(vocalRequest.style == "vocal music; upfront lead vocal, clear diction, light vocal reverb; 180 BPM" && vocalRequest.lyrics.isEmpty)
        let vocalRadio = builder.makeRadioPlaybackRequest(profile: vocal, seed: 1, idea: "", voiceOverride: nil, arrangement: 0)
        precondition(vocalRadio.style.contains("clear diction") && vocalRadio.synthesisSteps == 8)
        let instrumentalRadio = builder.makeRadioPlaybackRequest(profile: vocal, seed: 1, idea: "", voiceOverride: .instrumental,
                                                                arrangement: 0, renderingSteps: .eight)
        precondition(!instrumentalRadio.style.contains("clear diction") && instrumentalRadio.synthesisSteps == 8)
        let radioTiming = RadioRenderTiming(voice: .vocals, steps: 8, elapsed: .seconds(75),
                                           synthesis: .seconds(28), audioDuration: 120)
        precondition(radioTiming.stepCount(preferred: .sixteen, readySongs: 1, voice: .vocals) == 8)
        precondition(radioTiming.stepCount(preferred: .sixteen, readySongs: 2, voice: .instrumental) == 8)
        precondition(radioTiming.stepCount(preferred: .thirtyTwo, readySongs: 2, voice: .vocals) == 9)
        precondition(radioTiming.stepCount(preferred: .eight, readySongs: 2, voice: .vocals) == 8)
        let nineSteps = RadioRenderTiming(voice: .vocals, steps: 9, elapsed: .seconds(105),
                                         synthesis: .seconds(36), audioDuration: 120)
        precondition(nineSteps.stepCount(preferred: .sixteen, readySongs: 2, voice: .vocals) == 9)
        let slowerRadio = RadioRenderTiming(voice: .vocals, steps: 9, elapsed: .seconds(110),
                                           synthesis: .seconds(36), audioDuration: 120)
        precondition(slowerRadio.stepCount(preferred: .sixteen, readySongs: 2, voice: .vocals) == 8)
        let empty = MusicProfile(name: "Empty", traits: [.init(name: "Vocals", category: .voice, intensity: 0)], tempo: .nan)
        precondition(builder.makeRequest(profile: empty, seed: 1).style == "90 BPM")
        let defaultVoice = MusicProfile(name: "Default", traits: [], tempo: 90)
        precondition(builder.makeRequest(profile: defaultVoice, seed: 1).voice == .vocals)
        let idea = builder.makeRequest(profile: profile, seed: 5, idea: "a trip to the moon", voiceOverride: .vocals)
        precondition(idea.voice == .vocals && idea.style.contains("song idea: a trip to the moon") && !idea.style.contains("instrumental"))
        precondition(idea.withLyrics("[Verse]\nHello").lyrics == "[Verse]\nHello")
        var created = builder.makeCreateRequest(idea: "a train at midnight", styles: "dreamy piano", instrumental: false, seed: 7)
        precondition(created.style == "vocal music; styles: dreamy piano; song idea: a train at midnight")
        precondition(created.voice == .vocals && created.lyrics.isEmpty)
        precondition(created.purpose == .createdSong && created.maxSemanticFrames == 5_200 && request.purpose == .radio)
        precondition(created.synthesisSteps == 32)
        precondition(created.createRenderer == .metal && request.createRenderer == .metal)
        created.createRenderer = .metalPaired
        let supplied = created.withLyrics("[Chorus]\nUnder the moonlight")
        precondition(supplied.lyrics == "[Chorus]\nUnder the moonlight" && supplied.style == created.style && supplied.createRenderer == .metalPaired)
        let extended = builder.makeCreateRequest(idea: "a train at midnight", styles: "dreamy piano", instrumental: false, seed: 7, length: .extended).withLyrics("[Outro]\nHome at last")
        precondition(extended.createRenderer == .metal && extended.maxSemanticFrames == 6_400 && extended.minimumSemanticFrames == 5_250)
        precondition(extended.style.contains("extended arrangement with a closing section"))
        let fullSong = builder.makeCreateRequest(idea: "Lo-fi", styles: "", instrumental: true, seed: 7, length: .fullSong)
        precondition(fullSong.minimumSemanticFrames == 3_000 && fullSong.maxSemanticFrames == 5_200 && fullSong.synthesisSteps == 32)
        precondition(AppleMusicQuery.parse("I want a Taylor Swift song")?.term == "Taylor Swift")
        precondition(AppleMusicQuery.parse("Play Shake It Off by Taylor Swift")?.artistOnly == false)
        precondition(AppleMusicQuery.parse("Make a piano song with a melancholy chorus") == nil)
        print("Music prompt checks passed")
    }
}
