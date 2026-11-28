import Foundation

@main struct StationCatalogChecks {
    static func main() throws {
        let stations = StationCatalog.merging([])
        precondition(stations.count == 50)
        precondition(Set(stations.compactMap(\.catalogID)).count == stations.count)
        precondition(Set(stations.map(\.name)).count == stations.count)
        precondition(Set(stations.map(\.prompt)).count == stations.count)
        let groups = Dictionary(grouping: stations) { StationCatalog.preset(for: $0)?.category }
        precondition(groups.count == StationCategory.allCases.count && groups[nil] == nil)
        precondition(groups[.christmas]?.count == 7 && groups[.workout]?.count == 7)

        let christmas = stations.first { $0.catalogID == "christmas-morning" }!
        let holidayRequest = MusicPromptBuilder().makeRequest(profile: christmas.musicProfile, seed: 42)
        precondition(holidayRequest.voice == .vocals)
        precondition(holidayRequest.style.contains("sleigh bells"))
        precondition(holidayRequest.style.contains("gathering with family"))
        precondition(StationCatalog.matches(christmas, query: "CHRISTMAS bells"))
        precondition(!StationCatalog.matches(christmas, query: "Christmas techno"))

        var frenchStation = christmas
        frenchStation.tags.append(tagOptions.first { $0.category == .language && $0.name == "French" }!)
        let savedFrench = try JSONDecoder().decode(Vibe.self, from: JSONEncoder().encode(frenchStation))
        let frenchRequest = MusicPromptBuilder().makeRequest(profile: savedFrench.musicProfile, seed: 42)
        precondition(frenchRequest.voice == .vocals && frenchRequest.style.hasPrefix("vocals sung in French; ")
                     && frenchRequest.style.contains("clear diction"))
        let instrumentalRequest = MusicPromptBuilder().makeRequest(profile: savedFrench.musicProfile, seed: 42,
                                                                    voiceOverride: .instrumental)
        precondition(instrumentalRequest.voice == .instrumental && !instrumentalRequest.style.contains("French"))

        var editedDefault = stations.first!
        editedDefault.catalogID = nil
        editedDefault.tempo = 101
        editedDefault.tags[0].intensity = 0.24
        let custom = Vibe(name: "Christmas Morning", subtitle: "Custom station", tags: christmas.tags,
                          tempo: 85, palette: 1, soundDescription: "  Warm horns and a steady beat.  ")
        let data = try JSONEncoder().encode([editedDefault, custom])
        let legacy = try JSONDecoder().decode([Vibe].self, from: data)
        let upgraded = StationCatalog.merging(legacy)
        precondition(upgraded.count == 51)
        precondition(upgraded.first?.catalogID == "lofi-beats")
        precondition(upgraded.first?.id == editedDefault.id)
        precondition(upgraded.first?.tempo == 101 && upgraded.first?.tags == editedDefault.tags)
        precondition(upgraded.last?.id == custom.id && upgraded.last?.catalogID == nil)
        precondition(upgraded.last?.prompt.contains("sound direction: Warm horns and a steady beat.") == true)
        precondition(StationCatalog.merging(upgraded).map(\.id) == upgraded.map(\.id))
        print("Station catalog checks passed")
    }
}
