# Five-task test with first-time users (for you to run)

My walkthrough is a hypothesis; only real people who have never seen the app can prove the main path works without instructions. Run this with 3–5 people (at least 2 Chinese-UI, 1 English-UI), one at a time, before and after this branch if you can.

**Setup.** Fresh data folder (rename `~/Library/Application Support/wellmusic` while testing). On the desktop, put a folder `测试专辑` with 5 MP3s, 3 loose songs (one with a Chinese GBK tag if you have one), and a `notes.txt`.

**Say only:** "This is a music app. Please think aloud. I can't help, but there are no wrong moves." No hints.

| # | task (read aloud) | success | record |
|---|---|---|---|
| 1 | "Put the three songs on the desktop into the app." | all 3 in the library | time; first thing clicked; any pause > 5 s |
| 2 | "Now add the folder 测试专辑 as an album." | album appears | did they find + or drag? |
| 3 | "Play the third song of that album." | it plays | double-click discovered? |
| 4 | "Make the second song play right after this one." | queued via Play Next | found right-click? |
| 5 | "Remove one song, then get it back." | removed + undone | saw Undo in time? |
| bonus | Drag `notes.txt` in. "What happened?" | they can say why nothing was added | their words |

**After:** "What was confusing?" "Was any wording odd?" Note every place they hesitated, misread a label, or asked "what does this mean".

**Pass bar:** each task done unaided by ≥ 4 of 5 people, median under 60 s for tasks 1–4.

Native-speaker copy review: send [strings.csv](strings.csv) to one mainland-Chinese and one native-English reader; ask them to mark anything they would not say.
