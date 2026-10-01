# Testliste nach der Nachtschicht (1.→2. Oktober 2026)

Stand: wird über Nacht ergänzt. Jeder Abschnitt ist ein gemergter Bereich. Geprüft durch Tests und Review, in der App ausprobiert hat es noch niemand.

## Effect Controls und Effekte
1. Opacity animieren, Keyframes auswählen, Rechtsklick auf einen: Linear, Bezier, Ease In, Ease Out, Easy Ease, Hold. Bei Ease wird die Raute zum Kreis.
2. Keyframe mit Shift ziehen: rastet am Playhead, an Clip-Enden und an anderen Keyframes ein. Mit Option ziehen: lässt eine Kopie zurück.
3. Keyframes auswählen, Cmd+C, Playhead versetzen, Cmd+V. Geht auch auf einem anderen Clip.
4. Klick auf den Namen „Opacity" wählt alle Keyframes der Eigenschaft. Delete löscht sie.
5. Wert anklicken, Zahl tippen, Tab springt ins nächste Feld. Cmd beim Ziehen = fein.
6. „Uniform Scale" abwählen: Breite und Höhe getrennt.
7. Auf- und Zuklappen der Bereiche wird pro Clip-Art gemerkt.
8. Rounded Corners hinzufügen, Kopfzeile anklicken, Cmd+C, anderen Clip wählen, Cmd+V.
9. Suchfeld im Effects-Panel.

Fehlt noch: Übergänge (Cross Dissolve), Blend Modes, Crop. Clip-Geschwindigkeit ist in Arbeit.

## App-Rahmen: Menüs, Kürzel, Export
1. Menüs File, Markers und View ansehen. Cmd+Opt+K öffnet die Liste aller Tastenkürzel, dort nach „razor" suchen.
2. Panels anklicken: der blaue Rahmen folgt. Taste ` über dem Programm-Monitor maximiert ihn, noch einmal ` stellt zurück.
3. Rechtsklick auf einen Panel-Reiter: Close Panel und Maximize.
4. Cmd+N: Vorlage „YouTube 1080p 30" oder die Hochkant-Vorlage (TikTok, Shorts, Reels) wählen.
5. Einen Clip mit anderer Größe oder Bildrate in eine neue leere Sequenz ziehen: Es kommt die Frage, ob die Sequenz angepasst werden soll.
6. Cmd+M: YouTube 4K oder ProRes wählen und die Zusammenfassung lesen.
7. Ein Projekt öffnen, dessen Medien verschoben wurden: Dialog „Locate…".
8. File > Open Recent und File > Revert.

Hinweis: Beim Prüfen hat der Agent versehentlich den aktiven Workspace auf „Editing – MacBook" gestellt. Falls die App so startet: Window > Workspaces > „Editing – PC".

Fehlt noch: Tastenkürzel selbst ändern, Dateiname im Export-Dialog, History-Liste, einige Einstellungen (Standard-Standbilddauer, Scroll-Verhalten).

## Timeline
1. Clip-Kante anklicken (wird als Balken markiert), Opt+Links/Rechts trimmt um 1 Bild, mit Shift um 5. E verlängert die Kante bis zum Playhead.
2. Cmd+Ziehen an einer Kante: Ripple-Trim (orange). Beide Seiten eines Schnitts mit Shift anklicken und ziehen: Rolling.
3. Lücke zwischen zwei Clips anklicken, Delete schließt sie.
4. Clip mit Option ziehen: Kopie. Cmd+C, Playhead versetzen, Cmd+V (überschreibt), Cmd+Shift+V (fügt ein).
5. Zwei Clips wählen, Cmd+L verbindet oder trennt. Cmd+Links/Rechts schiebt die Auswahl um 1 Bild.
6. Snap und Linked Selection: zwei Knöpfe in der Lineal-Ecke.
7. M zweimal auf demselben Bild öffnet den Marker-Dialog (Name, Farbe, Kommentar). Shift+M springt zum nächsten Marker.
8. Rechtsklick auf Clip, Lücke, Spurkopf und Lineal.
9. Zoom: = und - zoomen in großen Schritten um den Playhead (rund 9 Drücke vom Überblick bis zum Einzelbild). `\` zeigt die ganze Sequenz, noch einmal `\` geht zurück.
10. Option+Scrollen und Pinch zoomen um den Mauszeiger. Unten liegt eine Zoom-Leiste mit Griffen: Griff ziehen zoomt, Leiste ziehen verschiebt, Doppelklick zeigt alles.

Fehlt noch: Source Patching getrennt vom Track Targeting, Gruppieren, Clip deaktivieren (Enable), Paste Attributes.

## Clip-Geschwindigkeit (Stream speed)
1. Clip anklicken, Cmd+R (oder Rechtsklick, Clip-Menü): Speed/Duration. 200 eintippen: der Clip wird halb so lang, der Name zeigt „[200%]".
2. Im selben Dialog Dauer ändern: die Geschwindigkeit rechnet mit. Kettensymbol aus: die Geschwindigkeit ändert nur, wie viel vom Clip gezeigt wird, die Länge bleibt.
3. Reverse Speed ankreuzen (oder -100 tippen): der Clip läuft rückwärts, Ton auch. „Maintain Audio Pitch" hält die Tonhöhe, aus = Chipmunk-Effekt.
4. „Ripple Edit, Shifting Trailing Clips": die Clips danach rücken mit. Ohne: der Clip wächst nur in freien Platz und wird sonst abgeschnitten.
5. R = Rate Stretch: Clipkante ziehen, die Geschwindigkeit ändert sich, der Ausschnitt bleibt. Cmd+Z macht es in einem Schritt rückgängig.
6. Beschleunigten Clip mit C schneiden, trimmen, verschieben: Bild bleibt durchgehend, Keyframes bleiben an ihrer Stelle.
7. Export: Länge und Ton passen zum Abspielen.

Fehlt noch: Speed-Rampen (Zeit-Remapping), Geschwindigkeit für verschachtelte Sequenzen und Standbilder, Frame-Blending.
## Monitore und Projekt-Panel
1. Clip im Projekt-Panel doppelklicken: öffnet im Source-Monitor. I und O setzen In und Out. `,` fügt am Playhead ein, `.` überschreibt. Der Playhead springt ans Ende des neuen Clips.
2. Das Film-Symbol unter dem Source-Bild auf die Timeline ziehen (nur Video), danach das Wellenform-Symbol (nur Audio).
3. In der Timeline F drücken: Der Clip öffnet sich im Source-Monitor auf demselben Bild. Shift+R springt zurück.
4. Leertaste, J/K/L, Shift+L, K+L in beiden Monitoren. Timecode nach links und rechts ziehen zum Scrubben, anklicken zum Tippen.
5. Schraubenschlüssel-Menü: Loop, Safe Margins. Shift+Leertaste spielt von In bis Out. Shift+E exportiert ein Standbild.
6. Projekt-Panel: Icon-Ansicht umschalten, mit der Maus über einen Clip fahren (Hover-Scrub), Cmd+B neuer Bin, Return benennt um, Rechtsklick: „New Sequence From Clip", „Replace Footage".
7. Programm-Monitor: Clip wählen, an einem Seitengriff ziehen (skaliert gleichmäßig). „Uniform Scale" in den Effect Controls abwählen und noch einmal ziehen (nur Breite).
8. Ankerpunkt in der Bildmitte greifen und ziehen: Das Bild bleibt stehen. Knapp außerhalb einer Ecke erscheint der Dreh-Pfeil, Shift rastet in 45°-Schritten.

Fehlt noch: Marker im Source-Monitor, Vier-Punkt-Schnitt (Fit to Fill), eigene Source-Patch-Knöpfe.

## Farbe
1. Color-Seite, Clip wählen: einen Zahlenwert nach links und rechts ziehen, dann anklicken und eine Zahl tippen (auch „1,5").
2. Pipette neben White Balance anklicken, dann im Programm-Monitor auf eine graue Fläche klicken. Die Pipette ist ausgegraut, wenn eine andere Spur sichtbar ist oder der Clip mehrere Farb-Effekte hat.
3. Gruppe Light: „Auto" auf einem flauen Bild, danach Reset.
4. Curves > Hue Saturation Curves > Hue vs Sat: einen Punkt im blauen Bereich setzen und hochziehen.
5. Creative: Die Look-Vorschau zeigt dein eigenes Bild, wenn der Playhead über dem Clip steht.
6. „Copy Colour", zwei andere Clips wählen, „Paste Colour", einmal Undo.

Fehlt noch: Sharpen und HSL Secondary (ausgegraut). Pipette und Auto messen das Gesamtbild und sind deshalb bei mehreren Ebenen gesperrt.

## Text, Untertitel, Audio
1. Type-Tool (T): in den Programm-Monitor klicken, tippen, Cmd+Return. Dann eine Box aufziehen, eine lange Zeile tippen und in den Effect Controls „Vertical" auf Middle stellen.
2. Mit dem Type-Tool auf vorhandenen Text klicken: bearbeiten. Cmd+B und Cmd+I schalten Fett und Kursiv.
3. Textstil: Laufweite erhöhen, Kursiv, Schattenwinkel 135 mit Abstand.
4. Clip transkribieren, im Captions-Reiter „Create Captions…", Vorlage „Short Video". Die Untertitel erscheinen im Monitor.
5. Captions-Reiter: Untertitel bearbeiten, Wort suchen und ersetzen, Stil ändern. Rechtsklick auf einen Untertitel in der Timeline: teilen, zusammenführen.
6. Audiospur höher ziehen (Opt+=). Die grüne Linie ziehen, Cmd-Klick setzt einen Keyframe, Rechtsklick auf den Keyframe löscht ihn.
7. Audioclip wählen, G drücken, „Normalize Max Peak" auf -3 dB.
8. Nur den Ton eines verbundenen Clips verschieben (Option-Klick wählt eine Seite): rotes Abzeichen mit dem Versatz.

Fehlt noch: Audio-Übergänge, Untertitel direkt im Monitor bearbeiten, Schalter zum Ausblenden der Untertitel.

## Umbenennung
Projektdateien heißen jetzt `.sqproj`. Eine alte `.ssproj`-Datei öffnen und speichern: Es entsteht eine neue `.sqproj` daneben, die alte bleibt liegen.

# Zweite Runde (Morgen des 2. Oktober)

Geprüft durch Tests und Review. In der App ausprobiert hat es noch niemand.

## Übergänge
1. Zwei Clips nebeneinander, beide am Schnitt um etwa 15 Bilder trimmen, Playhead an den Schnitt, Cmd+D: Cross Dissolve. Durchscrubben.
2. Shift+Cmd+D macht die Audio-Überblendung, Shift+D beides.
3. „Dip to Black" aus dem Effects-Panel auf einen Schnitt ziehen: links, Mitte oder rechts vom Schnitt bestimmt die Ausrichtung.
4. Den Kasten anklicken, die rechte Kante ziehen (mit Shift nur eine Seite), den Kasten selbst ziehen, Doppelklick für die Dauer.
5. Cmd+D an einem Schnitt ohne Reserve: Meldung in der Statuszeile.
6. Einen Clip mit Übergang mit dem Razor schneiden: Der Übergang bleibt am Schnitt.

## Timeline-Schnitt
1. Playhead in den ersten von zwei aneinanderliegenden Clips, Shift+W (der Schnitt springt zum Playhead, Länge bleibt), dann Opt+W (Lücke bleibt).
2. Clip ziehen: normal überschreibt, mit Cmd fügt ein (Lücke am alten Platz), mit Cmd+Option sortiert um, mit Option kopiert. Die Statuszeile zeigt die Art an.
3. Z drücken: Klick zoomt hinein, Opt-Klick heraus, Kasten ziehen zoomt auf den Bereich.
4. Clip wählen, Shift+Cmd+E: wird grau und in der Wiedergabe schwarz und stumm.
5. Shift+Cmd+/ dupliziert die Auswahl dahinter.
6. Schnittkante anklicken, Ctrl+T mehrmals: wechselt zwischen normalem Trim, Ripple und Rolling.
7. Opt+Hoch und Opt+Runter verschiebt den Clip um eine Spur.
8. Clip an den Rand der Timeline ziehen: Die Ansicht scrollt mit. S während des Ziehens kehrt Snapping um.

## Source-Monitor und Projekt
1. L L L, dann J J J: 4-fach, 2-fach, 1-fach, dann rückwärts.
2. In und Out setzen: Die Dauer zählt das Out-Bild mit.
3. In der Sequenz nur ein Out setzen, dann `.` aus dem Source-Monitor: Der Clip endet am Out.
4. Source-Monitor: X markiert den ganzen Clip, M setzt Marker, die In/Out-Griffe auf der Leiste lassen sich ziehen. Titel-Popup zeigt die letzten Clips.
5. Shift+Leertaste spielt In bis Out mit Vor- und Nachlauf, Shift+K spielt um den Playhead herum und springt zurück.
6. Im Timecode-Feld `+10` oder `-5` tippen.
7. Projekt-Panel: mit der Maus über einen Clip, I und O drücken, Cmd+P setzt das Titelbild, Cmd+F sucht. Sequenz löschen.

## Untertitel und Text
1. Clip transkribieren, „Create Captions" mit „Short Video", im Captions-Reiter „Word Highlight" anhaken, abspielen: Das gesprochene Wort wird gelb.
2. Einen Untertitel verschieben und trimmen: Die Hervorhebung stimmt weiter.
3. Export mit eingebrannten Untertiteln: Die Hervorhebung sieht aus wie im Monitor.
4. Einem Untertitel per Rechtsklick einen eigenen Stil geben, dann den Spur-Stil ändern: Die anderen ändern sich, dieser nicht.
5. View > Show Captions in Program Monitor.
6. Untertitel im Programm-Monitor doppelklicken und tippen.
7. Textclip: All Caps, Kontur außen oder mittig, sechs Ausrichten-Knöpfe.

## Effekte
1. Clip > Video Options > Fade In und Fade Out.
2. Gaussian Blur zweimal anwenden, beide Werte setzen, eine Kopfzeile über die andere ziehen.
3. Crop anwenden und „Left" animieren.
4. Oberen Clip über einen anderen legen, Blend Mode auf Multiply.
5. Cmd-Klick auf die weiße Linie eines ausgewählten Videoclips: Deckkraft-Keyframe.
6. Clip > Video Options > Insert Frame Hold Segment, dann Undo.
7. Clip mit Effekten kopieren, anderen wählen, Cmd+Opt+V.
8. Ultra Key auf Greenscreen-Material.

## Tempo und Zeit
1. Videoclip wählen, Clip > Show Time Remapping, an zwei Stellen Cmd-Klick auf die Linie.
2. Den mittleren Teil hochziehen (etwa 400 %): Der Clip wird kürzer.
3. Die rechte Hälfte eines Punkts nach rechts ziehen: Rampe.
4. Abspielen: Bild und Ton folgen der Rampe.
5. Cmd+R auf einem verlangsamten Clip, Time Interpolation auf Frame Blending.
6. Speed/Duration auf einer verschachtelten Sequenz.

Fehlt noch: weiche Tempo-Kurven, Optical Flow, Wischblenden, Trim-Modus per Doppelklick, Gruppieren, Source Patching, Sharpen, HSL Secondary. Das Audio-Paket (Fade-Griffe, Ducking, Pan, Lautheit) ist noch in Arbeit.

## Audio (zweite Runde)
1. Audioclip wählen, `]` und `[` drücken (1 dB), mit Shift 6 dB.
2. Den Griff an der Clip-Kante ziehen: Fade In oder Fade Out. Eigene Lautstärke-Punkte bleiben erhalten.
3. Cmd-Klick auf die Lautstärke-Linie, dann den Punkt an seinem Nachbarn vorbeiziehen: geht nicht.
4. Einen Clip als Music und einen als Dialogue markieren (Clip > Audio Options), dann „Auto Duck Music".
5. „Match Loudness" auf einem leisen Clip.
6. Rechtsklick auf eine Audiospur > „Volume and Pan…": ganz nach links drehen, exportieren und vergleichen.

„Remove Silences…" ist gebaut, aber ausgeblendet, bis du entscheidest, ob du es willst.

## Befehle und Kürzel
1. Clip wählen, Cmd+Pfeil verschiebt um ein Bild. Schnittkante wählen, Opt+Pfeil trimmt um ein Bild.
2. Keyframes in den Effect Controls wählen, F9: Easy Ease.
3. Cmd+Opt+K, nach „trim" suchen.
4. Mit der Maus über einen Monitor-Knopf: Der Tooltip zeigt das Kürzel.

## Kleinere Korrekturen aus dem Review der Oberfläche
1. Clips mit anderer Bildrate aus dem Projekt-Panel auf die Timeline ziehen: Sie liegen ohne Lücke aneinander.
2. Etwas auf eine gesperrte Spur ziehen: Die Statuszeile nennt den Grund.
3. Neues Projekt öffnen: Wiedergabe stoppt, In/Out und Zwischenablage sind leer.
