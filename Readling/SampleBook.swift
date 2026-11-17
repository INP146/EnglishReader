import Foundation

/// A deliberately short, bundled excerpt, not the complete book.
/// Source/provenance and public-domain notice: SOURCE.md.
enum SampleBook {
    static let sourceURL = URL(string: "https://www.gutenberg.org/ebooks/11")!
    static let sourceNotice = "Lewis Carroll, Alice’s Adventures in Wonderland (1865). Short excerpts from the openings of Chapters I–III, from Project Gutenberg eBook #11. Public domain in the United States; check local law elsewhere."

    private static func excerpts() -> [(String, String)] {
        [
            ("I · Down the Rabbit-Hole", """
            Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, “and what is the use of a book,” thought Alice “without pictures or conversations?”

            So she was considering in her own mind (as well as she could, for the hot day made her feel very sleepy and stupid), whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.

            There was nothing so <em>very</em> remarkable in that; nor did Alice think it so <em>very</em> much out of the way to hear the Rabbit say to itself, “Oh dear! Oh dear! I shall be late!” (when she thought it over afterwards, it occurred to her that she ought to have wondered at this, but at the time it all seemed quite natural); but when the Rabbit actually <em>took a watch out of its waistcoat-pocket</em>, and looked at it, and then hurried on, Alice started to her feet, for it flashed across her mind that she had never before seen a rabbit with either a waistcoat-pocket, or a watch to take out of it, and burning with curiosity, she ran across the field after it, and fortunately was just in time to see it pop down a large rabbit-hole under the hedge.

            In another moment down went Alice after it, never once considering how in the world she was to get out again.

            The rabbit-hole went straight on like a tunnel for some way, and then dipped suddenly down, so suddenly that Alice had not a moment to think about stopping herself before she found herself falling down a very deep well.

            Either the well was very deep, or she fell very slowly, for she had plenty of time as she went down to look about her and to wonder what was going to happen next. First, she tried to look down and make out what she was coming to, but it was too dark to see anything; then she looked at the sides of the well, and noticed that they were filled with cupboards and book-shelves; here and there she saw maps and pictures hung upon pegs. She took down a jar from one of the shelves as she passed; it was labelled “ORANGE MARMALADE”, but to her great disappointment it was empty: she did not like to drop the jar for fear of killing somebody underneath, so managed to put it into one of the cupboards as she fell past it.

            “Well!” thought Alice to herself, “after such a fall as this, I shall think nothing of tumbling down stairs! How brave they’ll all think me at home! Why, I wouldn’t say anything about it, even if I fell off the top of the house!” (Which was very likely true.)
            """),
            ("II · The Pool of Tears", """
            “Curiouser and curiouser!” cried Alice (she was so much surprised, that for the moment she quite forgot how to speak good English); “now I’m opening out like the largest telescope that ever was! Good-bye, feet!” (for when she looked down at her feet, they seemed to be almost out of sight, they were getting so far off). “Oh, my poor little feet, I wonder who will put on your shoes and stockings for you now, dears? I’m sure <em>I</em> shan’t be able! I shall be a great deal too far off to trouble myself about you: you must manage the best way you can;—but I must be kind to them,” thought Alice, “or perhaps they won’t walk the way I want to go! Let me see: I’ll give them a new pair of boots every Christmas.”

            And she went on planning to herself how she would manage it. “They must go by the carrier,” she thought; “and how funny it’ll seem, sending presents to one’s own feet! And how odd the directions will look!

            <em>Alice’s Right Foot, Esq.</em>
            <em>Hearthrug,</em>
            <em>near the Fender,</em>
            <em>(with Alice’s love).</em>

            Oh dear, what nonsense I’m talking!”

            Just then her head struck against the roof of the hall: in fact she was now more than nine feet high, and she at once took up the little golden key and hurried off to the garden door.

            Poor Alice! It was as much as she could do, lying down on one side, to look through into the garden with one eye; but to get through was more hopeless than ever: she sat down and began to cry again.

            “You ought to be ashamed of yourself,” said Alice, “a great girl like you,” (she might well say this), “to go on crying in this way! Stop this moment, I tell you!” But she went on all the same, shedding gallons of tears, until there was a large pool all round her, about four inches deep and reaching half down the hall.
            """),
            ("III · A Caucus-Race and a Long Tale", """
            They were indeed a queer-looking party that assembled on the bank—the birds with draggled feathers, the animals with their fur clinging close to them, and all dripping wet, cross, and uncomfortable.

            The first question of course was, how to get dry again: they had a consultation about this, and after a few minutes it seemed quite natural to Alice to find herself talking familiarly with them, as if she had known them all her life. Indeed, she had quite a long argument with the Lory, who at last turned sulky, and would only say, “I am older than you, and must know better”; and this Alice would not allow without knowing how old it was, and, as the Lory positively refused to tell its age, there was no more to be said.

            At last the Mouse, who seemed to be a person of authority among them, called out, “Sit down, all of you, and listen to me! <em>I’ll</em> soon make you dry enough!” They all sat down at once, in a large ring, with the Mouse in the middle. Alice kept her eyes anxiously fixed on it, for she felt sure she would catch a bad cold if she did not get dry very soon.

            “Ahem!” said the Mouse with an important air, “are you all ready? This is the driest thing I know. Silence all round, if you please! ‘William the Conqueror, whose cause was favoured by the pope, was soon submitted to by the English, who wanted leaders, and had been of late much accustomed to usurpation and conquest. Edwin and Morcar, the earls of Mercia and Northumbria—’”

            “Ugh!” said the Lory, with a shiver.

            “I beg your pardon!” said the Mouse, frowning, but very politely: “Did you speak?”

            “Not I!” said the Lory hastily.

            “I thought you did,” said the Mouse. “—I proceed. ‘Edwin and Morcar, the earls of Mercia and Northumbria, declared for him: and even Stigand, the patriotic archbishop of Canterbury, found it advisable—’”

            “Found <em>what</em>?” said the Duck.

            “Found <em>it</em>,” the Mouse replied rather crossly: “of course you know what ‘it’ means.”
            """)
        ]
    }

    static func make() -> ReaderBook {
        ReaderBook(title: "Alice’s Adventures in Wonderland", author: "Lewis Carroll",
                   chapters: content().chapterInfo, isSample: true)
    }

    /// Generated on demand rather than stored, so the sample never takes disk space.
    static func content() -> BookContent {
        BookContent(chapters: excerpts().enumerated().map { index, excerpt in
            let html = excerpt.1.components(separatedBy: "\n\n")
                .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
                .joined()
            let text = (try? LenientHTML.extract(html)) ?? (text: excerpt.1, styles: [], anchors: [:])
            return ReaderChapter(id: "alice-excerpt-\(index + 1)", title: excerpt.0, text: text.text, styles: text.styles)
        })
    }
}
