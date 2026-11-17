//! A small language guess for the seven languages the models cover: counts frequent function words.

const WORDS: &[(&str, &str)] = &[
    (
        "en",
        "the and is are was were you your that this with for not have has but what they we it of to in on at be will can do does",
    ),
    (
        "de",
        "der die das und ist sind war nicht ich du sie wir ihr mit für auf ein eine einen es zu den dem von auch aber wie wenn dass nur noch schon",
    ),
    (
        "fr",
        "le la les des est sont une un et pas vous nous je il elle ce cette que qui dans pour sur avec mais ou plus très être avoir",
    ),
    (
        "es",
        "el la los las es son una un y no usted nosotros yo él ella este esta que quien en para con pero o más muy ser estar hay",
    ),
    (
        "it",
        "il lo la gli le è sono una uno e non voi noi io lui lei questo questa che chi di in per con ma o più molto essere avere c'è",
    ),
    (
        "pt",
        "o a os as é são uma um e não você nós eu ele ela este esta que quem em para com mas ou mais muito ser estar tem",
    ),
    (
        "nl",
        "de het een en is zijn niet je jij wij ik hij zij dit dat die dat van in op met maar of meer heel zeer ook nog wel",
    ),
];

/// The most likely language code among en, de, fr, es, it, pt, nl for `texts`; `None` when no word matches or two tie.
// Deliberate: Swift asks Apple's NLLanguageRecognizer (EditorSession+CaptionTranslate.swift:27); here stop words over seven
// languages score, on every OS (no character n-grams), upgrade when a wrong guess is reported.
pub fn detect_language(texts: &[String]) -> Option<&'static str> {
    let mut scores = [0usize; WORDS.len()];
    for text in texts {
        for word in text.split(|c: char| !(c.is_alphanumeric() || c == '\'')).filter(|w| !w.is_empty()) {
            let lower = word.to_lowercase();
            for (i, (_, list)) in WORDS.iter().enumerate() {
                if list.split(' ').any(|w| w == lower) {
                    scores[i] += 1;
                }
            }
        }
    }
    let best = scores.iter().copied().max().filter(|m| *m > 0)?;
    let mut top = scores.iter().enumerate().filter(|(_, s)| **s == best);
    let first = top.next()?;
    top.next().is_none().then(|| WORDS[first.0].0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one(s: &str) -> Option<&'static str> {
        detect_language(&[s.to_string()])
    }

    #[test]
    fn guesses_the_seven_languages() {
        assert_eq!(one("This is the best day and we are happy"), Some("en"));
        assert_eq!(one("Das ist der beste Tag und wir sind nicht traurig"), Some("de"));
        assert_eq!(one("C'est le meilleur jour et nous sommes très contents"), Some("fr"));
        assert_eq!(one("Este es el mejor día y nosotros no estamos tristes"), Some("es"));
        assert_eq!(one("Questo è il giorno migliore e non siamo tristi"), Some("it"));
        assert_eq!(one("Este é o melhor dia e nós não estamos tristes"), Some("pt"));
        assert_eq!(one("Dit is de beste dag en we zijn niet verdrietig"), Some("nl"));
        assert_eq!(one("12345"), None);
    }
}
