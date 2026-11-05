import Foundation
import Testing
@testable import VoiceTranscription

@Suite struct TranscriptRepairTests {
    /// Builds words 0.3 s apart.
    private func words(_ text: String, from start: TimeInterval = 0, confidence: Float = 0.9) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let time = start + Double(index) * 0.3
            return TranscriptWord(text: String(word), start: time, end: time + 0.25, confidence: confidence)
        }
    }

    private func joined(_ words: [TranscriptWord]) -> String {
        words.map(\.text).joined(separator: " ")
    }

    // MARK: Tail merging

    @Test func recoversAnEndingTheFinalWindowDropped() {
        let primary = words("the quick brown fox jumps")
        let tail = words("brown fox jumps over the lazy dog", from: 0.6)

        #expect(joined(TranscriptRepair.mergeTail(primary: primary, tail: tail))
            == "the quick brown fox jumps over the lazy dog")
    }

    @Test func aPeriodThePrimaryDecodeGuessedDoesNotStrandTheRecoveredWords() {
        let primary = words("and then the cat sat.")
        let tail = words("the cat sat on the mat by the door", from: 0.6)

        #expect(joined(TranscriptRepair.mergeTail(primary: primary, tail: tail))
            == "and then the cat sat on the mat by the door")
    }

    @Test func neverRemovesWordsWhenTheTailDecodeIsShorter() {
        let primary = words("one two three four five six")
        let tail = words("one two three four")

        #expect(TranscriptRepair.mergeTail(primary: primary, tail: tail) == primary)
    }

    @Test func restoresClosingPunctuationTheMainDecodeCutOff() {
        let primary = words("we can talk about it before we move on")
        let tail = words("about it before we move on.", from: 0.9)

        #expect(joined(TranscriptRepair.mergeTail(primary: primary, tail: tail))
            == "we can talk about it before we move on.")
    }

    @Test func restoresAQuestionMarkToo() {
        let primary = words("what do you think")
        let tail = words("what do you think?")

        #expect(joined(TranscriptRepair.mergeTail(primary: primary, tail: tail)) == "what do you think?")
    }

    @Test func leavesExistingPunctuationAlone() {
        let primary = words("what do you think?")
        let tail = words("what do you think.")

        #expect(TranscriptRepair.mergeTail(primary: primary, tail: tail) == primary)
    }

    @Test func doesNotTakePunctuationFromADifferentWord() {
        let primary = words("the first part ends here")
        let tail = words("the first part ends there.")

        #expect(TranscriptRepair.mergeTail(primary: primary, tail: tail) == primary)
    }

    @Test func identicalDecodesChangeNothing() {
        let primary = words("this is exactly the same text")
        #expect(TranscriptRepair.mergeTail(primary: primary, tail: primary) == primary)
    }

    @Test func anEmptyTailChangesNothing() {
        let primary = words("some words here")
        #expect(TranscriptRepair.mergeTail(primary: primary, tail: []) == primary)
    }

    @Test func anEmptyPrimaryTakesTheTail() {
        let tail = words("everything was dropped")
        #expect(TranscriptRepair.mergeTail(primary: [], tail: tail) == tail)
    }

    @Test func aTailWithNothingInCommonIsOnlyUsedIfItComesAfter() {
        let primary = words("the first part")
        let later = words("then a second part", from: 10)
        #expect(joined(TranscriptRepair.mergeTail(primary: primary, tail: later)) == "the first part then a second part")

        let overlapping = words("completely different words", from: 0.1)
        #expect(TranscriptRepair.mergeTail(primary: primary, tail: overlapping) == primary)
    }

    @Test func aRepeatedPhraseIsNotMatchedAcrossDistantTimes() {
        let primary = words("I think so yes", from: 0) + words("and more words", from: 20)
        let tail = words("I think so", from: 40)

        let merged = TranscriptRepair.mergeTail(primary: primary, tail: tail)
        #expect(joined(merged) == "I think so yes and more words I think so")
    }

    @Test func comparesWordsIgnoringCaseAndPunctuation() {
        let primary = words("okay, let's go.")
        let tail = words("Okay let's go there now please", from: 0)

        #expect(joined(TranscriptRepair.mergeTail(primary: primary, tail: tail)) == "okay, let's go there now please")
    }

    // MARK: Trailing artifacts

    private func stripped(
        _ input: [TranscriptWord],
        duration: TimeInterval,
        level: Double
    ) -> String {
        joined(TranscriptRepair.removeTrailingArtifacts(from: input, audioDuration: duration) { _, _ in level })
    }

    /// A stray word near the end, shaped like the ones measured in real recordings.
    private func withStrayWord(_ word: String = "Yeah.", at time: TimeInterval, confidence: Float = 0.3) -> [TranscriptWord] {
        words("I think that is right.") + [TranscriptWord(text: word, start: time, end: time + 0.2, confidence: confidence)]
    }

    @Test func removesAnInventedYeah() {
        #expect(stripped(withStrayWord(at: 40.64), duration: 41.0, level: 0.02) == "I think that is right.")
    }

    @Test func keepsAYeahThatWasReallySaid() {
        #expect(stripped(withStrayWord(at: 40.64, confidence: 0.72), duration: 41, level: 0.1).hasSuffix("Yeah."))
    }

    @Test func keepsAnUnsureWordThatIsAudible() {
        #expect(stripped(withStrayWord(at: 40.64), duration: 41, level: 0.8).hasSuffix("Yeah."))
    }

    @Test func keepsAWordThatIsNotAtTheVeryEnd() {
        #expect(stripped(withStrayWord(at: 38), duration: 41, level: 0.02).hasSuffix("Yeah."))
    }

    @Test func removesAnInventedTwoWordEnding() {
        let input = words("that sounds fine") + [
            TranscriptWord(text: "Oh,", start: 170.4, end: 170.6, confidence: 0.3),
            TranscriptWord(text: "yeah.", start: 170.64, end: 170.7, confidence: 0.23),
        ]

        #expect(stripped(input, duration: 170.7, level: 0.04) == "that sounds fine")
    }

    @Test func removesAtMostTwoWords() {
        let input = (0..<5).map {
            TranscriptWord(text: "yeah", start: 40.5 + Double($0) * 0.01, end: 40.6, confidence: 0.2)
        }

        #expect(stripped(input, duration: 41, level: 0).split(separator: " ").count == 3)
    }

    /// Real last words can be as quiet and unsure as any invented one.
    @Test(arguments: ["about.", "this.", "that.", "in.", "things."])
    func keepsARealLastWordHoweverQuietlyItTrailsOff(word: String) {
        #expect(stripped(withStrayWord(word, at: 40.64, confidence: 0.3), duration: 41, level: 0.02).hasSuffix(word))
    }

    @Test(arguments: ["Mm-hmm.", "Yeah.", "Oh", "Uh", "Okay."])
    func aLoneUnsureFillerIsNotDictation(word: String) {
        let input = [TranscriptWord(text: word, start: 0.3, end: 0.5, confidence: 0.3)]
        #expect(stripped(input, duration: 1.0, level: 0.8).isEmpty)
    }

    @Test func aShortRealDictationSurvives() {
        let input = words("Commit this.", confidence: 0.3)
        #expect(stripped(input, duration: 1.4, level: 0.8) == "Commit this.")
    }

    @Test func aDeliberateOneWordAnswerSurvives() {
        let input = [TranscriptWord(text: "Yeah.", start: 0.4, end: 0.7, confidence: 0.8)]
        #expect(stripped(input, duration: 1.4, level: 0.8) == "Yeah.")
    }

    @Test func aLoneUnsureRealWordSurvives() {
        let input = [TranscriptWord(text: "Commit.", start: 0.4, end: 0.7, confidence: 0.3)]
        #expect(stripped(input, duration: 1.4, level: 0.8) == "Commit.")
    }

    // MARK: Levels

    @Test func levelsAreRelativeToTheSpeechInTheRecording() {
        let sampleRate = 16_000.0
        let loud = [Float](repeating: 0.2, count: Int(sampleRate * 2))
        let quiet = [Float](repeating: 0.002, count: Int(sampleRate))
        let levels = AudioLevels(samples: loud + quiet, startTime: 100, sampleRate: sampleRate)

        #expect(abs(levels.relativeLevel(from: 100.5, to: 101) - 1) < 0.01)
        #expect(levels.relativeLevel(from: 102.2, to: 102.6) < 0.05)
    }

    @Test func levelsOutsideTheAudioAreZero() {
        let levels = AudioLevels(samples: [Float](repeating: 0.2, count: 16_000), startTime: 0, sampleRate: 16_000)
        #expect(levels.relativeLevel(from: 5, to: 6) == 0)
    }
}
