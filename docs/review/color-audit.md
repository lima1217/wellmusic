## Theme colors (OKLCH)

| name | hex | L | C | h | warm gray? |
|---|---|---|---|---|---|
| pink_800 | #b60356 | 0.501 | 0.2001 | 4° |  |
| pink_dark | #f87098 | 0.719 | 0.1701 | 4° |  |
| pink_ink | #ffffff | 1.000 | 0.0000 | 90° | neutral |
| pink_ink_dark | #12100e | 0.175 | 0.0052 | 67° | yes |
| knockout_light | #ffffff | 1.000 | 0.0000 | 90° | neutral |
| knockout_dark | #000000 | 0.000 | 0.0000 | 0° | neutral |
| dark_page | #12100e | 0.175 | 0.0052 | 67° | yes |
| dark_chrome | #22201d | 0.245 | 0.0064 | 78° | yes |
| dark_subtle | #2d2b28 | 0.290 | 0.0061 | 78° | yes |
| dark_pressed | #373532 | 0.330 | 0.0059 | 78° | yes |
| dark_text | #f1eeea | 0.950 | 0.0063 | 75° | yes |
| dark_text_muted | #b3b1ad | 0.761 | 0.0061 | 85° | yes |
| light_page | #f3efeb | 0.954 | 0.0069 | 68° | yes |
| light_chrome | #fffffd | 0.999 | 0.0026 | 106° | neutral |
| light_subtle | #e7e4df | 0.920 | 0.0075 | 81° | yes |
| light_pressed | #dad7d2 | 0.880 | 0.0076 | 81° | yes |
| light_text | #181613 | 0.201 | 0.0067 | 78° | yes |
| light_text_muted | #4a4744 | 0.400 | 0.0064 | 68° | yes |

## Contrast (WCAG 2.x)

| ink | ground | ratio | needs | result | where |
|---|---|---|---|---|---|
| light_text | light_page | 15.78:1 | 4.5:1 | pass | body text on page |
| light_text | light_chrome | 18.03:1 | 4.5:1 | pass | body text on header / bar / queue |
| light_text_muted | light_page | 8.07:1 | 4.5:1 | pass | secondary text on page |
| light_text_muted | light_chrome | 9.22:1 | 4.5:1 | pass | secondary text on chrome |
| light_text | light_pressed | 12.58:1 | 4.5:1 | pass | text on selected row |
| light_text_muted | light_pressed | 6.43:1 | 4.5:1 | pass | secondary text on selected row |
| light_text | light_subtle | 14.24:1 | 4.5:1 | pass | text on secondary button |
| pink_800 | light_page | 5.85:1 | 4.5:1 | pass | accent text (playing title) on page |
| pink_800 | light_pressed | 4.67:1 | 4.5:1 | pass | accent text on selected playing row |
| pink_800 | light_chrome | 6.69:1 | 3.0:1 | pass | accent icon on chrome (non-text) |
| pink_ink | pink_800 | 6.70:1 | 4.5:1 | pass | white on accent button |
| dark_text | dark_page | 16.42:1 | 4.5:1 | pass | body text on page |
| dark_text | dark_chrome | 14.05:1 | 4.5:1 | pass | body text on chrome |
| dark_text_muted | dark_page | 8.87:1 | 4.5:1 | pass | secondary text on page |
| dark_text_muted | dark_chrome | 7.59:1 | 4.5:1 | pass | secondary text on chrome |
| dark_text | dark_pressed | 10.57:1 | 4.5:1 | pass | text on selected row |
| dark_text_muted | dark_pressed | 5.71:1 | 4.5:1 | pass | secondary text on selected row |
| dark_text | dark_subtle | 12.20:1 | 4.5:1 | pass | text on secondary button |
| pink_dark | dark_page | 7.02:1 | 4.5:1 | pass | accent text on page |
| pink_dark | dark_pressed | 4.52:1 | 4.5:1 | pass | accent text on selected playing row |
| pink_dark | dark_chrome | 6.01:1 | 4.5:1 | pass | accent text in queue / bar |
| pink_ink_dark | pink_dark | 7.02:1 | 4.5:1 | pass | ink on accent button |
| pink_800 | light_subtle | 5.28:1 | 3.0:1 | pass | accent icon on hover wash (non-text) |

0 failing pair(s).
