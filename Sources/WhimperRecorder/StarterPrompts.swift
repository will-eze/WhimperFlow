import Foundation

/// A starting clip set covering the four things that fail differently:
/// ordinary prose, email register, personal/technical jargon, and
/// numbers & dates. Edit them freely — the closer they are to what you
/// actually dictate, the more the baseline is worth.
enum StarterPrompts {
    struct Item {
        let name: String
        let text: String
    }

    /// The four short categories: one or two sentences each, close-mic.
    static let core: [Item] = prose + email + jargon + numbers

    static let all: [Item] = core + longForm + conditions

    static let prose: [Item] = [
        .init(name: "prose-01", text: "I've been thinking about how much of my day disappears into typing, and whether dictation could give some of it back."),
        .init(name: "prose-02", text: "The weather finally turned this week, so I walked to the café instead of taking the car."),
        .init(name: "prose-03", text: "There's a real difference between a tool that works and a tool you reach for without thinking about it."),
        .init(name: "prose-04", text: "She said the meeting could have been an email, and honestly she wasn't wrong."),
        .init(name: "prose-05", text: "I don't want something clever. I want something that does the same thing every single time."),
        .init(name: "prose-06", text: "It took me three attempts to explain what I meant, which is probably a sign the idea needed more work."),
    ]

    static let email: [Item] = [
        .init(name: "email-01", text: "Hi Sarah, thanks for sending the draft over. I've left a few comments in the margin and I'll follow up properly tomorrow."),
        .init(name: "email-02", text: "Apologies for the slow reply, last week was busier than expected. Are you still free on Thursday afternoon?"),
        .init(name: "email-03", text: "Just to confirm, we're meeting at the office rather than the usual place. Let me know if that doesn't work for you."),
        .init(name: "email-04", text: "Please find the updated figures attached. The second tab has the breakdown you asked about."),
        .init(name: "email-05", text: "Quick one: do we need approval before I go ahead, or can I just make a start?"),
        .init(name: "email-06", text: "Thanks again for your time today. I'll write up the actions and circulate them by Friday."),
    ]

    static let jargon: [Item] = [
        .init(name: "jargon-01", text: "WhimperFlow uses SFSpeechRecognizer with requiresOnDeviceRecognition set to true."),
        .init(name: "jargon-02", text: "The custom language model is compiled from the user dictionary and cached by content hash."),
        .init(name: "jargon-03", text: "I deployed the container to the k8s cluster, but the pod kept crash looping."),
        .init(name: "jargon-04", text: "Open the pull request against main and tag me for review once CI goes green."),
        .init(name: "jargon-05", text: "The TranscriptProcessor tokenizes the raw string, then applies filler removal and spoken punctuation."),
        .init(name: "jargon-06", text: "We're storing everything as JSON under Application Support, with no database involved."),
    ]

    static let numbers: [Item] = [
        .init(name: "numbers-01", text: "The invoice came to £25.60, which is less than I expected."),
        .init(name: "numbers-02", text: "Let's meet on the 23rd of March at half past two."),
        .init(name: "numbers-03", text: "Roughly 50% of the errors came from just three clips."),
        .init(name: "numbers-04", text: "The build finished in 1 minute 40 seconds, down from three minutes."),
        .init(name: "numbers-05", text: "Set the threshold to 0.12 and see whether that makes any difference."),
        .init(name: "numbers-06", text: "My reference number ends in 4472 and the account was opened in 2019."),
    ]

    /// Long-form takes, which the short categories can't produce.
    ///
    /// `SpeechService` rotates the recognition session at a 35s soft limit and a
    /// 60s hard limit, and rotation is where the transcript gets stitched back
    /// together. Every short clip is under 10s, so nothing in the core set has
    /// ever exercised that path. At roughly 14 characters per second of speech,
    /// these run about 44s, 51s, 66s and 44s — three cross the soft limit and
    /// `long-03` crosses the hard one. `long-03` is also deliberately the
    /// jargon-heaviest of the four, since jargon is where the errors live.
    static let longForm: [Item] = [
        .init(name: "long-01", text: "I've been trying to work out whether dictation actually saves me time, or whether it just moves the effort somewhere else. When I type, the thinking and the writing happen together, and I can stop halfway through a sentence and change my mind without it costing me anything. When I dictate, I have to know roughly where the sentence is going before I start, which turns out to be a completely different skill. The odd thing is that after a couple of weeks it stopped feeling like talking to a machine and started feeling like thinking out loud. I still catch myself over-articulating whenever I reach a word I know it tends to get wrong, and I suspect that habit is doing more harm than good."),
        .init(name: "long-02", text: "Hi Tom, thanks for the detailed write-up, and apologies for taking most of the week to come back to you on it. I've read through the whole thing twice now and I think the direction is right, but I've got two reservations worth talking through before we commit to anything. The first is timing: if we start in the middle of the month we'll run straight into the release freeze, and I'd rather not have that conversation twice. The second is scope, which has quietly grown since the original brief and now includes a fair amount nobody has costed. Could we find half an hour on Thursday or Friday? I'm flexible either day, and I'd rather sort this out properly than trade emails about it for another fortnight."),
        .init(name: "long-03", text: "WhimperFlow uses SFSpeechRecognizer with requiresOnDeviceRecognition set to true, so the audio never leaves the machine, and the custom language model is compiled from the user dictionary and cached by content hash. Once the recognizer returns a result, TranscriptProcessor tokenizes the raw string and applies filler removal, spoken punctuation, dictionary replacement, snippets, casing and number formatting, in that order, and every stage is pinned by golden tests. The part I keep getting wrong is the session rotation: when a dictation runs past the soft threshold the code commits a partial and cancels the task before ending the audio, which throws away the retro-correction for that whole chunk. I opened a pull request against main to fix the ordering, but CI was already red, because the container I deployed to the k8s cluster kept crash looping and the logs were all JSON with no timestamps worth reading."),
        .init(name: "long-04", text: "The invoice came to one thousand two hundred and forty pounds fifty, which is about eighteen percent over what we agreed back in March, and I only noticed because the total didn't match the spreadsheet. I've asked them to send a revised version by the twenty-third, and if it turns up on time we can still pay it inside this quarter. There were three line items I couldn't account for at all: two of them were small, around forty pounds each, but the third was nearly six hundred and had no description against it whatsoever. I'd rather sort that out now than discover it all over again in the audit next January."),
    ]

    /// Re-recordings of sentences already in the core set, under a different
    /// microphone condition — read at arm's length (`farfield-`) or close but
    /// softly (`quiet-`).
    ///
    /// Same text on purpose: holding the words constant makes the condition the
    /// only variable, so the WER difference against the original clip is
    /// attributable. `quiet-` takes exist to exercise the fixed VAD threshold,
    /// which auto-stops hands-free dictation when speech never crosses it.
    ///
    /// The text is looked up rather than retyped, so an edit to a core sentence
    /// can't leave its variant quietly describing different words.
    static let conditions: [Item] = [
        ("prose-01", "farfield"),
        ("email-02", "farfield"),
        ("jargon-03", "farfield"),
        ("jargon-05", "quiet"),
        ("prose-03", "quiet"),
        ("numbers-02", "quiet"),
    ].compactMap { name, condition in
        guard let base = core.first(where: { $0.name == name }) else { return nil }
        return Item(name: "\(condition)-\(name)", text: base.text)
    }
}
